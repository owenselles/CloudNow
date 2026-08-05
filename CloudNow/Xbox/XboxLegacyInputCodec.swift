import Foundation

nonisolated struct XboxGamepadButtons: OptionSet, Equatable, Sendable {
    let rawValue: UInt16

    static let nexus = Self(rawValue: 1 << 1)
    static let menu = Self(rawValue: 1 << 2)
    static let view = Self(rawValue: 1 << 3)
    static let a = Self(rawValue: 1 << 4)
    static let b = Self(rawValue: 1 << 5)
    static let x = Self(rawValue: 1 << 6)
    static let y = Self(rawValue: 1 << 7)
    static let dpadUp = Self(rawValue: 1 << 8)
    static let dpadDown = Self(rawValue: 1 << 9)
    static let dpadLeft = Self(rawValue: 1 << 10)
    static let dpadRight = Self(rawValue: 1 << 11)
    static let leftShoulder = Self(rawValue: 1 << 12)
    static let rightShoulder = Self(rawValue: 1 << 13)
    static let leftThumbstick = Self(rawValue: 1 << 14)
    static let rightThumbstick = Self(rawValue: 1 << 15)
}

nonisolated struct XboxGamepadPhysicality: OptionSet, Equatable, Sendable {
    let rawValue: UInt32

    static let dpadUp = Self(rawValue: 1 << 0)
    static let dpadDown = Self(rawValue: 1 << 1)
    static let dpadLeft = Self(rawValue: 1 << 2)
    static let dpadRight = Self(rawValue: 1 << 3)
    static let menu = Self(rawValue: 1 << 4)
    static let view = Self(rawValue: 1 << 5)
    static let leftThumb = Self(rawValue: 1 << 6)
    static let rightThumb = Self(rawValue: 1 << 7)
    static let leftShoulder = Self(rawValue: 1 << 8)
    static let rightShoulder = Self(rawValue: 1 << 9)
    static let nexus = Self(rawValue: 1 << 10)
    static let a = Self(rawValue: 1 << 12)
    static let b = Self(rawValue: 1 << 13)
    static let x = Self(rawValue: 1 << 14)
    static let y = Self(rawValue: 1 << 15)
    static let leftTrigger = Self(rawValue: 1 << 16)
    static let rightTrigger = Self(rawValue: 1 << 17)
    static let leftThumbXAxis = Self(rawValue: 1 << 18)
    static let leftThumbYAxis = Self(rawValue: 1 << 19)
    static let rightThumbXAxis = Self(rawValue: 1 << 20)
    static let rightThumbYAxis = Self(rawValue: 1 << 21)
}

nonisolated struct XboxGamepadState: Equatable, Sendable {
    let index: UInt8
    let buttons: XboxGamepadButtons
    let leftThumbX: Int16
    let leftThumbY: Int16
    let rightThumbX: Int16
    let rightThumbY: Int16
    let leftTrigger: UInt16
    let rightTrigger: UInt16
    let physicalPhysicality: XboxGamepadPhysicality
    let virtualPhysicality: XboxGamepadPhysicality

    init(
        index: UInt8,
        buttons: XboxGamepadButtons = [],
        leftThumbX: Int16 = 0,
        leftThumbY: Int16 = 0,
        rightThumbX: Int16 = 0,
        rightThumbY: Int16 = 0,
        leftTrigger: UInt16 = 0,
        rightTrigger: UInt16 = 0,
        physicalPhysicality: XboxGamepadPhysicality = [],
        virtualPhysicality: XboxGamepadPhysicality = []
    ) {
        self.index = index
        self.buttons = buttons
        self.leftThumbX = leftThumbX
        self.leftThumbY = leftThumbY
        self.rightThumbX = rightThumbX
        self.rightThumbY = rightThumbY
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.physicalPhysicality = physicalPhysicality
        self.virtualPhysicality = virtualPhysicality
    }
}

nonisolated struct XboxRumbleCommand: Equatable, Sendable {
    let gamepadIndex: UInt8
    let leftMotorPercent: UInt8
    let rightMotorPercent: UInt8
    let leftTriggerMotorPercent: UInt8
    let rightTriggerMotorPercent: UInt8
    let durationMilliseconds: UInt16
    let delayMilliseconds: UInt16
    let repeatCount: UInt8
}

nonisolated enum XboxInputFeedback: Equatable, Sendable {
    case serverMetadata(height: UInt32, width: UInt32)
    case rumble(XboxRumbleCommand)
    case unreliableInputAcknowledgement(frameID: UInt32)
}

nonisolated enum XboxLegacyInputCodecError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion
    case tooManyGamepads
    case malformedFeedback
    case unsupportedFeedback

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "Xbox Cloud selected an unsupported input protocol version."
        case .tooManyGamepads:
            "Xbox Cloud input contains too many gamepads."
        case .malformedFeedback:
            "Xbox Cloud returned malformed input feedback."
        case .unsupportedFeedback:
            "Xbox Cloud returned unsupported input feedback."
        }
    }
}

/// Encodes the negotiated Xbox legacy input data channel without retaining
/// controller objects or allocating a second streaming runtime.
nonisolated struct XboxLegacyInputEncoder {
    private enum MessageFlag {
        static let gamepadReport: UInt16 = 1 << 1
        static let clientMetadata: UInt16 = 1 << 3
    }

    private(set) var inputToken: UInt32 = 0

    mutating func encodeClientMetadata(
        version: Int,
        maximumTouchPoints: UInt8 = 0,
        timestampMilliseconds: Double
    ) throws -> Data? {
        guard try validatedVersion(version) >= 3 else { return nil }
        var data = Data(capacity: headerSize(version: version) + 1)
        appendHeader(
            flags: MessageFlag.clientMetadata,
            version: version,
            timestampMilliseconds: timestampMilliseconds,
            to: &data
        )
        data.append(maximumTouchPoints)
        return data
    }

    mutating func encodeGamepads(
        _ gamepads: [XboxGamepadState],
        version: Int,
        timestampMilliseconds: Double
    ) throws -> Data {
        _ = try validatedVersion(version)
        guard gamepads.count <= 4 else {
            throw XboxLegacyInputCodecError.tooManyGamepads
        }

        let gamepadSize = version >= 2 ? 23 : 15
        var data = Data(
            capacity: headerSize(version: version) + 1 + gamepads.count * gamepadSize
        )
        appendHeader(
            flags: MessageFlag.gamepadReport,
            version: version,
            timestampMilliseconds: timestampMilliseconds,
            to: &data
        )
        data.append(UInt8(gamepads.count))
        for gamepad in gamepads {
            data.append(gamepad.index)
            data.appendLittleEndian(gamepad.buttons.rawValue)
            data.appendLittleEndian(gamepad.leftThumbX)
            data.appendLittleEndian(gamepad.leftThumbY)
            data.appendLittleEndian(gamepad.rightThumbX)
            data.appendLittleEndian(gamepad.rightThumbY)
            data.appendLittleEndian(gamepad.leftTrigger)
            data.appendLittleEndian(gamepad.rightTrigger)
            if version >= 2 {
                data.appendLittleEndian(gamepad.physicalPhysicality.rawValue)
                data.appendLittleEndian(gamepad.virtualPhysicality.rawValue)
            }
        }
        return data
    }

    private mutating func appendHeader(
        flags: UInt16,
        version: Int,
        timestampMilliseconds: Double,
        to data: inout Data
    ) {
        if version >= 8 {
            data.appendLittleEndian(flags)
        } else {
            data.append(UInt8(truncatingIfNeeded: flags))
        }
        data.appendLittleEndian(nextInputToken())
        if version >= 7 {
            data.appendLittleEndian(timestampMilliseconds.bitPattern)
        }
    }

    private mutating func nextInputToken() -> UInt32 {
        inputToken = inputToken == .max ? 0 : inputToken + 1
        return inputToken
    }

    private func validatedVersion(_ version: Int) throws -> Int {
        guard (1 ... 10).contains(version) else {
            throw XboxLegacyInputCodecError.unsupportedVersion
        }
        return version
    }

    private func headerSize(version: Int) -> Int {
        (version >= 8 ? 2 : 1) + 4 + (version >= 7 ? 8 : 0)
    }
}

nonisolated enum XboxLegacyInputFeedbackDecoder {
    private enum MessageFlag {
        static let serverMetadata: UInt16 = 1 << 4
        static let vibration: UInt16 = 1 << 7
        static let unreliableInputAcknowledgement: UInt16 = 1 << 10
    }

    static func decode(
        _ data: Data,
        version: Int
    ) throws -> XboxInputFeedback {
        guard (1 ... 10).contains(version) else {
            throw XboxLegacyInputCodecError.unsupportedVersion
        }
        var reader = XboxInputDataReader(data: data)
        let flags: UInt16 = if version >= 8 {
            try reader.readUInt16LittleEndian()
        } else {
            try UInt16(reader.readUInt8())
        }

        if flags & MessageFlag.serverMetadata != 0 {
            let height = try reader.readUInt32LittleEndian()
            let width = try reader.readUInt32LittleEndian()
            guard reader.isAtEnd else {
                throw XboxLegacyInputCodecError.malformedFeedback
            }
            return .serverMetadata(height: height, width: width)
        }

        if flags & MessageFlag.vibration != 0 {
            guard try reader.readUInt8() == 0 else {
                throw XboxLegacyInputCodecError.unsupportedFeedback
            }
            let command = try XboxRumbleCommand(
                gamepadIndex: reader.readUInt8(),
                leftMotorPercent: reader.readPercentage(),
                rightMotorPercent: reader.readPercentage(),
                leftTriggerMotorPercent: reader.readPercentage(),
                rightTriggerMotorPercent: reader.readPercentage(),
                durationMilliseconds: reader.readUInt16LittleEndian(),
                delayMilliseconds: reader.readUInt16LittleEndian(),
                repeatCount: reader.readUInt8()
            )
            guard reader.isAtEnd else {
                throw XboxLegacyInputCodecError.malformedFeedback
            }
            return .rumble(command)
        }

        if flags & MessageFlag.unreliableInputAcknowledgement != 0 {
            let frameID = try reader.readUInt32LittleEndian()
            guard reader.isAtEnd else {
                throw XboxLegacyInputCodecError.malformedFeedback
            }
            return .unreliableInputAcknowledgement(frameID: frameID)
        }

        throw XboxLegacyInputCodecError.unsupportedFeedback
    }
}

private nonisolated struct XboxInputDataReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool {
        offset == data.count
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw XboxLegacyInputCodecError.malformedFeedback
        }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readPercentage() throws -> UInt8 {
        let value = try readUInt8()
        guard value <= 100 else {
            throw XboxLegacyInputCodecError.malformedFeedback
        }
        return value
    }

    mutating func readUInt16LittleEndian() throws -> UInt16 {
        let byte0 = try UInt16(readUInt8())
        let byte1 = try UInt16(readUInt8())
        return byte0 | byte1 << 8
    }

    mutating func readUInt32LittleEndian() throws -> UInt32 {
        let byte0 = try UInt32(readUInt8())
        let byte1 = try UInt32(readUInt8())
        let byte2 = try UInt32(readUInt8())
        let byte3 = try UInt32(readUInt8())
        return byte0 | byte1 << 8 | byte2 << 16 | byte3 << 24
    }
}

private extension Data {
    nonisolated mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    nonisolated mutating func appendLittleEndian(_ value: Int16) {
        appendLittleEndian(UInt16(bitPattern: value))
    }

    nonisolated mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    nonisolated mutating func appendLittleEndian(_ value: UInt64) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 32))
        append(UInt8(truncatingIfNeeded: value >> 40))
        append(UInt8(truncatingIfNeeded: value >> 48))
        append(UInt8(truncatingIfNeeded: value >> 56))
    }
}
