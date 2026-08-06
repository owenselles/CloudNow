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
        #expect(
            snapshot.items[0].artworkURL?.absoluteString
                == "https://images-eds-ssl.xboxlive.com/halo-poster.jpg"
        )
        #expect(snapshot.items[1].artworkURL == nil)
        #expect(
            snapshot.items[2].artworkURL?.absoluteString
                == "https://images-eds-ssl.xboxlive.com/sea.jpg"
        )
        #expect(snapshot.items.map(\.routes) == [
            [XboxCloudTitleRoute(titleID: "111", accessKind: .standard)],
            [XboxCloudTitleRoute(titleID: "222", accessKind: .standard)],
            [XboxCloudTitleRoute(titleID: "333", accessKind: .standard)],
        ])
        #expect(await sessionProvider.requestCount() == 1)
        #expect(await transport.requests().count == 2)
    }

    @Test("Catalog parsing accepts only Microsoft and Xbox artwork hosts")
    func catalogArtworkHostAllowlist() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: #"""
            {
              "results": [
                {
                  "titleId": "trusted",
                  "details": {
                    "name": "Trusted",
                    "hasEntitlement": true,
                    "imageUrl": "https://store-images.s-microsoft.com/trusted.jpg"
                  }
                },
                {
                  "titleId": "localhost",
                  "details": {
                    "name": "Localhost",
                    "hasEntitlement": true,
                    "imageUrl": "https://localhost/private.jpg"
                  }
                },
                {
                  "titleId": "loopback",
                  "details": {
                    "name": "Loopback",
                    "hasEntitlement": true,
                    "imageUrl": "https://127.0.0.1/private.jpg"
                  }
                }
              ]
            }
            """#)
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
            "TRUSTED",
            "LOCALHOST",
            "LOOPBACK",
        ])
        #expect(
            snapshot.items[0].artworkURL?.absoluteString
                == "https://store-images.s-microsoft.com/trusted.jpg"
        )
        #expect(snapshot.items[1].artworkURL == nil)
        #expect(snapshot.items[2].artworkURL == nil)
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

        #expect(snapshot.items.map(\.id) == ["PRODUCT-ONE", "PRODUCT-TWO"])
        let merged = try #require(snapshot.items.first)
        #expect(merged.title == "Standard Name")
        #expect(
            merged.artworkURL?.absoluteString
                == "https://images-eds-ssl.xboxlive.com/product-one.jpg"
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

    @Test("Explicit refresh invalidates derived account state")
    func refreshInvalidatesAccountState() async {
        let account = makeAccount()
        let sessionProvider = XboxCloudGSSessionProviderStub(session: makeSession())
        let contentAccessProvider = XboxContentAccessInvalidationProbe()
        let client = XboxCloudCatalogClient(
            sessionProvider: sessionProvider,
            contentAccessProvider: contentAccessProvider,
            transport: RecordingHTTPTransport { _, _ in
                throw TestTransportError.unexpectedRequest(
                    "Refresh must not issue a catalog request"
                )
            },
            now: { fixedDate }
        )

        await client.refreshAccountState(for: account)

        #expect(
            await sessionProvider.removedAccountIdentifiers()
                == [account.authorizationIdentifier]
        )
        #expect(
            await contentAccessProvider.invalidatedAccountIdentifiers()
                == [account.authorizationIdentifier]
        )
    }

    @Test("Hydrates entitled standard routes that omit inline display metadata")
    func hydratesProductionShapedStandardRoutes() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            switch request.url?.host {
            case "wus.gssv-play-prod.xboxlive.com":
                #expect(request.httpMethod == "GET")
                return StubbedHTTPResponse(json: #"""
                {
                  "results": [
                    {
                      "titleId": "standard-route",
                      "details": {
                        "productId": "STANDARD-PRODUCT",
                        "hasEntitlement": true
                      }
                    }
                  ]
                }
                """#)
            case "catalog.gamepass.com":
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                #expect(!request.httpShouldHandleCookies)
                let body = try jsonObject(from: request)
                #expect(body["Products"] as? [String] == ["STANDARD-PRODUCT"])
                return StubbedHTTPResponse(json: #"""
                {
                  "Products": {
                    "STANDARD-PRODUCT": {
                      "StoreId": "STANDARD-PRODUCT",
                      "ProductTitle": "Hydrated Standard Game",
                      "Image_Poster": {
                        "URL": "https://store-images.s-microsoft.com/standard-poster.jpg"
                      },
                      "Image_SuperHeroArt": {
                        "URL": "https://store-images.s-microsoft.com/standard-hero.jpg"
                      },
                      "LocalizedCategories": ["Action", "Shooter", "action"],
                      "Categories": ["Fallback category"],
                      "PublisherName": "Xbox Game Studios",
                      "XCloudOfferings": {
                        "xgpuweb": {
                          "SupportedInputTypes": [
                            "Controller",
                            "Touch",
                            "MKB",
                            "Unknown"
                          ]
                        }
                      }
                    }
                  },
                  "InvalidIds": []
                }
                """#)
            default:
                throw TestTransportError.unexpectedRequest(
                    "Unexpected request \(request.url?.absoluteString ?? "nil")"
                )
            }
        }
        let contentAccess = XboxContentAccessSnapshot(
            membershipTier: .ultimate,
            fetchedAt: fixedDate,
            productAccessByProductID: [
                "STANDARD-PRODUCT": XboxProductCloudAccess(
                    userAccessTypes: 1,
                    aggregateAccessTypes: 0,
                    streamingProgram: nil,
                    remainingGameplayTimeInSeconds: nil,
                    maxGameplayTimeInSeconds: nil
                ),
            ]
        )
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            contentAccessProvider: XboxContentAccessProviderStub(snapshot: contentAccess),
            transport: transport,
            now: { fixedDate }
        )

        let snapshot = try await client.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "en-US", market: "US"),
            account: makeAccount()
        )

        let item = try #require(snapshot.items.first)
        #expect(snapshot.items.count == 1)
        #expect(item.id == "STANDARD-PRODUCT")
        #expect(item.title == "Hydrated Standard Game")
        #expect(item.genres == ["Action", "Shooter"])
        #expect(item.publisher == "Xbox Game Studios")
        #expect(
            item.artworkURL?.absoluteString
                == "https://store-images.s-microsoft.com/standard-poster.jpg"
        )
        #expect(
            item.heroArtworkURL?.absoluteString
                == "https://store-images.s-microsoft.com/standard-hero.jpg"
        )
        #expect(item.supportedInputTypes == [.controller, .touch, .mouseAndKeyboard])
        #expect(item.isOwned)
        #expect(item.routes == [
            XboxCloudTitleRoute(titleID: "standard-route", accessKind: .standard),
        ])
        #expect(await transport.requests().count == 2)
    }

    @Test("Rich detail hydration is public, lazy, bounded, and preserves access metadata")
    func hydratesOnePublicRichDetail() async throws {
        let imageValues: [[String: Any]] = [
            [
                "ImagePurpose": "SuperHeroArt",
                "Uri": "//store-images.s-microsoft.com/rich-hero.jpg",
            ],
            [
                "ImagePurpose": "Poster",
                "Uri": "https://store-images.s-microsoft.com/rich-poster.jpg",
            ],
            [
                "ImagePurpose": "Screenshot",
                "Uri": "http://store-images.s-microsoft.com/insecure.jpg",
            ],
            [
                "ImagePurpose": "Screenshot",
                "Uri": "https://store-images.s-microsoft.com/signed.jpg?token=private",
            ],
        ] + (0 ..< 10).map { index in
            [
                "ImagePurpose": "Screenshot",
                "Uri": "https://images-eds-ssl.xboxlive.com/screenshot-\(index).jpg",
            ]
        } + [
            [
                "ImagePurpose": "Screenshot",
                "Uri": "https://images-eds-ssl.xboxlive.com/screenshot-0.jpg",
            ],
        ]
        let response = try JSONSerialization.data(withJSONObject: [
            "Products": [
                [
                    "ProductId": "DECOY-PRODUCT",
                    "LocalizedProperties": [
                        ["ProductDescription": "Wrong product"],
                    ],
                ],
                [
                    "ProductId": "RICH-PRODUCT",
                    "LocalizedProperties": [
                        [
                            "ProductDescription": "A detailed description.\nSecond line.",
                            "DeveloperName": "Cloud Developer",
                            "PublisherName": "Cloud Publisher",
                            "Images": imageValues,
                        ],
                    ],
                    "MarketProperties": [
                        [
                            "MinimumUserAge": 13,
                            "ContentRatings": [
                                [
                                    "RatingSystem": "ESRB",
                                    "RatingId": "ESRB:M",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])
        let transport = RecordingHTTPTransport { request, index in
            #expect(index == 0)
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(!request.httpShouldHandleCookies)
            let url = try #require(request.url)
            let components = try #require(
                URLComponents(url: url, resolvingAgainstBaseURL: false)
            )
            #expect(components.scheme == "https")
            #expect(components.host == "displaycatalog.mp.microsoft.com")
            #expect(components.path == "/v7.0/products")
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                }
            )
            #expect(query["bigIds"] == "RICH-PRODUCT")
            #expect(query["market"] == "DE")
            #expect(query["languages"] == "de-DE")
            #expect(query["MS-CV"]?.hasSuffix(".0") == true)
            #expect(!url.absoluteString.contains("fixture-account"))
            #expect(!url.absoluteString.contains("fixture-gs-secret"))
            return StubbedHTTPResponse(data: response)
        }
        let item = XboxCatalogItem(
            id: "RICH-PRODUCT",
            title: "Rich Game",
            genres: ["Action", "Adventure"],
            publisher: "Base Publisher",
            artworkURL: URL(
                string: "https://store-images.s-microsoft.com/base-poster.jpg"
            ),
            supportedInputTypes: [.controller, .touch],
            isOwned: true,
            routes: [
                XboxCloudTitleRoute(
                    titleID: "rich-route",
                    accessKind: .standard
                ),
            ]
        )
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )

        let hydrated = try await client.fetchDetail(
            for: item,
            request: XboxCatalogRequest(localeIdentifier: "de_DE", market: "DE")
        )

        #expect(hydrated.id == item.id)
        #expect(hydrated.title == item.title)
        #expect(hydrated.longDescription == "A detailed description.\nSecond line.")
        #expect(hydrated.genres == item.genres)
        #expect(hydrated.developer == "Cloud Developer")
        #expect(hydrated.publisher == "Cloud Publisher")
        #expect(hydrated.contentRating == "ESRB M")
        #expect(hydrated.artworkURL == item.artworkURL)
        #expect(
            hydrated.heroArtworkURL?.absoluteString
                == "https://store-images.s-microsoft.com/rich-hero.jpg"
        )
        #expect(hydrated.screenshotURLs.count == 8)
        #expect(hydrated.screenshotURLs.map(\.absoluteString) == (0 ..< 8).map {
            "https://images-eds-ssl.xboxlive.com/screenshot-\($0).jpg"
        })
        #expect(hydrated.supportedInputTypes == item.supportedInputTypes)
        #expect(hydrated.isOwned)
        #expect(hydrated.routes == item.routes)
        #expect(await transport.requests().count == 1)
    }

    @Test("Rich detail accepts only Microsoft and Xbox artwork hosts")
    func richDetailArtworkHostAllowlist() async throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "Products": [
                [
                    "ProductId": "TRUSTED-ARTWORK",
                    "LocalizedProperties": [
                        [
                            "Images": [
                                [
                                    "ImagePurpose": "SuperHeroArt",
                                    "Uri": "//store-images.s-microsoft.com/hero.jpg",
                                ],
                                [
                                    "ImagePurpose": "Poster",
                                    "Uri": "https://assets.xboxservices.com/poster.jpg",
                                ],
                                [
                                    "ImagePurpose": "Screenshot",
                                    "Uri": "https://images-eds-ssl.xboxlive.com/one.jpg",
                                ],
                                [
                                    "ImagePurpose": "Screenshot",
                                    "Uri": "https://store-images.s-microsoft.com/two.jpg",
                                ],
                                [
                                    "ImagePurpose": "Screenshot",
                                    "Uri": "https://microsoft.com.attacker.example/spoofed.jpg",
                                ],
                                [
                                    "ImagePurpose": "Screenshot",
                                    "Uri": "https://evil-s-microsoft.com/lookalike.jpg",
                                ],
                                [
                                    "ImagePurpose": "Screenshot",
                                    "Uri": "https://127.0.0.1/loopback.jpg",
                                ],
                                [
                                    "ImagePurpose": "Screenshot",
                                    "Uri": "https://10.0.0.1/private.jpg",
                                ],
                                [
                                    "ImagePurpose": "Screenshot",
                                    "Uri": "https://localhost/local.jpg",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: response)
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )
        let item = XboxCatalogItem(
            id: "TRUSTED-ARTWORK",
            title: "Trusted Artwork",
            artworkURL: nil
        )

        let hydrated = try await client.fetchDetail(
            for: item,
            request: XboxCatalogRequest(localeIdentifier: "en-US", market: "US")
        )

        #expect(
            hydrated.artworkURL?.absoluteString
                == "https://assets.xboxservices.com/poster.jpg"
        )
        #expect(
            hydrated.heroArtworkURL?.absoluteString
                == "https://store-images.s-microsoft.com/hero.jpg"
        )
        #expect(hydrated.screenshotURLs.map(\.absoluteString) == [
            "https://images-eds-ssl.xboxlive.com/one.jpg",
            "https://store-images.s-microsoft.com/two.jpg",
        ])
    }

    @Test("Rich detail rejects an unrequested product document")
    func rejectsMismatchedDetailProduct() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: #"""
            {
              "Products": [
                {
                  "ProductId": "OTHER-PRODUCT",
                  "LocalizedProperties": []
                }
              ]
            }
            """#)
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )
        let item = XboxCatalogItem(
            id: "EXPECTED-PRODUCT",
            title: "Expected",
            artworkURL: nil
        )

        await #expect(throws: XboxCloudCatalogError.invalidPayload(.metadata)) {
            _ = try await client.fetchDetail(
                for: item,
                request: XboxCatalogRequest(localeIdentifier: "en-US", market: "US")
            )
        }
    }

    @Test("Rich detail validates its public URL before transport")
    func rejectsUnsafeDetailProductID() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            Issue.record("An invalid public detail URL must not reach transport")
            return StubbedHTTPResponse()
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )
        let item = XboxCatalogItem(
            id: "unsafe/product?id=secret",
            title: "Unsafe",
            artworkURL: nil
        )

        await #expect(throws: XboxCloudCatalogError.invalidConfiguration) {
            _ = try await client.fetchDetail(
                for: item,
                request: XboxCatalogRequest(localeIdentifier: "en-US", market: "US")
            )
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test("Rich detail bounds the response before decoding")
    func richDetailResponseSizeBound() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Data(repeating: 0x41, count: 4 * 1024 * 1024 + 1))
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )
        let item = XboxCatalogItem(
            id: "BOUNDED-PRODUCT",
            title: "Bounded",
            artworkURL: nil
        )

        await #expect(throws: XboxCloudCatalogError.responseTooLarge(.metadata)) {
            _ = try await client.fetchDetail(
                for: item,
                request: XboxCatalogRequest(localeIdentifier: "en-US", market: "US")
            )
        }
    }

    @Test("Rich detail uses the transport response-size boundary")
    func richDetailUsesBoundedTransport() async throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "Products": [
                [
                    "ProductId": "BOUNDED-TRANSPORT",
                    "LocalizedProperties": [],
                ],
            ],
        ])
        let transport = BoundedRecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: response)
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )
        let item = XboxCatalogItem(
            id: "BOUNDED-TRANSPORT",
            title: "Bounded Transport",
            artworkURL: nil
        )

        _ = try await client.fetchDetail(
            for: item,
            request: XboxCatalogRequest(localeIdentifier: "en-US", market: "US")
        )

        #expect(await transport.maximumResponseSizes() == [4 * 1024 * 1024])
        #expect(await transport.unboundedRequestCount() == 0)
    }

    @Test("Catalog and Fresno hydration use transport response-size boundaries")
    func catalogAndFresnoUseBoundedTransport() async throws {
        let transport = BoundedRecordingHTTPTransport { request, _ in
            if request.httpMethod == "GET" {
                return StubbedHTTPResponse(json: #"{"results":[]}"#)
            }
            switch request.url?.host {
            case "wus.gssv-play-prod.xboxlive.com":
                return StubbedHTTPResponse(json: #"{"results":[]}"#)
            case "catalog.gamepass.com":
                return StubbedHTTPResponse(json: #"{"Products":{},"InvalidIds":[]}"#)
            default:
                throw TestTransportError.unexpectedRequest(
                    "Unexpected bounded request \(request.url?.absoluteString ?? "nil")"
                )
            }
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            fresnoDiscovery: XboxFresnoDiscoveryStub(productIDs: ["FRESNO-PRODUCT"]),
            transport: transport,
            now: { fixedDate }
        )

        _ = try await client.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "en-US", market: "US"),
            account: makeAccount()
        )

        let requests = await transport.requests()
        let maximumResponseSizes = await transport.maximumResponseSizes()
        #expect(requests.count == 3)
        #expect(maximumResponseSizes.count == 3)
        #expect(await transport.unboundedRequestCount() == 0)
        for (request, maximumResponseSize) in zip(requests, maximumResponseSizes) {
            switch (request.httpMethod, request.url?.host) {
            case ("GET", "wus.gssv-play-prod.xboxlive.com"),
                 ("POST", "wus.gssv-play-prod.xboxlive.com"):
                #expect(maximumResponseSize == 2_097_152)
            case ("POST", "catalog.gamepass.com"):
                #expect(maximumResponseSize == 2_097_152)
            default:
                Issue.record(
                    "Unexpected bounded request \(request.url?.absoluteString ?? "nil")"
                )
            }
        }
    }

    @Test("Catalog metadata maps transport response overflow")
    func catalogMetadataResponseSizeBound() async throws {
        let transport = BoundedRecordingHTTPTransport { request, _ in
            if request.httpMethod == "GET" {
                return StubbedHTTPResponse(json: #"""
                {
                  "results": [
                    {
                      "titleId": "bounded-metadata-title",
                      "details": {
                        "productId": "BOUNDED-METADATA-PRODUCT",
                        "hasEntitlement": true
                      }
                    }
                  ]
                }
                """#)
            }
            return StubbedHTTPResponse(
                data: Data(repeating: 0x41, count: 2_097_153)
            )
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )

        await #expect(throws: XboxCloudCatalogError.responseTooLarge(.metadata)) {
            _ = try await client.fetchCatalog(
                XboxCatalogRequest(localeIdentifier: "en-US", market: "US"),
                account: makeAccount()
            )
        }
        #expect(await transport.maximumResponseSizes() == [2_097_152, 2_097_152])
        #expect(await transport.unboundedRequestCount() == 0)
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
                == "https://store-images.s-microsoft.com/playable-poster.jpg"
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

    @Test("Top-level metadata batches fail atomically after mixed results")
    func topLevelMetadataBatchFailureIsAtomic() async throws {
        let productIDs = (0 ..< 401).map { "STANDARD-PRODUCT-\($0)" }
        let catalogData = try JSONSerialization.data(withJSONObject: [
            "results": productIDs.enumerated().map { index, productID in
                var details: [String: Any] = [
                    "productId": productID,
                    "hasEntitlement": true,
                ]
                if index > 0 {
                    details["name"] = "Inline Game \(index)"
                }
                return [
                    "titleId": "standard-title-\(index)",
                    "details": details,
                ]
            },
        ])
        let firstBatchData = try JSONSerialization.data(withJSONObject: [
            "Products": [
                productIDs[0]: [
                    "StoreId": productIDs[0],
                    "ProductTitle": "Hydrated First Game",
                ],
            ],
            "InvalidIds": [],
        ])
        let transport = RecordingHTTPTransport { request, _ in
            if request.httpMethod == "GET" {
                return StubbedHTTPResponse(data: catalogData)
            }
            let body = try jsonObject(from: request)
            let requestedProductIDs = try #require(body["Products"] as? [String])
            switch requestedProductIDs.count {
            case 400:
                #expect(requestedProductIDs == Array(productIDs.prefix(400)))
                return StubbedHTTPResponse(data: firstBatchData)
            case 1:
                #expect(requestedProductIDs == [productIDs[400]])
                return StubbedHTTPResponse(
                    statusCode: 503,
                    json: #"{"code":"SecondBatchFailed"}"#
                )
            default:
                throw TestTransportError.unexpectedRequest(
                    "Unexpected metadata batch size \(requestedProductIDs.count)"
                )
            }
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )

        await #expect(throws: XboxCloudCatalogError.httpFailure(
            operation: .metadata,
            statusCode: 503,
            serviceCode: "SecondBatchFailed"
        )) {
            _ = try await client.fetchCatalog(
                XboxCatalogRequest(localeIdentifier: "en-US", market: "US"),
                account: makeAccount()
            )
        }
        #expect(await transport.requests().count == 3)
    }

    @Test("Fallback metadata batches fail atomically after mixed results")
    func fallbackMetadataBatchFailureIsAtomic() async throws {
        let productIDs = (0 ..< 201).map { "STANDARD-PRODUCT-\($0)" }
        let catalogData = try JSONSerialization.data(withJSONObject: [
            "results": productIDs.enumerated().map { index, productID in
                var details: [String: Any] = [
                    "productId": productID,
                    "hasEntitlement": true,
                ]
                if index > 0 {
                    details["name"] = "Inline Game \(index)"
                }
                return [
                    "titleId": "standard-title-\(index)",
                    "details": details,
                ]
            },
        ])
        let firstBatchData = try JSONSerialization.data(withJSONObject: [
            "Products": [
                productIDs[0]: [
                    "StoreId": productIDs[0],
                    "ProductTitle": "Hydrated First Game",
                ],
            ],
            "InvalidIds": [],
        ])
        let transport = RecordingHTTPTransport { request, _ in
            if request.httpMethod == "GET" {
                return StubbedHTTPResponse(data: catalogData)
            }
            let body = try jsonObject(from: request)
            let requestedProductIDs = try #require(body["Products"] as? [String])
            switch requestedProductIDs.count {
            case 201:
                return StubbedHTTPResponse(
                    statusCode: 413,
                    json: #"{"code":"TooLarge"}"#
                )
            case 200:
                #expect(requestedProductIDs == Array(productIDs.prefix(200)))
                return StubbedHTTPResponse(data: firstBatchData)
            case 1:
                #expect(requestedProductIDs == [productIDs[200]])
                return StubbedHTTPResponse(
                    statusCode: 503,
                    json: #"{"code":"FallbackBatchFailed"}"#
                )
            default:
                throw TestTransportError.unexpectedRequest(
                    "Unexpected metadata batch size \(requestedProductIDs.count)"
                )
            }
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )

        await #expect(throws: XboxCloudCatalogError.httpFailure(
            operation: .metadata,
            statusCode: 503,
            serviceCode: "FallbackBatchFailed"
        )) {
            _ = try await client.fetchCatalog(
                XboxCatalogRequest(localeIdentifier: "en-US", market: "US"),
                account: makeAccount()
            )
        }
        #expect(await transport.requests().count == 4)
    }

    @Test("Standard metadata hydration is bounded before preserving routes")
    func standardMetadataHydrationIsPrebounded() async throws {
        let policy = try XboxCloudCatalogPolicy(
            maximumPageCount: 1,
            maximumItemCount: 2,
            maximumPageResponseSize: 2_097_152
        )
        let transport = RecordingHTTPTransport { request, _ in
            if request.httpMethod == "GET" {
                return StubbedHTTPResponse(json: #"""
                {
                  "results": [
                    {
                      "titleId": "standard-a",
                      "details": {
                        "productId": "PRODUCT-A",
                        "name": "Game A",
                        "hasEntitlement": true
                      }
                    },
                    {
                      "titleId": "standard-b",
                      "details": {
                        "productId": "PRODUCT-B",
                        "name": "Game B",
                        "hasEntitlement": true
                      }
                    },
                    {
                      "titleId": "standard-c",
                      "details": {
                        "productId": "PRODUCT-C",
                        "name": "Game C",
                        "hasEntitlement": true
                      }
                    },
                    {
                      "titleId": "free-a",
                      "details": {
                        "productId": "PRODUCT-A",
                        "name": "Game A duplicate",
                        "hasEntitlement": true,
                        "userPrograms": ["FERDINAND"]
                      }
                    }
                  ]
                }
                """#)
            }
            let body = try jsonObject(from: request)
            #expect(body["Products"] as? [String] == [
                "PRODUCT-A",
                "PRODUCT-B",
            ])
            return StubbedHTTPResponse(json: #"{"Products":{},"InvalidIds":[]}"#)
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            policy: policy,
            now: { fixedDate }
        )

        let snapshot = try await client.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "en-US", market: "US"),
            account: makeAccount()
        )

        #expect(snapshot.items.map(\.id) == ["PRODUCT-A", "PRODUCT-B"])
        #expect(snapshot.items[0].routes == [
            XboxCloudTitleRoute(titleID: "standard-a", accessKind: .standard),
            XboxCloudTitleRoute(titleID: "free-a", accessKind: .freeWithAds),
        ])
        #expect(await transport.requests().count == 2)
    }

    @Test("Product identity is case-insensitive before capping and route merging")
    func productIdentityCaseNormalization() async throws {
        let policy = try XboxCloudCatalogPolicy(
            maximumPageCount: 1,
            maximumItemCount: 2,
            maximumPageResponseSize: 2_097_152
        )
        let transport = RecordingHTTPTransport { request, _ in
            if request.httpMethod == "GET" {
                return StubbedHTTPResponse(json: #"""
                {
                  "results": [
                    {
                      "titleId": "route-a-standard",
                      "details": {
                        "productId": "product-a",
                        "name": "Game A",
                        "hasEntitlement": true
                      }
                    },
                    {
                      "titleId": "route-a-ads",
                      "details": {
                        "productId": "PRODUCT-A",
                        "name": "Game A duplicate",
                        "hasEntitlement": true,
                        "userPrograms": ["FERDINAND"]
                      }
                    },
                    {
                      "titleId": "route-b-standard",
                      "details": {
                        "productId": "Product-B",
                        "name": "Game B",
                        "hasEntitlement": true
                      }
                    }
                  ]
                }
                """#)
            }
            let body = try jsonObject(from: request)
            #expect(body["Products"] as? [String] == [
                "product-a",
                "Product-B",
            ])
            return StubbedHTTPResponse(json: #"{"Products":{},"InvalidIds":[]}"#)
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            policy: policy,
            now: { fixedDate }
        )

        let snapshot = try await client.fetchCatalog(
            XboxCatalogRequest(localeIdentifier: "en-US", market: "US"),
            account: makeAccount()
        )

        #expect(snapshot.items.map(\.id) == ["PRODUCT-A", "PRODUCT-B"])
        #expect(snapshot.items[0].title == "Game A")
        #expect(snapshot.items[0].routes == [
            XboxCloudTitleRoute(titleID: "route-a-standard", accessKind: .standard),
            XboxCloudTitleRoute(titleID: "route-a-ads", accessKind: .freeWithAds),
        ])
        #expect(snapshot.items[1].routes == [
            XboxCloudTitleRoute(titleID: "route-b-standard", accessKind: .standard),
        ])
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

        #expect(snapshot.items.map(\.id) == ["NORMALIZED", "NEAR-MATCH"])
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

        #expect(snapshot.items.map(\.id) == ["ENTITLED"])
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
            "MISSING-TIME",
            "NULL-TIME",
            "POSITIVE-INTEGER",
            "POSITIVE-FRACTION",
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

        #expect(snapshot.items.map(\.id) == ["PRODUCT-A", "PRODUCT-B"])
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

        #expect(snapshot.items.map(\.id) == ["ONE-PRODUCT"])
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

    @Test("Cancel synchronously terminates an active detail request")
    func detailCancellation() async throws {
        let started = XboxCloudCatalogStartSignal()
        let transport = RecordingHTTPTransport { _, _ in
            await started.signal()
            try await Task.sleep(for: .seconds(60))
            return StubbedHTTPResponse()
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )
        let item = XboxCatalogItem(
            id: "CANCEL-DETAIL",
            title: "Cancel Detail",
            artworkURL: nil
        )
        let task = Task {
            try await client.fetchDetail(
                for: item,
                request: XboxCatalogRequest(localeIdentifier: "en-US", market: "US")
            )
        }
        await started.wait()

        client.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("Catalog and detail requests do not cancel each other")
    func concurrentCatalogAndDetailRequests() async throws {
        let catalogStarted = XboxCloudCatalogStartSignal()
        let catalogGate = XboxCloudCatalogResponseGate()
        let transport = RecordingHTTPTransport { request, _ in
            switch request.url?.host {
            case "wus.gssv-play-prod.xboxlive.com":
                await catalogStarted.signal()
                await catalogGate.wait()
                return StubbedHTTPResponse(json: #"{"results":[]}"#)
            case "displaycatalog.mp.microsoft.com":
                return StubbedHTTPResponse(json: #"""
                {
                  "Products": [
                    {
                      "ProductId": "CONCURRENT-DETAIL",
                      "LocalizedProperties": []
                    }
                  ]
                }
                """#)
            default:
                throw TestTransportError.unexpectedRequest(
                    "Unexpected request \(request.url?.absoluteString ?? "nil")"
                )
            }
        }
        let client = XboxCloudCatalogClient(
            sessionProvider: XboxCloudGSSessionProviderStub(session: makeSession()),
            transport: transport,
            now: { fixedDate }
        )
        let catalogTask = Task {
            try await client.fetchCatalog(
                XboxCatalogRequest(localeIdentifier: "en-US", market: "US"),
                account: makeAccount()
            )
        }
        await catalogStarted.wait()

        do {
            let detail = try await client.fetchDetail(
                for: XboxCatalogItem(
                    id: "CONCURRENT-DETAIL",
                    title: "Concurrent Detail",
                    artworkURL: nil
                ),
                request: XboxCatalogRequest(
                    localeIdentifier: "en-US",
                    market: "US"
                )
            )
            #expect(detail.id == "CONCURRENT-DETAIL")
            await catalogGate.release()
            let snapshot = try await catalogTask.value
            #expect(snapshot.items.isEmpty)
        } catch {
            await catalogGate.release()
            catalogTask.cancel()
            _ = try? await catalogTask.value
            throw error
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
              {"type": "Tile", "url": "https://images-eds-ssl.xboxlive.com/halo-tile.jpg"},
              {"type": "Poster", "url": "https://images-eds-ssl.xboxlive.com/halo-poster.jpg"}
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
            "imageUrl": "https://images-eds-ssl.xboxlive.com/sea.jpg"
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
            "imageUrl": "https://images-eds-ssl.xboxlive.com/product-one.jpg",
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
          "Image_Poster": {"URL":"//store-images.s-microsoft.com/playable-poster.jpg"}
        },
        "PRODUCT-NOT-ENTITLED": {
          "StoreId": "PRODUCT-NOT-ENTITLED",
          "ProductTitle": "Not Entitled Metadata"
        },
        "PRODUCT-MIXED-PROGRAMS": {
          "StoreId": "PRODUCT-MIXED-PROGRAMS",
          "ProductTitle": "Mixed Programs Metadata",
          "Image_Tile": {"URL":"https://store-images.s-microsoft.com/mixed-tile.jpg"}
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

private actor XboxContentAccessInvalidationProbe: XboxContentAccessProviding {
    private var invalidatedAccounts: [String] = []

    func fetchContentAccess(
        for _: XboxCloudAuthorizedAccount,
        market _: String,
        offeringID _: String
    ) throws -> XboxContentAccessSnapshot {
        throw XboxContentAccessError.transportFailure
    }

    func invalidateContentAccess(
        for account: XboxCloudAuthorizedAccount
    ) {
        invalidatedAccounts.append(account.authorizationIdentifier)
    }

    func invalidatedAccountIdentifiers() -> [String] {
        invalidatedAccounts
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
    private var removedAccounts: [String] = []

    init(session: XboxCloudGSSession) {
        storedSession = session
    }

    func session(for _: XboxCloudAuthorizedAccount) -> XboxCloudGSSession {
        requests += 1
        return storedSession
    }

    func removeSession(for account: XboxCloudAuthorizedAccount) {
        removedAccounts.append(account.authorizationIdentifier)
    }

    func clearSessions() {}

    func requestCount() -> Int {
        requests
    }

    func removedAccountIdentifiers() -> [String] {
        removedAccounts
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

private actor XboxCloudCatalogResponseGate {
    private var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func release() {
        isReleased = true
        waiter?.resume()
        waiter = nil
    }
}
