import SwiftUI

struct HomeView: View {
    let onPlay: (GameInfo) -> Void
    let onResume: (ResumableSession) -> Void

    @Environment(GamesViewModel.self) var viewModel
    @State private var carouselRequest: CarouselRequest?
    @State private var restoreScrollId: String?

    var body: some View {
        ZStack {
            if viewModel.isLoading {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.gray.opacity(0.2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .shimmer()
                            .padding(.horizontal, 60)
                        VStack(alignment: .leading, spacing: 48) {
                            skeletonRow
                            skeletonRow
                        }
                        .padding(.top, 48)
                        .padding(.bottom, 60)
                    }
                }
            } else if viewModel.continuePlaying.isEmpty, viewModel.recentlyPlayedGames.isEmpty, viewModel.favoriteGames.isEmpty, activeResumable == nil {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            let heroGame: GameInfo? = activeResumable == nil
                                ? (viewModel.continuePlaying.first ?? viewModel.recentlyPlayedGames.first ?? viewModel.favoriteGames.first)
                                : nil
                            if let rs = activeResumable {
                                resumeBanner(rs)
                            } else if let hero = heroGame {
                                heroBanner(hero)
                            }

                            VStack(alignment: .leading, spacing: 48) {
                                if !viewModel.continuePlaying.isEmpty {
                                    gameRow(title: L10n.text("resume_stream"), games: viewModel.continuePlaying, badge: L10n.text("live"))
                                }
                                let recentWithoutHero = viewModel.recentlyPlayedGames.filter { $0.id != heroGame?.id }
                                if !recentWithoutHero.isEmpty {
                                    gameRow(title: L10n.text("recently_played"), games: recentWithoutHero)
                                }
                                if !viewModel.favoriteGames.isEmpty {
                                    gameRow(title: L10n.text("favorites"), games: viewModel.favoriteGames, isFavoritesRow: true)
                                }
                            }
                            .padding(.top, 48)
                            .padding(.bottom, 60)
                        }
                    }
                    .onChange(of: restoreScrollId) { _, newValue in
                        guard let newValue else { return }
                        withAnimation {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                        restoreScrollId = nil
                    }
                }
            }
        }
        .fullScreenCover(item: $carouselRequest) { req in
            GameCarouselView(request: req, onPlay: onPlay, onDismiss: { lastId in
                restoreScrollId = lastId
                carouselRequest = nil
            })
            .environment(viewModel)
        }
        .animation(.easeInOut(duration: 0.25), value: carouselRequest?.id)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: viewModel.resumableSession?.session.sessionId) {
            guard viewModel.resumableSession != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if viewModel.resumableSession?.isExpired == true {
                    viewModel.resumableSession = nil
                    return
                }
            }
        }
    }

    private var activeResumable: ResumableSession? {
        guard let rs = viewModel.resumableSession, !rs.isExpired else { return nil }
        return rs
    }

    // MARK: Resume Banner

    private func resumeBanner(_ rs: ResumableSession) -> some View {
        ZStack(alignment: .bottomLeading) {
            SharedArtworkImage(
                urlString: rs.game.heroBannerUrl,
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
            .frame(maxWidth: .infinity)
            .frame(height: 420)
            .clipped()
            .overlay(LinearGradient(
                colors: [.black.opacity(0.8), .clear, .black.opacity(0.4)],
                startPoint: .bottom, endPoint: .top
            ))

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text(rs.game.title)
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                        Text(L10n.text("session_active"))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.green, in: Capsule())
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(L10n.format("session_expires_in", rs.secondsRemaining))
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Button { onResume(rs) } label: {
                        Label(L10n.text("rejoin_session"), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                Spacer()
            }
            .padding(60)
        }
        .focusSection()
    }

    // MARK: Hero Banner

    private func heroBanner(_ game: GameInfo) -> some View {
        HeroBannerView(game: game, onPlay: onPlay)
    }

    // MARK: Game Row

    private func gameRow(title: String, games: [GameInfo], badge: String? = nil, isFavoritesRow: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green, in: Capsule())
                }
            }
            .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(games) { game in
                        GameCardView(game: game) { onPlay(game) }
                            .frame(width: 200)
                            .id(game.id)
                            .contextMenu {
                                Button {
                                    carouselRequest = CarouselRequest(games: games, startId: game.id)
                                } label: {
                                    Label("Info", systemImage: "info.circle")
                                }
                                if isFavoritesRow {
                                    Button {
                                        viewModel.toggleFavorite(game.id)
                                    } label: {
                                        Label(L10n.text("remove_from_favorites"), systemImage: "star.slash.fill")
                                    }
                                }
                            }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
            }
            .focusSection()
            .scrollClipDisabled()
        }
    }

    // MARK: Skeleton Row

    private var skeletonRow: some View {
        VStack(alignment: .leading, spacing: 20) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.25))
                .frame(width: 180, height: 24)
                .shimmer()
                .padding(.horizontal, 60)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(0 ..< 6, id: \.self) { _ in
                        GameCardSkeleton().frame(width: 200)
                    }
                }
                .padding(.horizontal, 60)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(L10n.text("nothing_here_yet"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text(L10n.text("empty_home_message"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
        }
    }
}

// MARK: - Hero Banner View

private struct HeroBannerView: View {
    let game: GameInfo
    let onPlay: (GameInfo) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            SharedArtworkImage(
                urlString: game.heroBannerUrl,
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
            .frame(maxWidth: .infinity)
            .frame(height: 420)

            LinearGradient(
                colors: [.black.opacity(0.85), .black.opacity(0.5), .clear],
                startPoint: .bottom,
                endPoint: UnitPoint(x: 0.5, y: 0.55)
            )

            HStack {
                Button {
                    onPlay(game)
                } label: {
                    Label(L10n.text("play"), systemImage: "play.fill")
                        .prefetchHeroArtOnFocus(game.heroImageUrl ?? game.heroBannerUrl)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                Spacer()
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 60)
        .focusSection()
    }
}
