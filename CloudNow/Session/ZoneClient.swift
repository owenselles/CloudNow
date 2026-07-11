import Foundation
import os.log

private let zoneLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "Zones")

// MARK: - Zone Model

struct GFNZone: Identifiable, Equatable {
    let id: String // e.g. "NP-AWS-US-N-Virginia-1"
    let region: String // e.g. "US"
    let regionSuffix: String // e.g. "AWS-N-Virginia-1"
    var queuePosition: Int
    let etaMs: Double?
    let zoneUrl: String
    var pingMs: Int?
    var isMeasuring: Bool

    static let regionMeta: [String: (label: String, flag: String)] = [
        "US": ("North America", "🇺🇸"),
        "EU": ("Europe", "🇪🇺"),
        "JP": ("Japan", "🇯🇵"),
        "KR": ("South Korea", "🇰🇷"),
        "CA": ("Canada", "🇨🇦"),
        "THAI": ("Southeast Asia", "🇹🇭"),
        "MY": ("Malaysia", "🇲🇾"),
    ]
}

// MARK: - ZoneClient

actor ZoneClient {
    static let shared = ZoneClient()

    private struct LatencyRecord: Codable {
        var headPingMs: Double?
        var headMeasuredAt: Date?
        var sessionRttMs: Double?
        var sessionMeasuredAt: Date?
    }

    private struct AutoRouteRecord: Codable {
        let zoneUrl: String
        let selectedAt: Date
    }

    private static let latencyCacheKey = "gfn.zoneLatencyCache"
    private static let autoRouteCacheKey = "gfn.autoRouteCache"
    private static let headPingMaxAge: TimeInterval = 6 * 60 * 60
    private static let sessionRttMaxAge: TimeInterval = 7 * 24 * 60 * 60
    private static let autoRouteMaxAge: TimeInterval = 30 * 60
    private static let prewarmInterval: TimeInterval = 10 * 60

    private var latencyCache: [String: LatencyRecord]
    private var autoRouteCache: [String: AutoRouteRecord]
    private var isPrewarming = false
    private var lastPrewarmAt: Date?

    private init() {
        let defaults = UserDefaults.standard
        latencyCache = defaults.data(forKey: Self.latencyCacheKey)
            .flatMap { try? JSONDecoder().decode([String: LatencyRecord].self, from: $0) } ?? [:]
        autoRouteCache = defaults.data(forKey: Self.autoRouteCacheKey)
            .flatMap { try? JSONDecoder().decode([String: AutoRouteRecord].self, from: $0) } ?? [:]
    }

    // MARK: Public

    /// Fetches available GFN zones and their queue depths.
    func fetchZones() async throws -> [GFNZone] {
        async let queueTask = fetchQueueData()
        async let mappingTask = fetchMappingData()
        let (queueData, mappingData) = try await (queueTask, mappingTask)

        let nukedIds = Set(mappingData.compactMap { id, entry in entry.nuked == true ? id : nil })

        let now = Date()
        return queueData
            .filter { id, _ in id.hasPrefix("NP-") && !id.hasPrefix("NPA-") && !nukedIds.contains(id) }
            .map { zoneId, entry in
                let parts = entry.Region.split(separator: "-", maxSplits: 1).map(String.init)
                let url = zoneUrl(for: zoneId)
                let record = latencyCache[cacheKey(for: url)]
                let effectivePing = effectivePingMs(from: record, now: now)
                return GFNZone(
                    id: zoneId,
                    region: parts.first ?? entry.Region,
                    regionSuffix: parts.count > 1 ? parts[1] : entry.Region,
                    queuePosition: entry.QueuePosition,
                    etaMs: entry.eta,
                    zoneUrl: url,
                    pingMs: effectivePing.map { Int($0.rounded()) },
                    isMeasuring: !hasFreshHeadPing(record, now: now)
                )
            }
            .sorted { $0.queuePosition < $1.queuePosition }
    }

    /// Refreshes the HTTP probe and returns the best known latency for the zone.
    func measurePing(to url: String) async -> Int? {
        _ = await headProbe(url) // warm-up
        var samples: [Double] = []
        for _ in 0 ..< 2 {
            if let ms = await headProbe(url) { samples.append(ms) }
        }
        guard !samples.isEmpty else { return nil }
        let ping = samples.reduce(0, +) / Double(samples.count)
        var record = latencyCache[cacheKey(for: url)] ?? LatencyRecord()
        record.headPingMs = ping
        record.headMeasuredAt = Date()
        latencyCache[cacheKey(for: url)] = record
        persistLatencyCache()
        let effectivePing = effectivePingMs(from: record, now: Date()) ?? ping
        return Int(effectivePing.rounded())
    }

    /// Refreshes zone queue data and stale latency probes without delaying game launch.
    func prewarmAutomaticRouting() async {
        let now = Date()
        guard !isPrewarming,
              lastPrewarmAt.map({ now.timeIntervalSince($0) >= Self.prewarmInterval }) ?? true
        else {
            return
        }

        isPrewarming = true
        lastPrewarmAt = now
        defer { isPrewarming = false }

        do {
            var zones = try await fetchZones()
            cacheAutomaticSelections(from: zones)

            let staleZones = zones.filter(\.isMeasuring)
            let batchSize = 6
            for start in stride(from: 0, to: staleZones.count, by: batchSize) {
                let end = min(start + batchSize, staleZones.count)
                let batch = staleZones[start ..< end]
                await withTaskGroup(of: (String, Int?).self) { group in
                    for zone in batch {
                        group.addTask { [zone] in
                            await (zone.id, self.measurePing(to: zone.zoneUrl))
                        }
                    }
                    for await (id, ping) in group {
                        guard let index = zones.firstIndex(where: { $0.id == id }) else { continue }
                        let record = latencyCache[cacheKey(for: zones[index].zoneUrl)]
                        let effectivePing = effectivePingMs(from: record, now: Date())
                        zones[index].pingMs = effectivePing.map { Int($0.rounded()) } ?? ping ?? zones[index].pingMs
                        zones[index].isMeasuring = false
                    }
                }
                cacheAutomaticSelections(from: zones)
            }
        } catch {
            zoneLog.warning("[Zone] Automatic routing prewarm failed: \(error, privacy: .private)")
        }
    }

    /// Returns immediately from the last background refresh; nil preserves NVIDIA routing.
    func cachedAutomaticZoneUrl(isUnlimited: Bool) -> String? {
        let key = isUnlimited ? "unlimited" : "standard"
        guard let record = autoRouteCache[key],
              Date().timeIntervalSince(record.selectedAt) <= Self.autoRouteMaxAge
        else {
            return nil
        }
        return record.zoneUrl
    }

    /// Feeds the actual selected WebRTC path RTT back into future zone ranking.
    func recordSessionRtt(zoneUrl: String, rttMs: Double) {
        guard rttMs > 0, rttMs.isFinite, isZoneUrl(zoneUrl) else { return }
        let key = cacheKey(for: zoneUrl)
        var record = latencyCache[key] ?? LatencyRecord()
        record.sessionRttMs = record.sessionRttMs.map { $0 * 0.7 + rttMs * 0.3 } ?? rttMs
        record.sessionMeasuredAt = Date()
        latencyCache[key] = record
        persistLatencyCache()
    }

    func cacheAutomaticSelections(from zones: [GFNZone]) {
        let now = Date()
        if let zone = zones.autoZone(isUnlimited: false), zone.pingMs != nil {
            autoRouteCache["standard"] = AutoRouteRecord(zoneUrl: zone.zoneUrl, selectedAt: now)
        }
        if let zone = zones.autoZone(isUnlimited: true), zone.pingMs != nil {
            autoRouteCache["unlimited"] = AutoRouteRecord(zoneUrl: zone.zoneUrl, selectedAt: now)
        }
        if let data = try? JSONEncoder().encode(autoRouteCache) {
            UserDefaults.standard.set(data, forKey: Self.autoRouteCacheKey)
        }
    }

    // MARK: Private

    private func zoneUrl(for zoneId: String) -> String {
        "https://\(zoneId.lowercased()).cloudmatchbeta.nvidiagrid.net/"
    }

    private func cacheKey(for zoneUrl: String) -> String {
        zoneUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    private func effectivePingMs(from record: LatencyRecord?, now: Date) -> Double? {
        if let measuredAt = record?.sessionMeasuredAt,
           now.timeIntervalSince(measuredAt) <= Self.sessionRttMaxAge,
           let rtt = record?.sessionRttMs
        {
            return rtt
        }
        if let measuredAt = record?.headMeasuredAt,
           now.timeIntervalSince(measuredAt) <= Self.headPingMaxAge
        {
            return record?.headPingMs
        }
        return nil
    }

    private func hasFreshHeadPing(_ record: LatencyRecord?, now: Date) -> Bool {
        guard let measuredAt = record?.headMeasuredAt else { return false }
        return now.timeIntervalSince(measuredAt) <= Self.headPingMaxAge
    }

    private func isZoneUrl(_ zoneUrl: String) -> Bool {
        guard let host = URL(string: zoneUrl)?.host?.lowercased() else { return false }
        return host.hasPrefix("np-") && host.hasSuffix(".nvidiagrid.net")
    }

    private func persistLatencyCache() {
        if let data = try? JSONEncoder().encode(latencyCache) {
            UserDefaults.standard.set(data, forKey: Self.latencyCacheKey)
        }
    }

    private func headProbe(_ urlString: String) async -> Double? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        let start = Date()
        return try? await {
            _ = try await URLSession.shared.data(for: req)
            return Date().timeIntervalSince(start) * 1000
        }()
    }

    // MARK: API types

    private struct QueueEntry: Decodable {
        let QueuePosition: Int
        let Region: String
        let eta: Double?
        enum CodingKeys: String, CodingKey {
            case QueuePosition
            case Region
            case eta
        }
    }

    private struct MappingEntry: Decodable {
        let nuked: Bool?
    }

    private func fetchQueueData() async throws -> [String: QueueEntry] {
        let url = URL(string: "https://api.printedwaste.com/gfn/queue/")!
        var req = URLRequest(url: url)
        req.setValue("CloudNow/1.0 tvOS", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Response: Decodable { let data: [String: QueueEntry] }
        return try JSONDecoder().decode(Response.self, from: data).data
    }

    private func fetchMappingData() async throws -> [String: MappingEntry] {
        let url = URL(string: "https://remote.printedwaste.com/config/GFN_SERVERID_TO_REGION_MAPPING")!
        var req = URLRequest(url: url)
        req.setValue("CloudNow/1.0 tvOS", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Response: Decodable { let data: [String: MappingEntry] }
        return try JSONDecoder().decode(Response.self, from: data).data
    }
}

// MARK: - Auto-routing

extension [GFNZone] {
    /// Best zone by subscription tier. Ping dominates; queue depth is a bounded
    /// secondary penalty so a distant empty zone cannot beat a nearby busy one.
    nonisolated func autoZone(isUnlimited: Bool = false) -> GFNZone? {
        guard !isEmpty else { return nil }
        if isUnlimited { return closestZone }
        let measured = filter { $0.pingMs != nil }
        guard !measured.isEmpty else { return self.min { $0.queuePosition < $1.queuePosition } }
        return measured.min {
            let leftScore = Double($0.pingMs ?? .max) + Double(Swift.min($0.queuePosition, 80)) * 0.25
            let rightScore = Double($1.pingMs ?? .max) + Double(Swift.min($1.queuePosition, 80)) * 0.25
            return leftScore < rightScore
        }
    }

    /// Zone with the lowest measured ping.
    nonisolated var closestZone: GFNZone? {
        filter { $0.pingMs != nil }.min { ($0.pingMs ?? .max) < ($1.pingMs ?? .max) }
    }
}
