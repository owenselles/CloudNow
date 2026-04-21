import SwiftUI

struct HomeView: View {
    let onPlay: (GameInfo) -> Void
    let onResume: (ResumableSession) -> Void

    @Environment(GamesViewModel.self) var viewModel
    @Environment(AuthManager.self) var authManager
    @State private var tick = 0

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
            } else if viewModel.continuePlaying.isEmpty && viewModel.recentlyPlayedGames.isEmpty && viewModel.favoriteGames.isEmpty && activeResumable == nil {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Hero banner: resumable → active session → recently played → favorite
                        if let rs = activeResumable {
                            resumeBanner(rs)
                        } else if let hero = viewModel.continuePlaying.first ?? viewModel.recentlyPlayedGames.first ?? viewModel.favoriteGames.first {
                            heroBanner(hero)
                        }

                        VStack(alignment: .leading, spacing: 48) {
                            if !viewModel.continuePlaying.isEmpty {
                                gameRow(title: "Resume Stream", games: viewModel.continuePlaying, badge: "LIVE")
                            }
                            if !viewModel.recentlyPlayedGames.isEmpty {
                                gameRow(title: "Recently Played", games: viewModel.recentlyPlayedGames)
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
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            Task { await viewModel.refreshActiveSessions(authManager: authManager) }
        }
        .task(id: viewModel.resumableSession?.session.sessionId) {
            guard viewModel.resumableSession != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick &+= 1
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
            AsyncImage(url: rs.game.heroBannerUrl.flatMap { URL(string: $0) }) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure, .empty:
                    Rectangle().fill(Color.gray.opacity(0.2))
                @unknown default:
                    Color.gray.opacity(0.2)
                }
            }
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
                        Text("SESSION ACTIVE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.green, in: Capsule())
                    }
                    Text("Session expires in \(rs.secondsRemaining)s — tap to jump back in")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                    Button { onResume(rs) } label: {
                        Label("Rejoin Session", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                Spacer()
            }
            .padding(60)
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

    private func gameRow(title: String, games: [GameInfo], badge: String? = nil) -> some View {
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
