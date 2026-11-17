import Foundation

/// The WebRTC input protocol's synthesized DualShock 4 device, also used for DualSense sources.
nonisolated enum GFNSonyGamepad {
    static let reportSize = 71
    static let deviceChangeSize = 10

    static func gameSupportsSonyInput(_ supportedControls: [String]?) -> Bool {
        supportedControls?.contains { $0 == "GAMEPAD" || $0 == "DUALSHOCK4_GAMEPAD" } == true
    }

    /// Whether this session may present a PlayStation controller. The server's DS4 bit is
    /// still required on top (see `isSupported`).
    static func allowsSonyInput(
        preference: ControllerTypePreference,
        supportedControls: [String]?
    ) -> Bool {
        switch preference {
        case .automatic: gameSupportsSonyInput(supportedControls)
        case .xbox: false
        case .playStation: true
        }
    }

    static func serverHidMask(in sdp: String?) -> UInt32 {
        guard let sdp else { return 0 }
        for line in sdp.split(whereSeparator: \.isNewline) {
            let prefixes = ["a=ri.hidDeviceMask:", "a=x-nv-ri.hidDeviceMask:"]
            guard let prefix = prefixes.first(where: { line.hasPrefix($0) }) else { continue }
            let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if value.lowercased().hasPrefix("0x") {
                return UInt32(value.dropFirst(2), radix: 16) ?? 0
            }
            return UInt32(value) ?? 0
        }
        return 0
    }

    /// The DS4 bit the NVST answer advertises. The answer is sent before the input handshake,
    /// so it can't depend on the protocol version that `isSupported` also requires.
    static func answerHidMask(allowsSonyInput: Bool, serverHidMask: UInt32) -> UInt32 {
        allowsSonyInput ? serverHidMask & 4 : 0
    }

    static func isSupported(protocolVersion: Int, gameSupportsDualShock: Bool, serverHidMask: UInt32) -> Bool {
        protocolVersion >= 3 && gameSupportsDualShock && serverHidMask & 4 != 0
    }

    static func writeDeviceChange(slot: Int, connected: Bool, into bytes: UnsafeMutableRawBufferPointer) {
        precondition((0 ..< 4).contains(slot) && bytes.count >= deviceChangeSize)
        bytes[0] = 18
        bytes[4] = UInt8(6 + slot)
        bytes[5] = connected ? 1 : 3
        bytes[9] = 1 // Device-change flags, big endian.
    }

    static func writeReport(
        slot: Int,
        buttons: UInt16,
        leftTrigger: UInt8,
        rightTrigger: UInt8,
        leftStickX: Int16,
        leftStickY: Int16,
        rightStickX: Int16,
        rightStickY: Int16,
        into bytes: UnsafeMutableRawBufferPointer
    ) {
        precondition((0 ..< 4).contains(slot) && bytes.count >= reportSize)
        bytes[0] = 17
        bytes[4] = UInt8(6 + slot)
        bytes[5] = 4 // Synthesized DS4 interface.
        let report = 7
        bytes[report] = 1
        bytes[report + 1] = axis(leftStickX)
        bytes[report + 2] = axis(leftStickY, inverted: true)
        bytes[report + 3] = axis(rightStickX)
        bytes[report + 4] = axis(rightStickY, inverted: true)
        bytes[report + 5] = direction(buttons)
            | (buttons & 0x4000 != 0 ? 0x10 : 0) // Square
            | (buttons & 0x1000 != 0 ? 0x20 : 0) // Cross
            | (buttons & 0x2000 != 0 ? 0x40 : 0) // Circle
            | (buttons & 0x8000 != 0 ? 0x80 : 0) // Triangle
        bytes[report + 6] = (buttons & 0x0100 != 0 ? 1 : 0)
            | (buttons & 0x0200 != 0 ? 2 : 0)
            | (leftTrigger > 0 ? 4 : 0)
            | (rightTrigger > 0 ? 8 : 0)
            | (buttons & 0x0020 != 0 ? 0x10 : 0)
            | (buttons & 0x0010 != 0 ? 0x20 : 0)
            | (buttons & 0x0040 != 0 ? 0x40 : 0)
            | (buttons & 0x0080 != 0 ? 0x80 : 0)
        bytes[report + 7] = buttons & 0x0400 != 0 ? 1 : 0
        bytes[report + 8] = leftTrigger
        bytes[report + 9] = rightTrigger
        bytes[report + 30] = 11
    }

    private static func axis(_ value: Int16, inverted: Bool = false) -> UInt8 {
        let signed = inverted ? -Int(value) : Int(value)
        return UInt8(clamping: (signed + 32768) * 255 / 65535)
    }

    private static func direction(_ buttons: UInt16) -> UInt8 {
        let up = buttons & 1 != 0
        let down = buttons & 2 != 0
        let left = buttons & 4 != 0
        let right = buttons & 8 != 0
        if up {
            return right ? 1 : left ? 7 : 0
        }
        if down {
            return right ? 3 : left ? 5 : 4
        }
        return right ? 2 : left ? 6 : 8
    }
}
