@testable import CloudNow
import Foundation
import Testing

@Suite("Game filtering, options, and sorting")
@MainActor
struct GameFilterTests {
    @Test("Filter state starts empty, counts selections, and clears atomically")
    func filterStateLifecycle() {
        var state = GameFilterState()
        #expect(state.isEmpty)
        #expect(state.activeSelectionCount == 0)

        state.collections = [.library, .favorites]
        state.genres = ["ACTION"]
        state.stores = ["STEAM"]
        state.features = [.hdr, .rtx]

        #expect(!state.isEmpty)
        #expect(state.activeSelectionCount == 6)

        state.clear()
        #expect(state.isEmpty)
        #expect(state.activeSelectionCount == 0)
    }

    @Test("Search is trimmed and case-insensitive")
    func normalizedSearch() {
        let games = [
            game(id: "alpha", title: "Alpha Orbit"),
            game(id: "beta", title: "Beta Valley"),
        ]

        let result = apply(games, search: "  ALPHA\n")

        #expect(result.map(\.id) == ["alpha"])
    }

    @Test("Store context sees every variant while Library sees only owned variants")
    func contextUsesAppropriateVariants() {
        let games = [
            game(
                id: "variants",
                title: "Variants",
                stores: [("STEAM", true), ("EPIC", false)],
                library: true
            ),
        ]
        var state = GameFilterState()
        state.stores = ["EPIC_GAMES_STORE"]

        #expect(apply(games, context: .store, state: state).map(\.id) == ["variants"])
        #expect(apply(games, context: .library, state: state).isEmpty)
    }

    @Test("Library and favorites selections use OR semantics")
    func collectionFilterORSemantics() {
        let games = [
            game(id: "library", title: "Library", library: true),
            game(id: "favorite", title: "Favorite"),
            game(id: "neither", title: "Neither"),
        ]
        var state = GameFilterState()
        state.collections = [.library, .favorites]

        let result = apply(games, state: state, favorites: ["favorite"])

        #expect(Set(result.map(\.id)) == ["library", "favorite"])
    }

    @Test("Selections are OR within a category and AND across categories")
    func categorySemantics() {
        let games = [
            game(
                id: "match-action",
                title: "Action Match",
                genres: ["Action"],
                stores: [("STEAM", true)],
                features: [.hdr]
            ),
            game(
                id: "match-strategy",
                title: "Strategy Match",
                genres: ["Strategy"],
                stores: [("STEAM", true)],
                features: [.hdr]
            ),
            game(
                id: "wrong-store",
                title: "Wrong Store",
                genres: ["Action"],
                stores: [("EPIC", true)],
                features: [.hdr]
            ),
            game(
                id: "wrong-feature",
                title: "Wrong Feature",
                genres: ["Action"],
                stores: [("STEAM", true)],
                features: [.reflex]
            ),
        ]
        var state = GameFilterState()
        state.genres = ["ACTION", "STRATEGY"]
        state.stores = ["STEAM"]
        state.features = [.hdr, .rtx]

        let result = apply(games, state: state)

        #expect(Set(result.map(\.id)) == ["match-action", "match-strategy"])
    }

    @Test(
        "Store aliases normalize to their displayable canonical code",
        arguments: [
            ("EPIC", "EPIC_GAMES_STORE"),
            ("EPIC_GAMES", "EPIC_GAMES_STORE"),
            ("ORIGIN", "EA_APP"),
            ("EA", "EA_APP"),
            ("UBISOFT_CONNECT", "UBISOFT"),
            ("UPLAY", "UBISOFT"),
            ("MICROSOFT", "XBOX"),
            ("BATTLE.NET", "BATTLENET"),
        ]
    )
    func storeAliases(raw: String, expected: String) {
        let options = GameFilterOptions(
            games: [game(id: raw, title: raw, stores: [(raw, false)])],
            favoriteIds: [],
            context: .store
        )

        #expect(options.stores.map(\.id) == [expected])
        #expect(options.stores.first?.count == 1)
    }

    @Test(
        "Internal store codes do not create filter options",
        arguments: ["", "UNKNOWN", "NONE", "GFN", "NVIDIA", "NV_BUNDLE"]
    )
    func hiddenStoreCodes(raw: String) {
        let options = GameFilterOptions(
            games: [game(id: "hidden", title: "Hidden", stores: [(raw, true)])],
            favoriteIds: [],
            context: .store
        )

        #expect(options.stores.isEmpty)
    }

    @Test("Store options use all variants in Store and owned variants in Library")
    func contextSpecificStoreOptions() {
        let games = [
            game(
                id: "variants",
                title: "Variants",
                stores: [("STEAM", true), ("EPIC", false)],
                library: true
            ),
        ]

        let store = GameFilterOptions(games: games, favoriteIds: [], context: .store)
        let library = GameFilterOptions(games: games, favoriteIds: [], context: .library)

        #expect(Set(store.stores.map(\.id)) == ["STEAM", "EPIC_GAMES_STORE"])
        #expect(library.stores.map(\.id) == ["STEAM"])
    }

    @Test("Duplicate values and aliases count once per game")
    func optionCountsDeduplicateWithinGame() {
        let games = [
            game(
                id: "duplicates",
                title: "Duplicates",
                genres: ["Action", "ACTION", "action"],
                stores: [("EPIC", false), ("EPIC_GAMES", false)],
                features: [.hdr, .hdr]
            ),
        ]

        let options = GameFilterOptions(games: games, favoriteIds: [], context: .store)

        #expect(options.genres.first(where: { $0.id == "ACTION" })?.count == 1)
        #expect(options.stores.first(where: { $0.id == "EPIC_GAMES_STORE" })?.count == 1)
        #expect(options.features.first(where: { $0.id == "hdr" })?.count == 1)
    }

    @Test("Library and favorite counts are independent")
    func collectionCounts() {
        let games = [
            game(id: "one", title: "One", library: true),
            game(id: "two", title: "Two", library: true),
            game(id: "three", title: "Three"),
        ]

        let options = GameFilterOptions(
            games: games,
            favoriteIds: ["two", "three"],
            context: .store
        )

        #expect(options.libraryCount == 2)
        #expect(options.favoriteCount == 2)
    }

    @Test("Alphabetical sorting works in both directions")
    func alphabeticalSorting() {
        let games = [
            game(id: "z", title: "Zulu"),
            game(id: "a", title: "Alpha"),
            game(id: "m", title: "Mike"),
        ]

        #expect(apply(games, sort: .titleAZ).map(\.id) == ["a", "m", "z"])
        #expect(apply(games, sort: .titleZA).map(\.id) == ["z", "m", "a"])
    }

    @Test("Recent sorting honors the first duplicate ID and alphabetizes absent games")
    func recentSortingAndFallback() {
        let games = [
            game(id: "z", title: "Zulu"),
            game(id: "a", title: "Alpha"),
            game(id: "m", title: "Mike"),
            game(id: "b", title: "Beta"),
        ]

        let result = apply(
            games,
            sort: .recentFirst,
            recent: ["m", "a", "m", "missing"]
        )

        #expect(result.map(\.id) == ["m", "a", "b", "z"])
    }

    @Test("Count always matches apply for representative filter matrices")
    func countMatchesApply() {
        let games = [
            game(
                id: "one",
                title: "Alpha",
                genres: ["Action"],
                stores: [("STEAM", true)],
                features: [.hdr],
                library: true
            ),
            game(
                id: "two",
                title: "Beta",
                genres: ["Strategy"],
                stores: [("EPIC", false)],
                features: [.reflex]
            ),
            game(
                id: "three",
                title: "Gamma",
                genres: ["Action"],
                stores: [("EA", true)],
                features: [.rtx],
                library: true
            ),
        ]
        let favorites: Set = ["two"]
        var genre = GameFilterState()
        genre.genres = ["ACTION"]
        var combined = GameFilterState()
        combined.collections = [.library, .favorites]
        combined.stores = ["STEAM", "EA_APP"]
        combined.features = [.hdr, .rtx]
        let cases: [(GameFilterContext, GameFilterState, String)] = [
            (.store, GameFilterState(), ""),
            (.store, genre, "a"),
            (.store, combined, ""),
            (.library, GameFilterState(), ""),
            (.library, combined, " "),
        ]

        for (context, state, search) in cases {
            let applied = apply(
                games,
                context: context,
                state: state,
                search: search,
                favorites: favorites
            )
            let count = GameFilterEngine.count(
                in: games,
                context: context,
                state: state,
                searchText: search,
                favoriteIds: favorites
            )
            #expect(count == applied.count, "Context \(context), state \(state), search \(search)")
        }
    }

    private func game(
        id: String,
        title: String,
        genres: [String] = [],
        stores: [(String, Bool)] = [],
        features: [GameFeature] = [],
        library: Bool = false
    ) -> GameInfo {
        TestGameFactory.make(
            id: id,
            title: title,
            genres: genres,
            stores: stores.map { (code: $0.0, owned: $0.1) },
            features: features,
            isInLibrary: library
        )
    }

    private func apply(
        _ games: [GameInfo],
        context: GameFilterContext = .store,
        state: GameFilterState = GameFilterState(),
        search: String = "",
        sort: LibrarySortOrder = .default,
        favorites: Set<String> = [],
        recent: [String] = []
    ) -> [GameInfo] {
        GameFilterEngine.apply(
            to: games,
            context: context,
            state: state,
            searchText: search,
            sortOrder: sort,
            favoriteIds: favorites,
            recentlyPlayedIds: recent
        )
    }
}
