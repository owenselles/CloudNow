@preconcurrency import GameController
import Observation
import SwiftUI
import UIKit

enum UIControllerNavigationMode: Equatable {
    case tabs
    case carousel
    case modal
    case streaming
}

/// Owns physical-controller handlers used by the application UI.
///
/// SwiftUI remains responsible for Siri Remote and D-pad focus navigation. This coordinator only
/// handles controls that the focus engine does not expose consistently (shoulders and thumbsticks),
/// and guarantees that one application-UI owner updates those handlers at a time.
@Observable
@MainActor
final class UIControllerNavigationCoordinator {
    private(set) var activeMode: UIControllerNavigationMode = .tabs

    @ObservationIgnored private var rootActions = Actions()
    @ObservationIgnored private var contexts: [Context] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    isolated deinit {
        stop()
    }

    func start(
        onPreviousTab: @escaping () -> Void,
        onNextTab: @escaping () -> Void
    ) {
        rootActions = Actions(previous: onPreviousTab, next: onNextTab)

        if observers.isEmpty {
            registerForControllerNotifications()
        }
        refreshControllerHandlers()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        contexts.removeAll()
        rootActions = Actions()
        activeMode = .tabs
        clearOwnedHandlers()
    }

    func activateContext(
        id: UUID,
        mode: UIControllerNavigationMode,
        onPrevious: @escaping () -> Void = {},
        onNext: @escaping () -> Void = {}
    ) {
        let context = Context(
            id: id,
            mode: mode,
            actions: Actions(previous: onPrevious, next: onNext)
        )

        if let index = contexts.firstIndex(where: { $0.id == id }) {
            contexts[index] = context
        } else {
            contexts.append(context)
        }
        refreshActiveContext()
    }

    func deactivateContext(id: UUID) {
        guard contexts.contains(where: { $0.id == id }) else { return }
        contexts.removeAll { $0.id == id }
        refreshActiveContext()
    }

    private func refreshActiveContext() {
        let mode = contexts.last?.mode ?? .tabs
        if activeMode != mode {
            activeMode = mode
        }
        refreshControllerHandlers()
    }

    private func registerForControllerNotifications() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] notification in
                guard let controller = notification.object as? GCController else { return }
                MainActor.assumeIsolated {
                    self?.installHandlers(on: controller)
                }
            }
        )
        observers.append(
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshControllerHandlers()
                }
            }
        )
    }

    private func refreshControllerHandlers() {
        GCController.controllers().forEach(installHandlers)
    }

    private func installHandlers(on controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        clearOwnedHandlers(on: gamepad)

        let activeContext = contexts.last
        let mode = activeContext?.mode ?? .tabs
        let actions = activeContext?.actions ?? rootActions

        switch mode {
        case .tabs:
            gamepad.leftShoulder.pressedChangedHandler = handler(
                for: actions.previous,
                expectedMode: .tabs,
                requiresUnobscuredUI: true
            )
            gamepad.rightShoulder.pressedChangedHandler = handler(
                for: actions.next,
                expectedMode: .tabs,
                requiresUnobscuredUI: true
            )
        case .carousel:
            let previousHandler = handler(for: actions.previous, expectedMode: .carousel)
            let nextHandler = handler(for: actions.next, expectedMode: .carousel)
            gamepad.leftThumbstick.left.pressedChangedHandler = previousHandler
            gamepad.rightThumbstick.left.pressedChangedHandler = previousHandler
            gamepad.leftThumbstick.right.pressedChangedHandler = nextHandler
            gamepad.rightThumbstick.right.pressedChangedHandler = nextHandler
        case .modal, .streaming:
            break
        }
    }

    private func handler(
        for action: @escaping () -> Void,
        expectedMode: UIControllerNavigationMode,
        requiresUnobscuredUI: Bool = false
    ) -> GCControllerButtonValueChangedHandler {
        { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      activeMode == expectedMode,
                      !requiresUnobscuredUI || !hasPresentedContent
                else { return }
                action()
            }
        }
    }

    private var hasPresentedContent: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { window in
                window.rootViewController?.presentedViewController != nil
            }
    }

    private func clearOwnedHandlers() {
        for controller in GCController.controllers() {
            guard let gamepad = controller.extendedGamepad else { continue }
            clearOwnedHandlers(on: gamepad)
        }
    }

    private func clearOwnedHandlers(on gamepad: GCExtendedGamepad) {
        gamepad.leftShoulder.pressedChangedHandler = nil
        gamepad.rightShoulder.pressedChangedHandler = nil
        gamepad.leftThumbstick.left.pressedChangedHandler = nil
        gamepad.rightThumbstick.left.pressedChangedHandler = nil
        gamepad.leftThumbstick.right.pressedChangedHandler = nil
        gamepad.rightThumbstick.right.pressedChangedHandler = nil
    }

    private struct Actions {
        var previous: () -> Void = {}
        var next: () -> Void = {}
    }

    private struct Context {
        let id: UUID
        let mode: UIControllerNavigationMode
        let actions: Actions
    }
}

private struct ControllerNavigationBlocker: ViewModifier {
    @Environment(UIControllerNavigationCoordinator.self) private var coordinator
    @State private var contextID = UUID()

    let mode: UIControllerNavigationMode

    func body(content: Content) -> some View {
        content
            .onAppear {
                coordinator.activateContext(id: contextID, mode: mode)
            }
            .onDisappear {
                coordinator.deactivateContext(id: contextID)
            }
    }
}

private struct CarouselControllerNavigation: ViewModifier {
    @Environment(UIControllerNavigationCoordinator.self) private var coordinator
    @State private var contextID = UUID()

    let isEnabled: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: updateContext)
            .onChange(of: isEnabled) {
                updateContext()
            }
            .onDisappear {
                coordinator.deactivateContext(id: contextID)
            }
    }

    private func updateContext() {
        coordinator.activateContext(
            id: contextID,
            mode: isEnabled ? .carousel : .modal,
            onPrevious: onPrevious,
            onNext: onNext
        )
    }
}

extension View {
    func blocksGlobalControllerNavigation(
        mode: UIControllerNavigationMode = .modal
    ) -> some View {
        modifier(ControllerNavigationBlocker(mode: mode))
    }

    func handlesCarouselControllerNavigation(
        isEnabled: Bool,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void
    ) -> some View {
        modifier(CarouselControllerNavigation(
            isEnabled: isEnabled,
            onPrevious: onPrevious,
            onNext: onNext
        ))
    }
}
