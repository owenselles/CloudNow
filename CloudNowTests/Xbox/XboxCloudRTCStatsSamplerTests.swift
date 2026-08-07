@testable import CloudNow
import Testing

@Suite("Xbox Cloud RTC statistics")
struct XboxCloudRTCStatsSamplerTests {
    @Test("Video counters become one-second interval metrics")
    func videoDeltas() {
        var accumulator = XboxCloudRTCStatsAccumulator()
        accumulator.apply(video: XboxCloudRTCVideoSample(
            timestampUs: 1_000_000,
            bytesReceived: 1000,
            packetsReceived: 100,
            packetsLost: 10,
            framesDecoded: 100,
            framesDropped: 2,
            framesPerSecond: 60,
            frameWidth: 1920,
            frameHeight: 1080,
            jitterSeconds: 0.003,
            jitterBufferDelaySeconds: 0.2,
            jitterBufferTargetDelaySeconds: 0.3,
            jitterBufferEmittedCount: 100,
            totalDecodeTimeSeconds: 0.15,
            totalProcessingDelaySeconds: 0.05,
            freezeCount: 1,
            nackCount: 2,
            pliCount: 3,
            firCount: 4,
            retransmittedPackets: 5,
            codec: "H.264"
        ))
        accumulator.apply(video: XboxCloudRTCVideoSample(
            timestampUs: 2_000_000,
            bytesReceived: 126_000,
            packetsReceived: 195,
            packetsLost: 15,
            framesDecoded: 160,
            framesDropped: 5,
            framesPerSecond: 59.9,
            frameWidth: 1920,
            frameHeight: 1080,
            jitterSeconds: 0.004,
            jitterBufferDelaySeconds: 0.3,
            jitterBufferTargetDelaySeconds: 0.5,
            jitterBufferEmittedCount: 150,
            totalDecodeTimeSeconds: 0.27,
            totalProcessingDelaySeconds: 0.11,
            freezeCount: 3,
            nackCount: 6,
            pliCount: 5,
            firCount: 5,
            retransmittedPackets: 12,
            codec: "H.264"
        ))

        let stats = accumulator.snapshot.stream
        #expect(stats.bitrateKbps == 1000)
        #expect(stats.packetLossPercent == 5)
        #expect(stats.jitterMs == 4)
        #expect(abs(stats.jitterBufferDelayMs - 2) < 0.000_001)
        #expect(stats.jitterBufferTargetDelayMs == 4)
        #expect(abs(stats.decodeTimeMs - 2) < 0.000_001)
        #expect(stats.processingDelayMs == 1)
        #expect(stats.framesDropped == 3)
        #expect(stats.freezeCount == 2)
        #expect(stats.nackCount == 4)
        #expect(stats.pliCount == 2)
        #expect(stats.firCount == 1)
        #expect(stats.retransmittedPackets == 7)
    }

    @Test(
        "Candidate pairs map to the shared network path",
        arguments: [
            ("udp", "host", "srflx", "direct_udp"),
            ("udp", "relay", "relay", "turn_udp_relay"),
            ("tcp", "host", "host", "tcp_tls_fallback"),
            ("", "", "", "unknown"),
        ]
    )
    func networkPath(
        protocolName: String,
        localCandidateType: String,
        remoteCandidateType: String,
        expected: String
    ) {
        let sample = XboxCloudRTCConnectionSample(
            protocolName: protocolName,
            localCandidateType: localCandidateType,
            remoteCandidateType: remoteCandidateType
        )

        #expect(sample.networkPath == expected)
    }

    @Test("Audio codec and interval metrics stay source-driven")
    func audioDeltas() {
        var accumulator = XboxCloudRTCStatsAccumulator()
        let device = XboxCloudRTCAudioDeviceSample(
            outputLatencyMs: 18,
            outputChannels: 6,
            outputSampleRateHz: 48000,
            outputRouteName: "HDMI"
        )
        accumulator.apply(
            audio: XboxCloudRTCAudioSample(
                codecName: "opus",
                codecChannels: 2,
                packetsLost: 2,
                jitterSeconds: 0.002,
                jitterBufferDelaySeconds: 0.1,
                jitterBufferTargetDelaySeconds: 0.2,
                jitterBufferEmittedCount: 100,
                concealedSamples: 48,
                insertedSamplesForDeceleration: 96,
                removedSamplesForAcceleration: 48,
                totalPlayoutDelaySeconds: 0.1,
                playoutSamplesCount: 100,
                audioPlayoutTimestampMs: 900,
                videoPlayoutTimestampMs: 905
            ),
            device: device
        )
        accumulator.apply(
            audio: XboxCloudRTCAudioSample(
                codecName: "opus",
                codecChannels: 2,
                packetsLost: 5,
                jitterSeconds: 0.004,
                jitterBufferDelaySeconds: 0.2,
                jitterBufferTargetDelaySeconds: 0.4,
                jitterBufferEmittedCount: 150,
                concealedSamples: 528,
                insertedSamplesForDeceleration: 336,
                removedSamplesForAcceleration: 144,
                totalPlayoutDelaySeconds: 0.2,
                playoutSamplesCount: 150,
                audioPlayoutTimestampMs: 1000,
                videoPlayoutTimestampMs: 1008
            ),
            device: device
        )

        let audio = accumulator.snapshot.audio
        #expect(audio.codecName == "opus")
        #expect(audio.codecChannels == 2)
        #expect(audio.packetsLost == 3)
        #expect(audio.jitterMs == 4)
        #expect(audio.jitterBufferCurrentMs == 2)
        #expect(audio.jitterBufferTargetMs == 4)
        #expect(audio.devicePlayoutMs == 2)
        #expect(audio.concealedMsPerSecond == 10)
        #expect(audio.stretchedMsPerSecond == 5)
        #expect(audio.acceleratedMsPerSecond == 2)
        #expect(audio.avOffsetMs == 8)
        #expect(audio.outputLatencyMs == 18)
        #expect(audio.outputChannels == 6)
        #expect(audio.outputSampleRateHz == 48000)
        #expect(audio.outputRouteName == "HDMI")
    }

    @Test("Malformed RTC counters are bounded instead of trapping")
    func malformedCountersAreBounded() {
        var accumulator = XboxCloudRTCStatsAccumulator()
        accumulator.apply(video: XboxCloudRTCVideoSample(
            timestampUs: 1,
            bytesReceived: 0,
            packetsReceived: 0,
            framesDropped: 0,
            frameWidth: .nan,
            frameHeight: .infinity
        ))
        accumulator.apply(video: XboxCloudRTCVideoSample(
            timestampUs: 2,
            bytesReceived: .greatestFiniteMagnitude,
            packetsReceived: 1,
            framesDropped: .greatestFiniteMagnitude,
            frameWidth: .greatestFiniteMagnitude,
            frameHeight: -.infinity
        ))

        let stats = accumulator.snapshot.stream
        #expect(stats.resolutionWidth == Int.max)
        #expect(stats.resolutionHeight == 0)
        #expect(stats.bitrateKbps == Int.max)
        #expect(stats.framesDropped == Int.max)
    }
}
