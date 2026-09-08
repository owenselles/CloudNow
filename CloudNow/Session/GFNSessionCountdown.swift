import Foundation

/// Fixed session limits currently assigned by GeForce NOW membership tier.
nonisolated enum GFNSessionLimit {
    static let freeSeconds = 60 * 60
    static let performanceSeconds = 6 * 60 * 60
    static let ultimateSeconds = 8 * 60 * 60

    static func seconds(for membershipTier: String?) -> Int? {
        guard let membershipTier else { return nil }
        let normalizedTier = membershipTier.uppercased()
        if normalizedTier.contains("ULTIMATE") {
            return ultimateSeconds
        }
        if normalizedTier.contains("PERFORMANCE")
            || normalizedTier.contains("PRIORITY")
            || normalizedTier.contains("FOUNDER")
        {
            return performanceSeconds
        }
        if normalizedTier.contains("FREE") {
            return freeSeconds
        }
        return nil
    }
}

/// Wall-clock anchor for a GFN session limit. Server timer notifications can
/// replace the tier-based estimate without coupling countdown updates to a timer.
nonisolated struct GFNSessionCountdown: Equatable, Sendable {
    let endsAt: Date

    init?(
        membershipTier: String?,
        startedAt: Date
    ) {
        guard let duration = GFNSessionLimit.seconds(for: membershipTier) else {
            return nil
        }
        endsAt = startedAt.addingTimeInterval(TimeInterval(duration))
    }

    init?(secondsLeft: Int, receivedAt: Date) {
        guard secondsLeft >= 0 else { return nil }
        endsAt = receivedAt.addingTimeInterval(TimeInterval(secondsLeft))
    }

    func synchronized(secondsLeft: Int, receivedAt: Date) -> Self {
        Self(secondsLeft: secondsLeft, receivedAt: receivedAt) ?? self
    }

    func secondsRemaining(at date: Date) -> Int {
        max(0, Int(ceil(endsAt.timeIntervalSince(date))))
    }

    func minutesRemaining(at date: Date) -> Int {
        let seconds = secondsRemaining(at: date)
        guard seconds > 0 else { return 0 }
        return Int(ceil(Double(seconds) / 60))
    }

    func shouldShow(at date: Date, warningMinutes: Int) -> Bool {
        guard warningMinutes > 0 else { return false }
        let seconds = secondsRemaining(at: date)
        return seconds > 0 && seconds <= warningMinutes * 60
    }
}

/// GFN control-channel notification used to resynchronize the local estimate.
nonisolated struct StreamTimeWarning: Equatable, Sendable {
    /// 1 = approaching limit, 2 = idle warning, 3 = maximum session warning.
    let code: Int
    /// Seconds remaining as reported by the server, when present and valid.
    let secondsLeft: Int?

    init(code: Int, secondsLeft: Int?) {
        self.code = code
        self.secondsLeft = secondsLeft
    }

    /// Idle-timeout warnings must not move the fixed membership-session deadline.
    var reportsSessionLimit: Bool {
        code != 2
    }

    init?(timerNotificationData data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notification = json["timerNotification"] as? [String: Any],
              let rawCode = notification["code"] as? Int
        else {
            return nil
        }
        switch rawCode {
        case 1, 2:
            code = 1
        case 4:
            code = 2
        case 6:
            code = 3
        default:
            return nil
        }
        if let reportedSeconds = notification["secondsLeft"] as? Int,
           reportedSeconds >= 0
        {
            secondsLeft = reportedSeconds
        } else {
            secondsLeft = nil
        }
    }
}
