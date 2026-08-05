import Foundation
import Synchronization

/// Persists Microsoft's non-secret SDK installation identifier independently
/// from either provider account. It is read only when an Xbox stream controller
/// is created and Reset All Data removes it with the rest of CloudNow defaults.
final nonisolated class XboxCloudInstallationIdentityStore: Sendable {
    private static let preferenceKey = "xbox.sdkInstallID.v1"

    private let preferences: any PreferencesStore
    private let lock = Mutex(false)

    init(
        preferences: any PreferencesStore = UserDefaultsPreferencesStore()
    ) {
        self.preferences = preferences
    }

    func loadOrCreateSDKInstallID() -> String {
        lock.withLock { _ in
            if let persisted = preferences.string(
                forKey: Self.preferenceKey
            ), Self.isValid(persisted) {
                return persisted
            }

            let identifier = UUID().uuidString
            preferences.setString(
                identifier,
                forKey: Self.preferenceKey
            )
            return identifier
        }
    }

    private static func isValid(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value) != nil
    }
}
