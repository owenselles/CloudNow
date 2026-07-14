import SwiftUI

private nonisolated func fetchArtworkIntoURLCache(_ url: URL) async -> Bool {
    var request = URLRequest(url: url)
    request.cachePolicy = .returnCacheDataElseLoad
    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        return status < 400
    } catch {
        return false
    }
}

/// Warms `URLCache.shared` with a game's full-bleed loading art ahead of time so
/// `StreamView`'s loading background renders instantly instead of fetching a large
/// hero image the moment the user presses Play.
///
/// The loading screen uses a ~1920px hero (`heroImageUrl ?? heroBannerUrl`), a
/// different, larger image than the 272px box art the grids cache — so without a
/// prefetch every launch of a game shows a black screen behind the loading bar
/// until the hero downloads. Prefetching is triggered on card focus, so only the
/// game the user is looking at is fetched, not the whole catalog.
@MainActor
final class HeroArtPrefetcher {
    static let shared = HeroArtPrefetcher()

    /// URLs already fetched or in flight this session, so focus changes don't
    /// re-issue the same request. Failed fetches are removed so they can retry.
    private var requested = Set<String>()

    func prefetch(_ urlString: String?) {
        guard let urlString, let url = URL(string: urlString),
              requested.insert(urlString).inserted else { return }
        Task { @concurrent in
            guard await fetchArtworkIntoURLCache(url) == false else { return }
            await HeroArtPrefetcher.shared.removeFailedRequest(urlString)
        }
    }

    private func removeFailedRequest(_ urlString: String) {
        requested.remove(urlString)
    }
}

/// Keeps a small runway of box art in `URLCache` ahead of Store scrolling.
///
/// The Store can contain several thousand games. Loading every thumbnail would
/// waste bandwidth and memory, while waiting until a card appears makes forward
/// scrolling pay the download/decode cost. This prefetcher stays a short distance
/// ahead and caps concurrent requests so artwork never starves interactive work.
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
                let succeeded = await fetchArtworkIntoURLCache(item.url)
                await BoxArtPrefetcher.shared.finishedRequest(
                    key: item.key,
                    succeeded: succeeded
                )
            }
        }
    }

    private func finishedRequest(key: String, succeeded: Bool) {
        activeRequestCount -= 1
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
            if focused { HeroArtPrefetcher.shared.prefetch(urlString) }
        }
    }
}

extension View {
    /// Prefetches this game's loading art when the card gains focus. Attach to the
    /// focusable card's *content* (inside its Button label), where `\.isFocused` is set.
    func prefetchHeroArtOnFocus(_ urlString: String?) -> some View {
        modifier(PrefetchHeroArtOnFocus(urlString: urlString))
    }
}
