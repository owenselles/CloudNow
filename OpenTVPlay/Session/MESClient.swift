import Foundation

// MARK: - MES (Membership Entitlement Service) Client

/// Fetches subscription tier and entitled resolutions/FPS from NVIDIA's MES API.
/// Requires a VPC ID obtained from the streaming server's /v2/serverInfo endpoint.
actor MESClient {
    static let shared = MESClient()
    private let urlSession = URLSession.shared

    // MARK: VPC ID Discovery

    /// Fetches the VPC/server region ID from the streaming base URL.
    /// Returns nil on failure — caller should fall back to an empty vpcId.
    func fetchVpcId(token: String, base: String) async throws -> String? {
        let url = URL(string: "\(base)/v2/serverInfo")!
        var request = URLRequest(url: url)
        request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(NVIDIAAuth.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await urlSession.data(for: request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["requestStatus"] as? [String: Any],
              let serverId = status["serverId"] as? String
        else { return nil }
        return serverId
    }

    // MARK: Subscription Fetch

    func fetchSubscription(token: String, vpcId: String, userId: String) async throws -> SubscriptionInfo {
        var comps = URLComponents(string: "https://mes.geforcenow.com/v4/subscriptions")!
        comps.queryItems = [
            URLQueryItem(name: "serviceName", value: "gfn_pc"),
            URLQueryItem(name: "languageCode", value: "en_US"),
            URLQueryItem(name: "vpcId", value: vpcId),
            URLQueryItem(name: "userId", value: userId),
        ]
        guard let url = comps.url else {
            throw MESError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ec7e38d4-03af-4b58-b131-cfb0495903ab", forHTTPHeaderField: "nv-client-id")
        request.setValue("NATIVE", forHTTPHeaderField: "nv-client-type")
        request.setValue("2.0.80.173", forHTTPHeaderField: "nv-client-version")
        request.setValue("WEBRTC", forHTTPHeaderField: "nv-client-streamer")
        request.setValue(NVIDIAAuth.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await urlSession.data(for: request)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw MESError.fetchFailed(String(data: data, encoding: .utf8) ?? "HTTP error")
        }
        return try parseMESResponse(data)
    }

    // MARK: Private Parsing

    private func parseMESResponse(_ data: Data) throws -> SubscriptionInfo {
        let decoder = JSONDecoder()

        // Response may be an array or a single object — try both
        let raw: MESRawResponse
        if let array = try? decoder.decode([MESRawResponse].self, from: data), let first = array.first {
            raw = first
        } else {
            raw = try decoder.decode(MESRawResponse.self, from: data)
        }

        let tier = raw.membershipTier ?? raw.type ?? "FREE"
        let isUnlimited = raw.subType?.uppercased() == "UNLIMITED"

        let resolutions: [EntitledResolution] = (raw.features?.resolutions ?? []).map {
            EntitledResolution(
                widthInPixels: $0.widthInPixels,
                heightInPixels: $0.heightInPixels,
                framesPerSecond: $0.framesPerSecond
            )
        }

        return SubscriptionInfo(
            membershipTier: tier.uppercased() == "FREE" ? "Free" : tier,
            isUnlimited: isUnlimited,
            remainingMinutes: raw.remainingTimeInMinutes,
            totalMinutes: raw.totalTimeInMinutes,
            entitledResolutions: resolutions
        )
    }
}

// MARK: - Codable Response Types

private struct MESRawResponse: Decodable {
    let membershipTier: String?
    let type: String?
    let subType: String?
    let remainingTimeInMinutes: Int?
    let totalTimeInMinutes: Int?
    let features: Features?

    struct Features: Decodable {
        let resolutions: [Resolution]?
        struct Resolution: Decodable {
            let widthInPixels: Int
            let heightInPixels: Int
            let framesPerSecond: Int
        }
    }
}

// MARK: - Errors

enum MESError: Error, LocalizedError {
    case invalidURL
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Failed to build MES request URL."
        case .fetchFailed(let msg): return "Subscription fetch failed: \(msg)"
        }
    }
}
