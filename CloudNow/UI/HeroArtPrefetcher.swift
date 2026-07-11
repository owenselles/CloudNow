import SwiftUI

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
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard error != nil || status >= 400 else { return }
            Task { @MainActor in self?.requested.remove(urlString) }
        }.resume()
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
