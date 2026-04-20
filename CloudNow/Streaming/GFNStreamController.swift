// NOTE: This file requires the WebRTC package to be added to the Xcode project via SPM:
//   https://github.com/livekit/webrtc-xcframework
//   Product: WebRTC
//

import AVFoundation
import Foundation
import LiveKitWebRTC
import Observation

// MARK: - Session Time Warning

/// Severity levels for GFN session time-limit notifications from the control channel.
struct StreamTimeWarning: Equatable {
    /// 1 = approaching limit, 2 = 5 minutes left, 3 = last warning (imminent kick)
    var code: Int
    /// Seconds remaining as reported by the server, if available.
    var secondsLeft: Int?
}

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
    /// Active time-limit warning from the GFN server (nil when no warning is in effect).
    private(set) var timeWarning: StreamTimeWarning?
    /// Incremented each time the user presses Menu while VideoSurfaceView is first responder.
    /// SwiftUI observes this via .onChange to toggle the HUD overlay.
    private(set) var menuPressCount: Int = 0

    private var peerConnection: LKRTCPeerConnection?
    private var inputDataChannel: LKRTCDataChannel?
    private var signaling: GFNSignalingClient?
    private var inputSender: InputSender?
    private(set) var videoView: VideoSurfaceView?
    private(set) var remoteMode: RemoteInputMode = .mouse
    private var statsTimer: Timer?
    private var protocolVersion = 2
    private var partialReliableThresholdMs = 300
    private var sessionInfo: SessionInfo?
    private var settings = StreamSettings()
    private var micAudioSource: LKRTCAudioSource?
    private var micAudioTrack: LKRTCAudioTrack?
    private var signalingComplete = false
    private var partiallyReliableDataChannel: LKRTCDataChannel?
    private var controlChannel: LKRTCDataChannel?
    private var inputReady = false
    private var lastBytesReceived: Double = 0
    private var lastStatsTime: Date = .distantPast

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

    // MARK: Video View Binding

    /// Called by VideoSurfaceViewRepresentable once the UIView is created.
    /// Stores a reference so the inputHandler can be wired up when InputSender starts.
    func bindVideoView(_ view: VideoSurfaceView) {
        videoView = view
        view.inputHandler = inputSender
        view.menuPressHandler = { [weak self] in self?.handleMenuPress() }
    }

    /// Invoked by VideoSurfaceView when the user presses Menu.
    /// Incrementing the counter lets SwiftUI's .onChange react without depending
    /// on the tvOS focus engine (which is suppressed when UIKit holds first responder).
    func handleMenuPress() {
        menuPressCount += 1
    }

    // MARK: Input Control

    func toggleRemoteMode() {
        inputSender?.toggleRemoteMode()
        remoteMode = inputSender?.remoteMode ?? .mouse
        videoView?.gamepadModeActive = (remoteMode == .gamepad)
    }

    func setInputPaused(_ paused: Bool) {
        inputSender?.isPaused = paused
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
        partiallyReliableDataChannel = nil
        controlChannel = nil
        videoTrack = nil
        micAudioTrack = nil
        micAudioSource = nil
        pingHistory = []
        fpsHistory = []
        bitrateHistory = []
        signalingComplete = false
        inputReady = false
        lastBytesReceived = 0
        lastStatsTime = .distantPast
        videoView?.inputHandler = nil
        videoView?.menuPressHandler = nil
        videoView = nil
        remoteMode = .mouse
        menuPressCount = 0
        timeWarning = nil
        state = .idle
    }

    // MARK: Private — Signaling Setup

    private func setupSignaling(session: SessionInfo) {
        let client = GFNSignalingClient(
            signalingUrl: session.signalingUrl,
            sessionId: session.sessionId,
            serverIp: session.serverIp,
            resolution: settings.resolution
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

        // Configure audio session for real-time streaming before creating the peer connection.
        // .playback + .moviePlayback gives the lowest latency path; allowBluetooth covers
        // Bluetooth headsets paired to Apple TV.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.allowBluetooth, .allowBluetoothA2DP]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[Stream] AVAudioSession configuration failed (non-fatal): \(error)")
        }

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

        // Reliable ordered input channel — label must match the GFN server's expected "input_channel_v1"
        let dcConfig = LKRTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        dcConfig.isNegotiated = false
        if let dc = pc.dataChannel(forLabel: "input_channel_v1", configuration: dcConfig) {
            inputDataChannel = dc
            dc.delegate = self
        }

        // Partially-reliable gamepad channel — server expects this alongside the reliable one
        let prConfig = LKRTCDataChannelConfiguration()
        prConfig.isOrdered = false
        prConfig.maxPacketLifeTime = Int32(partialReliableThresholdMs)
        prConfig.isNegotiated = false
        if let dc = pc.dataChannel(forLabel: "input_channel_partially_reliable", configuration: prConfig) {
            partiallyReliableDataChannel = dc
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
            sdp
                .replacingOccurrences(of: "c=IN IP4 0.0.0.0", with: "c=IN IP4 \(ip)")
                .replacingOccurrences(of: "c=IN IP4 127.0.0.1", with: "c=IN IP4 \(ip)")
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
            // For H.265: rewrite tier-flag=1→0 and cap level-id to hardware-safe values.
            // Apple's decoder may reject High-tier or above-spec level-id advertisements.
            let h265SafeSdp = settings.codec == .h265
                ? SDPMunger.rewriteH265LevelId(SDPMunger.rewriteH265TierFlag(codecFilteredSdp))
                : codecFilteredSdp
            let mangledAnswerSdp = SDPMunger.injectBandwidth(h265SafeSdp, videoKbps: settings.maxBitrateKbps)
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
            let (iceUfrag, icePwd, dtlsFingerprint) = Self.extractIceCredentials(from: mangledAnswerSdp)
            signaling?.sendAnswer(sdp: mangledAnswerSdp, nvstSdp: buildNvstSdp(iceUfrag: iceUfrag, icePwd: icePwd, dtlsFingerprint: dtlsFingerprint))
            signalingComplete = true

            // Inject the server's ICE host candidate AFTER sending the answer.
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

            // Saturate ICE with every plausible server endpoint.
            // We don't know which port carries UDP media (usage=2 is absent for this zone),
            // so we inject candidates for ALL combinations of known IPs × known ports.
            // ICE probes them all simultaneously and succeeds on the first STUN reply.
            let resolvedIps = signaling?.resolvedIPs ?? []
            let connectedHost = signaling?.connectedHost ?? ""
            var allIps: [String] = []
            if let ip = mciIp { allIps.append(ip) }
            for ip in resolvedIps where !allIps.contains(ip) { allIps.append(ip) }
            if !connectedHost.isEmpty, !allIps.contains(connectedHost) { allIps.append(connectedHost) }

            let allPorts = ([mciPort, sdpPort]).filter { $0 > 0 }
            let pairs = allIps.flatMap { ip in allPorts.map { (ip, $0) } }

            if pairs.isEmpty {
                print("[ICE] No server IPs or ports available — ICE candidate injection skipped")
            } else {
                print("[ICE] Injecting \(pairs.count) candidate(s) (mciIp=\(mciIp ?? "nil") mciPort=\(mciPort) sdpPort=\(sdpPort))")
                for (i, (ip, port)) in pairs.enumerated() {
                    let cand = LKRTCIceCandidate(
                        sdp: "candidate:\(i + 1) 1 UDP 2130706431 \(ip) \(port) typ host",
                        sdpMLineIndex: 0, sdpMid: "0")
                    try? await pc.add(cand)
                    print("[ICE]   → \(ip):\(port)")
                }
            }
        } catch {
            state = .failed(message: "Answer creation failed: \(error.localizedDescription)")
        }
    }

    // MARK: Private — NVST SDP

    /// Extracts the client's ICE ufrag, ICE password, and DTLS fingerprint from an SDP string.
    /// The GFN server reads these from the NVST SDP (not the WebRTC SDP) to validate STUN probes.
    private static func extractIceCredentials(from sdp: String) -> (ufrag: String, pwd: String, fingerprint: String) {
        let lines = sdp.components(separatedBy: CharacterSet.newlines)
        let ufrag = lines.first { $0.hasPrefix("a=ice-ufrag:") }
            .map { String($0.dropFirst("a=ice-ufrag:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
        let pwd = lines.first { $0.hasPrefix("a=ice-pwd:") }
            .map { String($0.dropFirst("a=ice-pwd:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
        let fingerprint = lines.first { $0.hasPrefix("a=fingerprint:sha-256 ") }
            .map { String($0.dropFirst("a=fingerprint:sha-256 ".count)).trimmingCharacters(in: .whitespaces) } ?? ""
        return (ufrag, pwd, fingerprint)
    }

    /// Builds the NVIDIA streaming protocol capability descriptor sent alongside the WebRTC answer.
    /// Builds the NVST SDP capability descriptor — critically includes the client's ICE credentials so the
    /// GFN server can validate STUN MESSAGE-INTEGRITY on incoming binding requests.
    private func buildNvstSdp(iceUfrag: String, icePwd: String, dtlsFingerprint: String) -> String {
        let resolutionParts = settings.resolution.split(separator: "x")
        let width  = Int(resolutionParts.first ?? "1920") ?? 1920
        let height = Int(resolutionParts.last  ?? "1080") ?? 1080
        let minBitrateKbps     = max(5000, settings.maxBitrateKbps * 35 / 100)
        let initialBitrateKbps = max(minBitrateKbps, settings.maxBitrateKbps * 70 / 100)

        var lines: [String] = [
            "v=0",
            "o=SdpTest test_id_13 14 IN IPv4 127.0.0.1",
            "s=-",
            "t=0 0",
            // Client ICE credentials — GFN server uses these (not the WebRTC SDP) to validate STUN
            "a=general.icePassword:\(icePwd)",
            "a=general.iceUserNameFragment:\(iceUfrag)",
            "a=general.dtlsFingerprint:\(dtlsFingerprint)",
            // Video section with quality/bitrate hints for the server encoder
            "m=video 0 RTP/AVP",
            "a=msid:fbc-video-0",
            "a=vqos.fec.rateDropWindow:10",
            "a=vqos.fec.repairPercent:5",
            "a=vqos.drc.enable:0",
            "a=vqos.dfc.enable:0",
            "a=video.enableRtpNack:1",
            "a=video.packetSize:1140",
            "a=bwe.useOwdCongestionControl:1",
            "a=vqos.resControl.cpmRtc.enable:0",
            "a=vqos.resControl.cpmRtc.minResolutionPercent:100",
            "a=video.clientViewportWd:\(width)",
            "a=video.clientViewportHt:\(height)",
            "a=video.maxFPS:\(settings.fps)",
            "a=video.initialBitrateKbps:\(initialBitrateKbps)",
            "a=video.initialPeakBitrateKbps:\(settings.maxBitrateKbps)",
            "a=vqos.bw.maximumBitrateKbps:\(settings.maxBitrateKbps)",
            "a=vqos.bw.minimumBitrateKbps:\(minBitrateKbps)",
            "a=vqos.bw.peakBitrateKbps:\(settings.maxBitrateKbps)",
            "a=video.bitDepth:\(settings.colorQuality.bitDepth)",
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
            "a=ri.partialReliableThresholdMs:\(partialReliableThresholdMs)",
            "a=ri.hidDeviceMask:0",
            "a=ri.enablePartiallyReliableTransferGamepad:\(protocolVersion == 3 ? 65535 : 0)",
            "a=ri.enablePartiallyReliableTransferHid:0",
            "",
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
        // Build codec name lookup: stat ID → human-readable name (e.g. "H.265", "AV1")
        var codecNames: [String: String] = [:]
        for (id, stat) in report.statistics where stat.type == "codec" {
            if let mime = stat.values["mimeType"] as? String {
                let raw = mime.components(separatedBy: "/").last ?? mime
                switch raw.uppercased() {
                case "H264":         codecNames[id] = "H.264"
                case "H265", "HEVC": codecNames[id] = "H.265"
                case "AV01", "AV1":  codecNames[id] = "AV1"
                default:             codecNames[id] = raw
                }
            }
        }

        for (_, stat) in report.statistics {
            if stat.type == "inbound-rtp", stat.values["kind"] as? String == "video" {
                let bytesReceived = stat.values["bytesReceived"] as? Double ?? 0
                let framesReceived = stat.values["framesReceived"] as? Double ?? 0
                let framesDecoded  = stat.values["framesDecoded"]  as? Double ?? 0
                let now = Date()
                let elapsed = now.timeIntervalSince(lastStatsTime)
                if elapsed > 0 && lastBytesReceived > 0 {
                    let deltaBytes = bytesReceived - lastBytesReceived
                    stats.bitrateKbps = Int(max(0, deltaBytes) * 8 / elapsed / 1000)
                }
                lastBytesReceived = bytesReceived
                lastStatsTime = now

                stats.fps = stat.values["framesPerSecond"] as? Double ?? 0
                if let w = stat.values["frameWidth"] as? Double,
                   let h = stat.values["frameHeight"] as? Double {
                    stats.resolutionWidth  = Int(w)
                    stats.resolutionHeight = Int(h)
                }
                // Resolve the codec name from the codecId reference (e.g. "RTCCodec_V_Inbound_127" → "H.265")
                let codecId = stat.values["codecId"] as? String ?? ""
                stats.codec = codecNames[codecId] ?? codecId
                stats.jitterMs = (stat.values["jitter"] as? Double ?? 0) * 1000
                let lost = stat.values["packetsLost"] as? Double ?? 0
                let received = stat.values["packetsReceived"] as? Double ?? 0
                if lost + received > 0 {
                    stats.packetLossPercent = lost / (lost + received) * 100
                }
                print("[Stats] framesReceived=\(Int(framesReceived)) framesDecoded=\(Int(framesDecoded)) fps=\(stats.fps) res=\(stats.resolutionWidth)×\(stats.resolutionHeight) bitrateKbps=\(stats.bitrateKbps) codec=\(stats.codec)")
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
                self?.statsTimer?.invalidate()
                self?.statsTimer = nil
                self?.state = .disconnected(reason: "ICE disconnected")
            case .failed:
                self?.statsTimer?.invalidate()
                self?.statsTimer = nil
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

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        print("[DataChannel] Server opened channel: label=\(dataChannel.label)")
        if dataChannel.label == "control_channel" {
            dataChannel.delegate = self
            Task { @MainActor [weak self] in
                self?.controlChannel = dataChannel
            }
        }
    }

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
        print("[DataChannel] State → \(dataChannel.readyState.rawValue) label=\(dataChannel.label)")
        // InputSender is NOT started here — it starts only after the server sends its
        // handshake message on input_channel_v1 (handled in dataChannel(_:didReceiveMessageWith:))
    }

    nonisolated func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        // Handle control channel messages (timerNotification etc.)
        if dataChannel.label == "control_channel" {
            let text = String(data: buffer.data, encoding: .utf8) ?? "<binary \(buffer.data.count)B>"
            print("[ControlChannel] Message: \(text)")

            // Parse timerNotification — maps server codes to severity levels (matches OpenNOW)
            if let json = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any],
               let notification = json["timerNotification"] as? [String: Any],
               let rawCode = notification["code"] as? Int {
                let mappedCode: Int?
                switch rawCode {
                case 1, 2: mappedCode = 1  // approaching limit
                case 4:    mappedCode = 2  // ~5 minutes left
                case 6:    mappedCode = 3  // last warning, kick imminent
                default:   mappedCode = nil
                }
                if let code = mappedCode {
                    let secondsLeft = notification["secondsLeft"] as? Int
                    Task { @MainActor [weak self] in
                        self?.timeWarning = StreamTimeWarning(code: code, secondsLeft: secondsLeft)
                    }
                }
            }
            return
        }

        // Parse protocol version from the server's first handshake message on the input channel.
        // firstWord==526 (0x020e) → version in bytes[2:3]; bytes[0]==0x0e → version==firstWord.
        // Do NOT echo the handshake back — official GFN client doesn't.
        let bytes = buffer.data
        guard bytes.count >= 2 else { return }

        let firstWord = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        var version = 2

        if firstWord == 526 {
            version = bytes.count >= 4 ? Int(UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)) : 2
            print("[DataChannel] Handshake: firstWord=526 (0x020e), version=\(version)")
        } else if bytes[0] == 0x0e {
            version = Int(firstWord)
            print("[DataChannel] Handshake: byte[0]=0x0e, version=\(version)")
        } else {
            print("[DataChannel] Non-handshake message on \(dataChannel.label): firstWord=\(firstWord) (0x\(String(firstWord, radix: 16)))")
            return
        }

        Task { @MainActor [weak self] in
            guard let self, !self.inputReady else { return }
            self.inputReady = true
            self.protocolVersion = version
            print("[DataChannel] Input ready — starting InputSender (protocol v\(version))")
            let sender = InputSender(channel: self)
            sender.setProtocolVersion(version)
            sender.deadzone = Float(self.settings.controllerDeadzone)
            sender.menuToggleHandler = { [weak self] in self?.handleMenuPress() }
            sender.onRemoteModeChanged = { [weak self] mode in
                self?.remoteMode = mode
                self?.videoView?.gamepadModeActive = (mode == .gamepad)
            }
            sender.start()
            self.inputSender = sender
            // Forward keyboard/mouse events from the video surface to the sender
            self.videoView?.inputHandler = sender
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
