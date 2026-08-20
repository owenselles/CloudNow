import SwiftUI

struct XboxLibraryRefreshProgressView: View {
    @Environment(XboxCloudModeViewModel.self) private var modeViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedHeaderControl: XboxLibraryRefreshHeaderControl?

    private var refreshState: XboxLibraryRefreshState {
        modeViewModel.libraryRefreshState
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
                XboxLibraryRefreshHeader(
                    isRunning: isRunning,
                    isTerminal: isTerminal,
                    showsRetry: showsRetry,
                    retryAction: retry,
                    dismissAction: dismissFromHeader,
                    focusedControl: $focusedHeaderControl
                )

                ScrollView {
                    LazyVStack(spacing: 16) {
                        XboxLibraryRefreshOverallProgressCard(
                            statusText: overallStatusText,
                            symbol: overallStatusSymbol,
                            color: overallStatusColor,
                            completedStepCount: completedStepCount,
                            totalStepCount: 2
                        )

                        XboxLibraryRefreshStepRow(
                            title: L10n.text("xbox_cloud_catalog"),
                            phase: catalogStepPhase,
                            accessibilityIdentifier: "xboxLibraryRefreshCatalogStep"
                        )

                        XboxLibraryRefreshStepRow(
                            title: L10n.text("cloud_gaming_access"),
                            phase: accountAccessStepPhase,
                            accessibilityIdentifier: "xboxLibraryRefreshAccessStep"
                        )

                        if let summary {
                            XboxLibraryRefreshCompletionCard(summary: summary)
                        }

                        if let warningText {
                            XboxLibraryRefreshMessageCard(
                                message: warningText,
                                symbol: "exclamationmark.triangle.fill",
                                color: .orange,
                                accessibilityIdentifier: "xboxLibraryRefreshWarning"
                            )
                        }
                    }
                    .padding(.horizontal, 70)
                    .padding(.vertical, 24)
                }
                .focusSection()
                .accessibilityIdentifier("xboxLibraryRefreshProgress")
            }
        }
        .onExitCommand(perform: dismissFromHeader)
        .defaultFocus($focusedHeaderControl, defaultHeaderControl)
        .onChange(of: showsRetry) { _, retryAvailable in
            if !retryAvailable, focusedHeaderControl == .retry {
                focusedHeaderControl = .dismiss
            }
        }
        .blocksGlobalControllerNavigation()
    }

    private var backgroundColors: [Color] {
        colorScheme == .dark
            ? [Color(white: 0.055), Color(white: 0.11)]
            : [Color(white: 0.98), Color(white: 0.9)]
    }

    private var isRunning: Bool {
        switch refreshState {
        case .refreshingCatalog, .refreshingAccountAccess:
            true
        case .idle, .completed, .failed:
            false
        }
    }

    private var isTerminal: Bool {
        switch refreshState {
        case .completed, .failed:
            true
        case .idle, .refreshingCatalog, .refreshingAccountAccess:
            false
        }
    }

    private var showsRetry: Bool {
        switch refreshState {
        case .failed, .completed(_, accountAccessAvailable: false):
            true
        case .idle, .refreshingCatalog, .refreshingAccountAccess,
             .completed(_, accountAccessAvailable: true):
            false
        }
    }

    private var summary: XboxLibraryRefreshSummary? {
        switch refreshState {
        case let .completed(summary, _):
            summary
        case .idle, .refreshingCatalog, .refreshingAccountAccess, .failed:
            nil
        }
    }

    private var catalogStepPhase: XboxLibraryRefreshStepPhase {
        switch refreshState {
        case .idle:
            .queued
        case .refreshingCatalog:
            .active
        case .refreshingAccountAccess, .completed:
            .succeeded
        case .failed:
            .failed
        }
    }

    private var accountAccessStepPhase: XboxLibraryRefreshStepPhase {
        switch refreshState {
        case .idle, .refreshingCatalog:
            .queued
        case .refreshingAccountAccess:
            .active
        case let .completed(_, accountAccessAvailable):
            accountAccessAvailable ? .succeeded : .unavailable
        case .failed:
            .unavailable
        }
    }

    private var completedStepCount: Int {
        [catalogStepPhase, accountAccessStepPhase].count(where: \.isTerminal)
    }

    private var overallStatusText: String {
        switch refreshState {
        case .idle:
            L10n.text("refresh_library")
        case .refreshingCatalog:
            L10n.text("refresh_importing")
        case .refreshingAccountAccess:
            L10n.text("verifying_xbox_cloud_access")
        case .completed:
            L10n.text("refresh_completed")
        case .failed:
            L10n.text("refresh_failed")
        }
    }

    private var overallStatusSymbol: String {
        switch refreshState {
        case .idle, .refreshingCatalog, .refreshingAccountAccess:
            "arrow.triangle.2.circlepath"
        case let .completed(_, accountAccessAvailable):
            accountAccessAvailable
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill"
        case .failed:
            "xmark.octagon.fill"
        }
    }

    private var overallStatusColor: Color {
        switch refreshState {
        case .idle, .refreshingCatalog, .refreshingAccountAccess:
            .accentColor
        case let .completed(_, accountAccessAvailable):
            accountAccessAvailable ? .green : .orange
        case .failed:
            .red
        }
    }

    private var warningText: String? {
        switch refreshState {
        case let .failed(retainedLastGoodCatalog):
            switch retainedLastGoodCatalog {
            case true:
                L10n.text("catalog_may_be_out_of_date")
            case false:
                L10n.text("xbox_cloud_catalog_unavailable")
            }
        case .completed(_, accountAccessAvailable: false):
            L10n.text("access_not_confirmed")
        case .idle, .refreshingCatalog, .refreshingAccountAccess,
             .completed(_, accountAccessAvailable: true):
            nil
        }
    }

    private var defaultHeaderControl: XboxLibraryRefreshHeaderControl {
        showsRetry ? .retry : .dismiss
    }

    private func retry() {
        modeViewModel.retryLibraryRefresh()
    }

    private func dismissFromHeader() {
        if isTerminal {
            modeViewModel.acknowledgeLibraryRefresh()
        }
        dismiss()
    }
}

private enum XboxLibraryRefreshHeaderControl: Hashable {
    case retry
    case dismiss
}

private enum XboxLibraryRefreshStepPhase: Equatable {
    case queued
    case active
    case succeeded
    case unavailable
    case failed

    var isTerminal: Bool {
        switch self {
        case .queued, .active:
            false
        case .succeeded, .unavailable, .failed:
            true
        }
    }

    var isActive: Bool {
        self == .active
    }

    var statusText: String {
        switch self {
        case .queued:
            L10n.text("provider_sync_queued")
        case .active:
            L10n.text("provider_sync_syncing")
        case .succeeded:
            L10n.text("provider_sync_succeeded")
        case .unavailable:
            L10n.text("provider_sync_unavailable")
        case .failed:
            L10n.text("provider_sync_failed")
        }
    }

    var symbol: String {
        switch self {
        case .queued:
            "clock"
        case .active:
            "arrow.triangle.2.circlepath"
        case .succeeded:
            "checkmark.circle.fill"
        case .unavailable:
            "minus.circle.fill"
        case .failed:
            "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .succeeded:
            .green
        case .failed:
            .red
        case .queued, .active, .unavailable:
            .secondary
        }
    }
}

private struct XboxLibraryRefreshHeader: View {
    let isRunning: Bool
    let isTerminal: Bool
    let showsRetry: Bool
    let retryAction: () -> Void
    let dismissAction: () -> Void
    let focusedControl: FocusState<XboxLibraryRefreshHeaderControl?>.Binding

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

            Spacer(minLength: 24)

            if showsRetry, !isRunning {
                Button(action: retryAction) {
                    Label(
                        L10n.text("retry_failed"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .focused(focusedControl, equals: .retry)
                .accessibilityIdentifier("xboxLibraryRefreshRetryButton")
            }

            Button(action: dismissAction) {
                Label(
                    isTerminal ? L10n.text("done") : L10n.text("close"),
                    systemImage: isTerminal ? "checkmark" : "xmark"
                )
            }
            .buttonStyle(.bordered)
            .focused(focusedControl, equals: .dismiss)
            .accessibilityIdentifier(
                isTerminal
                    ? "xboxLibraryRefreshDoneButton"
                    : "xboxLibraryRefreshCloseButton"
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

private struct XboxLibraryRefreshOverallProgressCard: View {
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
        .xboxLibraryRefreshFocusableCard(
            accessibilityIdentifier: "xboxLibraryRefreshOverallProgress"
        )
    }
}

private struct XboxLibraryRefreshStepRow: View {
    let title: String
    let phase: XboxLibraryRefreshStepPhase
    let accessibilityIdentifier: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) {
                stepTitle
                    .frame(maxWidth: .infinity, alignment: .leading)

                phaseStatus
                    .fixedSize(horizontal: true, vertical: false)
                    .multilineTextAlignment(.trailing)
                    .layoutPriority(1)
            }

            VStack(alignment: .leading, spacing: 14) {
                stepTitle
                phaseStatus
                    .multilineTextAlignment(.leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(phase.statusText)
        .xboxLibraryRefreshFocusableCard(
            accessibilityIdentifier: accessibilityIdentifier
        )
    }

    private var stepTitle: some View {
        Text(title)
            .font(.headline)
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
}

private struct XboxLibraryRefreshCompletionCard: View {
    let summary: XboxLibraryRefreshSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                L10n.text("refresh_completed"),
                systemImage: "checkmark.circle.fill"
            )
            .font(.headline)

            LabeledContent(
                L10n.text("library"),
                value: "\(summary.playableGameCount)"
            )
            LabeledContent(
                L10n.text("browse"),
                value: "\(summary.catalogGameCount)"
            )
            Text(
                L10n.format(
                    "refresh_library_changes",
                    summary.addedGameCount,
                    summary.removedGameCount
                )
            )
            Text(
                L10n.format(
                    "catalog_last_updated",
                    summary.fetchedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
            )
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .xboxLibraryRefreshFocusableCard(
            accessibilityIdentifier: "xboxLibraryRefreshSummary"
        )
    }
}

private struct XboxLibraryRefreshMessageCard: View {
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
        .xboxLibraryRefreshFocusableCard(
            accessibilityIdentifier: accessibilityIdentifier
        )
    }
}

private struct XboxLibraryRefreshFocusableCardModifier: ViewModifier {
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
    func xboxLibraryRefreshFocusableCard(
        accessibilityIdentifier: String
    ) -> some View {
        modifier(
            XboxLibraryRefreshFocusableCardModifier(
                accessibilityIdentifier: accessibilityIdentifier
            )
        )
    }
}
