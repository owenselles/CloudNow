import Foundation
import Observation

nonisolated enum ProviderSyncPhase: Equatable, Sendable {
    case queued
    case requesting
    case syncing
    case succeeded(gameCount: Int?)
    case failed(message: String)
    case timedOut
    case relinkRequired
    case skipped

    var isTerminal: Bool {
        switch self {
        case .queued, .requesting, .syncing:
            false
        case .succeeded, .failed, .timedOut, .relinkRequired, .skipped:
            true
        }
    }

    var isFailure: Bool {
        switch self {
        case .failed, .timedOut, .relinkRequired:
            true
        case .queued, .requesting, .syncing, .succeeded, .skipped:
            false
        }
    }

    var isRetryable: Bool {
        switch self {
        case .failed, .timedOut:
            true
        case .queued, .requesting, .syncing, .succeeded, .relinkRequired, .skipped:
            false
        }
    }
}

nonisolated struct ProviderSyncProgress: Identifiable, Equatable, Sendable {
    var id: String {
        providerCode
    }

    let providerCode: String
    let displayName: String
    let accountName: String?
    var phase: ProviderSyncPhase
}

nonisolated struct LibraryRefreshSummary: Equatable, Sendable {
    let successfulProviderCount: Int
    let failedProviderCount: Int
    let skippedProviderCount: Int
    let finalGameCount: Int
    let addedGameIDs: Set<String>
    let removedGameIDs: Set<String>
}

nonisolated struct LibraryImportResult: Equatable, Sendable {
    let finalGameCount: Int
    let addedGameIDs: Set<String>
    let removedGameIDs: Set<String>
}

nonisolated enum FullLibraryRefreshStage: Equatable, Sendable {
    case idle
    case discovering
    case syncing
    case settling
    case importing
    case completed
    case partialFailure
    case failed
}

nonisolated struct FullLibraryRefreshState: Equatable, Sendable {
    var stage: FullLibraryRefreshStage = .idle
    var providers: [ProviderSyncProgress] = []
    var finalPhase: ProviderSyncPhase = .queued
    var summary: LibraryRefreshSummary?
    var warning: String?

    var isRunning: Bool {
        switch stage {
        case .discovering, .syncing, .settling, .importing:
            true
        case .idle, .completed, .partialFailure, .failed:
            false
        }
    }

    var hasRetryableFailures: Bool {
        finalPhase.isRetryable
            || providers.contains { $0.phase.isRetryable }
    }

    var completedStepCount: Int {
        guard stage != .idle else { return 0 }
        let completedProviders = providers.count { $0.phase.isTerminal }
        return completedProviders + (finalPhase.isTerminal ? 1 : 0)
    }

    var totalStepCount: Int {
        max(1, providers.count + 1)
    }

    var progressFraction: Double {
        min(1, Double(completedStepCount) / Double(totalStepCount))
    }
}

nonisolated struct LibraryRefreshScheduler: Sendable {
    let now: @Sendable () async -> TimeInterval
    let sleep: @Sendable (_ seconds: TimeInterval) async throws -> Void
    let deadlineSleep: @Sendable (_ seconds: TimeInterval) async throws -> Void

    init(
        now: @escaping @Sendable () async -> TimeInterval,
        sleep: @escaping @Sendable (_ seconds: TimeInterval) async throws -> Void,
        deadlineSleep: @escaping @Sendable (
            _ seconds: TimeInterval
        ) async throws -> Void = { seconds in
            try await ContinuousClock().sleep(for: .seconds(seconds))
        }
    ) {
        self.now = now
        self.sleep = sleep
        self.deadlineSleep = deadlineSleep
    }

    static let continuous: Self = {
        let clock = ContinuousClock()
        let origin = clock.now
        return Self(
            now: {
                let elapsed = origin.duration(to: clock.now).components
                return Double(elapsed.seconds)
                    + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
            },
            sleep: { seconds in
                try await clock.sleep(for: .seconds(seconds))
            },
            deadlineSleep: { seconds in
                try await clock.sleep(for: .seconds(seconds))
            }
        )
    }()
}

private actor ProviderDeadlineRace<Value: Sendable> {
    typealias Outcome = Result<Value, any Error>

    private var outcome: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?
    private var operationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    func install(
        operationTask: Task<Void, Never>,
        deadlineTask: Task<Void, Never>
    ) {
        guard outcome == nil else {
            operationTask.cancel()
            deadlineTask.cancel()
            return
        }
        self.operationTask = operationTask
        self.deadlineTask = deadlineTask
    }

    func value() async -> Outcome {
        if let outcome {
            return outcome
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func resolve(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        operationTask?.cancel()
        deadlineTask?.cancel()
        operationTask = nil
        deadlineTask = nil
        waiter?.resume(returning: outcome)
        waiter = nil
    }
}

@Observable
@MainActor
final class LibraryRefreshCoordinator {
    typealias TokenResolver = @MainActor @Sendable (
        _ rejectedToken: String?
    ) async throws -> String
    typealias UserValidator = @MainActor @Sendable () -> Bool
    typealias LibraryImporter = @MainActor @Sendable () async throws -> LibraryImportResult

    private struct RunContext {
        let generation: UInt64
        let userId: String
        let retryProviderCodes: Set<String>?
        let previousProviders: [String: ProviderSyncProgress]
        let previousBaselines: [String: SyncBaseline]
        let unresolvedSubmissionProviderCodes: Set<String>
        let resolveToken: TokenResolver
        let userIsCurrent: UserValidator
        let importLibrary: LibraryImporter
    }

    private nonisolated struct SyncBaseline: Sendable {
        let syncDate: Date?
    }

    private nonisolated struct ProviderDeadlineExceeded: Error {}

    private nonisolated struct TriggerResult: Sendable {
        let providerCode: String
        let phase: ProviderSyncPhase
        let accepted: Bool
        let refreshedToken: String?
        let retryNotBefore: TimeInterval?

        init(
            providerCode: String,
            phase: ProviderSyncPhase,
            accepted: Bool,
            refreshedToken: String?,
            retryNotBefore: TimeInterval? = nil
        ) {
            self.providerCode = providerCode
            self.phase = phase
            self.accepted = accepted
            self.refreshedToken = refreshedToken
            self.retryNotBefore = retryNotBefore
        }
    }

    private let client: any LibrarySyncClient
    private let scheduler: LibraryRefreshScheduler
    private let initialPollInterval: TimeInterval
    private let maximumPollInterval: TimeInterval
    private let providerTimeout: TimeInterval
    private let propagationDelay: TimeInterval

    private(set) var state = FullLibraryRefreshState()
    private var activeTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var previousBaselines: [String: SyncBaseline] = [:]
    private var retryNotBefore: [String: TimeInterval] = [:]
    private var unresolvedSubmissionProviderCodes = Set<String>()

    init(
        client: any LibrarySyncClient,
        scheduler: LibraryRefreshScheduler = .continuous,
        initialPollInterval: TimeInterval = 2,
        maximumPollInterval: TimeInterval = 5,
        providerTimeout: TimeInterval = 60,
        propagationDelay: TimeInterval = 5,
        initialState: FullLibraryRefreshState = FullLibraryRefreshState()
    ) {
        self.client = client
        self.scheduler = scheduler
        self.initialPollInterval = max(0, initialPollInterval)
        self.maximumPollInterval = max(initialPollInterval, maximumPollInterval)
        self.providerTimeout = max(0, providerTimeout)
        self.propagationDelay = max(0, propagationDelay)
        state = initialState
    }

    @discardableResult
    func start(
        userId: String,
        retryProviderCodes: Set<String>? = nil,
        resolveToken: @escaping TokenResolver,
        userIsCurrent: @escaping UserValidator,
        importLibrary: @escaping LibraryImporter
    ) -> Bool {
        guard activeTask == nil else { return false }

        generation &+= 1
        let runGeneration = generation
        let previousProviders = Dictionary(
            state.providers.map { ($0.providerCode, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        state = FullLibraryRefreshState(stage: .discovering)
        let context = RunContext(
            generation: runGeneration,
            userId: userId,
            retryProviderCodes: retryProviderCodes,
            previousProviders: previousProviders,
            previousBaselines: previousBaselines,
            unresolvedSubmissionProviderCodes: unresolvedSubmissionProviderCodes,
            resolveToken: resolveToken,
            userIsCurrent: userIsCurrent,
            importLibrary: importLibrary
        )

        activeTask = Task { @MainActor [weak self] in
            await self?.run(context)
        }
        return true
    }

    func cancel(resetState: Bool = true) {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        if resetState {
            state = FullLibraryRefreshState()
            previousBaselines = [:]
            retryNotBefore = [:]
            unresolvedSubmissionProviderCodes = []
        }
    }

    func acknowledgeCompletion() {
        guard !state.isRunning else { return }
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        state = FullLibraryRefreshState()
    }

    private func run(_ context: RunContext) async {
        defer {
            if context.generation == generation {
                activeTask = nil
            }
        }

        do {
            var token = try await context.resolveToken(nil)
            try requireAccepted(context)

            let discovery: [ConnectedGameLibrary]
            do {
                let result = try await authenticated(
                    token: token,
                    resolveToken: context.resolveToken
                ) { token in
                    try await self.client.discover(
                        token: token,
                        userId: context.userId
                    )
                }
                discovery = result.value
                token = result.token
            } catch {
                try requireAccepted(context)
                state.warning = warningMessage(for: error)
                state.stage = .importing
                state.finalPhase = .syncing
                try await finishImport(context)
                return
            }

            try requireAccepted(context)
            let baselines = Dictionary(
                discovery.map {
                    ($0.code, $0.snapshot.syncDate)
                },
                uniquingKeysWith: { first, _ in first }
            )
            state.providers = discovery.map { provider in
                ProviderSyncProgress(
                    providerCode: provider.code,
                    displayName: provider.displayName,
                    accountName: provider.accountDisplayName,
                    phase: initialPhase(
                        for: provider,
                        retryProviderCodes: context.retryProviderCodes,
                        previousProviders: context.previousProviders,
                        previousBaselines: context.previousBaselines,
                        unresolvedSubmissionProviderCodes:
                        context.unresolvedSubmissionProviderCodes
                    )
                )
            }
            let rediscoveredTerminalCodes = Set<String>(discovery.compactMap { provider -> String? in
                guard context.unresolvedSubmissionProviderCodes.contains(
                    provider.code
                ),
                    let previousBaseline = context.previousBaselines[provider.code],
                    isNew(
                        provider.snapshot.syncDate,
                        than: previousBaseline.syncDate
                    ),
                    snapshotPhase(provider.snapshot).isTerminal
                else {
                    return nil
                }
                return provider.code
            })
            unresolvedSubmissionProviderCodes.subtract(
                rediscoveredTerminalCodes
            )
            previousBaselines = Dictionary(
                discovery.map {
                    ($0.code, SyncBaseline(syncDate: $0.snapshot.syncDate))
                },
                uniquingKeysWith: { first, _ in first }
            )
            await Task.yield()
            try requireAccepted(context)

            let eligibleCodes = Set(state.providers.compactMap { provider in
                provider.phase == .queued ? provider.providerCode : nil
            })
            var acceptedCodes = Set(state.providers.compactMap { provider in
                context.unresolvedSubmissionProviderCodes.contains(
                    provider.providerCode
                ) && provider.phase == .syncing
                    ? provider.providerCode
                    : nil
            })
            var didAcceptProvider = !acceptedCodes.isEmpty

            if !eligibleCodes.isEmpty || !acceptedCodes.isEmpty {
                state.stage = .syncing
                mutateProviders(codes: eligibleCodes) { $0.phase = .requesting }
                let providerDeadline = await scheduler.now() + providerTimeout
                try requireAccepted(context)

                let triggerResults = if eligibleCodes.isEmpty {
                    [TriggerResult]()
                } else {
                    try await triggerProviders(
                        eligibleCodes,
                        token: token,
                        deadline: providerDeadline,
                        retryNotBefore: retryNotBefore,
                        resolveToken: context.resolveToken,
                        context: context
                    )
                }
                try requireAccepted(context)

                for result in triggerResults {
                    mutateProvider(code: result.providerCode) {
                        $0.phase = result.phase
                    }
                    if result.accepted {
                        didAcceptProvider = true
                        unresolvedSubmissionProviderCodes.insert(
                            result.providerCode
                        )
                        if result.phase == .syncing {
                            acceptedCodes.insert(result.providerCode)
                        }
                    }
                    if let refreshedToken = result.refreshedToken {
                        token = refreshedToken
                    }
                    if let deadline = result.retryNotBefore {
                        retryNotBefore[result.providerCode] = deadline
                    } else {
                        retryNotBefore[result.providerCode] = nil
                    }
                }

                if triggerResults.contains(where: { $0.phase == .skipped }) {
                    failClosedProviderSync()
                    acceptedCodes = []
                } else {
                    try await pollProviders(
                        acceptedCodes,
                        baselines: baselines,
                        token: &token,
                        deadline: providerDeadline,
                        context: context
                    )
                }
            }

            try requireAccepted(context)
            if didAcceptProvider, propagationDelay > 0 {
                state.stage = .settling
                try await scheduler.sleep(propagationDelay)
            }
            try requireAccepted(context)
            state.stage = .importing
            state.finalPhase = .syncing
            try await finishImport(context)
        } catch is CancellationError {
            guard context.generation == generation else { return }
            guard context.userIsCurrent() else {
                state = FullLibraryRefreshState()
                return
            }
            let message = L10n.text("refresh_failed")
            for index in state.providers.indices
                where !state.providers[index].phase.isTerminal
            {
                state.providers[index].phase = .failed(message: "")
            }
            state.stage = .failed
            state.finalPhase = .failed(message: message)
        } catch {
            guard accepts(context) else { return }
            state.stage = .failed
            state.finalPhase = .failed(message: L10n.text("refresh_failed"))
        }
    }

    private func initialPhase(
        for provider: ConnectedGameLibrary,
        retryProviderCodes: Set<String>?,
        previousProviders: [String: ProviderSyncProgress],
        previousBaselines: [String: SyncBaseline],
        unresolvedSubmissionProviderCodes: Set<String>
    ) -> ProviderSyncPhase {
        guard provider.supportsSync else { return .skipped }
        if unresolvedSubmissionProviderCodes.contains(provider.code) {
            if let previousBaseline = previousBaselines[provider.code],
               isNew(
                   provider.snapshot.syncDate,
                   than: previousBaseline.syncDate
               )
            {
                return snapshotPhase(provider.snapshot)
            }
            return .syncing
        }
        guard let retryProviderCodes else { return .queued }
        guard retryProviderCodes.contains(provider.code) else {
            return previousProviders[provider.code]?.phase
                ?? snapshotPhase(provider.snapshot)
        }
        if let previousBaseline = previousBaselines[provider.code],
           isNew(
               provider.snapshot.syncDate,
               than: previousBaseline.syncDate
           )
        {
            return snapshotPhase(provider.snapshot)
        }
        return .queued
    }

    private func triggerProviders(
        _ providerCodes: Set<String>,
        token: String,
        deadline: TimeInterval,
        retryNotBefore: [String: TimeInterval],
        resolveToken: @escaping TokenResolver,
        context: RunContext
    ) async throws -> [TriggerResult] {
        try await withThrowingTaskGroup(of: TriggerResult.self) { group in
            for providerCode in providerCodes {
                group.addTask { [client, scheduler] in
                    try await Self.triggerProvider(
                        providerCode,
                        token: token,
                        client: client,
                        scheduler: scheduler,
                        deadline: deadline,
                        retryNotBefore: retryNotBefore[providerCode],
                        resolveToken: resolveToken
                    )
                }
            }

            var results: [TriggerResult] = []
            for try await result in group {
                try requireAccepted(context)
                results.append(result)
                mutateProvider(code: result.providerCode) {
                    $0.phase = result.phase
                }
            }
            return results
        }
    }

    private nonisolated static func triggerProvider(
        _ providerCode: String,
        token: String,
        client: any LibrarySyncClient,
        scheduler: LibraryRefreshScheduler,
        deadline: TimeInterval,
        retryNotBefore: TimeInterval?,
        resolveToken: @escaping TokenResolver
    ) async throws -> TriggerResult {
        var currentToken = token
        var refreshedToken: String?
        var didRefreshAuthentication = false

        while true {
            let currentTime = await scheduler.now()
            try Task.checkCancellation()
            guard currentTime < deadline else {
                return TriggerResult(
                    providerCode: providerCode,
                    phase: .timedOut,
                    accepted: false,
                    refreshedToken: refreshedToken
                )
            }
            if let retryNotBefore, currentTime < retryNotBefore {
                return TriggerResult(
                    providerCode: providerCode,
                    phase: .failed(message: ""),
                    accepted: false,
                    refreshedToken: refreshedToken,
                    retryNotBefore: retryNotBefore
                )
            }
            do {
                let submittedToken = currentToken
                try await withProviderDeadline(
                    deadline: deadline,
                    scheduler: scheduler
                ) {
                    try await client.requestSync(
                        providerCode: providerCode,
                        token: submittedToken
                    )
                }
                let completedAt = await scheduler.now()
                try Task.checkCancellation()
                return TriggerResult(
                    providerCode: providerCode,
                    phase: completedAt < deadline ? .syncing : .timedOut,
                    accepted: true,
                    refreshedToken: refreshedToken
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch LibrarySyncError.unauthorized where !didRefreshAuthentication {
                do {
                    let rejectedToken = currentToken
                    currentToken = try await withProviderDeadline(
                        deadline: deadline,
                        scheduler: scheduler
                    ) {
                        try await resolveToken(rejectedToken)
                    }
                    refreshedToken = currentToken
                    didRefreshAuthentication = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch is ProviderDeadlineExceeded {
                    return TriggerResult(
                        providerCode: providerCode,
                        phase: .timedOut,
                        accepted: false,
                        refreshedToken: nil
                    )
                } catch {
                    return TriggerResult(
                        providerCode: providerCode,
                        phase: .failed(message: ""),
                        accepted: false,
                        refreshedToken: nil
                    )
                }
            } catch is ProviderDeadlineExceeded {
                return TriggerResult(
                    providerCode: providerCode,
                    phase: .timedOut,
                    accepted: true,
                    refreshedToken: refreshedToken
                )
            } catch let LibrarySyncError.rateLimited(retryAfter) {
                let receivedAt = await scheduler.now()
                try Task.checkCancellation()
                let delay = max(0, retryAfter ?? 2)
                return TriggerResult(
                    providerCode: providerCode,
                    phase: .failed(message: ""),
                    accepted: false,
                    refreshedToken: refreshedToken,
                    retryNotBefore: receivedAt + delay
                )
            } catch LibrarySyncError.forbidden {
                return TriggerResult(
                    providerCode: providerCode,
                    phase: .relinkRequired,
                    accepted: false,
                    refreshedToken: refreshedToken
                )
            } catch LibrarySyncError.networkAmbiguous {
                return TriggerResult(
                    providerCode: providerCode,
                    phase: .syncing,
                    accepted: true,
                    refreshedToken: refreshedToken
                )
            } catch LibrarySyncError.schema {
                return TriggerResult(
                    providerCode: providerCode,
                    phase: .skipped,
                    accepted: false,
                    refreshedToken: refreshedToken
                )
            } catch {
                return TriggerResult(
                    providerCode: providerCode,
                    phase: .failed(message: ""),
                    accepted: false,
                    refreshedToken: refreshedToken
                )
            }
        }
    }

    private func pollProviders(
        _ providerCodes: Set<String>,
        baselines: [String: Date?],
        token: inout String,
        deadline: TimeInterval,
        context: RunContext
    ) async throws {
        guard !providerCodes.isEmpty else { return }
        var interval = initialPollInterval
        var pendingCodes = providerCodes
        var didPoll = false

        while !pendingCodes.isEmpty {
            try requireAccepted(context)
            let now = await scheduler.now()
            try requireAccepted(context)
            if now >= deadline, didPoll {
                markProvidersTimedOutAfterPolling(pendingCodes)
                return
            }

            if now < deadline {
                try await scheduler.sleep(min(interval, max(0, deadline - now)))
                try requireAccepted(context)
            }

            didPoll = true
            do {
                let requestToken = token
                let result = try await Self.withProviderDeadline(
                    deadline: deadline,
                    scheduler: scheduler
                ) {
                    try await self.authenticated(
                        token: requestToken,
                        resolveToken: context.resolveToken
                    ) { token in
                        try await self.client.fetchSnapshots(
                            token: token,
                            userId: context.userId
                        )
                    }
                }
                token = result.token
                try requireAccepted(context)
                let receivedAt = await scheduler.now()
                try requireAccepted(context)
                guard receivedAt <= deadline else {
                    markProvidersTimedOutAfterPolling(pendingCodes)
                    return
                }
                state.warning = nil
                let snapshots = Dictionary(
                    result.value.map {
                        ($0.providerCode, $0)
                    },
                    uniquingKeysWith: { _, last in last }
                )

                var completedCodes = Set<String>()
                for providerCode in pendingCodes {
                    guard let snapshot = snapshots[providerCode],
                          isNew(snapshot.syncDate, than: baselines[providerCode] ?? nil)
                    else {
                        continue
                    }
                    let phase = snapshotPhase(snapshot)
                    mutateProvider(code: providerCode) { $0.phase = phase }
                    if phase.isTerminal {
                        previousBaselines[providerCode] = SyncBaseline(
                            syncDate: snapshot.syncDate
                        )
                        unresolvedSubmissionProviderCodes.remove(providerCode)
                        completedCodes.insert(providerCode)
                    }
                }
                pendingCodes.subtract(completedCodes)
            } catch is CancellationError {
                throw CancellationError()
            } catch is ProviderDeadlineExceeded {
                try requireAccepted(context)
                markProvidersTimedOutAfterPolling(pendingCodes)
                return
            } catch LibrarySyncError.forbidden {
                try requireAccepted(context)
                state.warning = L10n.text("provider_sync_relink_required")
                mutateProviders(codes: pendingCodes) {
                    $0.phase = .relinkRequired
                }
                unresolvedSubmissionProviderCodes.subtract(pendingCodes)
                return
            } catch LibrarySyncError.unauthorized {
                try requireAccepted(context)
                state.warning = L10n.text("provider_sync_failed")
                mutateProviders(codes: pendingCodes) {
                    $0.phase = .failed(message: "")
                }
                return
            } catch LibrarySyncError.schema {
                try requireAccepted(context)
                failClosedProviderSync()
                return
            } catch let LibrarySyncError.rateLimited(retryAfter) {
                try requireAccepted(context)
                state.warning = L10n.text("provider_sync_failed")
                interval = max(
                    interval,
                    max(0, retryAfter ?? maximumPollInterval)
                )
                continue
            } catch {
                try requireAccepted(context)
                state.warning = warningMessage(for: error)
            }

            interval = min(maximumPollInterval, max(initialPollInterval, interval * 1.5))
        }
    }

    private func markProvidersTimedOutAfterPolling(_ providerCodes: Set<String>) {
        mutateProviders(codes: providerCodes) { $0.phase = .timedOut }
        unresolvedSubmissionProviderCodes.subtract(providerCodes)
    }

    private func finishImport(_ context: RunContext) async throws {
        try requireAccepted(context)
        let result = try await context.importLibrary()
        try requireAccepted(context)

        let successfulCount = state.providers.count {
            if case .succeeded = $0.phase {
                return true
            }
            return false
        }
        let failedCount = state.providers.count { $0.phase.isFailure }
        let skippedCount = state.providers.count { $0.phase == .skipped }
        let summary = LibraryRefreshSummary(
            successfulProviderCount: successfulCount,
            failedProviderCount: failedCount,
            skippedProviderCount: skippedCount,
            finalGameCount: result.finalGameCount,
            addedGameIDs: result.addedGameIDs,
            removedGameIDs: result.removedGameIDs
        )
        state.summary = summary
        state.finalPhase = .succeeded(gameCount: result.finalGameCount)
        state.stage = failedCount > 0 || state.warning != nil
            ? .partialFailure
            : .completed
    }

    private func authenticated<T: Sendable>(
        token: String,
        resolveToken: @escaping TokenResolver,
        operation: @Sendable (String) async throws -> T
    ) async throws -> (value: T, token: String) {
        do {
            let value = try await operation(token)
            return (value, token)
        } catch LibrarySyncError.unauthorized {
            let refreshedToken = try await resolveToken(token)
            let value = try await operation(refreshedToken)
            return (value, refreshedToken)
        }
    }

    private nonisolated static func withProviderDeadline<T: Sendable>(
        deadline: TimeInterval,
        scheduler: LibraryRefreshScheduler,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let now = await scheduler.now()
        try Task.checkCancellation()
        let remaining = deadline - now
        guard remaining > 0 else { throw ProviderDeadlineExceeded() }

        let race = ProviderDeadlineRace<T>()
        let operationTask = Task {
            do {
                let value = try await operation()
                await race.resolve(.success(value))
            } catch {
                await race.resolve(.failure(error))
            }
        }
        let deadlineTask = Task {
            do {
                try await scheduler.deadlineSleep(remaining)
                await race.resolve(.failure(ProviderDeadlineExceeded()))
            } catch is CancellationError {
                return
            } catch {
                await race.resolve(.failure(error))
            }
        }
        await race.install(
            operationTask: operationTask,
            deadlineTask: deadlineTask
        )

        let outcome = await withTaskCancellationHandler {
            await race.value()
        } onCancel: {
            Task {
                await race.resolve(.failure(CancellationError()))
            }
        }
        try Task.checkCancellation()
        return try outcome.get()
    }

    private func snapshotPhase(_ snapshot: ProviderSyncSnapshot) -> ProviderSyncPhase {
        switch snapshot.state {
        case .success:
            .succeeded(gameCount: snapshot.totalSyncedGames)
        case .failed:
            .failed(message: "")
        case .denied, .profileNotCreated:
            .relinkRequired
        case .unknown:
            .failed(message: "")
        }
    }

    private func isNew(_ date: Date?, than baseline: Date?) -> Bool {
        guard let date else { return false }
        guard let baseline else { return true }
        return date > baseline
    }

    private func mutateProvider(
        code: String,
        _ mutation: (inout ProviderSyncProgress) -> Void
    ) {
        guard let index = state.providers.firstIndex(where: {
            $0.providerCode == code
        }) else { return }
        mutation(&state.providers[index])
    }

    private func mutateProviders(
        codes: Set<String>,
        _ mutation: (inout ProviderSyncProgress) -> Void
    ) {
        for code in codes {
            mutateProvider(code: code, mutation)
        }
    }

    private func failClosedProviderSync() {
        state.warning = L10n.text("provider_sync_unavailable")
        for index in state.providers.indices {
            state.providers[index].phase = .skipped
        }
    }

    private func warningMessage(for error: Error) -> String {
        if let error = error as? LibrarySyncError {
            switch error {
            case .schema:
                return L10n.text("provider_sync_unavailable")
            case .forbidden:
                return L10n.text("provider_sync_relink_required")
            case .unauthorized, .rateLimited, .httpStatus, .network,
                 .networkAmbiguous:
                return L10n.text("provider_sync_failed")
            }
        }
        return L10n.text("provider_sync_failed")
    }

    private func accepts(_ context: RunContext) -> Bool {
        !Task.isCancelled
            && context.generation == generation
            && context.userIsCurrent()
    }

    private func requireAccepted(_ context: RunContext) throws {
        guard accepts(context) else { throw CancellationError() }
    }
}
