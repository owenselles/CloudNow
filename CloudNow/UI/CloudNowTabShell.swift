import Observation
import SwiftUI
import UIKit

nonisolated protocol CloudNowTabSelection: Hashable {
    static var first: Self { get }
    static var last: Self { get }

    var previous: Self { get }
    var next: Self { get }
}

nonisolated enum CloudNowTopLevelNavigationDestination<Selection: CloudNowTabSelection>: Equatable {
    case providerMenu
    case tab(Selection)

    var previous: Self {
        switch self {
        case .providerMenu:
            .tab(Selection.last)
        case let .tab(selection) where selection == Selection.first:
            .providerMenu
        case let .tab(selection):
            .tab(selection.previous)
        }
    }

    var next: Self {
        switch self {
        case .providerMenu:
            .tab(Selection.first)
        case let .tab(selection) where selection == Selection.last:
            .providerMenu
        case let .tab(selection):
            .tab(selection.next)
        }
    }
}

/// Releases only the active mode's transient UI/runtime state before the app
/// changes providers. Persisted provider accounts remain owned by auth managers.
@MainActor
protocol CloudGamingProviderModeLifecycle: AnyObject {
    func deactivateForInactiveProvider() async
}

struct CloudProviderSwitchPrompt: Equatable, Identifiable {
    let targetProvider: CloudGamingProvider
    let requirement: CloudProviderSwitchRequirement

    var id: String {
        switch requirement {
        case let .leaveOrEnd(lease), let .endParkedSession(lease):
            "\(targetProvider.rawValue)|\(lease.id.uuidString)"
        case .allowed:
            targetProvider.rawValue
        }
    }

    var lease: CloudServerSessionLease? {
        switch requirement {
        case let .leaveOrEnd(lease), let .endParkedSession(lease):
            lease
        case .allowed:
            nil
        }
    }
}

struct CloudProviderSwitchConfirmationModifier: ViewModifier {
    @Environment(CloudSessionCoordinator.self) private var sessionCoordinator
    @Binding var prompt: CloudProviderSwitchPrompt?
    @State private var failureMessage: String?
    let onSwitch: @MainActor (CloudGamingProvider) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            L10n.text("cloud_session_active"),
            isPresented: isPresented,
            titleVisibility: .visible,
            presenting: prompt
        ) { prompt in
            if case let .leaveOrEnd(lease) = prompt.requirement,
               sessionCoordinator.canLeaveServerSession(lease)
            {
                Button(L10n.text("leave_game")) {
                    Task { @MainActor in
                        guard await sessionCoordinator.leaveServerSession(lease)
                        else {
                            failureMessage = L10n.text(
                                "cloud_service_unavailable"
                            )
                            return
                        }
                        onSwitch(prompt.targetProvider)
                    }
                }
            }

            Button(
                L10n.format(
                    "end_and_switch_to_service",
                    prompt.targetProvider.displayName
                ),
                role: .destructive
            ) {
                Task { @MainActor in
                    guard let lease = prompt.lease,
                          await sessionCoordinator.endServerSessionUsingProvider(
                              lease
                          )
                    else {
                        failureMessage = L10n.text(
                            "cloud_service_unavailable"
                        )
                        return
                    }
                    onSwitch(prompt.targetProvider)
                }
            }

            Button(L10n.text("cancel"), role: .cancel) {}
        } message: { prompt in
            switch prompt.requirement {
            case .leaveOrEnd:
                Text(L10n.text("active_session_switch_message"))
            case .endParkedSession:
                Text(L10n.text("parked_session_switch_message"))
            case .allowed:
                EmptyView()
            }
        }
        .alert(
            L10n.text("retry_failed"),
            isPresented: Binding(
                get: { failureMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        failureMessage = nil
                    }
                }
            )
        ) {
            Button(L10n.text("ok"), role: .cancel) {}
        } message: {
            Text(failureMessage ?? "")
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { prompt != nil },
            set: { isPresented in
                if !isPresented {
                    prompt = nil
                }
            }
        )
    }
}

extension View {
    func cloudProviderSwitchConfirmation(
        prompt: Binding<CloudProviderSwitchPrompt?>,
        onSwitch: @escaping @MainActor (CloudGamingProvider) -> Void
    ) -> some View {
        modifier(
            CloudProviderSwitchConfirmationModifier(
                prompt: prompt,
                onSwitch: onSwitch
            )
        )
    }
}

@Observable
@MainActor
final class CloudNowNativeTabBarState {
    private(set) var isVisible = true

    @ObservationIgnored private var focusObserver: NotificationCenter.ObservationToken?
    @ObservationIgnored private weak var nativeTabItemView: UIView?
    @ObservationIgnored private var visibilitySamplingTask: Task<Void, Never>?

    isolated deinit {
        stop()
    }

    func start() {
        guard focusObserver == nil else { return }
        isVisible = true
        focusObserver = NotificationCenter.default.addObserver(
            of: UIFocusSystem.self,
            for: .didUpdate
        ) { [weak self] message in
            self?.focusDidUpdate(message.updateContext)
        }
    }

    func stop() {
        if let focusObserver {
            NotificationCenter.default.removeObserver(focusObserver)
        }
        focusObserver = nil
        visibilitySamplingTask?.cancel()
        visibilitySamplingTask = nil
        nativeTabItemView = nil
        isVisible = true
    }

    private func focusDidUpdate(_ context: UIFocusUpdateContext?) {
        guard let nextFocusedView = context?.nextFocusedView else {
            sampleNativeTabBarPresentation()
            return
        }

        if Self.ancestorTabBar(of: nextFocusedView) != nil {
            nativeTabItemView = nextFocusedView
            revealTopNavigation(
                from: context?.previouslyFocusedView,
                tabItemView: nextFocusedView
            )
        }
        sampleNativeTabBarPresentation()
    }

    private func revealTopNavigation(
        from previouslyFocusedView: UIView?,
        tabItemView: UIView
    ) {
        guard !Self.isMostlyVisible(tabItemView) else { return }
        let scrollView = previouslyFocusedView.flatMap {
            Self.verticalScrollView(containing: $0)
        }
        guard let scrollView,
              scrollView.window === tabItemView.window
        else {
            return
        }

        let topOffset = -scrollView.adjustedContentInset.top
        guard scrollView.contentOffset.y > topOffset + 0.5 else { return }
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: topOffset),
            animated: false
        )
    }

    private func sampleNativeTabBarPresentation() {
        visibilitySamplingTask?.cancel()
        guard let nativeTabItemView else { return }

        visibilitySamplingTask = Task { @MainActor [weak self, weak nativeTabItemView] in
            for _ in 0 ..< 60 {
                guard let self,
                      let nativeTabItemView,
                      !Task.isCancelled
                else {
                    return
                }
                updateVisibility(from: nativeTabItemView)
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    return
                }
            }
        }
    }

    private func updateVisibility(from tabItemView: UIView) {
        guard let window = tabItemView.window else { return }
        guard Self.isVisibleInHierarchy(tabItemView, through: window) else {
            setVisibility(false)
            return
        }

        let tabItemFrame: CGRect
        let presentedOpacity: Float
        if let presentedTabItemLayer = tabItemView.layer.presentation(),
           let presentedWindowLayer = window.layer.presentation()
        {
            tabItemFrame = presentedTabItemLayer.convert(
                presentedTabItemLayer.bounds,
                to: presentedWindowLayer
            )
            presentedOpacity = presentedTabItemLayer.opacity
        } else {
            tabItemFrame = tabItemView.convert(tabItemView.bounds, to: window)
            presentedOpacity = tabItemView.layer.opacity
        }

        guard tabItemFrame.height > 0,
              tabItemFrame.width > 0,
              tabItemFrame.isFinite
        else {
            return
        }
        let intersection = tabItemFrame.intersection(window.bounds)
        let visibleHeight = intersection.isNull ? 0 : intersection.height
        let visibleFraction = visibleHeight / tabItemFrame.height
        setVisibility(visibleFraction >= 0.9 && presentedOpacity > 0.05)
    }

    private func setVisibility(_ newValue: Bool) {
        if isVisible != newValue {
            isVisible = newValue
        }
    }

    private static func ancestorTabBar(of view: UIView) -> UITabBar? {
        var ancestor: UIView? = view
        while let current = ancestor {
            if let tabBar = current as? UITabBar {
                return tabBar
            }
            ancestor = current.superview
        }
        return nil
    }

    private static func isMostlyVisible(_ view: UIView) -> Bool {
        guard let window = view.window,
              isVisibleInHierarchy(view, through: window)
        else {
            return false
        }
        let frame = view.convert(view.bounds, to: window)
        guard frame.height > 0, frame.width > 0, frame.isFinite else {
            return false
        }
        let intersection = frame.intersection(window.bounds)
        let visibleHeight = intersection.isNull ? 0 : intersection.height
        return visibleHeight / frame.height >= 0.9
    }

    private static func verticalScrollView(
        containing view: UIView
    ) -> UIScrollView? {
        var ancestor: UIView? = view
        while let current = ancestor {
            if let scrollView = current as? UIScrollView,
               scrollView.isScrollEnabled,
               !scrollView.isHidden,
               scrollView.alpha > 0.05,
               scrollView.contentSize.height > scrollView.bounds.height + 1
            {
                return scrollView
            }
            ancestor = current.superview
        }
        return nil
    }

    private static func isVisibleInHierarchy(
        _ view: UIView,
        through window: UIWindow
    ) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha <= 0.05 {
                return false
            }
            if current === window {
                return true
            }
            ancestor = current.superview
        }
        return false
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && width.isFinite
            && height.isFinite
    }
}

struct CloudNowTabShell<Selection: CloudNowTabSelection, Content: TabContent<Selection>>: View {
    @Binding private var selection: Selection
    @State private var isProviderMenuReady = false
    @State private var isProviderMenuFocusRequested = false
    @State private var nativeTabBarState = CloudNowNativeTabBarState()
    @FocusState private var isProviderMenuFocused: Bool

    private let controllerNavigation: UIControllerNavigationCoordinator
    private let accessibilityIdentifier: String
    private let modeLifecycle: any CloudGamingProviderModeLifecycle
    @TabContentBuilder<Selection> private let content: Content

    init(
        selection: Binding<Selection>,
        controllerNavigation: UIControllerNavigationCoordinator,
        accessibilityIdentifier: String,
        modeLifecycle: any CloudGamingProviderModeLifecycle,
        @TabContentBuilder<Selection> content: () -> Content
    ) {
        _selection = selection
        self.controllerNavigation = controllerNavigation
        self.accessibilityIdentifier = accessibilityIdentifier
        self.modeLifecycle = modeLifecycle
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TabView(selection: $selection) {
                content
            }
            .accessibilityIdentifier(accessibilityIdentifier)

            VStack(alignment: .leading) {
                CloudGamingProviderMenu(
                    modeLifecycle: modeLifecycle,
                    isInteractionReady: isProviderMenuReady,
                    isVisible: isProviderMenuVisible,
                    focus: $isProviderMenuFocused
                )
            }
            .frame(width: 280, height: 130, alignment: .topLeading)
            .padding(.leading, 60)
            .offset(y: isProviderMenuVisible ? -20 : -150)
            .allowsHitTesting(isProviderMenuVisible)
            .accessibilityHidden(!isProviderMenuVisible)
        }
        .environment(controllerNavigation)
        .task {
            // Let the native tab bar win the initial tvOS focus pass. The
            // auxiliary dropdown becomes reachable immediately afterward.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            isProviderMenuReady = true
        }
        .onAppear {
            nativeTabBarState.start()
            controllerNavigation.start(
                onPreviousTab: moveToPreviousDestination,
                onNextTab: moveToNextDestination
            )
        }
        .onDisappear {
            isProviderMenuReady = false
            isProviderMenuFocusRequested = false
            nativeTabBarState.stop()
            controllerNavigation.stop()
        }
        .onChange(of: isProviderMenuFocused) { _, isFocused in
            if isFocused {
                isProviderMenuFocusRequested = false
            }
        }
        .onChange(of: nativeTabBarState.isVisible) { _, isVisible in
            guard !isVisible else { return }
            isProviderMenuFocusRequested = false
            isProviderMenuFocused = false
        }
    }

    private func moveToPreviousDestination() {
        move(to: currentNavigationDestination.previous)
    }

    private func moveToNextDestination() {
        move(to: currentNavigationDestination.next)
    }

    private var currentNavigationDestination: CloudNowTopLevelNavigationDestination<Selection> {
        isProviderMenuFocused ? .providerMenu : .tab(selection)
    }

    private var isProviderMenuVisible: Bool {
        nativeTabBarState.isVisible
    }

    private func move(
        to destination: CloudNowTopLevelNavigationDestination<Selection>
    ) {
        switch destination {
        case .providerMenu:
            guard isProviderMenuReady,
                  nativeTabBarState.isVisible
            else {
                return
            }
            isProviderMenuFocusRequested = true
            Task { @MainActor in
                await Task.yield()
                guard isProviderMenuFocusRequested,
                      nativeTabBarState.isVisible
                else {
                    return
                }
                isProviderMenuFocused = true
                await Task.yield()
                isProviderMenuFocusRequested = false
            }
        case let .tab(tab):
            isProviderMenuFocusRequested = false
            isProviderMenuFocused = false
            selection = tab
        }
    }
}

private struct CloudGamingProviderMenu: View {
    @Environment(CloudGamingProviderCoordinator.self) private var providerCoordinator
    @Environment(CloudSessionCoordinator.self) private var sessionCoordinator
    @State private var providerSwitchPrompt: CloudProviderSwitchPrompt?

    let modeLifecycle: any CloudGamingProviderModeLifecycle
    let isInteractionReady: Bool
    let isVisible: Bool
    let focus: FocusState<Bool>.Binding

    var body: some View {
        if let activeProvider = providerCoordinator.selectedProvider {
            Menu {
                ForEach(CloudGamingProvider.allCases) { provider in
                    Button {
                        requestProviderSwitch(to: provider)
                    } label: {
                        Label(
                            provider.displayName,
                            systemImage: provider == activeProvider
                                ? "checkmark"
                                : provider.systemImage
                        )
                    }
                    .disabled(
                        provider == activeProvider
                            || providerCoordinator.isProviderInteractionBlocked
                            || !providerCoordinator.capabilities(
                                for: provider
                            ).availability.isSupported
                    )
                    .accessibilityHint(
                        providerCoordinator.capabilities(
                            for: provider
                        ).availability.unavailableReason.map {
                            L10n.text($0.localizationKey)
                        } ?? ""
                    )
                    .accessibilityIdentifier("provider-option.\(provider.rawValue)")
                }
            } label: {
                HStack(spacing: 6) {
                    if providerCoordinator.isProviderSwitchInProgress {
                        ProgressView()
                    } else {
                        Image(systemName: activeProvider.systemImage)
                            .imageScale(.small)
                    }
                    Text(activeProvider.navigationDisplayName)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(width: 160, alignment: .leading)
                .frame(minHeight: 50)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .focused(focus)
            .disabled(
                !isVisible
                    || !isInteractionReady
                    || providerCoordinator.isProviderInteractionBlocked
            )
            .accessibilityLabel(L10n.text("cloud_service"))
            .accessibilityValue(activeProvider.displayName)
            .accessibilityIdentifier("provider-switcher")
            .cloudProviderSwitchConfirmation(
                prompt: $providerSwitchPrompt,
                onSwitch: switchProvider
            )
        }
    }

    private func requestProviderSwitch(to provider: CloudGamingProvider) {
        let requirement = sessionCoordinator.switchRequirement(to: provider)
        switch requirement {
        case .allowed:
            switchProvider(to: provider)
        case .leaveOrEnd, .endParkedSession:
            providerSwitchPrompt = CloudProviderSwitchPrompt(
                targetProvider: provider,
                requirement: requirement
            )
        }
    }

    private func switchProvider(to provider: CloudGamingProvider) {
        guard let intent = providerCoordinator.beginProviderSwitch(to: provider)
        else {
            return
        }
        Task { @MainActor in
            await modeLifecycle.deactivateForInactiveProvider()
            guard !Task.isCancelled else {
                providerCoordinator.cancelProviderSwitch(intent)
                return
            }
            _ = providerCoordinator.commitProviderSwitch(intent)
        }
    }
}
