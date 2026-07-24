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
    @Test("Catalog, library, subscription, and sessions publish from injected clients")
    func loadsAllRemoteDatasets() async {
        let catalogGame = makeGame(
            id: "catalog",
            title: "Catalog",
            appId: "catalog-app",
            isInLibrary: true
        )
        let libraryGame = makeGame(
            id: "library",
            title: "Library",
            appId: "library-app",
            isInLibrary: true
        )
        var snapshot = AppPersistenceStore.GamesSnapshot()
        snapshot.vpcId = "TEST-VPC"
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
        #expect(Set(viewModel.libraryGames.map(\.id)) == ["catalog", "library"])
        #expect(viewModel.subscription?.membershipTier == "Ultimate")
        #expect(viewModel.activeSessions.map(\.sessionId) == ["session"])
        #expect(viewModel.continuePlaying.map(\.id) == ["catalog"])
        #expect(viewModel.catalogLoadPhase == .loaded)
        #expect(viewModel.libraryLoadPhase == .loaded)
        #expect(await persistence.savedLibrary?.count == 2)
        #expect(await persistence.savedSubscription?.membershipTier == "Ultimate")
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
    private func makeAuthenticatedManager(
        accessToken: String = "fixture-access-token"
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
                userId: "fixture-user",
                displayName: "Fixture User",
                email: nil,
                avatarUrl: nil,
                membershipTier: "FREE"
            )
        )
        let manager = AuthManager(
            api: UnavailableAuthAPI(),
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
}

private enum GamesViewModelTestError: Error {
    case unavailable
}

private actor ScriptedGamesClient: GamesCatalogClient {
    private let mainOutcomes: [ScriptedGamesOutcome]
    private let libraryOutcomes: [ScriptedGamesOutcome]
    private let blocksFirstMainRequest: Bool
    private var firstMainContinuation: CheckedContinuation<Void, Never>?
    private var mainIndex = 0
    private var libraryIndex = 0
    private(set) var mainCallCount = 0
    private var mainRequestWaiters: [MainRequestWaiter] = []

    private struct MainRequestWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    init(
        mainOutcomes: [ScriptedGamesOutcome] = [.success([])],
        libraryOutcomes: [ScriptedGamesOutcome] = [.success([])],
        blocksFirstMainRequest: Bool = false
    ) {
        self.mainOutcomes = mainOutcomes
        self.libraryOutcomes = libraryOutcomes
        self.blocksFirstMainRequest = blocksFirstMainRequest
    }

    func fetchMainGames(
        token _: String,
        streamingBaseUrl _: String,
        vpcId _: String?
    ) async throws -> [GameInfo] {
        let index = mainIndex
        mainIndex += 1
        mainCallCount += 1
        resumeMainRequestWaiters()
        if blocksFirstMainRequest, index == 0 {
            await withCheckedContinuation { continuation in
                firstMainContinuation = continuation
            }
        }
        return try value(
            from: mainOutcomes[min(index, mainOutcomes.count - 1)]
        )
    }

    func fetchLibrary(
        token _: String,
        streamingBaseUrl _: String,
        vpcId _: String?
    ) async throws -> [GameInfo] {
        let index = libraryIndex
        libraryIndex += 1
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

    private func value(from outcome: ScriptedGamesOutcome) throws -> [GameInfo] {
        switch outcome {
        case let .success(games):
            games
        case .failure:
            throw GamesViewModelTestError.unavailable
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
    private(set) var savedFavorites: Set<String>?
    private(set) var savedRecent: [String]?
    private(set) var savedSettings: StreamSettings?
    private(set) var savedLibrary: [GameInfo]?
    private(set) var savedSubscription: SubscriptionInfo?
    private(set) var savedCatalog: [GameInfo]?
    private var mutationWaiters: [MutationWaiter] = []

    private struct MutationWaiter {
        let favorites: Set<String>
        let bitrate: Int
        let recentCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    init(
        snapshot: AppPersistenceStore.GamesSnapshot = .init(),
        cachedCatalog: [GameInfo]? = nil
    ) {
        self.snapshot = snapshot
        self.cachedCatalog = cachedCatalog
    }

    func loadGamesSnapshot() -> AppPersistenceStore.GamesSnapshot {
        snapshot
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

    func saveLibraryGames(_ games: [GameInfo]) {
        savedLibrary = games
    }

    func saveSubscription(_ subscription: SubscriptionInfo) {
        savedSubscription = subscription
    }

    func saveVpcId(_: String) {}

    func loadCatalog(localeCode _: String, vpcId _: String?) -> [GameInfo]? {
        cachedCatalog
    }

    func saveCatalog(
        _ games: [GameInfo],
        localeCode _: String,
        vpcId _: String?
    ) {
        savedCatalog = games
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

    func saveAuthSession(_ session: AuthSession) {
        self.session = session
    }

    func deleteAuthSession() {
        session = nil
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
