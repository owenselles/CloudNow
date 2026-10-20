@testable import CloudNow
import Foundation
import Testing

@Suite("Install-to-Play launch policy")
@MainActor
struct GFNInstallToPlayLaunchTests {
    @Test("Ready-to-play games retain ordinary routing without storage")
    func readyToPlayBypassesStorage() throws {
        var game = makeGame()
        game.playType = .readyToPlay
        let membership = subscription(storage: nil)
        #expect(try GFNInstallToPlayLaunch.storage(for: game, variantId: "123", subscription: membership) == nil)
    }

    @Test("Playable and time-capped Install-to-Play accounts can launch", arguments: [
        "PLAYABLE", "UNPLAYABLE_DUE_TO_TIME_CAPPED_LIMIT",
    ])
    func allowedPlayability(playability: String) throws {
        var game = makeGame()
        game.playabilityState = playability
        let storage = makeStorage()
        #expect(try GFNInstallToPlayLaunch.storage(
            for: game, variantId: "123", subscription: subscription(storage: storage)
        ) == storage)
    }

    @Test("Upgrade-required, missing and unknown eligibility cannot launch", arguments: [
        "UNPLAYABLE_DUE_TO_UPGRADE", "UNKNOWN", "FUTURE_STATE", "",
    ])
    func unavailablePlayability(playability: String) {
        var game = makeGame()
        game.playabilityState = playability.isEmpty ? nil : playability
        #expect(throws: GFNInstallToPlayError.self) {
            try GFNInstallToPlayLaunch.storage(
                for: game, variantId: "123", subscription: subscription(storage: makeStorage())
            )
        }
    }

    @Test("Unknown game classification cannot be treated as Install-to-Play", arguments: [
        GamePlayType?.none, .some(.unknown),
    ])
    func unknownClassification(playType: GamePlayType?) {
        var game = makeGame()
        game.playType = playType
        #expect(throws: GFNInstallToPlayError.self) {
            try GFNInstallToPlayLaunch.storage(
                for: game, variantId: "123", subscription: subscription(storage: makeStorage())
            )
        }
    }

    @Test("Explicit account denial, unavailable variants and missing variants block launch", arguments: [0, 1, 2])
    func unavailableAccountOrVariant(scenario: Int) {
        var game = makeGame()
        var membership = subscription(storage: makeStorage())
        if scenario == 0 {
            membership.installToPlayAccess = false
        }
        if scenario == 1 {
            game.variants[0].playStatus = "NOT_PLAYABLE"
        }
        #expect(throws: GFNInstallToPlayError.self) {
            try GFNInstallToPlayLaunch.storage(
                for: game, variantId: scenario == 2 ? "missing" : "123", subscription: membership
            )
        }
    }

    @Test("Manual ownership does not inherit platform-sync playability restrictions")
    func manualOwnershipRemainsLaunchable() throws {
        var game = makeGame()
        game.variants[0].libraryStatus = "MANUAL"
        game.variants[0].playStatus = "NOT_PLAYABLE"
        let storage = makeStorage()
        #expect(try GFNInstallToPlayLaunch.storage(
            for: game, variantId: "123", subscription: subscription(storage: storage)
        ) == storage)
    }

    @Test("An existing installation does not require space for a second copy")
    func capacityAndInstalledBypass() throws {
        var game = makeGame()
        game.variants[0].minimumSizeInBytes = 20 * 1_073_741_824
        let storage = makeStorage(kind: .persistent, totalGB: 100, usedGB: 100)
        let membership = subscription(storage: storage)
        #expect(throws: GFNInstallToPlayError.self) {
            try GFNInstallToPlayLaunch.storage(for: game, variantId: "123", subscription: membership)
        }
        game.variants[0].isInstalled = true
        #expect(try GFNInstallToPlayLaunch.storage(for: game, variantId: "123", subscription: membership) == storage)
    }

    @Test("Single-session capacity uses the entire allocation")
    func singleSessionCapacity() throws {
        var game = makeGame()
        game.variants[0].minimumSizeInBytes = 100 * 1_073_741_824
        let storage = makeStorage(totalGB: 100, usedGB: 90)
        let membership = subscription(storage: storage)
        #expect(try GFNInstallToPlayLaunch.storage(for: game, variantId: "123", subscription: membership) == storage)
        game.variants[0].minimumSizeInBytes = 100 * 1_073_741_824 + 1
        #expect(throws: GFNInstallToPlayError.self) {
            try GFNInstallToPlayLaunch.storage(for: game, variantId: "123", subscription: membership)
        }
    }

    @Test("Missing storage blocks launch")
    func missingStorage() {
        #expect(throws: GFNInstallToPlayError.self) {
            try GFNInstallToPlayLaunch.storage(
                for: makeGame(), variantId: "123", subscription: subscription(storage: nil)
            )
        }
    }

    @Test("Provider storage diagnostics defer capacity handling to the streamed session", arguments: [
        "STORAGE_DOES_NOT_EXIST", "STORAGE_IN_ERROR", "UNKNOWN", "FUTURE_STATUS",
    ])
    func storageDiagnosticStillAllowsLaunch(status: String) throws {
        var game = makeGame()
        game.variants[0].minimumSizeInBytes = 20 * 1_073_741_824
        let storage = makeStorage(status: status, totalGB: 0)
        #expect(try GFNInstallToPlayLaunch.storage(
            for: game, variantId: "123", subscription: subscription(storage: storage)
        ) == storage)
    }

    @Test("Unrecognized storage kinds cannot launch")
    func unknownStorageKind() {
        #expect(throws: GFNInstallToPlayError.self) {
            try GFNInstallToPlayLaunch.storage(
                for: makeGame(), variantId: "123", subscription: subscription(storage: makeStorage(kind: .unknown))
            )
        }
    }

    @Test("Persistent storage selects its provider region case-insensitively")
    func storageRegionOverridesPreference() {
        let storage = makeStorage(kind: .persistent, region: " eu central ")
        let other = GFNRegion(name: "US East", address: "https://us.invalid/")
        let expected = GFNRegion(name: "EU Central", address: "https://eu.invalid/")
        #expect(GFNInstallToPlayLaunch.region(for: storage, regions: [other, expected]) == expected)
    }

    @Test("Missing or unmatched persistent regions retain provider routing", arguments: [nil, "", "Unknown region"])
    func persistentRegionFallback(region: String?) {
        let storage = makeStorage(kind: .persistent, region: region)
        #expect(GFNInstallToPlayLaunch.region(
            for: storage,
            regions: [GFNRegion(name: "EU Central", address: "https://eu.invalid/")]
        ) == nil)
    }

    @Test("Single-session storage always retains ordinary routing", arguments: [nil, "", "EU Central", "Unknown region"])
    func singleSessionRetainsRouting(region: String?) {
        #expect(GFNInstallToPlayLaunch.region(
            for: makeStorage(region: region),
            regions: [GFNRegion(name: "EU Central", address: "https://eu.invalid/")]
        ) == nil)
    }

    private func makeGame() -> GameInfo {
        var game = TestGameFactory.make(id: "game", title: "Game", isInLibrary: true)
        game.playType = .installToPlay
        game.playabilityState = "PLAYABLE"
        game.variants = [
            GameVariant(
                id: "123", appStore: "STEAM", isOwned: true, isInstalled: false,
                playStatus: "PLAYABLE", libraryStatus: "PLATFORM_SYNC"
            ),
        ]
        return game
    }

    private func subscription(storage: GFNCloudStorage?) -> SubscriptionInfo {
        SubscriptionInfo(
            membershipTier: "Performance", isUnlimited: false, remainingMinutes: 0, totalMinutes: 6000,
            entitledResolutions: [], cloudStorage: storage, installToPlayAccess: true
        )
    }

    private func makeStorage(
        kind: GFNCloudStorage.Kind = .singleSession,
        status: String? = "OK",
        totalGB: Int = 100,
        usedGB: Int = 0,
        region: String? = nil
    ) -> GFNCloudStorage {
        GFNCloudStorage(
            kind: kind, status: status, totalGB: totalGB, usedGB: usedGB, regionCode: nil, regionName: region
        )
    }
}
