@testable import CloudNow
import Foundation
import Testing

@Suite("Games view-model state")
struct GamesViewModelTests {
    @MainActor
    @Test("Cached catalog appears before its deterministic refresh completes")
    func cachedCatalogAppearsBeforeRefresh() async {
        let cached = makeGame(id: "cached", title: "Cached")
        let refreshed = makeGame(id: "fresh", title: "Fresh")
        var snapshot = AppPersistenceStore.GamesSnapshot()
        snapshot.favoriteIds = ["cached"]
        snapshot.libraryGames = [cached]
        snapshot.vpcId = "TEST-VPC"
        let persistence = FakeGamesPersistence(
            snapshot: snapshot,
            cachedCatalog: [cached]
        )
        let gamesClient = ScriptedGamesClient(
            mainOutcomes: [.success([refreshed])],
            libraryOutcomes: [.success([refreshed])],
            blocksFirstMainRequest: true
        )
        let viewModel = GamesViewModel(
            gamesClient: gamesClient,
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: FakeMembershipClient(),
            persistence: persistence
        )
        let authManager = await makeAuthenticatedManager()

        let load = Task { @MainActor in
            await viewModel.load(authManager: authManager)
        }
        await gamesClient.waitForMainRequest(count: 1)

        #expect(viewModel.mainGames == [cached])
        #expect(viewModel.favoriteIds == ["cached"])
        #expect(viewModel.catalogLoadPhase == .loading)

        await gamesClient.releaseFirstMainRequest()
        await load.value

        #expect(viewModel.mainGames == [refreshed])
        #expect(viewModel.catalogLoadPhase == .loaded)
        #expect(await persistence.savedCatalog == [refreshed])
    }

    @MainActor
    @Test("Shared cached catalog overlays only the current account ownership")
    func cachedCatalogOwnershipIsAccountScopedInMemory() async throws {
        var sharedCatalogGame = makeGame(
            id: "shared",
            title: "Shared title",
            isInLibrary: false
        )
        sharedCatalogGame.screenshots = ["https://art.invalid/shared.jpg"]
        let accountAGame = makeGame(
            id: "shared",
            title: "Account A library",
            isInLibrary: true
        )

        var accountASnapshot = AppPersistenceStore.GamesSnapshot()
        accountASnapshot.libraryGames = [accountAGame]
        accountASnapshot.vpcId = "TEST-VPC"
        let accountAClient = ScriptedGamesClient(
            mainOutcomes: [.success([sharedCatalogGame])],
            libraryOutcomes: [.success([accountAGame])],
            blockedMainRequestIndex: 0,
            blockedLibraryRequestIndex: 0
        )
        let accountAViewModel = GamesViewModel(
            gamesClient: accountAClient,
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: FakeMembershipClient(),
            persistence: FakeGamesPersistence(
                snapshot: accountASnapshot,
                cachedCatalog: [sharedCatalogGame]
            )
        )
        let accountA = await makeAuthenticatedManager(userId: "account-a")
        let accountALoad = Task { @MainActor in
            await accountAViewModel.load(authManager: accountA)
        }
        await accountAClient.waitForMainRequest(count: 1)
        await accountAClient.waitForLibraryRequest(count: 1)

        let accountACatalog = try #require(
            accountAViewModel.mainGames.first
        )
        #expect(accountACatalog.title == "Shared title")
        #expect(
            accountACatalog.screenshots
                == ["https://art.invalid/shared.jpg"]
        )
        #expect(accountACatalog.isInLibrary)
        #expect(accountACatalog.variants.first?.isOwned == true)

        await accountAClient.releaseFirstMainRequest()
        await accountAClient.releaseBlockedLibraryRequest()
        await accountALoad.value

        var accountBSnapshot = AppPersistenceStore.GamesSnapshot()
        accountBSnapshot.vpcId = "TEST-VPC"
        let accountBClient = ScriptedGamesClient(
            mainOutcomes: [.success([sharedCatalogGame])],
            libraryOutcomes: [.success([])],
            blockedMainRequestIndex: 0,
            blockedLibraryRequestIndex: 0
        )
        let accountBViewModel = GamesViewModel(
            gamesClient: accountBClient,
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: FakeMembershipClient(),
            persistence: FakeGamesPersistence(
                snapshot: accountBSnapshot,
                cachedCatalog: [sharedCatalogGame]
            )
        )
        let accountB = await makeAuthenticatedManager(userId: "account-b")
        let accountBLoad = Task { @MainActor in
            await accountBViewModel.load(authManager: accountB)
        }
        await accountBClient.waitForMainRequest(count: 1)
        await accountBClient.waitForLibraryRequest(count: 1)

        let accountBCatalog = try #require(
            accountBViewModel.mainGames.first
        )
        #expect(accountBCatalog.title == "Shared title")
        #expect(
            accountBCatalog.screenshots
                == ["https://art.invalid/shared.jpg"]
        )
        #expect(!accountBCatalog.isInLibrary)
        #expect(accountBCatalog.variants.first?.isOwned == false)

        await accountBClient.releaseFirstMainRequest()
        await accountBClient.releaseBlockedLibraryRequest()
        await accountBLoad.value
    }

    @MainActor
    @Test("Catalog, library, subscription, and sessions publish from injected clients")
    func loadsAllRemoteDatasets() async {
        let catalogGame = makeGame(
            id: "catalog",
            title: "Catalog",
            appId: "catalog-app",
            isInLibrary: false
        )
        let libraryGame = makeGame(
            id: "library",
            title: "Library",
            appId: "library-app",
            isInLibrary: true
        )
        var snapshot = AppPersistenceStore.GamesSnapshot()
        snapshot.vpcId = "TEST-VPC"
        snapshot.ownershipCacheGeneration = 42
        let persistence = FakeGamesPersistence(snapshot: snapshot)
        let subscription = SubscriptionInfo(
            membershipTier: "Ultimate",
            isUnlimited: true,
            remainingMinutes: nil,
            totalMinutes: nil,
            entitledResolutions: [
                EntitledResolution(
                    widthInPixels: 1920,
                    heightInPixels: 1080,
                    framesPerSecond: 60
                ),
            ]
        )
        let session = ActiveSessionInfo(
            sessionId: "session",
            status: 1,
            appId: "catalog-app",
            serverIp: "192.0.2.1",
            signalingUrl: nil
        )
        let viewModel = GamesViewModel(
            gamesClient: ScriptedGamesClient(
                mainOutcomes: [.success([catalogGame])],
                libraryOutcomes: [.success([libraryGame])]
            ),
            cloudMatchClient: FakeActiveSessionsClient(sessions: [session]),
            membershipClient: FakeMembershipClient(subscription: subscription),
            persistence: persistence
        )
        let authManager = await makeAuthenticatedManager()

        await viewModel.load(authManager: authManager)

        #expect(viewModel.mainGames == [catalogGame])
        #expect(viewModel.libraryGames.map(\.id) == ["library"])
        #expect(viewModel.subscription?.membershipTier == "Ultimate")
        #expect(viewModel.activeSessions.map(\.sessionId) == ["session"])
        #expect(viewModel.continuePlaying.map(\.id) == ["catalog"])
        #expect(viewModel.catalogLoadPhase == .loaded)
        #expect(viewModel.libraryLoadPhase == .loaded)
        #expect(await persistence.savedLibrary?.count == 1)
        #expect(await persistence.savedSubscription?.membershipTier == "Ultimate")
        #expect(await persistence.savedCatalogGenerations == [42])
        #expect(await persistence.savedLibraryGenerations == [42])
    }

    @MainActor
    @Test("A late response from an older load cannot replace newer state")
    func staleLoadCannotOverwriteNewerState() async {
        let stale = makeGame(id: "stale", title: "Stale")
        let current = makeGame(id: "current", title: "Current")
        var snapshot = AppPersistenceStore.GamesSnapshot()
        snapshot.vpcId = "TEST-VPC"
        let gamesClient = ScriptedGamesClient(
            mainOutcomes: [.success([stale]), .success([current])],
            libraryOutcomes: [.success([]), .success([])],
            blocksFirstMainRequest: true
        )
        let viewModel = GamesViewModel(
            gamesClient: gamesClient,
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: FakeMembershipClient(),
            persistence: FakeGamesPersistence(snapshot: snapshot)
        )
        let authManager = await makeAuthenticatedManager()

        let staleLoad = Task { @MainActor in
            await viewModel.load(authManager: authManager)
        }
        await gamesClient.waitForMainRequest(count: 1)

        let currentLoad = Task { @MainActor in
            await viewModel.load(authManager: authManager)
        }
        await gamesClient.waitForMainRequest(count: 2)
        await currentLoad.value
        #expect(viewModel.mainGames == [current])

        await gamesClient.releaseFirstMainRequest()
        await staleLoad.value

        #expect(viewModel.mainGames == [current])
        #expect(viewModel.catalogLoadPhase == .loaded)
    }

    @MainActor
    @Test("A newer credential starts a distinct active-session request and rejects the stale result")
    func activeSessionsDoNotReuseAnOlderCredential() async {
        let staleSession = ActiveSessionInfo(
            sessionId: "stale-session",
            status: 1,
            appId: nil,
            serverIp: nil,
            signalingUrl: nil
        )
        let currentSession = ActiveSessionInfo(
            sessionId: "current-session",
            status: 1,
            appId: nil,
            serverIp: nil,
            signalingUrl: nil
        )
        var snapshot = AppPersistenceStore.GamesSnapshot()
        snapshot.vpcId = "TEST-VPC"
        let sessionsClient = ScriptedActiveSessionsClient(
            outcomes: [[staleSession], [currentSession]],
            blocksFirstRequest: true
        )
        let viewModel = GamesViewModel(
            gamesClient: ScriptedGamesClient(
                mainOutcomes: [.success([]), .success([])],
                libraryOutcomes: [.success([]), .success([])]
            ),
            cloudMatchClient: sessionsClient,
            membershipClient: FakeMembershipClient(),
            persistence: FakeGamesPersistence(snapshot: snapshot)
        )
        let staleAuth = await makeAuthenticatedManager(accessToken: "stale-token")
        let currentAuth = await makeAuthenticatedManager(accessToken: "current-token")

        let staleLoad = Task { @MainActor in
            await viewModel.load(authManager: staleAuth)
        }
        await sessionsClient.waitForRequest(count: 1)

        let currentLoad = Task { @MainActor in
            await viewModel.load(authManager: currentAuth)
        }
        await sessionsClient.waitForRequest(count: 2)
        await currentLoad.value

        #expect(viewModel.activeSessions.map(\.sessionId) == ["current-session"])
        #expect(await sessionsClient.requestedTokens == ["stale-token", "current-token"])

        await sessionsClient.releaseFirstRequest()
        await staleLoad.value

        #expect(viewModel.activeSessions.map(\.sessionId) == ["current-session"])
    }

    @MainActor
    @Test("A newer credential starts a distinct VPC request and rejects the stale result")
    func vpcResolutionDoesNotReuseAnOlderCredential() async {
        let currentGame = makeGame(id: "current", title: "Current")
        let staleGame = makeGame(id: "stale", title: "Stale")
        let membership = ScriptedMembershipClient(
            vpcIds: ["stale-vpc", "current-vpc"],
            blocksFirstRequest: true
        )
        let gamesClient = ScriptedGamesClient(
            mainOutcomes: [.success([currentGame]), .success([staleGame])],
            libraryOutcomes: [.success([]), .success([])]
        )
        let viewModel = GamesViewModel(
            gamesClient: gamesClient,
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: membership,
            persistence: FakeGamesPersistence()
        )
        let staleAuth = await makeAuthenticatedManager(accessToken: "stale-token")
        let currentAuth = await makeAuthenticatedManager(accessToken: "current-token")

        let staleLoad = Task { @MainActor in
            await viewModel.load(authManager: staleAuth)
        }
        await membership.waitForVpcRequest(count: 1)

        let currentLoad = Task { @MainActor in
            await viewModel.load(authManager: currentAuth)
        }
        await membership.waitForVpcRequest(count: 2)
        await currentLoad.value

        #expect(viewModel.currentVpcId == "current-vpc")
        #expect(viewModel.mainGames == [currentGame])
        #expect(await membership.requestedTokens == ["stale-token", "current-token"])

        await membership.releaseFirstVpcRequest()
        await staleLoad.value

        #expect(viewModel.currentVpcId == "current-vpc")
        #expect(viewModel.mainGames == [currentGame])
    }

    @MainActor
    @Test("A failed load exposes errors and a later load recovers")
    func errorStateRecovers() async {
        let recovered = makeGame(id: "recovered", title: "Recovered")
        var snapshot = AppPersistenceStore.GamesSnapshot()
        snapshot.vpcId = "TEST-VPC"
        let gamesClient = ScriptedGamesClient(
            mainOutcomes: [.failure, .success([recovered])],
            libraryOutcomes: [.failure, .success([])]
        )
        let viewModel = GamesViewModel(
            gamesClient: gamesClient,
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: FakeMembershipClient(),
            persistence: FakeGamesPersistence(snapshot: snapshot)
        )
        let authManager = await makeAuthenticatedManager()

        await viewModel.load(authManager: authManager)

        if case .failed = viewModel.catalogLoadPhase {
            // Expected.
        } else {
            Issue.record("Expected the first catalog load to fail")
        }
        if case .failed = viewModel.libraryLoadPhase {
            // Expected.
        } else {
            Issue.record("Expected the first library load to fail")
        }

        await viewModel.load(authManager: authManager)

        #expect(viewModel.mainGames == [recovered])
        #expect(viewModel.catalogLoadPhase == .loaded)
        #expect(viewModel.libraryLoadPhase == .loaded)
        #expect(viewModel.error == nil)
        #expect(viewModel.libraryError == nil)
    }

    @MainActor
    @Test("Favorite, settings, and bounded recent history mutations persist")
    func mutationsPersist() async {
        let games = (0 ..< 12).map {
            makeGame(id: "game-\($0)", title: "Game \($0)")
        }
        let persistence = FakeGamesPersistence()
        let viewModel = GamesViewModel(
            mainGames: games,
            persistenceEnabled: true,
            gamesClient: ScriptedGamesClient(),
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: FakeMembershipClient(),
            persistence: persistence
        )

        viewModel.toggleFavorite("game-1")
        viewModel.streamSettings.maxBitrateKbps = 35000
        viewModel.saveSettings()
        for game in games {
            viewModel.recordPlayed(game)
        }

        await persistence.waitForMutationState(
            favorites: ["game-1"],
            bitrate: 35000,
            recentCount: 10
        )
        #expect(viewModel.favoriteIds == ["game-1"])
        #expect(viewModel.recentlyPlayedIds.count == 10)
        #expect(viewModel.recentlyPlayedIds.first == "game-11")
        #expect(viewModel.recentlyPlayedIds.last == "game-2")
    }

    @MainActor
    @Test("Full refresh treats the fresh library as authoritative")
    func fullRefreshDoesNotResurrectCatalogOwnership() async {
        let previous = makeGame(
            id: "previous",
            title: "Previous",
            isInLibrary: true
        )
        let fresh = makeGame(
            id: "fresh",
            title: "Fresh",
            isInLibrary: true
        )
        let staleCatalogOnly = makeGame(
            id: "catalog-only",
            title: "Catalog Only",
            isInLibrary: true
        )
        var snapshot = AppPersistenceStore.GamesSnapshot()
        snapshot.vpcId = "TEST-VPC"
        let persistence = FakeGamesPersistence(snapshot: snapshot)
        let syncClient = EmptyLibrarySyncClient()
        let viewModel = GamesViewModel(
            gamesClient: ScriptedGamesClient(
                mainOutcomes: [
                    .success([previous]),
                    .success([previous, staleCatalogOnly]),
                ],
                libraryOutcomes: [
                    .success([previous]),
                    .success([fresh]),
                ]
            ),
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: FakeMembershipClient(),
            persistence: persistence,
            librarySyncClient: syncClient,
            providerLibrarySyncEnabled: true
        )
        let authManager = await makeAuthenticatedManager()
        await viewModel.load(authManager: authManager)

        viewModel.startFullLibraryRefresh(authManager: authManager)
        #expect(await waitForLibraryRefresh(viewModel))

        #expect(viewModel.libraryRefreshState.stage == .completed)
        #expect(viewModel.libraryGames.map(\.id) == ["fresh"])
        #expect(await persistence.savedLibrary?.map(\.id) == ["fresh"])
        #expect(
            viewModel.libraryRefreshState.summary?.addedGameIDs == ["fresh"]
        )
        #expect(
            viewModel.libraryRefreshState.summary?.removedGameIDs
                == ["previous"]
        )
        #expect(
            await persistence.savedLibraryAccountScopes.last
                == nvidiaAccountScope(for: "fixture-user")
        )
    }

    @MainActor
    @Test("Final library failure preserves the prior memory and disk snapshot")
    func fullRefreshFailurePreservesPreviousLibrary() async {
        let previous = makeGame(
            id: "previous",
            title: "Previous",
            isInLibrary: true
        )
        let changedCatalog = makeGame(
            id: "changed",
            title: "Changed",
            isInLibrary: true
        )
        var snapshot = AppPersistenceStore.GamesSnapshot()
        snapshot.vpcId = "TEST-VPC"
        let persistence = FakeGamesPersistence(snapshot: snapshot)
        let viewModel = GamesViewModel(
            gamesClient: ScriptedGamesClient(
                mainOutcomes: [
                    .success([previous]),
                    .success([changedCatalog]),
                ],
                libraryOutcomes: [
                    .success([previous]),
                    .failure,
                ]
            ),
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: FakeMembershipClient(),
            persistence: persistence,
            librarySyncClient: EmptyLibrarySyncClient(),
            providerLibrarySyncEnabled: true
        )
        let authManager = await makeAuthenticatedManager()
        await viewModel.load(authManager: authManager)

        viewModel.startFullLibraryRefresh(authManager: authManager)
        #expect(await waitForLibraryRefresh(viewModel))

        #expect(viewModel.libraryRefreshState.stage == .failed)
        #expect(viewModel.libraryGames == [previous])
        #expect(await persistence.savedLibrary == [previous])
        #expect(await persistence.savedCatalog == [previous])
    }

    @MainActor
    @Test("Final import refreshes a rejected credential once")
    func fullRefreshRetriesUnauthorizedSnapshot() async {
        let previous = makeGame(
            id: "previous",
            title: "Previous",
            isInLibrary: true
        )
        let fresh = makeGame(
            id: "fresh",
            title: "Fresh",
            isInLibrary: true
        )
        var snapshot = AppPersistenceStore.GamesSnapshot()
        snapshot.vpcId = "TEST-VPC"
        let persistence = FakeGamesPersistence(snapshot: snapshot)
        let gamesClient = ScriptedGamesClient(
            mainOutcomes: [
                .success([previous]),
                .success([fresh]),
                .success([fresh]),
            ],
            libraryOutcomes: [
                .success([previous]),
                .unauthorized,
                .success([fresh]),
            ]
        )
        let authAPI = RotatingGamesAuthAPI()
        let viewModel = GamesViewModel(
            gamesClient: gamesClient,
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: FakeMembershipClient(),
            persistence: persistence,
            librarySyncClient: EmptyLibrarySyncClient(),
            providerLibrarySyncEnabled: true
        )
        let authManager = await makeAuthenticatedManager(api: authAPI)
        await viewModel.load(authManager: authManager)

        viewModel.startFullLibraryRefresh(authManager: authManager)
        #expect(await waitForLibraryRefresh(viewModel))

        #expect(viewModel.libraryRefreshState.stage == .completed)
        #expect(viewModel.libraryGames == [fresh])
        #expect(await authAPI.refreshCount == 1)
        #expect(await gamesClient.libraryCallCount == 3)
        #expect(await gamesClient.mainCallCount == 3)
        #expect(await gamesClient.requestedLibraryTokens.last == "rotated-token")
        #expect(await gamesClient.requestedMainTokens.last == "rotated-token")
        #expect(await persistence.savedLibrary == [fresh])
    }

    @MainActor
    @Test("A failed atomic commit does not publish the fetched snapshot")
    func fullRefreshCommitFailurePreservesPreviousLibrary() async {
        let previous = makeGame(
            id: "previous",
            title: "Previous",
            isInLibrary: true
        )
        let fresh = makeGame(
            id: "fresh",
            title: "Fresh",
            isInLibrary: true
        )
        var snapshot = AppPersistenceStore.GamesSnapshot()
        snapshot.vpcId = "TEST-VPC"
        let persistence = FakeGamesPersistence(
            snapshot: snapshot,
            failsRefreshedSnapshotSave: true
        )
        let viewModel = GamesViewModel(
            gamesClient: ScriptedGamesClient(
                mainOutcomes: [
                    .success([previous]),
                    .success([fresh]),
                ],
                libraryOutcomes: [
                    .success([previous]),
                    .success([fresh]),
                ]
            ),
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: FakeMembershipClient(),
            persistence: persistence,
            librarySyncClient: EmptyLibrarySyncClient(),
            providerLibrarySyncEnabled: true
        )
        let authManager = await makeAuthenticatedManager()
        await viewModel.load(authManager: authManager)

        viewModel.startFullLibraryRefresh(authManager: authManager)
        #expect(await waitForLibraryRefresh(viewModel))

        #expect(viewModel.libraryRefreshState.stage == .failed)
        #expect(viewModel.libraryGames == [previous])
        #expect(await persistence.savedLibrary == [previous])
        #expect(await persistence.savedCatalog == [previous])
    }

    @MainActor
    @Test("Disabled provider sync gate prevents provider discovery")
    func disabledProviderSyncGateDoesNotStart() async {
        var snapshot = AppPersistenceStore.GamesSnapshot()
        snapshot.vpcId = "TEST-VPC"
        let syncClient = EmptyLibrarySyncClient()
        let viewModel = GamesViewModel(
            gamesClient: ScriptedGamesClient(),
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: FakeMembershipClient(),
            persistence: FakeGamesPersistence(snapshot: snapshot),
            librarySyncClient: syncClient,
            providerLibrarySyncEnabled: false
        )
        let authManager = await makeAuthenticatedManager()
        await viewModel.load(authManager: authManager)

        viewModel.startFullLibraryRefresh(authManager: authManager)
        await Task.yield()

        #expect(viewModel.libraryRefreshState.stage == .idle)
        #expect(await syncClient.discoveryCount == 0)
    }

    @Test("Provider library synchronization is enabled in app builds")
    func providerLibrarySyncFeatureIsEnabled() {
        #expect(FeatureFlags.providerLibrarySyncEnabled)
    }

    @MainActor
    @Test("An unseen completed refresh reopens until Done is acknowledged")
    func completedRefreshIsNotRestartedBeforeAcknowledgement() async {
        let initialState = FullLibraryRefreshState(
            stage: .completed,
            finalPhase: .succeeded(gameCount: 2),
            summary: LibraryRefreshSummary(
                successfulProviderCount: 0,
                failedProviderCount: 0,
                skippedProviderCount: 0,
                finalGameCount: 2,
                addedGameIDs: [],
                removedGameIDs: []
            )
        )
        let syncClient = EmptyLibrarySyncClient()
        let viewModel = GamesViewModel(
            persistenceEnabled: false,
            librarySyncClient: syncClient,
            providerLibrarySyncEnabled: true,
            initialLibraryRefreshState: initialState,
            libraryRefreshImporterOverride: {
                LibraryImportResult(
                    finalGameCount: 3,
                    addedGameIDs: ["new"],
                    removedGameIDs: []
                )
            }
        )
        let authManager = await makeAuthenticatedManager()

        viewModel.startFullLibraryRefresh(authManager: authManager)
        await Task.yield()

        #expect(viewModel.libraryRefreshState == initialState)
        #expect(await syncClient.discoveryCount == 0)

        viewModel.acknowledgeLibraryRefresh()
        #expect(viewModel.libraryRefreshState.stage == .idle)

        viewModel.startFullLibraryRefresh(authManager: authManager)
        #expect(await waitForLibraryRefresh(viewModel))
        #expect(await syncClient.discoveryCount == 1)
        #expect(viewModel.libraryRefreshState.summary?.finalGameCount == 3)
    }

    @MainActor
    @Test("Retry Failed retries a failed final import without provider failures")
    func failedFinalImportCanBeRetried() async {
        let syncClient = EmptyLibrarySyncClient()
        let viewModel = GamesViewModel(
            persistenceEnabled: false,
            librarySyncClient: syncClient,
            providerLibrarySyncEnabled: true,
            initialLibraryRefreshState: FullLibraryRefreshState(
                stage: .failed,
                providers: [
                    ProviderSyncProgress(
                        providerCode: "STEAM",
                        displayName: "Steam",
                        accountName: nil,
                        phase: .succeeded(gameCount: 20)
                    ),
                ],
                finalPhase: .failed(message: "Fixture failure")
            ),
            libraryRefreshImporterOverride: {
                LibraryImportResult(
                    finalGameCount: 20,
                    addedGameIDs: [],
                    removedGameIDs: []
                )
            }
        )
        let authManager = await makeAuthenticatedManager()

        viewModel.retryFailedLibraryProviders(authManager: authManager)
        #expect(await waitForLibraryRefresh(viewModel))

        #expect(await syncClient.discoveryCount == 1)
        #expect(viewModel.libraryRefreshState.stage == .completed)
        #expect(viewModel.libraryRefreshState.finalPhase == .succeeded(gameCount: 20))
    }

    @MainActor
    @Test("Full refresh persists the VPC used for its network snapshot")
    func fullRefreshSnapshotKeepsItsCapturedVpcId() async {
        let initial = makeGame(
            id: "initial",
            title: "Initial",
            isInLibrary: true
        )
        let fresh = makeGame(
            id: "fresh",
            title: "Fresh",
            isInLibrary: true
        )
        var snapshot = AppPersistenceStore.GamesSnapshot()
        snapshot.vpcId = "OLD-VPC"
        let persistence = FakeGamesPersistence(snapshot: snapshot)
        let membership = ScriptedMembershipClient(
            vpcIds: ["NEW-VPC"],
            blocksFirstRequest: true
        )
        let gamesClient = ScriptedGamesClient(
            mainOutcomes: [
                .success([initial]),
                .success([fresh]),
                .success([initial]),
            ],
            libraryOutcomes: [
                .success([initial]),
                .success([fresh]),
                .success([initial]),
            ],
            blockedLibraryRequestIndex: 1
        )
        let viewModel = GamesViewModel(
            gamesClient: gamesClient,
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: membership,
            persistence: persistence,
            librarySyncClient: EmptyLibrarySyncClient(),
            providerLibrarySyncEnabled: true
        )
        let authManager = await makeAuthenticatedManager()
        await viewModel.load(authManager: authManager)
        await membership.waitForVpcRequest(count: 1)

        viewModel.startFullLibraryRefresh(authManager: authManager)
        await gamesClient.waitForLibraryRequest(count: 2)

        await viewModel.load(authManager: authManager)
        await membership.releaseFirstVpcRequest()
        for _ in 0 ..< 1000 where viewModel.currentVpcId != "NEW-VPC" {
            await Task.yield()
        }
        #expect(viewModel.currentVpcId == "NEW-VPC")

        await gamesClient.releaseBlockedLibraryRequest()
        #expect(await waitForLibraryRefresh(viewModel))

        #expect(await persistence.refreshedSnapshotVpcIds == ["OLD-VPC"])
    }

    @MainActor
    @Test("Full refresh normalizes VPC fallback and captures locale before fetching")
    func fullRefreshPersistsExactNetworkIdentity() async {
        let initial = makeGame(
            id: "initial",
            title: "Initial",
            isInLibrary: true
        )
        let fresh = makeGame(
            id: "fresh",
            title: "Fresh",
            isInLibrary: true
        )
        let locale = MutableLocaleCode("initial-locale")
        let persistence = FakeGamesPersistence()
        let membership = ScriptedMembershipClient(
            vpcIds: [nil],
            blocksFirstRequest: false
        )
        let gamesClient = ScriptedGamesClient(
            mainOutcomes: [
                .success([initial]),
                .success([fresh]),
            ],
            libraryOutcomes: [
                .success([initial]),
                .success([fresh]),
            ],
            blockedLibraryRequestIndex: 1
        )
        let viewModel = GamesViewModel(
            gamesClient: gamesClient,
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: membership,
            persistence: persistence,
            librarySyncClient: EmptyLibrarySyncClient(),
            providerLibrarySyncEnabled: true,
            localeCodeProvider: { locale.value }
        )
        let authManager = await makeAuthenticatedManager()
        await viewModel.load(authManager: authManager)
        #expect(viewModel.currentVpcId == nil)

        locale.value = "captured-locale"
        viewModel.startFullLibraryRefresh(authManager: authManager)
        await gamesClient.waitForLibraryRequest(count: 2)
        #expect(viewModel.libraryLoadPhase == .loading)
        #expect(viewModel.isFullLibraryRefreshRunning)
        #expect(viewModel.canPresentFullLibraryRefresh)
        locale.value = "late-locale"
        await gamesClient.releaseBlockedLibraryRequest()
        #expect(await waitForLibraryRefresh(viewModel))

        #expect(await persistence.refreshedSnapshotVpcIds == ["GFN-PC"])
        #expect(
            await persistence.refreshedSnapshotLocaleCodes
                == ["captured-locale"]
        )
        #expect(await persistence.refreshedSnapshotGenerations == [0])
        #expect(await gamesClient.libraryCallCount == 2)
        #expect(await gamesClient.mainCallCount == 2)
        #expect(
            await gamesClient.requestedLibraryVpcIds
                == ["GFN-PC", "GFN-PC"]
        )
        #expect(
            await gamesClient.requestedMainVpcIds
                == ["GFN-PC", "GFN-PC"]
        )
        #expect(await membership.requestedTokens.count == 1)
    }

    @MainActor
    @Test("Changing accounts clears prior ownership before the new response")
    func accountChangeClearsVisibleOwnership() async {
        let accountAGame = makeGame(
            id: "account-a",
            title: "Account A",
            isInLibrary: true
        )
        let accountBGame = makeGame(
            id: "account-b",
            title: "Account B",
            isInLibrary: false
        )
        var snapshot = AppPersistenceStore.GamesSnapshot()
        snapshot.vpcId = "TEST-VPC"
        let persistence = FakeGamesPersistence(snapshot: snapshot)
        let gamesClient = ScriptedGamesClient(
            mainOutcomes: [
                .success([accountAGame]),
                .success([accountBGame]),
            ],
            libraryOutcomes: [
                .success([accountAGame]),
                .success([]),
            ],
            blockedMainRequestIndex: 1
        )
        let viewModel = GamesViewModel(
            gamesClient: gamesClient,
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: FakeMembershipClient(),
            persistence: persistence
        )
        let accountA = await makeAuthenticatedManager(userId: "account-a")
        let accountB = await makeAuthenticatedManager(userId: "account-b")
        await viewModel.load(authManager: accountA)
        #expect(viewModel.libraryGames == [accountAGame])

        let accountBLoad = Task { @MainActor in
            await viewModel.load(authManager: accountB)
        }
        await gamesClient.waitForMainRequest(count: 2)

        #expect(!viewModel.mainGames.contains(accountAGame))
        #expect(!viewModel.libraryGames.contains(accountAGame))

        await gamesClient.releaseFirstMainRequest()
        await accountBLoad.value
        #expect(viewModel.mainGames == [accountBGame])
        #expect(
            await persistence.loadedAccountScopes
                == [
                    nvidiaAccountScope(for: "account-a"),
                    nvidiaAccountScope(for: "account-b"),
                ]
        )
    }

    @MainActor
    @Test("Full refresh waits for an active lightweight library reload")
    func fullRefreshWaitsForLightweightReload() async {
        let initial = makeGame(
            id: "initial",
            title: "Initial",
            isInLibrary: true
        )
        let stale = makeGame(
            id: "stale",
            title: "Stale",
            isInLibrary: true
        )
        let fresh = makeGame(
            id: "fresh",
            title: "Fresh",
            isInLibrary: true
        )
        var snapshot = AppPersistenceStore.GamesSnapshot()
        snapshot.vpcId = "TEST-VPC"
        let gamesClient = ScriptedGamesClient(
            mainOutcomes: [
                .success([initial]),
                .success([fresh]),
            ],
            libraryOutcomes: [
                .success([initial]),
                .success([stale]),
                .success([fresh]),
            ],
            blockedLibraryRequestIndex: 1
        )
        let syncClient = EmptyLibrarySyncClient()
        let viewModel = GamesViewModel(
            gamesClient: gamesClient,
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: FakeMembershipClient(),
            persistence: FakeGamesPersistence(snapshot: snapshot),
            librarySyncClient: syncClient,
            providerLibrarySyncEnabled: true
        )
        let authManager = await makeAuthenticatedManager()
        await viewModel.load(authManager: authManager)

        let lightweightReload = Task { @MainActor in
            await viewModel.refreshLibrary(authManager: authManager)
        }
        await gamesClient.waitForLibraryRequest(count: 2)

        #expect(!viewModel.canStartFullLibraryRefresh)
        viewModel.startFullLibraryRefresh(authManager: authManager)
        await Task.yield()
        #expect(viewModel.libraryRefreshState.stage == .idle)
        #expect(await syncClient.discoveryCount == 0)
        #expect(await gamesClient.libraryCallCount == 2)
        #expect(await gamesClient.mainCallCount == 1)

        await gamesClient.releaseBlockedLibraryRequest()
        await lightweightReload.value
        #expect(viewModel.libraryGames == [stale])
        #expect(viewModel.canStartFullLibraryRefresh)

        viewModel.startFullLibraryRefresh(authManager: authManager)
        #expect(await waitForLibraryRefresh(viewModel))
        #expect(viewModel.libraryGames == [fresh])
        #expect(await syncClient.discoveryCount == 1)
        #expect(await gamesClient.libraryCallCount == 3)
        #expect(await gamesClient.mainCallCount == 2)
    }

    @MainActor
    @Test("Full refresh waits for an active foreground catalog reload")
    func fullRefreshWaitsForCatalogReload() async {
        let initial = makeGame(
            id: "initial",
            title: "Initial",
            isInLibrary: true
        )
        let foregroundCatalog = makeGame(
            id: "foreground",
            title: "Foreground"
        )
        let foregroundLibrary = makeGame(
            id: "foreground",
            title: "Foreground",
            isInLibrary: true
        )
        let fresh = makeGame(
            id: "fresh",
            title: "Fresh",
            isInLibrary: true
        )
        var snapshot = AppPersistenceStore.GamesSnapshot()
        snapshot.vpcId = "TEST-VPC"
        let gamesClient = ScriptedGamesClient(
            mainOutcomes: [
                .success([initial]),
                .success([foregroundCatalog]),
                .success([fresh]),
            ],
            libraryOutcomes: [
                .success([initial]),
                .success([foregroundLibrary]),
                .success([fresh]),
            ],
            blockedMainRequestIndex: 1
        )
        let syncClient = EmptyLibrarySyncClient()
        let viewModel = GamesViewModel(
            gamesClient: gamesClient,
            cloudMatchClient: FakeActiveSessionsClient(),
            membershipClient: FakeMembershipClient(),
            persistence: FakeGamesPersistence(snapshot: snapshot),
            librarySyncClient: syncClient,
            providerLibrarySyncEnabled: true
        )
        let authManager = await makeAuthenticatedManager()
        await viewModel.load(authManager: authManager)

        let foregroundReload = Task { @MainActor in
            await viewModel.load(authManager: authManager)
        }
        await gamesClient.waitForMainRequest(count: 2)
        await gamesClient.waitForLibraryRequest(count: 2)

        #expect(viewModel.libraryLoadPhase == .loaded)
        #expect(viewModel.catalogLoadPhase == .loading)
        #expect(!viewModel.canStartFullLibraryRefresh)
        viewModel.startFullLibraryRefresh(authManager: authManager)
        await Task.yield()
        #expect(viewModel.libraryRefreshState.stage == .idle)
        #expect(await syncClient.discoveryCount == 0)
        #expect(await gamesClient.libraryCallCount == 2)
        #expect(await gamesClient.mainCallCount == 2)

        await gamesClient.releaseFirstMainRequest()
        await foregroundReload.value
        #expect(viewModel.canStartFullLibraryRefresh)

        viewModel.startFullLibraryRefresh(authManager: authManager)
        #expect(await waitForLibraryRefresh(viewModel))
        #expect(viewModel.libraryGames == [fresh])
        #expect(await syncClient.discoveryCount == 1)
        #expect(await gamesClient.libraryCallCount == 3)
        #expect(await gamesClient.mainCallCount == 3)
    }

    @MainActor
    private func waitForLibraryRefresh(
        _ viewModel: GamesViewModel
    ) async -> Bool {
        for _ in 0 ..< 10000 {
            if !viewModel.libraryRefreshState.isRunning,
               viewModel.libraryRefreshState.stage != .idle
            {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @MainActor
    private func makeAuthenticatedManager(
        accessToken: String = "fixture-access-token",
        userId: String = "fixture-user",
        api: any NVIDIAAuthAPIClient = UnavailableAuthAPI()
    ) async -> AuthManager {
        let session = AuthSession(
            provider: LoginProvider(
                idpId: "fixture",
                code: "NVIDIA",
                displayName: "Fixture",
                streamingServiceUrl: "https://stream.invalid/",
                priority: 0
            ),
            tokens: AuthTokens(
                accessToken: accessToken,
                refreshToken: "fixture-refresh-token",
                idToken: nil,
                expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
                clientToken: nil,
                clientTokenExpiresAt: nil
            ),
            user: AuthUser(
                userId: userId,
                displayName: "Fixture User",
                email: nil,
                avatarUrl: nil,
                membershipTier: "FREE"
            )
        )
        let manager = AuthManager(
            api: api,
            persistence: StaticAuthPersistence(session: session),
            backgroundScheduler: .disabled,
            schedulesAutomaticRefresh: false
        )
        await manager.initialize()
        return manager
    }

    private func makeGame(
        id: String,
        title: String,
        appId: String? = nil,
        isInLibrary: Bool = false
    ) -> GameInfo {
        var game = TestGameFactory.make(
            id: id,
            title: title,
            stores: [("STEAM", isInLibrary)],
            isInLibrary: isInLibrary
        )
        game.variants[0].appId = appId
        return game
    }
}

private enum ScriptedGamesOutcome: Sendable {
    case success([GameInfo])
    case failure
    case unauthorized
}

private enum GamesViewModelTestError: Error {
    case unavailable
}

@MainActor
private final class MutableLocaleCode {
    var value: String

    init(_ value: String) {
        self.value = value
    }
}

private actor EmptyLibrarySyncClient: LibrarySyncClient {
    private(set) var discoveryCount = 0

    func discover(
        token _: String,
        userId _: String
    ) -> [ConnectedGameLibrary] {
        discoveryCount += 1
        return []
    }

    func requestSync(providerCode _: String, token _: String) {}

    func fetchSnapshots(
        token _: String,
        userId _: String
    ) -> [ProviderSyncSnapshot] {
        []
    }
}

private actor ScriptedGamesClient: GamesCatalogClient {
    private let mainOutcomes: [ScriptedGamesOutcome]
    private let libraryOutcomes: [ScriptedGamesOutcome]
    private let blockedMainRequestIndex: Int?
    private let blockedLibraryRequestIndex: Int?
    private var firstMainContinuation: CheckedContinuation<Void, Never>?
    private var libraryContinuation: CheckedContinuation<Void, Never>?
    private var mainIndex = 0
    private var libraryIndex = 0
    private(set) var mainCallCount = 0
    private(set) var libraryCallCount = 0
    private(set) var requestedMainTokens: [String] = []
    private(set) var requestedLibraryTokens: [String] = []
    private(set) var requestedMainVpcIds: [String?] = []
    private(set) var requestedLibraryVpcIds: [String?] = []
    private var mainRequestWaiters: [MainRequestWaiter] = []
    private var libraryRequestWaiters: [MainRequestWaiter] = []

    private struct MainRequestWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    init(
        mainOutcomes: [ScriptedGamesOutcome] = [.success([])],
        libraryOutcomes: [ScriptedGamesOutcome] = [.success([])],
        blocksFirstMainRequest: Bool = false,
        blockedMainRequestIndex: Int? = nil,
        blockedLibraryRequestIndex: Int? = nil
    ) {
        self.mainOutcomes = mainOutcomes
        self.libraryOutcomes = libraryOutcomes
        self.blockedMainRequestIndex = blockedMainRequestIndex
            ?? (blocksFirstMainRequest ? 0 : nil)
        self.blockedLibraryRequestIndex = blockedLibraryRequestIndex
    }

    func fetchMainGames(
        token: String,
        streamingBaseUrl _: String,
        vpcId: String?
    ) async throws -> [GameInfo] {
        let index = mainIndex
        mainIndex += 1
        mainCallCount += 1
        requestedMainTokens.append(token)
        requestedMainVpcIds.append(vpcId)
        resumeMainRequestWaiters()
        if index == blockedMainRequestIndex {
            await withCheckedContinuation { continuation in
                firstMainContinuation = continuation
            }
        }
        return try value(
            from: mainOutcomes[min(index, mainOutcomes.count - 1)]
        )
    }

    func fetchLibrary(
        token: String,
        streamingBaseUrl _: String,
        vpcId: String?
    ) async throws -> [GameInfo] {
        let index = libraryIndex
        libraryIndex += 1
        libraryCallCount += 1
        requestedLibraryTokens.append(token)
        requestedLibraryVpcIds.append(vpcId)
        resumeLibraryRequestWaiters()
        if index == blockedLibraryRequestIndex {
            await withCheckedContinuation { continuation in
                libraryContinuation = continuation
            }
        }
        return try value(
            from: libraryOutcomes[min(index, libraryOutcomes.count - 1)]
        )
    }

    func waitForMainRequest(count: Int) async {
        guard mainCallCount < count else { return }
        await withCheckedContinuation { continuation in
            mainRequestWaiters.append(
                MainRequestWaiter(
                    count: count,
                    continuation: continuation
                )
            )
        }
    }

    func releaseFirstMainRequest() {
        firstMainContinuation?.resume()
        firstMainContinuation = nil
    }

    func waitForLibraryRequest(count: Int) async {
        guard libraryCallCount < count else { return }
        await withCheckedContinuation { continuation in
            libraryRequestWaiters.append(
                MainRequestWaiter(
                    count: count,
                    continuation: continuation
                )
            )
        }
    }

    func releaseBlockedLibraryRequest() {
        libraryContinuation?.resume()
        libraryContinuation = nil
    }

    private func resumeMainRequestWaiters() {
        var remaining: [MainRequestWaiter] = []
        for waiter in mainRequestWaiters {
            if mainCallCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        mainRequestWaiters = remaining
    }

    private func resumeLibraryRequestWaiters() {
        var remaining: [MainRequestWaiter] = []
        for waiter in libraryRequestWaiters {
            if libraryCallCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        libraryRequestWaiters = remaining
    }

    private func value(from outcome: ScriptedGamesOutcome) throws -> [GameInfo] {
        switch outcome {
        case let .success(games):
            games
        case .failure:
            throw GamesViewModelTestError.unavailable
        case .unauthorized:
            throw GamesError.unauthorized
        }
    }
}

private actor ScriptedActiveSessionsClient: ActiveSessionsClient {
    private let outcomes: [[ActiveSessionInfo]]
    private let blocksFirstRequest: Bool
    private var requestIndex = 0
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?
    private var requestWaiters: [RequestWaiter] = []
    private(set) var requestedTokens: [String] = []

    private struct RequestWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    init(
        outcomes: [[ActiveSessionInfo]],
        blocksFirstRequest: Bool
    ) {
        self.outcomes = outcomes
        self.blocksFirstRequest = blocksFirstRequest
    }

    func getActiveSessions(
        token: String,
        base _: String
    ) async -> [ActiveSessionInfo] {
        let index = requestIndex
        requestIndex += 1
        requestedTokens.append(token)
        resumeRequestWaiters()
        if blocksFirstRequest, index == 0 {
            await withCheckedContinuation { continuation in
                firstRequestContinuation = continuation
            }
        }
        guard outcomes.indices.contains(index) else { return [] }
        return outcomes[index]
    }

    func waitForRequest(count: Int) async {
        guard requestedTokens.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(
                RequestWaiter(
                    count: count,
                    continuation: continuation
                )
            )
        }
    }

    func releaseFirstRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }

    private func resumeRequestWaiters() {
        var remaining: [RequestWaiter] = []
        for waiter in requestWaiters {
            if requestedTokens.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        requestWaiters = remaining
    }
}

private actor ScriptedMembershipClient: MembershipClient {
    private let vpcIds: [String?]
    private let blocksFirstRequest: Bool
    private var requestIndex = 0
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?
    private var requestWaiters: [RequestWaiter] = []
    private(set) var requestedTokens: [String] = []

    private struct RequestWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    init(
        vpcIds: [String?],
        blocksFirstRequest: Bool
    ) {
        self.vpcIds = vpcIds
        self.blocksFirstRequest = blocksFirstRequest
    }

    func fetchVpcId(token: String, base _: String) async -> String? {
        let index = requestIndex
        requestIndex += 1
        requestedTokens.append(token)
        resumeRequestWaiters()
        if blocksFirstRequest, index == 0 {
            await withCheckedContinuation { continuation in
                firstRequestContinuation = continuation
            }
        }
        guard vpcIds.indices.contains(index) else { return nil }
        return vpcIds[index]
    }

    func fetchSubscription(
        token _: String,
        vpcId _: String,
        userId _: String
    ) throws -> SubscriptionInfo {
        throw GamesViewModelTestError.unavailable
    }

    func waitForVpcRequest(count: Int) async {
        guard requestedTokens.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(
                RequestWaiter(
                    count: count,
                    continuation: continuation
                )
            )
        }
    }

    func releaseFirstVpcRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }

    private func resumeRequestWaiters() {
        var remaining: [RequestWaiter] = []
        for waiter in requestWaiters {
            if requestedTokens.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        requestWaiters = remaining
    }
}

private actor FakeMembershipClient: MembershipClient {
    private let subscription: SubscriptionInfo?

    init(subscription: SubscriptionInfo? = nil) {
        self.subscription = subscription
    }

    func fetchVpcId(token _: String, base _: String) -> String? {
        "TEST-VPC"
    }

    func fetchSubscription(
        token _: String,
        vpcId _: String,
        userId _: String
    ) throws -> SubscriptionInfo {
        guard let subscription else {
            throw GamesViewModelTestError.unavailable
        }
        return subscription
    }
}

private actor FakeActiveSessionsClient: ActiveSessionsClient {
    private let sessions: [ActiveSessionInfo]

    init(sessions: [ActiveSessionInfo] = []) {
        self.sessions = sessions
    }

    func getActiveSessions(
        token _: String,
        base _: String
    ) -> [ActiveSessionInfo] {
        sessions
    }
}

private actor FakeGamesPersistence: GamesPersistence {
    private let snapshot: AppPersistenceStore.GamesSnapshot
    private let cachedCatalog: [GameInfo]?
    private let failsRefreshedSnapshotSave: Bool
    private(set) var savedFavorites: Set<String>?
    private(set) var savedRecent: [String]?
    private(set) var savedSettings: StreamSettings?
    private(set) var savedLibrary: [GameInfo]?
    private(set) var savedSubscription: SubscriptionInfo?
    private(set) var savedCatalog: [GameInfo]?
    private(set) var loadedAccountScopes: [String?] = []
    private(set) var savedLibraryAccountScopes: [String?] = []
    private(set) var refreshedSnapshotVpcIds: [String?] = []
    private(set) var refreshedSnapshotLocaleCodes: [String] = []
    private(set) var refreshedSnapshotGenerations: [UInt64] = []
    private(set) var savedCatalogGenerations: [UInt64] = []
    private(set) var savedLibraryGenerations: [UInt64] = []
    private var mutationWaiters: [MutationWaiter] = []

    private struct MutationWaiter {
        let favorites: Set<String>
        let bitrate: Int
        let recentCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    init(
        snapshot: AppPersistenceStore.GamesSnapshot = .init(),
        cachedCatalog: [GameInfo]? = nil,
        failsRefreshedSnapshotSave: Bool = false
    ) {
        self.snapshot = snapshot
        self.cachedCatalog = cachedCatalog
        self.failsRefreshedSnapshotSave = failsRefreshedSnapshotSave
    }

    func loadGamesSnapshot(accountScope: String?) -> AppPersistenceStore.GamesSnapshot {
        loadedAccountScopes.append(accountScope)
        return snapshot
    }

    func saveFavoriteIds(_ ids: Set<String>) {
        savedFavorites = ids
        resumeMutationWaiters()
    }

    func savePreferredStoreIds(_: [String: String]) {}

    func saveRecentlyPlayedIds(_ ids: [String]) {
        savedRecent = ids
        resumeMutationWaiters()
    }

    func saveStreamSettings(_ settings: StreamSettings) {
        savedSettings = settings
        resumeMutationWaiters()
    }

    func saveLastSession(_: LastSessionRecord?) {}

    func saveLibraryGames(
        _ games: [GameInfo],
        accountScope: String?,
        expectedGeneration: UInt64
    ) {
        savedLibrary = games
        savedLibraryAccountScopes.append(accountScope)
        savedLibraryGenerations.append(expectedGeneration)
    }

    func saveSubscription(_ subscription: SubscriptionInfo) {
        savedSubscription = subscription
    }

    func saveVpcId(_: String) {}

    func loadCatalog(
        localeCode _: String,
        vpcId _: String?,
        accountScope _: String?
    ) -> [GameInfo]? {
        cachedCatalog
    }

    func saveCatalog(
        _ games: [GameInfo],
        localeCode _: String,
        vpcId _: String?,
        accountScope _: String?,
        expectedGeneration: UInt64
    ) {
        savedCatalog = games
        savedCatalogGenerations.append(expectedGeneration)
    }

    func saveRefreshedLibrarySnapshot(
        libraryGames: [GameInfo],
        catalogGames: [GameInfo]?,
        localeCode: String,
        vpcId: String?,
        accountScope: String,
        expectedGeneration: UInt64
    ) throws {
        if failsRefreshedSnapshotSave {
            throw GamesViewModelTestError.unavailable
        }
        savedLibrary = libraryGames
        savedCatalog = catalogGames
        savedLibraryAccountScopes.append(accountScope)
        refreshedSnapshotVpcIds.append(vpcId)
        refreshedSnapshotLocaleCodes.append(localeCode)
        refreshedSnapshotGenerations.append(expectedGeneration)
    }

    func waitForMutationState(
        favorites: Set<String>,
        bitrate: Int,
        recentCount: Int
    ) async {
        guard !hasSavedMutationState(
            favorites: favorites,
            bitrate: bitrate,
            recentCount: recentCount
        ) else { return }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(
                MutationWaiter(
                    favorites: favorites,
                    bitrate: bitrate,
                    recentCount: recentCount,
                    continuation: continuation
                )
            )
        }
    }

    private func hasSavedMutationState(
        favorites: Set<String>,
        bitrate: Int,
        recentCount: Int
    ) -> Bool {
        savedFavorites == favorites
            && savedSettings?.maxBitrateKbps == bitrate
            && savedRecent?.count == recentCount
    }

    private func resumeMutationWaiters() {
        var remaining: [MutationWaiter] = []
        for waiter in mutationWaiters {
            if hasSavedMutationState(
                favorites: waiter.favorites,
                bitrate: waiter.bitrate,
                recentCount: waiter.recentCount
            ) {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        mutationWaiters = remaining
    }
}

private actor StaticAuthPersistence: AuthSessionPersistence {
    private var session: AuthSession?

    init(session: AuthSession) {
        self.session = session
    }

    func loadAuthSession() throws -> AuthSession {
        guard let session else {
            throw GamesViewModelTestError.unavailable
        }
        return session
    }

    func saveAuthSession(
        _ session: AuthSession,
        generation _: UInt64
    ) {
        self.session = session
    }

    func deleteAuthSession(generation _: UInt64) {
        session = nil
    }
}

private actor RotatingGamesAuthAPI: NVIDIAAuthAPIClient {
    private(set) var refreshCount = 0

    func fetchProviders() async throws -> [LoginProvider] {
        throw GamesViewModelTestError.unavailable
    }

    func refreshTokens(_: String) async throws -> AuthTokens {
        refreshCount += 1
        return AuthTokens(
            accessToken: "rotated-token",
            refreshToken: "rotated-refresh-token",
            idToken: nil,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_100),
            clientToken: nil,
            clientTokenExpiresAt: nil
        )
    }

    func fetchClientToken(accessToken _: String) async throws -> (
        token: String,
        expiresAt: Date
    ) {
        (
            token: "rotated-client-token",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_100)
        )
    }

    func refreshWithClientToken(
        _: String,
        userId _: String
    ) async throws -> AuthTokens {
        throw GamesViewModelTestError.unavailable
    }

    func requestDeviceAuthorization(
        idpId _: String?
    ) async throws -> DeviceFlowResponse {
        throw GamesViewModelTestError.unavailable
    }

    func pollForDeviceToken(
        deviceCode _: String,
        interval _: Int,
        expiresIn _: Int
    ) async throws -> AuthTokens {
        throw GamesViewModelTestError.unavailable
    }

    func fetchUserInfo(tokens _: AuthTokens) async throws -> AuthUser {
        throw GamesViewModelTestError.unavailable
    }
}

private struct UnavailableAuthAPI: NVIDIAAuthAPIClient {
    func fetchProviders() async throws -> [LoginProvider] {
        throw GamesViewModelTestError.unavailable
    }

    func refreshTokens(_: String) async throws -> AuthTokens {
        throw GamesViewModelTestError.unavailable
    }

    func fetchClientToken(accessToken _: String) async throws -> (
        token: String,
        expiresAt: Date
    ) {
        throw GamesViewModelTestError.unavailable
    }

    func refreshWithClientToken(
        _: String,
        userId _: String
    ) async throws -> AuthTokens {
        throw GamesViewModelTestError.unavailable
    }

    func requestDeviceAuthorization(
        idpId _: String?
    ) async throws -> DeviceFlowResponse {
        throw GamesViewModelTestError.unavailable
    }

    func pollForDeviceToken(
        deviceCode _: String,
        interval _: Int,
        expiresIn _: Int
    ) async throws -> AuthTokens {
        throw GamesViewModelTestError.unavailable
    }

    func fetchUserInfo(tokens _: AuthTokens) async throws -> AuthUser {
        throw GamesViewModelTestError.unavailable
    }
}
