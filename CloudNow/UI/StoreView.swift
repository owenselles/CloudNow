import SwiftUI

struct StoreView: View {
    let onPlay: (GameInfo) -> Void

    @Environment(GamesViewModel.self) var viewModel

    @State private var carouselRequest: CarouselRequest?
    @FocusState private var focusedGameId: String?
    @State private var expandedGame: GameInfo?

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40),
    ]

    var body: some View {
        @Bindable var viewModel = viewModel

        ZStack {
            if viewModel.mainGames.isEmpty, viewModel.isLoading {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(0 ..< 12, id: \.self) { _ in
                            GameCardSkeleton()
                        }
                    }
                    .padding(60)
                }
                .allowsHitTesting(false)
            } else if viewModel.mainGames.isEmpty {
                emptyState
            } else {
                gameContent
            }
        }
        .searchable(text: $viewModel.storeSearchText, prompt: Text(L10n.text("search_games")))
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
        @Bindable var viewModel = viewModel
        let visibleGames = viewModel.filteredStoreGames

        return GameGrid(
            games: visibleGames,
            focusedId: $focusedGameId,
            showLibraryBadge: true,
            pageSize: 96,
            boxArtPrefetchDistance: 24,
            hasActiveFilters: !viewModel.storeFilterState.isEmpty,
            onClearFilters: { viewModel.storeFilterState.clear() },
            onSelect: { game in
                carouselRequest = CarouselRequest(games: visibleGames, startId: game.id)
            },
            onExpand: { game in
                expandedGame = game
            },
            header: {
                filterHeader(visibleGames: visibleGames)
            }
        )
    }

    private func filterHeader(visibleGames: [GameInfo]) -> some View {
        @Bindable var viewModel = viewModel

        return GameFilterBar(
            totalCount: viewModel.mainGames.count,
            resultCount: visibleGames.count,
            context: .store,
            options: viewModel.storeFilterOptions,
            availableSortOrders: LibrarySortOrder.allCases,
            previewCount: viewModel.storePreviewCount,
            filterState: $viewModel.storeFilterState,
            sortOrder: $viewModel.storeSortOrder
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
