@testable import CloudNow
import Testing

@Suite("Video pipeline diagnostics")
struct VideoPipelineDiagnosticsTests {
    @Test("Disabled diagnostics do not collect frame or AV metrics")
    func disabledCollection() {
        let diagnostics = VideoPipelineDiagnostics()

        #expect(diagnostics.beginFrame() == nil)
        #expect(diagnostics.beginConversion(nil) == 0)
        #expect(diagnostics.beginSampleCreation(nil) == 0)
        diagnostics.endConversion(nil, startedAt: 0)
        diagnostics.cancelConversion(nil)
        diagnostics.endSampleCreation(nil, startedAt: 0)
        diagnostics.recordEnqueue(nil)
        diagnostics.recordDrop(nil)
        diagnostics.recordBackpressure()
        diagnostics.recordRendererFailure()
        diagnostics.recordRendererFlush()
        diagnostics.updateAVMetrics(
            totalFrames: 100,
            droppedFrames: 10,
            corruptedFrames: 2,
            accumulatedFrameDelaySeconds: 1.5
        )

        expectEmpty(diagnostics.snapshot())
    }

    @Test("Enabling records counters and disabling resets all collected state")
    func enableAndReset() throws {
        let diagnostics = VideoPipelineDiagnostics()
        diagnostics.setEnabled(true)

        let enqueuedTrace = try #require(diagnostics.beginFrame())
        diagnostics.recordEnqueue(enqueuedTrace)
        let droppedTrace = try #require(diagnostics.beginFrame())
        diagnostics.recordDrop(droppedTrace)
        diagnostics.recordBackpressure()
        diagnostics.recordRendererFailure()
        diagnostics.recordRendererFlush()

        let collected = diagnostics.snapshot()
        #expect(collected.callbackFrames == 2)
        #expect(collected.enqueuedFrames == 1)
        #expect(collected.droppedFrames == 1)
        #expect(collected.backpressureEvents == 1)
        #expect(collected.rendererFailures == 1)
        #expect(collected.rendererFlushes == 1)

        diagnostics.setEnabled(true)
        #expect(diagnostics.snapshot().callbackFrames == 2)

        diagnostics.setEnabled(false)
        expectEmpty(diagnostics.snapshot())

        diagnostics.setEnabled(true)
        expectEmpty(diagnostics.snapshot())
    }

    @Test("AV metrics use nonnegative deltas from the previous sample")
    func avMetricDeltas() {
        let diagnostics = VideoPipelineDiagnostics()
        diagnostics.setEnabled(true)

        diagnostics.updateAVMetrics(
            totalFrames: 1000,
            droppedFrames: 20,
            corruptedFrames: 4,
            accumulatedFrameDelaySeconds: 12.25
        )
        let baseline = diagnostics.snapshot()
        #expect(baseline.avTotalFrames == 0)
        #expect(baseline.avDroppedFrames == 0)
        #expect(baseline.avCorruptedFrames == 0)
        #expect(baseline.avAccumulatedFrameDelayMs == 0)

        diagnostics.updateAVMetrics(
            totalFrames: 1025,
            droppedFrames: 23,
            corruptedFrames: 6,
            accumulatedFrameDelaySeconds: 12.2875
        )
        let delta = diagnostics.snapshot()
        #expect(delta.avTotalFrames == 25)
        #expect(delta.avDroppedFrames == 3)
        #expect(delta.avCorruptedFrames == 2)
        #expect(abs(delta.avAccumulatedFrameDelayMs - 37.5) < 0.000_1)

        diagnostics.updateAVMetrics(
            totalFrames: 5,
            droppedFrames: 1,
            corruptedFrames: 0,
            accumulatedFrameDelaySeconds: 0.5
        )
        let resetCounters = diagnostics.snapshot()
        #expect(resetCounters.avTotalFrames == 0)
        #expect(resetCounters.avDroppedFrames == 0)
        #expect(resetCounters.avCorruptedFrames == 0)
        #expect(resetCounters.avAccumulatedFrameDelayMs == 0)
    }

    @Test("Re-enabling establishes a new AV baseline")
    func avBaselineResetsAcrossEnablement() {
        let diagnostics = VideoPipelineDiagnostics()
        diagnostics.setEnabled(true)
        diagnostics.updateAVMetrics(
            totalFrames: 100,
            droppedFrames: 5,
            corruptedFrames: 1,
            accumulatedFrameDelaySeconds: 2
        )
        diagnostics.updateAVMetrics(
            totalFrames: 110,
            droppedFrames: 6,
            corruptedFrames: 2,
            accumulatedFrameDelaySeconds: 2.01
        )
        #expect(diagnostics.snapshot().avTotalFrames == 10)

        diagnostics.setEnabled(false)
        diagnostics.setEnabled(true)
        diagnostics.updateAVMetrics(
            totalFrames: 500,
            droppedFrames: 50,
            corruptedFrames: 5,
            accumulatedFrameDelaySeconds: 20
        )

        let newBaseline = diagnostics.snapshot()
        #expect(newBaseline.avTotalFrames == 0)
        #expect(newBaseline.avDroppedFrames == 0)
        #expect(newBaseline.avCorruptedFrames == 0)
        #expect(newBaseline.avAccumulatedFrameDelayMs == 0)
    }

    private func expectEmpty(_ snapshot: VideoPipelineSnapshot) {
        #expect(snapshot.callbackFrames == 0)
        #expect(snapshot.softwareConvertedFrames == 0)
        #expect(snapshot.enqueuedFrames == 0)
        #expect(snapshot.droppedFrames == 0)
        #expect(snapshot.backpressureEvents == 0)
        #expect(snapshot.rendererFailures == 0)
        #expect(snapshot.rendererFlushes == 0)
        #expect(snapshot.averageConversionMs == 0)
        #expect(snapshot.averageSampleCreationMs == 0)
        #expect(snapshot.avTotalFrames == 0)
        #expect(snapshot.avDroppedFrames == 0)
        #expect(snapshot.avCorruptedFrames == 0)
        #expect(snapshot.avAccumulatedFrameDelayMs == 0)
    }
}
