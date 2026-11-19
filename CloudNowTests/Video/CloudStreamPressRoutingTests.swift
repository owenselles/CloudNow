@testable import CloudNow
import Testing
import UIKit

@Suite("Hardware keyboard and remote press ownership")
struct CloudStreamPressRoutingTests {
    @Test("Hardware Escape reaches the game while remote Menu still opens the local overlay")
    func escapeOwnership() {
        #expect(route(.menu, key: .keyboardEscape) == .keyboard)
        #expect(route(.menu, key: nil) == .overlay)
        #expect(route(.menu, key: .keyboardEscape, overlay: true) == .overlay)
    }

    @Test("Hardware Enter and Space are not mistaken for remote click or Play/Pause")
    func keyboardOwnership() {
        #expect(route(.select, key: .keyboardReturnOrEnter, mouse: true) == .keyboard)
        #expect(route(.select, key: .keyboardReturnOrEnter, mouse: false) == .keyboard)
        #expect(route(.playPause, key: .keyboardSpacebar) == .keyboard)
        #expect(route(.upArrow, key: .keyboardUpArrow) == .keyboard)
    }

    @Test("Remote clicks respect the selected mode and unhandled presses keep UIKit behavior")
    func remoteOwnership() {
        #expect(route(.select, key: nil, mouse: true) == .remoteClick)
        #expect(route(.select, key: nil, mouse: false) == .unhandled)
        #expect(route(.playPause, key: nil) == .overlay)
        #expect(route(.leftArrow, key: nil) == .unhandled)
    }

    @Test("Providers without keyboard-priority opt-in retain their existing remote semantics")
    func providerIsolation() {
        #expect(CloudStreamPressRouting.action(
            type: .menu, keyCode: .keyboardEscape, overlayVisible: false,
            remoteMouseEnabled: false, prefersHardwareKeyboard: false
        ) == .overlay)
        #expect(CloudStreamPressRouting.action(
            type: .select, keyCode: .keyboardReturnOrEnter, overlayVisible: false,
            remoteMouseEnabled: true, prefersHardwareKeyboard: false
        ) == .remoteClick)
        #expect(CloudStreamPressRouting.action(
            type: .upArrow, keyCode: .keyboardUpArrow, overlayVisible: false,
            remoteMouseEnabled: false, prefersHardwareKeyboard: false
        ) == .keyboard)
    }

    private func route(
        _ type: UIPress.PressType,
        key: UIKeyboardHIDUsage?,
        overlay: Bool = false,
        mouse: Bool = false
    ) -> CloudStreamPressAction {
        CloudStreamPressRouting.action(type: type, keyCode: key, overlayVisible: overlay, remoteMouseEnabled: mouse)
    }
}
