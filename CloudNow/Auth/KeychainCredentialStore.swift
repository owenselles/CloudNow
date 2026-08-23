import Foundation
import Security

nonisolated enum CloudCredentialNamespace: String, Sendable {
    case geForceNow = "gfn-auth-session"
    case xboxCloudGaming = "xbox-auth-session"
}

nonisolated struct KeychainCredentialStore: SecureCredentialStore {
    private let namespace: CloudCredentialNamespace

    init(namespace: CloudCredentialNamespace = .geForceNow) {
        self.namespace = namespace
    }

    func load() throws -> Data {
        try KeychainService.load(namespace: namespace)
    }

    func save(_ data: Data) throws {
        try KeychainService.save(data, namespace: namespace)
    }

    func delete() throws {
        try KeychainService.delete(namespace: namespace)
    }
}

nonisolated enum KeychainService {
    private static let service = "com.owenselles.CloudNow"

    static func save(
        _ data: Data,
        namespace: CloudCredentialNamespace
    ) throws {
        let query = query(namespace: namespace)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = accessibility(for: namespace)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func load(namespace: CloudCredentialNamespace) throws -> Data {
        var query = query(namespace: namespace)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.loadFailed(status)
        }
        return data
    }

    static func delete(namespace: CloudCredentialNamespace) throws {
        let status = SecItemDelete(query(namespace: namespace) as CFDictionary)
        try validateDeleteStatus(status)
    }

    static func validateDeleteStatus(_ status: OSStatus) throws {
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    static func accessibility(
        for namespace: CloudCredentialNamespace
    ) -> CFString {
        switch namespace {
        case .geForceNow:
            // Preserve the latest-main GFN Keychain contract and its existing
            // credential data. Namespace queries remain unchanged.
            kSecAttrAccessibleAfterFirstUnlock
        case .xboxCloudGaming:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    private static func query(
        namespace: CloudCredentialNamespace
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: namespace.rawValue,
        ]
    }

    enum KeychainError: Error {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
        case deleteFailed(OSStatus)
    }
}
