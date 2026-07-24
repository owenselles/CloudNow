@testable import CloudNow
import CoreVideo
import Foundation
import Testing

@Suite("Decoded video color-format inspection")
struct VideoColorFormatTests {
    struct PixelFormatCase: Sendable {
        let pixelFormat: OSType
        let bitDepth: Int
        let range: String
        let expectedMode: DetectedColorMode
    }

    @Test(
        "Bi-planar video and full-range formats report their bit depth and range",
        arguments: [
            PixelFormatCase(
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                bitDepth: 8,
                range: "Video",
                expectedMode: .sdr8
            ),
            PixelFormatCase(
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                bitDepth: 8,
                range: "Full",
                expectedMode: .sdr8
            ),
            PixelFormatCase(
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                bitDepth: 10,
                range: "Video",
                expectedMode: .sdr10
            ),
            PixelFormatCase(
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                bitDepth: 10,
                range: "Full",
                expectedMode: .sdr10
            ),
        ]
    )
    func knownPixelFormats(testCase: PixelFormatCase) throws {
        let buffer = try makeBuffer(pixelFormat: testCase.pixelFormat)
        setAttachment(
            kCVImageBufferTransferFunctionKey,
            value: kCVImageBufferTransferFunction_ITU_R_709_2,
            on: buffer
        )

        let format = DecodedVideoFormatInspector.inspect(
            pixelBuffer: buffer,
            decoderPath: .hardware
        )

        #expect(format.bitDepth == testCase.bitDepth)
        #expect(format.colorRange == testCase.range)
        #expect(format.mode == testCase.expectedMode)
        #expect(format.width == 8)
        #expect(format.height == 8)
    }

    @Test("Packed p420 is recognized as ten-bit video range")
    func packedTenBitFourCC() {
        let packedP420: OSType = 0x7034_3230
        let description = DecodedVideoFormatInspector.describe(
            pixelFormat: packedP420,
            transferFunction: String(describing: kCVImageBufferTransferFunction_ITU_R_709_2),
            colorPrimaries: nil
        )

        #expect(description.pixelFormatName == "p420")
        #expect(description.bitDepth == 10)
        #expect(description.colorRange == "Video")
        #expect(description.mode == .sdr10)
    }

    @Test("All known SDR transfer functions classify by bit depth")
    func knownSDRTransfers() throws {
        let transfers: [CFTypeRef] = [
            kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferTransferFunction_SMPTE_240M_1995,
            kCVImageBufferTransferFunction_sRGB,
            "IEC_sRGB" as CFString,
        ]

        for transfer in transfers {
            let eightBit = try makeBuffer(
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            let tenBit = try makeBuffer(
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            )
            setAttachment(kCVImageBufferTransferFunctionKey, value: transfer, on: eightBit)
            setAttachment(kCVImageBufferTransferFunctionKey, value: transfer, on: tenBit)

            #expect(
                DecodedVideoFormatInspector.inspect(
                    pixelBuffer: eightBit,
                    decoderPath: .hardware
                ).mode == .sdr8,
                "Eight-bit transfer \(transfer)"
            )
            #expect(
                DecodedVideoFormatInspector.inspect(
                    pixelBuffer: tenBit,
                    decoderPath: .hardware
                ).mode == .sdr10,
                "Ten-bit transfer \(transfer)"
            )
        }
    }

    @Test("HDR10 requires ten-bit data with both PQ and BT.2020 metadata")
    func hdrRequirements() throws {
        let hdr = try colorBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020
        )
        let wrongPrimaries = try colorBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2
        )
        let eightBitPQ = try colorBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020
        )

        #expect(inspect(hdr).mode == .hdr10)
        #expect(inspect(wrongPrimaries).mode == .unknown10Bit)
        #expect(inspect(eightBitPQ).mode == .unknown8Bit)
    }

    @Test("Missing or unknown metadata remains explicitly unknown")
    func unknownMetadata() throws {
        let eightBit = try makeBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let tenBit = try makeBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        let unknownTransfer = "Fixture_Unknown_Transfer" as CFString
        setAttachment(kCVImageBufferTransferFunctionKey, value: unknownTransfer, on: eightBit)
        setAttachment(kCVImageBufferTransferFunctionKey, value: unknownTransfer, on: tenBit)

        #expect(inspect(eightBit).mode == .unknown8Bit)
        #expect(inspect(tenBit).mode == .unknown10Bit)
        #expect(inspect(eightBit).colorPrimaries == nil)
        #expect(inspect(eightBit).yCbCrMatrix == nil)
    }

    @Test("Only propagated color attachments participate in classification")
    func attachmentPropagation() throws {
        let buffer = try makeBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        setAttachment(
            kCVImageBufferTransferFunctionKey,
            value: kCVImageBufferTransferFunction_ITU_R_709_2,
            mode: .shouldNotPropagate,
            on: buffer
        )

        let format = inspect(buffer)

        #expect(format.transferFunction == nil)
        #expect(format.mode == .unknown8Bit)
    }

    @Test("Mastering-display and content-light attachments are reported")
    func hdrMetadataFlags() throws {
        let buffer = try makeBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        setAttachment(
            kCVImageBufferMasteringDisplayColorVolumeKey,
            value: Data([1, 2, 3]) as CFData,
            mode: .shouldNotPropagate,
            on: buffer
        )
        setAttachment(
            kCVImageBufferContentLightLevelInfoKey,
            value: Data([4, 5]) as CFData,
            on: buffer
        )

        let format = inspect(buffer)

        #expect(format.hasDisplayColorVolumeMetadata)
        #expect(format.hasContentLightLevelMetadata)
    }

    @Test("The software I420 path is conservatively reported as SDR8")
    func softwarePathForcesSDR8() throws {
        let buffer = try colorBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020
        )

        let format = DecodedVideoFormatInspector.inspect(
            pixelBuffer: buffer,
            decoderPath: .softwareI420
        )

        #expect(format.mode == .sdr8)
        #expect(format.bitDepth == 10)
        #expect(format.transferFunction != nil)
    }

    @Test("Format signatures track relevant color metadata but ignore diagnostic-only values")
    func formatSignatures() throws {
        let baseBuffer = try colorBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2
        )
        let metadataBuffer = try colorBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2
        )
        setAttachment(
            kCVImageBufferContentLightLevelInfoKey,
            value: Data([9]) as CFData,
            on: metadataBuffer
        )
        let changedTransferBuffer = try colorBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2
        )

        let base = DecodedVideoFormatInspector.signature(for: inspect(baseBuffer))
        let metadataOnly = DecodedVideoFormatInspector.signature(
            for: DecodedVideoFormatInspector.inspect(
                pixelBuffer: metadataBuffer,
                decoderPath: .unknown
            )
        )
        let changedTransfer = DecodedVideoFormatInspector.signature(
            for: inspect(changedTransferBuffer)
        )

        #expect(base == metadataOnly)
        #expect(base != changedTransfer)
    }

    private func inspect(_ buffer: CVPixelBuffer) -> DecodedVideoFormat {
        DecodedVideoFormatInspector.inspect(pixelBuffer: buffer, decoderPath: .hardware)
    }

    private func colorBuffer(
        pixelFormat: OSType,
        transfer: CFTypeRef,
        primaries: CFTypeRef
    ) throws -> CVPixelBuffer {
        let buffer = try makeBuffer(pixelFormat: pixelFormat)
        setAttachment(kCVImageBufferTransferFunctionKey, value: transfer, on: buffer)
        setAttachment(kCVImageBufferColorPrimariesKey, value: primaries, on: buffer)
        return buffer
    }

    private func makeBuffer(pixelFormat: OSType) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            8,
            8,
            pixelFormat,
            nil,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess, "CVPixelBufferCreate returned \(status)")
        return try #require(pixelBuffer)
    }

    private func setAttachment(
        _ key: CFString,
        value: CFTypeRef,
        mode: CVAttachmentMode = .shouldPropagate,
        on buffer: CVPixelBuffer
    ) {
        CVBufferSetAttachment(buffer, key, value, mode)
    }
}
