import Foundation
import Network
import os

private let signalingLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "Signaling")
/// Same subsystem/category as signalingLog, used only for `isEnabled(type:)` so the
/// outgoing-message serialization is skipped unless debug logging is on.
private let signalingOSLog = OSLog(subsystem: "com.owenselles.CloudNow2", category: "Signaling")

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
//  • Certificate validation is bypassed — GFN signaling endpoints use non-standard TLS configs.
//  • Old heartbeat/receive tasks are cancelled at connect() entry to prevent zombie writes.

final class GFNSignalingClient {
    private let signalingUrl: String
    private let sessionId: String
    private let serverIp: String
    private let resolution: String

    private var connection: NWConnection?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var ackCounter = 0
    private var localPeerId = 2
    private var remotePeerId = 1
    private let peerName: String
    private(set) var connectedHost: String = ""
    private(set) var resolvedIPs: [String] = []

    var onEvent: ((SignalingEvent) -> Void)?

    init(signalingUrl: String, sessionId: String, serverIp: String = "", resolution: String = "1920x1080") {
        self.signalingUrl = signalingUrl
        self.sessionId = sessionId
        self.serverIp = serverIp
        self.resolution = resolution
        peerName = "peer-\(Int.random(in: 0 ..< 10_000_000_000))"
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
            URLQueryItem(name: "peer_role", value: "1"),
            URLQueryItem(name: "pairing_id", value: sessionId),
        ]
        guard comps.url != nil else { throw SignalingError.invalidUrl(signalingUrl) }

        let useTLS = url.scheme == "wss" || url.scheme == "https"

        // Resolve all IPs for the signaling hostname upfront so we can try each one
        // directly. NWConnection's Happy Eyeballs cache locks subsequent retries onto the
        // same "preferred" address — explicit enumeration bypasses that.
        let resolvedIPs = await resolveIPs(hostname: host)
        self.resolvedIPs = resolvedIPs // expose for ICE injection
        // Append the hostname itself as a final fallback in case direct IP connections fail.
        let candidates: [String] = resolvedIPs.isEmpty ? [host] : (resolvedIPs + [host])
        signalingLog.debug("[Signaling] Resolved \(resolvedIPs.count, privacy: .public) IPs for '\(host, privacy: .private)': \(resolvedIPs.joined(separator: ", "), privacy: .private)")

        let boundedCandidates = Array(candidates.prefix(8))
        var winner: ConnectedCandidate?
        var lastError: Error?

        let firstWave = Array(boundedCandidates.prefix(2))
        if firstWave.count > 1 {
            do {
                winner = try await raceCandidates(
                    firstWave,
                    originalHost: host,
                    components: comps,
                    useTLS: useTLS,
                    totalCount: boundedCandidates.count
                )
            } catch {
                lastError = error
            }
        } else if let candidate = firstWave.first {
            do {
                winner = try await connectCandidate(
                    candidate,
                    originalHost: host,
                    components: comps,
                    useTLS: useTLS,
                    index: 0,
                    totalCount: boundedCandidates.count
                )
            } catch {
                lastError = error
            }
        }

        if winner == nil {
            for (offset, candidate) in boundedCandidates.dropFirst(firstWave.count).enumerated() {
                do {
                    winner = try await connectCandidate(
                        candidate,
                        originalHost: host,
                        components: comps,
                        useTLS: useTLS,
                        index: firstWave.count + offset,
                        totalCount: boundedCandidates.count
                    )
                    break
                } catch {
                    lastError = error
                }
            }
        }

        guard let winner else {
            throw lastError ?? SignalingError.handshakeFailed("No signaling endpoint connected")
        }
        connection = winner.connection
        connectedHost = winner.host

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
            "peer_msg": ["from": localPeerId, "to": remotePeerId, "msg": jsonString(payload)],
            "ackid": nextAckId(),
        ])
    }

    // MARK: Send ICE Candidate

    func sendICECandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        guard !isTCPIceCandidate(candidate) else {
            signalingLog.debug("[Signaling] Dropping local TCP ICE candidate")
            return
        }
        var payload: [String: Any] = ["candidate": candidate]
        if let sdpMid { payload["sdpMid"] = sdpMid }
        if let sdpMLineIndex { payload["sdpMLineIndex"] = sdpMLineIndex }
        sendJson([
            "peer_msg": ["from": localPeerId, "to": remotePeerId, "msg": jsonString(payload)],
            "ackid": nextAckId(),
        ])
    }

    // MARK: Request Keyframe

    func requestKeyframe(reason: String = "decoder_recovery", backlogFrames: Int = 0, attempt: Int = 1) {
        sendJson([
            "peer_msg": ["from": localPeerId, "to": remotePeerId, "msg": jsonString([
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
                "id": localPeerId,
                "name": peerName,
                "peerRole": 1,
                "resolution": resolution,
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
                    if let text = try await receiveTextMessage() {
                        handleMessage(text)
                    }
                } catch {
                    if !Task.isCancelled {
                        signalingLog.error("[Signaling] Receive error: \(error, privacy: .private)")
                        onEvent?(.disconnected(reason: error.localizedDescription))
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
            guard isComplete else { continue } // more chunks coming for this message

            switch messageOpcode {
            case .text:
                return String(data: buffer, encoding: .utf8)
            case .close:
                if buffer.count >= 2 {
                    let code = UInt16(buffer[0]) << 8 | UInt16(buffer[1])
                    let reason = buffer.count > 2
                        ? String(data: buffer.subdata(in: 2 ..< buffer.count), encoding: .utf8) ?? "<non-UTF8>"
                        : ""
                    signalingLog.warning("[Signaling] Server closed: code=\(code, privacy: .public) reason=\(reason.isEmpty ? "(none)" : reason, privacy: .public)")
                } else {
                    signalingLog.warning("[Signaling] Server closed: no close-frame data")
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
        if signalingOSLog.isEnabled(type: .debug), let str = String(data: data, encoding: .utf8) {
            signalingLog.debug("[Signaling] → \(str.prefix(300), privacy: .private)")
        }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "ws-text", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true,
                  completion: .contentProcessed { err in
                      if let err { signalingLog.warning("[Signaling] Send error: \(err, privacy: .private)") }
                  })
    }

    // MARK: Private — Message Handling

    private func handleMessage(_ text: String) {
        signalingLog.debug("[Signaling] ← \(text.prefix(300), privacy: .private)")
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let peerInfo = obj["peer_info"] as? [String: Any],
           let id = peerInfo["id"] as? Int
        {
            if peerInfo["name"] as? String == peerName {
                localPeerId = id
            } else if id != localPeerId {
                remotePeerId = id
            }
        }

        // ACK
        if let ackId = obj["ackid"] as? Int {
            let shouldAck = (obj["peer_info"] as? [String: Any])?["id"] as? Int != localPeerId
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
        if let from = peerMsg["from"] as? Int, from != localPeerId {
            remotePeerId = from
        }

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

    private func isTCPIceCandidate(_ candidate: String) -> Bool {
        candidate.lowercased().components(separatedBy: " ").contains("tcp")
    }

    private struct ConnectedCandidate {
        let host: String
        let connection: NWConnection
    }

    private func raceCandidates(
        _ candidates: [String],
        originalHost: String,
        components: URLComponents,
        useTLS: Bool,
        totalCount: Int
    ) async throws -> ConnectedCandidate {
        var lastError: Error?
        return try await withThrowingTaskGroup(of: ConnectedCandidate.self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    try await self.connectCandidate(
                        candidate,
                        originalHost: originalHost,
                        components: components,
                        useTLS: useTLS,
                        index: index,
                        totalCount: totalCount
                    )
                }
            }

            while !group.isEmpty {
                do {
                    if let winner = try await group.next() {
                        group.cancelAll()
                        return winner
                    }
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? SignalingError.handshakeFailed("Candidate race produced no winner")
        }
    }

    private func connectCandidate(
        _ candidateHost: String,
        originalHost: String,
        components: URLComponents,
        useTLS: Bool,
        index: Int,
        totalCount: Int
    ) async throws -> ConnectedCandidate {
        let tlsOpts = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tlsOpts.securityProtocolOptions, .TLSv12)
        if useTLS {
            sec_protocol_options_set_tls_server_name(tlsOpts.securityProtocolOptions, originalHost)
        }
        sec_protocol_options_set_verify_block(
            tlsOpts.securityProtocolOptions,
            { _, _, complete in complete(true) },
            .global(qos: .userInitiated)
        )

        let wsOpts = NWProtocolWebSocket.Options()
        wsOpts.autoReplyPing = true
        wsOpts.setSubprotocols(["x-nv-sessionid.\(sessionId)"])
        wsOpts.setAdditionalHeaders([
            ("Origin", "https://play.geforcenow.com"),
            ("User-Agent", NVIDIAAuth.userAgent),
        ])

        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.noDelay = true
        tcpOpts.connectionTimeout = 4
        let params = useTLS
            ? NWParameters(tls: tlsOpts, tcp: tcpOpts)
            : NWParameters(tls: nil, tcp: tcpOpts)
        params.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)

        var endpointComponents = components
        endpointComponents.host = candidateHost
        guard let candidateUrl = endpointComponents.url else {
            throw SignalingError.invalidUrl(signalingUrl)
        }
        signalingLog.debug("[Signaling] Trying candidate \(index + 1, privacy: .public)/\(totalCount, privacy: .public) → \(candidateUrl.absoluteString, privacy: .private)")

        let connection = NWConnection(to: .url(candidateUrl), using: params)
        // State callbacks must be serialized AND the continuation resumed at most once:
        // when the candidate race is decided, the losers' cancel can arrive while (or
        // right after) their own .ready fires — on a concurrent queue that double-resumed
        // the continuation and crashed.
        let hasResumed = OSAllocatedUnfairLock(initialState: false)
        @Sendable func resumeOnce(_ resume: () -> Void) {
            let isFirst = hasResumed.withLock { resumed in
                if resumed { return false }
                resumed = true
                return true
            }
            if isFirst { resume() }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        signalingLog.info("[Signaling] Connected (WebSocket ready) via \(candidateHost, privacy: .private)")
                        resumeOnce { continuation.resume() }
                    case let .failed(error):
                        connection.stateUpdateHandler = nil
                        signalingLog.warning("[Signaling] Connection failed (\(candidateHost, privacy: .private)): \(error, privacy: .private)")
                        resumeOnce { continuation.resume(throwing: error) }
                    case .cancelled:
                        connection.stateUpdateHandler = nil
                        resumeOnce { continuation.resume(throwing: SignalingError.cancelled) }
                    case let .waiting(error):
                        let description = "\(error)"
                        if description.contains("53") || description.contains("ECONNABORTED") {
                            connection.stateUpdateHandler = nil
                            connection.cancel()
                            resumeOnce { continuation.resume(throwing: error) }
                        }
                    default:
                        break
                    }
                }
                connection.start(queue: DispatchQueue(label: "com.cloudnow.signaling.connect"))
            }
            return ConnectedCandidate(host: candidateHost, connection: connection)
        } onCancel: {
            connection.cancel()
        }
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
                                   &buf, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST) == 0
                    {
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
