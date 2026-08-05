@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox catalog presentation")
struct XboxCatalogViewModelTests {
    private let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let account = XboxCloudAuthorizedAccount(
        authorizationIdentifier: "fixture-account",
        displayName: "Fixture Player",
        expiresAt: .distantFuture
    )

    @MainActor
    @Test("Initial load forwards the runtime locale and market")
    func initialLoadUsesRuntimeLocaleAndMarket() async throws {
        let expectedLocaleIdentifier = L10n.localeCode
        let expectedMarket = Locale.current.region?.identifier
        let items = makeItems(count: 3)
        let client = XboxCatalogClientProbe(
            snapshot: XboxCatalogSnapshot(items: items, fetchedAt: fetchedAt)
        )
        let viewModel = XboxCatalogViewModel(
            client: client,
            account: account,
            cache: XboxCatalogMemoryCache()
        )

        await viewModel.load()

        let requests = await client.recordedRequests()
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(await client.recordedAccounts() == [account])
        #expect(request.localeIdentifier == expectedLocaleIdentifier)
        #expect(request.market == expectedMarket)
        #expect(viewModel.visibleItems == items)
        #expect(viewModel.phase == .loaded)
        #expect(viewModel.availableAccessKinds == [.standard])
    }

    @MainActor
    @Test("Pagination publishes at most 96 more items per boundary")
    func paginationIsBoundedToNinetySixItems() async {
        let items = makeItems(count: 250)
        let client = XboxCatalogClientProbe(
            snapshot: XboxCatalogSnapshot(items: items, fetchedAt: fetchedAt)
        )
        let viewModel = XboxCatalogViewModel(
            client: client,
            account: account,
            cache: XboxCatalogMemoryCache()
        )

        await viewModel.load()

        #expect(viewModel.visibleItems == Array(items.prefix(96)))

        viewModel.loadNextPageIfNeeded(items[94])
        #expect(viewModel.visibleItems.count == 96)

        viewModel.loadNextPageIfNeeded(items[95])
        #expect(viewModel.visibleItems == Array(items.prefix(192)))

        viewModel.loadNextPageIfNeeded(items[95])
        #expect(viewModel.visibleItems.count == 192)

        viewModel.loadNextPageIfNeeded(items[191])
        #expect(viewModel.visibleItems == items)

        viewModel.loadNextPageIfNeeded(items[249])
        #expect(viewModel.visibleItems.count == items.count)
    }

    @MainActor
    @Test("Home separates standard and free-with-ads titles into bounded rails")
    func homeAccessBuckets() async {
        let dualAccess = makeAccessItem(
            id: "dual-access",
            accessKinds: [.freeWithAds, .standard]
        )
        let standardOnly = (0 ..< 12).map { index in
            makeAccessItem(
                id: "standard-\(index)",
                accessKinds: [.standard]
            )
        }
        let freeWithAdsOnly = (0 ..< 12).map { index in
            makeAccessItem(
                id: "free-with-ads-\(index)",
                accessKinds: [.freeWithAds]
            )
        }
        let items = [dualAccess] + standardOnly + freeWithAdsOnly
        let viewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(
                    items: items,
                    fetchedAt: fetchedAt
                )
            ),
            account: account,
            cache: XboxCatalogMemoryCache()
        )

        await viewModel.load()

        #expect(
            viewModel.homeStandardItems
                == [dualAccess] + Array(standardOnly.prefix(11))
        )
        #expect(
            viewModel.homeFreeWithAdsItems
                == [dualAccess] + Array(freeWithAdsOnly.prefix(11))
        )
        #expect(viewModel.visibleItems == items)
        #expect(viewModel.phase == .loaded)
        #expect(viewModel.availableAccessKinds == [.standard, .freeWithAds])
    }

    @MainActor
    @Test("Browse switches between all titles and free-with-ads titles")
    func browseAccessFilter() async {
        let standardOnly = makeAccessItem(
            id: "standard-only",
            accessKinds: [.standard]
        )
        let freeWithAdsOnly = makeAccessItem(
            id: "free-with-ads-only",
            accessKinds: [.freeWithAds]
        )
        let dualAccess = makeAccessItem(
            id: "dual-access",
            accessKinds: [.standard, .freeWithAds]
        )
        let items = [standardOnly, freeWithAdsOnly, dualAccess]
        let viewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(
                    items: items,
                    fetchedAt: fetchedAt
                )
            ),
            account: account,
            cache: XboxCatalogMemoryCache()
        )

        await viewModel.load()

        #expect(viewModel.browseFilter == .all)
        #expect(viewModel.visibleItems == items)

        viewModel.browseFilter = .freeWithAds

        #expect(viewModel.visibleItems == [freeWithAdsOnly, dualAccess])

        viewModel.browseFilter = .all

        #expect(viewModel.visibleItems == items)
    }

    @MainActor
    @Test("All browse launch candidates prefer a standard route")
    func allBrowsePrefersStandardLaunchRoute() async throws {
        let freeWithAdsRoute = XboxCloudTitleRoute(
            titleID: "free-with-ads-title",
            accessKind: .freeWithAds
        )
        let standardRoute = XboxCloudTitleRoute(
            titleID: "standard-title",
            accessKind: .standard
        )
        let item = XboxCatalogItem(
            id: "dual-access-product",
            title: "Dual Access",
            artworkURL: nil,
            routes: [freeWithAdsRoute, standardRoute]
        )
        let viewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(
                    items: [item],
                    fetchedAt: fetchedAt
                )
            ),
            account: account,
            cache: XboxCatalogMemoryCache()
        )

        await viewModel.load()

        let launchCandidate = try #require(viewModel.visibleItems.first)
        #expect(viewModel.browseFilter == .all)
        #expect(launchCandidate.preferredRoute == standardRoute)
    }

    @MainActor
    @Test("Free-with-ads candidates remain visible while awaiting eligibility")
    func ineligibleFreeWithAdsCandidatesRemainVisible() async throws {
        let route = XboxCloudTitleRoute(
            titleID: "preview-title",
            accessKind: .freeWithAds,
            availability: .requiresEligibility
        )
        let candidate = XboxCatalogItem(
            id: "preview-product",
            title: "Preview Candidate",
            artworkURL: nil,
            routes: [route]
        )
        let viewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(
                    items: [candidate],
                    fetchedAt: fetchedAt
                )
            ),
            account: account,
            cache: XboxCatalogMemoryCache()
        )

        await viewModel.load()

        #expect(viewModel.homeFreeWithAdsItems == [candidate])
        #expect(viewModel.availableAccessKinds == [.freeWithAds])
        viewModel.browseFilter = .freeWithAds
        #expect(viewModel.visibleItems == [candidate])
        let selectedRoute = try #require(
            viewModel.visibleItems.first?.preferredRoute
        )
        #expect(selectedRoute == route)
        #expect(!route.isPlayable)
    }

    @MainActor
    @Test("Changing browse filters resets independent pagination")
    func filterResetsPagination() async throws {
        let items = (0 ..< 250).map { index in
            makeAccessItem(
                id: "mixed-game-\(index)",
                accessKinds: index.isMultiple(of: 2)
                    ? [.freeWithAds]
                    : [.standard]
            )
        }
        let freeWithAdsItems = items.filter(\.supportsFreeWithAds)
        let viewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(
                    items: items,
                    fetchedAt: fetchedAt
                )
            ),
            account: account,
            cache: XboxCatalogMemoryCache()
        )

        await viewModel.load()

        #expect(viewModel.visibleItems == Array(items.prefix(96)))
        let allBoundary = try #require(viewModel.visibleItems.last)
        viewModel.loadNextPageIfNeeded(allBoundary)
        #expect(viewModel.visibleItems == Array(items.prefix(192)))

        viewModel.browseFilter = .freeWithAds

        #expect(
            viewModel.visibleItems
                == Array(freeWithAdsItems.prefix(96))
        )
        viewModel.loadNextPageIfNeeded(allBoundary)
        #expect(viewModel.visibleItems.count == 96)
        let freeWithAdsBoundary = try #require(viewModel.visibleItems.last)
        viewModel.loadNextPageIfNeeded(freeWithAdsBoundary)
        #expect(viewModel.visibleItems == freeWithAdsItems)

        viewModel.browseFilter = .all

        #expect(viewModel.visibleItems == Array(items.prefix(96)))
    }

    @MainActor
    @Test("A successful empty snapshot is loaded with empty catalog buckets")
    func successfulEmptySnapshot() async {
        let client = XboxCatalogClientProbe(
            snapshot: XboxCatalogSnapshot(
                items: [],
                fetchedAt: fetchedAt
            )
        )
        let viewModel = XboxCatalogViewModel(
            client: client,
            account: account,
            cache: XboxCatalogMemoryCache()
        )

        await viewModel.load()

        #expect(viewModel.phase == .loaded)
        #expect(viewModel.visibleItems.isEmpty)
        #expect(viewModel.homeStandardItems.isEmpty)
        #expect(viewModel.homeFreeWithAdsItems.isEmpty)
        #expect(!viewModel.showsRefreshWarning)
        #expect(await client.recordedRequests().count == 1)
    }

    @MainActor
    @Test("A load already in flight rejects duplicate requests")
    func duplicateLoadsShareTheInFlightGuard() async {
        let items = makeItems(count: 2)
        let client = XboxCatalogClientProbe(
            snapshot: XboxCatalogSnapshot(items: items, fetchedAt: fetchedAt),
            suspendsResponse: true
        )
        let viewModel = XboxCatalogViewModel(
            client: client,
            account: account,
            cache: XboxCatalogMemoryCache()
        )

        let firstLoad = Task { @MainActor in
            await viewModel.load()
        }
        await client.waitForRequestCount(1)

        await viewModel.load()

        #expect(await client.recordedRequests().count == 1)
        #expect(viewModel.phase == .loading)

        await client.resolvePendingResponse()
        await firstLoad.value

        #expect(viewModel.visibleItems == items)
        #expect(viewModel.phase == .loaded)
    }

    @MainActor
    @Test("Cancellation rejects a delayed stale catalog response")
    func cancellationRejectsDelayedResults() async {
        let delayedItems = makeItems(count: 5)
        let client = XboxCatalogClientProbe(
            snapshot: XboxCatalogSnapshot(items: delayedItems, fetchedAt: fetchedAt),
            suspendsResponse: true
        )
        let viewModel = XboxCatalogViewModel(
            client: client,
            account: account,
            cache: XboxCatalogMemoryCache()
        )

        let load = Task { @MainActor in
            await viewModel.load()
        }
        await client.waitForRequestCount(1)

        viewModel.cancel()
        #expect(client.cancellationCount == 1)
        await client.resolvePendingResponse()
        await load.value

        #expect(viewModel.visibleItems.isEmpty)
        #expect(viewModel.phase != .loaded)
        #expect(await client.recordedRequests().count == 1)
    }

    @MainActor
    @Test("Cache clearing releases and lazily rebuilds the catalog client")
    func cacheClearRebuildsCatalogClientOnDemand() async {
        let items = makeItems(count: 3)
        let client = XboxCatalogClientProbe(
            snapshot: XboxCatalogSnapshot(items: items, fetchedAt: fetchedAt)
        )
        let factory = XboxCatalogClientFactoryProbe(client: client)
        let viewModel = XboxCatalogViewModel(
            makeClient: { factory.makeClient() },
            account: account,
            cache: XboxCatalogMemoryCache(),
            freshnessInterval: 0
        )

        #expect(factory.creationCount == 0)

        await viewModel.load()

        #expect(factory.creationCount == 1)
        #expect(viewModel.visibleItems == items)

        viewModel.prepareForCacheClear()

        #expect(viewModel.visibleItems.isEmpty)
        #expect(viewModel.phase == .idle)

        await viewModel.load()

        #expect(factory.creationCount == 2)
        #expect(viewModel.visibleItems == items)
    }

    @MainActor
    @Test("Provider deactivation releases the client, rows, and account cache")
    func providerDeactivationReleasesRuntimeCatalogState() async {
        let items = makeItems(count: 3)
        let snapshot = XboxCatalogSnapshot(items: items, fetchedAt: fetchedAt)
        let cache = XboxCatalogMemoryCache()
        let cacheKey = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: account.authorizationIdentifier,
            localeIdentifier: L10n.localeCode,
            market: Locale.current.region?.identifier
        )
        let client = XboxCatalogClientProbe(snapshot: snapshot)
        let viewModel = XboxCatalogViewModel(
            client: client,
            account: account,
            cache: cache
        )

        await viewModel.load()

        #expect(await cache.snapshot(for: cacheKey) == snapshot)
        #expect(viewModel.visibleItems == items)

        await viewModel.deactivateForInactiveProvider()

        #expect(client.cancellationCount == 1)
        #expect(viewModel.visibleItems.isEmpty)
        #expect(viewModel.phase == .idle)
        #expect(await cache.snapshot(for: cacheKey) == nil)
    }

    @MainActor
    @Test("A fresh account-scoped snapshot avoids a provider re-entry fetch")
    func freshCacheAvoidsNetworkFetch() async {
        let currentDate = fetchedAt
        let items = makeItems(count: 4)
        let snapshot = XboxCatalogSnapshot(items: items, fetchedAt: currentDate)
        let cache = XboxCatalogMemoryCache()
        let key = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: account.authorizationIdentifier,
            localeIdentifier: L10n.localeCode,
            market: Locale.current.region?.identifier
        )
        await cache.store(snapshot, for: key)
        let client = XboxCatalogClientProbe(snapshot: snapshot)
        let viewModel = XboxCatalogViewModel(
            client: client,
            account: account,
            cache: cache,
            now: { currentDate }
        )

        await viewModel.load()

        #expect(viewModel.visibleItems == items)
        #expect(viewModel.phase == .loaded)
        #expect(await client.recordedRequests().isEmpty)
    }

    @MainActor
    @Test("A stale catalog remains visible when its refresh fails")
    func staleCacheSurvivesRefreshFailure() async {
        let items = makeItems(count: 4)
        let snapshot = XboxCatalogSnapshot(items: items, fetchedAt: fetchedAt)
        let cache = XboxCatalogMemoryCache()
        let key = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: account.authorizationIdentifier,
            localeIdentifier: L10n.localeCode,
            market: Locale.current.region?.identifier
        )
        await cache.store(snapshot, for: key)
        let client = XboxCatalogClientProbe(
            snapshot: snapshot,
            failsResponse: true
        )
        let viewModel = XboxCatalogViewModel(
            client: client,
            account: account,
            cache: cache,
            now: { fetchedAt.addingTimeInterval(3600) }
        )

        await viewModel.load()

        #expect(viewModel.visibleItems == items)
        #expect(viewModel.phase == .loaded)
        #expect(viewModel.showsRefreshWarning)
        #expect(await client.recordedRequests().count == 1)
    }

    @Test("The catalog cache rejects oversized snapshots")
    func cacheRejectsOversizedSnapshots() async {
        let cache = XboxCatalogMemoryCache(maximumItemCount: 2)
        let key = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: account.authorizationIdentifier,
            localeIdentifier: "en-US",
            market: "US"
        )

        await cache.store(
            XboxCatalogSnapshot(items: makeItems(count: 3), fetchedAt: fetchedAt),
            for: key
        )

        #expect(await cache.snapshot(for: key) == nil)
    }

    @Test("Catalog snapshots bound items and reject private artwork URLs")
    func snapshotsBoundAndValidateExternalItems() {
        let oversized = XboxCatalogSnapshot(
            items: makeItems(
                count: XboxCatalogSnapshot.maximumRetainedItemCount + 100
            ),
            fetchedAt: fetchedAt
        )
        let validated = XboxCatalogSnapshot(
            items: [
                XboxCatalogItem(
                    id: "insecure",
                    title: "Insecure",
                    artworkURL: URL(string: "http://example.com/cover.jpg")
                ),
                XboxCatalogItem(
                    id: "signed",
                    title: "Signed",
                    artworkURL: URL(
                        string: "https://example.com/cover.jpg?signature=secret"
                    )
                ),
                XboxCatalogItem(
                    id: "public",
                    title: "Public",
                    artworkURL: URL(
                        string: "https://example.com/cover.jpg?width=640"
                    )
                ),
                XboxCatalogItem(
                    id: "public",
                    title: "Duplicate",
                    artworkURL: nil
                ),
                XboxCatalogItem(
                    id: "no-artwork",
                    title: "No Artwork",
                    artworkURL: nil
                ),
            ],
            fetchedAt: fetchedAt
        )

        #expect(
            oversized.items.count
                == XboxCatalogSnapshot.maximumRetainedItemCount
        )
        #expect(validated.items.map(\.id) == ["public", "no-artwork"])
        #expect(validated.items.first?.title == "Public")
    }

    @Test("The catalog cache evicts the least recently used entry")
    func cacheEvictsLeastRecentlyUsedEntry() async {
        let cache = XboxCatalogMemoryCache(capacity: 2)
        let firstKey = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: "first-account",
            localeIdentifier: "en-US",
            market: "US"
        )
        let secondKey = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: "second-account",
            localeIdentifier: "en-US",
            market: "US"
        )
        let thirdKey = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: "third-account",
            localeIdentifier: "en-US",
            market: "US"
        )
        let firstSnapshot = XboxCatalogSnapshot(
            items: makeItems(count: 1),
            fetchedAt: fetchedAt
        )
        let secondSnapshot = XboxCatalogSnapshot(
            items: makeItems(count: 2),
            fetchedAt: fetchedAt.addingTimeInterval(1)
        )
        let thirdSnapshot = XboxCatalogSnapshot(
            items: makeItems(count: 3),
            fetchedAt: fetchedAt.addingTimeInterval(2)
        )

        await cache.store(firstSnapshot, for: firstKey)
        await cache.store(secondSnapshot, for: secondKey)
        #expect(await cache.snapshot(for: firstKey) == firstSnapshot)

        await cache.store(thirdSnapshot, for: thirdKey)

        #expect(await cache.snapshot(for: secondKey) == nil)
        #expect(await cache.snapshot(for: firstKey) == firstSnapshot)
        #expect(await cache.snapshot(for: thirdKey) == thirdSnapshot)
    }

    @Test("The catalog cache bounds aggregate item cost")
    func cacheEvictsWhenAggregateCostExceedsLimit() async {
        let cache = XboxCatalogMemoryCache(
            capacity: 3,
            maximumCost: 200
        )
        let firstKey = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: "first-account",
            localeIdentifier: "en-US",
            market: "US"
        )
        let secondKey = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: "second-account",
            localeIdentifier: "en-US",
            market: "US"
        )
        let firstSnapshot = XboxCatalogSnapshot(
            items: makeItems(count: 1),
            fetchedAt: fetchedAt
        )
        let secondSnapshot = XboxCatalogSnapshot(
            items: makeItems(count: 1),
            fetchedAt: fetchedAt.addingTimeInterval(1)
        )

        await cache.store(firstSnapshot, for: firstKey)
        #expect(await cache.snapshot(for: firstKey) == firstSnapshot)

        await cache.store(secondSnapshot, for: secondKey)

        #expect(await cache.snapshot(for: firstKey) == nil)
        #expect(await cache.snapshot(for: secondKey) == secondSnapshot)
    }

    @Test("Account logout evicts only that account's catalog")
    func cacheEvictionIsAccountScoped() async {
        let cache = XboxCatalogMemoryCache()
        let firstKey = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: "first-account",
            localeIdentifier: "en-US",
            market: "US"
        )
        let secondKey = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: "second-account",
            localeIdentifier: "en-US",
            market: "US"
        )
        let snapshot = XboxCatalogSnapshot(
            items: makeItems(count: 1),
            fetchedAt: fetchedAt
        )
        await cache.store(snapshot, for: firstKey)
        await cache.store(snapshot, for: secondKey)

        await cache.remove(accountAuthorizationIdentifier: "first-account")

        #expect(await cache.snapshot(for: firstKey) == nil)
        #expect(await cache.snapshot(for: secondKey) == snapshot)
    }

    @MainActor
    @Test("Membership metadata loads without blocking the catalog")
    func membershipLoadsAlongsideCatalog() async throws {
        let items = makeItems(count: 2)
        let contentAccess = XboxContentAccessClientProbe(
            result: .success(
                XboxContentAccessSnapshot(
                    membershipTier: .pcGamePass,
                    fetchedAt: fetchedAt
                )
            )
        )
        let catalogViewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(items: items, fetchedAt: fetchedAt)
            ),
            account: account,
            cache: XboxCatalogMemoryCache()
        )
        let modeViewModel = XboxCloudModeViewModel(
            catalogViewModel: catalogViewModel,
            account: account,
            makeContentAccessClient: { contentAccess },
            makeStreamController: makeStreamController
        )

        await modeViewModel.load()

        #expect(catalogViewModel.phase == .loaded)
        #expect(catalogViewModel.visibleItems == items)
        #expect(modeViewModel.contentAccessPhase == .loaded)
        #expect(modeViewModel.membershipTier == .pcGamePass)
        let request = try #require(await contentAccess.recordedRequests().first)
        #expect(request.account == account)
        #expect(request.offeringID == "xgpuweb")
        #expect(!request.market.isEmpty)
    }

    @MainActor
    @Test("Membership failure remains optional and leaves catalog usable")
    func membershipFailureDoesNotBlockCatalog() async {
        let items = makeItems(count: 2)
        let contentAccess = XboxContentAccessClientProbe(
            result: .failure(.injected)
        )
        let catalogViewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(items: items, fetchedAt: fetchedAt)
            ),
            account: account,
            cache: XboxCatalogMemoryCache()
        )
        let modeViewModel = XboxCloudModeViewModel(
            catalogViewModel: catalogViewModel,
            account: account,
            makeContentAccessClient: { contentAccess },
            makeStreamController: makeStreamController
        )

        await modeViewModel.load()

        #expect(catalogViewModel.phase == .loaded)
        #expect(catalogViewModel.visibleItems == items)
        #expect(modeViewModel.contentAccessPhase == .unavailable)
        #expect(modeViewModel.membershipTier == nil)
    }

    @MainActor
    @Test("Membership metadata can retry after a transient failure")
    func membershipRetry() async {
        let contentAccess = XboxContentAccessClientProbe(
            result: .failure(.injected)
        )
        let catalogViewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(items: [], fetchedAt: fetchedAt)
            ),
            account: account,
            cache: XboxCatalogMemoryCache()
        )
        let modeViewModel = XboxCloudModeViewModel(
            catalogViewModel: catalogViewModel,
            account: account,
            makeContentAccessClient: { contentAccess },
            makeStreamController: makeStreamController
        )

        await modeViewModel.load()
        #expect(modeViewModel.contentAccessPhase == .unavailable)

        await contentAccess.setResult(
            .success(
                XboxContentAccessSnapshot(
                    membershipTier: .pcGamePass,
                    fetchedAt: fetchedAt
                )
            )
        )
        await modeViewModel.refreshContentAccess()

        #expect(modeViewModel.contentAccessPhase == .loaded)
        #expect(modeViewModel.membershipTier == .pcGamePass)
        #expect(await contentAccess.recordedRequests().count == 2)
    }

    @MainActor
    @Test("Xbox mode deactivation cancels and fences membership metadata")
    func modeDeactivationCancelsContentAccess() async {
        let contentAccess = XboxCancellationIgnoringAccessProbe(
            snapshot: XboxContentAccessSnapshot(
                membershipTier: .ultimate,
                fetchedAt: fetchedAt
            )
        )
        let catalogViewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(items: [], fetchedAt: fetchedAt)
            ),
            account: account,
            cache: XboxCatalogMemoryCache()
        )
        let modeViewModel = XboxCloudModeViewModel(
            catalogViewModel: catalogViewModel,
            account: account,
            makeContentAccessClient: { contentAccess },
            makeStreamController: makeStreamController
        )
        let load = Task { @MainActor in
            await modeViewModel.load()
        }
        await contentAccess.waitUntilStarted()

        await modeViewModel.deactivateForInactiveProvider()
        await load.value

        #expect(await contentAccess.recordedCancellationCount() == 1)
        #expect(modeViewModel.contentAccessPhase == .idle)
        #expect(modeViewModel.membershipTier == nil)
    }

    @MainActor
    @Test("Persistent data reset cancels and fences membership metadata")
    func persistentDataResetCancelsContentAccess() async {
        let contentAccess = XboxCancellationIgnoringAccessProbe(
            snapshot: XboxContentAccessSnapshot(
                membershipTier: .ultimate,
                fetchedAt: fetchedAt
            )
        )
        let catalogViewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(items: [], fetchedAt: fetchedAt)
            ),
            account: account,
            cache: XboxCatalogMemoryCache()
        )
        let modeViewModel = XboxCloudModeViewModel(
            catalogViewModel: catalogViewModel,
            account: account,
            makeContentAccessClient: { contentAccess },
            makeStreamController: makeStreamController
        )
        let load = Task { @MainActor in
            await modeViewModel.load()
        }
        await contentAccess.waitUntilStarted()

        modeViewModel.prepareForPersistentDataClear()
        await load.value

        #expect(await contentAccess.recordedCancellationCount() == 1)
        #expect(modeViewModel.contentAccessPhase == .idle)
        #expect(modeViewModel.membershipTier == nil)
    }

    @MainActor
    @Test("Xbox mode deactivation tears down streaming and catalog state")
    func modeDeactivationTearsDownProviderState() async {
        let items = makeItems(count: 2)
        let catalogViewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(
                    items: items,
                    fetchedAt: fetchedAt
                )
            ),
            account: account,
            cache: XboxCatalogMemoryCache()
        )
        let sessionProvider = XboxSuspendingGSSessionProvider()
        let modeViewModel = XboxCloudModeViewModel(
            catalogViewModel: catalogViewModel,
            account: account,
            makeStreamController: { transferToken in
                XboxCloudStreamController(
                    sessionProvider: sessionProvider,
                    transferToken: transferToken
                )
            }
        )
        await catalogViewModel.load()
        let controller = modeViewModel.streamController {
            "fixture-transfer-token"
        }
        let launch = Task { @MainActor in
            try? await controller.start(
                gameID: items[0].id,
                account: account,
                locale: "en-US",
                settings: XboxCloudStreamSettings()
            )
        }

        for _ in 0 ..< 100 where controller.state == .idle {
            await Task.yield()
        }
        #expect(controller.state == .requestingAccess)

        await modeViewModel.deactivateForInactiveProvider()

        #expect(controller.state == .idle)
        #expect(catalogViewModel.visibleItems.isEmpty)
        let replacement = modeViewModel.streamController {
            "fixture-transfer-token"
        }
        #expect(replacement !== controller)
        await modeViewModel.stopStream()
        await launch.value
    }

    private func makeItems(count: Int) -> [XboxCatalogItem] {
        (0 ..< count).map { index in
            XboxCatalogItem(
                id: "game-\(index)",
                title: "Game \(index)",
                artworkURL: nil
            )
        }
    }

    private func makeAccessItem(
        id: String,
        accessKinds: [XboxCloudAccessKind]
    ) -> XboxCatalogItem {
        XboxCatalogItem(
            id: id,
            title: id,
            artworkURL: nil,
            routes: accessKinds.enumerated().map { index, accessKind in
                XboxCloudTitleRoute(
                    titleID: "\(id)-route-\(index)",
                    accessKind: accessKind
                )
            }
        )
    }

    @MainActor
    private func makeStreamController(
        transferToken: @escaping @Sendable () async throws -> String
    ) -> XboxCloudStreamController {
        XboxCloudStreamController(
            sessionProvider: XboxSuspendingGSSessionProvider(),
            transferToken: transferToken
        )
    }
}

private enum XboxContentAccessProbeError: Error {
    case injected
}

private actor XboxContentAccessClientProbe: XboxContentAccessProviding {
    struct Request: Equatable, Sendable {
        let account: XboxCloudAuthorizedAccount
        let market: String
        let offeringID: String
    }

    private var result: Result<XboxContentAccessSnapshot, XboxContentAccessProbeError>
    private var requests: [Request] = []

    init(result: Result<XboxContentAccessSnapshot, XboxContentAccessProbeError>) {
        self.result = result
    }

    func fetchContentAccess(
        for account: XboxCloudAuthorizedAccount,
        market: String,
        offeringID: String
    ) throws -> XboxContentAccessSnapshot {
        requests.append(Request(account: account, market: market, offeringID: offeringID))
        return try result.get()
    }

    func recordedRequests() -> [Request] {
        requests
    }

    func setResult(
        _ result: Result<XboxContentAccessSnapshot, XboxContentAccessProbeError>
    ) {
        self.result = result
    }
}

private actor XboxCancellationIgnoringAccessProbe: XboxContentAccessProviding {
    private let snapshot: XboxContentAccessSnapshot
    private var cancellationCount = 0
    private var requestCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(snapshot: XboxContentAccessSnapshot) {
        self.snapshot = snapshot
    }

    func fetchContentAccess(
        for _: XboxCloudAuthorizedAccount,
        market _: String,
        offeringID _: String
    ) async throws -> XboxContentAccessSnapshot {
        requestCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            cancellationCount += 1
        }
        return snapshot
    }

    func waitUntilStarted() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func recordedCancellationCount() -> Int {
        cancellationCount
    }
}

private actor XboxSuspendingGSSessionProvider: XboxCloudGSSessionProviding {
    func session(
        for _: XboxCloudAuthorizedAccount
    ) async throws -> XboxCloudGSSession {
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }

    func removeSession(for _: XboxCloudAuthorizedAccount) {}

    func clearSessions() {}
}

private final class XboxCatalogClientFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let client: any XboxCatalogClient
    private var createdClientCount = 0

    var creationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return createdClientCount
    }

    init(client: any XboxCatalogClient) {
        self.client = client
    }

    func makeClient() -> any XboxCatalogClient {
        lock.lock()
        defer { lock.unlock() }
        createdClientCount += 1
        return client
    }
}

private actor XboxCatalogClientProbe: XboxCatalogClient {
    private nonisolated let cancellationProbe = XboxCatalogCancellationProbe()
    private let snapshot: XboxCatalogSnapshot
    private let suspendsResponse: Bool
    private let failsResponse: Bool
    private var requests: [XboxCatalogRequest] = []
    private var accounts: [XboxCloudAuthorizedAccount] = []
    private var pendingResponse: CheckedContinuation<XboxCatalogSnapshot, Error>?
    private var requestWaiters: [(
        target: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    init(
        snapshot: XboxCatalogSnapshot,
        suspendsResponse: Bool = false,
        failsResponse: Bool = false
    ) {
        self.snapshot = snapshot
        self.suspendsResponse = suspendsResponse
        self.failsResponse = failsResponse
    }

    func fetchCatalog(
        _ request: XboxCatalogRequest,
        account: XboxCloudAuthorizedAccount
    ) async throws -> XboxCatalogSnapshot {
        requests.append(request)
        accounts.append(account)
        if failsResponse {
            resumeSatisfiedRequestWaiters()
            throw XboxCatalogClientProbeError.unavailable
        }
        guard suspendsResponse else {
            resumeSatisfiedRequestWaiters()
            return snapshot
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponse = continuation
            resumeSatisfiedRequestWaiters()
        }
    }

    func recordedRequests() -> [XboxCatalogRequest] {
        requests
    }

    func recordedAccounts() -> [XboxCloudAuthorizedAccount] {
        accounts
    }

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func resolvePendingResponse() {
        let continuation = pendingResponse
        pendingResponse = nil
        continuation?.resume(returning: snapshot)
    }

    nonisolated var cancellationCount: Int {
        cancellationProbe.count
    }

    nonisolated func cancel() {
        cancellationProbe.record()
    }

    private func resumeSatisfiedRequestWaiters() {
        let satisfiedWaiters = requestWaiters.filter { requests.count >= $0.target }
        requestWaiters.removeAll { requests.count >= $0.target }
        satisfiedWaiters.forEach { $0.continuation.resume() }
    }
}

private final class XboxCatalogCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCount
    }

    func record() {
        lock.lock()
        recordedCount += 1
        lock.unlock()
    }
}

private enum XboxCatalogClientProbeError: Error {
    case unavailable
}
