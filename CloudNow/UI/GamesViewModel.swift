import Foundation
import Observation
import UIKit

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

struct LastSessionRecord: Codable {
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

@Observable
@MainActor
class GamesViewModel {
    var mainGames: [GameInfo] = []
    var libraryGames: [GameInfo] = []
    var activeSessions: [ActiveSessionInfo] = []
    var isLoading = false
    var isLibraryLoading = false
    var error: String?
    var libraryError: String?
    var libraryWarning: String?

    var favoriteIds: Set<String> = []
    var preferredStoreIds: [String: String] = [:]
    var recentlyPlayedIds: [String] = []
    var streamSettings: StreamSettings = .init()
    var subscription: SubscriptionInfo?
    /// Session the user left without ending — available to resume for ~2 minutes.
    var resumableSession: ResumableSession?
    /// Last created session, persisted so we can resume/stop it across app launches.
    var lastSession: LastSessionRecord?
    /// Top 5 lowest-latency zones, populated on launch.
    var topZones: [GFNZone] = []

    private let gamesClient = GamesClient()
    private let cloudMatchClient = CloudMatchClient()

    init() {
        if let data = UserDefaults.standard.data(forKey: "gfn.favoriteIds"),
           let ids = try? JSONDecoder().decode([String].self, from: data)
        {
            favoriteIds = Set(ids)
        }
        if let data = UserDefaults.standard.data(forKey: "gfn.preferredStores"),
           let stores = try? JSONDecoder().decode([String: String].self, from: data)
        {
            preferredStoreIds = stores
        }
        if let data = UserDefaults.standard.data(forKey: "gfn.recentlyPlayed"),
           let ids = try? JSONDecoder().decode([String].self, from: data)
        {
            recentlyPlayedIds = ids
        }
        if let data = UserDefaults.standard.data(forKey: "gfn.streamSettings"),
           let settings = try? JSONDecoder().decode(StreamSettings.self, from: data)
        {
            streamSettings = settings
        }
        if let data = UserDefaults.standard.data(forKey: "gfn.lastSession"),
           let session = try? JSONDecoder().decode(LastSessionRecord.self, from: data)
        {
            lastSession = session
        }
        // tvOS currently caps at 60 Hz; clamp any saved value to the screen maximum.
        // If Apple raises the cap in a future tvOS release this will automatically unlock.
        let screenMax = (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.maximumFramesPerSecond) ?? 60
        if streamSettings.fps > screenMax {
            streamSettings.fps = screenMax
        }
        streamSettings = streamSettings.normalizedForClient
        print(
            "[Localization] preferred=\(Locale.preferredLanguages.first ?? "nil") ui=\(L10n.localeCode) keyboard=\(streamSettings.keyboardLayout) gameLanguage=\(streamSettings.gameLanguage) effectiveGameLanguage=\(streamSettings.effectiveGameLanguage)"
        )
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

    private static let libraryCacheKey = "gfn.cache.libraryGames.v2"

    func load(authManager: AuthManager) async {
        // Invalidate stale v1 cache from the old panels API
        UserDefaults.standard.removeObject(forKey: "gfn.cache.mainGames")
        UserDefaults.standard.removeObject(forKey: "gfn.cache.libraryGames")

        // Show cached library instantly (catalog is too large to cache)
        if libraryGames.isEmpty, let cached = loadCache(Self.libraryCacheKey, as: [GameInfo].self) {
            libraryGames = cached
        }
        let hadCache = !libraryGames.isEmpty
        isLoading = !hadCache
        error = nil
        libraryError = nil

        do {
            let token = try await authManager.resolveToken()
            let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
            let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl

            // Fetch main games, library, active sessions, and subscription in parallel
            async let mainTask = gamesClient.fetchMainGames(token: token, streamingBaseUrl: base)
            async let libraryTask = fetchLibrarySafe(token: token, base: base)
            async let sessionsTask = fetchSessionsSafe(token: token, base: base)
            async let subTask = fetchSubscriptionSafe(authManager: authManager, token: token, base: base)

            let fetchedMain = try await mainTask
            let panelLibrary = await libraryTask
            activeSessions = await sessionsTask
            let sub = await subTask
            if let sub {
                print("[MES] tier=\(sub.membershipTier) resolutions=\(sub.entitledResolutions.map(\.resolutionLabel))")
                subscription = sub
                normalizeStreamSettingsForCurrentEntitlements()
            }

            mainGames = fetchedMain
            let catalogOwned = fetchedMain.filter(\.isInLibrary)
            var merged = panelLibrary
            var seen = Set(panelLibrary.map(\.id))
            for game in catalogOwned where seen.insert(game.id).inserted {
                merged.append(game)
            }
            libraryGames = merged

            // Only cache library (small); catalog is too large for tvOS UserDefaults
            saveCache(Self.libraryCacheKey, data: merged)
        } catch {
            if !hadCache { self.error = error.localizedDescription }
        }
        isLibraryLoading = false
        isLoading = false
    }

    private func fetchLibrarySafe(token: String, base: String) async -> [GameInfo] {
        await (try? gamesClient.fetchLibrary(token: token, streamingBaseUrl: base)) ?? []
    }

    private func fetchSessionsSafe(token: String, base: String) async -> [ActiveSessionInfo] {
        await (try? cloudMatchClient.getActiveSessions(token: token, base: base)) ?? []
    }

    private func fetchSubscriptionSafe(authManager: AuthManager, token: String, base: String) async -> SubscriptionInfo? {
        guard let userId = authManager.session?.user.userId else { return nil }
        let vpcId = await (try? MESClient.shared.fetchVpcId(token: token, base: base)) ?? ""
        return try? await MESClient.shared.fetchSubscription(token: token, vpcId: vpcId, userId: userId)
    }

    private func loadCache<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func saveCache(_ key: String, data: some Encodable) {
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    func refreshLibrary(authManager: AuthManager) async {
        guard !isLibraryLoading else { return }
        isLibraryLoading = true
        libraryError = nil
        defer { isLibraryLoading = false }

        do {
            let token = try await authManager.resolveToken()
            let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
            let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl
            libraryGames = try await gamesClient.fetchLibrary(token: token, streamingBaseUrl: base)
            saveCache(Self.libraryCacheKey, data: libraryGames)
        } catch {
            libraryError = error.localizedDescription
        }
    }

    func refreshActiveSessions(authManager: AuthManager) async {
        guard let token = try? await authManager.resolveToken() else { return }
        let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
        let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl
        activeSessions = await (try? cloudMatchClient.getActiveSessions(token: token, base: base)) ?? []
    }

    // MARK: Recently Played

    func recordPlayed(_ game: GameInfo) {
        recentlyPlayedIds.removeAll { $0 == game.id }
        recentlyPlayedIds.insert(game.id, at: 0)
        if recentlyPlayedIds.count > 10 { recentlyPlayedIds = Array(recentlyPlayedIds.prefix(10)) }
        let data = try? JSONEncoder().encode(recentlyPlayedIds)
        UserDefaults.standard.set(data, forKey: "gfn.recentlyPlayed")
    }

    // MARK: Preferred Store

    func setPreferredStore(gameId: String, variantId: String) {
        preferredStoreIds[gameId] = variantId
        let data = try? JSONEncoder().encode(preferredStoreIds)
        UserDefaults.standard.set(data, forKey: "gfn.preferredStores")
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
        let data = try? JSONEncoder().encode(Array(favoriteIds))
        UserDefaults.standard.set(data, forKey: "gfn.favoriteIds")
    }

    func saveSettings() {
        let data = try? JSONEncoder().encode(streamSettings)
        UserDefaults.standard.set(data, forKey: "gfn.streamSettings")
    }

    func saveLastSession(_ record: LastSessionRecord) {
        lastSession = record
        let data = try? JSONEncoder().encode(record)
        UserDefaults.standard.set(data, forKey: "gfn.lastSession")
    }

    func clearLastSession() {
        lastSession = nil
        UserDefaults.standard.removeObject(forKey: "gfn.lastSession")
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
        guard let zones = try? await ZoneClient.shared.fetchZones() else { return }
        var measured = zones
        await withTaskGroup(of: (String, Int?).self) { group in
            for zone in zones {
                group.addTask {
                    let ping = await ZoneClient.shared.measurePing(to: zone.zoneUrl)
                    return (zone.id, ping)
                }
            }
            for await (id, ping) in group {
                if let idx = measured.firstIndex(where: { $0.id == id }) {
                    measured[idx].pingMs = ping
                    measured[idx].isMeasuring = false
                }
            }
        }
        let reachable = measured.filter { $0.pingMs != nil }
        let isUnlimited = subscription?.isUnlimited ?? false
        topZones = Array(reachable
            .sorted { autoZoneScore($0, maxPing: reachable, maxQueue: reachable, isUnlimited: isUnlimited) <
                autoZoneScore($1, maxPing: reachable, maxQueue: reachable, isUnlimited: isUnlimited)
            }
            .prefix(5))
        print("[Zones] top 5: \(topZones.map { "\($0.id) ping=\($0.pingMs!)ms queue=\($0.queuePosition)" }.joined(separator: ", "))")
    }

    func bestZoneUrl() async -> String? {
        guard !topZones.isEmpty else { return nil }
        // Re-ping candidates and refresh queue data for current conditions
        var refreshed = topZones
        if let freshZones = try? await ZoneClient.shared.fetchZones() {
            let queueLookup = Dictionary(uniqueKeysWithValues: freshZones.map { ($0.id, $0.queuePosition) })
            for i in refreshed.indices {
                if let q = queueLookup[refreshed[i].id] {
                    refreshed[i].queuePosition = q
                }
            }
        }
        await withTaskGroup(of: (String, Int?).self) { group in
            for zone in refreshed {
                group.addTask {
                    let ping = await ZoneClient.shared.measurePing(to: zone.zoneUrl)
                    return (zone.id, ping)
                }
            }
            for await (id, ping) in group {
                if let idx = refreshed.firstIndex(where: { $0.id == id }) {
                    refreshed[idx].pingMs = ping
                }
            }
        }
        let reachable = refreshed.filter { $0.pingMs != nil }
        let isUnlimited = subscription?.isUnlimited ?? false
        let best = reachable.autoZone(isUnlimited: isUnlimited)
        if let best {
            print("[Zones] best at launch: \(best.zoneUrl) (ping=\(best.pingMs!)ms queue=\(best.queuePosition), unlimited=\(isUnlimited))")
        }
        return best?.zoneUrl
    }

    private func autoZoneScore(_ zone: GFNZone, maxPing: [GFNZone], maxQueue: [GFNZone], isUnlimited: Bool) -> Double {
        if isUnlimited { return Double(zone.pingMs ?? .max) }
        let mp = Double(Swift.max(maxPing.compactMap(\.pingMs).max() ?? 1, 1))
        let mq = Double(Swift.max(maxQueue.map(\.queuePosition).max() ?? 1, 1))
        return (Double(zone.pingMs ?? Int(mp)) / mp) * 0.4 + (Double(zone.queuePosition) / mq) * 0.6
    }
}
