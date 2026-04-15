// NOTE: This file requires the WebRTC package to be added to the Xcode project via SPM:
//   https://github.com/livekit/webrtc-xcframework
//   Product: WebRTC
//

import AVFoundation
import Foundation
import LiveKitWebRTC
import Observation

// MARK: - Stream State

enum StreamState: Equatable {
    case idle
    case connecting
    case streaming
    case disconnected(reason: String)
    case failed(message: String)
}

// MARK: - Stream Statistics

struct StreamStats {
    var bitrateKbps: Int = 0
    var resolutionWidth: Int = 0
    var resolutionHeight: Int = 0
    var fps: Double = 0
    var rttMs: Double = 0
    var packetLossPercent: Double = 0
    var jitterMs: Double = 0
    var codec: String = ""
    var gpuType: String = ""
}

// MARK: - GFNStreamController

@Observable
@MainActor
final class GFNStreamController: NSObject {
    private(set) var state: StreamState = .idle
    private(set) var stats = StreamStats()
    private(set) var videoTrack: LKRTCVideoTrack?
    private(set) var pingHistory: [Double] = []
    private(set) var fpsHistory: [Double] = []
    private(set) var bitrateHistory: [Double] = []

    private var peerConnection: LKRTCPeerConnection?
    private var inputDataChannel: LKRTCDataChannel?
    private var signaling: GFNSignalingClient?
    private var inputSender: InputSender?
    private var statsTimer: Timer?
    private var protocolVersion = 2
    private var partialReliableThresholdMs = 300
    private var sessionInfo: SessionInfo?
    private var settings = StreamSettings()
    private var micAudioSource: LKRTCAudioSource?
    private var micAudioTrack: LKRTCAudioTrack?
    private var signalingComplete = false

    private static let factory: LKRTCPeerConnectionFactory = {
        LKRTCInitializeSSL()
        let encoderFactory = LKRTCDefaultVideoEncoderFactory()
        let decoderFactory = LKRTCDefaultVideoDecoderFactory()
        return LKRTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }()

    // MARK: Connect

    func connect(session: SessionInfo, settings: StreamSettings) async {
        // Block if already active; allow from idle, disconnected, or failed (retry case)
        switch state {
        case .connecting, .streaming: return
        default: break
        }
        state = .connecting
        sessionInfo = session
        self.settings = settings
        stats.gpuType = session.gpuType ?? ""

        setupSignaling(session: session)
        do {
            try await signaling?.connect()
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    // MARK: Fail (external error surfacing)

    func fail(with message: String) {
        state = .failed(message: message)
    }

    // MARK: Disconnect

    func disconnect() {
        statsTimer?.invalidate()
        inputSender?.stop()
        signaling?.disconnect()
        peerConnection?.close()
        peerConnection = nil
        inputDataChannel = nil
        videoTrack = nil
        micAudioTrack = nil
        micAudioSource = nil
        pingHistory = []
        fpsHistory = []
        bitrateHistory = []
        signalingComplete = false
        state = .idle
    }

    // MARK: Private — Signaling Setup

    private func setupSignaling(session: SessionInfo) {
        let client = GFNSignalingClient(
            signalingUrl: session.signalingUrl,
            sessionId: session.sessionId,
            serverIp: session.serverIp
        )
        client.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handleSignalingEvent(event) }
        }
        signaling = client
    }

    private func handleSignalingEvent(_ event: SignalingEvent) {
        switch event {
        case .connected:
            break
        case .offer(let sdp):
            Task { await handleOffer(sdp: sdp) }
        case .remoteICE(let candidate, let sdpMid, let sdpMLineIndex):
            addRemoteICE(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
        case .disconnected(let reason):
            // Always stop the signaling client — kills heartbeat and releases the connection.
            signaling?.disconnect()
            if signalingComplete {
                // Server closes the WebSocket after answer + ICE exchange — expected GFN behavior.
                // The media runs over WebRTC ICE/DTLS/SRTP; let ICE state drive the outcome.
                print("[Stream] Signaling closed after setup (expected): \(reason)")
            } else {
                state = .disconnected(reason: reason)
            }
        case .error(let msg):
            state = .failed(message: msg)
        case .log:
            break
        }
    }

    // MARK: Private — WebRTC Peer Connection

    private func handleOffer(sdp: String) async {
        guard let session = sessionInfo else { return }
        print("[Stream] Offer SDP (\(sdp.count) chars):")
        sdp.components(separatedBy: "\r\n").forEach { print("  \($0)") }

        let iceServers: [LKRTCIceServer] = session.iceServers.map {
            LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        let config = LKRTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require

        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = GFNStreamController.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            state = .failed(message: "Failed to create LKRTCPeerConnection")
            return
        }
        peerConnection = pc
        print("[Stream] Peer connection created, starting offer handling")

        // Open input data channel (reliable + ordered)
        let dcConfig = LKRTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        dcConfig.isNegotiated = false
        if let dc = pc.dataChannel(forLabel: "input", configuration: dcConfig) {
            inputDataChannel = dc
            dc.delegate = self
        }

        // Attach microphone audio track if enabled (must happen before answer creation
        // so the m=audio sendrecv line is included in the SDP)
        if settings.micEnabled {
            await attachMicrophone(to: pc)
        }

        // Extract partial-reliable threshold from offer if the server advertises one
        if let match = sdp.range(of: #"ri\.partialReliableThresholdMs[: ]+(\d+)"#, options: .regularExpression),
           let numMatch = sdp[match].range(of: #"\d+"#, options: .regularExpression),
           let ms = Int(sdp[numMatch]) {
            partialReliableThresholdMs = ms
        }

        // AV1 uses protocol v3 (partially-reliable gamepad wrapping with sequence numbers)
        if settings.codec == .av1 {
            protocolVersion = 3
        }

        // Fix c= placeholder IPs with the real server IP. Do NOT filter codecs here —
        // SDPMunger.preferCodec is applied to the ANSWER instead (below), because munging
        // the offer leaves orphaned a=ssrc-group:FEC-FR lines that cause WebRTC to reject
        // the video m-line (port 0) when generating the answer.
        let serverMediaIp = session.mediaConnectionInfo.flatMap { Self.extractIpFromHost($0.ip) }
            ?? Self.extractIpFromHost(signaling?.connectedHost ?? "")
        let fixedSdp = serverMediaIp.map { ip in
            sdp.replacingOccurrences(of: "c=IN IP4 0.0.0.0", with: "c=IN IP4 \(ip)")
        } ?? sdp
        if let ip = serverMediaIp {
            print("[Stream] Fixed c= lines in offer SDP: 0.0.0.0 → \(ip)")
        } else {
            print("[Stream] Warning: no server IP available — offer c= lines left as 0.0.0.0")
        }
        let remoteSDP = LKRTCSessionDescription(type: .offer, sdp: fixedSdp)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                pc.setRemoteDescription(remoteSDP) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        } catch {
            print("[Stream] setRemoteDescription failed: \(error)")
        }

        // Create answer
        let answerConstraints = LKRTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveVideo": "true", "OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        do {
            let answer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { cont in
                pc.answer(for: answerConstraints) { sdp, error in
                    if let e = error { cont.resume(throwing: e); return }
                    if let sdp { cont.resume(returning: sdp) } else { cont.resume(throwing: StreamError.noSDP) }
                }
            }
            // Apply codec preference to the answer (not the offer) — avoids the
            // orphaned FEC-FR SSRC issue that caused video port 0 when munging the offer.
            let codecFilteredSdp = SDPMunger.preferCodec(answer.sdp, codec: settings.codec)
            let mangledAnswerSdp = SDPMunger.injectBandwidth(codecFilteredSdp, videoKbps: settings.maxBitrateKbps)
            print("[Stream] Answer SDP (\(mangledAnswerSdp.count) chars):")
            mangledAnswerSdp.components(separatedBy: "\r\n").forEach { print("  \($0)") }

            // Set local description
            let localSDP = LKRTCSessionDescription(type: .answer, sdp: mangledAnswerSdp)
            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    pc.setLocalDescription(localSDP) { error in
                        if let error { cont.resume(throwing: error) } else { cont.resume() }
                    }
                }
            } catch {
                print("[Stream] setLocalDescription failed: \(error)")
            }
            signaling?.sendAnswer(sdp: mangledAnswerSdp, nvstSdp: buildNvstSdp())
            signalingComplete = true

            // Inject the server's ICE host candidate AFTER sending the answer (matching OpenNOW timing).
            // GFN offers have no a=candidate: lines — the server relies on the client to probe it.
            // Primary source: mediaConnectionInfo (usage=2, or usage=14 highest-port fallback).
            // Fallback: all DNS-resolved IPs for the signaling hostname + SDP m-line port.
            let mciIp = session.mediaConnectionInfo.flatMap { Self.extractIpFromHost($0.ip) }
            let mciPort = session.mediaConnectionInfo?.port ?? 0

            let sdpPort = sdp.components(separatedBy: "\r\n").compactMap { line -> Int? in
                guard line.hasPrefix("m=") else { return nil }
                let p = line.components(separatedBy: " ")
                guard p.count >= 2, let port = Int(p[1]), port > 9 else { return nil }
                return port
            }.first ?? 0

            if let ip = mciIp, mciPort > 0 {
                // Primary: mediaConnectionInfo (dedicated media server IP/port)
                print("[ICE] Injecting server candidate (mediaConnectionInfo): \(ip):\(mciPort)")
                let cand = LKRTCIceCandidate(
                    sdp: "candidate:1 1 UDP 2130706431 \(ip) \(mciPort) typ host",
                    sdpMLineIndex: 0, sdpMid: "0")
                try? await pc.add(cand)
            } else if sdpPort > 0 {
                // Fallback: all DNS-resolved IPs at the SDP m-line port
                let resolvedIps = signaling?.resolvedIPs ?? []
                let connectedHost = signaling?.connectedHost ?? ""
                var allIps = resolvedIps.isEmpty
                    ? (connectedHost.isEmpty ? [] : [connectedHost])
                    : resolvedIps
                if !connectedHost.isEmpty, !allIps.contains(connectedHost) {
                    allIps.append(connectedHost)
                }
                if allIps.isEmpty {
                    print("[ICE] No server IPs available — ICE candidate injection skipped")
                } else {
                    print("[ICE] Injecting server candidates for \(allIps.count) IP(s) port=\(sdpPort) (signalingPool+sdpPort)")
                    for (i, ip) in allIps.enumerated() {
                        let cand = LKRTCIceCandidate(
                            sdp: "candidate:\(i + 1) 1 UDP 2130706431 \(ip) \(sdpPort) typ host",
                            sdpMLineIndex: 0, sdpMid: "0")
                        try? await pc.add(cand)
                        print("[ICE]   → \(ip):\(sdpPort)")
                    }
                }
            } else {
                print("[ICE] No server IP or SDP port available — ICE candidate injection skipped")
            }
        } catch {
            state = .failed(message: "Answer creation failed: \(error.localizedDescription)")
        }
    }

    // MARK: Private — NVST SDP

    /// Builds the NVIDIA streaming protocol capability descriptor sent alongside the WebRTC answer.
    /// Informs the server about audio/mic support and input data channel reliability settings.
    private func buildNvstSdp() -> String {
        var lines = [
            "m=audio 0 RTP/AVP",
            "a=msid:audio",
        ]
        if settings.micEnabled {
            lines += [
                "m=mic 0 RTP/AVP",
                "a=msid:mic",
                "a=rtpmap:0 PCMU/8000",
            ]
        }
        lines += [
            "m=application 0 RTP/AVP",
            "a=msid:input_1",
            "a=ri.partialReliableThresholdMs: \(partialReliableThresholdMs)",
            "a=ri.hidDeviceMask: 0",
            "a=ri.enablePartiallyReliableTransferGamepad: 65535",
            "a=ri.enablePartiallyReliableTransferHid: 0",
        ]
        return lines.joined(separator: "\r\n")
    }

    // MARK: Private — Microphone

    private func attachMicrophone(to pc: LKRTCPeerConnection) async {
        #if os(tvOS)
        let granted = true
        #else
        let granted = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
        #endif
        guard granted else { return }

        let audioConstraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: [
                "googEchoCancellation": "false",
                "googAutoGainControl": "false",
                "googNoiseSuppression": "false",
            ]
        )
        let source = GFNStreamController.factory.audioSource(with: audioConstraints)
        let track = GFNStreamController.factory.audioTrack(with: source, trackId: "mic")
        micAudioSource = source
        micAudioTrack = track
        pc.add(track, streamIds: ["mic"])
    }

    /// Extracts a dotted-decimal IP from a hostname that encodes it as dashes,
    /// e.g. "10-1-2-3.zone.nvidiagrid.net" → "10.1.2.3".
    /// Returns nil if the host is already a plain IP or doesn't match the pattern.
    private static func extractIpFromHost(_ host: String) -> String? {
        // Already a plain dotted-decimal IP (e.g. "80.250.97.40")
        let dotParts = host.components(separatedBy: ".")
        if dotParts.count == 4, dotParts.allSatisfy({ Int($0) != nil }) {
            return host
        }
        // Dash-encoded IP in hostname (e.g. "80-250-97-40.cloudmatchbeta.nvidiagrid.net")
        let label = dotParts.first ?? host
        let dashParts = label.components(separatedBy: "-")
        guard dashParts.count == 4, dashParts.allSatisfy({ Int($0) != nil }) else { return nil }
        return dashParts.joined(separator: ".")
    }

    private func addRemoteICE(candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        print("[ICE] Adding remote candidate: \(candidate) mid=\(sdpMid ?? "nil") mLineIndex=\(sdpMLineIndex ?? -1)")
        let ice = LKRTCIceCandidate(
            sdp: candidate,
            sdpMLineIndex: Int32(sdpMLineIndex ?? 0),
            sdpMid: sdpMid
        )
        peerConnection?.add(ice)
    }

    // MARK: Private — Stats

    private func startStatsTimer() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.collectStats()
        }
    }

    private func collectStats() {
        peerConnection?.statistics { [weak self] report in
            Task { @MainActor [weak self] in self?.parseStats(report) }
        }
    }

    private func parseStats(_ report: LKRTCStatisticsReport) {
        for (_, stat) in report.statistics {
            if stat.type == "inbound-rtp", stat.values["kind"] as? String == "video" {
                let bitsPerSecond = stat.values["bytesReceived"] as? Double ?? 0
                stats.bitrateKbps = Int(bitsPerSecond * 8 / 1000)
                stats.fps = stat.values["framesPerSecond"] as? Double ?? 0
                if let w = stat.values["frameWidth"] as? Double,
                   let h = stat.values["frameHeight"] as? Double {
                    stats.resolutionWidth  = Int(w)
                    stats.resolutionHeight = Int(h)
                }
                stats.codec = stat.values["codecId"] as? String ?? ""
                stats.jitterMs = (stat.values["jitter"] as? Double ?? 0) * 1000
                let lost = stat.values["packetsLost"] as? Double ?? 0
                let received = stat.values["packetsReceived"] as? Double ?? 0
                if lost + received > 0 {
                    stats.packetLossPercent = lost / (lost + received) * 100
                }
            }
            if stat.type == "candidate-pair", stat.values["state"] as? String == "succeeded" {
                stats.rttMs = (stat.values["currentRoundTripTime"] as? Double ?? 0) * 1000
            }
        }
        appendHistory(&pingHistory, value: stats.rttMs)
        appendHistory(&fpsHistory, value: stats.fps)
        appendHistory(&bitrateHistory, value: Double(stats.bitrateKbps) / 1000.0)
    }

    private func appendHistory(_ history: inout [Double], value: Double) {
        if history.count >= 30 { history.removeFirst() }
        history.append(value)
    }
}

// MARK: - LKRTCPeerConnectionDelegate

extension GFNStreamController: LKRTCPeerConnectionDelegate {
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {
        print("[Stream] Signaling state → \(stateChanged.rawValue)")
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        let name: String
        switch newState {
        case .new:          name = "new"
        case .checking:     name = "checking"
        case .connected:    name = "connected"
        case .completed:    name = "completed"
        case .failed:       name = "failed"
        case .disconnected: name = "disconnected"
        case .closed:       name = "closed"
        @unknown default:   name = "unknown(\(newState.rawValue))"
        }
        print("[ICE] State → \(name)")
        Task { @MainActor [weak self] in
            switch newState {
            case .connected, .completed:
                self?.state = .streaming
                self?.startStatsTimer()
            case .disconnected:
                self?.state = .disconnected(reason: "ICE disconnected")
            case .failed:
                self?.state = .failed(message: "ICE connection failed")
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        let name: String
        switch newState {
        case .new:       name = "new"
        case .gathering: name = "gathering"
        case .complete:  name = "complete"
        @unknown default: name = "unknown(\(newState.rawValue))"
        }
        print("[ICE] Gathering → \(name)")
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        Task { @MainActor [weak self] in
            self?.signaling?.sendICECandidate(
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: Int(candidate.sdpMLineIndex)
            )
        }
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection,
                                    didAdd rtpReceiver: LKRTCRtpReceiver,
                                    streams mediaStreams: [LKRTCMediaStream]) {
        print("[Stream] Received RTP receiver: kind=\(rtpReceiver.track?.kind ?? "nil")")
        guard let track = rtpReceiver.track as? LKRTCVideoTrack else { return }
        print("[Stream] Got video track")
        Task { @MainActor [weak self] in
            self?.videoTrack = track
        }
    }
}

// MARK: - LKRTCDataChannelDelegate

extension GFNStreamController: LKRTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        if dataChannel.readyState == .open {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let sender = InputSender(channel: self)
                sender.setProtocolVersion(self.protocolVersion)
                sender.start()
                self.inputSender = sender
            }
        }
    }

    nonisolated func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        // Parse any incoming protocol version negotiation if present
        if buffer.data.count >= 2 {
            let byte0 = buffer.data[0]
            let byte1 = buffer.data[1]
            if byte0 == 0x01 { // hypothetical version negotiation byte
                Task { @MainActor [weak self] in
                    self?.protocolVersion = Int(byte1)
                    self?.inputSender?.setProtocolVersion(Int(byte1))
                }
            }
        }
    }
}

// MARK: - DataChannelSender conformance

extension GFNStreamController: DataChannelSender {
    nonisolated func sendData(_ data: Data) {
        // Access inputDataChannel on the main actor asynchronously to satisfy isolation
        Task { @MainActor [weak self] in
            guard let dc = self?.inputDataChannel, dc.readyState == .open else { return }
            let buffer = LKRTCDataBuffer(data: data, isBinary: true)
            dc.sendData(buffer)
        }
    }
}

// MARK: - Errors

enum StreamError: Error {
    case noSDP
}
