@testable import CloudNow
import Security
import Testing

@Suite("Keychain credential deletion")
struct KeychainCredentialStoreTests {
    @Test("Successful and already-absent credentials count as deleted")
    func acceptedDeleteStatuses() throws {
        try KeychainService.validateDeleteStatus(errSecSuccess)
        try KeychainService.validateDeleteStatus(errSecItemNotFound)
    }

    @Test("Keychain deletion failures propagate to Reset All Data")
    func rejectedDeleteStatus() {
        #expect(throws: KeychainService.KeychainError.self) {
            try KeychainService.validateDeleteStatus(errSecInteractionNotAllowed)
        }
    }
}
