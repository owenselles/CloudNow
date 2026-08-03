@testable import CloudNow
import Foundation
import Testing

@Suite("Games GraphQL and catalog client")
struct GamesClientTests {
    @Test("Browse request builds headers and variables, derives features, orders selected variant, and merges public catalog")
    func browseAndMerge() async throws {
        let browse = try NetworkingFixture.data("games-browse.json")
        let publicCatalog = try NetworkingFixture.data("games-public.json")
        let transport = RecordingHTTPTransport { request, _ in
            if request.url?.host == "games.geforce.com" {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT fixture-token")
                #expect(request.value(forHTTPHeaderField: "Origin") == NVIDIAAuth.webOrigin)
                let body = try jsonObject(from: request)
                let variables = try #require(body["variables"] as? [String: Any])
                #expect(variables["vpcId"] as? String == "fixture-vpc")
                #expect(variables["fetchCount"] as? Int == 500)
                #expect(variables["cursor"] as? String == "")
                return StubbedHTTPResponse(data: browse)
            }
            if request.url?.host == "static.nvidiagrid.net" {
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                return StubbedHTTPResponse(data: publicCatalog)
            }
            throw TestTransportError.unexpectedRequest(request.url?.absoluteString ?? "(nil)")
        }

        let games = try await GamesClient(transport: transport).fetchMainGames(
            token: "fixture-token",
            vpcId: "fixture-vpc"
        )
        let racer = try #require(games.first { $0.id == "101" })

        #expect(games.map(\.id) == ["101", "fallback-title", "public-only"])
        #expect(racer.variants.map(\.id) == ["201", "202", "303"])
        #expect(racer.variants.first?.isOwned == true)
        #expect(racer.isInLibrary)
        #expect(racer.supportedFeatures == [.rtx, .hdr, .reflex])
        #expect(racer.genres == ["RACING"])
        #expect(games[1].title == "fallback-title")
    }

    @Test("Cursor pagination terminates and deduplicates IDs across pages")
    func paginationAndDeduplication() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            if request.url?.host == "static.nvidiagrid.net" {
                return StubbedHTTPResponse(json: #"{"games":[]}"#)
            }
            let body = try jsonObject(from: request)
            let variables = try #require(body["variables"] as? [String: Any])
            let cursor = variables["cursor"] as? String
            if cursor == "" {
                return StubbedHTTPResponse(json: browsePage(
                    items: [
                        #"{"id":"one","title":"One","images":{},"variants":[]}"#,
                        #"{"id":"duplicate","title":"First copy","images":{},"variants":[]}"#,
                    ],
                    hasNextPage: true,
                    cursor: "next"
                ))
            }
            return StubbedHTTPResponse(json: browsePage(
                items: [
                    #"{"id":"duplicate","title":"Second copy","images":{},"variants":[]}"#,
                    #"{"id":"two","title":"Two","images":{},"variants":[]}"#,
                ],
                hasNextPage: false,
                cursor: ""
            ))
        }

        let games = try await GamesClient(transport: transport).fetchMainGames(
            token: "token",
            vpcId: "vpc"
        )
        let graphQLRequests = await transport.requests().filter { $0.url?.host == "games.geforce.com" }

        #expect(games.map(\.id) == ["one", "duplicate", "two"])
        #expect(games.first { $0.id == "duplicate" }?.title == "First copy")
        #expect(graphQLRequests.count == 2)
    }

    @Test("Oversized browse page retries with 200 only for an intended client rejection")
    func oversizedPageRetry() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            if request.url?.host == "static.nvidiagrid.net" {
                return StubbedHTTPResponse(json: #"{"games":[]}"#)
            }
            let body = try jsonObject(from: request)
            let variables = try #require(body["variables"] as? [String: Any])
            if variables["fetchCount"] as? Int == 500 {
                return StubbedHTTPResponse(statusCode: 400, json: #"{"error":"page_too_large"}"#)
            }
            return StubbedHTTPResponse(json: browsePage(
                items: [#"{"id":"retry","title":"Retry","images":{},"variants":[]}"#],
                hasNextPage: false,
                cursor: ""
            ))
        }

        let games = try await GamesClient(transport: transport).fetchMainGames(token: "token", vpcId: "vpc")
        let fetchCounts = try await transport.requests()
            .filter { $0.url?.host == "games.geforce.com" }
            .map {
                let variables = try #require(jsonObject(from: $0)["variables"] as? [String: Any])
                return try #require(variables["fetchCount"] as? Int)
            }

        #expect(games.map(\.id) == ["retry"])
        #expect(fetchCounts == [500, 200])
    }

    @Test("Authentication and server failures do not trigger page-size retry", arguments: [401, 500])
    func failuresDoNotRetry(statusCode: Int) async throws {
        let transport = RecordingHTTPTransport { request, _ in
            if request.url?.host == "static.nvidiagrid.net" {
                return StubbedHTTPResponse(json: #"{"games":[]}"#)
            }
            return StubbedHTTPResponse(statusCode: statusCode, json: #"{"error":"failed"}"#)
        }
        let client = GamesClient(transport: transport)

        await #expect(throws: (any Error).self) {
            _ = try await client.fetchMainGames(token: "token", vpcId: "vpc")
        }
        #expect(await transport.requests().filter { $0.url?.host == "games.geforce.com" }.count == 1)
    }

    @Test("Genre schema errors retry the compatibility query")
    func genreCompatibilityFallback() async throws {
        let transport = RecordingHTTPTransport { request, index in
            if request.url?.host == "static.nvidiagrid.net" {
                return StubbedHTTPResponse(json: #"{"games":[]}"#)
            }
            if index == 0 || index == 1 {
                let query = try #require(jsonObject(from: request)["query"] as? String)
                if query.contains("genres") {
                    return StubbedHTTPResponse(
                        json: #"{"errors":[{"message":"Cannot query field genres"}],"data":null}"#
                    )
                }
            }
            return StubbedHTTPResponse(json: browsePage(
                items: [#"{"id":"compatible","title":"Compatible","images":{},"variants":[]}"#],
                hasNextPage: false,
                cursor: ""
            ))
        }

        let games = try await GamesClient(transport: transport).fetchMainGames(token: "token", vpcId: "vpc")
        let requests = await transport.requests().filter { $0.url?.host == "games.geforce.com" }
        let queries = try requests.map { try #require(jsonObject(from: $0)["query"] as? String) }

        #expect(games.map(\.id) == ["compatible"])
        #expect(queries.count == 2)
        #expect(queries[0].contains("genres"))
        #expect(!queries[1].contains("genres"))
    }

    @Test("Search trims text and selects relevance ordering")
    func searchRequest() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            let body = try jsonObject(from: request)
            let query = try #require(body["query"] as? String)
            let variables = try #require(body["variables"] as? [String: Any])
            #expect(query.contains("searchQuery: $searchString"))
            #expect(variables["searchString"] as? String == "Portal")
            #expect(variables["sortString"] as? String == "itemMetadata.relevance:DESC,sortName:ASC")
            return StubbedHTTPResponse(json: browsePage(
                items: [#"{"id":"portal","title":"Portal","images":{},"variants":[]}"#],
                hasNextPage: false,
                cursor: ""
            ))
        }

        let games = try await GamesClient(transport: transport).search(
            token: "token",
            query: "  Portal \n",
            vpcId: "vpc"
        )

        #expect(games.map(\.title) == ["Portal"])
    }

    @Test("Missing VPC ID requests server info and falls back to its server ID")
    func vpcDiscovery() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            if request.url?.path == "/v2/serverInfo" {
                #expect(request.value(forHTTPHeaderField: "nv-client-type") == "BROWSER")
                return StubbedHTTPResponse(json: #"{"requestStatus":{"serverId":"discovered-vpc"}}"#)
            }
            if request.url?.host == "static.nvidiagrid.net" {
                return StubbedHTTPResponse(json: #"{"games":[]}"#)
            }
            let variables = try #require(jsonObject(from: request)["variables"] as? [String: Any])
            #expect(variables["vpcId"] as? String == "discovered-vpc")
            return StubbedHTTPResponse(json: browsePage(items: [], hasNextPage: false, cursor: ""))
        }

        _ = try await GamesClient(transport: transport).fetchMainGames(
            token: "token",
            streamingBaseUrl: "https://stream.example.invalid"
        )

        #expect(await transport.requests().contains { $0.url?.path == "/v2/serverInfo" })
    }

    @Test("An unchanged second Library refresh sends no metadata request")
    func unchangedLibraryRefreshUsesMetadataCache() async throws {
        let cache = InMemoryGameMetadataCache()
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let transport = RecordingHTTPTransport { request, _ in
            if let variables = try metadataVariables(from: request) {
                let ids = try #require(variables["appIds"] as? [String])
                return try StubbedHTTPResponse(
                    data: metadataResponse(ids: ids)
                )
            }
            return StubbedHTTPResponse(
                json: libraryBrowsePage(ids: ["one"])
            )
        }

        let firstClient = GamesClient(
            transport: transport,
            now: { firstDate },
            localeCode: { "en-US" },
            metadataCache: cache
        )
        let first = try await firstClient.fetchLibrary(
            token: "token",
            vpcId: "vpc-a"
        )
        let secondClient = GamesClient(
            transport: transport,
            now: { firstDate.addingTimeInterval(60) },
            localeCode: { "en-US" },
            metadataCache: cache
        )
        let second = try await secondClient.fetchLibrary(
            token: "token",
            vpcId: "vpc-a"
        )
        let requests = await transport.requests()

        #expect(requests.filter(isMetadataRequest).count == 1)
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 2)
        #expect(first == second)
        let game = try #require(second.first)
        #expect(game.title == "Metadata one")
        #expect(game.longDescription == "Description one")
        #expect(game.boxArtUrl?.contains("browse-one") == true)
        #expect(game.supportedFeatures == [.rtx])
        #expect(game.isInLibrary)
        #expect(game.variants.map(\.id) == ["one-variant"])
    }

    @Test("A Library request uses one locale for browse, metadata, and cache scope")
    func libraryRequestKeepsCapturedLocale() async throws {
        let cache = InMemoryGameMetadataCache()
        let locale = LockedLocaleCode("en-US")
        let transport = RecordingHTTPTransport { request, _ in
            if let variables = try metadataVariables(from: request) {
                let ids = try #require(variables["appIds"] as? [String])
                return try StubbedHTTPResponse(
                    data: metadataResponse(ids: ids)
                )
            }
            locale.set("fr-FR")
            return StubbedHTTPResponse(
                json: libraryBrowsePage(ids: ["one"])
            )
        }
        let client = GamesClient(
            transport: transport,
            localeCode: { locale.get() },
            metadataCache: cache
        )

        _ = try await client.fetchLibrary(
            token: "token",
            vpcId: "vpc-a"
        )
        let requests = await transport.requests()
        let browseRequest = try #require(
            requests.first { $0.httpMethod == "POST" }
        )
        let browseBody = try jsonObject(from: browseRequest)
        let browseVariables = try #require(
            browseBody["variables"] as? [String: Any]
        )
        let metadataRequestVariables = try #require(
            requests.compactMap { try metadataVariables(from: $0) }.first
        )
        let englishCache = await cache.loadGameMetadataCache(
            localeCode: "en-US",
            vpcId: "vpc-a"
        )
        let frenchCache = await cache.loadGameMetadataCache(
            localeCode: "fr-FR",
            vpcId: "vpc-a"
        )

        #expect(browseVariables["locale"] as? String == "en-US")
        #expect(metadataRequestVariables["locale"] as? String == "en-US")
        #expect(englishCache.entries["one"]?.metadata?.title == "Metadata one")
        #expect(frenchCache.entries.isEmpty)
    }

    @Test("Clearing metadata while enrichment is in flight prevents a late cache write")
    func cacheClearIsGenerationBarrier() async throws {
        let cache = InMemoryGameMetadataCache()
        let gate = RequestGate()
        let transport = RecordingHTTPTransport { request, _ in
            if let variables = try metadataVariables(from: request) {
                await gate.suspendRequest()
                let ids = try #require(variables["appIds"] as? [String])
                return try StubbedHTTPResponse(
                    data: metadataResponse(ids: ids)
                )
            }
            return StubbedHTTPResponse(
                json: libraryBrowsePage(ids: ["one"])
            )
        }
        let client = GamesClient(
            transport: transport,
            localeCode: { "en-US" },
            metadataCache: cache
        )
        let fetch = Task {
            try await client.fetchLibrary(
                token: "token",
                vpcId: "vpc-a"
            )
        }

        await gate.waitUntilSuspended()
        await cache.clear()
        await gate.releaseRequest()
        _ = try await fetch.value

        #expect(
            await cache.loadGameMetadataCache(
                localeCode: "en-US",
                vpcId: "vpc-a"
            ).entries.isEmpty
        )
    }

    @Test("Clearing metadata during browse prevents that refresh from repopulating it")
    func cacheClearDuringBrowseIsGenerationBarrier() async throws {
        let cache = InMemoryGameMetadataCache()
        let gate = RequestGate()
        let transport = RecordingHTTPTransport { request, _ in
            if let variables = try metadataVariables(from: request) {
                let ids = try #require(variables["appIds"] as? [String])
                return try StubbedHTTPResponse(
                    data: metadataResponse(ids: ids)
                )
            }
            await gate.suspendRequest()
            return StubbedHTTPResponse(
                json: libraryBrowsePage(ids: ["one"])
            )
        }
        let client = GamesClient(
            transport: transport,
            localeCode: { "en-US" },
            metadataCache: cache
        )
        let fetch = Task {
            try await client.fetchLibrary(
                token: "token",
                vpcId: "vpc-a"
            )
        }

        await gate.waitUntilSuspended()
        await cache.clear()
        await gate.releaseRequest()
        _ = try await fetch.value

        #expect(await transport.requests().filter(isMetadataRequest).isEmpty)
        #expect(
            await cache.loadGameMetadataCache(
                localeCode: "en-US",
                vpcId: "vpc-a"
            ).entries.isEmpty
        )
    }

    @Test("Metadata refresh requests only missing or expired IDs and is VPC scoped")
    func metadataRefreshSelectsIdsAndScopesVpc() async throws {
        let cache = InMemoryGameMetadataCache()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        await cache.seed(
            [
                "fresh": GameMetadataCacheEntry(
                    metadata: cachedMetadata(title: "Cached fresh"),
                    refreshedAt: now.addingTimeInterval(-60)
                ),
                "expired": GameMetadataCacheEntry(
                    metadata: cachedMetadata(title: "Stale expired"),
                    refreshedAt: now.addingTimeInterval(-(25 * 60 * 60))
                ),
            ],
            localeCode: "en-US",
            vpcId: "vpc-a"
        )
        let transport = RecordingHTTPTransport { request, _ in
            if let variables = try metadataVariables(from: request) {
                let ids = try #require(variables["appIds"] as? [String])
                return try StubbedHTTPResponse(
                    data: metadataResponse(ids: ids)
                )
            }
            return StubbedHTTPResponse(
                json: libraryBrowsePage(ids: ["fresh", "expired", "new"])
            )
        }
        let client = GamesClient(
            transport: transport,
            now: { now },
            localeCode: { "en-US" },
            metadataCache: cache
        )

        let firstVpc = try await client.fetchLibrary(
            token: "token",
            vpcId: "vpc-a"
        )
        _ = try await client.fetchLibrary(
            token: "token",
            vpcId: "vpc-b"
        )
        let metadataRequests = await transport.requests()
            .compactMap { try? metadataVariables(from: $0) }
        let requestedIds = metadataRequests.compactMap {
            $0["appIds"] as? [String]
        }

        #expect(requestedIds == [
            ["expired", "new"],
            ["fresh", "expired", "new"],
        ])
        #expect(firstVpc.first { $0.id == "fresh" }?.title == "Cached fresh")
        #expect(firstVpc.first { $0.id == "expired" }?.title == "Metadata expired")
    }

    @Test("A successful metadata omission is temporarily negative cached")
    func missingMetadataUsesTombstone() async throws {
        let cache = InMemoryGameMetadataCache()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let transport = RecordingHTTPTransport { request, _ in
            if isMetadataRequest(request) {
                return StubbedHTTPResponse(
                    json: #"{"data":{"apps":{"items":[]}}}"#
                )
            }
            return StubbedHTTPResponse(
                json: libraryBrowsePage(ids: ["missing"])
            )
        }
        let client = GamesClient(
            transport: transport,
            now: { now },
            localeCode: { "en-US" },
            metadataCache: cache
        )

        let first = try await client.fetchLibrary(
            token: "token",
            vpcId: "vpc-a"
        )
        let second = try await client.fetchLibrary(
            token: "token",
            vpcId: "vpc-a"
        )

        #expect(await transport.requests().filter(isMetadataRequest).count == 1)
        #expect(first == second)
        #expect(second.first?.title == "Browse missing")
    }

    @Test("Failed metadata refresh retains stale enrichment without refreshing its timestamp")
    func failedMetadataRefreshUsesStaleCache() async throws {
        let cache = InMemoryGameMetadataCache()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let staleDate = now.addingTimeInterval(-(25 * 60 * 60))
        let staleEntry = GameMetadataCacheEntry(
            metadata: cachedMetadata(title: "Stale title"),
            refreshedAt: staleDate
        )
        await cache.seed(
            ["stale": staleEntry],
            localeCode: "en-US",
            vpcId: "vpc-a"
        )
        let transport = RecordingHTTPTransport { request, _ in
            if isMetadataRequest(request) {
                throw TestTransportError.unexpectedRequest("metadata unavailable")
            }
            return StubbedHTTPResponse(
                json: libraryBrowsePage(ids: ["stale"])
            )
        }
        let client = GamesClient(
            transport: transport,
            now: { now },
            localeCode: { "en-US" },
            metadataCache: cache
        )

        let games = try await client.fetchLibrary(
            token: "token",
            vpcId: "vpc-a"
        )
        let persisted = await cache.loadGameMetadataCache(
            localeCode: "en-US",
            vpcId: "vpc-a"
        ).entries

        #expect(games.first?.title == "Stale title")
        #expect(persisted["stale"] == staleEntry)
    }

    @Test("Cancellation propagates without retry")
    func cancellation() async {
        let transport = RecordingHTTPTransport { request, _ in
            if request.url?.host == "static.nvidiagrid.net" {
                throw CancellationError()
            }
            try Task.checkCancellation()
            throw CancellationError()
        }
        let client = GamesClient(transport: transport)
        let task = Task {
            try await client.fetchMainGames(token: "token", vpcId: "vpc")
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}

private nonisolated func browsePage(items: [String], hasNextPage: Bool, cursor: String) -> String {
    """
    {
      "data": {
        "apps": {
          "numberReturned": \(items.count),
          "pageInfo": {
            "hasNextPage": \(hasNextPage),
            "endCursor": "\(cursor)",
            "totalCount": \(items.count)
          },
          "items": [\(items.joined(separator: ","))]
        }
      }
    }
    """
}

private nonisolated func libraryBrowsePage(ids: [String]) -> String {
    browsePage(
        items: ids.map { id in
            """
            {
              "id": "\(id)",
              "title": "Browse \(id)",
              "genres": ["ACTION"],
              "images": {
                "GAME_BOX_ART": "https://images.invalid/browse-\(id).jpg"
              },
              "variants": [
                {
                  "id": "\(id)-variant",
                  "appStore": "STEAM",
                  "gfn": {
                    "status": "AVAILABLE",
                    "library": {
                      "status": "IN_LIBRARY",
                      "selected": true
                    },
                    "features": [
                      {
                        "__typename": "GfnSubscriptionFeatureValue",
                        "key": "RTX_ENABLED",
                        "value": "true"
                      }
                    ]
                  }
                }
              ]
            }
            """
        },
        hasNextPage: false,
        cursor: ""
    )
}

private nonisolated func metadataResponse(ids: [String]) throws -> Data {
    let items: [[String: Any]] = ids.map { id in
        [
            "id": id,
            "title": "Metadata \(id)",
            "longDescription": "Description \(id)",
            "genres": ["RACING"],
            "developerName": "Developer \(id)",
            "publisherName": "Publisher \(id)",
            "contentRatings": [
                "type": "ESRB",
                "categoryKey": "TEEN",
            ],
            "images": [
                "TV_BANNER": "https://images.invalid/banner-\(id).jpg",
                "HERO_IMAGE": "https://images.invalid/hero-\(id).jpg",
                "SCREENSHOT_1": "https://images.invalid/screenshot-\(id).jpg",
            ],
            "variants": [],
        ]
    }
    return try JSONSerialization.data(
        withJSONObject: [
            "data": [
                "apps": [
                    "items": items,
                ],
            ],
        ]
    )
}

private nonisolated func metadataVariables(
    from request: URLRequest
) throws -> [String: Any]? {
    guard let url = request.url,
          let components = URLComponents(
              url: url,
              resolvingAgainstBaseURL: false
          ),
          components.queryItems?.first(where: {
              $0.name == "requestType"
          })?.value == "appMetaData",
          let variablesValue = components.queryItems?.first(where: {
              $0.name == "variables"
          })?.value,
          let variablesData = variablesValue.data(using: .utf8)
    else {
        return nil
    }
    return try #require(
        JSONSerialization.jsonObject(with: variablesData) as? [String: Any]
    )
}

private nonisolated func isMetadataRequest(_ request: URLRequest) -> Bool {
    guard let url = request.url,
          let components = URLComponents(
              url: url,
              resolvingAgainstBaseURL: false
          )
    else {
        return false
    }
    return components.queryItems?.contains {
        $0.name == "requestType" && $0.value == "appMetaData"
    } == true
}

private nonisolated func cachedMetadata(title: String) -> CachedGameMetadata {
    CachedGameMetadata(
        title: title,
        longDescription: nil,
        genres: nil,
        developer: nil,
        publisher: nil,
        contentRating: nil,
        boxArtUrl: nil,
        tvBannerUrl: nil,
        heroImageUrl: nil,
        screenshots: []
    )
}

private final class LockedLocaleCode: @unchecked Sendable {
    private let lock = NSLock()
    private var code: String

    init(_ code: String) {
        self.code = code
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return code
    }

    func set(_ code: String) {
        lock.lock()
        self.code = code
        lock.unlock()
    }
}

private actor RequestGate {
    private var isSuspended = false
    private var isReleased = false
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendRequest() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters = []
        waiters.forEach { $0.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            requestContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func releaseRequest() {
        isReleased = true
        requestContinuation?.resume()
        requestContinuation = nil
    }
}

private actor InMemoryGameMetadataCache: GameMetadataCacheStore {
    private struct Scope: Hashable {
        let localeCode: String
        let vpcId: String
    }

    private var entriesByScope: [
        Scope: [String: GameMetadataCacheEntry]
    ] = [:]
    private var generation: UInt64 = 0

    func currentGameMetadataCacheGeneration() -> UInt64 {
        generation
    }

    func seed(
        _ entries: [String: GameMetadataCacheEntry],
        localeCode: String,
        vpcId: String
    ) {
        entriesByScope[
            Scope(localeCode: localeCode, vpcId: vpcId)
        ] = entries
    }

    func loadGameMetadataCache(
        localeCode: String,
        vpcId: String
    ) -> GameMetadataCacheSnapshot {
        GameMetadataCacheSnapshot(
            entries: entriesByScope[
                Scope(localeCode: localeCode, vpcId: vpcId),
                default: [:]
            ],
            generation: generation
        )
    }

    func mergeGameMetadataCache(
        _ updates: [String: GameMetadataCacheEntry],
        localeCode: String,
        vpcId: String,
        pruningBefore: Date,
        maximumEntryCount: Int,
        expectedGeneration: UInt64
    ) {
        guard expectedGeneration == generation else { return }
        let scope = Scope(localeCode: localeCode, vpcId: vpcId)
        var entries = entriesByScope[scope, default: [:]]
        entries.merge(updates) { current, updated in
            current.refreshedAt > updated.refreshedAt
                ? current
                : updated
        }
        entriesByScope[scope] = Dictionary(
            uniqueKeysWithValues: entries
                .filter { $0.value.refreshedAt >= pruningBefore }
                .sorted { $0.value.refreshedAt > $1.value.refreshedAt }
                .prefix(maximumEntryCount)
                .map { ($0.key, $0.value) }
        )
    }

    func clear() {
        generation &+= 1
        entriesByScope = [:]
    }
}
