@testable import CloudNow
import Foundation
import Testing

@Suite("Full library refresh coordinator")
@MainActor
struct LibraryRefreshCoordinatorTests {
    @Test("Progress exposes completed and total refresh steps")
    func progressStepCounts() {
        let idle = FullLibraryRefreshState()
        #expect(idle.completedStepCount == 0)
        #expect(idle.totalStepCount == 1)
        #expect(idle.progressFraction == 0)

        let syncing = FullLibraryRefreshState(
            stage: .syncing,
            providers: [
                ProviderSyncProgress(
                    providerCode: "STEAM",
                    displayName: "Steam",
                    accountName: nil,
                    phase: .succeeded(gameCount: 4)
                ),
                ProviderSyncProgress(
                    providerCode: "XBOX",
                    displayName: "Xbox",
                    accountName: nil,
                    phase: .syncing
                ),
            ],
            finalPhase: .queued
        )
        #expect(syncing.completedStepCount == 1)
        #expect(syncing.totalStepCount == 3)
        #expect(syncing.progressFraction == 1.0 / 3.0)
    }

    @Test("Publishes every provider before starting parallel synchronization requests")
    func publishesRowsBeforeParallelRequests() async {
        let baseline = Date(timeIntervalSince1970: 1000)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [
                .success([
                    provider("STEAM", date: baseline),
                    provider("XBOX", date: baseline),
                ]),
            ],
            snapshots: [
                .success([
                    snapshot("STEAM", date: baseline.addingTimeInterval(1), count: 3),
                    snapshot("XBOX", date: baseline.addingTimeInterval(1), count: 4),
                ]),
            ],
            blockRequests: true
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        await client.waitForRequestCount(2)

        #expect(coordinator.state.stage == .syncing)
        #expect(Set(coordinator.state.providers.map(\.providerCode)) == ["STEAM", "XBOX"])
        #expect(coordinator.state.providers.allSatisfy { $0.phase == .requesting })
        #expect(importer.callCount == 0)

        await client.releaseAllRequests()
        #expect(await eventually { coordinator.state.stage == .completed })
        let requestedProviderCodes = await client.requestedProviderCodes()
        #expect(Set(requestedProviderCodes) == ["STEAM", "XBOX"])
        #expect(importer.callCount == 1)
    }

    @Test("Final import waits until every accepted provider reaches a terminal state")
    func importWaitsForAllProviders() async {
        let baseline = Date(timeIntervalSince1970: 2000)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [
                .success([
                    provider("STEAM", date: baseline),
                    provider("XBOX", date: baseline),
                ]),
            ],
            snapshots: [
                .success([
                    snapshot("STEAM", date: baseline.addingTimeInterval(1), count: 8),
                    snapshot("XBOX", date: baseline, count: nil, state: .unknown(nil)),
                ]),
                .success([
                    snapshot("XBOX", date: baseline.addingTimeInterval(2), count: 6),
                ]),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: false)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        await clock.waitForSleepCount(1)
        #expect(coordinator.state.providers.allSatisfy { $0.phase == .syncing })
        #expect(importer.callCount == 0)

        #expect(await clock.advanceNextSleep())
        await clock.waitForSleepCount(2)

        #expect(coordinator.state.providers.first { $0.providerCode == "STEAM" }?.phase == .succeeded(gameCount: 8))
        #expect(coordinator.state.providers.first { $0.providerCode == "XBOX" }?.phase == .syncing)
        #expect(coordinator.state.finalPhase == .queued)
        #expect(importer.callCount == 0)

        #expect(await clock.advanceNextSleep())
        #expect(await eventually { coordinator.state.stage == .completed })
        #expect(coordinator.state.providers.filter { !$0.phase.isTerminal }.isEmpty)
        #expect(importer.callCount == 1)
        #expect(await client.snapshotCallCount() == 2)
    }

    @Test("A provider failure still permits best-effort final import")
    func partialFailureStillImports() async {
        let baseline = Date(timeIntervalSince1970: 3000)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [
                .success([
                    provider("STEAM", date: baseline),
                    provider("XBOX", date: baseline),
                ]),
            ],
            requestOutcomes: [
                "XBOX": [.failure(.httpStatus(500))],
            ],
            snapshots: [
                .success([
                    snapshot("STEAM", date: baseline.addingTimeInterval(1), count: 11),
                ]),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder(
            result: LibraryImportResult(
                finalGameCount: 20,
                addedGameIDs: ["new"],
                removedGameIDs: ["old"]
            )
        )
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        #expect(importer.callCount == 1)
        #expect(coordinator.state.finalPhase == .succeeded(gameCount: 20))
        #expect(coordinator.state.summary?.successfulProviderCount == 1)
        #expect(coordinator.state.summary?.failedProviderCount == 1)
        #expect(coordinator.state.summary?.addedGameIDs == ["new"])
        #expect(coordinator.state.summary?.removedGameIDs == ["old"])
    }

    @Test("A provider 401 refreshes authentication once and retries")
    func providerUnauthorizedRefreshesOnce() async {
        let baseline = Date(timeIntervalSince1970: 3500)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [.success([provider("STEAM", date: baseline)])],
            requestOutcomes: [
                "STEAM": [
                    .failure(.unauthorized),
                    .success,
                ],
            ],
            snapshots: [
                .success([
                    snapshot(
                        "STEAM",
                        date: baseline.addingTimeInterval(1),
                        count: 10
                    ),
                ]),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()
        var rejectedTokens: [String] = []

        #expect(
            coordinator.start(
                userId: "user",
                resolveToken: { rejectedToken in
                    guard let rejectedToken else { return "old-token" }
                    rejectedTokens.append(rejectedToken)
                    return "refreshed-token"
                },
                userIsCurrent: { validity.isCurrent },
                importLibrary: { importer.recordImport() }
            )
        )
        #expect(await eventually { coordinator.state.stage == .completed })

        #expect(rejectedTokens == ["old-token"])
        #expect(await client.requestedProviderCodes() == ["STEAM", "STEAM"])
        #expect(coordinator.state.providers.first?.phase == .succeeded(gameCount: 10))
        #expect(importer.callCount == 1)
    }

    @Test("A repeated polling 401 refreshes authentication at most once")
    func pollingUnauthorizedRefreshesAtMostOnce() async {
        let baseline = Date(timeIntervalSince1970: 3575)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [.success([provider("STEAM", date: baseline)])],
            snapshots: [
                .failure(.unauthorized),
                .failure(.unauthorized),
                .failure(.unauthorized),
                .failure(.unauthorized),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()
        var rejectedTokens: [String] = []

        #expect(
            coordinator.start(
                userId: "user",
                resolveToken: { rejectedToken in
                    guard let rejectedToken else { return "old-token" }
                    rejectedTokens.append(rejectedToken)
                    return "refreshed-token"
                },
                userIsCurrent: { validity.isCurrent },
                importLibrary: { importer.recordImport() }
            )
        )
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        #expect(rejectedTokens == ["old-token"])
        #expect(await client.snapshotCallCount() == 2)
        #expect(coordinator.state.providers.first?.phase == .failed(message: ""))
        #expect(importer.callCount == 1)
    }

    @Test("A polling 403 permits a fresh submission after relinking")
    func pollingForbiddenRequiresRelink() async {
        let baseline = Date(timeIntervalSince1970: 3650)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [
                .success([provider("STEAM", date: baseline)]),
                .success([provider("STEAM", date: baseline)]),
            ],
            snapshots: [
                .failure(.forbidden),
                .success([
                    snapshot(
                        "STEAM",
                        date: baseline.addingTimeInterval(1),
                        count: 11
                    ),
                ]),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        #expect(await client.requestedProviderCodes() == ["STEAM"])
        #expect(await client.snapshotCallCount() == 1)
        #expect(coordinator.state.providers.first?.phase == .relinkRequired)
        #expect(importer.callCount == 1)

        coordinator.acknowledgeCompletion()
        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .completed })

        #expect(await client.requestedProviderCodes() == ["STEAM", "STEAM"])
        #expect(await client.snapshotCallCount() == 2)
        #expect(coordinator.state.providers.first?.phase == .succeeded(gameCount: 11))
        #expect(importer.callCount == 2)
    }

    @Test(
        "Newer terminal account states map to truthful provider outcomes",
        arguments: [
            CoordinatorTerminalStateCase(
                state: .failed,
                expectedPhase: .failed(message: "")
            ),
            CoordinatorTerminalStateCase(
                state: .denied,
                expectedPhase: .relinkRequired
            ),
            CoordinatorTerminalStateCase(
                state: .profileNotCreated,
                expectedPhase: .relinkRequired
            ),
            CoordinatorTerminalStateCase(
                state: .unknown("SYNC_FUTURE"),
                expectedPhase: .failed(message: "")
            ),
        ]
    )
    func terminalStateMapping(testCase: CoordinatorTerminalStateCase) async {
        let baseline = Date(timeIntervalSince1970: 3600)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [.success([provider("STEAM", date: baseline)])],
            snapshots: [
                .success([
                    snapshot(
                        "STEAM",
                        date: baseline.addingTimeInterval(1),
                        count: nil,
                        state: testCase.state
                    ),
                ]),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        #expect(coordinator.state.providers.first?.phase == testCase.expectedPhase)
        #expect(importer.callCount == 1)
    }

    @Test("A provider 403 is shown as relink required")
    func forbiddenProviderRequiresRelink() async {
        let baseline = Date(timeIntervalSince1970: 3700)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [.success([provider("STEAM", date: baseline)])],
            requestOutcomes: [
                "STEAM": [.failure(.forbidden)],
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        #expect(coordinator.state.providers.first?.phase == .relinkRequired)
        #expect(!coordinator.state.hasRetryableFailures)
        #expect(importer.callCount == 1)
    }

    @Test("Zero connected providers imports directly")
    func zeroProvidersImportsDirectly() async {
        let client = CoordinatorLibrarySyncClient(discoveries: [.success([])])
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .completed })

        #expect(coordinator.state.providers.isEmpty)
        #expect(coordinator.state.finalPhase == .succeeded(gameCount: 7))
        #expect(importer.callCount == 1)
        #expect(await client.requestedProviderCodes().isEmpty)
        #expect(await client.snapshotCallCount() == 0)
    }

    @Test("Connected providers without sync capability remain visible and import directly")
    func unsupportedProvidersRemainVisible() async {
        let client = CoordinatorLibrarySyncClient(
            discoveries: [
                .success([
                    provider("EPIC", date: nil, supportsSync: false),
                ]),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .completed })

        #expect(coordinator.state.providers.count == 1)
        #expect(coordinator.state.providers.first?.providerCode == "EPIC")
        #expect(coordinator.state.providers.first?.phase == .skipped)
        #expect(coordinator.state.finalPhase == .succeeded(gameCount: 7))
        #expect(await client.requestedProviderCodes().isEmpty)
        #expect(await client.snapshotCallCount() == 0)
        #expect(importer.callCount == 1)
    }

    @Test("Discovery failure fails closed but falls back to final import")
    func discoveryFailureFallsBackToImport() async {
        let client = CoordinatorLibrarySyncClient(discoveries: [.failure(.schema)])
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        #expect(coordinator.state.providers.isEmpty)
        #expect(coordinator.state.warning != nil)
        #expect(coordinator.state.finalPhase == .succeeded(gameCount: 7))
        #expect(importer.callCount == 1)
        #expect(await client.requestedProviderCodes().isEmpty)
    }

    @Test("Duplicate taps share the active run")
    func duplicateStartsAreSingleFlight() async {
        let client = CoordinatorLibrarySyncClient(discoveries: [.success([])])
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        let firstStart = start(coordinator, importer: importer, validity: validity)
        let secondStart = start(coordinator, importer: importer, validity: validity)

        #expect(firstStart)
        #expect(!secondStart)
        #expect(await eventually { coordinator.state.stage == .completed })
        #expect(await client.discoveryCallCount() == 1)
        #expect(importer.callCount == 1)
    }

    @Test("Injected scheduler advances provider timeout without wall-clock sleeps")
    func providerTimeoutUsesInjectedScheduler() async {
        let baseline = Date(timeIntervalSince1970: 4000)
        let unchanged = snapshot("STEAM", date: baseline, count: nil, state: .unknown(nil))
        let client = CoordinatorLibrarySyncClient(
            discoveries: [.success([provider("STEAM", date: baseline)])],
            snapshots: [
                .success([unchanged]),
                .success([unchanged]),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(
            client: client,
            scheduler: clock.scheduler,
            initialPollInterval: 1,
            maximumPollInterval: 2,
            providerTimeout: 2.5
        )
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        #expect(coordinator.state.providers.first?.phase == .timedOut)
        #expect(coordinator.state.finalPhase == .succeeded(gameCount: 7))
        #expect(importer.callCount == 1)
        #expect(await clock.recordedSleeps() == [1, 1.5])
        #expect(await client.snapshotCallCount() >= 1)
    }

    @Test("A slow provider request cannot overrun the provider deadline")
    func slowRequestHonorsDeadline() async {
        let baseline = Date(timeIntervalSince1970: 4500)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [.success([provider("STEAM", date: baseline)])],
            requestOutcomes: [
                "STEAM": [.delay(1)],
            ]
        )
        let coordinator = makeCoordinator(
            client: client,
            scheduler: .continuous,
            providerTimeout: 0.02
        )
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        #expect(coordinator.state.providers.first?.phase == .timedOut)
        #expect(coordinator.state.finalPhase == .succeeded(gameCount: 7))
        #expect(importer.callCount == 1)
    }

    @Test("A cancellation-ignoring provider request cannot hold the run open")
    func cancellationIgnoringRequestHonorsDeadline() async {
        let baseline = Date(timeIntervalSince1970: 4525)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [.success([provider("STEAM", date: baseline)])],
            blockRequests: true
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let deadline = CoordinatorControlledDeadline()
        let coordinator = makeCoordinator(
            client: client,
            scheduler: LibraryRefreshScheduler(
                now: { await clock.currentTimeValue() },
                sleep: { try await clock.sleep(seconds: $0) },
                deadlineSleep: { try await deadline.sleep(seconds: $0) }
            )
        )
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        await client.waitForRequestCount(1)
        await deadline.waitForFirstSleep()
        await deadline.fireFirstDeadline()

        #expect(await eventually { coordinator.state.stage == .partialFailure })
        #expect(coordinator.state.providers.first?.phase == .timedOut)
        #expect(coordinator.state.finalPhase == .succeeded(gameCount: 7))
        #expect(importer.callCount == 1)

        await client.releaseAllRequests()
        await drainTasks()
    }

    @Test("A slow authentication refresh cannot overrun the provider deadline")
    func slowAuthenticationRefreshHonorsDeadline() async {
        let baseline = Date(timeIntervalSince1970: 4550)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [.success([provider("STEAM", date: baseline)])],
            requestOutcomes: [
                "STEAM": [.failure(.unauthorized)],
            ]
        )
        let coordinator = makeCoordinator(
            client: client,
            scheduler: .continuous,
            providerTimeout: 0.02
        )
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(
            coordinator.start(
                userId: "user",
                resolveToken: { rejectedToken in
                    if rejectedToken != nil {
                        try await ContinuousClock().sleep(for: .seconds(1))
                    }
                    return "token"
                },
                userIsCurrent: { validity.isCurrent },
                importLibrary: { importer.recordImport() }
            )
        )
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        #expect(coordinator.state.providers.first?.phase == .timedOut)
        #expect(coordinator.state.finalPhase == .succeeded(gameCount: 7))
        #expect(importer.callCount == 1)
    }

    @Test("A slow account snapshot cannot overrun the provider deadline")
    func slowSnapshotHonorsDeadline() async {
        let baseline = Date(timeIntervalSince1970: 4600)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [.success([provider("STEAM", date: baseline)])],
            snapshots: [
                .success([
                    snapshot(
                        "STEAM",
                        date: baseline.addingTimeInterval(1),
                        count: 5
                    ),
                ]),
            ],
            snapshotDelays: [1]
        )
        let coordinator = makeCoordinator(
            client: client,
            scheduler: .continuous,
            initialPollInterval: 0,
            maximumPollInterval: 0,
            providerTimeout: 0.02
        )
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        #expect(coordinator.state.providers.first?.phase == .timedOut)
        #expect(coordinator.state.finalPhase == .succeeded(gameCount: 7))
        #expect(importer.callCount == 1)
    }

    @Test("Stale accounts and explicit cancellation suppress final publication")
    func staleAccountAndCancellationSuppressWork() async {
        let staleValidity = CoordinatorValidity()
        let staleClient = CoordinatorLibrarySyncClient(
            discoveries: [.success([])],
            onDiscover: {
                staleValidity.isCurrent = false
            }
        )
        let staleClock = CoordinatorTestScheduler(autoAdvance: true)
        let staleCoordinator = makeCoordinator(client: staleClient, scheduler: staleClock.scheduler)
        let staleImporter = CoordinatorImportRecorder()

        #expect(start(staleCoordinator, importer: staleImporter, validity: staleValidity))
        #expect(await eventually { !staleValidity.isCurrent })
        await drainTasks()

        #expect(staleCoordinator.state.stage == .idle)
        #expect(staleCoordinator.state.summary == nil)
        #expect(staleImporter.callCount == 0)
        #expect(await staleClient.requestedProviderCodes().isEmpty)

        let cancelledClient = CoordinatorLibrarySyncClient(discoveries: [.success([])])
        let cancelledClock = CoordinatorTestScheduler(autoAdvance: true)
        let cancelledCoordinator = makeCoordinator(
            client: cancelledClient,
            scheduler: cancelledClock.scheduler
        )
        let cancelledImporter = CoordinatorImportRecorder()
        let cancelledValidity = CoordinatorValidity()

        #expect(start(
            cancelledCoordinator,
            importer: cancelledImporter,
            validity: cancelledValidity
        ))
        cancelledCoordinator.cancel()
        await drainTasks()

        #expect(cancelledCoordinator.state == FullLibraryRefreshState())
        #expect(cancelledImporter.callCount == 0)
    }

    @Test("A cancelled provider request cannot publish into its replacement run")
    func cancelledRequestCannotMutateReplacementRun() async {
        let baseline = Date(timeIntervalSince1970: 4800)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [
                .success([provider("STEAM", date: baseline)]),
                .success([
                    provider(
                        "STEAM",
                        date: baseline,
                        supportsSync: false
                    ),
                ]),
            ],
            blockRequests: true
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(
            client: client,
            scheduler: clock.scheduler
        )
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        await client.waitForRequestCount(1)

        coordinator.cancel()
        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .completed })
        #expect(coordinator.state.providers.first?.phase == .skipped)

        await client.releaseAllRequests()
        await drainTasks()

        #expect(coordinator.state.stage == .completed)
        #expect(coordinator.state.providers.first?.phase == .skipped)
        #expect(importer.callCount == 1)
    }

    @Test("A cancelled poll clock read cannot publish into its replacement run")
    func cancelledPollCannotMutateReplacementRun() async {
        let baseline = Date(timeIntervalSince1970: 4900)
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [
                .success([provider("STEAM", date: baseline)]),
                .success([
                    provider(
                        "STEAM",
                        date: baseline,
                        supportsSync: false
                    ),
                ]),
            ],
            snapshots: [
                .success([
                    snapshot(
                        "STEAM",
                        date: baseline.addingTimeInterval(1),
                        count: 12
                    ),
                ]),
            ],
            onSnapshot: {
                await clock.blockNextNowCall()
            }
        )
        let coordinator = makeCoordinator(
            client: client,
            scheduler: clock.scheduler
        )
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        await clock.waitForBlockedNowCall()

        coordinator.cancel()
        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .completed })
        #expect(coordinator.state.providers.first?.phase == .skipped)

        await clock.releaseBlockedNowCall()
        await drainTasks()

        #expect(coordinator.state.stage == .completed)
        #expect(coordinator.state.providers.first?.phase == .skipped)
        #expect(importer.callCount == 1)
    }

    @Test("Retry re-discovers state and skips POST when sync date already advanced")
    func retryAvoidsDuplicatePostAfterAdvancedSnapshot() async {
        let baseline = Date(timeIntervalSince1970: 5000)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [
                .success([provider("STEAM", date: baseline)]),
                .success([
                    provider(
                        "STEAM",
                        date: baseline.addingTimeInterval(5),
                        count: 9,
                        state: .success
                    ),
                ]),
            ],
            requestOutcomes: [
                "STEAM": [.failure(.httpStatus(503))],
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .partialFailure })
        #expect(await client.requestedProviderCodes() == ["STEAM"])

        #expect(start(
            coordinator,
            retryProviderCodes: ["STEAM"],
            importer: importer,
            validity: validity
        ))
        #expect(await eventually { coordinator.state.stage == .completed })

        #expect(await client.discoveryCallCount() == 2)
        #expect(await client.requestedProviderCodes() == ["STEAM"])
        #expect(coordinator.state.providers.first?.phase == .succeeded(gameCount: 9))
        #expect(importer.callCount == 2)
    }

    @Test("A newer terminal failure can be submitted again on retry")
    func retryResubmitsAfterNewerTerminalFailure() async {
        let baseline = Date(timeIntervalSince1970: 6000)
        let failedDate = baseline.addingTimeInterval(1)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [
                .success([provider("STEAM", date: baseline)]),
                .success([
                    provider(
                        "STEAM",
                        date: failedDate,
                        state: .failed
                    ),
                ]),
            ],
            snapshots: [
                .success([
                    snapshot(
                        "STEAM",
                        date: failedDate,
                        count: nil,
                        state: .failed
                    ),
                ]),
                .success([
                    snapshot(
                        "STEAM",
                        date: failedDate.addingTimeInterval(1),
                        count: 12
                    ),
                ]),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        #expect(start(
            coordinator,
            retryProviderCodes: ["STEAM"],
            importer: importer,
            validity: validity
        ))
        #expect(await eventually { coordinator.state.stage == .completed })

        #expect(await client.requestedProviderCodes() == ["STEAM", "STEAM"])
        #expect(coordinator.state.providers.first?.phase == .succeeded(gameCount: 12))
        #expect(importer.callCount == 2)
    }

    @Test("An ambiguous POST failure is polled without submitting it again")
    func ambiguousPostPollsWithoutRetrying() async {
        let baseline = Date(timeIntervalSince1970: 7000)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [.success([provider("STEAM", date: baseline)])],
            requestOutcomes: [
                "STEAM": [.failure(.networkAmbiguous)],
            ],
            snapshots: [
                .success([
                    snapshot(
                        "STEAM",
                        date: baseline.addingTimeInterval(1),
                        count: 14
                    ),
                ]),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .completed })

        #expect(await client.requestedProviderCodes() == ["STEAM"])
        #expect(await client.snapshotCallCount() == 1)
        #expect(coordinator.state.providers.first?.phase == .succeeded(gameCount: 14))
        #expect(importer.callCount == 1)
    }

    @Test("An ambiguous POST can be retried after a full unchanged poll deadline")
    func ambiguousPostTimeoutAllowsLaterSubmission() async {
        let baseline = Date(timeIntervalSince1970: 7250)
        let discovery = Result<[ConnectedGameLibrary], LibrarySyncError>.success([
            provider("STEAM", date: baseline),
        ])
        let client = CoordinatorLibrarySyncClient(
            discoveries: [discovery, discovery],
            requestOutcomes: [
                "STEAM": [
                    .failure(.networkAmbiguous),
                    .success,
                ],
            ],
            snapshots: [
                .success([
                    snapshot(
                        "STEAM",
                        date: baseline,
                        count: nil,
                        state: .unknown(nil)
                    ),
                ]),
                .success([
                    snapshot(
                        "STEAM",
                        date: baseline.addingTimeInterval(1),
                        count: 15
                    ),
                ]),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(
            client: client,
            scheduler: clock.scheduler,
            providerTimeout: 2
        )
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .partialFailure })
        #expect(await client.requestedProviderCodes() == ["STEAM"])
        #expect(await client.snapshotCallCount() == 1)

        #expect(start(
            coordinator,
            retryProviderCodes: ["STEAM"],
            importer: importer,
            validity: validity
        ))
        #expect(await eventually { coordinator.state.stage == .completed })

        #expect(await client.discoveryCallCount() == 2)
        #expect(await client.requestedProviderCodes() == ["STEAM", "STEAM"])
        #expect(await client.snapshotCallCount() == 2)
        #expect(coordinator.state.providers.first?.phase == .succeeded(gameCount: 15))
        #expect(importer.callCount == 2)
    }

    @Test("Advanced discovery suppresses retry after an ambiguous poll timeout")
    func advancedDiscoverySuppressesAmbiguousRetry() async {
        let baseline = Date(timeIntervalSince1970: 7375)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [
                .success([provider("STEAM", date: baseline)]),
                .success([
                    provider(
                        "STEAM",
                        date: baseline.addingTimeInterval(1),
                        count: 16,
                        state: .success
                    ),
                ]),
            ],
            requestOutcomes: [
                "STEAM": [.failure(.networkAmbiguous)],
            ],
            snapshots: [
                .success([
                    snapshot(
                        "STEAM",
                        date: baseline,
                        count: nil,
                        state: .unknown(nil)
                    ),
                ]),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(
            client: client,
            scheduler: clock.scheduler,
            providerTimeout: 2
        )
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        #expect(start(
            coordinator,
            retryProviderCodes: ["STEAM"],
            importer: importer,
            validity: validity
        ))
        #expect(await eventually { coordinator.state.stage == .completed })

        #expect(await client.discoveryCallCount() == 2)
        #expect(await client.requestedProviderCodes() == ["STEAM"])
        #expect(await client.snapshotCallCount() == 1)
        #expect(coordinator.state.providers.first?.phase == .succeeded(gameCount: 16))
        #expect(importer.callCount == 2)
    }

    @Test("Retry polls a timed-out POST before considering another submission")
    func timedOutPostRetryPollsWithoutDuplicateSubmission() async {
        let baseline = Date(timeIntervalSince1970: 7500)
        let discovery = Result<[ConnectedGameLibrary], LibrarySyncError>.success([
            provider("STEAM", date: baseline),
        ])
        let client = CoordinatorLibrarySyncClient(
            discoveries: [discovery, discovery],
            snapshots: [
                .success([
                    snapshot(
                        "STEAM",
                        date: baseline.addingTimeInterval(1),
                        count: 16
                    ),
                ]),
            ],
            blockRequests: true
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let deadline = CoordinatorControlledDeadline()
        let coordinator = makeCoordinator(
            client: client,
            scheduler: LibraryRefreshScheduler(
                now: { await clock.currentTimeValue() },
                sleep: { try await clock.sleep(seconds: $0) },
                deadlineSleep: { try await deadline.sleep(seconds: $0) }
            ),
            propagationDelay: 5
        )
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        await client.waitForRequestCount(1)
        await deadline.waitForFirstSleep()
        await deadline.fireFirstDeadline()
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        await client.releaseAllRequests()
        await drainTasks()

        #expect(start(
            coordinator,
            retryProviderCodes: ["STEAM"],
            importer: importer,
            validity: validity
        ))
        #expect(await eventually { coordinator.state.stage == .completed })

        #expect(await client.discoveryCallCount() == 2)
        #expect(await client.requestedProviderCodes() == ["STEAM"])
        #expect(await client.snapshotCallCount() == 1)
        #expect(coordinator.state.providers.first?.phase == .succeeded(gameCount: 16))
        #expect(importer.callCount == 2)
        #expect(await clock.recordedSleeps() == [5, 1, 5])
    }

    @Test("A polling schema change fails closed and still imports")
    func pollingSchemaFailureFailsClosed() async {
        let baseline = Date(timeIntervalSince1970: 8000)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [
                .success([
                    provider("STEAM", date: baseline),
                    provider("EPIC", date: nil, supportsSync: false),
                ]),
            ],
            snapshots: [.failure(.schema)]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        #expect(coordinator.state.providers.allSatisfy { $0.phase == .skipped })
        #expect(coordinator.state.warning != nil)
        #expect(coordinator.state.finalPhase == .succeeded(gameCount: 7))
        #expect(importer.callCount == 1)
    }

    @Test("Retry-After suppresses an immediate duplicate POST")
    func retryAfterSuppressesImmediatePost() async {
        let baseline = Date(timeIntervalSince1970: 9000)
        let discovery = Result<[ConnectedGameLibrary], LibrarySyncError>.success([
            provider("STEAM", date: baseline),
        ])
        let client = CoordinatorLibrarySyncClient(
            discoveries: [discovery, discovery, discovery],
            requestOutcomes: [
                "STEAM": [
                    .failure(.rateLimited(retryAfter: 30)),
                    .success,
                ],
            ],
            snapshots: [
                .success([
                    snapshot(
                        "STEAM",
                        date: baseline.addingTimeInterval(1),
                        count: 15
                    ),
                ]),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        #expect(start(
            coordinator,
            retryProviderCodes: ["STEAM"],
            importer: importer,
            validity: validity
        ))
        #expect(await eventually { coordinator.state.stage == .partialFailure })
        #expect(await client.requestedProviderCodes() == ["STEAM"])

        await clock.advance(by: 30)
        #expect(start(
            coordinator,
            retryProviderCodes: ["STEAM"],
            importer: importer,
            validity: validity
        ))
        #expect(await eventually { coordinator.state.stage == .completed })

        #expect(await client.requestedProviderCodes() == ["STEAM", "STEAM"])
        #expect(coordinator.state.providers.first?.phase == .succeeded(gameCount: 15))
        #expect(importer.callCount == 3)
    }

    @Test("Polling honors Retry-After before checking provider state again")
    func pollingRateLimitBacksOff() async {
        let baseline = Date(timeIntervalSince1970: 10000)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [.success([provider("STEAM", date: baseline)])],
            snapshots: [
                .failure(.rateLimited(retryAfter: 30)),
                .success([
                    snapshot(
                        "STEAM",
                        date: baseline.addingTimeInterval(1),
                        count: 18
                    ),
                ]),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(
            client: client,
            scheduler: clock.scheduler,
            providerTimeout: 40
        )
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .completed })

        #expect(await clock.recordedSleeps() == [1, 30])
        #expect(await client.snapshotCallCount() == 2)
        #expect(coordinator.state.providers.first?.phase == .succeeded(gameCount: 18))
        #expect(importer.callCount == 1)
    }

    @Test("A request contract change disables provider synchronization for the run")
    func requestSchemaFailureFailsClosed() async {
        let baseline = Date(timeIntervalSince1970: 11000)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [
                .success([
                    provider("STEAM", date: baseline),
                    provider("XBOX", date: baseline),
                ]),
            ],
            requestOutcomes: [
                "STEAM": [.failure(.schema)],
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        #expect(await eventually { coordinator.state.stage == .partialFailure })

        #expect(coordinator.state.providers.allSatisfy { $0.phase == .skipped })
        #expect(coordinator.state.warning == L10n.text("provider_sync_unavailable"))
        #expect(await client.snapshotCallCount() == 0)
        #expect(importer.callCount == 1)
    }

    @Test("Unexpected import cancellation becomes retryable instead of staying active")
    func unexpectedImportCancellationIsRetryable() async {
        let discovery = Result<[ConnectedGameLibrary], LibrarySyncError>.success([])
        let client = CoordinatorLibrarySyncClient(
            discoveries: [discovery, discovery]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let cancelledImporter = CoordinatorImportRecorder()
        let successfulImporter = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(
            coordinator.start(
                userId: "user",
                resolveToken: { _ in "token" },
                userIsCurrent: { validity.isCurrent },
                importLibrary: {
                    try cancelledImporter.recordCancelledImport()
                }
            )
        )
        #expect(await eventually { coordinator.state.stage == .failed })
        #expect(!coordinator.state.isRunning)
        #expect(coordinator.state.finalPhase.isRetryable)
        #expect(coordinator.state.hasRetryableFailures)

        #expect(start(
            coordinator,
            retryProviderCodes: [],
            importer: successfulImporter,
            validity: validity
        ))
        #expect(await eventually { coordinator.state.stage == .completed })
        #expect(cancelledImporter.callCount == 1)
        #expect(successfulImporter.callCount == 1)
    }

    @Test("Retrying only a failed final import does not resubmit synchronized providers")
    func finalImportRetryDoesNotResubmitProviders() async {
        let baseline = Date(timeIntervalSince1970: 12000)
        let advanced = baseline.addingTimeInterval(1)
        let client = CoordinatorLibrarySyncClient(
            discoveries: [
                .success([provider("STEAM", date: baseline)]),
                .success([
                    provider(
                        "STEAM",
                        date: advanced,
                        count: 25,
                        state: .success
                    ),
                ]),
            ],
            snapshots: [
                .success([
                    snapshot("STEAM", date: advanced, count: 25),
                ]),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: true)
        let coordinator = makeCoordinator(client: client, scheduler: clock.scheduler)
        let failedImporter = CoordinatorImportRecorder()
        let successfulImporter = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(
            coordinator.start(
                userId: "user",
                resolveToken: { _ in "token" },
                userIsCurrent: { validity.isCurrent },
                importLibrary: {
                    try failedImporter.recordFailedImport()
                }
            )
        )
        #expect(await eventually { coordinator.state.stage == .failed })
        #expect(await client.requestedProviderCodes() == ["STEAM"])
        #expect(coordinator.state.providers.first?.phase == .succeeded(gameCount: 25))

        #expect(start(
            coordinator,
            retryProviderCodes: [],
            importer: successfulImporter,
            validity: validity
        ))
        #expect(await eventually { coordinator.state.stage == .completed })

        #expect(await client.requestedProviderCodes() == ["STEAM"])
        #expect(successfulImporter.callCount == 1)
        #expect(coordinator.state.providers.first?.phase == .succeeded(gameCount: 25))
    }

    @Test("Accepted providers settle before import, while an empty run skips settling")
    func propagationBarrierOnlyFollowsAcceptedProviders() async {
        let baseline = Date(timeIntervalSince1970: 13000)
        let providerClient = CoordinatorLibrarySyncClient(
            discoveries: [.success([provider("STEAM", date: baseline)])],
            snapshots: [
                .success([
                    snapshot(
                        "STEAM",
                        date: baseline.addingTimeInterval(1),
                        count: 30
                    ),
                ]),
            ]
        )
        let clock = CoordinatorTestScheduler(autoAdvance: false)
        let coordinator = makeCoordinator(
            client: providerClient,
            scheduler: clock.scheduler,
            propagationDelay: 5
        )
        let importer = CoordinatorImportRecorder()
        let validity = CoordinatorValidity()

        #expect(start(coordinator, importer: importer, validity: validity))
        await clock.waitForSleepCount(1)
        #expect(await clock.advanceNextSleep())
        await clock.waitForSleepCount(2)

        #expect(coordinator.state.stage == .settling)
        #expect(importer.callCount == 0)
        #expect(await clock.recordedSleeps() == [1, 5])

        #expect(await clock.advanceNextSleep())
        #expect(await eventually { coordinator.state.stage == .completed })
        #expect(importer.callCount == 1)

        let emptyClock = CoordinatorTestScheduler(autoAdvance: false)
        let emptyCoordinator = makeCoordinator(
            client: CoordinatorLibrarySyncClient(discoveries: [.success([])]),
            scheduler: emptyClock.scheduler,
            propagationDelay: 5
        )
        let emptyImporter = CoordinatorImportRecorder()

        #expect(start(
            emptyCoordinator,
            importer: emptyImporter,
            validity: validity
        ))
        #expect(await eventually { emptyCoordinator.state.stage == .completed })
        #expect(await emptyClock.recordedSleeps().isEmpty)
        #expect(emptyImporter.callCount == 1)
    }
}

private extension LibraryRefreshCoordinatorTests {
    func makeCoordinator(
        client: any LibrarySyncClient,
        scheduler: LibraryRefreshScheduler,
        initialPollInterval: TimeInterval = 1,
        maximumPollInterval: TimeInterval = 2,
        providerTimeout: TimeInterval = 30,
        propagationDelay: TimeInterval = 0
    ) -> LibraryRefreshCoordinator {
        LibraryRefreshCoordinator(
            client: client,
            scheduler: scheduler,
            initialPollInterval: initialPollInterval,
            maximumPollInterval: maximumPollInterval,
            providerTimeout: providerTimeout,
            propagationDelay: propagationDelay
        )
    }

    @discardableResult
    func start(
        _ coordinator: LibraryRefreshCoordinator,
        retryProviderCodes: Set<String>? = nil,
        importer: CoordinatorImportRecorder,
        validity: CoordinatorValidity
    ) -> Bool {
        coordinator.start(
            userId: "user",
            retryProviderCodes: retryProviderCodes,
            resolveToken: { _ in "token" },
            userIsCurrent: { validity.isCurrent },
            importLibrary: { importer.recordImport() }
        )
    }
}

@MainActor
private final class CoordinatorImportRecorder {
    private(set) var callCount = 0
    private let result: LibraryImportResult

    init(
        result: LibraryImportResult = LibraryImportResult(
            finalGameCount: 7,
            addedGameIDs: [],
            removedGameIDs: []
        )
    ) {
        self.result = result
    }

    func recordImport() -> LibraryImportResult {
        callCount += 1
        return result
    }

    func recordCancelledImport() throws -> LibraryImportResult {
        callCount += 1
        throw CancellationError()
    }

    func recordFailedImport() throws -> LibraryImportResult {
        callCount += 1
        throw CoordinatorImportFailure()
    }
}

private nonisolated struct CoordinatorImportFailure: Error {}

@MainActor
private final class CoordinatorValidity {
    var isCurrent = true
}

private nonisolated enum CoordinatorRequestOutcome: Sendable {
    case success
    case delay(TimeInterval)
    case failure(LibrarySyncError)
}

nonisolated struct CoordinatorTerminalStateCase: Sendable,
    CustomTestStringConvertible
{
    let state: ProviderAccountSyncState
    let expectedPhase: ProviderSyncPhase

    var testDescription: String {
        state.rawValue ?? "nil"
    }
}

private actor CoordinatorLibrarySyncClient {
    typealias DiscoveryResult = Result<[ConnectedGameLibrary], LibrarySyncError>
    typealias SnapshotResult = Result<[ProviderSyncSnapshot], LibrarySyncError>

    private var discoveries: [DiscoveryResult]
    private var requestOutcomes: [String: [CoordinatorRequestOutcome]]
    private var snapshots: [SnapshotResult]
    private var snapshotDelays: [TimeInterval]
    private let blockRequests: Bool
    private let onDiscover: (@MainActor @Sendable () -> Void)?
    private let onSnapshot: (@Sendable () async -> Void)?

    private var discoveryCalls = 0
    private var requestCalls: [String] = []
    private var snapshotCalls = 0
    private var blockedRequests: [CheckedContinuation<Void, Never>] = []
    private var requestCountTarget: Int?
    private var requestCountContinuation: CheckedContinuation<Void, Never>?

    init(
        discoveries: [DiscoveryResult],
        requestOutcomes: [String: [CoordinatorRequestOutcome]] = [:],
        snapshots: [SnapshotResult] = [],
        snapshotDelays: [TimeInterval] = [],
        blockRequests: Bool = false,
        onDiscover: (@MainActor @Sendable () -> Void)? = nil,
        onSnapshot: (@Sendable () async -> Void)? = nil
    ) {
        self.discoveries = discoveries
        self.requestOutcomes = requestOutcomes
        self.snapshots = snapshots
        self.snapshotDelays = snapshotDelays
        self.blockRequests = blockRequests
        self.onDiscover = onDiscover
        self.onSnapshot = onSnapshot
    }

    func discover(token _: String, userId _: String) async throws -> [ConnectedGameLibrary] {
        discoveryCalls += 1
        if let onDiscover {
            await onDiscover()
        }
        guard !discoveries.isEmpty else {
            throw LibrarySyncError.schema
        }
        return try discoveries.removeFirst().get()
    }

    func requestSync(providerCode: String, token _: String) async throws {
        requestCalls.append(providerCode)
        resumeRequestCountWaiterIfNeeded()

        if blockRequests {
            await withCheckedContinuation { continuation in
                blockedRequests.append(continuation)
            }
        }

        var providerOutcomes = requestOutcomes[providerCode] ?? []
        let outcome = providerOutcomes.isEmpty ? .success : providerOutcomes.removeFirst()
        requestOutcomes[providerCode] = providerOutcomes
        switch outcome {
        case .success:
            break
        case let .delay(seconds):
            try await ContinuousClock().sleep(for: .seconds(seconds))
        case let .failure(error):
            throw error
        }
    }

    func fetchSnapshots(token _: String, userId _: String) async throws -> [ProviderSyncSnapshot] {
        snapshotCalls += 1
        if let onSnapshot {
            await onSnapshot()
        }
        if !snapshotDelays.isEmpty {
            let delay = snapshotDelays.removeFirst()
            try await ContinuousClock().sleep(for: .seconds(delay))
        }
        guard !snapshots.isEmpty else {
            throw LibrarySyncError.schema
        }
        return try snapshots.removeFirst().get()
    }

    func waitForRequestCount(_ expectedCount: Int) async {
        guard requestCalls.count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            requestCountTarget = expectedCount
            requestCountContinuation = continuation
        }
    }

    func releaseAllRequests() {
        let continuations = blockedRequests
        blockedRequests = []
        continuations.forEach { $0.resume() }
    }

    func requestedProviderCodes() -> [String] {
        requestCalls
    }

    func discoveryCallCount() -> Int {
        discoveryCalls
    }

    func snapshotCallCount() -> Int {
        snapshotCalls
    }

    private func resumeRequestCountWaiterIfNeeded() {
        guard let requestCountTarget,
              requestCalls.count >= requestCountTarget,
              let continuation = requestCountContinuation
        else {
            return
        }
        self.requestCountTarget = nil
        requestCountContinuation = nil
        continuation.resume()
    }
}

extension CoordinatorLibrarySyncClient: LibrarySyncClient {}

private actor CoordinatorControlledDeadline {
    private var sleepCount = 0
    private var firstSleepContinuation: CheckedContinuation<Void, Never>?
    private var firstSleepWaiter: CheckedContinuation<Void, Never>?

    func sleep(seconds: TimeInterval) async throws {
        sleepCount += 1
        guard sleepCount == 1 else {
            try await ContinuousClock().sleep(for: .seconds(seconds))
            return
        }

        await withCheckedContinuation { continuation in
            firstSleepContinuation = continuation
            firstSleepWaiter?.resume()
            firstSleepWaiter = nil
        }
    }

    func waitForFirstSleep() async {
        guard firstSleepContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            firstSleepWaiter = continuation
        }
    }

    func fireFirstDeadline() {
        let continuation = firstSleepContinuation
        firstSleepContinuation = nil
        continuation?.resume()
    }
}

private actor CoordinatorTestScheduler {
    private struct PendingSleep {
        let duration: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    nonisolated var scheduler: LibraryRefreshScheduler {
        LibraryRefreshScheduler(
            now: { await self.currentTimeValue() },
            sleep: { try await self.sleep(seconds: $0) }
        )
    }

    private let autoAdvance: Bool
    private var currentTime: TimeInterval = 0
    private var sleeps: [TimeInterval] = []
    private var pendingSleeps: [PendingSleep] = []
    private var sleepCountTarget: Int?
    private var sleepCountContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextNowCall = false
    private var nowCallIsBlocked = false
    private var blockedNowContinuation: CheckedContinuation<Void, Never>?
    private var nowBlockWaiter: CheckedContinuation<Void, Never>?

    init(autoAdvance: Bool) {
        self.autoAdvance = autoAdvance
    }

    func currentTimeValue() async -> TimeInterval {
        if shouldBlockNextNowCall {
            shouldBlockNextNowCall = false
            nowCallIsBlocked = true
            nowBlockWaiter?.resume()
            nowBlockWaiter = nil
            await withCheckedContinuation { continuation in
                blockedNowContinuation = continuation
            }
            nowCallIsBlocked = false
        }
        return currentTime
    }

    func blockNextNowCall() {
        shouldBlockNextNowCall = true
    }

    func waitForBlockedNowCall() async {
        guard !nowCallIsBlocked else { return }
        await withCheckedContinuation { continuation in
            nowBlockWaiter = continuation
        }
    }

    func releaseBlockedNowCall() {
        let continuation = blockedNowContinuation
        blockedNowContinuation = nil
        continuation?.resume()
    }

    func sleep(seconds: TimeInterval) async throws {
        sleeps.append(seconds)
        resumeSleepCountWaiterIfNeeded()
        if autoAdvance {
            currentTime += seconds
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            pendingSleeps.append(
                PendingSleep(duration: seconds, continuation: continuation)
            )
        }
    }

    func waitForSleepCount(_ expectedCount: Int) async {
        guard sleeps.count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            sleepCountTarget = expectedCount
            sleepCountContinuation = continuation
        }
    }

    func advanceNextSleep() -> Bool {
        guard !pendingSleeps.isEmpty else { return false }
        let pending = pendingSleeps.removeFirst()
        currentTime += pending.duration
        pending.continuation.resume()
        return true
    }

    func recordedSleeps() -> [TimeInterval] {
        sleeps
    }

    func advance(by seconds: TimeInterval) {
        currentTime += seconds
    }

    private func resumeSleepCountWaiterIfNeeded() {
        guard let sleepCountTarget,
              sleeps.count >= sleepCountTarget,
              let continuation = sleepCountContinuation
        else {
            return
        }
        self.sleepCountTarget = nil
        sleepCountContinuation = nil
        continuation.resume()
    }
}

private nonisolated func provider(
    _ code: String,
    date: Date?,
    count: Int? = nil,
    state: ProviderAccountSyncState = .unknown(nil),
    supportsSync: Bool = true
) -> ConnectedGameLibrary {
    ConnectedGameLibrary(
        code: code,
        displayName: code,
        accountDisplayName: "\(code) account",
        iconURL: nil,
        supportsSync: supportsSync,
        sortOrder: 0,
        snapshot: snapshot(code, date: date, count: count, state: state)
    )
}

private nonisolated func snapshot(
    _ code: String,
    date: Date?,
    count: Int?,
    state: ProviderAccountSyncState = .success
) -> ProviderSyncSnapshot {
    ProviderSyncSnapshot(
        providerCode: code,
        totalSyncedGames: count,
        state: state,
        syncDate: date
    )
}

@MainActor
private func eventually(
    _ condition: @MainActor () -> Bool
) async -> Bool {
    for _ in 0 ..< 1000 {
        if condition() {
            return true
        }
        try? await ContinuousClock().sleep(for: .milliseconds(1))
    }
    return false
}

@MainActor
private func drainTasks() async {
    for _ in 0 ..< 50 {
        await Task.yield()
    }
}
