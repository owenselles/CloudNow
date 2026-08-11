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
    static let share = Self(rawValue: 1 << 11)
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
    let isSharePressed: Bool
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
        isSharePressed: Bool = false,
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
        self.isSharePressed = isSharePressed
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

nonisolated enum XboxPointerPhase: UInt8, Equatable, Sendable {
    case unknown = 0
    case began = 1
    case ended = 2
    case moved = 3
}

/// One absolute pointer contact in Xbox Cloud's 20-byte wire layout.
nonisolated struct XboxPointerEvent: Equatable, Sendable {
    let contactWidth: UInt16
    let contactHeight: UInt16
    let pressure: UInt8
    let rotation: UInt16
    let pointerID: UInt32
    let x: UInt32
    let y: UInt32
    let phase: XboxPointerPhase

    init(
        contactWidth: UInt16 = 0,
        contactHeight: UInt16 = 0,
        pressure: UInt8 = 0,
        rotation: UInt16 = 0,
        pointerID: UInt32 = 0,
        x: UInt32,
        y: UInt32,
        phase: XboxPointerPhase
    ) {
        self.contactWidth = contactWidth
        self.contactHeight = contactHeight
        self.pressure = pressure
        self.rotation = rotation
        self.pointerID = pointerID
        self.x = x
        self.y = y
        self.phase = phase
    }
}

/// Xbox groups simultaneous contacts into one pointer frame.
nonisolated struct XboxPointerFrame: Equatable, Sendable {
    let events: [XboxPointerEvent]
}

nonisolated struct XboxMouseButtons: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let left = Self(rawValue: 1 << 0)
    static let right = Self(rawValue: 1 << 1)
    static let middle = Self(rawValue: 1 << 2)
    static let auxiliary1 = Self(rawValue: 1 << 3)
    static let auxiliary2 = Self(rawValue: 1 << 4)
}

/// Relative mouse report used by both negotiated Xbox input transports.
nonisolated struct XboxMouseReport: Equatable, Sendable {
    let x: Int32
    let y: Int32
    let wheelX: Int32
    let wheelY: Int32
    let buttons: XboxMouseButtons
    let isRelative: Bool

    init(
        x: Int32 = 0,
        y: Int32 = 0,
        wheelX: Int32 = 0,
        wheelY: Int32 = 0,
        buttons: XboxMouseButtons = [],
        isRelative: Bool = true
    ) {
        self.x = x
        self.y = y
        self.wheelX = wheelX
        self.wheelY = wheelY
        self.buttons = buttons
        self.isRelative = isRelative
    }
}

nonisolated enum XboxKeyboardKeyType: UInt8, Equatable, Sendable {
    case unknown = 0
    case known = 1
    case virtualKey = 2
    case appCommand = 3
}

/// One key transition. `keyCode` is a Windows virtual-key code when `type` is
/// `.virtualKey`, matching Xbox Cloud's browser protocol.
nonisolated struct XboxKeyboardReport: Equatable, Sendable {
    let type: XboxKeyboardKeyType
    let isPressed: Bool
    let keyCode: UInt8

    init(
        type: XboxKeyboardKeyType = .virtualKey,
        isPressed: Bool,
        keyCode: UInt8
    ) {
        self.type = type
        self.isPressed = isPressed
        self.keyCode = keyCode
    }
}

/// Provider boundary consumed by physical input handlers and future UIKit
/// text/pointer bridges. Empty sections are omitted from legacy reports and
/// represented by zero counts in modern reports.
nonisolated struct XboxPeripheralInputReport: Equatable, Sendable {
    var pointerFrames: [XboxPointerFrame]
    var keyboard: [XboxKeyboardReport]
    var mouse: [XboxMouseReport]

    init(
        pointerFrames: [XboxPointerFrame] = [],
        keyboard: [XboxKeyboardReport] = [],
        mouse: [XboxMouseReport] = []
    ) {
        self.pointerFrames = pointerFrames
        self.keyboard = keyboard
        self.mouse = mouse
    }

    var isEmpty: Bool {
        pointerFrames.isEmpty && keyboard.isEmpty && mouse.isEmpty
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
    case tooManyPeripheralEvents
    case malformedFeedback
    case unsupportedFeedback

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "Xbox Cloud selected an unsupported input protocol version."
        case .tooManyGamepads:
            "Xbox Cloud input contains too many gamepads."
        case .tooManyPeripheralEvents:
            "Xbox Cloud input contains too many pointer, keyboard, or mouse events."
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
        static let pointerReport: UInt16 = 1 << 2
        static let clientMetadata: UInt16 = 1 << 3
        static let mouseReport: UInt16 = 1 << 5
        static let keyboardReport: UInt16 = 1 << 6
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
        try encodeInput(
            gamepads: gamepads,
            version: version,
            timestampMilliseconds: timestampMilliseconds,
            includesEmptyGamepadSection: true
        )
    }

    mutating func encodeInput(
        gamepads: [XboxGamepadState] = [],
        peripherals: XboxPeripheralInputReport = .init(),
        version: Int,
        timestampMilliseconds: Double
    ) throws -> Data {
        try encodeInput(
            gamepads: gamepads,
            peripherals: peripherals,
            version: version,
            timestampMilliseconds: timestampMilliseconds,
            includesEmptyGamepadSection: false
        )
    }

    private mutating func encodeInput(
        gamepads: [XboxGamepadState],
        peripherals: XboxPeripheralInputReport = .init(),
        version: Int,
        timestampMilliseconds: Double,
        includesEmptyGamepadSection: Bool
    ) throws -> Data {
        _ = try validatedVersion(version)
        guard gamepads.count
            <= XboxCloudCompatibilityProfile.bundledV1.maximumControllerSlots
        else {
            throw XboxLegacyInputCodecError.tooManyGamepads
        }
        try validatePeripheralCounts(peripherals)

        let gamepadSize = version >= 2 ? 23 : 15
        let pointerSize = 1 + peripherals.pointerFrames.reduce(0) {
            $0 + 1 + $1.events.count * 20
        }
        let mouseSize = 1 + peripherals.mouse.count * 18
        let keyboardSize = 1 + peripherals.keyboard.count * 3
        var data = Data(
            capacity: headerSize(version: version)
                + (gamepads.isEmpty && !includesEmptyGamepadSection
                    ? 0
                    : 1 + gamepads.count * gamepadSize)
                + (peripherals.pointerFrames.isEmpty ? 0 : pointerSize)
                + (peripherals.mouse.isEmpty ? 0 : mouseSize)
                + (peripherals.keyboard.isEmpty ? 0 : keyboardSize)
        )
        var flags: UInt16 = 0
        if !gamepads.isEmpty || includesEmptyGamepadSection {
            flags |= MessageFlag.gamepadReport
        }
        if !peripherals.pointerFrames.isEmpty {
            flags |= MessageFlag.pointerReport
        }
        if !peripherals.mouse.isEmpty {
            flags |= MessageFlag.mouseReport
        }
        if !peripherals.keyboard.isEmpty {
            flags |= MessageFlag.keyboardReport
        }
        appendHeader(
            flags: flags,
            version: version,
            timestampMilliseconds: timestampMilliseconds,
            to: &data
        )
        appendGamepads(
            gamepads,
            version: version,
            includesEmptySection: includesEmptyGamepadSection,
            to: &data
        )
        appendPointerFrames(peripherals.pointerFrames, to: &data)
        appendMouseReports(peripherals.mouse, to: &data)
        appendKeyboardReports(peripherals.keyboard, to: &data)
        return data
    }

    /// Reserves the next token for the modern unreliable-input encoder while
    /// keeping reliable metadata and state reports on one sequence.
    mutating func reserveInputToken() -> UInt32 {
        nextInputToken()
    }

    private func appendGamepads(
        _ gamepads: [XboxGamepadState],
        version: Int,
        includesEmptySection: Bool,
        to data: inout Data
    ) {
        guard !gamepads.isEmpty || includesEmptySection else { return }
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
    }

    private func appendPointerFrames(
        _ frames: [XboxPointerFrame],
        to data: inout Data
    ) {
        guard !frames.isEmpty else { return }
        data.append(UInt8(frames.count))
        for frame in frames {
            data.append(UInt8(frame.events.count))
            for event in frame.events {
                data.appendLittleEndian(event.contactWidth)
                data.appendLittleEndian(event.contactHeight)
                data.append(event.pressure)
                data.appendLittleEndian(event.rotation)
                data.appendLittleEndian(event.pointerID)
                data.appendLittleEndian(event.x)
                data.appendLittleEndian(event.y)
                data.append(event.phase.rawValue)
            }
        }
    }

    private func appendMouseReports(
        _ reports: [XboxMouseReport],
        to data: inout Data
    ) {
        guard !reports.isEmpty else { return }
        data.append(UInt8(reports.count))
        for report in reports {
            data.appendLittleEndian(report.x)
            data.appendLittleEndian(report.y)
            data.appendLittleEndian(report.wheelX)
            data.appendLittleEndian(report.wheelY)
            data.append(report.buttons.rawValue)
            data.append(report.isRelative ? 1 : 0)
        }
    }

    private func appendKeyboardReports(
        _ reports: [XboxKeyboardReport],
        to data: inout Data
    ) {
        guard !reports.isEmpty else { return }
        data.append(UInt8(reports.count))
        for report in reports {
            data.append(report.type.rawValue)
            data.append(report.isPressed ? 1 : 0)
            data.append(report.keyCode)
        }
    }

    private func validatePeripheralCounts(
        _ peripherals: XboxPeripheralInputReport
    ) throws {
        guard peripherals.pointerFrames.count <= Int(UInt8.max),
              peripherals.pointerFrames.allSatisfy({
                  $0.events.count <= Int(UInt8.max)
              }),
              peripherals.keyboard.count <= Int(UInt8.max),
              peripherals.mouse.count <= Int(UInt8.max)
        else {
            throw XboxLegacyInputCodecError.tooManyPeripheralEvents
        }
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

    nonisolated mutating func appendLittleEndian(_ value: Int32) {
        appendLittleEndian(UInt32(bitPattern: value))
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
