@testable import CloudNow
import Foundation
import Testing

@Suite("Authentication state")
struct AuthManagerTests {
    @MainActor
    @Test("A valid saved session is restored without refreshing")
    func restoresValidSession() async {
        let saved = makeSession(expiresAt: Date().addingTimeInterval(3600))
        let persistence = FakeAuthPersistence(session: saved)
        let api = FakeAuthAPI()
        let manager = makeManager(api: api, persistence: persistence)

        await manager.initialize()

        #expect(manager.startupPhase == .ready)
        #expect(manager.isAuthenticated)
        #expect(manager.session?.tokens.accessToken == "access")
        #expect(await api.refreshTokenCallCount == 0)
    }

    @MainActor
    @Test("A delayed restore cannot replace a newer login")
    func delayedRestoreCannotReplaceNewLogin() async {
        let persistence = FakeAuthPersistence(
            session: makeSession(expiresAt: Date().addingTimeInterval(3600)),
            blocksFirstLoad: true
        )
        let api = FakeAuthAPI(
            devicePollResponse: makeTokens(
                accessToken: "new-login",
                expiresAt: Date().addingTimeInterval(7200)
            )
        )
        let manager = makeManager(
            api: api,
            persistence: persistence
        )
        let initialization = Task { @MainActor in
            await manager.initialize()
        }
        await persistence.waitForLoadRequest()

        let login = manager.login()
        await login.value
        await persistence.releaseLoad()
        await initialization.value

        #expect(manager.startupPhase == .ready)
        #expect(manager.session?.tokens.accessToken == "new-login")
        #expect(
            await persistence.savedSession?.tokens.accessToken
                == "new-login"
        )
        #expect(await persistence.saveGenerations == [1])
    }

    @MainActor
    @Test("An expired token refreshes and persists the replacement session")
    func refreshesExpiredToken() async {
        let saved = makeSession(expiresAt: Date().addingTimeInterval(-1))
        let refreshed = makeTokens(
            accessToken: "refreshed",
            expiresAt: Date().addingTimeInterval(7200)
        )
        let persistence = FakeAuthPersistence(session: saved)
        let api = FakeAuthAPI(
            refreshTokensResponse: refreshed,
            clientTokenResponse: (
                "replacement-client-token",
                Date().addingTimeInterval(7200)
            )
        )
        let manager = makeManager(api: api, persistence: persistence)

        await manager.initialize()

        #expect(manager.session?.tokens.accessToken == "refreshed")
        #expect(manager.session?.tokens.clientToken == "replacement-client-token")
        #expect(await api.refreshTokenCallCount == 1)
        #expect(await persistence.savedSession?.tokens.accessToken == "refreshed")
    }

    @MainActor
    @Test("Refresh failure clears an expired session")
    func expiredRefreshFailureSignsOut() async {
        let persistence = FakeAuthPersistence(
            session: makeSession(expiresAt: Date().addingTimeInterval(-10))
        )
        let manager = makeManager(
            api: FakeAuthAPI(),
            persistence: persistence
        )

        await manager.initialize()

        #expect(manager.startupPhase == .ready)
        #expect(!manager.isAuthenticated)
        #expect(await persistence.deleteCount == 1)
    }

    @MainActor
    @Test("Refresh failure keeps a token that has not expired")
    func nearExpiryRefreshFailureKeepsSession() async {
        let persistence = FakeAuthPersistence(
            session: makeSession(expiresAt: Date().addingTimeInterval(60))
        )
        let manager = makeManager(
            api: FakeAuthAPI(),
            persistence: persistence
        )

        await manager.initialize()

        #expect(manager.isAuthenticated)
        #expect(manager.session?.tokens.accessToken == "access")
        #expect(await persistence.deleteCount == 0)
    }

    @MainActor
    @Test("Concurrent refresh requests share one token rotation")
    func concurrentRefreshRequestsCoalesce() async throws {
        let persistence = FakeAuthPersistence(
            session: makeSession(expiresAt: Date().addingTimeInterval(-1))
        )
        let api = FakeAuthAPI(
            refreshTokensResponse: makeTokens(
                accessToken: "coalesced",
                expiresAt: Date().addingTimeInterval(7200)
            ),
            blockRefresh: true
        )
        let manager = makeManager(api: api, persistence: persistence)

        let initialization = Task { @MainActor in
            await manager.initialize()
        }
        await api.waitForRefreshRequest()

        let concurrentResolution = Task { @MainActor in
            try await manager.resolveToken()
        }
        await api.releaseRefresh()

        await initialization.value
        let token = try await concurrentResolution.value

        #expect(token == "coalesced")
        #expect(await api.refreshTokenCallCount == 1)
    }

    @MainActor
    @Test("A rejected ID token omitted by refresh is not reused")
    func rejectedIdTokenIsQuarantined() async throws {
        var saved = makeSession(expiresAt: Date().addingTimeInterval(3600))
        saved.tokens.idToken = "rejected-id-token"
        let persistence = FakeAuthPersistence(session: saved)
        let api = FakeAuthAPI(
            refreshTokensResponse: makeTokens(
                accessToken: "replacement-access-token",
                expiresAt: Date().addingTimeInterval(7200)
            )
        )
        let manager = makeManager(api: api, persistence: persistence)
        await manager.initialize()

        let retryToken = try await manager.resolveToken(
            rejecting: "rejected-id-token"
        )
        let subsequentToken = try await manager.resolveToken()

        #expect(retryToken == "replacement-access-token")
        #expect(subsequentToken == "replacement-access-token")
        #expect(manager.session?.tokens.idToken == nil)
        #expect(await persistence.savedSession?.tokens.idToken == nil)
        #expect(await api.refreshTokenCallCount == 1)
    }

    @MainActor
    @Test("Device flow publishes the PIN and cancellation prevents authentication")
    func deviceFlowCancellation() async {
        let persistence = FakeAuthPersistence()
        let api = FakeAuthAPI(blockDevicePoll: true)
        let manager = makeManager(api: api, persistence: persistence)
        await manager.initialize()

        let login = manager.login()
        await api.waitForDevicePollRequest()
        guard case .showingPIN = manager.loginPhase else {
            Issue.record("Expected the device flow to publish its PIN before polling")
            manager.cancelLogin()
            await login.value
            return
        }
        manager.cancelLogin()
        await login.value

        #expect(manager.loginPhase == .idle)
        #expect(!manager.isAuthenticated)
        #expect(await api.cancelledDevicePollCount == 1)
        #expect(await persistence.savedSession == nil)
    }

    @MainActor
    @Test("Cancellation rejects a delayed login save")
    func cancellationRejectsDelayedLoginSave() async {
        let persistence = FakeAuthPersistence(
            blocksFirstSave: true
        )
        let api = FakeAuthAPI(
            devicePollResponse: makeTokens(
                accessToken: "cancelled-login",
                expiresAt: Date().addingTimeInterval(3600)
            )
        )
        let manager = makeManager(
            api: api,
            persistence: persistence
        )
        await manager.initialize()

        let login = manager.login()
        await persistence.waitForSaveRequest()
        #expect(manager.session?.tokens.accessToken == "cancelled-login")

        manager.cancelLogin()
        await persistence.waitForDeleteCompletion()
        await persistence.releaseSave()
        await login.value

        #expect(manager.loginPhase == .idle)
        #expect(!manager.isAuthenticated)
        #expect(await persistence.savedSession == nil)
        #expect(await persistence.saveGenerations == [1])
        #expect(await persistence.deleteGenerations == [2])
    }

    @MainActor
    @Test("Cancellation restores the session that preceded login")
    func cancellationRestoresPriorSession() async {
        let persistence = FakeAuthPersistence(
            session: makeSession(expiresAt: Date().addingTimeInterval(3600)),
            blocksFirstSave: true
        )
        let api = FakeAuthAPI(
            devicePollResponse: makeTokens(
                accessToken: "cancelled-login",
                expiresAt: Date().addingTimeInterval(7200)
            )
        )
        let manager = makeManager(
            api: api,
            persistence: persistence
        )
        await manager.initialize()

        let login = manager.login()
        await persistence.waitForSaveRequest()
        manager.cancelLogin()
        await persistence.waitForSaveRequest(count: 2)
        await persistence.releaseSave()
        await login.value

        #expect(manager.session?.tokens.accessToken == "access")
        #expect(await persistence.savedSession?.tokens.accessToken == "access")
        #expect(await persistence.saveGenerations == [1, 2])
        #expect(await persistence.deleteGenerations.isEmpty)
    }

    @MainActor
    @Test("Device-flow denial is reported instead of silently restarting")
    func deviceFlowDenialFails() async {
        let persistence = FakeAuthPersistence()
        let api = FakeAuthAPI(devicePollError: AuthError.deviceFlowDenied)
        let manager = makeManager(api: api, persistence: persistence)
        await manager.initialize()

        let login = manager.login()
        await login.value

        guard case .failed = manager.loginPhase else {
            Issue.record("Expected device-flow denial to publish a failure")
            return
        }
        #expect(await api.deviceAuthorizationCallCount == 1)
        #expect(!manager.isAuthenticated)
    }

    @MainActor
    @Test("A delayed login save cannot restore credentials after logout")
    func delayedSaveCannotUndoLogout() async {
        let persistence = FakeAuthPersistence(
            blocksFirstSave: true
        )
        let api = FakeAuthAPI(
            devicePollResponse: makeTokens(
                accessToken: "old-login",
                expiresAt: Date().addingTimeInterval(3600)
            )
        )
        let manager = makeManager(
            api: api,
            persistence: persistence
        )
        await manager.initialize()

        let login = manager.login()
        await persistence.waitForSaveRequest()
        manager.logout()
        await persistence.waitForDeleteCompletion()
        await persistence.releaseSave()
        await login.value

        #expect(!manager.isAuthenticated)
        #expect(await persistence.savedSession == nil)
        #expect(await persistence.saveGenerations == [1])
        #expect(await persistence.deleteGenerations == [2])
        #expect(await persistence.deleteCount == 1)
    }

    @MainActor
    @Test("Logout discards login rollback ownership")
    func logoutDiscardsLoginRollbackOwnership() async {
        let persistence = FakeAuthPersistence(
            session: makeSession(expiresAt: Date().addingTimeInterval(3600)),
            blocksFirstSave: true,
            blocksSecondSave: true
        )
        let api = FakeAuthAPI(
            devicePollResponse: makeTokens(
                accessToken: "replacement-login",
                expiresAt: Date().addingTimeInterval(7200)
            )
        )
        let manager = makeManager(
            api: api,
            persistence: persistence
        )
        await manager.initialize()

        let firstLogin = manager.login()
        await persistence.waitForSaveRequest()
        manager.logout()
        await persistence.waitForDeleteCompletion()

        let secondLogin = manager.login()
        await persistence.waitForSaveRequest(count: 2)
        await persistence.releaseSave()
        await firstLogin.value

        manager.cancelLogin()
        await persistence.waitForDeleteCompletion(count: 2)
        await persistence.releaseSave(request: 2)
        await secondLogin.value

        #expect(!manager.isAuthenticated)
        #expect(await persistence.savedSession == nil)
        #expect(await persistence.saveGenerations == [1, 3])
        #expect(await persistence.deleteGenerations == [2, 4])
    }

    @MainActor
    @Test("A newer login save wins over a delayed older delete")
    func newerLoginWinsOverDelayedDelete() async {
        let persistence = FakeAuthPersistence(
            session: makeSession(
                expiresAt: Date().addingTimeInterval(3600)
            ),
            blocksFirstDelete: true
        )
        let api = FakeAuthAPI(
            devicePollResponse: makeTokens(
                accessToken: "new-login",
                expiresAt: Date().addingTimeInterval(7200)
            )
        )
        let manager = makeManager(
            api: api,
            persistence: persistence
        )
        await manager.initialize()

        manager.logout()
        await persistence.waitForDeleteRequest()
        let login = manager.login()
        await login.value
        #expect(manager.session?.tokens.accessToken == "new-login")
        #expect(
            await persistence.savedSession?.tokens.accessToken
                == "new-login"
        )

        await persistence.releaseDelete()
        await persistence.waitForDeleteCompletion()

        #expect(manager.session?.tokens.accessToken == "new-login")
        #expect(
            await persistence.savedSession?.tokens.accessToken
                == "new-login"
        )
        #expect(await persistence.saveGenerations == [2])
        #expect(await persistence.deleteGenerations == [1])
        #expect(await persistence.deleteCount == 0)
    }

    @MainActor
    @Test("An old refresh failure cannot clear a newer login")
    func oldRefreshFailureCannotClearNewLogin() async {
        let persistence = FakeAuthPersistence(
            session: makeSession(
                expiresAt: Date().addingTimeInterval(-1)
            )
        )
        let api = FakeAuthAPI(
            devicePollResponse: makeTokens(
                accessToken: "new-login",
                expiresAt: Date().addingTimeInterval(7200)
            ),
            blockRefresh: true
        )
        let manager = makeManager(
            api: api,
            persistence: persistence
        )
        let initialization = Task { @MainActor in
            await manager.initialize()
        }
        await api.waitForRefreshRequest()

        let login = manager.login()
        await login.value
        #expect(manager.session?.tokens.accessToken == "new-login")

        await api.releaseRefresh()
        await initialization.value

        #expect(manager.session?.tokens.accessToken == "new-login")
        #expect(
            await persistence.savedSession?.tokens.accessToken
                == "new-login"
        )
        #expect(await persistence.saveGenerations == [1])
        #expect(await persistence.deleteGenerations.isEmpty)
    }

    @MainActor
    private func makeManager(
        api: FakeAuthAPI,
        persistence: FakeAuthPersistence
    ) -> AuthManager {
        AuthManager(
            api: api,
            persistence: persistence,
            backgroundScheduler: .disabled,
            schedulesAutomaticRefresh: false
        )
    }

    private func makeSession(expiresAt: Date) -> AuthSession {
        AuthSession(
            provider: LoginProvider(
                idpId: "provider",
                code: "NVIDIA",
                displayName: "NVIDIA",
                streamingServiceUrl: "https://stream.invalid/",
                priority: 0
            ),
            tokens: makeTokens(
                accessToken: "access",
                expiresAt: expiresAt
            ),
            user: AuthUser(
                userId: "user",
                displayName: "Fixture User",
                email: nil,
                avatarUrl: nil,
                membershipTier: "FREE"
            )
        )
    }

    private func makeTokens(
        accessToken: String,
        expiresAt: Date
    ) -> AuthTokens {
        AuthTokens(
            accessToken: accessToken,
            refreshToken: "refresh",
            idToken: nil,
            expiresAt: expiresAt,
            clientToken: nil,
            clientTokenExpiresAt: nil
        )
    }
}

private enum FakeAuthAPIError: Error {
    case unavailable
}

private actor FakeAuthAPI: NVIDIAAuthAPIClient {
    private let refreshTokensResponse: AuthTokens?
    private let clientTokenResponse: (String, Date)?
    private let devicePollResponse: AuthTokens?
    private let blockRefresh: Bool
    private let blockDevicePoll: Bool
    private let devicePollError: (any Error)?
    private var refreshReleased = false
    private var refreshContinuation: CheckedContinuation<Void, Error>?
    private var refreshRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var devicePollContinuation: CheckedContinuation<Void, Error>?
    private var devicePollCancellationRequested = false
    private var devicePollRequestWaiters: [CheckedContinuation<Void, Never>] = []

    private(set) var refreshTokenCallCount = 0
    private(set) var deviceAuthorizationCallCount = 0
    private(set) var devicePollCallCount = 0
    private(set) var cancelledDevicePollCount = 0

    init(
        refreshTokensResponse: AuthTokens? = nil,
        clientTokenResponse: (String, Date)? = nil,
        devicePollResponse: AuthTokens? = nil,
        blockRefresh: Bool = false,
        blockDevicePoll: Bool = false,
        devicePollError: (any Error)? = nil
    ) {
        self.refreshTokensResponse = refreshTokensResponse
        self.clientTokenResponse = clientTokenResponse
        self.devicePollResponse = devicePollResponse
        self.blockRefresh = blockRefresh
        self.blockDevicePoll = blockDevicePoll
        self.devicePollError = devicePollError
    }

    func fetchProviders() async throws -> [LoginProvider] {
        [
            LoginProvider(
                idpId: "provider",
                code: "NVIDIA",
                displayName: "NVIDIA",
                streamingServiceUrl: "https://stream.invalid/",
                priority: 0
            ),
        ]
    }

    func refreshTokens(_: String) async throws -> AuthTokens {
        refreshTokenCallCount += 1
        let waiters = refreshRequestWaiters
        refreshRequestWaiters = []
        waiters.forEach { $0.resume() }
        if blockRefresh, !refreshReleased {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (
                    continuation: CheckedContinuation<Void, Error>
                ) in
                    if refreshReleased {
                        continuation.resume()
                    } else {
                        refreshContinuation = continuation
                    }
                }
            } onCancel: {
                Task {
                    await self.cancelRefreshWait()
                }
            }
        }
        guard let refreshTokensResponse else {
            throw FakeAuthAPIError.unavailable
        }
        return refreshTokensResponse
    }

    func fetchClientToken(accessToken _: String) async throws -> (
        token: String,
        expiresAt: Date
    ) {
        guard let clientTokenResponse else {
            throw FakeAuthAPIError.unavailable
        }
        return clientTokenResponse
    }

    func refreshWithClientToken(
        _: String,
        userId _: String
    ) async throws -> AuthTokens {
        throw FakeAuthAPIError.unavailable
    }

    func requestDeviceAuthorization(
        idpId _: String?
    ) async throws -> DeviceFlowResponse {
        deviceAuthorizationCallCount += 1
        return DeviceFlowResponse(
            userCode: "ABCD-EFGH",
            deviceCode: "device-code",
            verificationUri: "https://login.invalid/device",
            verificationUriComplete: "https://login.invalid/device?code=ABCD-EFGH",
            expiresIn: 600,
            interval: 0
        )
    }

    func pollForDeviceToken(
        deviceCode _: String,
        interval _: Int,
        expiresIn _: Int
    ) async throws -> AuthTokens {
        devicePollCallCount += 1
        let waiters = devicePollRequestWaiters
        devicePollRequestWaiters = []
        waiters.forEach { $0.resume() }
        if let devicePollError {
            throw devicePollError
        }
        if blockDevicePoll {
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (
                        continuation: CheckedContinuation<Void, Error>
                    ) in
                        if devicePollCancellationRequested {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            devicePollContinuation = continuation
                        }
                    }
                } onCancel: {
                    Task {
                        await self.cancelDevicePollWait()
                    }
                }
            } catch {
                cancelledDevicePollCount += 1
                throw error
            }
        }
        if let devicePollResponse {
            return devicePollResponse
        }
        throw FakeAuthAPIError.unavailable
    }

    func fetchUserInfo(tokens _: AuthTokens) async throws -> AuthUser {
        AuthUser(
            userId: "user",
            displayName: "Fixture User",
            email: nil,
            avatarUrl: nil,
            membershipTier: "FREE"
        )
    }

    func releaseRefresh() {
        refreshReleased = true
        refreshContinuation?.resume()
        refreshContinuation = nil
    }

    func waitForRefreshRequest() async {
        guard refreshTokenCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            refreshRequestWaiters.append(continuation)
        }
    }

    func waitForDevicePollRequest() async {
        guard devicePollCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            devicePollRequestWaiters.append(continuation)
        }
    }

    private func cancelRefreshWait() {
        refreshContinuation?.resume(throwing: CancellationError())
        refreshContinuation = nil
    }

    private func cancelDevicePollWait() {
        devicePollCancellationRequested = true
        devicePollContinuation?.resume(throwing: CancellationError())
        devicePollContinuation = nil
    }
}

private actor FakeAuthPersistence: AuthSessionPersistence {
    private(set) var savedSession: AuthSession?
    private(set) var deleteCount = 0
    private(set) var saveGenerations: [UInt64] = []
    private(set) var deleteGenerations: [UInt64] = []
    private(set) var completedDeleteCount = 0
    private(set) var loadRequestCount = 0
    private let blocksFirstLoad: Bool
    private let blocksFirstSave: Bool
    private let blocksSecondSave: Bool
    private let blocksFirstDelete: Bool
    private var didBlockLoad = false
    private var didBlockDelete = false
    private var credentialGeneration: UInt64 = 0
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var saveContinuations: [
        Int: CheckedContinuation<Void, Never>
    ] = [:]
    private var deleteContinuation: CheckedContinuation<Void, Never>?
    private var loadRequestWaiters: [OperationWaiter] = []
    private var saveRequestWaiters: [OperationWaiter] = []
    private var deleteRequestWaiters: [OperationWaiter] = []
    private var deleteCompletionWaiters: [OperationWaiter] = []

    private struct OperationWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    init(
        session: AuthSession? = nil,
        blocksFirstLoad: Bool = false,
        blocksFirstSave: Bool = false,
        blocksSecondSave: Bool = false,
        blocksFirstDelete: Bool = false
    ) {
        savedSession = session
        self.blocksFirstLoad = blocksFirstLoad
        self.blocksFirstSave = blocksFirstSave
        self.blocksSecondSave = blocksSecondSave
        self.blocksFirstDelete = blocksFirstDelete
    }

    func loadAuthSession() async throws -> AuthSession {
        let loadedSession = savedSession
        loadRequestCount += 1
        resumeWaiters(
            &loadRequestWaiters,
            completedCount: loadRequestCount
        )
        if blocksFirstLoad, !didBlockLoad {
            didBlockLoad = true
            await withCheckedContinuation { continuation in
                loadContinuation = continuation
            }
        }
        guard let loadedSession else {
            throw FakeAuthAPIError.unavailable
        }
        return loadedSession
    }

    func saveAuthSession(
        _ session: AuthSession,
        generation: UInt64
    ) async throws {
        saveGenerations.append(generation)
        resumeWaiters(
            &saveRequestWaiters,
            completedCount: saveGenerations.count
        )
        let requestCount = saveGenerations.count
        if (blocksFirstSave && requestCount == 1)
            || (blocksSecondSave && requestCount == 2)
        {
            await withCheckedContinuation { continuation in
                saveContinuations[requestCount] = continuation
            }
        }
        guard generation >= credentialGeneration else {
            return
        }
        credentialGeneration = generation
        savedSession = session
    }

    func deleteAuthSession(generation: UInt64) async throws {
        deleteGenerations.append(generation)
        resumeWaiters(
            &deleteRequestWaiters,
            completedCount: deleteGenerations.count
        )
        if blocksFirstDelete, !didBlockDelete {
            didBlockDelete = true
            await withCheckedContinuation { continuation in
                deleteContinuation = continuation
            }
        }
        if generation >= credentialGeneration {
            credentialGeneration = generation
            deleteCount += 1
            savedSession = nil
        }
        completedDeleteCount += 1
        resumeWaiters(
            &deleteCompletionWaiters,
            completedCount: completedDeleteCount
        )
    }

    func waitForSaveRequest(count: Int = 1) async {
        guard saveGenerations.count < count else { return }
        await withCheckedContinuation { continuation in
            saveRequestWaiters.append(
                OperationWaiter(
                    count: count,
                    continuation: continuation
                )
            )
        }
    }

    func waitForLoadRequest(count: Int = 1) async {
        guard loadRequestCount < count else { return }
        await withCheckedContinuation { continuation in
            loadRequestWaiters.append(
                OperationWaiter(
                    count: count,
                    continuation: continuation
                )
            )
        }
    }

    func waitForDeleteRequest(count: Int = 1) async {
        guard deleteGenerations.count < count else { return }
        await withCheckedContinuation { continuation in
            deleteRequestWaiters.append(
                OperationWaiter(
                    count: count,
                    continuation: continuation
                )
            )
        }
    }

    func waitForDeleteCompletion(count: Int = 1) async {
        guard completedDeleteCount < count else { return }
        await withCheckedContinuation { continuation in
            deleteCompletionWaiters.append(
                OperationWaiter(
                    count: count,
                    continuation: continuation
                )
            )
        }
    }

    func releaseSave(request: Int = 1) {
        saveContinuations.removeValue(forKey: request)?.resume()
    }

    func releaseLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func releaseDelete() {
        deleteContinuation?.resume()
        deleteContinuation = nil
    }

    private func resumeWaiters(
        _ waiters: inout [OperationWaiter],
        completedCount: Int
    ) {
        var remaining: [OperationWaiter] = []
        for waiter in waiters {
            if completedCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}
