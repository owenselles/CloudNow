@testable import CloudNow
import Testing
import UIKit

@Suite("Video surface UIKit responder phases")
@MainActor
struct CloudStreamResponderCancellationTests {
    @Test("Mixed cancellation forwards only unhandled presses with the cancelled phase")
    func mixedCancellation() {
        let parent = RecordingPressView()
        let surface = VideoSurfaceView()
        parent.addSubview(surface)
        let menu = SyntheticPress(.menu)
        let arrow = SyntheticPress(.upArrow)
        surface.pressesBegan([menu, arrow], with: nil)
        #expect(parent.began == [ObjectIdentifier(arrow)])
        surface.pressesCancelled([menu, arrow], with: nil)
        #expect(parent.cancelled == [ObjectIdentifier(arrow)])
        #expect(parent.ended.isEmpty)
    }
}

private final class SyntheticPress: UIPress {
    private let suppliedType: UIPress.PressType
    init(_ type: UIPress.PressType) {
        suppliedType = type
        super.init()
    }

    override var type: UIPress.PressType {
        suppliedType
    }
}

private final class RecordingPressView: UIView {
    var began: Set<ObjectIdentifier> = []
    var ended: Set<ObjectIdentifier> = []
    var cancelled: Set<ObjectIdentifier> = []

    override func pressesBegan(_ presses: Set<UIPress>, with _: UIPressesEvent?) {
        began.formUnion(presses.map(ObjectIdentifier.init))
    }

    override func pressesEnded(_ presses: Set<UIPress>, with _: UIPressesEvent?) {
        ended.formUnion(presses.map(ObjectIdentifier.init))
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with _: UIPressesEvent?) {
        cancelled.formUnion(presses.map(ObjectIdentifier.init))
    }
}
