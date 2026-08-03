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
        let accountScope = accountScope("a")

        await harness.store.saveFavoriteIds(["two"])
        await harness.store.savePreferredStoreIds(["two": "two-steam"])
        await harness.store.saveRecentlyPlayedIds(["two", "one"])
        await harness.store.saveStreamSettings(settings)
        await harness.store.saveLibraryGames(
            games,
            accountScope: accountScope
        )

        let snapshot = await harness.store.loadGamesSnapshot(
            accountScope: accountScope
        )

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
            await harness.store.loadGamesSnapshot(
                accountScope: nil
            ).streamSettings
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
        let accountScope = accountScope("a")

        await harness.store.saveCatalog(
            games,
            localeCode: "en-US",
            vpcId: "EU-1",
            accountScope: accountScope
        )
        let neutralGames = accountNeutralCatalog(games)

        #expect(
            await harness.store.loadCatalog(
                localeCode: "en-US",
                vpcId: "EU-1",
                accountScope: accountScope
            ) == neutralGames
        )
        #expect(
            await harness.store.loadCatalog(
                localeCode: "fr-FR",
                vpcId: "EU-1",
                accountScope: accountScope
            ) == nil
        )
        #expect(
            await harness.store.loadCatalog(
                localeCode: "en-US",
                vpcId: "EU-2",
                accountScope: accountScope
            ) == nil
        )
    }

    @Test("Libraries isolate accounts while the catalog is shared and neutral")
    func ownershipCacheAccountIsolation() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let accountA = accountScope("a")
        let accountB = accountScope("b")
        let libraryA = [makeGame(id: "library-a")]
        let libraryB = [makeGame(id: "library-b")]
        let catalogA = [makeGame(id: "catalog-a")]

        await harness.store.saveLibraryGames(
            libraryA,
            accountScope: accountA
        )
        await harness.store.saveLibraryGames(
            libraryB,
            accountScope: accountB
        )
        await harness.store.saveCatalog(
            catalogA,
            localeCode: "en-US",
            vpcId: "EU-1",
            accountScope: accountA
        )
        let neutralCatalog = accountNeutralCatalog(catalogA)

        #expect(
            await harness.store.loadGamesSnapshot(
                accountScope: accountA
            ).libraryGames == libraryA
        )
        #expect(
            await harness.store.loadGamesSnapshot(
                accountScope: accountB
            ).libraryGames == libraryB
        )
        #expect(
            await harness.store.loadCatalog(
                localeCode: "en-US",
                vpcId: "EU-1",
                accountScope: accountA
            ) == neutralCatalog
        )
        #expect(
            await harness.store.loadCatalog(
                localeCode: "en-US",
                vpcId: "EU-1",
                accountScope: accountB
            ) == neutralCatalog
        )
        let cacheNames = try FileManager.default.contentsOfDirectory(
            atPath: harness.cacheDirectory.path
        )
        #expect(cacheNames.contains { $0.contains(accountA) })
        #expect(cacheNames.contains { $0.contains(accountB) })
        let catalogNames = cacheNames.filter {
            $0.hasPrefix("gfn.catalog.v3.")
        }
        #expect(catalogNames.count == 1)
        #expect(catalogNames.allSatisfy { !$0.contains(accountA) })
        #expect(catalogNames.allSatisfy { !$0.contains(accountB) })
    }

    @Test("Full refresh writes an account library and shared catalog independently")
    func refreshedLibrarySnapshotUsesIndependentArtifacts() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let scope = accountScope("a")
        let library = [makeGame(id: "library")]
        let catalog = [makeGame(id: "catalog")]

        try await harness.store.saveRefreshedLibrarySnapshot(
            libraryGames: library,
            catalogGames: catalog,
            localeCode: "en-US",
            vpcId: "EU-1",
            accountScope: scope
        )

        #expect(
            await harness.store.loadGamesSnapshot(
                accountScope: scope
            ).libraryGames == library
        )
        #expect(
            await harness.store.loadCatalog(
                localeCode: "en-US",
                vpcId: "EU-1",
                accountScope: scope
            ) == accountNeutralCatalog(catalog)
        )

        let catalogName = try #require(
            try FileManager.default.contentsOfDirectory(
                atPath: harness.cacheDirectory.path
            ).first { $0.hasPrefix("gfn.catalog.v3.") }
        )
        let catalogURL = harness.cacheDirectory.appendingPathComponent(
            catalogName
        )
        let catalogDataBeforeLibrarySave = try Data(contentsOf: catalogURL)
        let replacementLibrary = [makeGame(id: "replacement-library")]
        await harness.store.saveLibraryGames(
            replacementLibrary,
            accountScope: scope
        )
        #expect(
            await harness.store.loadGamesSnapshot(
                accountScope: scope
            ).libraryGames == replacementLibrary
        )
        #expect(
            await harness.store.loadCatalog(
                localeCode: "en-US",
                vpcId: "EU-1",
                accountScope: scope
            ) == accountNeutralCatalog(catalog)
        )
        #expect(try Data(contentsOf: catalogURL) == catalogDataBeforeLibrarySave)

        let cacheNames = try FileManager.default.contentsOfDirectory(
            atPath: harness.cacheDirectory.path
        )
        #expect(cacheNames.filter { $0.hasPrefix("gfn.library.v2.") }.count == 1)
        #expect(cacheNames.filter { $0.hasPrefix("gfn.catalog.v3.") }.count == 1)
        #expect(cacheNames.allSatisfy { !$0.hasPrefix("gfn.refresh.") })
    }

    @Test("A failed fresh catalog preserves the old catalog and new library")
    func failedCatalogRefreshPreservesLastKnownGoodCatalog() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let scope = accountScope("a")
        let oldCatalog = [makeGame(id: "old-catalog")]
        await harness.store.saveCatalog(
            oldCatalog,
            localeCode: "en-US",
            vpcId: "EU-1",
            accountScope: scope
        )
        let refreshedLibrary = [makeGame(id: "fresh-library")]
        try await harness.store.saveRefreshedLibrarySnapshot(
            libraryGames: refreshedLibrary,
            catalogGames: nil,
            localeCode: "en-US",
            vpcId: "EU-1",
            accountScope: scope
        )
        let recreatedStore = AppPersistenceStore(
            preferences: harness.preferences,
            cacheDirectory: harness.cacheDirectory,
            credentialStore: harness.secureStore
        )

        #expect(
            await recreatedStore.loadGamesSnapshot(
                accountScope: scope
            ).libraryGames == refreshedLibrary
        )
        #expect(
            await recreatedStore.loadCatalog(
                localeCode: "en-US",
                vpcId: "EU-1",
                accountScope: scope
            ) == accountNeutralCatalog(oldCatalog)
        )
    }

    @Test("Nil account scope skips libraries but can use the shared catalog")
    func nilAccountScopeSkipsOwnershipCache() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let games = [makeGame(id: "private")]

        await harness.store.saveLibraryGames(games, accountScope: nil)
        await harness.store.saveCatalog(
            games,
            localeCode: "en-US",
            vpcId: "EU-1",
            accountScope: nil
        )

        #expect(
            await harness.store.loadGamesSnapshot(
                accountScope: nil
            ).libraryGames.isEmpty
        )
        #expect(
            await harness.store.loadCatalog(
                localeCode: "en-US",
                vpcId: "EU-1",
                accountScope: nil
            ) == accountNeutralCatalog(games)
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: harness.cacheDirectory.path
            ).filter { $0.hasPrefix("gfn.catalog.v3.") }.count == 1
        )
    }

    @Test("Scoped loads remove legacy ownership caches")
    func scopedLoadRemovesLegacyOwnershipCaches() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let legacyNames = [
            "gfn.library.v1.json",
            "gfn.catalog.v1.json",
            "gfn.catalog.v2.legacy.json",
            "gfn.refresh.v1.\(accountScope("a")).json",
            "gfn.catalog.v3.\(accountScope("a")).legacy.json",
        ]
        for name in legacyNames {
            try Data("legacy".utf8).write(
                to: harness.cacheDirectory.appendingPathComponent(name),
                options: .atomic
            )
        }

        _ = await harness.store.loadGamesSnapshot(
            accountScope: accountScope("a")
        )

        let remainingNames = try FileManager.default.contentsOfDirectory(
            atPath: harness.cacheDirectory.path
        )
        #expect(legacyNames.allSatisfy { !remainingNames.contains($0) })
    }

    @Test("Cache clearing removes every account-scoped ownership file")
    func clearRemovesAllScopedOwnershipCaches() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let games = [makeGame(id: "private")]
        let accountA = accountScope("a")
        let accountB = accountScope("b")

        for scope in [accountA, accountB] {
            await harness.store.saveLibraryGames(
                games,
                accountScope: scope
            )
            await harness.store.saveCatalog(
                games,
                localeCode: "en-US",
                vpcId: "EU-1",
                accountScope: scope
            )
        }

        #expect(await harness.store.clearCachedData().isEmpty)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: harness.cacheDirectory.path
            ).isEmpty
        )
        for scope in [accountA, accountB] {
            #expect(
                await harness.store.loadGamesSnapshot(
                    accountScope: scope
                ).libraryGames.isEmpty
            )
            #expect(
                await harness.store.loadCatalog(
                    localeCode: "en-US",
                    vpcId: "EU-1",
                    accountScope: scope
                ) == nil
            )
        }
    }

    @Test("Cache clear and reset reject every stale ownership write")
    func staleOwnershipWritesDoNotRecreateClearedCaches() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let scope = accountScope("a")
        let staleGeneration = await harness.store.loadGamesSnapshot(
            accountScope: scope
        ).ownershipCacheGeneration
        let games = [makeGame(id: "stale")]

        #expect(await harness.store.clearCachedData().isEmpty)
        await harness.store.saveLibraryGames(
            games,
            accountScope: scope,
            expectedGeneration: staleGeneration
        )
        await harness.store.saveCatalog(
            games,
            localeCode: "en-US",
            vpcId: "EU-1",
            accountScope: scope,
            expectedGeneration: staleGeneration
        )
        await #expect(throws: (any Error).self) {
            try await harness.store.saveRefreshedLibrarySnapshot(
                libraryGames: games,
                catalogGames: games,
                localeCode: "en-US",
                vpcId: "EU-1",
                accountScope: scope,
                expectedGeneration: staleGeneration
            )
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: harness.cacheDirectory.path
            ).isEmpty
        )

        let resetGeneration = await harness.store.loadGamesSnapshot(
            accountScope: scope
        ).ownershipCacheGeneration
        await harness.store.clearPersistentData()
        await harness.store.saveLibraryGames(
            games,
            accountScope: scope,
            expectedGeneration: resetGeneration
        )
        await harness.store.saveCatalog(
            games,
            localeCode: "en-US",
            vpcId: "EU-1",
            accountScope: scope,
            expectedGeneration: resetGeneration
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: harness.cacheDirectory.path
            ).isEmpty
        )

        let currentGeneration = await harness.store.loadGamesSnapshot(
            accountScope: scope
        ).ownershipCacheGeneration
        await harness.store.saveLibraryGames(
            games,
            accountScope: scope,
            expectedGeneration: currentGeneration
        )
        #expect(
            await harness.store.loadGamesSnapshot(
                accountScope: scope
            ).libraryGames == games
        )
    }

    @Test("Metadata cache is locale and VPC scoped, atomically merged, and cleared")
    func metadataCacheLifecycle() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(60)
        let first = metadataEntry(
            title: "First",
            refreshedAt: firstDate
        )
        let second = metadataEntry(
            title: "Second",
            refreshedAt: secondDate
        )
        let store = harness.store
        let generation = await store.loadGameMetadataCache(
            localeCode: "en-US",
            vpcId: "EU-1"
        ).generation

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await store.mergeGameMetadataCache(
                    ["first": first],
                    localeCode: "en-US",
                    vpcId: "EU-1",
                    pruningBefore: firstDate.addingTimeInterval(-60),
                    maximumEntryCount: 2000,
                    expectedGeneration: generation
                )
            }
            group.addTask {
                await store.mergeGameMetadataCache(
                    ["second": second],
                    localeCode: "en-US",
                    vpcId: "EU-1",
                    pruningBefore: firstDate.addingTimeInterval(-60),
                    maximumEntryCount: 2000,
                    expectedGeneration: generation
                )
            }
        }

        #expect(
            await store.loadGameMetadataCache(
                localeCode: "en-US",
                vpcId: "EU-1"
            ).entries == [
                "first": first,
                "second": second,
            ]
        )
        #expect(
            await store.loadGameMetadataCache(
                localeCode: "fr-FR",
                vpcId: "EU-1"
            ).entries.isEmpty
        )
        #expect(
            await store.loadGameMetadataCache(
                localeCode: "en-US",
                vpcId: "EU-2"
            ).entries.isEmpty
        )

        #expect(await store.clearCachedData().isEmpty)
        await store.mergeGameMetadataCache(
            ["late": second],
            localeCode: "en-US",
            vpcId: "EU-1",
            pruningBefore: firstDate.addingTimeInterval(-60),
            maximumEntryCount: 2000,
            expectedGeneration: generation
        )
        #expect(
            await store.loadGameMetadataCache(
                localeCode: "en-US",
                vpcId: "EU-1"
            ).entries.isEmpty
        )
    }

    @Test("An older metadata write cannot replace a newer value")
    func olderMetadataWriteDoesNotWin() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = oldDate.addingTimeInterval(60)
        let store = harness.store
        let generation = await store.loadGameMetadataCache(
            localeCode: "en-US",
            vpcId: "EU-1"
        ).generation

        await store.mergeGameMetadataCache(
            ["game": metadataEntry(title: "New", refreshedAt: newDate)],
            localeCode: "en-US",
            vpcId: "EU-1",
            pruningBefore: oldDate.addingTimeInterval(-60),
            maximumEntryCount: 2000,
            expectedGeneration: generation
        )
        await store.mergeGameMetadataCache(
            ["game": metadataEntry(title: "Old", refreshedAt: oldDate)],
            localeCode: "en-US",
            vpcId: "EU-1",
            pruningBefore: oldDate.addingTimeInterval(-60),
            maximumEntryCount: 2000,
            expectedGeneration: generation
        )

        let entry = await store.loadGameMetadataCache(
            localeCode: "en-US",
            vpcId: "EU-1"
        ).entries["game"]
        #expect(entry?.metadata?.title == "New")
        #expect(entry?.refreshedAt == newDate)
    }

    @Test("Corrupt metadata cache files recover as cache misses")
    func corruptMetadataCacheRecovery() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let generation = await harness.store.loadGameMetadataCache(
            localeCode: "en-US",
            vpcId: "EU-1"
        ).generation

        await harness.store.mergeGameMetadataCache(
            [
                "game": metadataEntry(
                    title: "Game",
                    refreshedAt: date
                ),
            ],
            localeCode: "en-US",
            vpcId: "EU-1",
            pruningBefore: date.addingTimeInterval(-60),
            maximumEntryCount: 2000,
            expectedGeneration: generation
        )
        let cacheName = try #require(
            try FileManager.default
                .contentsOfDirectory(
                    atPath: harness.cacheDirectory.path
                )
                .first { $0.hasPrefix("gfn.metadata.v1.") }
        )
        try Data("not-json".utf8).write(
            to: harness.cacheDirectory.appendingPathComponent(cacheName),
            options: .atomic
        )

        #expect(
            await harness.store.loadGameMetadataCache(
                localeCode: "en-US",
                vpcId: "EU-1"
            ).entries.isEmpty
        )
    }

    @Test("Missing and corrupt catalog files recover as cache misses")
    func corruptCatalogRecovery() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }

        #expect(
            await harness.store.loadCatalog(
                localeCode: "en-US",
                vpcId: nil,
                accountScope: accountScope("a")
            ) == nil
        )

        await harness.store.saveCatalog(
            [makeGame(id: "catalog")],
            localeCode: "en-US",
            vpcId: nil,
            accountScope: accountScope("a")
        )
        let cacheName = try #require(
            try FileManager.default
                .contentsOfDirectory(atPath: harness.cacheDirectory.path)
                .first { $0.hasPrefix("gfn.catalog.v3.") }
        )
        try Data("not-json".utf8).write(
            to: harness.cacheDirectory.appendingPathComponent(cacheName),
            options: .atomic
        )

        #expect(
            await harness.store.loadCatalog(
                localeCode: "en-US",
                vpcId: nil,
                accountScope: accountScope("a")
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

        let snapshot = await harness.store.loadGamesSnapshot(
            accountScope: nil
        )
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

        try await harness.store.saveAuthSession(
            first,
            generation: 0
        )
        #expect(try await harness.store.loadAuthSession().tokens.accessToken == "first")

        try await harness.store.saveAuthSession(
            updated,
            generation: 1
        )
        #expect(try await harness.store.loadAuthSession().tokens.accessToken == "updated")

        try await harness.store.deleteAuthSession(generation: 2)
        await #expect(throws: FakeSecureStoreError.notFound) {
            _ = try await harness.store.loadAuthSession()
        }
    }

    @Test("Credential generation rejects stale saves and deletes across reset")
    func credentialGenerationRejectsStaleMutations() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let current = makeAuthSession(accessToken: "current")
        let stale = makeAuthSession(accessToken: "stale")

        try await harness.store.saveAuthSession(
            current,
            generation: 2
        )
        try await harness.store.deleteAuthSession(generation: 1)
        try await harness.store.saveAuthSession(
            stale,
            generation: 1
        )
        #expect(
            try await harness.store.loadAuthSession().tokens.accessToken
                == "current"
        )

        await harness.store.clearPersistentData()
        try await harness.store.saveAuthSession(
            stale,
            generation: 2
        )
        await #expect(throws: FakeSecureStoreError.notFound) {
            _ = try await harness.store.loadAuthSession()
        }

        try await harness.store.saveAuthSession(
            current,
            generation: 3
        )
        #expect(
            try await harness.store.loadAuthSession().tokens.accessToken
                == "current"
        )
    }

    @Test("Secure credential storage errors propagate")
    func secureCredentialErrorsPropagate() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        harness.secureStore.error = .injected

        await #expect(throws: FakeSecureStoreError.injected) {
            try await harness.store.saveAuthSession(
                makeAuthSession(accessToken: "secret"),
                generation: 0
            )
        }
        await #expect(throws: FakeSecureStoreError.injected) {
            _ = try await harness.store.loadAuthSession()
        }
        await #expect(throws: FakeSecureStoreError.injected) {
            try await harness.store.deleteAuthSession(generation: 0)
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

    private func accountNeutralCatalog(
        _ games: [GameInfo]
    ) -> [GameInfo] {
        games.map { game in
            var game = game
            game.isInLibrary = false
            for index in game.variants.indices {
                game.variants[index].isOwned = false
            }
            return game
        }
    }

    private func accountScope(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func metadataEntry(
        title: String,
        refreshedAt: Date
    ) -> GameMetadataCacheEntry {
        GameMetadataCacheEntry(
            metadata: CachedGameMetadata(
                title: title,
                longDescription: nil,
                genres: nil,
                developer: nil,
                publisher: nil,
                contentRating: nil,
                boxArtUrl: nil,
                tvBannerUrl: nil,
                heroImageUrl: nil,
                screenshots: []
            ),
            refreshedAt: refreshedAt
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

extension AppPersistenceStore {
    func saveLibraryGames(
        _ games: [GameInfo],
        accountScope: String?
    ) {
        let generation = loadGamesSnapshot(
            accountScope: accountScope
        ).ownershipCacheGeneration
        saveLibraryGames(
            games,
            accountScope: accountScope,
            expectedGeneration: generation
        )
    }

    func saveCatalog(
        _ games: [GameInfo],
        localeCode: String,
        vpcId: String?,
        accountScope: String?
    ) {
        let generation = loadGamesSnapshot(
            accountScope: accountScope
        ).ownershipCacheGeneration
        saveCatalog(
            games,
            localeCode: localeCode,
            vpcId: vpcId,
            accountScope: accountScope,
            expectedGeneration: generation
        )
    }

    func saveRefreshedLibrarySnapshot(
        libraryGames: [GameInfo],
        catalogGames: [GameInfo]?,
        localeCode: String,
        vpcId: String?,
        accountScope: String
    ) throws {
        let generation = loadGamesSnapshot(
            accountScope: accountScope
        ).ownershipCacheGeneration
        try saveRefreshedLibrarySnapshot(
            libraryGames: libraryGames,
            catalogGames: catalogGames,
            localeCode: localeCode,
            vpcId: vpcId,
            accountScope: accountScope,
            expectedGeneration: generation
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
