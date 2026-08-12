import Foundation
@preconcurrency import GameController
import Observation
import os
@preconcurrency import UIKit

private nonisolated let xboxInputLog = Logger(
    subsystem: "com.owenselles.CloudNow2",
    category: "XboxInput"
)

nonisolated enum XboxCloudChannelProtocolError: Error, Equatable, Sendable {
    case invalidCorrelationVector
    case invalidHandshake
    case encodingFailed
}

nonisolated enum XboxCloudChannelProtocolCodec {
    /// Public access key sent by Microsoft's Xbox web client after its initial
    /// preferred-resolution update on the same control channel.
    private static let controlAccessKey =
        "4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E"
    private static let messageProtocolVersion = "messageV1"
    private static let maximumCorrelationVectorLength = 126

    private struct AuthorizationRequest: Encodable {
        let message = "authorizationRequest"
        let accessKey = XboxCloudChannelProtocolCodec.controlAccessKey
    }

    private struct Handshake: Encodable {
        let type = "Handshake"
        let version = XboxCloudChannelProtocolCodec.messageProtocolVersion
        let id: String
        let cv: String
    }

    private struct HandshakeResponse: Decodable {
        let type: String
        let version: String
    }

    private struct GamepadChanged: Encodable {
        let message = "gamepadChanged"
        let gamepadIndex: UInt8
        let wasAdded: Bool
    }

    private struct UserRequestedResolutionUpdate: Encodable {
        let message = "userRequestedResolutionUpdate"
        let resolutionAlias: String
    }

    private struct Message: Encodable {
        let type = "Message"
        let content: String
        let id: String
        let target: String
        let cv: String
    }

    private struct DimensionsChanged: Encodable {
        let horizontal: Int
        let vertical: Int
        let preferredWidth: Int
        let preferredHeight: Int
        let safeAreaLeft = 0
        let safeAreaTop = 0
        let safeAreaRight: Int
        let safeAreaBottom: Int
        let supportsCustomResolution = true
    }

    static func messageHandshake(
        id: UUID,
        correlationVector: String
    ) throws -> Data {
        let cv = try extendedCorrelationVector(correlationVector)
        do {
            return try JSONEncoder().encode(
                Handshake(id: id.uuidString, cv: cv)
            )
        } catch {
            throw XboxCloudChannelProtocolError.encodingFailed
        }
    }

    static func authorizationRequest() throws -> Data {
        do {
            return try JSONEncoder().encode(AuthorizationRequest())
        } catch {
            throw XboxCloudChannelProtocolError.encodingFailed
        }
    }

    static func gamepadChanged(
        index: UInt8,
        wasAdded: Bool
    ) throws -> Data {
        do {
            return try JSONEncoder().encode(
                GamepadChanged(gamepadIndex: index, wasAdded: wasAdded)
            )
        } catch {
            throw XboxCloudChannelProtocolError.encodingFailed
        }
    }

    static func userRequestedResolutionUpdate(
        resolution: XboxCloudDisplayResolution
    ) throws -> Data {
        do {
            return try JSONEncoder().encode(
                UserRequestedResolutionUpdate(
                    resolutionAlias: resolution.rawValue
                )
            )
        } catch {
            throw XboxCloudChannelProtocolError.encodingFailed
        }
    }

    static func dimensionsChanged(
        id: UUID,
        correlationVector: String,
        preferredWidth: Int,
        preferredHeight: Int,
        pixelDensity: Double
    ) throws -> Data {
        guard (1 ... 16384).contains(preferredWidth),
              (1 ... 16384).contains(preferredHeight),
              pixelDensity.isFinite,
              (0.1 ... 16).contains(pixelDensity)
        else {
            throw XboxCloudChannelProtocolError.encodingFailed
        }
        let millimetersPerInch = 25.4
        let logicalPixelsPerInch = 96.0
        let horizontal = max(1, Int(
            Double(preferredWidth) / pixelDensity
                / logicalPixelsPerInch * millimetersPerInch
        ))
        let vertical = max(1, Int(
            Double(preferredHeight) / pixelDensity
                / logicalPixelsPerInch * millimetersPerInch
        ))
        do {
            let contentData = try JSONEncoder().encode(DimensionsChanged(
                horizontal: horizontal,
                vertical: vertical,
                preferredWidth: preferredWidth,
                preferredHeight: preferredHeight,
                safeAreaRight: preferredWidth,
                safeAreaBottom: preferredHeight
            ))
            guard let content = String(data: contentData, encoding: .utf8)
            else {
                throw XboxCloudChannelProtocolError.encodingFailed
            }
            return try JSONEncoder().encode(Message(
                content: content,
                id: id.uuidString,
                target: "/streaming/characteristics/dimensionschanged",
                cv: extendedCorrelationVector(
                    correlationVector
                )
            ))
        } catch let error as XboxCloudChannelProtocolError {
            throw error
        } catch {
            throw XboxCloudChannelProtocolError.encodingFailed
        }
    }

    static func isHandshakeAcknowledgement(_ data: Data) -> Bool {
        guard data.count <= 4096,
              let text = String(data: data, encoding: .utf8)
        else {
            return false
        }
        let normalized = text
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedData = normalized.data(using: .utf8),
              let response = try? JSONDecoder().decode(
                  HandshakeResponse.self,
                  from: normalizedData
              )
        else {
            return false
        }
        return response.type == "HandshakeAck"
            && response.version == messageProtocolVersion
    }

    private static func extendedCorrelationVector(
        _ value: String,
        component: Int = 1
    ) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let incremented = normalized + ".\(component)"
        guard !normalized.isEmpty,
              component > 0,
              incremented.utf8.count <= maximumCorrelationVectorLength,
              normalized.utf8.allSatisfy(isAllowedCorrelationVectorByte)
        else {
            throw XboxCloudChannelProtocolError.invalidCorrelationVector
        }
        return incremented
    }

    private static func isAllowedCorrelationVectorByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 43, 45 ... 47, 48 ... 57, 61, 65 ... 90, 95, 97 ... 122:
            true
        default:
            false
        }
    }
}

/// Tracks accepted sends for one control-channel lifecycle. The bootstrap
/// predicate below supplies the ordering and backpressure dependencies.
nonisolated struct XboxCloudControlSendState: Sendable {
    private(set) var isOpen = false
    private(set) var didSendAuthorization = false
    private(set) var didSendResolutionUpdate = false

    var shouldSendAuthorization: Bool {
        isOpen && didSendResolutionUpdate && !didSendAuthorization
    }

    var shouldSendResolutionUpdate: Bool {
        isOpen && !didSendResolutionUpdate
    }

    mutating func channelStateChanged(isOpen: Bool) {
        guard self.isOpen != isOpen else { return }
        self.isOpen = isOpen
        didSendAuthorization = false
        didSendResolutionUpdate = false
    }

    mutating func recordAuthorization(
        disposition: XboxCloudDataSendDisposition
    ) {
        guard shouldSendAuthorization, disposition == .accepted else { return }
        didSendAuthorization = true
    }

    mutating func recordResolutionUpdate(
        disposition: XboxCloudDataSendDisposition
    ) {
        guard shouldSendResolutionUpdate, disposition == .accepted else {
            return
        }
        didSendResolutionUpdate = true
    }

    mutating func reset() {
        self = Self()
    }
}

/// Pure bootstrap predicate shared by the worker and focused tests. Each
/// accepted frame unlocks only the next protocol phase. Controller bootstrap
/// precedes the preferred-resolution update, which precedes authorization.
nonisolated struct XboxCloudInputBootstrapState: Equatable, Sendable {
    var isTransportReady: Bool
    var hasInputVersion: Bool
    var isInputChannelOpen: Bool
    var didSendClientMetadata: Bool
    var hasPendingControlUpdates: Bool
    var hasAttachedController: Bool
    var didSendInitialControllerReport: Bool
    var didSendAuthorization: Bool
    var didSendResolutionUpdate: Bool

    var canSendControlUpdates: Bool {
        isTransportReady && didSendClientMetadata
    }

    var canSendControllerReport: Bool {
        canSendControlUpdates && !hasPendingControlUpdates
    }

    var initialControllerReportSatisfied: Bool {
        !hasAttachedController || didSendInitialControllerReport
    }

    private var canStartControlBootstrap: Bool {
        isTransportReady
            && hasInputVersion
            && isInputChannelOpen
            && didSendClientMetadata
            && !hasPendingControlUpdates
            && initialControllerReportSatisfied
    }

    var canSendResolutionUpdate: Bool {
        canStartControlBootstrap
    }

    var canSendAuthorization: Bool {
        canStartControlBootstrap && didSendResolutionUpdate
    }

    func isPublishedReady(
        isMessageChannelOpen: Bool,
        didReceiveMessageHandshake: Bool,
        didSendMessageDimensions: Bool
    ) -> Bool {
        canSendAuthorization
            && didSendAuthorization
            && didSendResolutionUpdate
            && isMessageChannelOpen
            && didReceiveMessageHandshake
            && didSendMessageDimensions
    }
}

nonisolated enum XboxCloudControllerRegistrationPolicy {
    static func pendingUpdate(
        isAttached: Bool,
        isRegistered: Bool
    ) -> Bool? {
        if isAttached {
            return isRegistered ? nil : true
        }
        return isRegistered ? false : nil
    }
}

nonisolated enum XboxModernPausedInputPolicy {
    static func shouldAttemptSend(
        needsNeutralSnapshot: Bool,
        hasUnacknowledgedFrame: Bool
    ) -> Bool {
        needsNeutralSnapshot || hasUnacknowledgedFrame
    }
}

nonisolated enum XboxCloudOverlayGestureAction: Equatable, Sendable {
    case none
    case toggleOverlay
    case replayMenuTap
}

/// Provider-neutral gesture semantics expressed in Xbox input terms. This
/// matches GFN's default Start/Menu behavior: keep the remote button neutral
/// while deciding between a short tap and a local 1.8-second overlay hold.
nonisolated struct XboxCloudOverlayGestureState: Equatable, Sendable {
    static let longPressDurationNanoseconds = UInt64(216 * 8_333_333)

    private(set) var startedAtNanoseconds: UInt64?
    private(set) var didTrigger = false

    var suppressesRemoteMenu: Bool {
        startedAtNanoseconds != nil
    }

    mutating func update(
        isPressed: Bool,
        at timestampNanoseconds: UInt64
    ) -> XboxCloudOverlayGestureAction {
        guard isPressed else {
            guard startedAtNanoseconds != nil else { return .none }
            let action: XboxCloudOverlayGestureAction = didTrigger
                ? .none
                : .replayMenuTap
            reset()
            return action
        }

        guard let startedAtNanoseconds else {
            startedAtNanoseconds = timestampNanoseconds
            didTrigger = false
            return .none
        }
        guard !didTrigger,
              timestampNanoseconds >= startedAtNanoseconds,
              timestampNanoseconds - startedAtNanoseconds
              >= Self.longPressDurationNanoseconds
        else {
            return .none
        }
        didTrigger = true
        return .toggleOverlay
    }

    mutating func reset() {
        startedAtNanoseconds = nil
        didTrigger = false
    }
}

nonisolated enum XboxCloudOverlayInputAction: Equatable, Sendable {
    case none
    case toggleOverlay
    case remoteMenu(isPressed: Bool, replayToken: UInt64)
}

/// Owns the complete Start/Menu decision and synthetic remote tap lifecycle.
/// The worker schedules only the replay deadline; this value decides whether
/// that deadline still belongs to the active controller/session state.
nonisolated struct XboxCloudOverlayInputSequence: Equatable, Sendable {
    private var gesture = XboxCloudOverlayGestureState()
    private var replaySequence: UInt64 = 0
    private(set) var activeReplayToken: UInt64?

    var remoteMenuOverride: Bool? {
        if activeReplayToken != nil {
            return true
        }
        if gesture.suppressesRemoteMenu {
            return false
        }
        return nil
    }

    mutating func update(
        isPressed: Bool,
        at timestampNanoseconds: UInt64
    ) -> XboxCloudOverlayInputAction {
        switch gesture.update(
            isPressed: isPressed,
            at: timestampNanoseconds
        ) {
        case .none:
            return .none
        case .toggleOverlay:
            return .toggleOverlay
        case .replayMenuTap:
            replaySequence &+= 1
            activeReplayToken = replaySequence
            return .remoteMenu(
                isPressed: true,
                replayToken: replaySequence
            )
        }
    }

    mutating func finishReplay(
        token: UInt64
    ) -> XboxCloudOverlayInputAction {
        guard activeReplayToken == token else { return .none }
        activeReplayToken = nil
        return .remoteMenu(isPressed: false, replayToken: token)
    }

    mutating func reset() {
        gesture.reset()
        activeReplayToken = nil
    }
}

nonisolated enum XboxCloudOverlayInputPolicy {
    static func settingMenuPressed(
        _ isPressed: Bool,
        in state: XboxGamepadState
    ) -> XboxGamepadState {
        var buttons = state.buttons
        var physicality = state.physicalPhysicality
        if isPressed {
            buttons.insert(.menu)
            physicality.insert(.menu)
        } else {
            buttons.remove(.menu)
            physicality.remove(.menu)
        }
        return XboxGamepadState(
            index: state.index,
            buttons: buttons,
            isSharePressed: state.isSharePressed,
            leftThumbX: state.leftThumbX,
            leftThumbY: state.leftThumbY,
            rightThumbX: state.rightThumbX,
            rightThumbY: state.rightThumbY,
            leftTrigger: state.leftTrigger,
            rightTrigger: state.rightTrigger,
            physicalPhysicality: physicality,
            virtualPhysicality: state.virtualPhysicality
        )
    }
}

nonisolated struct XboxCloudInboundMessageBudget: Sendable {
    private(set) var pendingCount = 0
    private(set) var hasPendingHandshake = false
    private(set) var activeGeneration: UInt64?
    private let capacity: Int

    init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    mutating func activate(generation: UInt64) {
        activeGeneration = generation
        pendingCount = 0
        hasPendingHandshake = false
    }

    mutating func deactivate(generation: UInt64) {
        guard activeGeneration == generation else { return }
        activeGeneration = nil
        pendingCount = 0
        hasPendingHandshake = false
    }

    mutating func reserve(generation: UInt64) -> Bool {
        guard activeGeneration == generation,
              pendingCount < capacity
        else {
            return false
        }
        pendingCount += 1
        return true
    }

    mutating func complete(generation: UInt64) {
        guard activeGeneration == generation else { return }
        pendingCount = max(0, pendingCount - 1)
    }

    mutating func reserveHandshake(generation: UInt64) -> Bool {
        guard activeGeneration == generation,
              !hasPendingHandshake
        else {
            return false
        }
        hasPendingHandshake = true
        return true
    }

    mutating func completeHandshake(generation: UInt64) {
        guard activeGeneration == generation else { return }
        hasPendingHandshake = false
    }
}

private nonisolated struct XboxCloudInputDataSink: Sendable {
    let sendInput: @Sendable (Data) -> XboxCloudDataSendDisposition
    let sendReliableInput: @Sendable (Data) -> XboxCloudDataSendDisposition
    let sendUnreliableInput: @Sendable (Data) -> XboxCloudDataSendDisposition
    let sendControl: @Sendable (Data) -> XboxCloudDataSendDisposition
    let sendMessage: @Sendable (Data) -> XboxCloudDataSendDisposition
}

/// Fixed-capacity acknowledgement cache for the controller-report hot path.
/// A state becomes clean only after the data channel accepts its report, so
/// backpressure retries cannot silently lose controller changes.
nonisolated struct XboxCloudInputStateCache: Sendable {
    static let minimumSendIntervalNanoseconds: UInt64 = 8_000_000

    private var acknowledgedStates: [XboxGamepadState?] = Array(
        repeating: nil,
        count: XboxCloudCompatibilityProfile.bundledV1.maximumControllerSlots
    )
    private var lastSendAttemptNanoseconds: UInt64?

    func appendIfDirty(
        _ state: XboxGamepadState,
        to dirtyStates: inout [XboxGamepadState]
    ) {
        let index = Int(state.index)
        guard acknowledgedStates.indices.contains(index),
              acknowledgedStates[index] != state
        else {
            return
        }
        dirtyStates.append(state)
    }

    func canAttemptSend(at timestampNanoseconds: UInt64) -> Bool {
        guard let lastSendAttemptNanoseconds else { return true }
        guard timestampNanoseconds >= lastSendAttemptNanoseconds else {
            return false
        }
        return timestampNanoseconds - lastSendAttemptNanoseconds
            >= Self.minimumSendIntervalNanoseconds
    }

    mutating func recordSendAttempt(
        _ states: [XboxGamepadState],
        at timestampNanoseconds: UInt64,
        accepted: Bool
    ) {
        lastSendAttemptNanoseconds = timestampNanoseconds
        guard accepted else { return }
        for state in states {
            let index = Int(state.index)
            guard acknowledgedStates.indices.contains(index) else { continue }
            acknowledgedStates[index] = state
        }
    }

    mutating func invalidate(index: Int) {
        guard acknowledgedStates.indices.contains(index) else { return }
        acknowledgedStates[index] = nil
    }

    mutating func reset() {
        for index in acknowledgedStates.indices {
            acknowledgedStates[index] = nil
        }
        lastSendAttemptNanoseconds = nil
    }
}

/// Bounded peripheral queue shared by legacy and V2 send paths. Keyboard and
/// pointer transitions are retained in order; high-rate mouse deltas coalesce
/// into one relative report until accepted or copied into a V2 snapshot.
nonisolated struct XboxCloudPeripheralInputBuffer: Sendable {
    static let maximumTransitionCount = 64

    private(set) var keyboard: [XboxKeyboardReport] = []
    private(set) var pointerFrames: [XboxPointerFrame] = []
    private(set) var mouse = XboxMouseReport()
    private(set) var isMouseDirty = false

    var report: XboxPeripheralInputReport {
        XboxPeripheralInputReport(
            pointerFrames: pointerFrames,
            keyboard: keyboard,
            mouse: isMouseDirty ? [mouse] : []
        )
    }

    var isEmpty: Bool {
        report.isEmpty
    }

    mutating func appendKeyboard(_ event: XboxKeyboardReport) {
        keyboard.append(event)
        Self.trimOldest(&keyboard)
    }

    mutating func appendPointerFrame(_ frame: XboxPointerFrame) {
        guard !frame.events.isEmpty else { return }
        pointerFrames.append(frame)
        Self.trimOldest(&pointerFrames)
    }

    mutating func addMouseMovement(x: Float, y: Float) {
        mouse = XboxMouseReport(
            x: Self.adding(mouse.x, x),
            y: Self.adding(mouse.y, y),
            wheelX: mouse.wheelX,
            wheelY: mouse.wheelY,
            buttons: mouse.buttons
        )
        isMouseDirty = true
    }

    mutating func addMouseScroll(x: Float, y: Float) {
        mouse = XboxMouseReport(
            x: mouse.x,
            y: mouse.y,
            wheelX: Self.adding(mouse.wheelX, x),
            wheelY: Self.adding(mouse.wheelY, y),
            buttons: mouse.buttons
        )
        isMouseDirty = true
    }

    mutating func setMouseButtons(_ buttons: XboxMouseButtons) {
        mouse = XboxMouseReport(
            x: mouse.x,
            y: mouse.y,
            wheelX: mouse.wheelX,
            wheelY: mouse.wheelY,
            buttons: buttons
        )
        isMouseDirty = true
    }

    mutating func clear() {
        keyboard.removeAll(keepingCapacity: true)
        pointerFrames.removeAll(keepingCapacity: true)
        mouse = XboxMouseReport()
        isMouseDirty = false
    }

    private static func trimOldest(_ values: inout [some Any]) {
        guard values.count > maximumTransitionCount else { return }
        values.removeFirst(values.count - maximumTransitionCount)
    }

    private static func adding(_ current: Int32, _ delta: Float) -> Int32 {
        let rounded = Int64(delta.rounded())
        let sum = Int64(current) + rounded
        return Int32(clamping: sum)
    }
}

/// Converts Apple USB-HID key codes to Windows virtual-key values accepted by
/// Xbox Cloud. Layout and IME keys without a confirmed mapping fail closed
/// instead of being sent with a false code.
nonisolated enum XboxCloudKeyboardMapper {
    private static let virtualKeys: [GCKeyCode: UInt8] = [
        .keyA: 0x41,
        .keyB: 0x42,
        .keyC: 0x43,
        .keyD: 0x44,
        .keyE: 0x45,
        .keyF: 0x46,
        .keyG: 0x47,
        .keyH: 0x48,
        .keyI: 0x49,
        .keyJ: 0x4A,
        .keyK: 0x4B,
        .keyL: 0x4C,
        .keyM: 0x4D,
        .keyN: 0x4E,
        .keyO: 0x4F,
        .keyP: 0x50,
        .keyQ: 0x51,
        .keyR: 0x52,
        .keyS: 0x53,
        .keyT: 0x54,
        .keyU: 0x55,
        .keyV: 0x56,
        .keyW: 0x57,
        .keyX: 0x58,
        .keyY: 0x59,
        .keyZ: 0x5A,
        .zero: 0x30,
        .one: 0x31,
        .two: 0x32,
        .three: 0x33,
        .four: 0x34,
        .five: 0x35,
        .six: 0x36,
        .seven: 0x37,
        .eight: 0x38,
        .nine: 0x39,
        .returnOrEnter: 0x0D,
        .escape: 0x1B,
        .deleteOrBackspace: 0x08,
        .tab: 0x09,
        .spacebar: 0x20,
        .hyphen: 0xBD,
        .equalSign: 0xBB,
        .openBracket: 0xDB,
        .closeBracket: 0xDD,
        .backslash: 0xDC,
        .nonUSPound: 0xDC,
        .semicolon: 0xBA,
        .quote: 0xDE,
        .graveAccentAndTilde: 0xC0,
        .comma: 0xBC,
        .period: 0xBE,
        .slash: 0xBF,
        .capsLock: 0x14,
        .printScreen: 0x2C,
        .scrollLock: 0x91,
        .pause: 0x13,
        .leftArrow: 0x25,
        .upArrow: 0x26,
        .rightArrow: 0x27,
        .downArrow: 0x28,
        .insert: 0x2D,
        .deleteForward: 0x2E,
        .home: 0x24,
        .end: 0x23,
        .pageUp: 0x21,
        .pageDown: 0x22,
        .F1: 0x70,
        .F2: 0x71,
        .F3: 0x72,
        .F4: 0x73,
        .F5: 0x74,
        .F6: 0x75,
        .F7: 0x76,
        .F8: 0x77,
        .F9: 0x78,
        .F10: 0x79,
        .F11: 0x7A,
        .F12: 0x7B,
        .F13: 0x7C,
        .F14: 0x7D,
        .F15: 0x7E,
        .F16: 0x7F,
        .F17: 0x80,
        .F18: 0x81,
        .F19: 0x82,
        .F20: 0x83,
        .keypadNumLock: 0x90,
        .keypadSlash: 0x6F,
        .keypadAsterisk: 0x6A,
        .keypadHyphen: 0x6D,
        .keypadPlus: 0x6B,
        .keypadEnter: 0x0D,
        .keypad0: 0x60,
        .keypad1: 0x61,
        .keypad2: 0x62,
        .keypad3: 0x63,
        .keypad4: 0x64,
        .keypad5: 0x65,
        .keypad6: 0x66,
        .keypad7: 0x67,
        .keypad8: 0x68,
        .keypad9: 0x69,
        .keypadPeriod: 0x6E,
        .keypadEqualSign: 0x92,
        .nonUSBackslash: 0xE2,
        .application: 0x5D,
        .leftShift: 0xA0,
        .rightShift: 0xA1,
        .leftControl: 0xA2,
        .rightControl: 0xA3,
        .leftAlt: 0xA4,
        .rightAlt: 0xA5,
        .leftGUI: 0x5B,
        .rightGUI: 0x5C,
    ]

    static func isPauseMenuToggle(
        keyCode: GCKeyCode,
        isPressed: Bool
    ) -> Bool {
        keyCode == .escape && isPressed
    }

    static func virtualKey(for keyCode: GCKeyCode) -> UInt8? {
        virtualKeys[keyCode]
    }
}

nonisolated enum XboxCloudResponderKeyboardAction: Equatable, Sendable {
    case ignored
    case togglePauseMenu
    case keyboard(isPressed: Bool, virtualKey: UInt8)
}

/// State for the UIKit responder fallback used by tvOS Simulator. Physical
/// keyboards continue through GCKeyboard; when one is available this path
/// fails closed so the same key cannot be sent twice.
nonisolated struct XboxCloudResponderKeyboardState: Sendable {
    private var forwardedKeys: [Int: UInt8] = [:]

    mutating func action(
        keyCode: UIKeyboardHIDUsage,
        isPressed: Bool,
        isSimulator: Bool,
        hasGameControllerKeyboard: Bool
    ) -> XboxCloudResponderKeyboardAction {
        let identifier = Int(keyCode.rawValue)
        if !isPressed,
           let virtualKey = forwardedKeys.removeValue(forKey: identifier)
        {
            return .keyboard(isPressed: false, virtualKey: virtualKey)
        }

        guard isPressed,
              isSimulator,
              !hasGameControllerKeyboard
        else {
            return .ignored
        }
        if keyCode == .keyboardEscape {
            return .togglePauseMenu
        }
        guard forwardedKeys[identifier] == nil,
              let mapping = CloudKeyboardHIDMapper.mapping(for: keyCode),
              mapping.virtualKey <= UInt8.max
        else {
            return .ignored
        }
        let virtualKey = UInt8(mapping.virtualKey)
        forwardedKeys[identifier] = virtualKey
        return .keyboard(isPressed: true, virtualKey: virtualKey)
    }
}

/// Bounded ASCII-to-virtual-key helper retained for future or Debug-only input
/// plumbing. It is not a Unicode/composition channel and is not advertised as
/// generic text entry. Unsupported composed Unicode fails closed.
nonisolated enum XboxCloudTextInputMapper {
    private struct KeyStroke {
        let virtualKey: UInt8
        let requiresShift: Bool
    }

    private static let maximumCharacterCount = 1024
    private static let maximumReportCount =
        XboxCloudPeripheralInputBuffer.maximumTransitionCount
    private static let shiftedDigitKeys: [Character: UInt8] = [
        "!": 0x31,
        "@": 0x32,
        "#": 0x33,
        "$": 0x34,
        "%": 0x35,
        "^": 0x36,
        "&": 0x37,
        "*": 0x38,
        "(": 0x39,
        ")": 0x30,
    ]
    private static let punctuationKeys: [Character: KeyStroke] = [
        ";": KeyStroke(virtualKey: 0xBA, requiresShift: false),
        ":": KeyStroke(virtualKey: 0xBA, requiresShift: true),
        "=": KeyStroke(virtualKey: 0xBB, requiresShift: false),
        "+": KeyStroke(virtualKey: 0xBB, requiresShift: true),
        ",": KeyStroke(virtualKey: 0xBC, requiresShift: false),
        "<": KeyStroke(virtualKey: 0xBC, requiresShift: true),
        "-": KeyStroke(virtualKey: 0xBD, requiresShift: false),
        "_": KeyStroke(virtualKey: 0xBD, requiresShift: true),
        ".": KeyStroke(virtualKey: 0xBE, requiresShift: false),
        ">": KeyStroke(virtualKey: 0xBE, requiresShift: true),
        "/": KeyStroke(virtualKey: 0xBF, requiresShift: false),
        "?": KeyStroke(virtualKey: 0xBF, requiresShift: true),
        "`": KeyStroke(virtualKey: 0xC0, requiresShift: false),
        "~": KeyStroke(virtualKey: 0xC0, requiresShift: true),
        "[": KeyStroke(virtualKey: 0xDB, requiresShift: false),
        "{": KeyStroke(virtualKey: 0xDB, requiresShift: true),
        "\\": KeyStroke(virtualKey: 0xDC, requiresShift: false),
        "|": KeyStroke(virtualKey: 0xDC, requiresShift: true),
        "]": KeyStroke(virtualKey: 0xDD, requiresShift: false),
        "}": KeyStroke(virtualKey: 0xDD, requiresShift: true),
        "'": KeyStroke(virtualKey: 0xDE, requiresShift: false),
        "\"": KeyStroke(virtualKey: 0xDE, requiresShift: true),
    ]

    static func reports(for text: String) -> [XboxKeyboardReport]? {
        guard text.count <= maximumCharacterCount else { return nil }
        var reports: [XboxKeyboardReport] = []
        reports.reserveCapacity(text.count * 4)
        for character in text {
            guard let stroke = keyStroke(for: character) else { return nil }
            let transitionCount = stroke.requiresShift ? 4 : 2
            guard reports.count <= maximumReportCount - transitionCount else {
                return nil
            }
            if stroke.requiresShift {
                reports.append(XboxKeyboardReport(
                    isPressed: true,
                    keyCode: 0x10
                ))
            }
            reports.append(XboxKeyboardReport(
                isPressed: true,
                keyCode: stroke.virtualKey
            ))
            reports.append(XboxKeyboardReport(
                isPressed: false,
                keyCode: stroke.virtualKey
            ))
            if stroke.requiresShift {
                reports.append(XboxKeyboardReport(
                    isPressed: false,
                    keyCode: 0x10
                ))
            }
        }
        return reports
    }

    private static func keyStroke(for character: Character) -> KeyStroke? {
        if let key = shiftedDigitKeys[character] {
            return KeyStroke(virtualKey: key, requiresShift: true)
        }
        if let stroke = punctuationKeys[character] {
            return stroke
        }
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1
        else {
            return nil
        }
        switch scalar.value {
        case 0x41 ... 0x5A:
            return KeyStroke(
                virtualKey: UInt8(scalar.value),
                requiresShift: true
            )
        case 0x61 ... 0x7A:
            return KeyStroke(
                virtualKey: UInt8(scalar.value - 0x20),
                requiresShift: false
            )
        case 0x30 ... 0x39:
            return KeyStroke(
                virtualKey: UInt8(scalar.value),
                requiresShift: false
            )
        case 0x20:
            return KeyStroke(virtualKey: 0x20, requiresShift: false)
        case 0x09:
            return KeyStroke(virtualKey: 0x09, requiresShift: false)
        case 0x0A, 0x0D:
            return KeyStroke(virtualKey: 0x0D, requiresShift: false)
        case 0x08:
            return KeyStroke(virtualKey: 0x08, requiresShift: false)
        default:
            return nil
        }
    }
}

/// All mutable Xbox input state lives on one bounded latency-sensitive queue.
/// The unchecked conformance is safe because every mutable field below is
/// accessed only by `queue`; public entry points enqueue or synchronize work.
private final nonisolated class XboxCloudInputWorker: @unchecked Sendable {
    private struct ClaimedSystemGesture {
        let element: GCControllerElement
        let previousState: GCControllerElement.SystemGestureState
    }

    private struct ControllerSlot {
        let controller: GCController
        let identifier: ObjectIdentifier
        let haptics: ControllerHaptics?
        let previousHandlerQueue: DispatchQueue
        let previousPlayerIndex: GCControllerPlayerIndex
        let previousValueChangedHandler: GCExtendedGamepadValueChangedHandler?
        let claimedSystemGestures: [ClaimedSystemGesture]
    }

    private struct KeyboardSlot {
        let keyboard: GCKeyboard
        let identifier: ObjectIdentifier
        let previousHandlerQueue: DispatchQueue
        let previousKeyChangedHandler: GCKeyboardValueChangedHandler?
    }

    private struct MouseButtonHandler {
        let button: GCControllerButtonInput
        let previousPressedChangedHandler: GCControllerButtonValueChangedHandler?
    }

    private struct MouseSlot {
        let mouse: GCMouse
        let identifier: ObjectIdentifier
        let previousHandlerQueue: DispatchQueue
        let previousMouseMovedHandler: GCMouseMoved?
        let previousScrollHandler: GCControllerDirectionPadValueChangedHandler?
        let buttonHandlers: [MouseButtonHandler]
    }

    private enum RumblePhase {
        case starting
        case stopping
    }

    private struct RumblePlayback {
        let ownership: UInt64
        let haptics: ControllerHaptics
        let strongMagnitude: UInt16
        let weakMagnitude: UInt16
        let delay: DispatchTimeInterval
        let duration: DispatchTimeInterval
        let timer: DispatchSourceTimer
        var remainingIterations: Int
        var phase: RumblePhase
    }

    private static let controllerCapacity = XboxCloudCompatibilityProfile
        .bundledV1.maximumControllerSlots
    private static let sampleIntervalNanoseconds = Int(
        XboxCloudInputStateCache.minimumSendIntervalNanoseconds
    )
    private static let overlayReplayDelay = DispatchTimeInterval.milliseconds(17)
    private static let maximumRumbleIterations = 8

    private let queue = DispatchQueue(
        label: "com.cloudnow.xbox-input",
        qos: .userInteractive
    )
    private let inboundMessageBudget = OSAllocatedUnfairLock(
        initialState: XboxCloudInboundMessageBudget()
    )
    private let deadzone: Float
    private let rumbleEnabled: Bool
    private let rumbleIntensity: Float
    private let preferredResolution: XboxCloudDisplayResolution
    private let preferredDisplayWidth: Int
    private let preferredDisplayHeight: Int
    private let pixelDensity: Double

    private var generation: UInt64 = 0
    private var sink: XboxCloudInputDataSink?
    private var readinessChanged: (@Sendable (UInt64, Bool) -> Void)?
    private var samplingTimer: DispatchSourceTimer?
    private var controllerSlots: [ControllerSlot?] = Array(
        repeating: nil,
        count: controllerCapacity
    )
    private var keyboardSlot: KeyboardSlot?
    private var mouseSlot: MouseSlot?
    private var pressedVirtualKeys: Set<UInt8> = []
    private var currentMouseButtons: XboxMouseButtons = []
    private var peripheralInput = XboxCloudPeripheralInputBuffer()
    private var overlayInputSequences = Array(
        repeating: XboxCloudOverlayInputSequence(),
        count: controllerCapacity
    )
    private var overlayToggleRequested: (@Sendable (UInt64) -> Void)?
    private var pendingControlUpdates: [Bool?] = Array(
        repeating: nil,
        count: controllerCapacity
    )
    private var registeredControllerPresence = Array(
        repeating: false,
        count: controllerCapacity
    )
    private var rumblePlaybacks: [RumblePlayback?] = Array(
        repeating: nil,
        count: controllerCapacity
    )
    private var rumbleSequence: UInt64 = 0
    private var sampledStates: [XboxGamepadState] = []
    private var inputStateCache = XboxCloudInputStateCache()
    private var modernInputState = XboxModernInputStateTracker()
    private var modernInputSendCadence = XboxModernInputSendCadence()
    private var encoder = XboxLegacyInputEncoder()
    private var inputMode: XboxCloudInputTransportMode?
    private var controlAuthorizationData: Data?
    private var messageHandshakeData: Data?
    private var messageDimensionsData: Data?
    private var resolutionUpdateData: Data?
    private var controlSendState = XboxCloudControlSendState()
    private var isTransportReady = false
    private var isInputChannelOpen = false
    private var isReliableInputChannelOpen = false
    private var isUnreliableInputChannelOpen = false
    private var isMessageChannelOpen = false
    private var isControlChannelNegotiated = true
    private var isMessageChannelNegotiated = true
    private var didSendClientMetadata = false
    private var didSendInitialControllerReport = false
    private var didSendMessageHandshake = false
    private var didReceiveMessageHandshake = false
    private var didSendMessageDimensions = false
    private var lastReportedReadiness = false
    private var isPaused = false
    private var needsPausedNeutralSnapshot = false
    private var didLogAuthorizationDeferred = false
    private var didLogFirstControllerActivity = false
    private var didLogFirstInputReport = false
    private var didLogFirstModernAcknowledgement = false

    init(
        deadzone: Float,
        rumbleEnabled: Bool,
        rumbleIntensity: Float,
        preferredResolution: XboxCloudDisplayResolution,
        preferredDisplayWidth: Int,
        preferredDisplayHeight: Int,
        pixelDensity: Double
    ) {
        self.deadzone = deadzone
        self.rumbleEnabled = rumbleEnabled
        self.rumbleIntensity = rumbleIntensity
        self.preferredResolution = preferredResolution
        self.preferredDisplayWidth = preferredDisplayWidth
        self.preferredDisplayHeight = preferredDisplayHeight
        self.pixelDensity = pixelDensity
        sampledStates.reserveCapacity(Self.controllerCapacity)
    }

    func start(
        generation: UInt64,
        sink: XboxCloudInputDataSink,
        correlationVector: String,
        controllers: [GCController],
        keyboard: GCKeyboard?,
        mice: [GCMouse],
        overlayToggleRequested: @escaping @Sendable (UInt64) -> Void,
        readinessChanged: @escaping @Sendable (UInt64, Bool) -> Void
    ) {
        queue.sync {
            stopLocked()
            self.generation = generation
            inboundMessageBudget.withLock {
                $0.activate(generation: generation)
            }
            self.sink = sink
            self.overlayToggleRequested = overlayToggleRequested
            self.readinessChanged = readinessChanged
            controlAuthorizationData = try? XboxCloudChannelProtocolCodec
                .authorizationRequest()
            messageHandshakeData = try? XboxCloudChannelProtocolCodec
                .messageHandshake(
                    id: UUID(),
                    correlationVector: correlationVector
                )
            messageDimensionsData = try? XboxCloudChannelProtocolCodec
                .dimensionsChanged(
                    id: UUID(),
                    correlationVector: correlationVector,
                    preferredWidth: preferredDisplayWidth,
                    preferredHeight: preferredDisplayHeight,
                    pixelDensity: pixelDensity
                )
            resolutionUpdateData = try? XboxCloudChannelProtocolCodec
                .userRequestedResolutionUpdate(
                    resolution: preferredResolution
                )
            controllers.forEach(attachControllerLocked)
            if let keyboard {
                attachKeyboardLocked(keyboard)
            }
            if let mouse = GCMouse.current ?? mice.first {
                attachMouseLocked(mouse)
            }
            sampleAndFlushLocked()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now(),
                repeating: .nanoseconds(Self.sampleIntervalNanoseconds),
                leeway: .microseconds(500)
            )
            timer.setEventHandler { [weak self] in
                self?.sampleAndFlushLocked()
            }
            samplingTimer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            stopLocked()
        }
    }

    #if DEBUG
        func pendingPeripheralReportForTesting() -> XboxPeripheralInputReport {
            queue.sync { peripheralInput.report }
        }
    #endif

    func setNegotiatedInputMode(
        _ mode: XboxCloudInputTransportMode,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            inputMode = mode
            didSendClientMetadata = false
            didSendInitialControllerReport = false
            inputStateCache.reset()
            resetAllOverlayGesturesLocked()
            if case .unreliable = mode {
                resetModernInputStateLocked()
            } else {
                modernInputState.reset()
                modernInputSendCadence.reset()
            }
            resetControllerRegistrationLocked(
                controlIsOpen: controlSendState.isOpen
            )
            xboxInputLog.notice(
                "[Input] selected mode=\(mode.diagnosticName, privacy: .public) version=\(mode.reportVersion, privacy: .public)"
            )
            sampleAndFlushLocked()
        }
    }

    func setTransportReady(
        _ isReady: Bool,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            isTransportReady = isReady
            sampleAndFlushLocked()
        }
    }

    func setNegotiatedOptionalChannels(
        _ channels: Set<XboxCloudDataChannelKind>,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            isControlChannelNegotiated = channels.contains(.control)
            isMessageChannelNegotiated = channels.contains(.message)
            if !isControlChannelNegotiated {
                for index in pendingControlUpdates.indices {
                    pendingControlUpdates[index] = nil
                }
            }
            sampleAndFlushLocked()
        }
    }

    /// Keeps the controller path alive alongside the REST heartbeat without
    /// manufacturing user input. V2 retransmits its newest unacknowledged
    /// snapshot; legacy invalidates every attached slot for a real-state send.
    func sendKeepAlive(generation expectedGeneration: UInt64) {
        queue.async { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            guard !isPaused else {
                sendPausedNeutralSnapshotLocked()
                return
            }
            if case let .unreliable(_, version) = inputMode {
                sendPendingModernGamepadSnapshotLocked(version: version)
            } else {
                for index in controllerSlots.indices
                    where controllerSlots[index] != nil
                {
                    inputStateCache.invalidate(index: index)
                }
                sendGamepadSnapshotLocked()
            }
        }
    }

    func setPaused(
        _ paused: Bool,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self,
                  generation == expectedGeneration,
                  isPaused != paused
            else {
                return
            }
            isPaused = paused
            if paused {
                resetAllOverlayGesturesLocked()
                peripheralInput.clear()
                releasePressedKeysLocked()
                if !currentMouseButtons.isEmpty {
                    currentMouseButtons = []
                    peripheralInput.setMouseButtons([])
                }
                needsPausedNeutralSnapshot = true
                for index in rumblePlaybacks.indices {
                    cancelRumbleLocked(index: index)
                }
                sendPausedNeutralSnapshotLocked()
            } else {
                needsPausedNeutralSnapshot = false
                inputStateCache.reset()
                sendGamepadSnapshotLocked()
            }
        }
    }

    func channelStateChanged(
        _ kind: XboxCloudDataChannelKind,
        isOpen: Bool,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            if !isOpen {
                switch kind {
                case .input, .reliableInput, .unreliableInput, .control,
                     .message:
                    resetAllOverlayGesturesLocked()
                case .chat:
                    break
                }
            }
            switch kind {
            case .control:
                if !isOpen {
                    isControlChannelNegotiated = false
                }
                let wasOpen = controlSendState.isOpen
                controlSendState.channelStateChanged(isOpen: isOpen)
                if wasOpen != isOpen {
                    didLogAuthorizationDeferred = false
                    resetControllerRegistrationLocked(controlIsOpen: isOpen)
                    if isOpen {
                        didSendInitialControllerReport = false
                        inputStateCache.reset()
                        if case .unreliable = inputMode {
                            resetModernInputStateLocked()
                        } else {
                            modernInputState.reset()
                            modernInputSendCadence.reset()
                        }
                        needsPausedNeutralSnapshot = isPaused
                    }
                }
            case .input:
                if !isOpen {
                    isTransportReady = false
                }
                isInputChannelOpen = isOpen
                if isOpen, case .legacy = inputMode {
                    didSendClientMetadata = false
                    didSendInitialControllerReport = false
                    inputStateCache.reset()
                    needsPausedNeutralSnapshot = isPaused
                }
            case .reliableInput:
                if !isOpen, case .unreliable = inputMode {
                    isTransportReady = false
                }
                isReliableInputChannelOpen = isOpen
                if isOpen, case .unreliable = inputMode {
                    didSendClientMetadata = false
                }
            case .unreliableInput:
                if !isOpen, case .unreliable = inputMode {
                    isTransportReady = false
                }
                isUnreliableInputChannelOpen = isOpen
                if isOpen, case .unreliable = inputMode {
                    didSendInitialControllerReport = false
                    resetModernInputStateLocked()
                    needsPausedNeutralSnapshot = isPaused
                }
            case .message:
                if !isOpen {
                    isMessageChannelNegotiated = false
                }
                isMessageChannelOpen = isOpen
                if isOpen {
                    didSendMessageHandshake = false
                    didReceiveMessageHandshake = false
                    didSendMessageDimensions = false
                }
            case .chat:
                break
            }
            sampleAndFlushLocked()
        }
    }

    func received(
        _ data: Data,
        on kind: XboxCloudDataChannelKind,
        generation expectedGeneration: UInt64
    ) {
        let isHandshakeAcknowledgement: Bool
        if kind == .message {
            guard XboxCloudChannelProtocolCodec
                .isHandshakeAcknowledgement(data)
            else { return }
            isHandshakeAcknowledgement = true
        } else {
            isHandshakeAcknowledgement = false
        }
        let didReserve = inboundMessageBudget.withLock { budget in
            if isHandshakeAcknowledgement {
                budget.reserveHandshake(generation: expectedGeneration)
            } else {
                budget.reserve(generation: expectedGeneration)
            }
        }
        guard didReserve else { return }
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                inboundMessageBudget.withLock { budget in
                    if isHandshakeAcknowledgement {
                        budget.completeHandshake(
                            generation: expectedGeneration
                        )
                    } else {
                        budget.complete(generation: expectedGeneration)
                    }
                }
            }
            guard generation == expectedGeneration else { return }
            switch kind {
            case .message:
                if XboxCloudChannelProtocolCodec
                    .isHandshakeAcknowledgement(data)
                {
                    didReceiveMessageHandshake = true
                    sampleAndFlushLocked()
                }
            case .input, .unreliableInput, .reliableInput:
                guard let inputMode,
                      let feedback = try? XboxLegacyInputFeedbackDecoder.decode(
                          data,
                          version: Self.feedbackVersion(
                              for: kind,
                              mode: inputMode
                          )
                      )
                else {
                    return
                }
                switch feedback {
                case let .rumble(command):
                    applyRumbleLocked(command)
                case let .unreliableInputAcknowledgement(frameID):
                    guard modernInputState.acknowledge(frameID: frameID) else {
                        return
                    }
                    if !didLogFirstModernAcknowledgement {
                        didLogFirstModernAcknowledgement = true
                        xboxInputLog.notice(
                            "[Input] first modern acknowledgement received"
                        )
                    }
                case .serverMetadata:
                    break
                }
            case .chat, .control:
                break
            }
        }
    }

    func attachController(
        _ controller: GCController,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            attachControllerLocked(controller)
            sampleAndFlushLocked()
        }
    }

    func detachController(
        _ controller: GCController,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            detachControllerLocked(controller)
            sampleAndFlushLocked()
        }
    }

    func attachKeyboard(
        _ keyboard: GCKeyboard,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            attachKeyboardLocked(keyboard)
        }
    }

    func detachKeyboard(
        _ keyboard: GCKeyboard,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self,
                  generation == expectedGeneration,
                  keyboardSlot?.identifier == ObjectIdentifier(keyboard)
            else {
                return
            }
            releasePressedKeysLocked()
            releaseKeyboardLocked()
            sendGamepadSnapshotLocked(force: true)
        }
    }

    func attachMouse(
        _ mouse: GCMouse,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            attachMouseLocked(mouse)
        }
    }

    func detachMouse(
        _ mouse: GCMouse,
        replacement: GCMouse?,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self,
                  generation == expectedGeneration,
                  mouseSlot?.identifier == ObjectIdentifier(mouse)
            else {
                return
            }
            if !currentMouseButtons.isEmpty {
                currentMouseButtons = []
                peripheralInput.setMouseButtons([])
            }
            releaseMouseLocked()
            if let replacement {
                attachMouseLocked(replacement)
            }
            sendGamepadSnapshotLocked(force: true)
        }
    }

    func enqueueKeyboard(
        _ report: XboxKeyboardReport,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self,
                  generation == expectedGeneration,
                  !isPaused
            else {
                return
            }
            recordKeyboardLocked(report)
            sendGamepadSnapshotLocked(force: true)
        }
    }

    func enqueuePointer(
        _ frame: XboxPointerFrame,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self,
                  generation == expectedGeneration,
                  !isPaused
            else {
                return
            }
            peripheralInput.appendPointerFrame(frame)
            sendGamepadSnapshotLocked(force: true)
        }
    }

    func enqueueMouse(
        _ report: XboxMouseReport,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self,
                  generation == expectedGeneration,
                  !isPaused
            else {
                return
            }
            peripheralInput.addMouseMovement(
                x: Float(report.x),
                y: Float(report.y)
            )
            peripheralInput.addMouseScroll(
                x: Float(report.wheelX),
                y: Float(report.wheelY)
            )
            currentMouseButtons = report.buttons
            peripheralInput.setMouseButtons(currentMouseButtons)
            sendGamepadSnapshotLocked(force: true)
        }
    }

    private func stopLocked() {
        if controlSendState.isOpen {
            for index in controllerSlots.indices
                where registeredControllerPresence[index]
            {
                sendControlUpdateLocked(index: index, wasAdded: false)
            }
        }

        samplingTimer?.setEventHandler {}
        samplingTimer?.cancel()
        samplingTimer = nil

        for index in controllerSlots.indices {
            cancelRumbleLocked(index: index)
            releaseControllerLocked(index: index)
            pendingControlUpdates[index] = nil
            registeredControllerPresence[index] = false
        }
        sampledStates.removeAll(keepingCapacity: true)
        inputStateCache.reset()
        resetAllOverlayGesturesLocked()
        sink = nil
        overlayToggleRequested = nil
        readinessChanged = nil
        inboundMessageBudget.withLock {
            $0.deactivate(generation: generation)
        }
        generation = 0
        inputMode = nil
        controlAuthorizationData = nil
        messageHandshakeData = nil
        messageDimensionsData = nil
        resolutionUpdateData = nil
        controlSendState.reset()
        isTransportReady = false
        isInputChannelOpen = false
        isReliableInputChannelOpen = false
        isUnreliableInputChannelOpen = false
        isMessageChannelOpen = false
        isControlChannelNegotiated = true
        isMessageChannelNegotiated = true
        didSendClientMetadata = false
        didSendInitialControllerReport = false
        didSendMessageHandshake = false
        didReceiveMessageHandshake = false
        didSendMessageDimensions = false
        lastReportedReadiness = false
        isPaused = false
        needsPausedNeutralSnapshot = false
        didLogAuthorizationDeferred = false
        didLogFirstControllerActivity = false
        didLogFirstInputReport = false
        didLogFirstModernAcknowledgement = false
        encoder = XboxLegacyInputEncoder()
        modernInputState.reset()
        modernInputSendCadence.reset()
        releaseKeyboardLocked()
        releaseMouseLocked()
        pressedVirtualKeys.removeAll(keepingCapacity: true)
        currentMouseButtons = []
        peripheralInput.clear()
    }

    private func attachControllerLocked(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        let identifier = ObjectIdentifier(controller)
        guard !controllerSlots.contains(where: {
            $0?.identifier == identifier
        }),
            let index = controllerSlots.firstIndex(where: { $0 == nil })
        else {
            return
        }

        let previousHandlerQueue = controller.handlerQueue
        let previousPlayerIndex = controller.playerIndex
        let previousValueChangedHandler = gamepad.valueChangedHandler
        controller.handlerQueue = queue
        controller.playerIndex = Self.playerIndex(for: index)
        resetOverlayGestureLocked(index: index)
        let claimedSystemGestures = claimControllerInputLocked(gamepad)
        gamepad.valueChangedHandler = { [weak self, weak controller] _, _ in
            guard let self, let controller else { return }
            controllerValueChangedLocked(controller)
        }

        let haptics = rumbleEnabled
            ? ControllerHaptics(controller: controller)
            : nil
        haptics?.setIntensityScale(rumbleIntensity)
        controllerSlots[index] = ControllerSlot(
            controller: controller,
            identifier: identifier,
            haptics: haptics,
            previousHandlerQueue: previousHandlerQueue,
            previousPlayerIndex: previousPlayerIndex,
            previousValueChangedHandler: previousValueChangedHandler,
            claimedSystemGestures: claimedSystemGestures
        )
        inputStateCache.invalidate(index: index)
        if case .unreliable = inputMode {
            modernInputState.attach(index: UInt8(index))
        }
        pendingControlUpdates[index] = XboxCloudControllerRegistrationPolicy
            .pendingUpdate(
                isAttached: true,
                isRegistered: registeredControllerPresence[index]
            )
        if isPaused {
            needsPausedNeutralSnapshot = true
        }
        let controllerCount = attachedControllerCount
        xboxInputLog.notice(
            "[Controller] attached slot=\(index, privacy: .public) total=\(controllerCount, privacy: .public)"
        )
    }

    private func attachKeyboardLocked(_ keyboard: GCKeyboard) {
        guard let input = keyboard.keyboardInput else { return }
        let identifier = ObjectIdentifier(keyboard)
        guard keyboardSlot?.identifier != identifier else { return }
        if keyboardSlot != nil {
            releasePressedKeysLocked()
            releaseKeyboardLocked()
        }
        let previousHandlerQueue = keyboard.handlerQueue
        let previousHandler = input.keyChangedHandler
        keyboard.handlerQueue = queue
        input.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            guard let self else { return }
            if keyCode == .escape {
                if XboxCloudKeyboardMapper.isPauseMenuToggle(
                    keyCode: keyCode,
                    isPressed: pressed
                ) {
                    overlayToggleRequested?(generation)
                }
                return
            }
            guard !isPaused else { return }
            guard let virtualKey = XboxCloudKeyboardMapper.virtualKey(
                for: keyCode
            )
            else {
                return
            }
            recordKeyboardLocked(XboxKeyboardReport(
                isPressed: pressed,
                keyCode: virtualKey
            ))
            sendGamepadSnapshotLocked(force: true)
        }
        keyboardSlot = KeyboardSlot(
            keyboard: keyboard,
            identifier: identifier,
            previousHandlerQueue: previousHandlerQueue,
            previousKeyChangedHandler: previousHandler
        )
    }

    private func attachMouseLocked(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        let identifier = ObjectIdentifier(mouse)
        guard mouseSlot?.identifier != identifier else { return }
        if mouseSlot != nil {
            if !currentMouseButtons.isEmpty {
                currentMouseButtons = []
                peripheralInput.setMouseButtons([])
            }
            releaseMouseLocked()
        }
        let previousHandlerQueue = mouse.handlerQueue
        let previousMovedHandler = input.mouseMovedHandler
        let previousScrollHandler = input.scroll.valueChangedHandler
        var buttonHandlers: [MouseButtonHandler] = []
        mouse.handlerQueue = queue
        input.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            guard let self, !isPaused else { return }
            peripheralInput.addMouseMovement(x: deltaX, y: -deltaY)
            peripheralInput.setMouseButtons(currentMouseButtons)
            sendGamepadSnapshotLocked(force: true)
        }
        input.scroll.valueChangedHandler = { [weak self] _, x, y in
            guard let self, !isPaused else { return }
            peripheralInput.addMouseScroll(x: x, y: -y)
            peripheralInput.setMouseButtons(currentMouseButtons)
            sendGamepadSnapshotLocked(force: true)
        }
        let buttons = [input.leftButton, input.rightButton, input.middleButton]
            .compactMap { $0 } + (input.auxiliaryButtons ?? [])
        for button in buttons {
            buttonHandlers.append(MouseButtonHandler(
                button: button,
                previousPressedChangedHandler: button.pressedChangedHandler
            ))
            button.pressedChangedHandler = {
                [weak self] (_: GCControllerButtonInput, _: Float, _: Bool) in
                guard let self, !isPaused else { return }
                sampleMouseButtonsLocked(input)
                sendGamepadSnapshotLocked(force: true)
            }
        }
        mouseSlot = MouseSlot(
            mouse: mouse,
            identifier: identifier,
            previousHandlerQueue: previousHandlerQueue,
            previousMouseMovedHandler: previousMovedHandler,
            previousScrollHandler: previousScrollHandler,
            buttonHandlers: buttonHandlers
        )
        if !isPaused {
            sampleMouseButtonsLocked(input)
        }
    }

    private func recordKeyboardLocked(_ report: XboxKeyboardReport) {
        if report.isPressed {
            guard pressedVirtualKeys.insert(report.keyCode).inserted else {
                return
            }
        } else {
            guard pressedVirtualKeys.remove(report.keyCode) != nil else {
                return
            }
        }
        peripheralInput.appendKeyboard(report)
    }

    private func releasePressedKeysLocked() {
        for keyCode in pressedVirtualKeys.sorted() {
            peripheralInput.appendKeyboard(XboxKeyboardReport(
                isPressed: false,
                keyCode: keyCode
            ))
        }
        pressedVirtualKeys.removeAll(keepingCapacity: true)
    }

    private func sampleMouseButtonsLocked(_ input: GCMouseInput) {
        var buttons: XboxMouseButtons = []
        if input.leftButton.isPressed {
            buttons.insert(.left)
        }
        if input.rightButton?.isPressed == true {
            buttons.insert(.right)
        }
        if input.middleButton?.isPressed == true {
            buttons.insert(.middle)
        }
        for (index, button) in (input.auxiliaryButtons ?? [])
            .prefix(2)
            .enumerated()
            where button.isPressed
        {
            buttons.insert(index == 0 ? .auxiliary1 : .auxiliary2)
        }
        currentMouseButtons = buttons
        peripheralInput.setMouseButtons(buttons)
    }

    private func releaseKeyboardLocked() {
        guard let slot = keyboardSlot else { return }
        slot.keyboard.keyboardInput?.keyChangedHandler = nil
        slot.keyboard.handlerQueue = slot.previousHandlerQueue
        slot.keyboard.keyboardInput?.keyChangedHandler =
            slot.previousKeyChangedHandler
        keyboardSlot = nil
    }

    private func releaseMouseLocked() {
        guard let slot = mouseSlot else { return }
        let input = slot.mouse.mouseInput
        input?.mouseMovedHandler = nil
        input?.scroll.valueChangedHandler = nil
        for handler in slot.buttonHandlers {
            handler.button.pressedChangedHandler = nil
        }
        slot.mouse.handlerQueue = slot.previousHandlerQueue
        input?.mouseMovedHandler = slot.previousMouseMovedHandler
        input?.scroll.valueChangedHandler = slot.previousScrollHandler
        for handler in slot.buttonHandlers {
            handler.button.pressedChangedHandler =
                handler.previousPressedChangedHandler
        }
        mouseSlot = nil
    }

    private func detachControllerLocked(_ controller: GCController) {
        let identifier = ObjectIdentifier(controller)
        guard let index = controllerSlots.firstIndex(where: {
            $0?.identifier == identifier
        }) else {
            return
        }

        resetOverlayGestureLocked(index: index)
        cancelRumbleLocked(index: index)
        releaseControllerLocked(index: index)
        inputStateCache.invalidate(index: index)
        if case .unreliable = inputMode {
            modernInputState.detach(index: UInt8(index))
        }
        pendingControlUpdates[index] = XboxCloudControllerRegistrationPolicy
            .pendingUpdate(
                isAttached: false,
                isRegistered: registeredControllerPresence[index]
            )
        let controllerCount = attachedControllerCount
        xboxInputLog.notice(
            "[Controller] detached slot=\(index, privacy: .public) total=\(controllerCount, privacy: .public)"
        )
    }

    private func sampleAndFlushLocked() {
        let forceInputReport = sampleOverlayGesturesLocked()
        flushMessageHandshakeLocked()
        flushMessageDimensionsLocked()
        flushClientMetadataLocked()
        flushControlUpdatesLocked()
        if isPaused {
            sendPausedNeutralSnapshotLocked()
        } else {
            sendGamepadSnapshotLocked(force: forceInputReport)
        }
        flushResolutionUpdateLocked()
        flushControlAuthorizationLocked()
        updateReadinessLocked()
    }

    private func sampleOverlayGesturesLocked() -> Bool {
        guard !isPaused else { return false }
        let timestamp = DispatchTime.now().uptimeNanoseconds
        var shouldForceInputReport = false
        for index in controllerSlots.indices {
            guard let controller = controllerSlots[index]?.controller,
                  let gamepad = controller.extendedGamepad
            else {
                continue
            }
            let action = overlayInputSequences[index].update(
                isPressed: gamepad.buttonMenu.isPressed,
                at: timestamp
            )
            shouldForceInputReport = handleOverlayInputActionLocked(
                action,
                controller: controller,
                index: index
            ) || shouldForceInputReport
        }
        return shouldForceInputReport
    }

    private func handleOverlayInputActionLocked(
        _ action: XboxCloudOverlayInputAction,
        controller: GCController,
        index: Int
    ) -> Bool {
        switch action {
        case .none:
            return false
        case .toggleOverlay:
            overlayToggleRequested?(generation)
            return false
        case let .remoteMenu(isPressed, replayToken):
            if isPressed {
                scheduleOverlayReplayReleaseLocked(
                    controller: controller,
                    index: index,
                    token: replayToken
                )
            }
            return true
        }
    }

    private func scheduleOverlayReplayReleaseLocked(
        controller: GCController,
        index: Int,
        token: UInt64
    ) {
        let expectedGeneration = generation
        let controllerIdentifier = ObjectIdentifier(controller)
        queue.asyncAfter(deadline: .now() + Self.overlayReplayDelay) {
            [weak self] in
            guard let self,
                  generation == expectedGeneration,
                  overlayInputSequences.indices.contains(index),
                  controllerSlots[index]?.identifier == controllerIdentifier
            else {
                return
            }
            let action = overlayInputSequences[index].finishReplay(
                token: token
            )
            guard action == .remoteMenu(
                isPressed: false,
                replayToken: token
            ) else {
                return
            }
            sendGamepadSnapshotLocked(force: true)
        }
    }

    private func effectiveGamepadStateLocked(
        controller: GCController,
        physicalSlot: Int,
        wireIndex: UInt8
    ) -> XboxGamepadState? {
        guard overlayInputSequences.indices.contains(physicalSlot),
              let state = XboxCloudInputValueMapper.gamepadState(
                  controller: controller,
                  index: wireIndex,
                  deadzone: deadzone
              )
        else {
            return nil
        }
        if let remoteMenuOverride = overlayInputSequences[physicalSlot]
            .remoteMenuOverride
        {
            return XboxCloudOverlayInputPolicy.settingMenuPressed(
                remoteMenuOverride,
                in: state
            )
        }
        if controller.extendedGamepad?.buttonMenu.isPressed == true {
            return XboxCloudOverlayInputPolicy.settingMenuPressed(
                false,
                in: state
            )
        }
        return state
    }

    private func resetOverlayGestureLocked(index: Int) {
        guard overlayInputSequences.indices.contains(index) else { return }
        overlayInputSequences[index].reset()
    }

    private func resetAllOverlayGesturesLocked() {
        for index in overlayInputSequences.indices {
            resetOverlayGestureLocked(index: index)
        }
    }

    private func flushControlUpdatesLocked() {
        guard bootstrapState.canSendControlUpdates,
              controlSendState.isOpen,
              let sink
        else {
            return
        }
        for index in pendingControlUpdates.indices {
            guard let wasAdded = pendingControlUpdates[index],
                  let data = try? XboxCloudChannelProtocolCodec.gamepadChanged(
                      index: UInt8(index),
                      wasAdded: wasAdded
                  )
            else {
                continue
            }
            if sink.sendControl(data) == .accepted {
                registeredControllerPresence[index] = wasAdded
                pendingControlUpdates[index] = nil
            }
        }
    }

    private func flushResolutionUpdateLocked() {
        guard bootstrapState.canSendResolutionUpdate,
              controlSendState.shouldSendResolutionUpdate,
              let sink,
              let resolutionUpdateData
        else {
            return
        }
        controlSendState.recordResolutionUpdate(
            disposition: sink.sendControl(resolutionUpdateData)
        )
        if controlSendState.didSendResolutionUpdate {
            let resolutionAlias = preferredResolution.rawValue
            xboxInputLog.notice(
                "[Control] preferred resolution queued alias=\(resolutionAlias, privacy: .public)"
            )
        }
    }

    private func flushControlAuthorizationLocked() {
        guard bootstrapState.canSendAuthorization,
              controlSendState.shouldSendAuthorization,
              let sink,
              let controlAuthorizationData
        else {
            return
        }
        let disposition = sink.sendControl(controlAuthorizationData)
        controlSendState.recordAuthorization(disposition: disposition)
        if disposition == .accepted {
            xboxInputLog.notice("[Control] authorization queued")
            didLogAuthorizationDeferred = false
        } else if !didLogAuthorizationDeferred {
            xboxInputLog.info("[Control] authorization deferred; retrying")
            didLogAuthorizationDeferred = true
        }
    }

    private func sendControlUpdateLocked(index: Int, wasAdded: Bool) {
        guard controlSendState.isOpen,
              let sink,
              let data = try? XboxCloudChannelProtocolCodec.gamepadChanged(
                  index: UInt8(index),
                  wasAdded: wasAdded
              )
        else {
            return
        }
        _ = sink.sendControl(data)
    }

    private func flushMessageHandshakeLocked() {
        guard isMessageChannelOpen,
              !didSendMessageHandshake,
              let sink,
              let messageHandshakeData
        else {
            return
        }
        didSendMessageHandshake =
            sink.sendMessage(messageHandshakeData) == .accepted
    }

    private func flushMessageDimensionsLocked() {
        guard isMessageChannelOpen,
              didReceiveMessageHandshake,
              !didSendMessageDimensions,
              let sink,
              let messageDimensionsData
        else {
            return
        }
        didSendMessageDimensions =
            sink.sendMessage(messageDimensionsData) == .accepted
        if didSendMessageDimensions {
            let width = preferredDisplayWidth
            let height = preferredDisplayHeight
            xboxInputLog.notice(
                "[Message] preferred dimensions queued \(width, privacy: .public)x\(height, privacy: .public) custom=true"
            )
        }
    }

    private func flushClientMetadataLocked() {
        guard metadataChannelIsOpen,
              !didSendClientMetadata,
              let inputMode,
              let sink
        else {
            return
        }
        do {
            guard let data = try encoder.encodeClientMetadata(
                version: inputMode.metadataVersion,
                timestampMilliseconds: Self.timestampMilliseconds()
            ) else {
                didSendClientMetadata = true
                return
            }
            let disposition = switch inputMode {
            case .legacy:
                sink.sendInput(data)
            case .unreliable:
                sink.sendReliableInput(data)
            }
            didSendClientMetadata = disposition == .accepted
            if didSendClientMetadata {
                xboxInputLog.notice(
                    "[Input] client metadata queued mode=\(inputMode.diagnosticName, privacy: .public)"
                )
            }
        } catch {
            didSendClientMetadata = false
        }
    }

    private func sendGamepadSnapshotLocked(force: Bool = false) {
        guard let inputMode else { return }
        switch inputMode {
        case let .legacy(version):
            sendLegacyGamepadSnapshotLocked(version: version, force: force)
        case let .unreliable(_, unreliableVersion):
            sendModernGamepadSnapshotLocked(
                version: unreliableVersion,
                force: force
            )
        }
    }

    private func sendLegacyGamepadSnapshotLocked(
        version: Int,
        force: Bool = false
    ) {
        guard !isPaused,
              bootstrapState.canSendControllerReport,
              isInputChannelOpen,
              didSendClientMetadata,
              let sink
        else {
            return
        }
        let timestampNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard force || inputStateCache.canAttemptSend(
            at: timestampNanoseconds
        ) else {
            return
        }
        sampledStates.removeAll(keepingCapacity: true)
        for index in controllerSlots.indices {
            guard let controller = controllerSlots[index]?.controller,
                  let state = effectiveGamepadStateLocked(
                      controller: controller,
                      physicalSlot: index,
                      wireIndex: UInt8(index)
                  )
            else {
                continue
            }
            inputStateCache.appendIfDirty(state, to: &sampledStates)
        }
        let peripherals = peripheralInput.report
        guard !sampledStates.isEmpty || !peripherals.isEmpty else {
            didSendInitialControllerReport = true
            return
        }
        guard let data = try? encoder.encodeInput(
            gamepads: sampledStates,
            peripherals: peripherals,
            version: version,
            timestampMilliseconds: Double(timestampNanoseconds) / 1_000_000
        ) else { return }
        let disposition = sink.sendInput(data)
        inputStateCache.recordSendAttempt(
            sampledStates,
            at: timestampNanoseconds,
            accepted: disposition == .accepted
        )
        if disposition == .accepted {
            didSendInitialControllerReport = true
            peripheralInput.clear()
        }
        if disposition == .accepted, !didLogFirstInputReport {
            didLogFirstInputReport = true
            let reportCount = sampledStates.count
            xboxInputLog.notice(
                "[Input] first controller report queued count=\(reportCount, privacy: .public)"
            )
        }
    }

    private func sendModernGamepadSnapshotLocked(
        version: Int,
        force: Bool = false
    ) {
        guard !isPaused,
              bootstrapState.canSendControllerReport,
              isUnreliableInputChannelOpen,
              didSendClientMetadata
        else {
            return
        }
        sampledStates.removeAll(keepingCapacity: true)
        for index in controllerSlots.indices {
            guard let controller = controllerSlots[index]?.controller,
                  let state = effectiveGamepadStateLocked(
                      controller: controller,
                      physicalSlot: index,
                      wireIndex: UInt8(index)
                  )
            else {
                continue
            }
            sampledStates.append(state)
        }
        let peripherals = peripheralInput.report
        if modernInputState.record(
            sampledStates,
            peripherals: peripherals
        ) != nil, !peripherals.isEmpty {
            peripheralInput.clear()
        }
        sendPendingModernGamepadSnapshotLocked(
            version: version,
            force: force
        )
    }

    private func sendPendingModernGamepadSnapshotLocked(
        version: Int,
        force: Bool = false
    ) {
        guard !isPaused,
              bootstrapState.canSendControllerReport,
              isUnreliableInputChannelOpen,
              didSendClientMetadata,
              let sink
        else {
            return
        }
        let timestampNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard let frame = modernInputState.frameForTransmission(),
              force || modernInputSendCadence.canAttempt(
                  frameID: frame.frameID,
                  at: timestampNanoseconds
              ),
              let data = try? XboxModernInputEncoder.encode(
                  frame,
                  version: version,
                  inputToken: encoder.reserveInputToken(),
                  timestampMilliseconds: Double(timestampNanoseconds) / 1_000_000
              )
        else {
            if attachedControllerCount == 0 {
                didSendInitialControllerReport = true
            }
            return
        }
        let disposition = sink.sendUnreliableInput(data)
        guard disposition == .accepted else { return }
        modernInputSendCadence.recordAccepted(
            frameID: frame.frameID,
            at: timestampNanoseconds
        )
        didSendInitialControllerReport = true
        if !didLogFirstInputReport {
            didLogFirstInputReport = true
            xboxInputLog.notice(
                "[Input] first modern controller report queued bytes=\(data.count, privacy: .public)"
            )
        }
    }

    private func sendPausedNeutralSnapshotLocked() {
        guard let inputMode else { return }
        switch inputMode {
        case let .legacy(version):
            sendLegacyPausedNeutralSnapshotLocked(version: version)
        case let .unreliable(_, unreliableVersion):
            sendModernPausedNeutralSnapshotLocked(version: unreliableVersion)
        }
    }

    private func sendLegacyPausedNeutralSnapshotLocked(version: Int) {
        guard isPaused,
              needsPausedNeutralSnapshot,
              bootstrapState.canSendControllerReport,
              isInputChannelOpen,
              didSendClientMetadata,
              let sink
        else {
            return
        }
        sampledStates.removeAll(keepingCapacity: true)
        for index in controllerSlots.indices
            where controllerSlots[index] != nil
        {
            sampledStates.append(XboxGamepadState(index: UInt8(index)))
        }
        let peripherals = peripheralInput.report
        guard !sampledStates.isEmpty || !peripherals.isEmpty else {
            needsPausedNeutralSnapshot = false
            return
        }
        let timestampNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard let data = try? encoder.encodeInput(
            gamepads: sampledStates,
            peripherals: peripherals,
            version: version,
            timestampMilliseconds: Double(timestampNanoseconds) / 1_000_000
        ) else {
            return
        }
        guard sink.sendInput(data) == .accepted else { return }
        inputStateCache.recordSendAttempt(
            sampledStates,
            at: timestampNanoseconds,
            accepted: true
        )
        didSendInitialControllerReport = true
        needsPausedNeutralSnapshot = false
        peripheralInput.clear()
        let reportCount = sampledStates.count
        xboxInputLog.notice(
            "[Input] paused neutral queued count=\(reportCount, privacy: .public)"
        )
    }

    private func sendModernPausedNeutralSnapshotLocked(version: Int) {
        guard isPaused,
              bootstrapState.canSendControllerReport,
              isUnreliableInputChannelOpen,
              didSendClientMetadata,
              let sink
        else {
            return
        }
        guard XboxModernPausedInputPolicy.shouldAttemptSend(
            needsNeutralSnapshot: needsPausedNeutralSnapshot,
            hasUnacknowledgedFrame: modernInputState.frameForTransmission() != nil
        ) else {
            return
        }
        let shouldCreateNeutralSnapshot = needsPausedNeutralSnapshot
        if shouldCreateNeutralSnapshot {
            sampledStates.removeAll(keepingCapacity: true)
            for index in controllerSlots.indices
                where controllerSlots[index] != nil
            {
                sampledStates.append(XboxGamepadState(index: UInt8(index)))
            }
            let peripherals = peripheralInput.report
            _ = modernInputState.record(
                sampledStates,
                peripherals: peripherals
            )
            if !peripherals.isEmpty {
                peripheralInput.clear()
            }
            needsPausedNeutralSnapshot = false
        }
        guard let frame = modernInputState.frameForTransmission() else {
            return
        }
        let timestampNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard modernInputSendCadence.canAttempt(
            frameID: frame.frameID,
            at: timestampNanoseconds
        ),
            let data = try? XboxModernInputEncoder.encode(
                frame,
                version: version,
                inputToken: encoder.reserveInputToken(),
                timestampMilliseconds: Double(timestampNanoseconds) / 1_000_000
            )
        else {
            return
        }
        guard sink.sendUnreliableInput(data) == .accepted else { return }
        modernInputSendCadence.recordAccepted(
            frameID: frame.frameID,
            at: timestampNanoseconds
        )
        didSendInitialControllerReport = true
        if shouldCreateNeutralSnapshot {
            xboxInputLog.notice("[Input] paused modern neutral queued")
        }
    }

    private func updateReadinessLocked() {
        let nextValue = bootstrapState.isPublishedReady(
            isMessageChannelOpen: !isMessageChannelNegotiated
                || isMessageChannelOpen,
            didReceiveMessageHandshake: !isMessageChannelNegotiated
                || didReceiveMessageHandshake,
            didSendMessageDimensions: !isMessageChannelNegotiated
                || didSendMessageDimensions
        )
        guard nextValue != lastReportedReadiness else { return }
        lastReportedReadiness = nextValue
        readinessChanged?(generation, nextValue)
    }

    private var bootstrapState: XboxCloudInputBootstrapState {
        XboxCloudInputBootstrapState(
            isTransportReady: isTransportReady,
            hasInputVersion: inputMode != nil,
            isInputChannelOpen: negotiatedInputChannelsAreOpen,
            didSendClientMetadata: didSendClientMetadata,
            hasPendingControlUpdates: isControlChannelNegotiated
                && pendingControlUpdates.contains { $0 != nil },
            hasAttachedController: attachedControllerCount > 0,
            didSendInitialControllerReport: didSendInitialControllerReport,
            didSendAuthorization: !isControlChannelNegotiated
                || controlSendState.didSendAuthorization,
            didSendResolutionUpdate: !isControlChannelNegotiated
                || controlSendState.didSendResolutionUpdate
        )
    }

    private var metadataChannelIsOpen: Bool {
        switch inputMode {
        case .legacy:
            isInputChannelOpen
        case .unreliable:
            isReliableInputChannelOpen
        case nil:
            false
        }
    }

    private var negotiatedInputChannelsAreOpen: Bool {
        switch inputMode {
        case .legacy:
            isInputChannelOpen
        case .unreliable:
            isReliableInputChannelOpen && isUnreliableInputChannelOpen
        case nil:
            false
        }
    }

    private func resetModernInputStateLocked() {
        modernInputState.reset()
        modernInputSendCadence.reset()
        for index in controllerSlots.indices
            where controllerSlots[index] != nil
        {
            modernInputState.attach(index: UInt8(index))
        }
    }

    private func resetControllerRegistrationLocked(controlIsOpen: Bool) {
        for index in controllerSlots.indices {
            registeredControllerPresence[index] = false
            pendingControlUpdates[index] = nil
        }
        guard controlIsOpen else { return }
        for index in controllerSlots.indices {
            pendingControlUpdates[index] =
                XboxCloudControllerRegistrationPolicy.pendingUpdate(
                    isAttached: controllerSlots[index] != nil,
                    isRegistered: false
                )
        }
    }

    private static func feedbackVersion(
        for channel: XboxCloudDataChannelKind,
        mode: XboxCloudInputTransportMode
    ) -> Int {
        switch (channel, mode) {
        case (.reliableInput, .unreliable):
            mode.metadataVersion
        case (.unreliableInput, .unreliable):
            mode.reportVersion
        case (.input, .legacy):
            mode.reportVersion
        default:
            mode.reportVersion
        }
    }

    private func applyRumbleLocked(_ command: XboxRumbleCommand) {
        guard let index = controllerSlotIndex(
            forWireIndex: command.gamepadIndex
        ),
            !isPaused,
            rumbleEnabled,
            rumblePlaybacks.indices.contains(index),
            let haptics = controllerSlots[index]?.haptics
        else {
            return
        }

        cancelRumbleLocked(index: index)
        rumbleSequence &+= 1
        let ownership = rumbleSequence
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let playback = RumblePlayback(
            ownership: ownership,
            haptics: haptics,
            strongMagnitude: XboxCloudInputValueMapper.rumbleMagnitude(
                max(
                    command.leftMotorPercent,
                    command.leftTriggerMotorPercent
                )
            ),
            weakMagnitude: XboxCloudInputValueMapper.rumbleMagnitude(
                max(
                    command.rightMotorPercent,
                    command.rightTriggerMotorPercent
                )
            ),
            delay: .milliseconds(Int(command.delayMilliseconds)),
            duration: .milliseconds(Int(command.durationMilliseconds)),
            timer: timer,
            remainingIterations: min(
                Int(command.repeatCount) + 1,
                Self.maximumRumbleIterations
            ),
            phase: .starting
        )
        timer.setEventHandler { [weak self] in
            self?.advanceRumbleLocked(
                index: index,
                ownership: ownership
            )
        }
        rumblePlaybacks[index] = playback
        timer.schedule(deadline: .now() + playback.delay)
        timer.resume()
    }

    private func controllerSlotIndex(forWireIndex index: UInt8) -> Int? {
        let physicalIndex = Int(index)
        return controllerSlots.indices.contains(physicalIndex)
            ? physicalIndex
            : nil
    }

    private func advanceRumbleLocked(index: Int, ownership: UInt64) {
        guard var playback = rumblePlaybacks[index],
              playback.ownership == ownership
        else {
            return
        }

        switch playback.phase {
        case .starting:
            playback.haptics.setMotors(
                strong: playback.strongMagnitude,
                weak: playback.weakMagnitude
            )
            playback.phase = .stopping
            rumblePlaybacks[index] = playback
            playback.timer.schedule(deadline: .now() + playback.duration)
        case .stopping:
            playback.haptics.stop()
            playback.remainingIterations -= 1
            guard playback.remainingIterations > 0 else {
                playback.timer.setEventHandler {}
                playback.timer.cancel()
                rumblePlaybacks[index] = nil
                return
            }
            playback.phase = .starting
            rumblePlaybacks[index] = playback
            playback.timer.schedule(deadline: .now() + playback.delay)
        }
    }

    private func cancelRumbleLocked(index: Int) {
        guard let playback = rumblePlaybacks[index] else { return }
        playback.timer.setEventHandler {}
        playback.timer.cancel()
        playback.haptics.stop()
        rumblePlaybacks[index] = nil
    }

    private func controllerValueChangedLocked(_ controller: GCController) {
        guard !isPaused else { return }
        let identifier = ObjectIdentifier(controller)
        guard let index = controllerSlots.firstIndex(where: {
            $0?.identifier == identifier
        }),
            let gamepad = controller.extendedGamepad
        else {
            return
        }
        if !didLogFirstControllerActivity {
            didLogFirstControllerActivity = true
            xboxInputLog.notice("[Controller] first input observed")
        }
        let action = overlayInputSequences[index].update(
            isPressed: gamepad.buttonMenu.isPressed,
            at: DispatchTime.now().uptimeNanoseconds
        )
        let forceInputReport = handleOverlayInputActionLocked(
            action,
            controller: controller,
            index: index
        )
        sendGamepadSnapshotLocked(force: forceInputReport)
    }

    private func claimControllerInputLocked(
        _ gamepad: GCExtendedGamepad
    ) -> [ClaimedSystemGesture] {
        let elements: [GCControllerButtonInput?] = [
            gamepad.buttonA,
            gamepad.buttonB,
            gamepad.buttonX,
            gamepad.buttonY,
            gamepad.buttonMenu,
            gamepad.buttonOptions,
            gamepad.leftShoulder,
            gamepad.rightShoulder,
            gamepad.leftTrigger,
            gamepad.rightTrigger,
            gamepad.leftThumbstickButton,
            gamepad.rightThumbstickButton,
            (gamepad as? GCXboxGamepad)?.buttonShare,
        ]
        return elements.compactMap { element in
            guard let element else { return nil }
            let claim = ClaimedSystemGesture(
                element: element,
                previousState: element.preferredSystemGestureState
            )
            element.preferredSystemGestureState = .disabled
            return claim
        }
    }

    private func releaseControllerLocked(index: Int) {
        guard let slot = controllerSlots[index] else { return }
        let gamepad = slot.controller.extendedGamepad
        gamepad?.valueChangedHandler = nil
        for claim in slot.claimedSystemGestures {
            claim.element.preferredSystemGestureState = claim.previousState
        }
        slot.haptics?.cleanup()
        slot.controller.playerIndex = slot.previousPlayerIndex
        slot.controller.handlerQueue = slot.previousHandlerQueue
        gamepad?.valueChangedHandler = slot.previousValueChangedHandler
        controllerSlots[index] = nil
    }

    private var attachedControllerCount: Int {
        controllerSlots.reduce(into: 0) { count, slot in
            if slot != nil {
                count += 1
            }
        }
    }

    private static func playerIndex(for slot: Int) -> GCControllerPlayerIndex {
        switch slot {
        case 0: .index1
        case 1: .index2
        case 2: .index3
        case 3: .index4
        default: .indexUnset
        }
    }

    private static func timestampMilliseconds() -> Double {
        ProcessInfo.processInfo.systemUptime * 1000
    }
}

nonisolated enum XboxCloudInputValueMapper {
    static func gamepadState(
        controller: GCController,
        index: UInt8,
        deadzone: Float
    ) -> XboxGamepadState? {
        guard let pad = controller.extendedGamepad else { return nil }
        var buttons: XboxGamepadButtons = []
        var physicality: XboxGamepadPhysicality = []

        func apply(
            _ input: GCControllerButtonInput?,
            button: XboxGamepadButtons,
            physical: XboxGamepadPhysicality
        ) {
            guard input?.isPressed == true else { return }
            buttons.insert(button)
            physicality.insert(physical)
        }

        apply(pad.buttonHome, button: .nexus, physical: .nexus)
        apply(pad.buttonMenu, button: .menu, physical: .menu)
        apply(pad.buttonOptions, button: .view, physical: .view)
        apply(pad.buttonA, button: .a, physical: .a)
        apply(pad.buttonB, button: .b, physical: .b)
        apply(pad.buttonX, button: .x, physical: .x)
        apply(pad.buttonY, button: .y, physical: .y)
        apply(pad.dpad.up, button: .dpadUp, physical: .dpadUp)
        apply(pad.dpad.down, button: .dpadDown, physical: .dpadDown)
        apply(pad.dpad.left, button: .dpadLeft, physical: .dpadLeft)
        apply(pad.dpad.right, button: .dpadRight, physical: .dpadRight)
        apply(
            pad.leftShoulder,
            button: .leftShoulder,
            physical: .leftShoulder
        )
        apply(
            pad.rightShoulder,
            button: .rightShoulder,
            physical: .rightShoulder
        )
        apply(
            pad.leftThumbstickButton,
            button: .leftThumbstick,
            physical: .leftThumb
        )
        apply(
            pad.rightThumbstickButton,
            button: .rightThumbstick,
            physical: .rightThumb
        )

        let leftTrigger = triggerValue(pad.leftTrigger.value)
        let rightTrigger = triggerValue(pad.rightTrigger.value)
        let isSharePressed = (pad as? GCXboxGamepad)?.buttonShare?.isPressed
            == true
        if leftTrigger > 0 {
            physicality.insert(.leftTrigger)
        }
        if rightTrigger > 0 {
            physicality.insert(.rightTrigger)
        }
        if isSharePressed {
            physicality.insert(.share)
        }

        let leftThumb = thumbstickValues(
            x: pad.leftThumbstick.xAxis.value,
            y: pad.leftThumbstick.yAxis.value,
            deadzone: deadzone
        )
        let rightThumb = thumbstickValues(
            x: pad.rightThumbstick.xAxis.value,
            y: pad.rightThumbstick.yAxis.value,
            deadzone: deadzone
        )
        physicality.formUnion(thumbstickPhysicality(
            x: leftThumb.x,
            y: leftThumb.y,
            xAxis: .leftThumbXAxis,
            yAxis: .leftThumbYAxis
        ))
        physicality.formUnion(thumbstickPhysicality(
            x: rightThumb.x,
            y: rightThumb.y,
            xAxis: .rightThumbXAxis,
            yAxis: .rightThumbYAxis
        ))

        return XboxGamepadState(
            index: index,
            buttons: buttons,
            isSharePressed: isSharePressed,
            leftThumbX: leftThumb.x,
            leftThumbY: leftThumb.y,
            rightThumbX: rightThumb.x,
            rightThumbY: rightThumb.y,
            leftTrigger: leftTrigger,
            rightTrigger: rightTrigger,
            physicalPhysicality: physicality
        )
    }

    static func thumbstickValues(
        x: Float,
        y: Float,
        deadzone: Float
    ) -> (x: Int16, y: Int16) {
        let clampedX = min(max(x, -1), 1)
        // Xbox's wire format uses XInput orientation (up is positive). Browser
        // clients negate their negative-up Gamepad axis while encoding; Apple
        // GameController is already positive-up, so no second inversion belongs
        // here.
        let clampedY = min(max(y, -1), 1)
        let magnitude = (clampedX * clampedX + clampedY * clampedY)
            .squareRoot()
        guard magnitude > deadzone, magnitude > 0 else {
            return (0, 0)
        }
        let scaledMagnitude = min(
            1,
            (magnitude - deadzone) / (1 - deadzone)
        )
        let scale = scaledMagnitude / magnitude
        return (
            signedAxis(clampedX * scale),
            signedAxis(clampedY * scale)
        )
    }

    static func signedAxis(_ value: Float) -> Int16 {
        let clamped = min(max(value, -1), 1)
        return Int16(clamped * Float(Int16.max))
    }

    static func triggerValue(_ value: Float) -> UInt16 {
        UInt16(clamping: Int(min(max(value, 0), 1) * Float(UInt16.max)))
    }

    static func thumbstickPhysicality(
        x: Int16,
        y: Int16,
        xAxis: XboxGamepadPhysicality,
        yAxis: XboxGamepadPhysicality
    ) -> XboxGamepadPhysicality {
        x == 0 && y == 0 ? [] : [xAxis, yAxis]
    }

    static func rumbleMagnitude(_ percent: UInt8) -> UInt16 {
        UInt16((UInt32(percent) * UInt32(UInt16.max)) / 100)
    }
}

/// Xbox-only controller and data-channel lifecycle. Observable state remains
/// main-actor-owned while the latency-sensitive input path stays off-main.
@Observable
@MainActor
final class XboxCloudInputDriver {
    private(set) var isReady = false
    var menuToggleHandler: (@MainActor @Sendable () -> Void)?

    @ObservationIgnored private weak var transport: XboxCloudWebRTCTransport?
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let worker: XboxCloudInputWorker
    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var attachmentGeneration: UInt64 = 0
    @ObservationIgnored private var hasDecodedVideo = false

    init(
        notificationCenter: NotificationCenter = .default,
        deadzone: Float = 0.15,
        rumbleEnabled: Bool = true,
        rumbleIntensity: Float = 1,
        preferredResolution: XboxCloudDisplayResolution = .automatic,
        preferredDisplayWidth: Int = 1920,
        preferredDisplayHeight: Int = 1080,
        pixelDensity: Double = 1
    ) {
        self.notificationCenter = notificationCenter
        let displayWidth = (1 ... 16384).contains(preferredDisplayWidth)
            ? preferredDisplayWidth
            : 1920
        let displayHeight = (1 ... 16384).contains(preferredDisplayHeight)
            ? preferredDisplayHeight
            : 1080
        let displayDensity = pixelDensity.isFinite
            && (0.1 ... 16).contains(pixelDensity)
            ? pixelDensity
            : 1
        worker = XboxCloudInputWorker(
            deadzone: min(max(deadzone, 0), 0.95),
            rumbleEnabled: rumbleEnabled,
            rumbleIntensity: min(max(rumbleIntensity, 0), 1),
            preferredResolution: preferredResolution,
            preferredDisplayWidth: displayWidth,
            preferredDisplayHeight: displayHeight,
            pixelDensity: displayDensity
        )
    }

    isolated deinit {
        observerTokens.forEach(notificationCenter.removeObserver)
        if let transport {
            transport.onChannelStateChanged = nil
            transport.onChannelMessage = nil
        }
        worker.stop()
    }

    func attach(
        to transport: XboxCloudWebRTCTransport,
        signalingContext: XboxCloudSignalingContext
    ) {
        stop()
        let generation = attachmentGeneration
        self.transport = transport
        isReady = false
        hasDecodedVideo = false

        transport.onChannelStateChanged = { [weak self, weak transport] kind, isOpen in
            guard let self,
                  let transport,
                  attachmentGeneration == generation
            else {
                return
            }
            worker.channelStateChanged(
                kind,
                isOpen: isOpen,
                generation: generation
            )
            worker.setTransportReady(
                hasDecodedVideo && transport.readiness.isReady,
                generation: generation
            )
        }
        transport.onChannelMessage = { [worker] kind, data, _ in
            switch kind {
            case .message, .input, .unreliableInput, .reliableInput:
                worker.received(data, on: kind, generation: generation)
            case .chat, .control:
                break
            }
        }
        installControllerObservers(generation: generation)

        let sink = XboxCloudInputDataSink(
            sendInput: { [weak transport] data in
                transport?.sendInput(data) ?? .channelUnavailable
            },
            sendReliableInput: { [weak transport] data in
                transport?.sendReliableInput(data) ?? .channelUnavailable
            },
            sendUnreliableInput: { [weak transport] data in
                transport?.sendUnreliableInput(data) ?? .channelUnavailable
            },
            sendControl: { [weak transport] data in
                transport?.sendControl(data) ?? .channelUnavailable
            },
            sendMessage: { [weak transport] data in
                transport?.sendMessage(data) ?? .channelUnavailable
            }
        )
        worker.start(
            generation: generation,
            sink: sink,
            correlationVector: signalingContext.correlationVector,
            controllers: GCController.controllers(),
            keyboard: GCKeyboard.coalesced,
            mice: GCMouse.mice(),
            overlayToggleRequested: { [weak self] callbackGeneration in
                Task { @MainActor [weak self] in
                    guard let self,
                          attachmentGeneration == callbackGeneration
                    else {
                        return
                    }
                    menuToggleHandler?()
                }
            },
            readinessChanged: { [weak self] callbackGeneration, ready in
                Task { @MainActor [weak self] in
                    guard let self,
                          attachmentGeneration == callbackGeneration
                    else {
                        return
                    }
                    isReady = ready
                }
            }
        )
    }

    func setNegotiatedInputMode(_ mode: XboxCloudInputTransportMode?) throws {
        guard let mode else {
            throw XboxLegacyInputCodecError.unsupportedVersion
        }
        worker.setNegotiatedInputMode(
            mode,
            generation: attachmentGeneration
        )
    }

    func setNegotiatedOptionalChannels(
        _ channels: Set<XboxCloudDataChannelKind>
    ) {
        worker.setNegotiatedOptionalChannels(
            channels,
            generation: attachmentGeneration
        )
    }

    /// Microsoft's input manager starts only after video packets are flowing.
    /// A decoded-frame callback is stronger than the early RTP-track callback.
    func setVideoFlowing() {
        hasDecodedVideo = true
        worker.setTransportReady(
            transport?.readiness.isReady == true,
            generation: attachmentGeneration
        )
    }

    func sendKeepAlive() {
        worker.sendKeepAlive(generation: attachmentGeneration)
    }

    func setPaused(_ paused: Bool) {
        worker.setPaused(paused, generation: attachmentGeneration)
    }

    #if DEBUG
        func pendingPeripheralReportForTesting() -> XboxPeripheralInputReport {
            worker.pendingPeripheralReportForTesting()
        }
    #endif

    /// Internal virtual-key hook shared with physical GCKeyboard input. It does
    /// not provide a Unicode or committed-text composition channel.
    func sendKeyboardEvent(isPressed: Bool, virtualKey: UInt8) {
        worker.enqueueKeyboard(
            XboxKeyboardReport(
                isPressed: isPressed,
                keyCode: virtualKey
            ),
            generation: attachmentGeneration
        )
    }

    /// Encodes bounded ASCII only and fails closed for composed text.
    @discardableResult
    func sendTextEntry(_ text: String) -> Bool {
        guard let reports = XboxCloudTextInputMapper.reports(for: text) else {
            return false
        }
        for report in reports {
            worker.enqueueKeyboard(
                report,
                generation: attachmentGeneration
            )
        }
        return true
    }

    /// Absolute pointer foundation for touch/pencil surfaces owned by UI.
    func sendPointerFrame(_ frame: XboxPointerFrame) {
        worker.enqueuePointer(frame, generation: attachmentGeneration)
    }

    /// Relative-pointer foundation for platform adapters without GCMouse.
    func sendMouseReport(_ report: XboxMouseReport) {
        worker.enqueueMouse(report, generation: attachmentGeneration)
    }

    func stop() {
        attachmentGeneration &+= 1
        observerTokens.forEach(notificationCenter.removeObserver)
        observerTokens.removeAll(keepingCapacity: false)
        if let transport {
            transport.onChannelStateChanged = nil
            transport.onChannelMessage = nil
        }
        transport = nil
        hasDecodedVideo = false
        worker.stop()
        isReady = false
    }

    private func installControllerObservers(generation: UInt64) {
        observerTokens = [
            notificationCenter.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let controller = notification.object as? GCController else {
                    return
                }
                MainActor.assumeIsolated {
                    guard let self,
                          self.attachmentGeneration == generation
                    else {
                        return
                    }
                    self.worker.attachController(
                        controller,
                        generation: generation
                    )
                }
            },
            notificationCenter.addObserver(
                forName: .GCControllerDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let controller = notification.object as? GCController else {
                    return
                }
                MainActor.assumeIsolated {
                    guard let self,
                          self.attachmentGeneration == generation
                    else {
                        return
                    }
                    self.worker.detachController(
                        controller,
                        generation: generation
                    )
                }
            },
            notificationCenter.addObserver(
                forName: .GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let keyboard = notification.object as? GCKeyboard else {
                    return
                }
                MainActor.assumeIsolated {
                    guard let self,
                          self.attachmentGeneration == generation
                    else {
                        return
                    }
                    self.worker.attachKeyboard(
                        keyboard,
                        generation: generation
                    )
                }
            },
            notificationCenter.addObserver(
                forName: .GCKeyboardDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let keyboard = notification.object as? GCKeyboard else {
                    return
                }
                MainActor.assumeIsolated {
                    guard let self,
                          self.attachmentGeneration == generation
                    else {
                        return
                    }
                    self.worker.detachKeyboard(
                        keyboard,
                        generation: generation
                    )
                }
            },
            notificationCenter.addObserver(
                forName: .GCMouseDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let mouse = notification.object as? GCMouse else {
                    return
                }
                MainActor.assumeIsolated {
                    guard let self,
                          self.attachmentGeneration == generation
                    else {
                        return
                    }
                    self.worker.attachMouse(mouse, generation: generation)
                }
            },
            notificationCenter.addObserver(
                forName: .GCMouseDidBecomeCurrent,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let mouse = notification.object as? GCMouse else {
                    return
                }
                MainActor.assumeIsolated {
                    guard let self,
                          self.attachmentGeneration == generation
                    else {
                        return
                    }
                    self.worker.attachMouse(mouse, generation: generation)
                }
            },
            notificationCenter.addObserver(
                forName: .GCMouseDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let mouse = notification.object as? GCMouse else {
                    return
                }
                MainActor.assumeIsolated {
                    guard let self,
                          self.attachmentGeneration == generation
                    else {
                        return
                    }
                    let replacement = GCMouse.current ?? GCMouse.mice().first
                    self.worker.detachMouse(
                        mouse,
                        replacement: replacement,
                        generation: generation
                    )
                }
            },
        ]
    }
}
