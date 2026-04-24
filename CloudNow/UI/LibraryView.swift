import SwiftUI

private enum LibrarySortOrder: String, CaseIterable {
    case `default`   = "Default"
    case titleAZ     = "A → Z"
    case titleZA     = "Z → A"
    case recentFirst = "Recently Played"
}

struct LibraryView: View {
    let games: [GameInfo]
    let onPlay: (GameInfo) -> Void

    @Environment(GamesViewModel.self) var viewModel

    @State private var searchText = ""
    @State private var sortOrder: LibrarySortOrder = .default

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40)
    ]

    private var filteredGames: [GameInfo] {
        var result = searchText.isEmpty
            ? games
            : games.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        switch sortOrder {
        case .default: break
        case .titleAZ: result.sort { $0.title < $1.title }
        case .titleZA: result.sort { $0.title > $1.title }
        case .recentFirst:
            let order = viewModel.recentlyPlayedIds
            result.sort {
                let li = order.firstIndex(of: $0.id) ?? Int.max
                let ri = order.firstIndex(of: $1.id) ?? Int.max
                return li < ri
            }
        }
        return result
    }

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
            } else if filteredGames.isEmpty {
                emptyState
            } else {
                gameGrid
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search library")
    }

    private var gameGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 40) {
                ForEach(filteredGames) { game in
                    Button {
                        onPlay(viewModel.gameWithPreferredStore(game))
                    } label: {
                        GameCardLabel(game: game)
                    }
                    .aspectRatio(2/3, contentMode: .fit)
                    #if os(tvOS)
                    .buttonStyle(.card)
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .contextMenu {
                        Button {
                            viewModel.toggleFavorite(game.id)
                        } label: {
                            let isFav = viewModel.favoriteIds.contains(game.id)
                            Label(
                                isFav ? "Remove from Favorites" : "Add to Favorites",
                                systemImage: isFav ? "star.slash.fill" : "star"
                            )
                        }
                        if game.variants.count > 1 {
                            Menu("Launch via...") {
                                ForEach(game.variants, id: \.id) { variant in
                                    Button {
                                        viewModel.setPreferredStore(gameId: game.id, variantId: variant.id)
                                    } label: {
                                        let isSelected = viewModel.preferredVariantId(for: game) == variant.id
                                        if isSelected {
                                            Label(variant.storeName, systemImage: "checkmark")
                                        } else {
                                            Text(variant.storeName)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(60)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: viewModel.libraryError != nil ? "exclamationmark.triangle" : "books.vertical")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(viewModel.libraryError != nil ? "Library Failed to Load" : "Library Empty")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            if let err = viewModel.libraryError ?? viewModel.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
            } else {
                Text("Games you own or have linked will appear here.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(60)
    }
}

// MARK: - Shared Box Art

struct GameBoxArt: View {
    let url: String?
    @State private var attempt = 0

    var body: some View {
        AsyncImage(url: url.flatMap { URL(string: $0) }) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(2/3, contentMode: .fill)
            case .failure:
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(2/3, contentMode: .fit)
                    .shimmer()
                    .onAppear {
                        guard attempt < 3 else { return }
                        Task {
                            try? await Task.sleep(for: .seconds(pow(2.0, Double(attempt)) * 0.5))
                            attempt += 1
                        }
                    }
            case .empty:
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(2/3, contentMode: .fit)
                    .shimmer()
            @unknown default:
                Color.gray.opacity(0.2).aspectRatio(2/3, contentMode: .fit)
            }
        }
        .id(attempt)
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
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
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
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
    }
}
