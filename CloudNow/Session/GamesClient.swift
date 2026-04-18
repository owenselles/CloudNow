import Foundation

// MARK: - GamesClient

/// Fetches the GFN game library via the GraphQL persisted-query API.
actor GamesClient {
    private static let graphqlURL = "https://games.geforce.com/graphql"
    private static let panelsQueryHash = "f8e26265a5db5c20e1334a6872cf04b6e3970507697f6ae55a6ddefa5420daf0"
    private static let metadataQueryHash = "39187e85b6dcf60b7279a5f233288b0a8b69a8b1dbcfb5b25555afdcb988f0d7"
    private static let clientId = "ec7e38d4-03af-4b58-b131-cfb0495903ab"
    private static let clientVersion = "2.0.80.173"

    private let urlSession = URLSession.shared

    // MARK: Fetch Main Game List

    func fetchMainGames(token: String, streamingBaseUrl: String = NVIDIAAuth.defaultStreamingUrl) async throws -> [GameInfo] {
        let vpcId = (try? await fetchVpcId(token: token, baseUrl: streamingBaseUrl)) ?? "GFN-PC"
        var games = try await fetchPanels(token: token, panelNames: ["MAIN"], vpcId: vpcId)
        games = (try? await enrich(token: token, vpcId: vpcId, games: games)) ?? games
        return games
    }

    // MARK: Fetch Library (owned/purchased games)

    func fetchLibrary(token: String, streamingBaseUrl: String = NVIDIAAuth.defaultStreamingUrl) async throws -> [GameInfo] {
        let vpcId = (try? await fetchVpcId(token: token, baseUrl: streamingBaseUrl)) ?? "GFN-PC"
        var games = try await fetchPanels(token: token, panelNames: ["LIBRARY"], vpcId: vpcId)
        games = (try? await enrich(token: token, vpcId: vpcId, games: games)) ?? games
        return games
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
        let huId = "\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 16))\(String(Int.random(in: 0..<Int.max), radix: 16))"

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
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GamesError.fetchFailed(String(data: data, encoding: .utf8) ?? "")
        }
        let payload = try JSONDecoder().decode(PanelsResponse.self, from: data)
        return flattenPanels(payload)
    }

    private func flattenPanels(_ payload: PanelsResponse) -> [GameInfo] {
        var games: [GameInfo] = []
        for panel in payload.data?.panels ?? [] {
            for section in panel.sections ?? [] {
                for item in section.items ?? [] {
                    guard item.__typename == "GameItem", let app = item.app else { continue }
                    if let game = appToGame(app) { games.append(game) }
                }
            }
        }
        return games
    }

    private func appToGame(_ app: AppData) -> GameInfo? {
        guard let rawId = app.id else { return nil }
        let id = rawId.stringValue
        let variants: [GameVariant] = app.variants?.compactMap { v in
            guard let vid = v.id else { return nil }
            return GameVariant(id: vid, appStore: v.appStore ?? "unknown", appId: isNumericId(vid) ? vid : nil)
        } ?? []

        let selectedIndex = app.variants?.firstIndex { $0.gfn?.library?.selected == true } ?? 0
        let safeIndex = max(0, selectedIndex)
        let launchVariant = variants.indices.contains(safeIndex) ? variants[safeIndex] : variants.first
        let appId = launchVariant?.appId ?? variants.first { isNumericId($0.appStore) }?.id

        return GameInfo(
            id: id,
            title: app.title ?? id,
            boxArtUrl: app.images?.GAME_BOX_ART.flatMap { optimizeImageUrl($0) },
            heroBannerUrl: (app.images?.TV_BANNER ?? app.images?.HERO_IMAGE).flatMap { optimizeImageUrl($0, width: 1920) },
            isInLibrary: app.variants?.contains { $0.gfn?.library?.selected == true } ?? false,
            variants: variants.map {
                GameVariant(id: $0.id, appStore: $0.appStore, appId: appId)
            }
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
