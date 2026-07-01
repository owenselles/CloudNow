import Charts
import os.log
import SwiftUI

private let streamLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "Stream")

private enum LoadingPhase: Equatable {
    case finding
    case inQueue(Int?)
    case preparing
    case timedOut
}

struct StreamView: View {
    let game: GameInfo
    var settings: StreamSettings = .init()
    var existingSession: ActiveSessionInfo?
    /// When set, skips CloudMatch entirely and reconnects WebRTC directly using the stored session.
    var directSession: SessionInfo?
    let onDismiss: () -> Void
    /// Called when the user leaves without ending the session so the caller can offer a resume.
    var onLeave: ((GameInfo, SessionInfo) -> Void)?

    @Environment(AuthManager.self) var authManager
    @Environment(GamesViewModel.self) var viewModel
    @State private var streamController = GFNStreamController()
    @State private var showOverlay = false
    @State private var showExitConfirmation = false
    @State private var loadingPhase: LoadingPhase = .finding
    @State private var createdSession: SessionInfo?
    @State private var sessionToken: String?
    /// Per-ad state tracking to avoid duplicate reports
    @State private var adReportedAction: [String: AdAction] = [:]

    private let cloudMatchClient = CloudMatchClient()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch streamController.state {
            case .idle, .connecting:
                connectingView
            case .streaming:
                streamingView
            case let .reconnecting(attempt):
                reconnectingView(attempt: attempt)
            case let .disconnected(reason):
                disconnectedView(reason)
            case let .failed(message):
                failedView(message)
            case .sessionEnded:
                sessionEndedView
            }
        }
        .ignoresSafeArea()
        .task {
            streamController.onReconnectNeeded = { [self] in
                await reclaimSession()
            }
            await startSession()
        }
        .onDisappear { streamController.disconnect() }
        // During streaming, VideoSurfaceView is first responder and intercepts Menu via UIKit,
        // signaling us through menuPressCount. .onExitCommand only fires in non-streaming states
        // (loading, error) when the focus engine is active.
        .onChange(of: streamController.menuPressCount) { _, _ in
            toggleOverlay()
        }
        .onExitCommand {
            if streamController.state != .streaming {
                disconnect()
            }
        }
    }

    // MARK: Connecting

    private var connectingView: some View {
        VStack(spacing: 24) {
            if case .timedOut = loadingPhase {
                Image(systemName: "clock.badge.xmark")
                    .font(.system(size: 60))
                    .foregroundStyle(.orange)
            } else {
                ProgressView()
                    .scaleEffect(2)
                    .tint(.white)
            }
            Text("Starting \(game.title)…")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text(loadingLabel)
                .font(.body)
                .foregroundStyle(.secondary)
                .animation(.easeInOut, value: loadingPhase)

            // Show ad player when GFN requires watching an ad to stay in queue
            if let adState = createdSession?.adState,
               adState.isAdsRequired,
               let ad = adState.ads.first
            {
                QueueAdPlayerView(
                    ad: ad,
                    onStart: { id in reportAd(id: id, action: .start) },
                    onPause: { id in reportAd(id: id, action: .pause) },
                    onResume: { id in reportAd(id: id, action: .resume) },
                    onFinish: { id, ms in reportAd(id: id, action: .finish, watchedMs: ms) },
                    message: adState.message
                )
                .frame(maxWidth: 560)
            }

            HStack(spacing: 24) {
                if case .timedOut = loadingPhase {
                    Button("Retry") { Task { await startSession() } }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                }
                Button("Cancel") { disconnect() }
                    .buttonStyle(.bordered)
                    .tint(loadingPhase == .timedOut ? .red : .secondary)
            }
        }
    }

    private var loadingLabel: String {
        switch loadingPhase {
        case .finding:
            return "Connecting to a GeForce NOW server…"
        case let .inQueue(pos):
            if let pos { return "In queue · Position \(pos)" }
            return "In queue…"
        case .preparing:
            return "Preparing your game… This can take a minute"
        case .timedOut:
            return "Server took too long to respond."
        }
    }

    // MARK: Streaming

    private var streamingView: some View {
        ZStack {
            VideoSurfaceViewRepresentable(streamController: streamController, showOverlay: showOverlay)
                .ignoresSafeArea()

            if showOverlay {
                pauseMenu
                    .transition(.opacity)
            }

            if let warning = streamController.timeWarning, !showOverlay {
                timeWarningBanner(warning)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: streamController.timeWarning)
        .animation(.easeInOut(duration: 0.2), value: showOverlay)
        .onChange(of: showOverlay) { _, showing in
            // Pause game input while overlay is open in gamepad mode so D-pad
            // navigates overlay buttons instead of moving the in-game character.
            streamController.setInputPaused(showing && streamController.remoteMode != .mouse)
        }
        .alert("End Session?", isPresented: $showExitConfirmation) {
            Button("End Session", role: .destructive) { disconnect() }
            Button("Keep Playing", role: .cancel) {}
        } message: {
            Text("This will end your GeForce NOW session. To return later, use Leave Game instead.")
        }
    }

    // MARK: Pause Menu

    private var pauseMenu: some View {
        HStack(alignment: .top, spacing: 40) {
            // Actions
            VStack(spacing: 16) {
                Button {
                    toggleOverlay()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    streamController.toggleRemoteMode()
                } label: {
                    Label(remoteModeLabel, systemImage: remoteModeIcon)
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)

                Button {
                    leave()
                } label: {
                    Label("Leave Game", systemImage: "house")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)

                Button(role: .destructive) {
                    showExitConfirmation = true
                } label: {
                    Label("End Session", systemImage: "xmark.circle")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            // Live stats
            VStack(alignment: .leading, spacing: 10) {
                if streamController.statsMode == .off {
                    Label("Statistics disabled", systemImage: "chart.bar.xaxis")
                        .foregroundStyle(.secondary)
                } else {
                    metricRow(
                        icon: "network",
                        label: "RTT",
                        value: "\(Int(streamController.stats.rttMs)) ms",
                        history: streamController.pingHistory,
                        color: pingColor(streamController.stats.rttMs)
                    )
                    metricRow(
                        icon: "speedometer",
                        label: "FPS",
                        value: "\(Int(streamController.stats.fps))",
                        history: streamController.fpsHistory,
                        color: fpsColor(streamController.stats.fps)
                    )
                    metricRow(
                        icon: "wifi",
                        label: "Bitrate",
                        value: "\(streamController.stats.bitrateKbps / 1000) Mbps",
                        history: streamController.bitrateHistory,
                        color: .cyan
                    )
                    Divider().overlay(.white.opacity(0.4))
                    Label("\(streamController.stats.resolutionWidth)×\(streamController.stats.resolutionHeight) @ \(Int(streamController.stats.fps))fps", systemImage: "tv")
                    Label("Loss \(String(format: "%.1f", streamController.stats.packetLossPercent))%", systemImage: "arrow.triangle.2.circlepath")
                    Label(streamController.stats.selectedNetworkPath, systemImage: "point.3.connected.trianglepath.dotted")
                    Label(
                        "Input p95 \(String(format: "%.1f", streamController.stats.inputQueueP95Ms)) ms · \(streamController.stats.inputBufferedBytes) B queued",
                        systemImage: "gamecontroller"
                    )
                    if streamController.stats.inputDropped > 0 {
                        Label(
                            "Input drops \(streamController.stats.inputDropped)",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                    if streamController.stats.inputSuperseded > 0 {
                        Label(
                            "Analog snapshots coalesced \(streamController.stats.inputSuperseded)",
                            systemImage: "arrow.triangle.merge"
                        )
                        .foregroundStyle(.secondary)
                    }
                    if !streamController.stats.gpuType.isEmpty {
                        Label(streamController.stats.gpuType, systemImage: "cpu")
                    }
                    if let sub = viewModel.subscription, !sub.isUnlimited, let rem = sub.remainingMinutes {
                        Divider().overlay(.white.opacity(0.4))
                        Label {
                            Text(rem >= 60 ? "\(rem / 60)h \(rem % 60)m remaining" : "\(rem)m remaining")
                        } icon: {
                            Image(systemName: "clock")
                                .foregroundStyle(rem < 30 ? .orange : .white.opacity(0.7))
                        }
                        .foregroundStyle(rem < 30 ? .orange : .white)
                    }
                }

                if streamController.statsMode == .diagnostic {
                    diagnosticRows
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
        }
        .padding(32)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(60)
    }

    private var diagnosticRows: some View {
        let pipeline = streamController.videoDiagnostics
        return Group {
            Divider().overlay(.white.opacity(0.4))
            Label(
                "Jitter buffer \(formatMs(streamController.stats.jitterBufferDelayMs)) / target \(formatMs(streamController.stats.jitterBufferTargetDelayMs))",
                systemImage: "waveform.path"
            )
            Label(
                "Decode \(formatMs(streamController.stats.decodeTimeMs)) · process \(formatMs(streamController.stats.processingDelayMs))",
                systemImage: "cpu"
            )
            Label(
                "App \(pipeline.enqueuedFrames) enqueued · \(pipeline.droppedFrames) dropped · \(pipeline.backpressureEvents) backpressure",
                systemImage: "rectangle.stack"
            )
            Label(
                "Sample \(formatMs(pipeline.averageSampleCreationMs)) · convert \(formatMs(pipeline.averageConversionMs))",
                systemImage: "timer"
            )
            Label(
                "AV interval \(pipeline.avTotalFrames) frames · \(pipeline.avDroppedFrames) dropped · \(pipeline.avCorruptedFrames) corrupt · \(formatMs(pipeline.avAccumulatedFrameDelayMs)) late",
                systemImage: "display"
            )
            if !streamController.stats.decoderImplementation.isEmpty {
                Label(
                    "\(streamController.stats.decoderImplementation)\(streamController.stats.powerEfficientDecoder == true ? " · hardware" : "")",
                    systemImage: "video"
                )
            }
            Label(
                "Color \(streamController.colorState.preference.label) · requested \(streamController.colorState.requestedMode.rawValue.uppercased()) · detected \(streamController.colorState.detectedMode?.rawValue.uppercased() ?? "UNKNOWN") · display \(streamController.colorState.displayHDRSupport.rawValue)",
                systemImage: "circle.lefthalf.filled"
            )
            if let fallback = streamController.colorState.fallbackReason {
                Label("Fallback \(fallback.rawValue)", systemImage: "arrow.down.right.circle")
                    .foregroundStyle(.orange)
            }
            if let format = pipeline.decodedVideoFormat {
                Label(
                    "\(format.decoderPath.rawValue) \(format.pixelFormatName) \(format.bitDepth.map { "\($0)-bit" } ?? "unknown-bit") \(format.transferFunction ?? "no-transfer")",
                    systemImage: "scope"
                )
            }
            if streamController.rtcEventLogURL != nil {
                Label("RTC event log active", systemImage: "doc.text.magnifyingglass")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white.opacity(0.85))
    }

    private func formatMs(_ value: Double) -> String {
        String(format: "%.2f ms", value)
    }

    private var remoteModeLabel: String {
        switch streamController.remoteMode {
        case .mouse: "Remote: Mouse"
        case .gamepad: "Remote: Gamepad"
        case .dualsense: "Remote: Touchpad"
        }
    }

    private var remoteModeIcon: String {
        switch streamController.remoteMode {
        case .mouse: "cursorarrow"
        case .gamepad: "gamecontroller"
        case .dualsense: "hand.point.up.left"
        }
    }

    private func metricRow(icon: String, label: String, value: String, history: [Double], color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            Text("\(label): \(value)")
                .foregroundStyle(color)
                .frame(width: 130, alignment: .leading)
            if history.count > 1 {
                Chart {
                    ForEach(Array(history.enumerated()), id: \.offset) { idx, val in
                        LineMark(x: .value("t", idx), y: .value("v", val))
                            .foregroundStyle(color)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(width: 80, height: 24)
            }
        }
    }

    private func pingColor(_ ms: Double) -> Color {
        if ms < 30 { return .green }
        if ms < 80 { return .yellow }
        if ms < 150 { return .orange }
        return .red
    }

    private func fpsColor(_ fps: Double) -> Color {
        if fps >= 55 { return .green }
        if fps >= 30 { return .yellow }
        return .red
    }

    // MARK: Time Warning Banner

    private func timeWarningBanner(_ warning: StreamTimeWarning) -> some View {
        let (color, icon, message): (Color, String, String) = {
            let timeText = warning.secondsLeft.map { " (\($0)s left)" } ?? ""
            switch warning.code {
            case 3: return (.red, "clock.badge.xmark", "Session ending soon\(timeText)")
            case 2: return (.orange, "clock.badge.exclamationmark", "~5 minutes remaining\(timeText)")
            default: return (.yellow, "clock", "Session limit approaching\(timeText)")
            }
        }()
        return Label(message, systemImage: icon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(color.opacity(0.85), in: Capsule())
            .padding(.top, 40)
    }

    // MARK: Disconnected / Failed

    private func reconnectingView(attempt: Int) -> some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Reconnecting…")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text("Attempt \(attempt) of 3")
                .font(.body)
                .foregroundStyle(.secondary)
            Button("Cancel") { disconnect() }
                .buttonStyle(.bordered)
                .tint(.red)
        }
        .padding(60)
    }

    private var sessionEndedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("Session Ended")
                .font(.title.weight(.bold))
                .foregroundStyle(.white)
            Text("Your game session has ended.")
                .font(.body)
                .foregroundStyle(.secondary)
            Button("Exit") { disconnect() }
                .buttonStyle(.bordered)
                .tint(.blue)
        }
        .padding(60)
    }

    private func disconnectedView(_ reason: String) -> some View {
        statusView(
            icon: "wifi.slash",
            title: "Disconnected",
            message: reason,
            color: .yellow
        )
    }

    private func failedView(_ message: String) -> some View {
        statusView(
            icon: "exclamationmark.triangle",
            title: "Stream Failed",
            message: entitlementMessage(from: message),
            color: .red
        )
    }

    private func entitlementMessage(from raw: String) -> String {
        if raw.uppercased().contains("ENTITLEMENT") || raw.contains("3237093650") {
            return "\(game.title) is not in your GeForce NOW library."
        }
        if raw.contains("SESSION_LIMIT_EXCEEDED") {
            return "A previous session is still active. Please wait a moment and try again."
        }
        return raw
    }

    private func statusView(icon: String, title: String, message: String, color: Color) -> some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 60))
                .foregroundStyle(color)
            Text(title)
                .font(.title.weight(.bold))
                .foregroundStyle(.white)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 24) {
                Button("Retry") { Task { await startSession() } }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                Button("Exit") { disconnect() }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        }
        .padding(60)
    }

    // MARK: Actions

    private func startSession() async {
        let settings = settings.normalizedForClient
        streamLog.info("startSession: game=\(game.title), existingSession=\(existingSession != nil), directSession=\(directSession != nil)")
        // Reset stream controller (handles retry from failed/disconnected state)
        streamController.disconnect()

        // Reconnect path — RESUME PUT tells the server to rebuild its media endpoint,
        // then connect WebRTC as soon as we get a single status 2/3 (no double-poll wait).
        if let direct = directSession {
            streamLog.info("startSession: direct reconnect path, sessionId=\(direct.sessionId)")
            loadingPhase = .preparing
            do {
                let token = try await authManager.resolveToken()
                streamLog.info("startSession: token resolved")
                sessionToken = token
                let provider = authManager.session?.provider
                let streamingBaseUrl = provider?.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
                let base = streamingBaseUrl.hasSuffix("/") ? String(streamingBaseUrl.dropLast()) : streamingBaseUrl

                var sessionInfo = try await cloudMatchClient.claimSession(
                    sessionId: direct.sessionId,
                    serverIp: direct.serverIp,
                    token: token,
                    base: base,
                    routingZoneUrl: direct.zone,
                    clientId: direct.clientId,
                    deviceId: direct.deviceId,
                    appId: game.variants.first?.appId ?? game.variants.first?.id,
                    settings: settings
                )
                streamLog.info("startSession: claimed session, status=\(sessionInfo.status)")
                createdSession = sessionInfo

                // Poll until ready, but only need a single status 2/3 (server media is up).
                let timeout: TimeInterval = 60
                let start = Date()
                while sessionInfo.status != 2, sessionInfo.status != 3 {
                    if Date().timeIntervalSince(start) > timeout {
                        loadingPhase = .timedOut
                        return
                    }
                    try await Task.sleep(for: .seconds(2))
                    sessionInfo = try await cloudMatchClient.pollSession(
                        sessionId: sessionInfo.sessionId,
                        token: token,
                        base: sessionInfo.streamingBaseUrl,
                        serverIp: sessionInfo.serverIp.isEmpty ? nil : sessionInfo.serverIp,
                        routingZoneUrl: sessionInfo.zone,
                        clientId: sessionInfo.clientId,
                        deviceId: sessionInfo.deviceId
                    )
                    createdSession = sessionInfo
                }

                streamLog.info("startSession: direct path ready, connecting WebRTC")
                viewModel.recordPlayed(game)
                await streamController.connect(session: sessionInfo, settings: settings)
            } catch {
                streamLog.error("startSession: direct path failed: \(error)")
                streamController.fail(with: error.localizedDescription)
            }
            return
        }

        // Stop any previously created server session before opening a new one.
        // Skip for resume — we want to keep the existing session alive.
        if let session = createdSession, let token = sessionToken, existingSession == nil {
            streamLog.info("startSession: stopping previous session \(session.sessionId)")
            try? await cloudMatchClient.stopSession(
                sessionId: session.sessionId,
                token: token,
                base: session.streamingBaseUrl,
                serverIp: session.serverIp.isEmpty ? nil : session.serverIp,
                clientId: session.clientId,
                deviceId: session.deviceId
            )
        }
        createdSession = nil
        loadingPhase = .finding
        do {
            let token = try await authManager.resolveToken()
            streamLog.info("startSession: token resolved")
            sessionToken = token
            let provider = authManager.session?.provider
            let streamingBaseUrl = provider?.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
            let base = streamingBaseUrl.hasSuffix("/") ? String(streamingBaseUrl.dropLast()) : streamingBaseUrl
            streamLog.info("startSession: base=\(base)")

            var sessionInfo: SessionInfo

            if let existing = existingSession, let serverIp = existing.serverIp {
                streamLog.info("startSession: resume path, sessionId=\(existing.sessionId)")
                // Resume path: attach to the existing session without creating a new one
                sessionInfo = try await cloudMatchClient.claimSession(
                    sessionId: existing.sessionId,
                    serverIp: serverIp,
                    token: token,
                    base: base,
                    routingZoneUrl: viewModel.lastSession?.sessionId == existing.sessionId
                        ? viewModel.lastSession?.routingZoneUrl
                        : nil,
                    clientId: viewModel.lastSession?.sessionId == existing.sessionId
                        ? viewModel.lastSession?.clientId
                        : nil,
                    deviceId: viewModel.lastSession?.sessionId == existing.sessionId
                        ? viewModel.lastSession?.deviceId
                        : nil,
                    appId: existing.appId,
                    settings: settings
                )
                streamLog.info("startSession: claimed, status=\(sessionInfo.status)")
            } else {
                // New session path
                guard let appId = game.variants.first?.appId ?? game.variants.first?.id else {
                    streamLog.error("startSession: no appId found for game")
                    return
                }

                // Check for a locally saved session for this game — resume instead of creating new.
                if let last = viewModel.lastSession, last.appId == appId {
                    print("[Resume] found saved session \(last.sessionId) for appId=\(appId), trying resume")
                    do {
                        sessionInfo = try await cloudMatchClient.claimSession(
                            sessionId: last.sessionId,
                            serverIp: last.serverIp,
                            token: token,
                            base: last.base,
                            routingZoneUrl: last.routingZoneUrl,
                            clientId: last.clientId,
                            deviceId: last.deviceId,
                            appId: last.appId,
                            settings: settings
                        )
                        print("[Resume] claimed session, status=\(sessionInfo.status)")
                        createdSession = sessionInfo
                    } catch {
                        print("[Resume] claim failed: \(error), stopping old session and creating new")
                        try? await cloudMatchClient.stopSession(
                            sessionId: last.sessionId,
                            token: token,
                            base: last.base,
                            serverIp: last.serverIp.isEmpty ? nil : last.serverIp,
                            clientId: last.clientId,
                            deviceId: last.deviceId
                        )
                        viewModel.clearLastSession()
                        // Fall through to create new session below
                        sessionInfo = try await createNewSession(appId: appId, token: token, base: base)
                    }
                } else {
                    if let last = viewModel.lastSession {
                        print("[Resume] saved session appId=\(last.appId) != game appId=\(appId), stopping it")
                        try? await cloudMatchClient.stopSession(
                            sessionId: last.sessionId,
                            token: token,
                            base: last.base,
                            serverIp: last.serverIp.isEmpty ? nil : last.serverIp,
                            clientId: last.clientId,
                            deviceId: last.deviceId
                        )
                        viewModel.clearLastSession()
                    }
                    sessionInfo = try await createNewSession(appId: appId, token: token, base: base)
                }
            }
            createdSession = sessionInfo

            // Persist session so we can resume it across app launches
            if let appId = game.variants.first?.appId ?? game.variants.first?.id {
                viewModel.saveLastSession(LastSessionRecord(
                    sessionId: sessionInfo.sessionId,
                    serverIp: sessionInfo.serverIp,
                    appId: appId,
                    base: sessionInfo.streamingBaseUrl,
                    routingZoneUrl: sessionInfo.zone.isEmpty ? nil : sessionInfo.zone,
                    clientId: sessionInfo.clientId,
                    deviceId: sessionInfo.deviceId,
                    createdAt: Date()
                ))
            }

            // Poll with readyPollStreak confirmation (requires 2 consecutive ready polls).
            // While in queue: no timeout — user waits indefinitely with position updates.
            // After queue clears: 180-second setup timeout applies.
            var readyPollStreak = 0
            var setupStartTime: Date? = nil

            while readyPollStreak < 2 {
                // Update loading phase and apply timeout only outside the queue
                if sessionInfo.isInQueue {
                    loadingPhase = .inQueue(sessionInfo.queuePosition)
                    setupStartTime = nil
                } else {
                    if setupStartTime == nil { setupStartTime = Date() }
                    if let t = setupStartTime, Date().timeIntervalSince(t) > 180 {
                        loadingPhase = .timedOut
                        return
                    }
                    loadingPhase = .preparing
                }

                if sessionInfo.status == 2 || sessionInfo.status == 3 {
                    readyPollStreak += 1
                } else {
                    readyPollStreak = 0
                }

                if readyPollStreak >= 2 { break }

                try await Task.sleep(for: .seconds(2))
                sessionInfo = try await cloudMatchClient.pollSession(
                    sessionId: sessionInfo.sessionId,
                    token: token,
                    base: sessionInfo.streamingBaseUrl,
                    serverIp: sessionInfo.serverIp.isEmpty ? nil : sessionInfo.serverIp,
                    routingZoneUrl: sessionInfo.zone,
                    clientId: sessionInfo.clientId,
                    deviceId: sessionInfo.deviceId
                )
                createdSession = sessionInfo
            }

            streamLog.info("startSession: queue cleared, readyPollStreak=\(readyPollStreak), connecting WebRTC")
            streamLog.info("startSession: serverIp=\(sessionInfo.serverIp), signalingUrl=\(sessionInfo.signalingUrl)")
            viewModel.recordPlayed(game)
            await streamController.connect(session: sessionInfo, settings: settings)
        } catch {
            streamLog.error("startSession: FAILED: \(error)")
            streamController.fail(with: error.localizedDescription)
        }
    }

    private func reclaimSession() async -> SessionInfo? {
        guard let session = createdSession, let token = sessionToken else { return nil }
        streamLog.info("reclaimSession: attempting to reclaim \(session.sessionId)")
        do {
            let reclaimed = try await cloudMatchClient.claimSession(
                sessionId: session.sessionId,
                serverIp: session.serverIp,
                token: token,
                base: session.streamingBaseUrl,
                routingZoneUrl: session.zone,
                clientId: session.clientId,
                deviceId: session.deviceId,
                appId: game.variants.first?.appId ?? game.variants.first?.id,
                settings: settings
            )
            createdSession = reclaimed
            streamLog.info("reclaimSession: success, status=\(reclaimed.status)")
            return reclaimed
        } catch {
            streamLog.error("reclaimSession: failed: \(error)")
            return nil
        }
    }

    /// Leaves the stream locally without stopping the server session.
    /// GFN keeps the session alive for ~1–2 minutes so it can be resumed from home.
    private func leave() {
        if let session = createdSession {
            onLeave?(game, session)
        }
        streamController.disconnect()
        onDismiss()
    }

    private func disconnect() {
        // Intentional end — clear any pending resumable session
        viewModel.resumableSession = nil
        viewModel.clearLastSession()
        // Tell the server to stop the session so it doesn't linger
        if let session = createdSession, let token = sessionToken {
            Task {
                try? await cloudMatchClient.stopSession(
                    sessionId: session.sessionId,
                    token: token,
                    base: session.streamingBaseUrl,
                    serverIp: session.serverIp.isEmpty ? nil : session.serverIp,
                    clientId: session.clientId,
                    deviceId: session.deviceId
                )
            }
        }
        streamController.disconnect()
        onDismiss()
    }

    private func createNewSession(appId: String, token: String, base: String) async throws -> SessionInfo {
        let routeSelection: (base: String, routingZoneUrl: String?) = if let preferred = settings.preferredZoneUrl {
            (preferred, preferred)
        } else if let best = await viewModel.bestZoneUrl() {
            (best, best)
        } else {
            (base, nil)
        }
        print("[Session] creating new session, appId=\(appId), sessionBase=\(routeSelection.base), routingZoneUrl=\(routeSelection.routingZoneUrl ?? "nil")")

        let request = SessionCreateRequest(
            appId: appId,
            internalTitle: game.title,
            token: token,
            streamingBaseUrl: routeSelection.base,
            routingZoneUrl: routeSelection.routingZoneUrl,
            settings: settings,
            accountLinked: true
        )

        let sessionInfo = try await cloudMatchClient.createSession(request)
        print("[Session] created, sessionId=\(sessionInfo.sessionId), status=\(sessionInfo.status)")
        return sessionInfo
    }

    private func reportAd(id: String, action: AdAction, watchedMs: Int? = nil) {
        // Prevent duplicate reports for the same action on the same ad
        guard adReportedAction[id] != action else { return }
        adReportedAction[id] = action
        guard let session = createdSession, let token = sessionToken else { return }
        Task {
            await cloudMatchClient.reportAdEvent(
                sessionId: session.sessionId,
                token: token,
                base: session.streamingBaseUrl,
                serverIp: session.serverIp.isEmpty ? nil : session.serverIp,
                clientId: session.clientId,
                deviceId: session.deviceId,
                adId: id,
                action: action,
                watchedTimeMs: watchedMs
            )
        }
    }

    private func toggleOverlay() {
        showOverlay.toggle()
        // Pause input forwarding while the overlay is visible so swipes don't move
        // the game cursor and keyboard shortcuts don't reach the game accidentally.
        streamController.setInputPaused(showOverlay)
    }
}
