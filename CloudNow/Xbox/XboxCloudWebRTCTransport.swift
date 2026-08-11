import Foundation
@preconcurrency import LiveKitWebRTC
import Observation
import os

private nonisolated let xboxWebRTCLog = Logger(
    subsystem: "com.owenselles.CloudNow2",
    category: "XboxWebRTC"
)

/// Allowlisted view of Microsoft's otherwise opaque streaming overrides.
/// Unknown keys and incorrectly typed values deliberately remain inert.
nonisolated struct XboxCloudServiceStreamingOverrides: Equatable, Sendable {
    let enableHEVC: Bool?

    init(_ value: XboxCloudJSONValue?) {
        guard case let .object(root)? = value,
              case let .object(videoConfiguration)? = root["videoConfiguration"],
              case let .boolean(enableHEVC)? = videoConfiguration["enableHevc"]
        else {
            enableHEVC = nil
            return
        }
        self.enableHEVC = enableHEVC
    }
}

/// Provider-neutral value snapshot used to derive a safe ordering from the
/// capabilities reported by WebRTC. `associatedPayloadType` models RTX's apt.
nonisolated struct XboxCloudVideoCodecCapability: Equatable, Sendable {
    let name: String
    let preferredPayloadType: Int?
    let associatedPayloadType: Int?

    init(
        name: String,
        preferredPayloadType: Int? = nil,
        associatedPayloadType: Int? = nil
    ) {
        self.name = name
        self.preferredPayloadType = preferredPayloadType
        self.associatedPayloadType = associatedPayloadType
    }
}

nonisolated enum XboxCloudVideoCodecPreferencePolicy {
    /// Returns capability indexes in preference order, or `nil` when WebRTC's
    /// default order is safer. Enabling HEVC keeps every fallback codec;
    /// disabling it also removes repair codecs associated with HEVC payloads.
    static func preferredCapabilityIndexes(
        _ capabilities: [XboxCloudVideoCodecCapability],
        enableHEVC: Bool?
    ) -> [Int]? {
        guard let enableHEVC else { return nil }
        let hevcIndexes = capabilities.indices.filter {
            isHEVC(capabilities[$0].name)
        }
        guard !hevcIndexes.isEmpty else { return nil }

        let hevcPayloadTypes = Set(hevcIndexes.compactMap {
            capabilities[$0].preferredPayloadType
        })
        let associatedHEVCIndexes = capabilities.indices.filter { index in
            guard let associatedPayloadType = capabilities[index]
                .associatedPayloadType
            else {
                return false
            }
            return hevcPayloadTypes.contains(associatedPayloadType)
        }
        let hevcGroup = Set(hevcIndexes + associatedHEVCIndexes)

        if enableHEVC {
            return capabilities.indices.filter(hevcGroup.contains)
                + capabilities.indices.filter { !hevcGroup.contains($0) }
        }

        var remaining = capabilities.indices.filter { !hevcGroup.contains($0) }
        let remainingPayloadTypes = Set(remaining.compactMap {
            capabilities[$0].preferredPayloadType
        })
        remaining.removeAll { index in
            guard let associatedPayloadType = capabilities[index]
                .associatedPayloadType
            else {
                return false
            }
            return !remainingPayloadTypes.contains(associatedPayloadType)
        }
        guard remaining.contains(where: {
            !isAuxiliaryCodec(capabilities[$0].name)
        }) else {
            return nil
        }
        return remaining
    }

    private static func isHEVC(_ name: String) -> Bool {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "h265", "hevc":
            true
        default:
            false
        }
    }

    private static func isAuxiliaryCodec(_ name: String) -> Bool {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "rtx", "red", "ulpfec", "flexfec", "flexfec-03":
            true
        default:
            false
        }
    }
}

nonisolated enum XboxCloudWebRTCConnectionState: Equatable, Sendable {
    case idle
    case preparing
    case negotiating
    case connecting
    case connected
    case disconnected(reason: String)
    case failed(message: String)

    var hasActivePeer: Bool {
        switch self {
        case .preparing, .negotiating, .connecting, .connected:
            true
        case .idle, .disconnected, .failed:
            false
        }
    }
}

nonisolated enum XboxCloudRequiredChannelClosurePolicy {
    static func shouldTerminate(
        channel: XboxCloudDataChannelKind,
        state: XboxCloudWebRTCConnectionState,
        inputMode: XboxCloudInputTransportMode?
    ) -> Bool {
        guard state.hasActivePeer else { return false }
        return inputMode?.requiredChannels.contains(channel) == true
    }
}

nonisolated enum XboxCloudChannelNegotiationPolicy {
    static let optionalChannels: Set<XboxCloudDataChannelKind> = [
        .chat,
        .control,
        .message,
    ]

    static func isRequiredForOffer(
        _ channel: XboxCloudDataChannelKind
    ) -> Bool {
        !optionalChannels.contains(channel)
    }

    static func negotiatedOptionalChannels(
        from answer: XboxCloudSDPAnswer
    ) -> Set<XboxCloudDataChannelKind> {
        var channels: Set<XboxCloudDataChannelKind> = []
        if answer.chat != nil || answer.chatStream != nil {
            channels.insert(.chat)
        }
        if answer.control != nil {
            channels.insert(.control)
        }
        if answer.message != nil {
            channels.insert(.message)
        }
        return channels
    }
}

nonisolated enum XboxCloudDataSendDisposition: Equatable, Sendable {
    case accepted
    case channelUnavailable
    case backpressured
    case payloadTooLarge
    case rejected
}

private nonisolated struct XboxCloudChannelSendState {
    var channels: [XboxCloudDataChannelKind: LKRTCDataChannel] = [:]
}

private nonisolated struct XboxCloudChannelReceiveState {
    var onMessage: (@Sendable (
        XboxCloudDataChannelKind,
        Data,
        Bool
    ) -> Void)?
}

/// WebRTC may invoke delegate methods on different native threads. Exactly one
/// MainActor drain preserves callback arrival order across peer, receiver, and
/// data-channel delegates; the unchecked closure box only transports captured
/// WebRTC references to that single actor.
nonisolated enum XboxCloudDelegateEventPolicy: Equatable, Sendable {
    enum CoalescingKey: Hashable, Sendable {
        case iceConnectionState
        case peerConnectionState
    }

    case required
    case optional
    case coalescing(CoalescingKey)
}

nonisolated enum XboxCloudDelegateEventEnqueueResult: Equatable, Sendable {
    case enqueued
    case coalesced
    case dropped
    case overflowed
}

final nonisolated class XboxCloudDelegateEventQueue: @unchecked Sendable {
    fileprivate nonisolated struct Event: @unchecked Sendable {
        let policy: XboxCloudDelegateEventPolicy
        let operation: @MainActor () -> Void
    }

    fileprivate nonisolated struct State {
        var events: [Event?] = []
        var head = 0
        var liveCount = 0
        var coalescingIndexes: [
            XboxCloudDelegateEventPolicy.CoalescingKey: Int
        ] = [:]
        var isDrainScheduled = false
        var isOverflowed = false
        var droppedEventCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let maximumPendingEvents: Int
    private let automaticallyDrains: Bool

    init(
        maximumPendingEvents: Int = 512,
        automaticallyDrains: Bool = true
    ) {
        precondition(maximumPendingEvents > 0)
        self.maximumPendingEvents = maximumPendingEvents
        self.automaticallyDrains = automaticallyDrains
    }

    var pendingEventCount: Int {
        state.withLock { $0.liveCount }
    }

    var droppedEventCount: Int {
        state.withLock { $0.droppedEventCount }
    }

    @discardableResult
    func enqueue(
        policy: XboxCloudDelegateEventPolicy = .required,
        onOverflow: @escaping @MainActor () -> Void = {},
        _ operation: @escaping @MainActor () -> Void
    ) -> XboxCloudDelegateEventEnqueueResult {
        let event = Event(policy: policy, operation: operation)
        let outcome = state.withLock { state -> (
            XboxCloudDelegateEventEnqueueResult,
            Bool
        ) in
            guard !state.isOverflowed else {
                state.droppedEventCount += 1
                return (.dropped, false)
            }

            let result: XboxCloudDelegateEventEnqueueResult
            if case let .coalescing(key) = policy,
               let index = state.coalescingIndexes[key],
               index >= state.head,
               state.events[index] != nil
            {
                state.events[index] = nil
                state.liveCount -= 1
                state.coalescingIndexes[key] = nil
                state.append(event)
                result = .coalesced
            } else if state.liveCount < maximumPendingEvents {
                state.append(event)
                result = .enqueued
            } else if policy == .optional {
                state.droppedEventCount += 1
                result = .dropped
            } else if state.evictFirstNonrequiredEvent() {
                state.droppedEventCount += 1
                state.append(event)
                result = .enqueued
            } else {
                state.droppedEventCount += state.liveCount + 1
                state.removeAllPending()
                state.isOverflowed = true
                state.append(Event(policy: .required, operation: onOverflow))
                result = .overflowed
            }

            state.compactStorageIfNeeded(
                maximumPendingEvents: maximumPendingEvents
            )
            guard automaticallyDrains,
                  result != .dropped,
                  !state.isDrainScheduled
            else {
                return (result, false)
            }
            state.isDrainScheduled = true
            return (result, true)
        }
        guard outcome.1 else { return outcome.0 }
        Task { @MainActor [self] in
            drain()
        }
        return outcome.0
    }

    func removeAll() {
        state.withLock { state in
            state.removeAllPending()
            state.isOverflowed = false
        }
    }

    @MainActor
    func drainForTesting() {
        drain()
    }

    @MainActor
    private func drain() {
        while let event = state.withLock({ state -> Event? in
            guard let event = state.popFirst(
                maximumPendingEvents: maximumPendingEvents
            ) else {
                state.isDrainScheduled = false
                state.isOverflowed = false
                return nil
            }
            return event
        }) {
            event.operation()
        }
    }
}

private extension XboxCloudDelegateEventQueue.State {
    nonisolated mutating func append(
        _ event: XboxCloudDelegateEventQueue.Event
    ) {
        events.append(event)
        liveCount += 1
        if case let .coalescing(key) = event.policy {
            coalescingIndexes[key] = events.endIndex - 1
        }
    }

    nonisolated mutating func popFirst(
        maximumPendingEvents: Int
    ) -> XboxCloudDelegateEventQueue.Event? {
        while head < events.count {
            let index = head
            head += 1
            guard let event = events[index] else { continue }
            events[index] = nil
            liveCount -= 1
            if case let .coalescing(key) = event.policy,
               coalescingIndexes[key] == index
            {
                coalescingIndexes[key] = nil
            }
            compactStorageIfNeeded(
                maximumPendingEvents: maximumPendingEvents
            )
            return event
        }
        removeAllPending()
        return nil
    }

    nonisolated mutating func evictFirstNonrequiredEvent() -> Bool {
        for index in head ..< events.count {
            guard let event = events[index], event.policy != .required else {
                continue
            }
            events[index] = nil
            liveCount -= 1
            if case let .coalescing(key) = event.policy,
               coalescingIndexes[key] == index
            {
                coalescingIndexes[key] = nil
            }
            return true
        }
        return false
    }

    nonisolated mutating func removeAllPending() {
        events.removeAll(keepingCapacity: true)
        head = 0
        liveCount = 0
        coalescingIndexes.removeAll(keepingCapacity: true)
    }

    nonisolated mutating func compactStorageIfNeeded(
        maximumPendingEvents: Int
    ) {
        let occupiedSlots = events.count - head
        guard head >= maximumPendingEvents
            || occupiedSlots > maximumPendingEvents * 2
        else {
            return
        }
        events = Array(events[head...])
        head = 0
        coalescingIndexes.removeAll(keepingCapacity: true)
        for (index, event) in events.enumerated() {
            if case let .coalescing(key) = event?.policy {
                coalescingIndexes[key] = index
            }
        }
    }
}

nonisolated struct XboxCloudMediaReadinessMonitor: Equatable, Sendable {
    static let stallSampleLimit = 5

    private(set) var hasVideoReceiver = false
    private(set) var hasAudioReceiver = false
    private(set) var videoStallSamples = 0
    private(set) var audioStallSamples = 0
    private(set) var hasVideoProgress = false
    private(set) var hasAudioProgress = false
    private var lastVideoProgress: Double?
    private var lastAudioProgress: Double?

    var hasActiveMedia: Bool {
        hasVideoReceiver
            && hasAudioReceiver
            && hasVideoProgress
            && hasAudioProgress
            && videoStallSamples < Self.stallSampleLimit
            && audioStallSamples < Self.stallSampleLimit
    }

    mutating func setVideoReceiver(_ present: Bool) {
        hasVideoReceiver = present
        lastVideoProgress = nil
        videoStallSamples = 0
        hasVideoProgress = false
    }

    mutating func setAudioReceiver(_ present: Bool) {
        hasAudioReceiver = present
        lastAudioProgress = nil
        audioStallSamples = 0
        hasAudioProgress = false
    }

    mutating func record(videoProgress: Double?, audioProgress: Double?) {
        record(
            videoProgress,
            previous: &lastVideoProgress,
            stalls: &videoStallSamples,
            hasProgress: &hasVideoProgress,
            receiverPresent: hasVideoReceiver
        )
        record(
            audioProgress,
            previous: &lastAudioProgress,
            stalls: &audioStallSamples,
            hasProgress: &hasAudioProgress,
            receiverPresent: hasAudioReceiver
        )
    }

    mutating func reset() {
        self = XboxCloudMediaReadinessMonitor()
    }

    private func record(
        _ progress: Double?,
        previous: inout Double?,
        stalls: inout Int,
        hasProgress: inout Bool,
        receiverPresent: Bool
    ) {
        guard receiverPresent else { return }
        guard let progress, progress.isFinite else {
            stalls = min(stalls + 1, Self.stallSampleLimit)
            return
        }
        defer { previous = progress }
        guard let previous else {
            hasProgress = progress > 0
            stalls = hasProgress ? 0 : min(stalls + 1, Self.stallSampleLimit)
            return
        }
        if progress > previous || progress < previous {
            hasProgress = true
            stalls = 0
        } else {
            stalls = min(stalls + 1, Self.stallSampleLimit)
        }
    }
}

@MainActor
private protocol XboxCloudCallbackCancelling: AnyObject {
    func cancel(with error: Error)
}

/// One-shot bridge for WebRTC's callback APIs. Every operation has a deadline,
/// observes task cancellation, and claims its continuation before resuming it.
/// Late or duplicated WebRTC callbacks therefore become harmless no-ops.
@MainActor
final class XboxCloudBoundedCallback<Value: Sendable>: XboxCloudCallbackCancelling {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let timeout: Duration
    private let timeoutError: XboxCloudWebRTCTransportError
    private let sleep: Sleep
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var didStart = false

    init(
        timeout: Duration,
        timeoutError: XboxCloudWebRTCTransportError,
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.timeout = timeout
        self.timeoutError = timeoutError
        self.sleep = sleep
    }

    func value(
        starting start: (@escaping @Sendable (
            Result<Value, XboxCloudWebRTCTransportError>
        ) -> Void) -> Void
    ) async throws -> Value {
        guard !didStart else {
            throw XboxCloudWebRTCTransportError.peerOperationFailed(
                operation: "starting a media operation more than once"
            )
        }
        didStart = true
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let timeout = self.timeout
                let timeoutError = self.timeoutError
                let sleep = self.sleep
                timeoutTask = Task { @concurrent [weak self] in
                    do {
                        try await sleep(timeout)
                    } catch {
                        return
                    }
                    await self?.cancel(with: timeoutError)
                }
                start { [weak self] result in
                    Task { @MainActor in
                        self?.complete(with: result)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(with: CancellationError())
            }
        }
    }

    func cancel(with error: Error) {
        guard let continuation = claimContinuation() else { return }
        continuation.resume(throwing: error)
    }

    isolated deinit {
        timeoutTask?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    private func complete(
        with result: Result<Value, XboxCloudWebRTCTransportError>
    ) {
        guard let continuation = claimContinuation() else { return }
        continuation.resume(with: result.mapError { $0 as Error })
    }

    private func claimContinuation() -> CheckedContinuation<Value, Error>? {
        guard let continuation else { return nil }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        return continuation
    }
}

/// Native Xbox Cloud media adapter. Provider-specific REST signaling terminates here;
/// decoding, audio playout, and the WebRTC factory remain shared CloudNow resources.
@Observable
@MainActor
final class XboxCloudWebRTCTransport: NSObject {
    private static let maximumCandidateCount = 64
    private static let maximumCandidateBytes = 16384
    private nonisolated static let maximumDataPayloadBytes = 256 * 1024
    private nonisolated static let maximumBufferedChannelBytes: UInt64 = 512 * 1024
    private nonisolated static let standardDisconnectGracePeriod: Duration = .seconds(3)
    private nonisolated static let standardPeerOperationTimeout: Duration = .seconds(15)

    private(set) var state: XboxCloudWebRTCConnectionState = .idle
    private(set) var readiness = XboxCloudWebRTCReadiness()
    private(set) var videoTrack: LKRTCVideoTrack?
    private(set) var microphoneEnabled = false
    private(set) var negotiatedOptionalChannels: Set<XboxCloudDataChannelKind> = []
    private(set) var negotiatedInputMode: XboxCloudInputTransportMode?

    var rtcEventLogActive: Bool {
        rtcEventLog.activeURL != nil
    }

    var negotiatedInputVersion: Int? {
        negotiatedInputMode?.reportVersion
    }

    @ObservationIgnored var onChannelStateChanged: (@MainActor (
        _ channel: XboxCloudDataChannelKind,
        _ isOpen: Bool
    ) -> Void)?

    @ObservationIgnored var onChannelMessage: (@Sendable (
        _ channel: XboxCloudDataChannelKind,
        _ data: Data,
        _ isBinary: Bool
    ) -> Void)? {
        didSet {
            let handler = onChannelMessage
            channelReceiveState.withLock { state in
                state.onMessage = handler
            }
        }
    }

    @ObservationIgnored private let negotiationPipeline: XboxCloudWebRTCNegotiationPipeline
    @ObservationIgnored private let rtcEventLog: any XboxCloudRTCEventLogging
    @ObservationIgnored private let audioSessionCoordinator =
        CloudAudioSessionCoordinator()
    @ObservationIgnored private let statsSampler = XboxCloudRTCStatsSampler()
    @ObservationIgnored private nonisolated let delegateEvents =
        XboxCloudDelegateEventQueue()
    @ObservationIgnored private var peerConnection: LKRTCPeerConnection?
    @ObservationIgnored private var videoReceiver: LKRTCRtpReceiver?
    @ObservationIgnored private var audioReceiver: LKRTCRtpReceiver?
    @ObservationIgnored private var microphoneSource: LKRTCAudioSource?
    @ObservationIgnored private var microphoneTrack: LKRTCAudioTrack?
    @ObservationIgnored private var mediaReadinessMonitor =
        XboxCloudMediaReadinessMonitor()
    @ObservationIgnored private var mediaHealthTask: Task<Void, Never>?
    @ObservationIgnored private var channels: [XboxCloudDataChannelKind: LKRTCDataChannel] = [:]
    @ObservationIgnored private var localICECandidates: [XboxCloudICECandidate] = []
    @ObservationIgnored private var localICECandidateKeys: Set<String> = []
    @ObservationIgnored private var localICECollectionError: XboxCloudWebRTCTransportError?
    @ObservationIgnored private var isLocalICEGatheringComplete = false
    @ObservationIgnored private var localICEWaiter: CheckedContinuation<[XboxCloudICECandidate], Error>?
    @ObservationIgnored private var localICETimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var disconnectGraceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPeerOperation: (any XboxCloudCallbackCancelling)?
    @ObservationIgnored private var terminalPeerFailure: (
        generation: UInt64,
        error: XboxCloudWebRTCTransportError
    )?
    @ObservationIgnored private var connectionGeneration: UInt64 = 0
    @ObservationIgnored private var rtcEventLogGeneration: UInt64?
    @ObservationIgnored private let disconnectGracePeriod: Duration
    @ObservationIgnored private let peerOperationTimeout: Duration
    @ObservationIgnored private let sleep: XboxCloudBoundedCallback<Void>.Sleep

    /// Data channel sends can originate on the controller sampling queue. The lock only
    /// guards six references and one immediate WebRTC send; it never encloses an await.
    @ObservationIgnored private nonisolated let channelSendState = OSAllocatedUnfairLock(
        initialState: XboxCloudChannelSendState()
    )
    @ObservationIgnored private nonisolated let channelReceiveState = OSAllocatedUnfairLock(
        initialState: XboxCloudChannelReceiveState()
    )

    init(
        signaling: any XboxCloudSignalingProviding = XboxCloudSignalingAPI(),
        rtcEventLog: any XboxCloudRTCEventLogging = XboxCloudRedactedRTCEventLog(),
        disconnectGracePeriod: Duration = standardDisconnectGracePeriod,
        peerOperationTimeout: Duration = standardPeerOperationTimeout,
        sleep: @escaping XboxCloudBoundedCallback<Void>.Sleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        negotiationPipeline = XboxCloudWebRTCNegotiationPipeline(signaling: signaling)
        self.rtcEventLog = rtcEventLog
        self.disconnectGracePeriod = disconnectGracePeriod
        self.peerOperationTimeout = peerOperationTimeout
        self.sleep = sleep
        super.init()
    }

    /// Negotiates one already-provisioned Xbox Cloud session. The caller owns this task and
    /// should cancel it with the launch surface lifecycle; `disconnect()` invalidates it too.
    func connect(
        configuration: XboxCloudSessionConfiguration,
        signalingContext: XboxCloudSignalingContext,
        microphoneRequested: Bool = false,
        rtcEventLogRequested: Bool = false
    ) async throws {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        terminalPeerFailure = nil
        releasePeerResources(resumingICEWaiterWith: CancellationError())
        resetPublishedConnectionState(to: .preparing)
        startRTCEventLogIfNeeded(
            requested: rtcEventLogRequested,
            generation: generation
        )

        do {
            let microphoneAuthorized = await audioSessionCoordinator
                .requestMicrophonePermission(if: microphoneRequested)
            try Task.checkCancellation()
            guard generation == connectionGeneration else {
                throw CancellationError()
            }
            let microphoneRouteReady = audioSessionCoordinator.configure(
                microphoneAuthorized: microphoneAuthorized
            )
            try preparePeer(
                configuration: configuration,
                microphoneAuthorized: microphoneAuthorized
            )
            guard generation == connectionGeneration else {
                throw CancellationError()
            }
            recordRTCEvent(.peerPrepared, generation: generation)
            if microphoneEnabled, !microphoneRouteReady {
                xboxWebRTCLog.info(
                    "Xbox microphone negotiated; capture awaits an input route"
                )
            }
            state = .negotiating

            let answer = try await negotiationPipeline.negotiate(
                peer: self,
                context: signalingContext
            )
            try Task.checkCancellation()
            guard generation == connectionGeneration else {
                throw CancellationError()
            }
            recordRTCEvent(.negotiationCompleted, generation: generation)

            let inputMode = try XboxCloudInputTransportMode(answer: answer)
            negotiatedInputMode = inputMode
            negotiatedOptionalChannels = XboxCloudChannelNegotiationPolicy
                .negotiatedOptionalChannels(from: answer)
            reconcileOptionalChannels()
            updateReadiness { readiness in
                readiness.setNegotiatedInputMode(inputMode)
            }
            xboxWebRTCLog.notice(
                "Xbox Cloud negotiated input mode=\(inputMode.diagnosticName, privacy: .public) version=\(inputMode.reportVersion, privacy: .public)"
            )
            state = .connecting
            synchronizeReadinessFromPeer()
        } catch {
            if !(error is CancellationError) {
                recordRTCEvent(.connectionFailed, generation: generation)
            }
            if let terminalFailure = terminalPeerFailure,
               terminalFailure.generation == generation
            {
                terminalPeerFailure = nil
                throw terminalFailure.error
            }

            if error is CancellationError {
                guard generation == connectionGeneration else {
                    throw CancellationError()
                }
                connectionGeneration &+= 1
                releasePeerResources(resumingICEWaiterWith: CancellationError())
                resetPublishedConnectionState(to: .idle)
                throw CancellationError()
            }

            guard generation == connectionGeneration else {
                throw CancellationError()
            }
            let safeError = Self.sanitizedTransportError(error)
            connectionGeneration &+= 1
            releasePeerResources(resumingICEWaiterWith: safeError)
            resetPublishedConnectionState(
                to: .failed(message: safeError.localizedDescription)
            )
            throw safeError
        }
    }

    /// Idempotently closes the peer, channels, tracks, pending ICE wait, and send registry.
    func disconnect() {
        connectionGeneration &+= 1
        terminalPeerFailure = nil
        releasePeerResources(resumingICEWaiterWith: CancellationError())
        resetPublishedConnectionState(to: .idle)
    }

    func sampleStatistics() async -> XboxCloudRTCStatsSnapshot {
        guard let peerConnection else { return XboxCloudRTCStatsSnapshot() }
        return await statsSampler.sample(
            peerConnection: peerConnection,
            videoReceiver: videoReceiver
        )
    }

    @discardableResult
    nonisolated func sendInput(_ data: Data) -> XboxCloudDataSendDisposition {
        send(data, on: .input, isBinary: true)
    }

    @discardableResult
    nonisolated func sendReliableInput(_ data: Data) -> XboxCloudDataSendDisposition {
        send(data, on: .reliableInput, isBinary: true)
    }

    @discardableResult
    nonisolated func sendUnreliableInput(_ data: Data) -> XboxCloudDataSendDisposition {
        send(data, on: .unreliableInput, isBinary: true)
    }

    @discardableResult
    nonisolated func sendControl(
        _ data: Data,
        isBinary: Bool = false
    ) -> XboxCloudDataSendDisposition {
        send(data, on: .control, isBinary: isBinary)
    }

    @discardableResult
    nonisolated func sendMessage(
        _ data: Data,
        isBinary: Bool = false
    ) -> XboxCloudDataSendDisposition {
        send(data, on: .message, isBinary: isBinary)
    }

    @discardableResult
    nonisolated func sendChat(
        _ data: Data,
        isBinary: Bool = true
    ) -> XboxCloudDataSendDisposition {
        send(data, on: .chat, isBinary: isBinary)
    }

    @discardableResult
    nonisolated func send(
        _ data: Data,
        on channelKind: XboxCloudDataChannelKind,
        isBinary: Bool
    ) -> XboxCloudDataSendDisposition {
        guard data.count <= Self.maximumDataPayloadBytes else {
            return .payloadTooLarge
        }
        return channelSendState.withLock { sendState in
            guard let channel = sendState.channels[channelKind],
                  channel.readyState == .open
            else {
                return .channelUnavailable
            }
            guard channel.bufferedAmount <= Self.maximumBufferedChannelBytes else {
                return .backpressured
            }
            let buffer = LKRTCDataBuffer(data: data, isBinary: isBinary)
            return channel.sendData(buffer) ? .accepted : .rejected
        }
    }

    isolated deinit {
        delegateEvents.removeAll()
        stopRTCEventLog()
        localICETimeoutTask?.cancel()
        disconnectGraceTask?.cancel()
        localICEWaiter?.resume(throwing: CancellationError())
        pendingPeerOperation?.cancel(with: CancellationError())
        channelSendState.withLock { $0.channels.removeAll() }
        channelReceiveState.withLock { $0.onMessage = nil }
        for channel in channels.values {
            channel.delegate = nil
            channel.close()
        }
        peerConnection?.delegate = nil
        peerConnection?.close()
    }

    private func preparePeer(
        configuration: XboxCloudSessionConfiguration,
        microphoneAuthorized: Bool
    ) throws {
        let stunURLs = try Self.validatedSTUNURLs(
            configuration.serverDetails.stunServerAddresses ?? []
        )
        CloudAudioDevice.shared.requestedOutputChannels = 2

        let rtcConfiguration = LKRTCConfiguration()
        rtcConfiguration.sdpSemantics = .unifiedPlan
        rtcConfiguration.bundlePolicy = .maxBundle
        rtcConfiguration.rtcpMuxPolicy = .require
        rtcConfiguration.continualGatheringPolicy = .gatherOnce
        if !stunURLs.isEmpty {
            rtcConfiguration.iceServers = [LKRTCIceServer(urlStrings: stunURLs)]
        }

        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        guard let peerConnection = CloudRTCRuntime.peerConnectionFactory.peerConnection(
            with: rtcConfiguration,
            constraints: constraints,
            delegate: self
        ) else {
            throw XboxCloudWebRTCTransportError.unableToCreatePeer
        }
        self.peerConnection = peerConnection

        let audio = LKRTCRtpTransceiverInit()
        audio.direction = .sendRecv
        guard peerConnection.addTransceiver(of: .audio, init: audio) != nil else {
            throw XboxCloudWebRTCTransportError.unableToCreateTransceiver(
                media: "audio"
            )
        }
        if microphoneAuthorized {
            if let attachment = audioSessionCoordinator.attachMicrophone(
                to: peerConnection
            ) {
                microphoneSource = attachment.source
                microphoneTrack = attachment.track
                microphoneEnabled = true
            } else {
                microphoneEnabled = false
                audioSessionCoordinator.configurePlayback()
            }
        }

        let video = LKRTCRtpTransceiverInit()
        video.direction = .recvOnly
        guard let videoTransceiver = peerConnection.addTransceiver(
            of: .video,
            init: video
        ) else {
            throw XboxCloudWebRTCTransportError.unableToCreateTransceiver(
                media: "video"
            )
        }
        applyServiceVideoCodecOverride(
            configuration.clientStreamingConfigOverrides,
            to: videoTransceiver
        )
        var createdChannels: [XboxCloudDataChannelKind: LKRTCDataChannel] = [:]
        for descriptor in XboxCloudDataChannelDescriptor.microsoftWebRTCChannels {
            let channelConfiguration = LKRTCDataChannelConfiguration()
            channelConfiguration.isOrdered = descriptor.isOrdered
            channelConfiguration.isNegotiated = false
            channelConfiguration.protocol = descriptor.subprotocol
            if let maximumRetransmits = descriptor.maximumRetransmits {
                channelConfiguration.maxRetransmits = Int32(maximumRetransmits)
            }
            guard let channel = peerConnection.dataChannel(
                forLabel: descriptor.label,
                configuration: channelConfiguration
            ) else {
                if !XboxCloudChannelNegotiationPolicy.isRequiredForOffer(
                    descriptor.kind
                ) {
                    xboxWebRTCLog.info(
                        "Optional Xbox channel unavailable kind=\(descriptor.kind.rawValue, privacy: .public)"
                    )
                    continue
                }
                throw XboxCloudWebRTCTransportError.unableToCreateDataChannel(
                    label: descriptor.label
                )
            }
            channel.delegate = self
            createdChannels[descriptor.kind] = channel
        }
        channels = createdChannels
        let registeredChannels = createdChannels
        channelSendState.withLock { $0.channels = registeredChannels }
        xboxWebRTCLog.info(
            "Prepared Xbox Cloud peer channels=\(createdChannels.count, privacy: .public)"
        )
    }

    /// Applies only capabilities WebRTC says this receiver supports. Failure is
    /// non-terminal: the untouched default order still provides Automatic mode.
    private func applyServiceVideoCodecOverride(
        _ rawOverrides: XboxCloudJSONValue?,
        to transceiver: LKRTCRtpTransceiver
    ) {
        let override = XboxCloudServiceStreamingOverrides(rawOverrides)
        guard override.enableHEVC != nil else { return }

        let capabilities = CloudRTCRuntime.peerConnectionFactory
            .rtpReceiverCapabilities(forKind: kLKRTCMediaStreamTrackKindVideo)
            .codecs
        let snapshots = capabilities.map { capability in
            XboxCloudVideoCodecCapability(
                name: capability.name,
                preferredPayloadType: capability.preferredPayloadType?.intValue,
                associatedPayloadType: capability.parameters["apt"].flatMap(Int.init)
            )
        }
        guard let indexes = XboxCloudVideoCodecPreferencePolicy
            .preferredCapabilityIndexes(
                snapshots,
                enableHEVC: override.enableHEVC
            )
        else {
            xboxWebRTCLog.info(
                "Xbox service codec override ignored because no safe supported preference exists"
            )
            return
        }

        let preferences = indexes.map { capabilities[$0] }
        do {
            try transceiver.setCodecPreferences(preferences, error: ())
        } catch {
            xboxWebRTCLog.info(
                "Xbox service codec override rejected by WebRTC; using Automatic"
            )
            return
        }
        xboxWebRTCLog.info(
            "Applied Xbox service HEVC override enabled=\(override.enableHEVC == true, privacy: .public)"
        )
    }

    private func reconcileOptionalChannels() {
        for kind in XboxCloudChannelNegotiationPolicy.optionalChannels
            where !negotiatedOptionalChannels.contains(kind)
        {
            guard let channel = channels.removeValue(forKey: kind) else {
                continue
            }
            channelSendState.withLock {
                _ = $0.channels.removeValue(forKey: kind)
            }
            channel.delegate = nil
            channel.close()
            updateReadiness { $0.setChannel(kind, isOpen: false) }
            onChannelStateChanged?(kind, false)
        }
    }

    private func synchronizeReadinessFromPeer() {
        guard let peerConnection else { return }
        updateReadiness { readiness in
            readiness.setPeerConnected(
                peerConnection.connectionState == .connected
                    || peerConnection.iceConnectionState == .connected
                    || peerConnection.iceConnectionState == .completed
            )
            readiness.setActiveMedia(mediaReadinessMonitor.hasActiveMedia)
            for (kind, channel) in channels {
                readiness.setChannel(kind, isOpen: channel.readyState == .open)
            }
        }
    }

    private func updateReadiness(
        _ update: (inout XboxCloudWebRTCReadiness) -> Void
    ) {
        var next = readiness
        update(&next)
        if next != readiness {
            readiness = next
        }
        if next.isReady, state != .connected {
            state = .connected
            recordRTCEvent(
                .mediaConnected,
                generation: connectionGeneration
            )
            xboxWebRTCLog.info("Xbox Cloud media, peer, and required channels are ready")
        }
    }

    private func releasePeerResources(resumingICEWaiterWith error: Error) {
        delegateEvents.removeAll()
        cancelDisconnectGrace()
        mediaHealthTask?.cancel()
        mediaHealthTask = nil
        localICETimeoutTask?.cancel()
        localICETimeoutTask = nil
        if let waiter = localICEWaiter {
            localICEWaiter = nil
            waiter.resume(throwing: error)
        }
        pendingPeerOperation?.cancel(with: error)
        pendingPeerOperation = nil

        channelSendState.withLock { $0.channels.removeAll(keepingCapacity: true) }
        for channel in channels.values {
            channel.delegate = nil
            channel.close()
        }
        channels.removeAll(keepingCapacity: true)

        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        videoReceiver = nil
        audioReceiver = nil
        videoTrack = nil
        microphoneSource = nil
        microphoneTrack = nil
        if microphoneEnabled {
            audioSessionCoordinator.configurePlayback()
        }
        microphoneEnabled = false
        mediaReadinessMonitor.reset()
        statsSampler.reset()
        localICECandidates.removeAll(keepingCapacity: true)
        localICECandidateKeys.removeAll(keepingCapacity: true)
        localICECollectionError = nil
        isLocalICEGatheringComplete = false
        stopRTCEventLog()
    }

    private func resetPublishedConnectionState(
        to state: XboxCloudWebRTCConnectionState
    ) {
        self.state = state
        readiness = XboxCloudWebRTCReadiness()
        negotiatedInputMode = nil
        negotiatedOptionalChannels = []
        videoTrack = nil
        microphoneEnabled = false
    }

    private func refreshMediaReadiness() {
        updateReadiness {
            $0.setActiveMedia(mediaReadinessMonitor.hasActiveMedia)
        }
        if mediaReadinessMonitor.hasVideoReceiver,
           mediaReadinessMonitor.hasAudioReceiver
        {
            startMediaHealthMonitorIfNeeded()
        } else {
            mediaHealthTask?.cancel()
            mediaHealthTask = nil
        }
    }

    private func startMediaHealthMonitorIfNeeded() {
        guard mediaHealthTask == nil else { return }
        let generation = connectionGeneration
        mediaHealthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self,
                      generation == connectionGeneration,
                      let peerConnection,
                      let videoReceiver,
                      let audioReceiver
                else {
                    return
                }
                let videoProgress = await Self.mediaProgress(
                    peerConnection: peerConnection,
                    receiver: videoReceiver,
                    mediaKind: "video"
                )
                let audioProgress = await Self.mediaProgress(
                    peerConnection: peerConnection,
                    receiver: audioReceiver,
                    mediaKind: "audio"
                )
                mediaReadinessMonitor.record(
                    videoProgress: videoProgress,
                    audioProgress: audioProgress
                )
                refreshMediaReadiness()
            }
        }
    }

    private static func mediaProgress(
        peerConnection: LKRTCPeerConnection,
        receiver: LKRTCRtpReceiver,
        mediaKind: String
    ) async -> Double? {
        let callback = XboxCloudBoundedCallback<LKRTCStatisticsReport>(
            timeout: .seconds(1),
            timeoutError: .peerOperationFailed(
                operation: "checking Xbox media flow"
            )
        )
        guard let report = try? await callback.value(starting: { completion in
            peerConnection.statistics(for: receiver) { report in
                completion(.success(report))
            }
        }) else {
            return nil
        }
        guard let inbound = report.statistics.values.first(where: { statistic in
            guard statistic.type == "inbound-rtp" else { return false }
            let kind = statistic.values["kind"] as? String
                ?? statistic.values["mediaType"] as? String
            return kind == nil || kind == mediaKind
        }) else {
            return nil
        }
        let preferredKey = mediaKind == "video"
            ? "framesDecoded"
            : "totalSamplesReceived"
        return numericProgress(inbound.values[preferredKey])
            ?? numericProgress(inbound.values["packetsReceived"])
    }

    private static func numericProgress(_ value: Any?) -> Double? {
        guard let value = (value as? NSNumber)?.doubleValue,
              value.isFinite
        else {
            return nil
        }
        return value
    }

    private func handlePeerConnectionState(
        _ newState: LKRTCPeerConnectionState,
        source: LKRTCPeerConnection
    ) {
        guard peerConnection === source else { return }
        switch newState {
        case .connected:
            recoverPeerConnection()
        case .disconnected:
            beginPeerConnectionLossGracePeriod(
                reason: "Xbox Cloud media disconnected."
            )
        case .failed:
            terminateActivePeer(reason: "Xbox Cloud media connection failed.")
        case .closed:
            beginPeerConnectionLossGracePeriod(
                reason: "Xbox Cloud media connection closed."
            )
        case .new, .connecting:
            break
        @unknown default:
            break
        }
    }

    private func handleICEConnectionState(
        _ newState: LKRTCIceConnectionState,
        source: LKRTCPeerConnection
    ) {
        guard peerConnection === source else { return }
        switch newState {
        case .connected, .completed:
            recoverPeerConnection()
        case .disconnected:
            beginPeerConnectionLossGracePeriod(
                reason: "Xbox Cloud network path disconnected."
            )
        case .failed:
            terminateActivePeer(reason: "Xbox Cloud network negotiation failed.")
        case .closed:
            beginPeerConnectionLossGracePeriod(
                reason: "Xbox Cloud network path closed."
            )
        case .new, .checking, .count:
            break
        @unknown default:
            break
        }
    }

    func beginPeerConnectionLossGracePeriod(reason: String) {
        updateReadiness { $0.setPeerConnected(false) }
        guard disconnectGraceTask == nil else { return }

        let generation = connectionGeneration
        let gracePeriod = disconnectGracePeriod
        let sleep = sleep
        disconnectGraceTask = Task { @concurrent [weak self] in
            do {
                try await sleep(gracePeriod)
            } catch {
                return
            }
            await self?.expireDisconnectGrace(
                generation: generation,
                reason: reason
            )
        }
    }

    func recoverPeerConnection() {
        cancelDisconnectGrace()
        updateReadiness { $0.setPeerConnected(true) }
    }

    func terminateActivePeer(reason: String) {
        cancelDisconnectGrace()
        let failure = XboxCloudWebRTCTransportError.peerOperationFailed(
            operation: "maintaining the network path"
        )
        recordRTCEvent(
            .connectionFailed,
            generation: connectionGeneration
        )
        terminalPeerFailure = (connectionGeneration, failure)
        connectionGeneration &+= 1
        releasePeerResources(resumingICEWaiterWith: failure)
        resetPublishedConnectionState(to: .failed(message: reason))
    }

    private func expireDisconnectGrace(
        generation: UInt64,
        reason: String
    ) {
        guard generation == connectionGeneration,
              disconnectGraceTask != nil,
              !readiness.isPeerConnected
        else { return }
        disconnectGraceTask = nil
        terminateActivePeer(reason: reason)
    }

    private func cancelDisconnectGrace() {
        disconnectGraceTask?.cancel()
        disconnectGraceTask = nil
    }

    private func startRTCEventLogIfNeeded(
        requested: Bool,
        generation: UInt64
    ) {
        rtcEventLogGeneration = nil
        guard requested,
              XboxCloudDiagnosticsPolicy.currentBuildAllowsDiagnostics,
              rtcEventLog.start() != nil
        else {
            return
        }
        rtcEventLogGeneration = generation
    }

    private func recordRTCEvent(
        _ event: XboxCloudRTCEvent,
        generation: UInt64
    ) {
        guard rtcEventLogGeneration == generation else { return }
        rtcEventLog.record(event)
    }

    private func stopRTCEventLog() {
        rtcEventLog.stop()
        rtcEventLogGeneration = nil
    }

    private func recordLocalICECandidate(
        _ candidate: LKRTCIceCandidate,
        source: LKRTCPeerConnection
    ) {
        guard peerConnection === source,
              !isLocalICEGatheringComplete,
              localICECollectionError == nil
        else { return }

        guard localICECandidates.count < Self.maximumCandidateCount else {
            localICECollectionError = .tooManyICECandidates
            completeLocalICEWaitIfPossible()
            return
        }
        guard !candidate.sdp.isEmpty,
              candidate.sdp.utf8.count <= Self.maximumCandidateBytes,
              !candidate.sdp.contains("\r"),
              !candidate.sdp.contains("\n")
        else {
            localICECollectionError = .invalidICECandidate
            completeLocalICEWaitIfPossible()
            return
        }

        let key = "\(candidate.sdpMid ?? "")|\(candidate.sdpMLineIndex)|\(candidate.sdp)"
        guard localICECandidateKeys.insert(key).inserted else { return }
        localICECandidates.append(
            XboxCloudICECandidate(
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: Int(candidate.sdpMLineIndex)
            )
        )
    }

    private func markLocalICEGatheringComplete(source: LKRTCPeerConnection) {
        guard peerConnection === source,
              !isLocalICEGatheringComplete
        else { return }
        guard localICECandidates.count < Self.maximumCandidateCount else {
            localICECollectionError = .tooManyICECandidates
            isLocalICEGatheringComplete = true
            completeLocalICEWaitIfPossible()
            return
        }
        localICECandidates.append(.endOfCandidates)
        isLocalICEGatheringComplete = true
        completeLocalICEWaitIfPossible()
    }

    private func completeLocalICEWaitIfPossible() {
        guard let waiter = localICEWaiter,
              isLocalICEGatheringComplete || localICECollectionError != nil
        else { return }
        localICEWaiter = nil
        localICETimeoutTask?.cancel()
        localICETimeoutTask = nil

        if let localICECollectionError {
            waiter.resume(throwing: localICECollectionError)
        } else if localICECandidates.isEmpty {
            waiter.resume(
                throwing: XboxCloudWebRTCTransportError.noLocalICECandidates
            )
        } else {
            waiter.resume(returning: localICECandidates)
        }
    }

    private func timeOutLocalICEWait() {
        guard localICEWaiter != nil else { return }
        localICECollectionError = .iceGatheringTimedOut
        completeLocalICEWaitIfPossible()
    }

    private func cancelLocalICEWait() {
        guard let waiter = localICEWaiter else { return }
        localICEWaiter = nil
        localICETimeoutTask?.cancel()
        localICETimeoutTask = nil
        waiter.resume(throwing: CancellationError())
    }

    private func dataChannelKind(
        for channel: LKRTCDataChannel
    ) -> XboxCloudDataChannelKind? {
        channels.first(where: { $0.value === channel })?.key
    }

    static func validatedSTUNURLs(_ values: [String]) throws -> [String] {
        guard values.count <= 32 else {
            throw XboxCloudWebRTCTransportError.invalidSTUNConfiguration
        }

        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = normalized.lowercased()
            guard !normalized.isEmpty,
                  normalized.utf8.count <= 512,
                  !normalized.unicodeScalars.contains(where: { scalar in
                      CharacterSet.whitespacesAndNewlines.contains(scalar)
                          || CharacterSet.controlCharacters.contains(scalar)
                  }),
                  !lowercased.contains("@"),
                  !lowercased.contains("?"),
                  !lowercased.contains("#"),
                  !lowercased.contains("/"),
                  let stunURL = normalizedSTUNURL(normalized)
            else {
                throw XboxCloudWebRTCTransportError.invalidSTUNConfiguration
            }
            let deduplicationKey = stunURL.lowercased()
            if seen.insert(deduplicationKey).inserted {
                result.append(stunURL)
            }
        }
        return result
    }

    private static func normalizedSTUNURL(_ value: String) -> String? {
        let lowercased = value.lowercased()
        let scheme: String
        let address: Substring
        if lowercased.hasPrefix("stuns:") {
            scheme = "stuns"
            address = value.dropFirst("stuns:".count)
        } else if lowercased.hasPrefix("stun:") {
            scheme = "stun"
            address = value.dropFirst("stun:".count)
        } else {
            scheme = "stun"
            address = value[...]
        }

        guard isValidSTUNAddress(address) else { return nil }
        return "\(scheme):\(address)"
    }

    private static func isValidSTUNAddress(_ value: Substring) -> Bool {
        guard !value.isEmpty else { return false }
        if value.hasPrefix("[") {
            guard let closingBracket = value.firstIndex(of: "]") else {
                return false
            }
            let host = value[value.index(after: value.startIndex) ..< closingBracket]
            let suffix = value[value.index(after: closingBracket)...]
            guard !host.isEmpty,
                  host.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." })
            else {
                return false
            }
            return suffix.isEmpty || isValidSTUNPortSuffix(suffix)
        }

        let components = value.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let host = components.first,
              !host.isEmpty,
              host.allSatisfy({
                  $0.isLetter || $0.isNumber || $0 == "." || $0 == "-"
              })
        else {
            return false
        }
        return components.count == 1 || isValidSTUNPort(components[1])
    }

    private static func isValidSTUNPortSuffix(_ suffix: Substring) -> Bool {
        guard suffix.hasPrefix(":") else { return false }
        return isValidSTUNPort(suffix.dropFirst())
    }

    private static func isValidSTUNPort(_ value: Substring) -> Bool {
        guard let port = Int(value) else { return false }
        return (1 ... 65535).contains(port)
    }

    private func performPeerOperation<Value: Sendable>(
        timeoutError: XboxCloudWebRTCTransportError,
        starting start: (@escaping @Sendable (
            Result<Value, XboxCloudWebRTCTransportError>
        ) -> Void) -> Void
    ) async throws -> Value {
        guard pendingPeerOperation == nil else {
            throw XboxCloudWebRTCTransportError.peerOperationFailed(
                operation: "overlapping media operations"
            )
        }

        let operation = XboxCloudBoundedCallback<Value>(
            timeout: peerOperationTimeout,
            timeoutError: timeoutError,
            sleep: sleep
        )
        pendingPeerOperation = operation
        defer {
            if pendingPeerOperation === operation {
                pendingPeerOperation = nil
            }
        }
        return try await operation.value(starting: start)
    }

    private static func sanitizedTransportError(
        _ error: Error
    ) -> XboxCloudWebRTCTransportError {
        if let error = error as? XboxCloudWebRTCTransportError {
            return error
        }
        if error is XboxCloudSignalingError {
            return .peerOperationFailed(operation: "contacting Xbox Cloud")
        }
        return .peerOperationFailed(operation: "negotiating media")
    }

    private nonisolated func enqueueDelegateEvent(
        policy: XboxCloudDelegateEventPolicy,
        _ operation: @escaping @MainActor (XboxCloudWebRTCTransport) -> Void
    ) {
        delegateEvents.enqueue(
            policy: policy,
            onOverflow: { [weak self] in
                self?.terminateActivePeer(
                    reason: "Xbox Cloud media callbacks exceeded the safe limit."
                )
            },
            { [weak self] in
                guard let self else { return }
                operation(self)
            }
        )
    }
}

extension XboxCloudWebRTCTransport: XboxCloudWebRTCNegotiatingPeer {
    func createAndSetLocalOffer() async throws -> String {
        guard let peerConnection else {
            throw XboxCloudWebRTCTransportError.unableToCreatePeer
        }
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true",
            ],
            optionalConstraints: nil
        )
        let offerSDP: String = try await performPeerOperation(
            timeoutError: .peerOperationFailed(
                operation: "creating the local offer"
            )
        ) { completion in
            peerConnection.offer(for: constraints) { description, error in
                if error != nil {
                    completion(.failure(.unableToCreateOffer))
                } else if let description {
                    completion(.success(description.sdp))
                } else {
                    completion(.failure(.unableToCreateOffer))
                }
            }
        }
        try Task.checkCancellation()
        guard self.peerConnection === peerConnection else {
            throw CancellationError()
        }

        let offer = LKRTCSessionDescription(type: .offer, sdp: offerSDP)
        let _: Void = try await performPeerOperation(
            timeoutError: .peerOperationFailed(
                operation: "setting the local offer"
            )
        ) { completion in
            peerConnection.setLocalDescription(offer) { error in
                if error != nil {
                    completion(
                        .failure(
                            .peerOperationFailed(
                                operation: "setting the local offer"
                            )
                        )
                    )
                } else {
                    completion(.success(()))
                }
            }
        }
        try Task.checkCancellation()
        guard self.peerConnection === peerConnection else {
            throw CancellationError()
        }
        guard let localDescription = peerConnection.localDescription,
              !localDescription.sdp.isEmpty
        else {
            throw XboxCloudWebRTCTransportError.unableToCreateOffer
        }
        return localDescription.sdp
    }

    func setRemoteAnswer(_ answer: XboxCloudSDPAnswer) async throws {
        guard let peerConnection else {
            throw CancellationError()
        }
        guard answer.isAccepted else {
            throw XboxCloudWebRTCTransportError.peerOperationFailed(
                operation: "validating the remote answer"
            )
        }
        let description = LKRTCSessionDescription(type: .answer, sdp: answer.sdp)
        let _: Void = try await performPeerOperation(
            timeoutError: .peerOperationFailed(
                operation: "setting the remote answer"
            )
        ) { completion in
            peerConnection.setRemoteDescription(description) { error in
                if error != nil {
                    completion(
                        .failure(
                            .peerOperationFailed(
                                operation: "setting the remote answer"
                            )
                        )
                    )
                } else {
                    completion(.success(()))
                }
            }
        }
        try Task.checkCancellation()
        guard self.peerConnection === peerConnection else {
            throw CancellationError()
        }
    }

    func waitForLocalICECandidates() async throws -> [XboxCloudICECandidate] {
        try Task.checkCancellation()
        if isLocalICEGatheringComplete || localICECollectionError != nil {
            if let localICECollectionError {
                throw localICECollectionError
            }
            guard !localICECandidates.isEmpty else {
                throw XboxCloudWebRTCTransportError.noLocalICECandidates
            }
            return localICECandidates
        }
        guard localICEWaiter == nil else {
            throw XboxCloudWebRTCTransportError.peerOperationFailed(
                operation: "waiting for network candidates"
            )
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                localICEWaiter = continuation
                localICETimeoutTask = Task { @concurrent [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(15))
                    } catch {
                        return
                    }
                    await self?.timeOutLocalICEWait()
                }
                completeLocalICEWaitIfPossible()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelLocalICEWait()
            }
        }
    }

    func addRemoteICECandidates(
        _ candidates: [XboxCloudICECandidate]
    ) async throws {
        guard let peerConnection else {
            throw CancellationError()
        }
        for candidate in candidates {
            try Task.checkCancellation()
            guard let candidateSDP = candidate.rtcCandidateSDP else {
                continue
            }
            let lineIndex = candidate.sdpMLineIndex ?? 0
            guard (0 ... Int(Int32.max)).contains(lineIndex) else {
                throw XboxCloudWebRTCTransportError.invalidICECandidate
            }
            let rtcCandidate = LKRTCIceCandidate(
                sdp: candidateSDP,
                sdpMLineIndex: Int32(lineIndex),
                sdpMid: candidate.sdpMid
            )
            do {
                try await peerConnection.add(rtcCandidate)
            } catch {
                throw XboxCloudWebRTCTransportError.peerOperationFailed(
                    operation: "adding a remote network candidate"
                )
            }
            guard self.peerConnection === peerConnection else {
                throw CancellationError()
            }
        }
    }
}

extension XboxCloudWebRTCTransport: LKRTCPeerConnectionDelegate {
    nonisolated func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}

    nonisolated func peerConnection(
        _: LKRTCPeerConnection,
        didChange _: LKRTCSignalingState
    ) {}

    nonisolated func peerConnection(
        _: LKRTCPeerConnection,
        didAdd _: LKRTCMediaStream
    ) {}

    nonisolated func peerConnection(
        _: LKRTCPeerConnection,
        didRemove _: LKRTCMediaStream
    ) {}

    nonisolated func peerConnection(
        _ source: LKRTCPeerConnection,
        didChange newState: LKRTCIceConnectionState
    ) {
        let policy: XboxCloudDelegateEventPolicy = switch newState {
        case .disconnected, .failed, .closed:
            .required
        case .new, .checking, .connected, .completed, .count:
            .coalescing(.iceConnectionState)
        @unknown default:
            .required
        }
        enqueueDelegateEvent(policy: policy) { transport in
            transport.handleICEConnectionState(newState, source: source)
        }
    }

    nonisolated func peerConnection(
        _ source: LKRTCPeerConnection,
        didChange newState: LKRTCIceGatheringState
    ) {
        guard newState == .complete else { return }
        enqueueDelegateEvent(policy: .required) { transport in
            transport.markLocalICEGatheringComplete(source: source)
        }
    }

    nonisolated func peerConnection(
        _ source: LKRTCPeerConnection,
        didGenerate candidate: LKRTCIceCandidate
    ) {
        enqueueDelegateEvent(policy: .required) { transport in
            transport.recordLocalICECandidate(candidate, source: source)
        }
    }

    nonisolated func peerConnection(
        _: LKRTCPeerConnection,
        didRemove _: [LKRTCIceCandidate]
    ) {}

    nonisolated func peerConnection(
        _: LKRTCPeerConnection,
        didOpen _: LKRTCDataChannel
    ) {}

    nonisolated func peerConnection(
        _ source: LKRTCPeerConnection,
        didChange newState: LKRTCPeerConnectionState
    ) {
        let policy: XboxCloudDelegateEventPolicy = switch newState {
        case .disconnected, .failed, .closed:
            .required
        case .new, .connecting, .connected:
            .coalescing(.peerConnectionState)
        @unknown default:
            .required
        }
        enqueueDelegateEvent(policy: policy) { transport in
            transport.handlePeerConnectionState(newState, source: source)
        }
    }

    nonisolated func peerConnection(
        _ source: LKRTCPeerConnection,
        didAdd receiver: LKRTCRtpReceiver,
        streams _: [LKRTCMediaStream]
    ) {
        guard let track = receiver.track else { return }
        enqueueDelegateEvent(policy: .required) { transport in
            guard transport.peerConnection === source else { return }
            if let videoTrack = track as? LKRTCVideoTrack {
                transport.videoReceiver = receiver
                transport.videoTrack = videoTrack
                transport.mediaReadinessMonitor.setVideoReceiver(true)
            } else if track is LKRTCAudioTrack {
                transport.audioReceiver = receiver
                transport.mediaReadinessMonitor.setAudioReceiver(true)
            } else {
                return
            }
            transport.refreshMediaReadiness()
        }
    }

    nonisolated func peerConnection(
        _ source: LKRTCPeerConnection,
        didRemove receiver: LKRTCRtpReceiver
    ) {
        enqueueDelegateEvent(policy: .required) { transport in
            guard transport.peerConnection === source else { return }
            if transport.videoReceiver === receiver {
                transport.videoReceiver = nil
                transport.videoTrack = nil
                transport.mediaReadinessMonitor.setVideoReceiver(false)
            }
            if transport.audioReceiver === receiver {
                transport.audioReceiver = nil
                transport.mediaReadinessMonitor.setAudioReceiver(false)
            }
            transport.refreshMediaReadiness()
        }
    }
}

extension XboxCloudWebRTCTransport: LKRTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        enqueueDelegateEvent(policy: .required) { transport in
            guard let kind = transport.dataChannelKind(for: dataChannel)
            else { return }
            let isOpen = dataChannel.readyState == .open
            let isClosed = dataChannel.readyState == .closed
            transport.updateReadiness { $0.setChannel(kind, isOpen: isOpen) }
            if isOpen || isClosed {
                transport.onChannelStateChanged?(kind, isOpen)
            }
            if isClosed {
                xboxWebRTCLog.error(
                    "Xbox Cloud data channel closed kind=\(kind.rawValue, privacy: .public)"
                )
            }
            if !isOpen,
               isClosed,
               XboxCloudRequiredChannelClosurePolicy.shouldTerminate(
                   channel: kind,
                   state: transport.state,
                   inputMode: transport.negotiatedInputMode
               )
            {
                transport.terminateActivePeer(
                    reason: "An Xbox Cloud session channel closed."
                )
            }
        }
    }

    nonisolated func dataChannel(
        _: LKRTCDataChannel,
        didChangeBufferedAmount _: UInt64
    ) {}

    nonisolated func dataChannel(
        _ dataChannel: LKRTCDataChannel,
        didReceiveMessageWith buffer: LKRTCDataBuffer
    ) {
        let data = buffer.data
        guard let kind = XboxCloudIncomingDataPolicy.channelKind(
            for: dataChannel.label
        ),
            XboxCloudIncomingDataPolicy.accepts(
                label: dataChannel.label,
                byteCount: data.count
            )
        else {
            return
        }
        let isBinary = buffer.isBinary
        let policy: XboxCloudDelegateEventPolicy =
            XboxCloudChannelNegotiationPolicy.isRequiredForOffer(kind)
                ? .required
                : .optional
        enqueueDelegateEvent(policy: policy) { transport in
            let handler = transport.channelReceiveState.withLock { $0.onMessage }
            handler?(kind, data, isBinary)
        }
    }
}
