import Foundation
import os.log

nonisolated struct XboxCatalogCacheKey: Codable, Hashable, Sendable {
    static let xboxProviderIdentifier = "xbox-cloud-gaming"

    let providerIdentifier: String
    /// Stable, privacy-preserving account scope. The legacy field name is
    /// retained to avoid widening the cache API during the Xbox integration.
    let accountAuthorizationIdentifier: String
    let localeIdentifier: String
    let market: String?

    init(
        providerIdentifier: String = Self.xboxProviderIdentifier,
        accountAuthorizationIdentifier: String,
        localeIdentifier: String,
        market: String?
    ) {
        self.providerIdentifier = providerIdentifier
        self.accountAuthorizationIdentifier = accountAuthorizationIdentifier
        self.localeIdentifier = localeIdentifier
        self.market = market
    }

    fileprivate var isValidForPersistence: Bool {
        providerIdentifier == Self.xboxProviderIdentifier
            && Self.isSafeScope(providerIdentifier, maximumSize: 64)
            && Self.isSafeScope(
                accountAuthorizationIdentifier,
                maximumSize: 512
            )
            && Self.isSafeScope(localeIdentifier, maximumSize: 128)
            && (market.map {
                Self.isSafeScope($0, maximumSize: 16)
            } ?? true)
    }

    private static func isSafeScope(
        _ value: String,
        maximumSize: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumSize
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}

nonisolated protocol XboxCatalogCaching: Sendable {
    func snapshot(for key: XboxCatalogCacheKey) async -> XboxCatalogSnapshot?
    func store(
        _ snapshot: XboxCatalogSnapshot,
        for key: XboxCatalogCacheKey
    ) async
    func remove(accountAuthorizationIdentifier: String) async
    func purge(accountAuthorizationIdentifier: String) async throws
}

nonisolated extension XboxCatalogCaching {
    func purge(accountAuthorizationIdentifier: String) async throws {
        await remove(
            accountAuthorizationIdentifier: accountAuthorizationIdentifier
        )
    }
}

private nonisolated enum XboxCatalogCacheCost {
    static func estimate(of snapshot: XboxCatalogSnapshot) -> Int {
        snapshot.items.reduce(into: 0) { cost, item in
            cost += 128
            cost += item.id.utf8.count
            cost += item.title.utf8.count
            cost += item.longDescription?.utf8.count ?? 0
            cost += item.genres.reduce(0) { $0 + $1.utf8.count }
            cost += item.developer?.utf8.count ?? 0
            cost += item.publisher?.utf8.count ?? 0
            cost += item.contentRating?.utf8.count ?? 0
            cost += item.artworkURL?.absoluteString.utf8.count ?? 0
            cost += item.heroArtworkURL?.absoluteString.utf8.count ?? 0
            cost += item.screenshotURLs.reduce(0) {
                $0 + $1.absoluteString.utf8.count
            }
            cost += item.supportedInputTypes.count * 8
            for route in item.routes {
                cost += 16
                cost += route.titleID.utf8.count
            }
        }
    }
}

private nonisolated enum XboxCatalogCacheLimits {
    static let maximumEstimatedCost = 8 * 1024 * 1024
    static let maximumEncodedSize = 16 * 1024 * 1024
}

/// Bounded process-local implementation retained for isolated tests and
/// explicitly ephemeral clients.
actor XboxCatalogMemoryCache: XboxCatalogCaching {
    private struct Entry {
        let snapshot: XboxCatalogSnapshot
        let estimatedCost: Int
        var accessOrder: UInt64
    }

    private let capacity: Int
    private let maximumItemCount: Int
    private let maximumCost: Int
    private var accessOrder: UInt64 = 0
    private var totalCost = 0
    private var entries: [XboxCatalogCacheKey: Entry] = [:]

    init(
        capacity: Int = 2,
        maximumItemCount: Int = XboxCatalogSnapshot.maximumRetainedItemCount,
        maximumCost: Int = XboxCatalogCacheLimits.maximumEstimatedCost
    ) {
        self.capacity = max(1, capacity)
        self.maximumItemCount = max(1, maximumItemCount)
        self.maximumCost = max(1, maximumCost)
    }

    func snapshot(for key: XboxCatalogCacheKey) -> XboxCatalogSnapshot? {
        guard var entry = entries[key] else { return nil }
        accessOrder &+= 1
        entry.accessOrder = accessOrder
        entries[key] = entry
        return entry.snapshot
    }

    func store(
        _ snapshot: XboxCatalogSnapshot,
        for key: XboxCatalogCacheKey
    ) {
        let estimatedCost = XboxCatalogCacheCost.estimate(of: snapshot)
        if snapshot.items.count > maximumItemCount
            || estimatedCost > maximumCost
        {
            removeValue(forKey: key)
            return
        }

        accessOrder &+= 1
        removeValue(forKey: key)
        entries[key] = Entry(
            snapshot: snapshot,
            estimatedCost: estimatedCost,
            accessOrder: accessOrder
        )
        totalCost += estimatedCost

        while entries.count > capacity || totalCost > maximumCost {
            guard let oldestKey = entries.min(by: {
                $0.value.accessOrder < $1.value.accessOrder
            })?.key
            else {
                break
            }
            removeValue(forKey: oldestKey)
        }
    }

    func remove(accountAuthorizationIdentifier: String) {
        let matchingKeys = entries.keys.filter {
            $0.accountAuthorizationIdentifier == accountAuthorizationIdentifier
        }
        for key in matchingKeys {
            removeValue(forKey: key)
        }
    }

    func clear() {
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
    }

    private func removeValue(forKey key: XboxCatalogCacheKey) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        totalCost = max(0, totalCost - removed.estimatedCost)
    }
}

/// Production cache with a bounded in-memory tier and an atomically replaced
/// cache-directory manifest. Cached content is disposable, account-scoped,
/// and safe to use stale while explicit refresh follows the existing policy.
actor XboxCatalogCache: XboxCatalogCaching {
    nonisolated static let shared = XboxCatalogCache()

    private struct Entry {
        let snapshot: XboxCatalogSnapshot
        let estimatedCost: Int
        var accessOrder: UInt64
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let entries: [ManifestEntry]
    }

    private struct ManifestEntry: Codable {
        let key: XboxCatalogCacheKey
        let snapshot: XboxCatalogSnapshot
        let accessOrder: UInt64
    }

    private static let schemaVersion = 1
    private static let directoryName = "XboxCatalog"
    private static let manifestName = "catalog-v1.json"
    private static let log = Logger(
        subsystem: "com.owenselles.CloudNow2",
        category: "XboxCatalogCache"
    )

    private let directoryURL: URL
    private let capacity: Int
    private let maximumItemCount: Int
    private let maximumCost: Int
    private let maximumEncodedSize: Int
    private let manifestWriter: @Sendable (
        _ data: Data?,
        _ directoryURL: URL,
        _ manifestURL: URL
    ) throws -> Void
    private var didLoadManifest = false
    private var accessOrder: UInt64 = 0
    private var totalCost = 0
    private var entries: [XboxCatalogCacheKey: Entry] = [:]

    init(
        directoryURL: URL? = nil,
        capacity: Int = 2,
        maximumItemCount: Int = XboxCatalogSnapshot.maximumRetainedItemCount,
        maximumCost: Int = XboxCatalogCacheLimits.maximumEstimatedCost,
        maximumEncodedSize: Int = XboxCatalogCacheLimits.maximumEncodedSize,
        manifestWriter: @escaping @Sendable (
            _ data: Data?,
            _ directoryURL: URL,
            _ manifestURL: URL
        ) throws -> Void = XboxCatalogCache.writeManifest
    ) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
        self.capacity = max(1, capacity)
        self.maximumItemCount = max(1, maximumItemCount)
        self.maximumCost = max(1, maximumCost)
        self.maximumEncodedSize = max(1024, maximumEncodedSize)
        self.manifestWriter = manifestWriter
    }

    func snapshot(for key: XboxCatalogCacheKey) -> XboxCatalogSnapshot? {
        loadManifestIfNeeded()
        guard var entry = entries[key] else { return nil }
        entry.accessOrder = nextAccessOrder()
        entries[key] = entry
        return entry.snapshot
    }

    func store(
        _ snapshot: XboxCatalogSnapshot,
        for key: XboxCatalogCacheKey
    ) {
        loadManifestIfNeeded()
        let estimatedCost = XboxCatalogCacheCost.estimate(of: snapshot)
        guard key.isValidForPersistence,
              snapshot.items.count <= maximumItemCount,
              estimatedCost <= maximumCost
        else {
            removeValue(forKey: key)
            persistBestEffort()
            return
        }

        removeValue(forKey: key)
        entries[key] = Entry(
            snapshot: snapshot,
            estimatedCost: estimatedCost,
            accessOrder: nextAccessOrder()
        )
        totalCost += estimatedCost
        evictIfNeeded()
        persistBestEffort()
    }

    func remove(accountAuthorizationIdentifier: String) {
        loadManifestIfNeeded()
        let matchingKeys = entries.keys.filter {
            $0.accountAuthorizationIdentifier == accountAuthorizationIdentifier
        }
        for key in matchingKeys {
            removeValue(forKey: key)
        }
        persistBestEffort()
    }

    /// Logout requires a durable account-scoped purge. Roll back the decoded
    /// tier if atomic persistence fails so the signed-in session keeps a
    /// coherent stale-first cache.
    func purge(accountAuthorizationIdentifier: String) async throws {
        loadManifestIfNeeded()
        let matchingKeys = entries.keys.filter {
            $0.accountAuthorizationIdentifier == accountAuthorizationIdentifier
        }
        let previousEntries = entries
        let previousTotalCost = totalCost
        let previousAccessOrder = accessOrder
        for key in matchingKeys {
            removeValue(forKey: key)
        }
        do {
            try persist()
        } catch {
            entries = previousEntries
            totalCost = previousTotalCost
            accessOrder = previousAccessOrder
            throw error
        }
    }

    /// Memory pressure drops decoded rows without deleting the stale-first disk
    /// tier. A later Xbox entry lazily decodes the bounded manifest again.
    func releaseMemory() {
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
        accessOrder = 0
        didLoadManifest = false
    }

    /// User-requested cache maintenance removes both tiers and surfaces disk
    /// failures so the settings workflow can report incomplete work.
    func clear() throws {
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
        accessOrder = 0
        didLoadManifest = true
        do {
            try FileManager.default.removeItem(at: directoryURL)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    private nonisolated static func defaultDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    private nonisolated static func writeManifest(
        _ data: Data?,
        directoryURL: URL,
        manifestURL: URL
    ) throws {
        guard let data else {
            do {
                try FileManager.default.removeItem(at: manifestURL)
            } catch CocoaError.fileNoSuchFile {
                return
            }
            return
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try data.write(to: manifestURL, options: [.atomic])
    }

    private var manifestURL: URL {
        directoryURL.appendingPathComponent(Self.manifestName)
    }

    private func loadManifestIfNeeded() {
        guard !didLoadManifest else { return }
        didLoadManifest = true
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
        accessOrder = 0
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return
        }

        do {
            let values = try manifestURL.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize,
                  fileSize <= maximumEncodedSize
            else {
                throw CocoaError(.fileReadTooLarge)
            }
            let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.schemaVersion == Self.schemaVersion,
                  manifest.entries.count <= max(capacity * 4, capacity)
            else {
                throw CocoaError(.fileReadCorruptFile)
            }

            var seenKeys = Set<XboxCatalogCacheKey>()
            for manifestEntry in manifest.entries {
                let key = manifestEntry.key
                let snapshot = manifestEntry.snapshot
                let estimatedCost = XboxCatalogCacheCost.estimate(of: snapshot)
                guard key.isValidForPersistence,
                      seenKeys.insert(key).inserted,
                      snapshot.items.count <= maximumItemCount,
                      estimatedCost <= maximumCost
                else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                entries[key] = Entry(
                    snapshot: snapshot,
                    estimatedCost: estimatedCost,
                    accessOrder: manifestEntry.accessOrder
                )
                totalCost += estimatedCost
                accessOrder = max(accessOrder, manifestEntry.accessOrder)
            }
            evictIfNeeded()
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            entries.removeAll(keepingCapacity: false)
            totalCost = 0
            accessOrder = 0
            try? FileManager.default.removeItem(at: manifestURL)
            Self.log.error(
                "Discarded invalid Xbox catalog cache: \(error, privacy: .private)"
            )
        }
    }

    private func persistBestEffort() {
        do {
            try persist()
        } catch {
            Self.log.error(
                "Unable to persist Xbox catalog cache: \(error, privacy: .private)"
            )
        }
    }

    private func persist() throws {
        if entries.isEmpty {
            try manifestWriter(nil, directoryURL, manifestURL)
            return
        }

        let orderedEntries = entries.map { key, entry in
            ManifestEntry(
                key: key,
                snapshot: entry.snapshot,
                accessOrder: entry.accessOrder
            )
        }.sorted {
            if $0.accessOrder != $1.accessOrder {
                return $0.accessOrder < $1.accessOrder
            }
            return Self.stableKey($0.key) < Self.stableKey($1.key)
        }
        let manifest = Manifest(
            schemaVersion: Self.schemaVersion,
            entries: orderedEntries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= maximumEncodedSize else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try manifestWriter(data, directoryURL, manifestURL)
    }

    private nonisolated static func stableKey(_ key: XboxCatalogCacheKey) -> String {
        [
            key.providerIdentifier,
            key.accountAuthorizationIdentifier,
            key.localeIdentifier,
            key.market ?? "",
        ].joined(separator: "|")
    }

    private func nextAccessOrder() -> UInt64 {
        if accessOrder == .max {
            let orderedKeys = entries.sorted {
                $0.value.accessOrder < $1.value.accessOrder
            }.map(\.key)
            for (index, key) in orderedKeys.enumerated() {
                entries[key]?.accessOrder = UInt64(index + 1)
            }
            accessOrder = UInt64(orderedKeys.count)
        }
        accessOrder += 1
        return accessOrder
    }

    private func evictIfNeeded() {
        while entries.count > capacity || totalCost > maximumCost {
            guard let oldestKey = entries.min(by: {
                $0.value.accessOrder < $1.value.accessOrder
            })?.key
            else {
                break
            }
            removeValue(forKey: oldestKey)
        }
    }

    private func removeValue(forKey key: XboxCatalogCacheKey) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        totalCost = max(0, totalCost - removed.estimatedCost)
    }
}
