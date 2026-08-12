@preconcurrency import GameController
@preconcurrency import LiveKitWebRTC
import SwiftUI

/// Xbox mode's thin SwiftUI bridge to CloudNow's tvOS-native video renderer.
/// The renderer and decoder are shared infrastructure; input and session
/// behavior remain owned by the Xbox provider mode.
struct XboxVideoSurfaceView: UIViewControllerRepresentable {
    let videoTrack: LKRTCVideoTrack?
    let showsOverlay: Bool
    let onMenuPress: () -> Void
    let onKeyboardEvent: (Bool, UInt8) -> Void
    let onDecodedVideoFormatChanged: @Sendable (DecodedVideoFormat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onMenuPress: onMenuPress,
            onKeyboardEvent: onKeyboardEvent
        )
    }

    func makeUIViewController(context: Context) -> StreamingViewController {
        let controller = StreamingViewController()
        controller.videoSurface.gamepadModeActive = true
        controller.videoSurface.menuPressHandler = onMenuPress
        controller.videoSurface.inputHandler = context.coordinator.inputHandler
        controller.videoSurface.onDecodedVideoFormatChanged = onDecodedVideoFormatChanged
        return controller
    }

    func updateUIViewController(
        _ controller: StreamingViewController,
        context: Context
    ) {
        context.coordinator.update(
            onMenuPress: onMenuPress,
            onKeyboardEvent: onKeyboardEvent
        )
        controller.videoSurface.videoTrack = videoTrack
        controller.videoSurface.gamepadModeActive = true
        controller.videoSurface.menuPressHandler = onMenuPress
        controller.videoSurface.inputHandler = context.coordinator.inputHandler
        controller.videoSurface.onDecodedVideoFormatChanged = onDecodedVideoFormatChanged
        controller.controllerUserInteractionEnabled = showsOverlay
        controller.videoSurface.overlayVisible = showsOverlay
    }

    static func dismantleUIViewController(
        _ controller: StreamingViewController,
        coordinator _: Coordinator
    ) {
        controller.videoSurface.prepareForDismantle()
    }

    final class Coordinator {
        fileprivate let inputHandler: XboxCloudResponderInputHandler

        fileprivate init(
            onMenuPress: @escaping () -> Void,
            onKeyboardEvent: @escaping (Bool, UInt8) -> Void
        ) {
            inputHandler = XboxCloudResponderInputHandler(
                onMenuPress: onMenuPress,
                onKeyboardEvent: onKeyboardEvent
            )
        }

        fileprivate func update(
            onMenuPress: @escaping () -> Void,
            onKeyboardEvent: @escaping (Bool, UInt8) -> Void
        ) {
            inputHandler.update(
                onMenuPress: onMenuPress,
                onKeyboardEvent: onKeyboardEvent
            )
        }
    }
}

/// The tvOS Simulator's connected Mac keyboard arrives through UIKit presses,
/// not GCKeyboard. Keep that fallback at the shared responder boundary and
/// compile-gate its forwarding policy so physical Apple TV input remains on the
/// existing GameController path.
private final class XboxCloudResponderInputHandler: InputEventHandler {
    private var keyboardState = XboxCloudResponderKeyboardState()
    private var onMenuPress: () -> Void
    private var onKeyboardEvent: (Bool, UInt8) -> Void

    init(
        onMenuPress: @escaping () -> Void,
        onKeyboardEvent: @escaping (Bool, UInt8) -> Void
    ) {
        self.onMenuPress = onMenuPress
        self.onKeyboardEvent = onKeyboardEvent
    }

    func update(
        onMenuPress: @escaping () -> Void,
        onKeyboardEvent: @escaping (Bool, UInt8) -> Void
    ) {
        self.onMenuPress = onMenuPress
        self.onKeyboardEvent = onKeyboardEvent
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

    func sendMouseMove(dx _: Int16, dy _: Int16) {}

    func sendMouseButton(down _: Bool, button _: UInt8) {}

    func sendMouseWheel(delta _: Int16) {}
}
