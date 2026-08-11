@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox catalog presentation")
struct XboxCatalogViewModelTests {
    private let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let account = XboxCloudAuthorizedAccount(
        authorizationIdentifier: "fixture-account-\(UUID().uuidString)",
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
        #expect(viewModel.playableAccessKinds == [.standard])
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
        #expect(viewModel.carouselItems == items)

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

    @Test("Focus restoration selects the nearest surviving catalog card")
    func nearestSurvivingFocusTarget() {
        let orderedIDs = ["first", "second", "third", "fourth"]

        #expect(
            nearestSurvivingCatalogItemID(
                orderedIDs: orderedIDs,
                preferredID: "second",
                survivingIDs: ["first", "third", "fourth"]
            ) == "third"
        )
        #expect(
            nearestSurvivingCatalogItemID(
                orderedIDs: orderedIDs,
                preferredID: "fourth",
                survivingIDs: ["first", "second"]
            ) == "second"
        )
        #expect(
            nearestSurvivingCatalogItemID(
                orderedIDs: orderedIDs,
                preferredID: "second",
                survivingIDs: []
            ) == nil
        )
    }

    @Test("Home hero prefers matching rich landscape artwork")
    func homeHeroPrefersMatchingRichArtwork() throws {
        let posterURL = try #require(
            URL(string: "https://store-images.s-microsoft.com/poster.jpg")
        )
        let heroURL = try #require(
            URL(string: "https://store-images.s-microsoft.com/hero.jpg")
        )
        let catalogItem = XboxCatalogItem(
            id: "hero-game",
            title: "Hero Game",
            artworkURL: posterURL
        )
        let detailItem = XboxCatalogItem(
            id: "hero-game",
            title: "Hero Game",
            artworkURL: posterURL,
            heroArtworkURL: heroURL
        )

        let presentation = XboxHomeHeroPresentation(
            catalogItem: catalogItem,
            detailItem: detailItem
        )

        #expect(presentation.item == detailItem)
        #expect(presentation.artworkURL == heroURL)
        #expect(presentation.usesHeroArtwork)
    }

    @Test("Home hero rejects stale detail and retains portrait fallback")
    func homeHeroRejectsStaleDetail() throws {
        let posterURL = try #require(
            URL(string: "https://store-images.s-microsoft.com/poster.jpg")
        )
        let staleHeroURL = try #require(
            URL(string: "https://store-images.s-microsoft.com/stale-hero.jpg")
        )
        let catalogItem = XboxCatalogItem(
            id: "current-game",
            title: "Current Game",
            artworkURL: posterURL
        )
        let staleDetailItem = XboxCatalogItem(
            id: "previous-game",
            title: "Previous Game",
            artworkURL: nil,
            heroArtworkURL: staleHeroURL
        )

        let stalePresentation = XboxHomeHeroPresentation(
            catalogItem: catalogItem,
            detailItem: staleDetailItem
        )
        let failedPresentation = XboxHomeHeroPresentation(
            catalogItem: catalogItem,
            detailItem: nil
        )

        #expect(stalePresentation.item == catalogItem)
        #expect(stalePresentation.artworkURL == posterURL)
        #expect(!stalePresentation.usesHeroArtwork)
        #expect(failedPresentation == stalePresentation)
    }

    @Test("Home hero skips enrichment when landscape artwork already exists")
    func homeHeroWithLandscapeArtworkNeedsNoEnrichment() throws {
        let posterURL = try #require(
            URL(string: "https://store-images.s-microsoft.com/poster.jpg")
        )
        let heroURL = try #require(
            URL(string: "https://store-images.s-microsoft.com/hero.jpg")
        )
        let item = XboxCatalogItem(
            id: "rich-hero-game",
            title: "Rich Hero Game",
            artworkURL: posterURL,
            heroArtworkURL: heroURL
        )

        #expect(!XboxHomeHeroPresentation.requiresDetailEnrichment(item))
    }

    @MainActor
    @Test("Home exposes only account favorites and recent activity")
    func homeActivityBuckets() async {
        let scopedAccount = XboxCloudAuthorizedAccount(
            authorizationIdentifier: "transient-vault-handle",
            activityScopeIdentifier: "stable-activity-scope",
            displayName: "Fixture Player",
            expiresAt: .distantFuture
        )
        let first = makeAccessItem(id: "first", accessKinds: [.standard])
        let second = makeAccessItem(id: "second", accessKinds: [.freeWithAds])
        let third = makeAccessItem(
            id: "third",
            accessKinds: [.freeWithAds, .standard]
        )
        let items = [first, second, third]
        let persistence = XboxCatalogActivityPersistenceProbe(
            snapshots: [
                scopedAccount.activityScopeIdentifier: CloudCatalogActivitySnapshot(
                    favoriteIDs: [first.id, third.id],
                    recentlyPlayedIDs: [second.id, first.id]
                ),
            ]
        )
        let viewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(
                    items: items,
                    fetchedAt: fetchedAt
                )
            ),
            account: scopedAccount,
            cache: XboxCatalogMemoryCache(),
            activityPersistence: persistence
        )

        await viewModel.load()

        #expect(viewModel.favoriteItems == [first, third])
        #expect(viewModel.recentlyPlayedItems == [second, first])
        #expect(viewModel.favoriteIDs == [first.id, third.id])
        #expect(viewModel.recentlyPlayedIDs == [second.id, first.id])
        #expect(viewModel.visibleItems == items)
        #expect(viewModel.carouselItems == items)
        #expect(viewModel.phase == .loaded)
        #expect(viewModel.availableAccessKinds == [.standard, .freeWithAds])
        #expect(viewModel.playableAccessKinds == [.standard, .freeWithAds])
        #expect(
            await persistence.recordedLoadScopes()
                == [scopedAccount.activityScopeIdentifier]
        )
    }

    @MainActor
    @Test("Favorite mutations update Home and persist to the active account")
    func favoriteMutationsPersist() async {
        let first = makeAccessItem(id: "first", accessKinds: [.standard])
        let second = makeAccessItem(id: "second", accessKinds: [.standard])
        let persistence = XboxCatalogActivityPersistenceProbe()
        let viewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(
                    items: [first, second],
                    fetchedAt: fetchedAt
                )
            ),
            account: account,
            cache: XboxCatalogMemoryCache(),
            activityPersistence: persistence
        )

        await viewModel.load()
        viewModel.toggleFavorite(second)

        #expect(viewModel.isFavorite(second))
        #expect(viewModel.isFavorite(second.id))
        #expect(viewModel.favoriteItems == [second])
        #expect(viewModel.filterOptions.favoriteCount == 1)

        viewModel.toggleFavorite(second.id)
        await viewModel.flushActivityPersistence()

        #expect(!viewModel.isFavorite(second))
        #expect(viewModel.favoriteItems.isEmpty)
        #expect(
            await persistence.snapshot(
                accountScope: account.authorizationIdentifier
            ).favoriteIDs.isEmpty
        )
        #expect(
            await persistence.recordedFavoriteSaveScopes()
                == [account.authorizationIdentifier, account.authorizationIdentifier]
        )
    }

    @MainActor
    @Test("A newly added favorite survives bounded persistence")
    func newlyAddedFavoriteSurvivesBoundedPersistence() async {
        let newFavorite = makeAccessItem(
            id: "zz-new-favorite",
            accessKinds: [.standard]
        )
        let existingFavorites = Set(
            (0 ..< CloudCatalogActivitySnapshot.maximumFavoriteCount)
                .map { "old-favorite-\($0)" }
        )
        let persistence = XboxCatalogActivityPersistenceProbe(
            snapshots: [
                account.activityScopeIdentifier: CloudCatalogActivitySnapshot(
                    favoriteIDs: existingFavorites
                ),
            ]
        )
        let viewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(
                    items: [newFavorite],
                    fetchedAt: fetchedAt
                )
            ),
            account: account,
            cache: XboxCatalogMemoryCache(),
            activityPersistence: persistence
        )

        await viewModel.load()
        viewModel.toggleFavorite(newFavorite)
        await viewModel.flushActivityPersistence()

        let snapshot = await persistence.snapshot(
            accountScope: account.activityScopeIdentifier
        )
        #expect(snapshot.favoriteIDs.count == CloudCatalogActivitySnapshot.maximumFavoriteCount)
        #expect(snapshot.favoriteIDs.contains(newFavorite.id))
    }

    @MainActor
    @Test("Queued favorites survive view-model replacement for the same account")
    func queuedFavoritesSurviveViewModelReplacement() async {
        let stableScope = "stable-favorite-account"
        let firstAccount = XboxCloudAuthorizedAccount(
            authorizationIdentifier: "first-transient-authorization",
            activityScopeIdentifier: stableScope,
            displayName: nil,
            expiresAt: .distantFuture
        )
        let replacementAccount = XboxCloudAuthorizedAccount(
            authorizationIdentifier: "replacement-transient-authorization",
            activityScopeIdentifier: stableScope,
            displayName: nil,
            expiresAt: .distantFuture
        )
        let first = makeAccessItem(id: "first", accessKinds: [.standard])
        let second = makeAccessItem(id: "second", accessKinds: [.standard])
        let snapshot = XboxCatalogSnapshot(
            items: [first, second],
            fetchedAt: fetchedAt
        )
        let persistence = XboxCatalogActivityPersistenceProbe()
        await persistence.suspendNextFavoriteSave()
        var viewModel: XboxCatalogViewModel? = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(snapshot: snapshot),
            account: firstAccount,
            cache: XboxCatalogMemoryCache(),
            activityPersistence: persistence
        )
        await viewModel?.load()

        viewModel?.toggleFavorite(first)
        await persistence.waitUntilFavoriteSaveIsSuspended()
        viewModel?.toggleFavorite(second)
        weak let releasedViewModel = viewModel
        viewModel = nil

        #expect(releasedViewModel == nil)

        await persistence.resumeFavoriteSave()
        for _ in 0 ..< 1000 {
            guard await persistence.favoriteSaveCount() < 2 else { break }
            await Task.yield()
        }
        #expect(await persistence.favoriteSaveCount() == 2)

        let replacement = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(snapshot: snapshot),
            account: replacementAccount,
            cache: XboxCatalogMemoryCache(),
            activityPersistence: persistence
        )
        await replacement.load()

        #expect(replacement.favoriteIDs == [first.id, second.id])
        #expect(replacement.favoriteItems == [first, second])
    }

    @MainActor
    @Test("Catalog activity remains isolated between Xbox accounts")
    func activityIsAccountScoped() async {
        let first = makeAccessItem(id: "first", accessKinds: [.standard])
        let second = makeAccessItem(id: "second", accessKinds: [.standard])
        let secondAccount = XboxCloudAuthorizedAccount(
            authorizationIdentifier: "second-account-\(UUID().uuidString)",
            displayName: "Second Fixture Player",
            expiresAt: .distantFuture
        )
        let persistence = XboxCatalogActivityPersistenceProbe(
            snapshots: [
                account.authorizationIdentifier: CloudCatalogActivitySnapshot(
                    favoriteIDs: [first.id]
                ),
                secondAccount.authorizationIdentifier: CloudCatalogActivitySnapshot(
                    favoriteIDs: [second.id]
                ),
            ]
        )
        let snapshot = XboxCatalogSnapshot(
            items: [first, second],
            fetchedAt: fetchedAt
        )
        let firstViewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(snapshot: snapshot),
            account: account,
            cache: XboxCatalogMemoryCache(),
            activityPersistence: persistence
        )
        let secondViewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(snapshot: snapshot),
            account: secondAccount,
            cache: XboxCatalogMemoryCache(),
            activityPersistence: persistence
        )

        await firstViewModel.load()
        await secondViewModel.load()

        #expect(firstViewModel.favoriteItems == [first])
        #expect(secondViewModel.favoriteItems == [second])
    }

    @MainActor
    @Test("Recent activity is deduplicated, bounded, ordered, and persisted")
    func recentActivityIsBoundedAndPersisted() async {
        let items = makeItems(count: 12)
        let persistence = XboxCatalogActivityPersistenceProbe()
        let viewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(items: items, fetchedAt: fetchedAt)
            ),
            account: account,
            cache: XboxCatalogMemoryCache(),
            activityPersistence: persistence
        )

        await viewModel.load()
        for item in items {
            viewModel.recordPlayed(item)
        }
        viewModel.recordPlayed(items[5])
        await viewModel.flushActivityPersistence()

        let expectedIDs = [items[5].id]
            + (2 ... 11).reversed().map { items[$0].id }
            .filter { $0 != items[5].id }
        #expect(viewModel.recentlyPlayedIDs == expectedIDs)
        #expect(viewModel.recentlyPlayedItems.map(\.id) == expectedIDs)
        #expect(viewModel.recentlyPlayedIDs.count == 10)
        #expect(
            await persistence.snapshot(
                accountScope: account.authorizationIdentifier
            ).recentlyPlayedIDs == expectedIDs
        )
    }

    @MainActor
    @Test("Cache clearing preserves activity while full reset clears it")
    func cacheAndPersistentResetActivitySemantics() async {
        let item = makeAccessItem(id: "favorite", accessKinds: [.standard])
        let persistence = XboxCatalogActivityPersistenceProbe(
            snapshots: [
                account.authorizationIdentifier: CloudCatalogActivitySnapshot(
                    favoriteIDs: [item.id],
                    recentlyPlayedIDs: [item.id]
                ),
            ]
        )
        let viewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(items: [item], fetchedAt: fetchedAt)
            ),
            account: account,
            cache: XboxCatalogMemoryCache(),
            activityPersistence: persistence
        )

        await viewModel.load()
        viewModel.prepareForCacheClear()

        #expect(viewModel.favoriteIDs == [item.id])
        #expect(viewModel.recentlyPlayedIDs == [item.id])
        #expect(viewModel.favoriteItems.isEmpty)
        #expect(viewModel.recentlyPlayedItems.isEmpty)

        viewModel.prepareForPersistentDataClear()

        #expect(viewModel.favoriteIDs.isEmpty)
        #expect(viewModel.recentlyPlayedIDs.isEmpty)
        #expect(viewModel.favoriteItems.isEmpty)
        #expect(viewModel.recentlyPlayedItems.isEmpty)
    }

    @MainActor
    @Test("Browse combines filter sections with OR within each section")
    func browseCombinableFilters() async throws {
        let favoriteStandard = makeAccessItem(
            id: "favorite-standard",
            accessKinds: [.standard],
            genres: ["Role-Playing"],
            supportedInputTypes: [.controller]
        )
        let ownedFree = makeAccessItem(
            id: "owned-free",
            accessKinds: [.freeWithAds],
            genres: ["Racing"],
            supportedInputTypes: [.controller, .touch],
            isOwned: true
        )
        let favoriteOwnedDual = makeAccessItem(
            id: "favorite-owned-dual",
            accessKinds: [.standard, .freeWithAds],
            genres: ["role-playing", "Racing"],
            supportedInputTypes: [.controller, .mouseAndKeyboard],
            isOwned: true
        )
        let standardPuzzle = makeAccessItem(
            id: "standard-puzzle",
            accessKinds: [.standard],
            genres: ["Puzzle"],
            supportedInputTypes: [.mouseAndKeyboard]
        )
        let items = [
            favoriteStandard,
            ownedFree,
            favoriteOwnedDual,
            standardPuzzle,
        ]
        let persistence = XboxCatalogActivityPersistenceProbe(
            snapshots: [
                account.authorizationIdentifier: CloudCatalogActivitySnapshot(
                    favoriteIDs: [favoriteStandard.id, favoriteOwnedDual.id]
                ),
            ]
        )
        let viewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(
                    items: items,
                    fetchedAt: fetchedAt
                )
            ),
            account: account,
            cache: XboxCatalogMemoryCache(),
            activityPersistence: persistence
        )

        await viewModel.load()

        #expect(viewModel.filterState.isEmpty)
        #expect(viewModel.visibleItems == items)
        #expect(viewModel.totalItemCount == 4)
        #expect(viewModel.filteredItemCount == 4)
        #expect(viewModel.filterOptions.favoriteCount == 2)
        #expect(viewModel.filterOptions.standardCount == 3)
        #expect(viewModel.filterOptions.freeWithAdsCount == 2)
        #expect(viewModel.filterOptions.ownedCount == 2)
        #expect(viewModel.filterOptions.inputTypeCounts[.controller] == 3)
        #expect(viewModel.filterOptions.inputTypeCounts[.touch] == nil)
        #expect(viewModel.filterOptions.inputTypeCounts[.mouseAndKeyboard] == 2)
        #expect(viewModel.filterOptions.playableCount == 4)
        #expect(viewModel.filterOptions.unavailableCount == 0)
        #expect(!viewModel.hasActiveBrowseFilters)

        var state = XboxCatalogFilterState()
        state.access = [.freeWithAds, .owned]
        viewModel.filterState = state

        #expect(viewModel.visibleItems == [ownedFree, favoriteOwnedDual])
        #expect(viewModel.filteredItemCount == 2)
        #expect(viewModel.activeBrowseFilterCount == 2)
        #expect(viewModel.hasActiveBrowseFilters)

        state.collections = [.favorites]
        viewModel.filterState = state

        #expect(viewModel.visibleItems == [favoriteOwnedDual])

        let rolePlayingID = try #require(
            viewModel.filterOptions.genres.first {
                $0.label.localizedCaseInsensitiveContains("role")
            }?.id
        )
        let racingID = try #require(
            viewModel.filterOptions.genres.first {
                $0.label.localizedCaseInsensitiveContains("racing")
            }?.id
        )
        state = XboxCatalogFilterState(
            access: [.standard],
            genres: [rolePlayingID, racingID]
        )
        viewModel.filterState = state

        #expect(viewModel.visibleItems == [favoriteStandard, favoriteOwnedDual])
        #expect(viewModel.browsePreviewCount(for: state) == 2)
        #expect(viewModel.activeBrowseFilterCount == 3)

        state = XboxCatalogFilterState(
            access: [.standard],
            inputTypes: [.touch, .mouseAndKeyboard]
        )
        viewModel.filterState = state

        #expect(viewModel.visibleItems == [favoriteOwnedDual, standardPuzzle])
        #expect(viewModel.browsePreviewCount(for: state) == 2)
        #expect(viewModel.activeBrowseFilterCount == 3)

        viewModel.clearBrowseFilters()

        #expect(viewModel.visibleItems == items)
        #expect(viewModel.filterState.isEmpty)
        #expect(!viewModel.hasActiveBrowseFilters)
    }

    @Test("Catalog filter sections expose only non-empty options")
    func filterSectionAvailabilityIsDataDriven() {
        #expect(!XboxCatalogFilterOptions.empty.showsCollectionsSection)
        #expect(XboxCatalogFilterOptions.empty.availableAccessFilters.isEmpty)

        let accessOnly = XboxCatalogFilterOptions(
            genres: [],
            inputTypeCounts: [:],
            favoriteCount: 0,
            standardCount: 0,
            freeWithAdsCount: 2,
            ownedCount: 0,
            playableCount: 2,
            unavailableCount: 0,
            unavailableReasonCounts: [:]
        )
        #expect(!accessOnly.showsCollectionsSection)
        #expect(accessOnly.availableAccessFilters == [.freeWithAds])
        #expect(accessOnly.accessCount(.freeWithAds) == 2)

        let favoritesOnly = XboxCatalogFilterOptions(
            genres: [],
            inputTypeCounts: [:],
            favoriteCount: 1,
            standardCount: 0,
            freeWithAdsCount: 0,
            ownedCount: 0,
            playableCount: 1,
            unavailableCount: 0,
            unavailableReasonCounts: [:]
        )
        #expect(favoritesOnly.showsCollectionsSection)
        #expect(favoritesOnly.availableAccessFilters.isEmpty)
    }

    @MainActor
    @Test("Browse search is trimmed and case-insensitive")
    func browseSearch() async {
        let haloInfinite = makeAccessItem(
            id: "Halo Infinite",
            accessKinds: [.standard]
        )
        let forza = makeAccessItem(
            id: "Forza Horizon",
            accessKinds: [.standard]
        )
        let haloWars = makeAccessItem(
            id: "halo wars",
            accessKinds: [.freeWithAds]
        )
        let viewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(
                    items: [haloInfinite, forza, haloWars],
                    fetchedAt: fetchedAt
                )
            ),
            account: account,
            cache: XboxCatalogMemoryCache()
        )

        await viewModel.load()
        viewModel.searchText = "  HaLo\n"

        #expect(viewModel.visibleItems == [haloInfinite, haloWars])
        #expect(viewModel.totalItemCount == 3)
        #expect(viewModel.browseFilterBaseCount == 2)
        #expect(viewModel.filteredItemCount == 2)
        #expect(
            viewModel.browsePreviewCount(
                for: XboxCatalogFilterState(access: [.standard])
            ) == 1
        )
        #expect(
            viewModel.browsePreviewCount(
                for: XboxCatalogFilterState(access: [.freeWithAds])
            ) == 1
        )

        viewModel.filterState.access = [.freeWithAds]

        #expect(viewModel.visibleItems == [haloWars])
        #expect(viewModel.browseFilterBaseCount == 2)
        #expect(viewModel.filteredItemCount == 1)

        viewModel.searchText = " \n\t "

        #expect(viewModel.visibleItems == [haloWars])
        #expect(viewModel.browseFilterBaseCount == 3)
        #expect(viewModel.filteredItemCount == 1)
    }

    @MainActor
    @Test("Playability and unavailable-reason filters stay reasoned")
    func reasonedPlayabilityFilters() async {
        let playable = makeAccessItem(
            id: "playable",
            accessKinds: [.standard],
            supportedInputTypes: [.controller]
        )
        let planRequired = makeAccessItem(
            id: "plan-required",
            accessKinds: [.standard],
            supportedInputTypes: [.controller],
            availability: .requiresEligibility,
            playabilityReason: .entitlementRequired
        )
        let timeExhausted = makeAccessItem(
            id: "time-exhausted",
            accessKinds: [.freeWithAds],
            supportedInputTypes: [.controller],
            availability: .requiresEligibility,
            playabilityReason: .gameplayTimeExhausted
        )
        let viewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(
                    items: [playable, planRequired, timeExhausted],
                    fetchedAt: fetchedAt
                )
            ),
            account: account,
            cache: XboxCatalogMemoryCache(),
            activityPersistence: XboxCatalogActivityPersistenceProbe()
        )

        await viewModel.load()

        #expect(viewModel.filterOptions.playableCount == 1)
        #expect(viewModel.filterOptions.unavailableCount == 2)
        #expect(
            viewModel.filterOptions.unavailableReasonCounts[
                .entitlementRequired
            ] == 1
        )

        var state = XboxCatalogFilterState()
        state.playability = [.unavailable]
        viewModel.filterState = state
        #expect(viewModel.visibleItems == [planRequired, timeExhausted])

        state.unavailableReasons = [.gameplayTimeExhausted]
        viewModel.filterState = state
        #expect(viewModel.visibleItems == [timeExhausted])
        #expect(viewModel.activeBrowseFilterCount == 2)
    }

    @MainActor
    @Test("Browse sorts titles while preserving the service order by default")
    func browseSortOrder() async {
        let charlie = makeAccessItem(id: "Charlie", accessKinds: [.standard])
        let alpha = makeAccessItem(id: "Alpha", accessKinds: [.standard])
        let bravo = makeAccessItem(id: "Bravo", accessKinds: [.standard])
        let serviceOrder = [charlie, alpha, bravo]
        let persistence = XboxCatalogActivityPersistenceProbe(
            snapshots: [
                account.authorizationIdentifier: CloudCatalogActivitySnapshot(
                    recentlyPlayedIDs: [bravo.id, charlie.id]
                ),
            ]
        )
        let viewModel = XboxCatalogViewModel(
            client: XboxCatalogClientProbe(
                snapshot: XboxCatalogSnapshot(
                    items: serviceOrder,
                    fetchedAt: fetchedAt
                )
            ),
            account: account,
            cache: XboxCatalogMemoryCache(),
            activityPersistence: persistence
        )

        await viewModel.load()

        #expect(viewModel.sortOrder == .default)
        #expect(viewModel.visibleItems == serviceOrder)

        viewModel.sortOrder = .titleAZ

        #expect(viewModel.visibleItems == [alpha, bravo, charlie])

        viewModel.sortOrder = .titleZA

        #expect(viewModel.visibleItems == [charlie, bravo, alpha])

        viewModel.sortOrder = .recentFirst

        #expect(viewModel.visibleItems == [bravo, charlie, alpha])

        viewModel.sortOrder = .default

        #expect(viewModel.visibleItems == serviceOrder)
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
        #expect(viewModel.filterState.isEmpty)
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

        #expect(viewModel.availableAccessKinds == [.freeWithAds])
        #expect(viewModel.playableAccessKinds.isEmpty)
        viewModel.filterState.access = [.freeWithAds]
        #expect(viewModel.visibleItems == [candidate])
        let selectedRoute = try #require(
            viewModel.visibleItems.first?.preferredRoute
        )
        #expect(selectedRoute == route)
        #expect(!route.isPlayable)
    }

    @MainActor
    @Test("Detail failures remain retryable instead of caching sparse data")
    func detailFailureRemainsRetryable() async {
        let item = makeAccessItem(id: "detail", accessKinds: [.standard])
        let client = XboxCatalogClientProbe(
            snapshot: XboxCatalogSnapshot(items: [item], fetchedAt: fetchedAt),
            failsDetailResponse: true
        )
        let viewModel = XboxCatalogViewModel(
            client: client,
            account: account,
            cache: XboxCatalogMemoryCache()
        )

        await viewModel.load()

        #expect(await viewModel.fetchDetail(for: item) == nil)
        #expect(await viewModel.fetchDetail(for: item) == nil)
        #expect(await client.recordedDetailRequestCount() == 2)
    }

    @MainActor
    @Test("Successful detail responses are reused across Xbox surfaces")
    func successfulDetailResponseIsCached() async {
        let item = makeAccessItem(id: "cached-detail", accessKinds: [.standard])
        let client = XboxCatalogClientProbe(
            snapshot: XboxCatalogSnapshot(items: [item], fetchedAt: fetchedAt)
        )
        let viewModel = XboxCatalogViewModel(
            client: client,
            account: account,
            cache: XboxCatalogMemoryCache()
        )

        await viewModel.load()

        #expect(await viewModel.fetchDetail(for: item) == item)
        #expect(await viewModel.fetchDetail(for: item) == item)
        #expect(await client.recordedDetailRequestCount() == 1)
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

        viewModel.filterState.access = [.freeWithAds]

        #expect(
            viewModel.visibleItems
                == Array(freeWithAdsItems.prefix(96))
        )
        viewModel.loadNextPageIfNeeded(allBoundary)
        #expect(viewModel.visibleItems.count == 96)
        let freeWithAdsBoundary = try #require(viewModel.visibleItems.last)
        viewModel.loadNextPageIfNeeded(freeWithAdsBoundary)
        #expect(viewModel.visibleItems == freeWithAdsItems)

        viewModel.clearBrowseFilters()

        #expect(viewModel.visibleItems == Array(items.prefix(96)))
    }

    @MainActor
    @Test("Changing search or sort resets browse pagination")
    func searchAndSortResetPagination() async throws {
        let items = (0 ..< 250).map { index in
            makeAccessItem(
                id: "Game \(index)",
                accessKinds: [.standard]
            )
        }
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
        let firstBoundary = try #require(viewModel.visibleItems.last)
        viewModel.loadNextPageIfNeeded(firstBoundary)
        #expect(viewModel.visibleItems.count == 192)

        viewModel.sortOrder = .titleZA

        let descending = items.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedDescending
        }
        #expect(viewModel.visibleItems == Array(descending.prefix(96)))
        #expect(viewModel.carouselItems == descending)
        let sortedBoundary = try #require(viewModel.visibleItems.last)
        viewModel.loadNextPageIfNeeded(sortedBoundary)
        #expect(viewModel.visibleItems == Array(descending.prefix(192)))

        viewModel.searchText = "  GAME 1  "

        let matching = descending.filter {
            $0.title.localizedCaseInsensitiveContains("GAME 1")
        }
        #expect(matching.count > 96)
        #expect(viewModel.visibleItems == Array(matching.prefix(96)))
        #expect(viewModel.carouselItems == matching)
        #expect(viewModel.browseFilterBaseCount == matching.count)
        #expect(viewModel.filteredItemCount == matching.count)
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
        #expect(viewModel.carouselItems.isEmpty)
        #expect(viewModel.favoriteItems.isEmpty)
        #expect(viewModel.recentlyPlayedItems.isEmpty)
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
        let cache = XboxCatalogMemoryCache()
        let viewModel = XboxCatalogViewModel(
            makeClient: { factory.makeClient() },
            account: account,
            cache: cache,
            freshnessInterval: 0
        )

        #expect(factory.creationCount == 0)

        await viewModel.load()

        #expect(factory.creationCount == 1)
        #expect(viewModel.visibleItems == items)

        viewModel.prepareForCacheClear()
        await cache.clear()

        #expect(viewModel.visibleItems.isEmpty)
        #expect(viewModel.phase == .idle)

        await viewModel.load()

        #expect(factory.creationCount == 2)
        #expect(viewModel.visibleItems == items)
    }

    @MainActor
    @Test("Provider deactivation releases rows but keeps the bounded re-entry cache")
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
        #expect(await cache.snapshot(for: cacheKey) == snapshot)
    }

    @MainActor
    @Test("A reauthorized Xbox account reuses its stable scoped catalog cache")
    func reauthorizationReusesStableScopedCache() async {
        let stableScope = "stable-account-scope"
        let firstAccount = XboxCloudAuthorizedAccount(
            authorizationIdentifier: "first-vault-handle",
            activityScopeIdentifier: stableScope,
            displayName: nil,
            expiresAt: .distantFuture
        )
        let reauthorizedAccount = XboxCloudAuthorizedAccount(
            authorizationIdentifier: "replacement-vault-handle",
            activityScopeIdentifier: stableScope,
            displayName: nil,
            expiresAt: .distantFuture
        )
        let items = makeItems(count: 3)
        let snapshot = XboxCatalogSnapshot(items: items, fetchedAt: fetchedAt)
        let cache = XboxCatalogMemoryCache()
        let firstClient = XboxCatalogClientProbe(snapshot: snapshot)
        let firstViewModel = XboxCatalogViewModel(
            client: firstClient,
            account: firstAccount,
            cache: cache,
            now: { fetchedAt }
        )

        await firstViewModel.load()
        await firstViewModel.deactivateForInactiveProvider()

        let replacementClient = XboxCatalogClientProbe(
            snapshot: snapshot,
            failsResponse: true
        )
        let replacementViewModel = XboxCatalogViewModel(
            client: replacementClient,
            account: reauthorizedAccount,
            cache: cache,
            now: { fetchedAt }
        )
        await replacementViewModel.load()

        #expect(replacementViewModel.visibleItems == items)
        #expect(replacementViewModel.phase == .loaded)
        #expect(await replacementClient.recordedRequests().isEmpty)
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
    @Test("Provider re-entry presents stale cache until explicit refresh")
    func staleCacheWaitsForExplicitRefresh() async {
        let cachedItems = makeItems(count: 2)
        let refreshedItems = [
            makeAccessItem(id: "refreshed", accessKinds: [.standard]),
        ]
        let cachedSnapshot = XboxCatalogSnapshot(
            items: cachedItems,
            fetchedAt: fetchedAt
        )
        let refreshedSnapshot = XboxCatalogSnapshot(
            items: refreshedItems,
            fetchedAt: fetchedAt.addingTimeInterval(3601)
        )
        let cache = XboxCatalogMemoryCache()
        let key = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: account.activityScopeIdentifier,
            localeIdentifier: L10n.localeCode,
            market: Locale.current.region?.identifier
        )
        await cache.store(cachedSnapshot, for: key)
        let client = XboxCatalogClientProbe(snapshot: refreshedSnapshot)
        let viewModel = XboxCatalogViewModel(
            client: client,
            account: account,
            cache: cache,
            now: { fetchedAt.addingTimeInterval(3600) }
        )

        await viewModel.load()

        #expect(viewModel.visibleItems == cachedItems)
        #expect(viewModel.phase == .loaded)
        #expect(viewModel.showsRefreshWarning)
        #expect(viewModel.catalogLastUpdatedAt == fetchedAt)
        #expect(await client.recordedRequests().isEmpty)

        await viewModel.load()
        #expect(await client.recordedRequests().isEmpty)

        await viewModel.reload()

        #expect(viewModel.visibleItems == refreshedItems)
        #expect(viewModel.phase == .loaded)
        #expect(!viewModel.showsRefreshWarning)
        #expect(await cache.snapshot(for: key) == refreshedSnapshot)
        #expect(await client.recordedRequests().count == 1)
        #expect(await client.recordedRefreshAccounts() == [account])
    }

    @MainActor
    @Test("Explicit reload invalidates account state and bypasses a fresh cache")
    func reloadForcesCatalogRefresh() async {
        let cachedItems = makeItems(count: 2)
        let refreshedItems = [
            makeAccessItem(id: "refreshed", accessKinds: [.standard]),
        ]
        let cachedSnapshot = XboxCatalogSnapshot(
            items: cachedItems,
            fetchedAt: fetchedAt
        )
        let refreshedSnapshot = XboxCatalogSnapshot(
            items: refreshedItems,
            fetchedAt: fetchedAt.addingTimeInterval(1)
        )
        let cache = XboxCatalogMemoryCache()
        let key = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: account.authorizationIdentifier,
            localeIdentifier: L10n.localeCode,
            market: Locale.current.region?.identifier
        )
        await cache.store(cachedSnapshot, for: key)
        let client = XboxCatalogClientProbe(snapshot: refreshedSnapshot)
        let viewModel = XboxCatalogViewModel(
            client: client,
            account: account,
            cache: cache,
            now: { fetchedAt }
        )

        await viewModel.load()

        #expect(viewModel.visibleItems == cachedItems)
        #expect(await client.recordedRequests().isEmpty)

        await viewModel.reload()

        #expect(viewModel.visibleItems == refreshedItems)
        #expect(viewModel.phase == .loaded)
        #expect(await client.recordedRefreshAccounts() == [account])
        #expect(await client.recordedRequests().count == 1)
        #expect(await cache.snapshot(for: key) == refreshedSnapshot)
    }

    @MainActor
    @Test("Explicit reload exposes progress, keeps content, and coalesces taps")
    func reloadProgressKeepsLastGoodCatalog() async {
        let cachedItems = makeItems(count: 2)
        let refreshedItems = [
            makeAccessItem(id: "refreshed", accessKinds: [.standard]),
        ]
        let cachedSnapshot = XboxCatalogSnapshot(
            items: cachedItems,
            fetchedAt: fetchedAt
        )
        let cache = XboxCatalogMemoryCache()
        let key = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: account.activityScopeIdentifier,
            localeIdentifier: L10n.localeCode,
            market: Locale.current.region?.identifier
        )
        await cache.store(cachedSnapshot, for: key)
        let client = XboxCatalogClientProbe(
            snapshot: XboxCatalogSnapshot(
                items: refreshedItems,
                fetchedAt: fetchedAt.addingTimeInterval(1)
            ),
            suspendsResponse: true
        )
        let viewModel = XboxCatalogViewModel(
            client: client,
            account: account,
            cache: cache,
            now: { fetchedAt }
        )

        await viewModel.load()
        let reloadTask = Task { @MainActor in
            await viewModel.reload()
        }
        await client.waitForRequestCount(1)

        #expect(viewModel.isRefreshing)
        #expect(viewModel.visibleItems == cachedItems)
        #expect(viewModel.phase == .loaded)

        await viewModel.reload()

        #expect(await client.recordedRequests().count == 1)

        await client.resolvePendingResponse()
        await reloadTask.value

        #expect(!viewModel.isRefreshing)
        #expect(viewModel.visibleItems == refreshedItems)
        #expect(viewModel.phase == .loaded)
    }

    @MainActor
    @Test("Catalog cancellation immediately clears explicit reload progress")
    func cancellationClearsReloadProgress() async {
        let items = makeItems(count: 2)
        let snapshot = XboxCatalogSnapshot(items: items, fetchedAt: fetchedAt)
        let cache = XboxCatalogMemoryCache()
        let key = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: account.activityScopeIdentifier,
            localeIdentifier: L10n.localeCode,
            market: Locale.current.region?.identifier
        )
        await cache.store(snapshot, for: key)
        let client = XboxCatalogClientProbe(
            snapshot: snapshot,
            suspendsResponse: true
        )
        let viewModel = XboxCatalogViewModel(
            client: client,
            account: account,
            cache: cache,
            now: { fetchedAt }
        )

        await viewModel.load()
        let reloadTask = Task { @MainActor in
            await viewModel.reload()
        }
        await client.waitForRequestCount(1)
        #expect(viewModel.isRefreshing)

        viewModel.prepareForCacheClear()

        #expect(!viewModel.isRefreshing)
        #expect(viewModel.phase == .idle)
        #expect(viewModel.visibleItems.isEmpty)

        await client.resolvePendingResponse()
        await reloadTask.value

        #expect(!viewModel.isRefreshing)
        #expect(viewModel.phase == .idle)
        #expect(viewModel.visibleItems.isEmpty)
    }

    @MainActor
    @Test("A stale catalog remains visible after explicit refresh fails")
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
        #expect(await client.recordedRequests().isEmpty)

        await viewModel.reload()

        #expect(viewModel.visibleItems == items)
        #expect(viewModel.phase == .loaded)
        #expect(viewModel.showsRefreshWarning)
        #expect(await client.recordedRequests().count == 1)
    }

    @MainActor
    @Test("A failed explicit reload retains the last good catalog")
    func failedReloadRetainsLastGoodCatalog() async {
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
            now: { fetchedAt }
        )

        await viewModel.load()
        await viewModel.reload()

        #expect(viewModel.visibleItems == items)
        #expect(viewModel.phase == .loaded)
        #expect(viewModel.showsRefreshWarning)
        #expect(await cache.snapshot(for: key) == snapshot)
        #expect(await client.recordedRefreshAccounts() == [account])
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
                    artworkURL: URL(
                        string: "http://store-images.s-microsoft.com/cover.jpg"
                    )
                ),
                XboxCatalogItem(
                    id: "signed",
                    title: "Signed",
                    artworkURL: URL(
                        string: "https://store-images.s-microsoft.com/cover.jpg?signature=secret"
                    )
                ),
                XboxCatalogItem(
                    id: "public",
                    title: "Public",
                    artworkURL: URL(
                        string: "https://store-images.s-microsoft.com/cover.jpg?width=640"
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
        #expect(validated.items.map(\.id) == ["PUBLIC", "NO-ARTWORK"])
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
        accessKinds: [XboxCloudAccessKind],
        genres: [String] = [],
        supportedInputTypes: Set<XboxCloudInputType> = [],
        isOwned: Bool = false,
        availability: XboxCloudRouteAvailability = .playable,
        playabilityReason: XboxCloudRoutePlayabilityReason? = nil
    ) -> XboxCatalogItem {
        XboxCatalogItem(
            id: id,
            title: id,
            genres: genres,
            artworkURL: nil,
            supportedInputTypes: supportedInputTypes,
            isOwned: isOwned,
            routes: accessKinds.enumerated().map { index, accessKind in
                XboxCloudTitleRoute(
                    titleID: "\(id)-route-\(index)",
                    accessKind: accessKind,
                    availability: availability,
                    playabilityReason: playabilityReason
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

private actor XboxCatalogActivityPersistenceProbe: XboxCatalogActivityPersistence {
    private let persistenceGeneration: UInt64 = 7
    private var snapshots: [String: CloudCatalogActivitySnapshot]
    private var loadScopes: [String?] = []
    private var favoriteSaveScopes: [String?] = []
    private var shouldSuspendNextFavoriteSave = false
    private var suspendedFavoriteSave: CheckedContinuation<Void, Never>?
    private var favoriteSaveSuspensionWaiters: [CheckedContinuation<Void, Never>] = []

    init(snapshots: [String: CloudCatalogActivitySnapshot] = [:]) {
        self.snapshots = snapshots
    }

    func loadXboxCatalogActivityLease(
        accountScope: String?
    ) async -> CloudCatalogActivityLease {
        loadScopes.append(accountScope)
        let snapshot = accountScope.flatMap { snapshots[$0] }
            ?? CloudCatalogActivitySnapshot()
        return CloudCatalogActivityLease(
            snapshot: snapshot,
            generation: persistenceGeneration
        )
    }

    func saveXboxFavoriteIDs(
        _ favoriteIDs: Set<String>,
        accountScope: String?,
        expectedGeneration: UInt64
    ) async {
        guard expectedGeneration == persistenceGeneration else { return }
        if shouldSuspendNextFavoriteSave {
            shouldSuspendNextFavoriteSave = false
            let waiters = favoriteSaveSuspensionWaiters
            favoriteSaveSuspensionWaiters.removeAll(keepingCapacity: false)
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                suspendedFavoriteSave = continuation
            }
            suspendedFavoriteSave = nil
        }
        favoriteSaveScopes.append(accountScope)
        guard let accountScope else { return }
        var snapshot = snapshots[accountScope] ?? CloudCatalogActivitySnapshot()
        snapshot.favoriteIDs = favoriteIDs
        snapshots[accountScope] = snapshot
    }

    func saveXboxRecentlyPlayedIDs(
        _ recentlyPlayedIDs: [String],
        accountScope: String?,
        expectedGeneration: UInt64
    ) async {
        guard expectedGeneration == persistenceGeneration else { return }
        guard let accountScope else { return }
        var snapshot = snapshots[accountScope] ?? CloudCatalogActivitySnapshot()
        snapshot.recentlyPlayedIDs = recentlyPlayedIDs
        snapshots[accountScope] = snapshot
    }

    func snapshot(accountScope: String) -> CloudCatalogActivitySnapshot {
        snapshots[accountScope] ?? CloudCatalogActivitySnapshot()
    }

    func recordedLoadScopes() -> [String?] {
        loadScopes
    }

    func recordedFavoriteSaveScopes() -> [String?] {
        favoriteSaveScopes
    }

    func suspendNextFavoriteSave() {
        shouldSuspendNextFavoriteSave = true
    }

    func waitUntilFavoriteSaveIsSuspended() async {
        guard suspendedFavoriteSave == nil else { return }
        await withCheckedContinuation { continuation in
            favoriteSaveSuspensionWaiters.append(continuation)
        }
    }

    func resumeFavoriteSave() {
        suspendedFavoriteSave?.resume()
        suspendedFavoriteSave = nil
    }

    func favoriteSaveCount() -> Int {
        favoriteSaveScopes.count
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
    private let failsDetailResponse: Bool
    private var requests: [XboxCatalogRequest] = []
    private var detailRequestCount = 0
    private var accounts: [XboxCloudAuthorizedAccount] = []
    private var refreshAccounts: [XboxCloudAuthorizedAccount] = []
    private var pendingResponse: CheckedContinuation<XboxCatalogSnapshot, Error>?
    private var requestWaiters: [(
        target: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    init(
        snapshot: XboxCatalogSnapshot,
        suspendsResponse: Bool = false,
        failsResponse: Bool = false,
        failsDetailResponse: Bool = false
    ) {
        self.snapshot = snapshot
        self.suspendsResponse = suspendsResponse
        self.failsResponse = failsResponse
        self.failsDetailResponse = failsDetailResponse
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

    func fetchDetail(
        for item: XboxCatalogItem,
        request _: XboxCatalogRequest
    ) async throws -> XboxCatalogItem {
        detailRequestCount += 1
        if failsDetailResponse {
            throw XboxCatalogClientProbeError.unavailable
        }
        return item
    }

    func recordedDetailRequestCount() -> Int {
        detailRequestCount
    }

    func refreshAccountState(for account: XboxCloudAuthorizedAccount) async {
        refreshAccounts.append(account)
    }

    func recordedRefreshAccounts() -> [XboxCloudAuthorizedAccount] {
        refreshAccounts
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
