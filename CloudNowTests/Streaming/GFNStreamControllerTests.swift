@testable import CloudNow
import Foundation
import Testing

@Suite("GFN stream configuration")
@MainActor
struct GFNStreamControllerTests {
    private let hdrCapabilities = LocalVideoCapabilities(
        supportsHardware10BitDecode: true,
        supportsHDRRendering: true,
        supportsExtendedDynamicRange: true,
        displaySupportsHDR: true,
        supportedPixelFormats: [],
        supportedCodecs: [.h264, .h265]
    )

    @Test(
        "NVST retains 4K stream settings and selected chroma with codec fallback",
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
        settings.resolution = "3840x2160"
        settings.fps = 120
        settings.maxBitrateKbps = 100_000
        settings.codec = codec
        settings.chromaFormat = chroma
        settings.colorPreference = .forceSDR8
        let controller = GFNStreamController()

        let sdp = controller.buildNvstSdp(
            settings: settings,
            requestedColorMode: settings.colorRequest(localCapabilities: hdrCapabilities).mode,
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
        #expect(video.contains("a=video.clientViewportWd:3840\r\n"))
        #expect(video.contains("a=video.clientViewportHt:2160\r\n"))
        #expect(video.contains("a=video.maxFPS:120\r\n"))
        #expect(video.contains("a=vqos.bw.maximumBitrateKbps:100000\r\n"))
        #expect(video.contains("a=video.bitDepth:8\r\n"))
        #expect(sdp.contains("a=general.iceUserNameFragment:fixture-user\r\n"))
        #expect(sdp.contains("a=general.icePassword:fixture-password\r\n"))
        #expect(sdp.contains("a=general.dtlsFingerprint:fixture-fingerprint\r\n"))
    }

    @Test("Only explicit server reports establish negotiated range, independently of decoded output")
    func reportedAndDecodedColor() {
        var settings = StreamSettings()
        settings.colorPreference = .preferHDR
        let request = settings.colorRequest(localCapabilities: hdrCapabilities)
        var state = StreamColorState(
            preference: settings.colorPreference,
            requestedMode: request.mode,
            gfn: GFNColorNegotiation(sessionRequest: .allocation(request), serverDynamicRange: GFNSessionDynamicRange(rawValue: 99))
        )
        #expect(state.gfn?.sessionRequest?.dynamicRange == .hdr)
        #expect(state.gfn?.serverDynamicRange == nil)
        state.detectedMode = .unknown8Bit
        #expect(state.gfnFallbackReason == .decoderReturned8Bit)
        state.gfn?.serverDynamicRange = GFNSessionDynamicRange(rawValue: 0)
        #expect(state.gfn?.serverDynamicRange == .sdr)
        #expect(state.gfnFallbackReason == .serverReturnedSDR)
        state.gfn?.serverDynamicRange = GFNSessionDynamicRange(rawValue: 1)
        state.detectedMode = .sdr10
        #expect(state.gfnFallbackReason == .decodedSDR)
        state.detectedMode = .hdr10
        #expect(state.gfnFallbackReason == nil)
    }

    @Test("Automatic distinguishes unconfirmed entitlement from a known restriction")
    func entitlementFallback() {
        let settings = StreamSettings()
        let unknown = settings.colorRequest(localCapabilities: hdrCapabilities)
        #expect(unknown.mode == .sdr10)
        #expect(unknown.fallbackReason == .accountHDRUnknown)
        let restricted = settings.colorRequest(localCapabilities: hdrCapabilities, accountAllowsHDR: false)
        let state = StreamColorState(
            preference: settings.colorPreference,
            requestedMode: restricted.mode,
            detectedMode: .sdr10,
            gfn: GFNColorNegotiation(sessionRequest: .allocation(restricted), serverDynamicRange: .sdr)
        )
        #expect(state.gfnFallbackReason == .accountHDRUnavailable)
    }

    @Test("Non-HEVC codecs explain the 8-bit request before any frame arrives", arguments: [VideoCodec.h264, .av1])
    func codecFallback(codec: VideoCodec) {
        var settings = StreamSettings()
        settings.codec = codec
        settings.colorPreference = .preferSDR10
        let request = settings.colorRequest(localCapabilities: hdrCapabilities)
        #expect(request.mode == .sdr8)
        #expect(request.fallbackReason == .codec10BitUnavailable)
    }
}
