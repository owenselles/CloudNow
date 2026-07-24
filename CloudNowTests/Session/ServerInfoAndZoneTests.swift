@testable import CloudNow
import Foundation
import Testing

@Suite("Server information and zone ranking")
@MainActor
struct ServerInfoAndZoneTests {
    @Test("Server information parses regions and normalizes their URLs")
    func serverInfoParsing() throws {
        let info = try ServerInfoClient.parse(
            TestFixture.data("server-info.json", subdirectory: "Server")
        )

        #expect(info.vpcId == "fixture-vpc")
        #expect(info.localRegionName == "EU Central")
        #expect(info.regions == [
            GFNRegion(name: "EU Central", address: "https://eu.example.invalid/"),
            GFNRegion(name: "US West", address: "http://us.example.invalid/base/"),
        ])
    }

    @Test(
        "Malformed server information fails conservatively",
        arguments: [
            Data(),
            Data("[]".utf8),
            Data(#"{"metaData":"not-an-array"}"#.utf8),
        ]
    )
    func malformedServerInfo(data: Data) {
        #expect(throws: (any Error).self) {
            try ServerInfoClient.parse(data)
        }
    }

    @Test("Unlimited ranking chooses the lowest measured ping")
    func unlimitedRankingUsesPingOnly() {
        let zones = [
            makeZone(id: "near", queue: 90, ping: 18),
            makeZone(id: "far", queue: 0, ping: 42),
        ]

        #expect(zones.recommendedZone(isUnlimited: true)?.id == "near")
        #expect(zones.closestZone?.id == "near")
    }

    @Test("Ranking without measurements chooses the shortest queue")
    func unmeasuredRankingUsesQueue() {
        let zones = [
            makeZone(id: "busy", queue: 24, ping: nil),
            makeZone(id: "quiet", queue: 3, ping: nil),
        ]

        #expect(zones.recommendedZone()?.id == "quiet")
        #expect(zones.closestZone == nil)
    }

    @Test("Measured ranking applies the documented 40% ping and 60% queue weighting")
    func weightedRanking() {
        let zones = [
            makeZone(id: "low-ping-busy", queue: 20, ping: 10),
            makeZone(id: "higher-ping-quiet", queue: 2, ping: 25),
            makeZone(id: "balanced", queue: 10, ping: 20),
        ]

        // Scores are 16, 11.2, and 14 respectively.
        #expect(zones.recommendedZone()?.id == "higher-ping-quiet")
    }

    @Test("Measured ranking ties use the zone ID")
    func measuredTieUsesZoneID() {
        let zones = [
            makeZone(id: "zone-z", queue: 10, ping: 20),
            makeZone(id: "zone-a", queue: 10, ping: 20),
        ]

        #expect(zones.recommendedZone()?.id == "zone-a")
    }

    @Test("Unmeasured ranking ties use the zone ID")
    func unmeasuredTieUsesZoneID() {
        let zones = [
            makeZone(id: "zone-z", queue: 10, ping: nil),
            makeZone(id: "zone-a", queue: 10, ping: nil),
        ]

        #expect(zones.recommendedZone()?.id == "zone-a")
    }

    @Test("Closest-zone ties use the zone ID")
    func closestTieUsesZoneID() {
        let zones = [
            makeZone(id: "zone-z", queue: 10, ping: 20),
            makeZone(id: "zone-a", queue: 20, ping: 20),
        ]

        #expect(zones.closestZone?.id == "zone-a")
    }

    @Test("An empty zone list has no recommendation")
    func emptyRanking() {
        let zones: [GFNZone] = []

        #expect(zones.recommendedZone() == nil)
        #expect(zones.closestZone == nil)
    }

    private func makeZone(id: String, queue: Int, ping: Int?) -> GFNZone {
        GFNZone(
            id: id,
            region: "EU",
            countryCode: "DE",
            city: id,
            queuePosition: queue,
            etaMs: nil,
            zoneUrl: "https://\(id).example.invalid/",
            pingMs: ping,
            isMeasuring: ping == nil
        )
    }
}
