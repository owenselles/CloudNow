import AVFoundation
import Foundation
@preconcurrency import LiveKitWebRTC

nonisolated struct XboxCloudRTCStatsSnapshot: Equatable {
    var stream = StreamStats()
    var audio = AudioStats()
}

nonisolated struct XboxCloudRTCVideoSample: Equatable, Sendable {
    var timestampUs: Double = 0
    var bytesReceived: Double = 0
    var packetsReceived: Double = 0
    var packetsLost: Double = 0
    var framesDecoded: Double = 0
    var framesDropped: Double = 0
    var framesPerSecond: Double = 0
    var frameWidth: Double = 0
    var frameHeight: Double = 0
    var jitterSeconds: Double = 0
    var jitterBufferDelaySeconds: Double = 0
    var jitterBufferTargetDelaySeconds: Double = 0
    var jitterBufferEmittedCount: Double = 0
    var totalDecodeTimeSeconds: Double = 0
    var totalProcessingDelaySeconds: Double = 0
    var freezeCount: Double = 0
    var nackCount: Double = 0
    var pliCount: Double = 0
    var firCount: Double = 0
    var retransmittedPackets: Double = 0
    var codec = ""
    var decoderImplementation = ""
    var powerEfficientDecoder: Bool?
}

nonisolated struct XboxCloudRTCAudioSample: Equatable, Sendable {
    var codecName = ""
    var codecChannels = 0
    var packetsLost: Double = 0
    var jitterSeconds: Double = 0
    var jitterBufferDelaySeconds: Double = 0
    var jitterBufferTargetDelaySeconds: Double = 0
    var jitterBufferEmittedCount: Double = 0
    var concealedSamples: Double = 0
    var insertedSamplesForDeceleration: Double = 0
    var removedSamplesForAcceleration: Double = 0
    var totalPlayoutDelaySeconds: Double = 0
    var playoutSamplesCount: Double = 0
    var audioPlayoutTimestampMs: Double?
    var videoPlayoutTimestampMs: Double?
}

nonisolated struct XboxCloudRTCConnectionSample: Equatable, Sendable {
    var rttMs: Double = 0
    var availableIncomingBitrateKbps: Int = 0
    var protocolName = ""
    var localCandidateType = ""
    var remoteCandidateType = ""

    var networkPath: String {
        let normalizedProtocol = protocolName.lowercased()
        let usesRelay = localCandidateType.lowercased() == "relay"
            || remoteCandidateType.lowercased() == "relay"
        if normalizedProtocol == "tcp" || normalizedProtocol == "tls" {
            return "tcp_tls_fallback"
        }
        if usesRelay, normalizedProtocol == "udp" {
            return "turn_udp_relay"
        }
        if normalizedProtocol == "udp" {
            return "direct_udp"
        }
        return "unknown"
    }
}

nonisolated struct XboxCloudRTCAudioDeviceSample: Equatable, Sendable {
    var outputLatencyMs: Double = 0
    var outputChannels: Int = 0
    var outputSampleRateHz: Double = 0
    var outputRouteName = ""
}

/// Pure delta accumulator used by the Xbox WebRTC adapter. Keeping interval
/// math independent from WebRTC objects makes it deterministic to test.
nonisolated struct XboxCloudRTCStatsAccumulator {
    private(set) var snapshot = XboxCloudRTCStatsSnapshot()
    private var previousVideo: XboxCloudRTCVideoSample?
    private var previousAudio: XboxCloudRTCAudioSample?

    mutating func reset() {
        self = XboxCloudRTCStatsAccumulator()
    }

    mutating func apply(video sample: XboxCloudRTCVideoSample) {
        var stats = snapshot.stream
        stats.fps = sample.framesPerSecond
        stats.resolutionWidth = xboxBoundedNonnegativeInt(sample.frameWidth)
        stats.resolutionHeight = xboxBoundedNonnegativeInt(sample.frameHeight)
        stats.codec = sample.codec
        stats.jitterMs = sample.jitterSeconds * 1000
        stats.decoderImplementation = sample.decoderImplementation
        stats.powerEfficientDecoder = sample.powerEfficientDecoder

        if let previousVideo {
            let elapsedSeconds = (sample.timestampUs - previousVideo.timestampUs) / 1_000_000
            if elapsedSeconds > 0 {
                stats.bitrateKbps = xboxBoundedNonnegativeInt(
                    max(0, sample.bytesReceived - previousVideo.bytesReceived)
                        * 8 / elapsedSeconds / 1000
                )
            }

            let received = max(0, sample.packetsReceived - previousVideo.packetsReceived)
            let lost = max(0, sample.packetsLost - previousVideo.packetsLost)
            if received + lost > 0 {
                stats.packetLossPercent = lost / (received + lost) * 100
            }

            let emitted = max(
                0,
                sample.jitterBufferEmittedCount - previousVideo.jitterBufferEmittedCount
            )
            stats.jitterBufferDelayMs = intervalAverage(
                sample.jitterBufferDelaySeconds,
                previousVideo.jitterBufferDelaySeconds,
                count: emitted
            )
            stats.jitterBufferTargetDelayMs = intervalAverage(
                sample.jitterBufferTargetDelaySeconds,
                previousVideo.jitterBufferTargetDelaySeconds,
                count: emitted
            )

            let decoded = max(0, sample.framesDecoded - previousVideo.framesDecoded)
            stats.decodeTimeMs = intervalAverage(
                sample.totalDecodeTimeSeconds,
                previousVideo.totalDecodeTimeSeconds,
                count: decoded
            )
            stats.processingDelayMs = intervalAverage(
                sample.totalProcessingDelaySeconds,
                previousVideo.totalProcessingDelaySeconds,
                count: decoded
            )
            stats.framesDropped = intervalCount(
                sample.framesDropped,
                previousVideo.framesDropped
            )
            stats.freezeCount = intervalCount(sample.freezeCount, previousVideo.freezeCount)
            stats.nackCount = intervalCount(sample.nackCount, previousVideo.nackCount)
            stats.pliCount = intervalCount(sample.pliCount, previousVideo.pliCount)
            stats.firCount = intervalCount(sample.firCount, previousVideo.firCount)
            stats.retransmittedPackets = intervalCount(
                sample.retransmittedPackets,
                previousVideo.retransmittedPackets
            )
        }

        previousVideo = sample
        snapshot.stream = stats
    }

    mutating func apply(connection sample: XboxCloudRTCConnectionSample) {
        snapshot.stream.rttMs = sample.rttMs
        snapshot.stream.availableIncomingBitrateKbps = sample.availableIncomingBitrateKbps
        snapshot.stream.selectedProtocol = sample.protocolName
        snapshot.stream.localCandidateType = sample.localCandidateType
        snapshot.stream.remoteCandidateType = sample.remoteCandidateType
        snapshot.stream.selectedNetworkPath = sample.networkPath
    }

    mutating func apply(
        audio sample: XboxCloudRTCAudioSample,
        device: XboxCloudRTCAudioDeviceSample
    ) {
        var audio = snapshot.audio
        audio.codecName = sample.codecName
        audio.codecChannels = sample.codecChannels
        audio.outputLatencyMs = device.outputLatencyMs
        audio.outputChannels = device.outputChannels
        audio.outputSampleRateHz = device.outputSampleRateHz
        audio.outputRouteName = device.outputRouteName

        defer {
            previousAudio = sample
            snapshot.audio = audio
        }
        guard let previousAudio else { return }

        let emitted = max(
            0,
            sample.jitterBufferEmittedCount - previousAudio.jitterBufferEmittedCount
        )
        audio.jitterBufferCurrentMs = intervalAverage(
            sample.jitterBufferDelaySeconds,
            previousAudio.jitterBufferDelaySeconds,
            count: emitted
        )
        audio.jitterBufferTargetMs = intervalAverage(
            sample.jitterBufferTargetDelaySeconds,
            previousAudio.jitterBufferTargetDelaySeconds,
            count: emitted
        )

        let playoutSamples = max(
            0,
            sample.playoutSamplesCount - previousAudio.playoutSamplesCount
        )
        audio.devicePlayoutMs = intervalAverage(
            sample.totalPlayoutDelaySeconds,
            previousAudio.totalPlayoutDelaySeconds,
            count: playoutSamples
        )
        audio.packetsLost = xboxBoundedNonnegativeInt(
            max(0, sample.packetsLost - previousAudio.packetsLost)
        )
        audio.jitterMs = sample.jitterSeconds * 1000
        audio.concealedMsPerSecond = max(
            0,
            sample.concealedSamples - previousAudio.concealedSamples
        ) / 48
        audio.stretchedMsPerSecond = max(
            0,
            sample.insertedSamplesForDeceleration
                - previousAudio.insertedSamplesForDeceleration
        ) / 48
        audio.acceleratedMsPerSecond = max(
            0,
            sample.removedSamplesForAcceleration
                - previousAudio.removedSamplesForAcceleration
        ) / 48
        if let audioTimestamp = sample.audioPlayoutTimestampMs,
           let videoTimestamp = sample.videoPlayoutTimestampMs
        {
            audio.avOffsetMs = videoTimestamp - audioTimestamp
        } else {
            audio.avOffsetMs = nil
        }
    }

    private func intervalAverage(
        _ current: Double,
        _ previous: Double,
        count: Double
    ) -> Double {
        guard count > 0 else { return 0 }
        return max(0, current - previous) / count * 1000
    }

    private func intervalCount(_ current: Double, _ previous: Double) -> Int {
        xboxBoundedNonnegativeInt(max(0, current - previous))
    }
}

/// Xbox-specific adapter from LiveKit WebRTC reports into CloudNow's shared
/// HUD values. GFN keeps its existing collection path unchanged.
@MainActor
final class XboxCloudRTCStatsSampler {
    private static let statisticsTimeout: Duration = .seconds(1)

    private var accumulator = XboxCloudRTCStatsAccumulator()
    private var generation: UInt64 = 0
    private var isSampling = false

    func reset() {
        generation &+= 1
        accumulator.reset()
    }

    func sample(
        peerConnection: LKRTCPeerConnection,
        videoReceiver: LKRTCRtpReceiver?
    ) async -> XboxCloudRTCStatsSnapshot {
        guard !isSampling else { return accumulator.snapshot }
        isSampling = true
        let sampleGeneration = generation
        defer { isSampling = false }

        if let videoReceiver {
            let report = await statistics(
                for: videoReceiver,
                peerConnection: peerConnection
            )
            guard generation == sampleGeneration else { return accumulator.snapshot }
            if let report, let sample = Self.videoSample(from: report) {
                accumulator.apply(video: sample)
            }
        }

        let report = await statistics(peerConnection: peerConnection)
        guard generation == sampleGeneration else { return accumulator.snapshot }
        if let report, let sample = Self.connectionSample(from: report) {
            accumulator.apply(connection: sample)
        }
        if let report, let sample = Self.audioSample(from: report) {
            accumulator.apply(
                audio: sample,
                device: Self.audioDeviceSample()
            )
        }
        return accumulator.snapshot
    }

    private func statistics(
        for receiver: LKRTCRtpReceiver,
        peerConnection: LKRTCPeerConnection
    ) async -> LKRTCStatisticsReport? {
        let callback = XboxCloudBoundedCallback<LKRTCStatisticsReport>(
            timeout: Self.statisticsTimeout,
            timeoutError: .peerOperationFailed(
                operation: "sampling receiver statistics"
            )
        )
        return try? await callback.value { completion in
            peerConnection.statistics(for: receiver) { report in
                completion(.success(report))
            }
        }
    }

    private func statistics(
        peerConnection: LKRTCPeerConnection
    ) async -> LKRTCStatisticsReport? {
        let callback = XboxCloudBoundedCallback<LKRTCStatisticsReport>(
            timeout: Self.statisticsTimeout,
            timeoutError: .peerOperationFailed(
                operation: "sampling connection statistics"
            )
        )
        return try? await callback.value { completion in
            peerConnection.statistics { report in
                completion(.success(report))
            }
        }
    }

    private static func videoSample(
        from report: LKRTCStatisticsReport
    ) -> XboxCloudRTCVideoSample? {
        var codecNames: [String: String] = [:]
        for (identifier, statistic) in report.statistics where statistic.type == "codec" {
            guard let mimeType = statistic.values["mimeType"] as? String else { continue }
            let rawName = mimeType.components(separatedBy: "/").last ?? mimeType
            codecNames[identifier] = switch rawName.uppercased() {
            case "H264": "H.264"
            case "H265", "HEVC": "H.265"
            case "AV01", "AV1": "AV1"
            default: rawName
            }
        }

        guard let statistic = report.statistics.values.first(where: {
            $0.type == "inbound-rtp" && $0.values["kind"] as? String == "video"
        }) else {
            return nil
        }
        let codecIdentifier = statistic.values["codecId"] as? String ?? ""
        return XboxCloudRTCVideoSample(
            timestampUs: statistic.timestamp_us,
            bytesReceived: numericValue(statistic.values["bytesReceived"]),
            packetsReceived: numericValue(statistic.values["packetsReceived"]),
            packetsLost: numericValue(statistic.values["packetsLost"]),
            framesDecoded: numericValue(statistic.values["framesDecoded"]),
            framesDropped: numericValue(statistic.values["framesDropped"]),
            framesPerSecond: numericValue(statistic.values["framesPerSecond"]),
            frameWidth: numericValue(statistic.values["frameWidth"]),
            frameHeight: numericValue(statistic.values["frameHeight"]),
            jitterSeconds: numericValue(statistic.values["jitter"]),
            jitterBufferDelaySeconds: numericValue(statistic.values["jitterBufferDelay"]),
            jitterBufferTargetDelaySeconds: numericValue(
                statistic.values["jitterBufferTargetDelay"]
            ),
            jitterBufferEmittedCount: numericValue(
                statistic.values["jitterBufferEmittedCount"]
            ),
            totalDecodeTimeSeconds: numericValue(statistic.values["totalDecodeTime"]),
            totalProcessingDelaySeconds: numericValue(
                statistic.values["totalProcessingDelay"]
            ),
            freezeCount: numericValue(statistic.values["freezeCount"]),
            nackCount: numericValue(statistic.values["nackCount"]),
            pliCount: numericValue(statistic.values["pliCount"]),
            firCount: numericValue(statistic.values["firCount"]),
            retransmittedPackets: numericValue(
                statistic.values["retransmittedPacketsReceived"]
            ),
            codec: codecNames[codecIdentifier] ?? codecIdentifier,
            decoderImplementation: statistic.values["decoderImplementation"] as? String ?? "",
            powerEfficientDecoder: boolValue(statistic.values["powerEfficientDecoder"])
        )
    }

    private static func audioSample(
        from report: LKRTCStatisticsReport
    ) -> XboxCloudRTCAudioSample? {
        guard let audio = report.statistics.values.first(where: {
            $0.type == "inbound-rtp" && $0.values["kind"] as? String == "audio"
        }) else {
            return nil
        }
        let playout = report.statistics.values.first { $0.type == "media-playout" }
        let video = report.statistics.values.first {
            $0.type == "inbound-rtp" && $0.values["kind"] as? String == "video"
        }
        let codecIdentifier = audio.values["codecId"] as? String
        let codec = codecIdentifier.flatMap { report.statistics[$0] }
        let mimeType = codec?.values["mimeType"] as? String ?? ""
        let codecName = mimeType.components(separatedBy: "/").last ?? mimeType
        return XboxCloudRTCAudioSample(
            codecName: codecName,
            codecChannels: xboxBoundedNonnegativeInt(
                numericValue(codec?.values["channels"])
            ),
            packetsLost: numericValue(audio.values["packetsLost"]),
            jitterSeconds: numericValue(audio.values["jitter"]),
            jitterBufferDelaySeconds: numericValue(audio.values["jitterBufferDelay"]),
            jitterBufferTargetDelaySeconds: numericValue(
                audio.values["jitterBufferTargetDelay"]
            ),
            jitterBufferEmittedCount: numericValue(audio.values["jitterBufferEmittedCount"]),
            concealedSamples: numericValue(audio.values["concealedSamples"]),
            insertedSamplesForDeceleration: numericValue(
                audio.values["insertedSamplesForDeceleration"]
            ),
            removedSamplesForAcceleration: numericValue(
                audio.values["removedSamplesForAcceleration"]
            ),
            totalPlayoutDelaySeconds: numericValue(playout?.values["totalPlayoutDelay"]),
            playoutSamplesCount: numericValue(playout?.values["totalSamplesCount"]),
            audioPlayoutTimestampMs: number(audio.values["estimatedPlayoutTimestamp"]),
            videoPlayoutTimestampMs: number(video?.values["estimatedPlayoutTimestamp"])
        )
    }

    private static func connectionSample(
        from report: LKRTCStatisticsReport
    ) -> XboxCloudRTCConnectionSample? {
        let selectedPairIdentifier = report.statistics.values
            .first(where: { $0.type == "transport" })?
            .values["selectedCandidatePairId"] as? String
        let succeededPairs = report.statistics.values.filter {
            $0.type == "candidate-pair" && $0.values["state"] as? String == "succeeded"
        }
        let selectedPair = selectedPairIdentifier.flatMap { report.statistics[$0] }
            ?? succeededPairs.first(where: {
                boolValue($0.values["nominated"]) == true
            })
            ?? succeededPairs.first
        guard let selectedPair else { return nil }

        let localIdentifier = selectedPair.values["localCandidateId"] as? String
        let remoteIdentifier = selectedPair.values["remoteCandidateId"] as? String
        let local = localIdentifier.flatMap { report.statistics[$0] }
        let remote = remoteIdentifier.flatMap { report.statistics[$0] }
        let localProtocol = local?.values["protocol"] as? String ?? ""
        let remoteProtocol = remote?.values["protocol"] as? String ?? ""
        return XboxCloudRTCConnectionSample(
            rttMs: numericValue(selectedPair.values["currentRoundTripTime"]) * 1000,
            availableIncomingBitrateKbps: xboxBoundedNonnegativeInt(
                numericValue(selectedPair.values["availableIncomingBitrate"]) / 1000
            ),
            protocolName: localProtocol.isEmpty ? remoteProtocol : localProtocol,
            localCandidateType: local?.values["candidateType"] as? String ?? "",
            remoteCandidateType: remote?.values["candidateType"] as? String ?? ""
        )
    }

    private static func audioDeviceSample() -> XboxCloudRTCAudioDeviceSample {
        XboxCloudRTCAudioDeviceSample(
            outputLatencyMs: AVAudioSession.sharedInstance().outputLatency * 1000,
            outputChannels: CloudAudioDevice.shared.outputNumberOfChannels,
            outputSampleRateHz: CloudAudioDevice.shared.deviceOutputSampleRate,
            outputRouteName: CloudAudioDevice.shared.outputRouteName
        )
    }

    private static func numericValue(_ value: Any?) -> Double {
        guard let number = (value as? NSNumber)?.doubleValue,
              number.isFinite
        else {
            return 0
        }
        return number
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue,
              number.isFinite
        else {
            return nil
        }
        return number
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }
}

private nonisolated func xboxBoundedNonnegativeInt(_ value: Double) -> Int {
    guard !value.isNaN, value > 0 else { return 0 }
    guard value.isFinite else { return Int.max }
    guard value < Double(Int.max) else { return Int.max }
    return Int(value)
}
