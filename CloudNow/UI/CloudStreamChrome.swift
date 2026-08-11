import SwiftUI

/// Provider-neutral pause chrome extracted from the native stream UI. Provider
/// adapters supply only actions that are genuinely supported.
struct CloudStreamPauseMenu<ProviderActions: View, Footer: View>: View {
    let statsMode: StreamStatsMode
    let onResume: () -> Void
    let onCycleStatistics: () -> Void
    let onLeave: (() -> Void)?
    let onEndRequest: () -> Void
    let isEndDisabled: Bool
    let accessibilityPrefix: String?
    @ViewBuilder let providerActions: ProviderActions
    @ViewBuilder let footer: Footer

    @Environment(\.colorScheme) private var colorScheme

    init(
        statsMode: StreamStatsMode,
        onResume: @escaping () -> Void,
        onCycleStatistics: @escaping () -> Void,
        onLeave: (() -> Void)?,
        onEndRequest: @escaping () -> Void,
        isEndDisabled: Bool = false,
        accessibilityPrefix: String? = nil,
        @ViewBuilder providerActions: () -> ProviderActions,
        @ViewBuilder footer: () -> Footer
    ) {
        self.statsMode = statsMode
        self.onResume = onResume
        self.onCycleStatistics = onCycleStatistics
        self.onLeave = onLeave
        self.onEndRequest = onEndRequest
        self.isEndDisabled = isEndDisabled
        self.accessibilityPrefix = accessibilityPrefix
        self.providerActions = providerActions()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: onResume) {
                Label(L10n.text("resume"), systemImage: "play.fill")
                    .foregroundStyle(Color.black.opacity(0.84))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .optionalAccessibilityIdentifier(
                identifier(suffix: "resume")
            )

            providerActions

            Button(action: onCycleStatistics) {
                Label(
                    L10n.format("statistics_level", statsMode.label),
                    systemImage: "chart.bar.xaxis"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .optionalAccessibilityIdentifier(
                identifier(suffix: "statistics")
            )

            if let onLeave {
                Button(action: onLeave) {
                    Label(L10n.text("leave_game"), systemImage: "house")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .optionalAccessibilityIdentifier(
                    identifier(suffix: "leave")
                )
            }

            Button(role: .destructive, action: onEndRequest) {
                Label(
                    L10n.text("end_session"),
                    systemImage: "xmark.circle"
                )
                .foregroundStyle(Color.black.opacity(0.84))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(isEndDisabled)
            .optionalAccessibilityIdentifier(
                identifier(suffix: "end-session")
            )

            Spacer()

            footer
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 80)
        .frame(width: 480)
        .frame(maxHeight: .infinity)
        .background(pauseMenuBackgroundColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .ignoresSafeArea()
    }

    private var pauseMenuBackgroundColor: Color {
        colorScheme == .dark ? .black.opacity(0.75) : .white.opacity(0.82)
    }

    private func identifier(suffix: String) -> String? {
        accessibilityPrefix.map { "\($0).\(suffix)" }
    }
}

private extension View {
    @ViewBuilder
    func optionalAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

#if DEBUG
    /// Network-free UI automation surface for every shared lifecycle state.
    /// It deliberately consumes the same provider-neutral model as adapters.
    struct CloudStreamPresentationFixtureView: View {
        let state: CloudStreamPresentationState

        var body: some View {
            ZStack {
                LinearGradient(
                    colors: [.black, Color.green.opacity(0.12)],
                    startPoint: .bottomTrailing,
                    endPoint: .topLeading
                )
                .ignoresSafeArea()

                if case let .resumable(expiresAt) = state {
                    CloudResumableSessionBanner(
                        title: "Fixture Racer",
                        artworkURL: nil,
                        expiresAt: expiresAt,
                        onResume: {}
                    )
                } else {
                    VStack(spacing: 24) {
                        Image(systemName: symbol)
                            .font(.system(size: 68, weight: .semibold))
                            .foregroundStyle(tint)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier(identifier)
                        if let detail {
                            Text(detail)
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if showsProgress {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.green)
                        }
                    }
                }
            }
            .accessibilityIdentifier(identifier)
        }

        private var identifier: String {
            "cloud-stream-state.\(stateName)"
        }

        private var stateName: String {
            switch state {
            case .idle: "idle"
            case .allocating: "allocating"
            case .queued: "queued"
            case .provisioning: "provisioning"
            case .connecting: "connecting"
            case .streaming: "streaming"
            case .reconnecting: "reconnecting"
            case .resumable: "resumable"
            case .failure: "failure"
            case .stopping: "stopping"
            }
        }

        private var title: String {
            switch state {
            case .idle:
                L10n.format("starting_game", "Fixture Racer")
            case .allocating:
                L10n.format("starting_game", "Fixture Racer")
            case .queued:
                L10n.text("in_queue")
            case .provisioning:
                L10n.text("preparing_game")
            case .connecting:
                L10n.text("connecting_to_server")
            case .streaming:
                L10n.text("live")
            case .reconnecting:
                L10n.text("reconnecting")
            case .resumable:
                L10n.text("session_active")
            case let .failure(failure):
                L10n.text(failure.localizationKey)
            case .stopping:
                L10n.text("ending_session")
            }
        }

        private var detail: String? {
            switch state {
            case let .queued(position, estimatedWait):
                if let position {
                    return "#\(position)"
                }
                return estimatedWait.map {
                    L10n.format("xbox_estimated_wait", Int($0.rounded(.up)))
                }
            case let .provisioning(progress, estimatedWait):
                if let progress {
                    return "\(Int((progress * 100).rounded()))%"
                }
                return estimatedWait.map {
                    L10n.format("xbox_estimated_wait", Int($0.rounded(.up)))
                }
            case let .reconnecting(attempt, maximumAttempts, nextDelay):
                let attemptText = L10n.format(
                    "reconnecting_attempt_note",
                    attempt
                )
                guard let nextDelay else { return attemptText }
                return "\(attemptText) · \(Int(nextDelay.rounded(.up)))s / \(maximumAttempts)"
            case .idle, .allocating, .connecting, .streaming, .resumable,
                 .failure, .stopping:
                return nil
            }
        }

        private var symbol: String {
            switch state {
            case .failure:
                "exclamationmark.triangle.fill"
            case .streaming:
                "play.fill"
            case .stopping:
                "xmark.circle.fill"
            default:
                "gamecontroller.fill"
            }
        }

        private var tint: Color {
            switch state {
            case .failure:
                .orange
            case .stopping:
                .red
            default:
                .green
            }
        }

        private var showsProgress: Bool {
            switch state {
            case .idle, .allocating, .queued, .provisioning, .connecting,
                 .reconnecting, .stopping:
                true
            case .streaming, .resumable, .failure:
                false
            }
        }
    }
#endif
