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
    nonisolated func applyingGamePreferences(for gameID: String) -> StreamSettings {
        guard let preferences = gamePreferences[gameID] else { return self }
        var resolved = self
        if let launchMode = preferences.launchMode {
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
