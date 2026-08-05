import Foundation
import Observation

nonisolated enum CloudGamingProvider: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case geForceNow = "geforce-now"
    case xboxCloudGaming = "xbox-cloud-gaming"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .geForceNow:
            "GeForce NOW"
        case .xboxCloudGaming:
            "Xbox Cloud Gaming"
        }
    }

    /// Keeps the fixed top-level service control compact while its menu and
    /// accessibility value continue to use the complete provider name.
    var navigationDisplayName: String {
        switch self {
        case .geForceNow:
            "GFN"
        case .xboxCloudGaming:
            "Xbox"
        }
    }

    var systemImage: String {
        switch self {
        case .geForceNow:
            "sparkles.tv"
        case .xboxCloudGaming:
            "gamecontroller.fill"
        }
    }
}

nonisolated enum CloudGamingProviderStartupPhase: Equatable, Sendable {
    case pending
    case restoringSelection
    case ready
}

nonisolated struct CloudGamingProviderSwitchIntent: Equatable, Sendable {
    fileprivate let generation: UInt64
    fileprivate let provider: CloudGamingProvider?
}

nonisolated struct CloudGamingCredentialMutation: Equatable, Sendable {
    fileprivate let generation: UInt64
}

nonisolated protocol CloudGamingProviderSelectionPersistence: Sendable {
    func loadSelectedCloudGamingProvider() async -> CloudGamingProvider?
    func hasStoredCloudGamingProviderSelection() async -> Bool
    func saveSelectedCloudGamingProvider(
        _ provider: CloudGamingProvider?,
        generation: UInt64
    ) async
}

extension AppPersistenceStore: CloudGamingProviderSelectionPersistence {}

@Observable
@MainActor
final class CloudGamingProviderCoordinator {
    private(set) var selectedProvider: CloudGamingProvider?
    private(set) var startupPhase: CloudGamingProviderStartupPhase
    private(set) var dataResetFailureMessage: String?
    private(set) var isProviderSwitchInProgress = false
    private(set) var isCredentialMutationInProgress = false

    var isProviderInteractionBlocked: Bool {
        isProviderSwitchInProgress || isCredentialMutationInProgress
    }

    var xboxAvailability: XboxCloudAvailability {
        xboxEnvironment.availability
    }

    var xboxServiceConfiguration: XboxCloudServiceConfiguration? {
        xboxEnvironment.service
    }

    /// A pre-provider-selection CloudNow install may still have a GeForce NOW
    /// session in the legacy credential namespace. Only that migration path
    /// should restore GFN credentials while the service chooser is visible.
    var requiresLegacyGeForceNowMigration: Bool {
        startupPhase == .ready
            && selectedProvider == nil
            && !hasStoredSelection
    }

    @ObservationIgnored private let persistence: any CloudGamingProviderSelectionPersistence
    @ObservationIgnored private let xboxEnvironment: XboxCloudEnvironment
    @ObservationIgnored private var selectionGeneration: UInt64 = 0
    @ObservationIgnored private var providerSwitchGeneration: UInt64 = 0
    @ObservationIgnored private var credentialMutationGeneration: UInt64 = 0
    @ObservationIgnored private var activeProviderSwitch: CloudGamingProviderSwitchIntent?
    @ObservationIgnored private var activeCredentialMutation: CloudGamingCredentialMutation?
    @ObservationIgnored private var hasStoredSelection: Bool
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var initializationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        persistence: any CloudGamingProviderSelectionPersistence = AppPersistenceStore.shared,
        xboxEnvironment: XboxCloudEnvironment = .unconfigured,
        initialSelection: CloudGamingProvider? = nil,
        startsReady: Bool = false
    ) {
        self.persistence = persistence
        self.xboxEnvironment = xboxEnvironment
        selectedProvider = initialSelection
        hasStoredSelection = initialSelection != nil
        startupPhase = startsReady ? .ready : .pending
    }

    isolated deinit {
        persistenceTask?.cancel()
    }

    func initialize() async {
        switch startupPhase {
        case .ready:
            return
        case .restoringSelection:
            await withCheckedContinuation { continuation in
                initializationWaiters.append(continuation)
            }
            return
        case .pending:
            break
        }
        startupPhase = .restoringSelection
        let generation = selectionGeneration
        async let restoredProvider = persistence.loadSelectedCloudGamingProvider()
        async let restoredSelectionFlag = persistence.hasStoredCloudGamingProviderSelection()
        let restored = await (restoredProvider, restoredSelectionFlag)
        guard generation == selectionGeneration else {
            finishInitialization()
            return
        }
        selectedProvider = restored.0
        hasStoredSelection = restored.1
        finishInitialization()
    }

    private func finishInitialization() {
        startupPhase = .ready
        let waiters = initializationWaiters
        initializationWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func select(_ provider: CloudGamingProvider?) {
        invalidateProviderSwitch()
        updateSelection(provider, forcesPersistence: false)
    }

    /// Reserves a provider transition while the active mode releases its
    /// transient work. The returned generation must still be current when the
    /// caller commits; credential deletion always invalidates older intents.
    func beginProviderSwitch(
        to provider: CloudGamingProvider?
    ) -> CloudGamingProviderSwitchIntent? {
        guard !isCredentialMutationInProgress,
              !isProviderSwitchInProgress,
              provider != selectedProvider
        else {
            return nil
        }
        providerSwitchGeneration &+= 1
        let intent = CloudGamingProviderSwitchIntent(
            generation: providerSwitchGeneration,
            provider: provider
        )
        activeProviderSwitch = intent
        isProviderSwitchInProgress = true
        return intent
    }

    @discardableResult
    func commitProviderSwitch(
        _ intent: CloudGamingProviderSwitchIntent
    ) -> Bool {
        guard !isCredentialMutationInProgress,
              activeProviderSwitch == intent,
              providerSwitchGeneration == intent.generation
        else {
            return false
        }
        activeProviderSwitch = nil
        isProviderSwitchInProgress = false
        updateSelection(intent.provider, forcesPersistence: false)
        return true
    }

    func cancelProviderSwitch(_ intent: CloudGamingProviderSwitchIntent) {
        guard activeProviderSwitch == intent else { return }
        invalidateProviderSwitch()
    }

    /// Credential deletion has priority over navigation. Starting a mutation
    /// invalidates any switch that may still be awaiting mode deactivation.
    func beginCredentialMutation() -> CloudGamingCredentialMutation? {
        guard !isCredentialMutationInProgress else { return nil }
        invalidateProviderSwitch()
        credentialMutationGeneration &+= 1
        let mutation = CloudGamingCredentialMutation(
            generation: credentialMutationGeneration
        )
        activeCredentialMutation = mutation
        isCredentialMutationInProgress = true
        return mutation
    }

    func finishCredentialMutation(_ mutation: CloudGamingCredentialMutation) {
        guard activeCredentialMutation == mutation else { return }
        activeCredentialMutation = nil
        isCredentialMutationInProgress = false
    }

    /// Preferences are removed before both independent Keychain deletions are
    /// known. A partial failure must persist the provider whose credential is
    /// still retained, even when it is already the visible selection.
    func preserveSelectionAfterFailedDataReset(
        _ provider: CloudGamingProvider
    ) {
        invalidateProviderSwitch()
        updateSelection(provider, forcesPersistence: true)
    }

    func presentDataResetFailure(_ message: String) {
        dataResetFailureMessage = message
    }

    func dismissDataResetFailure() {
        dataResetFailureMessage = nil
    }

    private func updateSelection(
        _ provider: CloudGamingProvider?,
        forcesPersistence: Bool
    ) {
        guard forcesPersistence || provider != selectedProvider else { return }
        if provider != selectedProvider,
           selectedProvider != nil
        {
            MemoryLifecycleCoordinator.shared.releaseCachedArtwork()
        }
        selectionGeneration &+= 1
        let generation = selectionGeneration
        hasStoredSelection = true
        selectedProvider = provider
        persistenceTask?.cancel()
        let persistence = persistence
        persistenceTask = Task { [weak self] in
            await persistence.saveSelectedCloudGamingProvider(
                provider,
                generation: generation
            )
            guard !Task.isCancelled,
                  let self,
                  selectionGeneration == generation
            else {
                return
            }
            persistenceTask = nil
        }
    }

    private func invalidateProviderSwitch() {
        providerSwitchGeneration &+= 1
        activeProviderSwitch = nil
        isProviderSwitchInProgress = false
    }

    func adoptLegacyGeForceNowSessionIfNeeded() {
        guard requiresLegacyGeForceNowMigration else { return }
        select(.geForceNow)
    }
}

/// Reconstructs just enough cold-launch state to decide whether the registered
/// GeForce NOW background task owns work. This keeps Xbox launches offline and
/// avoids relying on SwiftUI's foreground restoration task having run first.
@MainActor
struct GeForceNowBackgroundRefreshHandler {
    nonisolated enum Outcome: Equatable, Sendable {
        case skipped
        case handled
    }

    private let providerCoordinator: CloudGamingProviderCoordinator
    private let authManager: AuthManager

    init(
        providerCoordinator: CloudGamingProviderCoordinator,
        authManager: AuthManager
    ) {
        self.providerCoordinator = providerCoordinator
        self.authManager = authManager
    }

    func perform() async -> Outcome {
        await providerCoordinator.initialize()
        guard !Task.isCancelled,
              providerCoordinator.selectedProvider == .geForceNow
        else {
            return .skipped
        }

        await authManager.restorePersistedSession()
        guard !Task.isCancelled,
              providerCoordinator.selectedProvider == .geForceNow,
              authManager.isAuthenticated
        else {
            return .skipped
        }

        await authManager.refreshIfNeeded()
        guard !Task.isCancelled,
              providerCoordinator.selectedProvider == .geForceNow,
              authManager.isAuthenticated
        else {
            return .skipped
        }
        authManager.scheduleBackgroundRefresh()
        return .handled
    }
}
