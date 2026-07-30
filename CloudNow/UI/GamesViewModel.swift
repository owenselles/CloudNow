import Foundation
import Observation
import os.log
import UIKit

private let gamesLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "Games")

struct ResumableSession {
    let game: GameInfo
    let session: SessionInfo
    let leftAt: Date
    /// Grace window before we stop offering to resume (GFN keeps the session ~2 min).
    static let gracePeriod: TimeInterval = 110

    var secondsRemaining: Int {
        max(0, Int(Self.gracePeriod - Date().timeIntervalSince(leftAt)))
    }

    var isExpired: Bool {
        secondsRemaining == 0
    }
}

nonisolated struct LastSessionRecord: Codable {
    let sessionId: String
    let serverIp: String
    let appId: String
    let base: String
    let routingZoneUrl: String?
    let clientId: String?
    let deviceId: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionId, serverIp, appId, base, routingZoneUrl, clientId, deviceId, createdAt
    }

    init(
        sessionId: String,
        serverIp: String,
        appId: String,
        base: String,
        routingZoneUrl: String?,
        clientId: String?,
        deviceId: String?,
        createdAt: Date
    ) {
        self.sessionId = sessionId
        self.serverIp = serverIp
        self.appId = appId
        self.base = base
        self.routingZoneUrl = routingZoneUrl
        self.clientId = clientId
        self.deviceId = deviceId
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        serverIp = try c.decode(String.self, forKey: .serverIp)
        appId = try c.decode(String.self, forKey: .appId)
        base = try c.decode(String.self, forKey: .base)
        routingZoneUrl = try c.decodeIfPresent(String.self, forKey: .routingZoneUrl)
        clientId = try c.decodeIfPresent(String.self, forKey: .clientId)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

enum DatasetLoadPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@Observable
@MainActor
class GamesViewModel {
    var mainGames: [GameInfo] = [] {
        didSet { rebuildStoreDerivations() }
    }

    var libraryGames: [GameInfo] = [] {
        didSet { rebuildLibraryDerivations() }
    }

    var activeSessions: [ActiveSessionInfo] = []
    private(set) var catalogLoadPhase: DatasetLoadPhase = .loading
    private(set) var libraryLoadPhase: DatasetLoadPhase = .loading
    var libraryWarning: String?

    var isLoading: Bool {
        mainGames.isEmpty && catalogLoadPhase == .loading
    }

    var isLibraryLoading: Bool {
        libraryLoadPhase == .loading
    }

    var libraryRefreshState: FullLibraryRefreshState {
        libraryRefreshCoordinator.state
    }

    var isFullLibraryRefreshRunning: Bool {
        libraryRefreshCoordinator.state.isRunning
    }

    var isProviderLibrarySyncEnabled: Bool {
        providerLibrarySyncEnabled
    }

    var canStartFullLibraryRefresh: Bool {
        providerLibrarySyncEnabled
            && hasCompletedInitialLoad
            && libraryLoadPhase != .loading
            && catalogLoadPhase != .loading
    }

    var canPresentFullLibraryRefresh: Bool {
        isFullLibraryRefreshRunning || canStartFullLibraryRefresh
    }

    var error: String? {
        guard case let .failed(message) = catalogLoadPhase else { return nil }
        return message
    }

    var libraryError: String? {
        guard case let .failed(message) = libraryLoadPhase else { return nil }
        return message
    }

    var favoriteIds: Set<String> = [] {
        didSet {
            rebuildLibraryDerivations()
            rebuildStoreDerivations()
        }
    }

    var preferredStoreIds: [String: String] = [:]
    var recentlyPlayedIds: [String] = [] {
        didSet {
            rebuildFilteredLibraryGames()
            rebuildFilteredStoreGames()
        }
    }

    var streamSettings: StreamSettings = .init()
    var subscription: SubscriptionInfo?
    /// Session the user left without ending — available to resume for ~2 minutes.
    var resumableSession: ResumableSession?
    /// Last created session, persisted so we can resume/stop it across app launches.
    var lastSession: LastSessionRecord?
    var librarySearchText = "" {
        didSet {
            rebuildLibraryFilterBaseCount()
            rebuildFilteredLibraryGames()
        }
    }

    var librarySortOrder: LibrarySortOrder = .default {
        didSet { rebuildFilteredLibraryGames() }
    }

    var libraryFilterState = GameFilterState() {
        didSet { rebuildFilteredLibraryGames() }
    }

    var storeSearchText = "" {
        didSet {
            rebuildStoreFilterBaseCount()
            rebuildFilteredStoreGames()
        }
    }

    var storeSortOrder: LibrarySortOrder = .default {
        didSet { rebuildFilteredStoreGames() }
    }

    var storeFilterState = GameFilterState() {
        didSet { rebuildFilteredStoreGames() }
    }

    private(set) var libraryFilterOptions = GameFilterOptions(
        games: [], favoriteIds: [], context: .library
    )
    private(set) var filteredLibraryGames: [GameInfo] = []
    private(set) var libraryFilterBaseCount = 0
    private(set) var storeFilterOptions = GameFilterOptions(
        games: [], favoriteIds: [], context: .store
    )
    private(set) var filteredStoreGames: [GameInfo] = []
    private(set) var storeFilterBaseCount = 0

    private let gamesClient: any GamesCatalogClient
    private let cloudMatchClient: any ActiveSessionsClient
    private let membershipClient: any MembershipClient
    private let persistence: any GamesPersistence
    private let libraryRefreshCoordinator: LibraryRefreshCoordinator
    private let providerLibrarySyncEnabled: Bool
    private let libraryRefreshImporterOverride: LibraryRefreshCoordinator.LibraryImporter?
    private let localeCodeProvider: @MainActor @Sendable () -> String
    /// Server identifier discovered from NVIDIA's `/v2/serverInfo` response.
    /// Exposed read-only so the in-stream HUD can label server-routed sessions.
    private(set) var currentVpcId: String?
    private struct ServiceRequestKey: Equatable {
        let token: String
        let base: String
    }

    private struct ActiveSessionsRequest {
        let generation: Int
        let key: ServiceRequestKey
        let task: Task<[ActiveSessionInfo], Never>
    }

    private struct VpcIdRequest {
        let generation: Int
        let key: ServiceRequestKey
        let task: Task<String?, Never>
    }

    private struct ActiveSessionsFetchOutcome {
        let sessions: [ActiveSessionInfo]
        let requestGeneration: Int
    }

    private var activeSessionsRequest: ActiveSessionsRequest?
    private var vpcIdRequest: VpcIdRequest?
    private var activeSessionsRequestGeneration = 0
    private var vpcIdRequestGeneration = 0
    private var latestNetworkLibraryGames: [GameInfo]?
    private var currentAccountScope: String?
    private var persistenceEnabled = true
    private var cacheGeneration = 0
    private var ownershipCacheGeneration: UInt64 = 0
    private var loadGeneration = 0

    /// The scene-activation refresh in MainTabView also fires on cold launch,
    /// which would fetch the library a second time in parallel with load().
    /// Refreshes are skipped until the initial load has finished.
    private var hasCompletedInitialLoad = false

    /// Sessions the user just ended, keyed by id. The server keeps listing a
    /// stopped session for a few seconds, and the refresh triggered by the
    /// player dismissing races the stop request — so refreshes exclude these
    /// ids for a grace window instead of re-adding the dead session to Home.
    private var recentlyStoppedSessions: [String: Date] = [:]
    private static let stoppedSessionGracePeriod: TimeInterval = 60

    init(
        mainGames: [GameInfo] = [],
        libraryGames: [GameInfo] = [],
        favoriteIds: Set<String> = [],
        persistenceEnabled: Bool = true,
        gamesClient: any GamesCatalogClient = GamesClient(),
        cloudMatchClient: any ActiveSessionsClient = CloudMatchClient(),
        membershipClient: any MembershipClient = MESClient.shared,
        persistence: any GamesPersistence = AppPersistenceStore.shared,
        librarySyncClient: any LibrarySyncClient = GFNLibrarySyncClient(),
        libraryRefreshScheduler: LibraryRefreshScheduler = .continuous,
        providerLibrarySyncEnabled: Bool = FeatureFlags.providerLibrarySyncEnabled,
        initialLibraryRefreshState: FullLibraryRefreshState = FullLibraryRefreshState(),
        libraryRefreshImporterOverride: LibraryRefreshCoordinator.LibraryImporter? = nil,
        localeCodeProvider: @escaping @MainActor @Sendable () -> String = {
            L10n.nvidiaLocaleCode()
        }
    ) {
        self.gamesClient = gamesClient
        self.cloudMatchClient = cloudMatchClient
        self.membershipClient = membershipClient
        self.persistence = persistence
        libraryRefreshCoordinator = LibraryRefreshCoordinator(
            client: librarySyncClient,
            scheduler: libraryRefreshScheduler,
            initialState: initialLibraryRefreshState
        )
        self.providerLibrarySyncEnabled = providerLibrarySyncEnabled
        self.libraryRefreshImporterOverride = libraryRefreshImporterOverride
        self.localeCodeProvider = localeCodeProvider
        self.persistenceEnabled = persistenceEnabled
        self.mainGames = mainGames
        self.libraryGames = libraryGames
        self.favoriteIds = favoriteIds
        hasCompletedInitialLoad = !persistenceEnabled
        if !mainGames.isEmpty || !persistenceEnabled {
            catalogLoadPhase = .loaded
        }
        if !libraryGames.isEmpty || !persistenceEnabled {
            libraryLoadPhase = .loaded
        }
        rebuildLibraryDerivations()
        rebuildStoreDerivations()
    }

    // MARK: Computed — Entitled Resolutions & FPS

    /// Resolution strings available to the current account tier.
    /// Falls back to a standard preset if no subscription data is available.
    var availableResolutions: [String] {
        guard let resos = subscription?.entitledResolutions, !resos.isEmpty else {
            return ["1280x720", "1920x1080"]
        }
        let unique = Array(Set(resos.map(\.resolutionLabel)))
        return unique.sorted {
            let lw = Int($0.split(separator: "x").first ?? "") ?? 0
            let rw = Int($1.split(separator: "x").first ?? "") ?? 0
            return lw < rw
        }
    }

    /// FPS values available for the currently selected resolution, capped to the
    /// screen's maximum refresh rate. Today tvOS caps at 60 Hz; if Apple raises it
    /// in a future update this will automatically expose the higher option.
    var availableFps: [Int] {
        let maxFps = (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.maximumFramesPerSecond) ?? 60
        guard let resos = subscription?.entitledResolutions, !resos.isEmpty else {
            return [30, 60].filter { $0 <= maxFps }
        }
        let parts = streamSettings.resolution.split(separator: "x").compactMap { Int($0) }
        let w = parts.first ?? 1920
        let h = parts.last ?? 1080
        let matching = resos.filter { $0.widthInPixels == w && $0.heightInPixels == h }
        let source = matching.isEmpty ? resos : matching
        return Array(Set(source.map(\.framesPerSecond))).filter { $0 <= maxFps }.sorted()
    }

    // MARK: Computed — Games

    var continuePlaying: [GameInfo] {
        let sessionAppIds = Set(activeSessions.compactMap(\.appId))
        return mainGames.filter { game in
            game.variants.contains { v in
                guard let appId = v.appId else { return false }
                return sessionAppIds.contains(appId)
            }
        }
    }

    var favoriteGames: [GameInfo] {
        var seen = Set<String>()
        return mainGames.filter { favoriteIds.contains($0.id) && seen.insert($0.id).inserted }
    }

    var recentlyPlayedGames: [GameInfo] {
        let activeIds = Set(continuePlaying.map(\.id))
        return recentlyPlayedIds.compactMap { id in
            mainGames.first { $0.id == id && !activeIds.contains($0.id) }
        }
    }

    // MARK: Load

    private struct GamesFetchOutcome {
        let games: [GameInfo]?
        let errorMessage: String?
        let isUnauthorized: Bool
    }

    private struct LoadIdentity: Equatable {
        let cacheGeneration: Int
        let loadGeneration: Int
    }

    private func beginLoad() -> LoadIdentity {
        loadGeneration &+= 1
        return LoadIdentity(
            cacheGeneration: cacheGeneration,
            loadGeneration: loadGeneration
        )
    }

    private func isCurrent(_ identity: LoadIdentity) -> Bool {
        persistenceEnabled
            && identity.cacheGeneration == cacheGeneration
            && identity.loadGeneration == loadGeneration
    }

    func load(authManager: AuthManager) async {
        persistenceEnabled = true
        let identity = beginLoad()
        latestNetworkLibraryGames = nil
        let accountScope = authManager.session.map {
            nvidiaAccountScope(for: $0.user.userId)
        }
        if currentAccountScope != accountScope {
            libraryRefreshCoordinator.cancel()
            mainGames = []
            libraryGames = []
            activeSessions = []
            subscription = nil
            hasCompletedInitialLoad = false
        }
        currentAccountScope = accountScope
        let snapshot = await persistence.loadGamesSnapshot(
            accountScope: accountScope
        )
        guard isCurrent(identity) else { return }
        ownershipCacheGeneration = snapshot.ownershipCacheGeneration
        let catalogLocaleCode = localeCodeProvider()
        let expectedOwnershipCacheGeneration = snapshot.ownershipCacheGeneration
        favoriteIds = snapshot.favoriteIds
        preferredStoreIds = snapshot.preferredStoreIds
        recentlyPlayedIds = snapshot.recentlyPlayedIds
        streamSettings = (snapshot.streamSettings ?? StreamSettings()).normalizedForClient
        lastSession = snapshot.lastSession
        currentVpcId = snapshot.vpcId

        // tvOS currently caps at 60 Hz; clamp any saved value to the screen maximum.
        // If Apple raises the cap in a future tvOS release this will automatically unlock.
        let screenMax = (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.maximumFramesPerSecond) ?? 60
        if streamSettings.fps > screenMax {
            streamSettings.fps = screenMax
        }
        let settings = streamSettings
        gamesLog.debug("[Localization] preferred=\(Locale.preferredLanguages.first ?? "nil", privacy: .public) ui=\(L10n.localeCode, privacy: .public) keyboard=\(settings.keyboardLayout, privacy: .public) gameLanguage=\(settings.gameLanguage, privacy: .public) effectiveGameLanguage=\(settings.effectiveGameLanguage, privacy: .public)")

        // Show each cached dataset independently while its own network refresh runs.
        if libraryGames.isEmpty, !snapshot.libraryGames.isEmpty {
            libraryGames = snapshot.libraryGames
        }
        if subscription == nil, let cachedSub = snapshot.subscription {
            subscription = cachedSub
            normalizeStreamSettingsForCurrentEntitlements()
        }
        if mainGames.isEmpty {
            let cachedCatalog = await persistence.loadCatalog(
                localeCode: catalogLocaleCode,
                vpcId: snapshot.vpcId ?? "GFN-PC",
                accountScope: accountScope
            )
            guard isCurrent(identity) else { return }
            if let cachedCatalog {
                mainGames = catalogWithOwnership(
                    cachedCatalog,
                    library: snapshot.libraryGames
                )
            }
        }

        catalogLoadPhase = .loading
        libraryLoadPhase = .loading
        libraryWarning = nil

        do {
            let token = try await authManager.resolveToken()
            guard isCurrent(identity) else { return }
            let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
            let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl

            // The catalog, library, and subscription queries all need the vpcId;
            // resolve it once up front instead of three times in parallel.
            // A failed server-info lookup still has a well-defined backend fallback.
            // Pass it explicitly so GamesClient does not repeat the same lookup once
            // for the catalog and again for the library.
            let vpcId = await resolveVpcIdCached(
                snapshot.vpcId,
                token: token,
                base: base,
                identity: identity
            ) ?? "GFN-PC"
            guard isCurrent(identity) else { return }

            // Each dataset applies its result as soon as that request finishes;
            // a slow catalog no longer holds the library or sessions in loading.
            async let catalogUpdate: Void = loadCatalogFromNetwork(
                token: token,
                base: base,
                vpcId: vpcId,
                localeCode: catalogLocaleCode,
                accountScope: accountScope,
                expectedOwnershipCacheGeneration: expectedOwnershipCacheGeneration,
                identity: identity
            )
            async let libraryUpdate: Void = loadLibraryFromNetwork(
                token: token,
                base: base,
                vpcId: vpcId,
                accountScope: accountScope,
                expectedOwnershipCacheGeneration: expectedOwnershipCacheGeneration,
                identity: identity
            )
            async let sessionsUpdate: Void = loadActiveSessionsFromNetwork(
                token: token,
                base: base,
                identity: identity
            )
            async let subscriptionUpdate: Void = loadSubscriptionFromNetwork(
                authManager: authManager,
                token: token,
                vpcId: vpcId,
                identity: identity
            )
            _ = await (catalogUpdate, libraryUpdate, sessionsUpdate, subscriptionUpdate)
            guard isCurrent(identity) else { return }
        } catch {
            guard isCurrent(identity) else { return }
            catalogLoadPhase = mainGames.isEmpty ? .failed(error.localizedDescription) : .loaded
            libraryLoadPhase = libraryGames.isEmpty ? .failed(error.localizedDescription) : .loaded
        }
        guard isCurrent(identity) else { return }
        hasCompletedInitialLoad = true
    }

    /// Returns the vpcId shared by the launch queries. Uses the value from the
    /// previous launch when available (it changes only if NVIDIA migrates the
    /// account to another region) and revalidates it in the background, so the
    /// launch fetches don't wait a /v2/serverInfo round trip.
    private func resolveVpcIdCached(
        _ cached: String?,
        token: String,
        base: String,
        identity: LoadIdentity
    ) async -> String? {
        if let cached, !cached.isEmpty {
            guard isCurrent(identity) else { return nil }
            currentVpcId = cached
            Task { [weak self] in
                _ = await self?.refreshVpcId(
                    token: token,
                    base: base,
                    identity: identity
                )
            }
            return cached
        }

        let fetched = await refreshVpcId(
            token: token,
            base: base,
            identity: identity
        )
        guard isCurrent(identity) else { return nil }
        return fetched
    }

    private func refreshVpcId(
        token: String,
        base: String,
        identity: LoadIdentity
    ) async -> String? {
        let key = ServiceRequestKey(token: token, base: base)
        let request: VpcIdRequest
        if let existing = vpcIdRequest, existing.key == key {
            request = existing
        } else {
            vpcIdRequest?.task.cancel()
            vpcIdRequestGeneration &+= 1
            let generation = vpcIdRequestGeneration
            let task = Task<String?, Never> { [membershipClient] in
                await ((try? membershipClient.fetchVpcId(token: token, base: base)) ?? nil)
            }
            request = VpcIdRequest(
                generation: generation,
                key: key,
                task: task
            )
            vpcIdRequest = request
        }

        let fetched = await request.task.value
        if vpcIdRequest?.generation == request.generation {
            vpcIdRequest = nil
        }
        guard isCurrent(identity),
              request.generation == vpcIdRequestGeneration
        else { return nil }
        if let fetched, !fetched.isEmpty {
            await persistence.saveVpcId(fetched)
            guard isCurrent(identity),
                  request.generation == vpcIdRequestGeneration
            else { return nil }
            currentVpcId = fetched
        }
        return fetched
    }

    private func fetchMainOutcome(token: String, base: String, vpcId: String?) async -> GamesFetchOutcome {
        do {
            let games = try await gamesClient.fetchMainGames(token: token, streamingBaseUrl: base, vpcId: vpcId)
            return GamesFetchOutcome(
                games: games,
                errorMessage: nil,
                isUnauthorized: false
            )
        } catch {
            return GamesFetchOutcome(
                games: nil,
                errorMessage: error.localizedDescription,
                isUnauthorized: isUnauthorized(error)
            )
        }
    }

    private func fetchLibraryOutcome(token: String, base: String, vpcId: String?) async -> GamesFetchOutcome {
        do {
            let games = try await gamesClient.fetchLibrary(token: token, streamingBaseUrl: base, vpcId: vpcId)
            return GamesFetchOutcome(
                games: games,
                errorMessage: nil,
                isUnauthorized: false
            )
        } catch {
            return GamesFetchOutcome(
                games: nil,
                errorMessage: error.localizedDescription,
                isUnauthorized: isUnauthorized(error)
            )
        }
    }

    private func isUnauthorized(_ error: Error) -> Bool {
        if case GamesError.unauthorized = error {
            return true
        }
        return false
    }

    private func fetchActiveSessionsCoalesced(
        token: String,
        base: String
    ) async -> ActiveSessionsFetchOutcome {
        let key = ServiceRequestKey(token: token, base: base)
        let request: ActiveSessionsRequest
        if let existing = activeSessionsRequest, existing.key == key {
            request = existing
        } else {
            activeSessionsRequest?.task.cancel()
            activeSessionsRequestGeneration &+= 1
            let generation = activeSessionsRequestGeneration
            let task = Task<[ActiveSessionInfo], Never> { [cloudMatchClient] in
                await (try? cloudMatchClient.getActiveSessions(token: token, base: base)) ?? []
            }
            request = ActiveSessionsRequest(
                generation: generation,
                key: key,
                task: task
            )
            activeSessionsRequest = request
        }

        let sessions = await request.task.value
        if activeSessionsRequest?.generation == request.generation {
            activeSessionsRequest = nil
        }
        return ActiveSessionsFetchOutcome(
            sessions: sessions,
            requestGeneration: request.generation
        )
    }

    private func fetchSubscriptionSafe(authManager: AuthManager, token: String, vpcId: String) async -> SubscriptionInfo? {
        guard let userId = authManager.session?.user.userId else { return nil }
        return try? await membershipClient.fetchSubscription(
            token: token,
            vpcId: vpcId,
            userId: userId
        )
    }

    private func loadCatalogFromNetwork(
        token: String,
        base: String,
        vpcId: String?,
        localeCode: String,
        accountScope: String?,
        expectedOwnershipCacheGeneration: UInt64,
        identity: LoadIdentity
    ) async {
        let outcome = await fetchMainOutcome(token: token, base: base, vpcId: vpcId)
        guard isCurrent(identity) else { return }
        guard let fetchedMain = outcome.games else {
            catalogLoadPhase = mainGames.isEmpty
                ? .failed(outcome.errorMessage ?? L10n.text("failed_to_load_games"))
                : .loaded
            if !mainGames.isEmpty {
                mainGames = catalogWithOwnership(
                    mainGames,
                    library: libraryGames
                )
            }
            return
        }

        mainGames = catalogWithOwnership(
            fetchedMain,
            library: latestNetworkLibraryGames ?? libraryGames
        )
        catalogLoadPhase = .loaded
        await persistence.saveCatalog(
            fetchedMain,
            localeCode: localeCode,
            vpcId: vpcId,
            accountScope: accountScope,
            expectedGeneration: expectedOwnershipCacheGeneration
        )
        guard isCurrent(identity) else { return }

        // Merge only two fresh responses from this load. Cached ownership must
        // never re-add a game removed by the authoritative library response.
        guard let latestNetworkLibraryGames else { return }
        let merged = enrichLibrary(
            latestNetworkLibraryGames,
            catalog: fetchedMain
        )
        if merged != libraryGames {
            libraryGames = merged
            mainGames = catalogWithOwnership(
                fetchedMain,
                library: merged
            )
            await persistence.saveLibraryGames(
                merged,
                accountScope: accountScope,
                expectedGeneration: expectedOwnershipCacheGeneration
            )
            guard isCurrent(identity) else { return }
        }
    }

    private func loadLibraryFromNetwork(
        token: String,
        base: String,
        vpcId: String?,
        accountScope: String?,
        expectedOwnershipCacheGeneration: UInt64,
        identity: LoadIdentity
    ) async {
        let outcome = await fetchLibraryOutcome(token: token, base: base, vpcId: vpcId)
        guard isCurrent(identity) else { return }
        guard let panelLibrary = outcome.games else {
            if libraryGames.isEmpty {
                libraryLoadPhase = .failed(outcome.errorMessage ?? L10n.text("library_failed_to_load"))
            } else {
                libraryLoadPhase = .loaded
                libraryWarning = outcome.errorMessage
            }
            return
        }

        latestNetworkLibraryGames = panelLibrary
        let merged = catalogLoadPhase == .loaded
            ? enrichLibrary(panelLibrary, catalog: mainGames)
            : panelLibrary
        libraryGames = merged
        if catalogLoadPhase == .loaded, !mainGames.isEmpty {
            mainGames = catalogWithOwnership(
                mainGames,
                library: merged
            )
        }
        libraryLoadPhase = .loaded
        await persistence.saveLibraryGames(
            merged,
            accountScope: accountScope,
            expectedGeneration: expectedOwnershipCacheGeneration
        )
        guard isCurrent(identity) else { return }
    }

    private func loadActiveSessionsFromNetwork(
        token: String,
        base: String,
        identity: LoadIdentity
    ) async {
        let outcome = await fetchActiveSessionsCoalesced(token: token, base: base)
        guard isCurrent(identity),
              outcome.requestGeneration == activeSessionsRequestGeneration
        else { return }
        activeSessions = filterStopped(outcome.sessions)
    }

    private func loadSubscriptionFromNetwork(
        authManager: AuthManager,
        token: String,
        vpcId: String,
        identity: LoadIdentity
    ) async {
        guard let subscription = await fetchSubscriptionSafe(authManager: authManager, token: token, vpcId: vpcId) else {
            return
        }
        guard isCurrent(identity) else { return }
        gamesLog.info("[MES] tier=\(subscription.membershipTier, privacy: .public) resolutions=\(String(describing: subscription.entitledResolutions.map(\.resolutionLabel)), privacy: .public)")
        self.subscription = subscription
        normalizeStreamSettingsForCurrentEntitlements()
        await persistence.saveSubscription(subscription)
        guard isCurrent(identity) else { return }
    }

    private func enrichLibrary(
        _ authoritativeLibrary: [GameInfo],
        catalog: [GameInfo]
    ) -> [GameInfo] {
        let catalogById = Dictionary(
            catalog.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return authoritativeLibrary.map { libraryGame in
            guard let catalogGame = catalogById[libraryGame.id] else {
                return libraryGame
            }
            return GameInfo(
                id: libraryGame.id,
                title: catalogGame.title,
                longDescription: catalogGame.longDescription
                    ?? libraryGame.longDescription,
                genres: catalogGame.genres?.isEmpty == false
                    ? catalogGame.genres
                    : libraryGame.genres,
                developer: catalogGame.developer ?? libraryGame.developer,
                publisher: catalogGame.publisher ?? libraryGame.publisher,
                contentRating: catalogGame.contentRating
                    ?? libraryGame.contentRating,
                boxArtUrl: catalogGame.boxArtUrl ?? libraryGame.boxArtUrl,
                heroBannerUrl: catalogGame.heroBannerUrl
                    ?? libraryGame.heroBannerUrl,
                heroImageUrl: catalogGame.heroImageUrl
                    ?? libraryGame.heroImageUrl,
                supportedFeatures: catalogGame.supportedFeatures?.isEmpty == false
                    ? catalogGame.supportedFeatures
                    : libraryGame.supportedFeatures,
                screenshots: catalogGame.screenshots.isEmpty
                    ? libraryGame.screenshots
                    : catalogGame.screenshots,
                isInLibrary: libraryGame.isInLibrary,
                variants: libraryGame.variants
            )
        }
    }

    private func catalogWithOwnership(
        _ catalog: [GameInfo],
        library: [GameInfo]
    ) -> [GameInfo] {
        let libraryById = Dictionary(
            library.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return catalog.map { catalogGame in
            var catalogGame = catalogGame
            catalogGame.isInLibrary = false
            for index in catalogGame.variants.indices {
                catalogGame.variants[index].isOwned = false
            }
            guard let libraryGame = libraryById[catalogGame.id] else {
                return catalogGame
            }

            catalogGame.isInLibrary = libraryGame.isInLibrary
            let ownedVariantIds = Set(
                libraryGame.variants
                    .filter(\.isOwned)
                    .map(\.id)
            )
            for index in catalogGame.variants.indices {
                catalogGame.variants[index].isOwned = ownedVariantIds.contains(
                    catalogGame.variants[index].id
                )
            }
            return catalogGame
        }
    }

    func refreshLibrary(authManager: AuthManager) async {
        guard libraryLoadPhase != .loading,
              hasCompletedInitialLoad,
              !isFullLibraryRefreshRunning
        else { return }
        let identity = beginLoad()
        let expectedOwnershipCacheGeneration = ownershipCacheGeneration
        libraryLoadPhase = .loading
        libraryWarning = nil

        do {
            let token = try await authManager.resolveToken()
            guard isCurrent(identity) else { return }
            let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
            let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl
            let refreshed = try await gamesClient.fetchLibrary(token: token, streamingBaseUrl: base, vpcId: currentVpcId)
            guard isCurrent(identity) else { return }
            libraryGames = refreshed
            if !mainGames.isEmpty {
                mainGames = catalogWithOwnership(
                    mainGames,
                    library: refreshed
                )
            }
            libraryLoadPhase = .loaded
            await persistence.saveLibraryGames(
                libraryGames,
                accountScope: currentAccountScope,
                expectedGeneration: expectedOwnershipCacheGeneration
            )
            guard isCurrent(identity) else { return }
        } catch {
            guard isCurrent(identity) else { return }
            if libraryGames.isEmpty {
                libraryLoadPhase = .failed(error.localizedDescription)
            } else {
                libraryLoadPhase = .loaded
                libraryWarning = error.localizedDescription
            }
        }
    }

    func startFullLibraryRefresh(authManager: AuthManager) {
        guard libraryRefreshState.stage == .idle else { return }
        beginFullLibraryRefresh(
            authManager: authManager,
            retryProviderCodes: nil
        )
    }

    func retryFailedLibraryProviders(authManager: AuthManager) {
        let retryProviderCodes = Set(
            libraryRefreshState.providers.compactMap {
                $0.phase.isRetryable ? $0.providerCode : nil
            }
        )
        guard !retryProviderCodes.isEmpty
            || libraryRefreshState.finalPhase.isRetryable
        else { return }
        beginFullLibraryRefresh(
            authManager: authManager,
            retryProviderCodes: retryProviderCodes
        )
    }

    func acknowledgeLibraryRefresh() {
        libraryRefreshCoordinator.acknowledgeCompletion()
    }

    private func beginFullLibraryRefresh(
        authManager: AuthManager,
        retryProviderCodes: Set<String>?
    ) {
        guard providerLibrarySyncEnabled,
              let userId = authManager.session?.user.userId,
              hasCompletedInitialLoad,
              libraryLoadPhase != .loading,
              catalogLoadPhase != .loading,
              !isFullLibraryRefreshRunning
        else { return }
        _ = beginLoad()
        let accountScope = nvidiaAccountScope(for: userId)
        currentAccountScope = accountScope

        _ = libraryRefreshCoordinator.start(
            userId: userId,
            retryProviderCodes: retryProviderCodes,
            resolveToken: { [weak authManager] rejectedToken in
                guard let authManager else { throw AuthError.noSession }
                if let rejectedToken {
                    return try await authManager.resolveToken(
                        rejecting: rejectedToken
                    )
                }
                return try await authManager.resolveToken()
            },
            userIsCurrent: { [weak authManager] in
                authManager?.session?.user.userId == userId
            },
            importLibrary: { [weak self, weak authManager] in
                guard let self, let authManager else {
                    throw CancellationError()
                }
                if let importer = libraryRefreshImporterOverride {
                    return try await importer()
                }
                return try await importAuthoritativeLibrary(
                    authManager: authManager,
                    expectedUserId: userId,
                    accountScope: accountScope
                )
            }
        )
    }

    private func importAuthoritativeLibrary(
        authManager: AuthManager,
        expectedUserId: String,
        accountScope: String
    ) async throws -> LibraryImportResult {
        guard authManager.session?.user.userId == expectedUserId else {
            throw CancellationError()
        }
        let startingCacheGeneration = cacheGeneration
        let startingOwnershipCacheGeneration = ownershipCacheGeneration
        let previousLibrary = libraryGames
        let previousIds = Set(previousLibrary.map(\.id))
        let snapshotVpcId = currentVpcId.flatMap {
            $0.isEmpty ? nil : $0
        } ?? "GFN-PC"
        let snapshotLocaleCode = localeCodeProvider()
        libraryLoadPhase = .loading
        libraryWarning = nil

        do {
            var token = try await authManager.resolveToken()
            let streamingUrl = authManager.session?.provider.streamingServiceUrl
                ?? NVIDIAAuth.defaultStreamingUrl
            let base = streamingUrl.hasSuffix("/")
                ? String(streamingUrl.dropLast())
                : streamingUrl

            var didRefreshAuthentication = false
            let refreshedLibrary: [GameInfo]
            let catalogOutcome: GamesFetchOutcome
            while true {
                guard persistenceEnabled,
                      cacheGeneration == startingCacheGeneration,
                      authManager.session?.user.userId == expectedUserId
                else {
                    throw CancellationError()
                }
                do {
                    let result = try await fetchAuthoritativeSnapshot(
                        token: token,
                        base: base,
                        vpcId: snapshotVpcId
                    )
                    if result.catalog.isUnauthorized,
                       !didRefreshAuthentication
                    {
                        token = try await authManager.resolveToken(
                            rejecting: token
                        )
                        didRefreshAuthentication = true
                        continue
                    }
                    refreshedLibrary = result.library
                    catalogOutcome = result.catalog
                    break
                } catch GamesError.unauthorized
                    where !didRefreshAuthentication
                {
                    token = try await authManager.resolveToken(
                        rejecting: token
                    )
                    didRefreshAuthentication = true
                }
            }
            guard persistenceEnabled,
                  cacheGeneration == startingCacheGeneration,
                  authManager.session?.user.userId == expectedUserId
            else {
                throw CancellationError()
            }

            let authoritativeLibrary: [GameInfo]
            let freshCatalog = catalogOutcome.games
            if let freshCatalog {
                authoritativeLibrary = enrichLibrary(
                    refreshedLibrary,
                    catalog: freshCatalog
                )
            } else {
                authoritativeLibrary = refreshedLibrary
            }

            try await persistence.saveRefreshedLibrarySnapshot(
                libraryGames: authoritativeLibrary,
                catalogGames: freshCatalog,
                localeCode: snapshotLocaleCode,
                vpcId: snapshotVpcId,
                accountScope: accountScope,
                expectedGeneration: startingOwnershipCacheGeneration
            )
            guard persistenceEnabled,
                  cacheGeneration == startingCacheGeneration,
                  authManager.session?.user.userId == expectedUserId
            else {
                throw CancellationError()
            }

            if let freshCatalog {
                mainGames = catalogWithOwnership(
                    freshCatalog,
                    library: authoritativeLibrary
                )
                catalogLoadPhase = .loaded
            } else if !mainGames.isEmpty {
                mainGames = catalogWithOwnership(
                    mainGames,
                    library: authoritativeLibrary
                )
            }
            libraryGames = authoritativeLibrary
            libraryLoadPhase = .loaded
            libraryWarning = freshCatalog == nil
                ? catalogOutcome.errorMessage
                : nil

            let refreshedIds = Set(authoritativeLibrary.map(\.id))
            return LibraryImportResult(
                finalGameCount: authoritativeLibrary.count,
                addedGameIDs: refreshedIds.subtracting(previousIds),
                removedGameIDs: previousIds.subtracting(refreshedIds)
            )
        } catch {
            if persistenceEnabled,
               cacheGeneration == startingCacheGeneration,
               authManager.session?.user.userId == expectedUserId
            {
                libraryGames = previousLibrary
                libraryLoadPhase = previousLibrary.isEmpty
                    ? .failed(error.localizedDescription)
                    : .loaded
                libraryWarning = previousLibrary.isEmpty
                    ? nil
                    : error.localizedDescription
            }
            throw error
        }
    }

    private func fetchAuthoritativeSnapshot(
        token: String,
        base: String,
        vpcId: String?
    ) async throws -> (library: [GameInfo], catalog: GamesFetchOutcome) {
        async let libraryRequest = gamesClient.fetchLibrary(
            token: token,
            streamingBaseUrl: base,
            vpcId: vpcId
        )
        async let catalogRequest = fetchMainOutcome(
            token: token,
            base: base,
            vpcId: vpcId
        )
        return try await (libraryRequest, catalogRequest)
    }

    func refreshActiveSessions(authManager: AuthManager) async {
        let identity = LoadIdentity(
            cacheGeneration: cacheGeneration,
            loadGeneration: loadGeneration
        )
        guard let token = try? await authManager.resolveToken() else { return }
        guard isCurrent(identity) else { return }
        let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
        let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl
        let outcome = await fetchActiveSessionsCoalesced(token: token, base: base)
        guard isCurrent(identity),
              outcome.requestGeneration == activeSessionsRequestGeneration
        else { return }
        activeSessions = filterStopped(outcome.sessions)
    }

    /// Called when the user ends a session: removes it from the UI immediately
    /// and keeps refreshes from re-adding it while the server catches up with
    /// the stop. If the stop actually failed, the session reappears once the
    /// grace window passes — which is the honest outcome.
    func markSessionStopped(_ sessionId: String) {
        recentlyStoppedSessions[sessionId] = Date()
        activeSessions.removeAll { $0.sessionId == sessionId }
    }

    private func filterStopped(_ sessions: [ActiveSessionInfo]) -> [ActiveSessionInfo] {
        recentlyStoppedSessions = recentlyStoppedSessions.filter {
            Date().timeIntervalSince($0.value) < Self.stoppedSessionGracePeriod
        }
        guard !recentlyStoppedSessions.isEmpty else { return sessions }
        return sessions.filter { recentlyStoppedSessions[$0.sessionId] == nil }
    }

    // MARK: Cached Library & Store Derivations

    private func rebuildLibraryDerivations() {
        libraryFilterOptions = GameFilterOptions(
            games: libraryGames,
            favoriteIds: favoriteIds,
            context: .library
        )
        rebuildLibraryFilterBaseCount()
        rebuildFilteredLibraryGames()
    }

    private func rebuildLibraryFilterBaseCount() {
        libraryFilterBaseCount = GameFilterEngine.count(
            in: libraryGames,
            context: .library,
            state: GameFilterState(),
            searchText: librarySearchText,
            favoriteIds: favoriteIds
        )
    }

    private func rebuildFilteredLibraryGames() {
        filteredLibraryGames = filteredGames(
            libraryGames,
            context: .library,
            state: libraryFilterState,
            searchText: librarySearchText,
            sortOrder: librarySortOrder
        )
    }

    private func rebuildStoreDerivations() {
        storeFilterOptions = GameFilterOptions(
            games: mainGames,
            favoriteIds: favoriteIds,
            context: .store
        )
        rebuildStoreFilterBaseCount()
        rebuildFilteredStoreGames()
    }

    private func rebuildStoreFilterBaseCount() {
        storeFilterBaseCount = GameFilterEngine.count(
            in: mainGames,
            context: .store,
            state: GameFilterState(),
            searchText: storeSearchText,
            favoriteIds: favoriteIds
        )
    }

    private func rebuildFilteredStoreGames() {
        filteredStoreGames = filteredGames(
            mainGames,
            context: .store,
            state: storeFilterState,
            searchText: storeSearchText,
            sortOrder: storeSortOrder
        )
    }

    func libraryPreviewCount(for state: GameFilterState) -> Int {
        GameFilterEngine.count(
            in: libraryGames,
            context: .library,
            state: state,
            searchText: librarySearchText,
            favoriteIds: favoriteIds
        )
    }

    func storePreviewCount(for state: GameFilterState) -> Int {
        GameFilterEngine.count(
            in: mainGames,
            context: .store,
            state: state,
            searchText: storeSearchText,
            favoriteIds: favoriteIds
        )
    }

    private func filteredGames(
        _ games: [GameInfo],
        context: GameFilterContext,
        state: GameFilterState,
        searchText: String,
        sortOrder: LibrarySortOrder
    ) -> [GameInfo] {
        GameFilterEngine.apply(
            to: games,
            context: context,
            state: state,
            searchText: searchText,
            sortOrder: sortOrder,
            favoriteIds: favoriteIds,
            recentlyPlayedIds: recentlyPlayedIds
        )
    }

    // MARK: Recently Played

    func recordPlayed(_ game: GameInfo) {
        var ids = recentlyPlayedIds
        ids.removeAll { $0 == game.id }
        ids.insert(game.id, at: 0)
        if ids.count > 10 {
            ids = Array(ids.prefix(10))
        }
        recentlyPlayedIds = ids
        let generation = cacheGeneration
        Task { [weak self] in
            guard let self,
                  persistenceEnabled,
                  cacheGeneration == generation else { return }
            await persistence.saveRecentlyPlayedIds(ids)
        }
    }

    // MARK: Preferred Store

    func setPreferredStore(gameId: String, variantId: String) {
        preferredStoreIds[gameId] = variantId
        let stores = preferredStoreIds
        let generation = cacheGeneration
        Task { [weak self] in
            guard let self,
                  persistenceEnabled,
                  cacheGeneration == generation else { return }
            await persistence.savePreferredStoreIds(stores)
        }
    }

    func preferredVariantId(for game: GameInfo) -> String? {
        preferredStoreIds[game.id] ?? game.variants.first?.id
    }

    func gameWithPreferredStore(_ game: GameInfo) -> GameInfo {
        guard let preferredId = preferredStoreIds[game.id],
              let idx = game.variants.firstIndex(where: { $0.id == preferredId }),
              idx != 0 else { return game }
        var g = game
        let preferred = g.variants.remove(at: idx)
        g.variants.insert(preferred, at: 0)
        return g
    }

    // MARK: Favorites

    func toggleFavorite(_ id: String) {
        if favoriteIds.contains(id) {
            favoriteIds.remove(id)
        } else {
            favoriteIds.insert(id)
        }
        saveFavorites()
    }

    func isFavorite(_ id: String) -> Bool {
        favoriteIds.contains(id)
    }

    // MARK: Persistence

    func saveFavorites() {
        let ids = favoriteIds
        let generation = cacheGeneration
        Task { [weak self] in
            guard let self,
                  persistenceEnabled,
                  cacheGeneration == generation else { return }
            await persistence.saveFavoriteIds(ids)
        }
    }

    func saveSettings() {
        let settings = streamSettings
        let generation = cacheGeneration
        Task { [weak self] in
            guard let self,
                  persistenceEnabled,
                  cacheGeneration == generation else { return }
            await persistence.saveStreamSettings(settings)
        }
    }

    func saveLastSession(_ record: LastSessionRecord) {
        lastSession = record
        let generation = cacheGeneration
        Task { [weak self] in
            guard let self,
                  persistenceEnabled,
                  cacheGeneration == generation else { return }
            await persistence.saveLastSession(record)
        }
    }

    func clearLastSession() {
        lastSession = nil
        let generation = cacheGeneration
        Task { [weak self] in
            guard let self,
                  persistenceEnabled,
                  cacheGeneration == generation else { return }
            await persistence.saveLastSession(nil)
        }
    }

    func prepareForCacheClear() {
        cacheGeneration &+= 1
        ownershipCacheGeneration &+= 1
        loadGeneration &+= 1
        libraryRefreshCoordinator.cancel()
        cancelCoalescedRequests()
    }

    func prepareForLogout() {
        loadGeneration &+= 1
        libraryRefreshCoordinator.cancel()
        cancelCoalescedRequests()
        currentAccountScope = nil
    }

    func prepareForDataReset() {
        cacheGeneration &+= 1
        ownershipCacheGeneration &+= 1
        loadGeneration &+= 1
        persistenceEnabled = false
        libraryRefreshCoordinator.cancel()
        cancelCoalescedRequests()
    }

    func resetAllData() async {
        libraryRefreshCoordinator.cancel()
        mainGames = []
        libraryGames = []
        activeSessions = []
        catalogLoadPhase = .idle
        libraryLoadPhase = .idle
        libraryWarning = nil
        favoriteIds = []
        preferredStoreIds = [:]
        recentlyPlayedIds = []
        streamSettings = StreamSettings().normalizedForClient
        subscription = nil
        resumableSession = nil
        lastSession = nil
        currentVpcId = nil
        currentAccountScope = nil
        latestNetworkLibraryGames = nil
        hasCompletedInitialLoad = false
        recentlyStoppedSessions = [:]
    }

    private func cancelCoalescedRequests() {
        activeSessionsRequestGeneration &+= 1
        activeSessionsRequest?.task.cancel()
        activeSessionsRequest = nil
        vpcIdRequestGeneration &+= 1
        vpcIdRequest?.task.cancel()
        vpcIdRequest = nil
    }

    private func normalizeStreamSettingsForCurrentEntitlements() {
        let resolutions = availableResolutions
        guard !resolutions.isEmpty else { return }

        if !resolutions.contains(streamSettings.resolution) {
            // Keep the tvOS Picker in a valid state if the persisted resolution is no
            // longer entitled. Prefer the highest available value for the account.
            streamSettings.resolution = resolutions.last ?? resolutions[0]
        }

        let fpsValues = availableFps
        if !fpsValues.contains(streamSettings.fps), let fallbackFPS = fpsValues.last {
            streamSettings.fps = fallbackFPS
        }
    }
}
