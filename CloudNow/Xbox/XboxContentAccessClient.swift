import Foundation

/// The active Xbox membership reported by Microsoft's Content Access service.
/// Product identifiers stay inside the adapter so UI and persistence layers
/// cannot accidentally treat service implementation details as account state.
nonisolated enum XboxMembershipTier: Equatable, Hashable, Sendable {
    case ultimate
    case premium
    case essential
    case pcGamePass

    var displayName: String {
        switch self {
        case .ultimate:
            "Game Pass Ultimate"
        case .premium:
            "Game Pass Premium"
        case .essential:
            "Game Pass Essential"
        case .pcGamePass:
            "PC Game Pass"
        }
    }
}

/// Product-level cloud access with all account identifiers removed.
nonisolated struct XboxProductCloudAccess: Equatable, Sendable {
    private static let ownedAccessType: UInt32 = 1
    private static let streamingFresnoSYOGAccessType: UInt32 = 8_388_608
    private static let ferdinandStreamingProgram: UInt32 = 2

    let userAccessTypes: UInt32
    let aggregateAccessTypes: UInt32
    let streamingProgram: UInt32?
    let remainingGameplayTimeInSeconds: UInt64?
    let maxGameplayTimeInSeconds: UInt64?

    var effectiveAccessTypes: UInt32 {
        userAccessTypes | aggregateAccessTypes
    }

    /// Aggregate access is diagnostic metadata. First-party authorization is
    /// based only on access assigned directly to the selected user.
    var isOwned: Bool {
        userAccessTypes & Self.ownedAccessType != 0
    }

    var supportsStreamingFresnoSYOG: Bool {
        userAccessTypes & Self.streamingFresnoSYOGAccessType != 0
    }

    var isFerdinand: Bool {
        streamingProgram == Self.ferdinandStreamingProgram
    }

    var hasPlayableRemainingTime: Bool {
        remainingGameplayTimeInSeconds.map { $0 > 0 } ?? true
    }

    var isGameplayTimeExhausted: Bool {
        remainingGameplayTimeInSeconds == 0
    }

    var hasGameplayTimeLimit: Bool {
        maxGameplayTimeInSeconds != nil
    }
}

/// A normalized, credential-free view of the current account's Content Access
/// response. It intentionally excludes the PUID and raw pass records while
/// retaining bounded product identifiers required by Xbox catalog requests.
nonisolated struct XboxContentAccessSnapshot: Equatable, Sendable {
    static let maximumActiveSubscriptionCount = 128
    static let maximumProductAccessCount = 4096

    let membershipTier: XboxMembershipTier?
    let activeSubscriptionProductIDs: [String]
    let productAccessByProductID: [String: XboxProductCloudAccess]
    let fetchedAt: Date

    init(
        membershipTier: XboxMembershipTier?,
        fetchedAt: Date,
        activeSubscriptionProductIDs: [String] = [],
        productAccessByProductID: [String: XboxProductCloudAccess] = [:]
    ) {
        self.membershipTier = membershipTier
        self.fetchedAt = fetchedAt

        let normalizedSubscriptionIDs = Set(activeSubscriptionProductIDs.compactMap {
            XboxContentAccessIdentifier.normalizedProductID($0)
        })
        self.activeSubscriptionProductIDs = Array(
            normalizedSubscriptionIDs.sorted().prefix(Self.maximumActiveSubscriptionCount)
        )

        var normalizedProductAccess: [String: XboxProductCloudAccess] = [:]
        normalizedProductAccess.reserveCapacity(
            min(productAccessByProductID.count, Self.maximumProductAccessCount)
        )
        for productID in productAccessByProductID.keys.sorted() {
            guard normalizedProductAccess.count < Self.maximumProductAccessCount,
                  let normalizedProductID = XboxContentAccessIdentifier
                  .normalizedProductID(productID),
                  let access = productAccessByProductID[productID]
            else {
                continue
            }
            normalizedProductAccess[normalizedProductID] = access
        }
        self.productAccessByProductID = normalizedProductAccess
    }
}

/// Optional Xbox account metadata boundary. A failure here must not affect the
/// independently authorized Xbox Cloud catalog or streaming runtime.
nonisolated protocol XboxContentAccessProviding: Sendable {
    func fetchContentAccess(
        for account: XboxCloudAuthorizedAccount,
        market: String,
        offeringID: String
    ) async throws -> XboxContentAccessSnapshot
}

nonisolated enum XboxContentAccessError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration
    case invalidMarket
    case unsupportedOffering
    case credentialUnavailable
    case invalidResponse
    case responseTooLarge
    case invalidPayload
    case httpFailure(statusCode: Int)
    case transportFailure

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Xbox Content Access is not configured correctly."
        case .invalidMarket:
            "Xbox Content Access requires a valid market."
        case .unsupportedOffering:
            "Xbox Content Access does not support this cloud offering."
        case .credentialUnavailable:
            "Xbox membership information is unavailable for this account."
        case .invalidResponse:
            "Xbox Content Access returned an invalid response."
        case .responseTooLarge:
            "Xbox Content Access returned more data than CloudNow can safely process."
        case .invalidPayload:
            "Xbox Content Access returned invalid membership data."
        case let .httpFailure(statusCode):
            "Xbox Content Access failed with HTTP \(statusCode)."
        case .transportFailure:
            "Xbox Content Access could not be reached."
        }
    }
}

/// Lightweight adapter for the same Content Access surface used by the current
/// Xbox Cloud Gaming web client. It retains only bounded subscription and
/// product-access data with account identifiers removed.
nonisolated struct XboxContentAccessClient: XboxContentAccessProviding, Sendable {
    private static let serviceHost = "contentaccess.exp.xboxservices.com"
    private static let supportedOfferingIDs: Set<String> = [
        "xgpuweb",
        "xgpuwebf2p",
    ]
    private static let defaultMaximumResponseBytes = 8 * 1024 * 1024
    private static let maximumCredentialBytes = 131_072
    private static let requestTimeout: TimeInterval = 30

    private let credentialProvider: any XboxXSTSCredentialProviding
    private let transport: any HTTPTransport
    private let maximumResponseBytes: Int
    private let callingAppName: String
    private let callingAppVersion: String
    private let now: @Sendable () -> Date
    private let makeCorrelationVector: @Sendable () -> String

    init(
        credentialProvider: any XboxXSTSCredentialProviding,
        transport: any HTTPTransport = URLSessionHTTPTransport(configuration: .ephemeral),
        maximumResponseBytes: Int = Self.defaultMaximumResponseBytes,
        callingAppName: String = "CloudNow",
        callingAppVersion: String = "1.0",
        now: @escaping @Sendable () -> Date = Date.init,
        makeCorrelationVector: @escaping @Sendable () -> String = Self.newCorrelationVector
    ) {
        self.credentialProvider = credentialProvider
        self.transport = transport
        self.maximumResponseBytes = maximumResponseBytes
        self.callingAppName = callingAppName
        self.callingAppVersion = callingAppVersion
        self.now = now
        self.makeCorrelationVector = makeCorrelationVector
    }

    func fetchContentAccess(
        for account: XboxCloudAuthorizedAccount,
        market: String,
        offeringID: String
    ) async throws -> XboxContentAccessSnapshot {
        let endpoint = try endpoint(market: market, offeringID: offeringID)
        let correlationVector = try validatedHeaderValue(
            makeCorrelationVector(),
            maximumBytes: 256
        )
        let appName = try validatedHeaderValue(callingAppName, maximumBytes: 128)
        let appVersion = try validatedHeaderValue(callingAppVersion, maximumBytes: 64)
        guard (1 ... Self.defaultMaximumResponseBytes).contains(maximumResponseBytes) else {
            throw XboxContentAccessError.invalidConfiguration
        }

        let credential: XboxXSTSCredential
        do {
            try Task.checkCancellation()
            credential = try await credentialProvider.credential(
                for: account,
                relyingParty: .contentAccess
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw XboxContentAccessError.credentialUnavailable
        }
        guard credential.relyingParty == .contentAccess,
              credential.isUsable(at: now()),
              Self.isSafeCredentialComponent(credential.userHash),
              Self.isSafeCredentialComponent(credential.token)
        else {
            throw XboxContentAccessError.credentialUnavailable
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(credential.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        request.setValue(appName, forHTTPHeaderField: "Calling-App-Name")
        request.setValue(appVersion, forHTTPHeaderField: "Calling-App-Version")
        request.setValue(correlationVector, forHTTPHeaderField: "MS-CV")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw XboxContentAccessError.transportFailure
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw XboxContentAccessError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw XboxContentAccessError.httpFailure(statusCode: httpResponse.statusCode)
        }
        guard data.count <= maximumResponseBytes else {
            throw XboxContentAccessError.responseTooLarge
        }

        let decoded: XboxContentAccessDecodedSnapshot
        do {
            decoded = try XboxContentAccessProtobufDecoder.snapshot(from: data)
        } catch {
            throw XboxContentAccessError.invalidPayload
        }
        return XboxContentAccessSnapshot(
            membershipTier: decoded.membershipTier,
            fetchedAt: now(),
            activeSubscriptionProductIDs: decoded.activeSubscriptionProductIDs,
            productAccessByProductID: decoded.productAccessByProductID
        )
    }

    private func endpoint(market: String, offeringID: String) throws -> URL {
        let normalizedMarket = market.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedMarketCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        guard !normalizedMarket.isEmpty,
              normalizedMarket.utf8.count <= 32,
              normalizedMarket.unicodeScalars.allSatisfy(allowedMarketCharacters.contains)
        else {
            throw XboxContentAccessError.invalidMarket
        }

        let normalizedOfferingID = offeringID.lowercased()
        guard Self.supportedOfferingIDs.contains(normalizedOfferingID) else {
            throw XboxContentAccessError.unsupportedOffering
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.serviceHost
        components.path = "/all/v1"
        components.queryItems = [
            URLQueryItem(name: "market", value: normalizedMarket),
            URLQueryItem(name: "offering", value: normalizedOfferingID),
        ]
        guard let endpoint = components.url,
              endpoint.absoluteString.utf8.count <= 2048
        else {
            throw XboxContentAccessError.invalidConfiguration
        }
        return endpoint
    }

    private func validatedHeaderValue(
        _ value: String,
        maximumBytes: Int
    ) throws -> String {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == normalizedValue,
              !value.isEmpty,
              value.utf8.count <= maximumBytes,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw XboxContentAccessError.invalidConfiguration
        }
        return value
    }

    private static func isSafeCredentialComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumCredentialBytes
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func newCorrelationVector() -> String {
        var bytes = UUID().uuid
        let seed = withUnsafeBytes(of: &bytes) { buffer in
            Data(buffer).base64EncodedString()
        }
        return "\(seed.dropLast(2)).0"
    }
}

private nonisolated enum XboxContentAccessProtobufDecoder {
    private static let maximumTopLevelFields = 20000
    private static let maximumPassCount = 128
    private static let maximumPUIDCount = 128
    private static let maximumNestedFields = 64
    private static let passesByPUIDField = 1
    private static let productsByProductIDField = 2

    private static let tierByProductID: [String: XboxMembershipTier] = [
        "CFQ7TTC0KHS0": .ultimate,
        "CFQ7TTC0P85B": .premium,
        "CFQ7TTC0K5DJ": .essential,
        "CFQ7TTC0KGQ8": .pcGamePass,
    ]
    private static let tierPrecedence: [XboxMembershipTier] = [
        .ultimate,
        .premium,
        .essential,
        .pcGamePass,
    ]

    static func snapshot(from data: Data) throws -> XboxContentAccessDecodedSnapshot {
        var reader = XboxContentAccessProtobufReader(data: data)
        var topLevelFieldCount = 0
        var firstActiveSubscriptionProductIDs: [String]?
        var activeSubscriptionProductIDsByPUID: [String: [String]] = [:]
        var productEntryRanges: [Range<Int>] = []
        productEntryRanges.reserveCapacity(128)

        while !reader.isAtEnd {
            topLevelFieldCount += 1
            guard topLevelFieldCount <= maximumTopLevelFields else {
                throw XboxContentAccessProtobufError.invalidPayload
            }
            let field = try reader.readField()
            switch field.number {
            case passesByPUIDField:
                guard field.wireType == .lengthDelimited else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                let record = try decodePassesByPUIDEntry(
                    data: data,
                    range: reader.readLengthDelimitedRange()
                )
                if firstActiveSubscriptionProductIDs == nil {
                    firstActiveSubscriptionProductIDs = record.activeProductIDs
                }
                if activeSubscriptionProductIDsByPUID[record.puid] == nil {
                    guard activeSubscriptionProductIDsByPUID.count < maximumPUIDCount else {
                        throw XboxContentAccessProtobufError.invalidPayload
                    }
                }
                activeSubscriptionProductIDsByPUID[record.puid] = record.activeProductIDs
            case productsByProductIDField:
                guard field.wireType == .lengthDelimited,
                      productEntryRanges.count < XboxContentAccessSnapshot
                      .maximumProductAccessCount
                else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                try productEntryRanges.append(reader.readLengthDelimitedRange())
            default:
                try reader.skipValue(wireType: field.wireType)
            }
        }

        let selectedPUIDRecord = activeSubscriptionProductIDsByPUID.count == 1
            ? activeSubscriptionProductIDsByPUID.first
            : nil
        let membershipProductIDs = selectedPUIDRecord?.value
            ?? firstActiveSubscriptionProductIDs
            ?? []
        let membershipTier = membershipTier(for: membershipProductIDs)
        guard let selectedPUIDRecord else {
            return XboxContentAccessDecodedSnapshot(
                membershipTier: membershipTier,
                activeSubscriptionProductIDs: [],
                productAccessByProductID: [:]
            )
        }

        var accessEntryCount = 0
        var productAccessByProductID: [String: XboxProductCloudAccess] = [:]
        productAccessByProductID.reserveCapacity(productEntryRanges.count)
        for range in productEntryRanges {
            let product = try decodeProductMapEntry(
                data: data,
                range: range,
                selectedPUID: selectedPUIDRecord.key,
                accessEntryCount: &accessEntryCount
            )
            if let access = product.access {
                productAccessByProductID[product.productID] = access
            } else {
                productAccessByProductID.removeValue(forKey: product.productID)
            }
        }
        return XboxContentAccessDecodedSnapshot(
            membershipTier: membershipTier,
            activeSubscriptionProductIDs: selectedPUIDRecord.value,
            productAccessByProductID: productAccessByProductID
        )
    }

    private static func decodePassesByPUIDEntry(
        data: Data,
        range: Range<Int>
    ) throws -> XboxContentAccessPassUserRecord {
        var reader = XboxContentAccessProtobufReader(data: data, range: range)
        var fieldCount = 0
        var puid: String?
        var activeProductIDs: [String] = []

        while !reader.isAtEnd {
            fieldCount += 1
            guard fieldCount <= maximumNestedFields else {
                throw XboxContentAccessProtobufError.invalidPayload
            }
            let field = try reader.readField()
            switch field.number {
            case 1:
                guard field.wireType == .lengthDelimited else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                puid = try validatedPUID(
                    data: data,
                    range: reader.readLengthDelimitedRange()
                )
            case 2:
                guard field.wireType == .lengthDelimited else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                activeProductIDs = try decodeUserPassData(
                    data: data,
                    range: reader.readLengthDelimitedRange()
                )
            default:
                try reader.skipValue(wireType: field.wireType)
            }
        }
        guard let puid else {
            throw XboxContentAccessProtobufError.invalidPayload
        }
        return XboxContentAccessPassUserRecord(
            puid: puid,
            activeProductIDs: activeProductIDs
        )
    }

    private static func decodeUserPassData(
        data: Data,
        range: Range<Int>
    ) throws -> [String] {
        var reader = XboxContentAccessProtobufReader(data: data, range: range)
        var passCount = 0
        var activeStateByProductID: [String: Bool] = [:]

        while !reader.isAtEnd {
            let field = try reader.readField()
            guard field.number == 1,
                  field.wireType == .lengthDelimited
            else {
                try reader.skipValue(wireType: field.wireType)
                continue
            }
            passCount += 1
            guard passCount <= maximumPassCount else {
                throw XboxContentAccessProtobufError.invalidPayload
            }
            let pass = try decodePassMapEntry(
                data: data,
                range: reader.readLengthDelimitedRange()
            )
            activeStateByProductID[pass.productID] = pass.isActive
        }
        return activeStateByProductID.compactMap { productID, isActive in
            isActive ? productID : nil
        }.sorted()
    }

    private static func decodePassMapEntry(
        data: Data,
        range: Range<Int>
    ) throws -> XboxContentAccessPassRecord {
        var reader = XboxContentAccessProtobufReader(data: data, range: range)
        var fieldCount = 0
        var productID: String?
        var isActive: Bool?

        while !reader.isAtEnd {
            fieldCount += 1
            guard fieldCount <= maximumNestedFields else {
                throw XboxContentAccessProtobufError.invalidPayload
            }
            let field = try reader.readField()
            switch field.number {
            case 1:
                guard field.wireType == .lengthDelimited else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                let valueRange = try reader.readLengthDelimitedRange()
                let decodedValue = try decodedString(
                    data: data,
                    range: valueRange,
                    maximumBytes: XboxContentAccessIdentifier.maximumProductIDBytes
                )
                guard let value = XboxContentAccessIdentifier.normalizedProductID(
                    decodedValue
                ) else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                productID = value
            case 2:
                guard field.wireType == .lengthDelimited else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                isActive = try decodePassData(
                    data: data,
                    range: reader.readLengthDelimitedRange()
                )
            default:
                try reader.skipValue(wireType: field.wireType)
            }
        }
        guard let productID, let isActive else {
            throw XboxContentAccessProtobufError.invalidPayload
        }
        return XboxContentAccessPassRecord(productID: productID, isActive: isActive)
    }

    private static func decodePassData(
        data: Data,
        range: Range<Int>
    ) throws -> Bool {
        var reader = XboxContentAccessProtobufReader(data: data, range: range)
        var fieldCount = 0
        var status: UInt64 = 0

        while !reader.isAtEnd {
            fieldCount += 1
            guard fieldCount <= maximumNestedFields else {
                throw XboxContentAccessProtobufError.invalidPayload
            }
            let field = try reader.readField()
            if field.number == 1 {
                guard field.wireType == .varint else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                status = try reader.readVarint()
            } else {
                try reader.skipValue(wireType: field.wireType)
            }
        }
        return status == 0
    }

    private static func decodeProductMapEntry(
        data: Data,
        range: Range<Int>,
        selectedPUID: String,
        accessEntryCount: inout Int
    ) throws -> XboxContentAccessProductRecord {
        var reader = XboxContentAccessProtobufReader(data: data, range: range)
        var fieldCount = 0
        var productID: String?
        var productDataRange: Range<Int>?

        while !reader.isAtEnd {
            fieldCount += 1
            guard fieldCount <= maximumNestedFields else {
                throw XboxContentAccessProtobufError.invalidPayload
            }
            let field = try reader.readField()
            switch field.number {
            case 1:
                guard field.wireType == .lengthDelimited else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                let valueRange = try reader.readLengthDelimitedRange()
                let decodedValue = try decodedString(
                    data: data,
                    range: valueRange,
                    maximumBytes: XboxContentAccessIdentifier.maximumProductIDBytes
                )
                guard let value = XboxContentAccessIdentifier.normalizedProductID(
                    decodedValue
                ) else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                productID = value
            case 2:
                guard field.wireType == .lengthDelimited else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                productDataRange = try reader.readLengthDelimitedRange()
            default:
                try reader.skipValue(wireType: field.wireType)
            }
        }
        guard let productID else {
            throw XboxContentAccessProtobufError.invalidPayload
        }
        let access = try productDataRange.map {
            try decodeProductData(
                data: data,
                range: $0,
                selectedPUID: selectedPUID,
                accessEntryCount: &accessEntryCount
            )
        } ?? nil
        return XboxContentAccessProductRecord(productID: productID, access: access)
    }

    private static func decodeProductData(
        data: Data,
        range: Range<Int>,
        selectedPUID: String,
        accessEntryCount: inout Int
    ) throws -> XboxProductCloudAccess? {
        var reader = XboxContentAccessProtobufReader(data: data, range: range)
        var fieldCount = 0
        var selectedAccess: XboxProductCloudAccess?

        while !reader.isAtEnd {
            fieldCount += 1
            guard fieldCount <= XboxContentAccessSnapshot.maximumProductAccessCount
                + maximumNestedFields
            else {
                throw XboxContentAccessProtobufError.invalidPayload
            }
            let field = try reader.readField()
            guard field.number == 2 else {
                try reader.skipValue(wireType: field.wireType)
                continue
            }
            guard field.wireType == .lengthDelimited,
                  accessEntryCount < XboxContentAccessSnapshot.maximumProductAccessCount
            else {
                throw XboxContentAccessProtobufError.invalidPayload
            }
            accessEntryCount += 1
            let accessEntry = try decodeProductAccessMapEntry(
                data: data,
                range: reader.readLengthDelimitedRange()
            )
            if accessEntry.puid == selectedPUID {
                selectedAccess = try accessEntry.accessRange.map {
                    try decodeUserProductAccess(data: data, range: $0)
                } ?? XboxProductCloudAccess(
                    userAccessTypes: 0,
                    aggregateAccessTypes: 0,
                    streamingProgram: nil,
                    remainingGameplayTimeInSeconds: nil,
                    maxGameplayTimeInSeconds: nil
                )
            }
        }
        return selectedAccess
    }

    private static func decodeProductAccessMapEntry(
        data: Data,
        range: Range<Int>
    ) throws -> XboxContentAccessProductUserRecord {
        var reader = XboxContentAccessProtobufReader(data: data, range: range)
        var fieldCount = 0
        var puid: String?
        var accessRange: Range<Int>?

        while !reader.isAtEnd {
            fieldCount += 1
            guard fieldCount <= maximumNestedFields else {
                throw XboxContentAccessProtobufError.invalidPayload
            }
            let field = try reader.readField()
            switch field.number {
            case 1:
                guard field.wireType == .lengthDelimited else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                puid = try validatedPUID(
                    data: data,
                    range: reader.readLengthDelimitedRange()
                )
            case 2:
                guard field.wireType == .lengthDelimited else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                accessRange = try reader.readLengthDelimitedRange()
            default:
                try reader.skipValue(wireType: field.wireType)
            }
        }
        guard let puid else {
            throw XboxContentAccessProtobufError.invalidPayload
        }
        return XboxContentAccessProductUserRecord(puid: puid, accessRange: accessRange)
    }

    private static func decodeUserProductAccess(
        data: Data,
        range: Range<Int>
    ) throws -> XboxProductCloudAccess {
        var reader = XboxContentAccessProtobufReader(data: data, range: range)
        var fieldCount = 0
        var userAccessTypes: UInt32 = 0
        var aggregateAccessTypes: UInt32 = 0
        var streamingGameplayData: XboxContentAccessStreamingGameplayData?

        while !reader.isAtEnd {
            fieldCount += 1
            guard fieldCount <= maximumNestedFields else {
                throw XboxContentAccessProtobufError.invalidPayload
            }
            let field = try reader.readField()
            switch field.number {
            case 1:
                userAccessTypes = try readUInt32(field: field, reader: &reader)
            case 2:
                aggregateAccessTypes = try readUInt32(field: field, reader: &reader)
            case 11:
                guard field.wireType == .lengthDelimited else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                streamingGameplayData = try decodeStreamingGameplayData(
                    data: data,
                    range: reader.readLengthDelimitedRange()
                )
            default:
                try reader.skipValue(wireType: field.wireType)
            }
        }
        return XboxProductCloudAccess(
            userAccessTypes: userAccessTypes,
            aggregateAccessTypes: aggregateAccessTypes,
            streamingProgram: streamingGameplayData?.program,
            remainingGameplayTimeInSeconds: streamingGameplayData?
                .remainingGameplayTimeInSeconds,
            maxGameplayTimeInSeconds: streamingGameplayData?.maxGameplayTimeInSeconds
        )
    }

    private static func decodeStreamingGameplayData(
        data: Data,
        range: Range<Int>
    ) throws -> XboxContentAccessStreamingGameplayData {
        var reader = XboxContentAccessProtobufReader(data: data, range: range)
        var fieldCount = 0
        var program: UInt32?
        var remainingGameplayTimeInSeconds: UInt64?
        var maxGameplayTimeInSeconds: UInt64?

        while !reader.isAtEnd {
            fieldCount += 1
            guard fieldCount <= maximumNestedFields else {
                throw XboxContentAccessProtobufError.invalidPayload
            }
            let field = try reader.readField()
            switch field.number {
            case 1:
                program = try readUInt32(field: field, reader: &reader)
            case 2:
                guard field.wireType == .varint else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                remainingGameplayTimeInSeconds = try reader.readVarint()
            case 4:
                guard field.wireType == .varint else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                maxGameplayTimeInSeconds = try reader.readVarint()
            default:
                try reader.skipValue(wireType: field.wireType)
            }
        }
        return XboxContentAccessStreamingGameplayData(
            program: program,
            remainingGameplayTimeInSeconds: remainingGameplayTimeInSeconds,
            maxGameplayTimeInSeconds: maxGameplayTimeInSeconds
        )
    }

    private static func readUInt32(
        field: XboxContentAccessProtobufReader.Field,
        reader: inout XboxContentAccessProtobufReader
    ) throws -> UInt32 {
        guard field.wireType == .varint else {
            throw XboxContentAccessProtobufError.invalidPayload
        }
        let rawValue = try reader.readVarint()
        guard let value = UInt32(exactly: rawValue) else {
            throw XboxContentAccessProtobufError.invalidPayload
        }
        return value
    }

    private static func validatedPUID(
        data: Data,
        range: Range<Int>
    ) throws -> String {
        let value = try decodedString(
            data: data,
            range: range,
            maximumBytes: XboxContentAccessIdentifier.maximumPUIDBytes
        )
        guard XboxContentAccessIdentifier.isValidPUID(value) else {
            throw XboxContentAccessProtobufError.invalidPayload
        }
        return value
    }

    private static func decodedString(
        data: Data,
        range: Range<Int>,
        maximumBytes: Int
    ) throws -> String {
        guard !range.isEmpty,
              range.count <= maximumBytes,
              let value = String(data: data.subdata(in: range), encoding: .utf8)
        else {
            throw XboxContentAccessProtobufError.invalidPayload
        }
        return value
    }

    private static func membershipTier(for productIDs: [String]) -> XboxMembershipTier? {
        let tiers = Set(productIDs.compactMap { tierByProductID[$0] })
        return tierPrecedence.first(where: tiers.contains)
    }
}

private nonisolated enum XboxContentAccessIdentifier {
    static let maximumProductIDBytes = 128
    static let maximumPUIDBytes = 128

    static func normalizedProductID(_ value: String) -> String? {
        guard isSafeIdentifier(value, maximumBytes: maximumProductIDBytes) else {
            return nil
        }
        let normalizedValue = value.uppercased()
        guard normalizedValue.utf8.count <= maximumProductIDBytes else {
            return nil
        }
        return normalizedValue
    }

    static func isValidPUID(_ value: String) -> Bool {
        isSafeIdentifier(value, maximumBytes: maximumPUIDBytes)
    }

    private static func isSafeIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
            }
    }
}

private nonisolated struct XboxContentAccessDecodedSnapshot {
    let membershipTier: XboxMembershipTier?
    let activeSubscriptionProductIDs: [String]
    let productAccessByProductID: [String: XboxProductCloudAccess]
}

private nonisolated struct XboxContentAccessPassUserRecord {
    let puid: String
    let activeProductIDs: [String]
}

private nonisolated struct XboxContentAccessPassRecord {
    let productID: String
    let isActive: Bool
}

private nonisolated struct XboxContentAccessProductRecord {
    let productID: String
    let access: XboxProductCloudAccess?
}

private nonisolated struct XboxContentAccessProductUserRecord {
    let puid: String
    let accessRange: Range<Int>?
}

private nonisolated struct XboxContentAccessStreamingGameplayData {
    let program: UInt32?
    let remainingGameplayTimeInSeconds: UInt64?
    let maxGameplayTimeInSeconds: UInt64?
}

private nonisolated enum XboxContentAccessProtobufError: Error {
    case invalidPayload
}

private nonisolated struct XboxContentAccessProtobufReader {
    struct Field {
        let number: Int
        let wireType: WireType
    }

    enum WireType: UInt64 {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    private let data: Data
    private let endOffset: Int
    private var offset: Int

    init(data: Data) {
        self.data = data
        offset = data.startIndex
        endOffset = data.endIndex
    }

    init(data: Data, range: Range<Int>) {
        self.data = data
        offset = range.lowerBound
        endOffset = range.upperBound
    }

    var isAtEnd: Bool {
        offset == endOffset
    }

    mutating func readField() throws -> Field {
        let tag = try readVarint()
        let rawWireType = tag & 0b111
        let fieldNumber = tag >> 3
        guard fieldNumber > 0,
              fieldNumber <= UInt64(Int32.max),
              let wireType = WireType(rawValue: rawWireType)
        else {
            throw XboxContentAccessProtobufError.invalidPayload
        }
        return Field(number: Int(fieldNumber), wireType: wireType)
    }

    mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        for byteIndex in 0 ..< 10 {
            let byte = try readByte()
            if byteIndex == 9, byte > 1 {
                throw XboxContentAccessProtobufError.invalidPayload
            }
            value |= UInt64(byte & 0x7F) << UInt64(byteIndex * 7)
            if byte & 0x80 == 0 {
                guard byteIndex == 0 || byte != 0 else {
                    throw XboxContentAccessProtobufError.invalidPayload
                }
                return value
            }
        }
        throw XboxContentAccessProtobufError.invalidPayload
    }

    mutating func readLengthDelimitedRange() throws -> Range<Int> {
        let rawLength = try readVarint()
        guard rawLength <= UInt64(Int.max) else {
            throw XboxContentAccessProtobufError.invalidPayload
        }
        let length = Int(rawLength)
        guard length <= endOffset - offset else {
            throw XboxContentAccessProtobufError.invalidPayload
        }
        let range = offset ..< offset + length
        offset = range.upperBound
        return range
    }

    mutating func skipValue(wireType: WireType) throws {
        switch wireType {
        case .varint:
            _ = try readVarint()
        case .fixed64:
            try advance(by: 8)
        case .lengthDelimited:
            _ = try readLengthDelimitedRange()
        case .fixed32:
            try advance(by: 4)
        }
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < endOffset else {
            throw XboxContentAccessProtobufError.invalidPayload
        }
        defer { offset += 1 }
        return data[offset]
    }

    private mutating func advance(by count: Int) throws {
        guard count >= 0, count <= endOffset - offset else {
            throw XboxContentAccessProtobufError.invalidPayload
        }
        offset += count
    }
}
