import Foundation

/// Metadata returned by the persisted app-metadata query. Dynamic browse fields
/// such as ownership, variants, and supported features intentionally stay out of
/// this cache so every Library refresh continues to use current browse data.
nonisolated struct CachedGameMetadata: Codable, Equatable, Sendable {
    let title: String?
    let longDescription: String?
    let genres: [String]?
    let developer: String?
    let publisher: String?
    let contentRating: String?
    let boxArtUrl: String?
    let tvBannerUrl: String?
    let heroImageUrl: String?
    let screenshots: [String]
}

/// A nil metadata value records a successful query that omitted the requested
/// app ID. This short-lived tombstone prevents an unchanged refresh from
/// immediately requesting the same unavailable record again.
nonisolated struct GameMetadataCacheEntry: Codable, Equatable, Sendable {
    let metadata: CachedGameMetadata?
    let refreshedAt: Date
}

/// The generation makes cache clearing a barrier: enrichment started before a
/// clear cannot recreate files after the clear completes.
nonisolated struct GameMetadataCacheSnapshot: Sendable {
    let entries: [String: GameMetadataCacheEntry]
    let generation: UInt64
}

nonisolated protocol GameMetadataCacheStore: Actor {
    func currentGameMetadataCacheGeneration() -> UInt64

    func loadGameMetadataCache(
        localeCode: String,
        vpcId: String
    ) -> GameMetadataCacheSnapshot

    func mergeGameMetadataCache(
        _ updates: [String: GameMetadataCacheEntry],
        localeCode: String,
        vpcId: String,
        pruningBefore: Date,
        maximumEntryCount: Int,
        expectedGeneration: UInt64
    )
}

extension AppPersistenceStore: GameMetadataCacheStore {}
