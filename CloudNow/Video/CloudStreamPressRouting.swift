import UIKit

nonisolated enum CloudStreamPressAction: Equatable {
    case keyboard
    case overlay
    case dismissOverlay
    case consumed
    case remoteClick
    case unhandled
}

nonisolated enum CloudStreamPressRouting {
    static func action(
        type: UIPress.PressType,
        keyCode: UIKeyboardHIDUsage?,
        overlayVisible: Bool,
        remoteMouseEnabled: Bool,
        prefersHardwareKeyboard: Bool = true
    ) -> CloudStreamPressAction {
        if let keyCode, prefersHardwareKeyboard {
            // Hardware Escape/Enter/Space can share press types with remote buttons.
            // Keep Escape for the game unless a local overlay is already open.
            return overlayVisible && keyCode == .keyboardEscape ? .dismissOverlay : .keyboard
        }
        switch type {
        case .menu, .playPause: return .overlay
        case .select where remoteMouseEnabled: return .remoteClick
        default: return keyCode == nil ? .unhandled : .keyboard
        }
    }
}

/// Main-actor ownership of a physical press, independent of a later input handshake.
/// A press with no sender is consumed without manufacturing a release on a new sender.
@MainActor
final class CloudStreamPressLifecycle {
    private final class HeldPress {
        let action: CloudStreamPressAction
        weak var handler: InputEventHandler?
        let key: UIKeyboardHIDUsage?
        let modifiers: UIKeyModifierFlags
        var released = false

        init(action: CloudStreamPressAction, handler: InputEventHandler?, key: UIKeyboardHIDUsage?, modifiers: UIKeyModifierFlags) {
            self.action = action
            self.handler = handler
            self.key = key
            self.modifiers = modifiers
        }
    }

    private var held: [ObjectIdentifier: HeldPress] = [:]

    func begin(
        id: ObjectIdentifier,
        type: UIPress.PressType,
        key: UIKeyboardHIDUsage?,
        modifiers: UIKeyModifierFlags,
        prefersHardwareKeyboard: Bool,
        overlayVisible: Bool,
        remoteMouseEnabled: Bool,
        handler: InputEventHandler?
    ) -> CloudStreamPressAction {
        guard held[id] == nil else { return .consumed }
        let action = CloudStreamPressRouting.action(
            type: type, keyCode: key, overlayVisible: overlayVisible,
            remoteMouseEnabled: remoteMouseEnabled, prefersHardwareKeyboard: prefersHardwareKeyboard
        )
        guard action != .unhandled else { return action }
        let press = HeldPress(action: action, handler: handler, key: key, modifiers: modifiers)
        held[id] = press
        if action == .keyboard, let key {
            handler?.sendKeyEvent(down: true, keyCode: key, modifiers: modifiers)
        } else if action == .remoteClick {
            let anotherHeld = held.values.contains { $0 !== press && $0.action == .remoteClick && !$0.released && $0.handler === handler }
            if !anotherHeld {
                handler?.sendMouseButton(down: true, button: 1)
            }
        }
        return action
    }

    @discardableResult
    func end(id: ObjectIdentifier) -> Bool {
        guard let press = held.removeValue(forKey: id) else { return false }
        release(press)
        return true
    }

    func cancelRemoteMousePresses() {
        for press in held.values where press.action == .remoteClick {
            release(press)
        }
    }

    func cancelAll() {
        for id in Array(held.keys) {
            end(id: id)
        }
    }

    private func release(_ press: HeldPress) {
        guard !press.released else { return }
        press.released = true
        if press.action == .keyboard, let key = press.key {
            press.handler?.sendKeyEvent(down: false, keyCode: key, modifiers: press.modifiers)
        } else if press.action == .remoteClick {
            let anotherHeld = held.values.contains {
                $0.action == .remoteClick && !$0.released && $0.handler === press.handler
            }
            if !anotherHeld {
                press.handler?.sendMouseButton(down: false, button: 1)
            }
        }
    }
}
