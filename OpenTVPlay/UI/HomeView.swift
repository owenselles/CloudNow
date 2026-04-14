import SwiftUI

struct HomeView: View {
    let onPlay: (GameInfo) -> Void

    @Environment(GamesViewModel.self) var viewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isLoading {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.gray.opacity(0.2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 420)
                            .shimmer()
                        VStack(alignment: .leading, spacing: 48) {
                            skeletonRow
                            skeletonRow
                        }
                        .padding(.top, 48)
                        .padding(.bottom, 60)
                    }
                }
            } else if viewModel.continuePlaying.isEmpty && viewModel.favoriteGames.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Hero banner: first active session game
                        if let hero = viewModel.continuePlaying.first ?? viewModel.favoriteGames.first {
                            heroBanner(hero)
                        }

                        VStack(alignment: .leading, spacing: 48) {
                            if !viewModel.continuePlaying.isEmpty {
                                gameRow(title: "Continue Playing", games: viewModel.continuePlaying)
                            }
                            if !viewModel.favoriteGames.isEmpty {
                                gameRow(title: "Favorites", games: viewModel.favoriteGames)
                            }
                        }
                        .padding(.top, 48)
                        .padding(.bottom, 60)
                    }
                }
            }
        }
    }

    // MARK: Hero Banner

    private func heroBanner(_ game: GameInfo) -> some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: game.heroBannerUrl.flatMap { URL(string: $0) }) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure, .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                @unknown default:
                    Color.gray.opacity(0.2)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 420)
            .clipped()
            .overlay(
                LinearGradient(
                    colors: [.black.opacity(0.7), .clear, .black.opacity(0.4)],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(game.title)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)

                    if viewModel.continuePlaying.contains(where: { $0.id == game.id }) {
                        Button {
                            onPlay(game)
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }
                Spacer()
            }
            .padding(60)
        }
    }

    // MARK: Game Row

    private func gameRow(title: String, games: [GameInfo]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(games) { game in
                        GameCardView(game: game) {
                            onPlay(game)
                        }
                        .frame(width: 200)
                    }
                }
                .padding(.horizontal, 60)
            }
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
                HStack(spacing: 24) {
                    ForEach(0..<6, id: \.self) { _ in
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
            Text("Nothing here yet")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text("Start playing a game to see it here, or add favorites from the Library.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
        }
    }
}
