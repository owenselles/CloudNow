@testable import CloudNow
import Testing

@Suite("Session attempt generation")
struct SessionAttemptStateTests {
    @Test("The initial generation accepts its own callbacks")
    func initialAttempt() {
        let state = SessionAttemptState()

        #expect(state.generation == 0)
        #expect(state.isEnabled)
        #expect(state.accepts(0))
        #expect(!state.accepts(1))
    }

    @Test("Retry enables work and rejects every older callback")
    func retryInvalidatesStaleWork() {
        var state = SessionAttemptState()
        let first = state.generation
        let second = state.retry()
        let third = state.retry()

        #expect(second == first + 1)
        #expect(third == second + 1)
        #expect(!state.accepts(first))
        #expect(!state.accepts(second))
        #expect(state.accepts(third))
    }

    @Test("Cancellation disables mutation even for the latest generation")
    func cancellationDisablesMutation() {
        var state = SessionAttemptState()
        let cancelledGeneration = state.cancel()

        #expect(!state.isEnabled)
        #expect(!state.accepts(cancelledGeneration))
        #expect(!state.accepts(0))
    }

    @Test("Retry after cancellation creates one fresh accepted generation")
    func retryAfterCancellation() {
        var state = SessionAttemptState()
        let cancelled = state.cancel()
        let retried = state.retry()

        #expect(state.isEnabled)
        #expect(!state.accepts(cancelled))
        #expect(state.accepts(retried))
    }

    @Test("Task cancellation rejects an otherwise current callback")
    func taskCancellation() {
        let state = SessionAttemptState()

        #expect(!state.accepts(state.generation, taskIsCancelled: true))
        #expect(state.accepts(state.generation, taskIsCancelled: false))
    }
}
