import Foundation
import GameController

// MARK: - GFN Input Protocol Constants

private enum GFNInput {
    static let keyDown: UInt8      = 3
    static let keyUp: UInt8        = 4
    static let mouseRel: UInt8     = 7
    static let mouseBtnDown: UInt8 = 8
    static let mouseBtnUp: UInt8   = 9
    static let mouseWheel: UInt8   = 10
    static let gamepad: UInt8      = 12
    // Heartbeat type (u32 LE value 2) — keeps the server's virtual gamepad alive
    static let heartbeatU32: UInt32 = 2

    // Gamepad packet: 38 bytes, u32 LE type per GFN protocol
    static let gamepadPacketSize = 38
    // Keyboard/mouse packets use 4-byte UInt32 LE type (matches TS InputEncoder)
    static let keyboardPacketSize    = 18
    static let mouseButtonPacketSize = 18
    static let mouseMovePacketSize   = 22
    static let mouseWheelPacketSize  = 22

    // XInput button flags
    static let dpadUp: UInt16    = 0x0001
    static let dpadDown: UInt16  = 0x0002
    static let dpadLeft: UInt16  = 0x0004
    static let dpadRight: UInt16 = 0x0008
    static let start: UInt16     = 0x0010
    static let back: UInt16      = 0x0020
    static let ls: UInt16        = 0x0040
    static let rs: UInt16        = 0x0080
    static let lb: UInt16        = 0x0100
    static let rb: UInt16        = 0x0200
    static let guide: UInt16     = 0x0400
    static let buttonA: UInt16   = 0x1000
    static let buttonB: UInt16   = 0x2000
    static let buttonX: UInt16   = 0x4000
    static let buttonY: UInt16   = 0x8000
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
    func sendKeyEvent(down: Bool, vk: UInt16, scancode: UInt16, modifiers: UInt16)
    func sendMouseMove(dx: Int16, dy: Int16)
    func sendMouseButton(down: Bool, button: UInt8)
    func sendMouseWheel(delta: Int16)
}

// MARK: - Input Encoder

/// Encodes controller and HID input into GFN binary protocol packets.
/// Supports protocol v2 (plain) and v3 (wrapped with 0x23 timestamp header).
final class InputEncoder {
    private var protocolVersion = 2
    private var gamepadSequence = [Int: UInt16]()

    func setProtocolVersion(_ v: Int) { protocolVersion = v }

    // MARK: Heartbeat

    /// Sends a keep-alive to hold the server's virtual gamepad state between real input events.
    /// Encoded as a raw 4-byte u32 LE value 2 — no v3 wrapper (matches official client's Jc()).
    func encodeHeartbeat() -> Data {
        var buf = Data(count: 4)
        writeUInt32LE(&buf, offset: 0, value: GFNInput.heartbeatU32)
        return buf
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
        gamepadBitmap: UInt8
    ) -> Data {
        let timestamp = currentTimestamp()
        var buf = Data(count: GFNInput.gamepadPacketSize)
        writeUInt32LE(&buf, offset: 0,  value: 12)                        // type
        writeUInt16LE(&buf, offset: 4,  value: 26)                        // payload size
        writeUInt16LE(&buf, offset: 6,  value: UInt16(controllerId & 3))  // gamepad index
        writeUInt16LE(&buf, offset: 8,  value: UInt16(gamepadBitmap))     // connected-controller bitmask
        writeUInt16LE(&buf, offset: 10, value: 20)                        // inner payload size
        writeUInt16LE(&buf, offset: 12, value: buttons)                   // XInput buttons
        buf[14] = leftTrigger
        buf[15] = rightTrigger
        writeInt16LE(&buf, offset: 16, value: leftStickX)
        writeInt16LE(&buf, offset: 18, value: leftStickY)
        writeInt16LE(&buf, offset: 20, value: rightStickX)
        writeInt16LE(&buf, offset: 22, value: rightStickY)
        // buf[24–25]: reserved (zero)
        buf[26] = 0x55  // magic constant required by GFN protocol
        // buf[27–29]: reserved (zero)
        writeTimestampLE(&buf, offset: 30, value: timestamp)               // u64 LE microseconds
        return protocolVersion >= 3
            ? wrapGamepadPartiallyReliable(buf, gamepadIndex: controllerId, timestamp: timestamp)
            : buf
    }

    // MARK: Keyboard
    // Packet (18 bytes): [UInt32 LE type][UInt16 BE vk][UInt16 BE mods][UInt16 BE scan][UInt64 BE ts]

    func encodeKeyboard(down: Bool, vk: UInt16, scancode: UInt16, modifiers: UInt16) -> Data {
        let timestamp = currentTimestamp()
        var buf = Data(count: GFNInput.keyboardPacketSize)
        writeUInt32LE(&buf, offset: 0, value: down ? UInt32(GFNInput.keyDown) : UInt32(GFNInput.keyUp))
        writeUInt16BE(&buf, offset: 4, value: vk)
        writeUInt16BE(&buf, offset: 6, value: modifiers)
        writeUInt16BE(&buf, offset: 8, value: scancode)
        writeTimestampBE(&buf, offset: 10, value: timestamp)
        return wrapSingleEvent(buf, timestamp: timestamp)
    }

    // MARK: Mouse Move
    // Packet (22 bytes): [UInt32 LE type][Int16 BE dx][Int16 BE dy][6B reserved][UInt64 BE ts]

    func encodeMouseMove(dx: Int16, dy: Int16) -> Data {
        let timestamp = currentTimestamp()
        var buf = Data(count: GFNInput.mouseMovePacketSize)
        writeUInt32LE(&buf, offset: 0, value: UInt32(GFNInput.mouseRel))
        writeInt16BE(&buf, offset: 4, value: dx)
        writeInt16BE(&buf, offset: 6, value: dy)
        // bytes 8–13: reserved zeros (already zero from Data init)
        writeTimestampBE(&buf, offset: 14, value: timestamp)
        return wrapMouseMoveEvent(buf, timestamp: timestamp)
    }

    // MARK: Mouse Button
    // Packet (18 bytes): [UInt32 LE type][UInt8 button][1B pad][4B reserved][UInt64 BE ts]

    func encodeMouseButton(down: Bool, button: UInt8) -> Data {
        let timestamp = currentTimestamp()
        var buf = Data(count: GFNInput.mouseButtonPacketSize)
        writeUInt32LE(&buf, offset: 0, value: down ? UInt32(GFNInput.mouseBtnDown) : UInt32(GFNInput.mouseBtnUp))
        buf[4] = button
        // buf[5]: padding; buf[6–9]: reserved — all zero
        writeTimestampBE(&buf, offset: 10, value: timestamp)
        return wrapSingleEvent(buf, timestamp: timestamp)
    }

    // MARK: Mouse Wheel
    // Packet (22 bytes): [UInt32 LE type][2B reserved][Int16 BE vert][6B reserved][UInt64 BE ts]

    func encodeMouseWheel(delta: Int16) -> Data {
        let timestamp = currentTimestamp()
        var buf = Data(count: GFNInput.mouseWheelPacketSize)
        writeUInt32LE(&buf, offset: 0, value: UInt32(GFNInput.mouseWheel))
        // bytes 4–5: horizontal delta = 0
        writeInt16BE(&buf, offset: 6, value: delta)
        // bytes 8–13: reserved; timestamp at 14
        writeTimestampBE(&buf, offset: 14, value: timestamp)
        return wrapSingleEvent(buf, timestamp: timestamp)
    }

    // MARK: Private Wrappers (Protocol v3)

    /// v3: [0x23][8B ts BE][0x22][payload]  — keyboard, mouse button, mouse wheel
    private func wrapSingleEvent(_ payload: Data, timestamp: UInt64) -> Data {
        guard protocolVersion >= 3 else { return payload }
        var buf = Data(count: 10 + payload.count)
        buf[0] = 0x23
        writeTimestampBE(&buf, offset: 1, value: timestamp)
        buf[9] = 0x22
        buf.replaceSubrange(10..., with: payload)
        return buf
    }

    /// v3: [0x23][8B ts BE][0x21][2B len BE][payload]  — mouse move (coalesced path)
    private func wrapMouseMoveEvent(_ payload: Data, timestamp: UInt64) -> Data {
        guard protocolVersion >= 3 else { return payload }
        var buf = Data(count: 12 + payload.count)
        buf[0] = 0x23
        writeTimestampBE(&buf, offset: 1, value: timestamp)
        buf[9] = 0x21
        let len = UInt16(payload.count)
        buf[10] = UInt8(len >> 8)
        buf[11] = UInt8(len & 0xFF)
        buf.replaceSubrange(12..., with: payload)
        return buf
    }

    private func wrapGamepadPartiallyReliable(
        _ payload: Data,
        gamepadIndex: Int,
        timestamp: UInt64
    ) -> Data {
        let seq = nextGamepadSequence(gamepadIndex)
        // [0x23][8B ts][0x26][1B idx][2B seq BE][0x21][2B size BE][payload]
        var buf = Data(count: 9 + 1 + 1 + 2 + 1 + 2 + payload.count)
        buf[0] = 0x23
        writeTimestampBE(&buf, offset: 1, value: timestamp)
        buf[9]  = 0x26
        buf[10] = UInt8(gamepadIndex & 0xFF)
        buf[11] = UInt8(seq >> 8)
        buf[12] = UInt8(seq & 0xFF)
        buf[13] = 0x21
        buf[14] = UInt8(payload.count >> 8)
        buf[15] = UInt8(payload.count & 0xFF)
        buf.replaceSubrange(16..., with: payload)
        return buf
    }

    private func nextGamepadSequence(_ idx: Int) -> UInt16 {
        let current = gamepadSequence[idx] ?? 1
        gamepadSequence[idx] = current &+ 1  // wraps at 65535
        return current
    }

    // MARK: Write Helpers

    private func writeUInt16LE(_ buf: inout Data, offset: Int, value: UInt16) {
        buf[offset]     = UInt8(value & 0xFF)
        buf[offset + 1] = UInt8(value >> 8)
    }

    private func writeTimestampLE(_ buf: inout Data, offset: Int, value: UInt64) {
        buf[offset]     = UInt8(value        & 0xFF)
        buf[offset + 1] = UInt8((value >> 8)  & 0xFF)
        buf[offset + 2] = UInt8((value >> 16) & 0xFF)
        buf[offset + 3] = UInt8((value >> 24) & 0xFF)
        buf[offset + 4] = UInt8((value >> 32) & 0xFF)
        buf[offset + 5] = UInt8((value >> 40) & 0xFF)
        buf[offset + 6] = UInt8((value >> 48) & 0xFF)
        buf[offset + 7] = UInt8((value >> 56) & 0xFF)
    }

    private func writeUInt32LE(_ buf: inout Data, offset: Int, value: UInt32) {
        buf[offset]     = UInt8(value & 0xFF)
        buf[offset + 1] = UInt8((value >> 8) & 0xFF)
        buf[offset + 2] = UInt8((value >> 16) & 0xFF)
        buf[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func writeUInt16BE(_ buf: inout Data, offset: Int, value: UInt16) {
        buf[offset]     = UInt8(value >> 8)
        buf[offset + 1] = UInt8(value & 0xFF)
    }

    private func writeInt16BE(_ buf: inout Data, offset: Int, value: Int16) {
        let v = UInt16(bitPattern: value)
        buf[offset]     = UInt8(v >> 8)
        buf[offset + 1] = UInt8(v & 0xFF)
    }

    private func writeInt16LE(_ buf: inout Data, offset: Int, value: Int16) {
        let v = UInt16(bitPattern: value)
        buf[offset]     = UInt8(v & 0xFF)
        buf[offset + 1] = UInt8(v >> 8)
    }

    private func writeTimestampBE(_ buf: inout Data, offset: Int, value: UInt64) {
        buf[offset]     = UInt8((value >> 56) & 0xFF)
        buf[offset + 1] = UInt8((value >> 48) & 0xFF)
        buf[offset + 2] = UInt8((value >> 40) & 0xFF)
        buf[offset + 3] = UInt8((value >> 32) & 0xFF)
        buf[offset + 4] = UInt8((value >> 24) & 0xFF)
        buf[offset + 5] = UInt8((value >> 16) & 0xFF)
        buf[offset + 6] = UInt8((value >>  8) & 0xFF)
        buf[offset + 7] = UInt8((value      ) & 0xFF)
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
    func pressed(_ e: GCControllerButtonInput) -> Bool { e.isPressed }

    if pressed(pad.dpad.up)    { buttons |= GFNInput.dpadUp }
    if pressed(pad.dpad.down)  { buttons |= GFNInput.dpadDown }
    if pressed(pad.dpad.left)  { buttons |= GFNInput.dpadLeft }
    if pressed(pad.dpad.right) { buttons |= GFNInput.dpadRight }
    if pressed(pad.buttonMenu) { buttons |= GFNInput.start }
    if pressed(pad.buttonOptions ?? pad.buttonMenu) { buttons |= GFNInput.back }
    if let ls = pad.leftThumbstickButton,  pressed(ls) { buttons |= GFNInput.ls }
    if let rs = pad.rightThumbstickButton, pressed(rs) { buttons |= GFNInput.rs }
    if pressed(pad.leftShoulder)  { buttons |= GFNInput.lb }
    if pressed(pad.rightShoulder) { buttons |= GFNInput.rb }
    if pressed(pad.buttonA) { buttons |= GFNInput.buttonA }
    if pressed(pad.buttonB) { buttons |= GFNInput.buttonB }
    if pressed(pad.buttonX) { buttons |= GFNInput.buttonX }
    if pressed(pad.buttonY) { buttons |= GFNInput.buttonY }

    let lt = UInt8(clamping: Int(pad.leftTrigger.value * 255))
    let rt = UInt8(clamping: Int(pad.rightTrigger.value * 255))

    let lx = normalizeAxis(pad.leftThumbstick.xAxis.value, deadzone: deadzone)
    let ly = normalizeAxis(pad.leftThumbstick.yAxis.value, deadzone: deadzone)
    let rx = normalizeAxis(pad.rightThumbstick.xAxis.value, deadzone: deadzone)
    let ry = normalizeAxis(pad.rightThumbstick.yAxis.value, deadzone: deadzone)

    return (buttons, lt, rt, lx, ly, rx, ry)
}

private func normalizeAxis(_ v: Float, deadzone: Float) -> Int16 {
    let clamped = max(-1.0, min(1.0, v))
    if abs(clamped) < deadzone { return 0 }
    return Int16(clamped < 0 ? clamped * 32768 : clamped * 32767)
}

// MARK: - DataChannelSender

/// Abstracts the WebRTC data channel so the WebRTC dependency stays in GFNStreamController.
protocol DataChannelSender: AnyObject {
    func sendData(_ data: Data)
}

// MARK: - InputSender

/// Owns all mutable input state on one latency-sensitive serial queue.
final class InputSender {
    static let remoteSensitivity: Float = 250

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
    private var sampler: DispatchSourceTimer?
    private var observations: [NSObjectProtocol] = []
    private var remoteMode: RemoteInputMode = .mouse
    private var deadzone: Float = 0.15
    private var overlayTriggerButton: OverlayTriggerButton = .start
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

    private var overlayHoldTicks: [Int: Int] = [:]
    private var overlayTriggeredSlots = Set<Int>()
    private static let sampleInterval = 8_333_333
    private static let gamepadKeepAlive = UInt64(33_333_333)
    private static let heartbeatInterval = UInt64(2_000_000_000)
    private static let overlayLongPressThreshold = 216

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
            extendedControllers.forEach(clearControllerHandlers)
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
        remoteMode: RemoteInputMode
    ) {
        inputQueue.sync {
            encoder.setProtocolVersion(protocolVersion)
            self.deadzone = deadzone
            self.overlayTriggerButton = overlayTriggerButton
            self.remoteMode = remoteMode
        }
    }

    func setPaused(_ paused: Bool) {
        inputQueue.async { [weak self] in
            guard let self, self.isPaused != paused else { return }
            self.isPaused = paused
            self.pointerDelta = (0, 0)
            self.microPointerDelta = (0, 0)
            self.dualSensePointerDelta = (0, 0)
            self.lastMicroDpad = (0, 0)
            self.lastDualSenseTouchpad = (0, 0)
            if paused {
                self.sendNeutralGamepads()
            } else {
                self.lastSnapshots.removeAll()
            }
        }
    }

    // MARK: Remote Mode

    func toggleRemoteMode() {
        inputQueue.async { [weak self] in
            guard let self else { return }
            switch self.remoteMode {
            case .mouse:     self.remoteMode = .gamepad
            case .gamepad:   self.remoteMode = .dualsense
            case .dualsense: self.remoteMode = .mouse
            }
            self.applyRemoteMode()
            self.notifyRemoteModeChanged()
        }
    }

    private func applyRemoteMode() {
        lastMicroDpad = (0, 0)
        lastDualSenseTouchpad = (0, 0)
        pointerDelta = (0, 0)
        microPointerDelta = (0, 0)
        dualSensePointerDelta = (0, 0)
        overlayHoldTicks.removeAll()
        overlayTriggeredSlots.removeAll()
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

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        if now &- lastHeartbeat >= Self.heartbeatInterval {
            lastHeartbeat = now
            channel?.sendData(encoder.encodeHeartbeat())
        }
        guard !isPaused else { return }

        if remoteMode == .gamepad || remoteMode == .dualsense {
            for controller in extendedControllers.sorted(by: { slot(for: $0) < slot(for: $1) }) {
                sendGamepadState(for: controller, sampleOverlay: true, now: now)
            }

            if remoteMode == .dualsense,
               let controller = extendedControllers.first(where: { $0.extendedGamepad is GCDualSenseGamepad }) {
                handleDualSenseTouchpad(controller)
            }

            if extendedControllers.isEmpty, let remote = microControllers.first {
                handleMicroGamepad(remote, now: now)
            }
        } else {
            overlayHoldTicks.removeAll()
            overlayTriggeredSlots.removeAll()
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
        let isTouching  = abs(curX) > 0.02 || abs(curY) > 0.02
        let wasTouching = abs(lastMicroDpad.x) > 0.02 || abs(lastMicroDpad.y) > 0.02
        // Compute delta before updating the reference so we don't compare a value with itself.
        let dx = curX - lastMicroDpad.x
        let dy = curY - lastMicroDpad.y
        lastMicroDpad = (curX, curY)

        switch remoteMode {
        case .mouse:
            if isTouching && wasTouching {
                microPointerDelta.x += dx * Self.remoteSensitivity
                microPointerDelta.y += -dy * Self.remoteSensitivity
            } else {
                microPointerDelta = (0, 0)
            }

        case .gamepad:
            var buttons: UInt16 = 0
            if pad.dpad.up.isPressed    { buttons |= GFNInput.dpadUp }
            if pad.dpad.down.isPressed  { buttons |= GFNInput.dpadDown }
            if pad.dpad.left.isPressed  { buttons |= GFNInput.dpadLeft }
            if pad.dpad.right.isPressed { buttons |= GFNInput.dpadRight }
            if pad.buttonA.isPressed    { buttons |= GFNInput.buttonA }
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
            break  // Siri Remote is suppressed in DualSense mode; touchpad handled separately
        }
    }

    private func handleDualSenseTouchpad(_ controller: GCController) {
        guard let dualSense = controller.extendedGamepad as? GCDualSenseGamepad else { return }
        let curX = dualSense.touchpadPrimary.xAxis.value
        let curY = dualSense.touchpadPrimary.yAxis.value

        let isTouching  = abs(curX) > 0.02 || abs(curY) > 0.02
        let wasTouching = abs(lastDualSenseTouchpad.x) > 0.02 || abs(lastDualSenseTouchpad.y) > 0.02
        let dx = curX - lastDualSenseTouchpad.x
        let dy = curY - lastDualSenseTouchpad.y
        lastDualSenseTouchpad = (curX, curY)

        if isTouching && wasTouching {
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
        let changed = (lastButtons[slot] ?? buttons) ^ buttons
        lastButtons[slot] = buttons
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
                let ticks = (overlayHoldTicks[slot] ?? 0) + 1
                overlayHoldTicks[slot] = ticks
                if ticks == Self.overlayLongPressThreshold {
                    overlayTriggeredSlots.insert(slot)
                    notifyMenuToggle()
                }
            } else {
                overlayHoldTicks[slot] = 0
                overlayTriggeredSlots.remove(slot)
            }
        }
        if overlayTriggeredSlots.contains(slot) { state.buttons &= ~overlayButtonMask }

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
        let lastSend = lastSnapshotSend[slot] ?? 0
        guard force || lastSnapshots[slot] != snapshot || now &- lastSend >= Self.gamepadKeepAlive else {
            return
        }
        lastSnapshots[slot] = snapshot
        lastSnapshotSend[slot] = now
        channel?.sendData(encoder.encodeGamepad(
            controllerId: slot,
            buttons: snapshot.buttons,
            leftTrigger: snapshot.leftTrigger,
            rightTrigger: snapshot.rightTrigger,
            leftStickX: snapshot.leftStickX,
            leftStickY: snapshot.leftStickY,
            rightStickX: snapshot.rightStickX,
            rightStickY: snapshot.rightStickY,
            gamepadBitmap: snapshot.bitmap
        ))
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

    private func isOverlayButtonHeld(on controller: GCController) -> Bool {
        guard let pad = controller.extendedGamepad else { return false }
        switch overlayTriggerButton {
        case .start:   return pad.buttonMenu.isPressed
        case .options: return pad.buttonOptions?.isPressed ?? false
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
        channel?.sendData(encoder.encodeMouseMove(dx: dx, dy: dy))
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
        channel?.sendData(encoder.encodeMouseButton(down: down, button: button))
    }

    private func sendMouseWheelNow(_ delta: Int16) {
        guard !isPaused else { return }
        channel?.sendData(encoder.encodeMouseWheel(delta: delta))
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
        ]
    }

    private func setupMouseHandlers(for mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        mouse.handlerQueue = inputQueue

        input.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            guard let self, !self.isPaused else { return }
            self.accumulatePointer(x: deltaX, y: -deltaY)
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
            if delta != 0 { self.sendMouseWheelNow(delta) }
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

    private func detachController(_ controller: GCController) {
        clearControllerHandlers(controller)
        let id = ObjectIdentifier(controller)
        if let slot = controllerSlots.removeValue(forKey: id) {
            extendedControllers.removeAll { $0 === controller }
            gamepadBitmap &= ~(1 << UInt8(slot))
            lastButtons[slot] = nil
            lastSnapshots[slot] = nil
            lastSnapshotSend[slot] = nil
            overlayHoldTicks[slot] = nil
            overlayTriggeredSlots.remove(slot)
            sendGamepadSnapshot(neutralSnapshot(bitmap: gamepadBitmap), slot: slot, force: true)
            if extendedControllers.isEmpty && remoteMode != .mouse {
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
        return (0..<4).first { !used.contains($0) }
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
    func sendKeyEvent(down: Bool, vk: UInt16, scancode: UInt16, modifiers: UInt16) {
        inputQueue.async { [weak self] in
            guard let self, !self.isPaused else { return }
            self.channel?.sendData(
                self.encoder.encodeKeyboard(down: down, vk: vk, scancode: scancode, modifiers: modifiers)
            )
        }
    }

    func sendMouseMove(dx: Int16, dy: Int16) {
        inputQueue.async { [weak self] in
            guard let self, !self.isPaused else { return }
            self.accumulatePointer(x: Float(dx), y: Float(dy))
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
}
