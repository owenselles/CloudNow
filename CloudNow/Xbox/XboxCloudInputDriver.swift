import Foundation
@preconcurrency import GameController
import Observation
import os

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
    /// Public access key sent by Microsoft's Xbox web client after its input
    /// registration. Authorized quality updates follow on the same channel.
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
        isOpen && !didSendAuthorization
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
/// precedes authorization; the preferred resolution is an authorized update.
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

    var canSendResolutionUpdate: Bool {
        canSendAuthorization && didSendAuthorization
    }

    var canSendAuthorization: Bool {
        isTransportReady
            && hasInputVersion
            && isInputChannelOpen
            && didSendClientMetadata
            && !hasPendingControlUpdates
            && initialControllerReportSatisfied
    }

    func isPublishedReady(
        isMessageChannelOpen: Bool,
        didReceiveMessageHandshake: Bool
    ) -> Bool {
        canSendAuthorization
            && didSendAuthorization
            && didSendResolutionUpdate
            && isMessageChannelOpen
            && didReceiveMessageHandshake
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

nonisolated enum XboxModernControllerSlotPolicy {
    static func selectedSlot(
        current: Int?,
        occupiedSlots: [Bool]
    ) -> Int? {
        if let current,
           occupiedSlots.indices.contains(current),
           occupiedSlots[current]
        {
            return current
        }
        return occupiedSlots.firstIndex(of: true)
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
    private let inboundMessageBudget = OSAllocatedUnfairLock(
        initialState: XboxCloudInboundMessageBudget()
    )
    private let deadzone: Float
    private let rumbleEnabled: Bool
    private let rumbleIntensity: Float
    private let preferredResolution: XboxCloudDisplayResolution

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
    private var modernControllerSlotIndex: Int?
    private var encoder = XboxLegacyInputEncoder()
    private var inputMode: XboxCloudInputTransportMode?
    private var controlAuthorizationData: Data?
    private var messageHandshakeData: Data?
    private var resolutionUpdateData: Data?
    private var controlSendState = XboxCloudControlSendState()
    private var isTransportReady = false
    private var isInputChannelOpen = false
    private var isReliableInputChannelOpen = false
    private var isUnreliableInputChannelOpen = false
    private var isMessageChannelOpen = false
    private var didSendClientMetadata = false
    private var didSendInitialControllerReport = false
    private var didSendMessageHandshake = false
    private var didReceiveMessageHandshake = false
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
        preferredResolution: XboxCloudDisplayResolution
    ) {
        self.deadzone = deadzone
        self.rumbleEnabled = rumbleEnabled
        self.rumbleIntensity = rumbleIntensity
        self.preferredResolution = preferredResolution
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
            inboundMessageBudget.withLock {
                $0.activate(generation: generation)
            }
            self.sink = sink
            self.readinessChanged = readinessChanged
            controlAuthorizationData = try? XboxCloudChannelProtocolCodec
                .authorizationRequest()
            messageHandshakeData = try? XboxCloudChannelProtocolCodec
                .messageHandshake(
                    id: UUID(),
                    correlationVector: correlationVector
                )
            resolutionUpdateData = try? XboxCloudChannelProtocolCodec
                .userRequestedResolutionUpdate(
                    resolution: preferredResolution
                )
            controllers.forEach(attachControllerLocked)
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
            if case .unreliable = mode {
                resetModernInputStateLocked()
            } else {
                modernInputState.reset()
                modernInputSendCadence.reset()
                modernControllerSlotIndex = nil
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

    /// Keeps the controller path alive alongside the REST heartbeat. Legacy
    /// input invalidates its cache; V2 emits Xbox's bounded virtual-axis pulse.
    func sendKeepAlive(generation expectedGeneration: UInt64) {
        queue.async { [weak self] in
            guard let self, generation == expectedGeneration else { return }
            guard !isPaused else {
                sendPausedNeutralSnapshotLocked()
                return
            }
            if case let .unreliable(_, version) = inputMode {
                _ = modernInputState.recordVirtualKeepAlive()
                sendPendingModernGamepadSnapshotLocked(version: version)
            } else {
                inputStateCache.invalidate(index: 0)
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
            switch kind {
            case .control:
                if !isOpen {
                    isTransportReady = false
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
                            modernControllerSlotIndex = nil
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
                    isTransportReady = false
                }
                isMessageChannelOpen = isOpen
                if isOpen {
                    didSendMessageHandshake = false
                    didReceiveMessageHandshake = false
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
        sink = nil
        readinessChanged = nil
        inboundMessageBudget.withLock {
            $0.deactivate(generation: generation)
        }
        generation = 0
        inputMode = nil
        controlAuthorizationData = nil
        messageHandshakeData = nil
        resolutionUpdateData = nil
        controlSendState.reset()
        isTransportReady = false
        isInputChannelOpen = false
        isReliableInputChannelOpen = false
        isUnreliableInputChannelOpen = false
        isMessageChannelOpen = false
        didSendClientMetadata = false
        didSendInitialControllerReport = false
        didSendMessageHandshake = false
        didReceiveMessageHandshake = false
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
        modernControllerSlotIndex = nil
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
            let previousSlot = modernControllerSlotIndex
            selectModernControllerSlotLocked()
            if previousSlot == nil, modernControllerSlotIndex != nil {
                modernInputState.attach()
                pendingControlUpdates[0] =
                    XboxCloudControllerRegistrationPolicy.pendingUpdate(
                        isAttached: true,
                        isRegistered: registeredControllerPresence[0]
                    )
            }
        } else {
            pendingControlUpdates[index] = XboxCloudControllerRegistrationPolicy
                .pendingUpdate(
                    isAttached: true,
                    isRegistered: registeredControllerPresence[index]
                )
        }
        if isPaused {
            needsPausedNeutralSnapshot = true
        }
        let controllerCount = attachedControllerCount
        xboxInputLog.notice(
            "[Controller] attached slot=\(index, privacy: .public) total=\(controllerCount, privacy: .public)"
        )
    }

    private func detachControllerLocked(_ controller: GCController) {
        let identifier = ObjectIdentifier(controller)
        guard let index = controllerSlots.firstIndex(where: {
            $0?.identifier == identifier
        }) else {
            return
        }

        let wasModernActiveController = if case .unreliable = inputMode {
            modernControllerSlotIndex == index
        } else {
            false
        }
        cancelRumbleLocked(index: index)
        releaseControllerLocked(index: index)
        inputStateCache.invalidate(index: index)
        if case .unreliable = inputMode {
            selectModernControllerSlotLocked()
            if modernControllerSlotIndex == nil {
                modernInputState.detach()
                pendingControlUpdates[0] =
                    XboxCloudControllerRegistrationPolicy.pendingUpdate(
                        isAttached: false,
                        isRegistered: registeredControllerPresence[0]
                    )
            } else if wasModernActiveController {
                recordActiveModernControllerStateLocked()
            }
        } else {
            pendingControlUpdates[index] = XboxCloudControllerRegistrationPolicy
                .pendingUpdate(
                    isAttached: false,
                    isRegistered: registeredControllerPresence[index]
                )
        }
        let controllerCount = attachedControllerCount
        xboxInputLog.notice(
            "[Controller] detached slot=\(index, privacy: .public) total=\(controllerCount, privacy: .public)"
        )
    }

    private func sampleAndFlushLocked() {
        flushMessageHandshakeLocked()
        flushClientMetadataLocked()
        flushControlUpdatesLocked()
        if isPaused {
            sendPausedNeutralSnapshotLocked()
        } else {
            sendGamepadSnapshotLocked()
        }
        flushControlAuthorizationLocked()
        flushResolutionUpdateLocked()
        updateReadinessLocked()
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
                "[Control] preferred resolution queued alias=\(resolutionAlias, privacy: .public) authorized=true"
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

    private func sendGamepadSnapshotLocked() {
        guard let inputMode else { return }
        switch inputMode {
        case let .legacy(version):
            sendLegacyGamepadSnapshotLocked(version: version)
        case let .unreliable(_, unreliableVersion):
            sendModernGamepadSnapshotLocked(version: unreliableVersion)
        }
    }

    private func sendLegacyGamepadSnapshotLocked(version: Int) {
        guard !isPaused,
              bootstrapState.canSendControllerReport,
              isInputChannelOpen,
              didSendClientMetadata,
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
        guard !sampledStates.isEmpty else {
            didSendInitialControllerReport = true
            return
        }
        guard let data = try? encoder.encodeGamepads(
            sampledStates,
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
        }
        if disposition == .accepted, !didLogFirstInputReport {
            didLogFirstInputReport = true
            let reportCount = sampledStates.count
            xboxInputLog.notice(
                "[Input] first controller report queued count=\(reportCount, privacy: .public)"
            )
        }
    }

    private func sendModernGamepadSnapshotLocked(version: Int) {
        guard !isPaused,
              bootstrapState.canSendControllerReport,
              isUnreliableInputChannelOpen,
              didSendClientMetadata
        else {
            return
        }
        if let modernControllerSlotIndex,
           controllerSlots.indices.contains(modernControllerSlotIndex),
           let controller = controllerSlots[modernControllerSlotIndex]?.controller,
           let state = XboxCloudInputValueMapper.gamepadState(
               controller: controller,
               index: 0,
               deadzone: deadzone
           )
        {
            _ = modernInputState.record(state)
        }
        sendPendingModernGamepadSnapshotLocked(version: version)
    }

    private func sendPendingModernGamepadSnapshotLocked(version: Int) {
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
              modernInputSendCadence.canAttempt(
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
        guard !sampledStates.isEmpty else {
            needsPausedNeutralSnapshot = false
            return
        }
        let timestampNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard let data = try? encoder.encodeGamepads(
            sampledStates,
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
        guard attachedControllerCount > 0 else {
            needsPausedNeutralSnapshot = false
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
            _ = modernInputState.record(XboxGamepadState(index: 0))
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
            isMessageChannelOpen: isMessageChannelOpen,
            didReceiveMessageHandshake: didReceiveMessageHandshake
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
            hasPendingControlUpdates: pendingControlUpdates.contains {
                $0 != nil
            },
            hasAttachedController: attachedControllerCount > 0,
            didSendInitialControllerReport: didSendInitialControllerReport,
            didSendAuthorization: controlSendState.didSendAuthorization,
            didSendResolutionUpdate: controlSendState.didSendResolutionUpdate
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
        selectModernControllerSlotLocked()
        if modernControllerSlotIndex != nil {
            modernInputState.attach()
        }
    }

    private func selectModernControllerSlotLocked() {
        modernControllerSlotIndex = XboxModernControllerSlotPolicy.selectedSlot(
            current: modernControllerSlotIndex,
            occupiedSlots: controllerSlots.map { $0 != nil }
        )
    }

    private func recordActiveModernControllerStateLocked() {
        guard let modernControllerSlotIndex,
              controllerSlots.indices.contains(modernControllerSlotIndex),
              let controller = controllerSlots[modernControllerSlotIndex]?.controller
        else {
            return
        }
        if !modernInputState.isAttached {
            modernInputState.attach()
        }
        if isPaused {
            _ = modernInputState.record(XboxGamepadState(index: 0))
        } else if let state = XboxCloudInputValueMapper.gamepadState(
            controller: controller,
            index: 0,
            deadzone: deadzone
        ) {
            _ = modernInputState.record(state)
        }
    }

    private func resetControllerRegistrationLocked(controlIsOpen: Bool) {
        for index in controllerSlots.indices {
            registeredControllerPresence[index] = false
            pendingControlUpdates[index] = nil
        }
        guard controlIsOpen else { return }
        if case .unreliable = inputMode {
            pendingControlUpdates[0] =
                XboxCloudControllerRegistrationPolicy.pendingUpdate(
                    isAttached: attachedControllerCount > 0,
                    isRegistered: false
                )
            return
        }
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
        if case .unreliable = inputMode {
            guard index == 0 else { return nil }
            return modernControllerSlotIndex
        }
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
        guard controllerSlots.contains(where: {
            $0?.identifier == identifier
        }) else {
            return
        }
        if !didLogFirstControllerActivity {
            didLogFirstControllerActivity = true
            xboxInputLog.notice("[Controller] first input observed")
        }
        sendGamepadSnapshotLocked()
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
        preferredResolution: XboxCloudDisplayResolution = .automatic
    ) {
        self.notificationCenter = notificationCenter
        worker = XboxCloudInputWorker(
            deadzone: min(max(deadzone, 0), 0.95),
            rumbleEnabled: rumbleEnabled,
            rumbleIntensity: min(max(rumbleIntensity, 0), 1),
            preferredResolution: preferredResolution
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
        ]
    }
}
