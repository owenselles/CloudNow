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
    /// Top 5 lowest-latency zones, populated on launch.
    var topZones: [GFNZone] = []

    var librarySearchText = "" {
        didSet { rebuildFilteredLibraryGames() }
    }

    var librarySortOrder: LibrarySortOrder = .default {
        didSet { rebuildFilteredLibraryGames() }
    }

    var libraryFilterState = GameFilterState() {
        didSet { rebuildFilteredLibraryGames() }
    }

    var storeSearchText = "" {
        didSet { rebuildFilteredStoreGames() }
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
    private(set) var storeFilterOptions = GameFilterOptions(
        games: [], favoriteIds: [], context: .store
    )
    private(set) var filteredStoreGames: [GameInfo] = []

    private let gamesClient = GamesClient()
    private let cloudMatchClient = CloudMatchClient()
    private let persistence = AppPersistenceStore.shared
    private var currentVpcId: String?
    private var activeSessionsTask: Task<[ActiveSessionInfo], Never>?
    private var vpcIdRefreshTask: Task<String?, Never>?
    private var latestNetworkLibraryGames: [GameInfo]?

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

    init() {
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

    func load(authManager: AuthManager) async {
        latestNetworkLibraryGames = nil
        let snapshot = await persistence.loadGamesSnapshot()
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
        if mainGames.isEmpty,
           let cachedCatalog = await persistence.loadCatalog(
               localeCode: catalogLocaleCode,
               vpcId: snapshot.vpcId ?? "GFN-PC"
           )
        {
            mainGames = cachedCatalog
        }

        catalogLoadPhase = .loading
        libraryLoadPhase = .loading
        libraryWarning = nil

        do {
            let token = try await authManager.resolveToken()
            let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
            let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl

            // The catalog, library, and subscription queries all need the vpcId;
            // resolve it once up front instead of three times in parallel.
            // A failed server-info lookup still has a well-defined backend fallback.
            // Pass it explicitly so GamesClient does not repeat the same lookup once
            // for the catalog and again for the library.
            let vpcId = await resolveVpcIdCached(snapshot.vpcId, token: token, base: base) ?? "GFN-PC"

            // Each dataset applies its result as soon as that request finishes;
            // a slow catalog no longer holds the library or sessions in loading.
            async let catalogUpdate: Void = loadCatalogFromNetwork(
                token: token,
                base: base,
                vpcId: vpcId,
                localeCode: catalogLocaleCode
            )
            async let libraryUpdate: Void = loadLibraryFromNetwork(token: token, base: base, vpcId: vpcId)
            async let sessionsUpdate: Void = loadActiveSessionsFromNetwork(token: token, base: base)
            async let subscriptionUpdate: Void = loadSubscriptionFromNetwork(
                authManager: authManager,
                token: token,
                vpcId: vpcId
            )
            _ = await (catalogUpdate, libraryUpdate, sessionsUpdate, subscriptionUpdate)
        } catch {
            catalogLoadPhase = mainGames.isEmpty ? .failed(error.localizedDescription) : .loaded
            libraryLoadPhase = libraryGames.isEmpty ? .failed(error.localizedDescription) : .loaded
        }
        hasCompletedInitialLoad = true
    }

    /// Returns the vpcId shared by the launch queries. Uses the value from the
    /// previous launch when available (it changes only if NVIDIA migrates the
    /// account to another region) and revalidates it in the background, so the
    /// launch fetches don't wait a /v2/serverInfo round trip.
    private func resolveVpcIdCached(_ cached: String?, token: String, base: String) async -> String? {
        if let cached, !cached.isEmpty {
            currentVpcId = cached
            Task { [weak self] in
                _ = await self?.refreshVpcId(token: token, base: base)
            }
            return cached
        }

        return await refreshVpcId(token: token, base: base)
    }

    private func refreshVpcId(token: String, base: String) async -> String? {
        if let vpcIdRefreshTask {
            return await vpcIdRefreshTask.value
        }

        let task = Task<String?, Never> {
            await ((try? MESClient.shared.fetchVpcId(token: token, base: base)) ?? nil)
        }
        vpcIdRefreshTask = task
        let fetched = await task.value
        vpcIdRefreshTask = nil
        if let fetched, !fetched.isEmpty {
            currentVpcId = fetched
            await persistence.saveVpcId(fetched)
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

    private func fetchActiveSessionsCoalesced(token: String, base: String) async -> [ActiveSessionInfo] {
        if let activeSessionsTask {
            return await activeSessionsTask.value
        }
        let task = Task<[ActiveSessionInfo], Never> { [cloudMatchClient] in
            await (try? cloudMatchClient.getActiveSessions(token: token, base: base)) ?? []
        }
        activeSessionsTask = task
        let sessions = await task.value
        activeSessionsTask = nil
        return sessions
    }

    private func fetchSubscriptionSafe(authManager: AuthManager, token: String, vpcId: String) async -> SubscriptionInfo? {
        guard let userId = authManager.session?.user.userId else { return nil }
        return try? await MESClient.shared.fetchSubscription(token: token, vpcId: vpcId, userId: userId)
    }

    private func loadCatalogFromNetwork(token: String, base: String, vpcId: String?, localeCode: String) async {
        let outcome = await fetchMainOutcome(token: token, base: base, vpcId: vpcId)
        guard let fetchedMain = outcome.games else {
            catalogLoadPhase = mainGames.isEmpty
                ? .failed(outcome.errorMessage ?? L10n.text("failed_to_load_games"))
                : .loaded
            return
        }

        mainGames = fetchedMain
        catalogLoadPhase = .loaded
        await persistence.saveCatalog(fetchedMain, localeCode: localeCode, vpcId: vpcId)

        // If the library request completed first, fold in catalog ownership now.
        let merged = mergeLibrary(
            latestNetworkLibraryGames ?? libraryGames,
            catalog: fetchedMain
        )
        if merged != libraryGames {
            libraryGames = merged
            await persistence.saveLibraryGames(merged)
        }
    }

    private func loadLibraryFromNetwork(token: String, base: String, vpcId: String?) async {
        let outcome = await fetchLibraryOutcome(token: token, base: base, vpcId: vpcId)
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
    }

    private func loadActiveSessionsFromNetwork(token: String, base: String) async {
        activeSessions = await filterStopped(fetchActiveSessionsCoalesced(token: token, base: base))
    }

    private func loadSubscriptionFromNetwork(authManager: AuthManager, token: String, vpcId: String) async {
        guard let subscription = await fetchSubscriptionSafe(authManager: authManager, token: token, vpcId: vpcId) else {
            return
        }
        gamesLog.info("[MES] tier=\(subscription.membershipTier, privacy: .public) resolutions=\(String(describing: subscription.entitledResolutions.map(\.resolutionLabel)), privacy: .public)")
        self.subscription = subscription
        normalizeStreamSettingsForCurrentEntitlements()
        await persistence.saveSubscription(subscription)
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
        libraryLoadPhase = .loading
        libraryWarning = nil

        do {
            let token = try await authManager.resolveToken()
            let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
            let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl
            let refreshed = try await gamesClient.fetchLibrary(token: token, streamingBaseUrl: base, vpcId: currentVpcId)
            libraryGames = mergeLibrary(refreshed, catalog: mainGames)
            libraryLoadPhase = .loaded
            await persistence.saveLibraryGames(libraryGames)
        } catch {
            if libraryGames.isEmpty {
                libraryLoadPhase = .failed(error.localizedDescription)
            } else {
                libraryLoadPhase = .loaded
                libraryWarning = error.localizedDescription
            }
        }
    }

    func refreshActiveSessions(authManager: AuthManager) async {
        guard let token = try? await authManager.resolveToken() else { return }
        let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
        let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl
        activeSessions = await filterStopped(fetchActiveSessionsCoalesced(token: token, base: base))
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
        rebuildFilteredLibraryGames()
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
        rebuildFilteredStoreGames()
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
        filteredGames(
            libraryGames,
            context: .library,
            state: state,
            searchText: librarySearchText,
            sortOrder: librarySortOrder
        ).count
    }

    func storePreviewCount(for state: GameFilterState) -> Int {
        filteredGames(
            mainGames,
            context: .store,
            state: state,
            searchText: storeSearchText,
            sortOrder: storeSortOrder
        ).count
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
        if ids.count > 10 { ids = Array(ids.prefix(10)) }
        recentlyPlayedIds = ids
        Task { await persistence.saveRecentlyPlayedIds(ids) }
    }

    // MARK: Preferred Store

    func setPreferredStore(gameId: String, variantId: String) {
        preferredStoreIds[gameId] = variantId
        let stores = preferredStoreIds
        Task { await persistence.savePreferredStoreIds(stores) }
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
        Task { await persistence.saveFavoriteIds(ids) }
    }

    func saveSettings() {
        let settings = streamSettings
        Task { await persistence.saveStreamSettings(settings) }
    }

    func saveLastSession(_ record: LastSessionRecord) {
        lastSession = record
        Task { await persistence.saveLastSession(record) }
    }

    func clearLastSession() {
        lastSession = nil
        Task { await persistence.saveLastSession(nil) }
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

    // MARK: Zone Auto-Selection

    func measureTopZones() async {
        let measured = await ZoneClient.shared.prewarmAutomaticRouting()
        let reachable = measured.filter { $0.pingMs != nil }
        let isUnlimited = subscription?.isUnlimited ?? false
        topZones = Array(reachable
            .sorted { autoZoneScore($0, maxPing: reachable, maxQueue: reachable, isUnlimited: isUnlimited) <
                autoZoneScore($1, maxPing: reachable, maxQueue: reachable, isUnlimited: isUnlimited)
            }
            .prefix(5))
        let measuredTop = topZones
        gamesLog.info("[Zones] top 5: \(measuredTop.map { "\($0.id) ping=\($0.pingMs!)ms queue=\($0.queuePosition)" }.joined(separator: ", "), privacy: .public)")
    }

    func bestZoneUrl() async -> String? {
        let isUnlimited = subscription?.isUnlimited ?? false
        if let cached = await ZoneClient.shared.cachedAutomaticZoneUrl(isUnlimited: isUnlimited) {
            gamesLog.info("[Zones] using prewarmed automatic route: \(cached, privacy: .public) unlimited=\(isUnlimited, privacy: .public)")
            return cached
        }

        // Never put fresh HTTP probes on the launch path. If prewarming has not
        // completed yet, use its best in-memory result or preserve NVIDIA routing.
        return topZones.autoZone(isUnlimited: isUnlimited)?.zoneUrl
    }

    private func autoZoneScore(_ zone: GFNZone, maxPing: [GFNZone], maxQueue: [GFNZone], isUnlimited: Bool) -> Double {
        if isUnlimited { return Double(zone.pingMs ?? .max) }
        let mp = Double(Swift.max(maxPing.compactMap(\.pingMs).max() ?? 1, 1))
        let mq = Double(Swift.max(maxQueue.map(\.queuePosition).max() ?? 1, 1))
        return (Double(zone.pingMs ?? Int(mp)) / mp) * 0.4 + (Double(zone.queuePosition) / mq) * 0.6
    }
}
