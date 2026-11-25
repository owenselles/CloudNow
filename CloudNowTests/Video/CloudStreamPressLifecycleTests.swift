@testable import CloudNow
import Foundation
import Testing
import UIKit

@MainActor
@Suite("Press sequences across input handshakes and local overlays")
struct CloudStreamPressLifecycleTests {
    @Test("Enter before the input handshake never becomes a mouse click or an unmatched key release")
    func handshakeDoesNotChangeOwner() {
        let lifecycle = CloudStreamPressLifecycle()
        let press = NSObject()
        let sender = PressRecorder()
        #expect(begin(lifecycle, press, key: .keyboardReturnOrEnter, handler: nil) == .keyboard)
        #expect(lifecycle.end(id: ObjectIdentifier(press)))
        #expect(sender.events.isEmpty)
        #expect(begin(lifecycle, press, key: .keyboardReturnOrEnter, handler: sender) == .keyboard)
        lifecycle.end(id: ObjectIdentifier(press))
        #expect(sender.events == ["key:40:true", "key:40:false"])
    }

    @Test("A replacement sender never receives a release for a different sender's press")
    func senderReplacement() {
        let lifecycle = CloudStreamPressLifecycle()
        let press = NSObject()
        let first = PressRecorder()
        let replacement = PressRecorder()
        _ = begin(lifecycle, press, key: .keyboardSpacebar, handler: first)
        // Rebinding the surface cannot replace the recipient stored by begin().
        lifecycle.end(id: ObjectIdentifier(press))
        #expect(first.events == ["key:44:true", "key:44:false"])
        #expect(replacement.events.isEmpty)
        _ = begin(lifecycle, press, key: .keyboardSpacebar, handler: replacement)
        lifecycle.cancelAll()
        #expect(replacement.events == ["key:44:true", "key:44:false"])
        #expect(!lifecycle.end(id: ObjectIdentifier(press)))
    }

    @Test("Siri Remote Select remains held while physical Enter begins and ends")
    func simultaneousRemoteAndKeyboard() {
        let lifecycle = CloudStreamPressLifecycle()
        let remote = NSObject()
        let enter = NSObject()
        let sender = PressRecorder()
        #expect(begin(lifecycle, remote, key: nil, handler: sender) == .remoteClick)
        #expect(begin(lifecycle, enter, key: .keyboardReturnOrEnter, handler: sender) == .keyboard)
        lifecycle.end(id: ObjectIdentifier(enter))
        #expect(sender.events == ["mouse:true", "key:40:true", "key:40:false"])
        lifecycle.end(id: ObjectIdentifier(remote))
        #expect(sender.events.last == "mouse:false")
    }

    @Test("Overlay cancellation releases only the held mouse button, once")
    func cancellationAndLateRelease() {
        let lifecycle = CloudStreamPressLifecycle()
        let remote = NSObject()
        let key = NSObject()
        let sender = PressRecorder()
        _ = begin(lifecycle, remote, key: nil, handler: sender)
        _ = begin(lifecycle, key, key: .keyboardSpacebar, handler: sender)
        lifecycle.cancelRemoteMousePresses()
        lifecycle.cancelRemoteMousePresses()
        lifecycle.end(id: ObjectIdentifier(remote))
        lifecycle.cancelAll()
        #expect(sender.events == ["mouse:true", "key:44:true", "mouse:false", "key:44:false"])
    }

    @Test("Escape dismisses a local overlay and its release never leaks into the game")
    func localEscapeAndXboxPolicy() {
        let lifecycle = CloudStreamPressLifecycle()
        let escape = NSObject()
        let sender = PressRecorder()
        #expect(begin(lifecycle, escape, key: .keyboardEscape, handler: sender, overlay: true) == .dismissOverlay)
        lifecycle.end(id: ObjectIdentifier(escape))
        #expect(sender.events.isEmpty)
        #expect(begin(lifecycle, escape, key: .keyboardEscape, handler: sender, priority: false) == .overlay)
        lifecycle.end(id: ObjectIdentifier(escape))
        #expect(sender.events.isEmpty)
    }

    @Test("GFN binds the keyboard policy before a sender exists and Escape does not toggle Pause")
    func earlyBindingAndDismissal() {
        let controller = GFNStreamController()
        let surface = VideoSurfaceView(frame: .zero)
        controller.bindVideoView(surface)
        #expect(surface.inputHandler == nil)
        #expect(surface.prefersHardwareKeyboardPresses)
        controller.setOverlayInputPaused(true)
        #expect(surface.hardwareKeyboardOverlayActive)
        surface.hardwareEscapeHandler?()
        #expect(controller.overlayDismissRequestCount == 1)
        #expect(controller.menuPressCount == 0)
        #expect(!surface.hardwareKeyboardOverlayActive)
        surface.menuPressHandler?()
        #expect(controller.menuPressCount == 1)
        surface.prepareForDismantle()
    }

    private func begin(
        _ lifecycle: CloudStreamPressLifecycle,
        _ token: NSObject,
        key: UIKeyboardHIDUsage?,
        handler: InputEventHandler?,
        overlay: Bool = false,
        priority: Bool = true
    ) -> CloudStreamPressAction {
        lifecycle.begin(
            id: ObjectIdentifier(token), type: key == .keyboardEscape ? .menu : .select,
            key: key, modifiers: [], prefersHardwareKeyboard: priority,
            overlayVisible: overlay, remoteMouseEnabled: true, handler: handler
        )
    }
}

private final nonisolated class PressRecorder: InputEventHandler {
    var events: [String] = []

    func sendKeyEvent(down: Bool, keyCode: UIKeyboardHIDUsage, modifiers _: UIKeyModifierFlags) {
        events.append("key:\(keyCode.rawValue):\(down)")
    }

    func sendMouseButton(down: Bool, button _: UInt8) {
        events.append("mouse:\(down)")
    }

    func sendMouseMove(dx _: Int16, dy _: Int16) {}
    func sendMouseWheel(delta _: Int16) {}
}
