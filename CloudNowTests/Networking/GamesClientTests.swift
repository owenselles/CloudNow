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
