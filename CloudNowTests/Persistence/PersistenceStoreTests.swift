@testable import CloudNow
import Foundation
import Testing

@Suite("Application persistence")
struct PersistenceStoreTests {
    @Test("Cloud gaming service selection round-trips and rejects stale writes")
    func cloudGamingProviderSelection() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }

        #expect(await harness.store.loadSelectedCloudGamingProvider() == nil)

        await harness.store.saveSelectedCloudGamingProvider(
            .xboxCloudGaming,
            generation: 2
        )
        await harness.store.saveSelectedCloudGamingProvider(
            .geForceNow,
            generation: 1
        )

        #expect(
            await harness.store.loadSelectedCloudGamingProvider()
                == .xboxCloudGaming
        )

        await harness.store.saveSelectedCloudGamingProvider(nil, generation: 3)
        #expect(await harness.store.loadSelectedCloudGamingProvider() == nil)
    }

    @Test("Xbox Keychain stores only refresh credentials and rejects stale writes")
    func xboxCredentialPersistence() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let configuration = try MicrosoftDeviceCodeOAuthConfiguration(
            tenant: "consumers",
            clientID: "fixture-client",
            scopes: ["openid"]
        )
        let current = XboxAuthSession(
            configuration: configuration,
            token: MicrosoftOAuthToken(
                accessToken: "current",
                refreshToken: "refresh",
                idToken: nil,
                tokenType: "Bearer",
                scopes: ["openid"],
                expiresAt: .distantFuture
            )
        )
        var stale = current
        stale.token = MicrosoftOAuthToken(
            accessToken: "stale",
            refreshToken: "refresh",
            idToken: nil,
            tokenType: "Bearer",
            scopes: ["openid"],
            expiresAt: .distantFuture
        )

        try await harness.store.saveXboxAuthSession(current, generation: 2)
        try await harness.store.saveXboxAuthSession(stale, generation: 1)

        let restored = try #require(
            try await harness.store.loadXboxAuthSession()
        )
        #expect(restored.tenant == current.tenant)
        #expect(restored.clientID == current.clientID)
        #expect(restored.scopes == current.scopes)
        #expect(restored.token.accessToken.isEmpty)
        #expect(restored.token.idToken == nil)
        #expect(restored.token.refreshToken == "refresh")
        #expect(restored.token.expiresAt == .distantPast)
        let storedText = try #require(
            String(data: harness.xboxSecureStore.data, encoding: .utf8)
        )
        #expect(!storedText.contains("current"))
        #expect(!storedText.contains("stale"))
        #expect(!storedText.contains("accessToken"))
        #expect(!storedText.contains("idToken"))
        #expect(throws: FakeSecureStoreError.notFound) {
            _ = try harness.secureStore.load()
        }

        try await harness.store.deleteXboxAuthSession(generation: 3)
        await #expect(throws: FakeSecureStoreError.notFound) {
            _ = try await harness.store.loadXboxAuthSession()
        }
    }

    @Test("Legacy full Xbox OAuth records migrate silently to refresh-only storage")
    func xboxFullTokenMigration() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let configuration = try MicrosoftDeviceCodeOAuthConfiguration(
            tenant: "consumers",
            clientID: "fixture-client",
            scopes: ["openid", "offline_access"]
        )
        let legacy = XboxAuthSession(
            configuration: configuration,
            token: MicrosoftOAuthToken(
                accessToken: "legacy-access-secret",
                refreshToken: "legacy-refresh-secret",
                idToken: "legacy-id-secret",
                tokenType: "Bearer",
                scopes: configuration.scopes,
                expiresAt: .distantFuture
            ),
            activityScopeIdentifier: "stable-activity-scope"
        )
        try harness.xboxSecureStore.save(JSONEncoder().encode(legacy))

        let restored = try #require(
            try await harness.store.loadXboxAuthSession()
        )

        #expect(restored.token.accessToken.isEmpty)
        #expect(restored.token.idToken == nil)
        #expect(restored.token.refreshToken == "legacy-refresh-secret")
        #expect(restored.activityScopeIdentifier == "stable-activity-scope")
        let migratedText = try #require(
            String(data: harness.xboxSecureStore.data, encoding: .utf8)
        )
        #expect(!migratedText.contains("legacy-access-secret"))
        #expect(!migratedText.contains("legacy-id-secret"))
        #expect(migratedText.contains("legacy-refresh-secret"))
        #expect(migratedText.contains("\"schemaVersion\":1"))
    }

    @Test("Xbox stream settings persist independently from GeForce NOW settings")
    func xboxStreamSettingsPersistence() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        var geForceNowSettings = StreamSettings()
        geForceNowSettings.maxBitrateKbps = 42000
        let xboxSettings = XboxCloudStreamSettings(
            displayResolution: .qhd,
            codecPreference: .h265,
            gameLanguage: "de_DE",
            controllerDeadzone: 0.25,
            rumbleEnabled: false,
            rumbleIntensity: 0.6,
            enableTextToSpeech: true,
            magnifier: true,
            highContrast: true,
            enableOptionalDataCollection: true
        )

        await harness.store.saveStreamSettings(geForceNowSettings)
        await harness.store.saveXboxCloudStreamSettings(xboxSettings)

        #expect(
            await harness.store.loadXboxCloudStreamSettings() == xboxSettings
        )
        #expect(
            await harness.store.loadGamesSnapshot(accountScope: nil).streamSettings
                == geForceNowSettings
        )

        _ = await harness.store.clearCachedData()
        #expect(
            await harness.store.loadXboxCloudStreamSettings() == xboxSettings
        )

        _ = await harness.store.clearPersistentData()
        #expect(
            await harness.store.loadXboxCloudStreamSettings()
                == XboxCloudStreamSettings()
        )
    }

    @Test("A scoped GeForce NOW reset preserves every Xbox value and fence")
    func geForceNowScopedResetPreservesXboxData() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let xboxAccountScope = "preserved-xbox-account"
        let xboxSession = try makeXboxAuthSession()
        var geForceNowSettings = StreamSettings()
        geForceNowSettings.maxBitrateKbps = 42000
        let xboxSettings = XboxCloudStreamSettings(
            displayResolution: .qhd,
            gameLanguage: "de-DE"
        )
        try await harness.store.saveAuthSession(
            makeAuthSession(accessToken: "gfn-access"),
            generation: 1
        )
        try await harness.store.saveXboxAuthSession(
            xboxSession,
            generation: 1
        )
        await harness.store.saveFavoriteIds(["gfn-favorite"])
        await harness.store.saveStreamSettings(geForceNowSettings)
        await harness.store.saveXboxCloudStreamSettings(xboxSettings)
        await harness.store.saveXboxFavoriteIDs(
            ["xbox-favorite"],
            accountScope: xboxAccountScope
        )
        await harness.store.saveSelectedCloudGamingProvider(
            .xboxCloudGaming,
            generation: 1
        )
        let geForceNowFence = harness.store.authSessionResetGeneration()
        let xboxFence = harness.store.xboxAuthSessionResetGeneration()

        let result = await harness.store.clearPersistentData(
            for: .geForceNow
        )

        #expect(result.isComplete)
        #expect(result.provider == .geForceNow)
        #expect(result.credentialsRemoved)
        #expect(
            harness.store.authSessionResetGeneration() == geForceNowFence + 1
        )
        #expect(harness.store.xboxAuthSessionResetGeneration() == xboxFence)
        await #expect(throws: FakeSecureStoreError.notFound) {
            _ = try await harness.store.loadAuthSession()
        }
        let restoredXboxSession = try #require(
            try await harness.store.loadXboxAuthSession()
        )
        #expect(
            restoredXboxSession.token.refreshToken
                == xboxSession.token.refreshToken
        )
        let geForceNowSnapshot = await harness.store.loadGamesSnapshot(
            accountScope: nil
        )
        #expect(geForceNowSnapshot.favoriteIds.isEmpty)
        #expect(geForceNowSnapshot.streamSettings == nil)
        #expect(await harness.store.loadXboxCloudStreamSettings() == xboxSettings)
        #expect(
            await harness.store.loadXboxCatalogActivity(
                accountScope: xboxAccountScope
            ).favoriteIDs == ["XBOX-FAVORITE"]
        )
        #expect(
            await harness.store.loadSelectedCloudGamingProvider()
                == .xboxCloudGaming
        )
    }

    @Test("Xbox installation identity follows provider-scoped reset ownership")
    func xboxInstallationIdentityScopedReset() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let identity = XboxCloudInstallationIdentityStore(
            preferences: harness.preferences
        ).loadOrCreateSDKInstallID()

        _ = await harness.store.clearPersistentData(for: .geForceNow)

        #expect(
            harness.defaults.string(
                forKey: XboxCloudInstallationIdentityStore.preferenceKey
            ) == identity
        )

        _ = await harness.store.clearPersistentData(for: .xboxCloudGaming)

        #expect(
            harness.defaults.string(
                forKey: XboxCloudInstallationIdentityStore.preferenceKey
            ) == nil
        )
    }

    @Test("A scoped Xbox reset preserves every GeForce NOW value and fence")
    func xboxScopedResetPreservesGeForceNowData() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let xboxAccountScope = "removed-xbox-account"
        let geForceNowSession = makeAuthSession(accessToken: "gfn-access")
        var geForceNowSettings = StreamSettings()
        geForceNowSettings.maxBitrateKbps = 42000
        try await harness.store.saveAuthSession(
            geForceNowSession,
            generation: 1
        )
        try await harness.store.saveXboxAuthSession(
            makeXboxAuthSession(),
            generation: 1
        )
        await harness.store.saveFavoriteIds(["gfn-favorite"])
        await harness.store.saveStreamSettings(geForceNowSettings)
        await harness.store.saveXboxCloudStreamSettings(
            XboxCloudStreamSettings(displayResolution: .qhd)
        )
        await harness.store.saveXboxFavoriteIDs(
            ["xbox-favorite"],
            accountScope: xboxAccountScope
        )
        await harness.store.saveSelectedCloudGamingProvider(
            .geForceNow,
            generation: 1
        )
        let geForceNowFence = harness.store.authSessionResetGeneration()
        let xboxFence = harness.store.xboxAuthSessionResetGeneration()

        let result = await harness.store.clearPersistentData(
            for: .xboxCloudGaming
        )

        #expect(result.isComplete)
        #expect(result.provider == .xboxCloudGaming)
        #expect(result.credentialsRemoved)
        #expect(harness.store.authSessionResetGeneration() == geForceNowFence)
        #expect(
            harness.store.xboxAuthSessionResetGeneration() == xboxFence + 1
        )
        #expect(
            try await harness.store.loadAuthSession().tokens.accessToken
                == geForceNowSession.tokens.accessToken
        )
        let geForceNowSnapshot = await harness.store.loadGamesSnapshot(
            accountScope: nil
        )
        #expect(geForceNowSnapshot.favoriteIds == ["gfn-favorite"])
        #expect(geForceNowSnapshot.streamSettings == geForceNowSettings)
        await #expect(throws: FakeSecureStoreError.notFound) {
            _ = try await harness.store.loadXboxAuthSession()
        }
        #expect(
            await harness.store.loadXboxCloudStreamSettings()
                == XboxCloudStreamSettings()
        )
        #expect(
            await harness.store.loadXboxCatalogActivity(
                accountScope: xboxAccountScope
            ) == CloudCatalogActivitySnapshot()
        )
        #expect(
            await harness.store.loadSelectedCloudGamingProvider()
                == .geForceNow
        )
    }

    @Test("A scoped reset reports only its provider's credential failure")
    func scopedResetReportsTargetCredentialFailure() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        harness.xboxSecureStore.error = .injected

        let result = await harness.store.clearPersistentData(
            for: .xboxCloudGaming
        )

        #expect(!result.isComplete)
        #expect(!result.credentialsRemoved)
        #expect(result.failureDescription != nil)
        #expect(harness.secureStore.deleteCount == 0)
        #expect(harness.xboxSecureStore.deleteCount == 1)
    }

    @Test("A scoped Xbox cache clear preserves GeForce NOW disk caches")
    func xboxScopedCacheClearPreservesGeForceNowCaches() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        await harness.store.saveLibraryGames(
            [makeGame(id: "cached-game")],
            accountScope: "gfn-account"
        )
        let cachedNames = try FileManager.default.contentsOfDirectory(
            atPath: harness.cacheDirectory.path
        )
        #expect(cachedNames.contains { $0.hasPrefix("gfn.library.") })

        #expect(
            await harness.store.clearCachedData(
                for: .xboxCloudGaming
            ).isEmpty
        )
        let namesAfterXboxClear = try FileManager.default.contentsOfDirectory(
            atPath: harness.cacheDirectory.path
        )
        #expect(
            namesAfterXboxClear.contains { $0.hasPrefix("gfn.library.") }
        )

        #expect(
            await harness.store.clearCachedData(for: .geForceNow).isEmpty
        )
        let namesAfterGeForceNowClear = try FileManager.default
            .contentsOfDirectory(atPath: harness.cacheDirectory.path)
        #expect(
            !namesAfterGeForceNowClear.contains {
                $0.hasPrefix("gfn.library.")
            }
        )
    }

    @Test("Xbox favorites and history are account scoped and isolated from GeForce NOW")
    func xboxCatalogActivityIsolation() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let accountA = "xbox-account-a"
        let accountB = "xbox-account-b"

        await harness.store.saveFavoriteIds(["gfn-favorite"])
        await harness.store.saveRecentlyPlayedIds(["gfn-recent"])
        await harness.store.saveXboxFavoriteIDs(
            ["xbox-favorite-a"],
            accountScope: accountA
        )
        await harness.store.saveXboxRecentlyPlayedIDs(
            ["xbox-recent-a"],
            accountScope: accountA
        )
        await harness.store.saveXboxFavoriteIDs(
            ["xbox-favorite-b"],
            accountScope: accountB
        )

        #expect(
            await harness.store.loadXboxCatalogActivity(
                accountScope: accountA
            ) == CloudCatalogActivitySnapshot(
                favoriteIDs: ["xbox-favorite-a"],
                recentlyPlayedIDs: ["xbox-recent-a"]
            )
        )
        #expect(
            await harness.store.loadXboxCatalogActivity(
                accountScope: accountB
            ) == CloudCatalogActivitySnapshot(
                favoriteIDs: ["xbox-favorite-b"],
                recentlyPlayedIDs: []
            )
        )
        let geForceNowSnapshot = await harness.store.loadGamesSnapshot(
            accountScope: nil
        )
        #expect(geForceNowSnapshot.favoriteIds == ["gfn-favorite"])
        #expect(geForceNowSnapshot.recentlyPlayedIds == ["gfn-recent"])
        #expect(
            harness.preferences.keys().filter {
                $0.hasPrefix("cloudnow.catalog.activity.v1.")
            }.allSatisfy {
                $0.contains(".xbox-cloud-gaming.")
                    && !$0.contains(accountA)
                    && !$0.contains(accountB)
            }
        )
    }

    @MainActor
    @Test("Xbox favorites survive a recreated store and Xbox authorization")
    func xboxFavoritesSurviveStoreAndAuthorizationRecreation() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stableScope = "persisted-xbox-activity-scope"
        let configuration = try MicrosoftDeviceCodeOAuthConfiguration(
            tenant: "consumers",
            clientID: "fixture-client",
            scopes: ["openid", "offline_access"]
        )
        let session = XboxAuthSession(
            configuration: configuration,
            token: MicrosoftOAuthToken(
                accessToken: "fixture-access",
                refreshToken: "fixture-refresh",
                idToken: nil,
                tokenType: "Bearer",
                scopes: configuration.scopes,
                expiresAt: now.addingTimeInterval(3600)
            ),
            activityScopeIdentifier: stableScope
        )
        try await harness.store.saveXboxAuthSession(session, generation: 1)
        await harness.store.saveXboxFavoriteIDs(
            ["favorite-product"],
            accountScope: stableScope
        )

        let recreatedStore = harness.makeRecreatedStore()
        let authorization = PersistenceXboxAccountAuthorizationStub(
            account: XboxCloudAuthorizedAccount(
                authorizationIdentifier: "replacement-runtime-handle",
                activityScopeIdentifier: "newly-derived-activity-scope",
                displayName: nil,
                expiresAt: now.addingTimeInterval(3600)
            )
        )
        let oauth = PersistenceXboxOAuthClientStub(
            token: MicrosoftOAuthToken(
                accessToken: "refreshed-runtime-access",
                refreshToken: "fixture-refresh",
                idToken: "refreshed-runtime-id",
                tokenType: "Bearer",
                scopes: configuration.scopes,
                expiresAt: now.addingTimeInterval(3600)
            )
        )
        let manager = XboxAuthManager(
            environment: XboxCloudEnvironment(
                authentication: configuration,
                makeAccountAuthorizationClient: { authorization },
                service: nil
            ),
            oauthClient: oauth,
            persistence: recreatedStore,
            now: { now }
        )

        await manager.restorePersistedSession()
        await manager.activateXboxCloudAccess()

        let restoredAccount = try #require(manager.authorizedAccount)
        #expect(await oauth.refreshCount == 1)
        #expect(restoredAccount.activityScopeIdentifier == stableScope)
        #expect(
            await recreatedStore.loadXboxCatalogActivity(
                accountScope: restoredAccount.activityScopeIdentifier
            ).favoriteIDs == ["FAVORITE-PRODUCT"]
        )
    }

    @Test("Xbox history is normalized, bounded, and follows reset semantics")
    func xboxCatalogActivityBoundsAndReset() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let accountScope = " account-with-whitespace "
        let recentIDs = ["game-0", " game-1 ", "game-0", ""]
            + (2 ... 12).map { "game-\($0)" }

        await harness.store.saveXboxFavoriteIDs(
            [" favorite ", "", String(repeating: "x", count: 513)],
            accountScope: accountScope
        )
        await harness.store.saveXboxRecentlyPlayedIDs(
            recentIDs,
            accountScope: accountScope
        )

        #expect(
            await harness.store.loadXboxCatalogActivity(
                accountScope: "account-with-whitespace"
            ) == CloudCatalogActivitySnapshot(
                favoriteIDs: ["favorite"],
                recentlyPlayedIDs: (0 ... 9).map { "GAME-\($0)" }
            )
        )

        _ = await harness.store.clearCachedData()
        #expect(
            await harness.store.loadXboxCatalogActivity(
                accountScope: accountScope
            ).recentlyPlayedIDs == (0 ... 9).map { "GAME-\($0)" }
        )

        _ = await harness.store.clearPersistentData()
        #expect(
            await harness.store.loadXboxCatalogActivity(
                accountScope: accountScope
            ) == CloudCatalogActivitySnapshot()
        )
        #expect(
            await harness.store.loadXboxCatalogActivity(
                accountScope: nil
            ) == CloudCatalogActivitySnapshot()
        )
    }

    @Test("Xbox favorites are bounded and stale saves cannot cross reset")
    func xboxCatalogActivityGenerationFence() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let accountScope = "stable-xbox-activity-scope"
        let favoriteIDs = Set(
            (0 ..< CloudCatalogActivitySnapshot.maximumFavoriteCount + 32)
                .map { String(format: "game-%04d", $0) }
        )

        await harness.store.saveXboxFavoriteIDs(
            favoriteIDs,
            accountScope: accountScope
        )
        let lease = await harness.store.loadXboxCatalogActivityLease(
            accountScope: accountScope
        )
        #expect(
            lease.snapshot.favoriteIDs
                == Set(
                    favoriteIDs.map { $0.uppercased() }.sorted().prefix(
                        CloudCatalogActivitySnapshot.maximumFavoriteCount
                    )
                )
        )

        _ = await harness.store.clearPersistentData()
        await harness.store.saveXboxFavoriteIDs(
            ["must-not-return"],
            accountScope: accountScope,
            expectedGeneration: lease.generation
        )

        #expect(
            await harness.store.loadXboxCatalogActivity(
                accountScope: accountScope
            ).favoriteIDs.isEmpty
        )
    }

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

    @Test("VPC and subscription caches never cross account identities")
    func accountScopedCachesAreIsolated() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        let userA = accountCacheScope(idpId: "partner-dig", userId: "user-a")
        // Same provider, different user — the case a provider-only key cannot catch.
        let userB = accountCacheScope(idpId: "partner-dig", userId: "user-b")
        // Same user, different provider.
        let userAOnNvidia = accountCacheScope(idpId: "nvidia", userId: "user-a")
        let subscription = SubscriptionInfo(
            membershipTier: "ULTIMATE",
            isUnlimited: true,
            remainingMinutes: nil,
            totalMinutes: nil,
            entitledResolutions: []
        )

        await harness.store.saveVpcId("vpc-a", accountScope: userA)
        await harness.store.saveSubscription(subscription, accountScope: userA)

        let ownerSnapshot = await harness.store.loadGamesSnapshot(accountScope: userA)
        #expect(ownerSnapshot.vpcId == "vpc-a")
        #expect(ownerSnapshot.subscription?.membershipTier == "ULTIMATE")

        // A different user on the same provider must not inherit either value.
        let otherUserSnapshot = await harness.store.loadGamesSnapshot(accountScope: userB)
        #expect(otherUserSnapshot.vpcId == nil)
        #expect(otherUserSnapshot.subscription == nil)

        // Nor the same user arriving through a different provider.
        let otherProviderSnapshot = await harness.store.loadGamesSnapshot(accountScope: userAOnNvidia)
        #expect(otherProviderSnapshot.vpcId == nil)
        #expect(otherProviderSnapshot.subscription == nil)

        // A signed-out load has no identity to match, so it sees nothing.
        let signedOutSnapshot = await harness.store.loadGamesSnapshot(accountScope: nil)
        #expect(signedOutSnapshot.vpcId == nil)
        #expect(signedOutSnapshot.subscription == nil)
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
            credentialStore: harness.secureStore,
            xboxCredentialStore: harness.xboxSecureStore
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
        _ = await harness.store.clearPersistentData()
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

        _ = await harness.store.clearPersistentData()
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

    @Test("Reset reports secure deletion failures and attempts both accounts")
    func resetReportsCredentialDeletionFailures() async throws {
        let harness = try PersistenceHarness()
        defer { harness.cleanup() }
        harness.secureStore.error = .injected
        harness.xboxSecureStore.error = .injected

        let result = await harness.store.clearPersistentData()

        #expect(!result.isComplete)
        #expect(!result.geForceNowCredentialsRemoved)
        #expect(!result.xboxCredentialsRemoved)
        #expect(result.failedCredentialStoreCount == 2)
        #expect(harness.secureStore.deleteCount == 1)
        #expect(harness.xboxSecureStore.deleteCount == 1)
    }

    @Test("Reset reports each credential namespace independently")
    func resetReportsPartialCredentialDeletion() async throws {
        let geForceNowFailure = try PersistenceHarness()
        defer { geForceNowFailure.cleanup() }
        geForceNowFailure.secureStore.error = .injected

        let geForceNowResult = await geForceNowFailure.store.clearPersistentData()

        #expect(!geForceNowResult.geForceNowCredentialsRemoved)
        #expect(geForceNowResult.xboxCredentialsRemoved)
        #expect(geForceNowResult.failedCredentialStoreCount == 1)
        #expect(
            geForceNowResult.remainingProvider(preferring: .xboxCloudGaming)
                == .geForceNow
        )

        let xboxFailure = try PersistenceHarness()
        defer { xboxFailure.cleanup() }
        xboxFailure.xboxSecureStore.error = .injected

        let xboxResult = await xboxFailure.store.clearPersistentData()

        #expect(xboxResult.geForceNowCredentialsRemoved)
        #expect(!xboxResult.xboxCredentialsRemoved)
        #expect(xboxResult.failedCredentialStoreCount == 1)
        #expect(
            xboxResult.remainingProvider(preferring: .geForceNow)
                == .xboxCloudGaming
        )
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

    private func makeXboxAuthSession() throws -> XboxAuthSession {
        let configuration = try MicrosoftDeviceCodeOAuthConfiguration(
            tenant: "consumers",
            clientID: "fixture-client",
            scopes: ["openid", "offline_access"]
        )
        return XboxAuthSession(
            configuration: configuration,
            token: MicrosoftOAuthToken(
                accessToken: "xbox-runtime-access",
                refreshToken: "xbox-refresh",
                idToken: "xbox-runtime-id",
                tokenType: "Bearer",
                scopes: configuration.scopes,
                expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
            ),
            activityScopeIdentifier: "xbox-activity-scope"
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
    let xboxSecureStore: FakeSecureCredentialStore
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
        xboxSecureStore = FakeSecureCredentialStore()
        store = AppPersistenceStore(
            preferences: preferences,
            cacheDirectory: cacheDirectory,
            credentialStore: secureStore,
            xboxCredentialStore: xboxSecureStore
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    func makeRecreatedStore() -> AppPersistenceStore {
        AppPersistenceStore(
            preferences: preferences,
            cacheDirectory: cacheDirectory,
            credentialStore: secureStore,
            xboxCredentialStore: xboxSecureStore
        )
    }
}

private actor PersistenceXboxAccountAuthorizationStub: XboxCloudAccountAuthorizationClient {
    private let account: XboxCloudAuthorizedAccount

    init(account: XboxCloudAuthorizedAccount) {
        self.account = account
    }

    func authorize(
        microsoftToken _: MicrosoftOAuthToken
    ) -> XboxCloudAuthorizedAccount {
        account
    }
}

private actor PersistenceXboxOAuthClientStub: XboxOAuthClient {
    private let token: MicrosoftOAuthToken
    private(set) var refreshCount = 0

    init(token: MicrosoftOAuthToken) {
        self.token = token
    }

    func authenticate(
        configuration _: MicrosoftDeviceCodeOAuthConfiguration,
        onState _: @escaping @Sendable (MicrosoftDeviceCodeState) async -> Void
    ) -> MicrosoftOAuthToken {
        token
    }

    func refreshToken(
        configuration _: MicrosoftDeviceCodeOAuthConfiguration,
        refreshToken _: String
    ) -> MicrosoftOAuthToken {
        refreshCount += 1
        return token
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
    private var storedDeleteCount = 0

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

    var deleteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDeleteCount
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storedData ?? Data()
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
        storedDeleteCount += 1
        if let storedError {
            throw storedError
        }
        storedData = nil
    }
}
