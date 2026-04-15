import Foundation
import Observation

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

    var isAuthenticated: Bool { session != nil }

    private let api = NVIDIAAuthAPI()
    private var loginTask: Task<Void, Never>?

    // MARK: Lifecycle

    func initialize() async {
        guard let stored = try? KeychainService.load(),
              let saved = try? JSONDecoder().decode(AuthSession.self, from: stored)
        else { return }
        session = saved
        await refreshIfNeeded()
    }

    // MARK: Login (Device Flow)

    func login(with provider: LoginProvider? = nil) {
        loginTask?.cancel()
        loginTask = Task {
            loginPhase = .idle
            do {
                let providers: [LoginProvider]
                if let provider {
                    providers = [provider]
                } else {
                    providers = (try? await api.fetchProviders()) ?? []
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
                        let savedRefreshToken = tokens.refreshToken   // preserve device-flow refreshToken
                        tokens = rebound
                        if tokens.refreshToken == nil { tokens.refreshToken = savedRefreshToken }
                        // Re-fetch clientToken for the re-bound session
                        if let ct2 = try? await api.fetchClientToken(accessToken: tokens.accessToken) {
                            tokens.clientToken = ct2.token
                            tokens.clientTokenExpiresAt = ct2.expiresAt
                        }
                    }
                }

                let newSession = AuthSession(provider: selectedProvider, tokens: tokens, user: user)
                session = newSession
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
        return s.tokens.idToken ?? s.tokens.accessToken
    }

    // MARK: Private

    private func refreshIfNeeded() async {
        guard let s = session, s.tokens.isNearExpiry else { return }
        do {
            let refreshed = try await refresh(session: s)
            session = refreshed
            try? persist(refreshed)
        } catch AuthError.tokenRefreshFailed {
            // Both clientToken and refreshToken are gone — the stored session is unusable.
            // Clear it so the login screen appears rather than silently producing bad sessions.
            print("[Auth] All tokens exhausted on launch — clearing session, re-login required")
            session = nil
            KeychainService.delete()
        } catch {
            // Network failures, server errors, etc. — keep the session and try again later.
        }
    }

    private func refresh(session s: AuthSession) async throws -> AuthSession {
        var updated = s
        // Primary: client_token grant (re-binds to clientID, works cross-client).
        // Skip if the stored clientToken is already past its expiry — treat it the same as absent.
        let clientTokenUsable = s.tokens.clientToken != nil &&
            (s.tokens.clientTokenExpiresAt.map { $0 > Date() } ?? true)
        if !clientTokenUsable {
            print("[Auth] clientToken absent or expired (expiresAt: \(s.tokens.clientTokenExpiresAt?.description ?? "nil")), skipping primary path")
        }
        if clientTokenUsable,
           let clientToken = s.tokens.clientToken,
           let refreshed = try? await api.refreshWithClientToken(clientToken, userId: s.user.userId) {
            print("[Auth] refresh via client_token grant succeeded")
            let savedRefreshToken = updated.tokens.refreshToken
            updated.tokens = refreshed
            if updated.tokens.refreshToken == nil {
                print("[Auth] client_token grant did not return a refreshToken — preserving previous one")
                updated.tokens.refreshToken = savedRefreshToken
            }
        } else if let refreshToken = s.tokens.refreshToken {
            print("[Auth] client_token path unavailable or failed, falling back to refresh_token grant")
            let savedRefreshToken = updated.tokens.refreshToken
            updated.tokens = try await api.refreshTokens(refreshToken)
            if updated.tokens.refreshToken == nil {
                print("[Auth] refresh_token grant did not return a new refreshToken — preserving previous one")
                updated.tokens.refreshToken = savedRefreshToken
            }
            print("[Auth] refresh via refresh_token grant succeeded")
        } else {
            // Neither path available — surface a real error so the UI can prompt re-login
            // instead of silently returning the expired token to callers.
            print("[Auth] refresh failed: no usable clientToken or refreshToken available")
            throw AuthError.tokenRefreshFailed("All refresh mechanisms exhausted.")
        }
        // Re-bootstrap client token
        if let ct = try? await api.fetchClientToken(accessToken: updated.tokens.accessToken) {
            print("[Auth] client_token re-bootstrapped, expires: \(ct.expiresAt)")
            updated.tokens.clientToken = ct.token
            updated.tokens.clientTokenExpiresAt = ct.expiresAt
        } else {
            print("[Auth] warning: failed to re-bootstrap client_token after refresh")
        }
        session = updated
        try persist(updated)
        return updated
    }

    private func persist(_ s: AuthSession) throws {
        let data = try JSONEncoder().encode(s)
        try KeychainService.save(data)
    }
}
