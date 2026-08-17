import Foundation
import os.log

/// Shared artwork and URL responses cannot be attributed to one provider.
/// Provider-scoped maintenance therefore preserves them; only an app-wide
/// cache clear may evict those shared resources.
nonisolated enum AppCacheClearScope: Equatable, Sendable {
    case allProviders
    case provider(CloudGamingProvider)

    var clearsSharedArtworkAndURLResponses: Bool {
        self == .allProviders
    }
}

/// Owns destructive app-storage maintenance away from the UI actor.
actor AppDataManager {
    static let shared = AppDataManager()

    private static let geForceNowOwnedCacheArtifacts = [
        "RTCEventLogs",
    ]
    private static let xboxOwnedCacheArtifacts = [
        "XboxRTCEventLogs",
    ]
    private static let ownedCacheArtifacts =
        geForceNowOwnedCacheArtifacts + xboxOwnedCacheArtifacts

    private let fileManager = FileManager.default
    private let log = Logger(subsystem: "com.owenselles.CloudNow2", category: "AppData")

    /// Removes disposable data while preserving authentication and user preferences.
    func clearCaches() async throws {
        var failures: [String] = []
        await HeroArtPrefetcher.shared.cancelAll()
        await BoxArtPrefetcher.shared.cancelAll()
        do {
            try await XboxCatalogCache.shared.clear()
        } catch {
            failures.append("XboxCatalog")
            log.error(
                "Unable to clear Xbox catalog cache: \(error, privacy: .private)"
            )
        }
        await clearSharedArtworkAndURLResponses(for: .allProviders)

        await failures.append(
            contentsOf: AppPersistenceStore.shared.clearCachedData()
        )
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

    /// Removes disposable data owned by one provider. Shared decoded artwork and
    /// URL responses are preserved because they cannot be attributed safely.
    func clearCaches(for provider: CloudGamingProvider) async throws {
        var failures: [String] = []
        switch provider {
        case .geForceNow:
            await HeroArtPrefetcher.shared.cancelAll()
            await BoxArtPrefetcher.shared.cancelAll()
            failures = await AppPersistenceStore.shared.clearCachedData(
                for: provider
            )
            failures.append(
                contentsOf: clearOwnedCacheArtifacts(
                    Self.geForceNowOwnedCacheArtifacts
                )
            )
            await ZoneClient.shared.clearCachedRoutingData()
        case .xboxCloudGaming:
            do {
                try await XboxCatalogCache.shared.clear()
            } catch {
                failures.append("XboxCatalog")
                log.error(
                    "Unable to clear Xbox catalog cache: \(error, privacy: .private)"
                )
            }
            await failures.append(
                contentsOf: AppPersistenceStore.shared.clearCachedData(
                    for: provider
                )
            )
            failures.append(
                contentsOf: clearOwnedCacheArtifacts(
                    Self.xboxOwnedCacheArtifacts
                )
            )
        }
        await clearSharedArtworkAndURLResponses(for: .provider(provider))

        guard failures.isEmpty else {
            throw CacheClearError(failedItems: failures)
        }
    }

    /// Removes preferences and credentials after disposable caches were cleared.
    /// Authentication work must be cancelled before calling this method.
    func clearPersistentData() async -> PersistentDataClearResult {
        await AppPersistenceStore.shared.clearPersistentData()
    }

    /// Removes preferences and credentials owned by one provider.
    func clearPersistentData(
        for provider: CloudGamingProvider
    ) async -> ProviderPersistentDataClearResult {
        await AppPersistenceStore.shared.clearPersistentData(for: provider)
    }

    private func clearOwnedCacheArtifacts(
        _ artifacts: [String]
    ) -> [String] {
        guard let cachesURL = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first
        else {
            return []
        }
        var failures: [String] = []
        for artifact in artifacts {
            let url = cachesURL.appendingPathComponent(artifact)
            do {
                try fileManager.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                failures.append(artifact)
                log.error(
                    "Unable to remove cached item \(artifact, privacy: .public): \(error, privacy: .private)"
                )
            }
        }
        return failures
    }

    private func clearSharedArtworkAndURLResponses(
        for scope: AppCacheClearScope
    ) async {
        guard scope.clearsSharedArtworkAndURLResponses else { return }
        await ArtworkImagePipeline.shared.clearCache()
        URLCache.shared.removeAllCachedResponses()
    }
}

private struct CacheClearError: LocalizedError {
    let failedItems: [String]

    var errorDescription: String? {
        "Unable to remove \(failedItems.count) cached item(s)."
    }
}
