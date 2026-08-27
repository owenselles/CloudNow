@testable import CloudNow
import Testing

@Suite("Controller shortcut capture state")
@MainActor
struct ControllerShortcutCaptureStateTests {
    @Test("Starting without a controller reports the missing input explicitly")
    func noController() {
        var state = ControllerShortcutCaptureState()

        #expect(state.start(with: []) == .noControllers)
        #expect(state.phase == .idle)
    }

    @Test("The first active controller stays pinned until its chord is released")
    func firstActiveControllerIsPinned() {
        let firstController = ControllerIdentity()
        let secondController = ControllerIdentity()
        var state = ControllerShortcutCaptureState()
        let released = [
            reading(firstController),
            reading(secondController),
        ]

        #expect(state.start(with: released) == .none)
        #expect(state.update(with: released) == .none)
        #expect(state.phase == .waiting)
        #expect(state.update(with: [
            reading(firstController),
            reading(secondController, buttons: [.buttonB]),
        ]) == .none)
        #expect(state.pinnedControllerID == ObjectIdentifier(secondController))

        #expect(state.update(with: [
            reading(firstController, buttons: [.buttonA]),
            reading(secondController, buttons: [.buttonB, .buttonX]),
        ]) == .none)
        #expect(state.liveButtons == [.buttonB, .buttonX])

        #expect(state.update(with: [
            reading(firstController, buttons: [.buttonA]),
            reading(secondController),
        ]) == .completed(ControllerButtonSequence(buttons: [.buttonB, .buttonX])))
    }

    @Test("Face A and directional buttons can complete a chord")
    func focusEngineButtonsCompleteChord() {
        let controller = ControllerIdentity()
        let released = [reading(controller)]
        var state = ControllerShortcutCaptureState()

        #expect(state.start(with: released) == .none)
        #expect(state.update(with: released) == .none)
        #expect(state.update(with: [
            reading(controller, buttons: [.buttonA, .dpadLeft]),
        ]) == .none)
        #expect(state.update(with: released) == .completed(
            ControllerButtonSequence(buttons: [.buttonA, .dpadLeft])
        ))
    }

    @Test("Disconnecting the pinned controller stops capture")
    func pinnedControllerDisconnects() {
        let firstController = ControllerIdentity()
        let secondController = ControllerIdentity()
        var state = ControllerShortcutCaptureState()
        let released = [
            reading(firstController),
            reading(secondController),
        ]

        _ = state.start(with: released)
        _ = state.update(with: released)
        _ = state.update(with: [
            reading(firstController),
            reading(secondController, buttons: [.buttonY]),
        ])

        #expect(state.update(with: [reading(firstController)]) == .controllerDisconnected)
        #expect(state.phase == .idle)
        #expect(state.pinnedControllerID == nil)
        #expect(state.liveButtons.isEmpty)
    }

    @Test("Timeout and cancellation reset all capture state")
    func boundedStopsResetCapture() {
        let controller = ControllerIdentity()
        var state = ControllerShortcutCaptureState()

        #expect(ControllerShortcutCaptureState.timeout == .seconds(15))
        _ = state.start(with: [reading(controller)])
        #expect(state.expire() == .timedOut)
        #expect(state.phase == .idle)

        _ = state.start(with: [reading(controller)])
        state.cancel()
        #expect(state.phase == .idle)
        #expect(state.pinnedControllerID == nil)
    }

    private func reading(
        _ controller: ControllerIdentity,
        buttons: Set<ControllerSequenceButton> = []
    ) -> ControllerShortcutCaptureReading {
        ControllerShortcutCaptureReading(
            controllerID: ObjectIdentifier(controller),
            pressedButtons: buttons
        )
    }
}

private final class ControllerIdentity {}
