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
                decoderPath: .hardware
            )
        )
        let changedDecoderPath = DecodedVideoFormatInspector.signature(
            for: DecodedVideoFormatInspector.inspect(
                pixelBuffer: baseBuffer,
                decoderPath: .softwareI420
            )
        )
        let changedTransfer = DecodedVideoFormatInspector.signature(
            for: inspect(changedTransferBuffer)
        )

        #expect(base == metadataOnly)
        #expect(base != changedTransfer)
        #expect(base != changedDecoderPath)
    }

    @Test("Inspection cache reuses unchanged format metadata and invalidates relevant changes")
    func inspectionCacheInvalidation() throws {
        var cache = DecodedVideoFormatInspectionCache()
        let firstBuffer = try colorBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2
        )
        let equivalentBuffer = try colorBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2
        )
        let changedTransferBuffer = try colorBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2
        )
        let changedPixelFormatBuffer = try colorBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2
        )
        let changedResolutionBuffer = try colorBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            width: 16,
            height: 16
        )
        let changedHDRMetadataBuffer = try colorBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            width: 16,
            height: 16
        )
        setAttachment(
            kCVImageBufferContentLightLevelInfoKey,
            value: Data([1]) as CFData,
            on: changedHDRMetadataBuffer
        )

        let initialResolution = cache.resolve(pixelBuffer: firstBuffer, decoderPath: .hardware)
        let initial = try #require(initialResolution)
        let unchangedResolution = cache.resolve(
            pixelBuffer: equivalentBuffer,
            decoderPath: .hardware
        )
        let unchanged = try #require(unchangedResolution)
        let changedResolution = cache.resolve(
            pixelBuffer: changedTransferBuffer,
            decoderPath: .hardware
        )
        let changed = try #require(changedResolution)
        let changedDecoderPathResolution = cache.resolve(
            pixelBuffer: changedTransferBuffer,
            decoderPath: .softwareI420
        )
        let changedDecoderPath = try #require(changedDecoderPathResolution)
        let changedPixelFormatResolution = cache.resolve(
            pixelBuffer: changedPixelFormatBuffer,
            decoderPath: .softwareI420
        )
        let changedPixelFormat = try #require(changedPixelFormatResolution)
        let changedDimensionsResolution = cache.resolve(
            pixelBuffer: changedResolutionBuffer,
            decoderPath: .softwareI420
        )
        let changedDimensions = try #require(changedDimensionsResolution)
        let changedHDRMetadataResolution = cache.resolve(
            pixelBuffer: changedHDRMetadataBuffer,
            decoderPath: .softwareI420
        )
        let changedHDRMetadata = try #require(changedHDRMetadataResolution)

        #expect(initial.didInspect)
        #expect(!unchanged.didInspect)
        #expect(unchanged.format == initial.format)
        #expect(changed.didInspect)
        #expect(changed.format.transferFunction != initial.format.transferFunction)
        #expect(changedDecoderPath.didInspect)
        #expect(changedDecoderPath.format.decoderPath == .softwareI420)
        #expect(changedPixelFormat.didInspect)
        #expect(changedPixelFormat.format.pixelFormat != initial.format.pixelFormat)
        #expect(changedDimensions.didInspect)
        #expect(changedDimensions.format.width == 16)
        #expect(changedDimensions.format.height == 16)
        #expect(changedHDRMetadata.didInspect)
        #expect(changedHDRMetadata.format.hasContentLightLevelMetadata)
    }

    @Test("Inspection cache reset forces the next frame to be inspected")
    func inspectionCacheReset() throws {
        var cache = DecodedVideoFormatInspectionCache()
        let buffer = try colorBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2
        )

        let initialResolution = cache.resolve(pixelBuffer: buffer, decoderPath: .hardware)
        let initial = try #require(initialResolution)
        let cachedResolution = cache.resolve(pixelBuffer: buffer, decoderPath: .hardware)
        let cached = try #require(cachedResolution)
        #expect(initial.didInspect)
        #expect(!cached.didInspect)

        cache.reset()

        let resetResolution = cache.resolve(pixelBuffer: buffer, decoderPath: .hardware)
        let afterReset = try #require(resetResolution)
        #expect(afterReset.didInspect)
    }

    private func inspect(_ buffer: CVPixelBuffer) -> DecodedVideoFormat {
        DecodedVideoFormatInspector.inspect(pixelBuffer: buffer, decoderPath: .hardware)
    }

    private func colorBuffer(
        pixelFormat: OSType,
        transfer: CFTypeRef,
        primaries: CFTypeRef,
        width: Int = 8,
        height: Int = 8
    ) throws -> CVPixelBuffer {
        let buffer = try makeBuffer(
            pixelFormat: pixelFormat,
            width: width,
            height: height
        )
        setAttachment(kCVImageBufferTransferFunctionKey, value: transfer, on: buffer)
        setAttachment(kCVImageBufferColorPrimariesKey, value: primaries, on: buffer)
        return buffer
    }

    private func makeBuffer(
        pixelFormat: OSType,
        width: Int = 8,
        height: Int = 8
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
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
