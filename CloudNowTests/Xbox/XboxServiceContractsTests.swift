@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox service contracts")
struct XboxServiceContractsTests {
    @Test("Default environment has no sign-in or runtime configuration")
    func unconfiguredEnvironment() {
        let environment = XboxCloudEnvironment.unconfigured

        #expect(environment.authentication == nil)
        #expect(!environment.canRequestMicrosoftDeviceCode)
        #expect(!environment.canAuthorizeXboxCloud)
        #expect(environment.service == nil)
        #expect(environment.availability == .awaitingMicrosoftConfiguration)
        #expect(!environment.availability.isEnabled)
    }

    @Test("Production Microsoft sign-in does not imply Xbox runtime readiness")
    func productionMicrosoftSignInReadiness() {
        let environment = XboxCloudEnvironment.productionMicrosoftSignIn

        #expect(environment.authentication?.tenant == "consumers")
        #expect(
            environment.authentication?.clientID
                == "1f907974-e22b-4810-a9de-d9647380c97e"
        )
        #expect(
            Set(environment.authentication?.scopes ?? [])
                == Set([
                    "xboxlive.signin",
                    "openid",
                    "profile",
                    "offline_access",
                ])
        )
        #expect(environment.canRequestMicrosoftDeviceCode)
        #expect(!environment.canAuthorizeXboxCloud)
        #expect(environment.service == nil)
        #expect(environment.availability == .awaitingMicrosoftConfiguration)
    }

    @Test("Legacy catalog items retain a standard launch route")
    func legacyCatalogItemRoute() {
        let item = XboxCatalogItem(
            id: "fixture-title",
            title: "Fixture Game",
            artworkURL: nil
        )

        #expect(item.routes == [
            XboxCloudTitleRoute(
                titleID: "fixture-title",
                accessKind: .standard
            ),
        ])
    }

    @Test("Catalog snapshots merge duplicate product routes deterministically")
    func duplicateProductRoutes() throws {
        let artworkURL = try #require(
            URL(string: "https://store-images.s-microsoft.com/fixture.png")
        )
        let firstRoute = XboxCloudTitleRoute(
            titleID: "free-title",
            accessKind: .freeWithAds
        )
        let secondRoute = XboxCloudTitleRoute(
            titleID: "standard-title",
            accessKind: .standard
        )
        let snapshot = XboxCatalogSnapshot(
            items: [
                XboxCatalogItem(
                    id: "fixture-product",
                    title: "First Title",
                    artworkURL: nil,
                    routes: [firstRoute]
                ),
                XboxCatalogItem(
                    id: "fixture-product",
                    title: "Second Title",
                    artworkURL: artworkURL,
                    routes: [firstRoute, secondRoute]
                ),
            ],
            fetchedAt: .distantPast
        )

        let item = try #require(snapshot.items.first)
        #expect(snapshot.items.count == 1)
        #expect(item.id == "FIXTURE-PRODUCT")
        #expect(item.title == "First Title")
        #expect(item.artworkURL == artworkURL)
        #expect(item.routes == [firstRoute, secondRoute])
        #expect(item.accessKinds == [.standard, .freeWithAds])
        #expect(item.supportsFreeWithAds)
        #expect(item.preferredRoute == secondRoute)
    }

    @Test("Product and activity identity remains stable across refresh casing changes")
    func canonicalIdentityAcrossRefreshes() throws {
        let firstRoute = XboxCloudTitleRoute(
            titleID: "wire-route-first",
            accessKind: .standard
        )
        let refreshedRoute = XboxCloudTitleRoute(
            titleID: "WIRE-ROUTE-REFRESHED",
            accessKind: .standard
        )
        let firstSnapshot = XboxCatalogSnapshot(
            items: [
                XboxCatalogItem(
                    id: "product-a",
                    title: "First Refresh",
                    artworkURL: nil,
                    routes: [firstRoute]
                ),
            ],
            fetchedAt: .distantPast
        )
        let refreshedSnapshot = XboxCatalogSnapshot(
            items: [
                XboxCatalogItem(
                    id: "PRODUCT-A",
                    title: "Second Refresh",
                    artworkURL: nil,
                    routes: [refreshedRoute]
                ),
            ],
            fetchedAt: .distantFuture
        )
        let firstItem = try #require(firstSnapshot.items.first)
        let refreshedItem = try #require(refreshedSnapshot.items.first)
        let activity = CloudCatalogActivitySnapshot(
            favoriteIDs: ["product-a"],
            recentlyPlayedIDs: ["Product-A"]
        )

        #expect(firstItem.id == "PRODUCT-A")
        #expect(refreshedItem.id == firstItem.id)
        #expect(firstItem.routes == [firstRoute])
        #expect(refreshedItem.routes == [refreshedRoute])
        #expect(activity.favoriteIDs == [refreshedItem.id])
        #expect(activity.recentlyPlayedIDs == [refreshedItem.id])
    }

    @Test("Catalog snapshots reject loopback and localhost artwork")
    func catalogArtworkPolicy() throws {
        let trustedArtworkURL = try #require(
            URL(string: "https://store-images.s-microsoft.com/trusted.png")
        )
        let localhostArtworkURL = try #require(
            URL(string: "https://localhost/private.png")
        )
        let loopbackArtworkURL = try #require(
            URL(string: "https://127.0.0.1/private.png")
        )
        let snapshot = XboxCatalogSnapshot(
            items: [
                XboxCatalogItem(
                    id: "trusted",
                    title: "Trusted",
                    artworkURL: trustedArtworkURL
                ),
                XboxCatalogItem(
                    id: "localhost",
                    title: "Localhost",
                    artworkURL: localhostArtworkURL
                ),
                XboxCatalogItem(
                    id: "loopback",
                    title: "Loopback",
                    artworkURL: loopbackArtworkURL
                ),
            ],
            fetchedAt: .distantPast
        )

        #expect(snapshot.items.map(\.id) == ["TRUSTED"])
        #expect(snapshot.items.first?.artworkURL == trustedArtworkURL)
    }

    @Test("Playable availability replaces eligibility without duplicating a route")
    func playableAvailabilityWinsRouteCollision() throws {
        let unavailableRoute = XboxCloudTitleRoute(
            titleID: "free-title",
            accessKind: .freeWithAds,
            availability: .requiresEligibility,
            playabilityReason: .entitlementRequired
        )
        let playableRoute = XboxCloudTitleRoute(
            titleID: "free-title",
            accessKind: .freeWithAds,
            playabilityReason: .contentAccessConfirmed
        )
        let standardRoute = XboxCloudTitleRoute(
            titleID: "standard-title",
            accessKind: .standard
        )
        let snapshot = XboxCatalogSnapshot(
            items: [
                XboxCatalogItem(
                    id: "fixture-product",
                    title: "Fixture Game",
                    artworkURL: nil,
                    routes: [unavailableRoute]
                ),
                XboxCatalogItem(
                    id: "fixture-product",
                    title: "Duplicate Fixture Game",
                    artworkURL: nil,
                    routes: [playableRoute, standardRoute]
                ),
            ],
            fetchedAt: .distantPast
        )

        let item = try #require(snapshot.items.first)
        #expect(item.routes == [playableRoute, standardRoute])
        #expect(item.routes.first?.playabilityReason == .contentAccessConfirmed)
        #expect(item.preferredRoute == standardRoute)
    }

    @Test("A full route list still accepts a playable availability upgrade")
    func playableUpgradeAtRouteLimit() throws {
        let unavailableRoute = XboxCloudTitleRoute(
            titleID: "free-title",
            accessKind: .freeWithAds,
            availability: .requiresEligibility
        )
        let playableRoute = XboxCloudTitleRoute(
            titleID: "free-title",
            accessKind: .freeWithAds
        )
        let retainedRoutes = [unavailableRoute] + (1 ..< 16).map { index in
            XboxCloudTitleRoute(
                titleID: "standard-title-\(index)",
                accessKind: .standard
            )
        }
        let discardedRoute = XboxCloudTitleRoute(
            titleID: "route-over-limit",
            accessKind: .standard
        )
        let snapshot = XboxCatalogSnapshot(
            items: [
                XboxCatalogItem(
                    id: "fixture-product",
                    title: "Fixture Game",
                    artworkURL: nil,
                    routes: retainedRoutes
                ),
                XboxCatalogItem(
                    id: "fixture-product",
                    title: "Duplicate Fixture Game",
                    artworkURL: nil,
                    routes: [discardedRoute, playableRoute]
                ),
            ],
            fetchedAt: .distantPast
        )

        let item = try #require(snapshot.items.first)
        #expect(item.routes.count == 16)
        #expect(item.routes.first == playableRoute)
        #expect(!item.routes.contains(discardedRoute))
    }

    @Test("Preferred routes prioritize playability before access kind")
    func preferredRoutePrioritizesPlayability() {
        let unavailableStandardRoute = XboxCloudTitleRoute(
            titleID: "standard-title",
            accessKind: .standard,
            availability: .requiresEligibility
        )
        let playableFreeRoute = XboxCloudTitleRoute(
            titleID: "free-title",
            accessKind: .freeWithAds
        )
        let item = XboxCatalogItem(
            id: "fixture-product",
            title: "Fixture Game",
            artworkURL: nil,
            routes: [unavailableStandardRoute, playableFreeRoute]
        )

        #expect(item.preferredRoute == playableFreeRoute)
    }

    @Test("Configured environment uses injected catalog and native stream factory")
    @MainActor
    func injectedServices() async throws {
        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = XboxCatalogSnapshot(
            items: [
                XboxCatalogItem(
                    id: "fixture-game",
                    title: "Fixture Game",
                    artworkURL: URL(
                        string: "https://store-images.s-microsoft.com/artwork.png"
                    )
                ),
            ],
            fetchedAt: requestedAt
        )
        let catalog = XboxCatalogClientStub(snapshot: snapshot)
        let sessionProvider = XboxCloudGSSessionProviderStub()
        let account = XboxCloudAuthorizedAccount(
            authorizationIdentifier: "fixture-account-authorization",
            displayName: "Fixture Player",
            expiresAt: requestedAt.addingTimeInterval(3600)
        )
        let accountAuthorization = XboxAccountAuthorizationStub(account: account)
        let authentication = try MicrosoftDeviceCodeOAuthConfiguration(
            tenant: "consumers",
            clientID: "fixture-client",
            scopes: ["openid"]
        )
        let configuration = XboxCloudServiceConfiguration(
            makeCatalogClient: { catalog },
            makeStreamController: { transferToken in
                XboxCloudStreamController(
                    sessionProvider: sessionProvider,
                    transferToken: transferToken,
                    deviceInformation: .cloudNowTV(
                        sdkInstallID: "fixture-installation"
                    )
                )
            }
        )
        let environment = XboxCloudEnvironment(
            authentication: authentication,
            makeAccountAuthorizationClient: { accountAuthorization },
            service: configuration
        )
        let configuredCatalog = configuration.makeCatalogClient()
        let streamController = configuration.makeStreamController {
            "fixture-transfer-token"
        }
        let networkTestTarget = try await configuration
            .resolveNetworkTestTarget(account)

        let catalogResult = try await configuredCatalog.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "en-US", market: "US"),
            account: account
        )
        #expect(environment.availability == .configured)
        #expect(environment.availability.isEnabled)
        #expect(environment.canRequestMicrosoftDeviceCode)
        #expect(environment.canAuthorizeXboxCloud)
        #expect(catalogResult == snapshot)
        #expect(streamController.state == .idle)
        #expect(streamController.activeGameID == nil)
        #expect(
            networkTestTarget.address
                == XboxCloudCompatibilityProfile.bundledV1
                .defaultNetworkTestTargetURL.absoluteString
        )
        #expect(await catalog.requests() == [XboxCatalogRequest(localeIdentifier: "en-US", market: "US")])
        #expect(await catalog.accounts() == [account])
    }
}

private actor XboxAccountAuthorizationStub: XboxCloudAccountAuthorizationClient {
    let account: XboxCloudAuthorizedAccount

    init(account: XboxCloudAuthorizedAccount) {
        self.account = account
    }

    func authorize(
        microsoftToken _: MicrosoftOAuthToken
    ) -> XboxCloudAuthorizedAccount {
        account
    }
}

private actor XboxCatalogClientStub: XboxCatalogClient {
    private let snapshot: XboxCatalogSnapshot
    private var recordedRequests: [XboxCatalogRequest] = []
    private var recordedAccounts: [XboxCloudAuthorizedAccount] = []

    init(snapshot: XboxCatalogSnapshot) {
        self.snapshot = snapshot
    }

    func fetchCatalog(
        _ request: XboxCatalogRequest,
        account: XboxCloudAuthorizedAccount
    ) -> XboxCatalogSnapshot {
        recordedRequests.append(request)
        recordedAccounts.append(account)
        return snapshot
    }

    func requests() -> [XboxCatalogRequest] {
        recordedRequests
    }

    func accounts() -> [XboxCloudAuthorizedAccount] {
        recordedAccounts
    }

    nonisolated func cancel() {}
}

private actor XboxCloudGSSessionProviderStub: XboxCloudGSSessionProviding {
    func session(
        for _: XboxCloudAuthorizedAccount
    ) throws -> XboxCloudGSSession {
        throw XboxCloudOfferingServiceError.accountUnavailable
    }

    func removeSession(for _: XboxCloudAuthorizedAccount) {}

    func clearSessions() {}
}
