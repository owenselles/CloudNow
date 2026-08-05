import Foundation

/// Small process-local Content Access cache. It keeps account metadata lazy,
/// coalesces identical requests, and never lets one caller cancel shared work.
actor XboxContentAccessStore: XboxContentAccessProviding {
    private static let defaultTimeToLive: TimeInterval = 5 * 60
    private static let maximumSupportedEntryCount = 2

    private struct Key: Hashable, Sendable {
        let accountAuthorizationIdentifier: String
        let market: String
        let offeringID: String
    }

    private struct Entry: Sendable {
        let snapshot: XboxContentAccessSnapshot
        let expiresAt: Date
        var accessOrder: UInt64
    }

    private struct InFlightOperation: Sendable {
        let identifier: UUID
        let generation: UInt64
        let task: Task<XboxContentAccessSnapshot, Error>
    }

    private let upstream: any XboxContentAccessProviding
    private let timeToLive: TimeInterval
    private let maximumEntryCount: Int
    private let now: @Sendable () -> Date
    private var generation: UInt64 = 0
    private var accessOrder: UInt64 = 0
    private var entries: [Key: Entry] = [:]
    private var inFlightOperations: [Key: InFlightOperation] = [:]

    init(
        upstream: any XboxContentAccessProviding,
        timeToLive: TimeInterval = 300,
        maximumEntryCount: Int = 2,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.upstream = upstream
        self.timeToLive = timeToLive.isFinite
            ? max(0, timeToLive)
            : Self.defaultTimeToLive
        self.maximumEntryCount = min(
            Self.maximumSupportedEntryCount,
            max(1, maximumEntryCount)
        )
        self.now = now
    }

    func fetchContentAccess(
        for account: XboxCloudAuthorizedAccount,
        market: String,
        offeringID: String
    ) async throws -> XboxContentAccessSnapshot {
        try Task.checkCancellation()
        let key = Self.key(
            account: account,
            market: market,
            offeringID: offeringID
        )
        if let snapshot = freshSnapshot(for: key) {
            return snapshot
        }

        let operation: InFlightOperation
        if let activeOperation = inFlightOperations[key] {
            operation = activeOperation
        } else {
            let upstream = upstream
            let task = Task { @concurrent in
                try await upstream.fetchContentAccess(
                    for: account,
                    market: key.market,
                    offeringID: key.offeringID
                )
            }
            operation = InFlightOperation(
                identifier: UUID(),
                generation: generation,
                task: task
            )
            inFlightOperations[key] = operation
        }

        switch await operation.task.result {
        case let .success(snapshot):
            complete(
                operation,
                for: key,
                snapshot: snapshot
            )
            try Task.checkCancellation()
            return snapshot
        case let .failure(error):
            discard(operation, for: key)
            if error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    /// Invalidates cached and in-flight work. Identity fencing prevents an old
    /// completion from repopulating the store after this barrier.
    func clear() {
        generation &+= 1
        let operations = Array(inFlightOperations.values)
        inFlightOperations.removeAll(keepingCapacity: false)
        entries.removeAll(keepingCapacity: false)
        for operation in operations {
            operation.task.cancel()
        }
    }

    private func freshSnapshot(for key: Key) -> XboxContentAccessSnapshot? {
        guard var entry = entries[key] else { return nil }
        guard entry.expiresAt > now() else {
            entries.removeValue(forKey: key)
            return nil
        }
        accessOrder &+= 1
        entry.accessOrder = accessOrder
        entries[key] = entry
        return entry.snapshot
    }

    private func complete(
        _ operation: InFlightOperation,
        for key: Key,
        snapshot: XboxContentAccessSnapshot
    ) {
        guard isCurrent(operation, for: key) else { return }
        inFlightOperations.removeValue(forKey: key)
        accessOrder &+= 1
        entries[key] = Entry(
            snapshot: snapshot,
            expiresAt: now().addingTimeInterval(timeToLive),
            accessOrder: accessOrder
        )
        trimIfNeeded()
    }

    private func discard(
        _ operation: InFlightOperation,
        for key: Key
    ) {
        guard isCurrent(operation, for: key) else { return }
        inFlightOperations.removeValue(forKey: key)
    }

    private func isCurrent(
        _ operation: InFlightOperation,
        for key: Key
    ) -> Bool {
        guard generation == operation.generation,
              let currentOperation = inFlightOperations[key]
        else {
            return false
        }
        return currentOperation.identifier == operation.identifier
            && currentOperation.generation == operation.generation
    }

    private func trimIfNeeded() {
        while entries.count > maximumEntryCount,
              let oldestKey = entries.min(by: {
                  $0.value.accessOrder < $1.value.accessOrder
              })?.key
        {
            entries.removeValue(forKey: oldestKey)
        }
    }

    private static func key(
        account: XboxCloudAuthorizedAccount,
        market: String,
        offeringID: String
    ) -> Key {
        Key(
            accountAuthorizationIdentifier: account.authorizationIdentifier,
            market: market
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased(),
            offeringID: offeringID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        )
    }
}
