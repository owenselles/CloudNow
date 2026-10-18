@testable import CloudNow
import CoreMedia
import Foundation
import Testing

struct AV1StreamConfigurationTests {
    /// Actual SVT-AV1 4.2.0 sequence headers: one blue frame, preset 11, CRF 40.
    /// Dimensions, bit depth, level, and av1C bytes independently checked with ffprobe
    /// after remuxing the elementary streams to MP4 without re-encoding.
    private static let sdr = Data([
        0x0A, 0x0C, 0x02, 0x00, 0x00, 0x2D, 0x2A, 0x67, 0xFD, 0x9E, 0x25, 0x7C, 0x80, 0x20,
    ])
    private static let tenBit = Data([
        0x0A, 0x0F, 0x02, 0x00, 0x00, 0x4A, 0x95, 0x5D, 0xFE, 0x1B, 0x89, 0x5F, 0x2A, 0x04, 0x04, 0x12, 0x08,
    ])

    @Test("AV1 sequence headers preserve native dimensions and av1C color fields", arguments: [false, true])
    func parsesEncoderProducedHeaders(tenBit: Bool) throws {
        let header = tenBit ? Self.tenBit : Self.sdr
        let configuration = try #require(try AV1StreamConfiguration.parse(from: Data([0x12, 0]) + header))

        #expect(configuration.width == (tenBit ? 1920 : 1280))
        #expect(configuration.height == (tenBit ? 1080 : 720))
        let prefix = Data(tenBit ? [0x81, 0x09, 0x4C, 0] : [0x81, 0x05, 0x0C, 0])
        #expect(configuration.codecConfigurationRecord == prefix + header)
    }

    @Test("Timing, multiple operating points, and frame IDs do not misalign the configuration")
    func handlesOptionalSequenceFields() throws {
        // AV1 section 5.5 fixture: two operating points; first level 4.1/high tier,
        // decoder model and initial delay, 16x8 dimensions, vertical chroma position.
        let header = Data([
            0x0A, 0x1E, 0x04, 0x00, 0x00, 0x0F, 0xA4, 0x00, 0x03, 0xA9, 0x82, 0xA4, 0x00, 0x00, 0x03, 0xE8,
            0x21, 0x21, 0x00, 0x04, 0xE1, 0x0A, 0x40, 0x00, 0x50, 0xCF, 0xDE, 0x24, 0x04, 0x54, 0x02, 0x20,
        ])
        let configuration = try #require(try AV1StreamConfiguration.parse(from: header))

        #expect(configuration.width == 16)
        #expect(configuration.height == 8)
        #expect(configuration.codecConfigurationRecord == Data([0x81, 0x09, 0x8E, 0]) + header)
    }

    @Test("UVLC maximum-value timing consumes its terminator before the decoder model", arguments: [false, true])
    func parsesMaximumTimingInterval(extraLeadingZero: Bool) throws {
        // AOM uvlc(): at least 32 zero bits followed by one means UInt32.max,
        // without suffix bits. The remaining fields match the timing fixture above.
        let payloads: [[UInt8]] = [
            [0x04, 0x00, 0x00, 0x0F, 0xA4, 0x00, 0x03, 0xA9, 0x82, 0x00, 0x00, 0x00, 0x01, 0x90, 0x00, 0x00, 0x0F,
             0xA0, 0x84, 0x84, 0x00, 0x13, 0x84, 0x29, 0x00, 0x01, 0x43, 0x3F, 0x78, 0x90, 0x11, 0x50, 0x08, 0x80],
            [0x04, 0x00, 0x00, 0x0F, 0xA4, 0x00, 0x03, 0xA9, 0x82, 0x00, 0x00, 0x00, 0x00, 0xC8, 0x00, 0x00, 0x07,
             0xD0, 0x42, 0x42, 0x00, 0x09, 0xC2, 0x14, 0x80, 0x00, 0xA1, 0x9F, 0xBC, 0x48, 0x08, 0xA8, 0x04, 0x40],
        ]
        let header = Data([0x0A, 0x22] + payloads[extraLeadingZero ? 1 : 0])
        let configuration = try #require(try AV1StreamConfiguration.parse(from: header))
        #expect(configuration.width == 16)
        #expect(configuration.height == 8)
        #expect(configuration.codecConfigurationRecord == Data([0x81, 0x09, 0x8E, 0]) + header)
    }

    @Test("Reduced still-picture headers preserve monochrome, RGB, and 12-bit configuration", arguments: [0, 1, 2])
    func parsesReducedHeaders(profile: Int) throws {
        // AV1 section 5.5 fixtures: 16x8, level 3.1, reduced header.
        let headers = [
            Data([0x0A, 0x05, 0x19, 0x4C, 0xFD, 0xC0, 0x44]),
            Data([0x0A, 0x08, 0x39, 0x4C, 0xFD, 0xC0, 0xC0, 0x43, 0x40, 0x08]),
            Data([0x0A, 0x06, 0x59, 0x4C, 0xFD, 0xC0, 0xC6, 0x90]),
        ]
        let configuration = try #require(try AV1StreamConfiguration.parse(from: headers[profile]))
        #expect(configuration.width == 16)
        #expect(configuration.height == 8)
        let colorBytes: [UInt8] = [0x1C, 0x40, 0x6D]
        #expect(configuration.codecConfigurationRecord == Data([0x81, UInt8(profile << 5 | 5), colorBytes[profile], 0]) + headers[profile])
    }

    @Test("Frames without a sequence header keep the existing decoder configuration")
    func returnsNilWithoutSequenceHeader() throws {
        #expect(try AV1StreamConfiguration.parse(from: Data([0x32, 0x01, 0])) == nil)
        #expect(try AV1StreamConfiguration.parse(from: Data()) == nil)
    }

    @Test("OBU extensions and nonzero Data indices preserve the sequence header")
    func parsesExtendedAndSlicedData() throws {
        var extended = Data([0x0E, 0])
        extended.append(Self.sdr.dropFirst())
        let prefixed = Data([0xFF, 0xFF]) + extended
        let configuration = try #require(try AV1StreamConfiguration.parse(from: prefixed.dropFirst(2)))

        #expect(configuration.width == 1280)
        #expect(configuration.codecConfigurationRecord == Data([0x81, 0x05, 0x0C, 0]) + extended)
    }

    private static let malformedData: [Data] = [
        Data([0x8A, 0]), // Forbidden bit.
        Data([0x0B, 0]), // Reserved bit.
        Data([0x08]), // Missing size field.
        Data([0x0E]), // Truncated extension.
        Data([0x0E, 1, 0]), // Reserved extension bits.
        Data([0x0E, 0x20, 0]), // Sequence header cannot have a temporal layer ID.
        Data([0x0A, 0x80]), // Truncated LEB128.
        Data([0x0A] + Array(repeating: UInt8(0x80), count: 8)),
        Data([0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]), // Overflowing AV1 OBU size.
        Data([0x0A, 2, 0]), // Payload shorter than its advertised length.
        Data([0x0A, 0]), // Empty sequence header.
        Data([0x0A, 1, 0xE0]), // Reserved profile.
        Data([0x0A, 1, 0x08]), // Reduced header without still_picture.
        Data([0x0A, 1, 0]), // Incomplete sequence header.
    ]

    @Test("Malformed OBU framing and truncated sequence fields fail safely", arguments: malformedData)
    func rejectsMalformedData(_ data: Data) {
        #expect(throws: AV1StreamConfiguration.ParseError.self) {
            try AV1StreamConfiguration.parse(from: data)
        }
    }

    @Test("A valid sequence header does not hide a malformed trailing OBU")
    func validatesCompleteAccessUnit() {
        #expect(throws: AV1StreamConfiguration.ParseError.self) {
            try AV1StreamConfiguration.parse(from: Self.sdr + Data([0x32, 0x80]))
        }
        #expect(throws: AV1StreamConfiguration.ParseError.self) {
            try AV1StreamConfiguration.parse(from: Self.sdr + Self.tenBit)
        }
        var missingTrailingBit = Self.sdr
        missingTrailingBit[missingTrailingBit.count - 1] = 0
        #expect(throws: AV1StreamConfiguration.ParseError.self) {
            try AV1StreamConfiguration.parse(from: missingTrailingBit)
        }
    }

    @Test("Native AV1 format contains the sequence's av1C record and owned sample bytes")
    func createsCoreMediaFormatAndSample() throws {
        let configuration = try #require(try AV1StreamConfiguration.parse(from: Self.sdr))
        let format = try #require(CloudVideoDecoderAV1.makeFormatDescription(configuration: configuration))
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_AV1)
        #expect(CMVideoFormatDescriptionGetDimensions(format).width == 1280)
        #expect(CMVideoFormatDescriptionGetDimensions(format).height == 720)
        let atoms = try #require(CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Data])
        #expect(atoms["av1C"] == configuration.codecConfigurationRecord)

        var source = Self.sdr
        let sample = try #require(CloudVideoDecoderAV1.makeSampleBuffer(data: source, format: format))
        source.resetBytes(in: source.startIndex ..< source.endIndex)
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var actual = Data(count: CMBlockBufferGetDataLength(block))
        let count = actual.count
        let status = actual.withUnsafeMutableBytes { destination in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: destination.baseAddress!)
        }
        #expect(status == noErr)
        #expect(actual == Self.sdr)
    }
}
