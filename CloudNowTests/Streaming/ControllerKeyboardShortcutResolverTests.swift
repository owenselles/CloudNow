@testable import CloudNow
import Testing

@Suite("Controller keyboard shortcut resolver")
struct ControllerKeyboardShortcutResolverTests {
    private let firstButton: UInt16 = 1 << 0
    private let secondButton: UInt16 = 1 << 1
    private let unrelatedButton: UInt16 = 1 << 2
    private let holdDuration: UInt64 = 150_000_000

    @Test("A staggered chord is withheld and triggers only after the full hold delay")
    func staggeredChordHonorsHoldDelay() {
        var resolver = makeResolver()

        let firstPress = resolver.resolve(buttons: firstButton, now: 0)
        #expect(firstPress.forwardedButtons == 0)
        #expect(firstPress.replayTransitions.count == 0)
        #expect(!firstPress.triggered)
        #expect(!firstPress.suppressesOverlayGestures)
        #expect(!firstPress.suppressesSteamGestures)
        #expect(resolver.ownsCandidateGesture)

        let assembled = resolver.resolve(buttons: firstButton | secondButton, now: 10_000_000)
        #expect(assembled.forwardedButtons == 0)
        #expect(!assembled.triggered)
        #expect(assembled.suppressesOverlayGestures)
        #expect(assembled.suppressesSteamGestures)
        #expect(resolver.ownsCandidateGesture)

        let early = resolver.resolve(buttons: firstButton | secondButton, now: 159_999_999)
        #expect(!early.triggered)

        let triggered = resolver.resolve(buttons: firstButton | secondButton, now: 160_000_000)
        #expect(triggered.triggered)
        #expect(triggered.forwardedButtons == 0)

        let partialRelease = resolver.resolve(buttons: secondButton, now: 170_000_000)
        #expect(partialRelease.forwardedButtons == 0)
        #expect(partialRelease.replayTransitions.count == 0)

        _ = resolver.resolve(buttons: 0, now: 180_000_000)
        #expect(!resolver.ownsCandidateGesture)
    }

    @Test("An early release replays exact ordered edges and preserves the held button")
    func earlyReleaseReplaysOrderedTransitions() {
        var resolver = makeResolver()

        _ = resolver.resolve(buttons: firstButton, now: 0)
        _ = resolver.resolve(buttons: firstButton | secondButton, now: 10_000_000)
        let failed = resolver.resolve(buttons: firstButton, now: 20_000_000)

        #expect(failed.forwardedButtons == firstButton)
        #expect(failed.replayTransitions.values == [
            firstButton,
            firstButton | secondButton,
            firstButton,
        ])
        #expect(!failed.triggered)
        #expect(!failed.suppressesOverlayGestures)
        #expect(!failed.suppressesSteamGestures)
        #expect(failed.bypassesLocalGestureHandling)
        #expect(resolver.ownsCandidateGesture)

        let held = resolver.resolve(buttons: firstButton, now: 30_000_000)
        #expect(held.forwardedButtons == firstButton)
        #expect(held.replayTransitions.count == 0)

        _ = resolver.resolve(buttons: 0, now: 40_000_000)
        #expect(!resolver.ownsCandidateGesture)
        let nextCandidate = resolver.resolve(buttons: firstButton, now: 50_000_000)
        #expect(nextCandidate.forwardedButtons == 0)
    }

    @Test("A partial chord times out once and then passes through until release")
    func partialChordTimeoutDoesNotRepeat() {
        var resolver = makeResolver()

        _ = resolver.resolve(buttons: firstButton, now: 0)
        let timedOut = resolver.resolve(
            buttons: firstButton,
            now: ControllerKeyboardShortcutResolver.assemblyWindowNanoseconds
        )
        #expect(timedOut.forwardedButtons == firstButton)
        #expect(timedOut.replayTransitions.values == [firstButton])
        #expect(!timedOut.suppressesOverlayGestures)
        #expect(!timedOut.suppressesSteamGestures)
        #expect(!timedOut.bypassesLocalGestureHandling)
        #expect(!resolver.ownsCandidateGesture)

        let stillHeld = resolver.resolve(buttons: firstButton, now: 300_000_000)
        #expect(stillHeld.forwardedButtons == firstButton)
        #expect(stillHeld.replayTransitions.count == 0)
        #expect(!stillHeld.suppressesOverlayGestures)
        #expect(!stillHeld.suppressesSteamGestures)
    }

    @Test("A released partial overlay candidate replays exactly one deferred local tap")
    func partialOverlayReleaseDefersLocalTap() {
        var resolver = makeResolver()

        _ = resolver.resolve(buttons: firstButton, now: 0)
        #expect(!ControllerKeyboardShortcutOverlayPolicy.shouldFinishPressOnRelease(
            resolverOwnsGesture: resolver.ownsCandidateGesture
        ))

        let failed = resolver.resolve(buttons: 0, now: 10_000_000)
        #expect(ControllerKeyboardShortcutOverlayPolicy.shouldReplayDeferredTap(
            resolution: failed,
            overlayButtonMask: firstButton,
            physicalButtons: 0,
            hasPendingPress: true
        ))
        #expect(!failed.bypassesLocalGestureHandling)
        #expect(!resolver.ownsCandidateGesture)
    }

    @Test("A released full candidate is replayed remotely without a local overlay tap")
    func fullOverlayReleaseBypassesLocalTap() {
        var resolver = makeResolver()

        _ = resolver.resolve(buttons: firstButton, now: 0)
        _ = resolver.resolve(buttons: firstButton | secondButton, now: 10_000_000)
        let failed = resolver.resolve(buttons: 0, now: 20_000_000)

        #expect(failed.bypassesLocalGestureHandling)
        #expect(!ControllerKeyboardShortcutOverlayPolicy.shouldReplayDeferredTap(
            resolution: failed,
            overlayButtonMask: firstButton,
            physicalButtons: 0,
            hasPendingPress: true
        ))
    }

    @Test("An unrelated button fails the candidate without swallowing input")
    func unrelatedButtonFailsCandidate() {
        var resolver = makeResolver()

        _ = resolver.resolve(buttons: firstButton, now: 0)
        let failed = resolver.resolve(
            buttons: firstButton | unrelatedButton,
            now: 10_000_000
        )

        #expect(failed.forwardedButtons == firstButton | unrelatedButton)
        #expect(failed.replayTransitions.values == [firstButton])
        #expect(!failed.suppressesOverlayGestures)
        #expect(!failed.suppressesSteamGestures)

        let replay = failed.replayTransitions.projected(
            onto: 0,
            excluding: 0
        )
        #expect(replay.values == [firstButton])
        #expect(replay.values + [failed.forwardedButtons] == [
            firstButton,
            firstButton | unrelatedButton,
        ])
    }

    @Test("Replay projection preserves an existing remote base and removes local overlay edges")
    func replayProjectionPreservesRemoteBase() {
        let existingRemoteButton: UInt16 = 1 << 3
        var transitions = ShortcutTransitionBuffer()
        _ = transitions.append(firstButton)
        _ = transitions.append(firstButton | secondButton)
        _ = transitions.append(secondButton)
        _ = transitions.append(0)

        let replay = transitions.projected(
            onto: existingRemoteButton,
            excluding: firstButton
        )

        #expect(replay.values == [
            existingRemoteButton | secondButton,
            existingRemoteButton,
        ])
    }

    @Test("Transition history is fixed-capacity under button bounce")
    func transitionHistoryIsBounded() {
        var resolver = makeResolver()
        let transitions = [
            firstButton,
            secondButton,
            firstButton,
            secondButton,
            firstButton,
            secondButton,
            firstButton,
            secondButton,
            firstButton,
        ]
        var finalResolution: ControllerKeyboardShortcutResolution?

        for (index, buttons) in transitions.enumerated() {
            finalResolution = resolver.resolve(
                buttons: buttons,
                now: UInt64(index) * 10_000_000
            )
        }

        #expect(finalResolution?.replayTransitions.count == ShortcutTransitionBuffer.capacity)
        #expect(finalResolution?.forwardedButtons == firstButton)
    }

    private func makeResolver() -> ControllerKeyboardShortcutResolver {
        ControllerKeyboardShortcutResolver(
            targetMask: firstButton | secondButton,
            eligibleButtonMask: firstButton | secondButton | unrelatedButton,
            holdDurationNanoseconds: holdDuration
        )
    }
}
