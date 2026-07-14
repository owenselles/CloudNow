import Foundation
import ImageIO
import SwiftUI

private nonisolated enum ArtworkPipelineError: Error {
    case invalidResponse
    case decodeFailed
}

/// One decoded-image pipeline for cards, hero banners, and loading artwork.
/// The actor coalesces identical in-flight work, while NSCache bounds decoded memory.
actor ArtworkImagePipeline {
    static let shared = ArtworkImagePipeline()

    static let boxArtPixelSize = 640
    static let heroArtPixelSize = 1920

    private let cache = NSCache<NSString, CGImage>()
    private var inFlight: [String: Task<CGImage, Error>] = [:]

    private init() {
        cache.countLimit = 180
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    func image(for url: URL, maxPixelSize: Int) async throws -> CGImage {
        let key = Self.cacheKey(url: url, maxPixelSize: maxPixelSize)
        let cacheKey = key as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        if let task = inFlight[key] { return try await task.value }

        let task = Task.detached(priority: .userInitiated) {
            try await Self.fetchAndDownsample(url: url, maxPixelSize: maxPixelSize)
        }
        inFlight[key] = task
        do {
            let image = try await task.value
            cache.setObject(
                image,
                forKey: cacheKey,
                cost: image.bytesPerRow * image.height
            )
            inFlight[key] = nil
            return image
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    func prefetch(_ url: URL, maxPixelSize: Int) async -> Bool {
        do {
            _ = try await image(for: url, maxPixelSize: maxPixelSize)
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func cacheKey(url: URL, maxPixelSize: Int) -> String {
        "\(url.absoluteString)#\(maxPixelSize)"
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

    private var requestID: String {
        "\(urlString ?? "")#\(maxPixelSize)"
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
                    if !Task.isCancelled { loadState = .failed }
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

    private var requested = Set<String>()

    func prefetch(_ urlString: String?) {
        guard let urlString, let url = URL(string: urlString),
              requested.insert(urlString).inserted else { return }
        Task { @concurrent in
            let succeeded = await ArtworkImagePipeline.shared.prefetch(
                url,
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
            guard !succeeded else { return }
            await HeroArtPrefetcher.shared.removeFailedRequest(urlString)
        }
    }

    private func removeFailedRequest(_ urlString: String) {
        requested.remove(urlString)
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
    private var activeRequestCount = 0

    func prefetch(_ urlStrings: some Sequence<String>) {
        for urlString in urlStrings {
            guard let url = URL(string: urlString), requested.insert(urlString).inserted else {
                continue
            }
            pending.append((key: urlString, url: url))
        }
        startPendingRequests()
    }

    private func startPendingRequests() {
        while activeRequestCount < Self.maximumConcurrentRequests,
              nextPendingIndex < pending.count
        {
            let item = pending[nextPendingIndex]
            nextPendingIndex += 1
            activeRequestCount += 1

            Task { @concurrent in
                let succeeded = await ArtworkImagePipeline.shared.prefetch(
                    item.url,
                    maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
                )
                await BoxArtPrefetcher.shared.finishedRequest(
                    key: item.key,
                    succeeded: succeeded
                )
            }
        }
        if nextPendingIndex == pending.count {
            pending.removeAll(keepingCapacity: true)
            nextPendingIndex = 0
        }
    }

    private func finishedRequest(key: String, succeeded: Bool) {
        activeRequestCount -= 1
        if !succeeded { requested.remove(key) }
        startPendingRequests()
    }
}

private struct PrefetchHeroArtOnFocus: ViewModifier {
    let urlString: String?
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.onChange(of: isFocused) { _, focused in
            if focused { HeroArtPrefetcher.shared.prefetch(urlString) }
        }
    }
}

extension View {
    /// Attach to a focusable card's content, where the focus environment is available.
    func prefetchHeroArtOnFocus(_ urlString: String?) -> some View {
        modifier(PrefetchHeroArtOnFocus(urlString: urlString))
    }
}
