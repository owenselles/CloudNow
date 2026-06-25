import Foundation
import GameController
import UIKit

// MARK: - GFN Input Protocol Constants

private enum GFNInput {
    static let keyDown: UInt8 = 3
    static let keyUp: UInt8 = 4
    static let mouseRel: UInt8 = 7
    static let mouseBtnDown: UInt8 = 8
    static let mouseBtnUp: UInt8 = 9
    static let mouseWheel: UInt8 = 10
    static let gamepad: UInt8 = 12
    /// Heartbeat type (u32 LE value 2) — keeps the server's virtual gamepad alive
    static let heartbeatU32: UInt32 = 2

    /// Gamepad packet: 38 bytes, u32 LE type per GFN protocol
    static let gamepadPacketSize = 38
    // Keyboard/mouse packets use 4-byte UInt32 LE type (matches TS InputEncoder)
    static let keyboardPacketSize = 18
    static let mouseButtonPacketSize = 18
    static let mouseMovePacketSize = 22
    static let mouseWheelPacketSize = 22

    // XInput button flags
    static let dpadUp: UInt16 = 0x0001
    static let dpadDown: UInt16 = 0x0002
    static let dpadLeft: UInt16 = 0x0004
    static let dpadRight: UInt16 = 0x0008
    static let start: UInt16 = 0x0010
    static let back: UInt16 = 0x0020
    static let ls: UInt16 = 0x0040
    static let rs: UInt16 = 0x0080
    static let lb: UInt16 = 0x0100
    static let rb: UInt16 = 0x0200
    static let guide: UInt16 = 0x0400
    static let buttonA: UInt16 = 0x1000
    static let buttonB: UInt16 = 0x2000
    static let buttonX: UInt16 = 0x4000
    static let buttonY: UInt16 = 0x8000
}

// MARK: - Remote Input Mode

enum RemoteInputMode: String, Codable, Equatable {
    case mouse
    case gamepad
    case dualsense
}

// MARK: - Input Event Handler

/// Implemented by InputSender; adopted by VideoSurfaceView to forward keyboard/mouse events.
protocol InputEventHandler: AnyObject {
    func sendKeyEvent(down: Bool, keyCode: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags)
    func sendMouseMove(dx: Int16, dy: Int16)
    func sendMouseButton(down: Bool, button: UInt8)
    func sendMouseWheel(delta: Int16)
}

// MARK: - Encoded Packet

enum InputPacketCategory: String {
    case heartbeat
    case gamepadSnapshot
    case keyboard
    case mouseButton
    case mouseMove
    case mouseWheel
}

enum InputSendDisposition {
    case accepted
    case channelUnavailable
    case rejected
    case superseded
}

/// Reusable fixed-capacity storage handed from InputSender to the WebRTC send queue.
final class EncodedInputPacket: @unchecked Sendable {
    static let capacity = 64

    nonisolated(unsafe) let storage = NSMutableData(length: capacity)!
    private(set) nonisolated(unsafe) var count = 0
    private(set) nonisolated(unsafe) var category: InputPacketCategory = .heartbeat
    private(set) nonisolated(unsafe) var generatedAt: UInt64 = 0
    private(set) nonisolated(unsafe) var gamepadSlot: Int?
    private(set) nonisolated(unsafe) var isReplaceableGamepadSnapshot = false

    func markGenerated(
        as category: InputPacketCategory,
        gamepadSlot: Int? = nil,
        replaceableGamepadSnapshot: Bool = false
    ) {
        self.category = category
        self.gamepadSlot = gamepadSlot
        isReplaceableGamepadSnapshot = replaceableGamepadSnapshot
        generatedAt = DispatchTime.now().uptimeNanoseconds
    }

    func prepare(length: Int) -> UnsafeMutableRawBufferPointer {
        precondition(length <= Self.capacity)
        count = length
        let bytes = UnsafeMutableRawBufferPointer(start: storage.mutableBytes, count: Self.capacity)
        for index in 0 ..< length {
            bytes[index] = 0
        }
        return bytes
    }
}

// MARK: - Input Encoder

/// Encodes controller and HID input into reusable GFN protocol packet buffers.
final class InputEncoder {
    private var protocolVersion = 2
    private var gamepadSequence = [Int: UInt16]()

    func setProtocolVersion(_ v: Int) {
        protocolVersion = v
    }

    // MARK: Heartbeat

    /// Sends a keep-alive to hold the server's virtual gamepad state between real input events.
    /// Encoded as a raw 4-byte u32 LE value 2 — no v3 wrapper (matches official client's Jc()).
    func encodeHeartbeat(into packet: EncodedInputPacket) {
        let buf = packet.prepare(length: 4)
        writeUInt32LE(buf, offset: 0, value: GFNInput.heartbeatU32)
    }

    // MARK: Gamepad

    /// Encodes a gamepad state packet.
    /// - Parameter gamepadBitmap: Bitmask of connected controller slots (bit i = controller i active).
    func encodeGamepad(
        controllerId: Int,
        buttons: UInt16,
        leftTrigger: UInt8,
        rightTrigger: UInt8,
        leftStickX: Int16,
        leftStickY: Int16,
        rightStickX: Int16,
        rightStickY: Int16,
        gamepadBitmap: UInt8,
        into packet: EncodedInputPacket
    ) {
        let timestamp = currentTimestamp()
        let payloadOffset = protocolVersion >= 3 ? 16 : 0
        let buf = packet.prepare(length: payloadOffset + GFNInput.gamepadPacketSize)

        if protocolVersion >= 3 {
            let seq = nextGamepadSequence(controllerId)
            buf[0] = 0x23
            writeTimestampBE(buf, offset: 1, value: timestamp)
            buf[9] = 0x26
            buf[10] = UInt8(controllerId & 0xFF)
            buf[11] = UInt8(seq >> 8)
            buf[12] = UInt8(seq & 0xFF)
            buf[13] = 0x21
            buf[14] = UInt8(GFNInput.gamepadPacketSize >> 8)
            buf[15] = UInt8(GFNInput.gamepadPacketSize & 0xFF)
        }

        writeUInt32LE(buf, offset: payloadOffset, value: 12)
        writeUInt16LE(buf, offset: payloadOffset + 4, value: 26)
        writeUInt16LE(buf, offset: payloadOffset + 6, value: UInt16(controllerId & 3))
        writeUInt16LE(buf, offset: payloadOffset + 8, value: UInt16(gamepadBitmap))
        writeUInt16LE(buf, offset: payloadOffset + 10, value: 20)
        writeUInt16LE(buf, offset: payloadOffset + 12, value: buttons)
        buf[payloadOffset + 14] = leftTrigger
        buf[payloadOffset + 15] = rightTrigger
        writeInt16LE(buf, offset: payloadOffset + 16, value: leftStickX)
        writeInt16LE(buf, offset: payloadOffset + 18, value: leftStickY)
        writeInt16LE(buf, offset: payloadOffset + 20, value: rightStickX)
        writeInt16LE(buf, offset: payloadOffset + 22, value: rightStickY)
        buf[payloadOffset + 26] = 0x55
        writeTimestampLE(buf, offset: payloadOffset + 30, value: timestamp)
    }

    // MARK: Keyboard

    // Packet (18 bytes): [UInt32 LE type][UInt16 BE vk][UInt16 BE mods][UInt16 BE scan][UInt64 BE ts]

    func encodeKeyboard(
        down: Bool,
        vk: UInt16,
        scancode: UInt16,
        modifiers: UInt16,
        into packet: EncodedInputPacket
    ) {
        let timestamp = currentTimestamp()
        let payloadOffset = protocolVersion >= 3 ? 10 : 0
        let buf = packet.prepare(length: payloadOffset + GFNInput.keyboardPacketSize)
        writeSingleEventHeader(buf, timestamp: timestamp)
        writeUInt32LE(buf, offset: payloadOffset, value: down ? UInt32(GFNInput.keyDown) : UInt32(GFNInput.keyUp))
        writeUInt16BE(buf, offset: payloadOffset + 4, value: vk)
        writeUInt16BE(buf, offset: payloadOffset + 6, value: modifiers)
        writeUInt16BE(buf, offset: payloadOffset + 8, value: scancode)
        writeTimestampBE(buf, offset: payloadOffset + 10, value: timestamp)
    }

    // MARK: Mouse Move

    // Packet (22 bytes): [UInt32 LE type][Int16 BE dx][Int16 BE dy][6B reserved][UInt64 BE ts]

    func encodeMouseMove(dx: Int16, dy: Int16, into packet: EncodedInputPacket) {
        let timestamp = currentTimestamp()
        let payloadOffset = protocolVersion >= 3 ? 12 : 0
        let buf = packet.prepare(length: payloadOffset + GFNInput.mouseMovePacketSize)
        if protocolVersion >= 3 {
            buf[0] = 0x23
            writeTimestampBE(buf, offset: 1, value: timestamp)
            buf[9] = 0x21
            buf[10] = UInt8(GFNInput.mouseMovePacketSize >> 8)
            buf[11] = UInt8(GFNInput.mouseMovePacketSize & 0xFF)
        }
        writeUInt32LE(buf, offset: payloadOffset, value: UInt32(GFNInput.mouseRel))
        writeInt16BE(buf, offset: payloadOffset + 4, value: dx)
        writeInt16BE(buf, offset: payloadOffset + 6, value: dy)
        writeTimestampBE(buf, offset: payloadOffset + 14, value: timestamp)
    }

    // MARK: Mouse Button

    // Packet (18 bytes): [UInt32 LE type][UInt8 button][1B pad][4B reserved][UInt64 BE ts]

    func encodeMouseButton(down: Bool, button: UInt8, into packet: EncodedInputPacket) {
        let timestamp = currentTimestamp()
        let payloadOffset = protocolVersion >= 3 ? 10 : 0
        let buf = packet.prepare(length: payloadOffset + GFNInput.mouseButtonPacketSize)
        writeSingleEventHeader(buf, timestamp: timestamp)
        writeUInt32LE(buf, offset: payloadOffset, value: down ? UInt32(GFNInput.mouseBtnDown) : UInt32(GFNInput.mouseBtnUp))
        buf[payloadOffset + 4] = button
        writeTimestampBE(buf, offset: payloadOffset + 10, value: timestamp)
    }

    // MARK: Mouse Wheel

    // Packet (22 bytes): [UInt32 LE type][2B reserved][Int16 BE vert][6B reserved][UInt64 BE ts]

    func encodeMouseWheel(delta: Int16, into packet: EncodedInputPacket) {
        let timestamp = currentTimestamp()
        let payloadOffset = protocolVersion >= 3 ? 10 : 0
        let buf = packet.prepare(length: payloadOffset + GFNInput.mouseWheelPacketSize)
        writeSingleEventHeader(buf, timestamp: timestamp)
        writeUInt32LE(buf, offset: payloadOffset, value: UInt32(GFNInput.mouseWheel))
        writeInt16BE(buf, offset: payloadOffset + 6, value: delta)
        writeTimestampBE(buf, offset: payloadOffset + 14, value: timestamp)
    }

    private func writeSingleEventHeader(_ buf: UnsafeMutableRawBufferPointer, timestamp: UInt64) {
        guard protocolVersion >= 3 else { return }
        buf[0] = 0x23
        writeTimestampBE(buf, offset: 1, value: timestamp)
        buf[9] = 0x22
    }

    private func nextGamepadSequence(_ idx: Int) -> UInt16 {
        let current = gamepadSequence[idx] ?? 1
        gamepadSequence[idx] = current &+ 1 // wraps at 65535
        return current
    }

    // MARK: Write Helpers

    private func writeUInt16LE(_ buf: UnsafeMutableRawBufferPointer, offset: Int, value: UInt16) {
        buf[offset] = UInt8(value & 0xFF)
        buf[offset + 1] = UInt8(value >> 8)
    }

    private func writeTimestampLE(_ buf: UnsafeMutableRawBufferPointer, offset: Int, value: UInt64) {
        buf[offset] = UInt8(value & 0xFF)
        buf[offset + 1] = UInt8((value >> 8) & 0xFF)
        buf[offset + 2] = UInt8((value >> 16) & 0xFF)
        buf[offset + 3] = UInt8((value >> 24) & 0xFF)
        buf[offset + 4] = UInt8((value >> 32) & 0xFF)
        buf[offset + 5] = UInt8((value >> 40) & 0xFF)
        buf[offset + 6] = UInt8((value >> 48) & 0xFF)
        buf[offset + 7] = UInt8((value >> 56) & 0xFF)
    }

    private func writeUInt32LE(_ buf: UnsafeMutableRawBufferPointer, offset: Int, value: UInt32) {
        buf[offset] = UInt8(value & 0xFF)
        buf[offset + 1] = UInt8((value >> 8) & 0xFF)
        buf[offset + 2] = UInt8((value >> 16) & 0xFF)
        buf[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func writeUInt16BE(_ buf: UnsafeMutableRawBufferPointer, offset: Int, value: UInt16) {
        buf[offset] = UInt8(value >> 8)
        buf[offset + 1] = UInt8(value & 0xFF)
    }

    private func writeInt16BE(_ buf: UnsafeMutableRawBufferPointer, offset: Int, value: Int16) {
        let v = UInt16(bitPattern: value)
        buf[offset] = UInt8(v >> 8)
        buf[offset + 1] = UInt8(v & 0xFF)
    }

    private func writeInt16LE(_ buf: UnsafeMutableRawBufferPointer, offset: Int, value: Int16) {
        let v = UInt16(bitPattern: value)
        buf[offset] = UInt8(v & 0xFF)
        buf[offset + 1] = UInt8(v >> 8)
    }

    private func writeTimestampBE(_ buf: UnsafeMutableRawBufferPointer, offset: Int, value: UInt64) {
        buf[offset] = UInt8((value >> 56) & 0xFF)
        buf[offset + 1] = UInt8((value >> 48) & 0xFF)
        buf[offset + 2] = UInt8((value >> 40) & 0xFF)
        buf[offset + 3] = UInt8((value >> 32) & 0xFF)
        buf[offset + 4] = UInt8((value >> 24) & 0xFF)
        buf[offset + 5] = UInt8((value >> 16) & 0xFF)
        buf[offset + 6] = UInt8((value >> 8) & 0xFF)
        buf[offset + 7] = UInt8(value & 0xFF)
    }

    private func currentTimestamp() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }
}

// MARK: - GCController → XInput Mapping

func mapGCControllerToXInput(_ controller: GCController, deadzone: Float = 0.15) -> (
    buttons: UInt16, leftTrigger: UInt8, rightTrigger: UInt8,
    lx: Int16, ly: Int16, rx: Int16, ry: Int16
) {
    guard let pad = controller.extendedGamepad else {
        return (0, 0, 0, 0, 0, 0, 0)
    }

    var buttons: UInt16 = 0
    func pressed(_ e: GCControllerButtonInput) -> Bool {
        e.isPressed
    }

    if pressed(pad.dpad.up) { buttons |= GFNInput.dpadUp }
    if pressed(pad.dpad.down) { buttons |= GFNInput.dpadDown }
    if pressed(pad.dpad.left) { buttons |= GFNInput.dpadLeft }
    if pressed(pad.dpad.right) { buttons |= GFNInput.dpadRight }
    if pressed(pad.buttonMenu) { buttons |= GFNInput.start }
    if pressed(pad.buttonOptions ?? pad.buttonMenu) { buttons |= GFNInput.back }
    if let ls = pad.leftThumbstickButton, pressed(ls) { buttons |= GFNInput.ls }
    if let rs = pad.rightThumbstickButton, pressed(rs) { buttons |= GFNInput.rs }
    if pressed(pad.leftShoulder) { buttons |= GFNInput.lb }
    if pressed(pad.rightShoulder) { buttons |= GFNInput.rb }
    if pressed(pad.buttonA) { buttons |= GFNInput.buttonA }
    if pressed(pad.buttonB) { buttons |= GFNInput.buttonB }
    if pressed(pad.buttonX) { buttons |= GFNInput.buttonX }
    if pressed(pad.buttonY) { buttons |= GFNInput.buttonY }

    let lt = UInt8(clamping: Int(pad.leftTrigger.value * 255))
    let rt = UInt8(clamping: Int(pad.rightTrigger.value * 255))

    let (lx, ly) = radialDeadzone(
        x: pad.leftThumbstick.xAxis.value,
        y: pad.leftThumbstick.yAxis.value,
        deadzone: deadzone
    )
    let (rx, ry) = radialDeadzone(
        x: pad.rightThumbstick.xAxis.value,
        y: pad.rightThumbstick.yAxis.value,
        deadzone: deadzone
    )

    return (buttons, lt, rt, lx, ly, rx, ry)
}

private func radialDeadzone(x: Float, y: Float, deadzone: Float) -> (Int16, Int16) {
    let clampedX = max(-1, min(1, x))
    let clampedY = max(-1, min(1, y))
    let magnitude = (clampedX * clampedX + clampedY * clampedY).squareRoot()
    guard magnitude > deadzone, magnitude > 0 else { return (0, 0) }

    let scaled = min(1, (magnitude - deadzone) / (1 - deadzone))
    let factor = scaled / magnitude
    return (axisToInt16(clampedX * factor), axisToInt16(clampedY * factor))
}

private func axisToInt16(_ value: Float) -> Int16 {
    let clamped = max(-1, min(1, value))
    return Int16(clamped < 0 ? clamped * 32768 : clamped * 32767)
}

// MARK: - DataChannelSender

/// Abstracts the WebRTC data channel so the WebRTC dependency stays in GFNStreamController.
protocol DataChannelSender: AnyObject {
    func sendData(_ packet: EncodedInputPacket, completion: @escaping (InputSendDisposition) -> Void)
}

// MARK: - InputSender

/// Owns all mutable input state on one latency-sensitive serial queue.
final class InputSender {
    static let remoteSensitivity: Float = 250

    private struct OverlayPressState {
        var ticks = 0
        var triggered = false
    }

    private struct GamepadSnapshot: Equatable {
        let buttons: UInt16
        let leftTrigger: UInt8
        let rightTrigger: UInt8
        let leftStickX: Int16
        let leftStickY: Int16
        let rightStickX: Int16
        let rightStickY: Int16
        let bitmap: UInt8
    }

    /// Called when the user long-presses the overlay trigger button to toggle the GFN overlay.
    var menuToggleHandler: (() -> Void)?

    /// Called when remoteMode changes due to controller connect/disconnect auto-switching.
    var onRemoteModeChanged: ((RemoteInputMode) -> Void)?

    private weak var channel: DataChannelSender?
    private let encoder = InputEncoder()
    private let inputQueue = DispatchQueue(label: "com.cloudnow.input", qos: .userInteractive)
    private var packetPool = (0 ..< 16).map { _ in EncodedInputPacket() }
    private var sampler: DispatchSourceTimer?
    private var observations: [NSObjectProtocol] = []
    private var remoteMode: RemoteInputMode = .mouse
    private var deadzone: Float = 0.15
    private var overlayTriggerButton: OverlayTriggerButton = .start
    private var steamOverlayGestureEnabled = true
    private var isPaused = false

    private var extendedControllers: [GCController] = []
    private var microControllers: [GCController] = []
    private var controllerSlots: [ObjectIdentifier: Int] = [:]
    private var gamepadBitmap: UInt8 = 0
    private var lastButtons: [Int: UInt16] = [:]
    private var lastSnapshots: [Int: GamepadSnapshot] = [:]
    private var lastSnapshotSend: [Int: UInt64] = [:]

    private var lastMicroDpad: (x: Float, y: Float) = (0, 0)
    private var lastDualSenseTouchpad: (x: Float, y: Float) = (0, 0)
    private var pointerDelta: (x: Float, y: Float) = (0, 0)
    private var microPointerDelta: (x: Float, y: Float) = (0, 0)
    private var dualSensePointerDelta: (x: Float, y: Float) = (0, 0)
    private var lastHeartbeat: UInt64 = 0
    private var heldKeys: [UInt32: (vk: UInt16, scancode: UInt16, modifiers: UInt16)] = [:]
    private var heldMouseButtons = Set<UInt8>()

    private var overlayPresses: [Int: OverlayPressState] = [:]
    private var overlayReplaySlots = Set<Int>()
    private var steamHoldTicks: [Int: Int] = [:]
    private var steamTriggeredSlots = Set<Int>()
    private static let sampleInterval = 8_333_333
    private static let gamepadKeepAlive = UInt64(33_333_333)
    private static let heartbeatInterval = UInt64(2_000_000_000)
    private static let overlayLongPressThreshold = 216
    private static let steamLongPressThreshold = 120

    init(channel: DataChannelSender) {
        self.channel = channel
    }

    // MARK: Start / Stop

    func start() {
        inputQueue.sync {
            guard sampler == nil else { return }
            registerControllerNotifications()
            GCController.controllers().forEach { attachController($0, autoSwitch: false) }
            GCMouse.mice().forEach(setupMouseHandlers)

            // attachController(autoSwitch:false) won't promote the mode, so do it here for a controller present at start.
            if !extendedControllers.isEmpty, remoteMode == .mouse {
                remoteMode = .gamepad
                applyRemoteMode()
                notifyRemoteModeChanged()
            }

            lastHeartbeat = DispatchTime.now().uptimeNanoseconds
            let timer = DispatchSource.makeTimerSource(queue: inputQueue)
            timer.schedule(
                deadline: .now(),
                repeating: .nanoseconds(Self.sampleInterval),
                leeway: .microseconds(500)
            )
            timer.setEventHandler { [weak self] in self?.tick() }
            sampler = timer
            timer.resume()
        }
        GCController.startWirelessControllerDiscovery()
    }

    func stop() {
        inputQueue.sync {
            sampler?.setEventHandler {}
            sampler?.cancel()
            sampler = nil
            observations.forEach { NotificationCenter.default.removeObserver($0) }
            observations.removeAll()
            for extendedController in extendedControllers {
                clearControllerHandlers(extendedController)
                releaseControllerInput(extendedController)
                extendedController.playerIndex = .indexUnset
            }
            microControllers.forEach(clearControllerHandlers)
            GCMouse.mice().forEach(clearMouseHandlers)
            extendedControllers.removeAll()
            microControllers.removeAll()
        }
    }

    func configure(
        protocolVersion: Int,
        deadzone: Float,
        overlayTriggerButton: OverlayTriggerButton,
        steamOverlayGestureEnabled: Bool,
        remoteMode: RemoteInputMode
    ) {
        inputQueue.sync {
            encoder.setProtocolVersion(protocolVersion)
            self.deadzone = deadzone
            self.overlayTriggerButton = overlayTriggerButton
            self.steamOverlayGestureEnabled = steamOverlayGestureEnabled
            self.remoteMode = remoteMode
        }
    }

    func setPaused(_ paused: Bool) {
        inputQueue.async { [weak self] in
            guard let self, isPaused != paused else { return }
            isPaused = paused
            pointerDelta = (0, 0)
            microPointerDelta = (0, 0)
            dualSensePointerDelta = (0, 0)
            lastMicroDpad = (0, 0)
            lastDualSenseTouchpad = (0, 0)
            if paused {
                overlayPresses.removeAll()
                overlayReplaySlots.removeAll()
                steamHoldTicks.removeAll()
                steamTriggeredSlots.removeAll()
                releaseHeldDiscreteInputs()
                sendNeutralGamepads()
            } else {
                lastSnapshots.removeAll()
            }
        }
    }

    // MARK: Remote Mode

    func toggleRemoteMode() {
        inputQueue.async { [weak self] in
            guard let self else { return }
            switch remoteMode {
            case .mouse: remoteMode = .gamepad
            case .gamepad: remoteMode = .dualsense
            case .dualsense: remoteMode = .mouse
            }
            applyRemoteMode()
            notifyRemoteModeChanged()
        }
    }

    private func applyRemoteMode() {
        lastMicroDpad = (0, 0)
        lastDualSenseTouchpad = (0, 0)
        pointerDelta = (0, 0)
        microPointerDelta = (0, 0)
        dualSensePointerDelta = (0, 0)
        releaseHeldMouseButtons()
        overlayPresses.removeAll()
        overlayReplaySlots.removeAll()
        steamHoldTicks.removeAll()
        steamTriggeredSlots.removeAll()
        lastSnapshots.removeAll()
        for controller in extendedControllers {
            if remoteMode == .gamepad || remoteMode == .dualsense {
                claimControllerInput(controller)
            } else {
                releaseControllerInput(controller)
            }
        }
    }

    // MARK: Private — Tick

    private func sendEncoded(
        category: InputPacketCategory,
        gamepadSlot: Int? = nil,
        replaceableGamepadSnapshot: Bool = false,
        _ encode: (EncodedInputPacket) -> Void
    ) {
        let packet = packetPool.popLast() ?? EncodedInputPacket()
        packet.markGenerated(
            as: category,
            gamepadSlot: gamepadSlot,
            replaceableGamepadSnapshot: replaceableGamepadSnapshot
        )
        encode(packet)
        guard let channel else {
            packetPool.append(packet)
            return
        }
        channel.sendData(packet) { [weak self, packet] _ in
            self?.inputQueue.async { [weak self, packet] in
                self?.packetPool.append(packet)
            }
        }
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        if now &- lastHeartbeat >= Self.heartbeatInterval {
            lastHeartbeat = now
            sendEncoded(category: .heartbeat) { encoder.encodeHeartbeat(into: $0) }
        }
        guard !isPaused else { return }

        if remoteMode == .gamepad || remoteMode == .dualsense {
            for controller in extendedControllers.sorted(by: { slot(for: $0) < slot(for: $1) }) {
                sendGamepadState(for: controller, sampleOverlay: true, now: now)
            }

            if remoteMode == .dualsense,
               let controller = extendedControllers.first(where: { $0.extendedGamepad is GCDualSenseGamepad })
            {
                handleDualSenseTouchpad(controller)
            }

            if extendedControllers.isEmpty, let remote = microControllers.first {
                handleMicroGamepad(remote, now: now)
            }
        } else {
            overlayPresses.removeAll()
            overlayReplaySlots.removeAll()
            steamHoldTicks.removeAll()
            steamTriggeredSlots.removeAll()
            if let remote = microControllers.first {
                handleMicroGamepad(remote, now: now)
            }
        }
        flushPointerMotion()
    }

    private func handleMicroGamepad(_ controller: GCController, now: UInt64) {
        guard let pad = controller.microGamepad else { return }

        let curX = pad.dpad.xAxis.value
        let curY = pad.dpad.yAxis.value
        // Treat the touchpad as "not being touched" when position is near centre.
        // This prevents a snap-back mouseRel when the finger lifts and dpad returns to (0,0).
        let isTouching = abs(curX) > 0.02 || abs(curY) > 0.02
        let wasTouching = abs(lastMicroDpad.x) > 0.02 || abs(lastMicroDpad.y) > 0.02
        // Compute delta before updating the reference so we don't compare a value with itself.
        let dx = curX - lastMicroDpad.x
        let dy = curY - lastMicroDpad.y
        lastMicroDpad = (curX, curY)

        switch remoteMode {
        case .mouse:
            if isTouching, wasTouching {
                microPointerDelta.x += dx * Self.remoteSensitivity
                microPointerDelta.y += -dy * Self.remoteSensitivity
            } else {
                microPointerDelta = (0, 0)
            }

        case .gamepad:
            var buttons: UInt16 = 0
            if pad.dpad.up.isPressed { buttons |= GFNInput.dpadUp }
            if pad.dpad.down.isPressed { buttons |= GFNInput.dpadDown }
            if pad.dpad.left.isPressed { buttons |= GFNInput.dpadLeft }
            if pad.dpad.right.isPressed { buttons |= GFNInput.dpadRight }
            if pad.buttonA.isPressed { buttons |= GFNInput.buttonA }
            // buttonX (Play/Pause) is reserved for the overlay toggle — not forwarded to game

            sendGamepadSnapshot(
                GamepadSnapshot(
                    buttons: buttons,
                    leftTrigger: 0,
                    rightTrigger: 0,
                    leftStickX: 0,
                    leftStickY: 0,
                    rightStickX: 0,
                    rightStickY: 0,
                    bitmap: gamepadBitmap | 1
                ),
                slot: 0,
                now: now
            )

        case .dualsense:
            break // Siri Remote is suppressed in DualSense mode; touchpad handled separately
        }
    }

    private func handleDualSenseTouchpad(_ controller: GCController) {
        guard let dualSense = controller.extendedGamepad as? GCDualSenseGamepad else { return }
        let curX = dualSense.touchpadPrimary.xAxis.value
        let curY = dualSense.touchpadPrimary.yAxis.value

        let isTouching = abs(curX) > 0.02 || abs(curY) > 0.02
        let wasTouching = abs(lastDualSenseTouchpad.x) > 0.02 || abs(lastDualSenseTouchpad.y) > 0.02
        let dx = curX - lastDualSenseTouchpad.x
        let dy = curY - lastDualSenseTouchpad.y
        lastDualSenseTouchpad = (curX, curY)

        if isTouching, wasTouching {
            dualSensePointerDelta.x += dx * Self.remoteSensitivity
            dualSensePointerDelta.y += -dy * Self.remoteSensitivity
        } else {
            dualSensePointerDelta = (0, 0)
        }
    }

    private func handleExtendedValueChange(_ controller: GCController) {
        guard !isPaused,
              remoteMode == .gamepad || remoteMode == .dualsense,
              let slot = controllerSlots[ObjectIdentifier(controller)] else { return }

        let buttons = mapGCControllerToXInput(controller, deadzone: deadzone).buttons
        let previousButtons = lastButtons[slot] ?? buttons
        let changed = previousButtons ^ buttons
        lastButtons[slot] = buttons

        if changed & overlayButtonMask != 0 {
            if buttons & overlayButtonMask != 0 {
                overlayPresses[slot] = OverlayPressState()
            } else {
                finishOverlayPress(for: controller, slot: slot)
            }
        }

        guard changed & ~overlayButtonMask != 0 else { return }
        sendGamepadState(
            for: controller,
            sampleOverlay: false,
            now: DispatchTime.now().uptimeNanoseconds
        )
    }

    private func sendGamepadState(for controller: GCController, sampleOverlay: Bool, now: UInt64) {
        guard let slot = controllerSlots[ObjectIdentifier(controller)] else { return }
        var state = mapGCControllerToXInput(controller, deadzone: deadzone)
        lastButtons[slot] = state.buttons

        if sampleOverlay {
            if isOverlayButtonHeld(on: controller) {
                var press = overlayPresses[slot] ?? OverlayPressState()
                press.ticks += 1
                if !press.triggered, press.ticks >= Self.overlayLongPressThreshold {
                    press.triggered = true
                    notifyMenuToggle()
                }
                overlayPresses[slot] = press
            } else if overlayPresses[slot] != nil {
                finishOverlayPress(for: controller, slot: slot)
            }

            if steamOverlayGestureEnabled, isSteamButtonHeld(on: controller) {
                let ticks = (steamHoldTicks[slot] ?? 0) + 1
                steamHoldTicks[slot] = ticks
                if ticks >= Self.steamLongPressThreshold,
                   steamTriggeredSlots.insert(slot).inserted
                {
                    sendSteamOverlayChord()
                }
            } else {
                steamHoldTicks[slot] = nil
                steamTriggeredSlots.remove(slot)
            }
        }

        // The trigger is withheld for the entire gesture. A short press is replayed
        // as down/up on release; a long press is consumed by the local overlay.
        if overlayPresses[slot] != nil || isOverlayButtonHeld(on: controller) {
            state.buttons &= ~overlayButtonMask
        } else if overlayReplaySlots.contains(slot) {
            state.buttons |= overlayButtonMask
        }
        if steamTriggeredSlots.contains(slot) {
            state.buttons &= ~steamButtonMask
        }

        sendGamepadSnapshot(
            GamepadSnapshot(
                buttons: state.buttons,
                leftTrigger: state.leftTrigger,
                rightTrigger: state.rightTrigger,
                leftStickX: state.lx,
                leftStickY: state.ly,
                rightStickX: state.rx,
                rightStickY: state.ry,
                bitmap: gamepadBitmap
            ),
            slot: slot,
            now: now
        )
    }

    private func sendGamepadSnapshot(
        _ snapshot: GamepadSnapshot,
        slot: Int,
        now: UInt64 = DispatchTime.now().uptimeNanoseconds,
        force: Bool = false
    ) {
        let previous = lastSnapshots[slot]
        let lastSend = lastSnapshotSend[slot] ?? 0
        guard force || previous != snapshot || now &- lastSend >= Self.gamepadKeepAlive else {
            return
        }
        let returnedToNeutral = previous.map {
            isAnalogActive($0) && !isAnalogActive(snapshot)
        } ?? false
        let isReplaceable = !force
            && previous?.buttons == snapshot.buttons
            && previous?.bitmap == snapshot.bitmap
            && !returnedToNeutral
        lastSnapshots[slot] = snapshot
        lastSnapshotSend[slot] = now
        sendEncoded(
            category: .gamepadSnapshot,
            gamepadSlot: slot,
            replaceableGamepadSnapshot: isReplaceable
        ) {
            encoder.encodeGamepad(
                controllerId: slot,
                buttons: snapshot.buttons,
                leftTrigger: snapshot.leftTrigger,
                rightTrigger: snapshot.rightTrigger,
                leftStickX: snapshot.leftStickX,
                leftStickY: snapshot.leftStickY,
                rightStickX: snapshot.rightStickX,
                rightStickY: snapshot.rightStickY,
                gamepadBitmap: snapshot.bitmap,
                into: $0
            )
        }
    }

    private func isAnalogActive(_ snapshot: GamepadSnapshot) -> Bool {
        snapshot.leftTrigger != 0
            || snapshot.rightTrigger != 0
            || snapshot.leftStickX != 0
            || snapshot.leftStickY != 0
            || snapshot.rightStickX != 0
            || snapshot.rightStickY != 0
    }

    private func finishOverlayPress(for controller: GCController, slot: Int) {
        guard let press = overlayPresses.removeValue(forKey: slot) else { return }
        if !press.triggered { sendOverlayTap(for: controller, slot: slot) }
    }

    private func sendOverlayTap(for controller: GCController, slot: Int) {
        let state = mapGCControllerToXInput(controller, deadzone: deadzone)
        let baseButtons = state.buttons & ~overlayButtonMask
        let base = GamepadSnapshot(
            buttons: baseButtons,
            leftTrigger: state.leftTrigger,
            rightTrigger: state.rightTrigger,
            leftStickX: state.lx,
            leftStickY: state.ly,
            rightStickX: state.rx,
            rightStickY: state.ry,
            bitmap: gamepadBitmap
        )
        let down = GamepadSnapshot(
            buttons: base.buttons | overlayButtonMask,
            leftTrigger: base.leftTrigger,
            rightTrigger: base.rightTrigger,
            leftStickX: base.leftStickX,
            leftStickY: base.leftStickY,
            rightStickX: base.rightStickX,
            rightStickY: base.rightStickY,
            bitmap: base.bitmap
        )
        overlayReplaySlots.insert(slot)
        sendGamepadSnapshot(down, slot: slot, force: true)
        inputQueue.asyncAfter(deadline: .now() + .milliseconds(17)) { [weak self, weak controller] in
            guard let self,
                  let controller,
                  overlayReplaySlots.remove(slot) != nil,
                  controllerSlots[ObjectIdentifier(controller)] == slot else { return }
            let current = mapGCControllerToXInput(controller, deadzone: deadzone)
            sendGamepadSnapshot(
                GamepadSnapshot(
                    buttons: current.buttons & ~overlayButtonMask,
                    leftTrigger: current.leftTrigger,
                    rightTrigger: current.rightTrigger,
                    leftStickX: current.lx,
                    leftStickY: current.ly,
                    rightStickX: current.rx,
                    rightStickY: current.ry,
                    bitmap: gamepadBitmap
                ),
                slot: slot,
                force: true
            )
        }
    }

    private func sendNeutralGamepads() {
        if extendedControllers.isEmpty, remoteMode == .gamepad {
            sendGamepadSnapshot(neutralSnapshot(bitmap: gamepadBitmap | 1), slot: 0, force: true)
        } else {
            for controller in extendedControllers {
                guard let slot = controllerSlots[ObjectIdentifier(controller)] else { continue }
                sendGamepadSnapshot(neutralSnapshot(bitmap: gamepadBitmap), slot: slot, force: true)
            }
        }
    }

    private func neutralSnapshot(bitmap: UInt8) -> GamepadSnapshot {
        GamepadSnapshot(
            buttons: 0,
            leftTrigger: 0,
            rightTrigger: 0,
            leftStickX: 0,
            leftStickY: 0,
            rightStickX: 0,
            rightStickY: 0,
            bitmap: bitmap
        )
    }

    private var overlayButtonMask: UInt16 {
        overlayTriggerButton == .start ? GFNInput.start : GFNInput.back
    }

    private var steamButtonMask: UInt16 {
        overlayTriggerButton == .start ? GFNInput.back : GFNInput.start
    }

    private func isOverlayButtonHeld(on controller: GCController) -> Bool {
        guard let pad = controller.extendedGamepad else { return false }
        switch overlayTriggerButton {
        case .start: return pad.buttonMenu.isPressed
        case .options: return pad.buttonOptions?.isPressed ?? false
        }
    }

    private func isSteamButtonHeld(on controller: GCController) -> Bool {
        guard let pad = controller.extendedGamepad else { return false }
        switch overlayTriggerButton {
        case .start: return pad.buttonOptions?.isPressed ?? false
        case .options: return pad.buttonMenu.isPressed
        }
    }

    private func accumulatePointer(x: Float, y: Float) {
        pointerDelta.x += x
        pointerDelta.y += y
    }

    private func flushPointerMotion() {
        let physical = drainWholePixels(from: &pointerDelta)
        let micro = drainWholePixels(from: &microPointerDelta)
        let dualSense = drainWholePixels(from: &dualSensePointerDelta)
        let dx = Int16(clamping: physical.x + micro.x + dualSense.x)
        let dy = Int16(clamping: physical.y + micro.y + dualSense.y)
        guard dx != 0 || dy != 0 else { return }
        sendEncoded(category: .mouseMove) { encoder.encodeMouseMove(dx: dx, dy: dy, into: $0) }
    }

    private func drainWholePixels(from delta: inout (x: Float, y: Float)) -> (x: Int, y: Int) {
        let x = Int(delta.x.rounded(.towardZero))
        let y = Int(delta.y.rounded(.towardZero))
        delta.x -= Float(x)
        delta.y -= Float(y)
        return (x, y)
    }

    private func notifyMenuToggle() {
        let handler = menuToggleHandler
        DispatchQueue.main.async { handler?() }
    }

    private func notifyRemoteModeChanged() {
        let handler = onRemoteModeChanged
        let mode = remoteMode
        DispatchQueue.main.async { handler?(mode) }
    }

    private func sendMouseButtonNow(down: Bool, button: UInt8) {
        guard !isPaused else { return }
        if down {
            heldMouseButtons.insert(button)
        } else {
            heldMouseButtons.remove(button)
        }
        emitMouseButton(down: down, button: button)
    }

    private func sendMouseWheelNow(_ delta: Int16) {
        guard !isPaused else { return }
        sendEncoded(category: .mouseWheel) { encoder.encodeMouseWheel(delta: delta, into: $0) }
    }

    private func emitMouseButton(down: Bool, button: UInt8) {
        sendEncoded(category: .mouseButton) { encoder.encodeMouseButton(down: down, button: button, into: $0) }
    }

    private func emitKeyboard(
        down: Bool,
        vk: UInt16,
        scancode: UInt16,
        modifiers: UInt16
    ) {
        sendEncoded(category: .keyboard) {
            encoder.encodeKeyboard(
                down: down,
                vk: vk,
                scancode: scancode,
                modifiers: modifiers,
                into: $0
            )
        }
    }

    private func sendSteamOverlayChord() {
        let shiftVK: UInt16 = 0xA0
        let shiftScan: UInt16 = 0x2A
        let tabVK: UInt16 = 0x09
        let tabScan: UInt16 = 0x0F
        let shiftModifier: UInt16 = 0x0001

        emitKeyboard(down: true, vk: shiftVK, scancode: shiftScan, modifiers: shiftModifier)
        emitKeyboard(down: true, vk: tabVK, scancode: tabScan, modifiers: shiftModifier)
        inputQueue.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
            guard let self else { return }
            emitKeyboard(down: false, vk: tabVK, scancode: tabScan, modifiers: shiftModifier)
            emitKeyboard(down: false, vk: shiftVK, scancode: shiftScan, modifiers: 0)
        }
    }

    private func releaseHeldMouseButtons() {
        let buttons = heldMouseButtons.sorted()
        heldMouseButtons.removeAll()
        for button in buttons {
            emitMouseButton(down: false, button: button)
        }
    }

    private func releaseHeldDiscreteInputs() {
        releaseHeldMouseButtons()
        let keys = heldKeys
        heldKeys.removeAll()
        for key in keys.values {
            emitKeyboard(
                down: false,
                vk: key.vk,
                scancode: key.scancode,
                modifiers: key.modifiers
            )
        }
    }

    // MARK: Private — Controller Notifications

    private func registerControllerNotifications() {
        let center = NotificationCenter.default
        observations = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: nil) { [weak self] note in
                guard let controller = note.object as? GCController else { return }
                self?.inputQueue.async { [weak self] in
                    self?.attachController(controller, autoSwitch: true)
                }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: nil) { [weak self] note in
                guard let controller = note.object as? GCController else { return }
                self?.inputQueue.async { [weak self] in
                    self?.detachController(controller)
                }
            },
            center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: nil) { [weak self] note in
                guard let mouse = note.object as? GCMouse else { return }
                self?.inputQueue.async { [weak self] in
                    self?.setupMouseHandlers(for: mouse)
                }
            },
            center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: nil) { [weak self] note in
                guard let mouse = note.object as? GCMouse else { return }
                self?.inputQueue.async { [weak self] in
                    self?.clearMouseHandlers(for: mouse)
                }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.inputQueue.async { [weak self] in
                    self?.resyncConnectedDevices()
                }
            },
        ]
    }

    private func resyncConnectedDevices() {
        let connected = GCController.controllers()
        let stale = (extendedControllers + microControllers).filter { existing in
            !connected.contains(where: { $0 === existing })
        }
        stale.forEach { detachController($0, updateMode: false) }
        connected.forEach { attachController($0, autoSwitch: false) }
        GCMouse.mice().forEach(setupMouseHandlers)

        if extendedControllers.isEmpty, remoteMode != .mouse {
            remoteMode = .mouse
            applyRemoteMode()
            notifyRemoteModeChanged()
        }
    }

    private func setupMouseHandlers(for mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        mouse.handlerQueue = inputQueue

        input.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            guard let self, !self.isPaused else { return }
            accumulatePointer(x: deltaX, y: -deltaY)
        }

        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendMouseButtonNow(down: pressed, button: 1)
        }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendMouseButtonNow(down: pressed, button: 3)
        }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendMouseButtonNow(down: pressed, button: 2)
        }

        input.scroll.valueChangedHandler = { [weak self] _, _, yValue in
            guard let self, !self.isPaused else { return }
            let delta = Int16(clamping: Int((-yValue * 3).rounded()))
            if delta != 0 { sendMouseWheelNow(delta) }
        }
    }

    private func clearMouseHandlers(for mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = nil
        input.leftButton.pressedChangedHandler = nil
        input.rightButton?.pressedChangedHandler = nil
        input.middleButton?.pressedChangedHandler = nil
        input.scroll.valueChangedHandler = nil
    }

    private func claimControllerInput(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        // Prevent tvOS from intercepting any face/shoulder button as system navigation
        // (O/Circle and B are mapped to "back" by the OS by default)
        let buttons: [GCControllerButtonInput?] = [
            pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY,
            pad.buttonMenu, pad.buttonOptions,
            pad.leftShoulder, pad.rightShoulder,
            pad.leftTrigger, pad.rightTrigger,
            pad.leftThumbstickButton, pad.rightThumbstickButton,
        ]
        for btn in buttons.compactMap({ $0 }) {
            btn.preferredSystemGestureState = .disabled
        }
    }

    private func releaseControllerInput(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let buttons: [GCControllerButtonInput?] = [
            pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY,
            pad.buttonMenu, pad.buttonOptions,
            pad.leftShoulder, pad.rightShoulder,
            pad.leftTrigger, pad.rightTrigger,
            pad.leftThumbstickButton, pad.rightThumbstickButton,
        ]
        for btn in buttons.compactMap({ $0 }) {
            btn.preferredSystemGestureState = .enabled
        }
    }

    private func attachController(_ controller: GCController, autoSwitch: Bool) {
        controller.handlerQueue = inputQueue
        if let pad = controller.extendedGamepad {
            guard !extendedControllers.contains(where: { $0 === controller }),
                  let slot = firstFreeSlot else { return }
            extendedControllers.append(controller)
            controllerSlots[ObjectIdentifier(controller)] = slot
            controller.playerIndex = playerIndex(for: slot)
            gamepadBitmap |= 1 << UInt8(slot)
            lastButtons[slot] = mapGCControllerToXInput(controller, deadzone: deadzone).buttons
            pad.valueChangedHandler = { [weak self, weak controller] _, _ in
                guard let controller else { return }
                self?.handleExtendedValueChange(controller)
            }
            if let dualSense = pad as? GCDualSenseGamepad {
                dualSense.touchpadButton.pressedChangedHandler = { [weak self] _, _, pressed in
                    self?.sendDualSenseTouchpadButton(pressed)
                }
            }

            if autoSwitch && remoteMode == .mouse {
                remoteMode = .gamepad
                applyRemoteMode()
                notifyRemoteModeChanged()
            } else if remoteMode == .gamepad || remoteMode == .dualsense {
                claimControllerInput(controller)
            }
            sendGamepadSnapshot(neutralSnapshot(bitmap: gamepadBitmap), slot: slot, force: true)
            return
        }

        guard let pad = controller.microGamepad,
              !microControllers.contains(where: { $0 === controller }) else { return }
        microControllers.append(controller)
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendMicroButtonA(pressed)
        }
    }

    private func detachController(_ controller: GCController, updateMode: Bool = true) {
        clearControllerHandlers(controller)
        controller.playerIndex = .indexUnset
        let id = ObjectIdentifier(controller)
        if let slot = controllerSlots.removeValue(forKey: id) {
            extendedControllers.removeAll { $0 === controller }
            gamepadBitmap &= ~(1 << UInt8(slot))
            lastButtons[slot] = nil
            lastSnapshots[slot] = nil
            lastSnapshotSend[slot] = nil
            overlayPresses[slot] = nil
            overlayReplaySlots.remove(slot)
            steamHoldTicks[slot] = nil
            steamTriggeredSlots.remove(slot)
            sendGamepadSnapshot(neutralSnapshot(bitmap: gamepadBitmap), slot: slot, force: true)
            if updateMode, extendedControllers.isEmpty, remoteMode != .mouse {
                remoteMode = .mouse
                applyRemoteMode()
                notifyRemoteModeChanged()
            }
        } else {
            microControllers.removeAll { $0 === controller }
        }
    }

    private var firstFreeSlot: Int? {
        let used = Set(controllerSlots.values)
        return (0 ..< 4).first { !used.contains($0) }
    }

    private func playerIndex(for slot: Int) -> GCControllerPlayerIndex {
        switch slot {
        case 0: .index1
        case 1: .index2
        case 2: .index3
        case 3: .index4
        default: .indexUnset
        }
    }

    private func slot(for controller: GCController) -> Int {
        controllerSlots[ObjectIdentifier(controller)] ?? 4
    }

    private func clearControllerHandlers(_ controller: GCController) {
        controller.extendedGamepad?.valueChangedHandler = nil
        controller.microGamepad?.buttonA.pressedChangedHandler = nil
        (controller.extendedGamepad as? GCDualSenseGamepad)?.touchpadButton.pressedChangedHandler = nil
    }

    private func sendMicroButtonA(_ pressed: Bool) {
        guard remoteMode == .mouse else { return }
        sendMouseButtonNow(down: pressed, button: 1)
    }

    private func sendDualSenseTouchpadButton(_ pressed: Bool) {
        guard remoteMode == .dualsense else { return }
        sendMouseButtonNow(down: pressed, button: 1)
    }
}

// MARK: - InputSender: InputEventHandler

extension InputSender: InputEventHandler {
    func sendKeyEvent(down: Bool, keyCode: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) {
        inputQueue.async { [weak self] in
            guard let self,
                  !self.isPaused,
                  let mapping = Self.hidToKeyMapping[keyCode] else { return }
            let keyID = UInt32(mapping.vk) << 16 | UInt32(mapping.scancode)
            let currentModifiers = Self.gfnModifiers(from: modifiers)
            let encodedModifiers: UInt16
            if down {
                encodedModifiers = currentModifiers
                heldKeys[keyID] = (
                    vk: mapping.vk,
                    scancode: mapping.scancode,
                    modifiers: currentModifiers
                )
            } else {
                encodedModifiers = heldKeys.removeValue(forKey: keyID)?.modifiers ?? currentModifiers
            }
            emitKeyboard(
                down: down,
                vk: mapping.vk,
                scancode: mapping.scancode,
                modifiers: encodedModifiers
            )
        }
    }

    func sendMouseMove(dx: Int16, dy: Int16) {
        inputQueue.async { [weak self] in
            guard let self, !self.isPaused else { return }
            accumulatePointer(x: Float(dx), y: Float(dy))
        }
    }

    func sendMouseButton(down: Bool, button: UInt8) {
        inputQueue.async { [weak self] in
            self?.sendMouseButtonNow(down: down, button: button)
        }
    }

    func sendMouseWheel(delta: Int16) {
        inputQueue.async { [weak self] in self?.sendMouseWheelNow(delta) }
    }

    private static func gfnModifiers(from flags: UIKeyModifierFlags) -> UInt16 {
        var mods: UInt16 = 0
        if flags.contains(.shift) { mods |= 0x0001 }
        if flags.contains(.control) { mods |= 0x0002 }
        if flags.contains(.alternate) { mods |= 0x0004 }
        if flags.contains(.command) { mods |= 0x0008 }
        return mods
    }

    private static let hidToKeyMapping: [UIKeyboardHIDUsage: (vk: UInt16, scancode: UInt16)] = [
        .keyboardA: (0x41, 0x1E), .keyboardB: (0x42, 0x30), .keyboardC: (0x43, 0x2E),
        .keyboardD: (0x44, 0x20), .keyboardE: (0x45, 0x12), .keyboardF: (0x46, 0x21),
        .keyboardG: (0x47, 0x22), .keyboardH: (0x48, 0x23), .keyboardI: (0x49, 0x17),
        .keyboardJ: (0x4A, 0x24), .keyboardK: (0x4B, 0x25), .keyboardL: (0x4C, 0x26),
        .keyboardM: (0x4D, 0x32), .keyboardN: (0x4E, 0x31), .keyboardO: (0x4F, 0x18),
        .keyboardP: (0x50, 0x19), .keyboardQ: (0x51, 0x10), .keyboardR: (0x52, 0x13),
        .keyboardS: (0x53, 0x1F), .keyboardT: (0x54, 0x14), .keyboardU: (0x55, 0x16),
        .keyboardV: (0x56, 0x2F), .keyboardW: (0x57, 0x11), .keyboardX: (0x58, 0x2D),
        .keyboardY: (0x59, 0x15), .keyboardZ: (0x5A, 0x2C),

        .keyboard1: (0x31, 0x02), .keyboard2: (0x32, 0x03), .keyboard3: (0x33, 0x04),
        .keyboard4: (0x34, 0x05), .keyboard5: (0x35, 0x06), .keyboard6: (0x36, 0x07),
        .keyboard7: (0x37, 0x08), .keyboard8: (0x38, 0x09), .keyboard9: (0x39, 0x0A),
        .keyboard0: (0x30, 0x0B),

        .keyboardReturnOrEnter: (0x0D, 0x1C), .keyboardEscape: (0x1B, 0x01),
        .keyboardDeleteOrBackspace: (0x08, 0x0E), .keyboardTab: (0x09, 0x0F),
        .keyboardSpacebar: (0x20, 0x39), .keyboardCapsLock: (0x14, 0x3A),

        .keyboardHyphen: (0xBD, 0x0C), .keyboardEqualSign: (0xBB, 0x0D),
        .keyboardOpenBracket: (0xDB, 0x1A), .keyboardCloseBracket: (0xDD, 0x1B),
        .keyboardBackslash: (0xDC, 0x2B), .keyboardNonUSPound: (0xE2, 0x56),
        .keyboardSemicolon: (0xBA, 0x27), .keyboardQuote: (0xDE, 0x28),
        .keyboardGraveAccentAndTilde: (0xC0, 0x29), .keyboardComma: (0xBC, 0x33),
        .keyboardPeriod: (0xBE, 0x34), .keyboardSlash: (0xBF, 0x35),

        .keyboardF1: (0x70, 0x3B), .keyboardF2: (0x71, 0x3C), .keyboardF3: (0x72, 0x3D),
        .keyboardF4: (0x73, 0x3E), .keyboardF5: (0x74, 0x3F), .keyboardF6: (0x75, 0x40),
        .keyboardF7: (0x76, 0x41), .keyboardF8: (0x77, 0x42), .keyboardF9: (0x78, 0x43),
        .keyboardF10: (0x79, 0x44), .keyboardF11: (0x7A, 0x57), .keyboardF12: (0x7B, 0x58),
        .keyboardF13: (0x7C, 0x64),

        .keyboardInsert: (0x2D, 0xE052), .keyboardHome: (0x24, 0xE047),
        .keyboardPageUp: (0x21, 0xE049), .keyboardDeleteForward: (0x2E, 0xE053),
        .keyboardEnd: (0x23, 0xE04F), .keyboardPageDown: (0x22, 0xE051),
        .keyboardRightArrow: (0x27, 0xE04D), .keyboardLeftArrow: (0x25, 0xE04B),
        .keyboardDownArrow: (0x28, 0xE050), .keyboardUpArrow: (0x26, 0xE048),

        .keyboardPrintScreen: (0x2C, 0xE037), .keyboardScrollLock: (0x91, 0x46),
        .keyboardPause: (0x13, 0x45), .keyboardApplication: (0x5D, 0xE05D),

        .keypadNumLock: (0x90, 0xE045), .keypadSlash: (0x6F, 0xE035),
        .keypadAsterisk: (0x6A, 0x37), .keypadHyphen: (0x6D, 0x4A),
        .keypadPlus: (0x6B, 0x4E), .keypadEnter: (0x0D, 0xE01C),
        .keypad1: (0x61, 0x4F), .keypad2: (0x62, 0x50), .keypad3: (0x63, 0x51),
        .keypad4: (0x64, 0x4B), .keypad5: (0x65, 0x4C), .keypad6: (0x66, 0x4D),
        .keypad7: (0x67, 0x47), .keypad8: (0x68, 0x48), .keypad9: (0x69, 0x49),
        .keypad0: (0x60, 0x52), .keypadPeriod: (0x6E, 0x53),

        .keyboardLeftControl: (0xA2, 0x1D), .keyboardRightControl: (0xA3, 0xE01D),
        .keyboardLeftShift: (0xA0, 0x2A), .keyboardRightShift: (0xA1, 0x36),
        .keyboardLeftAlt: (0xA4, 0x38), .keyboardRightAlt: (0xA5, 0xE038),
        .keyboardLeftGUI: (0x5B, 0xE05B), .keyboardRightGUI: (0x5C, 0xE05C),
    ]
}
