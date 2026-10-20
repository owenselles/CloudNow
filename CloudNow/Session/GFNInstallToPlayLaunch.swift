import Foundation

/// Only new Install-to-Play sessions use these checks. Existing sessions retain their original route.
enum GFNInstallToPlayLaunch {
    static func storage(
        for game: GameInfo,
        variantId: String,
        subscription: SubscriptionInfo
    ) throws -> GFNCloudStorage? {
        if game.playType == .readyToPlay {
            return nil
        }
        guard game.isInstallToPlay else { throw GFNInstallToPlayError.statusUnavailable }
        guard game.playabilityState != nil, game.playabilityState != "UNKNOWN" else {
            throw GFNInstallToPlayError.statusUnavailable
        }
        guard game.playabilityState == "PLAYABLE" || game.playabilityState == "UNPLAYABLE_DUE_TO_TIME_CAPPED_LIMIT",
              subscription.installToPlayAccess != false
        else { throw GFNInstallToPlayError.unavailable }
        guard let variant = game.variants.first(where: { $0.id == variantId }) else {
            throw GFNInstallToPlayError.statusUnavailable
        }
        if variant.libraryStatus == "PLATFORM_SYNC", variant.playStatus == "NOT_PLAYABLE" {
            throw GFNInstallToPlayError.unavailable
        }
        guard let storage = subscription.cloudStorage, storage.kind != .unknown else {
            throw GFNInstallToPlayError.storageUnavailable
        }
        if storage.isUsable, variant.isInstalled != true,
           let required = variant.minimumSizeInBytes, required > 0,
           let available = storage.availableBytes, required > available
        {
            throw GFNInstallToPlayError.storageFull
        }
        return storage
    }

    static func region(for storage: GFNCloudStorage, regions: [GFNRegion]) -> GFNRegion? {
        guard storage.isPersistent,
              let name = storage.regionName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return nil }
        return regions.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Resolve localized text on the UI actor, then carry the immutable message across error boundaries.
nonisolated struct GFNInstallToPlayError: Error, LocalizedError {
    let errorDescription: String?

    @MainActor static var statusUnavailable: Self {
        Self(errorDescription: L10n.text("install_to_play_status_failed"))
    }

    @MainActor static var unavailable: Self {
        Self(errorDescription: L10n.text("install_to_play_unavailable"))
    }

    @MainActor static var storageUnavailable: Self {
        Self(errorDescription: L10n.text("install_to_play_storage_unavailable"))
    }

    @MainActor static var storageFull: Self {
        Self(errorDescription: L10n.text("install_to_play_storage_full"))
    }
}
