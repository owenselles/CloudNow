import Foundation
import Observation

nonisolated enum StoreConnectionPhase: Equatable, Sendable {
    case idle
    case requesting(providerCode: String)
    case authorizing(providerCode: String, authorization: StoreDeviceAuthorization)
    case confirming(providerCode: String)
    case disconnecting(providerCode: String)

    var providerCode: String? {
        switch self {
        case .idle: nil
        case let .requesting(code), let .authorizing(code, _),
             let .confirming(code), let .disconnecting(code): code
        }
    }
}

/// Owns one account-bound connection operation. Library synchronization remains
/// with LibraryRefreshCoordinator after the server confirms a connection change.
@Observable
@MainActor
final class StoreConnectionsCoordinator {
    typealias TokenResolver = LibraryRefreshCoordinator.TokenResolver
    typealias UserValidator = LibraryRefreshCoordinator.UserValidator
    typealias ConnectionChanged = @MainActor @Sendable (StoreConnection) -> Void

    private struct Context {
        let generation: UInt64
        let userId: String
        let resolveToken: TokenResolver
        let userIsCurrent: UserValidator
    }

    private struct ConfirmationFailed: Error {}

    private(set) var stores: [StoreConnection] = []
    private(set) var phase: StoreConnectionPhase = .idle
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    var isBusy: Bool {
        isLoading || phase != .idle
    }

    var activeStoreCode: String? {
        phase.providerCode
    }

    var authorization: StoreDeviceAuthorization? {
        guard case let .authorizing(_, authorization) = phase else { return nil }
        return authorization
    }

    @ObservationIgnored private let client: any StoreConnectionClient
    @ObservationIgnored private let scheduler: LibraryRefreshScheduler
    @ObservationIgnored private let confirmationTimeout: TimeInterval
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    init(
        client: any StoreConnectionClient = GFNStoreConnectionClient(),
        scheduler: LibraryRefreshScheduler = .continuous,
        confirmationTimeout: TimeInterval = 30
    ) {
        self.client = client
        self.scheduler = scheduler
        self.confirmationTimeout = max(0, confirmationTimeout)
    }

    func refresh(
        userId: String,
        resolveToken: @escaping TokenResolver,
        userIsCurrent: @escaping UserValidator
    ) {
        guard !isBusy else { return }
        let context = begin(userId: userId, resolveToken: resolveToken, userIsCurrent: userIsCurrent)
        isLoading = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish(context) }
            do {
                let refreshed = try await discover(context)
                try requireCurrent(context)
                stores = refreshed
                hasLoaded = true
            } catch {
                handle(error, context: context, fallback: "store_connections_failed")
            }
        }
    }

    func connect(
        store: StoreConnection,
        userId: String,
        resolveToken: @escaping TokenResolver,
        userIsCurrent: @escaping UserValidator,
        onChange: @escaping ConnectionChanged
    ) {
        guard !isBusy, store.supportsLinking else { return }
        let context = begin(userId: userId, resolveToken: resolveToken, userIsCurrent: userIsCurrent)
        phase = .requesting(providerCode: store.code)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let authorization = try await authenticated(context) { [client] token in
                    try await client.requestAuthorization(providerCode: store.code, token: token)
                }
                try await authorize(authorization, providerCode: store.code, context: context)
                try requireCurrent(context)
                phase = .confirming(providerCode: store.code)
                let confirmed = try await confirm(store: store, connected: true, context: context)
                try requireCurrent(context)
                finish(context)
                onChange(confirmed)
            } catch {
                handle(error, context: context, fallback: "store_link_failed")
                finish(context)
            }
        }
    }

    func disconnect(
        store: StoreConnection,
        userId: String,
        resolveToken: @escaping TokenResolver,
        userIsCurrent: @escaping UserValidator,
        onChange: @escaping ConnectionChanged
    ) {
        guard !isBusy, store.isConnected, store.supportsLinking else { return }
        let context = begin(userId: userId, resolveToken: resolveToken, userIsCurrent: userIsCurrent)
        phase = .disconnecting(providerCode: store.code)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await authenticated(context) { [client] token in
                    try await client.disconnect(providerCode: store.code, token: token)
                }
                let confirmed = try await confirm(store: store, connected: false, context: context)
                try requireCurrent(context)
                finish(context)
                onChange(confirmed)
            } catch {
                handle(error, context: context, fallback: "store_disconnect_failed")
                finish(context)
            }
        }
    }

    func cancel(clearStores: Bool = false) {
        generation &+= 1
        task?.cancel()
        task = nil
        phase = .idle
        isLoading = false
        errorMessage = nil
        if clearStores {
            stores = []
            hasLoaded = false
        }
    }

    func waitForOperation() async {
        await task?.value
    }

    private func begin(
        userId: String,
        resolveToken: @escaping TokenResolver,
        userIsCurrent: @escaping UserValidator
    ) -> Context {
        generation &+= 1
        errorMessage = nil
        return Context(
            generation: generation,
            userId: userId,
            resolveToken: resolveToken,
            userIsCurrent: userIsCurrent
        )
    }

    private func finish(_ context: Context) {
        guard context.generation == generation else { return }
        task = nil
        phase = .idle
        isLoading = false
    }

    private func requireCurrent(_ context: Context) throws {
        try Task.checkCancellation()
        guard generation == context.generation, context.userIsCurrent() else {
            throw CancellationError()
        }
    }

    private func authenticated<Value: Sendable>(
        _ context: Context,
        operation: @Sendable (String) async throws -> Value
    ) async throws -> Value {
        try requireCurrent(context)
        let token = try await context.resolveToken(nil)
        try requireCurrent(context)
        let value: Value
        do {
            value = try await operation(token)
        } catch {
            try requireCurrent(context)
            guard error as? StoreConnectionError == .unauthorized
                || error as? LibrarySyncError == .unauthorized
            else { throw error }
            let refreshedToken = try await context.resolveToken(token)
            try requireCurrent(context)
            value = try await operation(refreshedToken)
        }
        try requireCurrent(context)
        return value
    }

    private func discover(_ context: Context) async throws -> [StoreConnection] {
        try await authenticated(context) { [client] token in
            try await client.discoverStores(token: token, userId: context.userId)
        }
    }

    private func authorize(
        _ authorization: StoreDeviceAuthorization,
        providerCode: String,
        context: Context
    ) async throws {
        try requireCurrent(context)
        let deadline = await scheduler.now() + authorization.expiresIn
        try requireCurrent(context)
        var interval = authorization.interval
        phase = .authorizing(providerCode: providerCode, authorization: authorization)
        while true {
            try requireCurrent(context)
            let remaining = await deadline - (scheduler.now())
            guard remaining > 0 else { throw StoreConnectionError.expired }
            try await scheduler.sleep(min(interval, remaining))
            try requireCurrent(context)
            guard await scheduler.now() < deadline else { throw StoreConnectionError.expired }
            try requireCurrent(context)
            let result: StoreAuthorizationStatus
            do {
                result = try await client.pollAuthorization(deviceCode: authorization.deviceCode)
            } catch let StoreConnectionError.rateLimited(retryAfter) {
                interval = max(interval + 5, retryAfter ?? 0)
                continue
            }
            try requireCurrent(context)
            switch result {
            case .pending: continue
            case .slowDown: interval += 5
            case .authorized: return
            }
        }
    }

    private func confirm(
        store: StoreConnection,
        connected: Bool,
        context: Context
    ) async throws -> StoreConnection {
        let deadline = await scheduler.now() + confirmationTimeout
        while true {
            let refreshed = try await discover(context)
            try requireCurrent(context)
            stores = refreshed
            hasLoaded = true
            // A historical sync denial may only clear after the post-link sync.
            // Confirm account authorization independently of that previous result.
            if let confirmed = refreshed.first(where: { $0.code == store.code }),
               confirmed.isConnected == connected,
               !connected || !confirmed.isExpired
            {
                return confirmed
            }
            let remaining = await deadline - (scheduler.now())
            guard remaining > 0 else { throw ConfirmationFailed() }
            try await scheduler.sleep(min(2, remaining))
            try requireCurrent(context)
        }
    }

    private func handle(_ error: Error, context: Context, fallback: String) {
        guard context.generation == generation else { return }
        guard context.userIsCurrent() else {
            stores = []
            hasLoaded = false
            return
        }
        guard !(error is CancellationError) else { return }
        let key: String = switch error {
        case StoreConnectionError.expired: "store_link_expired"
        case StoreConnectionError.denied: "store_link_denied"
        case StoreConnectionError.rateLimited, LibrarySyncError.rateLimited: "store_link_rate_limited"
        case is ConfirmationFailed:
            fallback == "store_disconnect_failed" ? fallback : "store_connection_unconfirmed"
        default: fallback
        }
        errorMessage = L10n.text(key)
    }
}
