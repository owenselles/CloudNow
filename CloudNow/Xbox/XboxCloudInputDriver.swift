import Foundation
@preconcurrency import GameController
import Observation

nonisolated enum XboxCloudChannelProtocolError: Error, Equatable, Sendable {
    case invalidCorrelationVector
    case invalidHandshake
    case encodingFailed
}

nonisolated enum XboxCloudChannelProtocolCodec {
    private static let messageProtocolVersion = "messageV1"
    private static let maximumCorrelationVectorLength = 126

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
        _ value: String
    ) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let incremented = normalized + ".1"
        guard !normalized.isEmpty,
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

private nonisolated struct XboxCloudInputDataSink: Sendable {
    let sendInput: @Sendable (Data) -> XboxCloudDataSendDisposition
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
        count: 4
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

/// All mutable Xbox input state lives on one bounded latency-sensitive queue.
/// The unchecked conformance is safe because every mutable field below is
/// accessed only by `queue`; public entry points enqueue or synchronize work.
private final nonisolated class XboxCloudInputWorker: @unchecked Sendable {
    private struct ControllerSlot {
        let controller: GCController
        let identifier: ObjectIdentifier
        let haptics: ControllerHaptics?
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

    private static let controllerCapacity = 4
    private static let sampleIntervalNanoseconds = Int(
        XboxCloudInputStateCache.minimumSendIntervalNanoseconds
    )
    private static let maximumRumbleIterations = 8

    private let queue = DispatchQueue(
        label: "com.cloudnow.xbox-input",
        qos: .userInteractive
    )
    private let deadzone: Float
    private let rumbleEnabled: Bool
    private let rumbleIntensity: Float

    private var generation: UInt64 = 0
    private var sink: XboxCloudInputDataSink?
    private var readinessChanged: (@Sendable (UInt64, Bool) -> Void)?
    private var samplingTimer: DispatchSourceTimer?
    private var controllerSlots: [ControllerSlot?] = Array(
        repeating: nil,
        count: controllerCapacity
    )
    private var pendingControlUpdates: [Bool?] = Array(
        repeating: nil,
        count: controllerCapacity
    )
    private var rumblePlaybacks: [RumblePlayback?] = Array(
        repeating: nil,
        count: controllerCapacity
    )
    private var rumbleSequence: UInt64 = 0
    private var sampledStates: [XboxGamepadState] = []
    private var inputStateCache = XboxCloudInputStateCache()
    private var encoder = XboxLegacyInputEncoder()
    private var inputVersion: Int?
    private var messageHandshakeData: Data?
    private var isControlChannelOpen = false
    private var isInputChannelOpen = false
    private var isMessageChannelOpen = false
    private var didSendClientMetadata = false
    private var didSendMessageHandshake = false
    private var didReceiveMessageHandshake = false
    private var lastReportedReadiness = false

    init(
        deadzone: Float,
        rumbleEnabled: Bool,
        rumbleIntensity: Float
    ) {
        self.deadzone = deadzone
        self.rumbleEnabled = rumbleEnabled
        self.rumbleIntensity = rumbleIntensity
        sampledStates.reserveCapacity(Self.controllerCapacity)
    }

    func start(
        generation: UInt64,
        sink: XboxCloudInputDataSink,
        correlationVector: String,
        controllers: [GCController],
        readinessChanged: @escaping @Sendable (UInt64, Bool) -> Void
    ) {
        queue.sync {
            stopLocked()
            self.generation = generation
            self.sink = sink
            self.readinessChanged = readinessChanged
            messageHandshakeData = try? XboxCloudChannelProtocolCodec
                .messageHandshake(
                    id: UUID(),
                    correlationVector: correlationVector
                )
            controllers.forEach(attachControllerLocked)
            flushControlUpdatesLocked()

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

    func setNegotiatedInputVersion(
        _ version: Int,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            inputVersion = version
            didSendClientMetadata = false
            inputStateCache.reset()
            sampleAndFlushLocked()
        }
    }

    /// Forces one bounded controller snapshot through the existing sampler.
    /// Xbox uses input traffic alongside the REST heartbeat to keep an idle
    /// play session active. Invalidating slot zero avoids synthesizing input:
    /// the next report contains the controller's unchanged physical state.
    func sendKeepAlive(generation expectedGeneration: UInt64) {
        queue.async { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            inputStateCache.invalidate(index: 0)
            sendGamepadSnapshotLocked()
        }
    }

    func channelStateChanged(
        _ kind: XboxCloudDataChannelKind,
        isOpen: Bool,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            switch kind {
            case .control:
                isControlChannelOpen = isOpen
                if isOpen {
                    for index in controllerSlots.indices
                        where controllerSlots[index] != nil
                    {
                        pendingControlUpdates[index] = true
                    }
                }
            case .input:
                isInputChannelOpen = isOpen
                if isOpen {
                    didSendClientMetadata = false
                    inputStateCache.reset()
                }
            case .message:
                isMessageChannelOpen = isOpen
                if isOpen {
                    didSendMessageHandshake = false
                    didReceiveMessageHandshake = false
                }
            case .chat, .unreliableInput, .reliableInput:
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
        queue.async { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            switch kind {
            case .message:
                if XboxCloudChannelProtocolCodec
                    .isHandshakeAcknowledgement(data)
                {
                    didReceiveMessageHandshake = true
                    updateReadinessLocked()
                }
            case .input, .unreliableInput, .reliableInput:
                guard let inputVersion,
                      let feedback = try? XboxLegacyInputFeedbackDecoder.decode(
                          data,
                          version: inputVersion
                      )
                else {
                    return
                }
                if case let .rumble(command) = feedback {
                    applyRumbleLocked(command)
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
            flushControlUpdatesLocked()
        }
    }

    func detachController(
        _ controller: GCController,
        generation expectedGeneration: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            detachControllerLocked(controller)
            flushControlUpdatesLocked()
        }
    }

    private func stopLocked() {
        if isControlChannelOpen {
            for index in controllerSlots.indices
                where controllerSlots[index] != nil
            {
                sendControlUpdateLocked(index: index, wasAdded: false)
            }
        }

        samplingTimer?.setEventHandler {}
        samplingTimer?.cancel()
        samplingTimer = nil

        for index in controllerSlots.indices {
            cancelRumbleLocked(index: index)
            controllerSlots[index]?.haptics?.cleanup()
            controllerSlots[index] = nil
            pendingControlUpdates[index] = nil
        }
        sampledStates.removeAll(keepingCapacity: true)
        inputStateCache.reset()
        sink = nil
        readinessChanged = nil
        generation = 0
        inputVersion = nil
        messageHandshakeData = nil
        isControlChannelOpen = false
        isInputChannelOpen = false
        isMessageChannelOpen = false
        didSendClientMetadata = false
        didSendMessageHandshake = false
        didReceiveMessageHandshake = false
        lastReportedReadiness = false
        encoder = XboxLegacyInputEncoder()
    }

    private func attachControllerLocked(_ controller: GCController) {
        guard controller.extendedGamepad != nil else { return }
        let identifier = ObjectIdentifier(controller)
        guard !controllerSlots.contains(where: {
            $0?.identifier == identifier
        }),
            let index = controllerSlots.firstIndex(where: { $0 == nil })
        else {
            return
        }

        let haptics = rumbleEnabled
            ? ControllerHaptics(controller: controller)
            : nil
        haptics?.setIntensityScale(rumbleIntensity)
        controllerSlots[index] = ControllerSlot(
            controller: controller,
            identifier: identifier,
            haptics: haptics
        )
        inputStateCache.invalidate(index: index)
        pendingControlUpdates[index] = true
    }

    private func detachControllerLocked(_ controller: GCController) {
        let identifier = ObjectIdentifier(controller)
        guard let index = controllerSlots.firstIndex(where: {
            $0?.identifier == identifier
        }) else {
            return
        }

        cancelRumbleLocked(index: index)
        controllerSlots[index]?.haptics?.cleanup()
        controllerSlots[index] = nil
        inputStateCache.invalidate(index: index)
        pendingControlUpdates[index] = false
    }

    private func sampleAndFlushLocked() {
        flushControlUpdatesLocked()
        flushMessageHandshakeLocked()
        flushClientMetadataLocked()
        sendGamepadSnapshotLocked()
        updateReadinessLocked()
    }

    private func flushControlUpdatesLocked() {
        guard isControlChannelOpen, let sink else { return }
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
                pendingControlUpdates[index] = nil
            }
        }
    }

    private func sendControlUpdateLocked(index: Int, wasAdded: Bool) {
        guard let sink,
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

    private func flushClientMetadataLocked() {
        guard isInputChannelOpen,
              !didSendClientMetadata,
              let inputVersion,
              let sink
        else {
            return
        }
        do {
            guard let data = try encoder.encodeClientMetadata(
                version: inputVersion,
                timestampMilliseconds: Self.timestampMilliseconds()
            ) else {
                didSendClientMetadata = true
                return
            }
            didSendClientMetadata = sink.sendInput(data) == .accepted
        } catch {
            didSendClientMetadata = false
        }
    }

    private func sendGamepadSnapshotLocked() {
        guard isInputChannelOpen,
              didSendClientMetadata,
              let inputVersion,
              let sink
        else {
            return
        }
        let timestampNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard inputStateCache.canAttemptSend(
            at: timestampNanoseconds
        ) else {
            return
        }
        sampledStates.removeAll(keepingCapacity: true)
        for index in controllerSlots.indices {
            guard let controller = controllerSlots[index]?.controller,
                  let state = XboxCloudInputValueMapper.gamepadState(
                      controller: controller,
                      index: UInt8(index),
                      deadzone: deadzone
                  )
            else {
                continue
            }
            inputStateCache.appendIfDirty(state, to: &sampledStates)
        }
        guard !sampledStates.isEmpty,
              let data = try? encoder.encodeGamepads(
                  sampledStates,
                  version: inputVersion,
                  timestampMilliseconds: Double(timestampNanoseconds)
                      / 1_000_000
              )
        else {
            return
        }
        let disposition = sink.sendInput(data)
        inputStateCache.recordSendAttempt(
            sampledStates,
            at: timestampNanoseconds,
            accepted: disposition == .accepted
        )
    }

    private func updateReadinessLocked() {
        let nextValue = inputVersion != nil
            && isInputChannelOpen
            && didSendClientMetadata
            && isMessageChannelOpen
            && didReceiveMessageHandshake
        guard nextValue != lastReportedReadiness else { return }
        lastReportedReadiness = nextValue
        readinessChanged?(generation, nextValue)
    }

    private func applyRumbleLocked(_ command: XboxRumbleCommand) {
        let index = Int(command.gamepadIndex)
        guard rumbleEnabled,
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
        if leftTrigger > 0 {
            physicality.insert(.leftTrigger)
        }
        if rightTrigger > 0 {
            physicality.insert(.rightTrigger)
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
        if leftThumb.x != 0 {
            physicality.insert(.leftThumbXAxis)
        }
        if leftThumb.y != 0 {
            physicality.insert(.leftThumbYAxis)
        }
        if rightThumb.x != 0 {
            physicality.insert(.rightThumbXAxis)
        }
        if rightThumb.y != 0 {
            physicality.insert(.rightThumbYAxis)
        }

        return XboxGamepadState(
            index: index,
            buttons: buttons,
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

    @ObservationIgnored private weak var transport: XboxCloudWebRTCTransport?
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let worker: XboxCloudInputWorker
    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var attachmentGeneration: UInt64 = 0

    init(
        notificationCenter: NotificationCenter = .default,
        deadzone: Float = 0.15,
        rumbleEnabled: Bool = true,
        rumbleIntensity: Float = 1
    ) {
        self.notificationCenter = notificationCenter
        worker = XboxCloudInputWorker(
            deadzone: min(max(deadzone, 0), 0.95),
            rumbleEnabled: rumbleEnabled,
            rumbleIntensity: min(max(rumbleIntensity, 0), 1)
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

        transport.onChannelStateChanged = { [weak self] kind, isOpen in
            guard let self, attachmentGeneration == generation else { return }
            worker.channelStateChanged(
                kind,
                isOpen: isOpen,
                generation: generation
            )
        }
        transport.onChannelMessage = { [weak self] kind, data, _ in
            guard let self, attachmentGeneration == generation else { return }
            worker.received(data, on: kind, generation: generation)
        }
        installControllerObservers(generation: generation)

        let sink = XboxCloudInputDataSink(
            sendInput: { [weak transport] data in
                transport?.sendInput(data) ?? .channelUnavailable
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

    func setNegotiatedInputVersion(_ version: Int?) throws {
        guard let version, (1 ... 10).contains(version) else {
            throw XboxLegacyInputCodecError.unsupportedVersion
        }
        worker.setNegotiatedInputVersion(
            version,
            generation: attachmentGeneration
        )
    }

    func sendKeepAlive() {
        worker.sendKeepAlive(generation: attachmentGeneration)
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
        ]
    }
}
