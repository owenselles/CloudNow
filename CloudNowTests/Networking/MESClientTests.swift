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
        #expect(subscription.cloudStorage == nil)
        #expect(subscription.installToPlayAccess == nil)
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

    @Test("Storage add-ons expose the account plan, capacity, and authoritative region")
    func persistentStorage() async throws {
        let subscription = try await fetchSubscription(
            #"""
            {
              "membershipTier": "ULTIMATE",
              "addons": [
                {"type": "PLAYTIME", "subType": "UNLIMITED"},
                {
                  "type": "STORAGE",
                  "subType": "PERMANENT_STORAGE",
                  "status": "OK",
                  "attributes": [
                    {"key": "TOTAL_STORAGE_SIZE_IN_GB", "textValue": "500"},
                    {"key": "USED_STORAGE_SIZE_IN_GB", "textValue": "120"},
                    {"key": "STORAGE_METRO_REGION", "textValue": "EU-NORTHWEST"},
                    {"key": "STORAGE_METRO_REGION_NAME", "textValue": "EU Northwest"}
                  ]
                }
              ]
            }
            """#
        )

        let storage = try #require(subscription.cloudStorage)
        #expect(subscription.installToPlayAccess == true)
        #expect(storage.isPersistent)
        #expect(storage.isUsable)
        #expect(storage.totalGB == 500)
        #expect(storage.usedGB == 120)
        #expect(storage.remainingGB == 380)
        let availableBytes = try #require(storage.availableBytes)
        let expectedBytes: Int64 = 380 * 1_073_741_824
        #expect(availableBytes == expectedBytes)
        #expect(storage.regionCode == "EU-NORTHWEST")
        #expect(storage.regionName == "EU Northwest")
    }

    @Test("Single-session storage capacity is independent of the previous session's usage")
    func singleSessionStorage() async throws {
        let subscription = try await fetchSubscription(
            #"""
            {
              "addons": [{
                "type": "STORAGE",
                "subType": "EPHEMERAL_STORAGE",
                "attributes": [
                  {"key": "TOTAL_STORAGE_SIZE_IN_GB", "textValue": "100"},
                  {"key": "USED_STORAGE_SIZE_IN_GB", "textValue": "80"}
                ]
              }]
            }
            """#
        )

        let storage = try #require(subscription.cloudStorage)
        #expect(subscription.installToPlayAccess == true)
        #expect(storage.kind == .singleSession)
        #expect(storage.isUsable)
        #expect(storage.availableGB == 100)
    }

    @Test("Storage errors preserve entitlement but mark storage unavailable", arguments: [
        "STORAGE_DOES_NOT_EXIST", "STORAGE_IN_ERROR", "UNKNOWN", "FUTURE_STATUS",
    ])
    func storageErrors(status: String) async throws {
        let subscription = try await fetchSubscription(
            """
            {"addons":[{"type":"STORAGE","subType":"PERMANENT_STORAGE","status":"\(status)"}]}
            """
        )

        #expect(subscription.installToPlayAccess == true)
        #expect(subscription.cloudStorage?.isUsable == false)
        #expect(subscription.cloudStorage?.status == status)
    }

    @Test("Paid membership alone does not grant Install-to-Play access")
    func noStorageEntitlement() async throws {
        let subscription = try await fetchSubscription(#"{"membershipTier":"ULTIMATE","addons":[]}"#)

        #expect(subscription.membershipTier == "ULTIMATE")
        #expect(subscription.installToPlayAccess == false)
        #expect(subscription.cloudStorage == nil)
    }

    @Test("Unknown storage plans remain unknown without breaking membership decoding")
    func unknownStoragePlan() async throws {
        let subscription = try await fetchSubscription(
            #"{"membershipTier":"ULTIMATE","addons":[{"type":"STORAGE","subType":"FUTURE_STORAGE","status":"OK"}]}"#
        )

        #expect(subscription.membershipTier == "ULTIMATE")
        #expect(subscription.installToPlayAccess == nil)
        #expect(subscription.cloudStorage?.kind == .unknown)
        #expect(subscription.cloudStorage?.isUsable == false)
    }

    @Test("Invalid capacity remains unknown instead of granting space", arguments: [
        "-1", "invalid", "9999999999999999999999999999999",
    ])
    func invalidStorageCapacity(value: String) async throws {
        let subscription = try await fetchSubscription(
            """
            {"addons":[{"type":"STORAGE","subType":"EPHEMERAL_STORAGE","attributes":[
              {"key":"TOTAL_STORAGE_SIZE_IN_GB","textValue":"\(value)"}
            ]}]}
            """
        )

        #expect(subscription.cloudStorage?.totalGB == nil)
        #expect(subscription.cloudStorage?.availableBytes == nil)
    }

    @Test("Storage capacities handle overuse, missing usage, and conversion overflow")
    func storageCapacityBounds() {
        let overused = GFNCloudStorage(
            kind: .persistent, status: "OK", totalGB: 100, usedGB: 120, regionCode: nil, regionName: nil
        )
        let unknownUsage = GFNCloudStorage(
            kind: .persistent, status: "OK", totalGB: 100, usedGB: nil, regionCode: nil, regionName: nil
        )
        let hugeCapacity = GFNCloudStorage(
            kind: .singleSession, status: "OK", totalGB: Int.max, usedGB: nil, regionCode: nil, regionName: nil
        )

        #expect(overused.availableGB == 0)
        #expect(unknownUsage.availableGB == nil)
        #expect(hugeCapacity.availableBytes == nil)
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

    private func fetchSubscription(_ json: String) async throws -> SubscriptionInfo {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: json)
        }
        return try await MESClient(transport: transport).fetchSubscription(
            token: "fixture-token",
            vpcId: "fixture-vpc",
            userId: "fixture-user"
        )
    }
}
