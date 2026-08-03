@testable import CloudNow
import Foundation
import Testing

@Suite("Session orchestration")
struct SessionOrchestratorTests {
    @MainActor
    @Test("Concurrent creation callers share one CloudMatch request")
    func creationIsSingleFlight() async throws {
        let client = ControlledSessionClient()
        let orchestrator = SessionOrchestrator(client: client)
        let attempt = orchestrator.beginAttempt()
        let request = makeRequest()
        var updates: [String] = []

        let first = Task { @MainActor in
            try await orchestrator.createSession(
                request,
                attempt: attempt
            ) { session, _ in
                updates.append(session.sessionId)
            }
        }
        await client.waitForCreateCount(1)

        let second = Task { @MainActor in
            try await orchestrator.createSession(
                request,
                attempt: attempt
            )
        }
        await Task.yield()

        try await client.resolveCreate(
            call: 1,
            with: makeSession(id: "shared", status: 1)
        )
        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(firstResult.sessionId == "shared")
        #expect(secondResult.sessionId == "shared")
        #expect(await client.createCount == 1)
        #expect(updates == ["shared"])
    }

    @MainActor
    @Test("Retry rejects a late creation and cleans up its server session")
    func retryCleansUpLateCreation() async throws {
        let client = ControlledSessionClient()
        let orchestrator = SessionOrchestrator(client: client)
        let request = makeRequest()
        let firstAttempt = orchestrator.beginAttempt()
        var published: [String] = []

        let staleTask = Task { @MainActor in
            try await orchestrator.createSession(
                request,
                attempt: firstAttempt
            ) { session, _ in
                published.append(session.sessionId)
            }
        }
        await client.waitForCreateCount(1)

        let retryAttempt = orchestrator.beginAttempt()
        let retryTask = Task { @MainActor in
            try await orchestrator.createSession(
                request,
                attempt: retryAttempt
            ) { session, _ in
                published.append(session.sessionId)
            }
        }
        await client.waitForCreateCount(2)

        try await client.resolveCreate(
            call: 2,
            with: makeSession(id: "current", status: 1)
        )
        #expect(try await retryTask.value.sessionId == "current")

        try await client.resolveCreate(
            call: 1,
            with: makeSession(id: "stale", status: 1)
        )
        await #expect(throws: CancellationError.self) {
            try await staleTask.value
        }

        #expect(published == ["current"])
        #expect(await client.stoppedSessionIds == ["stale"])
    }

    @MainActor
    @Test("Queue duration is unbounded and readiness must be consecutive")
    func queueAndReadinessRules() async throws {
        let initial = makeSession(
            id: "queued",
            status: 1,
            queuePosition: 100,
            seatSetupStep: 1
        )
        let client = ScriptedSessionClient(polls: [
            makeSession(
                id: "queued",
                status: 1,
                queuePosition: 50,
                seatSetupStep: 1
            ),
            makeSession(id: "queued", status: 1, seatSetupStep: 2),
            makeSession(id: "queued", status: 2, seatSetupStep: 2),
            makeSession(id: "queued", status: 1, seatSetupStep: 2),
            makeSession(id: "queued", status: 2, seatSetupStep: 2),
            makeSession(id: "queued", status: 3, seatSetupStep: 2),
        ])
        let clock = ManualSessionScheduler(advances: [
            1000,
            1000,
            5,
            5,
            5,
            5,
        ])
        let orchestrator = SessionOrchestrator(
            client: client,
            scheduler: clock.scheduler,
            pollInterval: 1
        )
        let attempt = orchestrator.beginAttempt()
        var phases: [SessionReadinessState] = []

        let ready = try await orchestrator.waitUntilReady(
            initialSession: initial,
            token: "token",
            attempt: attempt
        ) { _, readiness in
            if let readiness {
                phases.append(readiness)
            }
        }

        #expect(ready.status == 3)
        #expect(phases == [
            .inQueue(position: 100),
            .inQueue(position: 50),
            .preparing,
            .preparing,
            .preparing,
            .preparing,
            .ready,
        ])
        #expect(await client.pollCount == 6)
        #expect(await clock.currentTime == 2020)
    }

    @MainActor
    @Test("Setup timeout begins only after the queue clears")
    func setupTimeoutStartsAfterQueue() async {
        let initial = makeSession(
            id: "timeout",
            status: 1,
            queuePosition: 10,
            seatSetupStep: 1
        )
        let client = ScriptedSessionClient(polls: [
            makeSession(id: "timeout", status: 1, seatSetupStep: 2),
            makeSession(id: "timeout", status: 1, seatSetupStep: 2),
        ])
        let clock = ManualSessionScheduler(advances: [500, 181])
        let orchestrator = SessionOrchestrator(
            client: client,
            scheduler: clock.scheduler,
            pollInterval: 1
        )
        let attempt = orchestrator.beginAttempt()
        var phases: [SessionReadinessState] = []

        await #expect(throws: SessionOrchestrationError.setupTimedOut) {
            try await orchestrator.waitUntilReady(
                initialSession: initial,
                token: "token",
                attempt: attempt,
                setupTimeout: 180
            ) { _, readiness in
                if let readiness {
                    phases.append(readiness)
                }
            }
        }

        #expect(phases == [
            .inQueue(position: 10),
            .preparing,
            .timedOut,
        ])
        #expect(await clock.currentTime == 681)
    }

    @MainActor
    @Test("Cancellation rejects a poll response that arrives late")
    func cancellationBlocksLatePollMutation() async {
        let client = ControlledSessionClient()
        let clock = ManualSessionScheduler()
        let orchestrator = SessionOrchestrator(
            client: client,
            scheduler: clock.scheduler,
            pollInterval: 0
        )
        let attempt = orchestrator.beginAttempt()
        let initial = makeSession(
            id: "cancelled",
            status: 1,
            seatSetupStep: 2
        )
        var phases: [SessionReadinessState] = []

        let polling = Task { @MainActor in
            try await orchestrator.waitUntilReady(
                initialSession: initial,
                token: "token",
                attempt: attempt
            ) { _, readiness in
                if let readiness {
                    phases.append(readiness)
                }
            }
        }
        await client.waitForPollCount(1)
        orchestrator.cancelAttempt()
        try? await client.resolvePoll(
            call: 1,
            with: makeSession(id: "cancelled", status: 2, seatSetupStep: 2)
        )

        await #expect(throws: CancellationError.self) {
            try await polling.value
        }
        #expect(phases == [.preparing])
    }

    @MainActor
    @Test("Teardown is idempotent")
    func teardownStopsOnce() async {
        let client = ScriptedSessionClient()
        let orchestrator = SessionOrchestrator(client: client)
        _ = orchestrator.beginAttempt()
        orchestrator.adopt(
            makeSession(id: "owned", status: 2),
            token: "token"
        )

        await orchestrator.teardown()
        await orchestrator.teardown()

        #expect(await client.stoppedSessionIds == ["owned"])
    }

    @MainActor
    @Test("New connection identity rejects callbacks from replaced connections")
    func connectionGenerationRejectsStaleCallbacks() throws {
        let orchestrator = SessionOrchestrator(
            client: ScriptedSessionClient()
        )
        let attempt = orchestrator.beginAttempt()
        let first = try #require(orchestrator.beginConnection(for: attempt))
        let second = try #require(orchestrator.beginConnection(for: attempt))

        #expect(!orchestrator.acceptsConnectionCallback(first))
        #expect(orchestrator.acceptsConnectionCallback(second))
        #expect(orchestrator.reconnectDecision(
            for: second,
            attempt: 1,
            intentionalDisconnect: false
        ) == .reconnect)

        orchestrator.cancelAttempt()

        #expect(!orchestrator.acceptsConnectionCallback(second))
        #expect(orchestrator.reconnectDecision(
            for: second,
            attempt: 1,
            intentionalDisconnect: false
        ) == .endSession)
    }

    @Test(
        "Reconnect policy bounds attempts and rejects intentional disconnects",
        arguments: [
            (attempt: 1, intentional: false, expected: SessionReconnectDecision.reconnect),
            (attempt: 3, intentional: false, expected: .reconnect),
            (attempt: 0, intentional: false, expected: .endSession),
            (attempt: 4, intentional: false, expected: .endSession),
            (attempt: 1, intentional: true, expected: .endSession),
        ]
    )
    func reconnectPolicy(
        attempt: Int,
        intentional: Bool,
        expected: SessionReconnectDecision
    ) {
        let policy = SessionReconnectPolicy(maximumAttempts: 3)

        #expect(policy.decision(
            attempt: attempt,
            intentionalDisconnect: intentional
        ) == expected)
    }
}

private actor ControlledSessionClient: SessionOrchestrationClient {
    private var createCalls = 0
    private var pollCalls = 0
    private var createContinuations: [Int: CheckedContinuation<SessionInfo, Error>] = [:]
    private var pollContinuations: [Int: CheckedContinuation<SessionInfo, Error>] = [:]
    private var createWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var pollWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var stoppedSessionIds: [String] = []

    var createCount: Int {
        createCalls
    }

    func createSession(_: SessionCreateRequest) async throws -> SessionInfo {
        createCalls += 1
        notifyCreateWaiters()
        let call = createCalls
        return try await withCheckedThrowingContinuation { continuation in
            createContinuations[call] = continuation
        }
    }

    func pollSession(
        sessionId _: String,
        token _: String,
        base _: String,
        serverIp _: String?,
        routingZoneUrl _: String?,
        clientId _: String,
        deviceId _: String
    ) async throws -> SessionInfo {
        pollCalls += 1
        notifyPollWaiters()
        let call = pollCalls
        return try await withCheckedThrowingContinuation { continuation in
            pollContinuations[call] = continuation
        }
    }

    func stopSession(
        sessionId: String,
        token _: String,
        base _: String,
        serverIp _: String?,
        clientId _: String?,
        deviceId _: String?
    ) {
        stoppedSessionIds.append(sessionId)
    }

    func waitForCreateCount(_ expected: Int) async {
        guard createCalls < expected else { return }
        await withCheckedContinuation { continuation in
            createWaiters.append((expected, continuation))
        }
    }

    func waitForPollCount(_ expected: Int) async {
        guard pollCalls < expected else { return }
        await withCheckedContinuation { continuation in
            pollWaiters.append((expected, continuation))
        }
    }

    func resolveCreate(call: Int, with session: SessionInfo) throws {
        guard let continuation = createContinuations.removeValue(forKey: call) else {
            throw SessionOrchestratorTestError.missingContinuation
        }
        continuation.resume(returning: session)
    }

    func resolvePoll(call: Int, with session: SessionInfo) throws {
        guard let continuation = pollContinuations.removeValue(forKey: call) else {
            throw SessionOrchestratorTestError.missingContinuation
        }
        continuation.resume(returning: session)
    }

    private func notifyCreateWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in createWaiters {
            if createCalls >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        createWaiters = remaining
    }

    private func notifyPollWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in pollWaiters {
            if pollCalls >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        pollWaiters = remaining
    }
}

private actor ScriptedSessionClient: SessionOrchestrationClient {
    private var creates: [SessionInfo]
    private var polls: [SessionInfo]
    private(set) var pollCount = 0
    private(set) var stoppedSessionIds: [String] = []

    init(
        creates: [SessionInfo] = [],
        polls: [SessionInfo] = []
    ) {
        self.creates = creates
        self.polls = polls
    }

    func createSession(_: SessionCreateRequest) throws -> SessionInfo {
        guard !creates.isEmpty else {
            throw SessionOrchestratorTestError.missingScriptedResponse
        }
        return creates.removeFirst()
    }

    func pollSession(
        sessionId _: String,
        token _: String,
        base _: String,
        serverIp _: String?,
        routingZoneUrl _: String?,
        clientId _: String,
        deviceId _: String
    ) throws -> SessionInfo {
        guard !polls.isEmpty else {
            throw SessionOrchestratorTestError.missingScriptedResponse
        }
        pollCount += 1
        return polls.removeFirst()
    }

    func stopSession(
        sessionId: String,
        token _: String,
        base _: String,
        serverIp _: String?,
        clientId _: String?,
        deviceId _: String?
    ) {
        stoppedSessionIds.append(sessionId)
    }
}

private actor ManualSessionScheduler {
    private var time: TimeInterval
    private var advances: [TimeInterval]

    init(
        now: TimeInterval = 0,
        advances: [TimeInterval] = []
    ) {
        time = now
        self.advances = advances
    }

    nonisolated var scheduler: SessionOrchestrationScheduler {
        SessionOrchestrationScheduler(
            now: { await self.currentTime },
            sleep: { requested in
                try Task.checkCancellation()
                await self.advance(by: requested)
            }
        )
    }

    var currentTime: TimeInterval {
        time
    }

    private func advance(by requested: TimeInterval) {
        time += advances.isEmpty ? requested : advances.removeFirst()
    }
}

private enum SessionOrchestratorTestError: Error {
    case missingContinuation
    case missingScriptedResponse
}

private func makeRequest() -> SessionCreateRequest {
    SessionCreateRequest(
        appId: "fixture-app",
        internalTitle: "Fixture Game",
        token: "fixture-token",
        streamingBaseUrl: "https://fixture.invalid",
        routingZoneUrl: nil,
        settings: .init(),
        localVideoCapabilities: LocalVideoCapabilities(
            supportsHardware10BitDecode: false,
            supportsHDRRendering: false,
            supportsExtendedDynamicRange: false,
            displaySupportsHDR: false,
            supportedPixelFormats: [],
            supportedCodecs: [.h264]
        ),
        accountLinked: true,
        accountAllowsHDR: false
    )
}

private func makeSession(
    id: String,
    status: Int,
    queuePosition: Int? = nil,
    seatSetupStep: Int? = nil
) -> SessionInfo {
    SessionInfo(
        sessionId: id,
        status: status,
        zone: "https://zone.fixture.invalid",
        streamingBaseUrl: "https://stream.fixture.invalid",
        serverIp: "192.0.2.10",
        signalingServer: "192.0.2.10:443",
        signalingUrl: "wss://192.0.2.10/nvst/",
        gpuType: "fixture",
        queuePosition: queuePosition,
        seatSetupStep: seatSetupStep,
        seatSetupEtaMs: nil,
        iceServers: [],
        mediaConnectionInfo: nil,
        clientId: "fixture-client",
        deviceId: "fixture-device",
        adState: nil
    )
}
