@testable import CloudNow
import Testing

@Suite("Latest-frame renderer mailbox")
struct LatestFrameMailboxTests {
    @Test("Capacity one keeps only the newest frame and reports the displaced frame")
    func newestFrameReplacesPendingFrame() {
        var mailbox = LatestFrameMailbox<Int>()

        switch mailbox.store(1) {
        case let .stored(replacing: replaced):
            #expect(replaced == nil)
        case .rejected:
            Issue.record("An active mailbox should accept its first frame")
        }

        switch mailbox.store(2) {
        case let .stored(replacing: replaced):
            #expect(replaced == 1)
        case .rejected:
            Issue.record("An active mailbox should replace its pending frame")
        }

        let newest = mailbox.take()
        let empty = mailbox.take()
        #expect(newest == 2)
        #expect(empty == nil)
    }

    @Test("Conditional restore never displaces a newer pending frame")
    func restoreOnlyWhenEmpty() {
        var mailbox = LatestFrameMailbox<Int>()

        let storedFirst = mailbox.storeIfEmpty(10)
        let rejectedOlder = mailbox.storeIfEmpty(9)
        let first = mailbox.take()
        let storedSecond = mailbox.storeIfEmpty(11)
        let second = mailbox.take()

        #expect(storedFirst)
        #expect(!rejectedOlder)
        #expect(first == 10)
        #expect(storedSecond)
        #expect(second == 11)
    }

    @Test("Flush drops the pending frame but leaves the mailbox reusable")
    func flush() {
        var mailbox = LatestFrameMailbox<Int>()
        _ = mailbox.store(3)

        let flushed = mailbox.flush()
        #expect(flushed == 3)
        #expect(!mailbox.hasPending)

        switch mailbox.store(4) {
        case let .stored(replacing: replaced):
            #expect(replaced == nil)
        case .rejected:
            Issue.record("A flushed mailbox should remain active")
        }
        let next = mailbox.take()
        #expect(next == 4)
    }

    @Test("Teardown drops the pending frame and permanently rejects later frames")
    func teardown() {
        var mailbox = LatestFrameMailbox<Int>()
        _ = mailbox.store(5)

        let tornDown = mailbox.teardown()
        #expect(tornDown == 5)
        #expect(mailbox.isTerminated)
        #expect(!mailbox.hasPending)

        switch mailbox.store(6) {
        case .stored:
            Issue.record("A terminated mailbox must not retain another frame")
        case let .rejected(rejected):
            #expect(rejected == 6)
        }
        let rejectedAfterTeardown = mailbox.storeIfEmpty(7)
        let pendingAfterTeardown = mailbox.take()
        #expect(!rejectedAfterTeardown)
        #expect(pendingAfterTeardown == nil)
    }
}

@Suite("Real-time video renderer drain scheduling")
struct VideoRendererDrainScheduleTests {
    @Test("A later frame rearms the drain without an AVFoundation readiness callback")
    func laterFrameRearmsCompletedDrain() {
        var schedule = VideoRendererDrainSchedule()

        let firstFrameStartsDrain = schedule.beginIfNeeded()
        let concurrentFrameUsesActiveDrain = schedule.beginIfNeeded()
        schedule.finish()
        let laterFrameStartsAnotherDrain = schedule.beginIfNeeded()

        #expect(firstFrameStartsDrain)
        #expect(!concurrentFrameUsesActiveDrain)
        #expect(laterFrameStartsAnotherDrain)
    }
}

@Suite("Video renderer flush sequencing")
struct VideoRendererFlushPlanTests {
    @Test("Teardown follows an in-flight recovery flush with a remove-image flush")
    func teardownUpgradesInFlightRecovery() {
        var plan = VideoRendererFlushPlan()
        let recovery = VideoRendererFlushRequest(
            generation: 1,
            removeDisplayedImage: false
        )
        let teardown = VideoRendererFlushRequest(
            generation: 2,
            removeDisplayedImage: true
        )

        let initial = plan.begin(recovery, activeEnqueues: 0)
        let immediateUpgrade = plan.upgradeToTerminal(teardown, activeEnqueues: 0)
        let recoveryCompletion = plan.complete(recovery)
        let teardownCompletion = plan.complete(teardown)

        #expect(initial == recovery)
        #expect(immediateUpgrade == nil)
        #expect(recoveryCompletion == .followUp(teardown))
        #expect(teardownCompletion == .finished)
        #expect(!plan.hasScheduledWork)
    }

    @Test("Teardown upgrades a recovery flush waiting for an active enqueue")
    func teardownUpgradesPendingRecovery() {
        var plan = VideoRendererFlushPlan()
        let recovery = VideoRendererFlushRequest(
            generation: 8,
            removeDisplayedImage: false
        )
        let teardown = VideoRendererFlushRequest(
            generation: 9,
            removeDisplayedImage: true
        )

        let initial = plan.begin(recovery, activeEnqueues: 1)
        let immediateUpgrade = plan.upgradeToTerminal(teardown, activeEnqueues: 1)
        let afterEnqueue = plan.activatePendingAfterEnqueuesDrain()
        let completion = plan.complete(teardown)

        #expect(initial == nil)
        #expect(immediateUpgrade == nil)
        #expect(afterEnqueue == teardown)
        #expect(completion == .finished)
        #expect(!plan.hasScheduledWork)
    }
}
