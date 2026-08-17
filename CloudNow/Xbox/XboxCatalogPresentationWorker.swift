import Foundation

nonisolated struct XboxCatalogPresentationInput: Sendable {
    let items: [XboxCatalogItem]
    let favoriteIDs: Set<String>
    let recentlyPlayedIDs: [String]
    let searchText: String
    let sortOrder: XboxCatalogSortOrder
    let filterState: XboxCatalogFilterState
    let visibleItemLimit: Int
}

nonisolated struct XboxCatalogPresentationSnapshot: Equatable, Sendable {
    let visibleItems: [XboxCatalogItem]
    let carouselItems: [XboxCatalogItem]
    let favoriteItems: [XboxCatalogItem]
    let recentlyPlayedItems: [XboxCatalogItem]
    let availableAccessKinds: Set<XboxCloudAccessKind>
    let playableAccessKinds: Set<XboxCloudAccessKind>
    let filterOptions: XboxCatalogFilterOptions
    let totalItemCount: Int
    let browseFilterBaseCount: Int
    let filteredItemCount: Int
}

nonisolated protocol XboxCatalogPresentationBuilding: Sendable {
    func build(
        _ input: XboxCatalogPresentationInput
    ) async throws -> XboxCatalogPresentationSnapshot
}

/// Owns catalog derivation away from the UI actor. Inputs and outputs are
/// immutable values, so cancellation and generation fencing never expose a
/// partially derived catalog to SwiftUI.
actor XboxCatalogPresentationWorker: XboxCatalogPresentationBuilding {
    func build(
        _ input: XboxCatalogPresentationInput
    ) async throws -> XboxCatalogPresentationSnapshot {
        try Task.checkCancellation()
        let presentableItems = try presentableItems(input.items)
        let availableAccessKinds = Set(presentableItems.flatMap(\.accessKinds))
        let playableAccessKinds = Set(presentableItems.flatMap { item in
            item.routes.compactMap { route in
                route.isPlayable ? route.accessKind : nil
            }
        })
        let searchedItems = try search(
            presentableItems,
            query: input.searchText
        )
        let filteredItems = try filter(
            searchedItems,
            state: input.filterState,
            favoriteIDs: input.favoriteIDs
        )
        let carouselItems = try sort(
            filteredItems,
            order: input.sortOrder,
            recentlyPlayedIDs: input.recentlyPlayedIDs
        )
        let itemsByID = Dictionary(
            presentableItems.map { ($0.id, $0) },
            uniquingKeysWith: { retained, _ in retained }
        )
        let favoriteItems = presentableItems.filter {
            input.favoriteIDs.contains($0.id)
        }
        let recentlyPlayedItems = input.recentlyPlayedIDs.compactMap {
            itemsByID[$0]
        }
        let filterOptions = try makeFilterOptions(
            presentableItems: presentableItems,
            favoriteIDs: input.favoriteIDs
        )
        try Task.checkCancellation()
        return XboxCatalogPresentationSnapshot(
            visibleItems: Array(
                carouselItems.prefix(max(0, input.visibleItemLimit))
            ),
            carouselItems: carouselItems,
            favoriteItems: favoriteItems,
            recentlyPlayedItems: recentlyPlayedItems,
            availableAccessKinds: availableAccessKinds,
            playableAccessKinds: playableAccessKinds,
            filterOptions: filterOptions,
            totalItemCount: presentableItems.count,
            browseFilterBaseCount: searchedItems.count,
            filteredItemCount: carouselItems.count
        )
    }

    private func presentableItems(
        _ items: [XboxCatalogItem]
    ) throws -> [XboxCatalogItem] {
        var result: [XboxCatalogItem] = []
        result.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            if !item.isTouchOnlyOnTVOS {
                result.append(item)
            }
        }
        return result
    }

    private func search(
        _ items: [XboxCatalogItem],
        query: String
    ) throws -> [XboxCatalogItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        var result: [XboxCatalogItem] = []
        result.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            if item.title.localizedCaseInsensitiveContains(query) {
                result.append(item)
            }
        }
        return result
    }

    private func filter(
        _ items: [XboxCatalogItem],
        state: XboxCatalogFilterState,
        favoriteIDs: Set<String>
    ) throws -> [XboxCatalogItem] {
        guard !state.isEmpty else { return items }
        var result: [XboxCatalogItem] = []
        result.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            if matches(item, state: state, favoriteIDs: favoriteIDs) {
                result.append(item)
            }
        }
        return result
    }

    private func matches(
        _ item: XboxCatalogItem,
        state: XboxCatalogFilterState,
        favoriteIDs: Set<String>
    ) -> Bool {
        if !state.collections.isEmpty {
            let matchesCollection = state.collections.contains(.favorites)
                && favoriteIDs.contains(item.id)
            guard matchesCollection else { return false }
        }

        if !state.access.isEmpty {
            let matchesAccess = state.access.contains { access in
                switch access {
                case .standard:
                    item.accessKinds.contains(.standard)
                case .freeWithAds:
                    item.supportsFreeWithAds
                case .owned:
                    item.isOwned
                }
            }
            guard matchesAccess else { return false }
        }

        if !state.playability.isEmpty {
            let hasPlayableRoute = item.routes.contains(where: \.isPlayable)
            let matchesPlayability =
                state.playability.contains(.playable) && hasPlayableRoute
                    || state.playability.contains(.unavailable)
                    && !hasPlayableRoute
            guard matchesPlayability else { return false }
        }

        if !state.unavailableReasons.isEmpty {
            let itemReasons = Set(item.routes.compactMap { route in
                route.isPlayable ? nil : route.playabilityReason
            })
            guard !state.unavailableReasons.isDisjoint(with: itemReasons) else {
                return false
            }
        }

        if !state.inputTypes.isEmpty,
           state.inputTypes.isDisjoint(with: item.supportedInputTypes)
        {
            return false
        }

        if !state.genres.isEmpty {
            let itemGenres = Set(item.genres.compactMap(Self.genreID))
            guard !state.genres.isDisjoint(with: itemGenres) else {
                return false
            }
        }
        return true
    }

    private func sort(
        _ items: [XboxCatalogItem],
        order: XboxCatalogSortOrder,
        recentlyPlayedIDs: [String]
    ) throws -> [XboxCatalogItem] {
        try Task.checkCancellation()
        switch order {
        case .default:
            return items
        case .titleAZ:
            return items.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .titleZA:
            return items.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedDescending
            }
        case .recentFirst:
            let recentRanks = Dictionary(
                uniqueKeysWithValues: recentlyPlayedIDs.enumerated().map {
                    ($0.element, $0.offset)
                }
            )
            return items.sorted { left, right in
                let leftRank = recentRanks[left.id] ?? .max
                let rightRank = recentRanks[right.id] ?? .max
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return left.title.localizedStandardCompare(right.title)
                    == .orderedAscending
            }
        }
    }

    private func makeFilterOptions(
        presentableItems: [XboxCatalogItem],
        favoriteIDs: Set<String>
    ) throws -> XboxCatalogFilterOptions {
        var genreLabels: [String: String] = [:]
        var genreCounts: [String: Int] = [:]
        var inputTypeCounts: [XboxCloudInputType: Int] = [:]
        var unavailableReasonCounts: [
            XboxCloudRoutePlayabilityReason: Int
        ] = [:]
        var favoriteCount = 0
        var standardCount = 0
        var freeWithAdsCount = 0
        var ownedCount = 0
        var playableCount = 0

        for (index, item) in presentableItems.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            favoriteCount += favoriteIDs.contains(item.id) ? 1 : 0
            standardCount += item.accessKinds.contains(.standard) ? 1 : 0
            freeWithAdsCount += item.supportsFreeWithAds ? 1 : 0
            ownedCount += item.isOwned ? 1 : 0
            let isPlayable = item.routes.contains(where: \.isPlayable)
            playableCount += isPlayable ? 1 : 0

            for inputType in item.supportedInputTypes where inputType != .touch {
                inputTypeCounts[inputType, default: 0] += 1
            }
            let unavailableReasons = Set(item.routes.compactMap { route in
                route.isPlayable ? nil : route.playabilityReason
            })
            for reason in unavailableReasons {
                unavailableReasonCounts[reason, default: 0] += 1
            }
            var itemGenreIDs: Set<String> = []
            for genre in item.genres {
                let label = genre.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let id = Self.genreID(label),
                      itemGenreIDs.insert(id).inserted
                else {
                    continue
                }
                genreLabels[id] = genreLabels[id] ?? label
                genreCounts[id, default: 0] += 1
            }
        }

        let genres = genreCounts.compactMap { id, count in
            genreLabels[id].map {
                XboxCatalogGenreFilterOption(id: id, label: $0, count: count)
            }
        }.sorted {
            $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
        return XboxCatalogFilterOptions(
            genres: genres,
            inputTypeCounts: inputTypeCounts,
            favoriteCount: favoriteCount,
            standardCount: standardCount,
            freeWithAdsCount: freeWithAdsCount,
            ownedCount: ownedCount,
            playableCount: playableCount,
            unavailableCount: presentableItems.count - playableCount,
            unavailableReasonCounts: unavailableReasonCounts
        )
    }

    private nonisolated static func genreID(_ genre: String) -> String? {
        let genre = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !genre.isEmpty else { return nil }
        return genre.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale.current
        ).lowercased()
    }
}
