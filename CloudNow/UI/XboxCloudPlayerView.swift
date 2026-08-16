import Foundation
import SwiftUI

nonisolated enum XboxCloudBackgroundSessionAction: Equatable, Sendable {
    case leave
    case end
}

nonisolated enum XboxCloudBackgroundSessionPolicy {
    static func action(canLeaveSession: Bool) -> XboxCloudBackgroundSessionAction {
        canLeaveSession ? .leave : .end
    }
}

/// Xbox-only player chrome around CloudNow's native video surface. Session,
/// signaling, input, and WebRTC state stay below this coarse observable seam.
struct XboxCloudPlayerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(CloudSessionCoordinator.self) private var cloudSessionCoordinator
    let item: XboxCatalogItem
    let route: XboxCloudTitleRoute
    let account: XboxCloudAuthorizedAccount
    let settings: XboxCloudStreamSettings
    let controller: XboxCloudStreamController
    let continuesExistingSession: Bool
    let onStreamStarted: () -> Void
    let onStatsModeChanged: (StreamStatsMode) -> Void
    let onDismiss: () -> Void

    @State private var showsOverlay = false
    @State private var showExitConfirmation = false
    @State private var launchAttempt: UInt64 = 0
    @State private var isEnding = false
    @State private var hasRecordedPlayback = false
    @State private var serverSessionLease: CloudServerSessionLease?
    @State private var localPeerLease: CloudLocalPeerLease?
    @State private var localFailureMessage: String?
    @State private var endConfirmationFailed = false
    @State private var didLeaveSession = false

    var body: some View {
        ZStack {
            launchBackdrop

            if controller.state == .streaming {
                streamingView
            } else {
                launchStatus
            }
        }
        .background(.black)
        .ignoresSafeArea()
        .task(id: launchAttempt) {
            localFailureMessage = nil
            endConfirmationFailed = false
            guard acquireServerSessionLease() else {
                localFailureMessage = L10n.text("cloud_session_in_use")
                return
            }
            do {
                if continuesExistingSession {
                    try await controller.continueSession()
                } else {
                    try await controller.start(
                        // Xbox represents the access lane in the title route. Its play
                        // request has no separate free-with-ads or ad-receipt parameter.
                        gameID: route.titleID,
                        account: account,
                        locale: settings.effectiveGameLanguage(
                            defaultLocale: L10n.localeCode
                        ),
                        settings: settings,
                        onSessionCreated: { sessionID in
                            try bindServerSession(to: sessionID)
                        }
                    )
                }
            } catch is CancellationError {
                await restoreCoordinatorAfterLaunchFailure()
                return
            } catch {
                await restoreCoordinatorAfterLaunchFailure()
                return
            }
        }
        .onChange(of: controller.state) { previousState, state in
            if state == .streaming {
                showsOverlay = false
                controller.setInputPaused(false)
                MemoryLifecycleCoordinator.shared.streamDidStart()
                if !hasRecordedPlayback {
                    hasRecordedPlayback = true
                    onStreamStarted()
                }
            } else if previousState == .streaming {
                MemoryLifecycleCoordinator.shared.streamDidLeavePlayback()
            }
            switch state {
            case .connecting, .streaming, .reconnecting:
                if !attachLocalPeer() {
                    endSession()
                }
            case .failed:
                if !controller.canContinueSession,
                   !controller.hasUnconfirmedSessionDeletion
                {
                    endSessionLease()
                }
            case .idle, .requestingAccess, .allocating, .waiting,
                 .provisioning, .stopping:
                releaseLocalPeerLease()
            }
        }
        .onChange(of: controller.menuPressCount) { _, _ in
            toggleOverlay()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            switch XboxCloudBackgroundSessionPolicy.action(
                canLeaveSession: controller.canLeaveSession
            ) {
            case .leave:
                leaveSession()
            case .end:
                endSession()
            }
        }
        .onExitCommand {
            if controller.state == .streaming {
                toggleOverlay()
            } else {
                endSession()
            }
        }
        .onPlayPauseCommand {
            guard controller.state == .streaming else { return }
            toggleOverlay()
        }
        .onDisappear {
            controller.setInputPaused(false)
            MemoryLifecycleCoordinator.shared.streamDidClose()
            guard !didLeaveSession, !controller.canContinueSession else {
                releaseLocalPeerLease()
                return
            }
            Task {
                _ = await endSessionUsingProvider()
            }
        }
    }

    private var launchBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.015, green: 0.05, blue: 0.035),
                    .black,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 420, weight: .ultraLight))
                .foregroundStyle(.green.opacity(0.07))
                .accessibilityHidden(true)
        }
    }

    private var launchStatus: some View {
        VStack(spacing: 26) {
            Image(systemName: statusSymbol)
                .font(.system(size: 68, weight: .semibold))
                .foregroundStyle(statusTint)
                .accessibilityHidden(true)

            Text(item.title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            if route.accessKind == .freeWithAds {
                Label(
                    L10n.text("free_with_ads"),
                    systemImage: "play.rectangle.on.rectangle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            }

            if showsProgress {
                ProgressView()
                    .controlSize(.large)
                    .tint(.green)
            }

            Text(statusTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(stateAccessibilityIdentifier)

            if let statusDetail {
                Text(statusDetail)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if let failureMessage {
                Text(failureMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)

                HStack(spacing: 24) {
                    Button(L10n.text("try_again")) {
                        if endConfirmationFailed {
                            endSession()
                        } else {
                            launchAttempt &+= 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .accessibilityIdentifier("xbox-stream.retry")

                    Button(L10n.text("cancel"), action: endSession)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("xbox-stream.cancel")
                }
            } else {
                Button(L10n.text("cancel"), action: endSession)
                    .buttonStyle(.bordered)
                    .disabled(isEnding || controller.state == .stopping)
                    .accessibilityIdentifier("xbox-stream.cancel")
            }
        }
        .padding(80)
    }

    private var streamingView: some View {
        XboxVideoSurfaceView(
            videoTrack: controller.videoTrack,
            showsOverlay: showsOverlay,
            onMenuPress: toggleOverlay,
            onKeyboardEvent: { isPressed, virtualKey in
                controller.sendKeyboardEvent(
                    isPressed: isPressed,
                    virtualKey: virtualKey
                )
            },
            onDecodedVideoFormatChanged: { format in
                Task { @MainActor in
                    controller.recordDecodedVideoFormat(format)
                }
            }
        )
        .ignoresSafeArea()
        .overlay {
            ZStack {
                if showsOverlay {
                    pauseMenu
                        .transition(pauseMenuTransition)
                }

                if controller.statsMode != .off {
                    StatsHUDView(snapshot: statsSnapshot)
                        .fixedSize()
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topTrailing
                        )
                        .transition(statsHUDTransition)
                }
            }
        }
        .animation(overlayAnimation, value: showsOverlay)
        .animation(overlayAnimation, value: controller.statsMode)
        .onChange(of: showsOverlay) { _, showing in
            controller.setInputPaused(showing)
        }
        .alert(L10n.text("end_session_title"), isPresented: $showExitConfirmation) {
            Button(L10n.text("end_session"), role: .destructive) { endSession() }
            Button(L10n.text("keep_playing"), role: .cancel) {}
        } message: {
            Text(L10n.text("end_session_message"))
        }
    }

    private var pauseMenu: some View {
        CloudStreamPauseMenu(
            statsMode: controller.statsMode,
            onResume: toggleOverlay,
            onCycleStatistics: {
                let next = controller.statsMode.nextHUDLevel
                controller.setStatsMode(next)
                onStatsModeChanged(next)
            },
            onLeave: leaveSession,
            onEndRequest: {
                showExitConfirmation = true
            },
            isEndDisabled: isEnding,
            accessibilityPrefix: "xbox-stream",
            providerActions: { EmptyView() },
            footer: { EmptyView() }
        )
    }

    private var statsSnapshot: StatsHUDSnapshot {
        let location = controller.serverLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        return StatsHUDSnapshot(
            mode: controller.statsMode,
            stats: controller.stats,
            audioStats: controller.audioStats,
            colorState: controller.colorState,
            streamingStartedAt: controller.streamingStartedAt,
            microphoneEnabled: controller.microphoneEnabledForConnection,
            headerTitle: L10n.text("app_name"),
            serverLocation: location.isEmpty ? L10n.text("unknown") : location,
            diagnosticsEnabled: controller.diagnosticsEnabled,
            rtcEventLogActive: controller.rtcEventLogActive,
            qualityRequest: StatsHUDQualityRequest(
                resolution: requestedResolutionLabel,
                bandwidth: requestedBandwidthLabel
            )
        )
    }

    private var requestedResolutionLabel: String {
        let resolution = activeStreamSettings.displayResolution
        return [resolution.label, resolution.badge]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private var requestedBandwidthLabel: String? {
        guard XboxCloudQualityBetaPolicy
            .currentBuildAllowsBandwidthPreference
        else {
            return nil
        }
        guard let maximumBitrateKbps = activeStreamSettings.bandwidthPreference
            .maximumRequestedBitrateKbps
        else {
            return "\(L10n.text("automatic")) · ∞"
        }
        return "\(maximumBitrateKbps / 1000) Mbps"
    }

    private var activeStreamSettings: XboxCloudStreamSettings {
        controller.activeStreamSettings ?? settings.normalizedForClient
    }

    private var statusTitle: String {
        if isEnding {
            return L10n.text("ending_session")
        }
        if localFailureMessage != nil {
            return L10n.text("disconnected")
        }
        return switch controller.state {
        case .idle:
            L10n.format("starting_game", item.title)
        case .requestingAccess:
            L10n.format("starting_game", item.title)
        case .allocating:
            L10n.format("starting_game", item.title)
        case .waiting:
            L10n.text("in_queue")
        case .provisioning:
            L10n.text("preparing_game")
        case .connecting:
            L10n.text("connecting_to_server")
        case .streaming:
            L10n.text("live")
        case .reconnecting:
            L10n.text("reconnecting")
        case .stopping:
            L10n.text("ending_session")
        case .failed:
            L10n.text("disconnected")
        }
    }

    private var statusSymbol: String {
        if localFailureMessage != nil {
            return "exclamationmark.triangle.fill"
        }
        return switch controller.state {
        case .failed:
            "exclamationmark.triangle.fill"
        case .stopping:
            "xmark.circle.fill"
        default:
            "gamecontroller.fill"
        }
    }

    private var statusDetail: String? {
        if case let .reconnecting(attempt, maximumAttempts, nextDelay) = controller.state {
            let attemptText = L10n.format(
                "reconnecting_attempt_note",
                attempt
            )
            guard let nextDelay else { return attemptText }
            return "\(attemptText) · \(Int(nextDelay.rounded(.up)))s / \(maximumAttempts)"
        }
        let estimatedSeconds: TimeInterval? = switch controller.state {
        case let .waiting(estimatedSeconds),
             let .provisioning(estimatedSeconds):
            estimatedSeconds
        default:
            nil
        }
        guard let estimatedSeconds,
              estimatedSeconds.isFinite,
              estimatedSeconds > 0
        else {
            return nil
        }
        return L10n.format(
            "xbox_estimated_wait",
            Int(estimatedSeconds.rounded(.up))
        )
    }

    private var statusTint: Color {
        if localFailureMessage != nil {
            return .orange
        }
        return switch controller.state {
        case .failed:
            .orange
        case .stopping:
            .red
        default:
            .green
        }
    }

    private var showsProgress: Bool {
        if localFailureMessage != nil {
            return false
        }
        return switch controller.state {
        case .idle, .requestingAccess, .allocating, .waiting, .provisioning,
             .connecting, .reconnecting, .stopping:
            true
        case .streaming, .failed:
            false
        }
    }

    private var stateAccessibilityIdentifier: String {
        if localFailureMessage != nil {
            return "xbox-stream-state.failed"
        }
        let stateName = switch controller.state {
        case .idle:
            "idle"
        case .requestingAccess:
            "requesting-access"
        case .allocating:
            "allocating"
        case .waiting:
            "waiting"
        case .provisioning:
            "provisioning"
        case .connecting:
            "connecting"
        case .streaming:
            "streaming"
        case .reconnecting:
            "reconnecting"
        case .stopping:
            "stopping"
        case .failed:
            "failed"
        }
        return "xbox-stream-state.\(stateName)"
    }

    private func toggleOverlay() {
        guard controller.state == .streaming else { return }
        guard !accessibilityReduceMotion else {
            showsOverlay.toggle()
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            showsOverlay.toggle()
        }
    }

    private var overlayAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    private var pauseMenuTransition: AnyTransition {
        accessibilityReduceMotion
            ? .identity
            : .move(edge: .leading).combined(with: .opacity)
    }

    private var statsHUDTransition: AnyTransition {
        accessibilityReduceMotion ? .identity : .opacity
    }

    private func endSession() {
        guard !isEnding else { return }
        isEnding = true
        endConfirmationFailed = false
        controller.setInputPaused(false)
        Task {
            guard await endSessionUsingProvider() else {
                localFailureMessage = L10n.text("cloud_service_unavailable")
                endConfirmationFailed = true
                isEnding = false
                return
            }
            onDismiss()
        }
    }

    private var failureMessage: String? {
        if let localFailureMessage {
            return localFailureMessage
        }
        guard case let .failed(message) = controller.state else { return nil }
        #if DEBUG
            return message
        #else
            return L10n.text("cloud_service_unavailable")
        #endif
    }

    private func leaveSession() {
        guard controller.canLeaveSession,
              let serverSessionLease
        else {
            return
        }
        controller.leaveForBackground()
        guard let expiresAt = controller.resumableSessionExpiresAt else {
            endSession()
            return
        }
        cloudSessionCoordinator.parkServerSession(
            serverSessionLease,
            expiresAt: expiresAt
        )
        releaseLocalPeerLease()
        didLeaveSession = true
        onDismiss()
    }

    private func acquireServerSessionLease() -> Bool {
        if serverSessionLease != nil {
            return true
        }
        do {
            let actions = CloudServerSessionActions(
                leave: { [controller] in
                    controller.leave()
                    return controller.resumableSessionExpiresAt
                },
                end: { [controller] in
                    await controller.endSession()
                }
            )
            if continuesExistingSession {
                guard let sessionID = controller.coordinatorServerSessionID else {
                    return false
                }
                serverSessionLease = try cloudSessionCoordinator
                    .adoptParkedServerSession(
                        provider: .xboxCloudGaming,
                        serverSessionID: sessionID,
                        actions: actions
                    )
            } else {
                serverSessionLease = try cloudSessionCoordinator
                    .reserveServerSession(
                        provider: .xboxCloudGaming,
                        serverSessionID: "\(account.activityScopeIdentifier):\(route.titleID)",
                        actions: actions
                    )
            }
            return true
        } catch {
            return false
        }
    }

    private func bindServerSession(to sessionID: String) throws {
        guard let serverSessionLease else {
            throw CloudSessionConflict.serverSessionLeaseNotOwned
        }
        self.serverSessionLease = try cloudSessionCoordinator.bindServerSession(
            serverSessionLease,
            to: sessionID
        )
    }

    private func attachLocalPeer() -> Bool {
        if localPeerLease != nil {
            return true
        }
        do {
            localPeerLease = try cloudSessionCoordinator.attachLocalPeer(
                for: .xboxCloudGaming
            )
            return true
        } catch {
            return false
        }
    }

    private func releaseLocalPeerLease() {
        guard let localPeerLease else { return }
        cloudSessionCoordinator.releaseLocalPeer(localPeerLease)
        self.localPeerLease = nil
    }

    private func restoreCoordinatorAfterLaunchFailure() async {
        guard controller.canContinueSession,
              let serverSessionLease,
              let expiresAt = controller.resumableSessionExpiresAt
        else {
            if !controller.hasUnconfirmedSessionDeletion {
                endSessionLease()
            }
            return
        }
        cloudSessionCoordinator.parkServerSession(
            serverSessionLease,
            expiresAt: expiresAt
        )
        releaseLocalPeerLease()
    }

    private func endSessionUsingProvider() async -> Bool {
        guard let serverSessionLease else {
            return await controller.endSession()
        }
        let didEnd = await cloudSessionCoordinator
            .endServerSessionUsingProvider(serverSessionLease)
        if didEnd {
            self.serverSessionLease = nil
            releaseLocalPeerLease()
        }
        return didEnd
    }

    private func endSessionLease() {
        guard let serverSessionLease else { return }
        cloudSessionCoordinator.endServerSession(serverSessionLease)
        self.serverSessionLease = nil
        releaseLocalPeerLease()
    }
}
