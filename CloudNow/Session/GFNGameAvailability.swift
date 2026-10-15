import Foundation

/// Live per-store availability. This state is intentionally excluded from game caches.
nonisolated struct GFNGameAvailability: Decodable, Equatable, Sendable {
    let status: String?
    let stateDetails: StateDetails?

    init(status: String?, stateDetails: StateDetails? = nil) {
        self.status = status
        self.stateDetails = stateDetails
    }

    var isUnavailable: Bool {
        status == "PATCHING" || status == "SERVER_MAINTENANCE"
    }

    var titleKey: String? {
        switch status {
        case "PATCHING": "gfn_game_patching"
        case "SERVER_MAINTENANCE": "gfn_game_maintenance"
        default: nil
        }
    }

    var messageKey: String? {
        guard isUnavailable else { return nil }
        switch stateDetails?.subType {
        case "GAME_DEVELOPER_MAINTENANCE":
            return "gfn_game_developer_maintenance_description"
        case "PATCHING_MANUAL_INTERVENTION", "GFN_DEVELOPER_MAINTENANCE":
            return "gfn_game_compatibility_description"
        default:
            return status == "PATCHING"
                ? "gfn_game_patching_description"
                : "gfn_game_compatibility_description"
        }
    }

    var estimatedEndDate: Date? {
        guard status == "PATCHING",
              let details = stateDetails,
              let subType = details.subType,
              ["PATCHING_AUTO", "PATCHING_MANUAL_INTERVENTION"].contains(subType),
              let endTime = details.endTime
        else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: endTime) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: endTime)
    }

    struct StateDetails: Decodable, Equatable, Sendable {
        let subType: String?
        let endTime: String?

        init(subType: String?, endTime: String? = nil) {
            self.subType = subType
            self.endTime = endTime
        }

        private enum CodingKeys: String, CodingKey {
            case subType, endTime
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            subType = try container.decodeIfPresent(String.self, forKey: .subType)
            // A malformed optional estimate must not hide the availability status.
            endTime = try? container.decodeIfPresent(String.self, forKey: .endTime)
        }
    }
}
