import CoreMedia
import Foundation
@preconcurrency import LiveKitWebRTC
import os.log
import VideoToolbox

private let h265Log = Logger(subsystem: "com.owenselles.CloudNow2", category: "H265Decoder")

/// VideoToolbox H.265 decoder that preserves bit depth and colorimetry.
///
/// LiveKitWebRTC's built-in `LKRTCVideoDecoderH265` pins its VideoToolbox output to 8-bit
/// NV12 (`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`) and force-stamps BT.709/sRGB
/// color attachments on every frame, which crushes HEVC Main10 HDR10 streams to washed-out
/// 8-bit SDR. This decoder lets VideoToolbox emit its native output format (10-bit for
/// Main10) and propagate the bitstream's VUI colorimetry (PQ/BT.2020 for HDR10) untouched.
/// The upstream fix is proposed as webrtc-sdk/webrtc#267; once it ships in a LiveKitWebRTC
/// release this class can be deleted and `GFNVideoDecoderFactory` reverted to the default
/// decoder.
final class GFNVideoDecoderH265: NSObject, LKRTCVideoDecoder {
    private var callback: RTCVideoDecoderCallback?
    private var videoFormat: CMVideoFormatDescription?
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
        let nalus = Self.annexBNALUnits(in: data)
        guard !nalus.isEmpty else { return -1 }

        // Keyframes carry VPS/SPS/PPS in-band (GFN requests sps-pps-idr-in-keyframe).
        // Rebuild the format description when parameter sets arrive and differ.
        if let format = Self.makeFormatDescription(data: data, nalus: nalus) {
            let formatChanged = videoFormat.map { !CMFormatDescriptionEqual($0, otherFormatDescription: format) } ?? true
            if formatChanged {
                videoFormat = format
                destroySession()
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
        // Captured by reference; the synchronous decode below runs the handler before returning.
        var decodeFailed = false
        let handler: VTDecompressionOutputHandler = { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else {
                h265Log.error("decode output failed: \(status)")
                decodeFailed = true
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
        if status != noErr || decodeFailed {
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

    // MARK: - Annex-B parsing

    private struct NALUnit {
        /// Payload range in the access unit, excluding the start code.
        let range: Range<Int>
        /// H.265 nal_unit_type: (first payload byte >> 1) & 0x3F.
        let type: UInt8
    }

    private static let vpsType: UInt8 = 32
    private static let spsType: UInt8 = 33
    private static let ppsType: UInt8 = 34

    private static func annexBNALUnits(in data: Data) -> [NALUnit] {
        var units: [NALUnit] = []
        let bytes = [UInt8](data)
        var payloadStarts: [Int] = []
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    payloadStarts.append(i + 3)
                    i += 3
                    continue
                }
                if bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    payloadStarts.append(i + 4)
                    i += 4
                    continue
                }
            }
            i += 1
        }
        for (index, start) in payloadStarts.enumerated() {
            let nextStartCode: Int = if index + 1 < payloadStarts.count {
                // The next payload start minus its start code (3 or 4 bytes; detect the longer form).
                payloadStarts[index + 1] - (payloadStarts[index + 1] >= 4 && bytes[payloadStarts[index + 1] - 4] == 0 && bytes[payloadStarts[index + 1] - 3] == 0 && bytes[payloadStarts[index + 1] - 2] == 0 ? 4 : 3)
            } else {
                bytes.count
            }
            guard nextStartCode > start else { continue }
            units.append(NALUnit(range: start ..< nextStartCode, type: (bytes[start] >> 1) & 0x3F))
        }
        return units
    }

    private static func makeFormatDescription(data: Data, nalus: [NALUnit]) -> CMVideoFormatDescription? {
        let vps = nalus.filter { $0.type == vpsType }
        let sps = nalus.filter { $0.type == spsType }
        let pps = nalus.filter { $0.type == ppsType }
        guard !vps.isEmpty, !sps.isEmpty, !pps.isEmpty else { return nil }

        let sets = (vps + sps + pps).map { data.subdata(in: $0.range) }
        var allocations: [UnsafeMutablePointer<UInt8>] = []
        defer { allocations.forEach { $0.deallocate() } }
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        for set in sets {
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            allocations.append(pointer)
            pointers.append(UnsafePointer(pointer))
            sizes.append(set.count)
        }

        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: sets.count,
            parameterSetPointers: &pointers,
            parameterSetSizes: &sizes,
            nalUnitHeaderLength: 4,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr else {
            h265Log.error("format description creation failed: \(status)")
            return nil
        }
        return format
    }

    /// Converts the Annex-B access unit to a 4-byte-length-prefixed sample buffer.
    private static func makeSampleBuffer(data: Data, nalus: [NALUnit], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var avcc = Data(capacity: data.count + nalus.count * 4)
        for nalu in nalus {
            var length = UInt32(nalu.range.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(data.subdata(in: nalu.range))
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return nil }
        status = avcc.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return OSStatus(kCMBlockBufferBadPointerParameterErr) }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
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
