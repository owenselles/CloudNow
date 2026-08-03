@testable import CloudNow
import Foundation
import Testing

@Suite("GFN input protocol encoding")
struct InputEncoderTests {
    private let timestamp: UInt64 = 0x0102_0304_0506_0708

    @Test("Heartbeat is always the unwrapped little-endian protocol value")
    func heartbeatEncoding() throws {
        let encoder = makeEncoder()
        encoder.setProtocolVersion(3)
        let packet = EncodedInputPacket()

        encoder.encodeHeartbeat(into: packet)

        try expectBytes(TestBytes.bytes(of: packet), equalTo: [0x02, 0x00, 0x00, 0x00])
    }

    @Test("Protocol v2 gamepad payload has exact fields, endianness, and reserved bytes")
    func protocolV2Gamepad() throws {
        let encoder = makeEncoder()
        let packet = EncodedInputPacket()

        encoder.encodeGamepad(
            controllerId: 7,
            buttons: 0xA55A,
            leftTrigger: 0x12,
            rightTrigger: 0xFE,
            leftStickX: -2,
            leftStickY: 0x1234,
            rightStickX: .min,
            rightStickY: .max,
            gamepadBitmap: 0x0305,
            into: packet
        )
        let bytes = TestBytes.bytes(of: packet)

        try #require(bytes.count == 38)
        #expect(TestBytes.uint32LE(bytes, at: 0) == 12, "type at byte offset 0")
        #expect(TestBytes.uint16LE(bytes, at: 4) == 26, "body length at byte offset 4")
        #expect(TestBytes.uint16LE(bytes, at: 6) == 3, "masked controller ID at byte offset 6")
        #expect(TestBytes.uint16LE(bytes, at: 8) == 0x0305, "gamepad bitmap at byte offset 8")
        #expect(TestBytes.uint16LE(bytes, at: 10) == 20, "state length at byte offset 10")
        #expect(TestBytes.uint16LE(bytes, at: 12) == 0xA55A, "button bits at byte offset 12")
        #expect(bytes[14] == 0x12, "left trigger at byte offset 14")
        #expect(bytes[15] == 0xFE, "right trigger at byte offset 15")
        #expect(TestBytes.uint16LE(bytes, at: 16) == UInt16(bitPattern: -2), "left X at byte offset 16")
        #expect(TestBytes.uint16LE(bytes, at: 18) == 0x1234, "left Y at byte offset 18")
        #expect(TestBytes.uint16LE(bytes, at: 20) == UInt16(bitPattern: Int16.min), "right X at byte offset 20")
        #expect(TestBytes.uint16LE(bytes, at: 22) == UInt16(bitPattern: Int16.max), "right Y at byte offset 22")
        try expectZeroes(bytes, offsets: [24, 25, 27, 28, 29])
        #expect(bytes[26] == 0x55, "protocol marker at byte offset 26")
        #expect(TestBytes.uint64LE(bytes, at: 30) == timestamp, "timestamp at byte offset 30")
    }

    @Test("Protocol v3 gamepad wraps the v2 body and advances sequence per controller")
    func protocolV3GamepadAndSequence() throws {
        let encoder = makeEncoder()
        encoder.setProtocolVersion(3)
        let first = EncodedInputPacket()
        let second = EncodedInputPacket()
        let otherController = EncodedInputPacket()

        encodeNeutralGamepad(controllerId: 5, encoder: encoder, packet: first)
        encodeNeutralGamepad(controllerId: 5, encoder: encoder, packet: second)
        encodeNeutralGamepad(controllerId: 1, encoder: encoder, packet: otherController)

        let firstBytes = TestBytes.bytes(of: first)
        let secondBytes = TestBytes.bytes(of: second)
        let otherBytes = TestBytes.bytes(of: otherController)
        try #require(firstBytes.count == 54)
        try #require(secondBytes.count == 54)
        try #require(otherBytes.count == 54)
        #expect(firstBytes[0] == 0x23, "wrapper kind at byte offset 0")
        #expect(TestBytes.uint64BE(firstBytes, at: 1) == timestamp, "wrapper timestamp at byte offset 1")
        #expect(firstBytes[9] == 0x26, "gamepad wrapper kind at byte offset 9")
        #expect(firstBytes[10] == 5, "unmasked controller ID at byte offset 10")
        #expect(TestBytes.uint16BE(firstBytes, at: 11) == 1, "first sequence at byte offset 11")
        #expect(firstBytes[13] == 0x21, "payload marker at byte offset 13")
        #expect(TestBytes.uint16BE(firstBytes, at: 14) == 38, "payload length at byte offset 14")
        #expect(TestBytes.uint16LE(firstBytes, at: 22) == 1, "masked controller ID at byte offset 22")
        #expect(TestBytes.uint64LE(firstBytes, at: 46) == timestamp, "payload timestamp at byte offset 46")
        #expect(TestBytes.uint16BE(secondBytes, at: 11) == 2)
        #expect(TestBytes.uint16BE(otherBytes, at: 11) == 1)
    }

    @Test(
        "Keyboard down and up packets encode modifiers and scan code in network order",
        arguments: [(true, UInt32(3)), (false, UInt32(4))]
    )
    func keyboardV2(down: Bool, expectedType: UInt32) throws {
        let encoder = makeEncoder()
        let packet = EncodedInputPacket()

        encoder.encodeKeyboard(
            down: down,
            vk: 0x1234,
            scancode: 0xABCD,
            modifiers: 0x00C3,
            into: packet
        )
        let bytes = TestBytes.bytes(of: packet)

        try #require(bytes.count == 18)
        #expect(TestBytes.uint32LE(bytes, at: 0) == expectedType, "event type at byte offset 0")
        #expect(TestBytes.uint16BE(bytes, at: 4) == 0x1234, "virtual key at byte offset 4")
        #expect(TestBytes.uint16BE(bytes, at: 6) == 0x00C3, "modifiers at byte offset 6")
        #expect(TestBytes.uint16BE(bytes, at: 8) == 0xABCD, "scan code at byte offset 8")
        #expect(TestBytes.uint64BE(bytes, at: 10) == timestamp, "timestamp at byte offset 10")
    }

    @Test("Protocol v3 single events receive the deterministic wrapper")
    func keyboardV3Wrapper() throws {
        let encoder = makeEncoder()
        encoder.setProtocolVersion(3)
        let packet = EncodedInputPacket()

        encoder.encodeKeyboard(down: true, vk: 1, scancode: 2, modifiers: 3, into: packet)
        let bytes = TestBytes.bytes(of: packet)

        try #require(bytes.count == 28)
        #expect(bytes[0] == 0x23)
        #expect(TestBytes.uint64BE(bytes, at: 1) == timestamp)
        #expect(bytes[9] == 0x22)
        #expect(TestBytes.uint32LE(bytes, at: 10) == 3)
        #expect(TestBytes.uint64BE(bytes, at: 20) == timestamp)
    }

    @Test("Mouse movement encodes signed deltas and zeroes reserved bytes")
    func mouseMovement() throws {
        let encoder = makeEncoder()
        let packet = EncodedInputPacket()

        encoder.encodeMouseMove(dx: -300, dy: 511, into: packet)
        let bytes = TestBytes.bytes(of: packet)

        try #require(bytes.count == 22)
        #expect(TestBytes.uint32LE(bytes, at: 0) == 7)
        #expect(TestBytes.uint16BE(bytes, at: 4) == UInt16(bitPattern: -300))
        #expect(TestBytes.uint16BE(bytes, at: 6) == UInt16(bitPattern: 511))
        try expectZeroes(bytes, offsets: Array(8 ... 13))
        #expect(TestBytes.uint64BE(bytes, at: 14) == timestamp)
    }

    @Test(
        "Mouse button transitions use distinct event types",
        arguments: [(true, UInt32(8)), (false, UInt32(9))]
    )
    func mouseButton(down: Bool, expectedType: UInt32) throws {
        let encoder = makeEncoder()
        let packet = EncodedInputPacket()

        encoder.encodeMouseButton(down: down, button: 4, into: packet)
        let bytes = TestBytes.bytes(of: packet)

        try #require(bytes.count == 18)
        #expect(TestBytes.uint32LE(bytes, at: 0) == expectedType)
        #expect(bytes[4] == 4)
        try expectZeroes(bytes, offsets: Array(5 ... 9))
        #expect(TestBytes.uint64BE(bytes, at: 10) == timestamp)
    }

    @Test("Mouse wheel encodes a signed network-order delta")
    func mouseWheel() throws {
        let encoder = makeEncoder()
        let packet = EncodedInputPacket()

        encoder.encodeMouseWheel(delta: -120, into: packet)
        let bytes = TestBytes.bytes(of: packet)

        try #require(bytes.count == 22)
        #expect(TestBytes.uint32LE(bytes, at: 0) == 10)
        try expectZeroes(bytes, offsets: [4, 5] + Array(8 ... 13))
        #expect(TestBytes.uint16BE(bytes, at: 6) == UInt16(bitPattern: -120))
        #expect(TestBytes.uint64BE(bytes, at: 14) == timestamp)
    }

    @Test(
        "Haptics capability packets encode enabled and disabled states",
        arguments: [(true, UInt16(1)), (false, UInt16(0))]
    )
    func hapticsEnabled(enabled: Bool, expected: UInt16) throws {
        let encoder = makeEncoder()
        encoder.setProtocolVersion(3)
        let packet = EncodedInputPacket()

        encoder.encodeHapticsEnabled(enabled, into: packet)
        let bytes = TestBytes.bytes(of: packet)

        try #require(bytes.count == 16)
        #expect(bytes[0] == 0x23)
        #expect(bytes[9] == 0x22)
        #expect(TestBytes.uint32LE(bytes, at: 10) == 13)
        #expect(TestBytes.uint16BE(bytes, at: 14) == expected)
    }

    @Test("Protocol v3 mouse movement carries its explicit payload length")
    func mouseMovementV3Wrapper() throws {
        let encoder = makeEncoder()
        encoder.setProtocolVersion(3)
        let packet = EncodedInputPacket()

        encoder.encodeMouseMove(dx: 1, dy: 2, into: packet)
        let bytes = TestBytes.bytes(of: packet)

        try #require(bytes.count == 34)
        #expect(bytes[0] == 0x23)
        #expect(TestBytes.uint64BE(bytes, at: 1) == timestamp)
        #expect(bytes[9] == 0x21)
        #expect(TestBytes.uint16BE(bytes, at: 10) == 22)
        #expect(TestBytes.uint32LE(bytes, at: 12) == 7)
    }

    @Test("Reusing storage exposes only the new packet and clears its reserved bytes")
    func reusablePacketDoesNotLeakLongerPayload() throws {
        let encoder = makeEncoder()
        let packet = EncodedInputPacket()

        encodeNeutralGamepad(controllerId: 0, encoder: encoder, packet: packet)
        #expect(packet.count == 38)
        encoder.encodeMouseButton(down: true, button: 1, into: packet)
        let buttonBytes = TestBytes.bytes(of: packet)

        try #require(buttonBytes.count == 18)
        try expectZeroes(buttonBytes, offsets: Array(5 ... 9))

        encoder.encodeHeartbeat(into: packet)
        try expectBytes(TestBytes.bytes(of: packet), equalTo: [2, 0, 0, 0])
    }

    private func makeEncoder() -> InputEncoder {
        let fixedTimestamp = timestamp
        return InputEncoder(timestampProvider: { fixedTimestamp })
    }

    private func encodeNeutralGamepad(
        controllerId: Int,
        encoder: InputEncoder,
        packet: EncodedInputPacket
    ) {
        encoder.encodeGamepad(
            controllerId: controllerId,
            buttons: 0,
            leftTrigger: 0,
            rightTrigger: 0,
            leftStickX: 0,
            leftStickY: 0,
            rightStickX: 0,
            rightStickY: 0,
            gamepadBitmap: 1,
            into: packet
        )
    }

    private func expectBytes(_ actual: [UInt8], equalTo expected: [UInt8]) throws {
        try #require(actual.count == expected.count)
        for offset in expected.indices {
            #expect(
                actual[offset] == expected[offset],
                "byte offset \(offset): expected \(expected[offset]), got \(actual[offset])"
            )
        }
    }

    private func expectZeroes(_ bytes: [UInt8], offsets: [Int]) throws {
        let highestOffset = try #require(offsets.max())
        try #require(bytes.indices.contains(highestOffset))
        for offset in offsets {
            #expect(bytes[offset] == 0, "reserved byte offset \(offset) was \(bytes[offset])")
        }
    }
}
