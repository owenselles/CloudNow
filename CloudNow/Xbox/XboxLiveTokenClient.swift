import Foundation

/// Stateless client for Microsoft's documented Microsoft Account -> Xbox User
/// Token -> XSTS exchange. The caller owns all credential lifetime decisions.
nonisolated struct XboxLiveTokenClient: Sendable {
    private let configuration: XboxLiveAuthorizationConfiguration
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    init(
        configuration: XboxLiveAuthorizationConfiguration,
        transport: any HTTPTransport = URLSessionHTTPTransport(configuration: .ephemeral),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.now = now
    }

    func requestUserToken(microsoftAccessToken: String) async throws -> XboxUserToken {
        let normalizedAccessToken = microsoftAccessToken.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedAccessToken.isEmpty,
              normalizedAccessToken.utf8.count <= 131_072
        else {
            throw XboxLiveAuthorizationError.invalidMicrosoftToken
        }

        let payload = XboxUserAuthenticationRequest(
            relyingParty: configuration.userTokenRelyingParty.identifier,
            tokenType: "JWT",
            properties: XboxUserAuthenticationRequest.Properties(
                authMethod: "RPS",
                siteName: "user.auth.xboxlive.com",
                rpsTicket: "d=\(normalizedAccessToken)"
            )
        )
        let data = try Self.encode(payload)
        let responseData = try await post(
            data,
            to: configuration.userAuthenticationEndpoint
        )
        let response = try parseTokenResponse(responseData)
        return XboxUserToken(
            token: response.token,
            userHash: response.userHash,
            expiresAt: response.expiresAt
        )
    }

    func requestXSTSCredential(
        userToken: XboxUserToken,
        relyingParty: XboxLiveRelyingParty
    ) async throws -> XboxXSTSCredential {
        guard userToken.expiresAt > now(),
              !userToken.token.isEmpty,
              !userToken.userHash.isEmpty
        else {
            throw XboxLiveAuthorizationError.credentialExpired
        }

        let payload = XboxXSTSAuthorizationRequest(
            properties: XboxXSTSAuthorizationRequest.Properties(
                sandboxID: configuration.sandboxID,
                userTokens: [userToken.token]
            ),
            relyingParty: relyingParty.identifier,
            tokenType: "JWT"
        )
        let data = try Self.encode(payload)
        let responseData = try await post(
            data,
            to: configuration.xstsAuthorizationEndpoint
        )
        let response = try parseTokenResponse(responseData)
        guard response.userHash == userToken.userHash else {
            throw XboxLiveAuthorizationError.invalidPayload
        }
        return XboxXSTSCredential(
            token: response.token,
            userHash: response.userHash,
            relyingParty: relyingParty,
            expiresAt: response.expiresAt,
            gamertag: response.gamertag
        )
    }

    private func post(_ body: Data, to endpoint: URL) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.contractVersion, forHTTPHeaderField: "x-xbl-contract-version")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let data: Data
        let response: URLResponse
        do {
            try Task.checkCancellation()
            (data, response) = try await transport.data(for: request)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw XboxLiveAuthorizationError.transportFailure
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw XboxLiveAuthorizationError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw XboxLiveAuthorizationError.service(
                statusCode: httpResponse.statusCode,
                xboxErrorCode: Self.xboxErrorCode(from: data)
            )
        }
        return data
    }

    private func parseTokenResponse(_ data: Data) throws -> ParsedXboxTokenResponse {
        guard data.count <= 262_144,
              let payload = try? JSONDecoder().decode(XboxTokenResponse.self, from: data),
              payload.token.utf8.count <= 131_072,
              !payload.token.isEmpty,
              let identity = payload.displayClaims.xui.first,
              !identity.userHash.isEmpty,
              identity.userHash.utf8.count <= 512,
              identity.gamertag?.utf8.count ?? 0 <= 256,
              let expiresAt = Self.parseISO8601(payload.notAfter),
              expiresAt > now()
        else {
            throw XboxLiveAuthorizationError.invalidPayload
        }
        return ParsedXboxTokenResponse(
            token: payload.token,
            userHash: identity.userHash,
            expiresAt: expiresAt,
            gamertag: identity.gamertag
        )
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw XboxLiveAuthorizationError.invalidPayload
        }
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func xboxErrorCode(from data: Data) -> UInt64? {
        guard data.count <= 65536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["XErr"]
        else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        if let string = value as? String {
            return UInt64(string)
        }
        return nil
    }
}

private nonisolated struct ParsedXboxTokenResponse: Sendable {
    let token: String
    let userHash: String
    let expiresAt: Date
    let gamertag: String?
}

private nonisolated struct XboxUserAuthenticationRequest: Encodable {
    struct Properties: Encodable {
        let authMethod: String
        let siteName: String
        let rpsTicket: String

        enum CodingKeys: String, CodingKey {
            case authMethod = "AuthMethod"
            case siteName = "SiteName"
            case rpsTicket = "RpsTicket"
        }
    }

    let relyingParty: String
    let tokenType: String
    let properties: Properties

    enum CodingKeys: String, CodingKey {
        case relyingParty = "RelyingParty"
        case tokenType = "TokenType"
        case properties = "Properties"
    }
}

private nonisolated struct XboxXSTSAuthorizationRequest: Encodable {
    struct Properties: Encodable {
        let sandboxID: String
        let userTokens: [String]

        enum CodingKeys: String, CodingKey {
            case sandboxID = "SandboxId"
            case userTokens = "UserTokens"
        }
    }

    let properties: Properties
    let relyingParty: String
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case properties = "Properties"
        case relyingParty = "RelyingParty"
        case tokenType = "TokenType"
    }
}

private nonisolated struct XboxTokenResponse: Decodable {
    struct DisplayClaims: Decodable {
        struct Identity: Decodable {
            let userHash: String
            let gamertag: String?

            enum CodingKeys: String, CodingKey {
                case userHash = "uhs"
                case gamertag = "gtg"
            }
        }

        let xui: [Identity]
    }

    let notAfter: String
    let token: String
    let displayClaims: DisplayClaims

    enum CodingKeys: String, CodingKey {
        case notAfter = "NotAfter"
        case token = "Token"
        case displayClaims = "DisplayClaims"
    }
}
