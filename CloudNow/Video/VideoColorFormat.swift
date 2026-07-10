import AVFoundation
import CoreMedia
import CoreVideo
import UIKit
import VideoToolbox

struct LocalVideoCapabilities: Equatable {
    let supportsHardware10BitDecode: Bool
    let supportsHDRRendering: Bool
    let supportsExtendedDynamicRange: Bool
    let displaySupportsHDR: Bool
    let supportedPixelFormats: Set<OSType>
    let supportedCodecs: Set<VideoCodec>

    static func detect(codec: VideoCodec?) -> LocalVideoCapabilities {
        let hevcHardwareDecode = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let displayEDRHeadroom: CGFloat = if #available(tvOS 16.0, *) {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen }
                .first?
                .potentialEDRHeadroom ?? 1
        } else {
            1
        }
        // tvOS switches the whole display into HDR for HDR content rather than compositing
        // EDR, so potentialEDRHeadroom reports 1.0 even on a 4K-HDR display. AVPlayer's
        // availableHDRModes reflects the connected display's actual HDR capability
        // (empty == SDR-only), which is the correct signal on tvOS.
        let displaySupportsHDR = !AVPlayer.availableHDRModes.isEmpty || displayEDRHeadroom > 1.0
        var codecs: Set<VideoCodec> = [.h264]
        if hevcHardwareDecode {
            codecs.insert(.h265)
        }

        return LocalVideoCapabilities(
            supportsHardware10BitDecode: hevcHardwareDecode && codec != .av1,
            supportsHDRRendering: displaySupportsHDR,
            supportsExtendedDynamicRange: displayEDRHeadroom > 1.0,
            displaySupportsHDR: displaySupportsHDR,
            supportedPixelFormats: [
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            ],
            supportedCodecs: codecs
        )
    }
}

enum VideoDecoderPath: String, Codable, Equatable {
    case hardware
    case softwareI420
    case unknown
}

struct DecodedVideoFormat: Codable, Equatable {
    let mode: DetectedColorMode
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let pixelFormatName: String
    let bitDepth: Int?
    let transferFunction: String?
    let colorPrimaries: String?
    let yCbCrMatrix: String?
    let colorRange: String?
    let hasDisplayColorVolumeMetadata: Bool
    let hasContentLightLevelMetadata: Bool
    let decoderPath: VideoDecoderPath

    var metadataDiagnosticSummary: String {
        L10n.metadataDiagnosticSummary(
            transferFunction: transferFunction,
            colorPrimaries: colorPrimaries,
            yCbCrMatrix: yCbCrMatrix,
            hasDisplayColorVolumeMetadata: hasDisplayColorVolumeMetadata,
            hasContentLightLevelMetadata: hasContentLightLevelMetadata
        )
    }
}

struct VideoFormatSignature: Hashable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let bitDepth: Int?
    let transferFunction: String?
    let colorPrimaries: String?
    let yCbCrMatrix: String?
    let colorRange: String?
}

enum DecodedVideoFormatInspector {
    static func inspect(pixelBuffer: CVPixelBuffer, decoderPath: VideoDecoderPath) -> DecodedVideoFormat {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let bitDepth = bitDepth(for: pixelFormat)
        let transferFunction = propagatedAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey)
        let colorPrimaries = propagatedAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey)
        let yCbCrMatrix = propagatedAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey)
        let colorRange = colorRange(for: pixelFormat)
        let mode = classify(
            bitDepth: bitDepth,
            transferFunction: transferFunction,
            colorPrimaries: colorPrimaries
        )

        return DecodedVideoFormat(
            mode: decoderPath == .softwareI420 ? .sdr8 : mode,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: pixelFormat,
            pixelFormatName: fourCC(pixelFormat),
            bitDepth: bitDepth,
            transferFunction: transferFunction,
            colorPrimaries: colorPrimaries,
            yCbCrMatrix: yCbCrMatrix,
            colorRange: colorRange,
            hasDisplayColorVolumeMetadata: attachmentExists(pixelBuffer, kCVImageBufferMasteringDisplayColorVolumeKey),
            hasContentLightLevelMetadata: attachmentExists(pixelBuffer, kCVImageBufferContentLightLevelInfoKey),
            decoderPath: decoderPath
        )
    }

    static func signature(for format: DecodedVideoFormat) -> VideoFormatSignature {
        VideoFormatSignature(
            width: format.width,
            height: format.height,
            pixelFormat: format.pixelFormat,
            bitDepth: format.bitDepth,
            transferFunction: format.transferFunction,
            colorPrimaries: format.colorPrimaries,
            yCbCrMatrix: format.yCbCrMatrix,
            colorRange: format.colorRange
        )
    }

    private static func classify(
        bitDepth: Int?,
        transferFunction: String?,
        colorPrimaries: String?
    ) -> DetectedColorMode {
        let isTenBit = (bitDepth ?? 0) >= 10
        let isPQ = transferFunction == string(kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        let isBT2020 = colorPrimaries == string(kCVImageBufferColorPrimaries_ITU_R_2020)
        let isKnownSDRTransfer = isSDRTransferFunction(transferFunction)

        if isTenBit, isPQ, isBT2020 {
            return .hdr10
        }
        if isTenBit {
            return isKnownSDRTransfer ? .sdr10 : .unknown10Bit
        }
        if bitDepth == 8 {
            return isKnownSDRTransfer ? .sdr8 : .unknown8Bit
        }
        return .unknown8Bit
    }

    private static func isSDRTransferFunction(_ transferFunction: String?) -> Bool {
        guard let transferFunction else { return false }
        let knownValues = [
            string(kCVImageBufferTransferFunction_ITU_R_709_2),
            string(kCVImageBufferTransferFunction_SMPTE_240M_1995),
            string(kCVImageBufferTransferFunction_sRGB),
            "IEC_sRGB", // Observed from VideoToolbox on tvOS simulator for 8-bit BT.709 frames.
        ]
        return knownValues.contains(transferFunction)
    }

    private static func propagatedAttachment(_ pixelBuffer: CVPixelBuffer, _ key: CFString) -> String? {
        var mode: CVAttachmentMode = .shouldNotPropagate
        guard let value = CVBufferCopyAttachment(pixelBuffer, key, &mode),
              mode == .shouldPropagate
        else {
            return nil
        }
        return string(value)
    }

    private static func attachmentExists(_ pixelBuffer: CVPixelBuffer, _ key: CFString) -> Bool {
        CVBufferCopyAttachment(pixelBuffer, key, nil) != nil
    }

    /// 'p420' — kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange. Not exposed in the
    /// tvOS SDK, but VideoToolbox emits it as the native 10-bit HEVC output format.
    private static let packed10BitBiPlanarVideoRange: OSType = 0x7034_3230

    private static func colorRange(for pixelFormat: OSType) -> String? {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             packed10BitBiPlanarVideoRange:
            "Video"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            "Full"
        default:
            nil
        }
    }

    private static func bitDepth(for pixelFormat: OSType) -> Int? {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return 8
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             packed10BitBiPlanarVideoRange:
            return 10
        default:
            let name = fourCC(pixelFormat).lowercased()
            // 'x420'-style 10-bit biplanar and 'p420'-style packed 10-bit families.
            if name.hasPrefix("x") || name.hasPrefix("p4") || name.contains("10") {
                return 10
            }
            if name.contains("420") || name.contains("422") || name.contains("444") {
                return 8
            }
            return nil
        }
    }

    private static func fourCC(_ value: OSType) -> String {
        let scalars = [
            UnicodeScalar((value >> 24) & 0xFF),
            UnicodeScalar((value >> 16) & 0xFF),
            UnicodeScalar((value >> 8) & 0xFF),
            UnicodeScalar(value & 0xFF),
        ]
        let text = scalars.compactMap { $0 }.map(Character.init)
        return text.count == 4 ? String(text) : "\(value)"
    }

    private static func string(_ value: CFTypeRef) -> String {
        String(describing: value)
    }
}
