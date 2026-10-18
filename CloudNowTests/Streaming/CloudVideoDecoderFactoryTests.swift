@testable import CloudNow
import Foundation
import LiveKitWebRTC
import Testing

@MainActor
struct CloudVideoDecoderFactoryTests {
    @Test("AV1 uses the native decoder only when hardware support is available", arguments: [false, true])
    func av1DecoderSelection(hardwareSupported: Bool) throws {
        let factory = CloudVideoDecoderFactory(supportsAV1HardwareDecode: hardwareSupported)
        let info = try #require(factory.supportedCodecs().first { $0.name.uppercased() == "AV1" })

        let decoder = try #require(factory.createDecoder(info))

        #expect((decoder is CloudVideoDecoderAV1) == hardwareSupported)
    }

    @Test("AV1 capability does not change the existing HEVC decoder or Main10 advertisement", arguments: [false, true])
    func preservesHEVC(hardwareSupported: Bool) throws {
        let factory = CloudVideoDecoderFactory(supportsAV1HardwareDecode: hardwareSupported)
        let main10 = try #require(factory.supportedCodecs().first {
            $0.name.uppercased() == "H265" && $0.parameters["profile-id"] == "2"
        })

        #expect(factory.createDecoder(main10) is CloudVideoDecoderH265)
    }

    @Test("Native AV1 requests a keyframe before receiving a sequence header")
    func requiresConfiguration() {
        let decoder = CloudVideoDecoderAV1()
        let frame = LKRTCEncodedImage()
        frame.buffer = Data([0x32, 0x01, 0x00])

        #expect(decoder.startDecode(withNumberOfCores: 1) == 0)
        #expect(decoder.decode(frame, missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0) == -1)
        #expect(decoder.release() == 0)
        #expect(decoder.release() == 0)
    }
}
