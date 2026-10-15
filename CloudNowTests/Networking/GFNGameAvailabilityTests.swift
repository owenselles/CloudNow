@testable import CloudNow
import Foundation
import Testing

@Suite("GFN game availability")
struct GFNGameAvailabilityTests {
    @Test("Targeted availability queries preserve per-store status and fetch changed estimates")
    func targetedAvailabilityRefresh() async throws {
        let transport = RecordingHTTPTransport { request, index in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT token")
            let body = try jsonObject(from: request)
            let variables = try #require(body["variables"] as? [String: Any])
            #expect(variables["appIds"] as? [String] == ["game"])
            #expect(variables["vpcId"] as? String == "vpc")
            #expect(variables["locale"] as? String == "en-US")
            let query = try #require(body["query"] as? String)
            #expect(query.contains("GetAppDataQueryForAppId"))
            #expect(query.contains("VariantGfnAutoPatchingMetadata { subType endTime }"))
            #expect(query.contains("VariantGfnManualPatchingMetadata { subType endTime }"))
            #expect(query.contains("VariantGfnMaintenanceMetadata { subType }"))
            let endTime = index == 0 ? "2026-10-15T12:00:00Z" : "2026-10-15T13:00:00.000Z"
            return StubbedHTTPResponse(json: """
            {"data":{"apps":{"items":[{"id":"game","variants":[
                {"id":"steam","gfn":{"status":"PATCHING","stateDetails":{"subType":"PATCHING_AUTO","endTime":"\(endTime)"}}},
                {"id":"epic","gfn":{"status":"AVAILABLE"}},
                {"id":"gog","gfn":{"status":"SERVER_MAINTENANCE","stateDetails":{"subType":"GAME_DEVELOPER_MAINTENANCE"}}}
            ]}]}}}
            """)
        }
        let client = GamesClient(transport: transport, localeCode: { "en-US" })
        let first = try await client.fetchAvailability(token: "token", appId: "game", vpcId: "vpc")
        let second = try await client.fetchAvailability(token: "token", appId: "game", vpcId: "vpc")
        let firstEnd = try #require(first["steam"]?.estimatedEndDate)
        let secondEnd = try #require(second["steam"]?.estimatedEndDate)

        #expect(secondEnd.timeIntervalSince(firstEnd) == 3600)
        #expect(first["steam"]?.isUnavailable == true)
        #expect(first["epic"]?.isUnavailable == false)
        #expect(first["gog"]?.messageKey == "gfn_game_developer_maintenance_description")
        #expect(first["gog"]?.estimatedEndDate == nil)
        #expect(await transport.requests().count == 2)
    }

    @Test("Missing target apps and variants produce no availability", arguments: [
        #"{"data":{"apps":{"items":[]}}}"#,
        #"{"data":{"apps":{"items":[{"id":"other","variants":[]}]}}}"#,
        #"{"data":{"apps":{"items":[{"id":"game"}]}}}"#,
        #"{"data":{"apps":{"items":[{"id":"game","variants":[{"id":"store"}]}]}}}"#,
    ])
    func missingAvailability(json: String) async throws {
        let transport = RecordingHTTPTransport { _, _ in StubbedHTTPResponse(json: json) }
        let result = try await GamesClient(transport: transport)
            .fetchAvailability(token: "token", appId: "game", vpcId: "vpc")
        #expect(result.isEmpty)
    }

    @Test("GraphQL errors do not masquerade as an available game")
    func availabilityGraphQLError() async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: #"{"errors":[{"message":"Unavailable schema"}],"data":null}"#)
        }
        await #expect(throws: GamesError.self) {
            try await GamesClient(transport: transport)
                .fetchAvailability(token: "token", appId: "game", vpcId: "vpc")
        }
    }

    @Test("Malformed or missing optional estimates preserve patching status", arguments: [
        #""not-a-date""#,
        "17",
        "null",
        "{}",
    ])
    func invalidEstimate(endTime: String) throws {
        let data = Data("""
        {"status":"PATCHING","stateDetails":{"subType":"PATCHING_AUTO","endTime":\(endTime)}}
        """.utf8)
        let availability = try JSONDecoder().decode(GFNGameAvailability.self, from: data)
        #expect(availability.isUnavailable)
        #expect(availability.estimatedEndDate == nil)
        #expect(availability.titleKey == "gfn_game_patching")
    }

    @Test("Only recognized patching subtypes use a provider completion time")
    func estimateSemantics() {
        let endTime = "2026-10-15T12:00:00Z"
        let manual = GFNGameAvailability(
            status: "PATCHING",
            stateDetails: .init(subType: "PATCHING_MANUAL_INTERVENTION", endTime: endTime)
        )
        #expect(manual.estimatedEndDate != nil)
        #expect(manual.messageKey == "gfn_game_compatibility_description")
        #expect(manual.isUnavailable)

        let maintenance = GFNGameAvailability(
            status: "SERVER_MAINTENANCE",
            stateDetails: .init(subType: "GFN_DEVELOPER_MAINTENANCE", endTime: endTime)
        )
        #expect(maintenance.isUnavailable)
        #expect(maintenance.estimatedEndDate == nil)
        #expect(maintenance.titleKey == "gfn_game_maintenance")

        let unknown = GFNGameAvailability(
            status: "FUTURE_STATUS",
            stateDetails: .init(subType: "PATCHING_AUTO", endTime: endTime)
        )
        #expect(!unknown.isUnavailable)
        #expect(unknown.titleKey == nil)
        #expect(unknown.messageKey == nil)
        #expect(unknown.estimatedEndDate == nil)
        #expect(GFNGameAvailability(
            status: "PATCHING",
            stateDetails: .init(subType: "FUTURE_SUBTYPE", endTime: endTime)
        ).estimatedEndDate == nil)
    }

    @Test("Game caches omit availability and remain compatible with older variants")
    func transientAvailability() throws {
        let variant = GameVariant(
            id: "steam",
            appStore: "STEAM",
            appId: "123",
            isOwned: true,
            availability: GFNGameAvailability(status: "PATCHING")
        )
        let data = try JSONEncoder().encode(variant)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["availability"] == nil)
        let decoded = try JSONDecoder().decode(GameVariant.self, from: data)
        #expect(decoded.availability == nil)
        #expect(decoded.isOwned)
        let oldData = Data(#"{"id":"steam","appStore":"STEAM"}"#.utf8)
        let oldVariant = try JSONDecoder().decode(GameVariant.self, from: oldData)
        #expect(oldVariant.availability == nil)
        #expect(!oldVariant.isOwned)
    }
}
