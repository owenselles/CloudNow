import SwiftUI

struct StoreView: View {
    let games: [GameInfo]
    let onPlay: (GameInfo) -> Void

    @Environment(GamesViewModel.self) var viewModel

    @State private var carouselRequest: CarouselRequest?
    @FocusState private var focusedGameId: String?
    @State private var expandedGame: GameInfo?
    @State private var searchText = ""
    @State private var filterState = GameFilterState()
    @State private var sortOrder: LibrarySortOrder = .default

    private var filterOptions: GameFilterOptions {
        GameFilterOptions(games: games, favoriteIds: viewModel.favoriteIds, context: .store)
    }

    private var filteredGames: [GameInfo] {
        GameFilterEngine.apply(
            to: games,
            context: .store,
            state: filterState,
            searchText: searchText,
            sortOrder: sortOrder,
            favoriteIds: viewModel.favoriteIds,
            recentlyPlayedIds: viewModel.recentlyPlayedIds
        )
    }

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40),
    ]

    var body: some View {
        ZStack {
            if games.isEmpty, viewModel.isLoading {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(0 ..< 12, id: \.self) { _ in
                            GameCardSkeleton()
                        }
                    }
                    .padding(60)
                }
                .allowsHitTesting(false)
            } else if games.isEmpty {
                emptyState
            } else {
                gameContent
            }
        }
        .searchable(text: $searchText, prompt: Text(L10n.text("search_games")))
        .fullScreenCover(item: $carouselRequest) { req in
            GameCarouselView(request: req, onPlay: onPlay, onDismiss: { lastId in
                carouselRequest = nil
                Task { @MainActor in focusedGameId = lastId }
            })
            .environment(viewModel)
        }
        .fullScreenCover(item: $expandedGame) { game in
            GameDetailView(game: game, onPlay: { g in
                expandedGame = nil
                onPlay(g)
            })
            .environment(viewModel)
        }
        .animation(.easeInOut(duration: 0.25), value: carouselRequest?.id)
    }

    private var gameContent: some View {
        let visibleGames = filteredGames
        let options = filterOptions

        return GameGrid(
            games: visibleGames,
            focusedId: $focusedGameId,
            showLibraryBadge: true,
            hasActiveFilters: !filterState.isEmpty,
            onClearFilters: { filterState.clear() },
            onSelect: { game in
                carouselRequest = CarouselRequest(games: visibleGames, startId: game.id)
            },
            onExpand: { game in
                expandedGame = game
            },
            header: {
                filterHeader(visibleGames: visibleGames, options: options)
            }
        )
    }

    private func filterHeader(visibleGames: [GameInfo], options: GameFilterOptions) -> some View {
        GameFilterBar(
            totalCount: games.count,
            resultCount: visibleGames.count,
            context: .store,
            options: options,
            availableSortOrders: LibrarySortOrder.allCases,
            previewCount: { state in
                GameFilterEngine.apply(
                    to: games,
                    context: .store,
                    state: state,
                    searchText: searchText,
                    sortOrder: sortOrder,
                    favoriteIds: viewModel.favoriteIds,
                    recentlyPlayedIds: viewModel.recentlyPlayedIds
                ).count
            },
            filterState: $filterState,
            sortOrder: $sortOrder
        )
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: viewModel.error != nil ? "exclamationmark.triangle" : "bag")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(viewModel.error != nil ? L10n.text("failed_to_load_games") : L10n.text("no_games_available"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
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
