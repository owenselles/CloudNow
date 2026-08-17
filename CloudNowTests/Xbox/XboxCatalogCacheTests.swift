@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox catalog durable cache")
struct XboxCatalogCacheTests {
    private let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Durable cache survives memory release and remains fully scoped")
    func durableRoundTripAndIsolation() async {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let snapshot = makeSnapshot(id: "durable")
        let key = makeKey()
        let cache = XboxCatalogCache(directoryURL: directoryURL)

        await cache.store(snapshot, for: key)
        await cache.releaseMemory()

        #expect(await cache.snapshot(for: key) == snapshot)

        let recreated = XboxCatalogCache(directoryURL: directoryURL)
        #expect(await recreated.snapshot(for: key) == snapshot)
        #expect(
            await recreated.snapshot(
                for: makeKey(provider: "another-provider")
            ) == nil
        )
        #expect(await recreated.snapshot(for: makeKey(account: "other")) == nil)
        #expect(await recreated.snapshot(for: makeKey(locale: "de-DE")) == nil)
        #expect(await recreated.snapshot(for: makeKey(market: "DE")) == nil)

        let foreignKey = makeKey(provider: "another-provider")
        await recreated.store(makeSnapshot(id: "foreign"), for: foreignKey)
        let afterRejectedStore = XboxCatalogCache(directoryURL: directoryURL)
        #expect(await afterRejectedStore.snapshot(for: foreignKey) == nil)
    }

    @Test("Durable cache validates schema before serving stale data")
    func invalidSchemaIsRejected() async throws {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let key = makeKey()
        let cache = XboxCatalogCache(directoryURL: directoryURL)
        await cache.store(makeSnapshot(id: "schema"), for: key)

        let manifestURL = directoryURL.appendingPathComponent("catalog-v1.json")
        var object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: manifestURL)
            ) as? [String: Any]
        )
        object["schemaVersion"] = 999
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: manifestURL, options: [.atomic])

        let recreated = XboxCatalogCache(directoryURL: directoryURL)
        #expect(await recreated.snapshot(for: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: manifestURL.path))
    }

    @Test("Durable LRU eviction and account removal survive recreation")
    func durableEvictionAndRemoval() async {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let firstKey = makeKey(account: "first")
        let secondKey = makeKey(account: "second")
        let thirdKey = makeKey(account: "third")
        let first = makeSnapshot(id: "first")
        let second = makeSnapshot(id: "second")
        let third = makeSnapshot(id: "third")
        let cache = XboxCatalogCache(directoryURL: directoryURL, capacity: 2)

        await cache.store(first, for: firstKey)
        await cache.store(second, for: secondKey)
        #expect(await cache.snapshot(for: firstKey) == first)
        await cache.store(third, for: thirdKey)

        let recreated = XboxCatalogCache(directoryURL: directoryURL, capacity: 2)
        #expect(await recreated.snapshot(for: secondKey) == nil)
        #expect(await recreated.snapshot(for: firstKey) == first)
        #expect(await recreated.snapshot(for: thirdKey) == third)

        await recreated.remove(accountAuthorizationIdentifier: "first")
        let afterRemoval = XboxCatalogCache(
            directoryURL: directoryURL,
            capacity: 2
        )
        #expect(await afterRemoval.snapshot(for: firstKey) == nil)
        #expect(await afterRemoval.snapshot(for: thirdKey) == third)
    }

    @Test("Explicit cache clear removes memory and disk tiers")
    func explicitClearRemovesBothTiers() async throws {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let key = makeKey()
        let cache = XboxCatalogCache(directoryURL: directoryURL)
        await cache.store(makeSnapshot(id: "clear"), for: key)

        try await cache.clear()

        #expect(await cache.snapshot(for: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: directoryURL.path))
    }

    @Test("Account purge rolls back when durable persistence fails")
    func accountPurgeFailureRollsBack() async {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let key = makeKey()
        let snapshot = makeSnapshot(id: "purge-failure")
        let writer = XboxCatalogCache(directoryURL: directoryURL)
        await writer.store(snapshot, for: key)
        let failingCache = XboxCatalogCache(
            directoryURL: directoryURL,
            manifestWriter: { _, _, _ in
                throw XboxCatalogCacheDiskProbeError.writeFailed
            }
        )

        await #expect(throws: XboxCatalogCacheDiskProbeError.writeFailed) {
            try await failingCache.purge(
                accountAuthorizationIdentifier: key.accountAuthorizationIdentifier
            )
        }

        #expect(await failingCache.snapshot(for: key) == snapshot)
        let recreated = XboxCatalogCache(directoryURL: directoryURL)
        #expect(await recreated.snapshot(for: key) == snapshot)
    }

    private func makeKey(
        provider: String = XboxCatalogCacheKey.xboxProviderIdentifier,
        account: String = "stable-account",
        locale: String = "en-US",
        market: String = "US"
    ) -> XboxCatalogCacheKey {
        XboxCatalogCacheKey(
            providerIdentifier: provider,
            accountAuthorizationIdentifier: account,
            localeIdentifier: locale,
            market: market
        )
    }

    private func makeSnapshot(id: String) -> XboxCatalogSnapshot {
        XboxCatalogSnapshot(
            items: [
                XboxCatalogItem(
                    id: id,
                    title: "Game \(id)",
                    longDescription: "Durable fixture",
                    genres: ["Action"],
                    developer: "Developer",
                    publisher: "Publisher",
                    contentRating: "Teen",
                    artworkURL: URL(
                        string: "https://store-images.s-microsoft.com/\(id).jpg"
                    ),
                    heroArtworkURL: URL(
                        string: "https://store-images.s-microsoft.com/\(id)-hero.jpg"
                    ),
                    screenshotURLs: [
                        URL(
                            string: "https://store-images.s-microsoft.com/\(id)-screen.jpg"
                        ),
                    ].compactMap { $0 },
                    supportedInputTypes: [.controller, .mouseAndKeyboard],
                    isOwned: true,
                    routes: [
                        XboxCloudTitleRoute(
                            titleID: "\(id)-title",
                            accessKind: .standard,
                            availability: .playable,
                            playabilityReason: .contentAccessConfirmed
                        ),
                    ]
                ),
            ],
            fetchedAt: fetchedAt
        )
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "XboxCatalogCacheTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private enum XboxCatalogCacheDiskProbeError: Error {
    case writeFailed
}
