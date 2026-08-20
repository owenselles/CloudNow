import Foundation

/// Readiness of the Xbox catalog and streaming runtime. Microsoft device-code
/// sign-in is configured independently so it can remain available while the
/// heavier provider clients stay lazy.
nonisolated enum XboxCloudAvailability: Equatable, Sendable {
    case awaitingMicrosoftConfiguration
    case configured

    var isEnabled: Bool {
        self == .configured
    }
}

/// Minimal CloudNow-owned catalog request. It makes no assumptions about a
/// private Xbox endpoint or wire format.
nonisolated struct XboxCatalogRequest: Equatable, Sendable {
    let localeIdentifier: String
    let market: String?
}

nonisolated enum XboxCloudAccessKind: String, Codable, Equatable, Hashable, Sendable {
    case standard
    case freeWithAds
}

nonisolated enum XboxCloudRouteAvailability: String, Codable, Equatable, Hashable, Sendable {
    case playable
    case requiresEligibility
}

/// Credential-free explanation for a route's current playability decision.
/// This keeps Fresno service hints and Content Access evidence available after
/// catalog merging without exposing account identifiers or raw service data.
nonisolated enum XboxCloudRoutePlayabilityReason: String, Codable, Equatable, Hashable, Sendable {
    case authenticatedCatalog
    case fresnoServiceConfirmed
    case contentAccessConfirmed
    case entitlementRequired
    case unsupportedStreamingProgram
    case gameplayTimeExhausted
    case eligibilityUnconfirmed
}

nonisolated enum XboxCloudInputType: String, CaseIterable, Codable, Hashable, Sendable {
    case controller
    case touch
    case mouseAndKeyboard

    init?(serviceValue: String) {
        let normalized = serviceValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter(\.isLetter)
        switch normalized {
        case "controller", "gamepad":
            self = .controller
        case "touch", "touchscreen":
            self = .touch
        case "keyboardandmouse", "keyboardmouse", "mkb", "mouseandkeyboard", "mousekeyboard":
            self = .mouseAndKeyboard
        default:
            return nil
        }
    }
}

nonisolated enum XboxArtworkURLPolicy {
    private static let maximumURLSize = 2048
    private static let trustedHostSuffixes = [
        "microsoft.com",
        "s-microsoft.com",
        "xboxlive.com",
        "xboxservices.com",
    ]
    private static let sensitiveQueryFragments = [
        "auth",
        "credential",
        "expires",
        "key",
        "policy",
        "secret",
        "sig",
        "token",
    ]

    static func validatedURL(
        from value: String,
        allowsProtocolRelativeURL: Bool = false
    ) -> URL? {
        let absoluteValue: String
        if value.hasPrefix("//") {
            guard allowsProtocolRelativeURL else { return nil }
            absoluteValue = "https:\(value)"
        } else {
            absoluteValue = value
        }
        guard absoluteValue.utf8.count <= maximumURLSize,
              let url = URL(string: absoluteValue),
              isApproved(url)
        else {
            return nil
        }
        return url
    }

    static func isApproved(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= maximumURLSize,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              trustedHostSuffixes.contains(where: { suffix in
                  host == suffix || host.hasSuffix(".\(suffix)")
              }),
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443
        else {
            return false
        }
        return URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems?.allSatisfy { queryItem in
            let name = queryItem.name.lowercased()
            return !sensitiveQueryFragments.contains { name.contains($0) }
        } ?? true
    }
}

/// The service title identifier and access path required to launch one catalog
/// product. A product can expose more than one route without changing its
/// stable catalog identity.
nonisolated struct XboxCloudTitleRoute: Codable, Equatable, Hashable, Sendable {
    let titleID: String
    let accessKind: XboxCloudAccessKind
    let availability: XboxCloudRouteAvailability
    let playabilityReason: XboxCloudRoutePlayabilityReason

    init(
        titleID: String,
        accessKind: XboxCloudAccessKind,
        availability: XboxCloudRouteAvailability = .playable,
        playabilityReason: XboxCloudRoutePlayabilityReason? = nil
    ) {
        self.titleID = titleID
        self.accessKind = accessKind
        self.availability = availability
        self.playabilityReason = playabilityReason ?? (
            availability == .playable
                ? .authenticatedCatalog
                : .eligibilityUnconfirmed
        )
    }

    var isPlayable: Bool {
        availability == .playable
    }
}

nonisolated struct XboxCatalogItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let longDescription: String?
    let genres: [String]
    let developer: String?
    let publisher: String?
    let contentRating: String?
    let artworkURL: URL?
    let heroArtworkURL: URL?
    let screenshotURLs: [URL]
    let supportedInputTypes: Set<XboxCloudInputType>
    let isOwned: Bool
    let routes: [XboxCloudTitleRoute]

    init(
        id: String,
        title: String,
        longDescription: String? = nil,
        genres: [String] = [],
        developer: String? = nil,
        publisher: String? = nil,
        contentRating: String? = nil,
        artworkURL: URL?,
        heroArtworkURL: URL? = nil,
        screenshotURLs: [URL] = [],
        supportedInputTypes: Set<XboxCloudInputType> = [],
        isOwned: Bool = false,
        routes: [XboxCloudTitleRoute]? = nil
    ) {
        self.id = id.uppercased()
        self.title = title
        self.longDescription = longDescription
        self.genres = genres
        self.developer = developer
        self.publisher = publisher
        self.contentRating = contentRating
        self.artworkURL = artworkURL
        self.heroArtworkURL = heroArtworkURL
        self.screenshotURLs = screenshotURLs
        self.supportedInputTypes = supportedInputTypes
        self.isOwned = isOwned
        self.routes = routes ?? [
            XboxCloudTitleRoute(
                titleID: id,
                accessKind: .standard
            ),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case longDescription
        case genres
        case developer
        case publisher
        case contentRating
        case artworkURL
        case heroArtworkURL
        case screenshotURLs
        case supportedInputTypes
        case isOwned
        case routes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            title: container.decode(String.self, forKey: .title),
            longDescription: container.decodeIfPresent(
                String.self,
                forKey: .longDescription
            ),
            genres: container.decode([String].self, forKey: .genres),
            developer: container.decodeIfPresent(
                String.self,
                forKey: .developer
            ),
            publisher: container.decodeIfPresent(
                String.self,
                forKey: .publisher
            ),
            contentRating: container.decodeIfPresent(
                String.self,
                forKey: .contentRating
            ),
            artworkURL: container.decodeIfPresent(
                URL.self,
                forKey: .artworkURL
            ),
            heroArtworkURL: container.decodeIfPresent(
                URL.self,
                forKey: .heroArtworkURL
            ),
            screenshotURLs: container.decode(
                [URL].self,
                forKey: .screenshotURLs
            ),
            supportedInputTypes: container.decode(
                Set<XboxCloudInputType>.self,
                forKey: .supportedInputTypes
            ),
            isOwned: container.decode(Bool.self, forKey: .isOwned),
            routes: container.decode(
                [XboxCloudTitleRoute].self,
                forKey: .routes
            )
        )
    }

    var accessKinds: Set<XboxCloudAccessKind> {
        Set(routes.map(\.accessKind))
    }

    var supportsFreeWithAds: Bool {
        routes.contains { $0.accessKind == .freeWithAds }
    }

    var preferredRoute: XboxCloudTitleRoute? {
        routes.min { left, right in
            if left.isPlayable != right.isPlayable {
                return left.isPlayable
            }
            if left.accessKind.launchPriority != right.accessKind.launchPriority {
                return left.accessKind.launchPriority < right.accessKind.launchPriority
            }
            return left.titleID < right.titleID
        }
    }

    fileprivate var normalizedIdentity: String {
        id.uppercased()
    }

    fileprivate var isSafeForPresentation: Bool {
        guard !id.isEmpty,
              id.utf8.count <= 512,
              !title.isEmpty,
              title.utf8.count <= 1024,
              Self.isSafeText(
                  longDescription,
                  maximumSize: 32768,
                  allowsNewlines: true
              ),
              genres.count <= 32,
              genres.allSatisfy({ Self.isSafeText($0, maximumSize: 256) }),
              Self.isSafeText(developer, maximumSize: 1024),
              Self.isSafeText(publisher, maximumSize: 1024),
              Self.isSafeText(contentRating, maximumSize: 256),
              screenshotURLs.count <= 12,
              !routes.isEmpty,
              routes.count <= 16,
              routes.allSatisfy(\.isSafeForPresentation)
        else {
            return false
        }
        let isArtworkApproved = artworkURL.map(
            XboxArtworkURLPolicy.isApproved
        ) ?? true
        let isHeroArtworkApproved = heroArtworkURL.map(
            XboxArtworkURLPolicy.isApproved
        ) ?? true
        return isArtworkApproved
            && isHeroArtworkApproved
            && screenshotURLs.allSatisfy(XboxArtworkURLPolicy.isApproved)
    }

    private static func isSafeText(
        _ value: String?,
        maximumSize: Int,
        allowsNewlines: Bool = false
    ) -> Bool {
        guard let value else { return true }
        let disallowedControls = allowsNewlines
            ? CharacterSet.controlCharacters.subtracting(
                CharacterSet(charactersIn: "\r\n")
            )
            : CharacterSet.controlCharacters
        return !value.isEmpty
            && value.utf8.count <= maximumSize
            && value.unicodeScalars.allSatisfy {
                !disallowedControls.contains($0)
            }
    }

    fileprivate func mergingRoutes(from other: XboxCatalogItem) -> XboxCatalogItem {
        guard normalizedIdentity == other.normalizedIdentity else { return self }

        var mergedRoutes = routes
        for route in other.routes {
            if let retainedIndex = mergedRoutes.firstIndex(where: {
                $0.representsSameLaunchPath(as: route)
            }) {
                if route.isPlayable, !mergedRoutes[retainedIndex].isPlayable {
                    mergedRoutes[retainedIndex] = route
                }
                continue
            }
            guard mergedRoutes.count < 16 else { continue }
            mergedRoutes.append(route)
        }
        return XboxCatalogItem(
            id: id,
            title: title,
            longDescription: longDescription ?? other.longDescription,
            genres: genres.isEmpty ? other.genres : genres,
            developer: developer ?? other.developer,
            publisher: publisher ?? other.publisher,
            contentRating: contentRating ?? other.contentRating,
            artworkURL: artworkURL ?? other.artworkURL,
            heroArtworkURL: heroArtworkURL ?? other.heroArtworkURL,
            screenshotURLs: screenshotURLs.isEmpty
                ? other.screenshotURLs
                : screenshotURLs,
            supportedInputTypes: supportedInputTypes
                .union(other.supportedInputTypes),
            isOwned: isOwned || other.isOwned,
            routes: mergedRoutes
        )
    }
}

private extension XboxCloudAccessKind {
    nonisolated var launchPriority: Int {
        switch self {
        case .standard:
            0
        case .freeWithAds:
            1
        }
    }
}

private extension XboxCloudTitleRoute {
    nonisolated func representsSameLaunchPath(
        as other: XboxCloudTitleRoute
    ) -> Bool {
        titleID == other.titleID && accessKind == other.accessKind
    }

    nonisolated var isSafeForPresentation: Bool {
        !titleID.isEmpty
            && titleID.utf8.count <= 512
            && titleID.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}

nonisolated struct XboxCatalogSnapshot: Codable, Equatable, Sendable {
    static let maximumRetainedItemCount = 4096

    let items: [XboxCatalogItem]
    let fetchedAt: Date

    init(items: [XboxCatalogItem], fetchedAt: Date) {
        var retainedItems: [XboxCatalogItem] = []
        retainedItems.reserveCapacity(
            min(items.count, Self.maximumRetainedItemCount)
        )
        var retainedIndexesByID: [String: Int] = [:]
        for item in items where item.isSafeForPresentation {
            if let retainedIndex = retainedIndexesByID[item.normalizedIdentity] {
                retainedItems[retainedIndex] = retainedItems[retainedIndex]
                    .mergingRoutes(from: item)
                continue
            }
            guard retainedItems.count < Self.maximumRetainedItemCount else {
                continue
            }
            retainedIndexesByID[item.normalizedIdentity] = retainedItems.count
            retainedItems.append(item)
        }
        self.items = retainedItems
        self.fetchedAt = fetchedAt
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case fetchedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedItems = try container.decode(
            [XboxCatalogItem].self,
            forKey: .items
        )
        let fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        guard fetchedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .fetchedAt,
                in: container,
                debugDescription: "Catalog timestamp must be finite."
            )
        }
        self.init(items: decodedItems, fetchedAt: fetchedAt)
        guard items.count == decodedItems.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .items,
                in: container,
                debugDescription: "Catalog cache contains invalid or duplicate items."
            )
        }
    }
}

/// Opaque account context returned after Xbox Live/XSTS authorization. A
/// generic Microsoft OAuth token is not enough to enter the Xbox runtime.
nonisolated struct XboxCloudAuthorizedAccount: Equatable, Sendable {
    let authorizationIdentifier: String
    let activityScopeIdentifier: String
    let displayName: String?
    let expiresAt: Date

    init(
        authorizationIdentifier: String,
        activityScopeIdentifier: String? = nil,
        displayName: String?,
        expiresAt: Date
    ) {
        self.authorizationIdentifier = authorizationIdentifier
        self.activityScopeIdentifier = activityScopeIdentifier
            ?? authorizationIdentifier
        self.displayName = displayName
        self.expiresAt = expiresAt
    }

    func isUsable(at date: Date) -> Bool {
        !authorizationIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
            && expiresAt > date
    }
}

/// Converts a generic Microsoft account token into explicit Xbox Cloud access.
/// Production uses CloudNow's memory-only Xbox Live/XSTS authorization client;
/// tests inject deterministic alternatives.
nonisolated protocol XboxCloudAccountAuthorizationClient: Sendable {
    func authorize(
        microsoftToken: MicrosoftOAuthToken
    ) async throws -> XboxCloudAuthorizedAccount
}

/// Lightweight lifecycle boundary for memory-only Xbox-derived credentials.
/// It is retained independently from lazy network clients so sign-out and a
/// full data reset can purge credentials without constructing a transport.
nonisolated protocol XboxLocalCredentialLifecycle: Sendable {
    func clearLocalCredentials() async
    func deactivateForInactiveProvider() async
}

nonisolated extension XboxLocalCredentialLifecycle {
    /// Implementations without provider-scoped retained state safely use a
    /// full credential clear when their provider becomes inactive.
    func deactivateForInactiveProvider() async {
        await clearLocalCredentials()
    }
}

/// Production and test implementations remain injected so the Xbox catalog is
/// lazy and provider switching can release transport work synchronously.
nonisolated protocol XboxCatalogClient: Sendable {
    func fetchCatalog(
        _ request: XboxCatalogRequest,
        account: XboxCloudAuthorizedAccount
    ) async throws -> XboxCatalogSnapshot

    /// Enriches one already-authorized catalog item on demand. The default
    /// keeps lightweight or test clients source-compatible.
    func fetchDetail(
        for item: XboxCatalogItem,
        request: XboxCatalogRequest
    ) async throws -> XboxCatalogItem

    /// Invalidates account-derived service state before an explicit refresh.
    /// Stateless and test clients use the default no-op implementation.
    func refreshAccountState(
        for account: XboxCloudAuthorizedAccount
    ) async

    /// Synchronously cancels provider-owned transport work and releases its
    /// heavy resources. Implementations must be idempotent and non-blocking.
    nonisolated func cancel()
}

extension XboxCatalogClient {
    nonisolated func fetchDetail(
        for item: XboxCatalogItem,
        request _: XboxCatalogRequest
    ) async throws -> XboxCatalogItem {
        item
    }

    nonisolated func refreshAccountState(
        for _: XboxCloudAuthorizedAccount
    ) async {}
}

/// Provider-scoped ownership that outlives the Xbox SwiftUI mode tree. A
/// retained controller carries only one resumable or deletion-quarantined
/// server allocation across provider switches.
nonisolated struct XboxCloudStreamControllerRetention: Sendable {
    static let none = XboxCloudStreamControllerRetention(
        retainedController: { _ in nil },
        retainController: { _, _ in },
        releaseController: { _ in }
    )

    let retainedController: @MainActor @Sendable (
        XboxCloudAuthorizedAccount
    ) -> XboxCloudStreamController?
    let retainController: @MainActor @Sendable (
        XboxCloudStreamController,
        XboxCloudAuthorizedAccount
    ) -> Void
    let releaseController: @MainActor @Sendable (
        XboxCloudStreamController
    ) -> Void
}

/// Provider clients required after Xbox identity has been established. The
/// controller factory keeps Game Streaming credentials and transport details
/// below the UI boundary; the UI contributes only a short-lived transfer-token
/// request owned by `XboxAuthManager`.
nonisolated struct XboxCloudServiceConfiguration: Sendable {
    let makeCatalogClient: @Sendable () -> any XboxCatalogClient
    let makeContentAccessClient: (@Sendable () -> any XboxContentAccessProviding)?
    let makeStreamController: @MainActor @Sendable (
        @escaping @Sendable () async throws -> String
    ) -> XboxCloudStreamController
    let streamControllerRetention: XboxCloudStreamControllerRetention
    /// Resolves the same coalesced GS login used by catalog and streaming while
    /// exposing only its non-secret offering identifier to membership metadata.
    let resolveContentAccessOfferingID: @Sendable (
        XboxCloudAuthorizedAccount
    ) async throws -> String
    let resolveNetworkTestTarget: @Sendable (
        XboxCloudAuthorizedAccount
    ) async throws -> CloudNetworkTestTarget

    init(
        makeCatalogClient: @escaping @Sendable () -> any XboxCatalogClient,
        makeContentAccessClient: (@Sendable () -> any XboxContentAccessProviding)? = nil,
        makeStreamController: @escaping @MainActor @Sendable (
            @escaping @Sendable () async throws -> String
        ) -> XboxCloudStreamController,
        streamControllerRetention: XboxCloudStreamControllerRetention = .none,
        resolveContentAccessOfferingID: @escaping @Sendable (
            XboxCloudAuthorizedAccount
        ) async throws -> String = { _ in
            XboxCloudOfferingServiceConfiguration.defaultConsumerOfferingID
        },
        resolveNetworkTestTarget: @escaping @Sendable (
            XboxCloudAuthorizedAccount
        ) async throws -> CloudNetworkTestTarget = { _ in
            CloudNetworkTestTarget(
                address: XboxCloudCompatibilityProfile.bundledV1
                    .defaultNetworkTestTargetURL.absoluteString
            )
        }
    ) {
        self.makeCatalogClient = makeCatalogClient
        self.makeContentAccessClient = makeContentAccessClient
        self.makeStreamController = makeStreamController
        self.streamControllerRetention = streamControllerRetention
        self.resolveContentAccessOfferingID = resolveContentAccessOfferingID
        self.resolveNetworkTestTarget = resolveNetworkTestTarget
    }
}

/// Xbox dependencies are split by readiness: public Microsoft device-code
/// sign-in, Xbox/XSTS account authorization, and the catalog/stream runtime.
/// A generic Microsoft token never makes `service` or Xbox authorization ready.
nonisolated struct XboxCloudEnvironment: Sendable {
    static let unconfigured = XboxCloudEnvironment(
        authentication: nil,
        makeAccountAuthorizationClient: nil,
        service: nil
    )

    /// Microsoft's public Xbox sign-in registration. The client identifier is
    /// public, not a client secret. Completing this OAuth flow proves only a
    /// Microsoft sign-in; Xbox/XSTS authorization must still succeed separately.
    static let productionMicrosoftSignIn = XboxCloudEnvironment(
        authentication: productionMicrosoftAuthentication,
        makeAccountAuthorizationClient: nil,
        service: nil
    )

    static let invalidCompatibilityProfile = XboxCloudEnvironment(
        authentication: productionMicrosoftAuthentication,
        makeAccountAuthorizationClient: nil,
        serviceConfigurationFailure: .invalidCompatibilityProfile,
        service: nil
    )

    static let productionMicrosoftAuthentication: MicrosoftDeviceCodeOAuthConfiguration = {
        do {
            return try MicrosoftDeviceCodeOAuthConfiguration(
                tenant: "consumers",
                clientID: "1f907974-e22b-4810-a9de-d9647380c97e",
                scopes: [
                    "xboxlive.signin",
                    "openid",
                    "profile",
                    "offline_access",
                ]
            )
        } catch {
            preconditionFailure("CloudNow's Xbox Microsoft sign-in configuration is invalid.")
        }
    }()

    let authentication: MicrosoftDeviceCodeOAuthConfiguration?
    let makeAccountAuthorizationClient: (@Sendable () -> any XboxCloudAccountAuthorizationClient)?
    let credentialLifecycle: (any XboxLocalCredentialLifecycle)?
    let serviceConfigurationFailure: XboxCloudServiceConfigurationFailure?
    let service: XboxCloudServiceConfiguration?

    init(
        authentication: MicrosoftDeviceCodeOAuthConfiguration?,
        makeAccountAuthorizationClient: (@Sendable () -> any XboxCloudAccountAuthorizationClient)?,
        credentialLifecycle: (any XboxLocalCredentialLifecycle)? = nil,
        serviceConfigurationFailure: XboxCloudServiceConfigurationFailure? = nil,
        service: XboxCloudServiceConfiguration?
    ) {
        self.authentication = authentication
        self.makeAccountAuthorizationClient = makeAccountAuthorizationClient
        self.credentialLifecycle = credentialLifecycle
        self.serviceConfigurationFailure = serviceConfigurationFailure
        self.service = service
    }

    var canRequestMicrosoftDeviceCode: Bool {
        authentication != nil
    }

    var canAuthorizeXboxCloud: Bool {
        makeAccountAuthorizationClient != nil
    }

    var availability: XboxCloudAvailability {
        service == nil ? .awaitingMicrosoftConfiguration : .configured
    }
}

nonisolated enum XboxCloudServiceConfigurationFailure: Equatable, Sendable {
    case invalidCompatibilityProfile
}
