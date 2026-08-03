/// Generation gate shared by session creation and reconnect callbacks.
///
/// Every retry or cancellation advances the generation, making callbacks from
/// earlier work stale even when an external API finishes after cancellation.
nonisolated struct SessionAttemptState: Equatable, Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var isEnabled = true

    @discardableResult
    mutating func retry() -> UInt64 {
        isEnabled = true
        generation &+= 1
        return generation
    }

    @discardableResult
    mutating func cancel() -> UInt64 {
        isEnabled = false
        generation &+= 1
        return generation
    }

    func accepts(_ candidateGeneration: UInt64, taskIsCancelled: Bool = false) -> Bool {
        isEnabled
            && !taskIsCancelled
            && candidateGeneration == generation
    }
}
