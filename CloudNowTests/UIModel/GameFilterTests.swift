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
        state.subscriptions = [.xboxGamePass, .ubisoftPremium]
        state.features = [.hdr, .rtx]

        #expect(!state.isEmpty)
        #expect(state.activeSelectionCount == 8)

        state.clear()
        #expect(state.isEmpty)
        #expect(state.activeSelectionCount == 0)
        #expect(state.subscriptions.isEmpty)
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

    @Test("Subscription options count games once and retain plan order")
    func subscriptionOptionCounts() {
        let games = [
            game(
                id: "multiple",
                title: "Multiple",
                stores: [("UPLAY", false), ("XBOX", false)],
                subscriptions: [
                    "UPLAY": [.ubisoftClassic, .xboxGamePass, .ubisoftPremium, .xboxGamePass],
                    "XBOX": [.xboxGamePass],
                ]
            ),
            game(
                id: "second",
                title: "Second",
                stores: [("XBOX", false)],
                subscriptions: ["XBOX": [.xboxGamePass]]
            ),
        ]

        let options = GameFilterOptions(games: games, favoriteIds: [], context: .store)

        #expect(options.subscriptions.map(\.id) == ["XBOX_GAME_PASS", "UBISOFT_PREMIUM", "UBISOFT_CLASSIC"])
        #expect(options.subscriptions.map(\.label) == ["Xbox Game Pass", "Ubisoft+ Premium", "Ubisoft+ Classics"])
        #expect(options.subscriptions.map(\.count) == [2, 1, 1])
    }

    @Test("Subscriptions use OR within the category and AND with other categories")
    func subscriptionCategorySemantics() {
        let games = [
            game(
                id: "game-pass", title: "Game Pass", genres: ["Action"], stores: [("UPLAY", false)],
                subscriptions: ["UPLAY": [.xboxGamePass]], features: [.hdr]
            ),
            game(
                id: "premium", title: "Premium", genres: ["Action"], stores: [("UPLAY", false)],
                subscriptions: ["UPLAY": [.ubisoftPremium]], features: [.hdr]
            ),
            game(
                id: "classic", title: "Classic", genres: ["Action"], stores: [("UPLAY", false)],
                subscriptions: ["UPLAY": [.ubisoftClassic]], features: [.hdr]
            ),
            game(
                id: "wrong-genre", title: "Wrong Genre", genres: ["Strategy"], stores: [("UPLAY", false)],
                subscriptions: ["UPLAY": [.xboxGamePass]], features: [.hdr]
            ),
            game(
                id: "wrong-feature", title: "Wrong Feature", genres: ["Action"], stores: [("UPLAY", false)],
                subscriptions: ["UPLAY": [.xboxGamePass]], features: [.rtx]
            ),
        ]
        var state = GameFilterState()
        state.subscriptions = [.xboxGamePass, .ubisoftPremium]
        state.genres = ["ACTION"]
        state.features = [.hdr]

        #expect(apply(games, state: state).map(\.id) == ["game-pass", "premium"])

        state.collections = [.favorites]
        #expect(apply(games, state: state, favorites: ["premium"]).map(\.id) == ["premium"])
    }

    @Test("Store and subscription selections must match the same variant")
    func subscriptionsMatchSelectedStoreVariant() {
        let games = [
            game(
                id: "variants", title: "Variants", stores: [("STEAM", true), ("UPLAY", true)],
                subscriptions: ["STEAM": [], "UPLAY": [.ubisoftPremium]]
            ),
        ]
        var state = GameFilterState()
        state.stores = ["STEAM"]
        state.subscriptions = [.ubisoftPremium]

        #expect(apply(games, state: state).isEmpty)

        state.stores = ["STEAM", "UBISOFT"]
        #expect(apply(games, state: state).map(\.id) == ["variants"])

        state.stores = ["STEAM"]
        state.subscriptions.removeAll()
        #expect(apply(games, state: state).map(\.id) == ["variants"])
    }

    @Test("Library subscription options and matches exclude unowned variants")
    func subscriptionsRespectVariantOwnership() {
        let games = [
            game(
                id: "variants", title: "Variants", stores: [("UPLAY", true), ("UBISOFT_CONNECT", false)],
                subscriptions: ["UPLAY": [.ubisoftPremium], "UBISOFT_CONNECT": [.xboxGamePass]], library: true
            ),
        ]
        let store = GameFilterOptions(games: games, favoriteIds: [], context: .store)
        let library = GameFilterOptions(games: games, favoriteIds: [], context: .library)
        #expect(store.subscriptions.map(\.id) == ["XBOX_GAME_PASS", "UBISOFT_PREMIUM"])
        #expect(library.subscriptions.map(\.id) == ["UBISOFT_PREMIUM"])

        var state = GameFilterState()
        state.stores = ["UBISOFT"]
        state.subscriptions = [.xboxGamePass]
        #expect(apply(games, context: .store, state: state).map(\.id) == ["variants"])
        #expect(apply(games, context: .library, state: state).isEmpty)

        state.subscriptions = [.ubisoftPremium]
        #expect(apply(games, context: .library, state: state).map(\.id) == ["variants"])
    }

    @Test("Missing or empty subscription metadata adds no filter options or matches")
    func absentSubscriptionMetadata() {
        let games = [
            game(id: "missing", title: "Missing", stores: [("XBOX", false)]),
            game(id: "empty", title: "Empty", stores: [("UPLAY", false)], subscriptions: ["UPLAY": []]),
        ]
        let options = GameFilterOptions(games: games, favoriteIds: [], context: .store)
        #expect(options.subscriptions.isEmpty)
        #expect(apply(games).map(\.id) == ["missing", "empty"])

        var state = GameFilterState()
        state.subscriptions = [.xboxGamePass, .ubisoftPremium]
        #expect(apply(games, state: state).isEmpty)
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
                subscriptions: ["STEAM": []],
                features: [.hdr],
                library: true
            ),
            game(
                id: "two",
                title: "Beta",
                genres: ["Strategy"],
                stores: [("EPIC", false)],
                subscriptions: ["EPIC": [.xboxGamePass]],
                features: [.reflex]
            ),
            game(
                id: "three",
                title: "Gamma",
                genres: ["Action"],
                stores: [("EA", true)],
                subscriptions: ["EA": [.xboxGamePass]],
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
        var subscription = combined
        subscription.subscriptions = [.xboxGamePass]
        let cases: [(GameFilterContext, GameFilterState, String)] = [
            (.store, GameFilterState(), ""),
            (.store, genre, "a"),
            (.store, combined, ""),
            (.library, GameFilterState(), ""),
            (.library, combined, " "),
            (.store, subscription, ""),
            (.library, subscription, ""),
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
        subscriptions: [String: [GameSubscription]] = [:],
        features: [GameFeature] = [],
        library: Bool = false
    ) -> GameInfo {
        var result = TestGameFactory.make(
            id: id,
            title: title,
            genres: genres,
            stores: stores.map { (code: $0.0, owned: $0.1) },
            features: features,
            isInLibrary: library
        )
        for index in result.variants.indices {
            result.variants[index].subscriptions = subscriptions[result.variants[index].appStore]
        }
        return result
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
