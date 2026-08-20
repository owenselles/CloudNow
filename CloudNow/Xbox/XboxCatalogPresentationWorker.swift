import Foundation

nonisolated struct XboxCatalogPresentationInput: Sendable {
    let items: [XboxCatalogItem]
    let favoriteIDs: Set<String>
    let recentlyPlayedIDs: [String]
    let scope: XboxCatalogScope
    let searchText: String
    let sortOrder: XboxCatalogSortOrder
    let filterState: XboxCatalogFilterState
    let visibleItemLimit: Int
}

nonisolated struct XboxCatalogPresentationSnapshot: Equatable, Sendable {
    let scope: XboxCatalogScope
    let visibleItems: [XboxCatalogItem]
    let carouselItems: [XboxCatalogItem]
    let selectedRoutesByItemID: [String: XboxCloudTitleRoute]
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
        let scopedItems = try scopedItems(
            presentableItems,
            scope: input.scope
        )
        let availableAccessKinds = Set(scopedItems.flatMap { item in
            scopedRoutes(for: item, scope: input.scope).map(\.accessKind)
        })
        let playableAccessKinds = Set(scopedItems.flatMap { item in
            item.routes.compactMap { route in
                route.isPlayable && !item.isTouchOnlyOnTVOS
                    ? route.accessKind
                    : nil
            }
        })
        let searchedItems = try search(
            scopedItems,
            query: input.searchText
        )
        let filteredEntries = try filter(
            searchedItems,
            scope: input.scope,
            state: input.filterState,
            favoriteIDs: input.favoriteIDs
        )
        let filteredItems = filteredEntries.map(\.item)
        let carouselItems = try sort(
            filteredItems,
            order: input.sortOrder,
            recentlyPlayedIDs: input.recentlyPlayedIDs
        )
        let selectedRoutesByItemID = Dictionary(
            filteredEntries.map { ($0.item.id, $0.route) },
            uniquingKeysWith: { retained, _ in retained }
        )
        let playableItems = presentableItems.filter { item in
            !item.isTouchOnlyOnTVOS
                && item.routes.contains(where: \.isPlayable)
        }
        let playableItemsByID = Dictionary(
            playableItems.map { ($0.id, $0) },
            uniquingKeysWith: { retained, _ in retained }
        )
        let favoriteItems = playableItems.filter {
            input.favoriteIDs.contains($0.id)
        }
        let recentlyPlayedItems = input.recentlyPlayedIDs.compactMap {
            playableItemsByID[$0]
        }
        let filterOptions = try makeFilterOptions(
            presentableItems: scopedItems,
            scope: input.scope,
            favoriteIDs: input.favoriteIDs
        )
        try Task.checkCancellation()
        return XboxCatalogPresentationSnapshot(
            scope: input.scope,
            visibleItems: Array(
                carouselItems.prefix(max(0, input.visibleItemLimit))
            ),
            carouselItems: carouselItems,
            selectedRoutesByItemID: selectedRoutesByItemID,
            favoriteItems: favoriteItems,
            recentlyPlayedItems: recentlyPlayedItems,
            availableAccessKinds: availableAccessKinds,
            playableAccessKinds: playableAccessKinds,
            filterOptions: filterOptions,
            totalItemCount: scopedItems.count,
            browseFilterBaseCount: searchedItems.count,
            filteredItemCount: carouselItems.count
        )
    }

    private struct Entry {
        let item: XboxCatalogItem
        let route: XboxCloudTitleRoute
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
            result.append(item)
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

    private func scopedItems(
        _ items: [XboxCatalogItem],
        scope: XboxCatalogScope
    ) throws -> [XboxCatalogItem] {
        guard scope == .library else { return items }
        var result: [XboxCatalogItem] = []
        result.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            if !item.isTouchOnlyOnTVOS,
               item.routes.contains(where: \.isPlayable)
            {
                result.append(item)
            }
        }
        return result
    }

    private func filter(
        _ items: [XboxCatalogItem],
        scope: XboxCatalogScope,
        state: XboxCatalogFilterState,
        favoriteIDs: Set<String>
    ) throws -> [Entry] {
        var result: [Entry] = []
        result.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            if let route = matchingRoute(
                for: item,
                scope: scope,
                state: state,
                favoriteIDs: favoriteIDs
            ) {
                result.append(Entry(item: item, route: route))
            }
        }
        return result
    }

    private func matchingRoute(
        for item: XboxCatalogItem,
        scope: XboxCatalogScope,
        state: XboxCatalogFilterState,
        favoriteIDs: Set<String>
    ) -> XboxCloudTitleRoute? {
        if !state.collections.isEmpty {
            let matchesCollection = state.collections.contains(.favorites)
                && favoriteIDs.contains(item.id)
            guard matchesCollection else { return nil }
        }

        var routes = scopedRoutes(for: item, scope: scope)
        if !state.access.isEmpty {
            let matchesOwned = state.access.contains(.owned) && item.isOwned
            if !matchesOwned {
                let accessKinds = Set(state.access.compactMap { access in
                    switch access {
                    case .standard:
                        XboxCloudAccessKind.standard
                    case .freeWithAds:
                        XboxCloudAccessKind.freeWithAds
                    case .owned:
                        nil
                    }
                })
                routes.removeAll { !accessKinds.contains($0.accessKind) }
            }
        }

        if !state.playability.isEmpty {
            routes.removeAll { route in
                let isPlayable = route.isPlayable && !item.isTouchOnlyOnTVOS
                return isPlayable
                    ? !state.playability.contains(.playable)
                    : !state.playability.contains(.unavailable)
            }
        }

        if !state.unavailableReasons.isEmpty {
            routes.removeAll { route in
                route.isPlayable
                    || !state.unavailableReasons.contains(
                        route.playabilityReason
                    )
            }
        }

        if !state.inputTypes.isEmpty,
           state.inputTypes.isDisjoint(with: item.supportedInputTypes)
        {
            return nil
        }

        if !state.genres.isEmpty {
            let itemGenres = Set(item.genres.compactMap(Self.genreID))
            guard !state.genres.isDisjoint(with: itemGenres) else {
                return nil
            }
        }
        return preferredRoute(in: routes)
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
        scope: XboxCatalogScope,
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
        var unavailableCount = 0

        for (index, item) in presentableItems.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            favoriteCount += favoriteIDs.contains(item.id) ? 1 : 0
            let routes = scopedRoutes(for: item, scope: scope)
            standardCount += routes.contains {
                $0.accessKind == .standard
            } ? 1 : 0
            freeWithAdsCount += routes.contains {
                $0.accessKind == .freeWithAds
            } ? 1 : 0
            ownedCount += item.isOwned ? 1 : 0
            let isPlayable = !item.isTouchOnlyOnTVOS
                && routes.contains(where: \.isPlayable)
            playableCount += isPlayable ? 1 : 0
            let isUnavailable = item.isTouchOnlyOnTVOS
                || routes.contains { !$0.isPlayable }
            unavailableCount += isUnavailable ? 1 : 0

            for inputType in item.supportedInputTypes where inputType != .touch {
                inputTypeCounts[inputType, default: 0] += 1
            }
            let unavailableReasons = Set(routes.compactMap { route in
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
            unavailableCount: unavailableCount,
            unavailableReasonCounts: unavailableReasonCounts
        )
    }

    private func scopedRoutes(
        for item: XboxCatalogItem,
        scope: XboxCatalogScope
    ) -> [XboxCloudTitleRoute] {
        switch scope {
        case .library:
            item.isTouchOnlyOnTVOS ? [] : item.routes.filter(\.isPlayable)
        case .browse:
            item.routes
        }
    }

    private func preferredRoute(
        in routes: [XboxCloudTitleRoute]
    ) -> XboxCloudTitleRoute? {
        routes.min { left, right in
            if left.isPlayable != right.isPlayable {
                return left.isPlayable
            }
            let leftPriority = accessPriority(left.accessKind)
            let rightPriority = accessPriority(right.accessKind)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            return left.titleID < right.titleID
        }
    }

    private func accessPriority(_ kind: XboxCloudAccessKind) -> Int {
        switch kind {
        case .standard:
            0
        case .freeWithAds:
            1
        }
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
