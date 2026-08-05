import Foundation
import os
import Synchronization

private nonisolated let xboxCatalogLog = Logger(
    subsystem: "com.owenselles.CloudNow2",
    category: "XboxCatalog"
)

nonisolated struct XboxCloudCatalogPolicy: Equatable, Sendable {
    static let standard: XboxCloudCatalogPolicy = {
        do {
            return try XboxCloudCatalogPolicy(
                maximumPageCount: 16,
                maximumItemCount: XboxCatalogSnapshot.maximumRetainedItemCount,
                maximumPageResponseSize: 2_097_152
            )
        } catch {
            preconditionFailure("CloudNow's Xbox catalog policy is invalid.")
        }
    }()

    let maximumPageCount: Int
    let maximumItemCount: Int
    let maximumPageResponseSize: Int

    init(
        maximumPageCount: Int,
        maximumItemCount: Int,
        maximumPageResponseSize: Int
    ) throws {
        guard (1 ... 32).contains(maximumPageCount),
              (1 ... XboxCatalogSnapshot.maximumRetainedItemCount).contains(maximumItemCount),
              (1 ... 8_388_608).contains(maximumPageResponseSize)
        else {
            throw XboxCloudCatalogError.invalidConfiguration
        }
        self.maximumPageCount = maximumPageCount
        self.maximumItemCount = maximumItemCount
        self.maximumPageResponseSize = maximumPageResponseSize
    }
}

/// Authenticated Xbox Cloud title enumeration. It owns no credential storage;
/// the small GS-session provider is injected and shared with the stream client.
/// `cancel()` synchronously cancels the one active catalog load and is safe to
/// call repeatedly from provider-switch and app-lifecycle paths.
final nonisolated class XboxCloudCatalogClient: XboxCatalogClient, Sendable {
    private let sessionProvider: any XboxCloudGSSessionProviding
    private let contentAccessProvider: (any XboxContentAccessProviding)?
    private let fresnoDiscovery: (any XboxFresnoCatalogDiscovering)?
    private let transport: any HTTPTransport
    private let policy: XboxCloudCatalogPolicy
    private let now: @Sendable () -> Date
    private let cancellationState = XboxCloudCatalogCancellationState()

    init(
        sessionProvider: any XboxCloudGSSessionProviding,
        contentAccessProvider: (any XboxContentAccessProviding)? = nil,
        fresnoDiscovery: (any XboxFresnoCatalogDiscovering)? = nil,
        transport: any HTTPTransport = URLSessionHTTPTransport(configuration: .ephemeral),
        policy: XboxCloudCatalogPolicy = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionProvider = sessionProvider
        self.contentAccessProvider = contentAccessProvider
        self.fresnoDiscovery = fresnoDiscovery
        self.transport = transport
        self.policy = policy
        self.now = now
    }

    func fetchCatalog(
        _ request: XboxCatalogRequest,
        account: XboxCloudAuthorizedAccount
    ) async throws -> XboxCatalogSnapshot {
        let operation = Task<XboxCatalogSnapshot, Error> {
            let loader = XboxCloudCatalogLoader(
                sessionProvider: self.sessionProvider,
                contentAccessProvider: self.contentAccessProvider,
                fresnoDiscovery: self.fresnoDiscovery,
                transport: self.transport,
                policy: self.policy,
                now: self.now
            )
            return try await loader.fetchCatalog(request, account: account)
        }
        let identifier = cancellationState.replaceCurrentOperation(with: operation)

        return try await withTaskCancellationHandler {
            defer { cancellationState.clearOperation(identifier: identifier) }
            do {
                return try await operation.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let metadata = XboxCloudCatalogFailureMetadata(error: error)
                xboxCatalogLog.error(
                    "Catalog failure operation=\(metadata.operation, privacy: .public) type=\(metadata.type, privacy: .public) status=\(metadata.statusCode, privacy: .public) serviceCode=\(metadata.serviceCode, privacy: .public)"
                )
                throw error
            }
        } onCancel: {
            cancellationState.cancelOperation(identifier: identifier)
        }
    }

    nonisolated func cancel() {
        cancellationState.cancelCurrentOperation()
    }
}

nonisolated enum XboxCloudCatalogOperation: String, Equatable, Sendable {
    case metadata
    case titles
}

nonisolated enum XboxCloudCatalogError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration
    case invalidMarket
    case invalidResponse(XboxCloudCatalogOperation)
    case responseTooLarge(XboxCloudCatalogOperation)
    case invalidPayload(XboxCloudCatalogOperation)
    case pageLimitExceeded(Int)
    case itemLimitExceeded(Int)
    case httpFailure(
        operation: XboxCloudCatalogOperation,
        statusCode: Int,
        serviceCode: String?
    )
    case transportFailure(XboxCloudCatalogOperation)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Xbox Cloud catalog configuration is invalid."
        case .invalidMarket:
            "Xbox Cloud catalog market is invalid."
        case let .invalidResponse(operation):
            "Xbox Cloud \(operation.rawValue) returned an invalid HTTP response."
        case let .responseTooLarge(operation):
            "Xbox Cloud \(operation.rawValue) returned too much data."
        case let .invalidPayload(operation):
            "Xbox Cloud \(operation.rawValue) returned an invalid payload."
        case let .pageLimitExceeded(maximum):
            "Xbox Cloud catalog exceeded its \(maximum)-page safety limit."
        case let .itemLimitExceeded(maximum):
            "Xbox Cloud catalog exceeded its \(maximum)-item safety limit."
        case let .httpFailure(operation, statusCode, serviceCode):
            if let serviceCode {
                "Xbox Cloud \(operation.rawValue) failed with \(serviceCode) (HTTP \(statusCode))."
            } else {
                "Xbox Cloud \(operation.rawValue) failed with HTTP \(statusCode)."
            }
        case let .transportFailure(operation):
            "Xbox Cloud \(operation.rawValue) could not be completed."
        }
    }
}

private nonisolated struct XboxCloudCatalogFailureMetadata {
    let operation: String
    let type: String
    let statusCode: String
    let serviceCode: String

    init(error: Error) {
        guard let error = error as? XboxCloudCatalogError else {
            operation = "titles"
            type = error is XboxCloudOfferingServiceError
                ? "offeringUnavailable"
                : "unexpected"
            statusCode = "none"
            serviceCode = "none"
            return
        }

        switch error {
        case .invalidConfiguration:
            operation = "catalog"
            type = "invalidConfiguration"
            statusCode = "none"
            serviceCode = "none"
        case .invalidMarket:
            operation = "titles"
            type = "invalidMarket"
            statusCode = "none"
            serviceCode = "none"
        case let .invalidResponse(operationValue):
            operation = operationValue.rawValue
            type = "invalidResponse"
            statusCode = "none"
            serviceCode = "none"
        case let .responseTooLarge(operationValue):
            operation = operationValue.rawValue
            type = "responseTooLarge"
            statusCode = "none"
            serviceCode = "none"
        case let .invalidPayload(operationValue):
            operation = operationValue.rawValue
            type = "invalidPayload"
            statusCode = "none"
            serviceCode = "none"
        case .pageLimitExceeded:
            operation = "titles"
            type = "pageLimitExceeded"
            statusCode = "none"
            serviceCode = "none"
        case .itemLimitExceeded:
            operation = "titles"
            type = "itemLimitExceeded"
            statusCode = "none"
            serviceCode = "none"
        case let .httpFailure(operationValue, statusCodeValue, serviceCodeValue):
            operation = operationValue.rawValue
            type = "httpFailure"
            statusCode = String(statusCodeValue)
            serviceCode = serviceCodeValue ?? "none"
        case let .transportFailure(operationValue):
            operation = operationValue.rawValue
            type = "transportFailure"
            statusCode = "none"
            serviceCode = "none"
        }
    }
}

private nonisolated struct XboxFresnoCatalogFailureMetadata {
    let stage: String
    let type: String
    let statusCode: String

    init(error: Error) {
        if let error = error as? XboxFresnoCatalogDiscoveryError {
            stage = "discovery"
            switch error {
            case .invalidConfiguration:
                type = "invalidConfiguration"
                statusCode = "none"
            case .invalidRequest:
                type = "invalidRequest"
                statusCode = "none"
            case .invalidResponse:
                type = "invalidResponse"
                statusCode = "none"
            case .responseTooLarge:
                type = "responseTooLarge"
                statusCode = "none"
            case .invalidPayload:
                type = "invalidPayload"
                statusCode = "none"
            case let .httpFailure(statusCodeValue):
                type = "httpFailure"
                statusCode = String(statusCodeValue)
            case .transportFailure:
                type = "transportFailure"
                statusCode = "none"
            }
            return
        }

        let catalogMetadata = XboxCloudCatalogFailureMetadata(error: error)
        stage = "hydration"
        type = catalogMetadata.type
        statusCode = catalogMetadata.statusCode
    }
}

private nonisolated struct XboxFresnoProductMetadata: Sendable {
    let title: String
    let artworkURL: URL?
}

private nonisolated struct XboxCloudCatalogLoader: Sendable {
    private static let gamePassCatalogURL: URL = {
        guard let url = URL(
            string: "https://catalog.gamepass.com/v3/products"
        ) else {
            preconditionFailure("CloudNow's Xbox Game Pass Catalog URL is invalid.")
        }
        return url
    }()

    private static let maximumContinuationTokenSize = 4096
    private static let maximumWireResultCount = 4096
    private static let maximumResultsPerPage = maximumWireResultCount
    private static let maximumImageCountPerTitle = 64
    private static let maximumUserProgramCount = 64
    private static let maximumFresnoProductCount = 400
    private static let fallbackFresnoMetadataBatchSize = 200
    private static let maximumFresnoRequestSize = 131_072
    private static let maximumFresnoMetadataResponseSize = 2_097_152
    private static let gamePassCatalogCallingAppName = "Xbox Cloud Gaming Web"
    private static let gamePassCatalogCallingAppVersion = "29.19.17"

    let sessionProvider: any XboxCloudGSSessionProviding
    let contentAccessProvider: (any XboxContentAccessProviding)?
    let fresnoDiscovery: (any XboxFresnoCatalogDiscovering)?
    let transport: any HTTPTransport
    let policy: XboxCloudCatalogPolicy
    let now: @Sendable () -> Date

    func fetchCatalog(
        _ request: XboxCatalogRequest,
        account: XboxCloudAuthorizedAccount
    ) async throws -> XboxCatalogSnapshot {
        try Task.checkCancellation()
        let session = try await sessionProvider.session(for: account)
        guard session.isUsable(at: now(), minimumLifetime: 0) else {
            throw XboxCloudOfferingServiceError.accountUnavailable
        }
        let market = try Self.validatedMarket(request.market ?? session.market)
        xboxCatalogLog.info(
            "Catalog session offering=\(session.offeringID, privacy: .public) market=\(market, privacy: .public)"
        )
        async let contentAccessLoad: XboxContentAccessSnapshot? = fetchContentAccess(
            account: account,
            market: market
        )

        var continuationToken: String?
        var seenContinuationTokens = Set<String>()
        var rawItemCount = 0
        var wireItems: [XboxCatalogItem] = []
        wireItems.reserveCapacity(min(Self.maximumWireResultCount, 128))

        for pageIndex in 0 ..< policy.maximumPageCount {
            try Task.checkCancellation()
            let page = try await fetchPage(
                baseURL: session.defaultRegion.baseURL,
                market: market,
                continuationToken: continuationToken,
                gsToken: session.gsToken
            )
            guard rawItemCount <= Self.maximumWireResultCount - page.rawResultCount else {
                throw XboxCloudCatalogError.itemLimitExceeded(Self.maximumWireResultCount)
            }
            rawItemCount += page.rawResultCount
            wireItems.append(contentsOf: page.items)

            guard let nextToken = page.continuationToken else {
                let contentAccess = await contentAccessLoad
                try Task.checkCancellation()
                let fresnoItems = await fetchFresnoItems(
                    session: session,
                    market: market,
                    localeIdentifier: request.localeIdentifier,
                    contentAccess: contentAccess
                )
                try Task.checkCancellation()
                return retainedSnapshot(from: wireItems + fresnoItems)
            }
            guard pageIndex + 1 < policy.maximumPageCount else {
                throw XboxCloudCatalogError.pageLimitExceeded(policy.maximumPageCount)
            }
            guard seenContinuationTokens.insert(nextToken).inserted else {
                throw XboxCloudCatalogError.invalidPayload(.titles)
            }
            continuationToken = nextToken
        }

        throw XboxCloudCatalogError.pageLimitExceeded(policy.maximumPageCount)
    }

    private func fetchContentAccess(
        account: XboxCloudAuthorizedAccount,
        market: String
    ) async -> XboxContentAccessSnapshot? {
        guard let contentAccessProvider else { return nil }
        do {
            let snapshot = try await contentAccessProvider.fetchContentAccess(
                for: account,
                market: market,
                offeringID: XboxCloudOfferingServiceConfiguration.defaultConsumerOfferingID
            )
            let values = snapshot.productAccessByProductID.values
            let ownedCount = values.count(where: \.isOwned)
            let streamingFresnoSYOGCount = values.count(
                where: \.supportsStreamingFresnoSYOG
            )
            let ferdinandCount = values.count(where: \.isFerdinand)
            let playableTimeCount = values.count(where: \.hasPlayableRemainingTime)
            xboxCatalogLog.info(
                "Content Access products=\(values.count, privacy: .public) subscriptions=\(snapshot.activeSubscriptionProductIDs.count, privacy: .public) owned=\(ownedCount, privacy: .public) streamingFresnoSYOG=\(streamingFresnoSYOGCount, privacy: .public) ferdinand=\(ferdinandCount, privacy: .public) playableTime=\(playableTimeCount, privacy: .public)"
            )
            return snapshot
        } catch is CancellationError {
            return nil
        } catch {
            xboxCatalogLog.info("Content Access unavailable for catalog enrichment")
            return nil
        }
    }

    private func fetchFresnoItems(
        session: XboxCloudGSSession,
        market: String,
        localeIdentifier: String,
        contentAccess: XboxContentAccessSnapshot?
    ) async -> [XboxCatalogItem] {
        guard let fresnoDiscovery else { return [] }
        do {
            try Task.checkCancellation()
            let discovery = try await fresnoDiscovery.fetchProductIDs(
                market: market,
                localeIdentifier: localeIdentifier,
                activeSubscriptionProductIDs: contentAccess?.activeSubscriptionProductIDs ?? []
            )
            let productIDs = Array(
                discovery.productIDs.prefix(Self.maximumFresnoProductCount)
            )
            guard !productIDs.isEmpty else {
                xboxCatalogLog.info("Fresno discovery candidates=0")
                return []
            }
            async let titleDataLoad = fetchFresnoTitleData(
                baseURL: session.defaultRegion.baseURL,
                market: market,
                productIDs: productIDs,
                gsToken: session.gsToken
            )
            async let metadataLoad = fetchFresnoProductMetadata(
                market: market,
                localeIdentifier: localeIdentifier,
                productIDs: productIDs
            )
            let (data, metadataByProductID) = try await (
                titleDataLoad,
                metadataLoad
            )
            let items = try Self.parseFresnoItems(
                data,
                orderedProductIDs: productIDs,
                productAccessByProductID: contentAccess?.productAccessByProductID ?? [:],
                metadataByProductID: metadataByProductID
            )
            let playableCount = items.reduce(into: 0) { count, item in
                count += item.routes.count {
                    $0.accessKind == .freeWithAds && $0.isPlayable
                }
            }
            xboxCatalogLog.info(
                "Fresno discovery candidates=\(discovery.productIDs.count, privacy: .public) hydratedProducts=\(items.count, privacy: .public) playableRoutes=\(playableCount, privacy: .public)"
            )
            return items
        } catch is CancellationError {
            return []
        } catch {
            let metadata = XboxFresnoCatalogFailureMetadata(error: error)
            xboxCatalogLog.info(
                "Fresno unavailable stage=\(metadata.stage, privacy: .public) type=\(metadata.type, privacy: .public) status=\(metadata.statusCode, privacy: .public); retaining authenticated catalog"
            )
            return []
        }
    }

    private func fetchFresnoProductMetadata(
        market: String,
        localeIdentifier: String,
        productIDs: [String]
    ) async throws -> [String: XboxFresnoProductMetadata] {
        do {
            let data = try await fetchFresnoProductMetadataData(
                market: market,
                localeIdentifier: localeIdentifier,
                productIDs: productIDs
            )
            return try Self.parseFresnoProductMetadata(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard productIDs.count > Self.fallbackFresnoMetadataBatchSize,
                  Self.shouldRetryFresnoMetadataInSmallerBatches(error)
            else {
                throw error
            }

            var combinedMetadata: [String: XboxFresnoProductMetadata] = [:]
            var successfulBatchCount = 0
            for start in stride(
                from: 0,
                to: productIDs.count,
                by: Self.fallbackFresnoMetadataBatchSize
            ) {
                try Task.checkCancellation()
                let batch = Array(
                    productIDs[
                        start ..< min(
                            start + Self.fallbackFresnoMetadataBatchSize,
                            productIDs.count
                        )
                    ]
                )
                do {
                    let data = try await fetchFresnoProductMetadataData(
                        market: market,
                        localeIdentifier: localeIdentifier,
                        productIDs: batch
                    )
                    let metadata = try Self.parseFresnoProductMetadata(data)
                    combinedMetadata.merge(metadata) { existing, _ in existing }
                    successfulBatchCount += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
            }
            guard successfulBatchCount > 0 else {
                throw error
            }
            xboxCatalogLog.info(
                "Fresno metadata retried batchSize=\(Self.fallbackFresnoMetadataBatchSize, privacy: .public) successfulBatches=\(successfulBatchCount, privacy: .public) products=\(combinedMetadata.count, privacy: .public)"
            )
            return combinedMetadata
        }
    }

    private func fetchFresnoTitleData(
        baseURL: URL,
        market: String,
        productIDs: [String],
        gsToken: String
    ) async throws -> Data {
        let endpoint = try Self.titlesEndpoint(
            baseURL: baseURL,
            market: market,
            continuationToken: nil
        )
        let body: Data
        do {
            body = try JSONSerialization.data(
                withJSONObject: [
                    "alternateIds": productIDs,
                    "alternateIdType": "productId",
                ],
                options: [.sortedKeys]
            )
        } catch {
            throw XboxCloudCatalogError.invalidConfiguration
        }
        guard body.count <= Self.maximumFresnoRequestSize else {
            throw XboxCloudCatalogError.invalidConfiguration
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(gsToken)", forHTTPHeaderField: "Authorization")
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
            throw XboxCloudCatalogError.transportFailure(.titles)
        }
        guard let response = response as? HTTPURLResponse else {
            throw XboxCloudCatalogError.invalidResponse(.titles)
        }
        guard data.count <= policy.maximumPageResponseSize else {
            throw XboxCloudCatalogError.responseTooLarge(.titles)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw XboxCloudCatalogError.httpFailure(
                operation: .titles,
                statusCode: response.statusCode,
                serviceCode: Self.serviceCode(from: data)
            )
        }
        return data
    }

    private func fetchFresnoProductMetadataData(
        market: String,
        localeIdentifier: String,
        productIDs: [String]
    ) async throws -> Data {
        let normalizedLocale = localeIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-")
        )
        let productIDCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        guard !normalizedLocale.isEmpty,
              normalizedLocale.utf8.count <= 64,
              normalizedLocale.unicodeScalars.allSatisfy(allowedCharacters.contains),
              !productIDs.isEmpty,
              productIDs.count <= Self.maximumFresnoProductCount,
              productIDs.allSatisfy({ productID in
                  guard let normalizedProductID = Self.safeIdentifier(productID) else {
                      return false
                  }
                  return normalizedProductID.unicodeScalars.allSatisfy(
                      productIDCharacters.contains
                  )
              }),
              var components = URLComponents(
                  url: Self.gamePassCatalogURL,
                  resolvingAgainstBaseURL: false
              )
        else {
            throw XboxCloudCatalogError.invalidConfiguration
        }
        components.queryItems = [
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "language", value: normalizedLocale),
            URLQueryItem(name: "hydration", value: "RemoteLowJade0"),
        ]
        guard let endpoint = components.url,
              endpoint.scheme == "https",
              endpoint.host == "catalog.gamepass.com",
              endpoint.path == "/v3/products",
              endpoint.absoluteString.utf8.count <= 8192
        else {
            throw XboxCloudCatalogError.invalidConfiguration
        }
        let body: Data
        do {
            body = try JSONSerialization.data(
                withJSONObject: ["Products": productIDs],
                options: [.sortedKeys]
            )
        } catch {
            throw XboxCloudCatalogError.invalidConfiguration
        }
        guard body.count <= Self.maximumFresnoRequestSize else {
            throw XboxCloudCatalogError.invalidConfiguration
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            Self.gamePassCatalogCallingAppName,
            forHTTPHeaderField: "Calling-App-Name"
        )
        request.setValue(
            Self.gamePassCatalogCallingAppVersion,
            forHTTPHeaderField: "Calling-App-Version"
        )
        request.setValue(Self.newCorrelationVector(), forHTTPHeaderField: "MS-CV")
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
            throw XboxCloudCatalogError.transportFailure(.metadata)
        }
        guard let response = response as? HTTPURLResponse else {
            throw XboxCloudCatalogError.invalidResponse(.metadata)
        }
        guard data.count <= Self.maximumFresnoMetadataResponseSize else {
            throw XboxCloudCatalogError.responseTooLarge(.metadata)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw XboxCloudCatalogError.httpFailure(
                operation: .metadata,
                statusCode: response.statusCode,
                serviceCode: Self.serviceCode(from: data)
            )
        }
        return data
    }

    private static func parseFresnoProductMetadata(
        _ data: Data
    ) throws -> [String: XboxFresnoProductMetadata] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let products = object["Products"] as? [String: Any],
              products.count <= Self.maximumFresnoProductCount
        else {
            throw XboxCloudCatalogError.invalidPayload(.metadata)
        }

        var metadataByProductID: [String: XboxFresnoProductMetadata] = [:]
        metadataByProductID.reserveCapacity(products.count)
        for (wireProductID, value) in products {
            guard let product = value as? [String: Any],
                  let productID = safeIdentifier(product["StoreId"])
                  ?? safeIdentifier(wireProductID),
                  let title = safeTitle(product["ProductTitle"])
            else {
                continue
            }
            let artworkURL = safeGamePassCatalogArtworkURL(
                (product["Image_Poster"] as? [String: Any])?["URL"]
            ) ?? safeGamePassCatalogArtworkURL(
                (product["Image_Tile"] as? [String: Any])?["URL"]
            )
            metadataByProductID[productID.uppercased()] = XboxFresnoProductMetadata(
                title: title,
                artworkURL: artworkURL
            )
        }
        return metadataByProductID
    }

    private static func shouldRetryFresnoMetadataInSmallerBatches(
        _ error: Error
    ) -> Bool {
        guard let error = error as? XboxCloudCatalogError else { return false }
        switch error {
        case .responseTooLarge(.metadata), .invalidPayload(.metadata):
            return true
        case let .httpFailure(.metadata, statusCode, _):
            return [400, 413, 414, 422].contains(statusCode)
        default:
            return false
        }
    }

    private static func parseFresnoItems(
        _ data: Data,
        orderedProductIDs: [String],
        productAccessByProductID: [String: XboxProductCloudAccess],
        metadataByProductID: [String: XboxFresnoProductMetadata]
    ) throws -> [XboxCatalogItem] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [Any],
              results.count <= maximumResultsPerPage
        else {
            throw XboxCloudCatalogError.invalidPayload(.titles)
        }

        var itemsByProductID: [String: [XboxCatalogItem]] = [:]
        var entitlementFalseCount = 0
        var ownedMatchCount = 0
        var explicitEligibilityHintCount = 0
        var invalidShapeCount = 0
        var missingTitleIDCount = 0
        var missingProductIDCount = 0
        var missingMetadataCount = 0
        for result in results {
            guard let object = result as? [String: Any],
                  let details = object["details"] as? [String: Any]
            else {
                invalidShapeCount += 1
                continue
            }
            guard let titleID = safeIdentifier(object["titleId"])
                ?? safeIdentifier(details["titleId"])
            else {
                missingTitleIDCount += 1
                continue
            }
            guard let productID = safeIdentifier(details["productId"])
                ?? safeIdentifier(object["productId"])
            else {
                missingProductIDCount += 1
                continue
            }
            let normalizedProductID = productID.uppercased()
            guard let metadata = metadataByProductID[normalizedProductID] else {
                missingMetadataCount += 1
                continue
            }
            let access = productAccessByProductID[normalizedProductID]
            let hasFerdinandMetadata = hasExclusiveFerdinandProgram(details)
            let hasPlayableTime = hasRemainingGameplayTime(
                details["remainingGameplayTimeInSeconds"]
            )
            let hasEntitlement = hasPlayableEntitlement(details["hasEntitlement"])
            let hasExplicitEligibilityHints = hasEntitlement
                && hasFerdinandMetadata
                && hasPlayableTime
            if !hasEntitlement {
                entitlementFalseCount += 1
            }
            if access?.isOwned == true {
                ownedMatchCount += 1
            }
            if hasExplicitEligibilityHints {
                explicitEligibilityHintCount += 1
            }
            itemsByProductID[normalizedProductID, default: []].append(
                XboxCatalogItem(
                    id: productID,
                    title: metadata.title,
                    artworkURL: metadata.artworkURL
                        ?? artworkURL(from: object, details: details),
                    routes: [
                        XboxCloudTitleRoute(
                            titleID: titleID,
                            accessKind: .freeWithAds
                        ),
                    ]
                )
            )
        }

        var orderedItems: [XboxCatalogItem] = []
        for productID in orderedProductIDs {
            orderedItems.append(
                contentsOf: itemsByProductID[productID.uppercased()] ?? []
            )
        }
        xboxCatalogLog.info(
            "Fresno titles raw=\(results.count, privacy: .public) matched=\(orderedItems.count, privacy: .public) invalidShape=\(invalidShapeCount, privacy: .public) missingTitleID=\(missingTitleIDCount, privacy: .public) missingProductID=\(missingProductIDCount, privacy: .public) missingMetadata=\(missingMetadataCount, privacy: .public) ownedMatches=\(ownedMatchCount, privacy: .public) entitlementFalse=\(entitlementFalseCount, privacy: .public) explicitEligibilityHints=\(explicitEligibilityHintCount, privacy: .public)"
        )
        return orderedItems
    }

    private func retainedSnapshot(
        from wireItems: [XboxCatalogItem]
    ) -> XboxCatalogSnapshot {
        let fetchedAt = now()
        let mergedSnapshot = XboxCatalogSnapshot(
            items: wireItems,
            fetchedAt: fetchedAt
        )
        let snapshot = if mergedSnapshot.items.count > policy.maximumItemCount {
            XboxCatalogSnapshot(
                items: Array(mergedSnapshot.items.prefix(policy.maximumItemCount)),
                fetchedAt: fetchedAt
            )
        } else {
            mergedSnapshot
        }
        let standardRouteCount = snapshot.items.reduce(into: 0) { count, item in
            count += item.routes.count { $0.accessKind == .standard }
        }
        let freeWithAdsRouteCount = snapshot.items.reduce(into: 0) { count, item in
            count += item.routes.count { $0.accessKind == .freeWithAds }
        }
        xboxCatalogLog.info(
            "Catalog complete products=\(snapshot.items.count, privacy: .public) standardRoutes=\(standardRouteCount, privacy: .public) freeWithAdsRoutes=\(freeWithAdsRouteCount, privacy: .public)"
        )
        return snapshot
    }

    private func fetchPage(
        baseURL: URL,
        market: String,
        continuationToken: String?,
        gsToken: String
    ) async throws -> XboxCloudCatalogPage {
        let endpoint = try Self.titlesEndpoint(
            baseURL: baseURL,
            market: market,
            continuationToken: continuationToken
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(gsToken)", forHTTPHeaderField: "Authorization")
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
            throw XboxCloudCatalogError.transportFailure(.titles)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw XboxCloudCatalogError.invalidResponse(.titles)
        }
        guard data.count <= policy.maximumPageResponseSize else {
            throw XboxCloudCatalogError.responseTooLarge(.titles)
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw XboxCloudCatalogError.httpFailure(
                operation: .titles,
                statusCode: httpResponse.statusCode,
                serviceCode: Self.serviceCode(from: data)
            )
        }
        return try Self.parsePage(data)
    }

    private static func parsePage(_ data: Data) throws -> XboxCloudCatalogPage {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [Any],
              results.count <= maximumResultsPerPage
        else {
            throw XboxCloudCatalogError.invalidPayload(.titles)
        }

        var diagnostics = XboxCloudCatalogParseDiagnostics()
        var items: [XboxCatalogItem] = []
        items.reserveCapacity(results.count)
        for result in results {
            switch parseItem(result) {
            case let .accepted(item):
                diagnostics.record(item)
                items.append(item)
            case let .rejected(reason):
                diagnostics.record(reason)
            }
        }
        xboxCatalogLog.info(
            "Catalog page raw=\(results.count, privacy: .public) accepted=\(items.count, privacy: .public) standard=\(diagnostics.standardCount, privacy: .public) freeWithAds=\(diagnostics.freeWithAdsCount, privacy: .public) rejectedShape=\(diagnostics.invalidShapeCount, privacy: .public) rejectedEntitlement=\(diagnostics.entitlementCount, privacy: .public) rejectedTime=\(diagnostics.remainingTimeCount, privacy: .public) rejectedIdentity=\(diagnostics.identityCount, privacy: .public) rejectedPrograms=\(diagnostics.accessMetadataCount, privacy: .public)"
        )
        let continuationToken = try parseContinuationToken(from: object)
        return XboxCloudCatalogPage(
            items: items,
            rawResultCount: results.count,
            continuationToken: continuationToken
        )
    }

    private static func parseItem(_ value: Any) -> XboxCloudCatalogItemParseResult {
        guard let object = value as? [String: Any],
              let details = object["details"] as? [String: Any]
        else {
            return .rejected(.invalidShape)
        }
        guard hasPlayableEntitlement(details["hasEntitlement"]) else {
            return .rejected(.entitlement)
        }
        guard hasRemainingGameplayTime(details["remainingGameplayTimeInSeconds"]) else {
            return .rejected(.remainingTime)
        }

        let titleID = safeIdentifier(object["titleId"])
            ?? safeIdentifier(details["titleId"])
        let productID = safeIdentifier(details["productId"])
            ?? safeIdentifier(object["productId"])
        let title = safeTitle(details["name"])
            ?? safeTitle(details["title"])
            ?? safeTitle(object["name"])
            ?? safeTitle(object["title"])
        guard let titleID,
              let title
        else {
            return .rejected(.identity)
        }
        guard let accessKind = accessKind(from: details) else {
            return .rejected(.accessMetadata)
        }

        return .accepted(
            XboxCatalogItem(
                id: productID ?? titleID,
                title: title,
                artworkURL: artworkURL(from: object, details: details),
                routes: [
                    XboxCloudTitleRoute(
                        titleID: titleID,
                        accessKind: accessKind
                    ),
                ]
            )
        )
    }

    private static func hasPlayableEntitlement(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
            return false
        }
        return number.boolValue
    }

    private static func hasRemainingGameplayTime(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return false
        }
        let seconds = number.doubleValue
        return seconds.isFinite && seconds > 0
    }

    private static func accessKind(
        from details: [String: Any]?
    ) -> XboxCloudAccessKind? {
        guard let rawPrograms = details?["userPrograms"] else {
            return .standard
        }
        guard let values = rawPrograms as? [Any],
              values.count <= maximumUserProgramCount
        else {
            return nil
        }

        var hasFerdinand = false
        for value in values {
            let identifier: String
            if let string = value as? String {
                identifier = string
            } else if let object = value as? [String: Any] {
                guard let objectIdentifier = object["id"] as? String
                    ?? object["name"] as? String
                    ?? object["programId"] as? String
                else {
                    return nil
                }
                identifier = objectIdentifier
            } else {
                return nil
            }

            let normalizedIdentifier = identifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedIdentifier.isEmpty,
                  normalizedIdentifier.utf8.count <= 256,
                  normalizedIdentifier.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  })
            else {
                return nil
            }
            if normalizedIdentifier.caseInsensitiveCompare("FERDINAND") == .orderedSame {
                hasFerdinand = true
            }
        }
        return values.count == 1 && hasFerdinand ? .freeWithAds : .standard
    }

    private static func hasExclusiveFerdinandProgram(
        _ details: [String: Any]
    ) -> Bool {
        accessKind(from: details) == .freeWithAds
    }

    private static func artworkURL(
        from object: [String: Any],
        details: [String: Any]?
    ) -> URL? {
        let directValues = [
            details?["artworkUrl"],
            details?["imageUrl"],
            details?["posterUrl"],
            object["artworkUrl"],
            object["imageUrl"],
        ]
        for value in directValues {
            if let url = safeArtworkURL(value) {
                return url
            }
        }

        let imageValues = details?["images"] as? [Any]
            ?? object["images"] as? [Any]
            ?? []
        guard imageValues.count <= maximumImageCountPerTitle else { return nil }

        let preferredTypes = ["poster", "boxart", "tile", "superheroart"]
        let images = imageValues.compactMap { value -> (type: String, url: URL)? in
            guard let image = value as? [String: Any],
                  let url = safeArtworkURL(image["url"] ?? image["uri"])
            else {
                return nil
            }
            return ((image["type"] as? String)?.lowercased() ?? "", url)
        }
        return images.min { left, right in
            let leftRank = preferredTypes.firstIndex(of: left.type) ?? preferredTypes.count
            let rightRank = preferredTypes.firstIndex(of: right.type) ?? preferredTypes.count
            return leftRank < rightRank
        }?.url
    }

    private static func parseContinuationToken(
        from object: [String: Any]
    ) throws -> String? {
        let values = [
            object["continuationToken"],
            object["continuation"],
            object["nextContinuationToken"],
        ]
        for value in values {
            let rawToken: String? = if let string = value as? String {
                string
            } else if let dictionary = value as? [String: Any] {
                dictionary["token"] as? String
            } else {
                nil
            }
            guard let rawToken else { continue }
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return nil }
            guard token.utf8.count <= maximumContinuationTokenSize,
                  token.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  })
            else {
                throw XboxCloudCatalogError.invalidPayload(.titles)
            }
            return token
        }
        return nil
    }

    private static func titlesEndpoint(
        baseURL: URL,
        market: String,
        continuationToken: String?
    ) throws -> URL {
        guard baseURL.scheme?.lowercased() == "https",
              let host = baseURL.host?.lowercased(),
              host == "xboxlive.com" || host.hasSuffix(".xboxlive.com"),
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.port == nil
        else {
            throw XboxCloudCatalogError.invalidConfiguration
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/v2/titles"
        var queryItems = [URLQueryItem(name: "mr", value: market)]
        if let continuationToken {
            queryItems.append(URLQueryItem(name: "ct", value: continuationToken))
        }
        components?.queryItems = queryItems
        guard let endpoint = components?.url,
              endpoint.absoluteString.utf8.count <= 8192
        else {
            throw XboxCloudCatalogError.invalidConfiguration
        }
        return endpoint
    }

    private static func validatedMarket(_ market: String) throws -> String {
        let normalized = market.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        guard !normalized.isEmpty,
              normalized.utf8.count <= 32,
              normalized.unicodeScalars.allSatisfy(allowedCharacters.contains)
        else {
            throw XboxCloudCatalogError.invalidMarket
        }
        return normalized
    }

    private static func safeIdentifier(_ value: Any?) -> String? {
        let rawValue: String? = if let string = value as? String {
            string
        } else if let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID()
        {
            number.stringValue
        } else {
            nil
        }
        guard let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty,
              normalized.utf8.count <= 512,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        return normalized
    }

    private static func safeTitle(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 1024,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        return normalized
    }

    private static func safeArtworkURL(_ value: Any?) -> URL? {
        guard let string = value as? String,
              string.utf8.count <= 2048,
              let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil
        else {
            return nil
        }
        return url
    }

    private static func safeGamePassCatalogArtworkURL(_ value: Any?) -> URL? {
        guard let string = value as? String else { return nil }
        let absoluteString = string.hasPrefix("//") ? "https:\(string)" : string
        return safeArtworkURL(absoluteString)
    }

    private static func newCorrelationVector() -> String {
        var bytes = UUID().uuid
        let seed = withUnsafeBytes(of: &bytes) { buffer in
            Data(buffer).base64EncodedString()
        }
        return "\(seed.dropLast(2)).0"
    }

    private static func serviceCode(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let rawCode = object["code"] as? String
            ?? (object["error"] as? [String: Any])?["code"] as? String
            ?? (object["errorDetails"] as? [String: Any])?["code"] as? String
        guard let code = rawCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty,
              code.utf8.count <= 128,
              code.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(
                      CharacterSet(charactersIn: "-._:/")
                  ).contains($0)
              })
        else {
            return nil
        }
        return code
    }
}

private nonisolated enum XboxCloudCatalogItemRejection: Sendable {
    case invalidShape
    case entitlement
    case remainingTime
    case identity
    case accessMetadata
}

private nonisolated enum XboxCloudCatalogItemParseResult: Sendable {
    case accepted(XboxCatalogItem)
    case rejected(XboxCloudCatalogItemRejection)
}

private nonisolated struct XboxCloudCatalogParseDiagnostics: Sendable {
    private(set) var standardCount = 0
    private(set) var freeWithAdsCount = 0
    private(set) var invalidShapeCount = 0
    private(set) var entitlementCount = 0
    private(set) var remainingTimeCount = 0
    private(set) var identityCount = 0
    private(set) var accessMetadataCount = 0

    mutating func record(_ item: XboxCatalogItem) {
        for route in item.routes {
            switch route.accessKind {
            case .standard:
                standardCount += 1
            case .freeWithAds:
                freeWithAdsCount += 1
            }
        }
    }

    mutating func record(_ rejection: XboxCloudCatalogItemRejection) {
        switch rejection {
        case .invalidShape:
            invalidShapeCount += 1
        case .entitlement:
            entitlementCount += 1
        case .remainingTime:
            remainingTimeCount += 1
        case .identity:
            identityCount += 1
        case .accessMetadata:
            accessMetadataCount += 1
        }
    }
}

private nonisolated struct XboxCloudCatalogPage: Sendable {
    let items: [XboxCatalogItem]
    let rawResultCount: Int
    let continuationToken: String?
}

private final nonisolated class XboxCloudCatalogCancellationState: Sendable {
    private struct State: Sendable {
        var identifier: UUID?
        var operation: Task<XboxCatalogSnapshot, Error>?
    }

    private let state = Mutex(State())

    func replaceCurrentOperation(
        with operation: Task<XboxCatalogSnapshot, Error>
    ) -> UUID {
        let identifier = UUID()
        let previousOperation = state.withLock { state in
            let previousOperation = state.operation
            state.identifier = identifier
            state.operation = operation
            return previousOperation
        }
        previousOperation?.cancel()
        return identifier
    }

    func clearOperation(identifier: UUID) {
        state.withLock { state in
            guard state.identifier == identifier else { return }
            state.identifier = nil
            state.operation = nil
        }
    }

    func cancelOperation(identifier: UUID) {
        let operation = state.withLock { state -> Task<XboxCatalogSnapshot, Error>? in
            guard state.identifier == identifier else { return nil }
            state.identifier = nil
            defer { state.operation = nil }
            return state.operation
        }
        operation?.cancel()
    }

    func cancelCurrentOperation() {
        let operation = state.withLock { state -> Task<XboxCatalogSnapshot, Error>? in
            state.identifier = nil
            defer { state.operation = nil }
            return state.operation
        }
        operation?.cancel()
    }
}
