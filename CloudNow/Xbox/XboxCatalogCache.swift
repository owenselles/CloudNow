import Foundation

nonisolated struct XboxCatalogCacheKey: Hashable, Sendable {
    /// Stable, privacy-preserving account scope. The legacy field name is
    /// retained to avoid widening the cache API during the Xbox integration.
    let accountAuthorizationIdentifier: String
    let localeIdentifier: String
    let market: String?
}

nonisolated protocol XboxCatalogCaching: Sendable {
    func snapshot(for key: XboxCatalogCacheKey) async -> XboxCatalogSnapshot?
    func store(
        _ snapshot: XboxCatalogSnapshot,
        for key: XboxCatalogCacheKey
    ) async
    func remove(accountAuthorizationIdentifier: String) async
}

/// Tiny process-local cache. It gives provider re-entry a stale-first catalog
/// without adding a package, disk schema, or unbounded account data.
actor XboxCatalogMemoryCache: XboxCatalogCaching {
    static let shared = XboxCatalogMemoryCache()

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
        maximumCost: Int = 2 * 1024 * 1024
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
        let estimatedCost = estimateCost(of: snapshot)
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

    private func estimateCost(of snapshot: XboxCatalogSnapshot) -> Int {
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

    private func removeValue(forKey key: XboxCatalogCacheKey) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        totalCost = max(0, totalCost - removed.estimatedCost)
    }
}
