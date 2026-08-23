@preconcurrency import GameController
@preconcurrency import LiveKitWebRTC
import SwiftUI

/// Xbox mode's thin SwiftUI bridge to CloudNow's tvOS-native video renderer.
/// The renderer and decoder are shared infrastructure; input and session
/// behavior remain owned by the Xbox provider mode.
struct XboxVideoSurfaceView: UIViewControllerRepresentable {
    let videoTrack: LKRTCVideoTrack?
    let showsOverlay: Bool
    let hasGamepadController: Bool
    let onMenuPress: () -> Void
    let onKeyboardEvent: (Bool, UInt8) -> Void
    let onMouseReport: (XboxMouseReport) -> Void
    let onDecodedVideoFormatChanged: @Sendable (DecodedVideoFormat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onMenuPress: onMenuPress,
            onKeyboardEvent: onKeyboardEvent,
            onMouseReport: onMouseReport
        )
    }

    func makeUIViewController(context: Context) -> StreamingViewController {
        let controller = StreamingViewController()
        controller.videoSurface.menuPressHandler = onMenuPress
        controller.videoSurface.inputHandler = context.coordinator.inputHandler
        controller.videoSurface.onDecodedVideoFormatChanged = onDecodedVideoFormatChanged
        context.coordinator.applyInputRouting(
            to: controller,
            showsOverlay: showsOverlay,
            hasGamepadController: hasGamepadController
        )
        return controller
    }

    func updateUIViewController(
        _ controller: StreamingViewController,
        context: Context
    ) {
        context.coordinator.update(
            onMenuPress: onMenuPress,
            onKeyboardEvent: onKeyboardEvent,
            onMouseReport: onMouseReport
        )
        controller.videoSurface.videoTrack = videoTrack
        controller.videoSurface.menuPressHandler = onMenuPress
        controller.videoSurface.inputHandler = context.coordinator.inputHandler
        controller.videoSurface.onDecodedVideoFormatChanged = onDecodedVideoFormatChanged
        context.coordinator.applyInputRouting(
            to: controller,
            showsOverlay: showsOverlay,
            hasGamepadController: hasGamepadController
        )
    }

    static func dismantleUIViewController(
        _ controller: StreamingViewController,
        coordinator: Coordinator
    ) {
        coordinator.inputHandler.resetAllInput()
        controller.videoSurface.prepareForDismantle()
    }

    final class Coordinator {
        fileprivate let inputHandler: XboxCloudResponderInputHandler
        private var previousShowsOverlay: Bool?

        fileprivate init(
            onMenuPress: @escaping () -> Void,
            onKeyboardEvent: @escaping (Bool, UInt8) -> Void,
            onMouseReport: @escaping (XboxMouseReport) -> Void
        ) {
            inputHandler = XboxCloudResponderInputHandler(
                onMenuPress: onMenuPress,
                onKeyboardEvent: onKeyboardEvent,
                onMouseReport: onMouseReport
            )
        }

        fileprivate func update(
            onMenuPress: @escaping () -> Void,
            onKeyboardEvent: @escaping (Bool, UInt8) -> Void,
            onMouseReport: @escaping (XboxMouseReport) -> Void
        ) {
            inputHandler.update(
                onMenuPress: onMenuPress,
                onKeyboardEvent: onKeyboardEvent,
                onMouseReport: onMouseReport
            )
        }

        fileprivate func applyInputRouting(
            to controller: StreamingViewController,
            showsOverlay: Bool,
            hasGamepadController: Bool
        ) {
            #if targetEnvironment(simulator)
                let isSimulator = true
            #else
                let isSimulator = false
            #endif
            let routing = XboxCloudVideoSurfaceInputRouting.resolve(
                isSimulator: isSimulator,
                showsOverlay: showsOverlay,
                hasGamepadController: hasGamepadController
            )
            controller.controllerUserInteractionEnabled =
                routing.controllerUserInteractionEnabled
            controller.videoSurface.gamepadModeActive = routing.gamepadModeActive
            controller.videoSurface.overlayVisible = showsOverlay

            if previousShowsOverlay == false,
               showsOverlay
            {
                inputHandler.resetGameplayInput()
            }
            if previousShowsOverlay == true,
               !showsOverlay
            {
                inputHandler.resetAllInput()
                let videoSurface = controller.videoSurface
                Task { @MainActor [weak videoSurface] in
                    await Task.yield()
                    guard let videoSurface,
                          videoSurface.window != nil,
                          !videoSurface.overlayVisible
                    else {
                        return
                    }
                    videoSurface.becomeFirstResponder()
                }
            }
            previousShowsOverlay = showsOverlay
        }
    }
}

nonisolated struct XboxCloudVideoSurfaceInputRouting: Equatable, Sendable {
    let controllerUserInteractionEnabled: Bool
    let gamepadModeActive: Bool

    static func resolve(
        isSimulator: Bool,
        showsOverlay: Bool,
        hasGamepadController: Bool
    ) -> Self {
        if isSimulator {
            return Self(
                controllerUserInteractionEnabled: showsOverlay
                    || !hasGamepadController,
                gamepadModeActive: false
            )
        }
        return Self(
            controllerUserInteractionEnabled: showsOverlay,
            gamepadModeActive: true
        )
    }
}

/// The tvOS Simulator's connected Mac keyboard arrives through UIKit presses,
/// not GCKeyboard. Keep that fallback at the shared responder boundary and
/// compile-gate its forwarding policy so physical Apple TV input remains on the
/// existing GameController path.
private final class XboxCloudResponderInputHandler: InputEventHandler {
    private var keyboardState = XboxCloudResponderKeyboardState()
    private var mouseState = XboxCloudResponderMouseState()
    private var onMenuPress: () -> Void
    private var onKeyboardEvent: (Bool, UInt8) -> Void
    private var onMouseReport: (XboxMouseReport) -> Void

    init(
        onMenuPress: @escaping () -> Void,
        onKeyboardEvent: @escaping (Bool, UInt8) -> Void,
        onMouseReport: @escaping (XboxMouseReport) -> Void
    ) {
        self.onMenuPress = onMenuPress
        self.onKeyboardEvent = onKeyboardEvent
        self.onMouseReport = onMouseReport
    }

    func update(
        onMenuPress: @escaping () -> Void,
        onKeyboardEvent: @escaping (Bool, UInt8) -> Void,
        onMouseReport: @escaping (XboxMouseReport) -> Void
    ) {
        self.onMenuPress = onMenuPress
        self.onKeyboardEvent = onKeyboardEvent
        self.onMouseReport = onMouseReport
    }

    func sendKeyEvent(
        down: Bool,
        keyCode: UIKeyboardHIDUsage,
        modifiers _: UIKeyModifierFlags
    ) {
        #if targetEnvironment(simulator)
            let isSimulator = true
        #else
            let isSimulator = false
        #endif
        switch keyboardState.action(
            keyCode: keyCode,
            isPressed: down,
            isSimulator: isSimulator,
            hasGameControllerKeyboard: GCKeyboard.coalesced != nil
        ) {
        case .ignored:
            break
        case .togglePauseMenu:
            onMenuPress()
        case let .keyboard(isPressed, virtualKey):
            onKeyboardEvent(isPressed, virtualKey)
        }
    }

    func sendMouseMove(dx: Int16, dy: Int16) {
        guard let report = mouseState.moved(dx: dx, dy: dy) else { return }
        onMouseReport(report)
    }

    func sendMouseButton(down: Bool, button: UInt8) {
        guard let report = mouseState.changedButton(
            button,
            isPressed: down
        ) else {
            return
        }
        onMouseReport(report)
    }

    func sendMouseWheel(delta: Int16) {
        guard let report = mouseState.scrolled(delta: delta) else { return }
        onMouseReport(report)
    }

    func resetGameplayInput() {
        keyboardState.resetGameplayKeys()
        mouseState.reset()
    }

    func resetAllInput() {
        keyboardState.reset()
        mouseState.reset()
    }
}

nonisolated struct XboxCloudResponderMouseState: Sendable {
    private var buttons: XboxMouseButtons = []

    mutating func moved(dx: Int16, dy: Int16) -> XboxMouseReport? {
        guard dx != 0 || dy != 0 else { return nil }
        return XboxMouseReport(
            x: Int32(dx),
            y: Int32(dy),
            buttons: buttons
        )
    }

    mutating func changedButton(
        _ button: UInt8,
        isPressed: Bool
    ) -> XboxMouseReport? {
        guard let mappedButton = Self.mappedButton(button) else { return nil }
        if isPressed {
            buttons.insert(mappedButton)
        } else {
            buttons.remove(mappedButton)
        }
        return XboxMouseReport(buttons: buttons)
    }

    mutating func scrolled(delta: Int16) -> XboxMouseReport? {
        guard delta != 0 else { return nil }
        return XboxMouseReport(
            wheelY: Int32(delta),
            buttons: buttons
        )
    }

    mutating func reset() {
        buttons = []
    }

    private static func mappedButton(_ button: UInt8) -> XboxMouseButtons? {
        switch button {
        case 1:
            .left
        case 2:
            .middle
        case 3:
            .right
        case 4:
            .auxiliary1
        case 5:
            .auxiliary2
        default:
            nil
        }
    }
}
