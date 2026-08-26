import CryptoKit
import Foundation
import Synchronization

nonisolated protocol SecureCredentialStore: Sendable {
    func load() throws -> Data
    func save(_ data: Data) throws
    func delete() throws
}

nonisolated protocol PreferencesStore: Sendable {
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func setData(_ data: Data, forKey key: String)
    func setString(_ value: String, forKey key: String)
    func removeObject(forKey key: String)
    func keys() -> [String]
}

nonisolated struct CloudCatalogActivitySnapshot: Codable, Equatable, Sendable {
    static let maximumFavoriteCount = XboxCatalogSnapshot.maximumRetainedItemCount
    static let maximumRecentlyPlayedCount = 10

    var favoriteIDs: Set<String> = []
    var recentlyPlayedIDs: [String] = []

    init(
        favoriteIDs: Set<String> = [],
        recentlyPlayedIDs: [String] = []
    ) {
        var seenRecentlyPlayedIDs: Set<String> = []
        let normalizedFavoriteIDs = favoriteIDs
            .compactMap(Self.normalizedGameID)
            .sorted()
        self.favoriteIDs = Set(
            normalizedFavoriteIDs.prefix(Self.maximumFavoriteCount)
        )
        self.recentlyPlayedIDs = recentlyPlayedIDs
            .compactMap(Self.normalizedGameID)
            .filter { seenRecentlyPlayedIDs.insert($0).inserted }
            .prefix(Self.maximumRecentlyPlayedCount)
            .map { $0 }
    }

    fileprivate var normalized: Self {
        Self(
            favoriteIDs: favoriteIDs,
            recentlyPlayedIDs: recentlyPlayedIDs
        )
    }

    private static func normalizedGameID(_ gameID: String) -> String? {
        let gameID = gameID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gameID.isEmpty, gameID.utf8.count <= 512 else { return nil }
        return gameID.uppercased()
    }
}

nonisolated struct CloudCatalogActivityLease: Equatable, Sendable {
    let snapshot: CloudCatalogActivitySnapshot
    let generation: UInt64
}

nonisolated protocol XboxCatalogActivityPersistence: Sendable {
    func loadXboxCatalogActivityLease(
        accountScope: String?
    ) async -> CloudCatalogActivityLease
    func saveXboxFavoriteIDs(
        _ favoriteIDs: Set<String>,
        accountScope: String?,
        expectedGeneration: UInt64
    ) async
    func saveXboxRecentlyPlayedIDs(
        _ recentlyPlayedIDs: [String],
        accountScope: String?,
        expectedGeneration: UInt64
    ) async
}

nonisolated struct PersistentDataClearResult: Equatable, Sendable {
    let geForceNowCredentialsRemoved: Bool
    let xboxCredentialsRemoved: Bool

    var isComplete: Bool {
        geForceNowCredentialsRemoved && xboxCredentialsRemoved
    }

    var failedCredentialStoreCount: Int {
        (geForceNowCredentialsRemoved ? 0 : 1)
            + (xboxCredentialsRemoved ? 0 : 1)
    }

    var failureDescription: String? {
        guard !isComplete else { return nil }
        return "Unable to remove \(failedCredentialStoreCount) secure account credential store(s)."
    }

    func remainingProvider(
        preferring currentProvider: CloudGamingProvider
    ) -> CloudGamingProvider? {
        if !geForceNowCredentialsRemoved,
           !xboxCredentialsRemoved
        {
            return currentProvider
        }
        if !geForceNowCredentialsRemoved {
            return .geForceNow
        }
        if !xboxCredentialsRemoved {
            return .xboxCloudGaming
        }
        return nil
    }
}

nonisolated struct ProviderPersistentDataClearResult: Equatable, Sendable {
    let provider: CloudGamingProvider
    let credentialsRemoved: Bool

    var isComplete: Bool {
        credentialsRemoved
    }

    var failureDescription: String? {
        guard !isComplete else { return nil }
        return "Unable to remove the secure account credential store."
    }
}

private nonisolated struct ProviderCredentialResetGenerations: Sendable {
    var geForceNow: UInt64 = 0
    var xboxCloudGaming: UInt64 = 0
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
    private static let maximumXboxCredentialRecordSize = 262_144

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

    /// Wraps an account-specific cached value with the identity that produced it, so
    /// a value written by one account is never handed back to another. Values written
    /// before scoping existed are stored in a different format and simply fail to
    /// decode, which is the safe outcome — the caller refetches.
    private struct ScopedValueEnvelope<Value: Codable>: Codable {
        let accountScope: String
        let value: Value
    }

    private struct GameMetadataCacheEnvelope: Codable {
        let schemaVersion: Int
        let localeCode: String
        let vpcId: String
        let entries: [String: GameMetadataCacheEntry]
    }

    private enum Key {
        static let selectedCloudGamingProvider = "cloudnow.provider.selected.v1"
        static let xboxCloudStreamSettings = "xbox.streamSettings.v1"
        static let cloudCatalogActivityPrefix = "cloudnow.catalog.activity.v1"
        static let favoriteIds = "gfn.favoriteIds"
        static let preferredStores = "gfn.preferredStores"
        static let recentlyPlayed = "gfn.recentlyPlayed"
        static let streamSettings = "gfn.streamSettings"
        static let lastSession = "gfn.lastSession"
        static let legacyLibraryGames = "gfn.cache.libraryGames.v2"
        static let subscription = "gfn.cache.subscription.v1"
        static let vpcId = "gfn.cache.vpcId"
    }

    private static let serviceChooserSelection = "cloudnow-service-chooser"

    private let preferences: any PreferencesStore
    private let cacheDirectory: URL?
    private let fileManager: FileManager
    private let credentialStore: any SecureCredentialStore
    private let xboxCredentialStore: any SecureCredentialStore
    private var gameMetadataCacheGeneration: UInt64 = 0
    private var ownershipCacheGeneration: UInt64 = 0
    private var authCredentialGeneration: UInt64 = 0
    private var xboxAuthCredentialGeneration: UInt64 = 0
    private var cloudGamingProviderGeneration: UInt64 = 0
    private var cloudCatalogActivityGeneration: UInt64 = 0
    private nonisolated let credentialResetGenerations = Mutex(
        ProviderCredentialResetGenerations()
    )

    init(
        preferences: any PreferencesStore = UserDefaultsPreferencesStore(),
        cacheDirectory: URL? = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first,
        fileManager: FileManager = .default,
        credentialStore: any SecureCredentialStore = KeychainCredentialStore(),
        xboxCredentialStore: any SecureCredentialStore = KeychainCredentialStore(
            namespace: .xboxCloudGaming
        )
    ) {
        self.preferences = preferences
        self.cacheDirectory = cacheDirectory
        self.fileManager = fileManager
        self.credentialStore = credentialStore
        self.xboxCredentialStore = xboxCredentialStore
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
        snapshot.subscription = loadScoped(
            SubscriptionInfo.self,
            forKey: Key.subscription,
            accountScope: accountScope
        )
        snapshot.vpcId = loadScoped(
            String.self,
            forKey: Key.vpcId,
            accountScope: accountScope
        )
        snapshot.ownershipCacheGeneration = ownershipCacheGeneration

        // Remove caches written by the retired panels API.
        preferences.removeObject(forKey: "gfn.cache.mainGames")
        preferences.removeObject(forKey: "gfn.cache.libraryGames")
        return snapshot
    }

    func loadSelectedCloudGamingProvider() -> CloudGamingProvider? {
        guard let rawValue = preferences.string(
            forKey: Key.selectedCloudGamingProvider
        ) else {
            return nil
        }
        return CloudGamingProvider(rawValue: rawValue)
    }

    func hasStoredCloudGamingProviderSelection() -> Bool {
        preferences.keys().contains(Key.selectedCloudGamingProvider)
    }

    func saveSelectedCloudGamingProvider(
        _ provider: CloudGamingProvider?,
        generation: UInt64
    ) {
        guard generation >= cloudGamingProviderGeneration else { return }
        cloudGamingProviderGeneration = generation
        if let provider {
            preferences.setString(
                provider.rawValue,
                forKey: Key.selectedCloudGamingProvider
            )
        } else {
            preferences.setString(
                Self.serviceChooserSelection,
                forKey: Key.selectedCloudGamingProvider
            )
        }
    }

    func loadXboxCloudStreamSettings() -> XboxCloudStreamSettings {
        decode(
            XboxCloudStreamSettings.self,
            forKey: Key.xboxCloudStreamSettings
        ) ?? XboxCloudStreamSettings()
    }

    func saveXboxCloudStreamSettings(_ settings: XboxCloudStreamSettings) {
        encode(settings, forKey: Key.xboxCloudStreamSettings)
    }

    func loadXboxCatalogActivity(
        accountScope: String?
    ) -> CloudCatalogActivitySnapshot {
        guard let key = cloudCatalogActivityKey(
            provider: .xboxCloudGaming,
            accountScope: accountScope
        ) else {
            return CloudCatalogActivitySnapshot()
        }
        return (
            decode(CloudCatalogActivitySnapshot.self, forKey: key)
                ?? CloudCatalogActivitySnapshot()
        ).normalized
    }

    func loadXboxCatalogActivityLease(
        accountScope: String?
    ) -> CloudCatalogActivityLease {
        CloudCatalogActivityLease(
            snapshot: loadXboxCatalogActivity(accountScope: accountScope),
            generation: cloudCatalogActivityGeneration
        )
    }

    func saveXboxFavoriteIDs(
        _ favoriteIDs: Set<String>,
        accountScope: String?
    ) {
        saveXboxFavoriteIDs(
            favoriteIDs,
            accountScope: accountScope,
            expectedGeneration: cloudCatalogActivityGeneration
        )
    }

    func saveXboxFavoriteIDs(
        _ favoriteIDs: Set<String>,
        accountScope: String?,
        expectedGeneration: UInt64
    ) {
        guard expectedGeneration == cloudCatalogActivityGeneration else {
            return
        }
        guard let key = cloudCatalogActivityKey(
            provider: .xboxCloudGaming,
            accountScope: accountScope
        ) else {
            return
        }
        var snapshot = loadXboxCatalogActivity(accountScope: accountScope)
        snapshot.favoriteIDs = favoriteIDs
        encode(snapshot.normalized, forKey: key)
    }

    func saveXboxRecentlyPlayedIDs(
        _ recentlyPlayedIDs: [String],
        accountScope: String?
    ) {
        saveXboxRecentlyPlayedIDs(
            recentlyPlayedIDs,
            accountScope: accountScope,
            expectedGeneration: cloudCatalogActivityGeneration
        )
    }

    func saveXboxRecentlyPlayedIDs(
        _ recentlyPlayedIDs: [String],
        accountScope: String?,
        expectedGeneration: UInt64
    ) {
        guard expectedGeneration == cloudCatalogActivityGeneration else {
            return
        }
        guard let key = cloudCatalogActivityKey(
            provider: .xboxCloudGaming,
            accountScope: accountScope
        ) else {
            return
        }
        var snapshot = loadXboxCatalogActivity(accountScope: accountScope)
        snapshot.recentlyPlayedIDs = recentlyPlayedIDs
        encode(snapshot.normalized, forKey: key)
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

    func saveSubscription(_ subscription: SubscriptionInfo, accountScope: String?) {
        saveScoped(subscription, forKey: Key.subscription, accountScope: accountScope)
    }

    func saveVpcId(_ vpcId: String, accountScope: String?) {
        saveScoped(vpcId, forKey: Key.vpcId, accountScope: accountScope)
    }

    /// Stores a value tagged with the current account. Without a usable scope there
    /// is no identity to tag it with, so any existing value is cleared rather than
    /// left behind for the next account to read.
    private func saveScoped(_ value: some Codable, forKey key: String, accountScope: String?) {
        guard let accountScope = safeAccountScope(accountScope) else {
            preferences.removeObject(forKey: key)
            return
        }
        encode(ScopedValueEnvelope(accountScope: accountScope, value: value), forKey: key)
    }

    /// Returns the cached value only when it was written by this same account.
    private func loadScoped<Value: Codable>(
        _: Value.Type,
        forKey key: String,
        accountScope: String?
    ) -> Value? {
        guard let accountScope = safeAccountScope(accountScope),
              let envelope = decode(ScopedValueEnvelope<Value>.self, forKey: key)
        else {
            return nil
        }
        return envelope.accountScope == accountScope ? envelope.value : nil
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

    nonisolated func authSessionResetGeneration() -> UInt64 {
        credentialResetGenerations.withLock { $0.geForceNow }
    }

    func saveAuthSession(
        _ session: AuthSession,
        generation: UInt64,
        resetGeneration: UInt64
    ) async throws {
        guard resetGeneration == authSessionResetGeneration(),
              generation >= authCredentialGeneration
        else {
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

    func deleteAuthSession(
        generation: UInt64,
        resetGeneration: UInt64
    ) async throws {
        guard resetGeneration == authSessionResetGeneration(),
              generation >= authCredentialGeneration
        else {
            return
        }
        authCredentialGeneration = generation
        try credentialStore.delete()
    }

    func loadXboxAuthSession() async throws -> XboxAuthSession? {
        let data = try xboxCredentialStore.load()
        guard data.count <= Self.maximumXboxCredentialRecordSize else {
            throw XboxAuthError.persistenceUnavailable
        }
        let decoder = JSONDecoder()
        if let credential = try? decoder.decode(
            XboxRefreshTokenCredential.self,
            from: data
        ) {
            return try credential.makeRefreshOnlySession()
        }

        // Version 0 stored Microsoft's complete OAuth response. Rewrite it
        // immediately, returning a refresh-only in-memory session so legacy
        // access and ID tokens never survive migration.
        let legacySession = try decoder.decode(XboxAuthSession.self, from: data)
        let credential = try XboxRefreshTokenCredential(session: legacySession)
        let migratedData = try JSONEncoder().encode(credential)
        guard migratedData.count <= Self.maximumXboxCredentialRecordSize else {
            throw XboxAuthError.persistenceUnavailable
        }
        try xboxCredentialStore.save(migratedData)
        return try credential.makeRefreshOnlySession()
    }

    func saveXboxAuthSession(
        _ session: XboxAuthSession,
        generation: UInt64
    ) async throws {
        guard generation >= xboxAuthCredentialGeneration else { return }
        let credential = try XboxRefreshTokenCredential(session: session)
        let data = try JSONEncoder().encode(credential)
        guard data.count <= Self.maximumXboxCredentialRecordSize else {
            throw XboxAuthError.persistenceUnavailable
        }
        xboxAuthCredentialGeneration = generation
        try xboxCredentialStore.save(data)
    }

    nonisolated func xboxAuthSessionResetGeneration() -> UInt64 {
        credentialResetGenerations.withLock { $0.xboxCloudGaming }
    }

    func saveXboxAuthSession(
        _ session: XboxAuthSession,
        generation: UInt64,
        resetGeneration: UInt64
    ) async throws {
        guard resetGeneration == xboxAuthSessionResetGeneration(),
              generation >= xboxAuthCredentialGeneration
        else {
            return
        }
        let credential = try XboxRefreshTokenCredential(session: session)
        let data = try JSONEncoder().encode(credential)
        guard data.count <= Self.maximumXboxCredentialRecordSize else {
            throw XboxAuthError.persistenceUnavailable
        }
        xboxAuthCredentialGeneration = generation
        try xboxCredentialStore.save(data)
    }

    func deleteXboxAuthSession(generation: UInt64) async throws {
        guard generation >= xboxAuthCredentialGeneration else { return }
        xboxAuthCredentialGeneration = generation
        try xboxCredentialStore.delete()
    }

    func deleteXboxAuthSession(
        generation: UInt64,
        resetGeneration: UInt64
    ) async throws {
        guard resetGeneration == xboxAuthSessionResetGeneration(),
              generation >= xboxAuthCredentialGeneration
        else {
            return
        }
        xboxAuthCredentialGeneration = generation
        try xboxCredentialStore.delete()
    }

    /// Removes cache-backed preferences and files after callers have invalidated
    /// in-flight producers. Running this on the persistence actor serializes the
    /// deletion behind writes that were already submitted.
    func clearCachedData() -> [String] {
        clearCachedData(for: .geForceNow)
    }

    /// Removes only cache-backed state owned by `provider`. Xbox catalog data is
    /// memory-only, so its persistent cache operation is intentionally empty.
    func clearCachedData(for provider: CloudGamingProvider) -> [String] {
        guard provider == .geForceNow else { return [] }
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

    /// Clears preferences and credentials owned by one provider while retaining
    /// the other provider's account and settings. Callers remain responsible for
    /// updating the shared provider selection after the reset succeeds.
    func clearPersistentData(
        for provider: CloudGamingProvider
    ) -> ProviderPersistentDataClearResult {
        let credentialsRemoved: Bool
        switch provider {
        case .geForceNow:
            credentialResetGenerations.withLock { generations in
                generations.geForceNow &+= 1
            }
            gameMetadataCacheGeneration &+= 1
            ownershipCacheGeneration &+= 1
            authCredentialGeneration &+= 1
            preferences.keys()
                .filter { $0.hasPrefix("gfn.") }
                .forEach(preferences.removeObject(forKey:))
            do {
                try credentialStore.delete()
                credentialsRemoved = true
            } catch {
                credentialsRemoved = false
            }
        case .xboxCloudGaming:
            credentialResetGenerations.withLock { generations in
                generations.xboxCloudGaming &+= 1
            }
            cloudCatalogActivityGeneration &+= 1
            xboxAuthCredentialGeneration &+= 1
            let catalogActivityPrefix = "\(Key.cloudCatalogActivityPrefix).\(provider.rawValue)."
            preferences.keys()
                .filter {
                    $0 == Key.xboxCloudStreamSettings
                        || $0 == XboxCloudInstallationIdentityStore.preferenceKey
                        || $0.hasPrefix(catalogActivityPrefix)
                }
                .forEach(preferences.removeObject(forKey:))
            do {
                try xboxCredentialStore.delete()
                credentialsRemoved = true
            } catch {
                credentialsRemoved = false
            }
        }
        return ProviderPersistentDataClearResult(
            provider: provider,
            credentialsRemoved: credentialsRemoved
        )
    }

    /// Clears every preference and credential after all producers have been
    /// invalidated. Actor serialization prevents an earlier queued write from
    /// restoring data after this deletion completes.
    func clearPersistentData() -> PersistentDataClearResult {
        credentialResetGenerations.withLock { generations in
            generations.geForceNow &+= 1
            generations.xboxCloudGaming &+= 1
        }
        ownershipCacheGeneration &+= 1
        cloudCatalogActivityGeneration &+= 1
        authCredentialGeneration &+= 1
        xboxAuthCredentialGeneration &+= 1
        cloudGamingProviderGeneration &+= 1
        for key in preferences.keys() {
            preferences.removeObject(forKey: key)
        }
        var geForceNowCredentialsRemoved = false
        do {
            try credentialStore.delete()
            geForceNowCredentialsRemoved = true
        } catch {
            geForceNowCredentialsRemoved = false
        }
        var xboxCredentialsRemoved = false
        do {
            try xboxCredentialStore.delete()
            xboxCredentialsRemoved = true
        } catch {
            xboxCredentialsRemoved = false
        }
        return PersistentDataClearResult(
            geForceNowCredentialsRemoved: geForceNowCredentialsRemoved,
            xboxCredentialsRemoved: xboxCredentialsRemoved
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = preferences.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode(_ value: some Encodable, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        preferences.setData(data, forKey: key)
    }

    private func cloudCatalogActivityKey(
        provider: CloudGamingProvider,
        accountScope: String?
    ) -> String? {
        guard let accountScope = accountScope?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !accountScope.isEmpty,
            accountScope.utf8.count <= 1024
        else {
            return nil
        }
        let accountHash = SHA256.hash(data: Data(accountScope.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(Key.cloudCatalogActivityPrefix).\(provider.rawValue).\(accountHash)"
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

extension AppPersistenceStore: XboxCatalogActivityPersistence {}
