import Foundation

/// Configuration for Microsoft's public OAuth 2.0 device authorization flow.
///
/// The caller supplies a public-client identifier and scopes. This generic OAuth
/// layer does not infer Xbox identity, entitlement, or streaming authorization.
nonisolated struct MicrosoftDeviceCodeOAuthConfiguration: Equatable, Sendable, CustomStringConvertible {
    let tenant: String
    let clientID: String
    let scopes: [String]
    let deviceAuthorizationEndpoint: URL
    let tokenEndpoint: URL

    init(tenant: String, clientID: String, scopes: [String]) throws {
        let normalizedTenant = tenant.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedScopes = scopes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard Self.isValidTenant(normalizedTenant) else {
            throw MicrosoftDeviceCodeOAuthError.invalidConfiguration("Microsoft tenant is invalid.")
        }
        guard !normalizedClientID.isEmpty,
              normalizedClientID.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else {
            throw MicrosoftDeviceCodeOAuthError.invalidConfiguration("Microsoft client identifier is missing or invalid.")
        }
        guard !normalizedScopes.isEmpty,
              normalizedScopes.allSatisfy(Self.isValidScope)
        else {
            throw MicrosoftDeviceCodeOAuthError.invalidConfiguration("At least one valid Microsoft OAuth scope is required.")
        }

        self.tenant = normalizedTenant
        self.clientID = normalizedClientID
        self.scopes = normalizedScopes
        deviceAuthorizationEndpoint = try Self.endpoint(
            tenant: normalizedTenant,
            operation: "devicecode"
        )
        tokenEndpoint = try Self.endpoint(
            tenant: normalizedTenant,
            operation: "token"
        )
    }

    var description: String {
        "MicrosoftDeviceCodeOAuthConfiguration(tenant: \(tenant), clientID: <redacted>, scopes: \(scopes.count))"
    }

    private static func endpoint(tenant: String, operation: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "login.microsoftonline.com"
        components.path = "/\(tenant)/oauth2/v2.0/\(operation)"
        guard let url = components.url else {
            throw MicrosoftDeviceCodeOAuthError.invalidConfiguration("Microsoft OAuth endpoint could not be constructed.")
        }
        return url
    }

    private static func isValidTenant(_ tenant: String) -> Bool {
        guard !tenant.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        return tenant.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isValidScope(_ scope: String) -> Bool {
        guard !scope.isEmpty else { return false }
        return scope.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}

/// User-facing values returned by Microsoft's device authorization endpoint.
nonisolated struct MicrosoftDeviceAuthorization: Equatable, Sendable, CustomStringConvertible {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let verificationURIComplete: URL?
    let expiresAt: Date
    let pollingInterval: TimeInterval
    let message: String?

    var qrVerificationURI: URL {
        if let verificationURIComplete {
            return verificationURIComplete
        }

        guard var components = URLComponents(url: verificationURI, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "www.microsoft.com",
              components.path == "/link",
              components.user == nil,
              components.password == nil,
              components.port == nil
        else {
            return verificationURI
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.caseInsensitiveCompare("otc") == .orderedSame }
        queryItems.append(URLQueryItem(name: "otc", value: userCode))
        components.queryItems = queryItems
        return components.url ?? verificationURI
    }

    var description: String {
        "MicrosoftDeviceAuthorization(deviceCode: <redacted>, userCode: <redacted>, verificationURI: \(verificationURI), expiresAt: \(expiresAt), pollingInterval: \(pollingInterval))"
    }
}

/// OAuth credentials returned by Microsoft. Descriptions never expose token material.
nonisolated struct MicrosoftOAuthToken: Codable, Equatable, Sendable, CustomStringConvertible {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String
    let scopes: [String]
    let expiresAt: Date

    var description: String {
        "MicrosoftOAuthToken(accessToken: <redacted>, refreshToken: \(refreshToken == nil ? "nil" : "<redacted>"), idToken: \(idToken == nil ? "nil" : "<redacted>"), tokenType: \(tokenType), scopes: \(scopes.count), expiresAt: \(expiresAt))"
    }
}

/// Observable milestones for a device-code sign-in attempt. Token material is never retained here.
nonisolated enum MicrosoftDeviceCodeState: Equatable, Sendable, CustomStringConvertible {
    case idle
    case requestingCode
    case awaitingUser(MicrosoftDeviceAuthorization)
    case polling(attempt: Int)
    case authorized
    case declined
    case expired
    case cancelled
    case failed(MicrosoftDeviceCodeOAuthError)

    var description: String {
        switch self {
        case .idle: "idle"
        case .requestingCode: "requestingCode"
        case .awaitingUser: "awaitingUser(<redacted>)"
        case let .polling(attempt): "polling(attempt: \(attempt))"
        case .authorized: "authorized"
        case .declined: "declined"
        case .expired: "expired"
        case .cancelled: "cancelled"
        case let .failed(error): "failed(\(error))"
        }
    }
}

nonisolated enum MicrosoftDeviceCodeOAuthError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration(String)
    case invalidResponse
    case responseTooLarge
    case invalidPayload
    case httpFailure(statusCode: Int)
    case server(statusCode: Int, code: String)
    case authorizationDeclined
    case authorizationExpired
    case transportFailure

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message): message
        case .invalidResponse: "Microsoft OAuth returned an invalid HTTP response."
        case .responseTooLarge: "Microsoft OAuth returned too much data."
        case .invalidPayload: "Microsoft OAuth returned an invalid response payload."
        case let .httpFailure(statusCode): "Microsoft OAuth request failed with HTTP \(statusCode)."
        case let .server(statusCode, code): "Microsoft OAuth request failed with \(code) (HTTP \(statusCode))."
        case .authorizationDeclined: "Microsoft sign-in was declined."
        case .authorizationExpired: "Microsoft sign-in code expired. Please try again."
        case .transportFailure: "Microsoft OAuth request could not be completed."
        }
    }

    var invalidatesPersistedCredentials: Bool {
        guard case let .server(_, code) = self else { return false }
        return code.caseInsensitiveCompare("invalid_grant") == .orderedSame
    }
}

/// Generic, dependency-free client for Microsoft's documented device-code endpoints.
/// It does not implement Xbox authentication, catalog, session, or streaming behavior.
actor MicrosoftDeviceCodeOAuthClient {
    private static let maximumResponseSize = 262_144

    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    init(
        transport: any HTTPTransport = URLSessionHTTPTransport(configuration: .ephemeral),
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    func authenticate(
        configuration: MicrosoftDeviceCodeOAuthConfiguration,
        onState: @escaping @Sendable (MicrosoftDeviceCodeState) async -> Void = { _ in }
    ) async throws -> MicrosoftOAuthToken {
        do {
            await onState(.requestingCode)
            let authorization = try await requestAuthorization(configuration: configuration)
            await onState(.awaitingUser(authorization))
            let token = try await pollForToken(
                configuration: configuration,
                authorization: authorization,
                onState: onState
            )
            await onState(.authorized)
            return token
        } catch is CancellationError {
            await onState(.cancelled)
            throw CancellationError()
        } catch let error as MicrosoftDeviceCodeOAuthError {
            switch error {
            case .authorizationDeclined:
                await onState(.declined)
            case .authorizationExpired:
                await onState(.expired)
            default:
                await onState(.failed(error))
            }
            throw error
        } catch {
            await onState(.failed(.transportFailure))
            throw error
        }
    }

    func requestAuthorization(
        configuration: MicrosoftDeviceCodeOAuthConfiguration
    ) async throws -> MicrosoftDeviceAuthorization {
        var request = URLRequest(url: configuration.deviceAuthorizationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formURLEncoded([
            ("client_id", configuration.clientID),
            ("scope", configuration.scopes.joined(separator: " ")),
        ])

        let (data, response) = try await perform(request)
        let statusCode = try statusCode(from: response)
        guard (200 ..< 300).contains(statusCode) else {
            throw Self.oauthError(from: data, statusCode: statusCode)
        }

        guard let payload = try? JSONDecoder().decode(DeviceAuthorizationPayload.self, from: data),
              !payload.deviceCode.isEmpty,
              !payload.userCode.isEmpty,
              payload.expiresIn > 0,
              (1 ... 3600).contains(payload.interval ?? 5),
              let verificationURI = Self.secureURL(from: payload.verificationURI)
        else {
            throw MicrosoftDeviceCodeOAuthError.invalidPayload
        }
        let verificationURIComplete = try Self.optionalSecureURL(from: payload.verificationURIComplete)

        return MicrosoftDeviceAuthorization(
            deviceCode: payload.deviceCode,
            userCode: payload.userCode,
            verificationURI: verificationURI,
            verificationURIComplete: verificationURIComplete,
            expiresAt: now().addingTimeInterval(TimeInterval(payload.expiresIn)),
            pollingInterval: TimeInterval(payload.interval ?? 5),
            message: payload.message
        )
    }

    func pollForToken(
        configuration: MicrosoftDeviceCodeOAuthConfiguration,
        authorization: MicrosoftDeviceAuthorization,
        onState: @escaping @Sendable (MicrosoftDeviceCodeState) async -> Void = { _ in }
    ) async throws -> MicrosoftOAuthToken {
        var pollingInterval = authorization.pollingInterval
        var attempt = 0

        while now() < authorization.expiresAt {
            try Task.checkCancellation()
            attempt += 1
            await onState(.polling(attempt: attempt))
            let remainingLifetime = authorization.expiresAt.timeIntervalSince(now())
            guard remainingLifetime > 0 else {
                throw MicrosoftDeviceCodeOAuthError.authorizationExpired
            }
            try await sleep(min(pollingInterval, remainingLifetime))
            try Task.checkCancellation()
            guard now() < authorization.expiresAt else {
                throw MicrosoftDeviceCodeOAuthError.authorizationExpired
            }

            switch try await requestToken(
                configuration: configuration,
                deviceCode: authorization.deviceCode
            ) {
            case let .token(token):
                return token
            case .authorizationPending:
                continue
            case .slowDown:
                pollingInterval += 5
            }
        }

        throw MicrosoftDeviceCodeOAuthError.authorizationExpired
    }

    func refreshToken(
        configuration: MicrosoftDeviceCodeOAuthConfiguration,
        refreshToken: String
    ) async throws -> MicrosoftOAuthToken {
        guard !refreshToken.isEmpty else {
            throw MicrosoftDeviceCodeOAuthError.invalidConfiguration("Microsoft refresh token is missing.")
        }

        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formURLEncoded([
            ("client_id", configuration.clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("scope", configuration.scopes.joined(separator: " ")),
        ])

        let (data, response) = try await perform(request)
        let statusCode = try statusCode(from: response)
        guard (200 ..< 300).contains(statusCode) else {
            throw Self.oauthError(from: data, statusCode: statusCode)
        }
        return try parseToken(
            data,
            fallbackScopes: configuration.scopes,
            fallbackRefreshToken: refreshToken
        )
    }

    private func requestToken(
        configuration: MicrosoftDeviceCodeOAuthConfiguration,
        deviceCode: String
    ) async throws -> TokenPollResult {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formURLEncoded([
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ("client_id", configuration.clientID),
            ("device_code", deviceCode),
        ])

        let (data, response) = try await perform(request)
        let statusCode = try statusCode(from: response)
        if (200 ..< 300).contains(statusCode) {
            return try .token(parseToken(data, fallbackScopes: configuration.scopes))
        }

        guard let payload = try? JSONDecoder().decode(OAuthErrorPayload.self, from: data) else {
            throw MicrosoftDeviceCodeOAuthError.httpFailure(statusCode: statusCode)
        }
        switch payload.error {
        case "authorization_pending":
            return .authorizationPending
        case "slow_down":
            return .slowDown
        case "authorization_declined", "access_denied":
            throw MicrosoftDeviceCodeOAuthError.authorizationDeclined
        case "expired_token":
            throw MicrosoftDeviceCodeOAuthError.authorizationExpired
        default:
            throw MicrosoftDeviceCodeOAuthError.server(
                statusCode: statusCode,
                code: Self.sanitizedErrorCode(payload.error)
            )
        }
    }

    private func parseToken(
        _ data: Data,
        fallbackScopes: [String],
        fallbackRefreshToken: String? = nil
    ) throws -> MicrosoftOAuthToken {
        guard let payload = try? JSONDecoder().decode(TokenPayload.self, from: data),
              !payload.accessToken.isEmpty,
              payload.expiresIn > 0
        else {
            throw MicrosoftDeviceCodeOAuthError.invalidPayload
        }
        let scopes = payload.scope?
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init) ?? fallbackScopes
        return MicrosoftOAuthToken(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken ?? fallbackRefreshToken,
            idToken: payload.idToken,
            tokenType: payload.tokenType ?? "Bearer",
            scopes: scopes,
            expiresAt: now().addingTimeInterval(TimeInterval(payload.expiresIn))
        )
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let result: (Data, URLResponse)
        do {
            result = try await transport.data(
                for: request,
                maximumResponseSize: Self.maximumResponseSize
            )
        } catch HTTPTransportError.responseTooLarge {
            throw MicrosoftDeviceCodeOAuthError.responseTooLarge
        }
        try Task.checkCancellation()
        return result
    }

    private func statusCode(from response: URLResponse) throws -> Int {
        guard let response = response as? HTTPURLResponse else {
            throw MicrosoftDeviceCodeOAuthError.invalidResponse
        }
        return response.statusCode
    }

    private nonisolated static func secureURL(from value: String) -> URL? {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else {
            return nil
        }
        return url
    }

    private nonisolated static func optionalSecureURL(from value: String?) throws -> URL? {
        guard let value else { return nil }
        guard let url = secureURL(from: value) else {
            throw MicrosoftDeviceCodeOAuthError.invalidPayload
        }
        return url
    }

    private nonisolated static func oauthError(
        from data: Data,
        statusCode: Int
    ) -> MicrosoftDeviceCodeOAuthError {
        guard let payload = try? JSONDecoder().decode(OAuthErrorPayload.self, from: data) else {
            return .httpFailure(statusCode: statusCode)
        }
        return .server(statusCode: statusCode, code: sanitizedErrorCode(payload.error))
    }

    private nonisolated static func sanitizedErrorCode(_ code: String) -> String {
        let normalized = code.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        guard !normalized.isEmpty,
              normalized.count <= 64,
              normalized.unicodeScalars.allSatisfy(allowed.contains)
        else {
            return "unknown_error"
        }
        return normalized
    }

    private nonisolated static func formURLEncoded(_ fields: [(String, String)]) -> Data {
        let body = fields.map { name, value in
            "\(formComponent(name))=\(formComponent(value))"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private nonisolated static func formComponent(_ value: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 48 ... 57, 65 ... 90, 97 ... 122, 45, 46, 95, 126:
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            case 32:
                encoded.append("+")
            default:
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded
    }
}

private nonisolated enum TokenPollResult {
    case token(MicrosoftOAuthToken)
    case authorizationPending
    case slowDown
}

private nonisolated struct DeviceAuthorizationPayload: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let verificationURIComplete: String?
    let expiresIn: Int
    let interval: Int?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
        case message
    }
}

private nonisolated struct TokenPayload: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String?
    let scope: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
    }
}

private nonisolated struct OAuthErrorPayload: Decodable {
    let error: String
}
