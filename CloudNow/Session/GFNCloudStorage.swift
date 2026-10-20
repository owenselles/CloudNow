import Foundation

/// Account-specific cloud storage reported by the membership service.
nonisolated struct GFNCloudStorage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case persistent = "PERMANENT_STORAGE"
        case singleSession = "EPHEMERAL_STORAGE"
        case unknown = "UNKNOWN"
    }

    let kind: Kind
    let status: String?
    let totalGB: Int?
    let usedGB: Int?
    let regionCode: String?
    let regionName: String?

    var isPersistent: Bool {
        kind == .persistent
    }

    var isUsable: Bool {
        kind != .unknown && (status == nil || status == "OK")
    }

    var remainingGB: Int? {
        guard let totalGB, totalGB >= 0, let usedGB, usedGB >= 0 else { return nil }
        return max(totalGB - usedGB, 0)
    }

    var availableGB: Int? {
        switch kind {
        case .persistent:
            return remainingGB
        case .singleSession:
            guard let totalGB, totalGB >= 0 else { return nil }
            return totalGB
        case .unknown:
            return nil
        }
    }

    var availableBytes: Int64? {
        guard let availableGB, let gigabytes = Int64(exactly: availableGB) else { return nil }
        let (bytes, overflow) = gigabytes.multipliedReportingOverflow(by: 1_073_741_824)
        return overflow ? nil : bytes
    }
}
