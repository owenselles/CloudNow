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
                        tokens = rebound
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
        if let refreshed = try? await refresh(session: s) {
            session = refreshed
            try? persist(refreshed)
        }
    }

    private func refresh(session s: AuthSession) async throws -> AuthSession {
        var updated = s
        // Primary: client_token grant (re-binds to clientID, works cross-client)
        if let clientToken = s.tokens.clientToken,
           let refreshed = try? await api.refreshWithClientToken(clientToken, userId: s.user.userId) {
            updated.tokens = refreshed
        } else if let refreshToken = s.tokens.refreshToken {
            // Fallback: standard refresh_token grant
            updated.tokens = try await api.refreshTokens(refreshToken)
        }
        // Re-bootstrap client token
        if let ct = try? await api.fetchClientToken(accessToken: updated.tokens.accessToken) {
            updated.tokens.clientToken = ct.token
            updated.tokens.clientTokenExpiresAt = ct.expiresAt
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
