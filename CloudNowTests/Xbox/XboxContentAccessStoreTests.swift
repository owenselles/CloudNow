@testable import CloudNow
import Foundation
import Synchronization
import Testing

@Suite("Xbox Content Access store")
struct XboxContentAccessStoreTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Concurrent identical requests share one upstream operation")
    func concurrentRequestsCoalesce() async throws {
        let snapshot = makeSnapshot(tier: .pcGamePass)
        let upstream = XboxContentAccessUpstreamProbe(
            responses: [.success(snapshot)],
            holdsRequests: true
        )
        let store = makeStore(upstream: upstream)
        let account = makeAccount(identifier: "account-a")

        let first = Task {
            try await store.fetchContentAccess(
                for: account,
                market: "US",
                offeringID: "xgpuweb"
            )
        }
        await upstream.waitForRequestCount(1)
        let second = Task {
            try await store.fetchContentAccess(
                for: account,
                market: "US",
                offeringID: "xgpuweb"
            )
        }
        await upstream.releaseAllRequests()

        #expect(try await first.value == snapshot)
        #expect(try await second.value == snapshot)
        #expect(await upstream.requests().count == 1)
    }

    @Test("Fresh normalized contexts use the memory cache")
    func freshCacheHit() async throws {
        let snapshot = makeSnapshot(tier: .ultimate)
        let upstream = XboxContentAccessUpstreamProbe(responses: [.success(snapshot)])
        let store = makeStore(upstream: upstream)
        let account = makeAccount(identifier: "account-a")

        let first = try await store.fetchContentAccess(
            for: account,
            market: " us ",
            offeringID: " XGPUWEB "
        )
        let second = try await store.fetchContentAccess(
            for: account,
            market: "US",
            offeringID: "xgpuweb"
        )

        #expect(first == snapshot)
        #expect(second == snapshot)
        let request = try #require(await upstream.requests().first)
        #expect(request.market == "US")
        #expect(request.offeringID == "xgpuweb")
        #expect(await upstream.requests().count == 1)
    }

    @Test("An expired entry is replaced by a new upstream snapshot")
    func expiryRefetches() async throws {
        let firstSnapshot = makeSnapshot(tier: .pcGamePass)
        let secondSnapshot = XboxContentAccessSnapshot(
            membershipTier: .ultimate,
            fetchedAt: fixedDate.addingTimeInterval(301)
        )
        let clock = XboxContentAccessTestClock(fixedDate)
        let upstream = XboxContentAccessUpstreamProbe(responses: [
            .success(firstSnapshot),
            .success(secondSnapshot),
        ])
        let store = makeStore(upstream: upstream, clock: clock)
        let account = makeAccount(identifier: "account-a")

        #expect(
            try await store.fetchContentAccess(
                for: account,
                market: "US",
                offeringID: "xgpuweb"
            ) == firstSnapshot
        )
        clock.advance(by: 299)
        #expect(
            try await store.fetchContentAccess(
                for: account,
                market: "US",
                offeringID: "xgpuweb"
            ) == firstSnapshot
        )
        clock.advance(by: 1)
        #expect(
            try await store.fetchContentAccess(
                for: account,
                market: "US",
                offeringID: "xgpuweb"
            ) == secondSnapshot
        )
        #expect(await upstream.requests().count == 2)
    }

    @Test("Account, market, and offering contexts stay separate and bounded")
    func keysAndEvictionAreBounded() async throws {
        let snapshot = makeSnapshot(tier: .pcGamePass)
        let upstream = XboxContentAccessUpstreamProbe(
            responses: Array(repeating: .success(snapshot), count: 5)
        )
        let store = makeStore(upstream: upstream)
        let firstAccount = makeAccount(identifier: "account-a")
        let secondAccount = makeAccount(identifier: "account-b")

        _ = try await store.fetchContentAccess(
            for: firstAccount,
            market: "US",
            offeringID: "xgpuweb"
        )
        _ = try await store.fetchContentAccess(
            for: firstAccount,
            market: "DE",
            offeringID: "xgpuweb"
        )
        _ = try await store.fetchContentAccess(
            for: firstAccount,
            market: "DE",
            offeringID: "xgpuwebf2p"
        )
        _ = try await store.fetchContentAccess(
            for: secondAccount,
            market: "DE",
            offeringID: "xgpuwebf2p"
        )
        _ = try await store.fetchContentAccess(
            for: firstAccount,
            market: "US",
            offeringID: "xgpuweb"
        )

        let requests = await upstream.requests()
        #expect(requests.count == 5)
        #expect(Set(requests.map(\.accountIdentifier)) == ["account-a", "account-b"])
        #expect(Set(requests.map(\.market)) == ["US", "DE"])
        #expect(Set(requests.map(\.offeringID)) == ["xgpuweb", "xgpuwebf2p"])
    }

    @Test("A failed operation is not cached")
    func failureRetries() async throws {
        let snapshot = makeSnapshot(tier: .essential)
        let upstream = XboxContentAccessUpstreamProbe(responses: [
            .failure(.injected),
            .success(snapshot),
        ])
        let store = makeStore(upstream: upstream)
        let account = makeAccount(identifier: "account-a")

        await #expect(throws: XboxContentAccessStoreProbeError.injected) {
            _ = try await store.fetchContentAccess(
                for: account,
                market: "US",
                offeringID: "xgpuweb"
            )
        }
        #expect(
            try await store.fetchContentAccess(
                for: account,
                market: "US",
                offeringID: "xgpuweb"
            ) == snapshot
        )
        #expect(await upstream.requests().count == 2)
    }

    @Test("Canceling one waiter does not cancel shared work")
    func callerCancellationIsIsolated() async throws {
        let snapshot = makeSnapshot(tier: .pcGamePass)
        let upstream = XboxContentAccessUpstreamProbe(
            responses: [.success(snapshot)],
            holdsRequests: true
        )
        let store = makeStore(upstream: upstream)
        let account = makeAccount(identifier: "account-a")
        let canceledCaller = Task {
            try await store.fetchContentAccess(
                for: account,
                market: "US",
                offeringID: "xgpuweb"
            )
        }
        await upstream.waitForRequestCount(1)
        canceledCaller.cancel()
        let survivingCaller = Task {
            try await store.fetchContentAccess(
                for: account,
                market: "US",
                offeringID: "xgpuweb"
            )
        }

        await upstream.releaseAllRequests()

        await #expect(throws: CancellationError.self) {
            _ = try await canceledCaller.value
        }
        #expect(try await survivingCaller.value == snapshot)
        #expect(await upstream.requests().count == 1)
    }

    private func makeStore(
        upstream: XboxContentAccessUpstreamProbe,
        clock: XboxContentAccessTestClock? = nil
    ) -> XboxContentAccessStore {
        let clock = clock ?? XboxContentAccessTestClock(fixedDate)
        return XboxContentAccessStore(
            upstream: upstream,
            now: { clock.now() }
        )
    }

    private func makeAccount(identifier: String) -> XboxCloudAuthorizedAccount {
        XboxCloudAuthorizedAccount(
            authorizationIdentifier: identifier,
            displayName: nil,
            expiresAt: fixedDate.addingTimeInterval(3600)
        )
    }

    private func makeSnapshot(tier: XboxMembershipTier) -> XboxContentAccessSnapshot {
        XboxContentAccessSnapshot(
            membershipTier: tier,
            fetchedAt: fixedDate
        )
    }
}

private nonisolated enum XboxContentAccessStoreProbeError: Error, Equatable, Sendable {
    case injected
    case missingResponse
}

private actor XboxContentAccessUpstreamProbe: XboxContentAccessProviding {
    struct Request: Equatable, Sendable {
        let accountIdentifier: String
        let market: String
        let offeringID: String
    }

    private struct RequestWaiter {
        let targetCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var responses: [Result<XboxContentAccessSnapshot, XboxContentAccessStoreProbeError>]
    private var recordedRequests: [Request] = []
    private var requestWaiters: [RequestWaiter] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var holdsRequests: Bool

    init(
        responses: [Result<XboxContentAccessSnapshot, XboxContentAccessStoreProbeError>],
        holdsRequests: Bool = false
    ) {
        self.responses = responses
        self.holdsRequests = holdsRequests
    }

    func fetchContentAccess(
        for account: XboxCloudAuthorizedAccount,
        market: String,
        offeringID: String
    ) async throws -> XboxContentAccessSnapshot {
        recordedRequests.append(Request(
            accountIdentifier: account.authorizationIdentifier,
            market: market,
            offeringID: offeringID
        ))
        resumeSatisfiedRequestWaiters()
        if holdsRequests {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        guard !responses.isEmpty else {
            throw XboxContentAccessStoreProbeError.missingResponse
        }
        return try responses.removeFirst().get()
    }

    func waitForRequestCount(_ count: Int) async {
        guard recordedRequests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(RequestWaiter(
                targetCount: count,
                continuation: continuation
            ))
        }
    }

    func releaseAllRequests() {
        holdsRequests = false
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func requests() -> [Request] {
        recordedRequests
    }

    private func resumeSatisfiedRequestWaiters() {
        var pendingWaiters: [RequestWaiter] = []
        for waiter in requestWaiters {
            if recordedRequests.count >= waiter.targetCount {
                waiter.continuation.resume()
            } else {
                pendingWaiters.append(waiter)
            }
        }
        requestWaiters = pendingWaiters
    }
}

private final class XboxContentAccessTestClock: Sendable {
    private let value: Mutex<Date>

    init(_ date: Date) {
        value = Mutex(date)
    }

    func now() -> Date {
        value.withLock { $0 }
    }

    func advance(by interval: TimeInterval) {
        value.withLock { date in
            date = date.addingTimeInterval(interval)
        }
    }
}
