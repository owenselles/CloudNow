@testable import CloudNow
import Foundation
import Testing

@Suite("SDP munging")
@MainActor
struct SDPMungerTests {
    @Test(
        "Codec filtering retains the selected codec and its RTX payload",
        arguments: [
            (VideoCodec.h264, "m=video 9 UDP/TLS/RTP/SAVPF 96 97", ["a=rtpmap:96 H264", "a=fmtp:97 apt=96"]),
            (VideoCodec.av1, "m=video 9 UDP/TLS/RTP/SAVPF 102 103", ["a=rtpmap:102 AV1", "a=fmtp:103 apt=102"]),
        ]
    )
    func selectedCodecAndRTX(
        codec: VideoCodec,
        expectedMediaLine: String,
        retainedAttributes: [String]
    ) throws {
        let source = try TestFixture.string("mixed-codecs.sdp", subdirectory: "SDP")

        let result = SDPMunger.preferCodec(source, codec: codec)

        #expect(result.contains(expectedMediaLine))
        for attribute in retainedAttributes {
            #expect(result.contains(attribute), "Missing retained attribute: \(attribute)")
        }
        #expect(result.contains("a=x-video-attribute:preserve-me"))
        #expect(result.contains("a=x-microphone-attribute:preserve-me"))
    }

    @Test("Codec filtering removes unrelated payload attributes")
    func unrelatedPayloadAttributesAreRemoved() throws {
        let source = try TestFixture.string("mixed-codecs.sdp", subdirectory: "SDP")

        let result = SDPMunger.preferCodec(source, codec: .h264)

        for removedPayload in ["98", "99", "100", "101", "102", "103"] {
            #expect(!result.contains("a=rtpmap:\(removedPayload) "))
            #expect(!result.contains("a=fmtp:\(removedPayload) "))
        }
    }

    @Test("Unavailable codecs fall back to H.264 without damaging the offer", arguments: [VideoCodec.automatic, .h265])
    func unavailableCodecFallsBack(codec: VideoCodec) throws {
        let source = try TestFixture.string("h264-only.sdp", subdirectory: "SDP")

        let result = SDPMunger.preferCodec(source, codec: codec, preferTenBit: true)

        #expect(result == source)
    }

    @Test("Automatic and H.265 retain HEVC Main and Main10 ordering", arguments: [VideoCodec.automatic, .h265])
    func h265ProfileOrdering(codec: VideoCodec) throws {
        let source = try TestFixture.string("mixed-codecs.sdp", subdirectory: "SDP")

        let main = SDPMunger.preferCodec(source, codec: codec)
        let main10 = SDPMunger.preferCodec(source, codec: codec, preferTenBit: true)
        let mainLine = try videoMediaLine(in: main)
        let main10Line = try videoMediaLine(in: main10)

        #expect(payloadIndex("98", in: mainLine) < payloadIndex("100", in: mainLine))
        #expect(payloadIndex("100", in: main10Line) < payloadIndex("98", in: main10Line))
        #expect(main.contains("a=fmtp:99 apt=98"))
        #expect(main.contains("a=fmtp:101 apt=100"))
        #expect(!main.contains("a=rtpmap:102 AV1"))
    }

    @Test("H.265 tier and level rewrites are profile-aware")
    func h265SafetyRewrites() throws {
        let source = try TestFixture.string("mixed-codecs.sdp", subdirectory: "SDP")

        let tierSafe = SDPMunger.rewriteH265TierFlag(source)
        let levelSafe = SDPMunger.rewriteH265LevelId(tierSafe)

        #expect(!levelSafe.contains("tier-flag=1"))
        #expect(levelSafe.contains("a=fmtp:98 profile-id=1;tier-flag=0;level-id=183"))
        #expect(levelSafe.contains("a=fmtp:100 profile-id=2;tier-flag=0;level-id=153"))
        #expect(levelSafe.contains("a=fmtp:96 profile-level-id=640033"))
    }

    @Test("Codec filtering preserves LF and CRLF line endings")
    func lineEndingPreservation() throws {
        let lf = try TestFixture.string("mixed-codecs.sdp", subdirectory: "SDP")
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")

        let lfResult = SDPMunger.preferCodec(lf, codec: .h264)
        let crlfResult = SDPMunger.preferCodec(crlf, codec: .h264)

        #expect(lfResult.contains("\n"))
        #expect(!lfResult.contains("\r\n"))
        #expect(crlfResult.contains("\r\n"))
        #expect(!crlfResult.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test("Bandwidth and Opus stereo insertion are idempotent")
    func bandwidthInsertionIsIdempotent() throws {
        let source = try TestFixture.string("mixed-codecs.sdp", subdirectory: "SDP")

        let once = SDPMunger.injectBandwidth(source, videoKbps: 50000, audioKbps: 256)
        let twice = SDPMunger.injectBandwidth(once, videoKbps: 50000, audioKbps: 256)

        #expect(once == twice)
        #expect(occurrences(of: "b=AS:50000", in: twice) == 1)
        #expect(occurrences(of: "b=AS:256", in: twice) == 2)
        #expect(occurrences(of: "stereo=1", in: twice) == 2)
    }

    @Test("Existing bandwidth and stereo parameters are not duplicated")
    func existingParametersRemainUnique() {
        let source = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        b=AS:192
        a=rtpmap:111 opus/48000/2
        a=fmtp:111 minptime=10;stereo=1
        m=video 9 UDP/TLS/RTP/SAVPF 96
        b=AS:40000
        a=rtpmap:96 H264/90000
        """

        let result = SDPMunger.injectBandwidth(source, videoKbps: 50000, audioKbps: 256)

        #expect(occurrences(of: "b=AS:", in: result) == 2)
        #expect(occurrences(of: "stereo=1", in: result) == 1)
        #expect(result.contains("b=AS:192"))
        #expect(result.contains("b=AS:40000"))
    }

    @Test("RED is removed only from the first game-audio section")
    func redRemovalIsScopedToGameAudio() {
        let answer = """
        v=0
        a=group:BUNDLE game mic
        m=audio 9 UDP/TLS/RTP/SAVPF 111 63
        a=mid:game
        a=rtpmap:111 opus/48000/2
        a=rtpmap:63 red/48000/2
        a=fmtp:63 111/111
        m=audio 9 UDP/TLS/RTP/SAVPF 111 64
        a=mid:mic
        a=rtpmap:111 opus/48000/2
        a=rtpmap:64 red/48000/2
        a=fmtp:64 111/111
        """

        let result = SDPMunger.mungeAudioAnswer(answer, offer: answer)

        #expect(result.contains("m=audio 9 UDP/TLS/RTP/SAVPF 111\n"))
        #expect(!result.contains("a=rtpmap:63 "))
        #expect(result.contains("m=audio 9 UDP/TLS/RTP/SAVPF 111 64"))
        #expect(result.contains("a=rtpmap:64 red/48000/2"))
    }

    @Test("Surround reconstruction restores BUNDLE, multiopus, and bundle transport")
    func surroundReconstruction() throws {
        let offer = try TestFixture.string("surround-offer.sdp", subdirectory: "SDP")
        let answer = try TestFixture.string("rejected-surround-answer.sdp", subdirectory: "SDP")

        let result = SDPMunger.mungeAudioAnswer(answer, offer: offer)

        #expect(result.contains("a=group:BUNDLE game video mic"))
        #expect(result.contains("m=audio 9 UDP/TLS/RTP/SAVPF 112"))
        #expect(result.contains("a=mid:game"))
        #expect(result.contains("a=rtpmap:112 multiopus/48000/6"))
        #expect(result.contains("channel_mapping=0,4,1,2,3,5"))
        #expect(result.contains("a=ice-ufrag:test-ufrag"))
        #expect(result.contains("a=fingerprint:sha-256 00:11:22:33"))
        #expect(result.contains("a=mid:mic"))
        #expect(result.contains("a=sendrecv"))
    }

    @Test("Audio munging and codec filtering are repeatable")
    func repeatedCallsAreIdempotent() throws {
        let offer = try TestFixture.string("surround-offer.sdp", subdirectory: "SDP")
        let answer = try TestFixture.string("rejected-surround-answer.sdp", subdirectory: "SDP")
        let source = try TestFixture.string("mixed-codecs.sdp", subdirectory: "SDP")

        let audioOnce = SDPMunger.mungeAudioAnswer(answer, offer: offer)
        let audioTwice = SDPMunger.mungeAudioAnswer(audioOnce, offer: offer)
        let videoOnce = SDPMunger.preferCodec(source, codec: .h264)
        let videoTwice = SDPMunger.preferCodec(videoOnce, codec: .h264)

        #expect(audioOnce == audioTwice)
        #expect(videoOnce == videoTwice)
    }

    @Test("7.1 preserves the server's channel mapping and microphone section", arguments: ["\n", "\r\n"])
    func surround71Reconstruction(separator: String) throws {
        let offer = try TestFixture.string("surround-offer.sdp", subdirectory: "SDP")
            .replacingOccurrences(of: "multiopus/48000/6", with: "multiopus/48000/8")
            .replacingOccurrences(
                of: "channel_mapping=0,4,1,2,3,5;num_streams=4;coupled_streams=2",
                with: "channel_mapping=0,6,1,2,3,4,5,7;num_streams=5;coupled_streams=3"
            )
            .replacingOccurrences(of: "\n", with: separator)
        let answer = try TestFixture.string("rejected-surround-answer.sdp", subdirectory: "SDP")
            .replacingOccurrences(of: "\n", with: separator)
        let result = SDPMunger.mungeAudioAnswer(answer, offer: offer)

        #expect(SDPMunger.audioChannelCount(in: offer) == 8)
        #expect(result.contains("a=group:BUNDLE game video mic"))
        #expect(result.contains("a=rtpmap:112 multiopus/48000/8"))
        #expect(result.contains("channel_mapping=0,6,1,2,3,4,5,7;num_streams=5;coupled_streams=3"))
        #expect(result.contains("a=mid:mic\(separator)a=sendrecv\(separator)a=rtpmap:111 opus/48000/2"))
        #expect(result == SDPMunger.mungeAudioAnswer(result, offer: offer))
    }

    @Test(
        "Playout follows the offered format, including stereo and 5.1 fallbacks",
        arguments: [("opus/48000/2", 2), ("multiopus/48000/6", 6), ("multiopus/48000/8", 8)]
    )
    func offeredAudioChannels(codec: String, expected: Int) {
        let offer = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 112
        a=rtpmap:112 \(codec)
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=rtpmap:96 H264/90000
        m=audio 9 UDP/TLS/RTP/SAVPF 113
        a=rtpmap:113 multiopus/48000/8
        """
        #expect(SDPMunger.audioChannelCount(in: offer) == expected)
    }

    @Test(
        "Unadvertised and unsupported surround payloads do not select an invalid output layout",
        arguments: ["multiopus/48000/3", "multiopus/48000/32", "multiopus/48000/invalid", "multiopus/16000/8"]
    )
    func invalidSurroundChannels(codec: String) {
        let offer = """
        m=audio 9 UDP/TLS/RTP/SAVPF 112
        a=rtpmap:112 \(codec)
        a=rtpmap:113 multiopus/48000/8
        """
        #expect(SDPMunger.audioChannelCount(in: offer) == 2)
        #expect(SDPMunger.audioChannelCount(in: "m=audio 0 UDP/TLS/RTP/SAVPF 112\na=rtpmap:112 multiopus/48000/8") == 2)
        #expect(SDPMunger.audioChannelCount(in: "v=0") == 2)
    }

    @Test("Missing or malformed sections fail conservatively")
    func malformedInputRemainsUncorrupted() throws {
        let malformed = try TestFixture.string("malformed.sdp", subdirectory: "SDP")
        let surroundOffer = try TestFixture.string("surround-offer.sdp", subdirectory: "SDP")

        #expect(SDPMunger.preferCodec(malformed, codec: .h265) == malformed)
        #expect(SDPMunger.mungeAudioAnswer(malformed, offer: surroundOffer) == malformed)
        #expect(SDPMunger.rewriteH265TierFlag(malformed) == malformed)
        #expect(SDPMunger.rewriteH265LevelId(malformed) == malformed)
    }

    private func videoMediaLine(in sdp: String) throws -> String {
        try #require(sdp.split(whereSeparator: \.isNewline).first { $0.hasPrefix("m=video") }.map(String.init))
    }

    private func payloadIndex(_ payload: String, in mediaLine: String) -> Int {
        mediaLine.components(separatedBy: " ").firstIndex(of: payload) ?? .max
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
