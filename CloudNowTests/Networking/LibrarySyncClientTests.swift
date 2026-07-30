@testable import CloudNow
import Foundation
import Testing

@Suite("Provider library synchronization client")
struct LibrarySyncClientTests {
    @Test("Discovery uses persisted LCARS contracts and keeps every connected store visible")
    func discoveryRequestAndDecoding() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            let query = queryValues(from: request)
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "apps.gxn.nvidia.com")
            #expect(request.url?.path == "/graphql")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT fixture-token")
            #expect(
                request.value(forHTTPHeaderField: "nv-client-id")
                    == "ec7e38d4-03af-4b58-b131-cfb0495903ab"
            )
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/graphql")
            #expect(
                query["huId"]
                    == "6d894aa3ee802549d7f340e7c1cf0d1c1cb14cd84f768d92ffaa6785337c4997"
            )

            switch query["requestType"] {
            case "staticAppData":
                try expectPersistedQueryHash(
                    "d4117df5319f644c984945715ded9574bb074107eb02e97be17605b5f14c33ba",
                    query: query
                )
                let variables = try jsonDictionary(query["variables"])
                #expect(variables["locale"] as? String == "en-US")
                #expect((variables["stringsKey"] as? [Any])?.isEmpty == true)
                return StubbedHTTPResponse(json: staticDefinitionsResponse)

            case "userAccount":
                try expectPersistedQueryHash(
                    "fc7ce0b3cfe6e09bfcd331aebef9fc27dd648a16d27888231a8282831afab85f",
                    query: query
                )
                #expect(query["variables"] == nil)
                return StubbedHTTPResponse(json: connectedAccountsResponse)

            default:
                throw TestTransportError.unexpectedRequest(request.url?.absoluteString ?? "(nil)")
            }
        }
        let client = GFNLibrarySyncClient(transport: transport, localeCode: { "en-US" })

        let providers = try await client.discover(token: "fixture-token", userId: "user-42")

        #expect(
            providers.map(\.code)
                == ["STEAM", "BATTLE_NET", "EPIC", "SERVER_ONLY_PROVIDER"]
        )
        let steam = try #require(providers.first)
        #expect(steam.id == "STEAM")
        #expect(steam.displayName == "Steam")
        #expect(steam.accountDisplayName == "Steam Player")
        #expect(steam.iconURL == URL(string: "https://assets.example/steam.png"))
        #expect(steam.supportsSync)
        #expect(steam.sortOrder == 10)
        #expect(steam.snapshot.totalSyncedGames == 23)
        #expect(steam.snapshot.state == .success)
        #expect(steam.snapshot.syncDate == Date(timeIntervalSince1970: 1_700_000_000))

        let battleNet = try #require(providers.first { $0.code == "BATTLE_NET" })
        #expect(!battleNet.supportsSync)
        #expect(battleNet.snapshot.state == .denied)

        let epic = try #require(providers.first { $0.code == "EPIC" })
        #expect(!epic.supportsSync)
        #expect(epic.accountDisplayName == nil)
        #expect(epic.snapshot.state == .unknown(nil))

        let serverOnly = try #require(
            providers.first { $0.code == "SERVER_ONLY_PROVIDER" }
        )
        #expect(serverOnly.displayName == "SERVER_ONLY_PROVIDER")
        #expect(!serverOnly.supportsSync)
        #expect(serverOnly.sortOrder == .max)
        #expect(await transport.requests().count == 2)
    }

    @Test("Account snapshots decode every known state and preserve unknown states")
    func accountSnapshotStates() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            #expect(queryValues(from: request)["requestType"] == "userAccount")
            return StubbedHTTPResponse(json: """
            {
              "data": {
                "userAccount": {
                  "storesData": [
                    {
                      "store": "SUCCESS",
                      "accountLinkingData": {
                        "accountSyncingData": {
                          "totalNumberOfSyncedGfnGames": "4",
                          "syncState": "SYNC_SUCCESS",
                          "syncDate": "2026-07-30T10:15:30.250Z"
                        }
                      }
                    },
                    {
                      "store": "FAILED",
                      "accountLinkingData": {
                        "accountSyncingData": {
                          "syncState": "SYNC_FAILED",
                          "syncDate": 1700000000
                        }
                      }
                    },
                    {
                      "store": "DENIED",
                      "accountLinkingData": {
                        "accountSyncingData": { "syncState": "SYNC_DENIED" }
                      }
                    },
                    {
                      "store": "PROFILE",
                      "accountLinkingData": {
                        "accountSyncingData": { "syncState": "PROFILE_NOT_CREATED" }
                      }
                    },
                    {
                      "store": "FUTURE",
                      "accountLinkingData": {
                        "accountSyncingData": { "syncState": "SYNC_SUPER_NEW" }
                      }
                    },
                    {
                      "store": "DISCONNECTED",
                      "accountLinkingData": null
                    }
                  ]
                }
              }
            }
            """)
        }

        let snapshots = try await GFNLibrarySyncClient(transport: transport)
            .fetchSnapshots(token: "token", userId: "user")

        #expect(snapshots.map(\.providerCode) == ["SUCCESS", "FAILED", "DENIED", "PROFILE", "FUTURE"])
        #expect(snapshots[0].totalSyncedGames == 4)
        #expect(snapshots[0].state == .success)
        #expect(snapshots[0].syncDate != nil)
        #expect(snapshots[1].state == .failed)
        #expect(snapshots[1].syncDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(snapshots[2].state == .denied)
        #expect(snapshots[3].state == .profileNotCreated)
        #expect(snapshots[4].state == .unknown("SYNC_SUPER_NEW"))
        #expect(snapshots[4].state.rawValue == "SYNC_SUPER_NEW")
    }

    @Test("ALS synchronization sends an encoded provider path and requires HTTP 202")
    func syncRequest() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "als.geforcenow.com")
            #expect(components.percentEncodedPath == "/v1/sync/XBOX%2FGame%20Pass")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sync-token")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.httpBody == Data("{}".utf8))
            return StubbedHTTPResponse(statusCode: 202)
        }

        try await GFNLibrarySyncClient(transport: transport).requestSync(
            providerCode: "XBOX/Game Pass",
            token: "sync-token"
        )

        #expect(await transport.requests().count == 1)
    }

    @Test(
        "HTTP failures map to actionable errors without retaining response bodies",
        arguments: [
            LibrarySyncHTTPFailureFixture(statusCode: 401, headers: [:], expected: .unauthorized),
            LibrarySyncHTTPFailureFixture(statusCode: 403, headers: [:], expected: .forbidden),
            LibrarySyncHTTPFailureFixture(
                statusCode: 429,
                headers: ["Retry-After": "30"],
                expected: .rateLimited(retryAfter: 30)
            ),
            LibrarySyncHTTPFailureFixture(statusCode: 500, headers: [:], expected: .httpStatus(500)),
        ]
    )
    func httpErrors(failure: LibrarySyncHTTPFailureFixture) async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                statusCode: failure.statusCode,
                json: #"{"token":"must-not-escape","userDisplayName":"Private"}"#,
                headers: failure.headers
            )
        }
        let client = GFNLibrarySyncClient(transport: transport)

        let error = await capturedLibrarySyncError {
            try await client.requestSync(providerCode: "STEAM", token: "private-token")
        }

        #expect(error == failure.expected)
        #expect(error?.localizedDescription.contains("private-token") == false)
        #expect(error?.localizedDescription.contains("must-not-escape") == false)
        #expect(error?.localizedDescription.contains("Private") == false)
    }

    @Test(
        "ALS contract drift fails closed while service failures retain their status",
        arguments: [
            LibrarySyncALSStatusFixture(statusCode: 200, expected: .schema),
            LibrarySyncALSStatusFixture(statusCode: 201, expected: .schema),
            LibrarySyncALSStatusFixture(statusCode: 204, expected: .schema),
            LibrarySyncALSStatusFixture(statusCode: 404, expected: .schema),
            LibrarySyncALSStatusFixture(statusCode: 405, expected: .schema),
            LibrarySyncALSStatusFixture(statusCode: 410, expected: .schema),
            LibrarySyncALSStatusFixture(statusCode: 500, expected: .httpStatus(500)),
            LibrarySyncALSStatusFixture(statusCode: 503, expected: .httpStatus(503)),
        ]
    )
    func alsContractDrift(fixture: LibrarySyncALSStatusFixture) async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(statusCode: fixture.statusCode)
        }
        let client = GFNLibrarySyncClient(transport: transport)

        let error = await capturedLibrarySyncError {
            try await client.requestSync(providerCode: "STEAM", token: "token")
        }

        #expect(error == fixture.expected)
    }

    @Test(
        "LCARS GET contract drift fails closed for discovery and polling",
        arguments: [
            LibrarySyncLCARSStatusFixture(statusCode: 201, expected: .schema),
            LibrarySyncLCARSStatusFixture(statusCode: 202, expected: .schema),
            LibrarySyncLCARSStatusFixture(statusCode: 204, expected: .schema),
            LibrarySyncLCARSStatusFixture(statusCode: 404, expected: .schema),
            LibrarySyncLCARSStatusFixture(statusCode: 405, expected: .schema),
            LibrarySyncLCARSStatusFixture(statusCode: 410, expected: .schema),
            LibrarySyncLCARSStatusFixture(statusCode: 500, expected: .httpStatus(500)),
            LibrarySyncLCARSStatusFixture(statusCode: 503, expected: .httpStatus(503)),
        ]
    )
    func lcarsContractDrift(fixture: LibrarySyncLCARSStatusFixture) async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(statusCode: fixture.statusCode)
        }
        let client = GFNLibrarySyncClient(transport: transport)

        let discoveryError = await capturedLibrarySyncError {
            _ = try await client.discover(token: "token", userId: "user")
        }
        let pollingError = await capturedLibrarySyncError {
            _ = try await client.fetchSnapshots(token: "token", userId: "user")
        }

        #expect(discoveryError == fixture.expected)
        #expect(pollingError == fixture.expected)
    }

    @Test(
        "Retry-After accepts delta-seconds and HTTP dates",
        arguments: [
            LibrarySyncRetryAfterFixture(
                headerValue: " 30 ",
                currentDate: Date(timeIntervalSince1970: 1_445_412_420),
                expectedDelay: 30
            ),
            LibrarySyncRetryAfterFixture(
                headerValue: "Wed, 21 Oct 2015 07:28:00 GMT",
                currentDate: Date(timeIntervalSince1970: 1_445_412_420),
                expectedDelay: 60
            ),
            LibrarySyncRetryAfterFixture(
                headerValue: "Wed, 21 Oct 2015 07:26:00 GMT",
                currentDate: Date(timeIntervalSince1970: 1_445_412_420),
                expectedDelay: 0
            ),
            LibrarySyncRetryAfterFixture(
                headerValue: "not-a-retry-window",
                currentDate: Date(timeIntervalSince1970: 1_445_412_420),
                expectedDelay: nil
            ),
        ]
    )
    func retryAfterParsing(fixture: LibrarySyncRetryAfterFixture) async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                statusCode: 429,
                headers: ["Retry-After": fixture.headerValue]
            )
        }
        let currentDate = fixture.currentDate
        let client = GFNLibrarySyncClient(
            transport: transport,
            currentDate: { currentDate }
        )

        let error = await capturedLibrarySyncError {
            try await client.requestSync(providerCode: "STEAM", token: "token")
        }

        #expect(error == .rateLimited(retryAfter: fixture.expectedDelay))
    }

    @Test("GraphQL authorization codes map without exposing server messages")
    func graphQLErrorMapping() async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: """
            {
              "errors": [
                {
                  "message": "account Private User was rejected",
                  "extensions": { "code": "FORBIDDEN" }
                }
              ],
              "data": null
            }
            """)
        }
        let client = GFNLibrarySyncClient(transport: transport)

        let error = await capturedLibrarySyncError {
            _ = try await client.fetchSnapshots(token: "token", userId: "user")
        }

        #expect(error == .forbidden)
        #expect(error?.localizedDescription.contains("Private User") == false)
    }

    @Test("Malformed and incomplete GraphQL payloads fail closed", arguments: [
        #"{"notData":true}"#,
        #"{"data":{"userAccount":{"storesData":"not-an-array"}}}"#,
        #"{"data":{"userAccount":{"storesData":[{"store":"STEAM","accountLinkingData":{"accountSyncingData":{"syncDate":"not-a-date"}}}]}}}"#,
    ])
    func schemaFailures(payload: String) async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: payload)
        }
        let client = GFNLibrarySyncClient(transport: transport)

        let error = await capturedLibrarySyncError {
            _ = try await client.fetchSnapshots(token: "token", userId: "user")
        }

        #expect(error == .schema)
    }

    @Test("GET network failures and ambiguous POST failures remain distinguishable")
    func networkFailureMapping() async {
        let transport = RecordingHTTPTransport { _, _ in
            throw TestTransportError.unexpectedRequest("offline")
        }
        let client = GFNLibrarySyncClient(transport: transport)

        let getError = await capturedLibrarySyncError {
            _ = try await client.fetchSnapshots(token: "token", userId: "user")
        }
        let postError = await capturedLibrarySyncError {
            try await client.requestSync(providerCode: "STEAM", token: "token")
        }

        #expect(getError == .network)
        #expect(postError == .networkAmbiguous)
    }

    @Test("Transport cancellation remains cancellation")
    func cancellation() async {
        let transport = RecordingHTTPTransport { _, _ in
            throw CancellationError()
        }
        let client = GFNLibrarySyncClient(transport: transport)

        await #expect(throws: CancellationError.self) {
            _ = try await client.fetchSnapshots(token: "token", userId: "user")
        }
        await #expect(throws: CancellationError.self) {
            try await client.requestSync(providerCode: "STEAM", token: "token")
        }
    }
}

nonisolated struct LibrarySyncALSStatusFixture: Sendable, CustomTestStringConvertible {
    let statusCode: Int
    let expected: LibrarySyncError

    var testDescription: String {
        "ALS HTTP \(statusCode)"
    }
}

nonisolated struct LibrarySyncLCARSStatusFixture: Sendable, CustomTestStringConvertible {
    let statusCode: Int
    let expected: LibrarySyncError

    var testDescription: String {
        "LCARS HTTP \(statusCode)"
    }
}

nonisolated struct LibrarySyncRetryAfterFixture: Sendable, CustomTestStringConvertible {
    let headerValue: String
    let currentDate: Date
    let expectedDelay: TimeInterval?

    var testDescription: String {
        "Retry-After: \(headerValue)"
    }
}

nonisolated struct LibrarySyncHTTPFailureFixture: Sendable, CustomTestStringConvertible {
    let statusCode: Int
    let headers: [String: String]
    let expected: LibrarySyncError

    var testDescription: String {
        "HTTP \(statusCode)"
    }
}

private nonisolated func queryValues(from request: URLRequest) -> [String: String] {
    guard let url = request.url else { return [:] }
    return Dictionary(
        uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? [])
            .compactMap { item in
                item.value.map { (item.name, $0) }
            }
    )
}

private nonisolated func jsonDictionary(_ string: String?) throws -> [String: Any] {
    let string = try #require(string)
    return try #require(
        JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
    )
}

private nonisolated func expectPersistedQueryHash(
    _ expectedHash: String,
    query: [String: String]
) throws {
    let extensions = try jsonDictionary(query["extensions"])
    let persistedQuery = try #require(extensions["persistedQuery"] as? [String: Any])
    #expect(persistedQuery["sha256Hash"] as? String == expectedHash)
}

private nonisolated func capturedLibrarySyncError(
    _ operation: @Sendable () async throws -> Void
) async -> LibrarySyncError? {
    do {
        try await operation()
        Issue.record("Expected a LibrarySyncError")
        return nil
    } catch let error as LibrarySyncError {
        return error
    } catch {
        Issue.record("Unexpected error type: \(type(of: error))")
        return nil
    }
}

private let staticDefinitionsResponse = """
{
  "data": {
    "appStoreDefinitions": [
      {
        "store": "EPIC",
        "label": "Epic Games Store",
        "sortOrder": 30,
        "smallImageUrl": "https://assets.example/epic.png",
        "features": [
          { "__typename": "AccountLinkingSso", "supported": true }
        ]
      },
      {
        "store": "STEAM",
        "label": "Steam",
        "sortOrder": 10,
        "smallImageUrl": "https://assets.example/steam.png",
        "features": [
          { "__typename": "AccountGamesSyncing", "supported": true }
        ]
      },
      {
        "store": "BATTLE_NET",
        "label": "Battle.net",
        "sortOrder": 20,
        "smallImageUrl": null,
        "features": [
          { "__typename": "AccountGamesSyncing", "supported": false }
        ]
      },
      {
        "store": "DISCONNECTED",
        "label": "Disconnected",
        "sortOrder": 40,
        "features": [
          { "__typename": "AccountGamesSyncing", "supported": true }
        ]
      }
    ]
  }
}
"""

private let connectedAccountsResponse = """
{
  "data": {
    "userAccount": {
      "subscriptions": [],
      "storesData": [
        {
          "store": "steam",
          "accountLinkingData": {
            "userDisplayName": " Steam Player ",
            "expiresIn": 1209600,
            "userIdentifier": "private-id",
            "accountSyncingData": {
              "totalNumberOfSyncedGfnGames": "23",
              "syncState": "SYNC_SUCCESS",
              "syncDate": 1700000000000
            }
          }
        },
        {
          "store": "EPIC",
          "accountLinkingData": {
            "userDisplayName": " ",
            "accountSyncingData": null
          }
        },
        {
          "store": "BATTLE_NET",
          "accountLinkingData": {
            "userDisplayName": "Battle Player",
            "accountSyncingData": {
              "totalNumberOfSyncedGfnGames": 5,
              "syncState": "SYNC_DENIED",
              "syncDate": "2026-07-30T10:15:30Z"
            }
          }
        },
        {
          "store": "DISCONNECTED",
          "accountLinkingData": null
        },
        {
          "store": "SERVER_ONLY_PROVIDER",
          "accountLinkingData": {
            "userDisplayName": "No static definition",
            "accountSyncingData": null
          }
        }
      ]
    }
  }
}
"""
