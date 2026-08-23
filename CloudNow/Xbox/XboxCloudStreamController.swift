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
    case reconnecting(
        attempt: Int,
        maximumAttempts: Int,
        nextDelay: TimeInterval?
    )
    case stopping
    case failed(message: String)
}

nonisolated struct XboxCloudStreamControllerPolicy: Equatable, Sendable {
    static let standard = XboxCloudStreamControllerPolicy(
        uncheckedMaximumConsecutiveKeepAliveFailures: 3,
        minimumKeepAliveInterval: 1,
        maximumKeepAliveInterval: 3600,
        mediaMonitorInterval: 0.25,
        maximumReconnectAttempts: 3,
        initialReconnectDelay: 1,
        reconnectWindow: 30
    )

    let maximumConsecutiveKeepAliveFailures: Int
    let minimumKeepAliveInterval: TimeInterval
    let maximumKeepAliveInterval: TimeInterval
    let mediaMonitorInterval: TimeInterval
    let maximumReconnectAttempts: Int
    let initialReconnectDelay: TimeInterval
    let reconnectWindow: TimeInterval

    init(
        maximumConsecutiveKeepAliveFailures: Int,
        minimumKeepAliveInterval: TimeInterval,
        maximumKeepAliveInterval: TimeInterval,
        mediaMonitorInterval: TimeInterval,
        maximumReconnectAttempts: Int = 3,
        initialReconnectDelay: TimeInterval = 1,
        reconnectWindow: TimeInterval = 30
    ) throws {
        guard (1 ... 10).contains(maximumConsecutiveKeepAliveFailures),
              minimumKeepAliveInterval.isFinite,
              maximumKeepAliveInterval.isFinite,
              mediaMonitorInterval.isFinite,
              initialReconnectDelay.isFinite,
              reconnectWindow.isFinite,
              (0.01 ... 60).contains(minimumKeepAliveInterval),
              (minimumKeepAliveInterval ... 3600).contains(maximumKeepAliveInterval),
              (0.05 ... 5).contains(mediaMonitorInterval),
              (1 ... 3).contains(maximumReconnectAttempts),
              (0.01 ... 5).contains(initialReconnectDelay),
              (1 ... 30).contains(reconnectWindow)
        else {
            throw XboxCloudStreamControllerError.invalidPolicy
        }
        let backoffBudget = initialReconnectDelay
            * (pow(2, Double(maximumReconnectAttempts - 1)) - 1)
        guard backoffBudget < reconnectWindow else {
            throw XboxCloudStreamControllerError.invalidPolicy
        }
        self.init(
            uncheckedMaximumConsecutiveKeepAliveFailures: maximumConsecutiveKeepAliveFailures,
            minimumKeepAliveInterval: minimumKeepAliveInterval,
            maximumKeepAliveInterval: maximumKeepAliveInterval,
            mediaMonitorInterval: mediaMonitorInterval,
            maximumReconnectAttempts: maximumReconnectAttempts,
            initialReconnectDelay: initialReconnectDelay,
            reconnectWindow: reconnectWindow
        )
    }

    func keepAliveInterval(for requestedInterval: TimeInterval) -> TimeInterval {
        min(
            max(requestedInterval, minimumKeepAliveInterval),
            maximumKeepAliveInterval
        )
    }

    func reconnectDelay(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        return initialReconnectDelay * pow(2, Double(attempt - 2))
    }

    private init(
        uncheckedMaximumConsecutiveKeepAliveFailures maximumConsecutiveKeepAliveFailures: Int,
        minimumKeepAliveInterval: TimeInterval,
        maximumKeepAliveInterval: TimeInterval,
        mediaMonitorInterval: TimeInterval,
        maximumReconnectAttempts: Int,
        initialReconnectDelay: TimeInterval,
        reconnectWindow: TimeInterval
    ) {
        self.maximumConsecutiveKeepAliveFailures = maximumConsecutiveKeepAliveFailures
        self.minimumKeepAliveInterval = minimumKeepAliveInterval
        self.maximumKeepAliveInterval = maximumKeepAliveInterval
        self.mediaMonitorInterval = mediaMonitorInterval
        self.maximumReconnectAttempts = maximumReconnectAttempts
        self.initialReconnectDelay = initialReconnectDelay
        self.reconnectWindow = reconnectWindow
    }
}

private nonisolated enum XboxCloudReconnectRecoveryResult: Sendable {
    case recovered
    case failed(XboxCloudStreamControllerError)
    case timedOut
    case cancelled
}

/// Coarse, UI-facing Xbox stream state. Provider traffic, controller sampling,
/// keepalive pulses, and WebRTC callbacks are deliberately observation-ignored
/// so SwiftUI only invalidates for meaningful launch/player transitions.
@Observable
@MainActor
final class XboxCloudStreamController {
    private struct ActiveOperation {
        var generation: UInt64
        let lifecycle: any XboxCloudSessionLifecycleServing
        let token: XboxCloudStreamSessionToken
        let serviceExpiresAt: Date
        let streamSettings: XboxCloudStreamSettings
        var preparedStream: XboxCloudPreparedStream?
        var runtime: (any XboxCloudStreamRuntime)?
    }

    private struct SessionDeletion {
        let lifecycle: any XboxCloudSessionLifecycleServing
        let token: XboxCloudStreamSessionToken
    }

    private struct SessionDeletionOperation {
        let id: UUID
        let task: Task<Bool, Never>
    }

    private(set) var state: XboxCloudStreamState = .idle
    private(set) var videoTrack: LKRTCVideoTrack?
    private(set) var activeGameID: String?
    private(set) var stats = StreamStats()
    private(set) var audioStats = AudioStats()
    private(set) var statsMode: StreamStatsMode = .off
    private(set) var streamingStartedAt: Date?
    private(set) var serverLocation = ""
    private(set) var menuPressCount = 0
    private(set) var microphoneEnabledForConnection = false
    private(set) var diagnosticsEnabled = false
    private(set) var rtcEventLogActive = false
    private(set) var resumableSessionExpiresAt: Date?
    private(set) var coordinatorServerSessionID: String?
    private(set) var colorState = StreamColorState(
        preference: .automatic,
        requestedMode: .sdr8,
        negotiatedMode: nil,
        detectedMode: nil,
        displayHDRSupport: .unknown,
        fallbackReason: nil
    )

    var isStreaming: Bool {
        state == .streaming
    }

    var canContinueSession: Bool {
        guard state != .streaming,
              activeOperation?.preparedStream != nil,
              activeOperation?.runtime != nil,
              let resumableSessionExpiresAt
        else {
            return false
        }
        return resumableSessionExpiresAt > now()
    }

    var canLeaveSession: Bool {
        guard let operation = activeOperation,
              operation.preparedStream != nil,
              operation.runtime != nil,
              operation.serviceExpiresAt > now()
        else {
            return false
        }
        switch state {
        case .streaming, .reconnecting:
            return true
        case .idle, .requestingAccess, .allocating, .waiting, .provisioning,
             .connecting, .stopping, .failed:
            return false
        }
    }

    var hasUnconfirmedSessionDeletion: Bool {
        !pendingSessionDeletions.isEmpty
    }

    /// Normalized settings retained by the live or resumable allocation.
    /// Continue reuses that allocation and its runtime, so player presentation
    /// must not substitute preferences changed after the original launch.
    var activeStreamSettings: XboxCloudStreamSettings? {
        activeOperation?.streamSettings
    }

    @ObservationIgnored private let sessionProvider: any XboxCloudGSSessionProviding
    @ObservationIgnored private let transferToken: @Sendable () async throws -> String
    @ObservationIgnored private let deviceInformationProvider: @MainActor @Sendable () -> XboxCloudDeviceInformation
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
    @ObservationIgnored private let reconnectSleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private let reconnectDeadlineSleep: @Sendable (
        TimeInterval
    ) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date

    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var launchTask: Task<Void, Error>?
    @ObservationIgnored private var launchTaskGeneration: UInt64?
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var mediaMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var statisticsTask: Task<Void, Never>?
    @ObservationIgnored private var resumeExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var statisticsGeneration: UInt64 = 0
    @ObservationIgnored private var activeOperation: ActiveOperation?
    @ObservationIgnored private var pendingSessionDeletions: [
        XboxCloudStreamSessionToken: SessionDeletion
    ] = [:]
    @ObservationIgnored private var sessionDeletionOperations: [
        XboxCloudStreamSessionToken: SessionDeletionOperation
    ] = [:]

    init(
        sessionProvider: any XboxCloudGSSessionProviding,
        transferToken: @escaping @Sendable () async throws -> String,
        deviceInformation: XboxCloudDeviceInformation = .cloudNowTV(),
        deviceInformationProvider: (@MainActor @Sendable () -> XboxCloudDeviceInformation)? = nil,
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
                    rumbleIntensity: Float(settings.rumbleIntensity),
                    preferredResolution: settings.displayResolution
                ),
                microphoneRequested: settings.microphoneEnabled,
                diagnosticsEnabled: settings.diagnosticsEnabled,
                rtcEventLogRequested: settings.enableRtcEventLog
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
        },
        reconnectSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(
                nanoseconds: XboxCloudStreamController.nanoseconds(for: seconds)
            )
        },
        reconnectDeadlineSleep: @escaping @Sendable (
            TimeInterval
        ) async throws -> Void = { seconds in
            try await Task.sleep(
                nanoseconds: XboxCloudStreamController.nanoseconds(for: seconds)
            )
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sessionProvider = sessionProvider
        self.transferToken = transferToken
        if let deviceInformationProvider {
            self.deviceInformationProvider = deviceInformationProvider
        } else {
            self.deviceInformationProvider = { deviceInformation }
        }
        self.makeSessionLifecycle = makeSessionLifecycle
        self.makeRuntime = makeRuntime
        self.policy = policy
        self.timezoneOffsetMinutes = timezoneOffsetMinutes
        self.keepAliveSleep = keepAliveSleep
        self.monitorSleep = monitorSleep
        self.reconnectSleep = reconnectSleep
        self.reconnectDeadlineSleep = reconnectDeadlineSleep
        self.now = now
    }

    isolated deinit {
        launchTask?.cancel()
        keepAliveTask?.cancel()
        mediaMonitorTask?.cancel()
        statisticsTask?.cancel()
        resumeExpiryTask?.cancel()
        activeOperation?.runtime?.disconnect()
        if let activeOperation {
            Self.deleteAfterOwnerDeinitializes(
                lifecycle: activeOperation.lifecycle,
                token: activeOperation.token
            )
        }
        if let pendingDeletion = pendingSessionDeletions.values.first,
           pendingDeletion.token != activeOperation?.token
        {
            Self.deleteAfterOwnerDeinitializes(
                lifecycle: pendingDeletion.lifecycle,
                token: pendingDeletion.token
            )
        }
    }

    func start(
        gameID: String,
        account: XboxCloudAuthorizedAccount,
        locale: String,
        settings: XboxCloudStreamSettings,
        onSessionCreated: (@MainActor @Sendable (String) throws -> Void)? = nil
    ) async throws {
        guard await stop() else {
            let error = XboxCloudStreamControllerError.sessionDeletionUnconfirmed
            state = .failed(message: error.localizedDescription)
            throw error
        }

        let settings = settings.normalizedForClient

        let deviceInformation = deviceInformationProvider()
        generation &+= 1
        let operationGeneration = generation
        activeGameID = gameID
        menuPressCount = 0
        resetStatistics(settings: settings)
        state = .requestingAccess

        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await performStart(
                gameID: gameID,
                account: account,
                locale: locale,
                settings: settings,
                deviceInformation: deviceInformation,
                onSessionCreated: onSessionCreated,
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
            try ensureCurrent(operationGeneration)
            clearLaunchTask(matching: operationGeneration)
        } catch is CancellationError {
            clearLaunchTask(matching: operationGeneration)
            throw CancellationError()
        } catch {
            clearLaunchTask(matching: operationGeneration)
            throw error
        }
    }

    /// Releases media and input synchronously, then reports whether every owned
    /// server allocation was confirmed deleted. Repeated calls retry failures.
    @discardableResult
    func stop() async -> Bool {
        generation &+= 1
        let stopGeneration = generation
        let hadWork = launchTask != nil
            || activeOperation != nil
            || !pendingSessionDeletions.isEmpty
            || state != .idle
        if hadWork {
            state = .stopping
        }

        let cancelledLaunchTask = launchTask
        let cancelledLaunchGeneration = launchTaskGeneration
        cancelledLaunchTask?.cancel()
        let operation = detachActiveResources()

        if let operation {
            retainForDeletion(operation)
        }
        if let cancelledLaunchTask {
            _ = await cancelledLaunchTask.result
        }
        if let cancelledLaunchGeneration {
            clearLaunchTask(matching: cancelledLaunchGeneration)
        }
        let didDelete = await confirmPendingSessionDeletions()
        guard generation == stopGeneration else { return didDelete }
        state = .idle
        return didDelete
    }

    /// Leaves playback locally while retaining exactly one server allocation
    /// until the Game Streaming credential expires. Keepalive continues without
    /// input traffic so an explicit Continue can renegotiate the same session.
    func leave() {
        guard canLeaveSession,
              var operation = activeOperation,
              let preparedStream = operation.preparedStream,
              let runtime = operation.runtime
        else {
            return
        }

        generation &+= 1
        let leaveGeneration = generation
        operation.generation = leaveGeneration
        activeOperation = operation
        mediaMonitorTask?.cancel()
        mediaMonitorTask = nil
        stopStatisticsMonitor()
        resumeExpiryTask?.cancel()
        resumeExpiryTask = nil
        runtime.setMenuToggleHandler(nil)
        runtime.setInputPaused(true)
        runtime.disconnect()
        videoTrack = nil
        microphoneEnabledForConnection = false
        diagnosticsEnabled = false
        rtcEventLogActive = false
        streamingStartedAt = nil
        resumableSessionExpiresAt = operation.serviceExpiresAt
        state = .idle

        startKeepAlive(
            lifecycle: operation.lifecycle,
            token: operation.token,
            runtime: runtime,
            interval: policy.keepAliveInterval(
                for: preparedStream.configuration.keepAlivePulse
            ),
            generation: leaveGeneration
        )
        startResumeExpiryMonitor(
            expiresAt: operation.serviceExpiresAt,
            generation: leaveGeneration
        )
    }

    /// Backgrounding has Leave semantics. The UI owns when to call this hook;
    /// it intentionally does not broaden background execution privileges.
    func leaveForBackground() {
        leave()
    }

    /// Reconnects the locally retained allocation without creating a second
    /// Xbox Cloud session.
    func continueSession() async throws {
        guard var operation = activeOperation,
              let preparedStream = operation.preparedStream,
              let runtime = operation.runtime,
              resumableSessionExpiresAt != nil
        else {
            throw XboxCloudStreamControllerError.noResumableSession
        }
        guard operation.serviceExpiresAt > now() else {
            generation &+= 1
            let expiryGeneration = generation
            state = .stopping
            let expiredOperation = detachActiveResources()
            if let expiredOperation {
                _ = await deleteAndRetainIfNeeded(expiredOperation)
            }
            guard generation == expiryGeneration else {
                throw CancellationError()
            }
            state = .idle
            throw XboxCloudStreamControllerError.resumableSessionExpired
        }

        resumeExpiryTask?.cancel()
        resumeExpiryTask = nil
        generation &+= 1
        let continueGeneration = generation
        operation.generation = continueGeneration
        activeOperation = operation
        resumableSessionExpiresAt = nil
        state = .connecting
        runtime.setMenuToggleHandler { [weak self] in
            self?.handleMenuPress(generation: continueGeneration)
        }
        startKeepAlive(
            lifecycle: operation.lifecycle,
            token: operation.token,
            runtime: runtime,
            interval: policy.keepAliveInterval(
                for: preparedStream.configuration.keepAlivePulse
            ),
            generation: continueGeneration
        )

        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await runtime.connect(
                configuration: preparedStream.configuration,
                signalingContext: preparedStream.signalingContext
            )
            try ensureCurrent(continueGeneration)
            guard let track = runtime.videoTrack else {
                throw XboxCloudStreamControllerError.missingVideoTrack
            }
            runtime.setInputPaused(false)
            videoTrack = track
            microphoneEnabledForConnection = runtime.microphoneEnabled
            updateDiagnostics(from: runtime)
            streamingStartedAt = now()
            state = .streaming
            startMediaMonitor(
                runtime: runtime,
                generation: continueGeneration
            )
            if shouldCollectStatistics {
                startStatisticsMonitor(
                    runtime: runtime,
                    generation: continueGeneration
                )
            }
        }
        launchTask = task
        launchTaskGeneration = continueGeneration

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try ensureCurrent(continueGeneration)
            clearLaunchTask(matching: continueGeneration)
        } catch is CancellationError {
            clearLaunchTask(matching: continueGeneration)
            guard generation == continueGeneration else {
                throw CancellationError()
            }
            restoreResumableState(operation, failure: nil)
            throw CancellationError()
        } catch {
            clearLaunchTask(matching: continueGeneration)
            guard generation == continueGeneration else {
                throw CancellationError()
            }
            let safeError = Self.sanitizedControllerError(error)
            restoreResumableState(operation, failure: safeError)
            throw safeError
        }
    }

    /// Explicit End succeeds only after the service confirms deletion.
    @discardableResult
    func endSession() async -> Bool {
        await stop()
    }

    private func performStart(
        gameID: String,
        account: XboxCloudAuthorizedAccount,
        locale: String,
        settings: XboxCloudStreamSettings,
        deviceInformation: XboxCloudDeviceInformation,
        onSessionCreated: (@MainActor @Sendable (String) throws -> Void)?,
        generation operationGeneration: UInt64
    ) async throws {
        do {
            let gsSession = try await sessionProvider.session(for: account)
            try ensureCurrent(operationGeneration)
            serverLocation = gsSession.defaultRegion.name
            let access = try gsSession.makeSessionAccessContext(
                deviceInformation: deviceInformation,
                compatibilityProfile: .microsoftWeb,
                msaTransferToken: transferToken
            )
            let lifecycle = makeSessionLifecycle(access)

            let launchSettings = XboxCloudSessionLaunchSettings(
                enableTextToSpeech: settings.enableTextToSpeech,
                magnifier: settings.magnifier,
                highContrast: settings.highContrast ? 1 : 0,
                locale: locale,
                timezoneOffsetMinutes: timezoneOffsetMinutes(),
                enableOptionalDataCollection: false
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
                _ = await deleteAndRetainIfNeeded(
                    lifecycle: lifecycle,
                    token: token
                )
                throw error
            }
            activeOperation = ActiveOperation(
                generation: operationGeneration,
                lifecycle: lifecycle,
                token: token,
                serviceExpiresAt: gsSession.expiresAt,
                streamSettings: settings,
                preparedStream: nil,
                runtime: nil
            )
            coordinatorServerSessionID = token.coordinatorSessionID
            try onSessionCreated?(token.coordinatorSessionID)

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
            operation.preparedStream = prepared
            runtime.setMenuToggleHandler { [weak self] in
                self?.handleMenuPress(generation: operationGeneration)
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
            microphoneEnabledForConnection = runtime.microphoneEnabled
            updateDiagnostics(from: runtime)
            state = .streaming
            streamingStartedAt = now()
            resumableSessionExpiresAt = nil
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
            if shouldCollectStatistics {
                startStatisticsMonitor(
                    runtime: runtime,
                    generation: operationGeneration
                )
            }
        } catch is CancellationError {
            guard generation == operationGeneration else {
                throw CancellationError()
            }
            let operation = detachActiveResources()
            if let operation {
                _ = await deleteAndRetainIfNeeded(operation)
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
                _ = await deleteAndRetainIfNeeded(operation)
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
                    guard await self?.isOwned(operationGeneration) == true else {
                        return
                    }
                    if await self?.shouldPulseInput(operationGeneration) == true {
                        await runtime.sendInputKeepAlive()
                    }
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
                let failure = await Self.mediaFailure(from: runtime)
                guard let failure else { continue }
                await self?.recoverFromMediaFailure(
                    failure,
                    generation: operationGeneration
                )
                return
            }
        }
    }

    func setStatsMode(_ mode: StreamStatsMode) {
        guard statsMode != mode else { return }
        statsMode = mode
        if mode == .off {
            stopStatisticsMonitor()
            return
        }
        guard state == .streaming,
              let operation = activeOperation,
              let runtime = operation.runtime
        else {
            return
        }
        startStatisticsMonitor(
            runtime: runtime,
            generation: operation.generation
        )
    }

    func setInputPaused(_ isPaused: Bool) {
        activeOperation?.runtime?.setInputPaused(isPaused)
    }

    func sendKeyboardEvent(isPressed: Bool, virtualKey: UInt8) {
        guard state == .streaming else { return }
        activeOperation?.runtime?.sendKeyboardEvent(
            isPressed: isPressed,
            virtualKey: virtualKey
        )
    }

    func sendMouseReport(_ report: XboxMouseReport) {
        guard state == .streaming else { return }
        activeOperation?.runtime?.sendMouseReport(report)
    }

    /// Sends bounded ASCII-compatible text over the negotiated keyboard
    /// channel. Product UI does not expose this for composed Unicode input.
    @discardableResult
    func sendTextEntry(_ text: String) -> Bool {
        guard state == .streaming,
              let runtime = activeOperation?.runtime
        else {
            return false
        }
        return runtime.sendTextEntry(text)
    }

    private func handleMenuPress(generation operationGeneration: UInt64) {
        guard generation == operationGeneration,
              state == .streaming
        else {
            return
        }
        menuPressCount &+= 1
    }

    func recordDecodedVideoFormat(_ format: DecodedVideoFormat) {
        colorState.detectedMode = format.mode
        activeOperation?.runtime?.recordDecodedVideoFrame()
    }

    private func startStatisticsMonitor(
        runtime: any XboxCloudStreamRuntime,
        generation operationGeneration: UInt64
    ) {
        statisticsTask?.cancel()
        statisticsGeneration &+= 1
        let monitorGeneration = statisticsGeneration
        statisticsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self?.isCollectingStatistics(
                    operationGeneration,
                    monitorGeneration: monitorGeneration
                ) == true else {
                    return
                }
                let snapshot = await runtime.sampleStatistics()
                guard self?.isCollectingStatistics(
                    operationGeneration,
                    monitorGeneration: monitorGeneration
                ) == true else {
                    return
                }
                self?.applyStatistics(snapshot)
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func stopStatisticsMonitor() {
        statisticsGeneration &+= 1
        statisticsTask?.cancel()
        statisticsTask = nil
    }

    private func isCollectingStatistics(
        _ operationGeneration: UInt64,
        monitorGeneration: UInt64
    ) -> Bool {
        statisticsGeneration == monitorGeneration
            && isActive(operationGeneration)
            && shouldCollectStatistics
    }

    private var shouldCollectStatistics: Bool {
        statsMode != .off
    }

    private func applyStatistics(_ snapshot: XboxCloudRTCStatsSnapshot) {
        var nextStats = snapshot.stream
        nextStats.serverZone = serverLocation
        if nextStats != stats {
            stats = nextStats
        }
        if snapshot.audio != audioStats {
            audioStats = snapshot.audio
        }
    }

    private func resetStatistics(settings: XboxCloudStreamSettings) {
        stopStatisticsMonitor()
        stats = StreamStats()
        audioStats = AudioStats()
        statsMode = settings.statsMode
        diagnosticsEnabled = false
        rtcEventLogActive = false
        streamingStartedAt = nil
        serverLocation = ""
        colorState = StreamColorState(
            preference: .automatic,
            requestedMode: .sdr8,
            negotiatedMode: nil,
            detectedMode: nil,
            displayHDRSupport: .unknown,
            fallbackReason: nil
        )
    }

    private func recoverFromMediaFailure(
        _ originalFailure: XboxCloudStreamControllerError,
        generation operationGeneration: UInt64
    ) async {
        guard generation == operationGeneration,
              let operation = activeOperation,
              let preparedStream = operation.preparedStream,
              let runtime = operation.runtime
        else {
            return
        }

        stopStatisticsMonitor()
        videoTrack = nil
        microphoneEnabledForConnection = false
        diagnosticsEnabled = false
        rtcEventLogActive = false
        runtime.disconnect()
        runtime.setMenuToggleHandler { [weak self] in
            self?.handleMenuPress(generation: operationGeneration)
        }

        let reconnectStartedAt = now()
        let reconnectWindow = policy.reconnectWindow
        let deadlineSleep = reconnectDeadlineSleep
        let result: XboxCloudReconnectRecoveryResult = await withTaskGroup(
            of: XboxCloudReconnectRecoveryResult.self
        ) { group -> XboxCloudReconnectRecoveryResult in
            group.addTask { [weak self] in
                guard let self else { return .cancelled }
                return await performReconnectAttempts(
                    originalFailure: originalFailure,
                    preparedStream: preparedStream,
                    runtime: runtime,
                    generation: operationGeneration,
                    startedAt: reconnectStartedAt
                )
            }
            group.addTask { @concurrent in
                do {
                    try await deadlineSleep(reconnectWindow)
                    try Task.checkCancellation()
                    return .timedOut
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .timedOut
                }
            }

            while let next = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return .cancelled
                }
                switch next {
                case .cancelled:
                    continue
                case .timedOut:
                    group.cancelAll()
                    runtime.disconnect()
                    return .timedOut
                case .recovered, .failed:
                    group.cancelAll()
                    return next
                }
            }
            return .cancelled
        }

        switch result {
        case .recovered, .cancelled:
            return
        case let .failed(failure):
            await backgroundFailure(
                failure,
                generation: operationGeneration
            )
        case .timedOut:
            await backgroundFailure(
                originalFailure,
                generation: operationGeneration
            )
        }
    }

    private func performReconnectAttempts(
        originalFailure: XboxCloudStreamControllerError,
        preparedStream: XboxCloudPreparedStream,
        runtime: any XboxCloudStreamRuntime,
        generation operationGeneration: UInt64,
        startedAt reconnectStartedAt: Date
    ) async -> XboxCloudReconnectRecoveryResult {
        var terminalFailure = originalFailure
        for attempt in 1 ... policy.maximumReconnectAttempts {
            guard !Task.isCancelled else { return .cancelled }
            let delay = policy.reconnectDelay(beforeAttempt: attempt)
            let elapsed = max(0, now().timeIntervalSince(reconnectStartedAt))
            guard elapsed + delay < policy.reconnectWindow else { break }
            state = .reconnecting(
                attempt: attempt,
                maximumAttempts: policy.maximumReconnectAttempts,
                nextDelay: delay > 0 ? delay : nil
            )

            do {
                if delay > 0 {
                    try await reconnectSleep(delay)
                }
                try ensureCurrent(operationGeneration)
                guard now().timeIntervalSince(reconnectStartedAt)
                    < policy.reconnectWindow
                else {
                    break
                }
                try await runtime.connect(
                    configuration: preparedStream.configuration,
                    signalingContext: preparedStream.signalingContext
                )
                try ensureCurrent(operationGeneration)
                guard now().timeIntervalSince(reconnectStartedAt)
                    < policy.reconnectWindow,
                    let track = runtime.videoTrack
                else {
                    throw XboxCloudStreamControllerError.missingVideoTrack
                }

                videoTrack = track
                microphoneEnabledForConnection = runtime.microphoneEnabled
                updateDiagnostics(from: runtime)
                state = .streaming
                startMediaMonitor(
                    runtime: runtime,
                    generation: operationGeneration
                )
                if shouldCollectStatistics {
                    startStatisticsMonitor(
                        runtime: runtime,
                        generation: operationGeneration
                    )
                }
                return .recovered
            } catch is CancellationError {
                return .cancelled
            } catch {
                runtime.disconnect()
                let safeError = Self.sanitizedControllerError(error)
                terminalFailure = .mediaDisconnected(
                    message: safeError.localizedDescription
                )
            }
        }
        return .failed(terminalFailure)
    }

    private func restoreResumableState(
        _ operation: ActiveOperation,
        failure: XboxCloudStreamControllerError?
    ) {
        operation.runtime?.setMenuToggleHandler(nil)
        operation.runtime?.disconnect()
        activeOperation = operation
        videoTrack = nil
        microphoneEnabledForConnection = false
        diagnosticsEnabled = false
        rtcEventLogActive = false
        streamingStartedAt = nil
        resumableSessionExpiresAt = operation.serviceExpiresAt
        if let failure {
            state = .failed(message: failure.localizedDescription)
        } else {
            state = .idle
        }
        startResumeExpiryMonitor(
            expiresAt: operation.serviceExpiresAt,
            generation: operation.generation
        )
    }

    private func startResumeExpiryMonitor(
        expiresAt: Date,
        generation operationGeneration: UInt64
    ) {
        resumeExpiryTask?.cancel()
        let sleep = monitorSleep
        resumeExpiryTask = Task { @concurrent [weak self] in
            while !Task.isCancelled {
                guard let remaining = await self?.remainingResumeLifetime(
                    expiresAt: expiresAt,
                    generation: operationGeneration
                ) else {
                    return
                }
                if remaining <= 0 {
                    await self?.expireResumableSession(
                        generation: operationGeneration
                    )
                    return
                }
                do {
                    try await sleep(min(remaining, 60))
                    try Task.checkCancellation()
                } catch {
                    return
                }
            }
        }
    }

    private func remainingResumeLifetime(
        expiresAt: Date,
        generation operationGeneration: UInt64
    ) -> TimeInterval? {
        guard generation == operationGeneration,
              activeOperation?.generation == operationGeneration,
              resumableSessionExpiresAt == expiresAt,
              state != .streaming
        else {
            return nil
        }
        return expiresAt.timeIntervalSince(now())
    }

    private func expireResumableSession(
        generation operationGeneration: UInt64
    ) async {
        guard generation == operationGeneration,
              activeOperation?.generation == operationGeneration,
              state != .streaming
        else {
            return
        }
        generation &+= 1
        let expiryGeneration = generation
        let operation = detachActiveResources()
        if let operation {
            _ = await deleteAndRetainIfNeeded(operation)
        }
        guard generation == expiryGeneration else { return }
        state = .idle
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
            _ = await deleteAndRetainIfNeeded(operation)
        }
        guard generation == failureGeneration else { return }
        state = .failed(message: error.localizedDescription)
    }

    private func detachActiveResources() -> ActiveOperation? {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        mediaMonitorTask?.cancel()
        mediaMonitorTask = nil
        resumeExpiryTask?.cancel()
        resumeExpiryTask = nil
        stopStatisticsMonitor()
        activeOperation?.runtime?.setMenuToggleHandler(nil)
        activeOperation?.runtime?.disconnect()
        let operation = activeOperation
        activeOperation = nil
        videoTrack = nil
        microphoneEnabledForConnection = false
        diagnosticsEnabled = false
        rtcEventLogActive = false
        activeGameID = nil
        coordinatorServerSessionID = nil
        streamingStartedAt = nil
        resumableSessionExpiresAt = nil
        return operation
    }

    private func updateDiagnostics(from runtime: any XboxCloudStreamRuntime) {
        diagnosticsEnabled = runtime.diagnosticsEnabled
        rtcEventLogActive = runtime.rtcEventLogActive
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

    private func isOwned(_ operationGeneration: UInt64) -> Bool {
        generation == operationGeneration
            && activeOperation?.generation == operationGeneration
    }

    private func shouldPulseInput(_ operationGeneration: UInt64) -> Bool {
        isOwned(operationGeneration) && state == .streaming
    }

    private static func mediaFailure(
        from runtime: any XboxCloudStreamRuntime
    ) -> XboxCloudStreamControllerError? {
        guard runtime.videoTrack != nil else {
            return .missingVideoTrack
        }
        guard runtime.isMediaReady else {
            return .mediaDisconnected(
                message: "Xbox Cloud audio or video stopped."
            )
        }
        return switch runtime.connectionState {
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

    private func retainForDeletion(_ operation: ActiveOperation) {
        retainForDeletion(
            lifecycle: operation.lifecycle,
            token: operation.token
        )
    }

    private func retainForDeletion(
        lifecycle: any XboxCloudSessionLifecycleServing,
        token: XboxCloudStreamSessionToken
    ) {
        pendingSessionDeletions[token] = SessionDeletion(
            lifecycle: lifecycle,
            token: token
        )
    }

    private func deleteAndRetainIfNeeded(
        _ operation: ActiveOperation
    ) async -> Bool {
        await deleteAndRetainIfNeeded(
            lifecycle: operation.lifecycle,
            token: operation.token
        )
    }

    private func deleteAndRetainIfNeeded(
        lifecycle: any XboxCloudSessionLifecycleServing,
        token: XboxCloudStreamSessionToken
    ) async -> Bool {
        retainForDeletion(lifecycle: lifecycle, token: token)
        return await confirmSessionDeletion(for: token)
    }

    private func confirmPendingSessionDeletions() async -> Bool {
        let tokens = Array(pendingSessionDeletions.keys)
        for token in tokens {
            _ = await confirmSessionDeletion(for: token)
        }
        return pendingSessionDeletions.isEmpty
    }

    /// DELETE runs in a fresh task because launch cancellation must not cancel
    /// the service cleanup. Concurrent End calls share the same attempt.
    private func confirmSessionDeletion(
        for token: XboxCloudStreamSessionToken
    ) async -> Bool {
        guard let deletion = pendingSessionDeletions[token] else { return true }

        let operation: SessionDeletionOperation
        if let current = sessionDeletionOperations[token] {
            operation = current
        } else {
            let lifecycle = deletion.lifecycle
            let task = Task { @concurrent in
                await lifecycle.delete(token)
            }
            operation = SessionDeletionOperation(id: UUID(), task: task)
            sessionDeletionOperations[token] = operation
        }

        let confirmed = await operation.task.value
        if sessionDeletionOperations[token]?.id == operation.id {
            sessionDeletionOperations.removeValue(forKey: token)
        }
        if confirmed {
            pendingSessionDeletions.removeValue(forKey: token)
        }
        return confirmed
    }

    private nonisolated static func deleteAfterOwnerDeinitializes(
        lifecycle: any XboxCloudSessionLifecycleServing,
        token: XboxCloudStreamSessionToken
    ) {
        Task { @concurrent in
            _ = await lifecycle.delete(token)
        }
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
    case noResumableSession
    case resumableSessionExpired
    case sessionDeletionUnconfirmed
    case launchFailed(message: String)
    case keepAliveFailed
    case mediaDisconnected(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidPolicy:
            "Xbox Cloud stream policy is invalid."
        case .missingVideoTrack:
            "Xbox Cloud connected without a video stream."
        case .noResumableSession:
            "There is no Xbox Cloud session available to continue."
        case .resumableSessionExpired:
            "The Xbox Cloud session is no longer available to continue."
        case .sessionDeletionUnconfirmed:
            "Xbox Cloud could not confirm that the previous session ended."
        case let .launchFailed(message):
            message
        case .keepAliveFailed:
            "Xbox Cloud stopped responding to session keepalive requests."
        case let .mediaDisconnected(message):
            message
        }
    }
}
