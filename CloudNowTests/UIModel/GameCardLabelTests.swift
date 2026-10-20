@testable import CloudNow
import Testing

@Suite("Game card footer content")
@MainActor
struct GameCardLabelTests {
    @Test("Available stores appear regardless of library ownership", arguments: [false, true])
    func storesDoNotRequireOwnership(isInLibrary: Bool) throws {
        let game = TestGameFactory.make(
            id: "stores",
            title: "Stores",
            stores: [("STEAM", isInLibrary), ("XBOX", false)],
            isInLibrary: isInLibrary
        )

        let footer = try #require(GameCardLabel(game: game).focusedFooter)
        #expect(footer.stores == ["Steam", "Xbox"])
        #expect(footer.subscriptions.isEmpty)
    }

    @Test("A single store needs no subscription metadata")
    func singleStore() throws {
        let game = TestGameFactory.make(
            id: "single-store",
            title: "Single Store",
            stores: [("STEAM", false)]
        )

        let footer = try #require(GameCardLabel(game: game).focusedFooter)
        #expect(footer.stores == ["Steam"])
        #expect(footer.subscriptions.isEmpty)
    }

    @Test("Store aliases are deduplicated in variant order and internal codes stay hidden")
    func normalizedStores() throws {
        let game = TestGameFactory.make(
            id: "aliases",
            title: "Aliases",
            stores: [
                (" Uplay ", false), ("UBISOFT_CONNECT", false),
                ("EPIC", false), ("EPIC_GAMES_STORE", false),
                ("MICROSOFT", false), ("XBOX", false),
                ("GFN", false),
            ]
        )

        let footer = try #require(GameCardLabel(game: game).focusedFooter)
        #expect(footer.stores == ["Ubisoft Connect", "Epic Games", "Xbox"])
    }

    @Test("Full subscription names remain separate from stores without duplicates")
    func subscriptionServices() throws {
        var game = TestGameFactory.make(
            id: "subscriptions",
            title: "Subscriptions",
            stores: [("STEAM", false), ("UPLAY", false)]
        )
        game.variants[0].subscriptions = [.xboxGamePass]
        game.variants[1].subscriptions = [.ubisoftClassic, .ubisoftPremium, .xboxGamePass]

        let footer = try #require(GameCardLabel(game: game).focusedFooter)
        #expect(footer.stores == ["Steam", "Ubisoft Connect"])
        #expect(footer.subscriptions == ["Xbox Game Pass", "Ubisoft+ Premium", "Ubisoft+ Classics"])
    }

    @Test("Install-to-Play keeps stores and subscriptions in separate footer rows", arguments: [false, true])
    func installToPlayMetadata(isInLibrary: Bool) throws {
        var game = TestGameFactory.make(
            id: "install-to-play",
            title: "Install-to-Play",
            stores: [("STEAM", isInLibrary)],
            isInLibrary: isInLibrary
        )
        game.variants[0].subscriptions = [.xboxGamePass]
        game.playType = .installToPlay

        let footer = try #require(GameCardLabel(game: game).focusedFooter)
        #expect(footer.stores == ["Steam"])
        #expect(footer.subscriptions == ["Xbox Game Pass"])
        #expect(footer.isInstallToPlay)
    }

    @Test("Install-to-Play can supply a footer without other metadata")
    func installToPlayOnly() throws {
        var game = TestGameFactory.make(id: "install-only", title: "Install Only")
        game.playType = .installToPlay

        let footer = try #require(GameCardLabel(game: game).focusedFooter)
        #expect(footer.stores.isEmpty)
        #expect(footer.subscriptions.isEmpty)
        #expect(footer.isInstallToPlay)
    }

    @Test("Only confirmed Install-to-Play games receive the extra row", arguments: [
        GamePlayType?.none, .readyToPlay, .unknown,
    ])
    func ordinaryFooter(playType: GamePlayType?) throws {
        var game = TestGameFactory.make(
            id: "ordinary",
            title: "Ordinary",
            stores: [("STEAM", false)]
        )
        game.playType = playType

        let footer = try #require(GameCardLabel(game: game).focusedFooter)
        #expect(footer.stores == ["Steam"])
        #expect(!footer.isInstallToPlay)
    }

    @Test("No footer appears without displayable stores or subscriptions", arguments: [
        [String](),
        ["", "UNKNOWN", "NONE", "GFN", "NVIDIA", "NV_BUNDLE"],
    ])
    func noDisplayableMetadata(stores: [String]) {
        let game = TestGameFactory.make(
            id: "no-metadata",
            title: "No Metadata",
            stores: stores.map { ($0, false) }
        )

        #expect(GameCardLabel(game: game).focusedFooter == nil)
    }

    @Test("Compact summaries count only hidden names", arguments: [
        (["Steam", "Xbox", "Epic Games", "Ubisoft Connect"], 2, "Steam · Xbox +2"),
        (["Steam", "Xbox"], 2, "Steam · Xbox"),
        (["Steam"], 2, "Steam"),
        (["Xbox Game Pass", "Ubisoft+ Premium", "Ubisoft+ Classics"], 1, "Xbox Game Pass +2"),
        (["Xbox Game Pass"], 1, "Xbox Game Pass"),
        ([], 2, ""),
    ])
    func compactSummary(items: [String], visibleCount: Int, expected: String) {
        #expect(CloudCatalogCardFooter.summary(items, visibleCount: visibleCount) == expected)
    }
}
