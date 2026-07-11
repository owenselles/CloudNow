import BackgroundTasks
import Foundation
import Observation
import os.log

private let authLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "Auth")

// MARK: - AuthSession (persisted)

struct AuthSession: Codable {
    var provider: LoginProvider
    var tokens: AuthTokens
    var user: AuthUser
}

// MARK: - Login Phase

enum LoginPhase: Equatable {
    case idle
    case showingPIN(code: String, url: String, urlComplete: String)
    case exchangingTokens
    case failed(String)
}

// MARK: - AuthManager

@Observable
@MainActor
final class AuthManager {
    private(set) var session: AuthSession?
    private(set) var loginPhase: LoginPhase = .idle

    var isAuthenticated: Bool {
        session != nil
    }

    private let api = NVIDIAAuthAPI()
    private var loginTask: Task<Void, Never>?
    private var activeRefreshTask: Task<AuthSession, Error>?
    private var refreshTimer: Task<Void, Never>?

    private static let bgTaskID = "com.owenselles.CloudNow.tokenRefresh"

    // MARK: Lifecycle

    func initialize() async {
        guard let stored = try? KeychainService.load(),
              let saved = try? JSONDecoder().decode(AuthSession.self, from: stored)
        else { return }
        session = saved
        scheduleProactiveRefresh()
        scheduleBackgroundRefresh()
        await refreshIfNeeded()
    }

    // MARK: Login (Device Flow)

    func login(with provider: LoginProvider? = nil) {
        loginTask?.cancel()
        loginTask = Task {
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

                // Request device authorization (get PIN)
                let deviceAuth = try await api.requestDeviceAuthorization(idpId: selectedProvider.idpId)
                loginPhase = .showingPIN(
                    code: deviceAuth.userCode,
                    url: deviceAuth.verificationUri
                        .replacingOccurrences(of: "https://", with: ""),
                    urlComplete: deviceAuth.verificationUriComplete
                )

                // Poll for user to complete login
                var tokens = try await api.pollForDeviceToken(
                    deviceCode: deviceAuth.deviceCode,
                    interval: deviceAuth.interval,
                    expiresIn: deviceAuth.expiresIn
                )
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
                        if tokens.refreshToken == nil { tokens.refreshToken = savedRefreshToken }
                        if tokens.idToken == nil { tokens.idToken = savedIdToken }
                        // Re-fetch clientToken for the re-bound session
                        if let ct2 = try? await api.fetchClientToken(accessToken: tokens.accessToken) {
                            tokens.clientToken = ct2.token
                            tokens.clientTokenExpiresAt = ct2.expiresAt
                        }
                    }
                }

                let newSession = AuthSession(provider: selectedProvider, tokens: tokens, user: user)
                session = newSession
                scheduleProactiveRefresh()
                scheduleBackgroundRefresh()
                try persist(newSession)
                loginPhase = .idle
            } catch is CancellationError {
                loginPhase = .idle
            } catch {
                loginPhase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        loginPhase = .idle
    }

    // MARK: Logout

    func logout() {
        refreshTimer?.cancel()
        session = nil
        loginPhase = .idle
        KeychainService.delete()
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
            let refreshed = try await refresh(session: s)
            session = refreshed
            try? persist(refreshed)
        } catch {
            if s.tokens.isExpired {
                authLog.error("[Auth] Token expired and refresh failed: \(error, privacy: .private) — clearing session, re-login required")
                refreshTimer?.cancel()
                session = nil
                KeychainService.delete()
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
        let task = Task<AuthSession, Error> { @MainActor [weak self] in
            guard let self else { throw AuthError.noSession }
            defer { self.activeRefreshTask = nil }
            return try await performRefresh(session: s)
        }
        activeRefreshTask = task
        return try await task.value
    }

    private func performRefresh(session s: AuthSession) async throws -> AuthSession {
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
            if updated.tokens.idToken == nil { updated.tokens.idToken = savedIdToken }
        } else if let refreshToken = s.tokens.refreshToken {
            authLog.warning("[Auth] client_token path unavailable or failed, falling back to refresh_token grant")
            let savedRefreshToken = updated.tokens.refreshToken
            let savedIdToken = updated.tokens.idToken
            updated.tokens = try await api.refreshTokens(refreshToken)
            if updated.tokens.refreshToken == nil {
                authLog.warning("[Auth] refresh_token grant did not return a new refreshToken — preserving previous one")
                updated.tokens.refreshToken = savedRefreshToken
            }
            if updated.tokens.idToken == nil { updated.tokens.idToken = savedIdToken }
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
            if updated.tokens.idToken == nil { updated.tokens.idToken = idToken }
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
        session = updated
        scheduleProactiveRefresh()
        scheduleBackgroundRefresh()
        try persist(updated)
        return updated
    }

    // MARK: Proactive Refresh

    private func scheduleProactiveRefresh() {
        refreshTimer?.cancel()
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
        guard let s = session else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskID)
        request.earliestBeginDate = s.tokens.expiresAt.addingTimeInterval(-(5 * 60))
        try? BGTaskScheduler.shared.submit(request)
    }

    private func persist(_ s: AuthSession) throws {
        let data = try JSONEncoder().encode(s)
        try KeychainService.save(data)
    }
}
