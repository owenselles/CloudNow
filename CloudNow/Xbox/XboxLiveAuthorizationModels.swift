import Foundation

/// Xbox service audience used when requesting an XSTS credential.
///
/// Audience URIs are identifiers, not transport endpoints, so Microsoft's
/// first-party values intentionally include both `http` and `rp` schemes.
nonisolated struct XboxLiveRelyingParty: Equatable, Hashable, Sendable, CustomStringConvertible {
    static let userAuthentication = XboxLiveRelyingParty(
        trustedIdentifier: "http://auth.xboxlive.com"
    )
    static let xboxLive = XboxLiveRelyingParty(
        trustedIdentifier: "http://xboxlive.com"
    )
    static let cloudGaming = XboxLiveRelyingParty(
        trustedIdentifier: "http://gssv.xboxlive.com/"
    )
    static let cloudGamingWebPortal = XboxLiveRelyingParty(
        trustedIdentifier: "rp://gswp.xboxlive.com/"
    )
    static let contentAccess = XboxLiveRelyingParty(
        trustedIdentifier: "http://mp.microsoft.com/"
    )

    let identifier: String

    init(identifier: String) throws {
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedIdentifier.utf8.count <= 512,
              let components = URLComponents(string: normalizedIdentifier),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "rp"].contains(scheme),
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw XboxLiveAuthorizationError.invalidConfiguration(
                "Xbox relying party is invalid."
            )
        }
        self.identifier = normalizedIdentifier
    }

    var description: String {
        identifier
    }

    private init(trustedIdentifier: String) {
        identifier = trustedIdentifier
    }
}

/// Microsoft-owned endpoints and request values for Xbox User Token and XSTS
/// exchange. Tests and future service adapters can inject an alternate endpoint
/// set without scattering production constants through the app.
nonisolated struct XboxLiveAuthorizationConfiguration: Equatable, Sendable {
    let userAuthenticationEndpoint: URL
    let xstsAuthorizationEndpoint: URL
    let userTokenRelyingParty: XboxLiveRelyingParty
    let contractVersion: String
    let sandboxID: String

    init(
        userAuthenticationEndpoint: URL,
        xstsAuthorizationEndpoint: URL,
        userTokenRelyingParty: XboxLiveRelyingParty = .userAuthentication,
        contractVersion: String = "1",
        sandboxID: String = "RETAIL"
    ) throws {
        guard Self.isSecureEndpoint(userAuthenticationEndpoint),
              Self.isSecureEndpoint(xstsAuthorizationEndpoint)
        else {
            throw XboxLiveAuthorizationError.invalidConfiguration(
                "Xbox authentication endpoints must be credential-free HTTPS URLs."
            )
        }

        let normalizedContractVersion = contractVersion.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedContractVersion.isEmpty,
              normalizedContractVersion.utf8.count <= 8,
              normalizedContractVersion.allSatisfy(\.isNumber)
        else {
            throw XboxLiveAuthorizationError.invalidConfiguration(
                "Xbox contract version is invalid."
            )
        }

        let normalizedSandboxID = sandboxID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedSandboxCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._")
        )
        guard !normalizedSandboxID.isEmpty,
              normalizedSandboxID.utf8.count <= 64,
              normalizedSandboxID.unicodeScalars.allSatisfy(allowedSandboxCharacters.contains)
        else {
            throw XboxLiveAuthorizationError.invalidConfiguration(
                "Xbox sandbox identifier is invalid."
            )
        }

        self.userAuthenticationEndpoint = userAuthenticationEndpoint
        self.xstsAuthorizationEndpoint = xstsAuthorizationEndpoint
        self.userTokenRelyingParty = userTokenRelyingParty
        self.contractVersion = normalizedContractVersion
        self.sandboxID = normalizedSandboxID
    }

    /// Values documented and operated by Microsoft for Xbox web authentication.
    static func microsoftProduction() throws -> XboxLiveAuthorizationConfiguration {
        guard let userAuthenticationEndpoint = URL(
            string: "https://user.auth.xboxlive.com/user/authenticate"
        ),
            let xstsAuthorizationEndpoint = URL(
                string: "https://xsts.auth.xboxlive.com/xsts/authorize"
            )
        else {
            throw XboxLiveAuthorizationError.invalidConfiguration(
                "Microsoft Xbox authentication endpoints could not be constructed."
            )
        }
        return try XboxLiveAuthorizationConfiguration(
            userAuthenticationEndpoint: userAuthenticationEndpoint,
            xstsAuthorizationEndpoint: xstsAuthorizationEndpoint
        )
    }

    private static func isSecureEndpoint(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 2048,
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else {
            return false
        }
        return true
    }
}

/// Short-lived Xbox User Token. This type deliberately has no Codable
/// conformance so the intermediate credential is not accidentally persisted.
nonisolated struct XboxUserToken: Equatable, Sendable, CustomStringConvertible {
    let token: String
    let userHash: String
    let expiresAt: Date

    var description: String {
        "XboxUserToken(token: <redacted>, userHash: <redacted>, expiresAt: \(expiresAt))"
    }
}

/// Short-lived XSTS credential scoped to exactly one relying party. It remains
/// memory-only and is retrieved by provider clients immediately before a call.
nonisolated struct XboxXSTSCredential: Equatable, Sendable, CustomStringConvertible {
    let token: String
    let userHash: String
    let relyingParty: XboxLiveRelyingParty
    let expiresAt: Date
    let gamertag: String?

    var authorizationHeaderValue: String {
        "XBL3.0 x=\(userHash);\(token)"
    }

    func isUsable(at date: Date, minimumLifetime: TimeInterval = 30) -> Bool {
        expiresAt.timeIntervalSince(date) > minimumLifetime
    }

    var description: String {
        "XboxXSTSCredential(token: <redacted>, userHash: <redacted>, relyingParty: \(relyingParty), expiresAt: \(expiresAt), gamertag: \(gamertag == nil ? "nil" : "<redacted>"))"
    }
}

nonisolated enum XboxLiveAuthorizationError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration(String)
    case invalidMicrosoftToken
    case microsoftTokenExpired
    case invalidResponse
    case invalidPayload
    case service(statusCode: Int, xboxErrorCode: UInt64?)
    case transportFailure
    case accountNotAuthorized
    case credentialUnavailable(XboxLiveRelyingParty)
    case credentialExpired

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            message
        case .invalidMicrosoftToken:
            "Microsoft sign-in returned an invalid access token."
        case .microsoftTokenExpired:
            "Microsoft sign-in expired. Please sign in again."
        case .invalidResponse:
            "Xbox authentication returned an invalid HTTP response."
        case .invalidPayload:
            "Xbox authentication returned an invalid response payload."
        case let .service(statusCode, xboxErrorCode):
            if let xboxErrorCode {
                "Xbox authentication failed with service error \(xboxErrorCode) (HTTP \(statusCode))."
            } else {
                "Xbox authentication failed with HTTP \(statusCode)."
            }
        case .transportFailure:
            "Xbox authentication could not be completed."
        case .accountNotAuthorized:
            "The Xbox account authorization is no longer available."
        case let .credentialUnavailable(relyingParty):
            "No Xbox credential is available for \(relyingParty.identifier)."
        case .credentialExpired:
            "Xbox authorization expired. Please sign in again."
        }
    }
}
