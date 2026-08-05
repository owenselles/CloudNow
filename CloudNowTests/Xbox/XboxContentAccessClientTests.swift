@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox Content Access membership")
struct XboxContentAccessClientTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Uses the MDollar credential and first-party Content Access request shape")
    func requestShape() async throws {
        let credentialProvider = XboxContentAccessCredentialProviderStub(
            credential: makeCredential()
        )
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.timeoutInterval == 30)
            #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
            #expect(
                request.value(forHTTPHeaderField: "Authorization")
                    == "XBL3.0 x=fixture-user-hash;fixture-content-access-token"
            )
            #expect(request.value(forHTTPHeaderField: "Calling-App-Name") == "CloudNow")
            #expect(request.value(forHTTPHeaderField: "Calling-App-Version") == "1.0")
            #expect(request.value(forHTTPHeaderField: "MS-CV") == "fixture-cv.0")
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")

            let components = try #require(
                request.url.flatMap {
                    URLComponents(url: $0, resolvingAgainstBaseURL: false)
                }
            )
            #expect(components.scheme == "https")
            #expect(components.host == "contentaccess.exp.xboxservices.com")
            #expect(components.path == "/all/v1")
            #expect(Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value)
            }) == [
                "market": "DE",
                "offering": "xgpuwebf2p",
            ])
            return StubbedHTTPResponse(
                data: Self.response(passes: [(Self.pcProductID, 0)])
            )
        }
        let client = makeClient(
            credentialProvider: credentialProvider,
            transport: transport
        )

        let snapshot = try await client.fetchContentAccess(
            for: makeAccount(),
            market: "DE",
            offeringID: "XGPUWEBF2P"
        )

        #expect(snapshot.membershipTier == .pcGamePass)
        #expect(snapshot.activeSubscriptionProductIDs == [Self.pcProductID])
        #expect(snapshot.productAccessByProductID.isEmpty)
        #expect(snapshot.fetchedAt == fixedDate)
        #expect(await credentialProvider.requestedRelyingParties() == [.contentAccess])
    }

    @Test(
        "Maps each active first-party pass product",
        arguments: [
            MembershipFixture(productID: ultimateProductID, tier: .ultimate),
            MembershipFixture(productID: premiumProductID, tier: .premium),
            MembershipFixture(productID: essentialProductID, tier: .essential),
            MembershipFixture(productID: pcProductID, tier: .pcGamePass),
        ]
    )
    func membershipMapping(fixture: MembershipFixture) async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                data: Self.response(passes: [(fixture.productID, 0)])
            )
        }
        let client = makeClient(transport: transport)

        let snapshot = try await client.fetchContentAccess(
            for: makeAccount(),
            market: "US",
            offeringID: "xgpuweb"
        )

        #expect(snapshot.membershipTier == fixture.tier)
        #expect(snapshot.activeSubscriptionProductIDs == [fixture.productID])
    }

    @Test("Uses the current first-party membership precedence")
    func membershipPrecedence() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Self.response(passes: [
                (Self.pcProductID, 0),
                (Self.essentialProductID, 0),
                (Self.premiumProductID, 0),
                (Self.ultimateProductID, 0),
            ]))
        }
        let client = makeClient(transport: transport)

        let snapshot = try await client.fetchContentAccess(
            for: makeAccount(),
            market: "US",
            offeringID: "xgpuweb"
        )

        #expect(snapshot.membershipTier == .ultimate)
    }

    @Test("Expired, revoked, banned, and unknown passes do not become membership")
    func inactivePasses() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Self.response(passes: [
                (Self.ultimateProductID, 1),
                (Self.premiumProductID, 2),
                (Self.essentialProductID, 3),
                ("UNKNOWNPRODUCT", 0),
            ]))
        }
        let client = makeClient(transport: transport)

        let snapshot = try await client.fetchContentAccess(
            for: makeAccount(),
            market: "US",
            offeringID: "xgpuweb"
        )

        #expect(snapshot.membershipTier == nil)
        #expect(snapshot.activeSubscriptionProductIDs == ["UNKNOWNPRODUCT"])
    }

    @Test("Proto3's omitted default status is treated as active")
    func omittedActiveStatus() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                data: Self.responseWithOmittedStatus(productID: Self.essentialProductID)
            )
        }
        let client = makeClient(transport: transport)

        let snapshot = try await client.fetchContentAccess(
            for: makeAccount(),
            market: "US",
            offeringID: "xgpuweb"
        )

        #expect(snapshot.membershipTier == .essential)
        #expect(snapshot.activeSubscriptionProductIDs == [Self.essentialProductID])
    }

    @Test("Returns normalized sorted active subscription product IDs")
    func activeSubscriptionProductIDs() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Self.response(passes: [
                ("z-subscription", 0),
                (Self.pcProductID.lowercased(), 0),
                ("A-subscription", 0),
                ("inactive-subscription", 1),
            ]))
        }
        let client = makeClient(transport: transport)

        let snapshot = try await client.fetchContentAccess(
            for: makeAccount(),
            market: "US",
            offeringID: "xgpuweb"
        )

        #expect(snapshot.membershipTier == .pcGamePass)
        #expect(snapshot.activeSubscriptionProductIDs == [
            "A-SUBSCRIPTION",
            Self.pcProductID,
            "Z-SUBSCRIPTION",
        ])
    }

    @Test("Decodes selected-user product access and Ferdinand gameplay time")
    func productAccess() async throws {
        let productID = "9abc-product"
        let directAccess: UInt64 = 1 | 8_388_608
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Self.response(
                passes: [(Self.pcProductID, 0)],
                products: [
                    ProductAccessFixture(
                        productID: productID,
                        accesses: [
                            ProductUserAccessFixture(
                                puid: "another-puid",
                                userAccessTypes: UInt64(UInt32.max),
                                aggregateAccessTypes: 0
                            ),
                            ProductUserAccessFixture(
                                puid: Self.fixturePUID,
                                userAccessTypes: directAccess,
                                aggregateAccessTypes: 4,
                                streamingProgram: 2,
                                remainingGameplayTimeInSeconds: 37,
                                maxGameplayTimeInSeconds: 3600
                            ),
                        ]
                    ),
                ]
            ))
        }
        let client = makeClient(transport: transport)

        let snapshot = try await client.fetchContentAccess(
            for: makeAccount(),
            market: "US",
            offeringID: "xgpuweb"
        )
        let access = try #require(snapshot.productAccessByProductID[productID.uppercased()])

        #expect(snapshot.productAccessByProductID.count == 1)
        #expect(access.userAccessTypes == UInt32(directAccess))
        #expect(access.aggregateAccessTypes == 4)
        #expect(access.effectiveAccessTypes == UInt32(directAccess) | 4)
        #expect(access.isOwned)
        #expect(access.supportsStreamingFresnoSYOG)
        #expect(access.isFerdinand)
        #expect(access.remainingGameplayTimeInSeconds == 37)
        #expect(access.maxGameplayTimeInSeconds == 3600)
        #expect(access.hasPlayableRemainingTime)
        #expect(!access.isGameplayTimeExhausted)
        #expect(access.hasGameplayTimeLimit)
    }

    @Test("Aggregate-only access cannot authorize owned Fresno streaming")
    func aggregateAccessDoesNotAuthorize() async throws {
        let aggregateAccess: UInt64 = 1 | 8_388_608
        let productID = "aggregate-only"
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Self.response(
                passes: [(Self.pcProductID, 0)],
                products: [
                    ProductAccessFixture(
                        productID: productID,
                        accesses: [
                            ProductUserAccessFixture(
                                puid: Self.fixturePUID,
                                userAccessTypes: 0,
                                aggregateAccessTypes: aggregateAccess,
                                streamingProgram: 2,
                                remainingGameplayTimeInSeconds: 0,
                                maxGameplayTimeInSeconds: 3600
                            ),
                        ]
                    ),
                ]
            ))
        }
        let client = makeClient(transport: transport)

        let snapshot = try await client.fetchContentAccess(
            for: makeAccount(),
            market: "US",
            offeringID: "xgpuweb"
        )
        let access = try #require(snapshot.productAccessByProductID[productID.uppercased()])

        #expect(access.effectiveAccessTypes == UInt32(aggregateAccess))
        #expect(!access.isOwned)
        #expect(!access.supportsStreamingFresnoSYOG)
        #expect(access.isFerdinand)
        #expect(!access.hasPlayableRemainingTime)
        #expect(access.isGameplayTimeExhausted)
    }

    @Test("Ambiguous pass users fail closed without losing membership display")
    func ambiguousPUIDs() async throws {
        let productID = "ambiguous-product"
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Self.response(
                passUsers: [
                    (Self.fixturePUID, [(Self.pcProductID, 0)]),
                    ("second-puid", [(Self.ultimateProductID, 0)]),
                ],
                products: [
                    ProductAccessFixture(
                        productID: productID,
                        accesses: [
                            ProductUserAccessFixture(
                                puid: Self.fixturePUID,
                                userAccessTypes: 1 | 8_388_608,
                                aggregateAccessTypes: 0,
                                streamingProgram: 2,
                                remainingGameplayTimeInSeconds: 60
                            ),
                        ]
                    ),
                ]
            ))
        }
        let client = makeClient(transport: transport)

        let snapshot = try await client.fetchContentAccess(
            for: makeAccount(),
            market: "US",
            offeringID: "xgpuweb"
        )

        #expect(snapshot.membershipTier == .pcGamePass)
        #expect(snapshot.activeSubscriptionProductIDs.isEmpty)
        #expect(snapshot.productAccessByProductID.isEmpty)
    }

    @Test("Skips another user's product access and unknown protobuf fields")
    func skipsUnneededFields() async throws {
        var response = Data()
        response.append(Self.lengthDelimitedField(
            number: 2,
            value: Self.productMapEntry(ProductAccessFixture(
                productID: "not-selected",
                accesses: [
                    ProductUserAccessFixture(
                        puid: "another-puid",
                        userAccessTypes: 1 | 8_388_608,
                        aggregateAccessTypes: 0
                    ),
                ]
            ))
        ))
        response.append(Self.fixed32Field(number: 9, value: 42))
        response.append(Self.response(passes: [(Self.premiumProductID, 0)]))
        response.append(Self.varintField(number: 10, value: 7))
        let fixtureResponse = response
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: fixtureResponse)
        }
        let client = makeClient(transport: transport)

        let snapshot = try await client.fetchContentAccess(
            for: makeAccount(),
            market: "US",
            offeringID: "xgpuweb"
        )

        #expect(snapshot.membershipTier == .premium)
        #expect(snapshot.productAccessByProductID.isEmpty)
    }

    @Test("Malformed and oversized protobuf responses fail closed")
    func payloadBounds() async throws {
        let malformedTransport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Data([0x0A, 0x08, 0x12]))
        }
        let malformedClient = makeClient(transport: malformedTransport)
        await #expect(throws: XboxContentAccessError.invalidPayload) {
            _ = try await malformedClient.fetchContentAccess(
                for: makeAccount(),
                market: "US",
                offeringID: "xgpuweb"
            )
        }

        let oversizedTransport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Data(repeating: 0, count: 17))
        }
        let oversizedClient = makeClient(
            transport: oversizedTransport,
            maximumResponseBytes: 16
        )
        await #expect(throws: XboxContentAccessError.responseTooLarge) {
            _ = try await oversizedClient.fetchContentAccess(
                for: makeAccount(),
                market: "US",
                offeringID: "xgpuweb"
            )
        }
    }

    @Test("Product, access, and subscription maps enforce entry limits")
    func productMapBounds() async throws {
        let excessiveProducts = (0 ... XboxContentAccessSnapshot.maximumProductAccessCount)
            .map { index in
                ProductAccessFixture(productID: "PRODUCT\(index)", accesses: [])
            }
        let productTransport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Self.response(
                passes: [(Self.pcProductID, 0)],
                products: excessiveProducts
            ))
        }
        let productClient = makeClient(transport: productTransport)
        await #expect(throws: XboxContentAccessError.invalidPayload) {
            _ = try await productClient.fetchContentAccess(
                for: makeAccount(),
                market: "US",
                offeringID: "xgpuweb"
            )
        }

        let excessiveAccessEntries = (0 ... XboxContentAccessSnapshot.maximumProductAccessCount)
            .map { index in
                ProductUserAccessFixture(
                    puid: "OTHER\(index)",
                    userAccessTypes: 0,
                    aggregateAccessTypes: 0
                )
            }
        let accessTransport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Self.response(
                passes: [(Self.pcProductID, 0)],
                products: [
                    ProductAccessFixture(
                        productID: "ACCESS-BOUND",
                        accesses: excessiveAccessEntries
                    ),
                ]
            ))
        }
        let accessClient = makeClient(transport: accessTransport)
        await #expect(throws: XboxContentAccessError.invalidPayload) {
            _ = try await accessClient.fetchContentAccess(
                for: makeAccount(),
                market: "US",
                offeringID: "xgpuweb"
            )
        }

        let excessivePasses = (0 ... XboxContentAccessSnapshot.maximumActiveSubscriptionCount)
            .map { index in ("PASS\(index)", UInt64(0)) }
        let passTransport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Self.response(passes: excessivePasses))
        }
        let passClient = makeClient(transport: passTransport)
        await #expect(throws: XboxContentAccessError.invalidPayload) {
            _ = try await passClient.fetchContentAccess(
                for: makeAccount(),
                market: "US",
                offeringID: "xgpuweb"
            )
        }
    }

    @Test("Rejects unsafe identifiers and out-of-range uint32 access flags")
    func productFieldValidation() async throws {
        let unsafeIdentifierTransport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Self.response(
                passes: [(Self.pcProductID, 0)],
                products: [
                    ProductAccessFixture(productID: "BAD\nPRODUCT", accesses: []),
                ]
            ))
        }
        let unsafeIdentifierClient = makeClient(transport: unsafeIdentifierTransport)
        await #expect(throws: XboxContentAccessError.invalidPayload) {
            _ = try await unsafeIdentifierClient.fetchContentAccess(
                for: makeAccount(),
                market: "US",
                offeringID: "xgpuweb"
            )
        }

        let oversizedAccessTransport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Self.response(
                passes: [(Self.pcProductID, 0)],
                products: [
                    ProductAccessFixture(
                        productID: "OVERSIZED-ACCESS",
                        accesses: [
                            ProductUserAccessFixture(
                                puid: Self.fixturePUID,
                                userAccessTypes: UInt64(UInt32.max) + 1,
                                aggregateAccessTypes: 0
                            ),
                        ]
                    ),
                ]
            ))
        }
        let oversizedAccessClient = makeClient(transport: oversizedAccessTransport)
        await #expect(throws: XboxContentAccessError.invalidPayload) {
            _ = try await oversizedAccessClient.fetchContentAccess(
                for: makeAccount(),
                market: "US",
                offeringID: "xgpuweb"
            )
        }
    }

    @Test("Credential, HTTP, and transport failures are typed and redacted")
    func typedFailures() async throws {
        let unavailableClient = makeClient(
            credentialProvider: XboxContentAccessCredentialProviderStub(credential: nil),
            transport: RecordingHTTPTransport { _, _ in
                Issue.record("Transport must not run without a Content Access credential")
                return StubbedHTTPResponse()
            }
        )
        await #expect(throws: XboxContentAccessError.credentialUnavailable) {
            _ = try await unavailableClient.fetchContentAccess(
                for: makeAccount(),
                market: "US",
                offeringID: "xgpuweb"
            )
        }

        let httpClient = makeClient(transport: RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                statusCode: 403,
                json: #"{"token":"response-secret","message":"fixture-content-access-token"}"#
            )
        })
        do {
            _ = try await httpClient.fetchContentAccess(
                for: makeAccount(),
                market: "US",
                offeringID: "xgpuweb"
            )
            Issue.record("Expected Content Access HTTP failure")
        } catch {
            #expect((error as? XboxContentAccessError) == .httpFailure(statusCode: 403))
            #expect(!error.localizedDescription.contains("response-secret"))
            #expect(!error.localizedDescription.contains("fixture-content-access-token"))
        }

        let transportClient = makeClient(transport: RecordingHTTPTransport { _, _ in
            throw TestTransportError.unexpectedRequest("offline")
        })
        await #expect(throws: XboxContentAccessError.transportFailure) {
            _ = try await transportClient.fetchContentAccess(
                for: makeAccount(),
                market: "US",
                offeringID: "xgpuweb"
            )
        }
    }

    @Test("Invalid request inputs are rejected before credentials are requested")
    func requestValidation() async throws {
        let credentialProvider = XboxContentAccessCredentialProviderStub(
            credential: makeCredential()
        )
        let transport = RecordingHTTPTransport { _, _ in
            Issue.record("Transport must not receive an invalid request")
            return StubbedHTTPResponse()
        }
        let client = makeClient(
            credentialProvider: credentialProvider,
            transport: transport
        )

        await #expect(throws: XboxContentAccessError.invalidMarket) {
            _ = try await client.fetchContentAccess(
                for: makeAccount(),
                market: "US\r\nInjected: true",
                offeringID: "xgpuweb"
            )
        }
        await #expect(throws: XboxContentAccessError.unsupportedOffering) {
            _ = try await client.fetchContentAccess(
                for: makeAccount(),
                market: "US",
                offeringID: "takehomeweb"
            )
        }

        #expect(await credentialProvider.requestedRelyingParties().isEmpty)
        #expect(await transport.requests().isEmpty)
    }

    private func makeClient(
        credentialProvider: XboxContentAccessCredentialProviderStub? = nil,
        transport: any HTTPTransport,
        maximumResponseBytes: Int = 8 * 1024 * 1024
    ) -> XboxContentAccessClient {
        XboxContentAccessClient(
            credentialProvider: credentialProvider ?? XboxContentAccessCredentialProviderStub(
                credential: makeCredential()
            ),
            transport: transport,
            maximumResponseBytes: maximumResponseBytes,
            now: { fixedDate },
            makeCorrelationVector: { "fixture-cv.0" }
        )
    }

    private func makeCredential() -> XboxXSTSCredential {
        XboxXSTSCredential(
            token: "fixture-content-access-token",
            userHash: "fixture-user-hash",
            relyingParty: .contentAccess,
            expiresAt: fixedDate.addingTimeInterval(3600),
            gamertag: nil
        )
    }

    private func makeAccount() -> XboxCloudAuthorizedAccount {
        XboxCloudAuthorizedAccount(
            authorizationIdentifier: "fixture-account",
            displayName: nil,
            expiresAt: fixedDate.addingTimeInterval(3600)
        )
    }

    private static let ultimateProductID = "CFQ7TTC0KHS0"
    private static let premiumProductID = "CFQ7TTC0P85B"
    private static let essentialProductID = "CFQ7TTC0K5DJ"
    private static let pcProductID = "CFQ7TTC0KGQ8"
    private static let fixturePUID = "fixture-puid"

    private static func response(
        passes: [(String, UInt64)],
        products: [ProductAccessFixture] = []
    ) -> Data {
        response(passUsers: [(fixturePUID, passes)], products: products)
    }

    private static func response(
        passUsers: [(String, [(String, UInt64)])],
        products: [ProductAccessFixture] = []
    ) -> Data {
        var response = Data()
        for (puid, passes) in passUsers {
            let userPassData = Data(passes.flatMap { productID, status in
                Array(lengthDelimitedField(
                    number: 1,
                    value: passMapEntry(productID: productID, status: status)
                ))
            })
            var mapEntry = Data()
            mapEntry.append(stringField(number: 1, value: puid))
            mapEntry.append(lengthDelimitedField(number: 2, value: userPassData))
            response.append(lengthDelimitedField(number: 1, value: mapEntry))
        }
        for product in products {
            response.append(lengthDelimitedField(
                number: 2,
                value: productMapEntry(product)
            ))
        }
        return response
    }

    private static func responseWithOmittedStatus(productID: String) -> Data {
        let passEntry = passMapEntry(productID: productID, status: nil)
        let userPassData = lengthDelimitedField(number: 1, value: passEntry)
        var mapEntry = Data()
        mapEntry.append(stringField(number: 1, value: fixturePUID))
        mapEntry.append(lengthDelimitedField(number: 2, value: userPassData))
        return lengthDelimitedField(number: 1, value: mapEntry)
    }

    private static func passMapEntry(productID: String, status: UInt64?) -> Data {
        var entry = Data()
        entry.append(stringField(number: 1, value: productID))
        var passData = Data()
        if let status {
            passData.append(varintField(number: 1, value: status))
        }
        passData.append(varintField(number: 4, value: 1))
        entry.append(lengthDelimitedField(number: 2, value: passData))
        return entry
    }

    private static func productMapEntry(_ fixture: ProductAccessFixture) -> Data {
        var productData = Data()
        for access in fixture.accesses {
            productData.append(lengthDelimitedField(
                number: 2,
                value: productUserAccessMapEntry(access)
            ))
        }

        var entry = Data()
        entry.append(stringField(number: 1, value: fixture.productID))
        entry.append(lengthDelimitedField(number: 2, value: productData))
        return entry
    }

    private static func productUserAccessMapEntry(
        _ fixture: ProductUserAccessFixture
    ) -> Data {
        var userAccess = Data()
        userAccess.append(varintField(number: 1, value: fixture.userAccessTypes))
        userAccess.append(varintField(number: 2, value: fixture.aggregateAccessTypes))
        if fixture.streamingProgram != nil
            || fixture.remainingGameplayTimeInSeconds != nil
            || fixture.maxGameplayTimeInSeconds != nil
        {
            var streamingGameplayData = Data()
            if let streamingProgram = fixture.streamingProgram {
                streamingGameplayData.append(varintField(number: 1, value: streamingProgram))
            }
            if let remainingGameplayTimeInSeconds = fixture
                .remainingGameplayTimeInSeconds
            {
                streamingGameplayData.append(varintField(
                    number: 2,
                    value: remainingGameplayTimeInSeconds
                ))
            }
            if let maxGameplayTimeInSeconds = fixture.maxGameplayTimeInSeconds {
                streamingGameplayData.append(varintField(
                    number: 4,
                    value: maxGameplayTimeInSeconds
                ))
            }
            userAccess.append(lengthDelimitedField(
                number: 11,
                value: streamingGameplayData
            ))
        }

        var entry = Data()
        entry.append(stringField(number: 1, value: fixture.puid))
        entry.append(lengthDelimitedField(number: 2, value: userAccess))
        return entry
    }

    private static func stringField(number: Int, value: String) -> Data {
        lengthDelimitedField(number: number, value: Data(value.utf8))
    }

    private static func lengthDelimitedField(number: Int, value: Data) -> Data {
        var data = varint(UInt64(number << 3 | 2))
        data.append(varint(UInt64(value.count)))
        data.append(value)
        return data
    }

    private static func varintField(number: Int, value: UInt64) -> Data {
        var data = varint(UInt64(number << 3))
        data.append(varint(value))
        return data
    }

    private static func fixed32Field(number: Int, value: UInt32) -> Data {
        var data = varint(UInt64(number << 3 | 5))
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    private static func varint(_ value: UInt64) -> Data {
        var remaining = value
        var data = Data()
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            data.append(byte)
        } while remaining != 0
        return data
    }
}

nonisolated struct MembershipFixture: Sendable {
    let productID: String
    let tier: XboxMembershipTier
}

private nonisolated struct ProductAccessFixture: Sendable {
    let productID: String
    let accesses: [ProductUserAccessFixture]
}

private nonisolated struct ProductUserAccessFixture: Sendable {
    let puid: String
    let userAccessTypes: UInt64
    let aggregateAccessTypes: UInt64
    let streamingProgram: UInt64?
    let remainingGameplayTimeInSeconds: UInt64?
    let maxGameplayTimeInSeconds: UInt64?

    init(
        puid: String,
        userAccessTypes: UInt64,
        aggregateAccessTypes: UInt64,
        streamingProgram: UInt64? = nil,
        remainingGameplayTimeInSeconds: UInt64? = nil,
        maxGameplayTimeInSeconds: UInt64? = nil
    ) {
        self.puid = puid
        self.userAccessTypes = userAccessTypes
        self.aggregateAccessTypes = aggregateAccessTypes
        self.streamingProgram = streamingProgram
        self.remainingGameplayTimeInSeconds = remainingGameplayTimeInSeconds
        self.maxGameplayTimeInSeconds = maxGameplayTimeInSeconds
    }
}

private actor XboxContentAccessCredentialProviderStub: XboxXSTSCredentialProviding {
    private let credential: XboxXSTSCredential?
    private var relyingParties: [XboxLiveRelyingParty] = []

    init(credential: XboxXSTSCredential?) {
        self.credential = credential
    }

    func credential(
        for _: XboxCloudAuthorizedAccount,
        relyingParty: XboxLiveRelyingParty
    ) throws -> XboxXSTSCredential {
        relyingParties.append(relyingParty)
        guard let credential else {
            throw XboxLiveAuthorizationError.credentialUnavailable(relyingParty)
        }
        return credential
    }

    func requestedRelyingParties() -> [XboxLiveRelyingParty] {
        relyingParties
    }
}
