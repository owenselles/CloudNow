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
        blockRefresh: Bool = false,
        blockDevicePoll: Bool = false,
        devicePollError: (any Error)? = nil
    ) {
        self.refreshTokensResponse = refreshTokensResponse
        self.clientTokenResponse = clientTokenResponse
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

    init(session: AuthSession? = nil) {
        savedSession = session
    }

    func loadAuthSession() async throws -> AuthSession {
        guard let savedSession else {
            throw FakeAuthAPIError.unavailable
        }
        return savedSession
    }

    func saveAuthSession(_ session: AuthSession) async throws {
        savedSession = session
    }

    func deleteAuthSession() async throws {
        deleteCount += 1
        savedSession = nil
    }
}
