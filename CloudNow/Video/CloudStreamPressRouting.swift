import UIKit

nonisolated enum CloudStreamPressAction: Equatable {
    case keyboard
    case overlay
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
            return overlayVisible && keyCode == .keyboardEscape ? .overlay : .keyboard
        }
        switch type {
        case .menu, .playPause: return .overlay
        case .select where remoteMouseEnabled: return .remoteClick
        default: return keyCode == nil ? .unhandled : .keyboard
        }
    }
}
