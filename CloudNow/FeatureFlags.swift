import CryptoKit
import Foundation

nonisolated func nvidiaAccountScope(for userId: String) -> String {
    SHA256.hash(data: Data(userId.utf8))
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
