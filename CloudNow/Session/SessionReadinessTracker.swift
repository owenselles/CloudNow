import Foundation

nonisolated enum SessionReadinessState: Equatable, Sendable {
    case inQueue(position: Int?)
    case preparing
    case ready
    case timedOut
}

/// Pure reducer for CloudMatch queue/setup polling. Callers supply time so queue waits and
/// post-queue setup deadlines can be tested without sleeping.
nonisolated struct SessionReadinessTracker: Sendable {
    private let requiredReadyResponses: Int
    private let setupTimeout: TimeInterval
    private var consecutiveReadyResponses = 0
    private var setupStartedAt: Date?

    init(
        requiredReadyResponses: Int = 2,
        setupTimeout: TimeInterval = 180
    ) {
        self.requiredReadyResponses = max(1, requiredReadyResponses)
        self.setupTimeout = max(0, setupTimeout)
    }

    mutating func observe(
        status: Int,
        isInQueue: Bool,
        queuePosition: Int?,
        now: Date
    ) -> SessionReadinessState {
        let loadingState: SessionReadinessState
        if isInQueue {
            setupStartedAt = nil
            loadingState = .inQueue(position: queuePosition)
        } else {
            if setupStartedAt == nil {
                setupStartedAt = now
            }
            if let setupStartedAt,
               now.timeIntervalSince(setupStartedAt) > setupTimeout
            {
                return .timedOut
            }
            loadingState = .preparing
        }

        if status == 2 || status == 3 {
            consecutiveReadyResponses += 1
        } else {
            consecutiveReadyResponses = 0
        }

        return consecutiveReadyResponses >= requiredReadyResponses
            ? .ready
            : loadingState
    }
}
