import Foundation
@preconcurrency import LiveKitWebRTC
import Observation
import os

private nonisolated let xboxWebRTCLog = Logger(
    subsystem: "com.owenselles.CloudNow2",
    category: "XboxWebRTC"
)

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
        state: XboxCloudWebRTCConnectionState
    ) -> Bool {
        state.hasActivePeer
            && XboxCloudWebRTCReadiness.requiredChannels.contains(channel)
    }
}

nonisolated enum XboxCloudDataSendDisposition: Equatable, Sendable {
    case accepted
    case channelUnavailable
    case backpressured
    case payloadTooLarge
    case rejected
}

nonisolated struct XboxCloudCodecDescriptor: Equatable, Sendable {
    let name: String
    let payloadType: Int?
    let associatedPayloadType: Int?
}

nonisolated enum XboxCloudCodecPreferenceOrdering {
    static func indices(
        for codecs: [XboxCloudCodecDescriptor],
        preferredName: String?
    ) -> [Int] {
        let allIndices = Array(codecs.indices)
        guard let preferredName else { return allIndices }
        let preferredPrimaryIndices = Set(allIndices.filter {
            codecs[$0].name.caseInsensitiveCompare(preferredName) == .orderedSame
        })
        guard !preferredPrimaryIndices.isEmpty else { return allIndices }

        let preferredPayloadTypes = Set(preferredPrimaryIndices.compactMap {
            codecs[$0].payloadType
        })
        let preferredIndices = Set(allIndices.filter { index in
            if preferredPrimaryIndices.contains(index) {
                return true
            }
            let codec = codecs[index]
            return codec.name.caseInsensitiveCompare("rtx") == .orderedSame
                && codec.associatedPayloadType.map(preferredPayloadTypes.contains) == true
        })
        return allIndices.filter(preferredIndices.contains)
            + allIndices.filter { !preferredIndices.contains($0) }
    }
}

private nonisolated struct XboxCloudChannelSendState {
    var channels: [XboxCloudDataChannelKind: LKRTCDataChannel] = [:]
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
    private(set) var negotiatedInputVersion: Int?

    @ObservationIgnored var onChannelStateChanged: (@MainActor (
        _ channel: XboxCloudDataChannelKind,
        _ isOpen: Bool
    ) -> Void)?

    @ObservationIgnored var onChannelMessage: (@MainActor (
        _ channel: XboxCloudDataChannelKind,
        _ data: Data,
        _ isBinary: Bool
    ) -> Void)?

    @ObservationIgnored private let negotiationPipeline: XboxCloudWebRTCNegotiationPipeline
    @ObservationIgnored private let codecPreference: XboxCloudVideoCodecPreference
    @ObservationIgnored private var peerConnection: LKRTCPeerConnection?
    @ObservationIgnored private var videoReceiver: LKRTCRtpReceiver?
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
    @ObservationIgnored private let disconnectGracePeriod: Duration
    @ObservationIgnored private let peerOperationTimeout: Duration
    @ObservationIgnored private let sleep: XboxCloudBoundedCallback<Void>.Sleep

    /// Data channel sends can originate on the controller sampling queue. The lock only
    /// guards six references and one immediate WebRTC send; it never encloses an await.
    @ObservationIgnored private nonisolated let channelSendState = OSAllocatedUnfairLock(
        initialState: XboxCloudChannelSendState()
    )

    init(
        signaling: any XboxCloudSignalingProviding = XboxCloudSignalingAPI(),
        codecPreference: XboxCloudVideoCodecPreference = .automatic,
        disconnectGracePeriod: Duration = standardDisconnectGracePeriod,
        peerOperationTimeout: Duration = standardPeerOperationTimeout,
        sleep: @escaping XboxCloudBoundedCallback<Void>.Sleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        negotiationPipeline = XboxCloudWebRTCNegotiationPipeline(signaling: signaling)
        self.codecPreference = codecPreference
        self.disconnectGracePeriod = disconnectGracePeriod
        self.peerOperationTimeout = peerOperationTimeout
        self.sleep = sleep
        super.init()
    }

    /// Negotiates one already-provisioned Xbox Cloud session. The caller owns this task and
    /// should cancel it with the launch surface lifecycle; `disconnect()` invalidates it too.
    func connect(
        configuration: XboxCloudSessionConfiguration,
        signalingContext: XboxCloudSignalingContext
    ) async throws {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        terminalPeerFailure = nil
        releasePeerResources(resumingICEWaiterWith: CancellationError())
        resetPublishedConnectionState(to: .preparing)

        do {
            try preparePeer(configuration: configuration)
            guard generation == connectionGeneration else {
                throw CancellationError()
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

            negotiatedInputVersion = answer.input
            updateReadiness { readiness in
                readiness.setNegotiatedInputVersion(answer.input)
            }
            state = .connecting
            synchronizeReadinessFromPeer()
        } catch {
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
        localICETimeoutTask?.cancel()
        disconnectGraceTask?.cancel()
        localICEWaiter?.resume(throwing: CancellationError())
        pendingPeerOperation?.cancel(with: CancellationError())
        channelSendState.withLock { $0.channels.removeAll() }
        for channel in channels.values {
            channel.delegate = nil
            channel.close()
        }
        peerConnection?.delegate = nil
        peerConnection?.close()
    }

    private func preparePeer(configuration: XboxCloudSessionConfiguration) throws {
        let stunURLs = try Self.validatedSTUNURLs(
            configuration.serverDetails.stunServerAddresses ?? []
        )
        GFNAudioDevice.shared.requestedOutputChannels = 2

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
        applyCodecPreference(
            to: videoTransceiver,
            configuration: configuration
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
        xboxWebRTCLog.info("Prepared one Xbox Cloud peer with six data channels")
    }

    private func applyCodecPreference(
        to transceiver: LKRTCRtpTransceiver,
        configuration: XboxCloudSessionConfiguration
    ) {
        let preferredName: String? = switch codecPreference {
        case .automatic:
            nil
        case .h264:
            kLKRTCVideoCodecH264Name
        case .h265 where configuration.permitsHEVC:
            kLKRTCVideoCodecH265Name
        case .h265:
            nil
        }
        guard let preferredName else { return }

        let capabilities = CloudRTCRuntime.peerConnectionFactory
            .rtpReceiverCapabilities(
                forKind: kLKRTCMediaStreamTrackKindVideo
            )
        let codecs = capabilities.codecs
        let descriptors = codecs.map {
            XboxCloudCodecDescriptor(
                name: $0.name,
                payloadType: $0.preferredPayloadType?.intValue,
                associatedPayloadType: $0.parameters["apt"].flatMap(Int.init)
            )
        }
        let indices = XboxCloudCodecPreferenceOrdering.indices(
            for: descriptors,
            preferredName: preferredName
        )
        guard indices != Array(codecs.indices) else { return }
        do {
            try transceiver.setCodecPreferences(
                indices.map { codecs[$0] },
                error: ()
            )
        } catch {
            xboxWebRTCLog.error(
                "Xbox Cloud codec preference was unavailable; using WebRTC defaults"
            )
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
            readiness.setActiveMedia(videoTrack != nil)
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
            xboxWebRTCLog.info("Xbox Cloud media, peer, and required channels are ready")
        }
    }

    private func releasePeerResources(resumingICEWaiterWith error: Error) {
        cancelDisconnectGrace()
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
        videoTrack = nil
        localICECandidates.removeAll(keepingCapacity: true)
        localICECandidateKeys.removeAll(keepingCapacity: true)
        localICECollectionError = nil
        isLocalICEGatheringComplete = false
    }

    private func resetPublishedConnectionState(
        to state: XboxCloudWebRTCConnectionState
    ) {
        self.state = state
        readiness = XboxCloudWebRTCReadiness()
        negotiatedInputVersion = nil
        videoTrack = nil
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
        Task { @MainActor [weak self] in
            self?.handleICEConnectionState(newState, source: source)
        }
    }

    nonisolated func peerConnection(
        _ source: LKRTCPeerConnection,
        didChange newState: LKRTCIceGatheringState
    ) {
        guard newState == .complete else { return }
        Task { @MainActor [weak self] in
            self?.markLocalICEGatheringComplete(source: source)
        }
    }

    nonisolated func peerConnection(
        _ source: LKRTCPeerConnection,
        didGenerate candidate: LKRTCIceCandidate
    ) {
        Task { @MainActor [weak self] in
            self?.recordLocalICECandidate(candidate, source: source)
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
        Task { @MainActor [weak self] in
            self?.handlePeerConnectionState(newState, source: source)
        }
    }

    nonisolated func peerConnection(
        _ source: LKRTCPeerConnection,
        didAdd receiver: LKRTCRtpReceiver,
        streams _: [LKRTCMediaStream]
    ) {
        guard let track = receiver.track as? LKRTCVideoTrack else { return }
        Task { @MainActor [weak self] in
            guard let self, peerConnection === source else { return }
            videoReceiver = receiver
            videoTrack = track
            updateReadiness { $0.setActiveMedia(true) }
        }
    }

    nonisolated func peerConnection(
        _ source: LKRTCPeerConnection,
        didRemove receiver: LKRTCRtpReceiver
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  peerConnection === source,
                  videoReceiver === receiver
            else { return }
            videoReceiver = nil
            videoTrack = nil
            updateReadiness { $0.setActiveMedia(false) }
        }
    }
}

extension XboxCloudWebRTCTransport: LKRTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        Task { @MainActor [weak self] in
            guard let self,
                  let kind = dataChannelKind(for: dataChannel)
            else { return }
            let isOpen = dataChannel.readyState == .open
            updateReadiness { $0.setChannel(kind, isOpen: isOpen) }
            onChannelStateChanged?(kind, isOpen)
            if dataChannel.readyState == .closed {
                xboxWebRTCLog.error(
                    "Xbox Cloud data channel closed kind=\(kind.rawValue, privacy: .public)"
                )
            }
            if !isOpen,
               dataChannel.readyState == .closed,
               XboxCloudRequiredChannelClosurePolicy.shouldTerminate(
                   channel: kind,
                   state: state
               )
            {
                terminateActivePeer(reason: "An Xbox Cloud session channel closed.")
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
        let isBinary = buffer.isBinary
        Task { @MainActor [weak self] in
            guard let self,
                  let kind = dataChannelKind(for: dataChannel)
            else { return }
            onChannelMessage?(kind, data, isBinary)
        }
    }
}
