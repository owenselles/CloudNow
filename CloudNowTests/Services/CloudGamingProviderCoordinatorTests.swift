@testable import CloudNow
import Foundation
import Testing

@Suite("Cloud gaming provider coordination")
struct CloudGamingProviderCoordinatorTests {
    @MainActor
    @Test("Restores the last selected provider")
    func restoresSelection() async {
        let persistence = ProviderSelectionPersistence(selectedProvider: .xboxCloudGaming)
        let coordinator = CloudGamingProviderCoordinator(persistence: persistence)

        await coordinator.initialize()

        #expect(coordinator.startupPhase == .ready)
        #expect(coordinator.selectedProvider == .xboxCloudGaming)
        #expect(!coordinator.requiresLegacyGeForceNowMigration)
    }

    @MainActor
    @Test("A choice made during restore wins over the delayed value")
    func currentChoiceWinsOverDelayedRestore() async {
        let persistence = ProviderSelectionPersistence(
            selectedProvider: .xboxCloudGaming,
            blocksLoad: true
        )
        let coordinator = CloudGamingProviderCoordinator(persistence: persistence)
        let initialization = Task { @MainActor in
            await coordinator.initialize()
        }
        await persistence.waitForLoad()

        coordinator.select(.geForceNow)
        await persistence.releaseLoad()
        await initialization.value
        await persistence.waitForSaveCount(1)

        #expect(coordinator.startupPhase == .ready)
        #expect(coordinator.selectedProvider == .geForceNow)
        #expect(await persistence.savedProvider == .geForceNow)
    }

    @MainActor
    @Test("Concurrent initialization waits for the active selection restore")
    func concurrentInitializationCoalesces() async {
        let persistence = ProviderSelectionPersistence(
            selectedProvider: .xboxCloudGaming,
            blocksLoad: true
        )
        let coordinator = CloudGamingProviderCoordinator(persistence: persistence)
        let first = Task { @MainActor in
            await coordinator.initialize()
        }
        await persistence.waitForLoad()

        let second = Task { @MainActor in
            await coordinator.initialize()
            return coordinator.selectedProvider
        }
        await Task.yield()
        await persistence.releaseLoad()
        await first.value

        #expect(await second.value == .xboxCloudGaming)
        #expect(coordinator.startupPhase == .ready)
    }

    @MainActor
    @Test("Rapid switching persists only the newest provider")
    func rapidSwitchingKeepsNewestSelection() async {
        let persistence = ProviderSelectionPersistence()
        let coordinator = CloudGamingProviderCoordinator(
            persistence: persistence,
            startsReady: true
        )

        coordinator.select(.geForceNow)
        coordinator.select(.xboxCloudGaming)
        coordinator.select(nil)
        await persistence.waitForSavedGeneration(3)

        #expect(coordinator.selectedProvider == nil)
        #expect(await persistence.savedProvider == nil)
        #expect(await persistence.latestSavedGeneration == 3)
    }

    @MainActor
    @Test("Legacy GeForce NOW sessions migrate without overwriting a choice")
    func legacyMigration() async {
        let persistence = ProviderSelectionPersistence()
        let coordinator = CloudGamingProviderCoordinator(
            persistence: persistence,
            startsReady: true
        )

        #expect(coordinator.requiresLegacyGeForceNowMigration)
        coordinator.adoptLegacyGeForceNowSessionIfNeeded()
        coordinator.adoptLegacyGeForceNowSessionIfNeeded()
        await persistence.waitForSaveCount(1)

        #expect(coordinator.selectedProvider == .geForceNow)
        #expect(!coordinator.requiresLegacyGeForceNowMigration)
        #expect(await persistence.savedGenerations == [1])
    }

    @MainActor
    @Test("An explicitly persisted chooser is not mistaken for a legacy install")
    func explicitChooserSurvivesLegacyMigration() async {
        let persistence = ProviderSelectionPersistence(hasStoredSelection: true)
        let coordinator = CloudGamingProviderCoordinator(persistence: persistence)

        await coordinator.initialize()
        #expect(!coordinator.requiresLegacyGeForceNowMigration)
        coordinator.adoptLegacyGeForceNowSessionIfNeeded()

        #expect(coordinator.selectedProvider == nil)
        #expect(await persistence.savedGenerations.isEmpty)
    }

    @MainActor
    @Test("A partial reset re-persists an unchanged surviving provider")
    func partialResetPreservesSurvivingSelection() async {
        let persistence = ProviderSelectionPersistence(
            selectedProvider: .xboxCloudGaming
        )
        let coordinator = CloudGamingProviderCoordinator(
            persistence: persistence,
            initialSelection: .xboxCloudGaming,
            startsReady: true
        )

        coordinator.preserveSelectionAfterFailedDataReset(.xboxCloudGaming)
        coordinator.presentDataResetFailure("Fixture failure")
        await persistence.waitForSaveCount(1)

        #expect(coordinator.selectedProvider == .xboxCloudGaming)
        #expect(await persistence.savedProvider == .xboxCloudGaming)
        #expect(coordinator.dataResetFailureMessage == "Fixture failure")

        coordinator.dismissDataResetFailure()

        #expect(coordinator.dataResetFailureMessage == nil)
    }

    @MainActor
    @Test("Credential mutation invalidates a stale provider switch intent")
    func credentialMutationInvalidatesStaleSwitch() async {
        let persistence = ProviderSelectionPersistence(
            selectedProvider: .geForceNow
        )
        let coordinator = CloudGamingProviderCoordinator(
            persistence: persistence,
            initialSelection: .geForceNow,
            startsReady: true
        )

        let intent = try? #require(
            coordinator.beginProviderSwitch(to: .xboxCloudGaming)
        )
        #expect(coordinator.isProviderSwitchInProgress)

        let mutation = try? #require(coordinator.beginCredentialMutation())
        #expect(!coordinator.isProviderSwitchInProgress)
        #expect(coordinator.isCredentialMutationInProgress)

        coordinator.select(nil)
        if let intent {
            #expect(!coordinator.commitProviderSwitch(intent))
        }
        if let mutation {
            coordinator.finishCredentialMutation(mutation)
        }
        await persistence.waitForSaveCount(1)

        #expect(coordinator.selectedProvider == nil)
        #expect(await persistence.savedProvider == nil)
        #expect(!coordinator.isProviderInteractionBlocked)
    }

    @MainActor
    @Test("Credential mutation blocks new provider switch intents")
    func credentialMutationBlocksSwitches() throws {
        let coordinator = CloudGamingProviderCoordinator(
            persistence: ProviderSelectionPersistence(),
            initialSelection: .geForceNow,
            startsReady: true
        )
        let mutation = try #require(coordinator.beginCredentialMutation())

        #expect(
            coordinator.beginProviderSwitch(to: .xboxCloudGaming) == nil
        )
        #expect(coordinator.isProviderInteractionBlocked)

        coordinator.finishCredentialMutation(mutation)
        let intent = try #require(
            coordinator.beginProviderSwitch(to: .xboxCloudGaming)
        )
        #expect(coordinator.commitProviderSwitch(intent))
        #expect(coordinator.selectedProvider == .xboxCloudGaming)
    }

    @MainActor
    @Test("Only the current switch intent can commit")
    func onlyCurrentSwitchIntentCommits() throws {
        let coordinator = CloudGamingProviderCoordinator(
            persistence: ProviderSelectionPersistence(),
            initialSelection: .geForceNow,
            startsReady: true
        )
        let first = try #require(
            coordinator.beginProviderSwitch(to: .xboxCloudGaming)
        )
        coordinator.cancelProviderSwitch(first)
        let second = try #require(
            coordinator.beginProviderSwitch(to: nil)
        )

        #expect(!coordinator.commitProviderSwitch(first))
        #expect(coordinator.selectedProvider == .geForceNow)
        #expect(coordinator.commitProviderSwitch(second))
        #expect(coordinator.selectedProvider == nil)
    }
}

private actor ProviderSelectionPersistence: CloudGamingProviderSelectionPersistence {
    private(set) var savedProvider: CloudGamingProvider?
    private(set) var savedGenerations: [UInt64] = []
    private(set) var latestSavedGeneration: UInt64 = 0
    private var hasStoredSelection: Bool
    private let blocksLoad: Bool
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var loadStarted = false
    private var saveWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var generationWaiters: [(UInt64, CheckedContinuation<Void, Never>)] = []

    init(
        selectedProvider: CloudGamingProvider? = nil,
        hasStoredSelection: Bool? = nil,
        blocksLoad: Bool = false
    ) {
        savedProvider = selectedProvider
        self.hasStoredSelection = hasStoredSelection ?? (selectedProvider != nil)
        self.blocksLoad = blocksLoad
    }

    func loadSelectedCloudGamingProvider() async -> CloudGamingProvider? {
        loadStarted = true
        if blocksLoad {
            await withCheckedContinuation { continuation in
                loadContinuation = continuation
            }
        }
        return savedProvider
    }

    func hasStoredCloudGamingProviderSelection() -> Bool {
        hasStoredSelection
    }

    func saveSelectedCloudGamingProvider(
        _ provider: CloudGamingProvider?,
        generation: UInt64
    ) {
        guard generation >= latestSavedGeneration else { return }
        latestSavedGeneration = generation
        hasStoredSelection = true
        savedGenerations.append(generation)
        savedProvider = provider
        let ready = saveWaiters.filter { savedGenerations.count >= $0.0 }
        saveWaiters.removeAll { savedGenerations.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        let readyGenerations = generationWaiters.filter { generation >= $0.0 }
        generationWaiters.removeAll { generation >= $0.0 }
        readyGenerations.forEach { $0.1.resume() }
    }

    func waitForLoad() async {
        while !loadStarted {
            await Task.yield()
        }
    }

    func releaseLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func waitForSaveCount(_ count: Int) async {
        guard savedGenerations.count < count else { return }
        await withCheckedContinuation { continuation in
            saveWaiters.append((count, continuation))
        }
    }

    func waitForSavedGeneration(_ generation: UInt64) async {
        guard latestSavedGeneration < generation else { return }
        await withCheckedContinuation { continuation in
            generationWaiters.append((generation, continuation))
        }
    }
}
