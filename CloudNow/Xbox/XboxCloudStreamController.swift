import Foundation
@preconcurrency import LiveKitWebRTC
import Observation

nonisolated enum XboxCloudStreamState: Equatable, Sendable {
    case idle
    case requestingAccess
    case allocating
    case waiting(estimatedSeconds: TimeInterval?)
    case provisioning(estimatedSeconds: TimeInterval?)
    case connecting
    case streaming
    case stopping
    case failed(message: String)
}

nonisolated struct XboxCloudStreamControllerPolicy: Equatable, Sendable {
    static let standard = XboxCloudStreamControllerPolicy(
        uncheckedMaximumConsecutiveKeepAliveFailures: 3,
        minimumKeepAliveInterval: 1,
        maximumKeepAliveInterval: 3600,
        mediaMonitorInterval: 0.25
    )

    let maximumConsecutiveKeepAliveFailures: Int
    let minimumKeepAliveInterval: TimeInterval
    let maximumKeepAliveInterval: TimeInterval
    let mediaMonitorInterval: TimeInterval

    init(
        maximumConsecutiveKeepAliveFailures: Int,
        minimumKeepAliveInterval: TimeInterval,
        maximumKeepAliveInterval: TimeInterval,
        mediaMonitorInterval: TimeInterval
    ) throws {
        guard (1 ... 10).contains(maximumConsecutiveKeepAliveFailures),
              minimumKeepAliveInterval.isFinite,
              maximumKeepAliveInterval.isFinite,
              mediaMonitorInterval.isFinite,
              (0.01 ... 60).contains(minimumKeepAliveInterval),
              (minimumKeepAliveInterval ... 3600).contains(maximumKeepAliveInterval),
              (0.05 ... 5).contains(mediaMonitorInterval)
        else {
            throw XboxCloudStreamControllerError.invalidPolicy
        }
        self.init(
            uncheckedMaximumConsecutiveKeepAliveFailures: maximumConsecutiveKeepAliveFailures,
            minimumKeepAliveInterval: minimumKeepAliveInterval,
            maximumKeepAliveInterval: maximumKeepAliveInterval,
            mediaMonitorInterval: mediaMonitorInterval
        )
    }

    func keepAliveInterval(for requestedInterval: TimeInterval) -> TimeInterval {
        min(
            max(requestedInterval, minimumKeepAliveInterval),
            maximumKeepAliveInterval
        )
    }

    private init(
        uncheckedMaximumConsecutiveKeepAliveFailures maximumConsecutiveKeepAliveFailures: Int,
        minimumKeepAliveInterval: TimeInterval,
        maximumKeepAliveInterval: TimeInterval,
        mediaMonitorInterval: TimeInterval
    ) {
        self.maximumConsecutiveKeepAliveFailures = maximumConsecutiveKeepAliveFailures
        self.minimumKeepAliveInterval = minimumKeepAliveInterval
        self.maximumKeepAliveInterval = maximumKeepAliveInterval
        self.mediaMonitorInterval = mediaMonitorInterval
    }
}

/// Coarse, UI-facing Xbox stream state. Provider traffic, controller sampling,
/// keepalive pulses, and WebRTC callbacks are deliberately observation-ignored
/// so SwiftUI only invalidates for meaningful launch/player transitions.
@Observable
@MainActor
final class XboxCloudStreamController {
    private struct ActiveOperation {
        let generation: UInt64
        let lifecycle: any XboxCloudSessionLifecycleServing
        let token: XboxCloudStreamSessionToken
        var runtime: (any XboxCloudStreamRuntime)?
    }

    private(set) var state: XboxCloudStreamState = .idle
    private(set) var videoTrack: LKRTCVideoTrack?
    private(set) var activeGameID: String?

    var isStreaming: Bool {
        state == .streaming
    }

    @ObservationIgnored private let sessionProvider: any XboxCloudGSSessionProviding
    @ObservationIgnored private let transferToken: @Sendable () async throws -> String
    @ObservationIgnored private let deviceInformation: XboxCloudDeviceInformation
    @ObservationIgnored private let makeSessionLifecycle: @MainActor @Sendable (
        XboxCloudSessionAccessContext
    ) -> any XboxCloudSessionLifecycleServing
    @ObservationIgnored private let makeRuntime: @MainActor @Sendable (
        XboxCloudStreamSettings
    ) -> any XboxCloudStreamRuntime
    @ObservationIgnored private let policy: XboxCloudStreamControllerPolicy
    @ObservationIgnored private let timezoneOffsetMinutes: @Sendable () -> Int
    @ObservationIgnored private let keepAliveSleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private let monitorSleep: @Sendable (TimeInterval) async throws -> Void

    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var launchTask: Task<Void, Error>?
    @ObservationIgnored private var launchTaskGeneration: UInt64?
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var mediaMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var activeOperation: ActiveOperation?

    init(
        sessionProvider: any XboxCloudGSSessionProviding,
        transferToken: @escaping @Sendable () async throws -> String,
        deviceInformation: XboxCloudDeviceInformation = .cloudNowTV(),
        makeSessionLifecycle: @escaping @MainActor @Sendable (
            XboxCloudSessionAccessContext
        ) -> any XboxCloudSessionLifecycleServing = { access in
            XboxCloudSessionLifecycleClient(
                api: XboxCloudSessionAPI(access: access)
            )
        },
        makeRuntime: @escaping @MainActor @Sendable (
            XboxCloudStreamSettings
        ) -> any XboxCloudStreamRuntime = { settings in
            XboxCloudNativeStreamRuntime(
                inputDriver: XboxCloudInputDriver(
                    deadzone: Float(settings.controllerDeadzone),
                    rumbleEnabled: settings.rumbleEnabled,
                    rumbleIntensity: Float(settings.rumbleIntensity)
                )
            )
        },
        policy: XboxCloudStreamControllerPolicy = .standard,
        timezoneOffsetMinutes: @escaping @Sendable () -> Int = {
            TimeZone.current.secondsFromGMT() / 60
        },
        keepAliveSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(
                nanoseconds: XboxCloudStreamController.nanoseconds(for: seconds)
            )
        },
        monitorSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(
                nanoseconds: XboxCloudStreamController.nanoseconds(for: seconds)
            )
        }
    ) {
        self.sessionProvider = sessionProvider
        self.transferToken = transferToken
        self.deviceInformation = deviceInformation
        self.makeSessionLifecycle = makeSessionLifecycle
        self.makeRuntime = makeRuntime
        self.policy = policy
        self.timezoneOffsetMinutes = timezoneOffsetMinutes
        self.keepAliveSleep = keepAliveSleep
        self.monitorSleep = monitorSleep
    }

    isolated deinit {
        launchTask?.cancel()
        keepAliveTask?.cancel()
        mediaMonitorTask?.cancel()
        activeOperation?.runtime?.disconnect()
        if let activeOperation {
            let lifecycle = activeOperation.lifecycle
            let token = activeOperation.token
            Task { @concurrent in
                await lifecycle.delete(token)
            }
        }
    }

    func start(
        gameID: String,
        account: XboxCloudAuthorizedAccount,
        locale: String,
        settings: XboxCloudStreamSettings
    ) async throws {
        await stop()

        generation &+= 1
        let operationGeneration = generation
        activeGameID = gameID
        state = .requestingAccess

        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await performStart(
                gameID: gameID,
                account: account,
                locale: locale,
                settings: settings,
                generation: operationGeneration
            )
        }
        launchTask = task
        launchTaskGeneration = operationGeneration

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            clearLaunchTask(matching: operationGeneration)
        } catch is CancellationError {
            clearLaunchTask(matching: operationGeneration)
            throw CancellationError()
        } catch {
            clearLaunchTask(matching: operationGeneration)
            throw error
        }
    }

    /// Releases media and input synchronously, then performs a best-effort
    /// server DELETE before returning. Repeated calls are safe.
    func stop() async {
        generation &+= 1
        let stopGeneration = generation
        let hadWork = launchTask != nil || activeOperation != nil || state != .idle
        if hadWork {
            state = .stopping
        }

        launchTask?.cancel()
        launchTask = nil
        launchTaskGeneration = nil
        let operation = detachActiveResources()

        if let operation {
            await Self.deleteBestEffort(operation)
        }
        guard generation == stopGeneration else { return }
        state = .idle
    }

    private func performStart(
        gameID: String,
        account: XboxCloudAuthorizedAccount,
        locale: String,
        settings: XboxCloudStreamSettings,
        generation operationGeneration: UInt64
    ) async throws {
        do {
            let gsSession = try await sessionProvider.session(for: account)
            try ensureCurrent(operationGeneration)
            let access = try gsSession.makeSessionAccessContext(
                deviceInformation: deviceInformation,
                msaTransferToken: transferToken
            )
            let lifecycle = makeSessionLifecycle(access)

            let launchSettings = XboxCloudSessionLaunchSettings(
                enableTextToSpeech: settings.enableTextToSpeech,
                magnifier: settings.magnifier,
                highContrast: settings.highContrast ? 1 : 0,
                locale: locale,
                timezoneOffsetMinutes: timezoneOffsetMinutes(),
                enableOptionalDataCollection: settings.enableOptionalDataCollection
            )
            let launchRequest = try XboxCloudSessionLaunchRequest(
                titleID: gameID,
                settings: launchSettings
            )
            state = .allocating
            let token = try await lifecycle.createSession(launchRequest)
            do {
                try ensureCurrent(operationGeneration)
            } catch {
                await Self.deleteBestEffort(
                    lifecycle: lifecycle,
                    token: token
                )
                throw error
            }
            activeOperation = ActiveOperation(
                generation: operationGeneration,
                lifecycle: lifecycle,
                token: token,
                runtime: nil
            )

            let prepared = try await lifecycle.provisionSession(token) { [weak self] snapshot in
                await self?.apply(
                    snapshot,
                    generation: operationGeneration
                )
            }
            try ensureCurrent(operationGeneration)
            state = .connecting

            let runtime = makeRuntime(settings)
            guard var operation = activeOperation,
                  operation.generation == operationGeneration
            else {
                runtime.disconnect()
                throw CancellationError()
            }
            operation.runtime = runtime
            activeOperation = operation

            try await runtime.connect(
                configuration: prepared.configuration,
                signalingContext: prepared.signalingContext
            )
            try ensureCurrent(operationGeneration)
            guard let track = runtime.videoTrack else {
                throw XboxCloudStreamControllerError.missingVideoTrack
            }

            videoTrack = track
            state = .streaming
            startKeepAlive(
                lifecycle: lifecycle,
                token: token,
                runtime: runtime,
                interval: policy.keepAliveInterval(
                    for: prepared.configuration.keepAlivePulse
                ),
                generation: operationGeneration
            )
            startMediaMonitor(
                runtime: runtime,
                generation: operationGeneration
            )
        } catch is CancellationError {
            guard generation == operationGeneration else {
                throw CancellationError()
            }
            let operation = detachActiveResources()
            if let operation {
                await Self.deleteBestEffort(operation)
            }
            state = .idle
            throw CancellationError()
        } catch {
            guard generation == operationGeneration else {
                throw CancellationError()
            }
            let safeError = Self.sanitizedControllerError(error)
            let operation = detachActiveResources()
            if let operation {
                await Self.deleteBestEffort(operation)
            }
            guard generation == operationGeneration else {
                throw CancellationError()
            }
            state = .failed(message: safeError.localizedDescription)
            throw safeError
        }
    }

    private func apply(
        _ snapshot: XboxCloudSessionStateSnapshot,
        generation operationGeneration: UInt64
    ) {
        guard generation == operationGeneration else { return }
        switch snapshot.state {
        case .waitingForResources:
            state = .waiting(
                estimatedSeconds: snapshot.estimatedTotalWaitTime
            )
        case .readyToConnect, .provisioning:
            state = .provisioning(
                estimatedSeconds: snapshot.estimatedTotalWaitTime
            )
        case .provisioned:
            state = .connecting
        case .failed, .unknown:
            break
        }
    }

    private func startKeepAlive(
        lifecycle: any XboxCloudSessionLifecycleServing,
        token: XboxCloudStreamSessionToken,
        runtime: any XboxCloudStreamRuntime,
        interval: TimeInterval,
        generation operationGeneration: UInt64
    ) {
        keepAliveTask?.cancel()
        let sleep = keepAliveSleep
        let maximumFailures = policy.maximumConsecutiveKeepAliveFailures
        keepAliveTask = Task { @concurrent [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                    try Task.checkCancellation()
                    guard await self?.isActive(operationGeneration) == true else {
                        return
                    }
                    await runtime.sendInputKeepAlive()
                    try await lifecycle.keepAlive(token)
                    consecutiveFailures = 0
                } catch is CancellationError {
                    return
                } catch {
                    consecutiveFailures += 1
                    guard consecutiveFailures >= maximumFailures else { continue }
                    await self?.backgroundFailure(
                        .keepAliveFailed,
                        generation: operationGeneration
                    )
                    return
                }
            }
        }
    }

    private func startMediaMonitor(
        runtime: any XboxCloudStreamRuntime,
        generation operationGeneration: UInt64
    ) {
        mediaMonitorTask?.cancel()
        let interval = policy.mediaMonitorInterval
        let sleep = monitorSleep
        mediaMonitorTask = Task { @concurrent [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard await self?.isActive(operationGeneration) == true else {
                    return
                }
                let failure = await Self.mediaFailure(from: runtime.connectionState)
                guard let failure else { continue }
                await self?.backgroundFailure(
                    failure,
                    generation: operationGeneration
                )
                return
            }
        }
    }

    private func backgroundFailure(
        _ error: XboxCloudStreamControllerError,
        generation operationGeneration: UInt64
    ) async {
        guard generation == operationGeneration else { return }
        generation &+= 1
        let failureGeneration = generation
        let operation = detachActiveResources()
        if let operation {
            await Self.deleteBestEffort(operation)
        }
        guard generation == failureGeneration else { return }
        state = .failed(message: error.localizedDescription)
    }

    private func detachActiveResources() -> ActiveOperation? {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        mediaMonitorTask?.cancel()
        mediaMonitorTask = nil
        activeOperation?.runtime?.disconnect()
        let operation = activeOperation
        activeOperation = nil
        videoTrack = nil
        activeGameID = nil
        return operation
    }

    private func clearLaunchTask(matching operationGeneration: UInt64) {
        guard launchTaskGeneration == operationGeneration else { return }
        launchTask = nil
        launchTaskGeneration = nil
    }

    private func ensureCurrent(_ operationGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard generation == operationGeneration else {
            throw CancellationError()
        }
    }

    private func isActive(_ operationGeneration: UInt64) -> Bool {
        generation == operationGeneration
            && activeOperation?.generation == operationGeneration
            && state == .streaming
    }

    private static func mediaFailure(
        from state: XboxCloudWebRTCConnectionState
    ) -> XboxCloudStreamControllerError? {
        switch state {
        case let .disconnected(reason):
            .mediaDisconnected(message: reason)
        case let .failed(message):
            .mediaDisconnected(message: message)
        case .idle:
            .mediaDisconnected(message: "Xbox Cloud media stopped unexpectedly.")
        case .preparing, .negotiating, .connecting, .connected:
            nil
        }
    }

    private static func sanitizedControllerError(
        _ error: Error
    ) -> XboxCloudStreamControllerError {
        if let error = error as? XboxCloudStreamControllerError {
            return error
        }
        let safeMessage: String? = switch error {
        case let error as XboxCloudOfferingServiceError:
            error.localizedDescription
        case let error as XboxLiveAuthorizationError:
            error.localizedDescription
        case let error as XboxCloudSessionAPIError:
            error.localizedDescription
        case let error as XboxCloudStreamLifecycleError:
            error.localizedDescription
        case let error as XboxCloudWebRTCTransportError:
            error.localizedDescription
        case let error as XboxCloudSignalingError:
            error.localizedDescription
        case let error as XboxLegacyInputCodecError:
            error.localizedDescription
        default:
            nil
        }
        return .launchFailed(
            message: safeMessage ?? "Xbox Cloud streaming could not be started."
        )
    }

    /// Teardown runs in a fresh task because launch cancellation must not stop
    /// the REST client before it can issue the best-effort server DELETE.
    private static func deleteBestEffort(
        _ operation: ActiveOperation
    ) async {
        await deleteBestEffort(
            lifecycle: operation.lifecycle,
            token: operation.token
        )
    }

    private nonisolated static func deleteBestEffort(
        lifecycle: any XboxCloudSessionLifecycleServing,
        token: XboxCloudStreamSessionToken
    ) async {
        await Task { @concurrent in
            await lifecycle.delete(token)
        }.value
    }

    private nonisolated static func nanoseconds(
        for interval: TimeInterval
    ) -> UInt64 {
        let boundedInterval = min(max(interval, 0), 3600)
        return UInt64(boundedInterval * 1_000_000_000)
    }
}

nonisolated enum XboxCloudStreamControllerError: Error, Equatable, Sendable, LocalizedError {
    case invalidPolicy
    case missingVideoTrack
    case launchFailed(message: String)
    case keepAliveFailed
    case mediaDisconnected(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidPolicy:
            "Xbox Cloud stream policy is invalid."
        case .missingVideoTrack:
            "Xbox Cloud connected without a video stream."
        case let .launchFailed(message):
            message
        case .keepAliveFailed:
            "Xbox Cloud stopped responding to session keepalive requests."
        case let .mediaDisconnected(message):
            message
        }
    }
}
