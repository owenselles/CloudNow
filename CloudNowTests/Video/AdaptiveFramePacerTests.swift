@testable import CloudNow
import Testing

@Suite("Adaptive video frame pacing")
struct AdaptiveFramePacerTests {
    @Test("First and steadily delivered frames have no added delay", arguments: [30, 60, 120])
    func stableDeliveryIsImmediate(frameRate: Int) {
        var pacer = AdaptiveFramePacer(frameRate: frameRate)

        for index in 0 ..< 12 {
            let timestamp = UInt32(index * (90000 / frameRate))
            let arrival = Double(index) / Double(frameRate)
            let reset = pacer.observe(timestamp: timestamp, arrivalTime: arrival)
            let deadline = pacer.deadline(timestamp: timestamp, arrivalTime: arrival, now: arrival)

            #expect(!reset)
            #expect(abs(deadline - arrival) < 0.000_001)
            pacer.didSubmit(timestamp: timestamp, deadline: deadline)
        }
    }

    @Test("Late frames display immediately and compressed arrivals receive bounded spacing")
    func lateThenEarlyDelivery() {
        var pacer = AdaptiveFramePacer(frameRate: 60)
        _ = submit(timestamp: 0, arrival: 0, to: &pacer)
        let late = submit(timestamp: 1500, arrival: 0.030, to: &pacer)
        let early = submit(timestamp: 3000, arrival: 0.031, to: &pacer)

        #expect(late == 0.030)
        #expect(early > 0.031)
        #expect(early - 0.031 <= pacer.maximumDelay)
        #expect(early <= late + 1.0 / 60)
    }

    @Test("Stable delivery reduces a previously needed pacing delay")
    func stableDeliveryRemovesJitterBudget() {
        var pacer = AdaptiveFramePacer(frameRate: 60)
        _ = submit(timestamp: 0, arrival: 0, to: &pacer)
        _ = submit(timestamp: 1500, arrival: 0.030, to: &pacer)
        let held = submit(timestamp: 3000, arrival: 0.031, to: &pacer)
        let initialJitter = pacer.jitter
        var lastDelay = held - 0.031

        for index in 1 ... 80 {
            let arrival = 0.031 + Double(index) / 60
            let deadline = submit(timestamp: UInt32(3000 + index * 1500), arrival: arrival, to: &pacer)
            lastDelay = deadline - arrival
        }

        #expect(pacer.jitter < initialJitter)
        #expect(lastDelay < held - 0.031)
        #expect(lastDelay < 0.001)
    }

    @Test("RTP timestamp rollover preserves frame pacing")
    func rtpRollover() {
        var pacer = AdaptiveFramePacer(frameRate: 60)
        _ = submit(timestamp: UInt32.max - 1499, arrival: 0, to: &pacer)

        let reset = pacer.observe(timestamp: 0, arrivalTime: 0.010)
        let deadline = pacer.deadline(timestamp: 0, arrivalTime: 0.010, now: 0.010)

        #expect(!reset)
        #expect(deadline > 0.010)
        #expect(deadline <= 1.0 / 60)
    }

    @Test(
        "Duplicate, backwards, and discontinuous timestamps clear pending pacing",
        arguments: [
            (UInt32(3000), 0.040),
            (UInt32(1500), 0.040),
            (UInt32(27000), 0.040),
            (UInt32(4500), 0.500),
            (UInt32(4500), 0.030),
        ]
    )
    func discontinuityResets(timestamp: UInt32, arrival: Double) {
        var pacer = AdaptiveFramePacer(frameRate: 60)
        _ = submit(timestamp: 0, arrival: 0, to: &pacer)
        _ = submit(timestamp: 1500, arrival: 0.030, to: &pacer)
        _ = submit(timestamp: 3000, arrival: 0.031, to: &pacer)

        let reset = pacer.observe(timestamp: timestamp, arrivalTime: arrival)
        let deadline = pacer.deadline(timestamp: timestamp, arrivalTime: arrival, now: arrival)

        #expect(reset)
        #expect(pacer.jitter == 0)
        #expect(deadline == arrival)
        pacer.didSubmit(timestamp: timestamp, deadline: deadline)

        let resumed = submit(timestamp: timestamp + 1500, arrival: arrival + 1.0 / 60, to: &pacer)
        #expect(abs(resumed - (arrival + 1.0 / 60)) < 0.000_001)
    }

    @Test("A 30 fps source retains its timestamp spacing under a 60 fps setting")
    func sourceFrameRateDeterminesSpacing() {
        var pacer = AdaptiveFramePacer(frameRate: 60)
        _ = submit(timestamp: 0, arrival: 0, to: &pacer)
        _ = submit(timestamp: 3000, arrival: 0.040, to: &pacer)
        let early = submit(timestamp: 6000, arrival: 0.065, to: &pacer)

        #expect(early > 0.065)
        #expect(early <= 0.040 + 1.0 / 30)
        #expect(early - 0.065 <= 1.0 / 60)
    }

    @Test("Repeated bursts never add more than one configured frame of delay", arguments: [30, 60, 120])
    func burstDelayIsBounded(frameRate: Int) {
        var pacer = AdaptiveFramePacer(frameRate: frameRate)
        var arrival = 0.0
        var delayedFrames = 0

        for index in 0 ..< 100 {
            arrival += index.isMultiple(of: 2) ? 0.080 : 0.001
            let deadline = submit(
                timestamp: UInt32(index * (90000 / frameRate)),
                arrival: arrival,
                to: &pacer
            )
            let delay = deadline - arrival
            #expect(delay >= 0)
            #expect(delay <= 1.0 / Double(frameRate) + 0.000_001)
            if delay > 0 {
                delayedFrames += 1
            }
        }

        #expect(delayedFrames > 0)
    }

    @Test("Explicit reset discards learned jitter and pending presentation timing")
    func explicitResetRestoresImmediatePresentation() {
        var pacer = AdaptiveFramePacer(frameRate: 60)
        _ = submit(timestamp: 0, arrival: 0, to: &pacer)
        _ = submit(timestamp: 1500, arrival: 0.030, to: &pacer)
        _ = submit(timestamp: 3000, arrival: 0.031, to: &pacer)
        pacer.reset()

        #expect(pacer.jitter == 0)
        let first = submit(timestamp: 4500, arrival: 0.032, to: &pacer)
        #expect(first == 0.032)
    }

    @Test("A delayed renderer callback never waits on an expired presentation deadline")
    func expiredDeadlineIsImmediate() {
        var pacer = AdaptiveFramePacer(frameRate: 60)
        _ = submit(timestamp: 0, arrival: 0, to: &pacer)
        _ = submit(timestamp: 1500, arrival: 0.030, to: &pacer)
        _ = pacer.observe(timestamp: 3000, arrivalTime: 0.031)

        let deadline = pacer.deadline(timestamp: 3000, arrivalTime: 0.031, now: 0.100)
        #expect(deadline == 0.100)
    }

    private func submit(timestamp: UInt32, arrival: Double, to pacer: inout AdaptiveFramePacer) -> Double {
        _ = pacer.observe(timestamp: timestamp, arrivalTime: arrival)
        let deadline = pacer.deadline(timestamp: timestamp, arrivalTime: arrival, now: arrival)
        pacer.didSubmit(timestamp: timestamp, deadline: deadline)
        return deadline
    }
}
