@testable import CloudNow
import Foundation

nonisolated enum CredentialResetTestStoreError: Error, Equatable {
    case notFound
}

final nonisolated class CredentialResetTestSecureStore: SecureCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?

    func load() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let storedData else {
            throw CredentialResetTestStoreError.notFound
        }
        return storedData
    }

    func save(_ data: Data) {
        lock.lock()
        storedData = data
        lock.unlock()
    }

    func delete() {
        lock.lock()
        storedData = nil
        lock.unlock()
    }
}

final nonisolated class CredentialResetTestPreferences: PreferencesStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? {
        lock.withLock { values[key] as? Data }
    }

    func string(forKey key: String) -> String? {
        lock.withLock { values[key] as? String }
    }

    func setData(_ data: Data, forKey key: String) {
        lock.withLock { values[key] = data }
    }

    func setString(_ value: String, forKey key: String) {
        lock.withLock { values[key] = value }
    }

    func removeObject(forKey key: String) {
        lock.withLock { values.removeValue(forKey: key) }
    }

    func keys() -> [String] {
        lock.withLock { Array(values.keys) }
    }
}

nonisolated struct CredentialResetTestHarness {
    let geForceNowStore = CredentialResetTestSecureStore()
    let xboxStore = CredentialResetTestSecureStore()
    let persistence: AppPersistenceStore

    init() {
        persistence = AppPersistenceStore(
            preferences: CredentialResetTestPreferences(),
            cacheDirectory: nil,
            credentialStore: geForceNowStore,
            xboxCredentialStore: xboxStore
        )
    }
}

actor DelayedGeForceNowRollbackPersistence: AuthSessionPersistence {
    private nonisolated let upstream: AppPersistenceStore
    private var isSaveBlocked = false
    private var didForwardSave = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(upstream: AppPersistenceStore) {
        self.upstream = upstream
    }

    nonisolated func authSessionResetGeneration() -> UInt64 {
        upstream.authSessionResetGeneration()
    }

    func loadAuthSession() async throws -> AuthSession {
        try await upstream.loadAuthSession()
    }

    func saveAuthSession(
        _ session: AuthSession,
        generation: UInt64
    ) async throws {
        try await upstream.saveAuthSession(session, generation: generation)
    }

    func saveAuthSession(
        _ session: AuthSession,
        generation: UInt64,
        resetGeneration: UInt64
    ) async throws {
        isSaveBlocked = true
        let blockedWaiters = blockedWaiters
        self.blockedWaiters.removeAll(keepingCapacity: false)
        blockedWaiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        try await upstream.saveAuthSession(
            session,
            generation: generation,
            resetGeneration: resetGeneration
        )
        didForwardSave = true
        let completionWaiters = completionWaiters
        self.completionWaiters.removeAll(keepingCapacity: false)
        completionWaiters.forEach { $0.resume() }
    }

    func deleteAuthSession(generation: UInt64) async throws {
        try await upstream.deleteAuthSession(generation: generation)
    }

    func waitUntilSaveIsBlocked() async {
        guard !isSaveBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func releaseSave() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func waitUntilSaveIsForwarded() async {
        guard !didForwardSave else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append(continuation)
        }
    }
}

actor DelayedXboxRollbackPersistence: XboxAuthSessionPersistence {
    private nonisolated let upstream: AppPersistenceStore
    private var isSaveBlocked = false
    private var didForwardSave = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(upstream: AppPersistenceStore) {
        self.upstream = upstream
    }

    nonisolated func xboxAuthSessionResetGeneration() -> UInt64 {
        upstream.xboxAuthSessionResetGeneration()
    }

    func loadXboxAuthSession() async throws -> XboxAuthSession? {
        try await upstream.loadXboxAuthSession()
    }

    func saveXboxAuthSession(
        _ session: XboxAuthSession,
        generation: UInt64
    ) async throws {
        try await upstream.saveXboxAuthSession(session, generation: generation)
    }

    func saveXboxAuthSession(
        _ session: XboxAuthSession,
        generation: UInt64,
        resetGeneration: UInt64
    ) async throws {
        isSaveBlocked = true
        let blockedWaiters = blockedWaiters
        self.blockedWaiters.removeAll(keepingCapacity: false)
        blockedWaiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        try await upstream.saveXboxAuthSession(
            session,
            generation: generation,
            resetGeneration: resetGeneration
        )
        didForwardSave = true
        let completionWaiters = completionWaiters
        self.completionWaiters.removeAll(keepingCapacity: false)
        completionWaiters.forEach { $0.resume() }
    }

    func deleteXboxAuthSession(generation: UInt64) async throws {
        try await upstream.deleteXboxAuthSession(generation: generation)
    }

    func waitUntilSaveIsBlocked() async {
        guard !isSaveBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func releaseSave() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func waitUntilSaveIsForwarded() async {
        guard !didForwardSave else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append(continuation)
        }
    }
}
