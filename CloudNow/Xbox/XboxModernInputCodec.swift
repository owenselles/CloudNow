import Foundation

nonisolated enum XboxModernInputCodecError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "Xbox Cloud selected an unsupported modern input protocol version."
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
        to current: XboxGamepadButtons
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
    let gamepad: XboxModernGamepadReport
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

/// Encodes one slot-zero gamepad snapshot for the negotiated unreliable-input
/// channel. The caller supplies the shared input token so reliable metadata and
/// unreliable reports can use one token sequence.
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

        var data = Data(capacity: version >= 10 ? 61 : 60)
        data.appendXboxLittleEndian(MessageFlag.unreliableInputReport)
        data.appendXboxLittleEndian(inputToken)
        data.appendXboxLittleEndian(timestampMilliseconds.bitPattern)
        data.appendXboxLittleEndian(frame.frameID)
        data.append(1)
        appendGamepad(frame.gamepad, to: &data)
        data.append(0) // Pointer count.
        data.append(0) // Keyboard absent.
        data.append(0) // Mouse absent.
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
        data.append(0) // Modern Xbox Cloud input maps the active pad to slot 0.

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
}

/// Tracks the latest unreliable gamepad state until the server acknowledges
/// it. At most 120 snapshots are retained, bounding memory even if feedback is
/// delayed or absent.
nonisolated struct XboxModernInputStateTracker: Sendable {
    static let maximumPendingSnapshotCount = 120

    private(set) var isAttached = false
    private(set) var lastAcknowledgedFrameID: UInt32?

    private var latestFrameID: UInt32 = 0
    private var previousState: XboxGamepadState?
    private var transitionCounters = XboxModernGamepadTransitionCounters()
    private var pendingSnapshots: [XboxModernInputFrame] = []

    var pendingSnapshotCount: Int {
        pendingSnapshots.count
    }

    init() {
        pendingSnapshots.reserveCapacity(Self.maximumPendingSnapshotCount)
    }

    /// Starts or restarts one physical-controller attachment. Frame IDs remain
    /// monotonic across hotplug events, while controller counters restart from
    /// a neutral state.
    @discardableResult
    mutating func attach() -> XboxModernInputFrame {
        clearControllerState()
        isAttached = true
        return appendSnapshot(for: XboxGamepadState(index: 0))
    }

    /// Records one sampled physical state. Unchanged samples do not allocate a
    /// new frame; `frameForTransmission()` continues returning the same newest
    /// unacknowledged frame for retransmission.
    @discardableResult
    mutating func record(_ state: XboxGamepadState) -> XboxModernInputFrame? {
        guard isAttached else { return nil }
        let normalizedState = Self.normalized(state)
        guard normalizedState != previousState else { return nil }

        transitionCounters.recordTransitions(
            from: previousState?.buttons ?? [],
            to: normalizedState.buttons
        )
        return appendSnapshot(for: normalizedState)
    }

    /// Produces the tiny virtual-axis delta used by Xbox's current client to
    /// keep an otherwise idle V2 input session alive. The next physical sample
    /// restores the real axis without changing button transition counters.
    @discardableResult
    mutating func recordVirtualKeepAlive() -> XboxModernInputFrame? {
        guard isAttached, let previousState else { return nil }
        let delta = 3277 // Approximately ten percent of the Int16 axis range.
        let threshold = 29490 // Approximately ninety percent of the range.
        let currentX = Int(previousState.leftThumbX)
        let adjustedX = currentX > threshold
            ? currentX - delta
            : currentX + delta
        let boundedX = min(max(adjustedX, -32767), 32767)
        return appendSnapshot(for: XboxGamepadState(
            index: 0,
            buttons: previousState.buttons,
            leftThumbX: Int16(boundedX),
            leftThumbY: previousState.leftThumbY,
            rightThumbX: previousState.rightThumbX,
            rightThumbY: previousState.rightThumbY,
            leftTrigger: previousState.leftTrigger,
            rightTrigger: previousState.rightTrigger,
            physicalPhysicality: previousState.physicalPhysicality,
            virtualPhysicality: previousState.virtualPhysicality
        ))
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

    /// Clears controller-specific state after a hotplug without reusing frame
    /// IDs from the current streaming session.
    mutating func detach() {
        clearControllerState()
        isAttached = false
    }

    /// Clears all session state. The next attachment begins again at frame 1.
    mutating func reset() {
        detach()
        latestFrameID = 0
    }

    private mutating func appendSnapshot(
        for state: XboxGamepadState
    ) -> XboxModernInputFrame {
        previousState = state
        let frame = XboxModernInputFrame(
            frameID: nextFrameID(),
            gamepad: XboxModernGamepadReport(
                transitionCounters: transitionCounters,
                leftTrigger: state.leftTrigger,
                rightTrigger: state.rightTrigger,
                leftThumbX: state.leftThumbX,
                leftThumbY: state.leftThumbY,
                rightThumbX: state.rightThumbX,
                rightThumbY: state.rightThumbY,
                physicalPhysicality: state.physicalPhysicality,
                virtualPhysicality: state.virtualPhysicality
            )
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

    private mutating func clearControllerState() {
        previousState = nil
        transitionCounters = XboxModernGamepadTransitionCounters()
        pendingSnapshots.removeAll(keepingCapacity: true)
        lastAcknowledgedFrameID = nil
    }

    private static func normalized(
        _ state: XboxGamepadState
    ) -> XboxGamepadState {
        XboxGamepadState(
            index: 0,
            buttons: state.buttons,
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
