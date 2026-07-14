import Foundation

/// Serializes disk, UserDefaults, JSON, and Keychain work away from the UI actor.
actor AppPersistenceStore {
    static let shared = AppPersistenceStore()

    struct GamesSnapshot {
        var favoriteIds: Set<String> = []
        var preferredStoreIds: [String: String] = [:]
        var recentlyPlayedIds: [String] = []
        var streamSettings: StreamSettings?
        var lastSession: LastSessionRecord?
        var libraryGames: [GameInfo] = []
        var subscription: SubscriptionInfo?
        var vpcId: String?
    }

    private struct CatalogCacheEnvelope: Codable {
        let schemaVersion: Int
        let localeCode: String
        let vpcId: String?
        let games: [GameInfo]
    }

    private enum Key {
        static let favoriteIds = "gfn.favoriteIds"
        static let preferredStores = "gfn.preferredStores"
        static let recentlyPlayed = "gfn.recentlyPlayed"
        static let streamSettings = "gfn.streamSettings"
        static let lastSession = "gfn.lastSession"
        static let legacyLibraryGames = "gfn.cache.libraryGames.v2"
        static let subscription = "gfn.cache.subscription.v1"
        static let vpcId = "gfn.cache.vpcId"
    }

    private let defaults = UserDefaults.standard

    func loadGamesSnapshot() -> GamesSnapshot {
        // Library metadata can exceed tvOS's per-value UserDefaults limit.
        // Remove the retired preference before reading the file-backed cache.
        defaults.removeObject(forKey: Key.legacyLibraryGames)

        var snapshot = GamesSnapshot()
        snapshot.favoriteIds = Set(decode([String].self, forKey: Key.favoriteIds) ?? [])
        snapshot.preferredStoreIds = decode([String: String].self, forKey: Key.preferredStores) ?? [:]
        snapshot.recentlyPlayedIds = decode([String].self, forKey: Key.recentlyPlayed) ?? []
        snapshot.streamSettings = decode(StreamSettings.self, forKey: Key.streamSettings)
        snapshot.lastSession = decode(LastSessionRecord.self, forKey: Key.lastSession)
        snapshot.libraryGames = loadLibraryGames()
        snapshot.subscription = decode(SubscriptionInfo.self, forKey: Key.subscription)
        snapshot.vpcId = defaults.string(forKey: Key.vpcId)

        // Remove caches written by the retired panels API.
        defaults.removeObject(forKey: "gfn.cache.mainGames")
        defaults.removeObject(forKey: "gfn.cache.libraryGames")
        return snapshot
    }

    func saveFavoriteIds(_ ids: Set<String>) {
        encode(Array(ids), forKey: Key.favoriteIds)
    }

    func savePreferredStoreIds(_ stores: [String: String]) {
        encode(stores, forKey: Key.preferredStores)
    }

    func saveRecentlyPlayedIds(_ ids: [String]) {
        encode(ids, forKey: Key.recentlyPlayed)
    }

    func saveStreamSettings(_ settings: StreamSettings) {
        encode(settings, forKey: Key.streamSettings)
    }

    func saveLastSession(_ session: LastSessionRecord?) {
        guard let session else {
            defaults.removeObject(forKey: Key.lastSession)
            return
        }
        encode(session, forKey: Key.lastSession)
    }

    func saveLibraryGames(_ games: [GameInfo]) {
        guard let url = libraryCacheURL,
              let data = try? JSONEncoder().encode(games)
        else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    func saveSubscription(_ subscription: SubscriptionInfo) {
        encode(subscription, forKey: Key.subscription)
    }

    func saveVpcId(_ vpcId: String) {
        defaults.set(vpcId, forKey: Key.vpcId)
    }

    func loadCatalog(localeCode: String, vpcId: String?) -> [GameInfo]? {
        removeLegacyCatalogCache()
        guard let url = catalogCacheURL(localeCode: localeCode, vpcId: vpcId),
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(CatalogCacheEnvelope.self, from: data),
              envelope.schemaVersion == 2,
              envelope.localeCode == localeCode,
              envelope.vpcId == vpcId,
              !envelope.games.isEmpty
        else {
            return nil
        }
        return envelope.games
    }

    func saveCatalog(_ games: [GameInfo], localeCode: String, vpcId: String?) {
        guard !games.isEmpty,
              let url = catalogCacheURL(localeCode: localeCode, vpcId: vpcId),
              let data = try? JSONEncoder().encode(CatalogCacheEnvelope(
                  schemaVersion: 2,
                  localeCode: localeCode,
                  vpcId: vpcId,
                  games: games
              ))
        else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    func loadAuthSession() throws -> AuthSession {
        let data = try KeychainService.load()
        return try JSONDecoder().decode(AuthSession.self, from: data)
    }

    func saveAuthSession(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        try KeychainService.save(data)
    }

    func deleteAuthSession() {
        KeychainService.delete()
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode(_ value: some Encodable, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func catalogCacheURL(localeCode: String, vpcId: String?) -> URL? {
        let rawKey = "\(localeCode)\u{1F}\(vpcId ?? "default")"
        let safeKey = Data(rawKey.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("gfn.catalog.v2.\(safeKey).json")
    }

    private var libraryCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("gfn.library.v1.json")
    }

    private func loadLibraryGames() -> [GameInfo] {
        guard let url = libraryCacheURL,
              let data = try? Data(contentsOf: url),
              let games = try? JSONDecoder().decode([GameInfo].self, from: data)
        else {
            return []
        }
        return games
    }

    private func removeLegacyCatalogCache() {
        guard let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("gfn.catalog.v1.json")
        else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }
}
