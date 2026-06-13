import Foundation
import os

struct VideoPipelineSnapshot: Sendable {
    var callbackFrames: Int = 0
    var softwareConvertedFrames: Int = 0
    var enqueuedFrames: Int = 0
    var droppedFrames: Int = 0
    var backpressureEvents: Int = 0
    var rendererFailures: Int = 0
    var rendererFlushes: Int = 0
    var averageConversionMs: Double = 0
    var averageSampleCreationMs: Double = 0
    var avTotalFrames: Int = 0
    var avDroppedFrames: Int = 0
    var avCorruptedFrames: Int = 0
    var avAccumulatedFrameDelayMs: Double = 0
}

struct VideoFrameTrace {
    fileprivate let signpostID: OSSignpostID
}

final class VideoPipelineDiagnostics: @unchecked Sendable {
    private struct State {
        var isEnabled = false
        var snapshot = VideoPipelineSnapshot()
        var conversionNanoseconds: UInt64 = 0
        var sampleCreationNanoseconds: UInt64 = 0
        var sampleCreationCount = 0
    }

    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "CloudNow",
        category: "VideoPipeline"
    )

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setEnabled(_ enabled: Bool) {
        state.withLock { state in
            guard state.isEnabled != enabled else { return }
            state = State(isEnabled: enabled)
        }
    }

    func beginFrame() -> VideoFrameTrace? {
        let enabled = state.withLock { state -> Bool in
            guard state.isEnabled else { return false }
            state.snapshot.callbackFrames += 1
            return true
        }
        guard enabled else { return nil }

        let signpostID = OSSignpostID(log: Self.log)
        os_signpost(.begin, log: Self.log, name: "DecodedFrame", signpostID: signpostID)
        return VideoFrameTrace(signpostID: signpostID)
    }

    func beginConversion(_ trace: VideoFrameTrace?) -> UInt64 {
        guard let trace else { return 0 }
        os_signpost(.begin, log: Self.log, name: "I420Conversion", signpostID: trace.signpostID)
        return DispatchTime.now().uptimeNanoseconds
    }

    func endConversion(_ trace: VideoFrameTrace?, startedAt: UInt64) {
        guard let trace else { return }
        let duration = DispatchTime.now().uptimeNanoseconds - startedAt
        state.withLock { state in
            state.snapshot.softwareConvertedFrames += 1
            state.conversionNanoseconds &+= duration
            state.snapshot.averageConversionMs = Self.averageMilliseconds(
                totalNanoseconds: state.conversionNanoseconds,
                count: state.snapshot.softwareConvertedFrames
            )
        }
        os_signpost(.end, log: Self.log, name: "I420Conversion", signpostID: trace.signpostID)
    }

    func cancelConversion(_ trace: VideoFrameTrace?) {
        guard let trace else { return }
        os_signpost(.end, log: Self.log, name: "I420Conversion", signpostID: trace.signpostID)
    }

    func beginSampleCreation(_ trace: VideoFrameTrace?) -> UInt64 {
        guard let trace else { return 0 }
        os_signpost(.begin, log: Self.log, name: "SampleCreation", signpostID: trace.signpostID)
        return DispatchTime.now().uptimeNanoseconds
    }

    func endSampleCreation(_ trace: VideoFrameTrace?, startedAt: UInt64) {
        guard let trace else { return }
        let duration = DispatchTime.now().uptimeNanoseconds - startedAt
        state.withLock { state in
            state.sampleCreationNanoseconds &+= duration
            state.sampleCreationCount += 1
            state.snapshot.averageSampleCreationMs = Self.averageMilliseconds(
                totalNanoseconds: state.sampleCreationNanoseconds,
                count: state.sampleCreationCount
            )
        }
        os_signpost(.end, log: Self.log, name: "SampleCreation", signpostID: trace.signpostID)
    }

    func recordEnqueue(_ trace: VideoFrameTrace?) {
        state.withLock { state in
            guard state.isEnabled else { return }
            state.snapshot.enqueuedFrames += 1
        }
        guard let trace else { return }
        os_signpost(.end, log: Self.log, name: "DecodedFrame", signpostID: trace.signpostID)
    }

    func recordDrop(_ trace: VideoFrameTrace?) {
        state.withLock { state in
            guard state.isEnabled else { return }
            state.snapshot.droppedFrames += 1
        }
        guard let trace else { return }
        os_signpost(.end, log: Self.log, name: "DecodedFrame", signpostID: trace.signpostID)
    }

    func recordBackpressure() {
        state.withLock { state in
            guard state.isEnabled else { return }
            state.snapshot.backpressureEvents += 1
        }
    }

    func recordRendererFailure() {
        state.withLock { state in
            guard state.isEnabled else { return }
            state.snapshot.rendererFailures += 1
        }
        os_signpost(.event, log: Self.log, name: "RendererFailure")
    }

    func recordRendererFlush() {
        state.withLock { state in
            guard state.isEnabled else { return }
            state.snapshot.rendererFlushes += 1
        }
        os_signpost(.event, log: Self.log, name: "RendererFlush")
    }

    func updateAVMetrics(
        totalFrames: Int,
        droppedFrames: Int,
        corruptedFrames: Int,
        accumulatedFrameDelaySeconds: Double
    ) {
        state.withLock { state in
            guard state.isEnabled else { return }
            state.snapshot.avTotalFrames = totalFrames
            state.snapshot.avDroppedFrames = droppedFrames
            state.snapshot.avCorruptedFrames = corruptedFrames
            state.snapshot.avAccumulatedFrameDelayMs = accumulatedFrameDelaySeconds * 1000
        }
    }

    func snapshot() -> VideoPipelineSnapshot {
        state.withLock { $0.snapshot }
    }

    nonisolated private static func averageMilliseconds(totalNanoseconds: UInt64, count: Int) -> Double {
        guard count > 0 else { return 0 }
        return Double(totalNanoseconds) / Double(count) / 1_000_000
    }
}
