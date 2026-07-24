@testable import CloudNow
import Foundation
import Testing

@Suite("Application persistence")
struct PersistenceStoreTests {
    @Test("Settings, favorites, history, and library data round-trip in isolated storage")
    func snapshotRoundTrip() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        var settings = StreamSettings()
        settings.codec = .h265
        settings.maxBitrateKbps = 42000
        let games = [makeGame(id: "one"), makeGame(id: "two")]

        await harness.store.saveFavoriteIds(["two"])
        await harness.store.savePreferredStoreIds(["two": "two-steam"])
        await harness.store.saveRecentlyPlayedIds(["two", "one"])
        await harness.store.saveStreamSettings(settings)
        await harness.store.saveLibraryGames(games)

        let snapshot = await harness.store.loadGamesSnapshot()

        #expect(snapshot.favoriteIds == ["two"])
        #expect(snapshot.preferredStoreIds == ["two": "two-steam"])
        #expect(snapshot.recentlyPlayedIds == ["two", "one"])
        #expect(snapshot.streamSettings == settings)
        #expect(snapshot.libraryGames == games)
    }

    @Test("Legacy settings JSON is migrated while loading a snapshot")
    func legacySettingsMigration() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let legacy = Data(
            """
            {
              "resolution": "1280x720",
              "fps": 30,
              "colorQuality": "HDR10bit",
              "statsMode": "hud",
              "preferredZoneUrl": "https://np-old.example/"
            }
            """.utf8
        )
        harness.preferences.setData(legacy, forKey: "gfn.streamSettings")

        let settings = try #require(
            await harness.store.loadGamesSnapshot().streamSettings
        )

        #expect(settings.resolution == "1280x720")
        #expect(settings.fps == 30)
        #expect(settings.colorPreference == .preferHDR)
        #expect(settings.statsMode == .off)
        #expect(settings.serverRoutingMode == .client)
    }

    @Test("Catalog cache validates locale and VPC identity")
    func catalogCacheIdentity() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let games = [makeGame(id: "catalog")]

        await harness.store.saveCatalog(games, localeCode: "en-US", vpcId: "EU-1")

        #expect(
            await harness.store.loadCatalog(
                localeCode: "en-US",
                vpcId: "EU-1"
            ) == games
        )
        #expect(
            await harness.store.loadCatalog(
                localeCode: "fr-FR",
                vpcId: "EU-1"
            ) == nil
        )
        #expect(
            await harness.store.loadCatalog(
                localeCode: "en-US",
                vpcId: "EU-2"
            ) == nil
        )
    }

    @Test("Missing and corrupt catalog files recover as cache misses")
    func corruptCatalogRecovery() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }

        #expect(
            await harness.store.loadCatalog(
                localeCode: "en-US",
                vpcId: nil
            ) == nil
        )

        await harness.store.saveCatalog(
            [makeGame(id: "catalog")],
            localeCode: "en-US",
            vpcId: nil
        )
        let cacheName = try #require(
            try FileManager.default
                .contentsOfDirectory(atPath: harness.cacheDirectory.path)
                .first { $0.hasPrefix("gfn.catalog.v2.") }
        )
        try Data("not-json".utf8).write(
            to: harness.cacheDirectory.appendingPathComponent(cacheName),
            options: .atomic
        )

        #expect(
            await harness.store.loadCatalog(
                localeCode: "en-US",
                vpcId: nil
            ) == nil
        )
    }

    @Test("Concurrent actor writes to independent values are retained")
    func concurrentWritesAreSerialized() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let store = harness.store

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await store.saveFavoriteIds(["favorite"])
            }
            group.addTask {
                await store.saveRecentlyPlayedIds(["recent"])
            }
            group.addTask {
                await store.savePreferredStoreIds([
                    "favorite": "favorite-steam",
                ])
            }
        }

        let snapshot = await harness.store.loadGamesSnapshot()
        #expect(snapshot.favoriteIds == ["favorite"])
        #expect(snapshot.recentlyPlayedIds == ["recent"])
        #expect(snapshot.preferredStoreIds == [
            "favorite": "favorite-steam",
        ])
    }

    @Test("Secure credential storage supports save, update, load, and delete")
    func secureCredentialLifecycle() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let first = makeAuthSession(accessToken: "first")
        let updated = makeAuthSession(accessToken: "updated")

        try await harness.store.saveAuthSession(first)
        #expect(try await harness.store.loadAuthSession().tokens.accessToken == "first")

        try await harness.store.saveAuthSession(updated)
        #expect(try await harness.store.loadAuthSession().tokens.accessToken == "updated")

        try await harness.store.deleteAuthSession()
        await #expect(throws: FakeSecureStoreError.notFound) {
            _ = try await harness.store.loadAuthSession()
        }
    }

    @Test("Secure credential storage errors propagate")
    func secureCredentialErrorsPropagate() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        harness.secureStore.error = .injected

        await #expect(throws: FakeSecureStoreError.injected) {
            try await harness.store.saveAuthSession(
                makeAuthSession(accessToken: "secret")
            )
        }
        await #expect(throws: FakeSecureStoreError.injected) {
            _ = try await harness.store.loadAuthSession()
        }
        await #expect(throws: FakeSecureStoreError.injected) {
            try await harness.store.deleteAuthSession()
        }
    }

    private func makeGame(id: String) -> GameInfo {
        GameInfo(
            id: id,
            title: "Game \(id)",
            longDescription: nil,
            genres: ["ACTION"],
            developer: nil,
            publisher: nil,
            contentRating: nil,
            boxArtUrl: nil,
            heroBannerUrl: nil,
            heroImageUrl: nil,
            supportedFeatures: [.reflex],
            screenshots: [],
            isInLibrary: true,
            variants: [
                GameVariant(
                    id: "\(id)-steam",
                    appStore: "STEAM",
                    appId: id,
                    isOwned: true
                ),
            ]
        )
    }

    private func makeAuthSession(accessToken: String) -> AuthSession {
        AuthSession(
            provider: LoginProvider(
                idpId: "provider",
                code: "NVIDIA",
                displayName: "NVIDIA",
                streamingServiceUrl: "https://stream.invalid/",
                priority: 0
            ),
            tokens: AuthTokens(
                accessToken: accessToken,
                refreshToken: "refresh",
                idToken: nil,
                expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
                clientToken: nil,
                clientTokenExpiresAt: nil
            ),
            user: AuthUser(
                userId: "user",
                displayName: "Fixture User",
                email: nil,
                avatarUrl: nil,
                membershipTier: "FREE"
            )
        )
    }
}

private struct PersistenceHarness {
    let defaults: UserDefaults
    let preferences: UserDefaultsPreferencesStore
    let cacheDirectory: URL
    let secureStore: FakeSecureCredentialStore
    let store: AppPersistenceStore
    private let suiteName: String

    init() throws {
        suiteName = "CloudNowTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        preferences = UserDefaultsPreferencesStore(defaults: defaults)
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudNowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        secureStore = FakeSecureCredentialStore()
        store = AppPersistenceStore(
            preferences: preferences,
            cacheDirectory: cacheDirectory,
            credentialStore: secureStore
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}

private enum FakeSecureStoreError: Error, Equatable {
    case notFound
    case injected
}

private final class FakeSecureCredentialStore: SecureCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?
    private var storedError: FakeSecureStoreError?

    var error: FakeSecureStoreError? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }
        set {
            lock.lock()
            storedError = newValue
            lock.unlock()
        }
    }

    func load() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let storedError {
            throw storedError
        }
        guard let storedData else {
            throw FakeSecureStoreError.notFound
        }
        return storedData
    }

    func save(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if let storedError {
            throw storedError
        }
        storedData = data
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        if let storedError {
            throw storedError
        }
        storedData = nil
    }
}
