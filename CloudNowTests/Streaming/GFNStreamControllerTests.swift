@testable import CloudNow
import Foundation
import Testing

@Suite("GFN stream configuration")
@MainActor
struct GFNStreamControllerTests {
    @Test(
        "NVST video configuration sends selected chroma and respects codec fallback",
        arguments: [
            (VideoCodec.automatic, ChromaFormat.yuv420, 0),
            (.automatic, .yuv444, 1),
            (.h265, .yuv420, 0),
            (.h265, .yuv444, 1),
            (.h264, .yuv444, 0),
            (.av1, .yuv444, 0),
        ]
    )
    func nvstChromaRequest(codec: VideoCodec, chroma: ChromaFormat, expected: Int) throws {
        var settings = StreamSettings()
        settings.codec = codec
        settings.chromaFormat = chroma
        settings.colorPreference = .forceSDR8
        let controller = GFNStreamController()

        let sdp = controller.buildNvstSdp(
            settings: settings,
            iceUfrag: "fixture-user",
            icePwd: "fixture-password",
            dtlsFingerprint: "fixture-fingerprint",
            microphoneEnabled: false
        )
        let video = try #require(sdp.components(separatedBy: "m=video 0 RTP/AVP\r\n").last)
            .components(separatedBy: "m=audio 0 RTP/AVP")[0]
        let chromaAttributes = video.components(separatedBy: "\r\n")
            .filter { $0.hasPrefix("a=video.chromaFormat:") }

        #expect(chromaAttributes == ["a=video.chromaFormat:\(expected)"])
        #expect(video.contains("a=video.bitDepth:8\r\n"))
        #expect(sdp.contains("a=general.iceUserNameFragment:fixture-user\r\n"))
        #expect(sdp.contains("a=general.icePassword:fixture-password\r\n"))
    }
}
