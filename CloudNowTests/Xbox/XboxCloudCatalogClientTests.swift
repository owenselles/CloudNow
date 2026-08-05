@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox Cloud authenticated catalog")
struct XboxCloudCatalogClientTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Enumerates authenticated titles with bounded continuation pagination")
    func enumeratesTitles() async throws {
        let sessionProvider = XboxCloudGSSessionProviderStub(session: makeSession())
        let transport = RecordingHTTPTransport { request, index in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-gs-secret")
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            switch index {
            case 0:
                #expect(request.url?.absoluteString == "https://wus.gssv-play-prod.xboxlive.com/v2/titles?mr=DE")
                return StubbedHTTPResponse(json: Self.firstCatalogPageJSON)
            case 1:
                #expect(request.url?.absoluteString == "https://wus.gssv-play-prod.xboxlive.com/v2/titles?mr=DE&ct=next%20page")
                return StubbedHTTPResponse(json: Self.secondCatalogPageJSON)
            default:
                throw TestTransportError.unexpectedRequest("Unexpected page \(index)")
            }
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: sessionProvider,
            transport: transport,
            now: { fixedDate }
        )

        let snapshot = try await client.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "de-DE", market: "DE"),
            account: makeAccount()
        )

        #expect(snapshot.fetchedAt == fixedDate)
        #expect(snapshot.items.map(\.id) == ["111", "222", "333"])
        #expect(snapshot.items.map(\.title) == ["Halo Infinite", "Forza Horizon", "Sea of Thieves"])
        #expect(snapshot.items[0].artworkURL?.absoluteString == "https://images.example/halo-poster.jpg")
        #expect(snapshot.items[1].artworkURL == nil)
        #expect(snapshot.items[2].artworkURL?.absoluteString == "https://images.example/sea.jpg")
        #expect(snapshot.items.map(\.routes) == [
            [XboxCloudTitleRoute(titleID: "111", accessKind: .standard)],
            [XboxCloudTitleRoute(titleID: "222", accessKind: .standard)],
            [XboxCloudTitleRoute(titleID: "333", accessKind: .standard)],
        ])
        #expect(await sessionProvider.requestCount() == 1)
        #expect(await transport.requests().count == 2)
    }

    @Test("Separates product identity, classifies FERDINAND, and merges title routes")
    func accessAwareProductIdentity() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: Self.accessAwareCatalogJSON)
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )

        let snapshot = try await client.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "en-US", market: "US"),
            account: makeAccount()
        )

        #expect(snapshot.items.map(\.id) == ["product-one", "product-two"])
        let merged = try #require(snapshot.items.first)
        #expect(merged.title == "Standard Name")
        #expect(
            merged.artworkURL?.absoluteString
                == "https://images.example/product-one.jpg"
        )
        #expect(merged.routes == [
            XboxCloudTitleRoute(
                titleID: "standard-title",
                accessKind: .standard
            ),
            XboxCloudTitleRoute(
                titleID: "ad-title",
                accessKind: .freeWithAds
            ),
        ])
        #expect(merged.accessKinds == [.standard, .freeWithAds])
        #expect(merged.supportsFreeWithAds)
        #expect(
            merged.preferredRoute == XboxCloudTitleRoute(
                titleID: "standard-title",
                accessKind: .standard
            )
        )
        #expect(snapshot.items[1].routes == [
            XboxCloudTitleRoute(
                titleID: "second-ad-title",
                accessKind: .freeWithAds
            ),
        ])
        #expect(snapshot.items[1].supportsFreeWithAds)
        #expect(snapshot.items[1].preferredRoute?.accessKind == .freeWithAds)
    }

    @Test("A successful empty catalog remains a successful empty snapshot")
    func successfulEmptyCatalog() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: #"{"results":[]}"#)
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )

        let snapshot = try await client.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "en-US", market: "US"),
            account: makeAccount()
        )

        #expect(snapshot.items.isEmpty)
        #expect(snapshot.fetchedAt == fixedDate)
    }

    @Test("Discovers Fresno candidates and keeps server authorization separate")
    func fresnoDiscoveryAndAuthorization() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            if request.httpMethod == "GET" {
                #expect(request.httpMethod == "GET")
                return StubbedHTTPResponse(json: #"{"results":[]}"#)
            }
            switch request.url?.host {
            case "wus.gssv-play-prod.xboxlive.com":
                #expect(request.httpMethod == "POST")
                #expect(
                    request.url?.absoluteString
                        == "https://wus.gssv-play-prod.xboxlive.com/v2/titles?mr=DE"
                )
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-gs-secret")
                let body = try jsonObject(from: request)
                #expect(body["alternateIdType"] as? String == "productId")
                #expect(body["alternateIds"] as? [String] == [
                    "PRODUCT-PLAYABLE",
                    "PRODUCT-NOT-ENTITLED",
                    "PRODUCT-MIXED-PROGRAMS",
                ])
                return StubbedHTTPResponse(json: Self.fresnoHydrationJSON)
            case "catalog.gamepass.com":
                #expect(request.httpMethod == "POST")
                let components = try #require(
                    request.url.flatMap {
                        URLComponents(url: $0, resolvingAgainstBaseURL: false)
                    }
                )
                #expect(components.scheme == "https")
                #expect(components.host == "catalog.gamepass.com")
                #expect(components.path == "/v3/products")
                let query = Dictionary(
                    uniqueKeysWithValues: (components.queryItems ?? []).map {
                        ($0.name, $0.value ?? "")
                    }
                )
                #expect(query["market"] == "DE")
                #expect(query["language"] == "de-DE")
                #expect(query["hydration"] == "RemoteLowJade0")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(request.value(forHTTPHeaderField: "Calling-App-Name") == "Xbox Cloud Gaming Web")
                #expect(request.value(forHTTPHeaderField: "Calling-App-Version") == "29.19.17")
                #expect(request.value(forHTTPHeaderField: "MS-CV")?.hasSuffix(".0") == true)
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                let body = try jsonObject(from: request)
                #expect(body["Products"] as? [String] == [
                    "PRODUCT-PLAYABLE",
                    "PRODUCT-NOT-ENTITLED",
                    "PRODUCT-MIXED-PROGRAMS",
                ])
                return StubbedHTTPResponse(json: Self.fresnoMetadataJSON)
            default:
                throw TestTransportError.unexpectedRequest(
                    "Unexpected request \(request.url?.absoluteString ?? "nil")"
                )
            }
        }
        let contentAccess = XboxContentAccessSnapshot(
            membershipTier: .pcGamePass,
            fetchedAt: fixedDate,
            activeSubscriptionProductIDs: ["CFQ7TTC0KGQ8"],
            productAccessByProductID: [
                "PRODUCT-NOT-ENTITLED": XboxProductCloudAccess(
                    userAccessTypes: 8_388_609,
                    aggregateAccessTypes: 0,
                    streamingProgram: 2,
                    remainingGameplayTimeInSeconds: 3600,
                    maxGameplayTimeInSeconds: 3600
                ),
            ]
        )
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            contentAccessProvider: XboxContentAccessProviderStub(snapshot: contentAccess),
            fresnoDiscovery: XboxFresnoDiscoveryStub(productIDs: [
                "PRODUCT-PLAYABLE",
                "PRODUCT-NOT-ENTITLED",
                "PRODUCT-MIXED-PROGRAMS",
            ]),
            transport: transport,
            now: { fixedDate }
        )

        let snapshot = try await client.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "de-DE", market: "DE"),
            account: makeAccount()
        )

        #expect(snapshot.items.map(\.id) == [
            "PRODUCT-PLAYABLE",
            "PRODUCT-NOT-ENTITLED",
            "PRODUCT-MIXED-PROGRAMS",
        ])
        #expect(snapshot.items.map(\.preferredRoute?.availability) == [
            .playable,
            .playable,
            .playable,
        ])
        #expect(snapshot.items.map(\.title) == [
            "Playable Metadata",
            "Not Entitled Metadata",
            "Mixed Programs Metadata",
        ])
        #expect(
            snapshot.items.first?.artworkURL?.absoluteString
                == "https://images.example/playable-poster.jpg"
        )
        #expect(snapshot.items.allSatisfy { item in
            item.supportsFreeWithAds == true
        })
        #expect(await transport.requests().count == 3)
    }

    @Test("Retries rejected Fresno metadata requests in 200-product batches")
    func fresnoMetadataBatchFallback() async throws {
        let productIDs = (0 ..< 201).map { "PRODUCT-\($0)" }
        let transport = RecordingHTTPTransport { request, _ in
            if request.httpMethod == "GET" {
                return StubbedHTTPResponse(json: #"{"results":[]}"#)
            }
            if request.url?.host == "wus.gssv-play-prod.xboxlive.com" {
                let body = try jsonObject(from: request)
                #expect(body["alternateIds"] as? [String] == productIDs)
                return StubbedHTTPResponse(json: #"""
                {
                  "results": [
                    {
                      "titleId": "first-batch-title",
                      "details": {
                        "productId": "PRODUCT-0",
                        "hasEntitlement": false
                      }
                    },
                    {
                      "titleId": "second-batch-title",
                      "details": {
                        "productId": "PRODUCT-200",
                        "hasEntitlement": false
                      }
                    }
                  ]
                }
                """#)
            }
            let body = try jsonObject(from: request)
            let requestedProductIDs = try #require(body["Products"] as? [String])
            switch requestedProductIDs.count {
            case 201:
                return StubbedHTTPResponse(statusCode: 413, json: #"{"error":"too large"}"#)
            case 200:
                #expect(requestedProductIDs == Array(productIDs.prefix(200)))
                return StubbedHTTPResponse(json: #"""
                {
                  "Products": {
                    "PRODUCT-0": {
                      "StoreId": "PRODUCT-0",
                      "ProductTitle": "First Batch"
                    }
                  },
                  "InvalidIds": []
                }
                """#)
            case 1:
                #expect(requestedProductIDs == [productIDs[200]])
                return StubbedHTTPResponse(json: #"""
                {
                  "Products": {
                    "PRODUCT-200": {
                      "StoreId": "PRODUCT-200",
                      "ProductTitle": "Second Batch"
                    }
                  },
                  "InvalidIds": []
                }
                """#)
            default:
                throw TestTransportError.unexpectedRequest(
                    "Unexpected metadata batch size \(requestedProductIDs.count)"
                )
            }
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            fresnoDiscovery: XboxFresnoDiscoveryStub(productIDs: productIDs),
            transport: transport,
            now: { fixedDate }
        )

        let snapshot = try await client.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "en-US", market: "US"),
            account: makeAccount()
        )

        #expect(snapshot.items.map(\.title) == ["First Batch", "Second Batch"])
        #expect(snapshot.items.allSatisfy { $0.preferredRoute?.availability == .playable })
        #expect(await transport.requests().count == 5)
    }

    @Test("FERDINAND classification is normalized, exact, and bounded")
    func boundedUserProgramClassification() async throws {
        let oversizedPrograms = Array(repeating: "FERDINAND", count: 65)
        let payload = try JSONSerialization.data(withJSONObject: [
            "results": [
                [
                    "titleId": "normalized",
                    "details": [
                        "name": "Normalized",
                        "hasEntitlement": true,
                        "userPrograms": ["  FeRdInAnD  "],
                    ],
                ],
                [
                    "titleId": "near-match",
                    "details": [
                        "name": "Near Match",
                        "hasEntitlement": true,
                        "userPrograms": ["FERDINAND-PREVIEW"],
                    ],
                ],
                [
                    "titleId": "oversized",
                    "details": [
                        "name": "Oversized",
                        "hasEntitlement": true,
                        "userPrograms": oversizedPrograms,
                    ],
                ],
            ],
        ])
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: payload)
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )

        let snapshot = try await client.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "en-US", market: "US"),
            account: makeAccount()
        )

        #expect(snapshot.items.map(\.id) == ["normalized", "near-match"])
        #expect(snapshot.items.map(\.preferredRoute?.accessKind) == [
            .freeWithAds,
            .standard,
        ])
    }

    @Test("Requires an explicit Boolean true entitlement")
    func requiresExplicitEntitlement() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: Self.entitlementCatalogJSON)
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )

        let snapshot = try await client.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "en-US", market: "US"),
            account: makeAccount()
        )

        #expect(snapshot.items.map(\.id) == ["entitled"])
    }

    @Test("Remaining gameplay time permits missing, null, and positive finite numbers")
    func validatesRemainingGameplayTime() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: Self.remainingGameplayTimeCatalogJSON)
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )

        let snapshot = try await client.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "en-US", market: "US"),
            account: makeAccount()
        )

        #expect(snapshot.items.map(\.id) == [
            "missing-time",
            "null-time",
            "positive-integer",
            "positive-fraction",
        ])
    }

    @Test("Uses the authenticated market when no override is requested")
    func defaultMarket() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.url?.query == "mr=US")
            return StubbedHTTPResponse(json: #"{"results":[]}"#)
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )

        _ = try await client.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "en-US", market: nil),
            account: makeAccount()
        )
    }

    @Test("Page limit fails closed")
    func pageLimit() async throws {
        let pagePolicy = try XboxCloudCatalogPolicy(
            maximumPageCount: 1,
            maximumItemCount: 10,
            maximumPageResponseSize: 4096
        )
        let pageTransport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                json: #"{"results":[],"continuationToken":{"token":"more"}}"#
            )
        }
        let pageClient = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: pageTransport,
            policy: pagePolicy,
            now: { fixedDate }
        )

        await #expect(throws: XboxCloudCatalogError.pageLimitExceeded(1)) {
            _ = try await pageClient.fetchCatalog(
                XboxCatalogRequest(localeIdentifier: "en-US", market: nil),
                account: makeAccount()
            )
        }
    }

    @Test("Unique products are truncated deterministically after route merging")
    func uniqueProductTruncation() async throws {
        let itemPolicy = try XboxCloudCatalogPolicy(
            maximumPageCount: 2,
            maximumItemCount: 2,
            maximumPageResponseSize: 16384
        )
        let itemTransport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: Self.truncatedCatalogJSON)
        }
        let itemClient = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: itemTransport,
            policy: itemPolicy,
            now: { fixedDate }
        )

        let snapshot = try await itemClient.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "en-US", market: nil),
            account: makeAccount()
        )

        #expect(snapshot.items.map(\.id) == ["product-a", "product-b"])
        #expect(snapshot.items[0].routes == [
            XboxCloudTitleRoute(titleID: "a-standard", accessKind: .standard),
            XboxCloudTitleRoute(titleID: "a-ad", accessKind: .freeWithAds),
        ])
    }

    @Test("More than 512 raw duplicate routes remain a valid bounded catalog")
    func rawRowsAboveRetainedLimitDeduplicate() async throws {
        let results: [[String: Any]] = (0 ... 512).map { index in
            let isStandard = index.isMultiple(of: 2)
            return [
                "titleId": isStandard ? "standard-route" : "ad-route",
                "details": [
                    "productId": "one-product",
                    "name": "One Product",
                    "hasEntitlement": true,
                    "userPrograms": isStandard ? ["OTHER"] : ["FERDINAND"],
                ],
            ]
        }
        let payload = try JSONSerialization.data(withJSONObject: ["results": results])
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: payload)
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )

        let snapshot = try await client.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "en-US", market: nil),
            account: makeAccount()
        )

        #expect(snapshot.items.map(\.id) == ["one-product"])
        #expect(snapshot.items[0].routes == [
            XboxCloudTitleRoute(titleID: "standard-route", accessKind: .standard),
            XboxCloudTitleRoute(titleID: "ad-route", accessKind: .freeWithAds),
        ])
    }

    @Test("Wire result count is bounded independently across pages")
    func wireResultCountBound() async throws {
        let firstPage = try JSONSerialization.data(withJSONObject: [
            "results": Array(repeating: [String: Any](), count: 4096),
            "continuationToken": "more",
        ])
        let secondPage = try JSONSerialization.data(withJSONObject: [
            "results": [[String: Any]()],
        ])
        let transport = RecordingHTTPTransport { _, index in
            switch index {
            case 0:
                StubbedHTTPResponse(data: firstPage)
            case 1:
                StubbedHTTPResponse(data: secondPage)
            default:
                throw TestTransportError.unexpectedRequest("Unexpected page \(index)")
            }
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )

        await #expect(throws: XboxCloudCatalogError.itemLimitExceeded(4096)) {
            _ = try await client.fetchCatalog(
                XboxCatalogRequest(localeIdentifier: "en-US", market: nil),
                account: makeAccount()
            )
        }
    }

    @Test("A single wire page cannot exceed its bounded result count")
    func wirePageResultCountBound() async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "results": Array(repeating: [String: Any](), count: 4097),
        ])
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: payload)
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )

        await #expect(throws: XboxCloudCatalogError.invalidPayload(.titles)) {
            _ = try await client.fetchCatalog(
                XboxCatalogRequest(localeIdentifier: "en-US", market: nil),
                account: makeAccount()
            )
        }
    }

    @Test("Repeated and oversized continuation tokens are rejected")
    func continuationBounds() async throws {
        let repeatingTransport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                json: #"{"results":[],"continuationToken":"same"}"#
            )
        }
        let repeatingClient = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: repeatingTransport,
            now: { fixedDate }
        )

        await #expect(throws: XboxCloudCatalogError.invalidPayload(.titles)) {
            _ = try await repeatingClient.fetchCatalog(
                XboxCatalogRequest(localeIdentifier: "en-US", market: nil),
                account: makeAccount()
            )
        }

        let oversizedToken = String(repeating: "a", count: 4097)
        let oversizedPayload = try JSONSerialization.data(
            withJSONObject: [
                "results": [],
                "continuationToken": oversizedToken,
            ]
        )
        let oversizedTransport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: oversizedPayload)
        }
        let oversizedClient = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: oversizedTransport,
            now: { fixedDate }
        )

        await #expect(throws: XboxCloudCatalogError.invalidPayload(.titles)) {
            _ = try await oversizedClient.fetchCatalog(
                XboxCatalogRequest(localeIdentifier: "en-US", market: nil),
                account: makeAccount()
            )
        }
    }

    @Test("Catalog rejects a non-Xbox region endpoint before sending credentials")
    func rejectsInvalidRegionHost() async throws {
        let untrustedURL = try #require(URL(string: "https://untrusted.example"))
        let session = makeSession(regionBaseURL: untrustedURL)
        let transport = RecordingHTTPTransport { _, _ in
            Issue.record("Transport must not receive credentials for an invalid host")
            return StubbedHTTPResponse()
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: session),
            transport: transport,
            now: { fixedDate }
        )

        await #expect(throws: XboxCloudCatalogError.invalidConfiguration) {
            _ = try await client.fetchCatalog(
                XboxCatalogRequest(localeIdentifier: "en-US", market: nil),
                account: makeAccount()
            )
        }

        #expect(await transport.requests().isEmpty)
    }

    @Test("Cancel synchronously terminates active transport work and is idempotent")
    func cancellation() async throws {
        let started = XboxCloudCatalogStartSignal()
        let transport = RecordingHTTPTransport { _, _ in
            await started.signal()
            try await Task.sleep(for: .seconds(60))
            return StubbedHTTPResponse(json: #"{"results":[]}"#)
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )
        let task = Task {
            try await client.fetchCatalog(
                XboxCatalogRequest(localeIdentifier: "en-US", market: nil),
                account: makeAccount()
            )
        }
        await started.wait()

        client.cancel()
        client.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("Cancellation during Fresno enrichment cannot return a partial snapshot")
    func fresnoEnrichmentCancellation() async throws {
        let started = XboxCloudCatalogStartSignal()
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: #"{"results":[]}"#)
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            fresnoDiscovery: BlockingXboxFresnoDiscoveryStub(started: started),
            transport: transport,
            now: { fixedDate }
        )
        let task = Task {
            try await client.fetchCatalog(
                XboxCatalogRequest(localeIdentifier: "en-US", market: nil),
                account: makeAccount()
            )
        }
        await started.wait()

        client.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("HTTP errors retain only a sanitized code and redact all credentials")
    func errorsAreRedacted() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                statusCode: 403,
                json: #"{"code":"NoEntitlement","message":"fixture-gs-secret","token":"response-secret"}"#
            )
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )

        do {
            _ = try await client.fetchCatalog(
                XboxCatalogRequest(localeIdentifier: "en-US", market: nil),
                account: makeAccount()
            )
            Issue.record("Expected title enumeration to fail")
        } catch {
            #expect((error as? XboxCloudCatalogError) == .httpFailure(
                operation: .titles,
                statusCode: 403,
                serviceCode: "NoEntitlement"
            ))
            #expect(error.localizedDescription.contains("NoEntitlement"))
            #expect(!error.localizedDescription.contains("fixture-gs-secret"))
            #expect(!error.localizedDescription.contains("response-secret"))
        }
    }

    @Test("Response size is bounded before JSON decoding")
    func responseSizeBound() async throws {
        let policy = try XboxCloudCatalogPolicy(
            maximumPageCount: 1,
            maximumItemCount: 1,
            maximumPageResponseSize: 16
        )
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Data(repeating: 0x41, count: 17))
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            policy: policy,
            now: { fixedDate }
        )

        await #expect(throws: XboxCloudCatalogError.responseTooLarge(.titles)) {
            _ = try await client.fetchCatalog(
                XboxCatalogRequest(localeIdentifier: "en-US", market: nil),
                account: makeAccount()
            )
        }
    }

    private func makeSession(
        regionBaseURL: URL = URL(
            string: "https://wus.gssv-play-prod.xboxlive.com"
        )!
    ) -> XboxCloudGSSession {
        let region = XboxCloudGSRegion(
            name: "West US",
            baseURL: regionBaseURL,
            isDefault: true,
            fallbackPriority: -1,
            systemUpdateGroups: ["flight-a"]
        )
        return XboxCloudGSSession(
            gsToken: "fixture-gs-secret",
            offeringID: "xgpuweb",
            market: "US",
            regions: [region],
            defaultRegion: region,
            fallbackRegionNames: [],
            expiresAt: fixedDate.addingTimeInterval(3600)
        )
    }

    private func makeAccount() -> XboxCloudAuthorizedAccount {
        XboxCloudAuthorizedAccount(
            authorizationIdentifier: "fixture-account",
            displayName: "Cloud Player",
            expiresAt: fixedDate.addingTimeInterval(3600)
        )
    }

    private static let firstCatalogPageJSON = #"""
    {
      "results": [
        {
          "titleId": "111",
          "details": {
            "name": "Halo Infinite",
            "hasEntitlement": true,
            "images": [
              {"type": "Tile", "url": "https://images.example/halo-tile.jpg"},
              {"type": "Poster", "url": "https://images.example/halo-poster.jpg"}
            ]
          }
        },
        {
          "titleId": 222,
          "details": {
            "name": "Forza Horizon",
            "hasEntitlement": true,
            "images": [{"type": "Poster", "url": "http://insecure.example/forza.jpg"}]
          }
        },
        {"details": {"name": "Missing ID", "hasEntitlement": true}}
      ],
      "continuationToken": {"token": "next page"}
    }
    """#

    private static let secondCatalogPageJSON = #"""
    {
      "results": [
        {
          "titleId": "333",
          "details": {
            "name": "Sea of Thieves",
            "hasEntitlement": true,
            "imageUrl": "https://images.example/sea.jpg"
          }
        }
      ]
    }
    """#

    private static let accessAwareCatalogJSON = #"""
    {
      "results": [
        {
          "titleId": "standard-title",
          "details": {
            "productId": "product-one",
            "name": "Standard Name",
            "hasEntitlement": true,
            "userPrograms": ["OTHER"]
          }
        },
        {
          "titleId": "ad-title",
          "details": {
            "productId": "product-one",
            "name": "Duplicate Name",
            "hasEntitlement": true,
            "imageUrl": "https://images.example/product-one.jpg",
            "userPrograms": ["FERDINAND"]
          }
        },
        {
          "titleId": "second-ad-title",
          "details": {
            "productId": "product-two",
            "name": "Second Product",
            "hasEntitlement": true,
            "userPrograms": [{"id": "ferdinand"}]
          }
        }
      ]
    }
    """#

    private static let entitlementCatalogJSON = #"""
    {
      "results": [
        {"titleId":"entitled","details":{"name":"Entitled","hasEntitlement":true}},
        {"titleId":"false","details":{"name":"False","hasEntitlement":false}},
        {"titleId":"missing","details":{"name":"Missing"}},
        {"titleId":"numeric","details":{"name":"Numeric","hasEntitlement":1}},
        {"titleId":"string","details":{"name":"String","hasEntitlement":"true"}},
        {"titleId":"null","details":{"name":"Null","hasEntitlement":null}}
      ]
    }
    """#

    private static let remainingGameplayTimeCatalogJSON = #"""
    {
      "results": [
        {"titleId":"missing-time","details":{"name":"Missing","hasEntitlement":true}},
        {"titleId":"null-time","details":{"name":"Null","hasEntitlement":true,"remainingGameplayTimeInSeconds":null}},
        {"titleId":"positive-integer","details":{"name":"Integer","hasEntitlement":true,"remainingGameplayTimeInSeconds":1}},
        {"titleId":"positive-fraction","details":{"name":"Fraction","hasEntitlement":true,"remainingGameplayTimeInSeconds":0.5}},
        {"titleId":"zero","details":{"name":"Zero","hasEntitlement":true,"remainingGameplayTimeInSeconds":0}},
        {"titleId":"negative","details":{"name":"Negative","hasEntitlement":true,"remainingGameplayTimeInSeconds":-1}},
        {"titleId":"boolean","details":{"name":"Boolean","hasEntitlement":true,"remainingGameplayTimeInSeconds":true}},
        {"titleId":"string","details":{"name":"String","hasEntitlement":true,"remainingGameplayTimeInSeconds":"60"}},
        {"titleId":"object","details":{"name":"Object","hasEntitlement":true,"remainingGameplayTimeInSeconds":{}}}
      ]
    }
    """#

    private static let truncatedCatalogJSON = #"""
    {
      "results": [
        {"titleId":"a-standard","details":{"productId":"product-a","name":"A","hasEntitlement":true}},
        {"titleId":"b-standard","details":{"productId":"product-b","name":"B","hasEntitlement":true}},
        {"titleId":"c-standard","details":{"productId":"product-c","name":"C","hasEntitlement":true}},
        {"titleId":"a-ad","details":{"productId":"product-a","name":"A duplicate","hasEntitlement":true,"userPrograms":["FERDINAND"]}}
      ]
    }
    """#

    private static let fresnoHydrationJSON = #"""
    {
      "results": [
        {
          "titleId": "not-entitled-route",
          "details": {
            "productId": "PRODUCT-NOT-ENTITLED",
            "name": "Not Entitled",
            "hasEntitlement": false,
            "userPrograms": ["FERDINAND"]
          }
        },
        {
          "titleId": "mixed-program-route",
          "details": {
            "productId": "PRODUCT-MIXED-PROGRAMS",
            "name": "Mixed Programs",
            "hasEntitlement": true,
            "userPrograms": ["FERDINAND", "OTHER"]
          }
        },
        {
          "titleId": "playable-route",
          "details": {
            "productId": "PRODUCT-PLAYABLE",
            "name": "Playable",
            "hasEntitlement": true,
            "remainingGameplayTimeInSeconds": 3600,
            "userPrograms": ["FERDINAND"]
          }
        }
      ]
    }
    """#

    private static let fresnoMetadataJSON = #"""
    {
      "Products": {
        "PRODUCT-PLAYABLE": {
          "StoreId": "PRODUCT-PLAYABLE",
          "ProductTitle": "Playable Metadata",
          "Image_Poster": {"URL":"//images.example/playable-poster.jpg"}
        },
        "PRODUCT-NOT-ENTITLED": {
          "StoreId": "PRODUCT-NOT-ENTITLED",
          "ProductTitle": "Not Entitled Metadata"
        },
        "PRODUCT-MIXED-PROGRAMS": {
          "StoreId": "PRODUCT-MIXED-PROGRAMS",
          "ProductTitle": "Mixed Programs Metadata",
          "Image_Tile": {"URL":"https://images.example/mixed-tile.jpg"}
        }
      },
      "InvalidIds": []
    }
    """#
}

private nonisolated struct XboxContentAccessProviderStub: XboxContentAccessProviding {
    let snapshot: XboxContentAccessSnapshot

    func fetchContentAccess(
        for _: XboxCloudAuthorizedAccount,
        market _: String,
        offeringID _: String
    ) async throws -> XboxContentAccessSnapshot {
        snapshot
    }
}

private nonisolated struct XboxFresnoDiscoveryStub: XboxFresnoCatalogDiscovering {
    let productIDs: [String]

    func fetchProductIDs(
        market _: String,
        localeIdentifier _: String,
        activeSubscriptionProductIDs _: [String]
    ) async throws -> XboxFresnoCatalogDiscoverySnapshot {
        XboxFresnoCatalogDiscoverySnapshot(
            productIDs: productIDs,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private nonisolated struct BlockingXboxFresnoDiscoveryStub: XboxFresnoCatalogDiscovering {
    let started: XboxCloudCatalogStartSignal

    func fetchProductIDs(
        market _: String,
        localeIdentifier _: String,
        activeSubscriptionProductIDs _: [String]
    ) async throws -> XboxFresnoCatalogDiscoverySnapshot {
        await started.signal()
        try await Task.sleep(for: .seconds(60))
        return XboxFresnoCatalogDiscoverySnapshot(productIDs: [], fetchedAt: Date())
    }
}

private actor XboxCloudGSSessionProviderStub: XboxCloudGSSessionProviding {
    private let storedSession: XboxCloudGSSession
    private var requests = 0

    init(session: XboxCloudGSSession) {
        storedSession = session
    }

    func session(for _: XboxCloudAuthorizedAccount) -> XboxCloudGSSession {
        requests += 1
        return storedSession
    }

    func removeSession(for _: XboxCloudAuthorizedAccount) {}

    func clearSessions() {}

    func requestCount() -> Int {
        requests
    }
}

private actor XboxCloudCatalogStartSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignalled = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
