@testable import CloudNow
import Foundation
import Testing

@Suite("Signaling endpoint race")
struct SignalingEndpointRaceTests {
    @Test("Deduplicates addresses and keeps the hostname fallback within the limit")
    func candidateOrdering() {
        let candidates = SignalingEndpointRace.candidates(
            resolvedAddresses: ["192.0.2.2", "192.0.2.2", "2001:db8::1"],
            originalHost: "signal.example",
            maximumCandidates: 3
        )

        #expect(candidates == ["192.0.2.2", "2001:db8::1", "signal.example"])
    }

    @Test("Does not displace the last direct address with a hostname fallback")
    func fullDirectAddressBudget() {
        let candidates = SignalingEndpointRace.candidates(
            resolvedAddresses: ["a", "b", "c"],
            originalHost: "signal.example",
            maximumCandidates: 2
        )

        #expect(candidates == ["a", "b"])
    }

    @Test("First successful endpoint wins and losing attempts observe cancellation")
    func firstSuccessCancelsLosers() async throws {
        let probe = CancellationProbe()
        let barrier = AttemptStartBarrier(participantCount: 3)
        let attemptEntryBarrier = AttemptEntryBarrier(participantCount: 2)

        let winner = try await SignalingEndpointRace.firstSuccess(
            candidates: ["slow-a", "winner", "slow-b"],
            maximumConcurrentAttempts: 3,
            stagger: { _ in await barrier.arrive() },
            attempt: { candidate, _ in
                if candidate == "winner" {
                    await attemptEntryBarrier.waitUntilAllEntered()
                    return candidate
                }
                return try await probe.waitForCancellation(
                    candidate,
                    entryBarrier: attemptEntryBarrier
                )
            },
            discard: { value in
                await probe.recordDiscard(value)
            }
        )

        #expect(winner == "winner")
        #expect(await probe.cancelledCandidates == ["slow-a", "slow-b"])
        #expect(await probe.discardedValues.isEmpty)
    }

    @Test("Failure aggregation follows candidate order, not completion order")
    func deterministicFailureAggregation() async {
        let candidates = ["one", "two", "three"]

        do {
            _ = try await SignalingEndpointRace.firstSuccess(
                candidates: candidates,
                maximumConcurrentAttempts: 3,
                stagger: { _ in },
                attempt: { candidate, _ -> String in
                    throw EndpointTestError.failed(candidate)
                },
                discard: { _ in }
            )
            Issue.record("Expected all endpoint attempts to fail")
        } catch let SignalingEndpointRaceError.allFailed(failures) {
            #expect(failures.map(\.candidate) == candidates)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("An empty candidate list fails without starting an attempt")
    func emptyCandidateList() async {
        await #expect(throws: SignalingEndpointRaceError.noCandidates) {
            _ = try await SignalingEndpointRace.firstSuccess(
                candidates: [],
                maximumConcurrentAttempts: 3,
                stagger: { _ in },
                attempt: { candidate, _ in candidate },
                discard: { _ in }
            )
        }
    }

    @Test("Parent cancellation stops an in-flight endpoint race")
    func parentCancellation() async throws {
        let probe = ParentCancellationProbe()
        let race = Task {
            try await SignalingEndpointRace.firstSuccess(
                candidates: ["pending"],
                maximumConcurrentAttempts: 1,
                stagger: { _ in },
                attempt: { _, _ in
                    try await probe.waitUntilCancelled()
                },
                discard: { _ in }
            )
        }
        await probe.waitUntilStarted()

        race.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await race.value
        }
        #expect(await probe.observedCancellation)
    }
}

private actor AttemptEntryBarrier {
    private var enteredCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private let participantCount: Int

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func arrive() {
        enteredCount += 1
        guard enteredCount == participantCount else { return }
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }

    func waitUntilAllEntered() async {
        guard enteredCount < participantCount else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private enum EndpointTestError: Error {
    case failed(String)
}

private actor AttemptStartBarrier {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private let participantCount: Int

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func arrive() async {
        if continuations.count + 1 == participantCount {
            let waiting = continuations
            continuations.removeAll()
            waiting.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private actor CancellationProbe {
    private(set) var cancelledCandidates: [String] = []
    private(set) var discardedValues: [String] = []

    func waitForCancellation(
        _ candidate: String,
        entryBarrier: AttemptEntryBarrier
    ) async throws -> String {
        await entryBarrier.arrive()
        do {
            while true {
                try Task.checkCancellation()
                await Task.yield()
            }
        } catch {
            cancelledCandidates.append(candidate)
            cancelledCandidates.sort()
            throw error
        }
    }

    func recordDiscard(_ value: String) {
        discardedValues.append(value)
    }
}

private actor ParentCancellationProbe {
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var observedCancellation = false
    private var started = false

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func waitUntilCancelled() async throws -> String {
        started = true
        let continuations = startContinuations
        startContinuations.removeAll()
        continuations.forEach { $0.resume() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if observedCancellation {
                    continuation.resume()
                } else {
                    cancellationContinuation = continuation
                }
            }
        } onCancel: {
            Task {
                await self.resumeForCancellation()
            }
        }
        try Task.checkCancellation()
        return "unreachable"
    }

    private func resumeForCancellation() {
        observedCancellation = true
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }
}
