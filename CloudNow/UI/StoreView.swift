import SwiftUI

struct StoreView: View {
    let games: [GameInfo]
    let onPlay: (GameInfo) -> Void

    @Environment(GamesViewModel.self) var viewModel

    @State private var notOwnedGame: GameInfo?
    @State private var showNotOwned = false
    @State private var searchText = ""
    @State private var selectedStore: String? = nil

    private var availableStores: [String] {
        let stores = Set(games.flatMap { $0.variants.map { $0.appStore } }
            .filter { $0 != "unknown" })
        return stores.sorted()
    }

    private var filteredGames: [GameInfo] {
        var result = games
        if !searchText.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        if let store = selectedStore {
            result = result.filter { $0.variants.contains { $0.appStore == store } }
        }
        return result
    }

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
            } else if filteredGames.isEmpty {
                emptyState
            } else {
                gameGrid
            }
        }
        .searchable(text: $searchText, prompt: "Search games")
        .alert("Not in Your Library", isPresented: $showNotOwned, presenting: notOwnedGame) { _ in
            Button("OK") { }
        } message: { game in
            Text("\(game.title) is not in your GeForce NOW library. Add it via the GeForce NOW store on another device.")
        }
    }

    private var gameGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if availableStores.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            filterChip("All", isSelected: selectedStore == nil) { selectedStore = nil }
                            ForEach(availableStores, id: \.self) { store in
                                filterChip(storeName(store), isSelected: selectedStore == store) {
                                    selectedStore = selectedStore == store ? nil : store
                                }
                            }
                        }
                        .padding(.horizontal, 60)
                    }
                    .scrollClipDisabled()
                    .padding(.vertical, 32)
                }
                LazyVGrid(columns: columns, spacing: 40) {
                    ForEach(filteredGames) { game in
                        Button {
                            if game.isInLibrary {
                                onPlay(viewModel.gameWithPreferredStore(game))
                            } else {
                                notOwnedGame = game
                                showNotOwned = true
                            }
                        } label: {
                            StoreCardLabel(game: game)
                        }
                        .aspectRatio(2/3, contentMode: .fit)
                        #if os(tvOS)
                        .buttonStyle(.card)
                        #else
                        .buttonStyle(.plain)
                        #endif
                        .contextMenu {
                            if game.isInLibrary {
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
                }
                .padding(60)
                .padding(.top, 0)
            }
        }
    }

    private func filterChip(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .blue : nil)
    }

    private func storeName(_ store: String) -> String {
        GameVariant(id: "", appStore: store).storeName
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: viewModel.error != nil ? "exclamationmark.triangle" : "bag")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(viewModel.error != nil ? "Failed to Load Games" : "No games available")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            if let err = viewModel.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(60)
    }
}

// MARK: - Store Card Label

private struct StoreCardLabel: View {
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

            if game.isInLibrary {
                Text("In Library")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.85), in: Capsule())
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }
}
