import Foundation

/// Presentation preferences are independent of physical input-device availability.
nonisolated struct GFNGamePreferences: Codable, Equatable {
    var launchMode: AppLaunchMode?
    var remoteMode: RemoteInputMode?

    var inheritsAllSettings: Bool {
        launchMode == nil && remoteMode == nil
    }
}

extension StreamSettings {
    nonisolated func applyingGamePreferences(for gameID: String, forNewSession: Bool = true) -> StreamSettings {
        guard let preferences = gamePreferences[gameID] else { return self }
        var resolved = self
        if forNewSession, let launchMode = preferences.launchMode {
            resolved.appLaunchMode = launchMode
        }
        if let remoteMode = preferences.remoteMode {
            resolved.defaultRemoteInputMode = remoteMode
        }
        return resolved
    }

    nonisolated mutating func setGamePreferences(_ preferences: GFNGamePreferences, for gameID: String) {
        gamePreferences[gameID] = preferences.inheritsAllSettings ? nil : preferences
    }
}

/// Decode fields and titles independently so one future or corrupt value cannot
/// discard unrelated preferences or the rest of StreamSettings.
extension GFNGamePreferences {
    private enum CodingKeys: String, CodingKey { case launchMode, remoteMode }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchMode = try? container.decode(AppLaunchMode.self, forKey: .launchMode)
        remoteMode = try? container.decode(RemoteInputMode.self, forKey: .remoteMode)
    }

    nonisolated static func decodeEntries(from decoder: Decoder?) -> [String: Self] {
        guard let decoder, let container = try? decoder.container(keyedBy: GameKey.self) else { return [:] }
        var result: [String: Self] = [:]
        for key in container.allKeys {
            if let entry = try? container.decode(Self.self, forKey: key), !entry.inheritsAllSettings {
                result[key.stringValue] = entry
            }
        }
        return result
    }

    private struct GameKey: CodingKey {
        let stringValue: String
        var intValue: Int? {
            nil
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }
    }
}
