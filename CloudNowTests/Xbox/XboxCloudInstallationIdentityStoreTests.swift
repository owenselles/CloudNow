@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox installation identity")
struct XboxCloudInstallationIdentityStoreTests {
    @Test("Installation identity is stable across store instances")
    func stableIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let first = XboxCloudInstallationIdentityStore(
            preferences: fixture.preferences
        ).loadOrCreateSDKInstallID()
        let second = XboxCloudInstallationIdentityStore(
            preferences: fixture.preferences
        ).loadOrCreateSDKInstallID()

        #expect(first == second)
        #expect(UUID(uuidString: first) != nil)
    }

    @Test("Invalid persisted identity is replaced")
    func invalidIdentityIsReplaced() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.defaults.set(
            "invalid",
            forKey: XboxCloudInstallationIdentityStore.preferenceKey
        )

        let identifier = XboxCloudInstallationIdentityStore(
            preferences: fixture.preferences
        ).loadOrCreateSDKInstallID()

        #expect(identifier != "invalid")
        #expect(UUID(uuidString: identifier) != nil)
    }
}

private struct Fixture {
    let suiteName: String
    let defaults: UserDefaults
    let preferences: UserDefaultsPreferencesStore

    init() throws {
        suiteName = "XboxCloudInstallationIdentityStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw FixtureError.unavailable
        }
        self.defaults = defaults
        preferences = UserDefaultsPreferencesStore(defaults: defaults)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private enum FixtureError: Error {
    case unavailable
}
