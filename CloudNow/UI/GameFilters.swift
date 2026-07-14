import SwiftUI

enum GameFilterContext: Equatable {
    case store
    case library
}

enum GameCollectionFilter: String, CaseIterable, Hashable, Identifiable {
    case library
    case favorites

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .library: L10n.text("my_library")
        case .favorites: L10n.text("favorites")
        }
    }
}

struct GameFilterState: Equatable {
    var collections: Set<GameCollectionFilter> = []
    var genres: Set<String> = []
    var stores: Set<String> = []
    var features: Set<GameFeature> = []

    var activeSelectionCount: Int {
        collections.count + genres.count + stores.count + features.count
    }

    var isEmpty: Bool {
        activeSelectionCount == 0
    }

    mutating func clear() {
        collections.removeAll()
        genres.removeAll()
        stores.removeAll()
        features.removeAll()
    }
}

struct GameFilterValueOption: Identifiable, Equatable {
    let id: String
    let label: String
    let count: Int
}

struct GameFilterOptions: Equatable {
    let genres: [GameFilterValueOption]
    let stores: [GameFilterValueOption]
    let features: [GameFilterValueOption]
    let libraryCount: Int
    let favoriteCount: Int

    init(games: [GameInfo], favoriteIds: Set<String>, context: GameFilterContext) {
        var genreCounts: [String: Int] = [:]
        var storeCounts: [String: Int] = [:]
        var featureCounts: [GameFeature: Int] = [:]

        for game in games {
            for genre in Set(game.genreCodes) {
                genreCounts[genre, default: 0] += 1
            }

            let storesForGame: Set<String> = switch context {
            case .store:
                Set(game.variants.map(\.appStore))
            case .library:
                Set(game.ownedStores)
            }
            for store in storesForGame {
                let code = GameStoreFilter.normalizedCode(store)
                if GameStoreFilter.isDisplayable(code) {
                    storeCounts[code, default: 0] += 1
                }
            }

            for feature in Set(game.supportedFeatures ?? []) {
                featureCounts[feature, default: 0] += 1
            }
        }

        genres = genreCounts.map { code, count in
            GameFilterValueOption(id: code, label: GameInfo.genreLabel(code), count: count)
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }

        stores = storeCounts.map { store, count in
            GameFilterValueOption(id: store, label: L10n.storeName(for: store), count: count)
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }

        features = GameFeature.allCases.compactMap { feature in
            guard let count = featureCounts[feature], count > 0 else { return nil }
            return GameFilterValueOption(id: feature.rawValue, label: feature.label, count: count)
        }

        libraryCount = games.count(where: \.isInLibrary)
        favoriteCount = games.count { favoriteIds.contains($0.id) }
    }
}

enum GameFilterEngine {
    static func apply(
        to games: [GameInfo],
        context: GameFilterContext,
        state: GameFilterState,
        searchText: String,
        sortOrder: LibrarySortOrder,
        favoriteIds: Set<String>,
        recentlyPlayedIds: [String]
    ) -> [GameInfo] {
        var result = games

        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(search) }
        }

        if !state.collections.isEmpty {
            result = result.filter { game in
                (state.collections.contains(.library) && game.isInLibrary)
                    || (state.collections.contains(.favorites) && favoriteIds.contains(game.id))
            }
        }

        if !state.genres.isEmpty {
            result = result.filter { !state.genres.isDisjoint(with: $0.genreCodes) }
        }

        if !state.stores.isEmpty {
            result = result.filter { game in
                let gameStores: [String] = switch context {
                case .store:
                    game.variants.map(\.appStore)
                case .library:
                    game.ownedStores
                }
                let normalizedStores = Set(gameStores.map(GameStoreFilter.normalizedCode))
                return !state.stores.isDisjoint(with: normalizedStores)
            }
        }

        if !state.features.isEmpty {
            result = result.filter { game in
                !state.features.isDisjoint(with: game.supportedFeatures ?? [])
            }
        }

        switch sortOrder {
        case .default:
            break
        case .titleAZ:
            result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .titleZA:
            result.sort { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        case .recentFirst:
            var recentRank: [String: Int] = [:]
            for (index, id) in recentlyPlayedIds.enumerated() where recentRank[id] == nil {
                recentRank[id] = index
            }
            result.sort { lhs, rhs in
                let leftRank = recentRank[lhs.id] ?? Int.max
                let rightRank = recentRank[rhs.id] ?? Int.max
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }

        return result
    }
}

private enum GameStoreFilter {
    private nonisolated static let internalCodes: Set<String> = ["", "UNKNOWN", "NONE", "GFN", "NVIDIA", "NV_BUNDLE"]

    nonisolated static func normalizedCode(_ value: String) -> String {
        let code = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "_")

        return switch code {
        case "EPIC", "EPIC_GAMES": "EPIC_GAMES_STORE"
        case "ORIGIN", "EA": "EA_APP"
        case "UBISOFT_CONNECT", "UPLAY": "UBISOFT"
        case "MICROSOFT": "XBOX"
        case "BATTLE_NET": "BATTLENET"
        default: code
        }
    }

    nonisolated static func isDisplayable(_ code: String) -> Bool {
        !internalCodes.contains(code)
    }
}

struct GameFilterBar: View {
    let totalCount: Int
    let resultCount: Int
    let context: GameFilterContext
    let options: GameFilterOptions
    let availableSortOrders: [LibrarySortOrder]
    let previewCount: (GameFilterState) -> Int

    @Binding var filterState: GameFilterState
    @Binding var sortOrder: LibrarySortOrder

    @State private var isShowingFilters = false

    var body: some View {
        let chips = activeChips

        return HStack(spacing: 20) {
            Text(L10n.format("games_result_count", resultCount, totalCount))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.primary)
                .fixedSize()

            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(chips) { chip in
                            ActiveFilterChip(label: chip.label, onRemove: chip.onRemove)
                        }
                    }
                }
                .scrollClipDisabled()
            }

            Spacer(minLength: 12)

            Menu {
                Picker(L10n.text("sort"), selection: $sortOrder) {
                    ForEach(availableSortOrders, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
            } label: {
                Label(sortOrder.label, systemImage: "line.3.horizontal.decrease")
            }
            .buttonStyle(.bordered)

            Button {
                isShowingFilters = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(L10n.text("filters"))
                    if filterState.activeSelectionCount > 0 {
                        Text("\(filterState.activeSelectionCount)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.green, in: Capsule())
                    }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 22)
        .fullScreenCover(isPresented: $isShowingFilters) {
            GameFilterSheet(
                state: $filterState,
                context: context,
                options: options,
                previewCount: previewCount,
                onClose: { isShowingFilters = false }
            )
        }
    }

    private struct ActiveChip: Identifiable {
        let id: String
        let label: String
        let onRemove: () -> Void
    }

    private var activeChips: [ActiveChip] {
        var chips: [ActiveChip] = []

        for collection in filterState.collections.sorted(by: { $0.rawValue < $1.rawValue }) {
            chips.append(ActiveChip(id: "collection-\(collection.rawValue)", label: collection.label) {
                filterState.collections.remove(collection)
            })
        }
        for genre in filterState.genres.sorted(by: {
            GameInfo.genreLabel($0).localizedStandardCompare(GameInfo.genreLabel($1)) == .orderedAscending
        }) {
            chips.append(ActiveChip(id: "genre-\(genre)", label: GameInfo.genreLabel(genre)) {
                filterState.genres.remove(genre)
            })
        }
        for store in filterState.stores.sorted() {
            chips.append(ActiveChip(id: "store-\(store)", label: L10n.storeName(for: store)) {
                filterState.stores.remove(store)
            })
        }
        for feature in filterState.features.sorted(by: { $0.rawValue < $1.rawValue }) {
            chips.append(ActiveChip(id: "feature-\(feature.rawValue)", label: feature.label) {
                filterState.features.remove(feature)
            })
        }
        return chips
    }
}

private struct ActiveFilterChip: View {
    let label: String
    let onRemove: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 7) {
                Text(label)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.black.opacity(0.84))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.green, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(isFocused ? Color.white : Color.clear, lineWidth: 3)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.07 : 1)
        .shadow(color: isFocused ? Color.white.opacity(0.25) : .clear, radius: 12)
        .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

private enum GameFilterSection: String, Hashable {
    case collections
    case genres
    case stores
    case features
}

private struct WrappingFilterLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let proposedWidth = proposal.width ?? .greatestFiniteMagnitude
        let result = arrangement(width: proposedWidth, subviews: subviews)
        return CGSize(
            width: proposal.width ?? result.contentWidth,
            height: result.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            let size = result.sizes[index]
            let position = result.positions[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> Arrangement {
        let availableWidth = width.isFinite ? max(width, 0) : .greatestFiniteMagnitude
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for size in sizes {
            if x > 0, x + size.width > availableWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            positions.append(CGPoint(x: x, y: y))
            contentWidth = max(contentWidth, x + size.width)
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return Arrangement(
            sizes: sizes,
            positions: positions,
            contentWidth: contentWidth,
            height: sizes.isEmpty ? 0 : y + rowHeight
        )
    }

    private struct Arrangement {
        let sizes: [CGSize]
        let positions: [CGPoint]
        let contentWidth: CGFloat
        let height: CGFloat
    }
}

private struct GameFilterSheet: View {
    @Binding var state: GameFilterState

    let context: GameFilterContext
    let options: GameFilterOptions
    let previewCount: (GameFilterState) -> Int
    let onClose: () -> Void

    @State private var expandedSections: Set<GameFilterSection> = [
        .collections,
        .genres,
        .stores,
        .features,
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.055), Color(white: 0.11)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 16) {
                        collectionsSection

                        if !options.genres.isEmpty {
                            valueSection(
                                section: .genres,
                                title: L10n.text("genres"),
                                selectedCount: state.genres.count,
                                options: options.genres,
                                selected: { state.genres.contains($0) },
                                toggle: toggleGenre
                            )
                        }

                        if !options.stores.isEmpty {
                            valueSection(
                                section: .stores,
                                title: L10n.text("game_stores"),
                                selectedCount: state.stores.count,
                                options: options.stores,
                                selected: { state.stores.contains($0) },
                                toggle: toggleStore
                            )
                        }

                        if !options.features.isEmpty {
                            valueSection(
                                section: .features,
                                title: L10n.text("features"),
                                selectedCount: state.features.count,
                                options: options.features,
                                selected: { id in state.features.contains(where: { $0.rawValue == id }) },
                                toggle: toggleFeature
                            )
                        }
                    }
                    .padding(.horizontal, 70)
                    .padding(.vertical, 22)
                }
            }
        }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        let resultCount = previewCount(state)
        let totalCount = previewCount(GameFilterState())

        return HStack(spacing: 20) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
            Text(L10n.text("filters"))
                .font(.title2.weight(.bold))

            if state.activeSelectionCount > 0 {
                Text("\(state.activeSelectionCount)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.green, in: Capsule())
            }

            Text(L10n.format("games_result_count", resultCount, totalCount))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                state.clear()
            } label: {
                Label(L10n.text("clear_all"), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .disabled(state.isEmpty)

            Button(action: onClose) {
                Label(L10n.text("done"), systemImage: "checkmark")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 70)
        .padding(.vertical, 18)
        .background(Color.black.opacity(0.38))
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    @ViewBuilder
    private var collectionsSection: some View {
        let collectionOptions = availableCollections
        if !collectionOptions.isEmpty {
            FilterAccordionSection(
                title: L10n.text("collections"),
                selectedCount: state.collections.count,
                isExpanded: sectionBinding(.collections)
            ) {
                WrappingFilterLayout(horizontalSpacing: 14, verticalSpacing: 14) {
                    ForEach(collectionOptions) { option in
                        FilterOptionButton(
                            label: option.filter.label,
                            count: option.count,
                            isSelected: state.collections.contains(option.filter),
                            action: { toggleCollection(option.filter) }
                        )
                    }
                }
            }
        }
    }

    private func valueSection(
        section: GameFilterSection,
        title: String,
        selectedCount: Int,
        options: [GameFilterValueOption],
        selected: @escaping (String) -> Bool,
        toggle: @escaping (String) -> Void
    ) -> some View {
        FilterAccordionSection(
            title: title,
            selectedCount: selectedCount,
            isExpanded: sectionBinding(section)
        ) {
            WrappingFilterLayout(horizontalSpacing: 14, verticalSpacing: 14) {
                ForEach(options) { option in
                    FilterOptionButton(
                        label: option.label,
                        count: option.count,
                        isSelected: selected(option.id),
                        action: { toggle(option.id) }
                    )
                }
            }
        }
    }

    private struct CollectionOption: Identifiable {
        let filter: GameCollectionFilter
        let count: Int
        var id: GameCollectionFilter {
            filter
        }
    }

    private var availableCollections: [CollectionOption] {
        var result: [CollectionOption] = []
        if context == .store {
            result.append(CollectionOption(filter: .library, count: options.libraryCount))
        }
        result.append(CollectionOption(filter: .favorites, count: options.favoriteCount))
        return result
    }

    private func sectionBinding(_ section: GameFilterSection) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(section) },
            set: { expanded in
                if expanded {
                    expandedSections.insert(section)
                } else {
                    expandedSections.remove(section)
                }
            }
        )
    }

    private func toggleCollection(_ collection: GameCollectionFilter) {
        if state.collections.contains(collection) {
            state.collections.remove(collection)
        } else {
            state.collections.insert(collection)
        }
    }

    private func toggleGenre(_ genre: String) {
        if state.genres.contains(genre) {
            state.genres.remove(genre)
        } else {
            state.genres.insert(genre)
        }
    }

    private func toggleStore(_ store: String) {
        if state.stores.contains(store) {
            state.stores.remove(store)
        } else {
            state.stores.insert(store)
        }
    }

    private func toggleFeature(_ rawValue: String) {
        guard let feature = GameFeature(rawValue: rawValue) else { return }
        if state.features.contains(feature) {
            state.features.remove(feature)
        } else {
            state.features.insert(feature)
        }
    }
}

private struct FilterAccordionSection<Content: View>: View {
    let title: String
    let selectedCount: Int
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 14) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                    if selectedCount > 0 {
                        Text("\(selectedCount)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.green, in: Capsule())
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .frame(height: 58)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct FilterOptionButton: View {
    let label: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(isSelected ? .green : .secondary)
                Text(label)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 15)
            .frame(minHeight: 54)
            .background(
                isSelected ? Color.green.opacity(0.14) : Color.white.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.green.opacity(0.8) : Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.card)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(count == 0)
    }
}

struct FilteredGamesEmptyView: View {
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 58))
                .foregroundStyle(.secondary)
            Text(L10n.text("no_games_match_filters"))
                .font(.title2.weight(.semibold))
            Text(L10n.text("adjust_search_or_filters"))
                .foregroundStyle(.secondary)
            if hasActiveFilters {
                Button {
                    onClearFilters()
                } label: {
                    Label(L10n.text("clear_filters"), systemImage: "xmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
    }
}
