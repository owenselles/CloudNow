import CoreMedia
import Foundation
@preconcurrency import LiveKitWebRTC
import os.log
import Synchronization
import VideoToolbox

private nonisolated let h265Log = Logger(subsystem: "com.owenselles.CloudNow2", category: "H265Decoder")

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
final nonisolated class GFNVideoDecoderH265: NSObject, LKRTCVideoDecoder, @unchecked Sendable {
    // HOT PATH INVARIANT: keep this imported Objective-C block in its concrete type and invoke
    // it directly. A generic Mutex read here previously accumulated callback reabstraction
    // thunks until the decoder thread overflowed its stack. WebRTC currently serializes the
    // decoder lifecycle and decode remains synchronous below. Re-profile and device-stress any
    // change that adds concurrency or a per-frame bridge around this callback.
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
        renderTimeMs: Int64
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
        let frameTimestampNanoseconds = Self.frameTimestampNanoseconds(
            renderTimeMs: renderTimeMs,
            rtpTimestamp: encodedImage.timeStamp
        )
        let presentationTimeStamp = CMTime(
            value: frameTimestampNanoseconds,
            timescale: 1_000_000_000
        )
        guard let session,
              let sampleBuffer = Self.makeSampleBuffer(
                  data: data,
                  nalus: nalus,
                  format: videoFormat,
                  presentationTimeStamp: presentationTimeStamp
              )
        else {
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
                timeStampNs: frameTimestampNanoseconds
            )
            frame.timeStamp = rtpTimestamp
            self?.callback?(frame)
        }
        // HOT PATH INVARIANT: keep one frame in flight. With no asynchronous flag,
        // VideoToolbox completes the output callback before this call returns. Enabling async
        // decode without a measured, bounded admission policy lets complexity spikes build a
        // stale decoder queue and retain multiple 4K CVPixelBuffers.
        let decodeFlags: VTDecodeFrameFlags = []
        var status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: decodeFlags,
            infoFlagsOut: nil,
            outputHandler: handler
        )
        if status == kVTInvalidSessionErr {
            // Session dies when the app is backgrounded — recreate and retry once.
            destroySession()
            guard createSession(format: videoFormat), let retrySession = self.session else { return -1 }
            status = VTDecompressionSessionDecodeFrame(
                retrySession,
                sampleBuffer: sampleBuffer,
                flags: decodeFlags,
                infoFlagsOut: nil,
                outputHandler: handler
            )
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
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var units: [NALUnit] = []
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
                    payloadStarts[index + 1] - (
                        payloadStarts[index + 1] >= 4
                            && bytes[payloadStarts[index + 1] - 4] == 0
                            && bytes[payloadStarts[index + 1] - 3] == 0
                            && bytes[payloadStarts[index + 1] - 2] == 0 ? 4 : 3
                    )
                } else {
                    bytes.count
                }
                guard nextStartCode > start else { continue }
                units.append(NALUnit(range: start ..< nextStartCode, type: (bytes[start] >> 1) & 0x3F))
            }
            return units
        }
    }

    private static func makeFormatDescription(data: Data, nalus: [NALUnit]) -> CMVideoFormatDescription? {
        let vps = nalus.filter { $0.type == vpsType }
        let sps = nalus.filter { $0.type == spsType }
        let pps = nalus.filter { $0.type == ppsType }
        guard !vps.isEmpty, !sps.isEmpty, !pps.isEmpty else { return nil }

        let parameterSets = vps + sps + pps
        return data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var pointers = parameterSets.map { UnsafePointer(bytes.advanced(by: $0.range.lowerBound)) }
            var sizes = parameterSets.map(\.range.count)
            var format: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
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
    }

    /// Converts the Annex-B access unit to a 4-byte-length-prefixed sample buffer.
    private static func makeSampleBuffer(
        data: Data,
        nalus: [NALUnit],
        format: CMVideoFormatDescription,
        presentationTimeStamp: CMTime
    ) -> CMSampleBuffer? {
        let blockLength = nalus.reduce(0) { $0 + 4 + $1.range.count }
        guard blockLength > 0 else { return nil }
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: blockLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: blockLength,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return nil }

        status = data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return OSStatus(kCMBlockBufferBadPointerParameterErr)
            }
            var destinationOffset = 0
            for nalu in nalus {
                var length = UInt32(nalu.range.count).bigEndian
                let lengthStatus = withUnsafeBytes(of: &length) { lengthBytes in
                    CMBlockBufferReplaceDataBytes(
                        with: lengthBytes.baseAddress!,
                        blockBuffer: blockBuffer,
                        offsetIntoDestination: destinationOffset,
                        dataLength: lengthBytes.count
                    )
                }
                guard lengthStatus == noErr else { return lengthStatus }
                destinationOffset += 4

                let payloadStatus = CMBlockBufferReplaceDataBytes(
                    with: baseAddress.advanced(by: nalu.range.lowerBound),
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: destinationOffset,
                    dataLength: nalu.range.count
                )
                guard payloadStatus == noErr else { return payloadStatus }
                destinationOffset += nalu.range.count
            }
            return noErr
        }
        guard status == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleSize = blockLength
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    private static func frameTimestampNanoseconds(renderTimeMs: Int64, rtpTimestamp: UInt32) -> Int64 {
        if renderTimeMs > 0 {
            return renderTimeMs * 1_000_000
        }
        return Int64(rtpTimestamp) * 1_000_000_000 / 90000
    }
}
