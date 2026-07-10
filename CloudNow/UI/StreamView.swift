import Combine
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var streamController = GFNStreamController()
    @State private var showOverlay = false
    @State private var showExitConfirmation = false
    @State private var loadingPhase: LoadingPhase = .finding
    @State private var createdSession: SessionInfo?
    @State private var sessionToken: String?
    /// Per-ad state tracking to avoid duplicate reports
    @State private var adReportedAction: [String: AdAction] = [:]

    /// Loading progress bar state (ETA-driven, mirrors the official client's determinate bar).
    @State private var loadingProgress: Double = 0
    /// Largest queue position seen this attempt, used as the 0% anchor so the bar fills as it drops.
    @State private var queueAnchor: Int?
    @State private var prepareStartedAt: Date?
    /// Latest server-reported remaining setup ETA, and when it was captured (for live countdown).
    @State private var prepareEta: TimeInterval?
    @State private var prepareEtaAt: Date?
    /// Feature badges to show on the loading screen (game supports it AND the client can use it).
    @State private var loadingBadges: [GameFeature] = []

    private let cloudMatchClient = CloudMatchClient()
    private let progressTick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            hostBackground.ignoresSafeArea()

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
            computeLoadingBadges()
            streamController.onReconnectNeeded = { [self] in
                await reclaimSession()
            }
            await startSession()
        }
        .onDisappear { streamController.disconnect() }
        // During streaming, VideoSurfaceView is first responder and intercepts Menu via UIKit,
        // signaling us through menuPressCount. .onExitCommand fires when the focus engine is
        // active: non-streaming states (loading, error) and while the pause menu holds focus —
        // there, B/Menu closes the menu just like Resume.
        .onChange(of: streamController.menuPressCount) { _, _ in
            toggleOverlay()
        }
        .onExitCommand {
            if showOverlay {
                toggleOverlay()
            } else if streamController.state != .streaming {
                disconnect()
            }
        }
        .onPlayPauseCommand {
            guard streamController.state == .streaming else { return }
            toggleOverlay()
        }
    }

    // MARK: Connecting

    private var connectingView: some View {
        // Top-left, left-aligned column (game title → status → progress bar → cancel), mirroring
        // the official client, whose primary content sits top-left with only a "powered by" strip
        // pushed to the bottom (loading-ui-badges { margin-top: auto }).
        ZStack(alignment: .topLeading) {
            loadingBackground
            VStack(alignment: .leading, spacing: 16) {
                if case .timedOut = loadingPhase {
                    Image(systemName: "clock.badge.xmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                }
                Text(game.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(loadingForegroundColor)
                    .lineLimit(2)
                Text(loadingLabel)
                    .font(.title3)
                    .foregroundStyle(loadingSecondaryForegroundColor)
                    .lineLimit(1)
                    .animation(.easeInOut, value: loadingPhase)

                if case .timedOut = loadingPhase {
                    EmptyView()
                } else if showDeterminateProgress {
                    ProgressView(value: loadingProgress)
                        .progressViewStyle(.linear)
                        .tint(loadingForegroundColor)
                        .frame(maxWidth: 560)
                        .padding(.top, 8)
                } else {
                    ProgressView()
                        .tint(loadingForegroundColor)
                        .padding(.top, 8)
                }

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
                    .padding(.top, 8)
                }

                HStack(spacing: 24) {
                    if case .timedOut = loadingPhase {
                        Button(L10n.text("retry")) { Task { await startSession() } }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                    }
                    Button(L10n.text("cancel")) { disconnect() }
                        .buttonStyle(.bordered)
                        .tint(loadingPhase == .timedOut ? .red : .secondary)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 90)
            .padding(.top, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottomLeading) { loadingBadgeRow }
        .onReceive(progressTick) { _ in advanceLoadingProgress() }
    }

    /// Feature badges (RTX/HDR/Reflex) shown bottom-left, mirroring the official client's badge
    /// strip. Only badges the game supports AND the client can actually use are present — see
    /// computeLoadingBadges().
    @ViewBuilder private var loadingBadgeRow: some View {
        if !loadingBadges.isEmpty, loadingPhase != .timedOut {
            HStack(spacing: 12) {
                ForEach(loadingBadges, id: \.self) { badge in
                    Label(badge.label, systemImage: badge.symbol)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(loadingForegroundColor)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(loadingForegroundColor.opacity(0.15), in: Capsule())
                        .overlay(Capsule().strokeBorder(loadingForegroundColor.opacity(0.25), lineWidth: 1))
                }
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 60)
        }
    }

    /// A badge shows only when the game supports the feature AND it's actually usable here:
    /// HDR requires the client's 10-bit/HDR pipeline, display, and an HDR-entitled tier; RTX
    /// requires a premium tier. Reflex is never shown: the session request only enables it
    /// at >= 120 fps, which tvOS's 60 Hz cap rules out. Mirrors the official client's
    /// supportedOnGame + systemSupported + subscription gating.
    private func computeLoadingBadges() {
        let supported = Set(game.supportedFeatures ?? [])
        guard !supported.isEmpty else { loadingBadges = []; return }
        let tier = (viewModel.subscription?.membershipTier ?? "").uppercased()
        let tierPremium = tier.contains("ULTIMATE") || tier.contains("PERFORMANCE") || tier.contains("PRIORITY")
        let caps = LocalVideoCapabilities.detect(codec: .h265)
        let hdrUsable = caps.supportsHardware10BitDecode && caps.displaySupportsHDR && tierPremium
        var badges: [GameFeature] = []
        if supported.contains(.rtx), tierPremium { badges.append(.rtx) }
        if supported.contains(.hdr), hdrUsable { badges.append(.hdr) }
        loadingBadges = badges
    }

    /// True when the loading screen has full-bleed key art behind it. With art, foreground content
    /// stays white over the art's dark scrim; without art we fall through to the host's theme-aware
    /// background (added in #52) and adopt its foreground color so text stays legible in light mode.
    private var hasLoadingArt: Bool {
        (game.heroImageUrl ?? game.heroBannerUrl).flatMap { URL(string: $0) } != nil
    }

    /// Primary loading foreground: white over key art, the host theme color over the themed fallback.
    private var loadingForegroundColor: Color {
        hasLoadingArt ? .white : hostPrimaryForegroundColor
    }

    /// Dimmed loading foreground (status line), tracking the primary's contrast.
    private var loadingSecondaryForegroundColor: Color {
        hasLoadingArt ? .white.opacity(0.85) : hostPrimaryForegroundColor.opacity(0.7)
    }

    @ViewBuilder private var loadingBackground: some View {
        // Prefer HERO_IMAGE (full-bleed key art) for the full-screen loading background, matching
        // the official client; fall back to the TV_BANNER-based heroBannerUrl when it's absent.
        if let url = (game.heroImageUrl ?? game.heroBannerUrl).flatMap({ URL(string: $0) }) {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.black
            }
            .ignoresSafeArea()
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.85), location: 0),
                        .init(color: .black.opacity(0.5), location: 0.4),
                        .init(color: .black.opacity(0.2), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
        }
        // No key art: render nothing so the host's theme-aware background (body's hostBackground,
        // from #52) shows through as the fallback — matching the app background in light and dark.
    }

    private var loadingLabel: String {
        switch loadingPhase {
        case .finding:
            return L10n.text("connecting_to_server")
        case let .inQueue(pos):
            if let pos { return L10n.format("in_queue_position", pos) }
            return L10n.text("in_queue")
        case .preparing:
            return (createdSession?.setupStage ?? .configuring).label
        case .timedOut:
            return L10n.text("server_took_too_long")
        }
    }

    /// Determinate bar once the server gives us a queue position or setup stage; the earliest
    /// "finding" moment (and the timed-out state) has no forward signal, so it stays a spinner —
    /// matching the official client, which is indeterminate until an ETA arrives.
    private var showDeterminateProgress: Bool {
        switch loadingPhase {
        case .finding, .timedOut: false
        case .inQueue, .preparing: true
        }
    }

    /// Eases the bar toward a phase-derived target. Queue fills as the position drops toward its
    /// first-seen anchor; setup fills over the server ETA (falling back to a nominal duration).
    /// The value only ever moves forward, so it never visibly jumps backward on a poll update.
    private func advanceLoadingProgress() {
        let target: Double
        switch loadingPhase {
        case .finding:
            prepareStartedAt = nil
            target = 0.06
        case let .inQueue(pos):
            prepareStartedAt = nil
            if let pos {
                queueAnchor = max(queueAnchor ?? pos, pos)
                let anchor = max(queueAnchor ?? pos, 1)
                let advanced = Double(anchor - pos) / Double(anchor)
                target = 0.08 + 0.47 * min(max(advanced, 0), 1)
            } else {
                target = 0.25
            }
        case .preparing:
            let now = Date()
            if prepareStartedAt == nil { prepareStartedAt = now }
            // seatSetupEta is the server's estimated *remaining* time. Refresh it whenever the
            // server revises the estimate (e.g. 30s → 20s) and count it down between polls so the
            // bar keeps advancing; mapping progress by elapsed / (elapsed + remaining) makes it
            // complete as the estimate approaches zero, matching the official client.
            if let serverEta = createdSession?.seatSetupEta, serverEta != prepareEta {
                prepareEta = serverEta
                prepareEtaAt = now
            }
            let elapsed = prepareStartedAt.map { now.timeIntervalSince($0) } ?? 0
            let liveRemaining: Double = if let eta = prepareEta, let at = prepareEtaAt {
                max(eta - now.timeIntervalSince(at), 0)
            } else {
                max(30 - elapsed, 0)
            }
            let total = max(elapsed + liveRemaining, 4)
            target = 0.55 + 0.41 * min(elapsed / total, 1)
        case .timedOut:
            return
        }
        if target > loadingProgress {
            loadingProgress = min(target, loadingProgress + (target - loadingProgress) * 0.12 + 0.0006)
        }
    }

    // MARK: Streaming

    private var streamingView: some View {
        ZStack {
            VideoSurfaceViewRepresentable(streamController: streamController, showOverlay: showOverlay)
                .ignoresSafeArea()

            if showOverlay {
                pauseMenu
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // Stays visible while the pause menu is open (the menu is a left sidebar)
            // so cycling the Statistics level takes effect on screen immediately.
            // Padding must sit INSIDE the flexible frame: outside it would grow the
            // ZStack beyond the screen and stretch the video underneath.
            if streamController.statsMode != .off {
                StatsHUDView(streamController: streamController)
                    .padding(.top, 60)
                    .padding(.trailing, 60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
        .animation(.easeInOut(duration: 0.2), value: streamController.statsMode)
        .onChange(of: showOverlay) { _, showing in
            // Pause game input while overlay is open in gamepad mode so D-pad
            // navigates overlay buttons instead of moving the in-game character.
            streamController.setInputPaused(showing && streamController.remoteMode != .mouse)
        }
        .alert(L10n.text("end_session_title"), isPresented: $showExitConfirmation) {
            Button(L10n.text("end_session"), role: .destructive) { disconnect() }
            Button(L10n.text("keep_playing"), role: .cancel) {}
        } message: {
            Text(L10n.text("end_session_message"))
        }
    }

    // MARK: Pause Menu

    /// Left sidebar, like the official client's in-game overlay. Stats live in the
    /// StatsHUDView on the right, which stays visible while this menu is open.
    private var pauseMenu: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                toggleOverlay()
            } label: {
                Label(L10n.text("resume"), systemImage: "play.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(.green)

            Button {
                streamController.toggleRemoteMode()
            } label: {
                Label(remoteModeLabel, systemImage: remoteModeIcon)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Button {
                let next = streamController.statsMode.nextHUDLevel
                streamController.setStatsMode(next)
                viewModel.streamSettings.statsMode = next
                viewModel.saveSettings()
            } label: {
                Label(
                    L10n.format("statistics_level", streamController.statsMode.label),
                    systemImage: "chart.bar.xaxis"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Button {
                leave()
            } label: {
                Label(L10n.text("leave_game"), systemImage: "house")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                showExitConfirmation = true
            } label: {
                Label(L10n.text("end_session"), systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(.red)

            Spacer()

            if let sub = viewModel.subscription, !sub.isUnlimited, let rem = sub.remainingMinutes {
                Label {
                    Text(rem >= 60 ? "\(rem / 60)h \(rem % 60)m remaining" : "\(rem)m remaining")
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(rem < 30 ? .orange : .white.opacity(0.8))
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 80)
        .frame(width: 480)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.75))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .ignoresSafeArea()
    }

    private var remoteModeLabel: String {
        L10n.remoteInputModeLabel(streamController.remoteMode)
    }

    private var remoteModeIcon: String {
        switch streamController.remoteMode {
        case .mouse: "cursorarrow"
        case .gamepad: "gamecontroller"
        case .dualsense: "hand.point.up.left"
        }
    }

    // MARK: Time Warning Banner

    private func timeWarningBanner(_ warning: StreamTimeWarning) -> some View {
        let (color, icon, message): (Color, String, String) = {
            let timeText = warning.secondsLeft.map { " (\($0)s left)" } ?? ""
            switch warning.code {
            case 3: return (.red, "clock.badge.xmark", L10n.text("session_ending_soon") + timeText)
            case 2: return (.orange, "clock.badge.exclamationmark", L10n.text("five_minutes_remaining") + timeText)
            default: return (.yellow, "clock", L10n.text("session_limit_approaching") + timeText)
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
            Text(L10n.text("reconnecting"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(hostPrimaryForegroundColor)
            Text(L10n.format("attempt_of", attempt))
                .font(.body)
                .foregroundStyle(.secondary)
            Button(L10n.text("cancel")) { disconnect() }
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
            Text(L10n.text("session_ended"))
                .font(.title.weight(.bold))
                .foregroundStyle(hostPrimaryForegroundColor)
            Text(L10n.text("your_game_session_has_ended"))
                .font(.body)
                .foregroundStyle(.secondary)
            Button(L10n.text("exit")) { disconnect() }
                .buttonStyle(.bordered)
                .tint(.blue)
        }
        .padding(60)
    }

    private func disconnectedView(_ reason: String) -> some View {
        statusView(
            icon: "wifi.slash",
            title: L10n.text("disconnected"),
            message: reason,
            color: .yellow
        )
    }

    private func failedView(_ message: String) -> some View {
        statusView(
            icon: "exclamationmark.triangle",
            title: L10n.text("stream_failed"),
            message: entitlementMessage(from: message),
            color: .red
        )
    }

    private func entitlementMessage(from raw: String) -> String {
        if raw.uppercased().contains("ENTITLEMENT") || raw.contains("3237093650") {
            return L10n.format("not_in_library", game.title)
        }
        if raw.contains("SESSION_LIMIT_EXCEEDED") {
            return L10n.text("previous_session_still_active")
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
                .foregroundStyle(hostPrimaryForegroundColor)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 24) {
                Button(L10n.text("retry")) { Task { await startSession() } }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                Button(L10n.text("exit")) { disconnect() }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        }
        .padding(60)
    }

    @ViewBuilder
    private var hostBackground: some View {
        if colorScheme == .dark {
            Color(white: 29.0 / 255.0)
        } else {
            LinearGradient(
                colors: [
                    Color(white: 0.74),
                    Color(white: 0.68),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.16),
                        .clear,
                    ],
                    center: .top,
                    startRadius: 0,
                    endRadius: 1100
                )
            }
        }
    }

    private var hostPrimaryForegroundColor: Color {
        colorScheme == .dark ? .white : .black
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
                    settings: settings,
                    accountAllowsHDR: viewModel.subscription?.allowsHDR
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
                await streamController.connect(session: sessionInfo, settings: settings, accountAllowsHDR: viewModel.subscription?.allowsHDR)
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
        loadingProgress = 0
        queueAnchor = nil
        prepareStartedAt = nil
        prepareEta = nil
        prepareEtaAt = nil
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
                    settings: settings,
                    accountAllowsHDR: viewModel.subscription?.allowsHDR
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
                            settings: settings,
                            accountAllowsHDR: viewModel.subscription?.allowsHDR
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
                streamLog.info("poll: status=\(sessionInfo.status) seatSetupStep=\(sessionInfo.seatSetupStep ?? -1) queuePosition=\(sessionInfo.queuePosition ?? -1) seatSetupEtaMs=\(sessionInfo.seatSetupEtaMs ?? -1)")
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
            await streamController.connect(session: sessionInfo, settings: settings, accountAllowsHDR: viewModel.subscription?.allowsHDR)
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
                settings: settings,
                accountAllowsHDR: viewModel.subscription?.allowsHDR
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
            accountLinked: true,
            accountAllowsHDR: viewModel.subscription?.allowsHDR
        )

        do {
            let sessionInfo = try await cloudMatchClient.createSession(request)
            print("[Session] created, sessionId=\(sessionInfo.sessionId), status=\(sessionInfo.status)")
            return sessionInfo
        } catch {
            guard shouldForceStopExistingSession(error) else { throw error }

            print("[Session] active session conflict detected for appId=\(appId), stopping matches and retrying once")
            await cloudMatchClient.stopActiveSessions(matchingAppId: appId, token: token, base: routeSelection.base)

            let sessionInfo = try await cloudMatchClient.createSession(request)
            print("[Session] created after conflict cleanup, sessionId=\(sessionInfo.sessionId), status=\(sessionInfo.status)")
            return sessionInfo
        }
    }

    private func shouldForceStopExistingSession(_ error: Error) -> Bool {
        guard case let CloudMatchError.sessionCreateFailed(raw) = error else { return false }
        return raw.contains("SESSION_LIMIT_EXCEEDED_STATUS") || raw.contains("REQUEST_LIMIT_EXCEEDED_STATUS")
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
