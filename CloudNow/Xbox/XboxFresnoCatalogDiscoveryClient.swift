import Foundation

nonisolated struct XboxFresnoCatalogDiscoverySnapshot: Equatable, Sendable {
    let productIDs: [String]
    let fetchedAt: Date
}

nonisolated protocol XboxFresnoCatalogDiscovering: Sendable {
    func fetchProductIDs(
        market: String,
        localeIdentifier: String,
        activeSubscriptionProductIDs: [String]
    ) async throws -> XboxFresnoCatalogDiscoverySnapshot
}

nonisolated enum XboxFresnoCatalogDiscoveryError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case invalidPayload
    case httpFailure(statusCode: Int)
    case transportFailure
}

/// Public, credential-free discovery for Microsoft's current Fresno catalog
/// rails. The response contributes product identifiers only; authenticated
/// title metadata and Content Access remain authoritative for playability.
nonisolated struct XboxFresnoCatalogDiscoveryClient: XboxFresnoCatalogDiscovering, Sendable {
    private static let compatibilityProfile = XboxCloudCompatibilityProfile.bundledV1
    private static let maximumResponseBytes = 1_048_576
    private static let maximumProductCountPerRail = 4096
    private static let maximumSubscriptionProductCount = 128

    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    init(
        transport: any HTTPTransport = URLSessionHTTPTransport(configuration: .ephemeral),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.now = now
    }

    func fetchProductIDs(
        market: String,
        localeIdentifier: String,
        activeSubscriptionProductIDs: [String]
    ) async throws -> XboxFresnoCatalogDiscoverySnapshot {
        let requestContext = try Self.validatedRequestContext(
            market: market,
            localeIdentifier: localeIdentifier,
            activeSubscriptionProductIDs: activeSubscriptionProductIDs
        )

        let productIDs = try await fetchRail(
            id: Self.compatibilityProfile.fresnoStreamWithAdsRailID,
            requestContext: requestContext
        )
        var retainedProductIDs: [String] = []
        retainedProductIDs.reserveCapacity(productIDs.count)
        var seenProductIDs = Set<String>()
        for productID in productIDs {
            let normalizedProductID = productID.uppercased()
            if seenProductIDs.insert(normalizedProductID).inserted {
                retainedProductIDs.append(productID)
            }
        }
        return XboxFresnoCatalogDiscoverySnapshot(
            productIDs: retainedProductIDs,
            fetchedAt: now()
        )
    }

    private func fetchRail(
        id: String,
        requestContext: XboxFresnoCatalogRequestContext
    ) async throws -> [String] {
        let endpoint = try Self.endpoint(
            railID: id,
            requestContext: requestContext
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let data: Data
        let response: URLResponse
        do {
            try Task.checkCancellation()
            (data, response) = try await transport.data(
                for: request,
                maximumResponseSize: Self.maximumResponseBytes
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch HTTPTransportError.responseTooLarge {
            throw XboxFresnoCatalogDiscoveryError.responseTooLarge
        } catch {
            throw XboxFresnoCatalogDiscoveryError.transportFailure
        }
        guard let response = response as? HTTPURLResponse else {
            throw XboxFresnoCatalogDiscoveryError.invalidResponse
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw XboxFresnoCatalogDiscoveryError.httpFailure(
                statusCode: response.statusCode
            )
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw XboxFresnoCatalogDiscoveryError.responseTooLarge
        }
        return try Self.parseProductIDs(data)
    }

    private static func parseProductIDs(_ data: Data) throws -> [String] {
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [Any],
              !values.isEmpty,
              values.count <= maximumProductCountPerRail + 1,
              values[0] is [String: Any]
        else {
            throw XboxFresnoCatalogDiscoveryError.invalidPayload
        }

        return try values.dropFirst().map { value in
            guard let object = value as? [String: Any],
                  let productID = safeProductID(object["id"])
            else {
                throw XboxFresnoCatalogDiscoveryError.invalidPayload
            }
            return productID
        }
    }

    private static func endpoint(
        railID: String,
        requestContext: XboxFresnoCatalogRequestContext
    ) throws -> URL {
        guard var components = URLComponents(
            url: compatibilityProfile.fresnoCatalogURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw XboxFresnoCatalogDiscoveryError.invalidConfiguration
        }
        var queryItems = [
            URLQueryItem(name: "id", value: railID),
            URLQueryItem(name: "market", value: requestContext.market),
            URLQueryItem(name: "language", value: requestContext.localeIdentifier),
            URLQueryItem(
                name: "platformContext",
                value: compatibilityProfile.fresnoPlatformContext
            ),
        ]
        queryItems.append(
            URLQueryItem(
                name: "subscriptionContext",
                value: requestContext.activeSubscriptionProductIDs.isEmpty
                    ? "none"
                    : requestContext.activeSubscriptionProductIDs.joined(separator: ";")
            )
        )
        components.queryItems = queryItems
        guard let endpoint = components.url,
              endpoint.scheme == compatibilityProfile.fresnoCatalogURL.scheme,
              endpoint.host == compatibilityProfile.fresnoCatalogURL.host,
              endpoint.path == compatibilityProfile.fresnoCatalogURL.path,
              endpoint.absoluteString.utf8.count <= 8192
        else {
            throw XboxFresnoCatalogDiscoveryError.invalidConfiguration
        }
        return endpoint
    }

    private static func validatedRequestContext(
        market: String,
        localeIdentifier: String,
        activeSubscriptionProductIDs: [String]
    ) throws -> XboxFresnoCatalogRequestContext {
        let normalizedMarket = market
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let normalizedLocale = localeIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        let identifierCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        guard !normalizedMarket.isEmpty,
              normalizedMarket.utf8.count <= 32,
              normalizedMarket.unicodeScalars.allSatisfy(identifierCharacters.contains),
              !normalizedLocale.isEmpty,
              normalizedLocale.utf8.count <= 64,
              normalizedLocale.unicodeScalars.allSatisfy(identifierCharacters.contains),
              activeSubscriptionProductIDs.count <= maximumSubscriptionProductCount
        else {
            throw XboxFresnoCatalogDiscoveryError.invalidRequest
        }

        var normalizedSubscriptionIDs = Set<String>()
        for productID in activeSubscriptionProductIDs {
            guard let normalizedProductID = safeProductID(productID) else {
                throw XboxFresnoCatalogDiscoveryError.invalidRequest
            }
            let canonicalProductID = normalizedProductID.uppercased()
            if compatibilityProfile.fresnoSupportedSubscriptionProductIDs
                .contains(canonicalProductID)
            {
                normalizedSubscriptionIDs.insert(canonicalProductID)
            }
        }
        return XboxFresnoCatalogRequestContext(
            market: normalizedMarket,
            localeIdentifier: normalizedLocale,
            activeSubscriptionProductIDs: normalizedSubscriptionIDs.sorted()
        )
    }

    private static func safeProductID(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        guard !normalizedValue.isEmpty,
              normalizedValue.utf8.count <= 128,
              normalizedValue.unicodeScalars.allSatisfy(allowedCharacters.contains)
        else {
            return nil
        }
        return normalizedValue
    }
}

private nonisolated struct XboxFresnoCatalogRequestContext: Sendable {
    let market: String
    let localeIdentifier: String
    let activeSubscriptionProductIDs: [String]
}
