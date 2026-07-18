import SwiftUI

enum LibrarySortOrder: String, CaseIterable {
    case `default` = "Default"
    case titleAZ = "A → Z"
    case titleZA = "Z → A"
    case recentFirst = "Recently Played"

    var label: String {
        L10n.librarySortLabel(self)
    }
}

struct LibraryView: View {
    let onPlay: (GameInfo) -> Void

    @Environment(AuthManager.self) var authManager
    @Environment(GamesViewModel.self) var viewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var carouselRequest: CarouselRequest?
    @State private var expandedGame: GameInfo?
    @FocusState private var focusedGameId: String?
    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40),
    ]

    var body: some View {
        @Bindable var viewModel = viewModel

        ZStack {
            if viewModel.libraryGames.isEmpty, viewModel.isLibraryLoading {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(0 ..< 12, id: \.self) { _ in
                            GameCardSkeleton()
                        }
                    }
                    .padding(60)
                }
                .allowsHitTesting(false)
            } else if viewModel.libraryGames.isEmpty {
                emptyState
            } else {
                gameContent
            }
        }
        .fullScreenCover(item: $carouselRequest) { req in
            GameCarouselView(request: req, onPlay: onPlay, onDismiss: { lastId in
                carouselRequest = nil
                Task { @MainActor in
                    await Task.yield()
                    focusedGameId = lastId
                }
            })
            .environment(viewModel)
        }
        .fullScreenCover(item: $expandedGame) { game in
            GameDetailView(game: game, onPlay: { g in
                expandedGame = nil
                onPlay(g)
            })
            .environment(viewModel)
            .blocksGlobalControllerNavigation()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: carouselRequest?.id)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.refreshLibrary(authManager: authManager) }
                } label: {
                    Label(L10n.text("refresh_library"), systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLibraryLoading)
            }
        }
        .searchable(
            text: $viewModel.librarySearchText,
            prompt: viewModel.libraryGames.isEmpty
                ? Text(L10n.text("loading_library"))
                : Text(L10n.format("search_games_count", viewModel.libraryGames.count))
        )
    }

    private var gameContent: some View {
        @Bindable var viewModel = viewModel
        let visibleGames = viewModel.filteredLibraryGames

        return GameGrid(
            games: visibleGames,
            focusedId: $focusedGameId,
            hasActiveFilters: !viewModel.libraryFilterState.isEmpty,
            onClearFilters: { viewModel.libraryFilterState.clear() },
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

        return VStack(alignment: .leading, spacing: 0) {
            if let statusMessage = viewModel.libraryError ?? viewModel.libraryWarning {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(statusMessage)
                        .font(.caption)
                        .lineLimit(2)
                }
                .foregroundStyle(viewModel.libraryError == nil ? .orange : .red)
                .padding(.horizontal, 60)
                .padding(.top, 24)
            }
            GameFilterBar(
                totalCount: viewModel.libraryGames.count,
                resultCount: visibleGames.count,
                context: .library,
                options: viewModel.libraryFilterOptions,
                availableSortOrders: LibrarySortOrder.allCases,
                previewBaseCount: viewModel.libraryFilterBaseCount,
                previewCount: viewModel.libraryPreviewCount,
                filterState: $viewModel.libraryFilterState,
                sortOrder: $viewModel.librarySortOrder
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: viewModel.libraryError != nil ? "exclamationmark.triangle" : "books.vertical")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(viewModel.libraryError != nil ? L10n.text("library_failed_to_load") : L10n.text("library_empty"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            if let err = viewModel.libraryError ?? viewModel.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
            } else {
                Text(L10n.text("games_you_own_or_have_linked_will_appear_here"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(60)
    }
}

// MARK: - Shared Game Views

struct GameBoxArt: View {
    let url: String?

    var body: some View {
        SharedArtworkImage(
            urlString: url,
            maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
        )
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct GameCardLabel: View {
    let game: GameInfo
    var showLibraryBadge: Bool = false

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

            if showLibraryBadge, game.isInLibrary {
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
        .prefetchHeroArtOnFocus(game.heroImageUrl ?? game.heroBannerUrl)
    }
}

// MARK: - Shared Game Grid

struct GameGrid<Header: View>: View {
    let games: [GameInfo]
    var focusedId: FocusState<String?>.Binding
    var showLibraryBadge: Bool = false
    var pageSize: Int?
    var boxArtPrefetchDistance = 0
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void
    let onSelect: (GameInfo) -> Void
    let onExpand: (GameInfo) -> Void // Nouveau closure pour l'expansion directe
    @ViewBuilder let header: Header

    @Environment(GamesViewModel.self) var viewModel

    @State private var visibleGameCount = 0

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40)]

    private var renderedGameCount: Int {
        guard let pageSize else { return games.count }
        return min(games.count, max(visibleGameCount, pageSize))
    }

    private var contentIdentity: [String] {
        [String(games.count)]
            + games.prefix(4).map(\.id)
            + games.suffix(4).map(\.id)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                if games.isEmpty {
                    FilteredGamesEmptyView(
                        hasActiveFilters: hasActiveFilters,
                        onClearFilters: onClearFilters
                    )
                    .frame(minHeight: 620)
                } else {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(Array(games.prefix(renderedGameCount).enumerated()), id: \.element.id) { index, game in
                            Button { onSelect(game) } label: {
                                GameCardLabel(game: game, showLibraryBadge: showLibraryBadge)
                            }
                            .aspectRatio(2 / 3, contentMode: .fit)
                            .buttonStyle(.card)
                            .focused(focusedId, equals: game.id)
                            .contextMenu {
                                Button {
                                    onExpand(game)
                                } label: {
                                    Label("Info", systemImage: "info.circle")
                                }
                                if game.isInLibrary {
                                    let isFav = viewModel.favoriteIds.contains(game.id)
                                    Button { viewModel.toggleFavorite(game.id) } label: {
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
                                                    if viewModel.preferredVariantId(for: game) == variant.id {
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
                            .onAppear { gameAppeared(at: index) }
                        }
                    }
                    .padding(60)
                    .focusSection()
                }
            }
        }
        .onChange(of: contentIdentity) {
            visibleGameCount = pageSize ?? 0
        }
    }

    private func gameAppeared(at index: Int) {
        if boxArtPrefetchDistance > 0 {
            let start = index + 1
            let end = min(games.count, start + boxArtPrefetchDistance)
            if start < end {
                BoxArtPrefetcher.shared.prefetch(
                    games[start ..< end].compactMap(\.boxArtUrl)
                )
            }
        }

        guard let pageSize, renderedGameCount < games.count else { return }
        let loadMoreThreshold = max(0, renderedGameCount - max(boxArtPrefetchDistance, 12))
        guard index >= loadMoreThreshold else { return }
        visibleGameCount = min(games.count, renderedGameCount + pageSize)
    }
}

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
