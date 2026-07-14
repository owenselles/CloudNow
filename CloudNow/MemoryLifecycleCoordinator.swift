import Foundation

extension Notification.Name {
    static let artworkLoadingDidResume = Notification.Name(
        "com.owenselles.CloudNow.artworkLoadingDidResume"
    )
}

/// Coordinates memory cleanup at ownership and lifecycle boundaries. Small state changes and task
/// cancellation happen immediately on the main actor; decoded-image eviction runs on the artwork
/// actor and is sequenced so rapid lifecycle changes cannot be applied out of order.
@MainActor
final class MemoryLifecycleCoordinator {
    static let shared = MemoryLifecycleCoordinator()

    private var isAppActive = true
    private var isStreamOpen = false
    private var isStreaming = false
    private var cleanupSequence: Task<Void, Never>?

    private init() {}

    func streamWillOpen() {
        guard !isStreamOpen else { return }
        isStreamOpen = true
        isStreaming = false
        HeroArtPrefetcher.shared.suspend(cancelActive: false)
        BoxArtPrefetcher.shared.suspend()
        enqueue(.streamOpening)
    }

    func streamDidStart() {
        guard isStreamOpen, !isStreaming else { return }
        isStreaming = true
        HeroArtPrefetcher.shared.suspend(cancelActive: true)
        BoxArtPrefetcher.shared.suspend()
        enqueue(.streaming)
    }

    func streamDidLeavePlayback() {
        guard isStreamOpen, isStreaming else { return }
        isStreaming = false
        enqueue(isAppActive ? .streamOpening : .background)
    }

    func streamDidClose() {
        guard isStreamOpen || isStreaming else { return }
        isStreamOpen = false
        isStreaming = false
        if isAppActive {
            enqueue(.foreground)
        } else {
            enqueue(.background)
        }
    }

    func appDidEnterBackground() {
        guard isAppActive else { return }
        isAppActive = false
        HeroArtPrefetcher.shared.suspend(cancelActive: true)
        BoxArtPrefetcher.shared.suspend()
        enqueue(.background)
    }

    func appDidBecomeActive() {
        guard !isAppActive else { return }
        isAppActive = true
        if isStreaming {
            enqueue(.streaming)
        } else if isStreamOpen {
            enqueue(.streamOpening)
        } else {
            enqueue(.foreground)
        }
    }

    func didReceiveMemoryWarning() {
        releaseCachedArtwork()
    }

    func releaseCachedArtwork() {
        HeroArtPrefetcher.shared.cancelAll()
        BoxArtPrefetcher.shared.cancelAll()
        enqueue(.memoryWarning)
    }

    private func enqueue(_ event: ArtworkMemoryEvent) {
        let previous = cleanupSequence
        cleanupSequence = Task(priority: .utility) { @concurrent in
            await previous?.value
            await ArtworkImagePipeline.shared.handleMemoryEvent(event)
            await MemoryLifecycleCoordinator.shared.didApply(event)
        }
    }

    private func didApply(_ event: ArtworkMemoryEvent) {
        guard isAppActive, !isStreaming else { return }
        if event == .foreground, !isStreamOpen {
            HeroArtPrefetcher.shared.resume()
            BoxArtPrefetcher.shared.resume()
        }
        guard event == .foreground
            || (event == .streamOpening && isStreamOpen)
            || event == .memoryWarning
        else { return }
        NotificationCenter.default.post(name: .artworkLoadingDidResume, object: nil)
    }
}
