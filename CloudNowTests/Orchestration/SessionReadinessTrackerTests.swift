@testable import CloudNow
import Foundation
import Testing

@Suite("Session queue readiness")
struct SessionReadinessTrackerTests {
    private let start = Date(timeIntervalSince1970: 1000)

    @Test("Queue polling has no overall timeout")
    func queueHasNoOverallTimeout() {
        var tracker = SessionReadinessTracker(setupTimeout: 10)

        let state = tracker.observe(
            status: 1,
            isInQueue: true,
            queuePosition: 12,
            now: start.addingTimeInterval(10000)
        )

        #expect(state == .inQueue(position: 12))
    }

    @Test("Two consecutive ready responses are required")
    func requiresConsecutiveReadyResponses() {
        var tracker = SessionReadinessTracker()

        let first = tracker.observe(
            status: 2,
            isInQueue: false,
            queuePosition: nil,
            now: start
        )
        let second = tracker.observe(
            status: 3,
            isInQueue: false,
            queuePosition: nil,
            now: start
        )

        #expect(first == .preparing)
        #expect(second == .ready)
    }

    @Test("A non-ready response resets readiness confirmation")
    func nonReadyResponseResetsStreak() {
        var tracker = SessionReadinessTracker()

        _ = tracker.observe(
            status: 2,
            isInQueue: false,
            queuePosition: nil,
            now: start
        )
        let reset = tracker.observe(
            status: 1,
            isInQueue: false,
            queuePosition: nil,
            now: start
        )
        let nextReady = tracker.observe(
            status: 2,
            isInQueue: false,
            queuePosition: nil,
            now: start
        )

        #expect(reset == .preparing)
        #expect(nextReady == .preparing)
    }

    @Test("Setup timeout starts only after queue clears")
    func setupTimeoutStartsAfterQueue() {
        var tracker = SessionReadinessTracker(setupTimeout: 30)

        _ = tracker.observe(
            status: 1,
            isInQueue: true,
            queuePosition: 4,
            now: start
        )
        let queueStillActive = tracker.observe(
            status: 1,
            isInQueue: true,
            queuePosition: 1,
            now: start.addingTimeInterval(500)
        )
        let setupStarts = tracker.observe(
            status: 1,
            isInQueue: false,
            queuePosition: nil,
            now: start.addingTimeInterval(500)
        )
        let beforeDeadline = tracker.observe(
            status: 1,
            isInQueue: false,
            queuePosition: nil,
            now: start.addingTimeInterval(530)
        )
        let afterDeadline = tracker.observe(
            status: 1,
            isInQueue: false,
            queuePosition: nil,
            now: start.addingTimeInterval(530.001)
        )

        #expect(queueStillActive == .inQueue(position: 1))
        #expect(setupStarts == .preparing)
        #expect(beforeDeadline == .preparing)
        #expect(afterDeadline == .timedOut)
    }

    @Test("Returning to queue resets the setup deadline")
    func queueReturnResetsSetupDeadline() {
        var tracker = SessionReadinessTracker(setupTimeout: 10)

        _ = tracker.observe(
            status: 1,
            isInQueue: false,
            queuePosition: nil,
            now: start
        )
        _ = tracker.observe(
            status: 1,
            isInQueue: true,
            queuePosition: 2,
            now: start.addingTimeInterval(9)
        )
        let state = tracker.observe(
            status: 1,
            isInQueue: false,
            queuePosition: nil,
            now: start.addingTimeInterval(50)
        )

        #expect(state == .preparing)
    }
}
