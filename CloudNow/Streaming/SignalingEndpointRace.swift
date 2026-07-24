import Foundation

nonisolated struct SignalingEndpointFailure: Equatable, Sendable {
    let candidate: String
    let reason: String
}

nonisolated enum SignalingEndpointRaceError: Error, Equatable {
    case noCandidates
    case allFailed([SignalingEndpointFailure])
}

/// Transport-independent endpoint selection used to test race ordering, cancellation, and
/// deterministic failure reporting without opening sockets.
nonisolated enum SignalingEndpointRace {
    static func candidates(
        resolvedAddresses: [String],
        originalHost: String,
        maximumCandidates: Int
    ) -> [String] {
        guard maximumCandidates > 0 else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for address in resolvedAddresses where address != originalHost {
            guard seen.insert(address).inserted else { continue }
            result.append(address)
            if result.count == maximumCandidates {
                return result
            }
        }
        if result.count < maximumCandidates, seen.insert(originalHost).inserted {
            result.append(originalHost)
        }
        return result
    }

    static func firstSuccess<Value: Sendable>(
        candidates: [String],
        maximumConcurrentAttempts: Int,
        stagger: @escaping @Sendable (Int) async throws -> Void,
        attempt: @escaping @Sendable (String, Int) async throws -> Value,
        discard: @escaping @Sendable (Value) async -> Void
    ) async throws -> Value {
        guard !candidates.isEmpty else {
            throw SignalingEndpointRaceError.noCandidates
        }
        let concurrency = max(1, min(maximumConcurrentAttempts, candidates.count))

        return try await withThrowingTaskGroup(
            of: AttemptOutcome<Value>.self,
            returning: Value.self
        ) { group in
            var nextIndex = 0
            var activeCount = 0
            var winner: Value?
            var failures: [Int: SignalingEndpointFailure] = [:]

            func addAttempt(at index: Int) {
                let candidate = candidates[index]
                group.addTask {
                    do {
                        try await stagger(index)
                        try Task.checkCancellation()
                        let value = try await attempt(candidate, index)
                        return .success(index: index, value: value)
                    } catch {
                        return .failure(
                            index: index,
                            failure: SignalingEndpointFailure(
                                candidate: candidate,
                                reason: String(describing: error)
                            )
                        )
                    }
                }
                activeCount += 1
                nextIndex += 1
            }

            while nextIndex < concurrency {
                addAttempt(at: nextIndex)
            }

            while activeCount > 0, let outcome = try await group.next() {
                activeCount -= 1
                switch outcome {
                case let .success(_, value):
                    if winner == nil {
                        winner = value
                        group.cancelAll()
                    } else {
                        await discard(value)
                    }
                case let .failure(index, failure):
                    failures[index] = failure
                }

                if winner == nil, nextIndex < candidates.count {
                    addAttempt(at: nextIndex)
                }
            }

            if Task.isCancelled {
                if let winner {
                    await discard(winner)
                }
                throw CancellationError()
            }
            if let winner {
                return winner
            }
            let orderedFailures = candidates.indices.compactMap { failures[$0] }
            throw SignalingEndpointRaceError.allFailed(orderedFailures)
        }
    }

    private enum AttemptOutcome<Value: Sendable>: Sendable {
        case success(index: Int, value: Value)
        case failure(index: Int, failure: SignalingEndpointFailure)
    }
}
