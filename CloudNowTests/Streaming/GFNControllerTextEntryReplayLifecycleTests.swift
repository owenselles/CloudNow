@testable import CloudNow
import Testing

@Suite("GFN controller text-entry replay lifecycle")
struct GFNTextReplayLifecycleTests {
    @Test("Rejected replay keeps text entry active")
    func rejectedReplayKeepsTextEntryActive() {
        var lifecycle = ControllerTextEntryReplayLifecycle()

        lifecycle.beginTextEntry()
        let replay = lifecycle.prepareReplay()
        let rejected = lifecycle.rejectReplay(replay)

        #expect(rejected)
        #expect(lifecycle.controllerTextEntryActive)
        #expect(!lifecycle.replayInputPaused)
        #expect(lifecycle.pendingReplay == nil)
        #expect(lifecycle.inputPaused(overlayPaused: false))
    }

    @Test("Reconnect invalidation isolates a replacement replay from stale completion")
    func reconnectInvalidationIsolatesReplacementReplay() {
        var lifecycle = ControllerTextEntryReplayLifecycle()

        lifecycle.beginTextEntry()
        let disconnectedReplay = lifecycle.prepareReplay()
        let disconnectedReplayAccepted = lifecycle.acceptReplay(disconnectedReplay)
        #expect(disconnectedReplayAccepted)
        #expect(!lifecycle.controllerTextEntryActive)
        #expect(lifecycle.replayInputPaused)
        #expect(lifecycle.inputPaused(overlayPaused: false))

        let invalidatedReplay = lifecycle.invalidate()
        #expect(invalidatedReplay == disconnectedReplay)
        #expect(!lifecycle.controllerTextEntryActive)
        #expect(!lifecycle.replayInputPaused)
        #expect(!lifecycle.inputPaused(overlayPaused: false))
        #expect(lifecycle.inputPaused(overlayPaused: true))

        lifecycle.beginTextEntry()
        let replacementReplay = lifecycle.prepareReplay()
        let replacementReplayAccepted = lifecycle.acceptReplay(replacementReplay)
        #expect(replacementReplayAccepted)

        let staleReplayFinished = lifecycle.finishReplay(disconnectedReplay)
        #expect(!staleReplayFinished)
        #expect(lifecycle.pendingReplay == replacementReplay)
        #expect(lifecycle.replayInputPaused)

        let replacementReplayFinished = lifecycle.finishReplay(replacementReplay)
        #expect(replacementReplayFinished)
        #expect(lifecycle.pendingReplay == nil)
        #expect(!lifecycle.replayInputPaused)
    }
}
