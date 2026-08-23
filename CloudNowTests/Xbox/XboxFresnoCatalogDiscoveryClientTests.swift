@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox Fresno catalog discovery")
struct XboxFresnoCatalogDiscoveryClientTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Fetches the current stream-with-ads rail and preserves deduplicated order")
    func requestShapeAndOrdering() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")

            let components = try #require(
                request.url.flatMap {
                    URLComponents(url: $0, resolvingAgainstBaseURL: false)
                }
            )
            #expect(components.scheme == "https")
            #expect(components.host == "catalog.gamepass.com")
            #expect(components.path == "/sigls/v3")
            let values = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                }
            )
            #expect(values["market"] == "DE")
            #expect(values["language"] == "en-DE")
            #expect(values["subscriptionContext"] == "CFQ7TTC0K5DJ;CFQ7TTC0KHS0")
            #expect(values["platformContext"] == "Cloud:XGPUWEB")

            #expect(values["id"] == "51f14e5d-bdcb-4e04-b9cb-76e5057702df")
            return StubbedHTTPResponse(
                json: Self.railJSON(ids: ["MAIN", "shared", "SHARED"])
            )
        }
        let client = XboxFresnoCatalogDiscoveryClient(
            transport: transport,
            now: { fixedDate }
        )

        let snapshot = try await client.fetchProductIDs(
            market: "de",
            localeIdentifier: "en_DE",
            activeSubscriptionProductIDs: [
                "cfq7ttc0khs0",
                "CFQ7TTC0K5DJ",
                "cfq7ttc0kgq8",
                "9NQL1Q8CD4D0",
                "cfq7ttc0khs0",
            ]
        )

        #expect(snapshot.productIDs == ["MAIN", "shared"])
        #expect(snapshot.fetchedAt == fixedDate)
        #expect(await transport.requests().count == 1)
    }

    @Test("Uses Microsoft's none sentinel when no supported cloud pass is active")
    func noSupportedSubscriptionContext() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            let components = try #require(
                request.url.flatMap {
                    URLComponents(url: $0, resolvingAgainstBaseURL: false)
                }
            )
            #expect(
                components.queryItems?.first {
                    $0.name == "subscriptionContext"
                }?.value == "none"
            )
            return StubbedHTTPResponse(json: Self.railJSON(ids: []))
        }
        let client = XboxFresnoCatalogDiscoveryClient(
            transport: transport,
            now: { fixedDate }
        )

        let snapshot = try await client.fetchProductIDs(
            market: "US",
            localeIdentifier: "en-US",
            activeSubscriptionProductIDs: []
        )

        #expect(snapshot.productIDs.isEmpty)
    }

    @Test("Rail discovery uses the transport response-size boundary")
    func usesBoundedTransport() async throws {
        let transport = BoundedRecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: Self.railJSON(ids: ["BOUNDED-PRODUCT"]))
        }
        let client = XboxFresnoCatalogDiscoveryClient(
            transport: transport,
            now: { fixedDate }
        )

        let snapshot = try await client.fetchProductIDs(
            market: "US",
            localeIdentifier: "en-US",
            activeSubscriptionProductIDs: []
        )

        #expect(snapshot.productIDs == ["BOUNDED-PRODUCT"])
        #expect(await transport.maximumResponseSizes() == [1_048_576])
        #expect(await transport.unboundedRequestCount() == 0)
    }

    @Test("Malformed, oversized, HTTP, and transport responses fail closed")
    func responseFailures() async {
        let malformed = XboxFresnoCatalogDiscoveryClient(
            transport: RecordingHTTPTransport { _, _ in
                StubbedHTTPResponse(json: #"[{"siglId":"fixture"},{"name":"missing-id"}]"#)
            }
        )
        await #expect(throws: XboxFresnoCatalogDiscoveryError.invalidPayload) {
            _ = try await malformed.fetchProductIDs(
                market: "US",
                localeIdentifier: "en-US",
                activeSubscriptionProductIDs: []
            )
        }

        let oversized = XboxFresnoCatalogDiscoveryClient(
            transport: RecordingHTTPTransport { _, _ in
                StubbedHTTPResponse(data: Data(repeating: 0x41, count: 1_048_577))
            }
        )
        await #expect(throws: XboxFresnoCatalogDiscoveryError.responseTooLarge) {
            _ = try await oversized.fetchProductIDs(
                market: "US",
                localeIdentifier: "en-US",
                activeSubscriptionProductIDs: []
            )
        }

        let http = XboxFresnoCatalogDiscoveryClient(
            transport: RecordingHTTPTransport { _, _ in
                StubbedHTTPResponse(statusCode: 503)
            }
        )
        await #expect(
            throws: XboxFresnoCatalogDiscoveryError.httpFailure(statusCode: 503)
        ) {
            _ = try await http.fetchProductIDs(
                market: "US",
                localeIdentifier: "en-US",
                activeSubscriptionProductIDs: []
            )
        }

        let transportFailure = XboxFresnoCatalogDiscoveryClient(
            transport: RecordingHTTPTransport { _, _ in
                throw TestTransportError.unexpectedRequest("offline")
            }
        )
        await #expect(throws: XboxFresnoCatalogDiscoveryError.transportFailure) {
            _ = try await transportFailure.fetchProductIDs(
                market: "US",
                localeIdentifier: "en-US",
                activeSubscriptionProductIDs: []
            )
        }
    }

    @Test("Rejects unsafe market, locale, and subscription values before transport")
    func requestValidation() async {
        let transport = RecordingHTTPTransport { _, _ in
            Issue.record("Invalid requests must not reach the transport")
            return StubbedHTTPResponse()
        }
        let client = XboxFresnoCatalogDiscoveryClient(transport: transport)

        await #expect(throws: XboxFresnoCatalogDiscoveryError.invalidRequest) {
            _ = try await client.fetchProductIDs(
                market: "US\r\nInjected: true",
                localeIdentifier: "en-US",
                activeSubscriptionProductIDs: []
            )
        }
        await #expect(throws: XboxFresnoCatalogDiscoveryError.invalidRequest) {
            _ = try await client.fetchProductIDs(
                market: "US",
                localeIdentifier: "en-US?bad=true",
                activeSubscriptionProductIDs: []
            )
        }
        await #expect(throws: XboxFresnoCatalogDiscoveryError.invalidRequest) {
            _ = try await client.fetchProductIDs(
                market: "US",
                localeIdentifier: "en-US",
                activeSubscriptionProductIDs: ["bad;product"]
            )
        }

        #expect(await transport.requests().isEmpty)
    }

    private static func railJSON(ids: [String]) -> String {
        let values = [["siglId": "fixture"]] + ids.map { ["id": $0] }
        let data = try? JSONSerialization.data(withJSONObject: values)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
