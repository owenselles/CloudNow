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
//  • NWEndpoint.url(_:) with ws:// (not wss://) passes path+query to the upgrade GET request
//    without triggering NWConnection's own TLS layer (we add TLS manually via NWParameters).
//  • No ALPN is set in TLS options — GFN's WebSocket server doesn't register any ALPN token.
//  • .legacy cipher suite group + min TLS 1.0 allows older/RSA-based cipher negotiation.
//  • Certificate validation is bypassed (mirrors OpenNOW rejectUnauthorized:false).
//  • Old heartbeat/receive tasks are cancelled at connect() entry to prevent zombie writes.

final class GFNSignalingClient {
    private let signalingUrl: String
    private let sessionId: String

    private var connection: NWConnection?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var ackCounter = 0
    private let peerId = 2
    private let peerName: String

    var onEvent: ((SignalingEvent) -> Void)?

    init(signalingUrl: String, sessionId: String) {
        self.signalingUrl = signalingUrl
        self.sessionId = sessionId
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
        guard let requestUrl = comps.url else { throw SignalingError.invalidUrl(signalingUrl) }

        let port = url.port ?? 443
        let useTLS = url.scheme == "wss" || url.scheme == "https"

        // TLS options — no ALPN, legacy cipher suites, cert bypass.
        let tlsOpts = NWProtocolTLS.Options()
        sec_protocol_options_append_tls_ciphersuite_group(tlsOpts.securityProtocolOptions, .legacy)
        sec_protocol_options_set_min_tls_protocol_version(tlsOpts.securityProtocolOptions, .TLSv10)
        sec_protocol_options_set_verify_block(tlsOpts.securityProtocolOptions,
                                              { _, _, complete in complete(true) },
                                              .global(qos: .userInitiated))

        // WebSocket options — system handles HTTP upgrade, framing, and ping/pong.
        let wsOpts = NWProtocolWebSocket.Options()
        wsOpts.autoReplyPing = true
        wsOpts.setAdditionalHeaders([
            ("Sec-WebSocket-Protocol", "x-nv-sessionid.\(sessionId)"),
            ("Origin", "https://play.geforcenow.com"),
            ("User-Agent", NVIDIAAuth.userAgent),
        ])

        // Stack: WebSocket → TLS → TCP
        let params: NWParameters
        if useTLS {
            params = NWParameters(tls: tlsOpts, tcp: NWProtocolTCP.Options())
        } else {
            params = NWParameters.tcp
        }
        params.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)

        // Use NWEndpoint.url so the path+query go into the WebSocket upgrade request.
        // Fall back to host:port endpoint if the URL can't be used (non-wss scheme etc.)
        let endpoint: NWEndpoint
        if let wsUrl = makeWebSocketURL(from: requestUrl) {
            endpoint = NWEndpoint.url(wsUrl)
        } else {
            endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: UInt16(port))!
            )
        }

        let conn = NWConnection(to: endpoint, using: params)
        connection = conn

        print("[Signaling] Connecting → \(requestUrl.absoluteString)")

        // .ready fires only after TLS handshake AND WebSocket HTTP upgrade both complete.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.stateUpdateHandler = nil
                    print("[Signaling] Connected (WebSocket ready)")
                    cont.resume()
                case .failed(let err):
                    conn.stateUpdateHandler = nil
                    print("[Signaling] Connection failed: \(err)")
                    cont.resume(throwing: err)
                case .cancelled:
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: SignalingError.cancelled)
                case .waiting(let err):
                    print("[Signaling] Waiting: \(err)")
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

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

    /// Reads one WebSocket message from the server. Returns the UTF-8 text payload for text
    /// frames, nil for control frames (ping is handled automatically by autoReplyPing).
    private func receiveTextMessage() async throws -> String? {
        guard let conn = connection else { throw SignalingError.cancelled }
        return try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { content, context, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                if isComplete {
                    cont.resume(throwing: SignalingError.remoteClosed)
                    return
                }
                let meta = context?.protocolMetadata(
                    definition: NWProtocolWebSocket.definition
                ) as? NWProtocolWebSocket.Metadata

                switch meta?.opcode {
                case .text:
                    let str = content.flatMap { String(data: $0, encoding: .utf8) }
                    cont.resume(returning: str)
                case .close:
                    cont.resume(throwing: SignalingError.remoteClosed)
                default:
                    // Binary, ping (handled by autoReplyPing), pong, continuation — skip.
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: Private — Send

    private func sendJson(_ obj: [String: Any]) {
        guard let conn = connection,
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "ws-text", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true,
                  completion: .contentProcessed { err in
            if let err { print("[Signaling] Send error: \(err)") }
        })
    }

    // MARK: Private — Message Handling

    private func handleMessage(_ text: String) {
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

    // MARK: Private — URL helpers

    /// NWEndpoint.url with a wss:// URL causes NWConnection to add its own TLS layer,
    /// which would conflict with our explicit NWParameters(tls:).  Use ws:// instead so
    /// NWConnection does not auto-add TLS; our params provide TLS with custom options.
    private func makeWebSocketURL(from url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if comps.scheme == "wss" { comps.scheme = "ws" }
        return comps.url
    }
}

// MARK: - Errors

enum SignalingError: Error {
    case invalidUrl(String)
    case handshakeFailed(String)
    case remoteClosed
    case cancelled
}
