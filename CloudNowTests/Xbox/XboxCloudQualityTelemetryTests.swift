@testable import CloudNow
import Testing

@Suite("Xbox Cloud quality telemetry")
struct XboxCloudQualityTelemetryTests {
    @Test("Profile identifiers are restricted to the telemetry allowlist")
    func profileAllowlist() {
        #expect(
            XboxCloudQualityTelemetryProfile(
                identifier: "xbox-native-tvos-control-v1"
            ) == .nativeTV
        )
        #expect(
            XboxCloudQualityTelemetryProfile(
                identifier: "xbox-web-www-29.19.17-sdk-10.6.57"
            ) == .microsoftWeb
        )
        #expect(
            XboxCloudQualityTelemetryProfile(
                identifier: "private-session-value"
            ) == .unknown
        )
    }

    @Test("SDP summary retains only allowlisted codec and limit facts")
    func sanitizedSDPSummary() {
        let summary = XboxCloudQualitySDPSummary(sdp: """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 96 97 98
        a=rtpmap:96 H264/90000
        a=rtpmap:97 rtx/90000
        a=rtpmap:98 credential-secret/90000
        a=fmtp:96 profile-level-id=42e01f;max-fs=8160
        a=imageattr:96 recv [x=[0:1920],y=[0:1080]]
        m=audio 9 UDP/TLS/RTP/SAVPF 111 112
        a=rtpmap:111 opus/48000/2
        a=rtpmap:112 multiopus/48000/6
        """)

        #expect(summary.videoCodecs == [.h264, .unknown])
        #expect(summary.audioCodecs == [.opus, .multiopus])
        #expect(summary.firstVideoCodec == .h264)
        #expect(summary.firstAudioCodec == .opus)
        #expect(summary.firstAudioChannels == 2)
        #expect(summary.hasImageAttribute)
        #expect(summary.hasMaximumFrameSize)
    }

    @Test("SDP summary fails closed for missing and incomplete media lines")
    func malformedSDPSummary() {
        let summary = XboxCloudQualitySDPSummary(sdp: """
        v=0
        m=video 9 UDP/TLS
        a=rtpmap:malformed
        """)

        #expect(summary.videoCodecs.isEmpty)
        #expect(summary.audioCodecs.isEmpty)
        #expect(summary.firstVideoCodec == nil)
        #expect(summary.firstAudioCodec == nil)
        #expect(summary.firstAudioChannels == nil)
        #expect(!summary.hasImageAttribute)
        #expect(!summary.hasMaximumFrameSize)
    }

    @Test("Recorder is disabled by policy and retains a bounded tail")
    func boundedRecorder() {
        let disabled = XboxCloudQualityTelemetry(
            isEnabled: false,
            maximumRecordCount: 2
        )
        disabled.record(.compatibilityProfile(.nativeTV))
        #expect(disabled.snapshot().isEmpty)

        let enabled = XboxCloudQualityTelemetry(
            isEnabled: true,
            maximumRecordCount: 2
        )
        enabled.record(.compatibilityProfile(.nativeTV))
        enabled.record(
            .qualityRequest(resolution: .qhd, maximumBitrateKbps: nil)
        )
        enabled.record(.compatibilityProfile(.microsoftWeb))

        #expect(enabled.snapshot() == [
            .qualityRequest(resolution: .qhd, maximumBitrateKbps: nil),
            .compatibilityProfile(.microsoftWeb),
        ])
        enabled.reset()
        #expect(enabled.snapshot().isEmpty)
    }
}
