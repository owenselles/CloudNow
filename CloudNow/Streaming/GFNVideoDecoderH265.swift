import CoreMedia
import Foundation
@preconcurrency import LiveKitWebRTC
import os.log
import Synchronization
import VideoToolbox

private nonisolated let h265Log = Logger(subsystem: "com.owenselles.CloudNow2", category: "H265Decoder")

/// Zero-copy view of an Annex-B access unit plus the one-copy AVCC conversion used by VideoToolbox.
nonisolated enum H265AnnexBConverter {
    struct NALUnit: Equatable, Sendable {
        /// Payload range in the access unit, excluding the start code.
        let range: Range<Int>
        /// H.265 nal_unit_type: (first payload byte >> 1) & 0x3F.
        let type: UInt8
    }

    struct ParameterSets: Equatable, Sendable {
        let units: [NALUnit]
        /// Small owned snapshot used to detect actual VPS/SPS/PPS changes between keyframes.
        let signature: [Data]
    }

    private static let vpsType: UInt8 = 32
    private static let spsType: UInt8 = 33
    private static let ppsType: UInt8 = 34

    static func nalUnits(in data: Data) -> [NALUnit] {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return [] }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            var units: [NALUnit] = []
            var payloadStart: Int?
            var index = 0

            while index + 2 < rawBuffer.count {
                let startCodeLength: Int? = if index + 3 < rawBuffer.count,
                                               bytes[index] == 0,
                                               bytes[index + 1] == 0,
                                               bytes[index + 2] == 0,
                                               bytes[index + 3] == 1
                {
                    4
                } else if bytes[index] == 0,
                          bytes[index + 1] == 0,
                          bytes[index + 2] == 1
                {
                    3
                } else {
                    nil
                }

                guard let startCodeLength else {
                    index += 1
                    continue
                }
                if let payloadStart, index > payloadStart {
                    units.append(
                        NALUnit(
                            range: payloadStart ..< index,
                            type: (bytes[payloadStart] >> 1) & 0x3F
                        )
                    )
                }
                payloadStart = index + startCodeLength
                index += startCodeLength
            }

            if let payloadStart, payloadStart < rawBuffer.count {
                units.append(
                    NALUnit(
                        range: payloadStart ..< rawBuffer.count,
                        type: (bytes[payloadStart] >> 1) & 0x3F
                    )
                )
            }
            return units
        }
    }

    static func parameterSets(in data: Data, nalus: [NALUnit]) -> ParameterSets? {
        let vps = nalus.filter { $0.type == vpsType }
        let sps = nalus.filter { $0.type == spsType }
        let pps = nalus.filter { $0.type == ppsType }
        let units = vps + sps + pps
        guard !vps.isEmpty, !sps.isEmpty, !pps.isEmpty else { return nil }
        return ParameterSets(
            units: units,
            signature: units.map { Data(data[$0.range]) }
        )
    }

    /// Writes length prefixes and payloads directly into CoreMedia-owned storage.
    ///
    /// Input pointers exist only inside `Data.withUnsafeBytes`; no input pointer escapes. The returned
    /// `CMBlockBuffer` owns its separate AVCC allocation, and `CMSampleBuffer` retains that block for
    /// the complete synchronous VideoToolbox decode call.
    static func makeAVCCBlockBuffer(data: Data, nalus: [NALUnit]) -> CMBlockBuffer? {
        guard let byteCount = avccByteCount(dataCount: data.count, nalus: nalus) else { return nil }
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == noErr, let blockBuffer else { return nil }

        var contiguousLength = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let pointerStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &contiguousLength,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard pointerStatus == noErr,
              contiguousLength >= byteCount,
              totalLength == byteCount,
              let dataPointer
        else { return nil }

        let destination = UnsafeMutableRawPointer(dataPointer)
        let wroteAllBytes = data.withUnsafeBytes { rawBuffer -> Bool in
            guard let source = rawBuffer.baseAddress else { return false }
            var destinationOffset = 0
            for nalu in nalus {
                var length = UInt32(nalu.range.count).bigEndian
                withUnsafeBytes(of: &length) { lengthBytes in
                    destination
                        .advanced(by: destinationOffset)
                        .copyMemory(from: lengthBytes.baseAddress!, byteCount: MemoryLayout<UInt32>.size)
                }
                destinationOffset += MemoryLayout<UInt32>.size
                destination
                    .advanced(by: destinationOffset)
                    .copyMemory(
                        from: source.advanced(by: nalu.range.lowerBound),
                        byteCount: nalu.range.count
                    )
                destinationOffset += nalu.range.count
            }
            return destinationOffset == byteCount
        }
        return wroteAllBytes ? blockBuffer : nil
    }

    private static func avccByteCount(dataCount: Int, nalus: [NALUnit]) -> Int? {
        guard !nalus.isEmpty else { return nil }
        var total = 0
        for nalu in nalus {
            guard nalu.range.lowerBound >= 0,
                  nalu.range.upperBound <= dataCount,
                  nalu.range.count <= Int(UInt32.max)
            else { return nil }
            let (unitLength, unitOverflow) = nalu.range.count.addingReportingOverflow(MemoryLayout<UInt32>.size)
            let (newTotal, totalOverflow) = total.addingReportingOverflow(unitLength)
            guard !unitOverflow, !totalOverflow else { return nil }
            total = newTotal
        }
        return total
    }
}

/// VideoToolbox H.265 decoder that preserves bit depth and colorimetry.
///
/// LiveKitWebRTC's built-in `LKRTCVideoDecoderH265` pins its VideoToolbox output to 8-bit
/// NV12 (`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`) and force-stamps BT.709/sRGB
/// color attachments on every frame, which crushes HEVC Main10 HDR10 streams to washed-out
/// 8-bit SDR. This decoder lets VideoToolbox emit its native output format (10-bit for
/// Main10) and propagate the bitstream's VUI colorimetry (PQ/BT.2020 for HDR10) untouched.
/// The upstream fix is proposed as webrtc-sdk/webrtc#267; once it ships in a LiveKitWebRTC
/// release this class can be deleted and `CloudVideoDecoderFactory` reverted to the default
/// decoder.
final nonisolated class CloudVideoDecoderH265: NSObject, LKRTCVideoDecoder, @unchecked Sendable {
    private var callback: RTCVideoDecoderCallback?
    private var videoFormat: CMVideoFormatDescription?
    private var parameterSetSignature: [Data]?
    private var session: VTDecompressionSession?

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        self.callback = callback
    }

    func startDecode(withNumberOfCores _: Int32) -> NSInteger {
        0 // WEBRTC_VIDEO_CODEC_OK
    }

    func release() -> NSInteger {
        destroySession()
        videoFormat = nil
        parameterSetSignature = nil
        callback = nil
        return 0
    }

    func implementationName() -> String {
        "GFNVideoToolboxH265"
    }

    func decode(
        _ encodedImage: LKRTCEncodedImage,
        missingFrames _: Bool,
        codecSpecificInfo _: (any LKRTCCodecSpecificInfo)?,
        renderTimeMs _: Int64
    ) -> NSInteger {
        let data = encodedImage.buffer
        guard !data.isEmpty else { return -1 }
        let nalus = H265AnnexBConverter.nalUnits(in: data)
        guard !nalus.isEmpty else { return -1 }

        // Keyframes carry VPS/SPS/PPS in-band (GFN requests sps-pps-idr-in-keyframe).
        // Rebuild the format description when parameter sets arrive and differ.
        if let parameterSets = H265AnnexBConverter.parameterSets(in: data, nalus: nalus),
           parameterSets.signature != parameterSetSignature
        {
            if let format = Self.makeFormatDescription(data: data, parameterSets: parameterSets) {
                parameterSetSignature = parameterSets.signature
                let formatChanged = videoFormat.map { !CMFormatDescriptionEqual($0, otherFormatDescription: format) } ?? true
                if formatChanged {
                    videoFormat = format
                    destroySession()
                }
            }
        }
        guard let videoFormat else {
            // No parameter sets seen yet (e.g. joined mid-stream) — request a keyframe.
            return -1
        }
        if session == nil, !createSession(format: videoFormat) {
            return -1
        }
        guard let session, let sampleBuffer = Self.makeSampleBuffer(data: data, nalus: nalus, format: videoFormat) else {
            return -1
        }

        let rtpTimestamp = Int32(bitPattern: encodedImage.timeStamp)
        let decodeFailed = Mutex(false)
        let handler: VTDecompressionOutputHandler = { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else {
                h265Log.error("decode output failed: \(status)")
                decodeFailed.withLock { $0 = true }
                return
            }
            let frame = LKRTCVideoFrame(
                buffer: LKRTCCVPixelBuffer(pixelBuffer: imageBuffer),
                rotation: ._0,
                timeStampNs: 0
            )
            frame.timeStamp = rtpTimestamp
            self?.callback?(frame)
        }
        // Synchronous decode: GFN streams have no B-frame reordering (zero-latency encode),
        // so decode order is display order and no reorder queue is needed.
        var status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil, outputHandler: handler)
        if status == kVTInvalidSessionErr {
            // Session dies when the app is backgrounded — recreate and retry once.
            destroySession()
            guard createSession(format: videoFormat), let retrySession = self.session else { return -1 }
            status = VTDecompressionSessionDecodeFrame(retrySession, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil, outputHandler: handler)
        }
        if status != noErr || decodeFailed.withLock({ $0 }) {
            h265Log.error("decode failed: \(status)")
            return -1
        }
        return 0
    }

    // MARK: - VideoToolbox session

    private func createSession(format: CMVideoFormatDescription) -> Bool {
        // No kCVPixelBufferPixelFormatTypeKey: VideoToolbox picks the native output format
        // (420f for Main, x420 for Main10) and propagates VUI colorimetry attachments.
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            h265Log.error("VTDecompressionSessionCreate failed: \(status)")
            return false
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        return true
    }

    private func destroySession() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    // MARK: - VideoToolbox buffers

    private static func makeFormatDescription(
        data: Data,
        parameterSets: H265AnnexBConverter.ParameterSets
    ) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = data.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else {
                return kCMFormatDescriptionError_InvalidParameter
            }
            var pointers = parameterSets.units.map {
                baseAddress
                    .advanced(by: $0.range.lowerBound)
                    .assumingMemoryBound(to: UInt8.self)
            }
            var sizes = parameterSets.units.map(\.range.count)
            // CoreMedia consumes/copies these parameter sets synchronously. None of the pointers
            // are stored by CloudNow or allowed to outlive this `withUnsafeBytes` scope.
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.units.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &format
            )
        }
        guard status == noErr else {
            h265Log.error("format description creation failed: \(status)")
            return nil
        }
        return format
    }

    /// Converts the Annex-B access unit to a 4-byte-length-prefixed sample buffer.
    private static func makeSampleBuffer(
        data: Data,
        nalus: [H265AnnexBConverter.NALUnit],
        format: CMVideoFormatDescription
    ) -> CMSampleBuffer? {
        guard let blockBuffer = H265AnnexBConverter.makeAVCCBlockBuffer(data: data, nalus: nalus) else {
            return nil
        }
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }
}

/// Source compatibility for existing native-provider references.
typealias GFNVideoDecoderH265 = CloudVideoDecoderH265
