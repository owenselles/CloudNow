import CryptoKit
import Foundation
import Security

// MARK: - Constants

enum NVIDIAAuth {
    static let authEndpoint    = "https://login.nvidia.com/authorize"
    static let tokenEndpoint   = "https://login.nvidia.com/token"
    static let deviceAuthorizeEndpoint = "https://login.nvidia.com/device/authorize"
    static let clientTokenEndpoint = "https://login.nvidia.com/client_token"
    static let userinfoEndpoint = "https://login.nvidia.com/userinfo"
    static let serviceUrlsEndpoint = "https://pcs.geforcenow.com/v1/serviceUrls"

    static let clientID = "ZU7sPN-miLujMD95LfOQ453IB0AtjM8sMyvgJ9wCXEQ"
    static let deviceFlowClientID = "zp4TWyCwtbLiUfcG0_ecveyZEK1OlNiee-8qthakGn8"
    static let scopes   = "openid consent email tk_client age"
    static let defaultIdpId = "PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg"
    static let defaultStreamingUrl = "https://prod.cloudmatchbeta.nvidiagrid.net/"
    static let callbackScheme = "http"

    // Matches the official GFN PC client User-Agent so the NVIDIA backend accepts the token
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173"
}

// MARK: - PKCE Helpers

struct PKCE {
    let verifier: String
    let challenge: String

    static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(86)
        let verifierStr = String(verifier)
        let challengeData = SHA256.hash(data: Data(verifierStr.utf8))
        let challenge = Data(challengeData)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return PKCE(verifier: verifierStr, challenge: challenge)
    }
}

// MARK: - Keychain

enum KeychainService {
    private static let service = "com.owenselles.OpenTVPlay"
    private static let account = "gfn-auth-session"

    static func save(_ data: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
        let attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func load() throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.loadFailed(status)
        }
        return data
    }

    static func delete() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Error {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
    }
}

// MARK: - Response Models

struct AuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date
    var clientToken: String?
    var clientTokenExpiresAt: Date?

    var isExpired: Bool { expiresAt < Date() }
    var isNearExpiry: Bool { expiresAt.timeIntervalSinceNow < 10 * 60 }
}

struct AuthUser: Codable {
    let userId: String
    let displayName: String
    let email: String?
    let avatarUrl: String?
    var membershipTier: String
}

struct DeviceFlowResponse: Codable {
    let userCode: String
    let deviceCode: String
    let verificationUri: String
    let verificationUriComplete: String
    let expiresIn: Int
    let interval: Int
}

struct LoginProvider: Codable {
    let idpId: String
    let code: String
    let displayName: String
    var streamingServiceUrl: String
    let priority: Int
}

// MARK: - NVIDIA OAuth API

actor NVIDIAAuthAPI {
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": NVIDIAAuth.userAgent]
        return URLSession(configuration: config)
    }()

    // MARK: Providers

    func fetchProviders() async throws -> [LoginProvider] {
        var request = URLRequest(url: URL(string: NVIDIAAuth.serviceUrlsEndpoint)!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        let payload = try JSONDecoder().decode(ServiceUrlsResponse.self, from: data)
        let endpoints = payload.gfnServiceInfo?.gfnServiceEndpoints ?? []
        return endpoints.map { entry in
            LoginProvider(
                idpId: entry.idpId,
                code: entry.loginProviderCode,
                displayName: entry.loginProviderCode == "BPC" ? "bro.game" : entry.loginProviderDisplayName,
                streamingServiceUrl: entry.streamingServiceUrl.hasSuffix("/") ? entry.streamingServiceUrl : "\(entry.streamingServiceUrl)/",
                priority: entry.loginProviderPriority ?? 0
            )
        }.sorted { $0.priority < $1.priority }
    }

    // MARK: Token Exchange

    func exchangeCode(_ code: String, verifier: String, redirectURI: String) async throws -> AuthTokens {
        var request = URLRequest(url: URL(string: NVIDIAAuth.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://nvfile", forHTTPHeaderField: "Origin")
        request.setValue("https://nvfile/", forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let body = "grant_type=authorization_code&code=\(code)&redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectURI)&code_verifier=\(verifier)"
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "")
        }
        return try parseTokenResponse(data)
    }

    // MARK: Token Refresh

    func refreshTokens(_ refreshToken: String) async throws -> AuthTokens {
        var request = URLRequest(url: URL(string: NVIDIAAuth.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://nvfile", forHTTPHeaderField: "Origin")
        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(NVIDIAAuth.clientID)"
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.tokenRefreshFailed(String(data: data, encoding: .utf8) ?? "")
        }
        return try parseTokenResponse(data)
    }

    // MARK: Client Token

    func fetchClientToken(accessToken: String) async throws -> (token: String, expiresAt: Date) {
        var request = URLRequest(url: URL(string: NVIDIAAuth.clientTokenEndpoint)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("https://nvfile", forHTTPHeaderField: "Origin")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.clientTokenFailed
        }
        let payload = try JSONDecoder().decode(ClientTokenResponse.self, from: data)
        let expiresAt = Date().addingTimeInterval(TimeInterval(payload.expires_in ?? 86400))
        return (payload.client_token, expiresAt)
    }

    // MARK: Device Flow (PIN-based login)

    func requestDeviceAuthorization(idpId: String? = nil) async throws -> DeviceFlowResponse {
        var request = URLRequest(url: URL(string: NVIDIAAuth.deviceAuthorizeEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var params = "client_id=\(NVIDIAAuth.deviceFlowClientID)&scope=\(NVIDIAAuth.scopes.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? NVIDIAAuth.scopes)&device_id=\(UUID().uuidString)&display_name=Apple%20TV"
        if let idpId {
            params += "&idp_id=\(idpId)"
        }
        request.httpBody = params.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.deviceFlowFailed(String(data: data, encoding: .utf8) ?? "")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DeviceFlowResponse.self, from: data)
    }

    func pollForDeviceToken(deviceCode: String, interval: Int, expiresIn: Int) async throws -> AuthTokens {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        var pollInterval = TimeInterval(interval)

        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            try Task.checkCancellation()

            var request = URLRequest(url: URL(string: NVIDIAAuth.tokenEndpoint)!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let body = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&device_code=\(deviceCode)&client_id=\(NVIDIAAuth.deviceFlowClientID)"
            request.httpBody = body.data(using: .utf8)
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if statusCode == 200 {
                return try parseTokenResponse(data)
            }

            // Parse error response
            if let errorResp = try? JSONDecoder().decode(DeviceFlowErrorResponse.self, from: data) {
                switch errorResp.error {
                case "authorization_pending":
                    continue
                case "slow_down":
                    pollInterval += 5
                    continue
                case "expired_token":
                    throw AuthError.deviceFlowExpired
                case "access_denied":
                    throw AuthError.deviceFlowDenied
                default:
                    throw AuthError.deviceFlowFailed(errorResp.errorDescription ?? errorResp.error)
                }
            }
        }
        throw AuthError.deviceFlowExpired
    }

    // MARK: User Info

    func fetchUserInfo(tokens: AuthTokens) async throws -> AuthUser {
        // Try JWT payload first (fast path)
        let jwt = tokens.idToken ?? tokens.accessToken
        if let user = parseUserFromJWT(jwt) { return user }

        var request = URLRequest(url: URL(string: NVIDIAAuth.userinfoEndpoint)!)
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("https://nvfile", forHTTPHeaderField: "Origin")
        let (data, _) = try await session.data(for: request)
        let payload = try JSONDecoder().decode(UserinfoResponse.self, from: data)
        return AuthUser(
            userId: payload.sub,
            displayName: payload.preferred_username ?? payload.email?.components(separatedBy: "@").first ?? "User",
            email: payload.email,
            avatarUrl: nil,
            membershipTier: "FREE"
        )
    }

    // MARK: Private Helpers

    private func parseTokenResponse(_ data: Data) throws -> AuthTokens {
        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        return AuthTokens(
            accessToken: payload.access_token,
            refreshToken: payload.refresh_token,
            idToken: payload.id_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expires_in ?? 86400)),
            clientToken: nil,
            clientTokenExpiresAt: nil
        )
    }

    private func parseUserFromJWT(_ jwt: String) -> AuthUser? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(JWTPayload.self, from: data),
              let sub = payload.sub
        else { return nil }
        return AuthUser(
            userId: sub,
            displayName: payload.preferred_username ?? payload.email?.components(separatedBy: "@").first ?? "User",
            email: payload.email,
            avatarUrl: payload.picture,
            membershipTier: payload.gfn_tier ?? "FREE"
        )
    }

    nonisolated private func randomHex(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Codable Response Types

private struct ServiceUrlsResponse: Decodable {
    let gfnServiceInfo: GFNServiceInfo?
    struct GFNServiceInfo: Decodable {
        let gfnServiceEndpoints: [Endpoint]?
        struct Endpoint: Decodable {
            let idpId: String
            let loginProviderCode: String
            let loginProviderDisplayName: String
            let streamingServiceUrl: String
            let loginProviderPriority: Int?
        }
    }
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let expires_in: Int?
}

private struct ClientTokenResponse: Decodable {
    let client_token: String
    let expires_in: Int?
}

private struct UserinfoResponse: Decodable {
    let sub: String
    let preferred_username: String?
    let email: String?
}

private struct DeviceFlowErrorResponse: Decodable {
    let error: String
    let errorDescription: String?
    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private struct JWTPayload: Decodable {
    let sub: String?
    let email: String?
    let preferred_username: String?
    let picture: String?
    let gfn_tier: String?
}

// MARK: - Errors

enum AuthError: Error, LocalizedError {
    case noAuthCode
    case tokenExchangeFailed(String)
    case tokenRefreshFailed(String)
    case clientTokenFailed
    case noSession
    case deviceFlowFailed(String)
    case deviceFlowExpired
    case deviceFlowDenied

    var errorDescription: String? {
        switch self {
        case .noAuthCode: return "No authorization code received."
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .tokenRefreshFailed(let msg): return "Token refresh failed: \(msg)"
        case .clientTokenFailed: return "Failed to obtain client token."
        case .noSession: return "No authenticated session."
        case .deviceFlowFailed(let msg): return "Device login failed: \(msg)"
        case .deviceFlowExpired: return "Login code expired. Please try again."
        case .deviceFlowDenied: return "Login was denied."
        }
    }
}
