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
            URL(string: "https://example.invalid/fixture.png")
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
        #expect(item.id == "fixture-product")
        #expect(item.title == "First Title")
        #expect(item.artworkURL == artworkURL)
        #expect(item.routes == [firstRoute, secondRoute])
        #expect(item.accessKinds == [.standard, .freeWithAds])
        #expect(item.supportsFreeWithAds)
        #expect(item.preferredRoute == secondRoute)
    }

    @Test("Playable availability replaces eligibility without duplicating a route")
    func playableAvailabilityWinsRouteCollision() throws {
        let unavailableRoute = XboxCloudTitleRoute(
            titleID: "free-title",
            accessKind: .freeWithAds,
            availability: .requiresEligibility
        )
        let playableRoute = XboxCloudTitleRoute(
            titleID: "free-title",
            accessKind: .freeWithAds
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
                    artworkURL: URL(string: "https://example.invalid/artwork.png")
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
