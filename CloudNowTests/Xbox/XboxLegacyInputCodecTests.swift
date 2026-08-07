@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox legacy input codec")
struct XboxLegacyInputCodecTests {
    @Test("Version 2 encodes a little-endian gamepad report")
    func encodesVersionTwoGamepad() throws {
        var encoder = XboxLegacyInputEncoder()

        let data = try encoder.encodeGamepads(
            [
                XboxGamepadState(
                    index: 0,
                    buttons: [.a, .dpadUp, .rightShoulder],
                    leftThumbX: 1,
                    leftThumbY: -1,
                    rightThumbX: .max,
                    rightThumbY: -32767,
                    leftTrigger: 32768,
                    rightTrigger: .max,
                    physicalPhysicality: [.a, .dpadUp, .rightShoulder],
                    virtualPhysicality: []
                ),
            ],
            version: 2,
            timestampMilliseconds: 123.5
        )

        #expect(data == Data([
            0x02,
            0x01, 0x00, 0x00, 0x00,
            0x01,
            0x00,
            0x10, 0x21,
            0x01, 0x00,
            0xFF, 0xFF,
            0xFF, 0x7F,
            0x01, 0x80,
            0x00, 0x80,
            0xFF, 0xFF,
            0x01, 0x12, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ]))
    }

    @Test("Version 10 uses a wide flag and monotonic timestamp header")
    func encodesVersionTenHeader() throws {
        var encoder = XboxLegacyInputEncoder()
        let timestamp = 123.5

        let data = try encoder.encodeGamepads(
            [],
            version: 10,
            timestampMilliseconds: timestamp
        )

        var expected = Data([
            0x02, 0x00,
            0x01, 0x00, 0x00, 0x00,
        ])
        expected.append(contentsOf: littleEndianBytes(timestamp.bitPattern))
        expected.append(0)
        #expect(data == expected)
    }

    @Test("Version 10 encodes an exact single-controller report")
    func encodesVersionTenGamepad() throws {
        var encoder = XboxLegacyInputEncoder()
        let timestamp = 123.5
        _ = try encoder.encodeClientMetadata(
            version: 10,
            timestampMilliseconds: timestamp
        )

        let data = try encoder.encodeGamepads(
            [
                XboxGamepadState(
                    index: 0,
                    buttons: [.a, .dpadUp, .rightShoulder],
                    leftThumbX: 1,
                    leftThumbY: -1,
                    rightThumbX: .max,
                    rightThumbY: -32767,
                    leftTrigger: 32768,
                    rightTrigger: .max,
                    physicalPhysicality: [.a, .dpadUp, .rightShoulder]
                ),
            ],
            version: 10,
            timestampMilliseconds: timestamp
        )

        var expected = Data([
            0x02, 0x00,
            0x02, 0x00, 0x00, 0x00,
        ])
        expected.append(contentsOf: littleEndianBytes(timestamp.bitPattern))
        expected.append(contentsOf: [
            0x01,
            0x00,
            0x10, 0x21,
            0x01, 0x00,
            0xFF, 0xFF,
            0xFF, 0x7F,
            0x01, 0x80,
            0x00, 0x80,
            0xFF, 0xFF,
            0x01, 0x12, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])

        #expect(data == expected)
    }

    @Test("Client metadata starts at protocol version 3")
    func encodesClientMetadata() throws {
        var encoder = XboxLegacyInputEncoder()

        #expect(try encoder.encodeClientMetadata(
            version: 2,
            timestampMilliseconds: 1
        ) == nil)
        #expect(try encoder.encodeClientMetadata(
            version: 3,
            timestampMilliseconds: 1
        ) == Data([
            0x08,
            0x01, 0x00, 0x00, 0x00,
            0x00,
        ]))
        #expect(try encoder.encodeClientMetadata(
            version: 3,
            maximumTouchPoints: 1,
            timestampMilliseconds: 1
        )?.last == 1)
    }

    @Test("Version 10 client metadata advertises no touch input")
    func encodesVersionTenClientMetadata() throws {
        var encoder = XboxLegacyInputEncoder()
        let timestamp = 123.5

        let optionalData = try encoder.encodeClientMetadata(
            version: 10,
            timestampMilliseconds: timestamp
        )
        let data = try #require(optionalData)
        var expected = Data([
            0x08, 0x00,
            0x01, 0x00, 0x00, 0x00,
        ])
        expected.append(contentsOf: littleEndianBytes(timestamp.bitPattern))
        expected.append(0)

        #expect(data == expected)
    }

    @Test("Decoder accepts server metadata and four-motor rumble")
    func decodesFeedback() throws {
        let metadata = try XboxLegacyInputFeedbackDecoder.decode(
            Data([
                0x10, 0x00,
                0xD0, 0x02, 0x00, 0x00,
                0x00, 0x05, 0x00, 0x00,
            ]),
            version: 10
        )
        #expect(metadata == .serverMetadata(height: 720, width: 1280))

        let rumble = try XboxLegacyInputFeedbackDecoder.decode(
            Data([
                0x80, 0x00,
                0x00,
                0x01,
                50, 25, 10, 5,
                0x2C, 0x01,
                0x14, 0x00,
                0x02,
            ]),
            version: 10
        )
        #expect(rumble == .rumble(XboxRumbleCommand(
            gamepadIndex: 1,
            leftMotorPercent: 50,
            rightMotorPercent: 25,
            leftTriggerMotorPercent: 10,
            rightTriggerMotorPercent: 5,
            durationMilliseconds: 300,
            delayMilliseconds: 20,
            repeatCount: 2
        )))
    }

    @Test("Encoder and decoder reject unsupported or malformed data")
    func rejectsInvalidInput() throws {
        var encoder = XboxLegacyInputEncoder()

        #expect(throws: XboxLegacyInputCodecError.unsupportedVersion) {
            _ = try encoder.encodeGamepads(
                [],
                version: 11,
                timestampMilliseconds: 0
            )
        }
        #expect(throws: XboxLegacyInputCodecError.tooManyGamepads) {
            _ = try encoder.encodeGamepads(
                (0 ... 4).map { XboxGamepadState(index: UInt8($0)) },
                version: 10,
                timestampMilliseconds: 0
            )
        }
        #expect(throws: XboxLegacyInputCodecError.malformedFeedback) {
            _ = try XboxLegacyInputFeedbackDecoder.decode(
                Data([0x80, 0x00]),
                version: 10
            )
        }
        #expect(throws: XboxLegacyInputCodecError.malformedFeedback) {
            _ = try XboxLegacyInputFeedbackDecoder.decode(
                Data([
                    0x80, 0x00,
                    0x00, 0x00,
                    101, 0, 0, 0,
                    0, 0, 0, 0, 0,
                ]),
                version: 10
            )
        }
    }
}

private func littleEndianBytes(_ value: UInt64) -> [UInt8] {
    [
        UInt8(truncatingIfNeeded: value),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 32),
        UInt8(truncatingIfNeeded: value >> 40),
        UInt8(truncatingIfNeeded: value >> 48),
        UInt8(truncatingIfNeeded: value >> 56),
    ]
}
