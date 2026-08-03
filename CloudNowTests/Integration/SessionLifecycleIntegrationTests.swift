@testable import CloudNow
import Foundation
import Testing

@Suite("Session lifecycle integration")
struct SessionLifecycleIntegrationTests {
    @Test("A fake queued session requires confirmed readiness before connecting")
    func queuedSessionBecomesReady() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let responses = [
            SessionStatus(status: 1, queuePosition: 12, isInQueue: true),
            SessionStatus(status: 2, queuePosition: nil, isInQueue: false),
            SessionStatus(status: 1, queuePosition: nil, isInQueue: false),
            SessionStatus(status: 2, queuePosition: nil, isInQueue: false),
            SessionStatus(status: 3, queuePosition: nil, isInQueue: false),
        ]
        let attempt = SessionAttemptState()
        var tracker = SessionReadinessTracker()
        var states: [SessionReadinessState] = []

        for (index, response) in responses.enumerated()
            where attempt.accepts(attempt.generation)
        {
            states.append(tracker.observe(
                status: response.status,
                isInQueue: response.isInQueue,
                queuePosition: response.queuePosition,
                now: start.addingTimeInterval(TimeInterval(index))
            ))
        }

        #expect(states == [
            .inQueue(position: 12),
            .preparing,
            .preparing,
            .preparing,
            .ready,
        ])
        #expect(attempt.accepts(attempt.generation))
    }

    @Test("Cancellation rejects every later fake queue response")
    func cancellationStopsStateMutation() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var attempt = SessionAttemptState()
        let generation = attempt.generation
        var tracker = SessionReadinessTracker()
        let queued = tracker.observe(
            status: 1,
            isInQueue: true,
            queuePosition: 4,
            now: start
        )

        attempt.cancel()
        let lateResponses = [
            SessionStatus(status: 2, queuePosition: nil, isInQueue: false),
            SessionStatus(status: 3, queuePosition: nil, isInQueue: false),
        ]
        var published: [SessionReadinessState] = [queued]
        for response in lateResponses where attempt.accepts(generation) {
            published.append(tracker.observe(
                status: response.status,
                isInQueue: response.isInQueue,
                queuePosition: response.queuePosition,
                now: start
            ))
        }

        #expect(published == [.inQueue(position: 4)])
        #expect(!attempt.accepts(generation))
    }
}

private struct SessionStatus: Sendable {
    let status: Int
    let queuePosition: Int?
    let isInQueue: Bool
}
