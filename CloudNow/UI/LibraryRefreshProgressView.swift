import SwiftUI

struct LibraryRefreshProgressView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(GamesViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedHeaderControl: LibraryRefreshHeaderControl?

    private var refreshState: FullLibraryRefreshState {
        viewModel.libraryRefreshState
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: backgroundColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                LibraryRefreshHeader(
                    isRunning: refreshState.isRunning,
                    hasRetryableFailures: refreshState.hasRetryableFailures,
                    retryAction: retryFailedProviders,
                    dismissAction: dismissFromHeader,
                    focusedControl: $focusedHeaderControl
                )

                ScrollView {
                    LazyVStack(spacing: 16) {
                        LibraryRefreshOverallProgressCard(
                            statusText: overallStatusText,
                            symbol: overallStatusSymbol,
                            color: overallStatusColor,
                            completedStepCount: refreshState.completedStepCount,
                            totalStepCount: refreshState.totalStepCount
                        )

                        LibraryRefreshProviderList(state: refreshState)

                        ProviderSyncPhaseRow(
                            title: L10n.text("gfn_to_cloudnow"),
                            subtitle: nil,
                            phase: refreshState.finalPhase,
                            accessibilityIdentifier: "libraryRefreshFinalImport"
                        )

                        if let summary = refreshState.summary {
                            LibraryRefreshCompletionCard(summary: summary)
                        }

                        if let warning = refreshState.warning, !warning.isEmpty {
                            LibraryRefreshMessageCard(
                                message: warning,
                                symbol: "exclamationmark.triangle.fill",
                                color: .orange,
                                accessibilityIdentifier: "libraryRefreshWarning"
                            )
                        }
                    }
                    .padding(.horizontal, 70)
                    .padding(.vertical, 24)
                }
                .focusSection()
                .accessibilityIdentifier("libraryRefreshProgressSheet")
            }
        }
        .onExitCommand {
            dismissFromHeader()
        }
        .defaultFocus($focusedHeaderControl, defaultHeaderControl)
        .onChange(of: refreshState.hasRetryableFailures) { _, hasFailures in
            if !hasFailures, focusedHeaderControl == .retry {
                focusedHeaderControl = .dismiss
            }
        }
        .blocksGlobalControllerNavigation()
    }

    private var backgroundColors: [Color] {
        if colorScheme == .dark {
            [Color(white: 0.055), Color(white: 0.11)]
        } else {
            [Color(white: 0.98), Color(white: 0.9)]
        }
    }

    private func retryFailedProviders() {
        viewModel.retryFailedLibraryProviders(authManager: authManager)
    }

    private func dismissFromHeader() {
        if !refreshState.isRunning {
            viewModel.acknowledgeLibraryRefresh()
        }
        dismiss()
    }

    private var defaultHeaderControl: LibraryRefreshHeaderControl {
        refreshState.hasRetryableFailures && !refreshState.isRunning
            ? .retry
            : .dismiss
    }

    private var overallStatusText: String {
        switch refreshState.stage {
        case .idle:
            L10n.text("refresh_library")
        case .discovering:
            L10n.text("refresh_discovering")
        case .syncing:
            L10n.text("refresh_syncing")
        case .settling:
            L10n.text("refresh_settling")
        case .importing:
            L10n.text("refresh_importing")
        case .completed:
            L10n.text("refresh_completed")
        case .partialFailure:
            L10n.text("refresh_partial_failure")
        case .failed:
            L10n.text("refresh_failed")
        }
    }

    private var overallStatusSymbol: String {
        switch refreshState.stage {
        case .idle, .discovering, .syncing, .settling, .importing:
            "arrow.triangle.2.circlepath"
        case .completed:
            "checkmark.circle.fill"
        case .partialFailure:
            "exclamationmark.triangle.fill"
        case .failed:
            "xmark.octagon.fill"
        }
    }

    private var overallStatusColor: Color {
        switch refreshState.stage {
        case .completed:
            .green
        case .partialFailure:
            .orange
        case .failed:
            .red
        case .idle, .discovering, .syncing, .settling, .importing:
            .accentColor
        }
    }
}

private enum LibraryRefreshHeaderControl: Hashable {
    case retry
    case dismiss
}

private struct LibraryRefreshHeader: View {
    let isRunning: Bool
    let hasRetryableFailures: Bool
    let retryAction: () -> Void
    let dismissAction: () -> Void
    let focusedControl: FocusState<LibraryRefreshHeaderControl?>.Binding

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title3)
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text(L10n.text("library_refresh_progress"))
                .font(.title2.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .accessibilityIdentifier("libraryRefreshHeader")

            Spacer(minLength: 24)

            if hasRetryableFailures, !isRunning {
                Button(action: retryAction) {
                    Label(
                        L10n.text("retry_failed"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .focused(focusedControl, equals: .retry)
                .accessibilityIdentifier("libraryRefreshRetryFailedButton")
            }

            Button(action: dismissAction) {
                Label(
                    isRunning ? L10n.text("close") : L10n.text("done"),
                    systemImage: isRunning ? "xmark" : "checkmark"
                )
            }
            .buttonStyle(.bordered)
            .focused(focusedControl, equals: .dismiss)
            .accessibilityIdentifier(
                isRunning
                    ? "libraryRefreshCloseButton"
                    : "libraryRefreshDoneButton"
            )
        }
        .padding(.horizontal, 70)
        .padding(.vertical, 18)
        .background(Color.black.opacity(0.24))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }
}

private struct LibraryRefreshOverallProgressCard: View {
    let statusText: String
    let symbol: String
    let color: Color
    let completedStepCount: Int
    let totalStepCount: Int

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(color)

                ProgressView(
                    value: Double(completedStepCount),
                    total: Double(totalStepCount)
                )
                .tint(color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("library_refresh_progress"))
        .accessibilityValue(
            "\(statusText), "
                + L10n.format(
                    "refresh_progress_steps",
                    completedStepCount,
                    totalStepCount
                )
        )
        .libraryRefreshFocusableCard(
            accessibilityIdentifier: "libraryRefreshOverallProgress"
        )
    }
}

private struct LibraryRefreshProviderList: View {
    let state: FullLibraryRefreshState

    var body: some View {
        if state.providers.isEmpty {
            if state.stage != .idle, state.stage != .discovering {
                LibraryRefreshMessageCard(
                    message: state.warning == nil
                        ? L10n.text("no_connected_libraries")
                        : L10n.text("provider_sync_unavailable"),
                    symbol: state.warning == nil
                        ? "person.2.slash"
                        : "exclamationmark.triangle.fill",
                    color: .secondary,
                    accessibilityIdentifier: "libraryRefreshNoConnectedProviders"
                )
            }
        } else {
            if state.warning == nil,
               state.providers.allSatisfy({ $0.phase == .skipped })
            {
                LibraryRefreshMessageCard(
                    message: L10n.text("no_connected_libraries"),
                    symbol: "person.2.slash",
                    color: .secondary,
                    accessibilityIdentifier: "libraryRefreshNoSyncCapableProviders"
                )
            }

            ForEach(state.providers) { provider in
                ProviderSyncProgressRow(provider: provider)
            }
        }
    }
}

private struct LibraryRefreshCompletionCard: View {
    let summary: LibraryRefreshSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                L10n.format(
                    "refresh_provider_summary",
                    summary.successfulProviderCount,
                    summary.failedProviderCount
                ),
                systemImage: summary.failedProviderCount == 0
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.headline)

            Text(
                L10n.format(
                    "refresh_library_changes",
                    summary.addedGameIDs.count,
                    summary.removedGameIDs.count
                )
            )
            Text(L10n.format("refresh_final_game_count", summary.finalGameCount))
        }
        .accessibilityElement(children: .combine)
        .libraryRefreshFocusableCard(
            accessibilityIdentifier: "libraryRefreshSummary"
        )
    }
}

private struct LibraryRefreshMessageCard: View {
    let message: String
    let symbol: String
    let color: Color
    let accessibilityIdentifier: String

    var body: some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .libraryRefreshFocusableCard(
            accessibilityIdentifier: accessibilityIdentifier
        )
    }
}

private struct ProviderSyncProgressRow: View {
    let provider: ProviderSyncProgress

    var body: some View {
        ProviderSyncPhaseRow(
            title: provider.displayName,
            subtitle: provider.accountName,
            phase: provider.phase,
            accessibilityIdentifier: "libraryRefreshProvider.\(provider.providerCode)"
        )
    }
}

private struct ProviderSyncPhaseRow: View {
    let title: String
    let subtitle: String?
    let phase: ProviderSyncPhase
    let accessibilityIdentifier: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) {
                providerDetails
                    .frame(maxWidth: .infinity, alignment: .leading)

                phaseStatus
                    .fixedSize(horizontal: true, vertical: false)
                    .multilineTextAlignment(.trailing)
                    .layoutPriority(1)
            }

            VStack(alignment: .leading, spacing: 14) {
                providerDetails
                phaseStatus
                    .multilineTextAlignment(.leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(phase.accessibilityValue)
        .libraryRefreshFocusableCard(
            accessibilityIdentifier: accessibilityIdentifier
        )
    }

    private var providerDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if case let .failed(message) = phase, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var phaseStatus: some View {
        HStack(spacing: 12) {
            if phase.isActive {
                ProgressView()
            } else {
                Image(systemName: phase.symbol)
                    .foregroundStyle(phase.color)
                    .accessibilityHidden(true)
            }
            Text(phase.statusText)
                .font(.callout.weight(.semibold))
                .foregroundStyle(phase.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilityLabel: String {
        guard let subtitle, !subtitle.isEmpty else { return title }
        return "\(title), \(subtitle)"
    }
}

private struct LibraryRefreshFocusableCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    let accessibilityIdentifier: String

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(
                isFocused
                    ? Color.accentColor.opacity(0.22)
                    : Color.primary.opacity(0.08)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        isFocused ? Color.accentColor : .clear,
                        lineWidth: 4
                    )
            }
            .compositingGroup()
            .clipShape(.rect(cornerRadius: 16))
            .scaleEffect(isFocused && !reduceMotion ? 1.015 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.15),
                value: isFocused
            )
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private extension View {
    func libraryRefreshFocusableCard(
        accessibilityIdentifier: String
    ) -> some View {
        modifier(
            LibraryRefreshFocusableCardModifier(
                accessibilityIdentifier: accessibilityIdentifier
            )
        )
    }
}

private extension ProviderSyncPhase {
    var isActive: Bool {
        switch self {
        case .requesting, .syncing:
            true
        case .queued, .succeeded, .failed, .timedOut, .relinkRequired, .skipped:
            false
        }
    }

    var statusText: String {
        switch self {
        case .queued:
            L10n.text("provider_sync_queued")
        case .requesting:
            L10n.text("provider_sync_requesting")
        case .syncing:
            L10n.text("provider_sync_syncing")
        case let .succeeded(gameCount):
            if let gameCount {
                L10n.format("provider_sync_succeeded_count", gameCount)
            } else {
                L10n.text("provider_sync_succeeded")
            }
        case .failed:
            L10n.text("provider_sync_failed")
        case .timedOut:
            L10n.text("provider_sync_timed_out")
        case .relinkRequired:
            L10n.text("provider_sync_relink_required")
        case .skipped:
            L10n.text("provider_sync_unavailable")
        }
    }

    var accessibilityValue: String {
        if case let .failed(message) = self, !message.isEmpty {
            return "\(statusText), \(message)"
        }
        return statusText
    }

    var symbol: String {
        switch self {
        case .queued:
            "clock"
        case .requesting, .syncing:
            "arrow.triangle.2.circlepath"
        case .succeeded:
            "checkmark.circle.fill"
        case .failed:
            "xmark.octagon.fill"
        case .timedOut:
            "clock.badge.exclamationmark"
        case .relinkRequired:
            "person.crop.circle.badge.exclamationmark"
        case .skipped:
            "minus.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .succeeded:
            .green
        case .failed, .timedOut:
            .red
        case .relinkRequired:
            .orange
        case .queued, .requesting, .syncing, .skipped:
            .secondary
        }
    }
}
