@testable import CloudNow
import Testing

@Suite("Replayed tap scheduler")
struct ReplayedTapSchedulerTests {
    private let buttonY: UInt16 = 1 << 15
    private let buttonView: UInt16 = 1 << 5
    private let buttonStart: UInt16 = 1 << 4
    private let buttonA: UInt16 = 1 << 12
    private let hold: UInt64 = 80
    private let gap: UInt64 = 50

    @Test("An isolated tap stays down for the minimum hold, then releases once")
    func isolatedTapHonorsMinimumHold() {
        var scheduler = makeScheduler()
        var recorder = EdgeRecorder()

        scheduler.beginReplayedPress(buttonY, now: 0)
        for now in stride(from: UInt64(0), through: 200, by: 10) {
            recorder.record(scheduler.compose(forwarded: 0, now: now), at: now)
        }

        #expect(recorder.edges(of: buttonY) == [.down(at: 0), .up(at: 80)])
        #expect(scheduler.managedButtons == 0)
    }

    @Test("A tap of another button does not cut a pending replay short")
    func overlappingButtonsKeepIndependentHolds() {
        var scheduler = makeScheduler()
        var recorder = EdgeRecorder()

        for now in stride(from: UInt64(0), through: 200, by: 10) {
            if now == 0 {
                scheduler.beginReplayedPress(buttonY, now: now)
            }
            if now == 30 {
                scheduler.beginReplayedPress(buttonView, now: now)
            }
            recorder.record(scheduler.compose(forwarded: 0, now: now), at: now)
        }

        #expect(recorder.edges(of: buttonY) == [.down(at: 0), .up(at: 80)])
        #expect(recorder.edges(of: buttonView) == [.down(at: 30), .up(at: 110)])
    }

    @Test("Two quick taps of one button stay two presses with a minimum release between them")
    func repeatedTapsStayDistinct() {
        var scheduler = makeScheduler()
        var recorder = EdgeRecorder()

        for now in stride(from: UInt64(0), through: 400, by: 10) {
            if now == 0 || now == 30 {
                scheduler.beginReplayedPress(buttonY, now: now)
            }
            recorder.record(scheduler.compose(forwarded: 0, now: now), at: now)
        }

        #expect(recorder.edges(of: buttonY) == [
            .down(at: 0), .up(at: 80),
            .down(at: 130), .up(at: 210),
        ])
    }

    @Test("A release just after the chord timeout still gets the full minimum hold")
    func releaseAfterTimeoutGetsFullHold() {
        var scheduler = makeScheduler()
        var recorder = EdgeRecorder()

        // The candidate timed out while Y was held, so Y was forwarded late at 0 and is
        // still physically down; the player lets go 10 later.
        scheduler.beginReplayedPress(buttonY, now: 0)
        for now in stride(from: UInt64(0), through: 200, by: 10) {
            let forwarded = now < 10 ? buttonY : 0
            recorder.record(scheduler.compose(forwarded: forwarded, now: now), at: now)
        }

        #expect(recorder.edges(of: buttonY) == [.down(at: 0), .up(at: 80)])
    }

    @Test("A replayed press still held after the minimum hold releases without extra delay")
    func heldPressReturnsToOrdinaryForwarding() {
        var scheduler = makeScheduler()
        var recorder = EdgeRecorder()

        scheduler.beginReplayedPress(buttonY, now: 0)
        for now in stride(from: UInt64(0), through: 300, by: 10) {
            let forwarded = now < 250 ? buttonY : 0
            recorder.record(scheduler.compose(forwarded: forwarded, now: now), at: now)
        }

        #expect(recorder.edges(of: buttonY) == [.down(at: 0), .up(at: 250)])
        #expect(scheduler.managedButtons == 0)
    }

    @Test("An ordinary press of a button during its replay hold becomes a separate press")
    func ordinaryPressDuringHoldIsQueued() {
        var scheduler = makeScheduler()
        var recorder = EdgeRecorder()

        scheduler.beginReplayedPress(buttonY, now: 0)
        for now in stride(from: UInt64(0), through: 400, by: 10) {
            // Y passes through directly from 40 to 60, for example while A is held.
            let forwarded = (40 ..< 60).contains(now) ? buttonY | buttonA : 0
            recorder.record(scheduler.compose(forwarded: forwarded, now: now), at: now)
        }

        #expect(recorder.edges(of: buttonY) == [
            .down(at: 0), .up(at: 80),
            .down(at: 130), .up(at: 210),
        ])
        #expect(recorder.edges(of: buttonA) == [.down(at: 40), .up(at: 60)])
    }

    @Test("Queued repeat presses are bounded per button")
    func queuedPressesAreBounded() {
        var scheduler = makeScheduler()
        var recorder = EdgeRecorder()

        for _ in 0 ..< 6 {
            scheduler.beginReplayedPress(buttonY, now: 0)
        }
        for now in stride(from: UInt64(0), through: 1000, by: 10) {
            recorder.record(scheduler.compose(forwarded: 0, now: now), at: now)
        }

        let presses = recorder.edges(of: buttonY).filter(\.isDown)
        #expect(presses.count == 1 + Int(ReplayedTapScheduler.maximumQueuedPresses))
        #expect(scheduler.managedButtons == 0)
    }

    @Test("Unmanaged buttons are forwarded immediately while a replay is held")
    func unmanagedButtonsPassThrough() {
        var scheduler = makeScheduler()

        scheduler.beginReplayedPress(buttonStart, now: 0)

        #expect(scheduler.compose(forwarded: buttonA, now: 5) == buttonA | buttonStart)
        #expect(scheduler.compose(forwarded: 0, now: 15) == buttonStart)
        #expect(scheduler.compose(forwarded: buttonA, now: 100) == buttonA)
    }

    @Test("Replayed down edges are emitted in order and a release-phase press waits")
    func overlayEmitsDownEdgesInOrder() {
        var scheduler = makeScheduler()

        scheduler.beginReplayedPress(buttonView, now: 0)
        #expect(scheduler.overlay(onto: buttonA) == buttonA | buttonView)
        scheduler.beginReplayedPress(buttonY, now: 0)
        #expect(scheduler.overlay(onto: buttonA) == buttonA | buttonView | buttonY)

        _ = scheduler.compose(forwarded: 0, now: 90)
        scheduler.beginReplayedPress(buttonY, now: 95)
        #expect(scheduler.overlay(onto: 0) & buttonY == 0)
    }

    @Test("A controller that reuses a slot does not inherit a pending replay")
    func slotReuseDropsPendingReplay() {
        var slots = ReplayedTapSlots(minimumHold: hold, minimumGap: gap)

        slots.beginReplayedPress(buttonY, slot: 0, now: 0)
        slots.beginReplayedPress(buttonY, slot: 0, now: 10)
        slots.beginReplayedPress(buttonStart, slot: 1, now: 0)
        #expect(slots.compose(forwarded: 0, slot: 0, now: 20) == buttonY)

        slots.releaseSlot(0)

        #expect(slots.managedButtons(slot: 0) == 0)
        for now in stride(from: UInt64(20), through: 300, by: 10) {
            #expect(slots.compose(forwarded: 0, slot: 0, now: now) == 0)
        }
        #expect(slots.compose(forwarded: 0, slot: 1, now: 30) == buttonStart)
    }

    @Test("Clearing all slots drops every pending replay")
    func removeAllDropsEverySlot() {
        var slots = ReplayedTapSlots(minimumHold: hold, minimumGap: gap)

        slots.beginReplayedPress(buttonY, slot: 0, now: 0)
        slots.beginReplayedPress(buttonStart, slot: 1, now: 0)
        slots.removeAll()

        #expect(slots.compose(forwarded: 0, slot: 0, now: 10) == 0)
        #expect(slots.compose(forwarded: 0, slot: 1, now: 10) == 0)
    }

    private func makeScheduler() -> ReplayedTapScheduler {
        ReplayedTapScheduler(minimumHold: hold, minimumGap: gap)
    }
}

private enum ButtonEdge: Equatable {
    case down(at: UInt64)
    case up(at: UInt64)

    var isDown: Bool {
        if case .down = self {
            return true
        }
        return false
    }
}

private struct EdgeRecorder {
    private var lastButtons: UInt16 = 0
    private var history: [(buttons: UInt16, time: UInt64)] = []

    mutating func record(_ buttons: UInt16, at time: UInt64) {
        guard buttons != lastButtons else { return }
        history.append((buttons, time))
        lastButtons = buttons
    }

    func edges(of button: UInt16) -> [ButtonEdge] {
        var wasDown = false
        var edges: [ButtonEdge] = []
        for entry in history {
            let isDown = entry.buttons & button != 0
            guard isDown != wasDown else { continue }
            edges.append(isDown ? .down(at: entry.time) : .up(at: entry.time))
            wasDown = isDown
        }
        return edges
    }
}
