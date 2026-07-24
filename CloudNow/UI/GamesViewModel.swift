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
    private var persistenceEnabled = true
    private var cacheGeneration = 0
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
        persistence: any GamesPersistence = AppPersistenceStore.shared
    ) {
        self.gamesClient = gamesClient
        self.cloudMatchClient = cloudMatchClient
        self.membershipClient = membershipClient
        self.persistence = persistence
        self.persistenceEnabled = persistenceEnabled
        self.mainGames = mainGames
        self.libraryGames = libraryGames
        self.favoriteIds = favoriteIds
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
        let snapshot = await persistence.loadGamesSnapshot()
        guard isCurrent(identity) else { return }
        let catalogLocaleCode = L10n.nvidiaLocaleCode()
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
                vpcId: snapshot.vpcId ?? "GFN-PC"
            )
            guard isCurrent(identity) else { return }
            if let cachedCatalog {
                mainGames = cachedCatalog
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
                identity: identity
            )
            async let libraryUpdate: Void = loadLibraryFromNetwork(
                token: token,
                base: base,
                vpcId: vpcId,
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
            return GamesFetchOutcome(games: games, errorMessage: nil)
        } catch {
            return GamesFetchOutcome(games: nil, errorMessage: error.localizedDescription)
        }
    }

    private func fetchLibraryOutcome(token: String, base: String, vpcId: String?) async -> GamesFetchOutcome {
        do {
            let games = try await gamesClient.fetchLibrary(token: token, streamingBaseUrl: base, vpcId: vpcId)
            return GamesFetchOutcome(games: games, errorMessage: nil)
        } catch {
            return GamesFetchOutcome(games: nil, errorMessage: error.localizedDescription)
        }
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
        identity: LoadIdentity
    ) async {
        let outcome = await fetchMainOutcome(token: token, base: base, vpcId: vpcId)
        guard isCurrent(identity) else { return }
        guard let fetchedMain = outcome.games else {
            catalogLoadPhase = mainGames.isEmpty
                ? .failed(outcome.errorMessage ?? L10n.text("failed_to_load_games"))
                : .loaded
            return
        }

        mainGames = fetchedMain
        catalogLoadPhase = .loaded
        await persistence.saveCatalog(
            fetchedMain,
            localeCode: localeCode,
            vpcId: vpcId
        )
        guard isCurrent(identity) else { return }

        // If the library request completed first, fold in catalog ownership now.
        let merged = mergeLibrary(
            latestNetworkLibraryGames ?? libraryGames,
            catalog: fetchedMain
        )
        if merged != libraryGames {
            libraryGames = merged
            await persistence.saveLibraryGames(merged)
            guard isCurrent(identity) else { return }
        }
    }

    private func loadLibraryFromNetwork(
        token: String,
        base: String,
        vpcId: String?,
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
        let merged = mergeLibrary(panelLibrary, catalog: mainGames)
        libraryGames = merged
        libraryLoadPhase = .loaded
        await persistence.saveLibraryGames(merged)
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

    private func mergeLibrary(_ panelLibrary: [GameInfo], catalog: [GameInfo]) -> [GameInfo] {
        var merged = panelLibrary
        var seen = Set(panelLibrary.map(\.id))
        for game in catalog where game.isInLibrary && seen.insert(game.id).inserted {
            merged.append(game)
        }
        return merged
    }

    func refreshLibrary(authManager: AuthManager) async {
        guard libraryLoadPhase != .loading, hasCompletedInitialLoad else { return }
        let identity = beginLoad()
        libraryLoadPhase = .loading
        libraryWarning = nil

        do {
            let token = try await authManager.resolveToken()
            guard isCurrent(identity) else { return }
            let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
            let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl
            let refreshed = try await gamesClient.fetchLibrary(token: token, streamingBaseUrl: base, vpcId: currentVpcId)
            guard isCurrent(identity) else { return }
            libraryGames = mergeLibrary(refreshed, catalog: mainGames)
            libraryLoadPhase = .loaded
            await persistence.saveLibraryGames(libraryGames)
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
        loadGeneration &+= 1
        cancelCoalescedRequests()
    }

    func prepareForDataReset() {
        cacheGeneration &+= 1
        loadGeneration &+= 1
        persistenceEnabled = false
        cancelCoalescedRequests()
    }

    func resetAllData() async {
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
