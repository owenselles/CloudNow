import SwiftUI

struct LibraryView: View {
    let games: [GameInfo]

    @Environment(AuthManager.self) var authManager
    @Environment(GamesViewModel.self) var viewModel

    @State private var selectedGame: GameInfo?
    @State private var showStream = false

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40)
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if games.isEmpty && viewModel.isLoading {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(0..<12, id: \.self) { _ in
                            GameCardSkeleton()
                        }
                    }
                    .padding(60)
                }
                .allowsHitTesting(false)
            } else if games.isEmpty {
                emptyState
            } else {
                gameGrid
            }
        }
        .fullScreenCover(isPresented: $showStream) {
            if let game = selectedGame {
                StreamView(game: game, settings: viewModel.streamSettings, onDismiss: { showStream = false })
                    .environment(authManager)
            }
        }
    }

    private var gameGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 40) {
                ForEach(games) { game in
                    Button {
                        selectedGame = game
                        showStream = true
                    } label: {
                        GameCardLabel(game: game)
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(60)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "books.vertical")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Library Empty")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text("Games you own or have linked will appear here.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(60)
    }
}

// MARK: - Shared Box Art

struct GameBoxArt: View {
    let url: String?

    var body: some View {
        AsyncImage(url: url.flatMap { URL(string: $0) }) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(2/3, contentMode: .fill)
            case .failure, .empty:
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(2/3, contentMode: .fit)
            @unknown default:
                Color.gray.opacity(0.2).aspectRatio(2/3, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Game Card Label (shared)

struct GameCardLabel: View {
    let game: GameInfo

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GameBoxArt(url: game.boxArtUrl)

            LinearGradient(
                colors: [.black.opacity(0.7), .clear],
                startPoint: .bottom,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(game.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(10)
        }
    }
}

// MARK: - Game Card (used on Home rows)

struct GameCardView: View {
    let game: GameInfo
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            GameCardLabel(game: game)
        }
        .buttonStyle(.card)
    }
}

// MARK: - Library Card

struct LibraryCardView: View {
    let game: GameInfo
    let isFavorite: Bool
    let onFavoriteToggle: () -> Void
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            GameCardLabel(game: game)
        }
        .buttonStyle(.card)
    }
}
