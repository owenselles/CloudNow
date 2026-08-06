import Foundation

/// Loads the large Microsoft Store document only for the carousel item the
/// user is inspecting. Catalog startup stays on the much smaller Game Pass
/// projection; rich descriptions and screenshots never fan out across the
/// entire library.
nonisolated struct XboxCloudCatalogDetailLoader: Sendable {
    private static let endpoint: URL = {
        guard let url = URL(
            string: "https://displaycatalog.mp.microsoft.com/v7.0/products"
        ) else {
            preconditionFailure("CloudNow's Xbox detail URL is invalid.")
        }
        return url
    }()

    private static let maximumResponseSize = 4 * 1024 * 1024
    private static let maximumProductIDSize = 128
    private static let maximumLocalizedPropertyCount = 16
    private static let maximumWireImageCount = 128
    private static let maximumMarketPropertyCount = 16
    private static let maximumContentRatingCount = 64
    private static let maximumScreenshotCount = 8

    let transport: any HTTPTransport

    func fetchDetail(
        for item: XboxCatalogItem,
        request: XboxCatalogRequest
    ) async throws -> XboxCatalogItem {
        let endpoint = try Self.detailEndpoint(
            productID: item.id,
            localeIdentifier: request.localeIdentifier,
            market: request.market
        )
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "GET"
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let data: Data
        let response: URLResponse
        do {
            try Task.checkCancellation()
            (data, response) = try await transport.data(
                for: urlRequest,
                maximumResponseSize: Self.maximumResponseSize
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch HTTPTransportError.responseTooLarge {
            throw XboxCloudCatalogError.responseTooLarge(.metadata)
        } catch {
            throw XboxCloudCatalogError.transportFailure(.metadata)
        }
        guard let response = response as? HTTPURLResponse else {
            throw XboxCloudCatalogError.invalidResponse(.metadata)
        }
        guard data.count <= Self.maximumResponseSize else {
            throw XboxCloudCatalogError.responseTooLarge(.metadata)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw XboxCloudCatalogError.httpFailure(
                operation: .metadata,
                statusCode: response.statusCode,
                serviceCode: nil
            )
        }
        return try Self.parseDetail(data, mergingInto: item)
    }

    private static func detailEndpoint(
        productID: String,
        localeIdentifier: String,
        market: String?
    ) throws -> URL {
        let normalizedProductID = productID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedLocale = localeIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        let normalizedMarket = (market ?? "US")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let localeCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-")
        )
        let identifierCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        guard !normalizedProductID.isEmpty,
              normalizedProductID.utf8.count <= Self.maximumProductIDSize,
              normalizedProductID.unicodeScalars.allSatisfy(
                  identifierCharacters.contains
              ),
              !normalizedLocale.isEmpty,
              normalizedLocale.utf8.count <= 64,
              normalizedLocale.unicodeScalars.allSatisfy(
                  localeCharacters.contains
              ),
              !normalizedMarket.isEmpty,
              normalizedMarket.utf8.count <= 32,
              normalizedMarket.unicodeScalars.allSatisfy(
                  localeCharacters.contains
              ),
              var components = URLComponents(
                  url: Self.endpoint,
                  resolvingAgainstBaseURL: false
              )
        else {
            throw XboxCloudCatalogError.invalidConfiguration
        }
        components.queryItems = [
            URLQueryItem(name: "bigIds", value: normalizedProductID),
            URLQueryItem(name: "market", value: normalizedMarket),
            URLQueryItem(name: "languages", value: normalizedLocale),
            URLQueryItem(name: "MS-CV", value: newCorrelationVector()),
        ]
        guard let url = components.url,
              url.scheme == "https",
              url.host == "displaycatalog.mp.microsoft.com",
              url.path == "/v7.0/products",
              url.absoluteString.utf8.count <= 8192
        else {
            throw XboxCloudCatalogError.invalidConfiguration
        }
        return url
    }

    private static func parseDetail(
        _ data: Data,
        mergingInto item: XboxCatalogItem
    ) throws -> XboxCatalogItem {
        guard let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
            let products = object["Products"] as? [Any],
            products.count <= 4
        else {
            throw XboxCloudCatalogError.invalidPayload(.metadata)
        }
        let productDictionaries = products.compactMap { $0 as? [String: Any] }
        guard productDictionaries.count == products.count,
              let product = productDictionaries.first(where: {
                  safeIdentifier($0["ProductId"])?
                      .caseInsensitiveCompare(item.id) == .orderedSame
              })
        else {
            throw XboxCloudCatalogError.invalidPayload(.metadata)
        }

        let localizedValues = product["LocalizedProperties"] as? [Any] ?? []
        guard localizedValues.count <= maximumLocalizedPropertyCount else {
            throw XboxCloudCatalogError.invalidPayload(.metadata)
        }
        let localizedProperties = localizedValues.compactMap {
            $0 as? [String: Any]
        }
        guard localizedProperties.count == localizedValues.count else {
            throw XboxCloudCatalogError.invalidPayload(.metadata)
        }
        let localized = localizedProperties.first
        let imageValues = localized?["Images"] as? [Any] ?? []
        let images = imageValues
            .prefix(maximumWireImageCount)
            .compactMap { $0 as? [String: Any] }
        var seenScreenshotURLs = Set<String>()
        let screenshots = images.compactMap { image -> URL? in
            guard safeText(image["ImagePurpose"], maximumSize: 64)?
                .caseInsensitiveCompare("Screenshot") == .orderedSame,
                let url = safeArtworkURL(image["Uri"]),
                seenScreenshotURLs.insert(url.absoluteString).inserted
            else {
                return nil
            }
            return url
        }
        let heroArtworkURL = preferredArtworkURL(
            in: images,
            purposes: [
                "SuperHeroArt",
                "TitledHeroArt",
                "Hero",
                "BrandedKeyArt",
            ]
        )
        let artworkURL = preferredArtworkURL(
            in: images,
            purposes: ["Poster", "BoxArt", "BrandedKeyArt"]
        )

        return XboxCatalogItem(
            id: item.id,
            title: item.title,
            longDescription: safeText(
                localized?["ProductDescription"],
                maximumSize: 32768,
                allowsNewlines: true
            ) ?? item.longDescription,
            genres: item.genres,
            developer: safeText(
                localized?["DeveloperName"],
                maximumSize: 1024
            ) ?? item.developer,
            publisher: safeText(
                localized?["PublisherName"],
                maximumSize: 1024
            ) ?? item.publisher,
            contentRating: contentRating(from: product)
                ?? item.contentRating,
            artworkURL: item.artworkURL ?? artworkURL,
            heroArtworkURL: heroArtworkURL ?? item.heroArtworkURL,
            screenshotURLs: screenshots.isEmpty
                ? item.screenshotURLs
                : Array(screenshots.prefix(maximumScreenshotCount)),
            supportedInputTypes: item.supportedInputTypes,
            isOwned: item.isOwned,
            routes: item.routes
        )
    }

    private static func contentRating(
        from product: [String: Any]
    ) -> String? {
        let marketProperties = (product["MarketProperties"] as? [Any])?
            .prefix(maximumMarketPropertyCount)
            .compactMap { $0 as? [String: Any] }
            .first
        let rating = (marketProperties?["ContentRatings"] as? [Any])?
            .prefix(maximumContentRatingCount)
            .compactMap { $0 as? [String: Any] }
            .first
        let system = safeText(rating?["RatingSystem"], maximumSize: 64)
        let identifier = safeText(rating?["RatingId"], maximumSize: 128)?
            .replacingOccurrences(of: ":", with: " ")
        if let identifier, let system,
           !identifier.localizedCaseInsensitiveContains(system)
        {
            return "\(system) \(identifier)"
        }
        if let identifier {
            return identifier
        }
        if let age = marketProperties?["MinimumUserAge"] as? NSNumber,
           age.intValue >= 0,
           age.intValue <= 120
        {
            return "\(age.intValue)+"
        }
        return nil
    }

    private static func preferredArtworkURL(
        in images: [[String: Any]],
        purposes: [String]
    ) -> URL? {
        for purpose in purposes {
            if let image = images.first(where: {
                safeText($0["ImagePurpose"], maximumSize: 64)?
                    .caseInsensitiveCompare(purpose) == .orderedSame
            }), let url = safeArtworkURL(image["Uri"]) {
                return url
            }
        }
        return nil
    }

    private static func safeIdentifier(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumProductIDSize,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        return normalized
    }

    private static func safeText(
        _ value: Any?,
        maximumSize: Int,
        allowsNewlines: Bool = false
    ) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let disallowedControls = allowsNewlines
            ? CharacterSet.controlCharacters.subtracting(
                CharacterSet(charactersIn: "\r\n")
            )
            : CharacterSet.controlCharacters
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumSize,
              normalized.unicodeScalars.allSatisfy({
                  !disallowedControls.contains($0)
              })
        else {
            return nil
        }
        return normalized
    }

    private static func safeArtworkURL(_ value: Any?) -> URL? {
        guard let value = value as? String else { return nil }
        return XboxArtworkURLPolicy.validatedURL(
            from: value,
            allowsProtocolRelativeURL: true
        )
    }

    private static func newCorrelationVector() -> String {
        var bytes = UUID().uuid
        let seed = withUnsafeBytes(of: &bytes) { buffer in
            Data(buffer).base64EncodedString()
        }
        return "\(seed.dropLast(2)).0"
    }
}
