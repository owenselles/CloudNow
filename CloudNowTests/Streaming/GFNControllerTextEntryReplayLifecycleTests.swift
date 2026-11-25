@testable import CloudNow
import Testing

@Suite("GFN controller text-entry replay lifecycle")
struct GFNTextReplayLifecycleTests {
    @Test("Queued presentation cannot reopen text entry after dismissal in either callback order", arguments: [true, false])
    func presentationAndDismissalOrder(dismissalFirst: Bool) {
        var lifecycle = ControllerTextEntryReplayLifecycle()
        var overlay = StreamOverlayState.none
        lifecycle.beginTextEntry()
        if dismissalFirst {
            lifecycle.invalidate()
        }
        if lifecycle.shouldPresentTextEntry(requestIsCurrent: true, isStreaming: true, overlay: overlay) {
            overlay = .textEntry
        }
        if !dismissalFirst {
            lifecycle.invalidate(); overlay = .none
        }
        #expect(overlay == .none)
        #expect(!lifecycle.inputPaused(overlayPaused: overlay != .none))
    }

    @Test("An active shortcut presents normally, while stale or blocked requests do not")
    func activePresentation() {
        var lifecycle = ControllerTextEntryReplayLifecycle()
        lifecycle.beginTextEntry()
        #expect(lifecycle.shouldPresentTextEntry(requestIsCurrent: true, isStreaming: true, overlay: .none))
        #expect(lifecycle.inputPaused(overlayPaused: false))
        #expect(!lifecycle.shouldPresentTextEntry(requestIsCurrent: false, isStreaming: true, overlay: .none))
        #expect(!lifecycle.shouldPresentTextEntry(requestIsCurrent: true, isStreaming: false, overlay: .none))
        #expect(!lifecycle.shouldPresentTextEntry(requestIsCurrent: true, isStreaming: true, overlay: .pauseMenu))
    }

    @Test("Rejected replay keeps text entry active")
    func rejectedReplayKeepsTextEntryActive() throws {
        var lifecycle = ControllerTextEntryReplayLifecycle()

        lifecycle.beginTextEntry()
        let preparedReplay = lifecycle.prepareReplay()
        let replay = try #require(preparedReplay)
        let rejected = lifecycle.rejectReplay(replay)

        #expect(rejected)
        #expect(lifecycle.controllerTextEntryActive)
        #expect(!lifecycle.replayInputPaused)
        #expect(lifecycle.pendingReplay == nil)
        #expect(lifecycle.inputPaused(overlayPaused: false))
    }

    @Test("Reconnect invalidation isolates a replacement replay from stale completion")
    func reconnectInvalidationIsolatesReplacementReplay() throws {
        var lifecycle = ControllerTextEntryReplayLifecycle()

        lifecycle.beginTextEntry()
        let preparedDisconnectedReplay = lifecycle.prepareReplay()
        let disconnectedReplay = try #require(preparedDisconnectedReplay)
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

        let preparedReplacementReplay = lifecycle.prepareReplay()
        let replacementReplay = try #require(preparedReplacementReplay)
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

    @Test("A pending replay remains authoritative when submit fires twice")
    func duplicateReplayPreparationIsRejected() throws {
        var lifecycle = ControllerTextEntryReplayLifecycle()

        lifecycle.beginTextEntry()
        let preparedFirstReplay = lifecycle.prepareReplay()
        let firstReplay = try #require(preparedFirstReplay)
        let duplicateReplay = lifecycle.prepareReplay()

        #expect(duplicateReplay == nil)
        #expect(lifecycle.pendingReplay == firstReplay)

        let firstReplayAccepted = lifecycle.acceptReplay(firstReplay)
        #expect(firstReplayAccepted)
        #expect(lifecycle.replayInputPaused)
    }
}
