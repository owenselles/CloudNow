import BackgroundTasks
import Foundation
import Observation
import os.log

private let authLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "Auth")

// MARK: - AuthSession (persisted)

nonisolated struct AuthSession: Codable {
    var provider: LoginProvider
    var tokens: AuthTokens
    var user: AuthUser
}

nonisolated protocol NVIDIAAuthAPIClient: Sendable {
    func fetchProviders() async throws -> [LoginProvider]
    func refreshTokens(_ refreshToken: String) async throws -> AuthTokens
    func fetchClientToken(accessToken: String) async throws -> (
        token: String,
        expiresAt: Date
    )
    func refreshWithClientToken(
        _ clientToken: String,
        userId: String
    ) async throws -> AuthTokens
    func requestDeviceAuthorization(idpId: String?) async throws -> DeviceFlowResponse
    func pollForDeviceToken(
        deviceCode: String,
        interval: Int,
        expiresIn: Int
    ) async throws -> AuthTokens
    func fetchUserInfo(tokens: AuthTokens) async throws -> AuthUser
}

extension NVIDIAAuthAPI: NVIDIAAuthAPIClient {}

nonisolated protocol AuthSessionPersistence: Sendable {
    nonisolated func authSessionResetGeneration() -> UInt64
    func loadAuthSession() async throws -> AuthSession
    func saveAuthSession(
        _ session: AuthSession,
        generation: UInt64
    ) async throws
    func deleteAuthSession(generation: UInt64) async throws
    func saveAuthSession(
        _ session: AuthSession,
        generation: UInt64,
        resetGeneration: UInt64
    ) async throws
    func deleteAuthSession(
        generation: UInt64,
        resetGeneration: UInt64
    ) async throws
}

extension AuthSessionPersistence {
    nonisolated func authSessionResetGeneration() -> UInt64 {
        0
    }

    func saveAuthSession(
        _ session: AuthSession,
        generation: UInt64,
        resetGeneration _: UInt64
    ) async throws {
        try await saveAuthSession(session, generation: generation)
    }

    func deleteAuthSession(
        generation: UInt64,
        resetGeneration _: UInt64
    ) async throws {
        try await deleteAuthSession(generation: generation)
    }
}

extension AppPersistenceStore: AuthSessionPersistence {}

nonisolated struct AuthBackgroundScheduler: Sendable {
    let cancel: @MainActor @Sendable (String) -> Void
    let submit: @MainActor @Sendable (String, Date) -> Void

    static let live = AuthBackgroundScheduler(
        cancel: { identifier in
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        },
        submit: { identifier, earliestBeginDate in
            let request = BGAppRefreshTaskRequest(identifier: identifier)
            request.earliestBeginDate = earliestBeginDate
            try? BGTaskScheduler.shared.submit(request)
        }
    )

    static let disabled = AuthBackgroundScheduler(
        cancel: { _ in },
        submit: { _, _ in }
    )
}

// MARK: - Login Phase

enum LoginPhase: Equatable {
    case idle
    case showingPIN(code: String, url: String, urlComplete: String)
    case exchangingTokens
    case failed(String)
}

enum AuthStartupPhase: Equatable {
    case pending
    case restoringSession
    case ready
}

// MARK: - AuthManager

@Observable
@MainActor
final class AuthManager {
    private struct ActiveLogin {
        let generation: UInt64
        let priorSession: AuthSession?
    }

    private(set) var session: AuthSession?
    private(set) var loginPhase: LoginPhase = .idle
    private(set) var startupPhase: AuthStartupPhase = .pending

    var isAuthenticated: Bool {
        session != nil
    }

    @ObservationIgnored private var api: (any NVIDIAAuthAPIClient)?
    @ObservationIgnored private let makeAPI: @Sendable () -> any NVIDIAAuthAPIClient
    @ObservationIgnored private let retainsInjectedAPI: Bool
    private let persistence: any AuthSessionPersistence
    private let backgroundScheduler: AuthBackgroundScheduler
    private let schedulesAutomaticRefresh: Bool
    private var loginTask: Task<Void, Never>?
    private var activeLogin: ActiveLogin?
    private var activeRefreshTask: Task<AuthSession, Error>?
    private var refreshTaskGeneration: UInt64 = 0
    private var refreshTimer: Task<Void, Never>?
    private var credentialGeneration: UInt64 = 0
    private var isCredentialMutationInProgress = false
    @ObservationIgnored private var sessionRestoreWaiters: [CheckedContinuation<Void, Never>] = []

    private static let bgTaskID = "com.owenselles.CloudNow.tokenRefresh"

    init(
        api: (any NVIDIAAuthAPIClient)? = nil,
        makeAPI: @escaping @Sendable () -> any NVIDIAAuthAPIClient = {
            NVIDIAAuthAPI()
        },
        persistence: any AuthSessionPersistence = AppPersistenceStore.shared,
        backgroundScheduler: AuthBackgroundScheduler = .live,
        schedulesAutomaticRefresh: Bool = true,
        initialSession: AuthSession? = nil
    ) {
        self.api = api
        self.makeAPI = makeAPI
        retainsInjectedAPI = api != nil
        self.persistence = persistence
        self.backgroundScheduler = backgroundScheduler
        self.schedulesAutomaticRefresh = schedulesAutomaticRefresh
        session = initialSession
        if initialSession != nil {
            startupPhase = .ready
        }
    }

    // MARK: Lifecycle

    func initialize() async {
        guard !isCredentialMutationInProgress else { return }
        await restorePersistedSession()
        await refreshIfNeeded()
    }

    func restorePersistedSession() async {
        guard !isCredentialMutationInProgress else {
            return
        }
        switch startupPhase {
        case .ready:
            return
        case .restoringSession:
            await withCheckedContinuation { continuation in
                sessionRestoreWaiters.append(continuation)
            }
            return
        case .pending:
            break
        }
        startupPhase = .restoringSession
        defer { finishSessionRestore() }
        let generation = credentialGeneration

        let saved = try? await persistence.loadAuthSession()
        guard !isCredentialMutationInProgress,
              credentialGeneration == generation
        else {
            return
        }
        guard let saved else {
            return
        }

        session = saved
    }

    private func finishSessionRestore() {
        startupPhase = .ready
        let waiters = sessionRestoreWaiters
        sessionRestoreWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    /// Starts GeForce NOW-only refresh work after the provider coordinator has
    /// selected it. Restoring credentials by itself must not produce network
    /// traffic while another cloud service is active.
    func activateForCurrentProvider() async {
        guard !isCredentialMutationInProgress,
              session != nil
        else {
            return
        }
        await refreshIfNeeded()
        guard !Task.isCancelled, session != nil else { return }
        scheduleProactiveRefresh()
        scheduleBackgroundRefresh()
    }

    /// Cancels provider-owned work without removing the persisted account.
    func deactivateForInactiveProvider() {
        if activeLogin != nil {
            cancelLogin()
        }
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        refreshTimer?.cancel()
        refreshTimer = nil
        backgroundScheduler.cancel(Self.bgTaskID)
        releaseRuntimeClient()
    }

    // MARK: Login (Device Flow)

    func discoverLoginProviders() async throws -> [LoginProvider] {
        try await resolvedAPI().fetchProviders()
    }

    @discardableResult
    func login(with provider: LoginProvider? = nil) -> Task<Void, Never> {
        guard !isCredentialMutationInProgress else { return Task {} }
        if activeLogin != nil {
            cancelLogin()
        }
        let api = resolvedAPI()
        credentialGeneration &+= 1
        let generation = credentialGeneration
        activeLogin = ActiveLogin(
            generation: generation,
            priorSession: session
        )
        let task = Task {
            defer {
                if activeLogin?.generation == generation {
                    activeLogin = nil
                    loginTask = nil
                }
            }
            loginPhase = .idle
            do {
                let providers: [LoginProvider] = if let provider {
                    [provider]
                } else {
                    await (try? api.fetchProviders()) ?? []
                }
                let selectedProvider = providers.first ?? .nvidiaDirect

                // Device flow loop: restart automatically when the code expires.
                // access_denied and other hard errors escape to the outer catch.
                var tokens: AuthTokens
                while true {
                    try Task.checkCancellation()
                    let deviceAuth = try await api.requestDeviceAuthorization(idpId: selectedProvider.idpId)
                    loginPhase = .showingPIN(
                        code: deviceAuth.userCode,
                        url: deviceAuth.verificationUri
                            .replacingOccurrences(of: "https://", with: ""),
                        urlComplete: deviceAuth.verificationUriComplete
                    )
                    do {
                        tokens = try await api.pollForDeviceToken(
                            deviceCode: deviceAuth.deviceCode,
                            interval: deviceAuth.interval,
                            expiresIn: deviceAuth.expiresIn
                        )
                        break
                    } catch AuthError.deviceFlowExpired {
                        continue
                    }
                }
                loginPhase = .exchangingTokens

                let user = try await api.fetchUserInfo(tokens: tokens)

                // Bootstrap client token, then immediately use it to re-bind all
                // tokens under the main clientID. Device flow issues tokens under
                // deviceFlowClientID; games.geforce.com only accepts tokens from
                // clientID. The client_token grant works cross-client.
                if let ct = try? await api.fetchClientToken(accessToken: tokens.accessToken) {
                    tokens.clientToken = ct.token
                    tokens.clientTokenExpiresAt = ct.expiresAt
                    if let rebound = try? await api.refreshWithClientToken(ct.token, userId: user.userId) {
                        let savedRefreshToken = tokens.refreshToken // preserve device-flow refreshToken
                        let savedIdToken = tokens.idToken // preserve device-flow idToken
                        tokens = rebound
                        if tokens.refreshToken == nil {
                            tokens.refreshToken = savedRefreshToken
                        }
                        if tokens.idToken == nil {
                            tokens.idToken = savedIdToken
                        }
                        // Re-fetch clientToken for the re-bound session
                        if let ct2 = try? await api.fetchClientToken(accessToken: tokens.accessToken) {
                            tokens.clientToken = ct2.token
                            tokens.clientTokenExpiresAt = ct2.expiresAt
                        }
                    }
                }

                try Task.checkCancellation()
                guard credentialGeneration == generation else {
                    throw CancellationError()
                }
                let newSession = AuthSession(provider: selectedProvider, tokens: tokens, user: user)
                session = newSession
                scheduleProactiveRefresh()
                scheduleBackgroundRefresh()
                try await persist(
                    newSession,
                    generation: generation
                )
                guard credentialGeneration == generation else {
                    throw CancellationError()
                }
                loginPhase = .idle
            } catch is CancellationError {
                if credentialGeneration == generation {
                    loginPhase = .idle
                }
            } catch {
                if credentialGeneration == generation {
                    loginPhase = .failed(error.localizedDescription)
                }
            }
        }
        loginTask = task
        return task
    }

    func cancelLogin() {
        guard let activeLogin else {
            loginTask = nil
            loginPhase = .idle
            return
        }

        credentialGeneration &+= 1
        let rollbackGeneration = credentialGeneration
        let resetGeneration = persistence.authSessionResetGeneration()
        loginTask?.cancel()
        loginTask = nil
        self.activeLogin = nil
        session = activeLogin.priorSession
        loginPhase = .idle
        refreshTimer?.cancel()
        refreshTimer = nil
        if session == nil {
            backgroundScheduler.cancel(Self.bgTaskID)
            releaseRuntimeClient()
        } else {
            scheduleProactiveRefresh()
            scheduleBackgroundRefresh()
        }

        Task {
            if let priorSession = activeLogin.priorSession {
                try? await persistence.saveAuthSession(
                    priorSession,
                    generation: rollbackGeneration,
                    resetGeneration: resetGeneration
                )
            } else {
                try? await persistence.deleteAuthSession(
                    generation: rollbackGeneration,
                    resetGeneration: resetGeneration
                )
            }
        }
    }

    // MARK: Logout

    func logout() async throws {
        guard !isCredentialMutationInProgress else { return }
        isCredentialMutationInProgress = true
        defer { isCredentialMutationInProgress = false }
        invalidateAuthenticationWork()
        let generation = credentialGeneration
        let resetGeneration = persistence.authSessionResetGeneration()
        do {
            try await persistence.deleteAuthSession(
                generation: generation,
                resetGeneration: resetGeneration
            )
        } catch {
            guard credentialGeneration == generation else { return }
            resumeAfterDataResetFailure()
            throw AuthError.secureStorageUnavailable
        }
        guard credentialGeneration == generation else { return }
        session = nil
        loginPhase = .idle
        releaseRuntimeClient()
    }

    /// Stops authentication work before Reset All Data removes credentials.
    /// The visible session remains available until cleanup finishes and logout
    /// performs the final UI transition.
    func prepareForDataReset() {
        isCredentialMutationInProgress = true
        invalidateAuthenticationWork()
    }

    /// Completes the in-memory half of Reset All Data after the shared
    /// persistence store confirms that both account namespaces were removed.
    func finishDataReset() {
        invalidateAuthenticationWork()
        session = nil
        loginPhase = .idle
        releaseRuntimeClient()
        isCredentialMutationInProgress = false
    }

    /// Restores refresh scheduling when Reset All Data aborts before credentials
    /// are removed and the current session remains active.
    func resumeAfterDataResetFailure() {
        abortDataResetWithoutActivation()
        guard session != nil else { return }
        scheduleProactiveRefresh()
        scheduleBackgroundRefresh()
    }

    /// Leaves the reset barrier without starting inactive-provider work.
    func abortDataResetWithoutActivation() {
        isCredentialMutationInProgress = false
    }

    private func invalidateAuthenticationWork() {
        credentialGeneration &+= 1
        activeLogin = nil
        cancelAuthenticationWork()
    }

    private func cancelAuthenticationWork() {
        loginTask?.cancel()
        loginTask = nil
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        refreshTimer?.cancel()
        refreshTimer = nil
        backgroundScheduler.cancel(Self.bgTaskID)
    }

    // MARK: Token Refresh

    /// Returns the best available JWT token, refreshing if near expiry.
    func resolveToken() async throws -> String {
        guard !isCredentialMutationInProgress else {
            throw CancellationError()
        }
        guard var s = session else { throw AuthError.noSession }
        if s.tokens.isNearExpiry {
            s = try await refresh(session: s)
        }
        return preferredToken(in: s)
    }

    /// Returns a credential different from one rejected by the server. If another
    /// request already refreshed the session, reuse it instead of rotating again.
    func resolveToken(rejecting rejectedToken: String) async throws -> String {
        guard !isCredentialMutationInProgress else {
            throw CancellationError()
        }
        guard let s = session else { throw AuthError.noSession }
        let currentToken = preferredToken(in: s)
        if currentToken != rejectedToken {
            return currentToken
        }

        let generation = credentialGeneration
        _ = try await refresh(session: s)
        guard credentialGeneration == generation else {
            throw CancellationError()
        }
        guard var refreshedSession = session else {
            throw AuthError.noSession
        }

        // Some refresh grants omit id_token, causing performRefresh to preserve
        // the previous value. Once a server has rejected that ID token, keeping
        // it would make the next plain resolveToken() select it again.
        if refreshedSession.tokens.idToken == rejectedToken {
            refreshedSession.tokens.idToken = nil
            session = refreshedSession
            try await persist(
                refreshedSession,
                generation: generation
            )
            guard credentialGeneration == generation else {
                throw CancellationError()
            }
        }

        let refreshedToken = preferredToken(in: refreshedSession)
        return refreshedToken == rejectedToken
            ? refreshedSession.tokens.accessToken
            : refreshedToken
    }

    // MARK: Private

    private func preferredToken(in session: AuthSession) -> String {
        session.tokens.idToken ?? session.tokens.accessToken
    }

    func refreshIfNeeded() async {
        guard !isCredentialMutationInProgress,
              let s = session,
              s.tokens.isNearExpiry
        else {
            return
        }
        let generation = credentialGeneration
        do {
            _ = try await refresh(session: s)
        } catch is CancellationError {
            return
        } catch {
            guard credentialGeneration == generation else {
                return
            }
            if s.tokens.isExpired {
                authLog.error("[Auth] Token expired and refresh failed: \(error, privacy: .private) — clearing session, re-login required")
                refreshTimer?.cancel()
                session = nil
                let resetGeneration = persistence.authSessionResetGeneration()
                try? await persistence.deleteAuthSession(
                    generation: generation,
                    resetGeneration: resetGeneration
                )
            } else {
                authLog.warning("[Auth] Refresh failed but token still valid (\(Int(s.tokens.expiresAt.timeIntervalSinceNow), privacy: .public)s left) — keeping session")
            }
        }
    }

    private func refresh(session s: AuthSession) async throws -> AuthSession {
        guard !isCredentialMutationInProgress else {
            throw CancellationError()
        }
        // Coalesce: if a refresh is already in-flight, wait for it instead of
        // starting a second one (which would try to use an already-rotated token).
        if let existing = activeRefreshTask {
            return try await existing.value
        }
        let generation = credentialGeneration
        refreshTaskGeneration &+= 1
        let taskGeneration = refreshTaskGeneration
        let task = Task<AuthSession, Error> { @MainActor [weak self] in
            guard let self else { throw AuthError.noSession }
            defer {
                if self.refreshTaskGeneration == taskGeneration {
                    self.activeRefreshTask = nil
                }
            }
            return try await performRefresh(session: s, generation: generation)
        }
        activeRefreshTask = task
        return try await task.value
    }

    private func performRefresh(
        session s: AuthSession,
        generation: UInt64
    ) async throws -> AuthSession {
        try ensureAuthenticationWorkIsCurrent(generation)
        let api = resolvedAPI()
        var updated = s
        authLog.debug("[Auth] performRefresh: accessToken expires=\(String(describing: s.tokens.expiresAt), privacy: .public), clientToken=\(s.tokens.clientToken != nil ? "yes" : "nil", privacy: .public) expires=\(s.tokens.clientTokenExpiresAt?.description ?? "nil", privacy: .public), refreshToken=\(s.tokens.refreshToken != nil ? "yes" : "nil", privacy: .public), idToken=\(s.tokens.idToken != nil ? "yes" : "nil", privacy: .public)")
        let clientTokenUsable = s.tokens.clientToken != nil &&
            (s.tokens.clientTokenExpiresAt.map { $0 > Date() } ?? false)
        if !clientTokenUsable {
            authLog.debug("[Auth] clientToken absent or expired (expiresAt: \(s.tokens.clientTokenExpiresAt?.description ?? "nil", privacy: .public)), skipping primary path")
        }
        var clientTokenRefreshed: AuthTokens? = nil
        if clientTokenUsable, let clientToken = s.tokens.clientToken {
            do {
                try ensureAuthenticationWorkIsCurrent(generation)
                clientTokenRefreshed = try await api.refreshWithClientToken(clientToken, userId: s.user.userId)
            } catch {
                try ensureAuthenticationWorkIsCurrent(generation)
                authLog.warning("[Auth] client_token grant failed: \(error, privacy: .private)")
            }
        }
        if let refreshed = clientTokenRefreshed {
            authLog.info("[Auth] refresh via client_token grant succeeded")
            let savedRefreshToken = updated.tokens.refreshToken
            let savedIdToken = updated.tokens.idToken
            updated.tokens = refreshed
            if updated.tokens.refreshToken == nil {
                authLog.warning("[Auth] client_token grant did not return a refreshToken — preserving previous one")
                updated.tokens.refreshToken = savedRefreshToken
            }
            if updated.tokens.idToken == nil {
                updated.tokens.idToken = savedIdToken
            }
        } else if let refreshToken = s.tokens.refreshToken {
            try ensureAuthenticationWorkIsCurrent(generation)
            authLog.warning("[Auth] client_token path unavailable or failed, falling back to refresh_token grant")
            let savedRefreshToken = updated.tokens.refreshToken
            let savedIdToken = updated.tokens.idToken
            updated.tokens = try await api.refreshTokens(refreshToken)
            if updated.tokens.refreshToken == nil {
                authLog.warning("[Auth] refresh_token grant did not return a new refreshToken — preserving previous one")
                updated.tokens.refreshToken = savedRefreshToken
            }
            if updated.tokens.idToken == nil {
                updated.tokens.idToken = savedIdToken
            }
            authLog.info("[Auth] refresh via refresh_token grant succeeded")
        } else if let idToken = s.tokens.idToken {
            // Third path: the idToken is a longer-lived JWT (typically 30 days) that NVIDIA
            // servers accept directly. Use it to fetch a fresh clientToken, then re-bind.
            // This mirrors how the official GFN client recovers when the clientToken has expired
            // and no refresh_token is available — it passes the idToken to /client_token.
            authLog.warning("[Auth] both primary paths unavailable, attempting idToken bootstrap")
            let ct: (token: String, expiresAt: Date)
            let rebound: AuthTokens
            do {
                try ensureAuthenticationWorkIsCurrent(generation)
                ct = try await api.fetchClientToken(accessToken: idToken)
            } catch {
                try ensureAuthenticationWorkIsCurrent(generation)
                authLog.error("[Auth] idToken bootstrap — fetchClientToken failed: \(error, privacy: .private)")
                throw AuthError.tokenRefreshFailed("All refresh mechanisms exhausted.")
            }
            do {
                try ensureAuthenticationWorkIsCurrent(generation)
                rebound = try await api.refreshWithClientToken(ct.token, userId: s.user.userId)
            } catch {
                try ensureAuthenticationWorkIsCurrent(generation)
                authLog.error("[Auth] idToken bootstrap — refreshWithClientToken failed: \(error, privacy: .private)")
                throw AuthError.tokenRefreshFailed("All refresh mechanisms exhausted.")
            }
            authLog.info("[Auth] refresh via idToken bootstrap succeeded")
            let savedRefreshToken = updated.tokens.refreshToken
            updated.tokens = rebound
            if updated.tokens.refreshToken == nil {
                updated.tokens.refreshToken = savedRefreshToken
            }
            // Preserve the idToken used for bootstrap so we can re-use it on the next cycle
            if updated.tokens.idToken == nil {
                updated.tokens.idToken = idToken
            }
        } else {
            authLog.error("[Auth] refresh failed: no usable clientToken, refreshToken, or idToken available")
            throw AuthError.tokenRefreshFailed("All refresh mechanisms exhausted.")
        }
        // Re-bootstrap client token
        do {
            try ensureAuthenticationWorkIsCurrent(generation)
            let ct = try await api.fetchClientToken(accessToken: updated.tokens.accessToken)
            authLog.info("[Auth] client_token re-bootstrapped, expires: \(String(describing: ct.expiresAt), privacy: .public)")
            updated.tokens.clientToken = ct.token
            updated.tokens.clientTokenExpiresAt = ct.expiresAt
        } catch {
            try ensureAuthenticationWorkIsCurrent(generation)
            authLog.warning("[Auth] warning: failed to re-bootstrap client_token after refresh: \(error, privacy: .private)")
        }
        try ensureAuthenticationWorkIsCurrent(generation)
        session = updated
        scheduleProactiveRefresh()
        scheduleBackgroundRefresh()
        try await persist(
            updated,
            generation: generation
        )
        guard credentialGeneration == generation else {
            throw CancellationError()
        }
        return updated
    }

    private func resolvedAPI() -> any NVIDIAAuthAPIClient {
        if let api {
            return api
        }
        let api = makeAPI()
        self.api = api
        return api
    }

    private func releaseRuntimeClient() {
        guard !retainsInjectedAPI else { return }
        api = nil
    }

    // MARK: Proactive Refresh

    private func scheduleProactiveRefresh() {
        refreshTimer?.cancel()
        guard !isCredentialMutationInProgress,
              schedulesAutomaticRefresh
        else {
            return
        }
        guard let s = session else { return }
        let delay = s.tokens.expiresAt.timeIntervalSinceNow - (5 * 60)
        guard delay > 0 else { return }
        refreshTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refreshIfNeeded()
        }
    }

    func scheduleBackgroundRefresh() {
        guard !isCredentialMutationInProgress,
              schedulesAutomaticRefresh
        else {
            return
        }
        guard let s = session else { return }
        backgroundScheduler.submit(
            Self.bgTaskID,
            s.tokens.expiresAt.addingTimeInterval(-(5 * 60))
        )
    }

    private func persist(
        _ session: AuthSession,
        generation: UInt64
    ) async throws {
        try ensureAuthenticationWorkIsCurrent(generation)
        let resetGeneration = persistence.authSessionResetGeneration()
        try await persistence.saveAuthSession(
            session,
            generation: generation,
            resetGeneration: resetGeneration
        )
    }

    private func ensureAuthenticationWorkIsCurrent(
        _ generation: UInt64
    ) throws {
        try Task.checkCancellation()
        guard !isCredentialMutationInProgress,
              credentialGeneration == generation
        else {
            throw CancellationError()
        }
    }
}
