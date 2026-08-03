import Foundation

nonisolated protocol SecureCredentialStore: Sendable {
    func load() throws -> Data
    func save(_ data: Data) throws
    func delete() throws
}

nonisolated struct KeychainCredentialStore: SecureCredentialStore {
    func load() throws -> Data {
        try KeychainService.load()
    }

    func save(_ data: Data) throws {
        try KeychainService.save(data)
    }

    func delete() throws {
        KeychainService.delete()
    }
}

nonisolated protocol PreferencesStore: Sendable {
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func setData(_ data: Data, forKey key: String)
    func setString(_ value: String, forKey key: String)
    func removeObject(forKey key: String)
    func keys() -> [String]
}

/// `UserDefaults` is documented as thread-safe but is not annotated `Sendable`.
/// This narrow adapter keeps the unchecked boundary in one place and exposes
/// only the value types used by persistence.
final nonisolated class UserDefaultsPreferencesStore: PreferencesStore, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func setData(_ data: Data, forKey key: String) {
        defaults.set(data, forKey: key)
    }

    func setString(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }

    func keys() -> [String] {
        Array(defaults.dictionaryRepresentation().keys)
    }
}

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
        var ownershipCacheGeneration: UInt64 = 0
    }

    private struct LibraryCacheEnvelope: Codable {
        let schemaVersion: Int
        let accountScope: String
        let games: [GameInfo]
    }

    private struct CatalogCacheEnvelope: Codable {
        let schemaVersion: Int
        let localeCode: String
        let vpcId: String?
        let games: [GameInfo]
    }

    private enum PersistenceError: Error {
        case cacheUnavailable
        case invalidAccountScope
        case staleOwnershipCacheGeneration
    }

    private struct GameMetadataCacheEnvelope: Codable {
        let schemaVersion: Int
        let localeCode: String
        let vpcId: String
        let entries: [String: GameMetadataCacheEntry]
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

    private let preferences: any PreferencesStore
    private let cacheDirectory: URL?
    private let fileManager: FileManager
    private let credentialStore: any SecureCredentialStore
    private var gameMetadataCacheGeneration: UInt64 = 0
    private var ownershipCacheGeneration: UInt64 = 0
    private var authCredentialGeneration: UInt64 = 0

    init(
        preferences: any PreferencesStore = UserDefaultsPreferencesStore(),
        cacheDirectory: URL? = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first,
        fileManager: FileManager = .default,
        credentialStore: any SecureCredentialStore = KeychainCredentialStore()
    ) {
        self.preferences = preferences
        self.cacheDirectory = cacheDirectory
        self.fileManager = fileManager
        self.credentialStore = credentialStore
    }

    func loadGamesSnapshot(accountScope: String?) -> GamesSnapshot {
        // Library metadata can exceed tvOS's per-value UserDefaults limit.
        // Remove the retired preference before reading the file-backed cache.
        preferences.removeObject(forKey: Key.legacyLibraryGames)

        var snapshot = GamesSnapshot()
        snapshot.favoriteIds = Set(decode([String].self, forKey: Key.favoriteIds) ?? [])
        snapshot.preferredStoreIds = decode([String: String].self, forKey: Key.preferredStores) ?? [:]
        snapshot.recentlyPlayedIds = decode([String].self, forKey: Key.recentlyPlayed) ?? []
        snapshot.streamSettings = decode(StreamSettings.self, forKey: Key.streamSettings)
        snapshot.lastSession = decode(LastSessionRecord.self, forKey: Key.lastSession)
        snapshot.libraryGames = loadLibraryGames(accountScope: accountScope)
        snapshot.subscription = decode(SubscriptionInfo.self, forKey: Key.subscription)
        snapshot.vpcId = preferences.string(forKey: Key.vpcId)
        snapshot.ownershipCacheGeneration = ownershipCacheGeneration

        // Remove caches written by the retired panels API.
        preferences.removeObject(forKey: "gfn.cache.mainGames")
        preferences.removeObject(forKey: "gfn.cache.libraryGames")
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
            preferences.removeObject(forKey: Key.lastSession)
            return
        }
        encode(session, forKey: Key.lastSession)
    }

    func saveLibraryGames(
        _ games: [GameInfo],
        accountScope: String?,
        expectedGeneration: UInt64
    ) {
        guard expectedGeneration == ownershipCacheGeneration,
              let accountScope = safeAccountScope(accountScope)
        else {
            return
        }
        try? writeLibraryGames(games, accountScope: accountScope)
    }

    func saveSubscription(_ subscription: SubscriptionInfo) {
        encode(subscription, forKey: Key.subscription)
    }

    func saveVpcId(_ vpcId: String) {
        preferences.setString(vpcId, forKey: Key.vpcId)
    }

    func loadCatalog(
        localeCode: String,
        vpcId: String?,
        accountScope _: String?
    ) -> [GameInfo]? {
        removeLegacyOwnershipCaches()
        guard let url = catalogCacheURL(
            localeCode: localeCode,
            vpcId: vpcId
        ),
            let data = try? Data(contentsOf: url),
            let envelope = try? JSONDecoder().decode(CatalogCacheEnvelope.self, from: data),
            envelope.schemaVersion == 3,
            envelope.localeCode == localeCode,
            envelope.vpcId == vpcId,
            !envelope.games.isEmpty,
            isAccountNeutralCatalog(envelope.games)
        else {
            return nil
        }
        return envelope.games
    }

    func saveCatalog(
        _ games: [GameInfo],
        localeCode: String,
        vpcId: String?,
        accountScope _: String?,
        expectedGeneration: UInt64
    ) {
        guard expectedGeneration == ownershipCacheGeneration,
              !games.isEmpty
        else {
            return
        }
        try? writeCatalog(
            games,
            localeCode: localeCode,
            vpcId: vpcId
        )
    }

    func saveRefreshedLibrarySnapshot(
        libraryGames: [GameInfo],
        catalogGames: [GameInfo]?,
        localeCode: String,
        vpcId: String?,
        accountScope: String,
        expectedGeneration: UInt64
    ) throws {
        guard expectedGeneration == ownershipCacheGeneration else {
            throw PersistenceError.staleOwnershipCacheGeneration
        }
        guard let accountScope = safeAccountScope(accountScope) else {
            throw PersistenceError.invalidAccountScope
        }
        try writeLibraryGames(libraryGames, accountScope: accountScope)
        if let catalogGames, !catalogGames.isEmpty {
            try? writeCatalog(
                catalogGames,
                localeCode: localeCode,
                vpcId: vpcId
            )
        }
    }

    func currentGameMetadataCacheGeneration() -> UInt64 {
        gameMetadataCacheGeneration
    }

    func loadGameMetadataCache(
        localeCode: String,
        vpcId: String
    ) -> GameMetadataCacheSnapshot {
        let entries: [String: GameMetadataCacheEntry] = if let url = gameMetadataCacheURL(
            localeCode: localeCode,
            vpcId: vpcId
        ),
            let data = try? Data(contentsOf: url),
            let envelope = try? JSONDecoder().decode(
                GameMetadataCacheEnvelope.self,
                from: data
            ),
            envelope.schemaVersion == 1,
            envelope.localeCode == localeCode,
            envelope.vpcId == vpcId
        {
            envelope.entries
        } else {
            [:]
        }
        return GameMetadataCacheSnapshot(
            entries: entries,
            generation: gameMetadataCacheGeneration
        )
    }

    /// Merges updates inside the persistence actor so overlapping client
    /// instances cannot replace one another's entries with stale snapshots.
    func mergeGameMetadataCache(
        _ updates: [String: GameMetadataCacheEntry],
        localeCode: String,
        vpcId: String,
        pruningBefore: Date,
        maximumEntryCount: Int,
        expectedGeneration: UInt64
    ) {
        guard !updates.isEmpty,
              expectedGeneration == gameMetadataCacheGeneration
        else {
            return
        }
        var entries = loadGameMetadataCache(
            localeCode: localeCode,
            vpcId: vpcId
        ).entries
        entries.merge(updates) { current, updated in
            if current.refreshedAt != updated.refreshedAt {
                return current.refreshedAt > updated.refreshedAt
                    ? current
                    : updated
            }
            if current.metadata != nil, updated.metadata == nil {
                return current
            }
            return updated
        }
        let retained = entries
            .filter { $0.value.refreshedAt >= pruningBefore }
            .sorted {
                if $0.value.refreshedAt == $1.value.refreshedAt {
                    return $0.key < $1.key
                }
                return $0.value.refreshedAt > $1.value.refreshedAt
            }
            .prefix(max(0, maximumEntryCount))
        let boundedEntries = Dictionary(
            uniqueKeysWithValues: retained.map { ($0.key, $0.value) }
        )

        guard let url = gameMetadataCacheURL(
            localeCode: localeCode,
            vpcId: vpcId
        ),
            let data = try? JSONEncoder().encode(GameMetadataCacheEnvelope(
                schemaVersion: 1,
                localeCode: localeCode,
                vpcId: vpcId,
                entries: boundedEntries
            ))
        else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    func loadAuthSession() async throws -> AuthSession {
        let data = try credentialStore.load()
        return try JSONDecoder().decode(AuthSession.self, from: data)
    }

    func saveAuthSession(
        _ session: AuthSession,
        generation: UInt64
    ) async throws {
        guard generation >= authCredentialGeneration else {
            return
        }
        let data = try JSONEncoder().encode(session)
        authCredentialGeneration = generation
        try credentialStore.save(data)
    }

    func deleteAuthSession(generation: UInt64) async throws {
        guard generation >= authCredentialGeneration else {
            return
        }
        authCredentialGeneration = generation
        try credentialStore.delete()
    }

    /// Removes cache-backed preferences and files after callers have invalidated
    /// in-flight producers. Running this on the persistence actor serializes the
    /// deletion behind writes that were already submitted.
    func clearCachedData() -> [String] {
        gameMetadataCacheGeneration &+= 1
        ownershipCacheGeneration &+= 1
        [
            "gfn.cache.mainGames",
            "gfn.cache.libraryGames",
            Key.legacyLibraryGames,
            Key.subscription,
            Key.vpcId,
        ].forEach(preferences.removeObject(forKey:))

        guard let cacheDirectory else { return [] }

        let names = (try? fileManager.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        let cacheFiles = names.filter {
            (
                $0.hasPrefix("gfn.catalog.")
                    || $0.hasPrefix("gfn.library.")
                    || $0.hasPrefix("gfn.metadata.")
                    || $0.hasPrefix("gfn.refresh.")
            )
                && $0.hasSuffix(".json")
        }
        var failures: [String] = []
        for name in cacheFiles {
            do {
                try fileManager.removeItem(at: cacheDirectory.appendingPathComponent(name))
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                failures.append(name)
            }
        }
        return failures
    }

    /// Clears every preference and credential after all producers have been
    /// invalidated. Actor serialization prevents an earlier queued write from
    /// restoring data after this deletion completes.
    func clearPersistentData() {
        ownershipCacheGeneration &+= 1
        authCredentialGeneration &+= 1
        for key in preferences.keys() {
            preferences.removeObject(forKey: key)
        }
        try? credentialStore.delete()
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = preferences.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode(_ value: some Encodable, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        preferences.setData(data, forKey: key)
    }

    private func catalogCacheURL(
        localeCode: String,
        vpcId: String?
    ) -> URL? {
        let safeKey = scopedCacheKey(
            localeCode: localeCode,
            vpcId: vpcId
        )
        return cacheDirectory?
            .appendingPathComponent("gfn.catalog.v3.\(safeKey).json")
    }

    private func gameMetadataCacheURL(
        localeCode: String,
        vpcId: String
    ) -> URL? {
        let safeKey = scopedCacheKey(
            localeCode: localeCode,
            vpcId: vpcId
        )
        return cacheDirectory?.appendingPathComponent("gfn.metadata.v1.\(safeKey).json")
    }

    private func scopedCacheKey(
        localeCode: String,
        vpcId: String?
    ) -> String {
        let rawKey = "\(localeCode)\u{1F}\(vpcId ?? "default")"
        return Data(rawKey.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func safeAccountScope(_ accountScope: String?) -> String? {
        let allowedCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        )
        guard let accountScope,
              !accountScope.isEmpty,
              accountScope.unicodeScalars.allSatisfy({
                  allowedCharacters.contains($0)
              })
        else {
            return nil
        }
        return accountScope
    }

    private func libraryCacheURL(accountScope: String) -> URL? {
        cacheDirectory?
            .appendingPathComponent("gfn.library.v2.\(accountScope).json")
    }

    private func loadLibraryGames(accountScope: String?) -> [GameInfo] {
        guard let accountScope = safeAccountScope(accountScope) else {
            return []
        }
        removeLegacyOwnershipCaches()
        guard let url = libraryCacheURL(accountScope: accountScope),
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(
                  LibraryCacheEnvelope.self,
                  from: data
              ),
              envelope.schemaVersion == 2,
              envelope.accountScope == accountScope
        else {
            return []
        }
        return envelope.games
    }

    private func writeLibraryGames(
        _ games: [GameInfo],
        accountScope: String
    ) throws {
        guard let url = libraryCacheURL(accountScope: accountScope) else {
            throw PersistenceError.cacheUnavailable
        }
        let data = try JSONEncoder().encode(LibraryCacheEnvelope(
            schemaVersion: 2,
            accountScope: accountScope,
            games: games
        ))
        try data.write(to: url, options: .atomic)
    }

    private func writeCatalog(
        _ games: [GameInfo],
        localeCode: String,
        vpcId: String?
    ) throws {
        guard let url = catalogCacheURL(
            localeCode: localeCode,
            vpcId: vpcId
        ) else {
            throw PersistenceError.cacheUnavailable
        }
        let data = try JSONEncoder().encode(CatalogCacheEnvelope(
            schemaVersion: 3,
            localeCode: localeCode,
            vpcId: vpcId,
            games: accountNeutralCatalog(games)
        ))
        try data.write(to: url, options: .atomic)
    }

    private func accountNeutralCatalog(_ games: [GameInfo]) -> [GameInfo] {
        games.map { game in
            var game = game
            game.isInLibrary = false
            for index in game.variants.indices {
                game.variants[index].isOwned = false
            }
            return game
        }
    }

    private func isAccountNeutralCatalog(_ games: [GameInfo]) -> Bool {
        games.allSatisfy { game in
            !game.isInLibrary
                && game.variants.allSatisfy { !$0.isOwned }
        }
    }

    private func removeLegacyOwnershipCaches() {
        guard let cacheDirectory else { return }
        let names = (try? fileManager.contentsOfDirectory(
            atPath: cacheDirectory.path
        )) ?? []
        let legacyNames = names.filter {
            $0 == "gfn.library.v1.json"
                || $0 == "gfn.catalog.v1.json"
                || (
                    $0.hasPrefix("gfn.catalog.v2.")
                        && $0.hasSuffix(".json")
                )
                || (
                    $0.hasPrefix("gfn.refresh.")
                        && $0.hasSuffix(".json")
                )
                || isAccountScopedVersion3Catalog($0)
        }
        for name in legacyNames {
            try? fileManager.removeItem(
                at: cacheDirectory.appendingPathComponent(name)
            )
        }
    }

    private func isAccountScopedVersion3Catalog(_ name: String) -> Bool {
        guard name.hasPrefix("gfn.catalog.v3."),
              name.hasSuffix(".json")
        else {
            return false
        }
        let start = name.index(
            name.startIndex,
            offsetBy: "gfn.catalog.v3.".count
        )
        let end = name.index(name.endIndex, offsetBy: -".json".count)
        return name[start ..< end].contains(".")
    }
}
