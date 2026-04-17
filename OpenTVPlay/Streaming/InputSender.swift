import Foundation
import GameController

// MARK: - GFN Input Protocol Constants (from OpenNOW inputProtocol.ts)

private enum GFNInput {
    static let heartbeat: UInt8  = 2
    static let keyDown: UInt8    = 3
    static let keyUp: UInt8      = 4
    static let mouseRel: UInt8   = 7
    static let mouseBtnDown: UInt8 = 8
    static let mouseBtnUp: UInt8   = 9
    static let mouseWheel: UInt8   = 10
    static let gamepad: UInt8    = 12

    static let gamepadPacketSize = 38

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

// MARK: - Input Encoder

/// Encodes GCController events into GFN binary input protocol packets.
/// Supports protocol v2 (plain) and v3 (wrapped with 0x23 timestamp header).
final class InputEncoder {
    private var protocolVersion = 2
    private var gamepadSequence = [Int: UInt16]()

    func setProtocolVersion(_ v: Int) { protocolVersion = v }

    // MARK: Gamepad

    func encodeGamepad(
        controllerId: Int,
        buttons: UInt16,
        leftTrigger: UInt8,
        rightTrigger: UInt8,
        leftStickX: Int16,
        leftStickY: Int16,
        rightStickX: Int16,
        rightStickY: Int16,
        connected: Bool
    ) -> Data {
        var buf = Data(count: GFNInput.gamepadPacketSize)
        buf[0] = GFNInput.gamepad
        buf[1] = UInt8(controllerId & 0xFF)
        buf[2] = connected ? 1 : 0
        // buttons (little-endian uint16)
        buf[3] = UInt8(buttons & 0xFF)
        buf[4] = UInt8(buttons >> 8)
        buf[5] = leftTrigger
        buf[6] = rightTrigger
        // axes (little-endian int16)
        writeInt16LE(&buf, offset: 7, value: leftStickX)
        writeInt16LE(&buf, offset: 9, value: leftStickY)
        writeInt16LE(&buf, offset: 11, value: rightStickX)
        writeInt16LE(&buf, offset: 13, value: rightStickY)
        // timestamp (8 bytes, big-endian microseconds at offset 15)
        writeTimestampBE(&buf, offset: 15)
        // remaining bytes are zero padding to reach 38 bytes
        return protocolVersion >= 3
            ? wrapGamepadPartiallyReliable(buf, gamepadIndex: controllerId)
            : buf
    }

    // MARK: Heartbeat

    func encodeHeartbeat() -> Data {
        Data([GFNInput.heartbeat])
    }

    // MARK: Private Wrappers (Protocol v3)

    private func wrapGamepadPartiallyReliable(_ payload: Data, gamepadIndex: Int) -> Data {
        let seq = nextGamepadSequence(gamepadIndex)
        // [0x23][8B ts][0x26][1B idx][2B seq BE][0x21][2B size BE][payload]
        var buf = Data(count: 9 + 1 + 1 + 2 + 1 + 2 + payload.count)
        buf[0] = 0x23
        writeTimestampBE(&buf, offset: 1)
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
        gamepadSequence[idx] = current &+ 1  // UInt16 wraps automatically at 65535
        return current
    }

    private func writeInt16LE(_ buf: inout Data, offset: Int, value: Int16) {
        let v = UInt16(bitPattern: value)
        buf[offset]     = UInt8(v & 0xFF)
        buf[offset + 1] = UInt8(v >> 8)
    }

    private func writeTimestampBE(_ buf: inout Data, offset: Int) {
        let tsUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        buf[offset]     = UInt8((tsUs >> 56) & 0xFF)
        buf[offset + 1] = UInt8((tsUs >> 48) & 0xFF)
        buf[offset + 2] = UInt8((tsUs >> 40) & 0xFF)
        buf[offset + 3] = UInt8((tsUs >> 32) & 0xFF)
        buf[offset + 4] = UInt8((tsUs >> 24) & 0xFF)
        buf[offset + 5] = UInt8((tsUs >> 16) & 0xFF)
        buf[offset + 6] = UInt8((tsUs >>  8) & 0xFF)
        buf[offset + 7] = UInt8((tsUs      ) & 0xFF)
    }
}

// MARK: - GCController → XInput Mapping

func mapGCControllerToXInput(_ controller: GCController) -> (
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

    // XInput Y axis is inverted (positive = up)
    let lx = normalizeAxis(pad.leftThumbstick.xAxis.value)
    let ly = normalizeAxis(-pad.leftThumbstick.yAxis.value)
    let rx = normalizeAxis(pad.rightThumbstick.xAxis.value)
    let ry = normalizeAxis(-pad.rightThumbstick.yAxis.value)

    return (buttons, lt, rt, lx, ly, rx, ry)
}

private func normalizeAxis(_ v: Float) -> Int16 {
    let clamped = max(-1.0, min(1.0, v))
    if abs(clamped) < 0.15 { return 0 } // 15% deadzone
    return Int16(clamped < 0 ? clamped * 32768 : clamped * 32767)
}

// MARK: - InputSender

/// Monitors connected GCControllers and sends encoded input over a WebRTC data channel.
/// The data channel is abstracted through the `DataChannelSender` protocol so the
/// WebRTC dependency is only needed in GFNStreamController.
protocol DataChannelSender: AnyObject {
    func sendData(_ data: Data)
}

final class InputSender {
    private weak var channel: DataChannelSender?
    private let encoder = InputEncoder()
    private var sendTimer: Timer?
    private var observations: [NSObjectProtocol] = []

    init(channel: DataChannelSender) {
        self.channel = channel
    }

    // MARK: Start / Stop

    func start() {
        registerControllerNotifications()
        // Heartbeat at 0.5Hz — matches OpenNOW's 2-second interval
        sendTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        sendTimer?.invalidate()
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations.removeAll()
    }

    func setProtocolVersion(_ v: Int) {
        encoder.setProtocolVersion(v)
    }

    // MARK: Private

    private func tick() {
        let controllers = GCController.controllers()
        if controllers.isEmpty {
            channel?.sendData(encoder.encodeHeartbeat())
            return
        }
        for (idx, controller) in controllers.prefix(4).enumerated() {
            let (btns, lt, rt, lx, ly, rx, ry) = mapGCControllerToXInput(controller)
            let data = encoder.encodeGamepad(
                controllerId: idx,
                buttons: btns,
                leftTrigger: lt,
                rightTrigger: rt,
                leftStickX: lx,
                leftStickY: ly,
                rightStickX: rx,
                rightStickY: ry,
                connected: true
            )
            channel?.sendData(data)
        }
    }

    private func registerControllerNotifications() {
        let connectObs = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] notif in
            if let c = notif.object as? GCController {
                self?.controllerConnected(c)
            }
        }
        let disconnectObs = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] notif in
            if let c = notif.object as? GCController {
                self?.controllerDisconnected(c)
            }
        }
        observations = [connectObs, disconnectObs]
        GCController.startWirelessControllerDiscovery()
    }

    private func controllerConnected(_ controller: GCController) {
        let idx = GCController.controllers().firstIndex(where: { $0 === controller }) ?? 0
        let data = encoder.encodeGamepad(
            controllerId: idx, buttons: 0, leftTrigger: 0, rightTrigger: 0,
            leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0,
            connected: true
        )
        channel?.sendData(data)
    }

    private func controllerDisconnected(_ controller: GCController) {
        let idx = GCController.controllers().firstIndex(where: { $0 === controller }) ?? 0
        let data = encoder.encodeGamepad(
            controllerId: idx, buttons: 0, leftTrigger: 0, rightTrigger: 0,
            leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0,
            connected: false
        )
        channel?.sendData(data)
    }
}
