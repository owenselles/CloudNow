import CryptoKit
import Foundation

nonisolated func nvidiaAccountScope(for userId: String) -> String {
    SHA256.hash(data: Data(userId.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

/// Local cache scope for a signed-in account, keyed by provider *and* user.
///
/// Two users of the same provider — and the same user across two providers —
/// hash differently, so cached library, VPC and subscription data can never be
/// read back under a different identity. Catalog data remains account-neutral.
///
/// Deliberately separate from `nvidiaAccountScope`, which is the `huId` value
/// sent to NVIDIA and must stay user-only.
nonisolated func accountCacheScope(idpId: String, userId: String) -> String {
    // The separator keeps ("ab", "c") and ("a", "bc") from colliding.
    SHA256.hash(data: Data("\(idpId)\n\(userId)".utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

nonisolated enum FeatureFlags {
    #if ProviderLibrarySyncEnabled
        static let providerLibrarySyncEnabled = true
    #else
        static let providerLibrarySyncEnabled = false
    #endif
}
