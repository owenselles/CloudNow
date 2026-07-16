import Foundation
import os.log

/// Owns destructive app-storage maintenance away from the UI actor.
actor AppDataManager {
    static let shared = AppDataManager()

    private static let ownedCacheArtifacts = [
        "RTCEventLogs",
    ]

    private let fileManager = FileManager.default
    private let log = Logger(subsystem: "com.owenselles.CloudNow2", category: "AppData")

    /// Removes disposable data while preserving authentication and user preferences.
    func clearCaches() async throws {
        await HeroArtPrefetcher.shared.cancelAll()
        await BoxArtPrefetcher.shared.cancelAll()
        await ArtworkImagePipeline.shared.clearCache()
        URLCache.shared.removeAllCachedResponses()

        var failures = await AppPersistenceStore.shared.clearCachedData()
        if let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            for artifact in Self.ownedCacheArtifacts {
                let url = cachesURL.appendingPathComponent(artifact)
                do {
                    try fileManager.removeItem(at: url)
                } catch CocoaError.fileNoSuchFile {
                    // The system may purge cache files at any time. Already absent
                    // means the requested cleanup for this artifact succeeded.
                } catch {
                    failures.append(artifact)
                    log.error("Unable to remove cached item \(artifact, privacy: .public): \(error, privacy: .private)")
                }
            }
        }

        await ZoneClient.shared.clearCachedRoutingData()

        guard failures.isEmpty else {
            throw CacheClearError(failedItems: failures)
        }
    }

    /// Removes preferences and credentials after disposable caches were cleared.
    /// Authentication work must be cancelled before calling this method.
    func clearPersistentData() async {
        await AppPersistenceStore.shared.clearPersistentData()
    }
}

private struct CacheClearError: LocalizedError {
    let failedItems: [String]

    var errorDescription: String? {
        "Unable to remove \(failedItems.count) cached item(s)."
    }
}
