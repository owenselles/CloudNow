import Foundation

nonisolated struct ShortcutTransitionBuffer: Equatable, Sendable {
    static let capacity = 8

    private var value0: UInt16 = 0
    private var value1: UInt16 = 0
    private var value2: UInt16 = 0
    private var value3: UInt16 = 0
    private var value4: UInt16 = 0
    private var value5: UInt16 = 0
    private var value6: UInt16 = 0
    private var value7: UInt16 = 0
    private(set) var count = 0

    mutating func append(_ value: UInt16) -> Bool {
        guard count < Self.capacity else { return false }
        switch count {
        case 0: value0 = value
        case 1: value1 = value
        case 2: value2 = value
        case 3: value3 = value
        case 4: value4 = value
        case 5: value5 = value
        case 6: value6 = value
        case 7: value7 = value
        default: return false
        }
        count += 1
        return true
    }

    subscript(index: Int) -> UInt16 {
        precondition(index >= 0 && index < count)
        switch index {
        case 0: return value0
        case 1: return value1
        case 2: return value2
        case 3: return value3
        case 4: return value4
        case 5: return value5
        case 6: return value6
        case 7: return value7
        default: preconditionFailure("Transition index is outside the fixed buffer")
        }
    }

    func contains(buttonMask: UInt16) -> Bool {
        for index in 0 ..< count where self[index] & buttonMask != 0 {
            return true
        }
        return false
    }

    func projected(
        onto baseButtons: UInt16,
        excluding excludedButtons: UInt16
    ) -> ShortcutTransitionBuffer {
        var result = ShortcutTransitionBuffer()
        var previousButtons = baseButtons
        for index in 0 ..< count {
            let buttons = baseButtons | (self[index] & ~excludedButtons)
            guard buttons != previousButtons else { continue }
            _ = result.append(buttons)
            previousButtons = buttons
        }
        return result
    }

    var values: [UInt16] {
        (0 ..< count).map { self[$0] }
    }
}

nonisolated struct ControllerKeyboardShortcutResolution: Equatable, Sendable {
    let forwardedButtons: UInt16
    let suppressesOverlayGestures: Bool
    let suppressesSteamGestures: Bool
    let replayTransitions: ShortcutTransitionBuffer
    let triggered: Bool
    let bypassesLocalGestureHandling: Bool
}

nonisolated enum ControllerKeyboardShortcutOverlayPolicy {
    static func shouldFinishPressOnRelease(
        resolverOwnsGesture: Bool
    ) -> Bool {
        !resolverOwnsGesture
    }

    static func shouldReplayDeferredTap(
        resolution: ControllerKeyboardShortcutResolution,
        overlayButtonMask: UInt16,
        physicalButtons: UInt16,
        hasPendingPress: Bool
    ) -> Bool {
        hasPendingPress
            && !resolution.bypassesLocalGestureHandling
            && physicalButtons & overlayButtonMask == 0
            && resolution.replayTransitions.contains(buttonMask: overlayButtonMask)
    }
}

/// Resolves a controller chord without allocating in the 120 Hz sampling path.
/// Candidate button edges remain private until the chord succeeds or fails. A failure
/// returns the exact bounded target-button history so the remote side sees the original order.
nonisolated struct ControllerKeyboardShortcutResolver: Sendable {
    private struct PendingState: Sendable {
        var transitions = ShortcutTransitionBuffer()
        var lastTargetButtons: UInt16
        var assemblyDeadline: UInt64
        var triggerDeadline: UInt64?
    }

    private enum Phase: Sendable {
        case idle
        case pending(PendingState)
        case consumed
        case passthroughUntilRelease(bypassesLocalGestures: Bool)
    }

    static let assemblyWindowNanoseconds: UInt64 = 250_000_000

    private let targetMask: UInt16
    private let eligibleButtonMask: UInt16
    private let holdDurationNanoseconds: UInt64
    private var phase: Phase = .idle

    init(
        targetMask: UInt16,
        eligibleButtonMask: UInt16,
        holdDurationNanoseconds: UInt64
    ) {
        self.targetMask = targetMask
        self.eligibleButtonMask = eligibleButtonMask
        self.holdDurationNanoseconds = holdDurationNanoseconds
    }

    var ownsCandidateGesture: Bool {
        switch phase {
        case .pending, .consumed: true
        case let .passthroughUntilRelease(bypassesLocalGestures): bypassesLocalGestures
        case .idle: false
        }
    }

    mutating func resolve(buttons: UInt16, now: UInt64) -> ControllerKeyboardShortcutResolution {
        let eligibleButtons = buttons & eligibleButtonMask
        let targetButtons = eligibleButtons & targetMask

        switch phase {
        case .idle:
            guard targetMask != 0,
                  targetButtons != 0,
                  eligibleButtons & ~targetMask == 0
            else {
                return passthrough(buttons)
            }

            var pending = PendingState(
                lastTargetButtons: targetButtons,
                assemblyDeadline: now &+ Self.assemblyWindowNanoseconds,
                triggerDeadline: targetButtons == targetMask
                    ? now &+ holdDurationNanoseconds
                    : nil
            )
            _ = pending.transitions.append(targetButtons)
            phase = .pending(pending)
            return suppressed(
                buttons,
                suppressesLocalGestures: targetButtons == targetMask
            )

        case var .pending(pending):
            if targetButtons != pending.lastTargetButtons {
                guard pending.transitions.append(targetButtons) else {
                    return fail(pending: pending, buttons: buttons, targetButtons: targetButtons)
                }
                pending.lastTargetButtons = targetButtons
            }

            guard eligibleButtons & ~targetMask == 0 else {
                return fail(pending: pending, buttons: buttons, targetButtons: targetButtons)
            }

            if let triggerDeadline = pending.triggerDeadline {
                guard targetButtons == targetMask else {
                    return fail(pending: pending, buttons: buttons, targetButtons: targetButtons)
                }
                if now >= triggerDeadline {
                    phase = .consumed
                    return ControllerKeyboardShortcutResolution(
                        forwardedButtons: buttons & ~targetMask,
                        suppressesOverlayGestures: true,
                        suppressesSteamGestures: true,
                        replayTransitions: .init(),
                        triggered: true,
                        bypassesLocalGestureHandling: false
                    )
                }
            } else if targetButtons == targetMask {
                pending.triggerDeadline = now &+ holdDurationNanoseconds
            } else if targetButtons == 0 || now >= pending.assemblyDeadline {
                return fail(pending: pending, buttons: buttons, targetButtons: targetButtons)
            }

            phase = .pending(pending)
            return suppressed(
                buttons,
                suppressesLocalGestures: targetButtons == targetMask
            )

        case .consumed:
            if targetButtons == 0 {
                phase = .idle
            }
            return ControllerKeyboardShortcutResolution(
                forwardedButtons: buttons & ~targetMask,
                suppressesOverlayGestures: true,
                suppressesSteamGestures: true,
                replayTransitions: .init(),
                triggered: false,
                bypassesLocalGestureHandling: false
            )

        case let .passthroughUntilRelease(bypassesLocalGestures):
            if targetButtons == 0 {
                phase = .idle
            }
            return passthrough(
                buttons,
                bypassesLocalGestureHandling: bypassesLocalGestures
            )
        }
    }

    private func passthrough(
        _ buttons: UInt16,
        bypassesLocalGestureHandling: Bool = false
    ) -> ControllerKeyboardShortcutResolution {
        ControllerKeyboardShortcutResolution(
            forwardedButtons: buttons,
            suppressesOverlayGestures: false,
            suppressesSteamGestures: false,
            replayTransitions: .init(),
            triggered: false,
            bypassesLocalGestureHandling: bypassesLocalGestureHandling
        )
    }

    private func suppressed(
        _ buttons: UInt16,
        suppressesLocalGestures: Bool
    ) -> ControllerKeyboardShortcutResolution {
        ControllerKeyboardShortcutResolution(
            forwardedButtons: buttons & ~targetMask,
            suppressesOverlayGestures: suppressesLocalGestures,
            suppressesSteamGestures: suppressesLocalGestures,
            replayTransitions: .init(),
            triggered: false,
            bypassesLocalGestureHandling: false
        )
    }

    private mutating func fail(
        pending: PendingState,
        buttons: UInt16,
        targetButtons: UInt16
    ) -> ControllerKeyboardShortcutResolution {
        let bypassesLocalGestures = pending.triggerDeadline != nil
        phase = targetButtons == 0
            ? .idle
            : .passthroughUntilRelease(
                bypassesLocalGestures: bypassesLocalGestures
            )
        return ControllerKeyboardShortcutResolution(
            forwardedButtons: buttons,
            suppressesOverlayGestures: false,
            suppressesSteamGestures: false,
            replayTransitions: pending.transitions,
            triggered: false,
            bypassesLocalGestureHandling: bypassesLocalGestures
        )
    }
}
