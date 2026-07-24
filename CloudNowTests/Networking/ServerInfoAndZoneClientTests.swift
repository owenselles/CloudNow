@testable import CloudNow
import Foundation
import Testing

@Suite("Server-info HTTP client")
@MainActor
struct ServerInfoHTTPClientTests {
    @Test("Fetch constructs identity headers, parses regions, and caches success")
    func fetchAndCache() async throws {
        let fixture = try NetworkingFixture.data("server-info-client.json")
        let fixedUUID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.url?.absoluteString == "https://stream.example.invalid/v2/serverInfo")
            #expect(request.timeoutInterval == 15)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT token")
            #expect(request.value(forHTTPHeaderField: "nv-client-id") == fixedUUID.uuidString)
            #expect(request.value(forHTTPHeaderField: "x-device-id") == "fixture-device")
            return StubbedHTTPResponse(data: fixture)
        }
        let client = ServerInfoClient(
            transport: transport,
            uuid: { fixedUUID },
            deviceId: { "fixture-device" }
        )

        let info = try await client.fetch(baseUrl: "https://stream.example.invalid/", token: "token")

        #expect(info.vpcId == "fixture-vpc")
        #expect(info.localRegionName == "EU Central")
        #expect(info.regions == [
            GFNRegion(name: "EU Central", address: "https://eu.example.invalid/"),
            GFNRegion(name: "US West", address: "https://us.example.invalid/base/"),
        ])
        #expect(client.cached == info)

        let cached = try await client.fetch(baseUrl: "https://stream.example.invalid", token: "new-token")

        #expect(cached == info)
        #expect(await transport.requests().count == 1)
    }

    @Test("HTTP errors do not overwrite a valid cache")
    func failedRefreshPreservesCache() async throws {
        let fixture = try NetworkingFixture.data("server-info-client.json")
        let fixedUUID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let clock = DateStepper(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            step: 61
        )
        let transport = RecordingHTTPTransport { _, index in
            index == 0
                ? StubbedHTTPResponse(data: fixture)
                : StubbedHTTPResponse(statusCode: 503, json: #"{"error":"unavailable"}"#)
        }
        let client = ServerInfoClient(
            transport: transport,
            uuid: { fixedUUID },
            deviceId: { "fixture-device" },
            now: { clock.next() },
            cacheTTL: 60
        )
        let valid = try await client.fetch(baseUrl: "https://stream.example.invalid", token: "token")

        await #expect(throws: URLError.self) {
            _ = try await client.fetch(baseUrl: "https://stream.example.invalid", token: "token")
        }

        #expect(client.cached == valid)
    }

    @Test("An expired cache entry refreshes from the transport")
    func expiredCacheRefreshes() async throws {
        let fixture = try NetworkingFixture.data("server-info-client.json")
        let fixedUUID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let clock = DateStepper(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            step: 61
        )
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: fixture)
        }
        let client = ServerInfoClient(
            transport: transport,
            uuid: { fixedUUID },
            deviceId: { "fixture-device" },
            now: { clock.next() },
            cacheTTL: 60
        )

        _ = try await client.fetch(baseUrl: "https://stream.example.invalid", token: "token")
        _ = try await client.fetch(baseUrl: "https://stream.example.invalid/", token: "token")

        #expect(await transport.requests().count == 2)
    }

    @Test("A fresh cache entry is scoped to its normalized service base URL")
    func cacheIsScopedToServiceBaseURL() async throws {
        let fixture = try NetworkingFixture.data("server-info-client.json")
        let fixedUUID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: fixture)
        }
        let client = ServerInfoClient(
            transport: transport,
            uuid: { fixedUUID },
            deviceId: { "fixture-device" },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        _ = try await client.fetch(baseUrl: "https://one.example.invalid/", token: "token")
        _ = try await client.fetch(baseUrl: "https://two.example.invalid/", token: "token")

        #expect(await transport.requests().map { $0.url?.host } == [
            "one.example.invalid",
            "two.example.invalid",
        ])
    }

    @Test("Cancellation propagates from transport")
    func cancellation() async throws {
        let fixedUUID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let transport = RecordingHTTPTransport { _, _ in throw CancellationError() }
        let client = ServerInfoClient(
            transport: transport,
            uuid: { fixedUUID },
            deviceId: { "fixture-device" }
        )

        await #expect(throws: CancellationError.self) {
            _ = try await client.fetch(
                baseUrl: "https://stream.example.invalid",
                token: "token"
            )
        }
    }
}

@Suite("Dedicated-zone HTTP client")
struct ZoneHTTPClientTests {
    @Test("Queue and mapping responses merge, filter internal zones, and normalize locations")
    func fetchZones() async throws {
        let queue = try NetworkingFixture.data("zones-queue.json")
        let mapping = try NetworkingFixture.data("zones-mapping.json")
        let transport = RecordingHTTPTransport { request, _ in
            switch request.url?.host {
            case "api.printedwaste.com":
                #expect(request.value(forHTTPHeaderField: "User-Agent") == "CloudNow/1.0 tvOS")
                return StubbedHTTPResponse(data: queue)
            case "remote.printedwaste.com":
                return StubbedHTTPResponse(data: mapping)
            default:
                throw TestTransportError.unexpectedRequest(request.url?.absoluteString ?? "(nil)")
            }
        }

        let client = try ZoneClient(
            transport: transport,
            defaults: isolatedDefaults(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let zones = try await client.fetchZones()

        await MainActor.run {
            #expect(zones.map(\.id) == ["NP-NEW-01", "NP-AMS-01"])
            #expect(zones[0].countryCode == "US")
            #expect(zones[0].city == "New City")
            #expect(zones[1].countryCode == "NL")
            #expect(zones[1].city == "Amsterdam")
            let allAreMeasuring = zones.allSatisfy(\.isMeasuring)
            #expect(allAreMeasuring)
        }
        await client.clearCachedRoutingData()
    }

    @Test("Equal queue positions are ordered by stable zone identifier")
    func queueTieOrder() async throws {
        let queue = try NetworkingFixture.data("zones-queue-ties.json")
        let mapping = try NetworkingFixture.data("zones-mapping.json")
        let transport = RecordingHTTPTransport { request, _ in
            if request.url?.host == "api.printedwaste.com" {
                return StubbedHTTPResponse(data: queue)
            }
            if request.url?.host == "remote.printedwaste.com" {
                return StubbedHTTPResponse(data: mapping)
            }
            throw TestTransportError.unexpectedRequest(request.url?.absoluteString ?? "(nil)")
        }
        let client = try ZoneClient(
            transport: transport,
            defaults: isolatedDefaults(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let zones = try await client.fetchZones()

        #expect(zones.map(\.id) == ["NP-AAA-01", "NP-ZZZ-01"])
        await client.clearCachedRoutingData()
    }

    @Test("Measured session RTT persists and takes precedence in a later client")
    func persistedSessionRtt() async throws {
        let queue = try NetworkingFixture.data("zones-queue.json")
        let mapping = try NetworkingFixture.data("zones-mapping.json")
        let suiteName = "CloudNow.ZoneHTTPClientTests.\(UUID().uuidString)"
        let firstDefaults = try defaults(suiteName: suiteName, reset: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let transport = RecordingHTTPTransport { request, _ in
            if request.url?.host == "api.printedwaste.com" {
                return StubbedHTTPResponse(data: queue)
            }
            if request.url?.host == "remote.printedwaste.com" {
                return StubbedHTTPResponse(data: mapping)
            }
            throw TestTransportError.unexpectedRequest(request.url?.absoluteString ?? "(nil)")
        }
        let first = ZoneClient(transport: transport, defaults: firstDefaults, now: { now })
        await first.recordSessionRtt(
            zoneUrl: "https://np-ams-01.cloudmatchbeta.nvidiagrid.net/",
            rttMs: 24.4
        )
        let secondDefaults = try defaults(suiteName: suiteName, reset: false)
        let second = ZoneClient(transport: transport, defaults: secondDefaults, now: { now })

        let zones = try await second.fetchZones()

        await MainActor.run {
            #expect(zones.first { $0.id == "NP-AMS-01" }?.pingMs == 24)
            #expect(zones.first { $0.id == "NP-AMS-01" }?.isMeasuring == true)
        }
        await second.clearCachedRoutingData()
    }

    @Test("HTTP probe uses HEAD and deterministic elapsed time")
    func headProbe() async throws {
        let clock = DateStepper(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            step: 0.010
        )
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.httpMethod == "HEAD")
            #expect(request.timeoutInterval == 5)
            return StubbedHTTPResponse()
        }
        let client = try ZoneClient(
            transport: transport,
            defaults: isolatedDefaults(),
            now: { clock.next() }
        )

        let ping = await client.measurePing(to: "https://np-ams-01.cloudmatchbeta.nvidiagrid.net/")

        #expect(ping == 10)
        #expect(await transport.requests().count == 3)
        await client.clearCachedRoutingData()
    }

    @Test("Failed probes do not poison a later retry")
    func failedProbeDoesNotPoisonRetry() async throws {
        let transport = RecordingHTTPTransport { _, index in
            if index < 3 {
                throw URLError(.timedOut)
            }
            return StubbedHTTPResponse()
        }
        let clock = DateStepper(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            step: 0.010
        )
        let client = try ZoneClient(
            transport: transport,
            defaults: isolatedDefaults(),
            now: { clock.next() }
        )

        #expect(await client.measurePing(to: "https://np-ams-01.cloudmatchbeta.nvidiagrid.net/") == nil)
        #expect(await client.measurePing(to: "https://np-ams-01.cloudmatchbeta.nvidiagrid.net/") == 10)
        #expect(await transport.requests().count == 6)
        await client.clearCachedRoutingData()
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let name = "CloudNow.ZoneHTTPClientTests.\(UUID().uuidString)"
        return try defaults(suiteName: name, reset: true)
    }

    private func defaults(suiteName: String, reset: Bool) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        if reset {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

private final class DateStepper: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    private let step: TimeInterval

    init(start: Date, step: TimeInterval) {
        value = start
        self.step = step
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value = value.addingTimeInterval(step)
        return current
    }
}
