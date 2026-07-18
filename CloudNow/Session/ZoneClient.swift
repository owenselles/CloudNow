import Foundation

// MARK: - Zone Model

struct GFNZone: Identifiable, Equatable {
    let id: String // e.g. "NP-AWS-US-N-Virginia-1"
    let region: String // e.g. "US"
    /// ISO country code derived from the dedicated-server site code.
    let countryCode: String
    /// Human-readable city represented by the dedicated-server site code.
    let city: String
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

    private static let latencyCacheKey = "gfn.zoneLatencyCache"
    private static let headPingMaxAge: TimeInterval = 6 * 60 * 60
    private static let sessionRttMaxAge: TimeInterval = 7 * 24 * 60 * 60

    /// The live mapping title is not consistently a city (for example "Virginia",
    /// "Germany", or "Japan"). NVIDIA's stable site code gives us the hierarchy
    /// users expect while the API title remains available as a future-site fallback.
    private static let locationBySiteCode: [String: (countryCode: String, city: String)] = [
        "AMS": ("NL", "Amsterdam"),
        "ASH": ("US", "Ashburn"),
        "ATL": ("US", "Atlanta"),
        "BOM": ("IN", "Mumbai"),
        "CHI": ("US", "Chicago"),
        "DAL": ("US", "Dallas"),
        "FRK": ("DE", "Frankfurt"),
        "LAX": ("US", "Los Angeles"),
        "LON": ("GB", "London"),
        "MIA": ("US", "Miami"),
        "MON": ("CA", "Montreal"),
        "NWK": ("US", "Newark"),
        "PAR": ("FR", "Paris"),
        "PDX": ("US", "Portland"),
        "PHX": ("US", "Phoenix"),
        "SJC6": ("US", "San Jose"),
        "SOF": ("BG", "Sofia"),
        "STH": ("SE", "Stockholm"),
        "TYO": ("JP", "Tokyo"),
        "WAW": ("PL", "Warsaw"),
        "YYZ": ("CA", "Toronto"),
    ]

    private var latencyCache: [String: LatencyRecord]
    private var cacheGeneration = 0

    private init() {
        let defaults = UserDefaults.standard
        latencyCache = defaults.data(forKey: Self.latencyCacheKey)
            .flatMap { try? JSONDecoder().decode([String: LatencyRecord].self, from: $0) } ?? [:]
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
                let url = zoneUrl(for: zoneId)
                let record = latencyCache[cacheKey(for: url)]
                let effectivePing = effectivePingMs(from: record, now: now)
                let location = location(for: zoneId, queueRegion: entry.Region, mapping: mappingData[zoneId])
                return GFNZone(
                    id: zoneId,
                    region: entry.Region,
                    countryCode: location.countryCode,
                    city: location.city,
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
        let generation = cacheGeneration
        _ = await headProbe(url) // warm-up
        var samples: [Double] = []
        for _ in 0 ..< 2 {
            if let ms = await headProbe(url) {
                samples.append(ms)
            }
        }
        guard generation == cacheGeneration, !samples.isEmpty else { return nil }
        let ping = samples.reduce(0, +) / Double(samples.count)
        var record = latencyCache[cacheKey(for: url)] ?? LatencyRecord()
        record.headPingMs = ping
        record.headMeasuredAt = Date()
        latencyCache[cacheKey(for: url)] = record
        persistLatencyCache()
        let effectivePing = effectivePingMs(from: record, now: Date()) ?? ping
        return Int(effectivePing.rounded())
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

    func clearCachedRoutingData() {
        cacheGeneration &+= 1
        latencyCache.removeAll(keepingCapacity: false)
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.latencyCacheKey)
    }

    // MARK: Private

    private func zoneUrl(for zoneId: String) -> String {
        "https://\(zoneId.lowercased()).cloudmatchbeta.nvidiagrid.net/"
    }

    private func location(
        for zoneId: String,
        queueRegion: String,
        mapping: MappingEntry?
    ) -> (countryCode: String, city: String) {
        let components = zoneId.split(separator: "-")
        let siteCode = components.count > 1 ? String(components[1]) : zoneId
        if let location = Self.locationBySiteCode[siteCode] {
            return location
        }

        // Do not hide a newly-added site while this table catches up. Standard
        // two-letter queue regions localize as countries; aggregate codes use the
        // existing region fallback in the country picker.
        if let title = mapping?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return (queueRegion.uppercased(), title)
        }
        return (queueRegion.uppercased(), siteCode)
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
        let title: String?
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

// MARK: - Zone recommendation

extension [GFNZone] {
    /// Highlights a likely good manual choice. Ping dominates; queue depth is a
    /// bounded secondary penalty so a distant empty zone cannot beat a nearby one.
    nonisolated func recommendedZone(isUnlimited: Bool = false) -> GFNZone? {
        guard !isEmpty else { return nil }
        if isUnlimited {
            return closestZone
        }
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
