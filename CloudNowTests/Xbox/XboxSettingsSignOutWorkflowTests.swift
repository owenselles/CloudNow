@testable import CloudNow
import Testing

@MainActor
@Suite("Xbox settings sign-out workflow")
struct XboxSettingsSignOutWorkflowTests {
    private enum ProbeError: Error {
        case logoutFailed
    }

    @Test("Failed End keeps catalog and credentials active")
    func failedEndStopsBeforeMutation() async throws {
        var events: [String] = []

        let didSignOut = try await XboxSettingsSignOutWorkflow.run(
            endSession: {
                events.append("end")
                return false
            },
            deactivate: { events.append("deactivate") },
            logout: { events.append("logout") },
            clearCatalog: { events.append("clear-catalog") },
            selectFallback: { events.append("select-fallback") }
        )

        #expect(!didSignOut)
        #expect(events == ["end"])
    }

    @Test("Failed logout does not clear the signed-in catalog")
    func failedLogoutStopsBeforeCatalogClear() async {
        var events: [String] = []

        do {
            _ = try await XboxSettingsSignOutWorkflow.run(
                endSession: {
                    events.append("end")
                    return true
                },
                deactivate: { events.append("deactivate") },
                logout: {
                    events.append("logout")
                    throw ProbeError.logoutFailed
                },
                clearCatalog: { events.append("clear-catalog") },
                selectFallback: { events.append("select-fallback") }
            )
            Issue.record("Expected logout to fail")
        } catch ProbeError.logoutFailed {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(events == ["end", "deactivate", "logout"])
    }

    @Test("Successful sign-out clears catalog only after logout")
    func successfulSignOutOrdersMutations() async throws {
        var events: [String] = []

        let didSignOut = try await XboxSettingsSignOutWorkflow.run(
            endSession: {
                events.append("end")
                return true
            },
            deactivate: { events.append("deactivate") },
            logout: { events.append("logout") },
            clearCatalog: { events.append("clear-catalog") },
            selectFallback: { events.append("select-fallback") }
        )

        #expect(didSignOut)
        #expect(events == [
            "end",
            "deactivate",
            "logout",
            "clear-catalog",
            "select-fallback",
        ])
    }
}
