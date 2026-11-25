@testable import CloudNow
import Foundation
import GameController
import Testing

@Suite("GFN physical mouse input")
struct InputSenderMouseTests {
    @MainActor
    @Test("A mouse without a profile at connection gets handlers when it becomes current")
    func attachesWhenProfileBecomesAvailable() {
        let mouse = DelayedProfileMouse()
        let channel = MouseTestChannel()
        let sender = InputSender(channel: channel)
        sender.start()
        let center = NotificationCenter.default
        center.post(name: .GCMouseDidConnect, object: mouse)
        center.post(name: .GCMouseDidBecomeCurrent, object: mouse)
        // Both notifications finish on the sender's serial queue before stop returns.
        sender.stop()

        #expect(mouse.profile.didInstallMovementHandler)
    }
}

private final class DelayedProfileMouse: GCMouse {
    let profile = RecordingMouseProfile()
    private var isProfileAvailable = false

    override var mouseInput: GCMouseInput? {
        defer { isProfileAvailable = true }
        return isProfileAvailable ? profile : nil
    }
}

private final class RecordingMouseProfile: GCMouseInput {
    private(set) var didInstallMovementHandler = false

    override var mouseMovedHandler: GCMouseMoved? {
        didSet {
            if mouseMovedHandler != nil {
                didInstallMovementHandler = true
            }
        }
    }
}

private final class MouseTestChannel: DataChannelSender {
    func sendData(_: EncodedInputPacket, completion: @escaping @Sendable (InputSendDisposition) -> Void) {
        completion(.accepted)
    }
}
