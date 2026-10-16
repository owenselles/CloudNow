@testable import CloudNow
import Foundation
import Testing

@Suite("GFN store connection coordinator", .timeLimit(.minutes(1)))
@MainActor
struct StoreConnectionsCoordinatorTests {
    @Test("Pending and slowdown responses respect server polling intervals before confirming the account")
    func pendingAndSlowdown() async {
        let client = StoreConnectionClientProbe(
            discoveries: [.success([store(connected: true)])],
            polls: [.success(.pending), .success(.slowDown), .success(.authorized)]
        )
        let clock = StoreConnectionClock()
        let coordinator = StoreConnectionsCoordinator(client: client, scheduler: clock.scheduler)
        var changes: [StoreConnection] = []
        connect(coordinator) { changes.append($0) }
        await coordinator.waitForOperation()

        #expect(await clock.sleeps == [5, 5, 10])
        #expect(await client.pollCount == 3)
        #expect(await client.discoveryCount == 1)
        #expect(changes == [store(connected: true)])
        #expect(coordinator.phase == .idle)
        #expect(coordinator.authorization == nil)
        #expect(coordinator.errorMessage == nil)
    }

    @Test("Rate limiting lengthens polling without submitting another authorization")
    func pollingRateLimit() async {
        let client = StoreConnectionClientProbe(
            discoveries: [.success([store(connected: true)])],
            polls: [.failure(.rateLimited(retryAfter: 20)), .success(.authorized)]
        )
        let clock = StoreConnectionClock()
        let coordinator = StoreConnectionsCoordinator(client: client, scheduler: clock.scheduler)
        connect(coordinator)
        await coordinator.waitForOperation()

        #expect(await clock.sleeps == [5, 20])
        #expect(await client.authorizationTokens.count == 1)
        #expect(coordinator.errorMessage == nil)
    }

    @Test("Authorization expires without polling beyond the code deadline")
    func authorizationExpiry() async {
        let client = StoreConnectionClientProbe(
            authorizations: [.success(authorization(expiresIn: 12))],
            polls: [.success(.pending)]
        )
        let clock = StoreConnectionClock()
        let coordinator = StoreConnectionsCoordinator(client: client, scheduler: clock.scheduler)
        var changed = false
        connect(coordinator) { _ in changed = true }
        await coordinator.waitForOperation()

        #expect(await clock.sleeps == [5, 5, 2])
        #expect(await client.pollCount == 2)
        #expect(await client.discoveryCount == 0)
        #expect(!changed)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.errorMessage == L10n.text("store_link_expired"))
    }

    @Test("OAuth completion waits for LCARS to confirm the linked store")
    func connectionConfirmation() async {
        let client = StoreConnectionClientProbe(discoveries: [
            .success([store()]),
            .success([store(connected: true)]),
        ])
        let clock = StoreConnectionClock()
        let coordinator = StoreConnectionsCoordinator(client: client, scheduler: clock.scheduler)
        var changes: [StoreConnection] = []
        connect(coordinator) { changes.append($0) }
        await coordinator.waitForOperation()

        #expect(await client.discoveryCount == 2)
        #expect(await clock.sleeps == [5, 2])
        #expect(changes == [store(connected: true)])
        #expect(coordinator.stores == changes)
    }

    @Test("An unconfirmed or still-expired account never reports a successful connection", arguments: [false, true])
    func connectionConfirmationFailure(expired: Bool) async {
        let client = StoreConnectionClientProbe(discoveries: [
            .success([store(connected: expired, requiresReconnect: expired, isExpired: expired)]),
        ])
        let clock = StoreConnectionClock()
        let coordinator = StoreConnectionsCoordinator(client: client, scheduler: clock.scheduler, confirmationTimeout: 4)
        var changed = false
        connect(coordinator) { _ in changed = true }
        await coordinator.waitForOperation()

        #expect(!changed)
        #expect(await client.discoveryCount == 3)
        #expect(coordinator.errorMessage == L10n.text("store_connection_unconfirmed"))
        #expect(coordinator.phase == .idle)
    }

    @Test("Freshly reconnected accounts can resync despite a historical denied sync result")
    func reconnectWithHistoricalSyncDenial() async {
        let reconnected = store(connected: true, requiresReconnect: true, syncState: .denied)
        let client = StoreConnectionClientProbe(discoveries: [.success([reconnected])])
        let clock = StoreConnectionClock()
        let coordinator = StoreConnectionsCoordinator(client: client, scheduler: clock.scheduler)
        var changes: [StoreConnection] = []
        coordinator.connect(
            store: reconnected, userId: "user", resolveToken: { _ in "token" },
            userIsCurrent: { true }, onChange: { changes.append($0) }
        )
        await coordinator.waitForOperation()

        #expect(reconnected.requiresReconnect)
        #expect(!reconnected.isExpired)
        #expect(reconnected.snapshot?.state == .denied)
        #expect(changes == [reconnected])
        #expect(await client.discoveryCount == 1)
        #expect(coordinator.errorMessage == nil)
        #expect(coordinator.phase == .idle)
    }

    @Test("A rejected NVIDIA token is refreshed once for authorization", arguments: [false, true])
    func authorizationAuthenticationRefresh(rejectRefresh: Bool) async {
        let second: Result<StoreDeviceAuthorization, StoreConnectionError> = rejectRefresh
            ? .failure(.unauthorized) : .success(authorization())
        let client = StoreConnectionClientProbe(
            discoveries: [.success([store(connected: true)])],
            authorizations: [.failure(.unauthorized), second]
        )
        let clock = StoreConnectionClock()
        let coordinator = StoreConnectionsCoordinator(client: client, scheduler: clock.scheduler)
        var rejectedTokens: [String] = []
        var changed = false
        coordinator.connect(
            store: store(),
            userId: "user",
            resolveToken: { rejected in
                if let rejected {
                    rejectedTokens.append(rejected); return "new-token"
                }
                return "old-token"
            },
            userIsCurrent: { true },
            onChange: { _ in changed = true }
        )
        await coordinator.waitForOperation()

        #expect(rejectedTokens == ["old-token"])
        #expect(await client.authorizationTokens == ["old-token", "new-token"])
        #expect(changed == !rejectRefresh)
        #expect((coordinator.errorMessage != nil) == rejectRefresh)
    }

    @Test("Ambiguous authorization submissions are never automatically repeated")
    func ambiguousAuthorization() async {
        let client = StoreConnectionClientProbe(authorizations: [.failure(.networkAmbiguous)])
        let clock = StoreConnectionClock()
        let coordinator = StoreConnectionsCoordinator(client: client, scheduler: clock.scheduler)
        connect(coordinator)
        await coordinator.waitForOperation()

        #expect(await client.authorizationTokens.count == 1)
        #expect(await client.pollCount == 0)
        #expect(coordinator.errorMessage == L10n.text("store_link_failed"))
    }

    @Test("Canceling a pending authorization discards its late result")
    func cancellation() async {
        let gate = StoreConnectionGate()
        let client = StoreConnectionClientProbe(authorizationGate: gate)
        let clock = StoreConnectionClock()
        let coordinator = StoreConnectionsCoordinator(client: client, scheduler: clock.scheduler)
        var changed = false
        connect(coordinator) { _ in changed = true }
        let completion = Task { await coordinator.waitForOperation() }
        await gate.waitUntilEntered()
        coordinator.cancel(clearStores: true)
        await gate.release()
        await completion.value

        #expect(!changed)
        #expect(await client.pollCount == 0)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.stores.isEmpty)
        #expect(!coordinator.hasLoaded)
        #expect(coordinator.errorMessage == nil)
    }

    @Test("Switching NVIDIA accounts discards a pending connection result")
    func accountSwitch() async {
        let gate = StoreConnectionGate()
        let client = StoreConnectionClientProbe(authorizationGate: gate)
        let clock = StoreConnectionClock()
        let coordinator = StoreConnectionsCoordinator(client: client, scheduler: clock.scheduler)
        var current = true
        var changed = false
        coordinator.connect(
            store: store(),
            userId: "old-user",
            resolveToken: { _ in "token" },
            userIsCurrent: { current },
            onChange: { _ in changed = true }
        )
        await gate.waitUntilEntered()
        current = false
        await gate.release()
        await coordinator.waitForOperation()

        #expect(!changed)
        #expect(await client.pollCount == 0)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.stores.isEmpty)
        #expect(coordinator.errorMessage == nil)
    }

    @Test("Cancellation during clock access cannot restore the QR phase")
    func cancellationDuringClockAccess() async {
        let gate = StoreConnectionGate()
        let client = StoreConnectionClientProbe()
        let scheduler = LibraryRefreshScheduler(now: {
            await gate.enter()
            return 0
        }, sleep: { _ in })
        let coordinator = StoreConnectionsCoordinator(client: client, scheduler: scheduler)
        connect(coordinator)
        let completion = Task { await coordinator.waitForOperation() }
        await gate.waitUntilEntered()
        coordinator.cancel()
        await gate.release()
        await completion.value

        #expect(coordinator.phase == .idle)
        #expect(coordinator.authorization == nil)
        #expect(await client.pollCount == 0)
    }

    @Test("Disconnect waits until LCARS confirms the store is disconnected")
    func disconnectConfirmation() async {
        let client = StoreConnectionClientProbe(discoveries: [
            .success([store(connected: true)]),
            .success([store()]),
        ])
        let clock = StoreConnectionClock()
        let coordinator = StoreConnectionsCoordinator(client: client, scheduler: clock.scheduler)
        var changes: [StoreConnection] = []
        coordinator.disconnect(
            store: store(connected: true),
            userId: "user",
            resolveToken: { _ in "token" },
            userIsCurrent: { true },
            onChange: { changes.append($0) }
        )
        await coordinator.waitForOperation()

        #expect(await client.disconnectCount == 1)
        #expect(await client.discoveryCount == 2)
        #expect(changes == [store()])
        #expect(coordinator.errorMessage == nil)
    }

    @Test("An ambiguous disconnect is not retried and cannot report success")
    func ambiguousDisconnect() async {
        let client = StoreConnectionClientProbe(disconnectError: .networkAmbiguous)
        let clock = StoreConnectionClock()
        let coordinator = StoreConnectionsCoordinator(client: client, scheduler: clock.scheduler)
        var changed = false
        coordinator.disconnect(
            store: store(connected: true),
            userId: "user",
            resolveToken: { _ in "token" },
            userIsCurrent: { true },
            onChange: { _ in changed = true }
        )
        await coordinator.waitForOperation()

        #expect(await client.disconnectCount == 1)
        #expect(!changed)
        #expect(coordinator.errorMessage == L10n.text("store_disconnect_failed"))
    }

    @Test("Unsupported store actions and concurrent operations do not send requests")
    func unsupportedAndBusyGuards() async {
        let gate = StoreConnectionGate()
        let client = StoreConnectionClientProbe(authorizationGate: gate)
        let clock = StoreConnectionClock()
        let coordinator = StoreConnectionsCoordinator(client: client, scheduler: clock.scheduler)
        coordinator.connect(
            store: store(supportsLinking: false),
            userId: "user", resolveToken: { _ in "token" }, userIsCurrent: { true }, onChange: { _ in }
        )
        coordinator.disconnect(
            store: store(),
            userId: "user", resolveToken: { _ in "token" }, userIsCurrent: { true }, onChange: { _ in }
        )
        #expect(await client.authorizationTokens.isEmpty)
        #expect(await client.disconnectCount == 0)

        connect(coordinator)
        let completion = Task { await coordinator.waitForOperation() }
        await gate.waitUntilEntered()
        connect(coordinator)
        coordinator.refresh(userId: "user", resolveToken: { _ in "token" }, userIsCurrent: { true })
        coordinator.disconnect(
            store: store(connected: true),
            userId: "user", resolveToken: { _ in "token" }, userIsCurrent: { true }, onChange: { _ in }
        )
        coordinator.cancel()
        await gate.release()
        await completion.value

        #expect(await client.authorizationTokens.count == 1)
        #expect(await client.disconnectCount == 0)
        #expect(await client.discoveryCount == 0)
    }

    private func connect(
        _ coordinator: StoreConnectionsCoordinator,
        onChange: @escaping StoreConnectionsCoordinator.ConnectionChanged = { _ in }
    ) {
        coordinator.connect(
            store: store(), userId: "user", resolveToken: { _ in "token" },
            userIsCurrent: { true }, onChange: onChange
        )
    }
}

private nonisolated func store(
    connected: Bool = false,
    requiresReconnect: Bool = false,
    isExpired: Bool = false,
    supportsLinking: Bool = true,
    syncState: ProviderAccountSyncState? = nil
) -> StoreConnection {
    StoreConnection(
        code: "STEAM", displayName: "Steam", accountDisplayName: connected ? "Player" : nil,
        iconURL: nil, isConnected: connected, requiresReconnect: requiresReconnect,
        supportsLinking: supportsLinking, supportsSync: supportsLinking,
        supportsAutomaticSignIn: false, isExpired: isExpired, sortOrder: 0,
        snapshot: syncState.map {
            ProviderSyncSnapshot(providerCode: "STEAM", totalSyncedGames: nil, state: $0, syncDate: nil)
        }
    )
}

private nonisolated func authorization(expiresIn: TimeInterval = 600) -> StoreDeviceAuthorization {
    StoreDeviceAuthorization(
        deviceCode: "device", userCode: "ABCD-EFGH",
        verificationURL: URL(string: "https://gfn.link/connect")!,
        verificationURLComplete: URL(string: "https://gfn.link/connect?user_code=ABCD-EFGH")!,
        expiresIn: expiresIn, interval: 5
    )
}

private actor StoreConnectionClientProbe {
    var discoveryCount = 0
    var authorizationTokens: [String] = []
    var pollCount = 0
    var disconnectCount = 0
    private var discoveries: [Result<[StoreConnection], StoreConnectionError>]
    private var authorizations: [Result<StoreDeviceAuthorization, StoreConnectionError>]
    private var polls: [Result<StoreAuthorizationStatus, StoreConnectionError>]
    private let authorizationGate: StoreConnectionGate?
    private let disconnectError: StoreConnectionError?

    init(
        discoveries: [Result<[StoreConnection], StoreConnectionError>] = [.success([])],
        authorizations: [Result<StoreDeviceAuthorization, StoreConnectionError>] = [.success(authorization())],
        polls: [Result<StoreAuthorizationStatus, StoreConnectionError>] = [.success(.authorized)],
        authorizationGate: StoreConnectionGate? = nil,
        disconnectError: StoreConnectionError? = nil
    ) {
        self.discoveries = discoveries
        self.authorizations = authorizations
        self.polls = polls
        self.authorizationGate = authorizationGate
        self.disconnectError = disconnectError
    }

    func discoverStores(token _: String, userId _: String) async throws -> [StoreConnection] {
        discoveryCount += 1
        return try discoveries[min(discoveryCount - 1, discoveries.count - 1)].get()
    }

    func requestAuthorization(providerCode _: String, token: String) async throws -> StoreDeviceAuthorization {
        authorizationTokens.append(token)
        await authorizationGate?.enter()
        return try authorizations[min(authorizationTokens.count - 1, authorizations.count - 1)].get()
    }

    func pollAuthorization(deviceCode _: String) async throws -> StoreAuthorizationStatus {
        pollCount += 1
        return try polls[min(pollCount - 1, polls.count - 1)].get()
    }

    func disconnect(providerCode _: String, token _: String) async throws {
        disconnectCount += 1
        if let disconnectError {
            throw disconnectError
        }
    }
}

extension StoreConnectionClientProbe: StoreConnectionClient {}

private actor StoreConnectionClock {
    var sleeps: [TimeInterval] = []
    private var time: TimeInterval = 0

    nonisolated var scheduler: LibraryRefreshScheduler {
        LibraryRefreshScheduler(now: { await self.now() }, sleep: { await self.sleep($0) })
    }

    private func now() -> TimeInterval {
        time
    }

    private func sleep(_ seconds: TimeInterval) {
        sleeps.append(seconds)
        time += seconds
    }
}

private actor StoreConnectionGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        waiter?.resume()
        waiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered {
            return
        }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
