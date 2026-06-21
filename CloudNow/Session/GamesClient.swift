import Foundation

// MARK: - GamesClient

/// Fetches the GFN game catalog via the GraphQL browse API and persisted-query metadata enrichment.
actor GamesClient {
    private static let graphqlURL = "https://games.geforce.com/graphql"
    private static let metadataQueryHash = "cf8b620dfd03617017ba7c858cee65197e1ace5180e41be194b39227227ced63"
    private static let clientId = "ec7e38d4-03af-4b58-b131-cfb0495903ab"
    private static let clientVersion = "2.0.80.173"

    private let urlSession = URLSession.shared

    private static let browseQuery = """
        query GetFilterBrowseResults($vpcId: String!, $locale: String!, $sortString: String!, $fetchCount: Int!, $cursor: String!, $filters: AppFilterFields!) {
            apps(vpcId: $vpcId, language: $locale, orderBy: $sortString, first: $fetchCount, after: $cursor, filters: $filters) {
                numberReturned pageInfo { hasNextPage endCursor totalCount }
                items {
                    id title
                    images { GAME_BOX_ART TV_BANNER HERO_IMAGE }
                    variants { id appStore supportedControls gfn { status library { status selected } } }
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
                    variants { id appStore supportedControls gfn { status library { status selected } } }
                    gfn { playabilityState minimumMembershipTierLabel }
                }
            }
        }
        """

    // MARK: Fetch Full Catalog (browse API)

    func fetchMainGames(token: String, streamingBaseUrl: String = NVIDIAAuth.defaultStreamingUrl) async throws -> [GameInfo] {
        let vpcId = (try? await fetchVpcId(token: token, baseUrl: streamingBaseUrl)) ?? "GFN-PC"
        return try await browseCatalog(token: token, vpcId: vpcId, filters: [:], maxPages: 15)
    }

    // MARK: Fetch Library (owned/purchased games via browse filter)

    func fetchLibrary(token: String, streamingBaseUrl: String = NVIDIAAuth.defaultStreamingUrl) async throws -> [GameInfo] {
        let vpcId = (try? await fetchVpcId(token: token, baseUrl: streamingBaseUrl)) ?? "GFN-PC"
        let libraryFilter: [String: Any] = ["variants": ["gfn": ["library": ["status": ["notEquals": "NOT_OWNED"]]]]]
        let games = try await browseCatalog(token: token, vpcId: vpcId, filters: libraryFilter, maxPages: 10)
        return (try? await enrich(token: token, vpcId: vpcId, games: games)) ?? games
    }

    // MARK: - Catalog Browse

    private func browseCatalog(token: String, vpcId: String, filters: [String: Any], searchString: String? = nil, maxPages: Int = 3) async throws -> [GameInfo] {
        var allGames: [GameInfo] = []
        var seen = Set<String>()
        var cursor = ""

        for _ in 0..<maxPages {
            var variables: [String: Any] = [
                "vpcId": vpcId,
                "locale": "en_US",
                "sortString": "sortName:ASC",
                "fetchCount": 200,
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
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw GamesError.fetchFailed(String(data: data, encoding: .utf8) ?? "")
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

        print("[GamesClient] browseCatalog: \(allGames.count) games fetched")
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
                isOwned: v.gfn?.library?.selected == true
            )
        } ?? []

        let selectedIndex = item.variants?.firstIndex { $0.gfn?.library?.selected == true } ?? 0
        let safeIndex = min(max(0, selectedIndex), max(0, variants.count - 1))
        if safeIndex > 0 && safeIndex < variants.count {
            let selected = variants.remove(at: safeIndex)
            variants.insert(selected, at: 0)
        }

        return GameInfo(
            id: id,
            title: item.title ?? id,
            boxArtUrl: item.images?.GAME_BOX_ART.flatMap { optimizeImageUrl($0) },
            heroBannerUrl: (item.images?.TV_BANNER ?? item.images?.HERO_IMAGE).flatMap { optimizeImageUrl($0, width: 1920) },
            isInLibrary: item.variants?.contains { $0.gfn?.library?.selected == true } ?? false,
            variants: variants
        )
    }

    // MARK: - Metadata Enrichment

    private func enrich(token: String, vpcId: String, games: [GameInfo]) async throws -> [GameInfo] {
        let ids = Array(Set(games.map(\.id)))
        guard !ids.isEmpty else { return games }

        var metaById: [String: AppData] = [:]
        let chunkSize = 40

        for start in stride(from: 0, to: ids.count, by: chunkSize) {
            let chunk = Array(ids[start..<min(start + chunkSize, ids.count)])
            let payload = try await fetchMetadata(token: token, appIds: chunk, vpcId: vpcId)
            for app in payload {
                guard let rawId = app.id else { continue }
                metaById[rawId.stringValue] = app
            }
        }

        return games.map { game in
            guard let meta = metaById[game.id] else { return game }
            let boxArt = meta.images?.GAME_BOX_ART.flatMap { optimizeImageUrl($0) }
            let hero   = (meta.images?.TV_BANNER ?? meta.images?.HERO_IMAGE).flatMap { optimizeImageUrl($0, width: 1920) }
            return GameInfo(
                id: game.id,
                title: meta.title ?? game.title,
                boxArtUrl: boxArt ?? game.boxArtUrl,
                heroBannerUrl: hero ?? game.heroBannerUrl,
                isInLibrary: game.isInLibrary,
                variants: game.variants
            )
        }
    }

    private func fetchMetadata(token: String, appIds: [String], vpcId: String) async throws -> [AppData] {
        let variables: [String: Any] = ["vpcId": vpcId, "locale": "en_US", "appIds": appIds]
        let extensions: [String: Any] = ["persistedQuery": ["sha256Hash": GamesClient.metadataQueryHash]]
        let huId = "\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 16))\(String(Int.random(in: 0..<Int.max), radix: 16))"

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
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GamesError.fetchFailed(String(data: data, encoding: .utf8) ?? "")
        }
        let payload = try JSONDecoder().decode(MetadataResponse.self, from: data)
        return payload.data?.apps.items ?? []
    }

    // MARK: - VPC ID

    private func fetchVpcId(token: String, baseUrl: String) async throws -> String {
        let base = baseUrl.hasSuffix("/") ? baseUrl : "\(baseUrl)/"
        let url = URL(string: "\(base)v2/serverInfo")!
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(NVIDIAAuth.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(GamesClient.clientId, forHTTPHeaderField: "nv-client-id")
        request.setValue("NVIDIA-CLASSIC", forHTTPHeaderField: "nv-client-streamer")
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
        request.setValue("https://play.geforcenow.com", forHTTPHeaderField: "Origin")
        request.setValue("https://play.geforcenow.com/", forHTTPHeaderField: "Referer")
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

    private func isNumericId(_ s: String?) -> Bool {
        guard let s else { return false }
        return s.allSatisfy { $0.isNumber } && !s.isEmpty
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - Response Types

private struct ServerInfoResponse: Decodable {
    let requestStatus: RequestStatus?
    struct RequestStatus: Decodable { let serverId: String? }
}

private struct MetadataResponse: Decodable {
    let data: MetadataData?
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
                    struct LibraryMeta: Decodable { let selected: Bool? }
                }
            }
        }
    }

    struct GQLError: Decodable { let message: String }
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
            struct LibraryMeta: Decodable { let selected: Bool? }
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
    var errorDescription: String? {
        if case .fetchFailed(let msg) = self { return "Games fetch failed: \(msg)" }
        return nil
    }
}
