import Foundation

/// Bounds optional presentation delay without building a second video queue.
/// RTP uses a 90 kHz clock; decoded frame nanosecond timestamps may be absent.
nonisolated struct AdaptiveFramePacer: Sendable {
    let frameRate: Int
    var maximumDelay: TimeInterval {
        1 / Double(frameRate)
    }

    private(set) var jitter: TimeInterval = 0
    private var previousArrival: (timestamp: UInt32, time: TimeInterval)?
    private var previousPresentation: (timestamp: UInt32, time: TimeInterval)?

    init(frameRate: Int) {
        self.frameRate = max(30, frameRate)
    }

    /// Returns true when a discontinuity invalidates an already scheduled frame.
    mutating func observe(timestamp: UInt32, arrivalTime: TimeInterval) -> Bool {
        defer { previousArrival = (timestamp, arrivalTime) }
        guard let previousArrival else { return false }
        let elapsed = arrivalTime - previousArrival.time
        guard let interval = Self.interval(from: previousArrival.timestamp, to: timestamp),
              elapsed >= 0, elapsed <= 0.25
        else {
            reset()
            return true
        }

        // A small, decaying budget absorbs compressed arrivals after a late frame.
        // Stable delivery gradually removes the extra latency again.
        let variation = min(maximumDelay, abs(elapsed - interval))
        jitter += (variation - jitter) / 8
        return false
    }

    func deadline(timestamp: UInt32, arrivalTime: TimeInterval, now: TimeInterval) -> TimeInterval {
        guard let previousPresentation,
              let interval = Self.interval(from: previousPresentation.timestamp, to: timestamp)
        else { return now }
        let budget = min(maximumDelay, jitter * 2)
        return max(now, min(previousPresentation.time + interval, arrivalTime + budget))
    }

    mutating func didSubmit(timestamp: UInt32, deadline: TimeInterval) {
        previousPresentation = (timestamp, deadline)
    }

    mutating func reset() {
        previousArrival = nil
        previousPresentation = nil
        jitter = 0
    }

    private static func interval(from previous: UInt32, to current: UInt32) -> TimeInterval? {
        let ticks = current &- previous
        // Reject duplicates, backwards time, and gaps; unsigned subtraction allows RTP rollover.
        guard ticks > 0, ticks <= 22500 else { return nil }
        return Double(ticks) / 90000
    }
}
