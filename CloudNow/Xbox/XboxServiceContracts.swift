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

nonisolated enum XboxCloudAccessKind: Equatable, Hashable, Sendable {
    case standard
    case freeWithAds
}

nonisolated enum XboxCloudRouteAvailability: Equatable, Hashable, Sendable {
    case playable
    case requiresEligibility
}

/// The service title identifier and access path required to launch one catalog
/// product. A product can expose more than one route without changing its
/// stable catalog identity.
nonisolated struct XboxCloudTitleRoute: Equatable, Hashable, Sendable {
    let titleID: String
    let accessKind: XboxCloudAccessKind
    let availability: XboxCloudRouteAvailability

    init(
        titleID: String,
        accessKind: XboxCloudAccessKind,
        availability: XboxCloudRouteAvailability = .playable
    ) {
        self.titleID = titleID
        self.accessKind = accessKind
        self.availability = availability
    }

    var isPlayable: Bool {
        availability == .playable
    }
}

nonisolated struct XboxCatalogItem: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let artworkURL: URL?
    let routes: [XboxCloudTitleRoute]

    init(
        id: String,
        title: String,
        artworkURL: URL?,
        routes: [XboxCloudTitleRoute]? = nil
    ) {
        self.id = id
        self.title = title
        self.artworkURL = artworkURL
        self.routes = routes ?? [
            XboxCloudTitleRoute(
                titleID: id,
                accessKind: .standard
            ),
        ]
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

    fileprivate var isSafeForPresentation: Bool {
        guard !id.isEmpty,
              id.utf8.count <= 512,
              !title.isEmpty,
              title.utf8.count <= 1024,
              !routes.isEmpty,
              routes.count <= 16,
              routes.allSatisfy(\.isSafeForPresentation)
        else {
            return false
        }
        guard let artworkURL else { return true }
        guard artworkURL.absoluteString.utf8.count <= 2048,
              artworkURL.scheme?.lowercased() == "https",
              artworkURL.user == nil,
              artworkURL.password == nil
        else {
            return false
        }
        let sensitiveQueryFragments = [
            "auth",
            "credential",
            "expires",
            "key",
            "policy",
            "secret",
            "sig",
            "token",
        ]
        return URLComponents(
            url: artworkURL,
            resolvingAgainstBaseURL: false
        )?.queryItems?.allSatisfy { queryItem in
            let name = queryItem.name.lowercased()
            return !sensitiveQueryFragments.contains { name.contains($0) }
        } ?? true
    }

    fileprivate func mergingRoutes(from other: XboxCatalogItem) -> XboxCatalogItem {
        guard id == other.id else { return self }

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
            artworkURL: artworkURL ?? other.artworkURL,
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

nonisolated struct XboxCatalogSnapshot: Equatable, Sendable {
    static let maximumRetainedItemCount = 512

    let items: [XboxCatalogItem]
    let fetchedAt: Date

    init(items: [XboxCatalogItem], fetchedAt: Date) {
        var retainedItems: [XboxCatalogItem] = []
        retainedItems.reserveCapacity(
            min(items.count, Self.maximumRetainedItemCount)
        )
        var retainedIndexesByID: [String: Int] = [:]
        for item in items where item.isSafeForPresentation {
            if let retainedIndex = retainedIndexesByID[item.id] {
                retainedItems[retainedIndex] = retainedItems[retainedIndex]
                    .mergingRoutes(from: item)
                continue
            }
            guard retainedItems.count < Self.maximumRetainedItemCount else {
                continue
            }
            retainedIndexesByID[item.id] = retainedItems.count
            retainedItems.append(item)
        }
        self.items = retainedItems
        self.fetchedAt = fetchedAt
    }
}

/// Opaque account context returned after Xbox Live/XSTS authorization. A
/// generic Microsoft OAuth token is not enough to enter the Xbox runtime.
nonisolated struct XboxCloudAuthorizedAccount: Equatable, Sendable {
    let authorizationIdentifier: String
    let displayName: String?
    let expiresAt: Date

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
}

/// Production and test implementations remain injected so the Xbox catalog is
/// lazy and provider switching can release transport work synchronously.
nonisolated protocol XboxCatalogClient: Sendable {
    func fetchCatalog(
        _ request: XboxCatalogRequest,
        account: XboxCloudAuthorizedAccount
    ) async throws -> XboxCatalogSnapshot

    /// Synchronously cancels provider-owned transport work and releases its
    /// heavy resources. Implementations must be idempotent and non-blocking.
    nonisolated func cancel()
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

    init(
        makeCatalogClient: @escaping @Sendable () -> any XboxCatalogClient,
        makeContentAccessClient: (@Sendable () -> any XboxContentAccessProviding)? = nil,
        makeStreamController: @escaping @MainActor @Sendable (
            @escaping @Sendable () async throws -> String
        ) -> XboxCloudStreamController
    ) {
        self.makeCatalogClient = makeCatalogClient
        self.makeContentAccessClient = makeContentAccessClient
        self.makeStreamController = makeStreamController
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
    let service: XboxCloudServiceConfiguration?

    init(
        authentication: MicrosoftDeviceCodeOAuthConfiguration?,
        makeAccountAuthorizationClient: (@Sendable () -> any XboxCloudAccountAuthorizationClient)?,
        credentialLifecycle: (any XboxLocalCredentialLifecycle)? = nil,
        service: XboxCloudServiceConfiguration?
    ) {
        self.authentication = authentication
        self.makeAccountAuthorizationClient = makeAccountAuthorizationClient
        self.credentialLifecycle = credentialLifecycle
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
