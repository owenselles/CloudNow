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
    func loadAuthSession() async throws -> AuthSession
    func saveAuthSession(_ session: AuthSession) async throws
    func deleteAuthSession() async throws
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
    private(set) var session: AuthSession?
    private(set) var loginPhase: LoginPhase = .idle
    private(set) var startupPhase: AuthStartupPhase = .pending

    var isAuthenticated: Bool {
        session != nil
    }

    private let api: any NVIDIAAuthAPIClient
    private let persistence: any AuthSessionPersistence
    private let backgroundScheduler: AuthBackgroundScheduler
    private let schedulesAutomaticRefresh: Bool
    private var loginTask: Task<Void, Never>?
    private var activeRefreshTask: Task<AuthSession, Error>?
    private var refreshTaskGeneration: UInt64 = 0
    private var refreshTimer: Task<Void, Never>?
    private var credentialGeneration = 0

    private static let bgTaskID = "com.owenselles.CloudNow.tokenRefresh"

    init(
        api: any NVIDIAAuthAPIClient = NVIDIAAuthAPI(),
        persistence: any AuthSessionPersistence = AppPersistenceStore.shared,
        backgroundScheduler: AuthBackgroundScheduler = .live,
        schedulesAutomaticRefresh: Bool = true
    ) {
        self.api = api
        self.persistence = persistence
        self.backgroundScheduler = backgroundScheduler
        self.schedulesAutomaticRefresh = schedulesAutomaticRefresh
    }

    // MARK: Lifecycle

    func initialize() async {
        guard startupPhase == .pending else { return }
        startupPhase = .restoringSession

        guard let saved = try? await persistence.loadAuthSession() else {
            startupPhase = .ready
            return
        }

        session = saved
        scheduleProactiveRefresh()
        scheduleBackgroundRefresh()
        startupPhase = .ready
        await refreshIfNeeded()
    }

    // MARK: Login (Device Flow)

    @discardableResult
    func login(with provider: LoginProvider? = nil) -> Task<Void, Never> {
        loginTask?.cancel()
        credentialGeneration &+= 1
        let generation = credentialGeneration
        let task = Task {
            loginPhase = .idle
            do {
                let providers: [LoginProvider] = if let provider {
                    [provider]
                } else {
                    await (try? api.fetchProviders()) ?? []
                }
                let selectedProvider = providers.first ?? LoginProvider(
                    idpId: NVIDIAAuth.defaultIdpId,
                    code: "NVIDIA",
                    displayName: "NVIDIA",
                    streamingServiceUrl: NVIDIAAuth.defaultStreamingUrl,
                    priority: 0
                )

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
                try await persist(newSession)
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
        loginTask?.cancel()
        loginTask = nil
        loginPhase = .idle
    }

    // MARK: Logout

    func logout() {
        invalidateAuthenticationWork()
        session = nil
        loginPhase = .idle
        Task { try? await persistence.deleteAuthSession() }
    }

    /// Stops authentication work before Reset All Data removes credentials.
    /// The visible session remains available until cleanup finishes and logout
    /// performs the final UI transition.
    func prepareForDataReset() {
        invalidateAuthenticationWork()
    }

    private func invalidateAuthenticationWork() {
        credentialGeneration &+= 1
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
        guard var s = session else { throw AuthError.noSession }
        if s.tokens.isNearExpiry {
            s = try await refresh(session: s)
        }
        return preferredToken(in: s)
    }

    /// Returns a credential different from one rejected by the server. If another
    /// request already refreshed the session, reuse it instead of rotating again.
    func resolveToken(rejecting rejectedToken: String) async throws -> String {
        guard var s = session else { throw AuthError.noSession }
        let currentToken = preferredToken(in: s)
        if currentToken != rejectedToken {
            return currentToken
        }

        s = try await refresh(session: s)
        let refreshedToken = preferredToken(in: s)
        return refreshedToken == rejectedToken ? s.tokens.accessToken : refreshedToken
    }

    // MARK: Private

    private func preferredToken(in session: AuthSession) -> String {
        session.tokens.idToken ?? session.tokens.accessToken
    }

    func refreshIfNeeded() async {
        guard let s = session, s.tokens.isNearExpiry else { return }
        do {
            _ = try await refresh(session: s)
        } catch is CancellationError {
            return
        } catch {
            if s.tokens.isExpired {
                authLog.error("[Auth] Token expired and refresh failed: \(error, privacy: .private) — clearing session, re-login required")
                refreshTimer?.cancel()
                session = nil
                try? await persistence.deleteAuthSession()
            } else {
                authLog.warning("[Auth] Refresh failed but token still valid (\(Int(s.tokens.expiresAt.timeIntervalSinceNow), privacy: .public)s left) — keeping session")
            }
        }
    }

    private func refresh(session s: AuthSession) async throws -> AuthSession {
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

    private func performRefresh(session s: AuthSession, generation: Int) async throws -> AuthSession {
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
                clientTokenRefreshed = try await api.refreshWithClientToken(clientToken, userId: s.user.userId)
            } catch {
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
                ct = try await api.fetchClientToken(accessToken: idToken)
            } catch {
                authLog.error("[Auth] idToken bootstrap — fetchClientToken failed: \(error, privacy: .private)")
                throw AuthError.tokenRefreshFailed("All refresh mechanisms exhausted.")
            }
            do {
                rebound = try await api.refreshWithClientToken(ct.token, userId: s.user.userId)
            } catch {
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
            let ct = try await api.fetchClientToken(accessToken: updated.tokens.accessToken)
            authLog.info("[Auth] client_token re-bootstrapped, expires: \(String(describing: ct.expiresAt), privacy: .public)")
            updated.tokens.clientToken = ct.token
            updated.tokens.clientTokenExpiresAt = ct.expiresAt
        } catch {
            authLog.warning("[Auth] warning: failed to re-bootstrap client_token after refresh: \(error, privacy: .private)")
        }
        try Task.checkCancellation()
        guard credentialGeneration == generation else {
            throw CancellationError()
        }
        session = updated
        scheduleProactiveRefresh()
        scheduleBackgroundRefresh()
        try await persist(updated)
        return updated
    }

    // MARK: Proactive Refresh

    private func scheduleProactiveRefresh() {
        refreshTimer?.cancel()
        guard schedulesAutomaticRefresh else { return }
        guard let s = session else { return }
        let delay = s.tokens.expiresAt.timeIntervalSinceNow - (5 * 60)
        guard delay > 0 else {
            Task { await self.refreshIfNeeded() }
            return
        }
        refreshTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refreshIfNeeded()
        }
    }

    func scheduleBackgroundRefresh() {
        guard schedulesAutomaticRefresh else { return }
        guard let s = session else { return }
        backgroundScheduler.submit(
            Self.bgTaskID,
            s.tokens.expiresAt.addingTimeInterval(-(5 * 60))
        )
    }

    private func persist(_ s: AuthSession) async throws {
        try await persistence.saveAuthSession(s)
    }
}
