import Foundation
import os.log

private let serverInfoLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "ServerInfo")

/// One selectable GFN region from /v2/serverInfo. Mirrors the official client's
/// Server Location dropdown entries: `name` is the display label, used verbatim.
struct GFNRegion: Identifiable, Equatable {
    let name: String
    /// https URL with trailing slash, usable directly as a CloudMatch base.
    let address: String
    var id: String {
        name
    }
}

struct GFNServerInfo: Equatable {
    let regions: [GFNRegion]
    /// Server-detected best region for this network — the Automatic target.
    let localRegionName: String?
    let vpcId: String?
}

/// Fetches the region list the same way the official GFN web client does:
/// `GET <streamingServiceUrl>/v2/serverInfo`. The response's `metaData` array
/// carries a `gfn-regions` CSV of region display names, one entry per region
/// name whose value is that region's address, and `local-region` with the
/// server-detected region for the caller's network.
@MainActor
final class ServerInfoClient {
    static let shared = ServerInfoClient()

    /// Last successful fetch, kept for the app run (region lists change rarely).
    private(set) var cached: GFNServerInfo?

    func fetch(baseUrl: String, token: String) async throws -> GFNServerInfo {
        let base = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        guard let url = URL(string: "\(base)/v2/serverInfo") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let deviceId = GFNDeviceIdentity.stableDeviceId()
        for (key, value) in gfnHeaders(token: token, clientId: UUID().uuidString, deviceId: deviceId) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            serverInfoLog.error("serverInfo failed: \(status) body=\(body, privacy: .public)")
            throw URLError(.badServerResponse)
        }

        let info = try Self.parse(data)
        serverInfoLog.info("serverInfo: \(info.regions.count) regions, local=\(info.localRegionName ?? "nil", privacy: .public)")
        cached = info
        return info
    }

    /// Mirrors the official client's buildZonesFromGfnRegions: `gfn-regions` lists the
    /// region names; each name is itself a metaData key whose value is the address.
    static func parse(_ data: Data) throws -> GFNServerInfo {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metaData = root["metaData"] as? [[String: Any]]
        else {
            serverInfoLog.error("serverInfo parse: unexpected shape \(String(data: data.prefix(300), encoding: .utf8) ?? "", privacy: .public)")
            throw URLError(.cannotParseResponse)
        }

        var valueByKey: [String: String] = [:]
        for entry in metaData {
            if let key = entry["key"] as? String {
                valueByKey[key] = entry["value"] as? String
            }
        }

        let regionNames = (valueByKey["gfn-regions"] ?? "")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let regions: [GFNRegion] = regionNames.compactMap { name in
            guard let raw = valueByKey[name], !raw.isEmpty else { return nil }
            return GFNRegion(name: name, address: normalizedAddress(raw))
        }

        return GFNServerInfo(
            regions: regions,
            localRegionName: valueByKey["local-region"],
            vpcId: root["vpcId"] as? String
        )
    }

    private static func normalizedAddress(_ raw: String) -> String {
        var address = raw.trimmingCharacters(in: .whitespaces)
        if !address.lowercased().hasPrefix("http") {
            address = "https://" + address
        }
        if !address.hasSuffix("/") {
            address += "/"
        }
        return address
    }
}
