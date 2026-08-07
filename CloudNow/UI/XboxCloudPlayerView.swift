import Foundation
import SwiftUI

/// Xbox-only player chrome around CloudNow's native video surface. Session,
/// signaling, input, and WebRTC state stay below this coarse observable seam.
struct XboxCloudPlayerView: View {
    @Environment(\.scenePhase) private var scenePhase
    let item: XboxCatalogItem
    let route: XboxCloudTitleRoute
    let account: XboxCloudAuthorizedAccount
    let settings: XboxCloudStreamSettings
    let controller: XboxCloudStreamController
    let onStreamStarted: () -> Void
    let onDismiss: () -> Void

    @State private var showsOverlay = true
    @State private var launchAttempt: UInt64 = 0
    @State private var isEnding = false
    @State private var hasRecordedPlayback = false

    var body: some View {
        ZStack {
            launchBackdrop

            if controller.state == .streaming {
                XboxVideoSurfaceView(
                    videoTrack: controller.videoTrack,
                    showsOverlay: showsOverlay,
                    onMenuPress: toggleOverlay
                )
                .ignoresSafeArea()

                if showsOverlay {
                    playerOverlay
                }
            } else {
                launchStatus
            }
        }
        .background(.black)
        .ignoresSafeArea()
        .task(id: launchAttempt) {
            do {
                try await controller.start(
                    // Xbox represents the access lane in the title route. Its play
                    // request has no separate free-with-ads or ad-receipt parameter.
                    gameID: route.titleID,
                    account: account,
                    locale: settings.effectiveGameLanguage(
                        defaultLocale: L10n.localeCode
                    ),
                    settings: settings
                )
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        .onChange(of: controller.state) { previousState, state in
            if state == .streaming {
                showsOverlay = true
                MemoryLifecycleCoordinator.shared.streamDidStart()
                if !hasRecordedPlayback {
                    hasRecordedPlayback = true
                    onStreamStarted()
                }
            } else if previousState == .streaming {
                MemoryLifecycleCoordinator.shared.streamDidLeavePlayback()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            endSession()
        }
        .onExitCommand {
            if controller.state == .streaming {
                toggleOverlay()
            } else {
                endSession()
            }
        }
        .onDisappear {
            MemoryLifecycleCoordinator.shared.streamDidClose()
            Task {
                await controller.stop()
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

            if case let .failed(message) = controller.state {
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)

                HStack(spacing: 24) {
                    Button(L10n.text("try_again")) {
                        launchAttempt &+= 1
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

    private var playerOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.title2.bold())
                    Text(
                        route.accessKind == .freeWithAds
                            ? L10n.text("free_with_ads")
                            : L10n.text("xbox_cloud_gaming")
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Label(L10n.text("live"), systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 58)
            .padding(.vertical, 32)
            .background(.ultraThinMaterial)

            Spacer()

            HStack {
                Button {
                    toggleOverlay()
                } label: {
                    Label(L10n.text("resume"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityIdentifier("xbox-stream.resume")

                Spacer()

                Button(role: .destructive, action: endSession) {
                    Label(L10n.text("end_session"), systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isEnding)
                .accessibilityIdentifier("xbox-stream.end-session")
            }
            .padding(.horizontal, 58)
            .padding(.vertical, 34)
            .background(.ultraThinMaterial)
        }
        .transition(.opacity)
    }

    private var statusTitle: String {
        if isEnding {
            return L10n.text("xbox_ending_session")
        }
        return switch controller.state {
        case .idle:
            L10n.format("starting_game", item.title)
        case .requestingAccess:
            L10n.text("xbox_requesting_access")
        case .allocating:
            L10n.text("xbox_allocating_session")
        case .waiting:
            L10n.text("xbox_waiting_capacity")
        case .provisioning:
            L10n.text("xbox_provisioning_console")
        case .connecting:
            L10n.text("xbox_connecting_stream")
        case .streaming:
            L10n.text("live")
        case .stopping:
            L10n.text("xbox_ending_session")
        case .failed:
            L10n.text("disconnected")
        }
    }

    private var statusSymbol: String {
        switch controller.state {
        case .failed:
            "exclamationmark.triangle.fill"
        case .stopping:
            "xmark.circle.fill"
        default:
            "gamecontroller.fill"
        }
    }

    private var statusDetail: String? {
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
        switch controller.state {
        case .failed:
            .orange
        case .stopping:
            .red
        default:
            .green
        }
    }

    private var showsProgress: Bool {
        switch controller.state {
        case .idle, .requestingAccess, .allocating, .waiting, .provisioning,
             .connecting, .stopping:
            true
        case .streaming, .failed:
            false
        }
    }

    private var stateAccessibilityIdentifier: String {
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
        case .stopping:
            "stopping"
        case .failed:
            "failed"
        }
        return "xbox-stream-state.\(stateName)"
    }

    private func toggleOverlay() {
        guard controller.state == .streaming else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            showsOverlay.toggle()
        }
    }

    private func endSession() {
        guard !isEnding else { return }
        isEnding = true
        Task {
            await controller.stop()
            onDismiss()
        }
    }
}
