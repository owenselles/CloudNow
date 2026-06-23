import Foundation

struct LibraryFetchResult {
    let games: [GameInfo]
    let warning: String?
}

// MARK: - GamesClient

/// Fetches the GFN game library via the GraphQL persisted-query API.
actor GamesClient {
    private static let graphqlURL = "https://games.geforce.com/graphql"
    private static let panelsQueryHash = "46ec15f267a056e7d5e46e629efa929529e5e7542a4850faece90b9f8fa5f810"
    private static let metadataQueryHash = "cf8b620dfd03617017ba7c858cee65197e1ace5180e41be194b39227227ced63"
    private static let ownedAppsQueryHash = "698bbc7e16a17c8e3fc56944a0e6d62e7d70296b29dfb35fb4d83ebd66dd10f1"
    private static let clientId = "ec7e38d4-03af-4b58-b131-cfb0495903ab"
    private static let clientVersion = "2.0.80.173"

    private let urlSession = URLSession.shared
    private var metadataCache: [String: AppData] = [:]

    // MARK: Fetch Main Game List

    func fetchMainGames(token: String, streamingBaseUrl: String = NVIDIAAuth.defaultStreamingUrl) async throws -> [GameInfo] {
        let vpcId = await (try? fetchVpcId(token: token, baseUrl: streamingBaseUrl)) ?? "GFN-PC"
        var games = try await fetchPanels(token: token, panelNames: ["MAIN"], vpcId: vpcId)
        games = await (try? enrich(token: token, vpcId: vpcId, games: games)) ?? games
        return games
    }

    // MARK: Fetch Library (owned/purchased games)

    func fetchLibrary(token: String, streamingBaseUrl: String = NVIDIAAuth.defaultStreamingUrl) async throws -> LibraryFetchResult {
        let vpcId = await (try? fetchVpcId(token: token, baseUrl: streamingBaseUrl)) ?? "GFN-PC"
        let ownedApps = try await fetchOwnedApps(token: token, vpcId: vpcId)
        let ownedIds = ownedApps.compactMap { $0.id?.stringValue }
        let metadataResult = try await fetchMetadataBestEffort(token: token, appIds: ownedIds, vpcId: vpcId)

        let games: [GameInfo] = ownedApps.compactMap { ownedApp -> GameInfo? in
            guard let id = ownedApp.id?.stringValue else { return nil }
            let ownedVariantIds = Set(
                ownedApp.variants?.compactMap { variant in
                    variant.gfn?.library?.isOwned == true ? variant.id : nil
                } ?? []
            )
            return appToGame(
                metadataCache[id] ?? ownedApp,
                ownedVariantIds: ownedVariantIds,
                fallbackVariants: ownedApp.variants ?? []
            )
        }

        let warning = metadataResult.failedChunkCount > 0
            ? "Some game details could not be refreshed. All owned games are shown with the metadata currently available."
            : nil
        return LibraryFetchResult(games: games, warning: warning)
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
                print("[Games] metadata chunk failed for \(chunk.count) apps: \(error)")
            }
        }
        return MetadataFetchResult(failedChunkCount: failedChunkCount)
    }

    private func fetchMetadataChunk(token: String, appIds: [String], vpcId: String) async throws -> [AppData] {
        let variables: [String: Any] = ["vpcId": vpcId, "locale": "en_US", "appIds": appIds]
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
            "locale": "en_US",
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

    // MARK: - Panels

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

    private func fetchPanels(token: String, panelNames: [String], vpcId: String) async throws -> [GameInfo] {
        let variables: [String: Any] = ["vpcId": vpcId, "locale": "en_US", "panelNames": panelNames]
        let extensions: [String: Any] = ["persistedQuery": ["sha256Hash": GamesClient.panelsQueryHash]]
        let requestType = panelNames.contains("LIBRARY") ? "panels/Library" : "panels/MainV2"
        let huId = "\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 16))\(String(Int.random(in: 0 ..< Int.max), radix: 16))"

        var comps = URLComponents(string: GamesClient.graphqlURL)!
        comps.queryItems = [
            URLQueryItem(name: "requestType", value: requestType),
            URLQueryItem(name: "extensions", value: jsonString(extensions)),
            URLQueryItem(name: "huId", value: huId),
            URLQueryItem(name: "variables", value: jsonString(variables)),
        ]
        var request = URLRequest(url: comps.url!)
        setGFNHeaders(on: &request, token: token)

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTPResponse(response, data: data)
        let payload = try JSONDecoder().decode(PanelsResponse.self, from: data)
        try validateGraphQL(errors: payload.errors)
        guard payload.data != nil else {
            throw GamesError.fetchFailed("GraphQL response did not contain panels")
        }
        return flattenPanels(payload)
    }

    private func flattenPanels(_ payload: PanelsResponse) -> [GameInfo] {
        var games: [GameInfo] = []
        var seen = Set<String>()
        for panel in payload.data?.panels ?? [] {
            for section in panel.sections ?? [] {
                for item in section.items ?? [] {
                    guard item.__typename == "GameItem", let app = item.app else { continue }
                    if let id = app.id?.stringValue, metadataCache[id] == nil {
                        metadataCache[id] = app
                    }
                    if let game = appToGame(app), seen.insert(game.id).inserted {
                        games.append(game)
                    }
                }
            }
        }
        return games
    }

    private func appToGame(
        _ app: AppData,
        ownedVariantIds: Set<String> = [],
        fallbackVariants: [AppData.Variant] = []
    ) -> GameInfo? {
        guard let rawId = app.id else { return nil }
        let id = rawId.stringValue
        var variantSources = app.variants ?? []
        var knownVariantIds = Set(variantSources.compactMap(\.id))
        variantSources.append(contentsOf: fallbackVariants.filter { variant in
            guard let id = variant.id else { return false }
            return knownVariantIds.insert(id).inserted
        })

        var variants: [GameVariant] = variantSources.compactMap { v in
            guard let vid = v.id else { return nil }
            return GameVariant(
                id: vid,
                appStore: v.appStore ?? "unknown",
                appId: isNumericId(vid) ? vid : nil,
                isOwned: v.gfn?.library?.isOwned == true || ownedVariantIds.contains(vid)
            )
        }

        // Move the backend-selected variant to front so variants.first is the default launch store
        let selectedVariantId = variantSources.first { $0.gfn?.library?.selected == true }?.id
        if let selectedVariantId,
           let selectedIndex = variants.firstIndex(where: { $0.id == selectedVariantId }),
           selectedIndex > 0
        {
            let selected = variants.remove(at: selectedIndex)
            variants.insert(selected, at: 0)
        }

        return GameInfo(
            id: id,
            title: app.title ?? id,
            boxArtUrl: app.images?.GAME_BOX_ART.flatMap { optimizeImageUrl($0) },
            heroBannerUrl: (app.images?.TV_BANNER ?? app.images?.HERO_IMAGE).flatMap { optimizeImageUrl($0, width: 1920) },
            isInLibrary: variants.contains { $0.isOwned },
            variants: variants
        )
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
        request.setValue("application/graphql", forHTTPHeaderField: "Content-Type")
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

private struct PanelsResponse: Decodable {
    let data: PanelsData?
    let errors: [GQLError]?
    struct PanelsData: Decodable {
        let panels: [Panel]?
        struct Panel: Decodable {
            let name: String?
            let sections: [Section]?
            struct Section: Decodable {
                let items: [Item]?
                struct Item: Decodable {
                    let __typename: String
                    let app: AppData?
                }
            }
        }
    }
}

private struct GQLError: Decodable { let message: String }

private struct MetadataFetchResult {
    let failedChunkCount: Int
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
                    return status.caseInsensitiveCompare("NOT_OWNED") != .orderedSame
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
    case graphql(String)
    case pagination(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case let .fetchFailed(message): "Games fetch failed: \(message)"
        case let .graphql(message): "Games GraphQL error: \(message)"
        case let .pagination(message): "Games pagination failed: \(message)"
        case .unauthorized: "Games authentication was rejected."
        }
    }
}
