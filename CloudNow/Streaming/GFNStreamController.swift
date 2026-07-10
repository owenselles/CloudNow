// NOTE: This file requires the WebRTC package to be added to the Xcode project via SPM:
//   https://github.com/livekit/webrtc-xcframework
//   Product: WebRTC
//

import AVFoundation
import Foundation
@preconcurrency import LiveKitWebRTC
import Observation
import os.log

private let gfnLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "GFNStream")
private let videoColorLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "VideoColor")
private let audioSyncLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "AudioSync")

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
    case reconnecting(attempt: Int)
    case disconnected(reason: String)
    case failed(message: String)
    case sessionEnded
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
    var jitterBufferDelayMs: Double = 0
    var jitterBufferTargetDelayMs: Double = 0
    var jitterBufferMinimumDelayMs: Double = 0
    var decodeTimeMs: Double = 0
    var processingDelayMs: Double = 0
    var framesDropped: Int = 0
    var freezeCount: Int = 0
    var freezeDurationMs: Double = 0
    var nackCount: Int = 0
    var pliCount: Int = 0
    var firCount: Int = 0
    var retransmittedPackets: Int = 0
    var decoderImplementation: String = ""
    var powerEfficientDecoder: Bool?
    var selectedCandidatePairId: String = ""
    var selectedProtocol: String = ""
    var localCandidateType: String = ""
    var remoteCandidateType: String = ""
    var localCandidateAddress: String = ""
    var remoteCandidateAddress: String = ""
    var availableIncomingBitrateKbps: Int = 0
    var candidatePairChanges: Int = 0
    var selectedNetworkPath: String = "unknown"
    /// Short GFN zone label the session runs in (e.g. "FRK-08"), derived from the
    /// CloudMatch routing zone URL to match the official client's display.
    var serverZone: String = ""
    var inputGenerated: UInt64 = 0
    var inputSubmitted: UInt64 = 0
    var inputAccepted: UInt64 = 0
    var inputDropped: UInt64 = 0
    var inputSuperseded: UInt64 = 0
    var inputBufferedBytes: UInt64 = 0
    var inputQueueP95Ms: Double = 0
    var inputQueueMaxMs: Double = 0
    var newestGamepadAgeMs: Double = 0
    var inputChannelState: String = "closed"
    /// Average FPS the game renders on the cloud rig, from the server's stats_channel
    /// messages (0 until the first message arrives). The official client shows this
    /// alongside the stream FPS.
    var gameFps: Double = 0
}

/// Audio metrics surfaced in the statistics HUD, refreshed once per stats tick.
/// NetEQ values are interval averages derived from AudioSyncStatsSnapshot pairs;
/// device/route fields are sampled from the live audio session.
struct AudioStats {
    var jitterBufferCurrentMs: Double = 0
    var jitterBufferTargetMs: Double = 0
    var devicePlayoutMs: Double = 0
    var packetsLost: Int = 0
    var jitterMs: Double = 0
    var concealedMsPerSecond: Double = 0
    var stretchedMsPerSecond: Double = 0
    var acceleratedMsPerSecond: Double = 0
    /// video − audio playout timestamp; positive = audio lags video. nil without RTCP SR.
    var avOffsetMs: Double?
    var outputLatencyMs: Double = 0
    var outputChannels: Int = 0
    var outputSampleRateHz: Double = 0
    var outputRouteName: String = ""
    var codecName: String = ""
    var codecChannels: Int = 0
}

private struct VideoStatsSnapshot {
    var timestampUs: Double = 0
    var bytesReceived: Double = 0
    var packetsReceived: Double = 0
    var packetsLost: Double = 0
    var framesDecoded: Double = 0
    var framesDropped: Double = 0
    var framesPerSecond: Double = 0
    var frameWidth: Double = 0
    var frameHeight: Double = 0
    var jitterSeconds: Double = 0
    var jitterBufferDelaySeconds: Double = 0
    var jitterBufferTargetDelaySeconds: Double = 0
    var jitterBufferMinimumDelaySeconds: Double = 0
    var jitterBufferEmittedCount: Double = 0
    var totalDecodeTimeSeconds: Double = 0
    var totalProcessingDelaySeconds: Double = 0
    var freezeCount: Double = 0
    var totalFreezeDurationSeconds: Double = 0
    var nackCount: Double = 0
    var pliCount: Double = 0
    var firCount: Double = 0
    var retransmittedPackets: Double = 0
    var codec: String = ""
    var decoderImplementation: String = ""
    var powerEfficientDecoder: Bool?
}

private struct ConnectionStatsSnapshot {
    var rttMs: Double
    var selectedNetworkPath: String
}

/// Audio-pipeline latency counters sampled from the full statistics report in diagnostic mode.
/// All values cumulative (interval-averaged at log time), mirroring VideoStatsSnapshot, to
/// pinpoint where the audio→video lag accumulates: NetEQ jitter buffer vs device playout.
private struct AudioSyncStatsSnapshot {
    var timestampUs: Double = 0
    var packetsReceived: Double = 0
    var packetsLost: Double = 0
    var jitterSeconds: Double = 0
    var jitterBufferDelaySeconds: Double = 0
    var jitterBufferTargetDelaySeconds: Double = 0
    var jitterBufferMinimumDelaySeconds: Double = 0
    var jitterBufferEmittedCount: Double = 0
    var concealedSamples: Double = 0
    var insertedSamplesForDeceleration: Double = 0
    var removedSamplesForAcceleration: Double = 0
    var totalPlayoutDelaySeconds: Double = 0
    var playoutSamplesCount: Double = 0
    /// estimatedPlayoutTimestamp of the audio/video inbound-rtp streams (sender clock domain).
    /// video − audio > 0 means audio is playing older media, i.e. audio lags video by that much.
    /// Requires RTCP SR from the server for the RTP→NTP mapping; nil when absent.
    var audioPlayoutTimestampMs: Double?
    var videoPlayoutTimestampMs: Double?
}

private let streamStatsParsingQueue = DispatchQueue(
    label: "com.cloudnow.stream-stats",
    qos: .utility
)

// MARK: - GFNStreamController

@Observable
@MainActor
final class GFNStreamController: NSObject {
    private(set) var state: StreamState = .idle
    private(set) var stats = StreamStats()
    private(set) var audioStats = AudioStats()
    private(set) var videoTrack: LKRTCVideoTrack?
    private(set) var statsMode: StreamStatsMode = .off
    private(set) var diagnosticsEnabled = false
    private(set) var videoDiagnostics = VideoPipelineSnapshot()
    /// Wall-clock start of the current stream, for the HUD's session duration row.
    private(set) var streamingStartedAt: Date?
    private(set) var colorState = StreamColorState(
        preference: .automatic,
        requestedMode: .sdr8,
        negotiatedMode: nil,
        detectedMode: nil,
        displayHDRSupport: .unknown,
        fallbackReason: nil
    )
    private(set) var diagnosticSessionSummary: String = ""
    private(set) var rtcEventLogURL: URL?
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
    @ObservationIgnored private nonisolated(unsafe) var reliableSendChannel: LKRTCDataChannel?
    @ObservationIgnored private nonisolated(unsafe) var rumbleSink: ((Int, UInt16, UInt16) -> Void)?
    @ObservationIgnored private nonisolated(unsafe) var inputGenerated: UInt64 = 0
    @ObservationIgnored private nonisolated(unsafe) var inputSubmitted: UInt64 = 0
    @ObservationIgnored private nonisolated(unsafe) var inputAccepted: UInt64 = 0
    @ObservationIgnored private nonisolated(unsafe) var inputDropped: UInt64 = 0
    @ObservationIgnored private nonisolated(unsafe) var inputSuperseded: UInt64 = 0
    @ObservationIgnored private nonisolated(unsafe) var inputBufferedBytes: UInt64 = 0
    @ObservationIgnored private nonisolated(unsafe) var inputQueueWaitsNs: [UInt64] = []
    @ObservationIgnored private nonisolated(unsafe) var inputQueueMaxNs: UInt64 = 0
    @ObservationIgnored private nonisolated(unsafe) var newestGamepadGeneratedAt: UInt64 = 0
    @ObservationIgnored private nonisolated(unsafe) var inputChannelState = "closed"
    @ObservationIgnored private nonisolated(unsafe) var pendingGamepadSnapshots: [
        Int: (packet: EncodedInputPacket, completion: (InputSendDisposition) -> Void)
    ] = [:]
    @ObservationIgnored private nonisolated(unsafe) let inputBackpressureHighWaterBytes: UInt64 = 512
    @ObservationIgnored private nonisolated(unsafe) let inputBackpressureLowWaterBytes: UInt64 = 128
    private let inputSendQueue = DispatchQueue(
        label: "com.cloudnow.input.send",
        qos: .userInteractive
    )
    private var signaling: GFNSignalingClient?
    private var inputSender: InputSender?
    private(set) var videoView: VideoSurfaceView?
    private(set) var remoteMode: RemoteInputMode = .mouse
    private var statsTimer: Timer?
    private var videoReceiver: LKRTCRtpReceiver?
    private var protocolVersion = 2
    private var partialReliableThresholdMs = 300
    private var sessionInfo: SessionInfo?
    private var settings = StreamSettings()
    /// Account HDR entitlement resolved from the subscription tier at connect time.
    private var accountAllowsHDR: Bool?
    private var micAudioSource: LKRTCAudioSource?
    private var micAudioTrack: LKRTCAudioTrack?
    private var signalingComplete = false
    private var partiallyReliableDataChannel: LKRTCDataChannel?
    private var statsChannel: LKRTCDataChannel?
    private var controlChannel: LKRTCDataChannel?
    private var inputReady = false
    private var previousVideoStats: VideoStatsSnapshot?
    private var previousAudioSyncStats: AudioSyncStatsSnapshot?
    private var statsTick = 0
    private var statsGeneration = 0
    private var videoStatsRequestInFlight = false
    private var connectionStatsRequestInFlight = false
    private var wasStreaming = false
    private var reconnectAttempt = 0
    private static let maxReconnectAttempts = 3
    /// Set when the server sends an `exitMessage` (game closed, session ended, kicked). The
    /// subsequent ICE disconnect is then treated as a normal end — not a reconnect candidate.
    private var serverStopped = false
    /// Set by the caller to enable auto-reconnect on ICE disconnect.
    var onReconnectNeeded: (() async -> SessionInfo?)?
    private var previousSelectedCandidatePairId = ""
    private var lastZoneRttFeedbackAt: Date?

    private static let factory: LKRTCPeerConnectionFactory = {
        LKRTCInitializeSSL()
        let encoderFactory = LKRTCDefaultVideoEncoderFactory()
        let decoderFactory = GFNVideoDecoderFactory()
        // Inject our own audio device (GFNAudioDevice): the built-in audio device module
        // plays MONO on Apple platforms and routes through the call-oriented voice
        // processing unit. The custom device renders true stereo — or 5.1 for multiopus
        // streams — through AVAudioEngine and owns the output render quantum (latency).
        return LKRTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory,
            audioDevice: GFNAudioDevice.shared
        )
    }()

    // MARK: Connect

    func connect(session: SessionInfo, settings: StreamSettings, accountAllowsHDR: Bool? = nil) async {
        // Block if already active; allow from idle, disconnected, or failed (retry case)
        let currentState = state
        switch currentState {
        case .connecting, .streaming:
            gfnLog.info("connect: already \(String(describing: currentState)), ignoring")
            return
        default: break
        }
        let settings = settings.normalizedForClient
        let localCapabilities = LocalVideoCapabilities.detect(codec: settings.codec)
        let colorRequest = settings.colorRequest(localCapabilities: localCapabilities, accountAllowsHDR: accountAllowsHDR)
        gfnLog.info("connect: starting, serverIp=\(session.serverIp), signalingUrl=\(session.signalingUrl)")
        videoColorLog.info("request preference=\(settings.colorPreference.rawValue) requested=\(colorRequest.mode.rawValue) bitDepth=\(colorRequest.bitDepth) hdr=\(colorRequest.hdrRequested) codec=\(settings.codec.rawValue) decoder10Bit=\(localCapabilities.supportsHardware10BitDecode) hdrPipeline=\(localCapabilities.supportsHDRRendering) displayHDR=\(localCapabilities.displaySupportsHDR)")
        state = .connecting
        serverStopped = false
        sessionInfo = session
        self.settings = settings
        self.accountAllowsHDR = accountAllowsHDR
        colorState = StreamColorState(
            preference: settings.colorPreference,
            requestedMode: colorRequest.mode,
            negotiatedMode: nil,
            detectedMode: nil,
            displayHDRSupport: localCapabilities.displaySupportsHDR ? .supported : .unsupported,
            fallbackReason: nil
        )
        diagnosticSessionSummary = L10n.diagnosticSessionSummary(
            sessionIdPrefix: String(session.sessionId.prefix(8)),
            serverIp: session.serverIp,
            resolution: settings.resolution,
            fps: settings.fps,
            codec: L10n.videoCodecLabel(settings.codec)
        )
        setStatsMode(settings.statsMode)
        setDiagnosticsEnabled(settings.diagnosticsEnabled)
        stats = StreamStats()
        stats.gpuType = session.gpuType ?? ""
        stats.serverZone = Self.zoneShortName(from: session.zone)
        audioStats = AudioStats()
        streamingStartedAt = nil
        inputSendQueue.sync {
            inputGenerated = 0
            inputSubmitted = 0
            inputAccepted = 0
            inputDropped = 0
            inputSuperseded = 0
            inputBufferedBytes = 0
            inputQueueWaitsNs.removeAll(keepingCapacity: true)
            inputQueueMaxNs = 0
            newestGamepadGeneratedAt = 0
            inputChannelState = "closed"
        }

        setupSignaling(session: session)
        do {
            gfnLog.info("connect: opening signaling WebSocket")
            try await signaling?.connect()
            gfnLog.info("connect: signaling connected")
        } catch {
            gfnLog.error("connect: signaling FAILED: \(error)")
            state = .failed(message: error.localizedDescription)
        }
    }

    // MARK: Video View Binding

    /// Called by VideoSurfaceViewRepresentable once the UIView is created.
    /// Stores a reference so the inputHandler can be wired up when InputSender starts.
    func bindVideoView(_ view: VideoSurfaceView) {
        videoView = view
        view.setDiagnosticsEnabled(diagnosticsEnabled)
        view.onDecodedVideoFormatChanged = { [weak self] format in
            Task { @MainActor [weak self] in
                self?.applyDecodedVideoFormat(format)
            }
        }
        view.inputHandler = inputSender
        view.menuPressHandler = { [weak self] in self?.handleMenuPress() }
    }

    /// Sets the statistics HUD level. Stats collection runs regardless while streaming;
    /// the level only controls what is rendered (and the full-report cadence).
    func setStatsMode(_ mode: StreamStatsMode) {
        statsMode = mode
    }

    /// Enables developer diagnostics: video-pipeline tracing, AudioSync logging, and the
    /// debug stats rows. Orthogonal to the statistics HUD level.
    func setDiagnosticsEnabled(_ enabled: Bool) {
        guard diagnosticsEnabled != enabled else { return }
        diagnosticsEnabled = enabled
        videoView?.setDiagnosticsEnabled(enabled)
    }

    @discardableResult
    func startRtcEventLog(maxSizeBytes: Int64 = 15 * 1024 * 1024) -> URL? {
        guard let peerConnection else { return nil }
        stopRtcEventLog()

        let fileManager = FileManager.default
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = caches.appendingPathComponent("RTCEventLogs", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try pruneRtcEventLogs(in: directory, keeping: 2)
        } catch {
            print("[Stats] Unable to prepare RTC event log directory: \(error)")
            return nil
        }

        let formatter = ISO8601DateFormatter()
        let filename = "rtc-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString).log"
        let url = directory.appendingPathComponent(filename)
        guard peerConnection.startRtcEventLog(
            withFilePath: url.path,
            maxSizeInBytes: max(1_048_576, maxSizeBytes)
        ) else { return nil }

        rtcEventLogURL = url
        return url
    }

    func stopRtcEventLog() {
        guard rtcEventLogURL != nil else { return }
        peerConnection?.stopRtcEventLog()
        rtcEventLogURL = nil
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
    }

    func setInputPaused(_ paused: Bool) {
        inputSender?.setPaused(paused)
    }

    // MARK: Fail (external error surfacing)

    func fail(with message: String) {
        state = .failed(message: message)
    }

    // MARK: Disconnect

    func disconnect() {
        stopRtcEventLog()
        stopStatsTimer()
        wasStreaming = false
        reconnectAttempt = 0
        serverStopped = false
        inputSender?.stop()
        signaling?.disconnect()
        videoView?.videoTrack = nil
        peerConnection?.close()
        peerConnection = nil
        inputDataChannel = nil
        inputSendQueue.sync {
            reliableSendChannel = nil
            let pending = Array(pendingGamepadSnapshots.values)
            pendingGamepadSnapshots.removeAll()
            inputDropped &+= UInt64(pending.count)
            pending.forEach { $0.completion(.channelUnavailable) }
        }
        inputSendQueue.async { [weak self] in self?.rumbleSink = nil }
        partiallyReliableDataChannel = nil
        statsChannel = nil
        controlChannel = nil
        videoTrack = nil
        videoReceiver = nil
        micAudioTrack = nil
        micAudioSource = nil
        pingHistory = []
        fpsHistory = []
        bitrateHistory = []
        streamingStartedAt = nil
        signalingComplete = false
        inputReady = false
        previousVideoStats = nil
        statsTick = 0
        previousSelectedCandidatePairId = ""
        lastZoneRttFeedbackAt = nil
        videoView?.inputHandler = nil
        videoView?.menuPressHandler = nil
        videoView?.onDecodedVideoFormatChanged = nil
        videoView = nil
        remoteMode = .mouse
        menuPressCount = 0
        timeWarning = nil
        videoDiagnostics = VideoPipelineSnapshot()
        colorState = StreamColorState(
            preference: .automatic,
            requestedMode: .sdr8,
            negotiatedMode: nil,
            detectedMode: nil,
            displayHDRSupport: .unknown,
            fallbackReason: nil
        )
        diagnosticSessionSummary = ""
        state = .idle
    }

    // MARK: Auto-Reconnect

    private func attemptReconnect() {
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        gfnLog.info("attemptReconnect: attempt \(attempt)/\(Self.maxReconnectAttempts)")

        guard attempt <= Self.maxReconnectAttempts, onReconnectNeeded != nil else {
            gfnLog.info("attemptReconnect: giving up, showing sessionEnded")
            state = .sessionEnded
            return
        }

        state = .reconnecting(attempt: attempt)

        // Tear down current peer connection before reconnecting
        inputSender?.stop()
        signaling?.disconnect()
        peerConnection?.close()
        peerConnection = nil
        inputDataChannel = nil
        partiallyReliableDataChannel = nil
        statsChannel = nil
        reliableSendChannel = nil
        controlChannel = nil
        videoTrack = nil
        micAudioTrack = nil
        micAudioSource = nil
        signalingComplete = false
        inputReady = false

        let delays: [TimeInterval] = [0.5, 1.0, 2.0]
        let delay = delays[min(attempt - 1, delays.count - 1)]

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            guard case .reconnecting = state else { return }

            guard let reclaim = onReconnectNeeded,
                  let session = await reclaim()
            else {
                gfnLog.info("attemptReconnect: reclaim failed on attempt \(attempt)")
                if attempt >= Self.maxReconnectAttempts {
                    state = .sessionEnded
                }
                return
            }

            gfnLog.info("attemptReconnect: reclaimed session, reconnecting WebRTC")
            sessionInfo = session
            setupSignaling(session: session)
            do {
                try await signaling?.connect()
            } catch {
                gfnLog.error("attemptReconnect: signaling failed: \(error)")
                if attempt >= Self.maxReconnectAttempts {
                    state = .sessionEnded
                }
            }
        }
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
        case let .offer(sdp):
            Task { await handleOffer(sdp: sdp) }
        case let .remoteICE(candidate, sdpMid, sdpMLineIndex):
            addRemoteICE(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
        case let .disconnected(reason):
            // Always stop the signaling client — kills heartbeat and releases the connection.
            signaling?.disconnect()
            if signalingComplete {
                // Server closes the WebSocket after answer + ICE exchange — expected GFN behavior.
                // The media runs over WebRTC ICE/DTLS/SRTP; let ICE state drive the outcome.
                print("[Stream] Signaling closed after setup (expected): \(reason)")
            } else {
                state = .disconnected(reason: reason)
            }
        case let .error(msg):
            state = .failed(message: msg)
        case .log:
            break
        }
    }

    // MARK: Private — WebRTC Peer Connection

    private func configureAudioSession(microphoneRequested: Bool) -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        if microphoneRequested, audioSession.availableCategories.contains(.playAndRecord) {
            do {
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.allowBluetoothHFP, .allowBluetoothA2DP]
                )
                try audioSession.setPreferredIOBufferDuration(0.01)
                try audioSession.setActive(true)
                guard audioSession.isInputAvailable else {
                    print("[Stream] AVAudioSession has no input route, falling back to playback")
                    return configurePlaybackAudioSession(audioSession)
                }
                print("[Stream] AVAudioSession configured for playback + microphone")
                logAudioSessionConfiguration(audioSession)
                return true
            } catch {
                print("[Stream] AVAudioSession microphone configuration failed, falling back to playback: \(error)")
            }
        } else if microphoneRequested {
            print("[Stream] AVAudioSession playAndRecord unavailable, falling back to playback")
        }

        return configurePlaybackAudioSession(audioSession)
    }

    private func configurePlaybackAudioSession(_ audioSession: AVAudioSession) -> Bool {
        do {
            // .default mode, not .moviePlayback: movie mode engages tvOS's high-latency,
            // quality-optimized output path (measured 80 ms outputLatency + 20 ms IO buffer
            // = 100 ms device playout delay over HDMI), which puts game audio ~100 ms behind
            // our zero-buffer video. A short preferred IO buffer keeps the render quantum small.
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setPreferredIOBufferDuration(0.01)
            try audioSession.setActive(true)
            print("[Stream] AVAudioSession configured for playback")
            logAudioSessionConfiguration(audioSession)
        } catch {
            print("[Stream] AVAudioSession playback configuration failed: \(error)")
        }
        return false
    }

    /// Logs the OS-level audio output configuration — the latency layer WebRTC stats can't see.
    /// outputLatency is the route's hardware/driver delay (HDMI vs TV speakers vs Bluetooth,
    /// which alone can add 100–200 ms); ioBufferDuration is the render quantum.
    private func logAudioSessionConfiguration(_ session: AVAudioSession) {
        let route = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ", ")
        let message = String(
            format: "session category %@ mode %@ | sampleRate %.0f Hz ioBuffer %.1fms outputLatency %.1fms | route [%@]",
            session.category.rawValue,
            session.mode.rawValue,
            session.sampleRate,
            session.ioBufferDuration * 1000,
            session.outputLatency * 1000,
            route
        )
        audioSyncLog.info("\(message, privacy: .public)")
    }

    private func handleOffer(sdp: String) async {
        guard let session = sessionInfo else { return }
        #if DEBUG
            print("[Stream] Offer SDP (\(sdp.count) chars):")
            sdp.components(separatedBy: "\r\n").forEach { print("  \($0)") }
        #endif

        // The server offers multiopus/48000/6 when the session requested 5.1 (see
        // CloudMatchClient surroundAudioInfo); the offer is the single source of truth
        // for the playout channel count. Must be set before the peer connection exists
        // so the audio device initializes with the right graph.
        let surroundOffered = sdp.contains("multiopus/")
        GFNAudioDevice.shared.requestedOutputChannels = surroundOffered ? 6 : 2
        audioStats.codecName = surroundOffered ? "Multiopus" : "Opus"
        audioStats.codecChannels = surroundOffered ? 6 : 2
        audioSyncLog.info("offer audio: \(surroundOffered ? "multiopus 5.1" : "opus stereo", privacy: .public)")

        let microphoneEnabledForConnection = configureAudioSession(microphoneRequested: settings.micEnabled)

        // The lifetime is immutable after channel creation, so resolve the server's value first.
        if let match = sdp.range(of: #"ri\.partialReliableThresholdMs[: ]+(\d+)"#, options: .regularExpression),
           let numMatch = sdp[match].range(of: #"\d+"#, options: .regularExpression),
           let ms = Int(sdp[numMatch])
        {
            partialReliableThresholdMs = min(max(ms, 1), Int(UInt16.max))
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
        // Keep the audio jitter buffer lean: measured NetEQ delay sat ~20 ms above its own
        // target without ever draining (stretch -0 ms). Fast-accelerate time-compresses the
        // excess away; the packet cap (50 × 10 ms = 500 ms) bounds worst-case buildup. The
        // GFN server sends no RTCP SR, so WebRTC cannot lip-sync — audio latency is all we
        // can trim, and video is rendered unbuffered by design (input latency).
        config.audioJitterBufferFastAccelerate = true
        config.audioJitterBufferMaxPackets = 50

        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = GFNStreamController.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            state = .failed(message: "Failed to create LKRTCPeerConnection")
            return
        }
        peerConnection = pc
        if settings.enableRtcEventLog {
            if let url = startRtcEventLog() {
                print("[Stats] RTC event log: \(url.path)")
            } else {
                print("[Stats] Unable to start RTC event log")
            }
        }
        print("[Stream] Peer connection created, starting offer handling")

        // Reliable ordered input channel — label must match the GFN server's expected "input_channel_v1"
        let dcConfig = LKRTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        dcConfig.isNegotiated = false
        if let dc = pc.dataChannel(forLabel: "input_channel_v1", configuration: dcConfig) {
            inputDataChannel = dc
            reliableSendChannel = dc
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

        // Server performance stats (game FPS, server RTD) arrive as binary messages
        // here — same channel the official client opens for its statistics overlay.
        let statsConfig = LKRTCDataChannelConfiguration()
        statsConfig.isOrdered = false
        statsConfig.maxRetransmits = 0
        statsConfig.isNegotiated = false
        if let dc = pc.dataChannel(forLabel: "stats_channel", configuration: statsConfig) {
            statsChannel = dc
            dc.delegate = self
        }

        // Attach microphone audio track if enabled (must happen before answer creation
        // so the m=audio sendrecv line is included in the SDP)
        if microphoneEnabledForConnection {
            await attachMicrophone(to: pc)
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
            Self.rewriteOfferConnectionAddresses(sdp, serverIp: ip)
        } ?? sdp
        if let ip = serverMediaIp {
            print("[Stream] Fixed placeholder IPs in offer SDP: 0.0.0.0/127.0.0.1 -> \(ip)")
        } else {
            print("[Stream] Warning: no server IP available — offer placeholder IPs left unchanged")
        }
        // Normalize H.265 fmtp in the offer before setRemoteDescription so WebRTC
        // keeps H.265 in the generated answer (tier-flag and level-id must be valid).
        let h265NormalizedSdp = SDPMunger.rewriteH265LevelId(SDPMunger.rewriteH265TierFlag(fixedSdp))
        let remoteSDP = LKRTCSessionDescription(type: .offer, sdp: h265NormalizedSdp)
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
            let answerColorRequest = settings.colorRequest(localCapabilities: .detect(codec: settings.codec), accountAllowsHDR: accountAllowsHDR)
            let codecFilteredSdp = SDPMunger.preferCodec(
                answer.sdp,
                codec: settings.codec,
                preferTenBit: answerColorRequest.bitDepth >= 10
            )
            // For H.265: rewrite tier-flag=1→0 and cap level-id to hardware-safe values.
            // Apple's decoder may reject High-tier or above-spec level-id advertisements.
            let h265SafeSdp = settings.codec == .h265
                ? SDPMunger.rewriteH265LevelId(SDPMunger.rewriteH265TierFlag(codecFilteredSdp))
                : codecFilteredSdp
            // Audio: strip RED (jitter-buffer latency) or, for surround offers, rebuild the
            // audio section to accept multiopus — createAnswer rejects codecs it does not
            // advertise, which would otherwise break the whole bundle.
            let audioMungedSdp = SDPMunger.mungeAudioAnswer(
                SDPMunger.injectBandwidth(h265SafeSdp, videoKbps: settings.maxBitrateKbps),
                offer: fixedSdp
            )
            let mangledAnswerSdp = audioMungedSdp
            let answerH265Params = mangledAnswerSdp.components(separatedBy: "\r\n")
                .filter { ($0.hasPrefix("a=rtpmap:") && $0.contains("H265")) || ($0.hasPrefix("a=fmtp:") && $0.contains("profile-id")) }
                .joined(separator: " ")
            videoColorLog.info("answer H265: \(answerH265Params.isEmpty ? "none" : answerH265Params)")
            #if DEBUG
                print("[Stream] Answer SDP (\(mangledAnswerSdp.count) chars):")
                mangledAnswerSdp.components(separatedBy: "\r\n").forEach { print("  \($0)") }
            #endif

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
            for ip in resolvedIps where !allIps.contains(ip) {
                allIps.append(ip)
            }
            if !connectedHost.isEmpty, !allIps.contains(connectedHost) { allIps.append(connectedHost) }

            let allPorts = [mciPort, sdpPort].filter { $0 > 0 }
            let pairs = allIps.flatMap { ip in allPorts.map { (ip, $0) } }

            if pairs.isEmpty {
                print("[ICE] No server IPs or ports available — ICE candidate injection skipped")
            } else {
                print("[ICE] Injecting \(pairs.count) candidate(s) (mciIp=\(mciIp ?? "nil") mciPort=\(mciPort) sdpPort=\(sdpPort))")
                for (i, (ip, port)) in pairs.enumerated() {
                    let cand = LKRTCIceCandidate(
                        sdp: "candidate:\(i + 1) 1 UDP 2130706431 \(ip) \(port) typ host",
                        sdpMLineIndex: 0, sdpMid: "0"
                    )
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
        let width = Int(resolutionParts.first ?? "1920") ?? 1920
        let height = Int(resolutionParts.last ?? "1080") ?? 1080
        let minBitrateKbps = max(5000, settings.maxBitrateKbps * 35 / 100)
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
            "a=video.bitDepth:\(settings.colorRequest(localCapabilities: .detect(codec: settings.codec), accountAllowsHDR: accountAllowsHDR).bitDepth)",
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

    private static func rewriteOfferConnectionAddresses(_ sdp: String, serverIp: String) -> String {
        sdp
            .replacingOccurrences(of: "c=IN IP4 0.0.0.0", with: "c=IN IP4 \(serverIp)")
            .replacingOccurrences(of: "c=IN IP4 127.0.0.1", with: "c=IN IP4 \(serverIp)")
            .replacingOccurrences(of: " 0.0.0.0 ", with: " \(serverIp) ")
            .replacingOccurrences(of: " 127.0.0.1 ", with: " \(serverIp) ")
    }

    private func addRemoteICE(candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        print("[ICE] Adding remote candidate: \(candidate) mid=\(sdpMid ?? "nil") mLineIndex=\(sdpMLineIndex ?? -1)")
        let ice = LKRTCIceCandidate(
            sdp: candidate,
            sdpMLineIndex: Int32(sdpMLineIndex ?? 0),
            sdpMid: sdpMid
        )
        peerConnection?.add(ice, completionHandler: { _ in })
    }

    // MARK: Private — Stats

    /// Extracts the average game FPS from a stats_channel binary message. Layout
    /// (mirrors the official web client's parser): byte 0 is the message type —
    /// 3: payload starts at byte 1; 4: the type byte doubles as the payload version.
    /// Payload: u8 version (>= 4), then little-endian float64s at offsets 1
    /// (timestamp), 9, 17 (round-trip delay) and 25 (average game FPS).
    private nonisolated static func parseStatsChannelGameFps(_ data: Data) -> Double? {
        guard let type = data.first else { return nil }
        let payload: Data
        switch type {
        case 3: payload = data.dropFirst()
        case 4: payload = data
        default: return nil
        }
        guard payload.count >= 33, let version = payload.first, version >= 4 else { return nil }
        let bytes = payload.subdata(in: (payload.startIndex + 25) ..< (payload.startIndex + 33))
        let bits = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        let value = Double(bitPattern: UInt64(littleEndian: bits))
        guard value.isFinite, value >= 0, value < 1000 else { return nil }
        return value
    }

    /// "https://np-frk-08.cloudmatchbeta.nvidiagrid.net/" → "FRK-08": first host label
    /// without the "np-" prefix, uppercased — the form the official client displays.
    private static func zoneShortName(from zone: String) -> String {
        guard !zone.isEmpty else { return "" }
        let host = URLComponents(string: zone)?.host ?? zone
        var name = host.components(separatedBy: ".").first ?? host
        if name.lowercased().hasPrefix("np-") {
            name = String(name.dropFirst(3))
        }
        return name.uppercased()
    }

    private func startStatsTimer() {
        guard statsTimer == nil else { return }
        collectStats()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.collectStats() }
        }
        statsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
        statsGeneration &+= 1
        videoStatsRequestInFlight = false
        connectionStatsRequestInFlight = false
        previousVideoStats = nil
        previousAudioSyncStats = nil
        statsTick = 0
    }

    private func collectStats() {
        guard let peerConnection else { return }
        collectInputStats()
        if diagnosticsEnabled {
            let generation = statsGeneration
            videoView?.captureDiagnostics { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self, statsGeneration == generation, diagnosticsEnabled else {
                        return
                    }
                    videoDiagnostics = snapshot
                }
            }
        }
        statsTick &+= 1
        let generation = statsGeneration

        if let videoReceiver, !videoStatsRequestInFlight {
            videoStatsRequestInFlight = true
            peerConnection.statistics(for: videoReceiver) { [weak self] report in
                streamStatsParsingQueue.async {
                    let snapshot = Self.parseVideoStats(report)
                    Task { @MainActor [weak self] in
                        guard let self, statsGeneration == generation else { return }
                        videoStatsRequestInFlight = false
                        if let snapshot { applyVideoStats(snapshot) }
                    }
                }
            }
        }

        // A visible HUD (or diagnostics) samples the full report every tick so audio rows and
        // the AudioSync log have 1 s resolution; otherwise every 5th tick is enough for the
        // pause menu's RTT/path display.
        let wantFullReport = statsTick == 1 || statsTick.isMultiple(of: 5)
            || statsMode != .off || diagnosticsEnabled
        if wantFullReport, !connectionStatsRequestInFlight {
            connectionStatsRequestInFlight = true
            let wantAudio = statsMode == .standard || diagnosticsEnabled
            peerConnection.statistics { [weak self] report in
                streamStatsParsingQueue.async {
                    let snapshot = Self.parseConnectionStats(report)
                    let audioSample = wantAudio ? Self.parseAudioSyncStats(report) : nil
                    Task { @MainActor [weak self] in
                        guard let self, statsGeneration == generation else { return }
                        connectionStatsRequestInFlight = false
                        if let snapshot {
                            stats.rttMs = snapshot.rttMs
                            stats.selectedNetworkPath = snapshot.selectedNetworkPath
                        }
                        if let audioSample { applyAudioSyncStats(audioSample) }
                    }
                }
            }
        }
    }

    private func collectInputStats() {
        inputSendQueue.async { [weak self] in
            guard let self else { return }
            let sortedWaits = inputQueueWaitsNs.sorted()
            let p95Index = sortedWaits.isEmpty
                ? 0
                : min(sortedWaits.count - 1, Int((Double(sortedWaits.count) * 0.95).rounded(.up)) - 1)
            let p95Ns = sortedWaits.isEmpty ? 0 : sortedWaits[p95Index]
            let now = DispatchTime.now().uptimeNanoseconds
            let gamepadAgeNs = newestGamepadGeneratedAt == 0
                ? 0
                : now &- newestGamepadGeneratedAt
            let generated = inputGenerated
            let submitted = inputSubmitted
            let accepted = inputAccepted
            let dropped = inputDropped
            let superseded = inputSuperseded
            let bufferedBytes = inputBufferedBytes
            let maxNs = inputQueueMaxNs
            let channelState = inputChannelState
            inputQueueWaitsNs.removeAll(keepingCapacity: true)
            inputQueueMaxNs = 0

            Task { @MainActor [weak self] in
                guard let self else { return }
                stats.inputGenerated = generated
                stats.inputSubmitted = submitted
                stats.inputAccepted = accepted
                stats.inputDropped = dropped
                stats.inputSuperseded = superseded
                stats.inputBufferedBytes = bufferedBytes
                stats.inputQueueP95Ms = Double(p95Ns) / 1_000_000
                stats.inputQueueMaxMs = Double(maxNs) / 1_000_000
                stats.newestGamepadAgeMs = Double(gamepadAgeNs) / 1_000_000
                stats.inputChannelState = channelState
            }
        }
    }

    private nonisolated static func parseVideoStats(_ report: LKRTCStatisticsReport) -> VideoStatsSnapshot? {
        // Build codec name lookup: stat ID → human-readable name (e.g. "H.265", "AV1")
        var codecNames: [String: String] = [:]
        for (id, stat) in report.statistics where stat.type == "codec" {
            if let mime = stat.values["mimeType"] as? String {
                let raw = mime.components(separatedBy: "/").last ?? mime
                switch raw.uppercased() {
                case "H264": codecNames[id] = "H.264"
                case "H265", "HEVC": codecNames[id] = "H.265"
                case "AV01", "AV1": codecNames[id] = "AV1"
                default: codecNames[id] = raw
                }
            }
        }

        guard let stat = report.statistics.values.first(where: {
            $0.type == "inbound-rtp" && $0.values["kind"] as? String == "video"
        }) else { return nil }

        let codecId = stat.values["codecId"] as? String ?? ""
        return VideoStatsSnapshot(
            timestampUs: stat.timestamp_us,
            bytesReceived: numericValue(stat.values["bytesReceived"]),
            packetsReceived: numericValue(stat.values["packetsReceived"]),
            packetsLost: numericValue(stat.values["packetsLost"]),
            framesDecoded: numericValue(stat.values["framesDecoded"]),
            framesDropped: numericValue(stat.values["framesDropped"]),
            framesPerSecond: numericValue(stat.values["framesPerSecond"]),
            frameWidth: numericValue(stat.values["frameWidth"]),
            frameHeight: numericValue(stat.values["frameHeight"]),
            jitterSeconds: numericValue(stat.values["jitter"]),
            jitterBufferDelaySeconds: numericValue(stat.values["jitterBufferDelay"]),
            jitterBufferTargetDelaySeconds: numericValue(stat.values["jitterBufferTargetDelay"]),
            jitterBufferMinimumDelaySeconds: numericValue(stat.values["jitterBufferMinimumDelay"]),
            jitterBufferEmittedCount: numericValue(stat.values["jitterBufferEmittedCount"]),
            totalDecodeTimeSeconds: numericValue(stat.values["totalDecodeTime"]),
            totalProcessingDelaySeconds: numericValue(stat.values["totalProcessingDelay"]),
            freezeCount: numericValue(stat.values["freezeCount"]),
            totalFreezeDurationSeconds: numericValue(stat.values["totalFreezesDuration"]),
            nackCount: numericValue(stat.values["nackCount"]),
            pliCount: numericValue(stat.values["pliCount"]),
            firCount: numericValue(stat.values["firCount"]),
            retransmittedPackets: numericValue(stat.values["retransmittedPacketsReceived"]),
            codec: codecNames[codecId] ?? codecId,
            decoderImplementation: stat.values["decoderImplementation"] as? String ?? "",
            powerEfficientDecoder: boolValue(stat.values["powerEfficientDecoder"])
        )
    }

    private nonisolated static func parseConnectionStats(_ report: LKRTCStatisticsReport) -> ConnectionStatsSnapshot? {
        var candidateDetails: [String: (protocolName: String, candidateType: String)] = [:]
        var candidatePairs: [String: (localID: String, remoteID: String, rttMs: Double, nominated: Bool)] = [:]
        var selectedCandidatePairID: String?

        for (id, stat) in report.statistics {
            if stat.type == "local-candidate" || stat.type == "remote-candidate" {
                candidateDetails[id] = (
                    protocolName: (stat.values["protocol"] as? String ?? "").lowercased(),
                    candidateType: (stat.values["candidateType"] as? String ?? "").lowercased()
                )
            } else if stat.type == "transport" {
                selectedCandidatePairID = stat.values["selectedCandidatePairId"] as? String
                    ?? selectedCandidatePairID
            } else if stat.type == "candidate-pair",
                      stat.values["state"] as? String == "succeeded"
            {
                candidatePairs[id] = (
                    localID: stat.values["localCandidateId"] as? String ?? "",
                    remoteID: stat.values["remoteCandidateId"] as? String ?? "",
                    rttMs: numericValue(stat.values["currentRoundTripTime"]) * 1000,
                    nominated: boolValue(stat.values["nominated"]) ?? false
                )
            }
        }

        let selectedPair = selectedCandidatePairID.flatMap { candidatePairs[$0] }
            ?? candidatePairs.values.first(where: \.nominated)
            ?? candidatePairs.values.first
        guard let selectedPair else { return nil }

        let local = candidateDetails[selectedPair.localID]
        let remote = candidateDetails[selectedPair.remoteID]
        let protocolName = local?.protocolName.isEmpty == false
            ? local?.protocolName ?? ""
            : remote?.protocolName ?? ""
        let usesRelay = local?.candidateType == "relay" || remote?.candidateType == "relay"
        let selectedNetworkPath = if protocolName == "tcp" || protocolName == "tls" {
            "tcp_tls_fallback"
        } else if usesRelay, protocolName == "udp" {
            "turn_udp_relay"
        } else if protocolName == "udp" {
            "direct_udp"
        } else {
            "unknown"
        }
        return ConnectionStatsSnapshot(
            rttMs: selectedPair.rttMs,
            selectedNetworkPath: selectedNetworkPath
        )
    }

    /// Extracts the audio-pipeline latency stats needed to diagnose audio↔video desync:
    /// NetEQ jitter-buffer delays (inbound-rtp kind=audio), device-side playout delay
    /// (media-playout), and both estimated playout timestamps for the direct A/V offset.
    private nonisolated static func parseAudioSyncStats(_ report: LKRTCStatisticsReport) -> AudioSyncStatsSnapshot? {
        guard let audio = report.statistics.values.first(where: {
            $0.type == "inbound-rtp" && $0.values["kind"] as? String == "audio"
        }) else { return nil }

        var snapshot = AudioSyncStatsSnapshot()
        snapshot.timestampUs = Double(audio.timestamp_us)
        snapshot.packetsReceived = numericValue(audio.values["packetsReceived"])
        snapshot.packetsLost = numericValue(audio.values["packetsLost"])
        snapshot.jitterSeconds = numericValue(audio.values["jitter"])
        snapshot.jitterBufferDelaySeconds = numericValue(audio.values["jitterBufferDelay"])
        snapshot.jitterBufferTargetDelaySeconds = numericValue(audio.values["jitterBufferTargetDelay"])
        snapshot.jitterBufferMinimumDelaySeconds = numericValue(audio.values["jitterBufferMinimumDelay"])
        snapshot.jitterBufferEmittedCount = numericValue(audio.values["jitterBufferEmittedCount"])
        snapshot.concealedSamples = numericValue(audio.values["concealedSamples"])
        snapshot.insertedSamplesForDeceleration = numericValue(audio.values["insertedSamplesForDeceleration"])
        snapshot.removedSamplesForAcceleration = numericValue(audio.values["removedSamplesForAcceleration"])
        snapshot.audioPlayoutTimestampMs = (audio.values["estimatedPlayoutTimestamp"] as? NSNumber)?.doubleValue

        if let playout = report.statistics.values.first(where: { $0.type == "media-playout" }) {
            snapshot.totalPlayoutDelaySeconds = numericValue(playout.values["totalPlayoutDelay"])
            snapshot.playoutSamplesCount = numericValue(playout.values["totalSamplesCount"])
        }
        if let video = report.statistics.values.first(where: {
            $0.type == "inbound-rtp" && $0.values["kind"] as? String == "video"
        }) {
            snapshot.videoPlayoutTimestampMs = (video.values["estimatedPlayoutTimestamp"] as? NSNumber)?.doubleValue
        }
        return snapshot
    }

    private nonisolated static func numericValue(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    private nonisolated static func boolValue(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    private func applyVideoStats(_ sample: VideoStatsSnapshot) {
        stats.fps = sample.framesPerSecond
        stats.resolutionWidth = Int(sample.frameWidth)
        stats.resolutionHeight = Int(sample.frameHeight)
        stats.codec = sample.codec
        stats.jitterMs = sample.jitterSeconds * 1000
        stats.decoderImplementation = sample.decoderImplementation
        stats.powerEfficientDecoder = sample.powerEfficientDecoder

        if let previous = previousVideoStats {
            let elapsedSeconds = (sample.timestampUs - previous.timestampUs) / 1_000_000
            if elapsedSeconds > 0 {
                stats.bitrateKbps = Int(
                    max(0, sample.bytesReceived - previous.bytesReceived) * 8 / elapsedSeconds / 1000
                )
            }

            let received = max(0, sample.packetsReceived - previous.packetsReceived)
            let lost = max(0, sample.packetsLost - previous.packetsLost)
            if received + lost > 0 {
                stats.packetLossPercent = lost / (received + lost) * 100
            }

            let emitted = max(0, sample.jitterBufferEmittedCount - previous.jitterBufferEmittedCount)
            stats.jitterBufferDelayMs = intervalAverage(
                sample.jitterBufferDelaySeconds,
                previous.jitterBufferDelaySeconds,
                count: emitted
            )
            stats.jitterBufferTargetDelayMs = intervalAverage(
                sample.jitterBufferTargetDelaySeconds,
                previous.jitterBufferTargetDelaySeconds,
                count: emitted
            )
            stats.jitterBufferMinimumDelayMs = intervalAverage(
                sample.jitterBufferMinimumDelaySeconds,
                previous.jitterBufferMinimumDelaySeconds,
                count: emitted
            )

            let decoded = max(0, sample.framesDecoded - previous.framesDecoded)
            stats.decodeTimeMs = intervalAverage(
                sample.totalDecodeTimeSeconds,
                previous.totalDecodeTimeSeconds,
                count: decoded
            )
            stats.processingDelayMs = intervalAverage(
                sample.totalProcessingDelaySeconds,
                previous.totalProcessingDelaySeconds,
                count: decoded
            )
            stats.framesDropped = intervalCount(sample.framesDropped, previous.framesDropped)
            stats.freezeCount = intervalCount(sample.freezeCount, previous.freezeCount)
            stats.freezeDurationMs = max(
                0,
                sample.totalFreezeDurationSeconds - previous.totalFreezeDurationSeconds
            ) * 1000
            stats.nackCount = intervalCount(sample.nackCount, previous.nackCount)
            stats.pliCount = intervalCount(sample.pliCount, previous.pliCount)
            stats.firCount = intervalCount(sample.firCount, previous.firCount)
            stats.retransmittedPackets = intervalCount(
                sample.retransmittedPackets,
                previous.retransmittedPackets
            )
        }

        previousVideoStats = sample
        appendHistory(&pingHistory, value: stats.rttMs)
        appendHistory(&fpsHistory, value: stats.fps)
        appendHistory(&bitrateHistory, value: Double(stats.bitrateKbps) / 1000.0)
    }

    private func applyDecodedVideoFormat(_ format: DecodedVideoFormat) {
        videoColorLog.info(
            "decoded mode=\(format.mode.rawValue) path=\(format.decoderPath.rawValue) \(format.width)x\(format.height) pixelFormat=\(format.pixelFormatName) bitDepth=\(format.bitDepth ?? -1) transfer=\(format.transferFunction ?? "nil") primaries=\(format.colorPrimaries ?? "nil") matrix=\(format.yCbCrMatrix ?? "nil") range=\(format.colorRange ?? "nil")"
        )
        colorState.detectedMode = format.mode
        colorState.fallbackReason = fallbackReason(for: format)
    }

    private func applyNegotiatedHDRMode(_ rawMode: Int) {
        videoColorLog.info("negotiated gameSessionHdrMode=\(rawMode)")
        if rawMode == 0 {
            if colorState.requestedMode != .hdr10 {
                colorState.negotiatedMode = colorState.requestedMode
            } else if colorState.fallbackReason == nil {
                colorState.fallbackReason = .serverReturnedSDR
            }
        } else {
            colorState.negotiatedMode = .hdr10
        }
    }

    private func fallbackReason(for format: DecodedVideoFormat) -> ColorFallbackReason? {
        if format.decoderPath == .softwareI420 {
            return .softwareDecoder
        }
        switch (colorState.requestedMode, format.mode) {
        case (.hdr10, .sdr10), (.hdr10, .sdr8):
            return .serverReturnedSDR
        case (.sdr10, .sdr8):
            return .decoderReturned8Bit
        case (_, .unknown10Bit), (_, .unknown8Bit):
            return .missingColorMetadata
        default:
            return nil
        }
    }

    /// Logs one compact AudioSync line per stats tick (diagnostic mode only), interval-averaged
    /// over the last tick like the video stats. Reading the line:
    /// - neteq: actual/target/floor delay of WebRTC's adaptive audio jitter buffer. A raised
    ///   floor (min) means something external — e.g. the lip-sync module — is holding audio back.
    /// - device: playout delay after the jitter buffer (ADM + OS output buffers).
    /// - stretch: NetEQ time-stretching (+slowed/−accelerated) and concealment, ms of audio.
    /// - av-offset: video − audio estimated playout timestamps; positive = audio behind video.
    private func applyAudioSyncStats(_ sample: AudioSyncStatsSnapshot) {
        defer { previousAudioSyncStats = sample }
        guard let previous = previousAudioSyncStats else { return }

        let emitted = max(0, sample.jitterBufferEmittedCount - previous.jitterBufferEmittedCount)
        let neteqMs = intervalAverage(sample.jitterBufferDelaySeconds, previous.jitterBufferDelaySeconds, count: emitted)
        let targetMs = intervalAverage(sample.jitterBufferTargetDelaySeconds, previous.jitterBufferTargetDelaySeconds, count: emitted)
        let minMs = intervalAverage(sample.jitterBufferMinimumDelaySeconds, previous.jitterBufferMinimumDelaySeconds, count: emitted)

        let playoutSamples = max(0, sample.playoutSamplesCount - previous.playoutSamplesCount)
        let deviceMs = intervalAverage(sample.totalPlayoutDelaySeconds, previous.totalPlayoutDelaySeconds, count: playoutSamples)

        // NetEQ time-stretching over the interval, converted from samples to ms at 48 kHz
        let sloweddMs = max(0, sample.insertedSamplesForDeceleration - previous.insertedSamplesForDeceleration) / 48
        let acceleratedMs = max(0, sample.removedSamplesForAcceleration - previous.removedSamplesForAcceleration) / 48
        let concealedMs = max(0, sample.concealedSamples - previous.concealedSamples) / 48

        let avOffsetMs: Double? = if let audioTs = sample.audioPlayoutTimestampMs,
                                     let videoTs = sample.videoPlayoutTimestampMs
        {
            videoTs - audioTs
        } else {
            nil
        }

        let lost = max(0, sample.packetsLost - previous.packetsLost)
        // Live OS output latency: the media-playout stat can be absent depending on the active
        // audio unit (then device reads 0), so also sample the route's latency directly.
        let osOutputLatencyMs = AVAudioSession.sharedInstance().outputLatency * 1000

        audioStats.jitterBufferCurrentMs = neteqMs
        audioStats.jitterBufferTargetMs = targetMs
        audioStats.devicePlayoutMs = deviceMs
        audioStats.packetsLost = Int(lost)
        audioStats.jitterMs = sample.jitterSeconds * 1000
        audioStats.concealedMsPerSecond = concealedMs
        audioStats.stretchedMsPerSecond = sloweddMs
        audioStats.acceleratedMsPerSecond = acceleratedMs
        audioStats.avOffsetMs = avOffsetMs
        audioStats.outputLatencyMs = osOutputLatencyMs
        audioStats.outputChannels = GFNAudioDevice.shared.outputNumberOfChannels
        audioStats.outputSampleRateHz = GFNAudioDevice.shared.deviceOutputSampleRate
        audioStats.outputRouteName = GFNAudioDevice.shared.outputRouteName

        guard diagnosticsEnabled else { return }
        let offset = avOffsetMs.map { String(format: "%+.0fms", $0) } ?? "n/a (no RTCP SR mapping)"
        let message = String(
            format: "neteq %.0fms (target %.0f, min %.0f) | device %.0fms out %.0fms | stretch +%.0f/-%.0fms conceal %.0fms | jitter %.1fms lost %.0f | av-offset %@",
            neteqMs, targetMs, minMs, deviceMs, osOutputLatencyMs, sloweddMs, acceleratedMs, concealedMs,
            sample.jitterSeconds * 1000, lost, offset
        )
        audioSyncLog.info("\(message, privacy: .public)")
    }

    private func intervalAverage(_ current: Double, _ previous: Double, count: Double) -> Double {
        guard count > 0 else { return 0 }
        return max(0, current - previous) / count * 1000
    }

    private func intervalCount(_ current: Double, _ previous: Double) -> Int {
        Int(max(0, current - previous))
    }

    private func pruneRtcEventLogs(in directory: URL, keeping count: Int) throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        let logs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        let sorted = logs.sorted { lhs, rhs in
            let leftValues = try? lhs.resourceValues(forKeys: keys)
            let rightValues = try? rhs.resourceValues(forKeys: keys)
            let leftDate = leftValues?.contentModificationDate ?? leftValues?.creationDate ?? .distantPast
            let rightDate = rightValues?.contentModificationDate ?? rightValues?.creationDate ?? .distantPast
            return leftDate > rightDate
        }
        for url in sorted.dropFirst(max(0, count)) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func appendHistory(_ history: inout [Double], value: Double) {
        if history.count >= 30 { history.removeFirst() }
        history.append(value)
    }

    private func parseSelectedConnectionStats(_ report: LKRTCStatisticsReport) {
        let transport = report.statistics.values.first { $0.type == "transport" }
        let selectedPairId = transport?.values["selectedCandidatePairId"] as? String
        let succeededPairs = report.statistics.values.filter {
            $0.type == "candidate-pair" && $0.values["state"] as? String == "succeeded"
        }
        let selectedPair = selectedPairId.flatMap { report.statistics[$0] }
            ?? succeededPairs.first(where: { ($0.values["nominated"] as? NSNumber)?.boolValue == true })
            ?? succeededPairs.first
        guard let selectedPair else { return }

        let localId = selectedPair.values["localCandidateId"] as? String
        let remoteId = selectedPair.values["remoteCandidateId"] as? String
        let local = localId.flatMap { report.statistics[$0] }
        let remote = remoteId.flatMap { report.statistics[$0] }
        let pairId = selectedPair.id

        if !previousSelectedCandidatePairId.isEmpty, previousSelectedCandidatePairId != pairId {
            stats.candidatePairChanges += 1
            print("[ICE] Selected pair changed: \(previousSelectedCandidatePairId) -> \(pairId)")
        }
        previousSelectedCandidatePairId = pairId

        stats.selectedCandidatePairId = pairId
        stats.rttMs = numericValue(selectedPair.values["currentRoundTripTime"]) * 1000
        stats.availableIncomingBitrateKbps = Int(
            numericValue(selectedPair.values["availableIncomingBitrate"]) / 1000
        )
        let localProtocol = local?.values["protocol"] as? String ?? ""
        let remoteProtocol = remote?.values["protocol"] as? String ?? ""
        stats.selectedProtocol = localProtocol.isEmpty ? remoteProtocol : localProtocol
        stats.localCandidateType = local?.values["candidateType"] as? String ?? ""
        stats.remoteCandidateType = remote?.values["candidateType"] as? String ?? ""
        stats.localCandidateAddress = candidateAddress(local)
        stats.remoteCandidateAddress = candidateAddress(remote)
        let protocolName = stats.selectedProtocol.lowercased()
        let usesRelay = stats.localCandidateType.lowercased() == "relay"
            || stats.remoteCandidateType.lowercased() == "relay"
        if protocolName == "tcp" || protocolName == "tls" {
            stats.selectedNetworkPath = "tcp_tls_fallback"
        } else if usesRelay, protocolName == "udp" {
            stats.selectedNetworkPath = "turn_udp_relay"
        } else if protocolName == "udp" {
            stats.selectedNetworkPath = "direct_udp"
        } else {
            stats.selectedNetworkPath = "unknown"
        }

        let now = Date()
        if stats.rttMs > 0,
           lastZoneRttFeedbackAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true,
           let zoneUrl = sessionInfo?.zone,
           !zoneUrl.isEmpty
        {
            lastZoneRttFeedbackAt = now
            let rttMs = stats.rttMs
            Task { await ZoneClient.shared.recordSessionRtt(zoneUrl: zoneUrl, rttMs: rttMs) }
        }
    }

    private func candidateAddress(_ candidate: LKRTCStatistics?) -> String {
        guard let candidate else { return "" }
        let address = candidate.values["address"] as? String
            ?? candidate.values["ip"] as? String
            ?? ""
        let port = Int(numericValue(candidate.values["port"]))
        return port > 0 ? "\(address):\(port)" : address
    }

    private func numericValue(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }
}

// MARK: - LKRTCPeerConnectionDelegate

extension GFNStreamController: LKRTCPeerConnectionDelegate {
    nonisolated func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}

    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {
        print("[Stream] Signaling state → \(stateChanged.rawValue)")
    }

    nonisolated func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}

    nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}

    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        let name = switch newState {
        case .new: "new"
        case .checking: "checking"
        case .connected: "connected"
        case .completed: "completed"
        case .failed: "failed"
        case .disconnected: "disconnected"
        case .closed: "closed"
        case .count: "count"
        @unknown default: "unknown(\(newState.rawValue))"
        }
        print("[ICE] State → \(name)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch newState {
            case .connected, .completed:
                wasStreaming = true
                reconnectAttempt = 0
                state = .streaming
                if streamingStartedAt == nil { streamingStartedAt = Date() }
                startStatsTimer()
            case .disconnected:
                stopStatsTimer()
                if serverStopped {
                    state = .sessionEnded
                } else if wasStreaming {
                    attemptReconnect()
                } else {
                    state = .disconnected(reason: "ICE disconnected")
                }
            case .failed:
                stopStatsTimer()
                if serverStopped {
                    state = .sessionEnded
                } else if wasStreaming {
                    attemptReconnect()
                } else {
                    state = .failed(message: "ICE connection failed")
                }
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        let name = switch newState {
        case .new: "new"
        case .gathering: "gathering"
        case .complete: "complete"
        @unknown default: "unknown(\(newState.rawValue))"
        }
        print("[ICE] Gathering → \(name)")
    }

    nonisolated func peerConnection(_: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        Task { @MainActor [weak self] in
            self?.signaling?.sendICECandidate(
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: Int(candidate.sdpMLineIndex)
            )
        }
    }

    nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}

    nonisolated func peerConnection(_: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        print("[DataChannel] Server opened channel: label=\(dataChannel.label)")
        if dataChannel.label == "control_channel" {
            dataChannel.delegate = self
            Task { @MainActor [weak self] in
                self?.controlChannel = dataChannel
            }
        }
    }

    nonisolated func peerConnection(_: LKRTCPeerConnection,
                                    didAdd rtpReceiver: LKRTCRtpReceiver,
                                    streams _: [LKRTCMediaStream])
    {
        print("[Stream] Received RTP receiver: kind=\(rtpReceiver.track?.kind ?? "nil")")
        guard let track = rtpReceiver.track as? LKRTCVideoTrack else { return }
        print("[Stream] Got video track")
        Task { @MainActor [weak self] in
            self?.videoReceiver = rtpReceiver
            self?.videoTrack = track
        }
    }
}

// MARK: - LKRTCDataChannelDelegate

extension GFNStreamController: LKRTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        print("[DataChannel] State → \(dataChannel.readyState.rawValue) label=\(dataChannel.label)")
        if dataChannel.label == "input_channel_v1" {
            let state = switch dataChannel.readyState {
            case .connecting: "connecting"
            case .open: "open"
            case .closing: "closing"
            case .closed: "closed"
            @unknown default: "unknown"
            }
            inputSendQueue.async { [weak self] in
                guard let self else { return }
                inputChannelState = state
                inputBufferedBytes = dataChannel.bufferedAmount
                if state == "closing" || state == "closed" {
                    let pending = Array(pendingGamepadSnapshots.values)
                    pendingGamepadSnapshots.removeAll()
                    inputDropped &+= UInt64(pending.count)
                    pending.forEach { $0.completion(.channelUnavailable) }
                }
            }
        }
        // InputSender is NOT started here — it starts only after the server sends its
        // handshake message on input_channel_v1 (handled in dataChannel(_:didReceiveMessageWith:))
    }

    nonisolated func dataChannel(_ dataChannel: LKRTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        guard dataChannel.label == "input_channel_v1" else { return }
        inputSendQueue.async { [weak self] in
            guard let self else { return }
            inputBufferedBytes = amount
            drainPendingGamepadSnapshotsIfPossible(on: dataChannel)
        }
    }

    nonisolated func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        if dataChannel.label == "stats_channel" {
            if let gameFps = Self.parseStatsChannelGameFps(buffer.data) {
                Task { @MainActor [weak self] in self?.stats.gameFps = gameFps }
            }
            return
        }

        // Handle control channel messages (timerNotification etc.)
        if dataChannel.label == "control_channel" {
            let text = String(data: buffer.data, encoding: .utf8) ?? "<binary \(buffer.data.count)B>"
            print("[ControlChannel] Message: \(text)")

            // Parse timerNotification — maps server codes to severity levels (matches OpenNOW)
            if let json = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any],
               let notification = json["timerNotification"] as? [String: Any],
               let rawCode = notification["code"] as? Int
            {
                let mappedCode: Int? = switch rawCode {
                case 1, 2: 1 // approaching limit
                case 4: 2 // ~5 minutes left
                case 6: 3 // last warning, kick imminent
                default: nil
                }
                if let code = mappedCode {
                    let secondsLeft = notification["secondsLeft"] as? Int
                    Task { @MainActor [weak self] in
                        self?.timeWarning = StreamTimeWarning(code: code, secondsLeft: secondsLeft)
                    }
                }
            }
            if let json = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any],
               let hdrMode = json["gameSessionHdrMode"] as? [String: Any],
               let rawMode = hdrMode["hdrMode"] as? Int
            {
                Task { @MainActor [weak self] in
                    self?.applyNegotiatedHDRMode(rawMode)
                }
            }
            // The server sends an `exitMessage` when it deliberately ends the stream — the user
            // closed the game, the session was stopped, a time limit was hit, or an idle kick.
            // Mark it so the ICE disconnect that follows ends the session instead of triggering a
            // pointless reconnect (the seat is being torn down; a reclaim would fail anyway).
            if let json = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any],
               json["exitMessage"] != nil
            {
                gfnLog.info("control channel exitMessage received — server ended stream, not reconnecting")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    serverStopped = true
                    state = .sessionEnded
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
        } else if bytes[0] == 0x0E {
            version = Int(firstWord)
            print("[DataChannel] Handshake: byte[0]=0x0e, version=\(version)")
        } else {
            if let cmd = GFNHapticsDecoder.decode(buffer.data) {
                print("[Rumble] inbound controller=\(cmd.controllerId) weak=\(cmd.weak) strong=\(cmd.strong)")
                inputSendQueue.async { [weak self] in
                    self?.rumbleSink?(cmd.controllerId, cmd.weak, cmd.strong)
                }
                return
            }
            print("[DataChannel] Non-handshake message on \(dataChannel.label): firstWord=\(firstWord) (0x\(String(firstWord, radix: 16)))")
            return
        }

        let negotiatedVersion = version
        Task { @MainActor [weak self] in
            guard let self, !self.inputReady else { return }
            inputReady = true
            protocolVersion = negotiatedVersion
            print("[DataChannel] Input ready — starting InputSender (protocol v\(negotiatedVersion))")
            let sender = InputSender(channel: self)
            sender.configure(
                protocolVersion: negotiatedVersion,
                deadzone: Float(settings.controllerDeadzone),
                overlayTriggerButton: settings.overlayTriggerButton,
                steamOverlayGestureEnabled: settings.enableSteamOverlayGesture,
                remoteMode: settings.defaultRemoteInputMode,
                rumbleEnabled: settings.rumbleEnabled,
                rumbleIntensity: Float(settings.rumbleIntensity)
            )
            remoteMode = settings.defaultRemoteInputMode
            videoView?.gamepadModeActive = (remoteMode == .gamepad || remoteMode == .dualsense)
            sender.menuToggleHandler = { [weak self] in self?.handleMenuPress() }
            sender.onRemoteModeChanged = { [weak self] mode in
                self?.remoteMode = mode
                self?.videoView?.gamepadModeActive = (mode == .gamepad || mode == .dualsense)
            }
            sender.start()
            inputSender = sender
            inputSendQueue.async { [weak self, weak sender] in
                self?.rumbleSink = { sender?.applyRumble(controllerId: $0, weak: $1, strong: $2) }
            }
            // Forward keyboard/mouse events from the video surface to the sender
            videoView?.inputHandler = sender
        }
    }
}

// MARK: - DataChannelSender conformance

extension GFNStreamController: DataChannelSender {
    nonisolated func sendData(
        _ packet: EncodedInputPacket,
        completion: @escaping (InputSendDisposition) -> Void
    ) {
        inputSendQueue.async { [weak self] in
            guard let self else {
                completion(.channelUnavailable)
                return
            }
            inputGenerated &+= 1

            guard let dc = reliableSendChannel, dc.readyState == .open else {
                inputDropped &+= 1
                completion(.channelUnavailable)
                return
            }

            if let slot = packet.gamepadSlot {
                if let pending = pendingGamepadSnapshots.removeValue(forKey: slot) {
                    inputSuperseded &+= 1
                    pending.completion(.superseded)
                }
                if packet.isReplaceableGamepadSnapshot,
                   dc.bufferedAmount > inputBackpressureHighWaterBytes
                {
                    pendingGamepadSnapshots[slot] = (packet, completion)
                    return
                }
            }

            sendImmediately(packet, completion: completion, on: dc)
            drainPendingGamepadSnapshotsIfPossible(on: dc)
        }
    }

    private nonisolated func sendImmediately(
        _ packet: EncodedInputPacket,
        completion: @escaping (InputSendDisposition) -> Void,
        on dataChannel: LKRTCDataChannel
    ) {
        let waitNs = DispatchTime.now().uptimeNanoseconds &- packet.generatedAt
        inputQueueWaitsNs.append(waitNs)
        inputQueueMaxNs = max(inputQueueMaxNs, waitNs)
        if packet.category == .gamepadSnapshot {
            newestGamepadGeneratedAt = packet.generatedAt
        }
        let data = Data(
            bytesNoCopy: packet.storage.mutableBytes,
            count: packet.count,
            deallocator: .none
        )
        let buffer = LKRTCDataBuffer(data: data, isBinary: true)
        inputSubmitted &+= 1
        var accepted = dataChannel.sendData(buffer)
        if !accepted, dataChannel.readyState == .open {
            // One immediate retry preserves FIFO ordering without creating an application retry queue.
            inputSubmitted &+= 1
            accepted = dataChannel.sendData(buffer)
        }
        inputBufferedBytes = dataChannel.bufferedAmount
        if accepted {
            inputAccepted &+= 1
            completion(.accepted)
        } else {
            inputDropped &+= 1
            completion(.rejected)
        }
    }

    private nonisolated func drainPendingGamepadSnapshotsIfPossible(on dataChannel: LKRTCDataChannel) {
        guard dataChannel.readyState == .open,
              dataChannel.bufferedAmount <= inputBackpressureLowWaterBytes else { return }
        for slot in pendingGamepadSnapshots.keys.sorted() {
            guard dataChannel.bufferedAmount <= inputBackpressureHighWaterBytes,
                  let pending = pendingGamepadSnapshots.removeValue(forKey: slot) else { break }
            sendImmediately(pending.packet, completion: pending.completion, on: dataChannel)
        }
    }
}

// MARK: - Errors

enum StreamError: Error {
    case noSDP
}
