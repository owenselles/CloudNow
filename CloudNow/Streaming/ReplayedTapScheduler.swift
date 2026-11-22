import Foundation

/// Keeps gamepad presses that were withheld for a local gesture and forwarded late
/// down long enough for a game that polls once per frame to see them.
///
/// Ordinary input passes through `compose` unchanged and without delay. A button is
/// managed only after `beginReplayedPress`, when its down edge reaches the remote after
/// the physical press began: a deferred overlay tap or a failed text-input chord
/// candidate. From that first forwarded down edge the button stays down for at least
/// `minimumHold`. It is then released for at least `minimumGap` before a queued repeat
/// press starts, so repeated taps stay distinct. Each button is tracked independently,
/// and at most `maximumQueuedPresses` repeats wait per button.
///
/// The scheduler is advanced by the caller's existing sampling path. It owns no timers
/// and does not allocate while composing.
nonisolated struct ReplayedTapScheduler: Equatable, Sendable {
    static let defaultMinimumHold: UInt64 = 80_000_000
    static let defaultMinimumGap: UInt64 = 50_000_000
    static let maximumQueuedPresses: UInt8 = 2
    private static let buttonCount = UInt16.bitWidth

    private enum Phase: Equatable, Sendable {
        case idle
        case holding(until: UInt64)
        case releasing(until: UInt64)
    }

    private struct ButtonState: Equatable, Sendable {
        var phase: Phase = .idle
        var queuedPresses: UInt8 = 0
        var lastForwarded = false
    }

    let minimumHold: UInt64
    let minimumGap: UInt64
    private var buttons = [ButtonState](repeating: ButtonState(), count: buttonCount)
    private(set) var managedButtons: UInt16 = 0

    init(
        minimumHold: UInt64 = Self.defaultMinimumHold,
        minimumGap: UInt64 = Self.defaultMinimumGap
    ) {
        self.minimumHold = minimumHold
        self.minimumGap = minimumGap
    }

    /// Records a forwarded down edge for each button in `mask`. An idle button goes
    /// down now. A button that is still held or released from an earlier replay queues
    /// one more press, up to `maximumQueuedPresses`.
    mutating func beginReplayedPress(_ mask: UInt16, now: UInt64) {
        var remaining = mask
        while remaining != 0 {
            let index = remaining.trailingZeroBitCount
            let bit = UInt16(1) << index
            remaining &= ~bit
            var state = buttons[index]
            if state.phase == .idle {
                state.phase = .holding(until: now &+ minimumHold)
                state.queuedPresses = 0
            } else {
                state.queuedPresses = min(state.queuedPresses + 1, Self.maximumQueuedPresses)
            }
            // The caller may still be forwarding this same physical press; only a later
            // rising edge counts as a new press.
            state.lastForwarded = true
            buttons[index] = state
            managedButtons |= bit
        }
    }

    /// Applies managed buttons to the buttons the ordinary path would forward and
    /// advances their phases to `now`. A rising forwarded edge of a managed button
    /// queues a distinct press instead of merging into the current one.
    mutating func compose(forwarded: UInt16, now: UInt64) -> UInt16 {
        guard managedButtons != 0 else { return forwarded }
        var output = forwarded
        var remaining = managedButtons
        while remaining != 0 {
            let index = remaining.trailingZeroBitCount
            let bit = UInt16(1) << index
            remaining &= ~bit
            if advance(index: index, isForwarded: forwarded & bit != 0, now: now) {
                output |= bit
            } else if buttons[index].phase != .idle {
                output &= ~bit
            }
        }
        return output
    }

    /// Applies managed buttons to `base` without advancing phases or observing edges.
    /// Used to emit replayed down edges in order within one sample.
    func overlay(onto base: UInt16) -> UInt16 {
        var output = base
        var remaining = managedButtons
        while remaining != 0 {
            let index = remaining.trailingZeroBitCount
            let bit = UInt16(1) << index
            remaining &= ~bit
            switch buttons[index].phase {
            case .holding: output |= bit
            case .releasing: output &= ~bit
            case .idle: break
            }
        }
        return output
    }

    /// Returns whether the button is down on the remote after advancing it to `now`.
    /// An idle result defers to the forwarded value.
    private mutating func advance(index: Int, isForwarded: Bool, now: UInt64) -> Bool {
        var state = buttons[index]
        if isForwarded, !state.lastForwarded {
            state.queuedPresses = min(state.queuedPresses + 1, Self.maximumQueuedPresses)
        }
        state.lastForwarded = isForwarded

        var isDown = isForwarded
        resolving: while true {
            switch state.phase {
            case let .holding(until):
                if now < until {
                    isDown = true
                    break resolving
                }
                if state.queuedPresses == 0, isForwarded {
                    // The same press is still physically held: return it to ordinary
                    // forwarding so its release is not delayed.
                    state.phase = .idle
                    continue resolving
                }
                state.phase = .releasing(until: now &+ minimumGap)

            case let .releasing(until):
                if now < until {
                    isDown = false
                    break resolving
                }
                if state.queuedPresses > 0 {
                    state.queuedPresses -= 1
                    state.phase = .holding(until: now &+ minimumHold)
                } else {
                    state.phase = .idle
                }

            case .idle:
                managedButtons &= ~(UInt16(1) << index)
                break resolving
            }
        }
        buttons[index] = state
        return isDown
    }
}

/// Per-slot replay schedulers. A slot's state is dropped when its controller detaches,
/// so a replacement controller in the same slot never inherits a pending press.
nonisolated struct ReplayedTapSlots: Sendable {
    private var schedulers: [Int: ReplayedTapScheduler] = [:]
    private let minimumHold: UInt64
    private let minimumGap: UInt64

    init(
        minimumHold: UInt64 = ReplayedTapScheduler.defaultMinimumHold,
        minimumGap: UInt64 = ReplayedTapScheduler.defaultMinimumGap
    ) {
        self.minimumHold = minimumHold
        self.minimumGap = minimumGap
    }

    mutating func beginReplayedPress(_ mask: UInt16, slot: Int, now: UInt64) {
        guard mask != 0 else { return }
        if schedulers[slot] == nil {
            schedulers[slot] = ReplayedTapScheduler(minimumHold: minimumHold, minimumGap: minimumGap)
        }
        schedulers[slot]?.beginReplayedPress(mask, now: now)
    }

    mutating func compose(forwarded: UInt16, slot: Int, now: UInt64) -> UInt16 {
        schedulers[slot]?.compose(forwarded: forwarded, now: now) ?? forwarded
    }

    func overlay(onto base: UInt16, slot: Int) -> UInt16 {
        schedulers[slot]?.overlay(onto: base) ?? base
    }

    func managedButtons(slot: Int) -> UInt16 {
        schedulers[slot]?.managedButtons ?? 0
    }

    mutating func releaseSlot(_ slot: Int) {
        schedulers[slot] = nil
    }

    mutating func removeAll() {
        schedulers.removeAll()
    }
}
