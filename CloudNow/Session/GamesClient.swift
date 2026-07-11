import Foundation
import os.log

private let gamesLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "Games")

struct LibraryFetchResult {
    let games: [GameInfo]
    let warning: String?
}

// MARK: - GamesClient

/// Fetches the GFN game catalog via the GraphQL browse API and persisted-query metadata enrichment.
actor GamesClient {
    private static let graphqlURL = "https://games.geforce.com/graphql"
    private static let metadataQueryHash = "cf8b620dfd03617017ba7c858cee65197e1ace5180e41be194b39227227ced63"
    private static let ownedAppsQueryHash = "698bbc7e16a17c8e3fc56944a0e6d62e7d70296b29dfb35fb4d83ebd66dd10f1"
    private static let clientId = NVIDIAAuth.gfnClientId
    private static let clientVersion = NVIDIAAuth.gfnClientVersion

    private let urlSession = URLSession.shared
    private var metadataCache: [String: AppData] = [:]
    private var localeCode: String {
        L10n.nvidiaLocaleCode()
    }

    private static let browseQuery = """
    query GetFilterBrowseResults($vpcId: String!, $locale: String!, $sortString: String!, $fetchCount: Int!, $cursor: String!, $filters: AppFilterFields!) {
        apps(vpcId: $vpcId, language: $locale, orderBy: $sortString, first: $fetchCount, after: $cursor, filters: $filters) {
            numberReturned pageInfo { hasNextPage endCursor totalCount }
            items {
                id title
                images { GAME_BOX_ART TV_BANNER HERO_IMAGE }
                variants { id appStore supportedControls gfn { status library { status selected } features { __typename ... on GfnSubscriptionFeatureInterface { key } ... on GfnSubscriptionFeatureValue { value } ... on GfnSubscriptionFeatureValueList { values } } } }
                gfn { playabilityState minimumMembershipTierLabel }
            }
        }
    }
    """

    private static let searchQuery = """
    query GetSearchFilterResults($vpcId: String!, $locale: String!, $sortString: String!, $fetchCount: Int!, $cursor: String!, $searchString: String!, $filters: AppFilterFields!) {
        apps(vpcId: $vpcId, language: $locale, orderBy: $sortString, first: $fetchCount, after: $cursor, searchQuery: $searchString, filters: $filters) {
            numberReturned pageInfo { hasNextPage endCursor totalCount }
            items {
                id title
                images { GAME_BOX_ART TV_BANNER HERO_IMAGE }
                variants { id appStore supportedControls gfn { status library { status selected } features { __typename ... on GfnSubscriptionFeatureInterface { key } ... on GfnSubscriptionFeatureValue { value } ... on GfnSubscriptionFeatureValueList { values } } } }
                gfn { playabilityState minimumMembershipTierLabel }
            }
        }
    }
    """

    // MARK: Fetch Full Catalog (browse API)

    func fetchMainGames(token: String, streamingBaseUrl: String = NVIDIAAuth.defaultStreamingUrl, vpcId: String? = nil) async throws -> [GameInfo] {
        let vpcId = await resolveVpcId(vpcId, token: token, baseUrl: streamingBaseUrl)
        // The public catalog is independent of the browse pagination — fetch both at once.
        async let publicTask = fetchPublicCatalog()
        let games = try await browseCatalog(token: token, vpcId: vpcId, filters: [:], maxPages: 15)
        let publicGames = await (try? publicTask) ?? []
        return mergeCatalog(games, supplemental: publicGames)
    }

    // MARK: Fetch Library (owned/purchased games via browse filter)

    func fetchLibrary(token: String, streamingBaseUrl: String = NVIDIAAuth.defaultStreamingUrl, vpcId: String? = nil) async throws -> [GameInfo] {
        let vpcId = await resolveVpcId(vpcId, token: token, baseUrl: streamingBaseUrl)
        let libraryFilter: [String: Any] = ["variants": ["gfn": ["library": ["status": ["notEquals": "NOT_OWNED"]]]]]
        let games = try await browseCatalog(token: token, vpcId: vpcId, filters: libraryFilter, maxPages: 10)
        return await (try? enrich(token: token, vpcId: vpcId, games: games)) ?? games
    }

    /// Callers that load catalog, library, and subscription together fetch the vpcId
    /// once and pass it in; standalone calls fall back to fetching it here.
    private func resolveVpcId(_ provided: String?, token: String, baseUrl: String) async -> String {
        if let provided, !provided.isEmpty { return provided }
        return await (try? fetchVpcId(token: token, baseUrl: baseUrl)) ?? "GFN-PC"
    }

    // MARK: - Catalog Browse

    /// Cursor pagination is inherently serial (each page needs the previous cursor),
    /// so page count dominates load time. Large pages cut the round trips; the
    /// long-proven 200-item retry runs only when the oversized page is plausibly
    /// the cause: a client-error HTTP status (except auth) or an empty result —
    /// a GraphQL-level rejection arrives as HTTP 200 with no data. Auth, network,
    /// and server failures propagate immediately instead of doubling the requests.
    private func browseCatalog(token: String, vpcId: String, filters: [String: Any], searchString: String? = nil, maxPages: Int = 3) async throws -> [GameInfo] {
        do {
            let games = try await browsePages(
                token: token, vpcId: vpcId, filters: filters, searchString: searchString,
                pageSize: 500, maxPages: maxPages
            )
            if !games.isEmpty { return games }
        } catch let GamesError.httpStatus(code, _) where (400 ..< 500).contains(code) && code != 403 {
            // Fall through to the 200-item retry.
        }
        return try await browsePages(
            token: token, vpcId: vpcId, filters: filters, searchString: searchString,
            pageSize: 200, maxPages: maxPages
        )
    }

    private func browsePages(token: String, vpcId: String, filters: [String: Any], searchString: String?, pageSize: Int, maxPages: Int) async throws -> [GameInfo] {
        var allGames: [GameInfo] = []
        var seen = Set<String>()
        var cursor = ""

        for _ in 0 ..< maxPages {
            var variables: [String: Any] = [
                "vpcId": vpcId,
                "locale": localeCode,
                "sortString": "sortName:ASC",
                "fetchCount": pageSize,
                "cursor": cursor,
                "filters": filters,
            ]
            let query: String
            if let search = searchString, !search.isEmpty {
                variables["searchString"] = search
                variables["sortString"] = "itemMetadata.relevance:DESC,sortName:ASC"
                query = GamesClient.searchQuery
            } else {
                query = GamesClient.browseQuery
            }

            let body: [String: Any] = ["query": query, "variables": variables]
            let bodyData = try JSONSerialization.data(withJSONObject: body)

            var request = URLRequest(url: URL(string: GamesClient.graphqlURL)!)
            request.httpMethod = "POST"
            setGFNHeaders(on: &request, token: token)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData

            let (data, response) = try await urlSession.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                if statusCode == 401 { throw GamesError.unauthorized }
                throw GamesError.httpStatus(statusCode, String(data: data, encoding: .utf8) ?? "")
            }

            let payload = try JSONDecoder().decode(BrowseResponse.self, from: data)
            guard let apps = payload.data?.apps else { break }

            for item in apps.items ?? [] {
                if let game = browseItemToGame(item), seen.insert(game.id).inserted {
                    allGames.append(game)
                }
            }

            guard apps.pageInfo?.hasNextPage == true,
                  let next = apps.pageInfo?.endCursor, !next.isEmpty else { break }
            cursor = next
        }

        gamesLog.debug("[GamesClient] browseCatalog: \(allGames.count, privacy: .public) games fetched")
        return allGames
    }

    private func browseItemToGame(_ item: BrowseResponse.BrowseApps.BrowseApp) -> GameInfo? {
        guard let rawId = item.id else { return nil }
        let id = rawId.stringValue

        var variants: [GameVariant] = item.variants?.compactMap { v in
            guard let vid = v.id else { return nil }
            return GameVariant(
                id: vid,
                appStore: v.appStore ?? "unknown",
                appId: isNumericId(vid) ? vid : nil,
                isOwned: v.gfn?.library?.isOwned == true
            )
        } ?? []

        let selectedIndex = item.variants?.firstIndex { $0.gfn?.library?.selected == true }
            ?? item.variants?.firstIndex { $0.gfn?.library?.isOwned == true }
            ?? 0
        let safeIndex = min(max(0, selectedIndex), max(0, variants.count - 1))
        if safeIndex > 0, safeIndex < variants.count {
            let selected = variants.remove(at: safeIndex)
            variants.insert(selected, at: 0)
        }

        return GameInfo(
            id: id,
            title: item.title ?? id,
            boxArtUrl: item.images?.GAME_BOX_ART.flatMap { optimizeImageUrl($0) },
            heroBannerUrl: (item.images?.TV_BANNER ?? item.images?.HERO_IMAGE).flatMap { optimizeImageUrl($0, width: 1920) },
            heroImageUrl: (item.images?.HERO_IMAGE ?? item.images?.TV_BANNER).flatMap { optimizeImageUrl($0, width: 1920) },
            supportedFeatures: Self.deriveFeatures(from: item.variants),
            isInLibrary: item.variants?.contains { $0.gfn?.library?.isOwned == true } ?? false,
            variants: variants
        )
    }

    /// Maps GFN's per-variant feature flags to the badge features, unioned across variants.
    /// HDR is signalled either by HDR_ENABLED or a non-empty SUPPORTED_HDR_VERSION list.
    private static func deriveFeatures(from variants: [BrowseResponse.BrowseApps.BrowseApp.Variant]?) -> [GameFeature] {
        guard let variants else { return [] }
        var found = Set<GameFeature>()
        for variant in variants {
            for flag in variant.gfn?.features ?? [] {
                switch flag.key {
                case "RTX_ENABLED": if flag.value == "true" { found.insert(.rtx) }
                case "HDR_ENABLED": if flag.value == "true" { found.insert(.hdr) }
                case "SUPPORTED_HDR_VERSION": if !(flag.values ?? []).isEmpty { found.insert(.hdr) }
                case "REFLEX_ENABLED": if flag.value == "true" { found.insert(.reflex) }
                default: break
                }
            }
        }
        return GameFeature.allCases.filter { found.contains($0) }
    }

    // MARK: - Public Catalog Fallback

    private func fetchPublicCatalog() async throws -> [GameInfo] {
        let publicCatalogURL = "https://static.nvidiagrid.net/supported-public-game-list/locales/gfnpc-\(L10n.keyboardLayoutCode()).json"
        guard let url = URL(string: publicCatalogURL) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(NVIDIAAuth.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await urlSession.data(for: request)
        try validateHTTPResponse(response, data: data)
        let root = try JSONSerialization.jsonObject(with: data)
        return publicCatalogEntries(in: root).compactMap { publicCatalogGame(from: $0) }
    }

    private func mergeCatalog(_ primary: [GameInfo], supplemental: [GameInfo]) -> [GameInfo] {
        var games = primary
        var indexByTitle: [String: Int] = [:]
        var seenIds = Set(primary.map(\.id))
        for (index, game) in games.enumerated() {
            indexByTitle[normalizedTitle(game.title)] = index
        }

        for game in supplemental {
            let titleKey = normalizedTitle(game.title)
            if let index = indexByTitle[titleKey] {
                var existing = games[index]
                var variantIds = Set(existing.variants.map(\.id))
                for variant in game.variants where variantIds.insert(variant.id).inserted {
                    existing.variants.append(variant)
                }
                games[index] = existing
            } else if seenIds.insert(game.id).inserted {
                indexByTitle[titleKey] = games.count
                games.append(game)
            }
        }
        return games
    }

    private func publicCatalogEntries(in value: Any) -> [[String: Any]] {
        if let entries = value as? [[String: Any]] {
            return entries
        }
        guard let dict = value as? [String: Any] else { return [] }
        for key in ["data", "items", "apps", "games"] {
            if let entries = dict[key] as? [[String: Any]] {
                return entries
            }
            if let nested = dict[key] as? [String: Any] {
                let entries = nested.values.compactMap { $0 as? [String: Any] }
                if !entries.isEmpty { return entries }
            }
        }
        let entries = dict.values.compactMap { $0 as? [String: Any] }
        return entries.isEmpty ? [] : entries
    }

    private func publicCatalogGame(from entry: [String: Any]) -> GameInfo? {
        guard (stringValue(entry["status"]) ?? "").uppercased() == "AVAILABLE" else { return nil }
        guard let title = stringValue(entry["title"])
            ?? stringValue(entry["name"])
            ?? stringValue(entry["appName"])
        else {
            return nil
        }
        let id = stringValue(entry["id"])
            ?? stringValue(entry["appId"])
            ?? stringValue(entry["cmsId"])
            ?? normalizedTitle(title)
        let boxArt = stringValue(entry["boxArtUrl"])
            ?? stringValue(entry["boxArt"])
            ?? stringValue(entry["imageUrl"])
        let hero = stringValue(entry["heroBannerUrl"])
            ?? stringValue(entry["heroImage"])
            ?? stringValue(entry["tvBanner"])
        let heroImage = stringValue(entry["heroImageUrl"])
            ?? stringValue(entry["heroImage"])
            ?? hero
        let variants = publicCatalogVariants(in: entry, fallbackId: id)
        guard !variants.isEmpty else { return nil }
        return GameInfo(
            id: id,
            title: title,
            boxArtUrl: boxArt.flatMap { optimizeImageUrl($0) },
            heroBannerUrl: hero.flatMap { optimizeImageUrl($0, width: 1920) },
            heroImageUrl: heroImage.flatMap { optimizeImageUrl($0, width: 1920) },
            supportedFeatures: nil,
            isInLibrary: false,
            variants: variants
        )
    }

    private func publicCatalogVariants(in entry: [String: Any], fallbackId: String) -> [GameVariant] {
        if let rawVariants = entry["variants"] as? [[String: Any]] {
            let variants = rawVariants.compactMap { variant -> GameVariant? in
                if let status = stringValue(variant["status"]), status.uppercased() != "AVAILABLE" {
                    return nil
                }
                let id = stringValue(variant["id"])
                    ?? stringValue(variant["appId"])
                    ?? stringValue(variant["cmsId"])
                guard let id else { return nil }
                let store = stringValue(variant["appStore"])
                    ?? stringValue(variant["store"])
                    ?? stringValue(variant["launcher"])
                    ?? "GFN"
                return GameVariant(id: id, appStore: store, appId: isNumericId(id) ? id : nil)
            }
            if !variants.isEmpty { return variants }
        }

        let id = stringValue(entry["appId"])
            ?? stringValue(entry["launchId"])
            ?? stringValue(entry["id"])
            ?? fallbackId
        let store = stringValue(entry["appStore"])
            ?? stringValue(entry["store"])
            ?? stringValue(entry["launcher"])
            ?? "GFN"
        return [GameVariant(id: id, appStore: store, appId: isNumericId(id) ? id : nil)]
    }

    // MARK: - Metadata Enrichment

    private func enrich(token: String, vpcId: String, games: [GameInfo]) async throws -> [GameInfo] {
        let ids = Array(Set(games.map(\.id)))
        guard !ids.isEmpty else { return games }

        var metaById: [String: AppData] = [:]
        let chunkSize = 40

        for start in stride(from: 0, to: ids.count, by: chunkSize) {
            let chunk = Array(ids[start ..< min(start + chunkSize, ids.count)])
            let payload = try await fetchMetadata(token: token, appIds: chunk, vpcId: vpcId)
            for app in payload {
                guard let rawId = app.id else { continue }
                metaById[rawId.stringValue] = app
            }
        }

        return games.map { game in
            guard let meta = metaById[game.id] else { return game }
            let boxArt = meta.images?.GAME_BOX_ART.flatMap { optimizeImageUrl($0) }
            let hero = (meta.images?.TV_BANNER ?? meta.images?.HERO_IMAGE).flatMap { optimizeImageUrl($0, width: 1920) }
            let heroImage = (meta.images?.HERO_IMAGE ?? meta.images?.TV_BANNER).flatMap { optimizeImageUrl($0, width: 1920) }
            return GameInfo(
                id: game.id,
                title: meta.title ?? game.title,
                boxArtUrl: boxArt ?? game.boxArtUrl,
                heroBannerUrl: hero ?? game.heroBannerUrl,
                heroImageUrl: heroImage ?? game.heroImageUrl,
                supportedFeatures: game.supportedFeatures,
                isInLibrary: game.isInLibrary,
                variants: game.variants
            )
        }
    }

    private func fetchMetadata(token: String, appIds: [String], vpcId: String) async throws -> [AppData] {
        guard !appIds.isEmpty else { return [] }

        var apps: [AppData] = []
        let chunkSize = 40
        for start in stride(from: 0, to: appIds.count, by: chunkSize) {
            let chunk = Array(appIds[start ..< min(start + chunkSize, appIds.count)])
            let payloadApps = try await fetchMetadataChunk(token: token, appIds: chunk, vpcId: vpcId)
            cacheMetadata(payloadApps)
            apps.append(contentsOf: payloadApps)
        }
        return apps
    }

    private func fetchMetadataBestEffort(token: String, appIds: [String], vpcId: String) async throws -> MetadataFetchResult {
        guard !appIds.isEmpty else { return MetadataFetchResult(failedChunkCount: 0) }

        var failedChunkCount = 0
        let chunkSize = 40
        for start in stride(from: 0, to: appIds.count, by: chunkSize) {
            let chunk = Array(appIds[start ..< min(start + chunkSize, appIds.count)])
            do {
                let payloadApps = try await fetchMetadataChunk(token: token, appIds: chunk, vpcId: vpcId)
                cacheMetadata(payloadApps)
            } catch is CancellationError {
                throw CancellationError()
            } catch GamesError.unauthorized {
                throw GamesError.unauthorized
            } catch {
                failedChunkCount += 1
                gamesLog.warning("[Games] metadata chunk failed for \(chunk.count, privacy: .public) apps: \(error, privacy: .private)")
            }
        }
        return MetadataFetchResult(failedChunkCount: failedChunkCount)
    }

    private func fetchMetadataChunk(token: String, appIds: [String], vpcId: String) async throws -> [AppData] {
        let variables: [String: Any] = ["vpcId": vpcId, "locale": localeCode, "appIds": appIds]
        let extensions: [String: Any] = ["persistedQuery": ["sha256Hash": GamesClient.metadataQueryHash]]
        let huId = "\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 16))\(String(Int.random(in: 0 ..< Int.max), radix: 16))"

        var comps = URLComponents(string: GamesClient.graphqlURL)!
        comps.queryItems = [
            URLQueryItem(name: "requestType", value: "appMetaData"),
            URLQueryItem(name: "extensions", value: jsonString(extensions)),
            URLQueryItem(name: "huId", value: huId),
            URLQueryItem(name: "variables", value: jsonString(variables)),
        ]
        var request = URLRequest(url: comps.url!)
        setGFNHeaders(on: &request, token: token)

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTPResponse(response, data: data)
        let payload = try JSONDecoder().decode(MetadataResponse.self, from: data)
        try validateGraphQL(errors: payload.errors)
        guard let apps = payload.data?.apps.items else {
            throw GamesError.fetchFailed("GraphQL response did not contain app metadata")
        }
        return apps
    }

    private func cacheMetadata(_ apps: [AppData]) {
        for app in apps {
            guard let id = app.id?.stringValue else { continue }
            metadataCache[id] = app
        }
    }

    // MARK: - Owned Apps

    private func fetchOwnedApps(token: String, vpcId: String) async throws -> [AppData] {
        var cursor = ""
        var apps: [AppData] = []
        var seenCursors = Set<String>()
        var expectedTotalCount: Int?

        while true {
            let page = try await fetchOwnedAppsPage(token: token, vpcId: vpcId, cursor: cursor)
            apps.append(contentsOf: page.items)

            if let totalCount = page.pageInfo.totalCount {
                guard totalCount >= 0 else {
                    throw GamesError.pagination("Owned-app total count was negative")
                }
                if let expectedTotalCount, expectedTotalCount != totalCount {
                    throw GamesError.pagination("Owned-app total count changed between pages")
                }
                expectedTotalCount = totalCount
            }

            guard let hasNextPage = page.pageInfo.hasNextPage else {
                throw GamesError.pagination("Owned-app response omitted hasNextPage")
            }
            guard hasNextPage else {
                break
            }

            guard let nextCursor = page.pageInfo.endCursor, !nextCursor.isEmpty else {
                throw GamesError.pagination("Owned-app response indicated another page without a cursor")
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw GamesError.pagination("Owned-app pagination repeated cursor \(nextCursor)")
            }
            cursor = nextCursor
        }

        var seenIds = Set<String>()
        let uniqueApps = apps.filter { app in
            guard let id = app.id?.stringValue else { return false }
            return seenIds.insert(id).inserted
        }
        if let expectedTotalCount, uniqueApps.count != expectedTotalCount {
            throw GamesError.pagination(
                "Owned-app response returned \(uniqueApps.count) unique apps, expected \(expectedTotalCount)"
            )
        }
        return uniqueApps
    }

    private func fetchOwnedAppsPage(token: String, vpcId: String, cursor: String) async throws -> AppsContainer {
        let variables: [String: Any] = [
            "vpcId": vpcId,
            "locale": localeCode,
            "fetchCount": 749,
            "cursor": cursor,
            "filters": [
                "variants": [
                    "gfn": [
                        "library": [
                            "status": ["notEquals": "NOT_OWNED"],
                        ],
                    ],
                ],
            ],
        ]
        let extensions: [String: Any] = ["persistedQuery": ["sha256Hash": GamesClient.ownedAppsQueryHash]]
        let huId = "\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 16))\(String(Int.random(in: 0 ..< Int.max), radix: 16))"

        var comps = URLComponents(string: GamesClient.graphqlURL)!
        comps.queryItems = [
            URLQueryItem(name: "requestType", value: "appsPatchInfoWithLibraryFilter"),
            URLQueryItem(name: "extensions", value: jsonString(extensions)),
            URLQueryItem(name: "huId", value: huId),
            URLQueryItem(name: "variables", value: jsonString(variables)),
        ]
        var request = URLRequest(url: comps.url!)
        setGFNHeaders(on: &request, token: token)

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTPResponse(response, data: data)
        let payload = try JSONDecoder().decode(OwnedAppsResponse.self, from: data)
        try validateGraphQL(errors: payload.errors)
        guard let apps = payload.data?.apps else {
            throw GamesError.fetchFailed("GraphQL response did not contain owned apps")
        }
        return apps
    }

    // MARK: - VPC ID

    private func fetchVpcId(token: String, baseUrl: String) async throws -> String {
        let base = baseUrl.hasSuffix("/") ? baseUrl : "\(baseUrl)/"
        let url = URL(string: "\(base)v2/serverInfo")!
        var request = URLRequest(url: url)
        setServerInfoHeaders(on: &request, token: token)
        let (data, _) = try await urlSession.data(for: request)
        let payload = try JSONDecoder().decode(ServerInfoResponse.self, from: data)
        return payload.requestStatus?.serverId ?? "GFN-PC"
    }

    // MARK: - Helpers

    private func optimizeImageUrl(_ url: String, width: Int = 272) -> String? {
        guard !url.isEmpty else { return nil }
        if url.contains("img.nvidiagrid.net") {
            return "\(url);f=webp;w=\(width)"
        }
        return url
    }

    private func setGFNHeaders(on request: inout URLRequest, token: String) {
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(NVIDIAAuth.webOrigin, forHTTPHeaderField: "Origin")
        request.setValue(NVIDIAAuth.webReferer, forHTTPHeaderField: "Referer")
        request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(GamesClient.clientId, forHTTPHeaderField: "nv-client-id")
        request.setValue("NATIVE", forHTTPHeaderField: "nv-client-type")
        request.setValue(GamesClient.clientVersion, forHTTPHeaderField: "nv-client-version")
        request.setValue("NVIDIA-CLASSIC", forHTTPHeaderField: "nv-client-streamer")
        request.setValue("WINDOWS", forHTTPHeaderField: "nv-device-os")
        request.setValue("DESKTOP", forHTTPHeaderField: "nv-device-type")
        request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-make")
        request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-model")
        request.setValue("CHROME", forHTTPHeaderField: "nv-browser-type")
        request.setValue(NVIDIAAuth.userAgent, forHTTPHeaderField: "User-Agent")
    }

    private func setServerInfoHeaders(on request: inout URLRequest, token: String) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(NVIDIAAuth.webOrigin, forHTTPHeaderField: "Origin")
        request.setValue(NVIDIAAuth.webReferer, forHTTPHeaderField: "Referer")
        request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(GamesClient.clientId, forHTTPHeaderField: "nv-client-id")
        request.setValue("BROWSER", forHTTPHeaderField: "nv-client-type")
        request.setValue(GamesClient.clientVersion, forHTTPHeaderField: "nv-client-version")
        request.setValue("WEBRTC", forHTTPHeaderField: "nv-client-streamer")
        request.setValue("WINDOWS", forHTTPHeaderField: "nv-device-os")
        request.setValue("DESKTOP", forHTTPHeaderField: "nv-device-type")
        request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-make")
        request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-model")
        request.setValue("CHROME", forHTTPHeaderField: "nv-browser-type")
        request.setValue(NVIDIAAuth.userAgent, forHTTPHeaderField: "User-Agent")
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func normalizedTitle(_ title: String) -> String {
        title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private func isNumericId(_ s: String?) -> Bool {
        guard let s else { return false }
        return s.allSatisfy(\.isNumber) && !s.isEmpty
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    private func validateGraphQL(errors: [GQLError]?) throws {
        guard let errors, !errors.isEmpty else { return }
        throw GamesError.graphql(errors.map(\.message).joined(separator: "; "))
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if statusCode == 401 {
            throw GamesError.unauthorized
        }
        guard statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw GamesError.fetchFailed(body)
        }
    }
}

// MARK: - Response Types

private struct ServerInfoResponse: Decodable {
    let requestStatus: RequestStatus?
    struct RequestStatus: Decodable { let serverId: String? }
}

private struct MetadataResponse: Decodable {
    let data: MetadataData?
    let errors: [GQLError]?
    struct MetadataData: Decodable {
        let apps: AppsContainer
        struct AppsContainer: Decodable {
            let items: [AppData]
        }
    }
}

private struct BrowseResponse: Decodable {
    let data: BrowseData?
    let errors: [GQLError]?

    struct BrowseData: Decodable { let apps: BrowseApps? }
    struct BrowseApps: Decodable {
        let numberReturned: Int?
        let pageInfo: PageInfo?
        let items: [BrowseApp]?

        struct PageInfo: Decodable {
            let hasNextPage: Bool?
            let endCursor: String?
            let totalCount: Int?
        }

        struct BrowseApp: Decodable {
            let id: AnyCodableGameId?
            let title: String?
            let images: Images?
            let variants: [Variant]?

            struct Images: Decodable {
                let GAME_BOX_ART: String?
                let TV_BANNER: String?
                let HERO_IMAGE: String?
            }

            struct Variant: Decodable {
                let id: String?
                let appStore: String?
                let gfn: GFNMeta?
                struct GFNMeta: Decodable {
                    let library: LibraryMeta?
                    let features: [FeatureFlag]?
                    /// A GfnSubscriptionFeature union member: `key` on the interface, `value` on
                    /// GfnSubscriptionFeatureValue, `values` on GfnSubscriptionFeatureValueList.
                    struct FeatureFlag: Decodable {
                        let key: String?
                        let value: String?
                        let values: [String]?
                    }

                    struct LibraryMeta: Decodable {
                        let status: String?
                        let selected: Bool?

                        var isOwned: Bool {
                            guard let status else { return false }
                            let ownedStatuses = ["MANUAL", "PLATFORM_SYNC", "IN_LIBRARY"]
                            return ownedStatuses.contains(status.uppercased())
                        }
                    }
                }
            }
        }
    }
}

private struct GQLError: Decodable { let message: String }

private struct MetadataFetchResult {
    let failedChunkCount: Int
}

private struct OwnedAppsResponse: Decodable {
    let data: OwnedAppsData?
    let errors: [GQLError]?
    struct OwnedAppsData: Decodable {
        let apps: AppsContainer
    }
}

private struct AppsContainer: Decodable {
    let items: [AppData]
    let pageInfo: PageInfo
}

private struct PageInfo: Decodable {
    let hasNextPage: Bool?
    let endCursor: String?
    let totalCount: Int?

    init(hasNextPage: Bool? = nil, endCursor: String? = nil, totalCount: Int? = nil) {
        self.hasNextPage = hasNextPage
        self.endCursor = endCursor
        self.totalCount = totalCount
    }
}

private struct AppData: Decodable {
    let id: AnyCodableGameId?
    let title: String?
    let images: Images?
    let variants: [Variant]?

    struct Images: Decodable {
        let GAME_BOX_ART: String?
        let TV_BANNER: String?
        let HERO_IMAGE: String?
    }

    struct Variant: Decodable {
        let id: String?
        let appStore: String?
        let gfn: GFNMeta?
        struct GFNMeta: Decodable {
            let library: LibraryMeta?
            struct LibraryMeta: Decodable {
                let status: String?
                let selected: Bool?

                var isOwned: Bool {
                    guard let status else { return false }
                    let ownedStatuses = ["MANUAL", "PLATFORM_SYNC", "IN_LIBRARY"]
                    return ownedStatuses.contains(status.uppercased())
                }
            }
        }
    }
}

private struct AnyCodableGameId: Decodable {
    let stringValue: String
    init(from decoder: Decoder) throws {
        if let int = try? Int(from: decoder) {
            stringValue = String(int)
        } else {
            stringValue = try String(from: decoder)
        }
    }
}

// MARK: - Errors

enum GamesError: Error, LocalizedError {
    case fetchFailed(String)
    case httpStatus(Int, String)
    case graphql(String)
    case pagination(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case let .fetchFailed(message): "Games fetch failed: \(message)"
        case let .httpStatus(code, message): "Games fetch failed: HTTP \(code): \(message)"
        case let .graphql(message): "Games GraphQL error: \(message)"
        case let .pagination(message): "Games pagination failed: \(message)"
        case .unauthorized: "Games authentication was rejected."
        }
    }
}
