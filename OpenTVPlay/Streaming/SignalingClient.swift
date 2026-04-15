import Foundation
import Network

// MARK: - Signaling Events

enum SignalingEvent {
    case connected
    case disconnected(reason: String)
    case offer(sdp: String)
    case remoteICE(candidate: String, sdpMid: String?, sdpMLineIndex: Int?)
    case log(String)
    case error(String)
}

// MARK: - GFN Signaling Client
//
// Uses NWConnection + NWProtocolWebSocket (system WebSocket) so Apple handles the HTTP/1.1
// upgrade handshake and RFC 6455 framing automatically.
//
// Key points:
//  • NWProtocolWebSocket always uses HTTP/1.1 WebSocket (not HTTP/2 / RFC 8441).
//    URLSessionWebSocketTask would negotiate h2 ALPN and attempt RFC 8441, which the
//    GFN signaling server does not support — hence we stay on NWConnection.
//  • No ALPN is set in TLS options — GFN's WebSocket server doesn't register any ALPN token.
//  • No cipher suite group restriction — system defaults include TLS 1.3 which the server requires.
//    (The old .legacy group excluded TLS 1.3 and caused HANDSHAKE_FAILURE_ON_CLIENT_HELLO.)
//  • Certificate validation is bypassed (mirrors OpenNOW rejectUnauthorized:false).
//  • Old heartbeat/receive tasks are cancelled at connect() entry to prevent zombie writes.

final class GFNSignalingClient {
    private let signalingUrl: String
    private let sessionId: String
    private let serverIp: String

    private var connection: NWConnection?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var ackCounter = 0
    private let peerId = 2
    private let peerName: String
    private(set) var connectedHost: String = ""
    private(set) var resolvedIPs: [String] = []

    var onEvent: ((SignalingEvent) -> Void)?

    init(signalingUrl: String, sessionId: String, serverIp: String = "") {
        self.signalingUrl = signalingUrl
        self.sessionId = sessionId
        self.serverIp = serverIp
        self.peerName = "peer-\(Int.random(in: 0..<10_000_000_000))"
    }

    // MARK: Connect

    func connect() async throws {
        // Cancel any zombie tasks / previous connection before starting fresh.
        heartbeatTask?.cancel()
        receiveTask?.cancel()
        connection?.cancel()
        connection = nil

        guard let url = URL(string: signalingUrl), let host = url.host else {
            throw SignalingError.invalidUrl(signalingUrl)
        }

        // Build the full WebSocket URL including path and peer_id / version query params.
        // NWEndpoint.url(_:) passes this path to NWProtocolWebSocket's HTTP upgrade GET request.
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.path = (comps.path.hasSuffix("/") ? comps.path : comps.path + "/") + "sign_in"
        comps.queryItems = [
            URLQueryItem(name: "peer_id", value: peerName),
            URLQueryItem(name: "version", value: "2"),
        ]
        guard comps.url != nil else { throw SignalingError.invalidUrl(signalingUrl) }

        let useTLS = url.scheme == "wss" || url.scheme == "https"

        // Resolve all IPs for the signaling hostname upfront so we can try each one
        // directly. NWConnection's Happy Eyeballs cache locks subsequent retries onto the
        // same "preferred" address — explicit enumeration bypasses that.
        let resolvedIPs = await resolveIPs(hostname: host)
        self.resolvedIPs = resolvedIPs   // expose for ICE injection
        // Append the hostname itself as a final fallback in case direct IP connections fail.
        let candidates: [String] = resolvedIPs.isEmpty ? [host] : (resolvedIPs + [host])
        print("[Signaling] Resolved \(resolvedIPs.count) IPs for '\(host)': \(resolvedIPs.joined(separator: ", "))")

        var lastError: Error?
        for (i, candidateHost) in candidates.prefix(8).enumerated() {
            // Fresh TLS/WS/params per attempt — each NWConnection needs its own option objects.
            // SNI is always set to the original hostname since we're connecting by IP.
            let tlsOpts = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tlsOpts.securityProtocolOptions, .TLSv12)
            if useTLS {
                sec_protocol_options_set_tls_server_name(tlsOpts.securityProtocolOptions, host)
            }
            sec_protocol_options_set_verify_block(tlsOpts.securityProtocolOptions,
                                                  { _, _, complete in complete(true) },
                                                  .global(qos: .userInitiated))
            // WebSocket options — system handles HTTP upgrade, framing, and ping/pong.
            // Register GFN session subprotocol — server echoes x-nv-sessionid.{id} in its 101;
            // RFC 6455 §4.1 requires we offer it or NWProtocolWebSocket aborts (ECONNABORTED).
            let wsOpts = NWProtocolWebSocket.Options()
            wsOpts.autoReplyPing = true
            wsOpts.setSubprotocols(["x-nv-sessionid.\(sessionId)"])
            wsOpts.setAdditionalHeaders([
                ("Origin", "https://play.geforcenow.com"),
                ("User-Agent", NVIDIAAuth.userAgent),
            ])
            let params: NWParameters = useTLS
                ? NWParameters(tls: tlsOpts, tcp: NWProtocolTCP.Options())
                : .tcp
            params.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)

            var epComps = comps
            epComps.host = candidateHost
            guard let candidateUrl = epComps.url else { continue }
            let candidateEndpoint = NWEndpoint.url(candidateUrl)

            if i == 0 {
                print("[Signaling] Connecting → \(candidateUrl.absoluteString)")
            } else {
                print("[Signaling] Trying candidate \(i + 1)/\(min(candidates.count, 8)) → \(candidateUrl.absoluteString)")
            }

            let conn = NWConnection(to: candidateEndpoint, using: params)
            connection = conn

            do {
                // .ready fires only after TLS handshake AND WebSocket HTTP upgrade both complete.
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            conn.stateUpdateHandler = nil
                            print("[Signaling] Connected (WebSocket ready) via \(candidateHost)")
                            cont.resume()
                        case .failed(let err):
                            conn.stateUpdateHandler = nil
                            print("[Signaling] Connection failed (\(candidateHost)): \(err)")
                            cont.resume(throwing: err)
                        case .cancelled:
                            conn.stateUpdateHandler = nil
                            cont.resume(throwing: SignalingError.cancelled)
                        case .waiting(let err):
                            let desc = "\(err)"
                            if desc.contains("53") || desc.contains("ECONNABORTED") {
                                // ECONNABORTED = server rejected WS handshake — try the next IP.
                                conn.stateUpdateHandler = nil
                                print("[Signaling] ECONNABORTED (\(candidateHost)) — trying next IP")
                                cont.resume(throwing: err)
                            } else {
                                print("[Signaling] Waiting: \(err)")
                            }
                        default:
                            break
                        }
                    }
                    conn.start(queue: .global(qos: .userInitiated))
                }
                lastError = nil
                connectedHost = candidateHost
                break  // connected — stop trying candidates
            } catch {
                lastError = error
                let desc = "\(error)"
                guard desc.contains("53") || desc.contains("ECONNABORTED") else { break }
                conn.cancel()
                connection = nil
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        if let e = lastError { throw e }

        startReceiving()
        sendPeerInfo()
        startHeartbeat()
        onEvent?(.connected)
    }

    // MARK: Send Answer

    func sendAnswer(sdp: String, nvstSdp: String? = nil) {
        var payload: [String: Any] = ["type": "answer", "sdp": sdp]
        if let nvstSdp { payload["nvstSdp"] = nvstSdp }
        sendJson([
            "peer_msg": ["from": peerId, "to": 1, "msg": jsonString(payload)],
            "ackid": nextAckId(),
        ])
    }

    // MARK: Send ICE Candidate

    func sendICECandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        var payload: [String: Any] = ["candidate": candidate]
        if let sdpMid { payload["sdpMid"] = sdpMid }
        if let sdpMLineIndex { payload["sdpMLineIndex"] = sdpMLineIndex }
        sendJson([
            "peer_msg": ["from": peerId, "to": 1, "msg": jsonString(payload)],
            "ackid": nextAckId(),
        ])
    }

    // MARK: Request Keyframe

    func requestKeyframe(reason: String = "decoder_recovery", backlogFrames: Int = 0, attempt: Int = 1) {
        sendJson([
            "peer_msg": ["from": peerId, "to": 1, "msg": jsonString([
                "type": "request_keyframe",
                "reason": reason,
                "backlogFrames": backlogFrames,
                "attempt": attempt,
            ])],
            "ackid": nextAckId(),
        ])
    }

    // MARK: Disconnect

    func disconnect() {
        heartbeatTask?.cancel()
        receiveTask?.cancel()
        connection?.cancel()
        connection = nil
    }

    // MARK: Private — Peer Info / Heartbeat

    private func sendPeerInfo() {
        sendJson([
            "ackid": nextAckId(),
            "peer_info": [
                "browser": "Chrome",
                "browserVersion": "131",
                "connected": true,
                "id": peerId,
                "name": peerName,
                "peerRole": 0,
                "resolution": "1920x1080",
                "version": 2,
            ],
        ])
    }

    private func startHeartbeat() {
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                sendJson(["hb": 1])
            }
        }
    }

    // MARK: Private — WebSocket Receive Loop

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    if let text = try await self.receiveTextMessage() {
                        self.handleMessage(text)
                    }
                } catch {
                    if !Task.isCancelled {
                        print("[Signaling] Receive error: \(error)")
                        self.onEvent?(.disconnected(reason: error.localizedDescription))
                    }
                    return
                }
            }
        }
    }

    /// Reads one complete WebSocket message from the server. Accumulates chunks across
    /// multiple receive() callbacks until isComplete=true (NWConnection delivers large
    /// messages in partial deliveries). Returns the UTF-8 text payload for text frames,
    /// nil for control frames (ping is handled automatically by autoReplyPing).
    private func receiveTextMessage() async throws -> String? {
        guard let conn = connection else { throw SignalingError.cancelled }
        var buffer = Data()
        var messageOpcode: NWProtocolWebSocket.Opcode? = nil

        while true {
            let (chunk, opcode, isComplete) = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<(Data?, NWProtocolWebSocket.Opcode?, Bool), Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { content, context, isComplete, error in
                    if let error { cont.resume(throwing: error); return }
                    let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                               as? NWProtocolWebSocket.Metadata
                    cont.resume(returning: (content, meta?.opcode, isComplete))
                }
            }

            if let data = chunk { buffer.append(data) }
            if messageOpcode == nil, let op = opcode { messageOpcode = op }
            guard isComplete else { continue }  // more chunks coming for this message

            switch messageOpcode {
            case .text:
                return String(data: buffer, encoding: .utf8)
            case .close:
                if buffer.count >= 2 {
                    let code = UInt16(buffer[0]) << 8 | UInt16(buffer[1])
                    let reason = buffer.count > 2
                        ? String(data: buffer.subdata(in: 2..<buffer.count), encoding: .utf8) ?? "<non-UTF8>"
                        : ""
                    print("[Signaling] Server closed: code=\(code) reason=\(reason.isEmpty ? "(none)" : reason)")
                } else {
                    print("[Signaling] Server closed: no close-frame data")
                }
                throw SignalingError.remoteClosed
            case nil:
                // isComplete with no WS metadata = TCP stream closed without a CLOSE frame
                throw SignalingError.remoteClosed
            default:
                // Binary, ping (handled by autoReplyPing), pong — skip
                return nil
            }
        }
    }

    // MARK: Private — Send

    private func sendJson(_ obj: [String: Any]) {
        guard let conn = connection,
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        if let str = String(data: data, encoding: .utf8) { print("[Signaling] → \(str.prefix(300))") }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "ws-text", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true,
                  completion: .contentProcessed { err in
            if let err { print("[Signaling] Send error: \(err)") }
        })
    }

    // MARK: Private — Message Handling

    private func handleMessage(_ text: String) {
        print("[Signaling] ← \(text.prefix(300))")
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // ACK
        if let ackId = obj["ackid"] as? Int {
            let shouldAck = (obj["peer_info"] as? [String: Any])?["id"] as? Int != peerId
            if shouldAck { sendJson(["ack": ackId]) }
        }

        // Heartbeat
        if obj["hb"] != nil {
            sendJson(["hb": 1])
            return
        }

        // Peer message
        guard let peerMsg = obj["peer_msg"] as? [String: Any],
              let msgStr = peerMsg["msg"] as? String,
              let msgData = msgStr.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any]
        else { return }

        // SDP offer
        if payload["type"] as? String == "offer", let sdp = payload["sdp"] as? String {
            onEvent?(.offer(sdp: sdp))
            return
        }

        // ICE candidate
        if let candidate = payload["candidate"] as? String {
            let mid = payload["sdpMid"] as? String
            let mLineIndex = payload["sdpMLineIndex"] as? Int
            onEvent?(.remoteICE(candidate: candidate, sdpMid: mid, sdpMLineIndex: mLineIndex))
            return
        }

        onEvent?(.log("Unhandled peer message keys: \(payload.keys.joined(separator: ", "))"))
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    private func nextAckId() -> Int {
        ackCounter += 1
        return ackCounter
    }

    // MARK: Private — DNS Resolution

    /// Returns all IPv4/IPv6 addresses for `hostname` via getaddrinfo, deduplicated.
    /// Called before the connection loop so we can try each IP directly, bypassing
    /// NWConnection's Happy Eyeballs preference cache that would lock all retries onto
    /// the same address after the first connection attempt to a given hostname.
    private func resolveIPs(hostname: String) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var res: UnsafeMutablePointer<addrinfo>? = nil
                guard getaddrinfo(hostname, nil, &hints, &res) == 0 else {
                    cont.resume(returning: [])
                    return
                }
                defer { freeaddrinfo(res) }
                var ips: [String] = []
                var cur = res
                while let info = cur {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                                   &buf, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: buf)
                        if !ips.contains(ip) { ips.append(ip) }
                    }
                    cur = info.pointee.ai_next
                }
                cont.resume(returning: ips)
            }
        }
    }

}

// MARK: - Errors

enum SignalingError: Error {
    case invalidUrl(String)
    case handshakeFailed(String)
    case remoteClosed
    case cancelled
}
