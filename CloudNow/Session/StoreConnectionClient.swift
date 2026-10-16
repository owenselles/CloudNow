import Foundation

nonisolated struct StoreConnection: Identifiable, Sendable, Equatable {
    let code: String
    let displayName: String
    let accountDisplayName: String?
    let iconURL: URL?
    let isConnected: Bool
    let requiresReconnect: Bool
    let supportsLinking: Bool
    let supportsSync: Bool
    let supportsAutomaticSignIn: Bool
    let isExpired: Bool
    let sortOrder: Int
    let snapshot: ProviderSyncSnapshot?

    var id: String {
        code
    }
}

nonisolated struct StoreDeviceAuthorization: Sendable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let verificationURLComplete: URL
    let expiresIn: TimeInterval
    let interval: TimeInterval
}

nonisolated enum StoreAuthorizationStatus: Sendable, Equatable {
    case pending
    case slowDown
    case authorized
}

nonisolated protocol StoreConnectionClient: Sendable {
    func discoverStores(token: String, userId: String) async throws -> [StoreConnection]
    func requestAuthorization(providerCode: String, token: String) async throws -> StoreDeviceAuthorization
    func pollAuthorization(deviceCode: String) async throws -> StoreAuthorizationStatus
    func disconnect(providerCode: String, token: String) async throws
}

nonisolated enum StoreConnectionError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: TimeInterval?)
    case httpStatus(Int)
    case schema
    case network
    case networkAmbiguous
    case expired
    case denied
}

/// ALS account linking uses its own OAuth client identifier, independently of LCARS.
nonisolated struct StoreConnectionContract: Sendable {
    let alsBaseURL: URL
    let clientId: String

    static let live = Self(
        alsBaseURL: LibrarySyncContract.live.alsBaseURL,
        // Match the PC identity already used by NVIDIAAuth.
        clientId: "gfn-pc"
    )
}

actor GFNStoreConnectionClient {
    private let transport: any HTTPTransport
    private let contract: StoreConnectionContract
    private let libraryClient: GFNLibrarySyncClient

    init(
        transport: any HTTPTransport = URLSessionHTTPTransport(configuration: .ephemeral),
        contract: StoreConnectionContract = .live,
        libraryContract: LibrarySyncContract = .live,
        localeCode: @escaping @Sendable () -> String = { L10n.nvidiaLocaleCode() },
        currentDate: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.contract = contract
        libraryClient = GFNLibrarySyncClient(
            transport: transport,
            contract: libraryContract,
            localeCode: localeCode,
            currentDate: currentDate
        )
    }

    func discoverStores(token: String, userId: String) async throws -> [StoreConnection] {
        try await libraryClient.discoverStores(token: token, userId: userId)
    }

    func requestAuthorization(providerCode: String, token: String) async throws -> StoreDeviceAuthorization {
        let provider = try normalizedProviderCode(providerCode)
        let request = try makeRequest(
            path: "login_url",
            method: "POST",
            token: token,
            body: ["platform": provider, "client_id": contract.clientId]
        )
        let (data, response) = try await perform(request, ambiguousOnFailure: true)
        try validate(response)
        guard let payload = try? JSONDecoder().decode(AuthorizationPayload.self, from: data),
              !payload.deviceCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              payload.deviceCode.utf8.count <= 4096,
              !payload.userCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              payload.userCode.utf8.count <= 128,
              payload.expiresIn.isFinite, (1 ... 3600).contains(payload.expiresIn),
              payload.interval.isFinite, (1 ... 60).contains(payload.interval),
              payload.interval < payload.expiresIn,
              let completeURL = validatedVerificationURL(payload.verificationURIComplete),
              !payload.verificationURIComplete.contains(token),
              !payload.verificationURIComplete.contains(payload.deviceCode),
              let verificationURL = validatedVerificationURL(payload.verificationURI ?? "https://gfn.link/connect")
        else {
            throw StoreConnectionError.schema
        }
        return StoreDeviceAuthorization(
            deviceCode: payload.deviceCode,
            userCode: payload.userCode,
            verificationURL: verificationURL,
            verificationURLComplete: completeURL,
            expiresIn: payload.expiresIn,
            interval: payload.interval
        )
    }

    func pollAuthorization(deviceCode: String) async throws -> StoreAuthorizationStatus {
        guard !deviceCode.isEmpty, deviceCode.utf8.count <= 4096 else {
            throw StoreConnectionError.schema
        }
        let request = try makeRequest(
            path: "token",
            method: "POST",
            body: ["client_id": contract.clientId, "device_code": deviceCode]
        )
        let (data, response) = try await perform(request)
        if response.statusCode == 400 {
            let error = try? JSONDecoder().decode(AuthorizationFailure.self, from: data)
            switch error?.error {
            case "authorization_pending":
                return .pending
            case "slow_down":
                return .slowDown
            case "expired_token", "invalid_grant":
                throw StoreConnectionError.expired
            case "access_denied":
                throw StoreConnectionError.denied
            default:
                break
            }
        }
        try validate(response)
        // ALS may return no platform data. The caller must confirm the account through LCARS.
        return .authorized
    }

    func disconnect(providerCode: String, token: String) async throws {
        let provider = try normalizedProviderCode(providerCode)
        guard let encodedProvider = provider.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw StoreConnectionError.schema
        }
        let request = try makeRequest(path: "linking/\(encodedProvider)", method: "DELETE", token: token)
        let (_, response) = try await perform(request, ambiguousOnFailure: true)
        try validate(response)
    }

    private func normalizedProviderCode(_ code: String) throws -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty, normalized.utf8.count <= 128 else {
            throw StoreConnectionError.schema
        }
        return normalized
    }

    private func makeRequest(
        path: String,
        method: String,
        token: String? = nil,
        body: [String: String] = [:]
    ) throws -> URLRequest {
        guard let url = URL(string: "v1/\(path)", relativeTo: contract.alsBaseURL)?.absoluteURL,
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil
        else {
            throw StoreConnectionError.schema
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform(
        _ request: URLRequest,
        ambiguousOnFailure: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport.data(for: request, maximumResponseSize: 65536)
            guard let response = response as? HTTPURLResponse else {
                throw StoreConnectionError.schema
            }
            return (data, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch HTTPTransportError.responseTooLarge {
            throw StoreConnectionError.schema
        } catch let error as StoreConnectionError {
            throw error
        } catch {
            throw ambiguousOnFailure ? StoreConnectionError.networkAmbiguous : .network
        }
    }

    private func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200 ..< 300:
            return
        case 401:
            throw StoreConnectionError.unauthorized
        case 403:
            throw StoreConnectionError.forbidden
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw StoreConnectionError.rateLimited(
                retryAfter: retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            )
        case 404, 405, 410:
            throw StoreConnectionError.schema
        default:
            throw StoreConnectionError.httpStatus(response.statusCode)
        }
    }

    private func validatedVerificationURL(_ value: String) -> URL? {
        guard value.utf8.count <= 8192, let url = URL(string: value),
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443,
              ["nvidia.com", "geforcenow.com", "gfn.link"].contains(where: {
                  host == $0 || host.hasSuffix(".\($0)")
              })
        else { return nil }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard !queryItems.contains(where: {
            ["access_token", "id_token", "refresh_token", "device_code", "authorization"].contains($0.name.lowercased())
        }) else { return nil }
        return url
    }
}

extension GFNStoreConnectionClient: StoreConnectionClient {}

private nonisolated struct AuthorizationPayload: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String?
    let verificationURIComplete: String
    let expiresIn: TimeInterval
    let interval: TimeInterval

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

private nonisolated struct AuthorizationFailure: Decodable {
    let error: String
}
