import Foundation

/// Narrow CloudMatch boundary used by the session lifecycle coordinator.
///
/// The production actor conforms directly. Tests provide deterministic actors
/// that never open a network connection.
nonisolated protocol SessionOrchestrationClient: Sendable {
    func createSession(_ input: SessionCreateRequest) async throws -> SessionInfo

    func pollSession(
        sessionId: String,
        token: String,
        base: String,
        serverIp: String?,
        routingZoneUrl: String?,
        clientId: String,
        deviceId: String
    ) async throws -> SessionInfo

    func stopSession(
        sessionId: String,
        token: String,
        base: String,
        serverIp: String?,
        clientId: String?,
        deviceId: String?
    ) async throws
}

extension CloudMatchClient: SessionOrchestrationClient {}

/// Monotonic time and cancellable waiting used by queue polling.
nonisolated struct SessionOrchestrationScheduler: Sendable {
    let now: @Sendable () async -> TimeInterval
    let sleep: @Sendable (_ seconds: TimeInterval) async throws -> Void

    static let continuous = Self(
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    )
}

nonisolated struct SessionAttemptToken: Equatable, Sendable {
    let generation: UInt64
}

nonisolated struct SessionConnectionToken: Equatable, Sendable {
    let attemptGeneration: UInt64
    let connectionGeneration: UInt64
}

nonisolated enum SessionReconnectDecision: Equatable, Sendable {
    case reconnect
    case endSession
}

nonisolated struct SessionReconnectPolicy: Sendable {
    let maximumAttempts: Int

    init(maximumAttempts: Int = 3) {
        self.maximumAttempts = max(0, maximumAttempts)
    }

    func decision(attempt: Int, intentionalDisconnect: Bool) -> SessionReconnectDecision {
        guard !intentionalDisconnect,
              attempt > 0,
              attempt <= maximumAttempts
        else {
            return .endSession
        }
        return .reconnect
    }
}

nonisolated enum SessionOrchestrationError: Error, Equatable {
    case setupTimedOut
}

/// Coordinates the testable portion of CloudMatch session lifecycle work.
///
/// UI state remains owned by `StreamView`; the coordinator only serializes
/// attempts and emits accepted snapshots on the main actor.
@MainActor
final class SessionOrchestrator {
    typealias UpdateHandler = @MainActor (
        _ session: SessionInfo,
        _ readiness: SessionReadinessState?
    ) -> Void

    private struct ActiveOperation {
        let attempt: SessionAttemptToken
        let sessionId: String?
        let task: Task<SessionInfo, Error>
    }

    private struct OwnedSession {
        let info: SessionInfo
        let token: String
    }

    private let client: any SessionOrchestrationClient
    private let scheduler: SessionOrchestrationScheduler
    private let pollInterval: TimeInterval
    private let reconnectPolicy: SessionReconnectPolicy

    private var attemptGeneration: UInt64 = 0
    private var connectionGeneration: UInt64 = 0
    private var attemptsEnabled = false
    private var activeCreation: ActiveOperation?
    private var activePolling: ActiveOperation?
    private var ownedSession: OwnedSession?
    private var stopTasks: [String: Task<Bool, Never>] = [:]
    private var stoppedSessionIds: Set<String> = []

    init(
        client: any SessionOrchestrationClient,
        scheduler: SessionOrchestrationScheduler = .continuous,
        pollInterval: TimeInterval = 2,
        reconnectPolicy: SessionReconnectPolicy = .init()
    ) {
        self.client = client
        self.scheduler = scheduler
        self.pollInterval = max(0, pollInterval)
        self.reconnectPolicy = reconnectPolicy
    }

    /// Starts a new generation and invalidates all callbacks from older work.
    @discardableResult
    func beginAttempt() -> SessionAttemptToken {
        invalidateAttempt(enablingNextAttempt: true)
        return SessionAttemptToken(generation: attemptGeneration)
    }

    /// Cancels lifecycle work without stopping an already-created server session.
    ///
    /// `teardown()` performs both cancellation and a best-effort server stop.
    func cancelAttempt() {
        invalidateAttempt(enablingNextAttempt: false)
    }

    func acceptsAttempt(
        _ attempt: SessionAttemptToken,
        taskIsCancelled: Bool = false
    ) -> Bool {
        attemptsEnabled
            && !taskIsCancelled
            && attempt.generation == attemptGeneration
    }

    /// Coalesces concurrent creation calls for the same generation.
    func createSession(
        _ request: SessionCreateRequest,
        attempt: SessionAttemptToken,
        onUpdate: UpdateHandler? = nil
    ) async throws -> SessionInfo {
        try requireAccepted(attempt)

        if let activeCreation,
           activeCreation.attempt == attempt
        {
            return try await value(
                of: activeCreation.task,
                attempt: attempt
            )
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            let session: SessionInfo
            do {
                session = try await client.createSession(request)
            } catch {
                guard acceptsAttempt(attempt, taskIsCancelled: Task.isCancelled) else {
                    throw CancellationError()
                }
                throw error
            }

            guard acceptsAttempt(attempt, taskIsCancelled: Task.isCancelled) else {
                await stopOnce(session: session, token: request.token)
                throw CancellationError()
            }

            adopt(session, token: request.token)
            onUpdate?(session, nil)
            return session
        }
        activeCreation = ActiveOperation(
            attempt: attempt,
            sessionId: nil,
            task: task
        )

        do {
            let session = try await value(of: task, attempt: attempt)
            clearCreation(ifMatching: attempt)
            return session
        } catch {
            clearCreation(ifMatching: attempt)
            throw error
        }
    }

    /// Polls indefinitely while queued, then applies a bounded post-queue setup timeout.
    ///
    /// Consecutive ready responses are intentionally counted by the pure readiness
    /// reducer so a transient ready response cannot start WebRTC prematurely.
    func waitUntilReady(
        initialSession: SessionInfo,
        token: String,
        attempt: SessionAttemptToken,
        requiredReadyResponses: Int = 2,
        setupTimeout: TimeInterval = 180,
        onUpdate: UpdateHandler? = nil
    ) async throws -> SessionInfo {
        try requireAccepted(attempt)

        if let activePolling,
           activePolling.attempt == attempt,
           activePolling.sessionId == initialSession.sessionId
        {
            return try await value(
                of: activePolling.task,
                attempt: attempt
            )
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            var session = initialSession
            var readiness = SessionReadinessTracker(
                requiredReadyResponses: requiredReadyResponses,
                setupTimeout: setupTimeout
            )

            while true {
                try requireAccepted(
                    attempt,
                    taskIsCancelled: Task.isCancelled
                )
                adopt(session, token: token)

                let state = await readiness.observe(
                    status: session.status,
                    isInQueue: session.isInQueue,
                    queuePosition: session.queuePosition,
                    now: Date(timeIntervalSinceReferenceDate: scheduler.now())
                )
                onUpdate?(session, state)

                switch state {
                case .ready:
                    return session
                case .timedOut:
                    throw SessionOrchestrationError.setupTimedOut
                case .inQueue, .preparing:
                    break
                }

                try await scheduler.sleep(pollInterval)
                try requireAccepted(
                    attempt,
                    taskIsCancelled: Task.isCancelled
                )

                let polled: SessionInfo
                do {
                    polled = try await client.pollSession(
                        sessionId: session.sessionId,
                        token: token,
                        base: session.streamingBaseUrl,
                        serverIp: session.serverIp.isEmpty ? nil : session.serverIp,
                        routingZoneUrl: session.zone,
                        clientId: session.clientId,
                        deviceId: session.deviceId
                    )
                } catch {
                    guard acceptsAttempt(attempt, taskIsCancelled: Task.isCancelled) else {
                        throw CancellationError()
                    }
                    throw error
                }
                try requireAccepted(
                    attempt,
                    taskIsCancelled: Task.isCancelled
                )
                session = polled
            }
        }
        activePolling = ActiveOperation(
            attempt: attempt,
            sessionId: initialSession.sessionId,
            task: task
        )

        do {
            let session = try await value(of: task, attempt: attempt)
            clearPolling(ifMatching: attempt)
            return session
        } catch {
            clearPolling(ifMatching: attempt)
            throw error
        }
    }

    /// Registers a session created or reclaimed outside the coordinator.
    func adopt(_ session: SessionInfo, token: String) {
        stoppedSessionIds.remove(session.sessionId)
        ownedSession = OwnedSession(info: session, token: token)
    }

    /// Relinquishes ownership when the user intentionally leaves a resumable session running.
    func detachOwnedSession() {
        ownedSession = nil
    }

    /// Stops the current owned session without invalidating the active generation.
    func stopOwnedSession() async {
        guard let ownedSession else { return }
        self.ownedSession = nil
        await stopOnce(
            session: ownedSession.info,
            token: ownedSession.token
        )
    }

    /// Cancels all work and stops the owned session at most once.
    func teardown() async {
        cancelAttempt()
        await stopOwnedSession()
    }

    /// Advances connection identity so callbacks from losing or replaced connections are stale.
    func beginConnection(
        for attempt: SessionAttemptToken
    ) -> SessionConnectionToken? {
        guard acceptsAttempt(attempt) else { return nil }
        connectionGeneration &+= 1
        return SessionConnectionToken(
            attemptGeneration: attempt.generation,
            connectionGeneration: connectionGeneration
        )
    }

    func acceptsConnectionCallback(
        _ connection: SessionConnectionToken,
        taskIsCancelled: Bool = false
    ) -> Bool {
        acceptsAttempt(
            SessionAttemptToken(generation: connection.attemptGeneration),
            taskIsCancelled: taskIsCancelled
        ) && connection.connectionGeneration == connectionGeneration
    }

    func reconnectDecision(
        for connection: SessionConnectionToken,
        attempt: Int,
        intentionalDisconnect: Bool
    ) -> SessionReconnectDecision {
        guard acceptsConnectionCallback(connection) else { return .endSession }
        return reconnectPolicy.decision(
            attempt: attempt,
            intentionalDisconnect: intentionalDisconnect
        )
    }

    private func invalidateAttempt(enablingNextAttempt: Bool) {
        activeCreation?.task.cancel()
        activePolling?.task.cancel()
        activeCreation = nil
        activePolling = nil
        attemptGeneration &+= 1
        connectionGeneration &+= 1
        attemptsEnabled = enablingNextAttempt
    }

    private func requireAccepted(
        _ attempt: SessionAttemptToken,
        taskIsCancelled: Bool = false
    ) throws {
        guard acceptsAttempt(
            attempt,
            taskIsCancelled: taskIsCancelled
        ) else {
            throw CancellationError()
        }
    }

    private func value(
        of task: Task<SessionInfo, Error>,
        attempt: SessionAttemptToken
    ) async throws -> SessionInfo {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self,
                      attempt.generation == attemptGeneration
                else {
                    return
                }
                cancelAttempt()
            }
        }
    }

    private func clearCreation(ifMatching attempt: SessionAttemptToken) {
        guard activeCreation?.attempt == attempt else { return }
        activeCreation = nil
    }

    private func clearPolling(ifMatching attempt: SessionAttemptToken) {
        guard activePolling?.attempt == attempt else { return }
        activePolling = nil
    }

    private func stopOnce(session: SessionInfo, token: String) async {
        let sessionId = session.sessionId
        guard !stoppedSessionIds.contains(sessionId) else { return }

        if let task = stopTasks[sessionId] {
            _ = await task.value
            return
        }

        let client = client
        let task = Task {
            do {
                try await client.stopSession(
                    sessionId: session.sessionId,
                    token: token,
                    base: session.streamingBaseUrl,
                    serverIp: session.serverIp.isEmpty ? nil : session.serverIp,
                    clientId: session.clientId,
                    deviceId: session.deviceId
                )
                return true
            } catch {
                return false
            }
        }
        stopTasks[sessionId] = task
        let stopped = await task.value
        stopTasks[sessionId] = nil
        if stopped {
            stoppedSessionIds.insert(sessionId)
        }
    }
}
