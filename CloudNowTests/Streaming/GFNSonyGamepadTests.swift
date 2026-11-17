@testable import CloudNow
import Foundation
import Testing

@Suite("GFN synthesized Sony controller protocol")
struct GFNSonyGamepadTests {
    @Test(
        "Neutral reports match the official 71-byte DS4 payload for every Sony slot",
        arguments: [(0, UInt8(6)), (1, 7), (2, 8), (3, 9)]
    )
    func neutralReport(slot: Int, expectedId: UInt8) {
        let expected: [UInt8] = [17, 0, 0, 0, expectedId, 4, 0, 1, 127, 127, 127, 127, 8]
            + [UInt8](repeating: 0, count: 24)
            + [11]
            + [UInt8](repeating: 0, count: 33)

        #expect(GFNSonyGamepad.reportSize == 71)
        #expect(report(slot: slot) == expected)
    }

    @Test(
        "Device changes use Sony IDs 6 through 9 and big-endian flags",
        arguments: [
            (0, true, [UInt8(18), 0, 0, 0, 6, 1, 0, 0, 0, 1]),
            (1, true, [18, 0, 0, 0, 7, 1, 0, 0, 0, 1]),
            (2, true, [18, 0, 0, 0, 8, 1, 0, 0, 0, 1]),
            (3, true, [18, 0, 0, 0, 9, 1, 0, 0, 0, 1]),
            (0, false, [18, 0, 0, 0, 6, 3, 0, 0, 0, 1]),
            (1, false, [18, 0, 0, 0, 7, 3, 0, 0, 0, 1]),
            (2, false, [18, 0, 0, 0, 8, 3, 0, 0, 0, 1]),
            (3, false, [18, 0, 0, 0, 9, 3, 0, 0, 0, 1]),
        ]
    )
    func deviceChange(slot: Int, connected: Bool, expected: [UInt8]) {
        var bytes = [UInt8](repeating: 0, count: 10)
        bytes.withUnsafeMutableBytes {
            GFNSonyGamepad.writeDeviceChange(slot: slot, connected: connected, into: $0)
        }

        #expect(GFNSonyGamepad.deviceChangeSize == 10)
        #expect(bytes == expected)
    }

    @Test(
        "Face, shoulder, menu, stick-click, and guide controls retain Sony positions",
        arguments: [
            (UInt16(0x4000), [UInt8(0x18), 0, 0]),
            (0x1000, [0x28, 0, 0]),
            (0x2000, [0x48, 0, 0]),
            (0x8000, [0x88, 0, 0]),
            (0x0100, [8, 0x01, 0]),
            (0x0200, [8, 0x02, 0]),
            (0x0020, [8, 0x10, 0]),
            (0x0010, [8, 0x20, 0]),
            (0x0040, [8, 0x40, 0]),
            (0x0080, [8, 0x80, 0]),
            (0x0400, [8, 0, 1]),
            (0xF7F0, [0xF8, 0xF3, 1]),
        ] as [(UInt16, [UInt8])]
    )
    func controls(buttons: UInt16, expected: [UInt8]) {
        #expect(Array(report(buttons: buttons)[12 ... 14]) == expected)
    }

    @Test(
        "D-pad uses the DS4 clockwise hat codes and neutral value",
        arguments: [
            (UInt16(0), UInt8(8)),
            (0x0001, 0),
            (0x0009, 1),
            (0x0008, 2),
            (0x000A, 3),
            (0x0002, 4),
            (0x0006, 5),
            (0x0004, 6),
            (0x0005, 7),
        ]
    )
    func direction(buttons: UInt16, expected: UInt8) {
        #expect(report(buttons: buttons)[12] == expected)
    }

    @Test(
        "Triggers preserve analog values and set independent digital flags",
        arguments: [
            (UInt8(0), UInt8(0), UInt8(0)),
            (1, 0, 4),
            (0, 1, 8),
            (0x12, 0xFE, 0x0C),
        ]
    )
    func triggers(left: UInt8, right: UInt8, expectedFlags: UInt8) {
        let bytes = report(leftTrigger: left, rightTrigger: right)

        #expect(bytes[13] == expectedFlags)
        #expect(Array(bytes[15 ... 16]) == [left, right])
    }

    @Test(
        "Stick conversion centers axes and reverses XInput Y without overflow",
        arguments: [
            (Int16.min, [UInt8(0), 255, 0, 255]),
            (-16384, [63, 191, 63, 191]),
            (0, [127, 127, 127, 127]),
            (16384, [191, 63, 191, 63]),
            (.max, [255, 0, 255, 0]),
        ] as [(Int16, [UInt8])]
    )
    func sticks(value: Int16, expected: [UInt8]) {
        let bytes = report(leftStickX: value, leftStickY: value, rightStickX: value, rightStickY: value)

        #expect(Array(bytes[8 ... 11]) == expected)
    }

    @Test(
        "Gamepad catalog metadata permits Sony input while missing or unrelated controls do not",
        arguments: [
            (nil, false),
            ([], false),
            (["KEYBOARD", "MOUSE"], false),
            (["UNKNOWN_GAMEPAD"], false),
            (["DUALSHOCK4_GAMEPAD"], true),
            (["GAMEPAD"], true),
            (["KEYBOARD", "MOUSE", "GAMEPAD"], true),
        ] as [([String]?, Bool)]
    )
    func catalogControls(supportedControls: [String]?, expected: Bool) {
        #expect(GFNSonyGamepad.gameSupportsSonyInput(supportedControls) == expected)
    }

    @Test(
        "Generic gamepad metadata still requires protocol 3 and the server DS4 bit",
        arguments: [
            (2, UInt32(4), false),
            (3, 0, false),
            (3, 1, false),
            (3, 2, false),
            (3, 4, true),
        ]
    )
    func genericGamepadCapability(protocolVersion: Int, serverMask: UInt32, expected: Bool) {
        #expect(GFNSonyGamepad.isSupported(
            protocolVersion: protocolVersion,
            gameSupportsDualShock: GFNSonyGamepad.gameSupportsSonyInput(["KEYBOARD", "MOUSE", "GAMEPAD"]),
            serverHidMask: serverMask
        ) == expected)
    }

    @Test(
        "Controller type preference overrides the catalog's gamepad support",
        arguments: [
            (ControllerTypePreference.automatic, [String]?.none, false),
            (.automatic, ["KEYBOARD", "MOUSE"], false),
            (.automatic, ["GAMEPAD"], true),
            (.automatic, ["DUALSHOCK4_GAMEPAD"], true),
            (.xbox, ["DUALSHOCK4_GAMEPAD"], false),
            (.playStation, ["KEYBOARD", "MOUSE"], true),
            (.playStation, nil, true),
        ]
    )
    func controllerTypePreference(
        preference: ControllerTypePreference,
        supportedControls: [String]?,
        expected: Bool
    ) {
        #expect(GFNSonyGamepad.allowsSonyInput(
            preference: preference,
            supportedControls: supportedControls
        ) == expected)
    }

    @Test(
        "Answer mask and packet type follow the preference and the handshake version for a DS4 offer",
        arguments: [
            (ControllerTypePreference.xbox, 3, UInt32(0), false),
            (.xbox, 2, 0, false),
            (.playStation, 3, 4, true),
            // The answer goes out before the v2 handshake, so it still advertises DS4.
            (.playStation, 2, 4, false),
            (.automatic, 3, 4, true),
            (.automatic, 2, 4, false),
        ]
    )
    func answerAndPacketType(
        preference: ControllerTypePreference,
        protocolVersion: Int,
        expectedMask: UInt32,
        expectedSonyPackets: Bool
    ) {
        let serverOffer = GFNSonyGamepad.serverHidMask(in: "a=ri.hidDeviceMask:4\r\n")
        let allowsSonyInput = GFNSonyGamepad.allowsSonyInput(
            preference: preference,
            supportedControls: ["GAMEPAD"]
        )

        #expect(GFNSonyGamepad.answerHidMask(
            allowsSonyInput: allowsSonyInput,
            serverHidMask: serverOffer
        ) == expectedMask)
        #expect(GFNSonyGamepad.isSupported(
            protocolVersion: protocolVersion,
            gameSupportsDualShock: allowsSonyInput,
            serverHidMask: serverOffer
        ) == expectedSonyPackets)
    }

    @Test(
        "Sony admission requires protocol 3, game permission, and the server DS4 bit",
        arguments: [
            (2, true, UInt32(4), false),
            (3, false, 4, false),
            (3, true, 0, false),
            (3, true, 1, false),
            (3, true, 2, false),
            (3, true, 4, true),
            (3, true, 5, true),
            (4, true, 4, true),
        ]
    )
    func capability(protocolVersion: Int, gameSupportsDualShock: Bool, serverMask: UInt32, expected: Bool) {
        #expect(GFNSonyGamepad.isSupported(
            protocolVersion: protocolVersion,
            gameSupportsDualShock: gameSupportsDualShock,
            serverHidMask: serverMask
        ) == expected)
    }

    @Test(
        "SDP parsing accepts negotiated decimal and hexadecimal masks and rejects missing values",
        arguments: [
            (String?.none, UInt32(0)),
            ("", 0),
            ("a=ri.otherMask:4\r\n", 0),
            ("a=ri.hidDeviceMask:4\r\n", 4),
            ("v=0\r\na=ri.hidDeviceMask: 0x5 \r\n", 5),
            ("a=x-nv-ri.hidDeviceMask:0XFF\n", 255),
            ("a=ri.hidDeviceMask:invalid\n", 0),
            ("a=ri.hidDeviceMask:-1\n", 0),
            ("a=ri.hidDeviceMask:4294967296\n", 0),
        ]
    )
    func negotiatedServerMask(sdp: String?, expected: UInt32) {
        #expect(GFNSonyGamepad.serverHidMask(in: sdp) == expected)
    }

    private func report(
        slot: Int = 0,
        buttons: UInt16 = 0,
        leftTrigger: UInt8 = 0,
        rightTrigger: UInt8 = 0,
        leftStickX: Int16 = 0,
        leftStickY: Int16 = 0,
        rightStickX: Int16 = 0,
        rightStickY: Int16 = 0
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 71)
        bytes.withUnsafeMutableBytes {
            GFNSonyGamepad.writeReport(
                slot: slot,
                buttons: buttons,
                leftTrigger: leftTrigger,
                rightTrigger: rightTrigger,
                leftStickX: leftStickX,
                leftStickY: leftStickY,
                rightStickX: rightStickX,
                rightStickY: rightStickY,
                into: $0
            )
        }
        return bytes
    }
}
