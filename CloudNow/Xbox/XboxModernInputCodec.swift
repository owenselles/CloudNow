import Foundation

nonisolated enum XboxModernInputCodecError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion
    case tooManyGamepads
    case tooManyPeripheralEvents

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "Xbox Cloud selected an unsupported modern input protocol version."
        case .tooManyGamepads:
            "Xbox Cloud modern input contains too many gamepads."
        case .tooManyPeripheralEvents:
            "Xbox Cloud modern input contains too many peripheral events."
        }
    }
}

/// Per-button transition counters used by Xbox Cloud's unreliable input path.
/// The wire order is defined by `XboxModernInputEncoder` and must not be
/// inferred from `XboxGamepadButtons.rawValue`.
nonisolated struct XboxModernGamepadTransitionCounters: Equatable, Sendable {
    private(set) var dpadUp: UInt8
    private(set) var dpadDown: UInt8
    private(set) var dpadLeft: UInt8
    private(set) var dpadRight: UInt8
    private(set) var menu: UInt8
    private(set) var view: UInt8
    private(set) var leftThumb: UInt8
    private(set) var rightThumb: UInt8
    private(set) var leftShoulder: UInt8
    private(set) var rightShoulder: UInt8
    private(set) var nexus: UInt8
    private(set) var share: UInt8
    private(set) var a: UInt8
    private(set) var b: UInt8
    private(set) var x: UInt8
    private(set) var y: UInt8

    init(
        dpadUp: UInt8 = 0,
        dpadDown: UInt8 = 0,
        dpadLeft: UInt8 = 0,
        dpadRight: UInt8 = 0,
        menu: UInt8 = 0,
        view: UInt8 = 0,
        leftThumb: UInt8 = 0,
        rightThumb: UInt8 = 0,
        leftShoulder: UInt8 = 0,
        rightShoulder: UInt8 = 0,
        nexus: UInt8 = 0,
        share: UInt8 = 0,
        a: UInt8 = 0,
        b: UInt8 = 0,
        x: UInt8 = 0,
        y: UInt8 = 0
    ) {
        self.dpadUp = dpadUp
        self.dpadDown = dpadDown
        self.dpadLeft = dpadLeft
        self.dpadRight = dpadRight
        self.menu = menu
        self.view = view
        self.leftThumb = leftThumb
        self.rightThumb = rightThumb
        self.leftShoulder = leftShoulder
        self.rightShoulder = rightShoulder
        self.nexus = nexus
        self.share = share
        self.a = a
        self.b = b
        self.x = x
        self.y = y
    }

    mutating func recordTransitions(
        from previous: XboxGamepadButtons,
        to current: XboxGamepadButtons,
        shareWasPressed: Bool = false,
        shareIsPressed: Bool = false
    ) {
        dpadUp = Self.advanced(dpadUp, button: .dpadUp, from: previous, to: current)
        dpadDown = Self.advanced(dpadDown, button: .dpadDown, from: previous, to: current)
        dpadLeft = Self.advanced(dpadLeft, button: .dpadLeft, from: previous, to: current)
        dpadRight = Self.advanced(dpadRight, button: .dpadRight, from: previous, to: current)
        menu = Self.advanced(menu, button: .menu, from: previous, to: current)
        view = Self.advanced(view, button: .view, from: previous, to: current)
        leftThumb = Self.advanced(leftThumb, button: .leftThumbstick, from: previous, to: current)
        rightThumb = Self.advanced(rightThumb, button: .rightThumbstick, from: previous, to: current)
        leftShoulder = Self.advanced(leftShoulder, button: .leftShoulder, from: previous, to: current)
        rightShoulder = Self.advanced(rightShoulder, button: .rightShoulder, from: previous, to: current)
        nexus = Self.advanced(nexus, button: .nexus, from: previous, to: current)
        if shareWasPressed != shareIsPressed {
            share &+= 1
        }
        a = Self.advanced(a, button: .a, from: previous, to: current)
        b = Self.advanced(b, button: .b, from: previous, to: current)
        x = Self.advanced(x, button: .x, from: previous, to: current)
        y = Self.advanced(y, button: .y, from: previous, to: current)
    }

    private static func advanced(
        _ counter: UInt8,
        button: XboxGamepadButtons,
        from previous: XboxGamepadButtons,
        to current: XboxGamepadButtons
    ) -> UInt8 {
        guard previous.contains(button) != current.contains(button) else {
            return counter
        }
        return counter &+ 1
    }
}

nonisolated struct XboxModernGamepadReport: Equatable, Sendable {
    let index: UInt8
    let transitionCounters: XboxModernGamepadTransitionCounters
    let leftTrigger: UInt16
    let rightTrigger: UInt16
    let leftThumbX: Int16
    let leftThumbY: Int16
    let rightThumbX: Int16
    let rightThumbY: Int16
    let physicalPhysicality: XboxGamepadPhysicality
    let virtualPhysicality: XboxGamepadPhysicality

    init(
        index: UInt8 = 0,
        transitionCounters: XboxModernGamepadTransitionCounters = .init(),
        leftTrigger: UInt16 = 0,
        rightTrigger: UInt16 = 0,
        leftThumbX: Int16 = 0,
        leftThumbY: Int16 = 0,
        rightThumbX: Int16 = 0,
        rightThumbY: Int16 = 0,
        physicalPhysicality: XboxGamepadPhysicality = [],
        virtualPhysicality: XboxGamepadPhysicality = []
    ) {
        self.index = index
        self.transitionCounters = transitionCounters
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.leftThumbX = leftThumbX
        self.leftThumbY = leftThumbY
        self.rightThumbX = rightThumbX
        self.rightThumbY = rightThumbY
        self.physicalPhysicality = physicalPhysicality
        self.virtualPhysicality = virtualPhysicality
    }
}

nonisolated struct XboxModernInputFrame: Equatable, Sendable {
    let frameID: UInt32
    let gamepads: [XboxModernGamepadReport]
    let peripherals: XboxPeripheralInputReport

    init(
        frameID: UInt32,
        gamepads: [XboxModernGamepadReport],
        peripherals: XboxPeripheralInputReport = .init()
    ) {
        self.frameID = frameID
        self.gamepads = gamepads
        self.peripherals = peripherals
    }

    init(
        frameID: UInt32,
        gamepad: XboxModernGamepadReport
    ) {
        self.init(frameID: frameID, gamepads: [gamepad])
    }

    /// Compatibility accessor for single-controller call sites.
    var gamepad: XboxModernGamepadReport {
        gamepads.first ?? XboxModernGamepadReport()
    }
}

/// Matches Xbox's current unreliable-input pacing: changed frames may be sent
/// on the 8 ms sampling cadence, while an unacknowledged frame is retried no
/// more often than every 16 ms.
nonisolated struct XboxModernInputSendCadence: Sendable {
    static let minimumChangedFrameIntervalNanoseconds: UInt64 = 8_000_000
    static let retransmissionIntervalNanoseconds: UInt64 = 16_000_000

    private var lastAcceptedFrameID: UInt32?
    private var lastAcceptedSendNanoseconds: UInt64?

    func canAttempt(frameID: UInt32, at timestampNanoseconds: UInt64) -> Bool {
        guard let lastAcceptedSendNanoseconds else { return true }
        guard timestampNanoseconds >= lastAcceptedSendNanoseconds else {
            return false
        }
        let minimumInterval = frameID == lastAcceptedFrameID
            ? Self.retransmissionIntervalNanoseconds
            : Self.minimumChangedFrameIntervalNanoseconds
        return timestampNanoseconds - lastAcceptedSendNanoseconds
            >= minimumInterval
    }

    mutating func recordAccepted(
        frameID: UInt32,
        at timestampNanoseconds: UInt64
    ) {
        lastAcceptedFrameID = frameID
        lastAcceptedSendNanoseconds = timestampNanoseconds
    }

    mutating func reset() {
        self = Self()
    }
}

/// Encodes the profile's stable-index gamepad capacity for the negotiated
/// unreliable-input channel. The caller supplies the shared input token so
/// reliable metadata and unreliable reports can use one token sequence.
nonisolated enum XboxModernInputEncoder {
    private enum MessageFlag {
        static let unreliableInputReport: UInt16 = 1 << 9
    }

    static func encode(
        _ frame: XboxModernInputFrame,
        version: Int,
        inputToken: UInt32,
        timestampMilliseconds: Double
    ) throws -> Data {
        guard (9 ... 10).contains(version) else {
            throw XboxModernInputCodecError.unsupportedVersion
        }
        guard frame.gamepads.count
            <= XboxCloudCompatibilityProfile.bundledV1.maximumControllerSlots
        else {
            throw XboxModernInputCodecError.tooManyGamepads
        }
        guard frame.peripherals.pointerFrames.count <= Int(UInt8.max),
              frame.peripherals.pointerFrames.allSatisfy({
                  $0.events.count <= Int(UInt8.max)
              }),
              frame.peripherals.keyboard.count <= Int(UInt8.max),
              frame.peripherals.mouse.count <= Int(UInt8.max)
        else {
            throw XboxModernInputCodecError.tooManyPeripheralEvents
        }

        let pointerBytes = frame.peripherals.pointerFrames.reduce(0) {
            $0 + 1 + $1.events.count * 20
        }
        let capacity = 24
            + frame.gamepads.count * 37
            + pointerBytes
            + frame.peripherals.keyboard.count * 3
            + frame.peripherals.mouse.count * 18
            + (version >= 10 ? 1 : 0)
        var data = Data(capacity: capacity)
        data.appendXboxLittleEndian(MessageFlag.unreliableInputReport)
        data.appendXboxLittleEndian(inputToken)
        data.appendXboxLittleEndian(timestampMilliseconds.bitPattern)
        data.appendXboxLittleEndian(frame.frameID)
        data.append(UInt8(frame.gamepads.count))
        for gamepad in frame.gamepads {
            appendGamepad(gamepad, to: &data)
        }
        appendPointerFrames(frame.peripherals.pointerFrames, to: &data)
        appendKeyboardReports(frame.peripherals.keyboard, to: &data)
        appendMouseReports(frame.peripherals.mouse, to: &data)
        if version >= 10 {
            data.append(0) // Lock-key state absent.
        }
        data.append(0) // Sensor count.
        return data
    }

    private static func appendGamepad(
        _ gamepad: XboxModernGamepadReport,
        to data: inout Data
    ) {
        data.append(gamepad.index)

        let counters = gamepad.transitionCounters
        data.append(counters.dpadUp)
        data.append(counters.dpadDown)
        data.append(counters.dpadLeft)
        data.append(counters.dpadRight)
        data.append(counters.menu)
        data.append(counters.view)
        data.append(counters.leftThumb)
        data.append(counters.rightThumb)
        data.append(counters.leftShoulder)
        data.append(counters.rightShoulder)
        data.append(counters.nexus)
        data.append(counters.share)
        data.append(counters.a)
        data.append(counters.b)
        data.append(counters.x)
        data.append(counters.y)

        data.appendXboxLittleEndian(gamepad.leftTrigger)
        data.appendXboxLittleEndian(gamepad.rightTrigger)
        data.appendXboxLittleEndian(gamepad.leftThumbX)
        data.appendXboxLittleEndian(gamepad.leftThumbY)
        data.appendXboxLittleEndian(gamepad.rightThumbX)
        data.appendXboxLittleEndian(gamepad.rightThumbY)
        data.appendXboxLittleEndian(gamepad.physicalPhysicality.rawValue)
        data.appendXboxLittleEndian(gamepad.virtualPhysicality.rawValue)
    }

    private static func appendPointerFrames(
        _ frames: [XboxPointerFrame],
        to data: inout Data
    ) {
        data.append(UInt8(frames.count))
        for frame in frames {
            data.append(UInt8(frame.events.count))
            for event in frame.events {
                data.appendXboxLittleEndian(event.contactWidth)
                data.appendXboxLittleEndian(event.contactHeight)
                data.append(event.pressure)
                data.appendXboxLittleEndian(event.rotation)
                data.appendXboxLittleEndian(event.pointerID)
                data.appendXboxLittleEndian(event.x)
                data.appendXboxLittleEndian(event.y)
                data.append(event.phase.rawValue)
            }
        }
    }

    private static func appendKeyboardReports(
        _ reports: [XboxKeyboardReport],
        to data: inout Data
    ) {
        data.append(UInt8(reports.count))
        for report in reports {
            data.append(report.type.rawValue)
            data.append(report.isPressed ? 1 : 0)
            data.append(report.keyCode)
        }
    }

    private static func appendMouseReports(
        _ reports: [XboxMouseReport],
        to data: inout Data
    ) {
        data.append(UInt8(reports.count))
        for report in reports {
            data.appendXboxLittleEndian(report.x)
            data.appendXboxLittleEndian(report.y)
            data.appendXboxLittleEndian(report.wheelX)
            data.appendXboxLittleEndian(report.wheelY)
            data.append(report.buttons.rawValue)
            data.append(report.isRelative ? 1 : 0)
        }
    }
}

/// Tracks the latest unreliable gamepad state until the server acknowledges
/// it. At most 120 snapshots are retained, bounding memory even if feedback is
/// delayed or absent.
nonisolated struct XboxModernInputStateTracker: Sendable {
    static let maximumPendingSnapshotCount = 120
    private static let controllerCapacity = XboxCloudCompatibilityProfile
        .bundledV1.maximumControllerSlots

    private struct ControllerState: Sendable {
        var state: XboxGamepadState
        var transitionCounters = XboxModernGamepadTransitionCounters()
    }

    private(set) var lastAcknowledgedFrameID: UInt32?

    private var latestFrameID: UInt32 = 0
    private var controllers: [ControllerState?] = Array(
        repeating: nil,
        count: controllerCapacity
    )
    private var pendingSnapshots: [XboxModernInputFrame] = []

    var isAttached: Bool {
        controllers.contains { $0 != nil }
    }

    var attachedIndexes: [UInt8] {
        controllers.indices.compactMap { index in
            controllers[index] == nil ? nil : UInt8(index)
        }
    }

    var pendingSnapshotCount: Int {
        pendingSnapshots.count
    }

    init() {
        pendingSnapshots.reserveCapacity(Self.maximumPendingSnapshotCount)
    }

    /// Starts or restarts one physical-controller attachment. Other slots and
    /// their transition counters remain intact across hot-plug events.
    @discardableResult
    mutating func attach(index: UInt8 = 0) -> XboxModernInputFrame {
        let slot = Int(index)
        precondition(controllers.indices.contains(slot))
        controllers[slot] = ControllerState(
            state: XboxGamepadState(index: index)
        )
        return appendSnapshot()
    }

    /// Records one sampled physical state. Unchanged samples do not allocate a
    /// new frame; `frameForTransmission()` continues returning the same newest
    /// unacknowledged frame for retransmission.
    @discardableResult
    mutating func record(_ state: XboxGamepadState) -> XboxModernInputFrame? {
        let index = Int(state.index)
        guard controllers.indices.contains(index),
              var controller = controllers[index]
        else {
            return nil
        }
        let normalizedState = Self.normalized(state)
        guard normalizedState != controller.state else { return nil }

        controller.transitionCounters.recordTransitions(
            from: controller.state.buttons,
            to: normalizedState.buttons,
            shareWasPressed: controller.state.isSharePressed,
            shareIsPressed: normalizedState.isSharePressed
        )
        controller.state = normalizedState
        controllers[index] = controller
        return appendSnapshot()
    }

    /// Atomically records a complete sample so one V2 frame can contain every
    /// negotiated controller slot without transient partial snapshots.
    @discardableResult
    mutating func record(
        _ states: [XboxGamepadState],
        peripherals: XboxPeripheralInputReport = .init()
    ) -> XboxModernInputFrame? {
        var didChange = !peripherals.isEmpty
        for state in states {
            let index = Int(state.index)
            guard controllers.indices.contains(index),
                  var controller = controllers[index]
            else {
                continue
            }
            let normalizedState = Self.normalized(state)
            guard normalizedState != controller.state else { continue }
            controller.transitionCounters.recordTransitions(
                from: controller.state.buttons,
                to: normalizedState.buttons,
                shareWasPressed: controller.state.isSharePressed,
                shareIsPressed: normalizedState.isSharePressed
            )
            controller.state = normalizedState
            controllers[index] = controller
            didChange = true
        }
        guard didChange else { return nil }
        return appendSnapshot(peripherals: peripherals)
    }

    /// Queues keyboard/mouse/pointer input without manufacturing controller
    /// motion. The frame remains retransmittable until acknowledged.
    @discardableResult
    mutating func record(
        peripherals: XboxPeripheralInputReport
    ) -> XboxModernInputFrame? {
        guard !peripherals.isEmpty else { return nil }
        return appendSnapshot(peripherals: peripherals)
    }

    func frameForTransmission() -> XboxModernInputFrame? {
        pendingSnapshots.last
    }

    /// Accepts only acknowledgements still represented by the bounded history.
    /// Acknowledging an older frame preserves every newer pending snapshot.
    @discardableResult
    mutating func acknowledge(frameID: UInt32) -> Bool {
        guard let index = pendingSnapshots.firstIndex(where: {
            $0.frameID == frameID
        }) else {
            return false
        }
        pendingSnapshots.removeFirst(index + 1)
        lastAcknowledgedFrameID = frameID
        return true
    }

    /// Removes one controller without reindexing the remaining slots.
    @discardableResult
    mutating func detach(index: UInt8 = 0) -> XboxModernInputFrame? {
        let slot = Int(index)
        guard controllers.indices.contains(slot), controllers[slot] != nil else {
            return nil
        }
        controllers[slot] = nil
        return appendSnapshot()
    }

    /// Clears all session state. The next attachment begins again at frame 1.
    mutating func reset() {
        for index in controllers.indices {
            controllers[index] = nil
        }
        pendingSnapshots.removeAll(keepingCapacity: true)
        lastAcknowledgedFrameID = nil
        latestFrameID = 0
    }

    private mutating func appendSnapshot(
        peripherals: XboxPeripheralInputReport = .init()
    ) -> XboxModernInputFrame {
        let frame = XboxModernInputFrame(
            frameID: nextFrameID(),
            gamepads: controllers.compactMap { controller in
                guard let controller else { return nil }
                let state = controller.state
                return XboxModernGamepadReport(
                    index: state.index,
                    transitionCounters: controller.transitionCounters,
                    leftTrigger: state.leftTrigger,
                    rightTrigger: state.rightTrigger,
                    leftThumbX: state.leftThumbX,
                    leftThumbY: state.leftThumbY,
                    rightThumbX: state.rightThumbX,
                    rightThumbY: state.rightThumbY,
                    physicalPhysicality: state.physicalPhysicality,
                    virtualPhysicality: state.virtualPhysicality
                )
            },
            peripherals: peripherals
        )
        pendingSnapshots.append(frame)
        if pendingSnapshots.count > Self.maximumPendingSnapshotCount {
            pendingSnapshots.removeFirst(
                pendingSnapshots.count - Self.maximumPendingSnapshotCount
            )
        }
        return frame
    }

    private mutating func nextFrameID() -> UInt32 {
        latestFrameID = latestFrameID == .max ? 0 : latestFrameID + 1
        return latestFrameID
    }

    private static func normalized(
        _ state: XboxGamepadState
    ) -> XboxGamepadState {
        XboxGamepadState(
            index: state.index,
            buttons: state.buttons,
            isSharePressed: state.isSharePressed,
            leftThumbX: state.leftThumbX,
            leftThumbY: state.leftThumbY,
            rightThumbX: state.rightThumbX,
            rightThumbY: state.rightThumbY,
            leftTrigger: state.leftTrigger,
            rightTrigger: state.rightTrigger,
            physicalPhysicality: state.physicalPhysicality,
            virtualPhysicality: state.virtualPhysicality
        )
    }
}

private extension Data {
    nonisolated mutating func appendXboxLittleEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    nonisolated mutating func appendXboxLittleEndian(_ value: Int16) {
        appendXboxLittleEndian(UInt16(bitPattern: value))
    }

    nonisolated mutating func appendXboxLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    nonisolated mutating func appendXboxLittleEndian(_ value: Int32) {
        appendXboxLittleEndian(UInt32(bitPattern: value))
    }

    nonisolated mutating func appendXboxLittleEndian(_ value: UInt64) {
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
