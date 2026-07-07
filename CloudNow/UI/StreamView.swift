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
    @Environment(CloudSessionCoordinator.self) private var cloudSessionCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var streamController = GFNStreamController()
    @State private var overlayState: StreamOverlayState = .none
    @State private var showExitConfirmation = false
    @State private var loadingPhase: LoadingPhase = .finding
    @State private var createdSession: SessionInfo?
    @State private var sessionToken: String?
    @State private var sessionAttemptState = SessionAttemptState()
    @State private var sessionOrchestrator: SessionOrchestrator
    @State private var serverSessionLease: CloudServerSessionLease?
    @State private var localPeerLease: CloudLocalPeerLease?
    @State private var isEndingSession = false
    @State private var endConfirmationFailed = false
    @State private var textEntryText = ""
    @FocusState private var textEntryFocused: Bool
    /// Per-ad state tracking to avoid duplicate reports
    @State private var adReportedAction: [String: AdAction] = [:]

    /// Feature badges to show on the loading screen (game supports it AND the client can use it).
    @State private var loadingBadges: [GameFeature] = []

    private let cloudMatchClient: CloudMatchClient

    init(
        game: GameInfo,
        settings: StreamSettings = .init(),
        existingSession: ActiveSessionInfo? = nil,
        directSession: SessionInfo? = nil,
        onDismiss: @escaping () -> Void,
        onLeave: ((GameInfo, SessionInfo) -> Void)? = nil,
        cloudMatchClient: CloudMatchClient = CloudMatchClient(),
        orchestrationClient: (any SessionOrchestrationClient)? = nil,
        sessionScheduler: SessionOrchestrationScheduler = .continuous
    ) {
        self.game = game
        self.settings = settings
        self.existingSession = existingSession
        self.directSession = directSession
        self.onDismiss = onDismiss
        self.onLeave = onLeave
        self.cloudMatchClient = cloudMatchClient
        _sessionOrchestrator = State(initialValue: SessionOrchestrator(
            client: orchestrationClient ?? cloudMatchClient,
            scheduler: sessionScheduler
        ))
    }

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
        .task(id: sessionAttemptState.generation) {
            computeLoadingBadges()
            guard sessionAttemptState.isEnabled else { return }
            let generation = sessionAttemptState.generation
            await startSession(generation: generation)
        }
        .onDisappear {
            cancelSessionAttempt()
            streamController.disconnect()
            releaseLocalPeerLease()
            MemoryLifecycleCoordinator.shared.streamDidClose()
        }
        .onChange(of: streamController.state) { oldState, state in
            if state == .streaming {
                MemoryLifecycleCoordinator.shared.streamDidStart()
            } else if oldState == .streaming {
                MemoryLifecycleCoordinator.shared.streamDidLeavePlayback()
            }
            switch state {
            case .connecting, .streaming, .reconnecting:
                break
            case .idle, .disconnected, .failed, .sessionEnded:
                releaseLocalPeerLease()
            }
        }
        // During streaming, VideoSurfaceView is first responder and intercepts Menu via UIKit,
        // signaling us through menuPressCount. .onExitCommand fires when the focus engine is
        // active: non-streaming states (loading, error) and while the pause menu holds focus —
        // there, B/Menu closes the menu just like Resume.
        .onChange(of: streamController.menuPressCount) { _, _ in
            togglePauseMenu()
        }
        .onChange(of: streamController.textEntryRequestCount) { _, _ in
            presentControllerTextEntry()
        }
        .onExitCommand {
            if overlayState == .textEntry {
                cancelControllerTextEntry()
            } else if overlayState == .pauseMenu {
                closeOverlay()
            } else if streamController.state != .streaming {
                disconnect()
            }
        }
        .onPlayPauseCommand {
            guard streamController.state == .streaming else { return }
            togglePauseMenu()
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
                    StreamLoadingProgressView(
                        phase: loadingPhase,
                        seatSetupEta: createdSession?.seatSetupEta
                    )
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
                        Button(L10n.text("retry")) { retrySessionAttempt() }
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
        if supported.contains(.rtx), tierPremium {
            badges.append(.rtx)
        }
        if supported.contains(.hdr), hdrUsable {
            badges.append(.hdr)
        }
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
        if let urlString = game.heroImageUrl ?? game.heroBannerUrl,
           URL(string: urlString) != nil
        {
            SharedArtworkImage(
                urlString: urlString,
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
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
            if let pos {
                return L10n.format("in_queue_position", pos)
            }
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

    // MARK: Streaming

    private var streamingView: some View {
        VideoSurfaceViewRepresentable(streamController: streamController, showOverlay: overlayState != .none)
            .ignoresSafeArea()
            // The video is a UIViewControllerRepresentable, which (unlike a plain view) can
            // expand to the union of its ZStack siblings' content. A tall Statistics HUD
            // (Standard + Diagnostics) grew the layout and zoomed the video via
            // resizeAspectFill. An overlay is sized to the video and can never grow it, so
            // the HUD/menu/warning live here instead of as ZStack siblings.
            .overlay {
                ZStack {
                    if overlayState == .pauseMenu {
                        pauseMenu
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    if overlayState == .textEntry {
                        controllerTextEntryOverlay
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }

                    // Stays visible while the pause menu is open (the menu is a left sidebar)
                    // so cycling the Statistics level takes effect on screen immediately.
                    if streamController.statsMode != .off {
                        StatsHUDView(
                            streamController: streamController,
                            microphoneEnabled: streamController.microphoneEnabledForConnection,
                            automaticServerId: viewModel.currentVpcId
                        )
                        .fixedSize()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity)
                    }

                    if let warning = streamController.timeWarning, overlayState == .none {
                        timeWarningBanner(warning)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.4), value: streamController.timeWarning)
            .animation(.easeInOut(duration: 0.2), value: overlayState)
            .animation(.easeInOut(duration: 0.2), value: streamController.statsMode)
            .onChange(of: overlayState) { _, state in
                streamController.setOverlayInputPaused(state != .none)
                textEntryFocused = state == .textEntry
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
        CloudStreamPauseMenu(
            statsMode: streamController.statsMode,
            onResume: closeOverlay,
            onCycleStatistics: {
                let next = streamController.statsMode.nextHUDLevel
                streamController.setStatsMode(next)
                viewModel.streamSettings.statsMode = next
                viewModel.saveSettings()
            },
            onLeave: leave,
            onEndRequest: {
                showExitConfirmation = true
            },
            isEndDisabled: isEndingSession,
            providerActions: {
                Button {
                    streamController.toggleRemoteMode()
                } label: {
                    Label(remoteModeLabel, systemImage: remoteModeIcon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            },
            footer: {
                if let sub = viewModel.subscription,
                   !sub.isUnlimited,
                   let rem = sub.remainingMinutes
                {
                    Label {
                        Text(
                            rem >= 60
                                ? "\(rem / 60)h \(rem % 60)m remaining"
                                : "\(rem)m remaining"
                        )
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(
                        rem < 30
                            ? .orange
                            : hostPrimaryForegroundColor.opacity(0.8)
                    )
                }
            }
        )
    }

    private var controllerTextEntryOverlay: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("controller_text_entry_title"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)

            Text(L10n.text("controller_text_entry_instructions"))
                .font(.body)
                .foregroundStyle(.secondary)

            TextField(L10n.text("controller_text_entry_placeholder"), text: $textEntryText)
                .textFieldStyle(.roundedBorder)
                .focused($textEntryFocused)
                .onSubmit {
                    submitControllerTextEntry()
                }

            HStack(spacing: 20) {
                Button(L10n.text("cancel")) {
                    cancelControllerTextEntry()
                }
                .buttonStyle(.bordered)

                Button(L10n.text("controller_text_entry_send")) {
                    submitControllerTextEntry()
                }
                .buttonStyle(.borderedProminent)
                .disabled(textEntryText.isEmpty)
            }
        }
        .frame(maxWidth: 620)
        .padding(32)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
    }

    private var remoteModeLabel: String {
        L10n.remoteInputModeLabel(streamController.remoteMode)
    }

    private var remoteModeIcon: String {
        switch streamController.remoteMode {
        case .gamepad: "gamecontroller"
        case .dualsense: "hand.point.up.left"
        case .gamepadMouse: "cursorarrow.click"
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
            message: friendlyFailureMessage(from: message),
            color: .red
        )
    }

    private func friendlyFailureMessage(from raw: String) -> String {
        let upper = raw.uppercased()
        if upper.contains("ENTITLEMENT") || raw.contains("3237093650") {
            return L10n.format("not_in_library", game.title)
        }
        if upper.contains("SESSION_LIMIT_EXCEEDED") {
            return L10n.text("previous_session_still_active")
        }
        // Never surface the raw JSON body on the failure screen: when the payload carries
        // a CloudMatch status phrase (e.g. "REQUEST_LIMIT_EXCEEDED_STATUS"), show just that.
        if let range = raw.range(of: "\"statusDescription\":\""),
           let end = raw[range.upperBound...].firstIndex(of: "\"")
        {
            let phrase = raw[range.upperBound ..< end].trimmingCharacters(in: .whitespaces)
            if !phrase.isEmpty {
                return phrase
            }
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
                Button(L10n.text("retry")) {
                    if endConfirmationFailed {
                        disconnect()
                    } else {
                        retrySessionAttempt()
                    }
                }
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

    private func retrySessionAttempt() {
        endConfirmationFailed = false
        sessionOrchestrator.cancelAttempt()
        sessionAttemptState.retry()
    }

    private func cancelSessionAttempt() {
        sessionOrchestrator.cancelAttempt()
        sessionAttemptState.cancel()
    }

    private func isCurrentSessionAttempt(_ generation: UInt64) -> Bool {
        sessionAttemptState.accepts(
            generation,
            taskIsCancelled: Task.isCancelled
        )
    }

    private func requireCurrentSessionAttempt(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard sessionAttemptState.accepts(generation) else { throw CancellationError() }
    }

    private func startSession(generation: UInt64) async {
        guard isCurrentSessionAttempt(generation) else { return }
        let orchestrationAttempt = sessionOrchestrator.beginAttempt()
        let settings = settings.normalizedForClient
        streamLog.info("startSession: game=\(game.title), existingSession=\(existingSession != nil), directSession=\(directSession != nil)")
        // Reset stream controller (handles retry from failed/disconnected state)
        streamController.disconnect()
        installReconnectHandler(
            generation: generation,
            orchestrationAttempt: orchestrationAttempt
        )

        // Reconnect path — RESUME PUT tells the server to rebuild its media endpoint,
        // then connect WebRTC as soon as we get a single status 2/3 (no double-poll wait).
        if let direct = directSession {
            streamLog.info("startSession: direct reconnect path, sessionId=\(direct.sessionId)")
            loadingPhase = .preparing
            do {
                let token = try await authManager.resolveToken()
                try requireCurrentSessionAttempt(generation)
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
                try requireCurrentSessionAttempt(generation)
                streamLog.info("startSession: claimed session, status=\(sessionInfo.status)")
                createdSession = sessionInfo
                sessionOrchestrator.adopt(sessionInfo, token: token)
                guard reserveServerSession(
                    sessionInfo,
                    adoptingParkedSession: true
                ) else {
                    await sessionOrchestrator.stopOwnedSession()
                    return
                }

                // A reclaimed media endpoint needs one ready response. Queue waiting remains
                // unbounded; the 60-second deadline begins only after the queue clears.
                sessionInfo = try await sessionOrchestrator.waitUntilReady(
                    initialSession: sessionInfo,
                    token: token,
                    attempt: orchestrationAttempt,
                    requiredReadyResponses: 1,
                    setupTimeout: 60
                ) { session, readiness in
                    applyOrchestrationUpdate(
                        session: session,
                        readiness: readiness,
                        generation: generation
                    )
                }
                try requireCurrentSessionAttempt(generation)

                streamLog.info("startSession: direct path ready, connecting WebRTC")
                viewModel.recordPlayed(game)
                _ = sessionOrchestrator.beginConnection(for: orchestrationAttempt)
                guard attachLocalPeer() else {
                    _ = await stopOwnedSessionAndReleaseLease()
                    return
                }
                await streamController.connect(session: sessionInfo, settings: settings, accountAllowsHDR: viewModel.subscription?.allowsHDR)
                return
            } catch is CancellationError {
                return
            } catch SessionOrchestrationError.setupTimedOut {
                guard isCurrentSessionAttempt(generation) else { return }
                loadingPhase = .timedOut
                return
            } catch {
                guard isCurrentSessionAttempt(generation) else { return }
                // Resume/claim failed — the saved session has almost certainly expired
                // server-side. Drop the stale resume offer and fall through to create a
                // fresh session rather than dead-ending on a raw server error.
                streamLog.error("startSession: direct path failed: \(error, privacy: .private); falling back to a fresh session")
                guard await stopOwnedSessionAndReleaseLease() else {
                    streamController.fail(with: L10n.text("cloud_service_unavailable"))
                    return
                }
                viewModel.resumableSession = nil
                createdSession = nil
            }
        }

        // Stop any previously created server session before opening a new one.
        // Skip for resume — we want to keep the existing session alive.
        if let session = createdSession, sessionToken != nil, existingSession == nil {
            streamLog.info("startSession: stopping previous session \(session.sessionId)")
            let didStop = await sessionOrchestrator.stopOwnedSession()
            guard isCurrentSessionAttempt(generation) else { return }
            guard didStop else {
                streamController.fail(with: L10n.text("cloud_service_unavailable"))
                return
            }
            endSessionLease()
        }
        createdSession = nil
        loadingPhase = .finding
        do {
            let token = try await authManager.resolveToken()
            try requireCurrentSessionAttempt(generation)
            streamLog.info("startSession: token resolved")
            sessionToken = token
            let provider = authManager.session?.provider
            let streamingBaseUrl = provider?.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
            let base = streamingBaseUrl.hasSuffix("/") ? String(streamingBaseUrl.dropLast()) : streamingBaseUrl
            streamLog.info("startSession: base=\(base)")

            var sessionInfo: SessionInfo
            var isContinuingExistingSession = false

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
                try requireCurrentSessionAttempt(generation)
                streamLog.info("startSession: claimed, status=\(sessionInfo.status)")
                sessionOrchestrator.adopt(sessionInfo, token: token)
                isContinuingExistingSession = true
            } else {
                // New session path
                guard let appId = game.variants.first?.appId ?? game.variants.first?.id else {
                    streamLog.error("startSession: no appId found for game")
                    return
                }

                // Check for a locally saved session for this game — resume instead of creating new.
                if let last = viewModel.lastSession, last.appId == appId {
                    streamLog.info("[Resume] found saved session \(last.sessionId, privacy: .private) for appId=\(appId, privacy: .public), trying resume")
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
                        try requireCurrentSessionAttempt(generation)
                        streamLog.info("[Resume] claimed session, status=\(sessionInfo.status, privacy: .public)")
                        createdSession = sessionInfo
                        sessionOrchestrator.adopt(sessionInfo, token: token)
                        isContinuingExistingSession = true
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try requireCurrentSessionAttempt(generation)
                        streamLog.warning("[Resume] claim failed: \(error, privacy: .private), stopping old session and creating new")
                        guard await stopSavedSession(last, token: token) else { return }
                        try requireCurrentSessionAttempt(generation)
                        viewModel.clearLastSession()
                        // Fall through to create new session below
                        sessionInfo = try await createNewSession(
                            appId: appId,
                            token: token,
                            base: base,
                            generation: generation,
                            orchestrationAttempt: orchestrationAttempt
                        )
                    }
                } else {
                    if let last = viewModel.lastSession {
                        streamLog.info("[Resume] saved session appId=\(last.appId, privacy: .public) != game appId=\(appId, privacy: .public), stopping it")
                        guard await stopSavedSession(last, token: token) else { return }
                        try requireCurrentSessionAttempt(generation)
                        viewModel.clearLastSession()
                    }
                    sessionInfo = try await createNewSession(
                        appId: appId,
                        token: token,
                        base: base,
                        generation: generation,
                        orchestrationAttempt: orchestrationAttempt
                    )
                }
            }
            createdSession = sessionInfo
            guard reserveServerSession(
                sessionInfo,
                adoptingParkedSession: isContinuingExistingSession
            ) else {
                await sessionOrchestrator.stopOwnedSession()
                return
            }

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
                    createdAt: Date(),
                    idpId: authManager.session?.provider.idpId ?? NVIDIAAuth.defaultIdpId,
                    userId: authManager.session?.user.userId
                ))
            }

            // Queue waiting is deliberately unbounded. Setup receives a monotonic
            // 180-second deadline only after the queue clears, and readiness must
            // be observed twice consecutively.
            sessionInfo = try await sessionOrchestrator.waitUntilReady(
                initialSession: sessionInfo,
                token: token,
                attempt: orchestrationAttempt
            ) { session, readiness in
                applyOrchestrationUpdate(
                    session: session,
                    readiness: readiness,
                    generation: generation
                )
            }
            try requireCurrentSessionAttempt(generation)

            streamLog.info("startSession: queue cleared after confirmed ready responses, connecting WebRTC")
            streamLog.info("startSession: serverIp=\(sessionInfo.serverIp), signalingUrl=\(sessionInfo.signalingUrl)")
            viewModel.recordPlayed(game)
            _ = sessionOrchestrator.beginConnection(for: orchestrationAttempt)
            guard attachLocalPeer() else {
                _ = await stopOwnedSessionAndReleaseLease()
                return
            }
            await streamController.connect(session: sessionInfo, settings: settings, accountAllowsHDR: viewModel.subscription?.allowsHDR)
        } catch is CancellationError {
            return
        } catch SessionOrchestrationError.setupTimedOut {
            guard isCurrentSessionAttempt(generation) else { return }
            loadingPhase = .timedOut
        } catch {
            guard isCurrentSessionAttempt(generation) else { return }
            streamLog.error("startSession: FAILED: \(error)")
            streamController.fail(with: error.localizedDescription)
        }
    }

    private func applyOrchestrationUpdate(
        session: SessionInfo,
        readiness: SessionReadinessState?,
        generation: UInt64
    ) {
        guard isCurrentSessionAttempt(generation) else { return }
        createdSession = session
        guard let readiness else { return }
        switch readiness {
        case let .inQueue(position):
            loadingPhase = .inQueue(position)
        case .preparing:
            loadingPhase = .preparing
        case .ready:
            break
        case .timedOut:
            loadingPhase = .timedOut
        }
    }

    private func installReconnectHandler(
        generation: UInt64,
        orchestrationAttempt: SessionAttemptToken
    ) {
        let createdSession = $createdSession
        let sessionToken = $sessionToken
        let sessionAttemptState = $sessionAttemptState
        let client = cloudMatchClient
        let orchestrator = sessionOrchestrator
        let appId = game.variants.first?.appId ?? game.variants.first?.id
        let reconnectSettings = settings.normalizedForClient
        let accountAllowsHDR = viewModel.subscription?.allowsHDR

        // Capture only the reconnect inputs. Capturing StreamView here also captures its
        // @State-held controller, creating controller -> callback -> controller ownership.
        streamController.onReconnectNeeded = {
            guard !Task.isCancelled,
                  sessionAttemptState.wrappedValue.accepts(generation),
                  orchestrator.acceptsAttempt(orchestrationAttempt),
                  let connection = orchestrator.beginConnection(for: orchestrationAttempt),
                  let session = createdSession.wrappedValue,
                  let token = sessionToken.wrappedValue else { return nil }
            streamLog.info("reclaimSession: attempting to reclaim \(session.sessionId)")
            do {
                let reclaimed = try await client.claimSession(
                    sessionId: session.sessionId,
                    serverIp: session.serverIp,
                    token: token,
                    base: session.streamingBaseUrl,
                    routingZoneUrl: session.zone,
                    clientId: session.clientId,
                    deviceId: session.deviceId,
                    appId: appId,
                    settings: reconnectSettings,
                    accountAllowsHDR: accountAllowsHDR
                )
                guard !Task.isCancelled,
                      sessionAttemptState.wrappedValue.accepts(generation),
                      orchestrator.acceptsConnectionCallback(connection) else { return nil }
                createdSession.wrappedValue = reclaimed
                orchestrator.adopt(reclaimed, token: token)
                streamLog.info("reclaimSession: success, status=\(reclaimed.status)")
                return reclaimed
            } catch is CancellationError {
                return nil
            } catch {
                guard sessionAttemptState.wrappedValue.accepts(generation),
                      orchestrator.acceptsConnectionCallback(connection) else { return nil }
                streamLog.error("reclaimSession: failed: \(error)")
                return nil
            }
        }
    }

    /// Leaves the stream locally without stopping the server session.
    /// GFN keeps the session alive for ~1–2 minutes so it can be resumed from home.
    private func leave() {
        overlayState = .none
        if let session = createdSession {
            onLeave?(game, session)
        }
        if let serverSessionLease {
            cloudSessionCoordinator.parkServerSession(
                serverSessionLease,
                expiresAt: Date().addingTimeInterval(
                    ResumableSession.gracePeriod
                )
            )
        }
        releaseLocalPeerLease()
        sessionOrchestrator.detachOwnedSession()
        cancelSessionAttempt()
        streamController.disconnect()
        onDismiss()
    }

    private func disconnect() {
        overlayState = .none
        guard !isEndingSession else { return }
        isEndingSession = true
        endConfirmationFailed = false
        cancelSessionAttempt()
        let shouldRefreshActiveSessions = createdSession != nil
        let lease = serverSessionLease
        Task {
            let didEnd: Bool = if let lease {
                await cloudSessionCoordinator
                    .endServerSessionUsingProvider(lease)
            } else {
                await sessionOrchestrator.teardown()
            }
            guard didEnd else {
                isEndingSession = false
                endConfirmationFailed = true
                streamController.disconnect()
                streamController.fail(
                    with: L10n.text("cloud_service_unavailable")
                )
                return
            }

            // Clear resumable metadata only after the service confirms End.
            viewModel.resumableSession = nil
            viewModel.clearLastSession()
            if let session = createdSession {
                viewModel.markSessionStopped(session.sessionId)
            }
            serverSessionLease = nil
            streamController.disconnect()
            releaseLocalPeerLease()
            if shouldRefreshActiveSessions {
                // Converge to server truth once the stop has actually landed
                // (the grace window still excludes the stopped id).
                await viewModel.refreshActiveSessions(authManager: authManager)
            }
            onDismiss()
        }
    }

    private func reserveServerSession(
        _ session: SessionInfo,
        adoptingParkedSession: Bool
    ) -> Bool {
        if let serverSessionLease,
           let current = cloudSessionCoordinator.serverSession,
           current.id == serverSessionLease.id,
           current.provider == .geForceNow,
           current.serverSessionID == session.sessionId
        {
            return true
        }
        guard sessionToken != nil,
              let stopHandle = sessionOrchestrator.stopHandle(for: session.sessionId)
        else {
            streamController.fail(with: L10n.text("cloud_session_in_use"))
            return false
        }
        do {
            let actions = CloudServerSessionActions(
                end: { [sessionOrchestrator, stopHandle] in
                    await sessionOrchestrator.stopSession(using: stopHandle)
                }
            )
            if adoptingParkedSession,
               cloudSessionCoordinator.serverSession != nil
            {
                serverSessionLease = try cloudSessionCoordinator
                    .adoptParkedServerSession(
                        provider: .geForceNow,
                        serverSessionID: session.sessionId,
                        actions: actions
                    )
            } else {
                serverSessionLease = try cloudSessionCoordinator
                    .reserveServerSession(
                        provider: .geForceNow,
                        serverSessionID: session.sessionId,
                        actions: actions
                    )
            }
            return true
        } catch {
            streamController.fail(with: L10n.text("cloud_session_in_use"))
            return false
        }
    }

    private func attachLocalPeer() -> Bool {
        if localPeerLease != nil {
            return true
        }
        do {
            localPeerLease = try cloudSessionCoordinator.attachLocalPeer(
                for: .geForceNow
            )
            return true
        } catch {
            streamController.fail(with: L10n.text("cloud_session_in_use"))
            return false
        }
    }

    private func endSessionLease() {
        guard let serverSessionLease else { return }
        cloudSessionCoordinator.endServerSession(serverSessionLease)
        self.serverSessionLease = nil
        releaseLocalPeerLease()
    }

    private func releaseLocalPeerLease() {
        guard let localPeerLease else { return }
        cloudSessionCoordinator.releaseLocalPeer(localPeerLease)
        self.localPeerLease = nil
    }

    private func stopOwnedSessionAndReleaseLease() async -> Bool {
        let didStop = await sessionOrchestrator.stopOwnedSession()
        if didStop {
            endSessionLease()
        }
        return didStop
    }

    private func stopSavedSession(
        _ session: LastSessionRecord,
        token: String
    ) async -> Bool {
        sessionOrchestrator.adoptStopTarget(
            sessionID: session.sessionId,
            token: token,
            base: session.base,
            serverIP: session.serverIp.isEmpty ? nil : session.serverIp,
            clientID: session.clientId,
            deviceID: session.deviceId
        )
        guard await sessionOrchestrator.stopOwnedSession() else {
            streamController.fail(with: L10n.text("cloud_service_unavailable"))
            return false
        }
        return true
    }

    private func createNewSession(
        appId: String,
        token: String,
        base: String,
        generation: UInt64,
        orchestrationAttempt: SessionAttemptToken
    ) async throws -> SessionInfo {
        try requireCurrentSessionAttempt(generation)
        let isNvidiaProvider = authManager.session?.provider.isNvidiaDirect ?? true
        let routeSelection: (base: String, routingZoneUrl: String?) = if isNvidiaProvider {
            switch settings.serverRoutingMode {
            case .region:
                settings.preferredRegionAddress.map { ($0, $0) } ?? (base, nil)
            case .client:
                settings.preferredZoneUrl.map { ($0, $0) } ?? (base, nil)
            case .serverAuto:
                // Official-client behavior: the default endpoint routes the session server-side.
                (base, nil)
            }
        } else {
            // Partner providers manage their own routing; skip NVIDIA zone/region selection.
            (base, nil)
        }
        streamLog.info("[Session] creating new session, appId=\(appId, privacy: .public), sessionBase=\(routeSelection.base, privacy: .public), routingZoneUrl=\(routeSelection.routingZoneUrl ?? "nil", privacy: .public)")

        let request = SessionCreateRequest(
            appId: appId,
            internalTitle: game.title,
            token: token,
            streamingBaseUrl: routeSelection.base,
            routingZoneUrl: routeSelection.routingZoneUrl,
            settings: settings,
            localVideoCapabilities: LocalVideoCapabilities.detect(codec: settings.codec),
            accountLinked: true,
            accountAllowsHDR: viewModel.subscription?.allowsHDR,
            skipNvidiaFallback: !isNvidiaProvider
        )

        do {
            let sessionInfo = try await sessionOrchestrator.createSession(
                request,
                attempt: orchestrationAttempt
            ) { session, readiness in
                applyOrchestrationUpdate(
                    session: session,
                    readiness: readiness,
                    generation: generation
                )
            }
            try requireCurrentSessionAttempt(generation)
            streamLog.info("[Session] created, sessionId=\(sessionInfo.sessionId, privacy: .private), status=\(sessionInfo.status, privacy: .public)")
            return sessionInfo
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try requireCurrentSessionAttempt(generation)
            guard shouldForceStopExistingSession(error) else { throw error }

            streamLog.warning("[Session] active session conflict detected for appId=\(appId, privacy: .public), stopping matches and retrying once")
            await cloudMatchClient.stopActiveSessions(matchingAppId: appId, token: token, base: routeSelection.base)
            try requireCurrentSessionAttempt(generation)

            let sessionInfo = try await sessionOrchestrator.createSession(
                request,
                attempt: orchestrationAttempt
            ) { session, readiness in
                applyOrchestrationUpdate(
                    session: session,
                    readiness: readiness,
                    generation: generation
                )
            }
            try requireCurrentSessionAttempt(generation)
            streamLog.info("[Session] created after conflict cleanup, sessionId=\(sessionInfo.sessionId, privacy: .private), status=\(sessionInfo.status, privacy: .public)")
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

    private func togglePauseMenu() {
        guard overlayState != .textEntry else { return }
        overlayState = overlayState == .pauseMenu ? .none : .pauseMenu
    }

    private func closeOverlay() {
        overlayState = .none
    }

    private func presentControllerTextEntry() {
        guard streamController.state == .streaming, overlayState == .none else { return }
        textEntryText = ""
        overlayState = .textEntry
    }

    private func cancelControllerTextEntry() {
        overlayState = .none
        textEntryText = ""
        streamController.cancelControllerTextEntry()
    }

    private func submitControllerTextEntry() {
        let text = textEntryText
        overlayState = .none
        textEntryText = ""
        streamController.submitControllerTextEntry(text)
    }
}

/// Owns the 10 Hz loading clock so progress updates invalidate only this small
/// bar, not the complete stream/session view hierarchy.
private struct StreamLoadingProgressView: View {
    let phase: LoadingPhase
    let seatSetupEta: TimeInterval?

    @State private var progress: Double = 0
    @State private var lifecycle = StreamLoadingProgressLifecycle()

    var body: some View {
        ProgressView(value: progress)
            .task(id: TickInput(phase: phase, seatSetupEta: seatSetupEta)) {
                while !Task.isCancelled {
                    advance(at: Date())
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                    } catch {
                        return
                    }
                }
            }
    }

    /// Eases toward a phase-derived target and never moves backwards.
    private func advance(at now: Date) {
        let target: Double
        switch phase {
        case .finding:
            lifecycle.prepareStartedAt = nil
            target = 0.06
        case let .inQueue(position):
            lifecycle.prepareStartedAt = nil
            if let position {
                lifecycle.queueAnchor = max(lifecycle.queueAnchor ?? position, position)
                let anchor = max(lifecycle.queueAnchor ?? position, 1)
                let advanced = Double(anchor - position) / Double(anchor)
                target = 0.08 + 0.47 * min(max(advanced, 0), 1)
            } else {
                target = 0.25
            }
        case .preparing:
            if lifecycle.prepareStartedAt == nil {
                lifecycle.prepareStartedAt = now
            }
            if let seatSetupEta, seatSetupEta != lifecycle.prepareEta {
                lifecycle.prepareEta = seatSetupEta
                lifecycle.prepareEtaAt = now
            }
            let elapsed = lifecycle.prepareStartedAt.map { now.timeIntervalSince($0) } ?? 0
            let liveRemaining: Double = if let prepareEta = lifecycle.prepareEta,
                                           let prepareEtaAt = lifecycle.prepareEtaAt
            {
                max(prepareEta - now.timeIntervalSince(prepareEtaAt), 0)
            } else {
                max(30 - elapsed, 0)
            }
            let total = max(elapsed + liveRemaining, 4)
            target = 0.55 + 0.41 * min(elapsed / total, 1)
        case .timedOut:
            return
        }

        guard target > progress else { return }
        let nextProgress = min(
            target,
            progress + (target - progress) * 0.12 + 0.0006
        )
        guard nextProgress != progress else { return }
        progress = nextProgress
    }

    private struct TickInput: Equatable {
        let phase: LoadingPhase
        let seatSetupEta: TimeInterval?
    }
}

/// Non-rendered loading bookkeeping stays outside SwiftUI observation so the
/// 10 Hz clock only invalidates this view when the visible progress changes.
@MainActor
private final class StreamLoadingProgressLifecycle {
    var queueAnchor: Int?
    var prepareStartedAt: Date?
    var prepareEta: TimeInterval?
    var prepareEtaAt: Date?
}
