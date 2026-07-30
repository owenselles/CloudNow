import Foundation

// MARK: - Provider Library Sync Domain

nonisolated enum ProviderAccountSyncState: Sendable, Equatable {
    case success
    case failed
    case denied
    case profileNotCreated
    case unknown(String?)

    init(rawValue: String?) {
        switch rawValue {
        case "SYNC_SUCCESS":
            self = .success
        case "SYNC_FAILED":
            self = .failed
        case "SYNC_DENIED":
            self = .denied
        case "PROFILE_NOT_CREATED":
            self = .profileNotCreated
        default:
            self = .unknown(rawValue)
        }
    }

    var rawValue: String? {
        switch self {
        case .success:
            "SYNC_SUCCESS"
        case .failed:
            "SYNC_FAILED"
        case .denied:
            "SYNC_DENIED"
        case .profileNotCreated:
            "PROFILE_NOT_CREATED"
        case let .unknown(value):
            value
        }
    }
}

nonisolated struct ProviderSyncSnapshot: Sendable, Equatable {
    let providerCode: String
    let totalSyncedGames: Int?
    let state: ProviderAccountSyncState
    let syncDate: Date?
}

nonisolated struct ConnectedGameLibrary: Identifiable, Sendable, Equatable {
    let code: String
    let displayName: String
    let accountDisplayName: String?
    let iconURL: URL?
    let supportsSync: Bool
    let sortOrder: Int
    let snapshot: ProviderSyncSnapshot

    var id: String {
        code
    }
}

nonisolated protocol LibrarySyncClient: Sendable {
    func discover(token: String, userId: String) async throws -> [ConnectedGameLibrary]
    func requestSync(providerCode: String, token: String) async throws
    func fetchSnapshots(token: String, userId: String) async throws -> [ProviderSyncSnapshot]
}

nonisolated struct LibrarySyncContract: Sendable, Equatable {
    let lcarsURL: URL
    let alsBaseURL: URL
    let clientId: String
    let staticAppDataHash: String
    let userAccountHash: String

    static let live = Self(
        lcarsURL: URL(string: "https://apps.gxn.nvidia.com/graphql")!,
        alsBaseURL: URL(string: "https://als.geforcenow.com")!,
        clientId: NVIDIAAuth.gfnClientId,
        staticAppDataHash: "d4117df5319f644c984945715ded9574bb074107eb02e97be17605b5f14c33ba",
        userAccountHash: "fc7ce0b3cfe6e09bfcd331aebef9fc27dd648a16d27888231a8282831afab85f"
    )
}

nonisolated enum LibrarySyncError: Error, Equatable, LocalizedError, Sendable {
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: TimeInterval?)
    case httpStatus(Int)
    case schema
    case network
    /// A failed transport call cannot prove whether the non-idempotent POST reached ALS.
    case networkAmbiguous

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Library synchronization authentication was rejected."
        case .forbidden:
            "Library synchronization requires the provider account to be linked again."
        case let .rateLimited(retryAfter):
            if let retryAfter {
                "Library synchronization was rate limited. Retry after \(Int(retryAfter.rounded(.up))) seconds."
            } else {
                "Library synchronization was rate limited."
            }
        case let .httpStatus(statusCode):
            "Library synchronization failed with HTTP status \(statusCode)."
        case .schema:
            "Library synchronization received an unsupported server response."
        case .network:
            "Library synchronization could not reach NVIDIA."
        case .networkAmbiguous:
            "NVIDIA may have accepted the library synchronization request before the connection failed."
        }
    }
}

// MARK: - NVIDIA Library Sync Client

/// Private API client matching the current GeForce NOW web client contracts.
/// Provider definitions remain server-driven because these endpoints are not public or versioned.
actor GFNLibrarySyncClient {
    private let transport: any HTTPTransport
    private let localeCode: @Sendable () -> String
    private let currentDate: @Sendable () -> Date
    private let contract: LibrarySyncContract

    init(
        transport: any HTTPTransport = URLSessionHTTPTransport(configuration: .ephemeral),
        contract: LibrarySyncContract = .live,
        localeCode: @escaping @Sendable () -> String = {
            L10n.nvidiaLocaleCode()
        },
        currentDate: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.contract = contract
        self.localeCode = localeCode
        self.currentDate = currentDate
    }

    func discover(token: String, userId: String) async throws -> [ConnectedGameLibrary] {
        async let definitionsRequest = fetchDefinitions(token: token, userId: userId)
        async let accountRequest = fetchAccount(token: token, userId: userId)
        let (definitions, account) = try await (definitionsRequest, accountRequest)
        var linkedStores: [String: AccountLinkingData] = [:]
        for store in account.stores {
            guard let linkingData = store.accountLinkingData else { continue }
            linkedStores[normalizedProviderCode(store.store)] = linkingData
        }

        let definitionsByCode = Dictionary(
            definitions.map { (normalizedProviderCode($0.store), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return linkedStores
            .map { code, linkingData in
                let definition = definitionsByCode[code]
                let snapshot = makeSnapshot(
                    providerCode: code,
                    linkingData: linkingData
                )
                return ConnectedGameLibrary(
                    code: code,
                    displayName: nonEmpty(definition?.label) ?? code,
                    accountDisplayName: nonEmpty(linkingData.userDisplayName),
                    iconURL: nonEmpty(definition?.smallImageURL).flatMap(URL.init(string:)),
                    supportsSync: definition?.features.contains {
                        $0.typeName == "AccountGamesSyncing" && $0.supported == true
                    } == true,
                    sortOrder: definition?.sortOrder ?? .max,
                    snapshot: snapshot
                )
            }
            .sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.code < $1.code
            }
    }

    func requestSync(providerCode: String, token: String) async throws {
        guard let encodedProviderCode = providerCode.addingPercentEncoding(
            withAllowedCharacters: Self.pathSegmentAllowedCharacters
        ), !encodedProviderCode.isEmpty,
        let url = URL(
            string: "v1/sync/\(encodedProviderCode)",
            relativeTo: contract.alsBaseURL
        )?.absoluteURL
        else {
            throw LibrarySyncError.schema
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let response: URLResponse
        do {
            let (_, receivedResponse) = try await transport.data(for: request)
            response = receivedResponse
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LibrarySyncError.networkAmbiguous
        }
        try validate(response: response, expectedStatus: 202)
    }

    func fetchSnapshots(token: String, userId: String) async throws -> [ProviderSyncSnapshot] {
        let account = try await fetchAccount(token: token, userId: userId)
        return account.stores.compactMap { store in
            guard let linkingData = store.accountLinkingData else { return nil }
            return makeSnapshot(providerCode: store.store, linkingData: linkingData)
        }
    }

    private func fetchDefinitions(token: String, userId: String) async throws -> [AppStoreDefinition] {
        let variables = try encodedJSONString([
            "locale": localeCode(),
            "stringsKey": [],
        ])
        let request = try lcarsRequest(
            requestType: "staticAppData",
            queryHash: contract.staticAppDataHash,
            variables: variables,
            token: token,
            userId: userId
        )
        let data = try await performGET(request)
        let response: GraphQLResponse<StaticAppData> = try decode(data)
        try validateGraphQLErrors(response.errors)
        guard let definitions = response.data?.appStoreDefinitions else {
            throw LibrarySyncError.schema
        }
        return definitions
    }

    private func fetchAccount(token: String, userId: String) async throws -> UserAccount {
        let request = try lcarsRequest(
            requestType: "userAccount",
            queryHash: contract.userAccountHash,
            variables: nil,
            token: token,
            userId: userId
        )
        let data = try await performGET(request)
        let response: GraphQLResponse<UserAccountData> = try decode(data)
        try validateGraphQLErrors(response.errors)
        guard let account = response.data?.userAccount else {
            throw LibrarySyncError.schema
        }
        return account
    }

    private func lcarsRequest(
        requestType: String,
        queryHash: String,
        variables: String?,
        token: String,
        userId: String
    ) throws -> URLRequest {
        var components = URLComponents(
            url: contract.lcarsURL,
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "requestType", value: requestType),
            URLQueryItem(
                name: "extensions",
                value: #"{"persistedQuery":{"sha256Hash":"\#(queryHash)"}}"#
            ),
            URLQueryItem(name: "huId", value: nvidiaAccountScope(for: userId)),
        ]
        if let variables {
            queryItems.append(URLQueryItem(name: "variables", value: variables))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw LibrarySyncError.schema
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 17
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/graphql", forHTTPHeaderField: "Content-Type")
        request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contract.clientId, forHTTPHeaderField: "nv-client-id")
        request.setValue(NVIDIAAuth.webOrigin, forHTTPHeaderField: "Origin")
        request.setValue(NVIDIAAuth.webReferer, forHTTPHeaderField: "Referer")
        request.setValue(NVIDIAAuth.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func performGET(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LibrarySyncError.network
        }
        try validate(response: response, expectedStatus: 200)
        return data
    }

    private func validate(response: URLResponse, expectedStatus: Int) throws {
        guard let response = response as? HTTPURLResponse else {
            throw LibrarySyncError.schema
        }
        guard response.statusCode == expectedStatus else {
            switch response.statusCode {
            case 401:
                throw LibrarySyncError.unauthorized
            case 403:
                throw LibrarySyncError.forbidden
            case 429:
                let retryAfter = retryAfterDelay(
                    from: response.value(forHTTPHeaderField: "Retry-After")
                )
                throw LibrarySyncError.rateLimited(retryAfter: retryAfter)
            case let statusCode
                where (200 ..< 300).contains(statusCode)
                || [404, 405, 410].contains(statusCode):
                throw LibrarySyncError.schema
            default:
                throw LibrarySyncError.httpStatus(response.statusCode)
            }
        }
    }

    private func retryAfterDelay(from headerValue: String?) -> TimeInterval? {
        guard let headerValue else { return nil }
        let value = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.utf8.allSatisfy({ (48 ... 57).contains($0) }),
           let seconds = UInt64(value)
        {
            return TimeInterval(seconds)
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false

        for format in Self.httpDateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return max(0, date.timeIntervalSince(currentDate()))
            }
        }
        return nil
    }

    private func validateGraphQLErrors(_ errors: [GraphQLError]?) throws {
        guard let errors, !errors.isEmpty else { return }
        if errors.contains(where: { $0.code == "UNAUTHENTICATED" || $0.code == "UNAUTHORIZED" }) {
            throw LibrarySyncError.unauthorized
        }
        if errors.contains(where: { $0.code == "FORBIDDEN" }) {
            throw LibrarySyncError.forbidden
        }
        throw LibrarySyncError.schema
    }

    private func makeSnapshot(
        providerCode: String,
        linkingData: AccountLinkingData
    ) -> ProviderSyncSnapshot {
        ProviderSyncSnapshot(
            providerCode: normalizedProviderCode(providerCode),
            totalSyncedGames: linkingData.accountSyncingData?.totalNumberOfSyncedGfnGames?.value,
            state: ProviderAccountSyncState(rawValue: linkingData.accountSyncingData?.syncState),
            syncDate: linkingData.accountSyncingData?.syncDate?.value
        )
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw LibrarySyncError.schema
        }
    }

    private func encodedJSONString(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw LibrarySyncError.schema
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw LibrarySyncError.schema
        }
        return string
    }

    private func normalizedProviderCode(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let pathSegmentAllowedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static let httpDateFormats = [
        "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
        "EEEE',' dd-MMM-yy HH':'mm':'ss zzz",
        "EEE MMM d HH':'mm':'ss yyyy",
    ]
}

extension GFNLibrarySyncClient: LibrarySyncClient {}

// MARK: - LCARS Payloads

private nonisolated struct GraphQLResponse<Value: Decodable>: Decodable {
    let data: Value?
    let errors: [GraphQLError]?
}

private nonisolated struct GraphQLError: Decodable {
    let extensions: Extensions?

    var code: String? {
        extensions?.code?.uppercased()
    }

    struct Extensions: Decodable {
        let code: String?
    }
}

private nonisolated struct StaticAppData: Decodable {
    let appStoreDefinitions: [AppStoreDefinition]?
}

private nonisolated struct AppStoreDefinition: Decodable {
    let store: String
    let label: String?
    let sortOrder: Int?
    let smallImageURL: String?
    let features: [AppStoreFeature]

    enum CodingKeys: String, CodingKey {
        case store
        case label
        case sortOrder
        case smallImageURL = "smallImageUrl"
        case features
    }
}

private nonisolated struct AppStoreFeature: Decodable {
    let typeName: String?
    let supported: Bool?

    enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case supported
    }
}

private nonisolated struct UserAccountData: Decodable {
    let userAccount: UserAccount?
}

private nonisolated struct UserAccount: Decodable {
    let stores: [StoreData]

    enum CodingKeys: String, CodingKey {
        case stores = "storesData"
    }
}

private nonisolated struct StoreData: Decodable {
    let store: String
    let accountLinkingData: AccountLinkingData?
}

private nonisolated struct AccountLinkingData: Decodable {
    let userDisplayName: String?
    let accountSyncingData: AccountSyncingData?
}

private nonisolated struct AccountSyncingData: Decodable {
    let totalNumberOfSyncedGfnGames: FlexibleInt?
    let syncState: String?
    let syncDate: FlexibleDate?
}

private nonisolated struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self.value = value
            return
        }
        if let string = try? container.decode(String.self), let value = Int(string) {
            self.value = value
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected an integer or integer string"
        )
    }
}

private nonisolated struct FlexibleDate: Decodable {
    let value: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let timestamp = try? container.decode(Double.self) {
            value = Self.date(fromTimestamp: timestamp)
            return
        }
        if let string = try? container.decode(String.self) {
            if let timestamp = Double(string) {
                value = Self.date(fromTimestamp: timestamp)
                return
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) {
                value = date
                return
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) {
                value = date
                return
            }
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected an ISO-8601 date or Unix timestamp"
        )
    }

    private static func date(fromTimestamp timestamp: TimeInterval) -> Date {
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp
        return Date(timeIntervalSince1970: seconds)
    }
}
