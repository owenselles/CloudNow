import Foundation
import ImageIO
import SwiftUI

private nonisolated enum ArtworkPipelineError: Error {
    case invalidResponse
    case decodeFailed
}

nonisolated enum ArtworkMemoryEvent: Equatable {
    case foreground
    case streamOpening
    case streaming
    case background
    case memoryWarning
}

private nonisolated enum ArtworkKind: Hashable {
    case boxArt
    case heroArt
}

/// One decoded-image pipeline for cards, hero banners, and loading artwork.
/// The actor coalesces identical in-flight work and enforces separate hard LRU budgets for
/// card and hero artwork so cache-owned decoded memory cannot drift past configured targets.
actor ArtworkImagePipeline {
    static let shared = ArtworkImagePipeline()

    static let boxArtPixelSize = 640
    static let screenshotPixelSize = 960
    static let heroArtPixelSize = 1920

    private struct CacheEntry {
        let image: CGImage
        let cost: Int
        let kind: ArtworkKind
        var lastAccess: UInt64
    }

    private struct InFlightRequest {
        let task: Task<CGImage, Error>
        let kind: ArtworkKind
        let generation: UInt64
    }

    private struct CacheBudget {
        let totalCostLimit: Int
        let countLimit: Int
    }

    private static let megabyte = 1024 * 1024
    private static let foregroundBoxArtBudget = CacheBudget(
        totalCostLimit: 96 * megabyte,
        countLimit: 96
    )
    private static let backgroundBoxArtBudget = CacheBudget(
        totalCostLimit: 32 * megabyte,
        countLimit: 32
    )
    private static let heroArtBudget = CacheBudget(
        totalCostLimit: 32 * megabyte,
        countLimit: 4
    )

    private var cache: [String: CacheEntry] = [:]
    private var totalCost: [ArtworkKind: Int] = [.boxArt: 0, .heroArt: 0]
    private var accessCounter: UInt64 = 0
    private var inFlight: [String: InFlightRequest] = [:]
    private var generation: [ArtworkKind: UInt64] = [.boxArt: 0, .heroArt: 0]
    private var memoryEvent = ArtworkMemoryEvent.foreground

    private init() {}

    func image(for url: URL, maxPixelSize: Int) async throws -> CGImage {
        let kind = Self.artworkKind(maxPixelSize: maxPixelSize)
        guard permitsNewLoads(for: kind, maxPixelSize: maxPixelSize) else {
            throw CancellationError()
        }

        let key = Self.cacheKey(url: url, maxPixelSize: maxPixelSize)
        if let cached = cachedImage(for: key) {
            return cached
        }
        if let request = inFlight[key] {
            return try await request.task.value
        }

        let requestGeneration = generation[kind, default: 0]
        let task = Task(priority: .userInitiated) { @concurrent in
            let image = try await Self.fetchAndDownsample(url: url, maxPixelSize: maxPixelSize)
            try Task.checkCancellation()
            return image
        }
        inFlight[key] = InFlightRequest(
            task: task,
            kind: kind,
            generation: requestGeneration
        )
        do {
            let image = try await task.value
            inFlight[key] = nil
            guard generation[kind, default: 0] == requestGeneration,
                  permitsNewLoads(for: kind, maxPixelSize: maxPixelSize)
            else {
                throw CancellationError()
            }
            insert(image, for: key, kind: kind)
            return image
        } catch {
            if inFlight[key]?.generation == requestGeneration {
                inFlight[key] = nil
            }
            throw error
        }
    }

    func prefetch(_ url: URL, maxPixelSize: Int) async -> Bool {
        do {
            try Task.checkCancellation()
            _ = try await image(for: url, maxPixelSize: maxPixelSize)
            try Task.checkCancellation()
            return true
        } catch {
            return false
        }
    }

    func handleMemoryEvent(_ event: ArtworkMemoryEvent) {
        if event != .memoryWarning {
            memoryEvent = event
        }

        switch event {
        case .foreground:
            trimCache(for: .boxArt, to: Self.foregroundBoxArtBudget)
            trimCache(for: .heroArt, to: Self.heroArtBudget)
        case .streamOpening:
            cancelInFlight(for: .boxArt)
        case .streaming:
            cancelInFlight(for: .boxArt)
            cancelInFlight(for: .heroArt)
            removeCachedImages(for: .heroArt)
        case .background:
            cancelInFlight(for: .boxArt)
            cancelInFlight(for: .heroArt)
            removeCachedImages(for: .heroArt)
            trimCache(for: .boxArt, to: Self.backgroundBoxArtBudget)
        case .memoryWarning:
            cancelInFlight(for: .boxArt)
            cancelInFlight(for: .heroArt)
            removeCachedImages(for: .boxArt)
            removeCachedImages(for: .heroArt)
        }
    }

    private func permitsNewLoads(for kind: ArtworkKind, maxPixelSize: Int) -> Bool {
        switch memoryEvent {
        case .foreground:
            true
        case .streamOpening:
            kind == .heroArt && maxPixelSize == Self.heroArtPixelSize
        case .streaming, .background, .memoryWarning:
            false
        }
    }

    private func cachedImage(for key: String) -> CGImage? {
        guard var entry = cache[key] else { return nil }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        cache[key] = entry
        return entry.image
    }

    private func insert(_ image: CGImage, for key: String, kind: ArtworkKind) {
        let budget = budget(for: kind)
        let cost = image.bytesPerRow * image.height
        guard cost <= budget.totalCostLimit else { return }

        if let existing = cache.removeValue(forKey: key) {
            totalCost[existing.kind, default: 0] -= existing.cost
        }
        accessCounter &+= 1
        cache[key] = CacheEntry(
            image: image,
            cost: cost,
            kind: kind,
            lastAccess: accessCounter
        )
        totalCost[kind, default: 0] += cost
        trimCache(for: kind, to: budget)
    }

    private func trimCache(for kind: ArtworkKind, to budget: CacheBudget) {
        while totalCost[kind, default: 0] > budget.totalCostLimit
            || cachedImageCount(for: kind) > budget.countLimit
        {
            guard let key = leastRecentlyUsedKey(for: kind),
                  let removed = cache.removeValue(forKey: key)
            else { return }
            totalCost[kind, default: 0] -= removed.cost
        }
    }

    private func cachedImageCount(for kind: ArtworkKind) -> Int {
        cache.values.lazy.filter { $0.kind == kind }.count
    }

    private func leastRecentlyUsedKey(for kind: ArtworkKind) -> String? {
        var candidate: (key: String, lastAccess: UInt64)?
        for (key, entry) in cache where entry.kind == kind {
            if let current = candidate {
                if entry.lastAccess < current.lastAccess {
                    candidate = (key, entry.lastAccess)
                }
            } else {
                candidate = (key, entry.lastAccess)
            }
        }
        return candidate?.key
    }

    private func removeCachedImages(for kind: ArtworkKind) {
        let keys = cache.compactMap { key, entry in
            entry.kind == kind ? key : nil
        }
        for key in keys {
            cache[key] = nil
        }
        totalCost[kind] = 0
    }

    private func cancelInFlight(for kind: ArtworkKind) {
        generation[kind, default: 0] &+= 1
        var keys: [String] = []
        for (key, request) in inFlight where request.kind == kind {
            request.task.cancel()
            keys.append(key)
        }
        for key in keys {
            inFlight[key] = nil
        }
    }

    private func budget(for kind: ArtworkKind) -> CacheBudget {
        switch kind {
        case .boxArt:
            memoryEvent == .background
                ? Self.backgroundBoxArtBudget
                : Self.foregroundBoxArtBudget
        case .heroArt:
            Self.heroArtBudget
        }
    }

    private nonisolated static func cacheKey(url: URL, maxPixelSize: Int) -> String {
        "\(url.absoluteString)#\(maxPixelSize)"
    }

    private nonisolated static func artworkKind(maxPixelSize: Int) -> ArtworkKind {
        maxPixelSize <= boxArtPixelSize ? .boxArt : .heroArt
    }

    private nonisolated static func fetchAndDownsample(
        url: URL,
        maxPixelSize: Int
    ) async throws -> CGImage {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        let (data, response) = try await URLSession.shared.data(for: request)
        if let response = response as? HTTPURLResponse,
           !(200 ..< 300).contains(response.statusCode)
        {
            throw ArtworkPipelineError.invalidResponse
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw ArtworkPipelineError.decodeFailed
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw ArtworkPipelineError.decodeFailed
        }
        return image
    }
}

private nonisolated enum ArtworkLoadState {
    case loading
    case loaded
    case failed
}

/// Cancellable artwork view with bounded retries. When it leaves the hierarchy, SwiftUI cancels
/// retry sleeps and prevents late state updates; a shared in-flight fetch may still finish to warm
/// the cache for another visible consumer.
struct SharedArtworkImage: View {
    let urlString: String?
    let maxPixelSize: Int
    var contentMode: ContentMode = .fill

    @State private var image: CGImage?
    @State private var loadState: ArtworkLoadState = .loading
    @State private var reloadGeneration = 0

    private var requestID: String {
        "\(urlString ?? "")#\(maxPixelSize)#\(reloadGeneration)"
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .task(id: requestID) {
            await loadImage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .artworkLoadingDidResume)) { _ in
            guard image == nil else { return }
            reloadGeneration &+= 1
        }
    }

    @ViewBuilder private var placeholder: some View {
        if loadState == .loading {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .shimmer()
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
        }
    }

    private func loadImage() async {
        image = nil
        loadState = .loading
        guard let urlString, let url = URL(string: urlString) else {
            loadState = .failed
            return
        }

        for attempt in 0 ..< 3 {
            do {
                let loaded = try await ArtworkImagePipeline.shared.image(
                    for: url,
                    maxPixelSize: maxPixelSize
                )
                try Task.checkCancellation()
                image = loaded
                loadState = .loaded
                return
            } catch is CancellationError {
                return
            } catch {
                guard attempt < 2 else {
                    if !Task.isCancelled {
                        loadState = .failed
                    }
                    return
                }
                let delay = pow(2.0, Double(attempt)) * 0.35 * Double.random(in: 0.8 ... 1.2)
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }
}

/// Warms the decoded cache with a game's full-bleed loading art when its card gains focus.
@MainActor
final class HeroArtPrefetcher {
    static let shared = HeroArtPrefetcher()

    private static let maximumConcurrentRequests = 2
    private static let maximumPendingRequests = 2

    private var requested = Set<String>()
    private var pending: [(key: String, url: URL)] = []
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var isSuspended = false

    func prefetch(_ urlString: String?) {
        guard !isSuspended,
              let urlString,
              let url = URL(string: urlString),
              requested.insert(urlString).inserted else { return }
        if pending.count >= Self.maximumPendingRequests {
            let stale = pending.removeFirst()
            requested.remove(stale.key)
        }
        pending.append((key: urlString, url: url))
        startPendingRequests()
    }

    func suspend(cancelActive: Bool) {
        isSuspended = true
        requested.subtract(pending.map(\.key))
        pending.removeAll(keepingCapacity: true)
        guard cancelActive else { return }
        cancelAll()
    }

    func resume() {
        isSuspended = false
        startPendingRequests()
    }

    func cancelAll() {
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        requested.removeAll(keepingCapacity: true)
    }

    private func startPendingRequests() {
        while !isSuspended,
              activeTasks.count < Self.maximumConcurrentRequests,
              !pending.isEmpty
        {
            let item = pending.removeFirst()
            let task = Task { @concurrent in
                let succeeded = await ArtworkImagePipeline.shared.prefetch(
                    item.url,
                    maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
                )
                await HeroArtPrefetcher.shared.finishedRequest(
                    key: item.key,
                    succeeded: succeeded
                )
            }
            activeTasks[item.key] = task
        }
    }

    private func finishedRequest(key: String, succeeded: Bool) {
        activeTasks[key] = nil
        if !succeeded {
            requested.remove(key)
        }
        startPendingRequests()
    }
}

/// Keeps a small decoded-art runway ahead of Store scrolling without loading the full catalog.
@MainActor
final class BoxArtPrefetcher {
    static let shared = BoxArtPrefetcher()

    private static let maximumConcurrentRequests = 6

    private var requested = Set<String>()
    private var pending: [(key: String, url: URL)] = []
    private var nextPendingIndex = 0
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var isSuspended = false

    func prefetch(_ urlStrings: some Sequence<String>) {
        guard !isSuspended else { return }
        for urlString in urlStrings {
            guard let url = URL(string: urlString), requested.insert(urlString).inserted else {
                continue
            }
            pending.append((key: urlString, url: url))
        }
        startPendingRequests()
    }

    func suspend() {
        isSuspended = true
        cancelAll()
    }

    func resume() {
        isSuspended = false
        startPendingRequests()
    }

    func cancelAll() {
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        nextPendingIndex = 0
        requested.removeAll(keepingCapacity: true)
    }

    private func startPendingRequests() {
        while !isSuspended,
              activeTasks.count < Self.maximumConcurrentRequests,
              nextPendingIndex < pending.count
        {
            let item = pending[nextPendingIndex]
            nextPendingIndex += 1

            let task = Task { @concurrent in
                let succeeded = await ArtworkImagePipeline.shared.prefetch(
                    item.url,
                    maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
                )
                await BoxArtPrefetcher.shared.finishedRequest(
                    key: item.key,
                    succeeded: succeeded
                )
            }
            activeTasks[item.key] = task
        }
        if nextPendingIndex == pending.count {
            pending.removeAll(keepingCapacity: true)
            nextPendingIndex = 0
        }
    }

    private func finishedRequest(key: String, succeeded: Bool) {
        activeTasks[key] = nil
        if !succeeded {
            requested.remove(key)
        }
        startPendingRequests()
    }
}

private struct PrefetchHeroArtOnFocus: ViewModifier {
    let urlString: String?
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.onChange(of: isFocused) { _, focused in
            if focused {
                HeroArtPrefetcher.shared.prefetch(urlString)
            }
        }
    }
}

extension View {
    /// Attach to a focusable card's content, where the focus environment is available.
    func prefetchHeroArtOnFocus(_ urlString: String?) -> some View {
        modifier(PrefetchHeroArtOnFocus(urlString: urlString))
    }
}
