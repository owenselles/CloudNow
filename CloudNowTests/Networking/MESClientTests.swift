@testable import CloudNow
import Foundation
import Testing

@Suite("Membership entitlement HTTP client")
struct MESClientTests {
    @Test("Subscription request maps query, headers, tier, and entitled resolutions")
    func subscriptionRequestAndDecoding() async throws {
        let fixture = try NetworkingFixture.data("mes-subscription.json")
        let transport = RecordingHTTPTransport { request, _ in
            let requestURL = try #require(request.url)
            let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT fixture-token")
            #expect(request.value(forHTTPHeaderField: "nv-client-type") == "NATIVE")
            #expect(query["serviceName"] == "gfn_pc")
            #expect(query["vpcId"] == "fixture-vpc")
            #expect(query["userId"] == "fixture-user")
            return StubbedHTTPResponse(data: fixture)
        }

        let subscription = try await MESClient(transport: transport).fetchSubscription(
            token: "fixture-token",
            vpcId: "fixture-vpc",
            userId: "fixture-user"
        )

        #expect(subscription.membershipTier == "ULTIMATE")
        #expect(subscription.isUnlimited)
        #expect(subscription.remainingMinutes == 120)
        #expect(subscription.totalMinutes == 360)
        #expect(subscription.entitledResolutions == [
            EntitledResolution(widthInPixels: 1920, heightInPixels: 1080, framesPerSecond: 60),
        ])
    }

    @Test("Empty VPC uses the conservative known fallback")
    func emptyVpcFallback() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            let requestURL = try #require(request.url)
            let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
            #expect(components.queryItems?.first { $0.name == "vpcId" }?.value == "NP-AMS-08")
            return StubbedHTTPResponse(json: #"{"type":"FREE"}"#)
        }

        let subscription = try await MESClient(transport: transport).fetchSubscription(
            token: "token",
            vpcId: "",
            userId: "user"
        )

        #expect(subscription.membershipTier == "Free")
        #expect(!subscription.isUnlimited)
        #expect(subscription.remainingMinutes == nil)
        #expect(subscription.entitledResolutions.isEmpty)
    }

    @Test("VPC discovery normalizes the base URL and returns optional server ID")
    func vpcDiscovery() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.url?.absoluteString == "https://stream.example.invalid/v2/serverInfo")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT token")
            #expect(request.value(forHTTPHeaderField: "nv-client-streamer") == "WEBRTC")
            return StubbedHTTPResponse(json: #"{"requestStatus":{"serverId":"fixture-vpc"}}"#)
        }

        let vpcId = try await MESClient(transport: transport).fetchVpcId(
            token: "token",
            base: "https://stream.example.invalid/"
        )

        #expect(vpcId == "fixture-vpc")
    }

    @Test("Malformed optional VPC payload falls back to nil")
    func missingVpcId() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: #"{"requestStatus":{}}"#)
        }

        let vpcId = try await MESClient(transport: transport).fetchVpcId(
            token: "token",
            base: "https://stream.example.invalid"
        )

        #expect(vpcId == nil)
    }

    @Test("HTTP failures include status but redact response credentials")
    func httpFailure() async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                statusCode: 401,
                json: #"{"error":"unauthorized","access_token":"do-not-leak"}"#
            )
        }
        let client = MESClient(transport: transport)

        do {
            _ = try await client.fetchSubscription(token: "secret", vpcId: "vpc", userId: "user")
            Issue.record("Expected subscription request to fail")
        } catch {
            #expect(error.localizedDescription.contains("HTTP 401"))
            #expect(error.localizedDescription.contains("unauthorized"))
            #expect(!error.localizedDescription.contains("do-not-leak"))
        }
    }

    @Test("Malformed success JSON surfaces decoding failure")
    func malformedResponse() async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: #"{"features":{"resolutions":"invalid"}}"#)
        }

        await #expect(throws: DecodingError.self) {
            _ = try await MESClient(transport: transport).fetchSubscription(
                token: "token",
                vpcId: "vpc",
                userId: "user"
            )
        }
    }

    @Test("Cancellation reaches the caller unchanged")
    func cancellation() async {
        let transport = RecordingHTTPTransport { _, _ in
            throw CancellationError()
        }

        await #expect(throws: CancellationError.self) {
            _ = try await MESClient(transport: transport).fetchSubscription(
                token: "token",
                vpcId: "vpc",
                userId: "user"
            )
        }
    }
}
