@testable import CloudNow
import Foundation
import Synchronization
import Testing

@Suite("Cloud gaming capabilities")
struct CloudGamingCapabilitiesTests {
    @Test("Capability states expose only confirmed support")
    func capabilityStatesFailClosed() {
        let reason = CloudCapabilityReason(
            .serviceUnavailable,
            localizationKey: "cloud_service_unavailable"
        )
        let supported = CloudCapability<Int>.supported(4)
        let unavailable = CloudCapability<Int>.unavailable(reason)
        let unknown = CloudCapability<Int>.unknown

        #expect(supported.value == 4)
        #expect(supported.unavailableReason == nil)
        #expect(supported.isSupported)
        #expect(unavailable.value == nil)
        #expect(unavailable.unavailableReason == reason)
        #expect(!unavailable.isSupported)
        #expect(unknown.value == nil)
        #expect(unknown.unavailableReason == nil)
        #expect(!unknown.isSupported)
    }

    @Test("Unknown provider snapshots hide every capability")
    func unknownSnapshot() {
        let snapshot = CloudGamingProviderCapabilities.unknown(
            for: .xboxCloudGaming
        )

        #expect(snapshot.provider == .xboxCloudGaming)
        #expect(snapshot.availability == .unknown)
        #expect(snapshot.account == .unknown)
        #expect(snapshot.catalog == .unknown)
        #expect(snapshot.streamOptions == .unknown)
        #expect(snapshot.input == .unknown)
        #expect(snapshot.microphone == .unknown)
        #expect(snapshot.session == .unknown)
        #expect(snapshot.diagnostics == .unknown)
    }

    @Test("Reconnect policy is bounded and exponential")
    func reconnectPolicy() {
        let policy = CloudReconnectPolicy.standard

        #expect(policy.maximumAttempts == 3)
        #expect(policy.attemptWindow == 30)
        #expect(policy.delay(beforeAttempt: 0) == nil)
        #expect(policy.delay(beforeAttempt: 1) == 1)
        #expect(policy.delay(beforeAttempt: 2) == 2)
        #expect(policy.delay(beforeAttempt: 3) == 4)
        #expect(policy.delay(beforeAttempt: 4) == nil)
    }

    @Test("Only connecting playback states own a local peer")
    func presentationPeerOwnership() {
        let failure = CloudStreamPresentationFailure(
            localizationKey: "stream_failed",
            isRetryable: true
        )
        let nonPeerStates: [CloudStreamPresentationState] = [
            .idle,
            .allocating,
            .queued(position: nil, estimatedWait: nil),
            .provisioning(progress: nil, estimatedWait: nil),
            .resumable(expiresAt: .distantFuture),
            .failure(failure),
            .stopping,
        ]

        #expect(nonPeerStates.allSatisfy { !$0.isUsingLocalPeer })
        #expect(CloudStreamPresentationState.connecting.isUsingLocalPeer)
        #expect(CloudStreamPresentationState.streaming.isUsingLocalPeer)
        #expect(
            CloudStreamPresentationState.reconnecting(
                attempt: 1,
                maximumAttempts: 3,
                nextDelay: 1
            ).isUsingLocalPeer
        )
    }

    @Test("GFN adapter declares the existing native feature set")
    func gfnAdapter() throws {
        let snapshot = GFNCapabilityAdapter().capabilities
        let input = try #require(snapshot.input.value)
        let microphone = try #require(snapshot.microphone.value)

        #expect(snapshot.availability.isSupported)
        #expect(input.maximumControllerSlots == 4)
        #expect(input.devices.contains(.keyboardMouse))
        #expect(input.controllerFeatures.contains(.independentRumble))
        #expect(!input.controllerFeatures.contains(.share))
        #expect(!microphone.defaultsEnabled)
        #expect(microphone.supportsAutomaticRouteHotSwap)
    }

    @Test("GFN stream states adapt without changing native behavior")
    func gfnPresentationAdapter() {
        #expect(StreamState.idle.cloudPresentationState == .idle)
        #expect(StreamState.connecting.cloudPresentationState == .connecting)
        #expect(StreamState.streaming.cloudPresentationState == .streaming)
        #expect(
            StreamState.reconnecting(attempt: 2).cloudPresentationState
                == .reconnecting(
                    attempt: 2,
                    maximumAttempts: 3,
                    nextDelay: 2
                )
        )
        #expect(
            StreamState.disconnected(reason: "fixture")
                .cloudPresentationState
                == .failure(
                    CloudStreamPresentationFailure(
                        localizationKey: "stream_failed",
                        isRetryable: true
                    )
                )
        )
        #expect(
            StreamState.failed(message: "fixture").cloudPresentationState
                == .failure(
                    CloudStreamPresentationFailure(
                        localizationKey: "stream_failed",
                        isRetryable: true
                    )
                )
        )
        #expect(StreamState.sessionEnded.cloudPresentationState == .stopping)
    }

    @Test("Unconfigured Xbox fails closed without affecting GFN")
    func unconfiguredXboxAdapter() {
        let xbox = XboxCapabilityAdapter(
            environment: .unconfigured
        ).capabilities
        let gfn = GFNCapabilityAdapter().capabilities

        #expect(!xbox.availability.isSupported)
        #expect(
            xbox.availability.unavailableReason?.code == .serviceUnavailable
        )
        #expect(gfn.availability.isSupported)
        #expect(gfn.diagnostics.value?.supportsLocalExport == false)
    }

    @Test("A sign-in-only Xbox environment reports service unavailability")
    func signInOnlyXboxAdapter() {
        let snapshot = XboxCapabilityAdapter(
            environment: .productionMicrosoftSignIn
        ).capabilities

        #expect(!snapshot.availability.isSupported)
        #expect(snapshot.availability.unavailableReason?.code == .serviceUnavailable)
        #expect(snapshot.catalog.unavailableReason?.code == .serviceUnavailable)
    }

    @Test("An invalid Xbox compatibility profile fails closed")
    func invalidProfileXboxAdapter() {
        let snapshot = XboxCapabilityAdapter(
            environment: .invalidCompatibilityProfile
        ).capabilities

        #expect(!snapshot.availability.isSupported)
        #expect(snapshot.availability.unavailableReason?.code == .profileInvalid)
        #expect(snapshot.catalog.unavailableReason?.code == .profileInvalid)
    }

    @Test("Configured Xbox exposes only confirmed options")
    func configuredXboxAdapter() throws {
        let snapshot = XboxCapabilityAdapter(
            environment: configuredXboxEnvironment()
        ).capabilities
        let catalog = try #require(snapshot.catalog.value)
        let options = try #require(snapshot.streamOptions.value)
        let input = try #require(snapshot.input.value)

        #expect(snapshot.availability.isSupported)
        #expect(snapshot.account.isSupported)
        #expect(catalog.filters == [
            .ads,
            .favorite,
            .genre,
            .input,
            .owned,
            .playable,
            .subscription,
            .unavailableReason,
        ])
        #expect(options.qualityControls == [.automatic])
        #expect(options.audioControls == [.automatic])
        #expect(options.hdrControls == [.automatic])
        #expect(input.devices == [.controller, .keyboardMouse])
        #expect(input.maximumControllerSlots == nil)
        #expect(input.controllerFeatures.contains(.share))
        #expect(
            snapshot.microphone.value?.supportsAutomaticRouteHotSwap == true
        )
        #expect(snapshot.session.value?.supportsResume == true)
        #expect(snapshot.diagnostics.value?.supportsNetworkTest == true)
        #expect(snapshot.diagnostics.value?.supportsLocalExport == false)
    }

    @Test("Provider cache clear preserves unattributed shared resources")
    func providerCacheClearScope() {
        #expect(
            AppCacheClearScope.allProviders
                .clearsSharedArtworkAndURLResponses
        )
        #expect(
            !AppCacheClearScope.provider(.geForceNow)
                .clearsSharedArtworkAndURLResponses
        )
        #expect(
            !AppCacheClearScope.provider(.xboxCloudGaming)
                .clearsSharedArtworkAndURLResponses
        )
    }

    @Test("Xbox stream states cover every shared presentation branch")
    func xboxPresentationAdapter() {
        let failure = CloudStreamPresentationFailure(
            localizationKey: "stream_failed",
            isRetryable: false
        )
        let cases: [(XboxCloudStreamState, CloudStreamPresentationState)] = [
            (.idle, .idle),
            (.requestingAccess, .allocating),
            (.allocating, .allocating),
            (.waiting(estimatedSeconds: 30), .queued(position: nil, estimatedWait: 30)),
            (
                .provisioning(estimatedSeconds: 20),
                .provisioning(progress: nil, estimatedWait: 20)
            ),
            (.connecting, .connecting),
            (.streaming, .streaming),
            (
                .reconnecting(attempt: 2, maximumAttempts: 3, nextDelay: 2),
                .reconnecting(attempt: 2, maximumAttempts: 3, nextDelay: 2)
            ),
            (.stopping, .stopping),
            (.failed(message: "sanitized"), .failure(failure)),
        ]

        for (state, expected) in cases {
            #expect(state.cloudPresentationState == expected)
        }
    }

    @Test("Provider availability does not imply account authorization")
    func configuredXboxWithoutAccountAuthorization() {
        let base = configuredXboxEnvironment()
        let environment = XboxCloudEnvironment(
            authentication: base.authentication,
            makeAccountAuthorizationClient: nil,
            service: base.service
        )
        let snapshot = XboxCapabilityAdapter(environment: environment).capabilities

        #expect(snapshot.availability.isSupported)
        #expect(!snapshot.account.isSupported)
        #expect(snapshot.account.unavailableReason?.code == .accountRequired)
    }

    @MainActor
    @Test("Session coordinator enforces one server session and peer")
    func sessionCoordinatorEnforcesGlobalLimits() throws {
        let coordinator = CloudSessionCoordinator()
        let lease = try coordinator.reserveServerSession(
            provider: .geForceNow,
            serverSessionID: "gfn-session"
        )

        #expect(
            coordinator.switchRequirement(to: .xboxCloudGaming)
                == .leaveOrEnd(lease)
        )
        #expect(throws: CloudSessionConflict.self) {
            _ = try coordinator.reserveServerSession(
                provider: .geForceNow,
                serverSessionID: "gfn-session"
            )
        }
        #expect(throws: CloudSessionConflict.self) {
            _ = try coordinator.reserveServerSession(
                provider: .geForceNow,
                serverSessionID: "second-session"
            )
        }
        #expect(throws: CloudSessionConflict.self) {
            _ = try coordinator.reserveServerSession(
                provider: .xboxCloudGaming,
                serverSessionID: "xbox-session"
            )
        }

        let localPeer = try coordinator.attachLocalPeer(for: .geForceNow)
        #expect(coordinator.localPeerProvider == .geForceNow)
        #expect(throws: CloudSessionConflict.self) {
            _ = try coordinator.attachLocalPeer(for: .geForceNow)
        }
        #expect(throws: CloudSessionConflict.self) {
            _ = try coordinator.attachLocalPeer(for: .xboxCloudGaming)
        }
        coordinator.releaseLocalPeer(CloudLocalPeerLease(
            provider: .geForceNow
        ))
        #expect(coordinator.localPeerProvider == .geForceNow)
        coordinator.releaseLocalPeer(localPeer)
        #expect(coordinator.localPeerProvider == nil)
    }

    @MainActor
    @Test("Local peer lease tokens reject duplicate attach and stale release")
    func localPeerLeaseTokens() throws {
        let coordinator = CloudSessionCoordinator()
        let first = try coordinator.attachLocalPeer(for: .geForceNow)

        #expect(throws: CloudSessionConflict.self) {
            _ = try coordinator.attachLocalPeer(for: .geForceNow)
        }

        coordinator.releaseLocalPeer(first)
        let second = try coordinator.attachLocalPeer(for: .geForceNow)
        coordinator.releaseLocalPeer(first)
        #expect(coordinator.localPeerLease == second)

        coordinator.releaseLocalPeer(second)
        #expect(coordinator.localPeerLease == nil)
    }

    @MainActor
    @Test("Parked reservation adopts explicitly and binds service identity")
    func parkedReservationAdoptionAndBinding() throws {
        let coordinator = CloudSessionCoordinator()
        let provisional = try coordinator.reserveServerSession(
            provider: .xboxCloudGaming,
            serverSessionID: "account:title"
        )
        let bound = try coordinator.bindServerSession(
            provisional,
            to: "xbox-service-redacted"
        )
        #expect(bound.id == provisional.id)
        #expect(bound.serverSessionID == "xbox-service-redacted")

        coordinator.parkServerSession(bound, expiresAt: .distantFuture)
        let adopted = try coordinator.adoptParkedServerSession(
            provider: .xboxCloudGaming,
            serverSessionID: "xbox-service-redacted"
        )

        #expect(adopted.id == provisional.id)
        #expect(adopted.phase == .active)
        #expect(throws: CloudSessionConflict.self) {
            _ = try coordinator.adoptParkedServerSession(
                provider: .xboxCloudGaming,
                serverSessionID: "xbox-service-redacted"
            )
        }
    }

    @MainActor
    @Test("Competing launch reservations create only one service session")
    func competingLaunchReservations() async {
        let coordinator = CloudSessionCoordinator()
        let createCounter = CapabilityLaunchCounter()

        let first = Task { @MainActor in
            do {
                _ = try coordinator.reserveServerSession(
                    provider: .xboxCloudGaming,
                    serverSessionID: "account:title"
                )
                createCounter.recordCreate()
                return true
            } catch {
                return false
            }
        }
        let second = Task { @MainActor in
            do {
                _ = try coordinator.reserveServerSession(
                    provider: .xboxCloudGaming,
                    serverSessionID: "account:title"
                )
                createCounter.recordCreate()
                return true
            } catch {
                return false
            }
        }

        let firstSucceeded = await first.value
        let secondSucceeded = await second.value
        #expect(firstSucceeded != secondSucceeded)
        #expect(createCounter.createCount == 1)
    }

    @MainActor
    @Test("A stale reservation cannot bind a newer server lease")
    func staleReservationCannotBindNewLease() throws {
        let coordinator = CloudSessionCoordinator()
        let stale = try coordinator.reserveServerSession(
            provider: .xboxCloudGaming,
            serverSessionID: "first"
        )
        coordinator.endServerSession(stale)
        let current = try coordinator.reserveServerSession(
            provider: .xboxCloudGaming,
            serverSessionID: "second"
        )

        #expect(throws: CloudSessionConflict.self) {
            _ = try coordinator.bindServerSession(stale, to: "stale-bind")
        }
        #expect(coordinator.serverSession == current)
    }

    @MainActor
    @Test("Parked sessions never expire without confirmed provider End")
    func parkedSessionPolicy() throws {
        let clock = CapabilityDateClock(Date(timeIntervalSince1970: 0))
        let coordinator = CloudSessionCoordinator(now: { clock.now })
        let lease = try coordinator.reserveServerSession(
            provider: .geForceNow,
            serverSessionID: "gfn-session"
        )
        _ = try coordinator.attachLocalPeer(for: .geForceNow)
        let expiry = Date(timeIntervalSince1970: 100)

        coordinator.parkServerSession(lease, expiresAt: expiry)
        let parked = try #require(coordinator.serverSession)

        #expect(coordinator.localPeerProvider == nil)
        #expect(
            coordinator.switchRequirement(to: .xboxCloudGaming)
                == .endParkedSession(parked)
        )
        #expect(
            coordinator.switchRequirement(to: .geForceNow) == .allowed
        )

        coordinator.removeExpiredParkedSession(
            now: Date(timeIntervalSince1970: 99)
        )
        #expect(coordinator.serverSession == parked)
        clock.set(expiry)
        coordinator.removeExpiredParkedSession()
        #expect(coordinator.serverSession == parked)
        #expect(
            coordinator.switchRequirement(to: .xboxCloudGaming)
                == .endParkedSession(parked)
        )
        #expect(throws: CloudSessionConflict.self) {
            _ = try coordinator.reserveServerSession(
                provider: .geForceNow,
                serverSessionID: "gfn-session"
            )
        }
        #expect(throws: CloudSessionConflict.self) {
            _ = try coordinator.reserveServerSession(
                provider: .xboxCloudGaming,
                serverSessionID: "xbox-session"
            )
        }
    }

    @MainActor
    @Test("Already-expired parking holds the lease through confirmed End")
    func expiredParkingAwaitsConfirmedEnd() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let coordinator = CloudSessionCoordinator(now: { now })
        let actions = SessionActionFixture()
        let entered = CapabilityAsyncGate()
        let release = CapabilityAsyncGate()
        let lease = try coordinator.reserveServerSession(
            provider: .xboxCloudGaming,
            serverSessionID: "expired-session",
            actions: CloudServerSessionActions(
                end: {
                    actions.endCount += 1
                    await entered.open()
                    await release.wait()
                    return true
                }
            )
        )

        coordinator.parkServerSession(lease, expiresAt: now)
        await entered.wait()

        let retainedLease = try #require(coordinator.serverSession)
        #expect(retainedLease.id == lease.id)
        #expect(actions.endCount == 1)
        #expect(
            coordinator.switchRequirement(to: .geForceNow)
                == .endParkedSession(retainedLease)
        )
        #expect(throws: CloudSessionConflict.self) {
            _ = try coordinator.reserveServerSession(
                provider: .xboxCloudGaming,
                serverSessionID: "expired-session"
            )
        }
        #expect(throws: CloudSessionConflict.self) {
            _ = try coordinator.reserveServerSession(
                provider: .geForceNow,
                serverSessionID: "gfn-session"
            )
        }

        await release.open()
        for _ in 0 ..< 100 where coordinator.serverSession != nil {
            await Task.yield()
        }

        #expect(coordinator.serverSession == nil)
        #expect(coordinator.switchRequirement(to: .geForceNow) == .allowed)
    }

    @MainActor
    @Test("Scheduled parked expiry rechecks an injected clock after rollback")
    func scheduledExpiryRechecksClock() async throws {
        let clock = CapabilityDateClock(Date(timeIntervalSince1970: 0))
        let sleeps = CapabilitySleepGate()
        let actions = SessionActionFixture()
        let coordinator = CloudSessionCoordinator(
            now: { clock.now },
            sleep: { delay in
                try await sleeps.sleep(for: delay)
            }
        )
        let lease = try coordinator.reserveServerSession(
            provider: .geForceNow,
            serverSessionID: "scheduled-expiry",
            actions: CloudServerSessionActions(
                end: {
                    actions.endCount += 1
                    return true
                }
            )
        )
        let expiry = Date(timeIntervalSince1970: 100)

        coordinator.parkServerSession(lease, expiresAt: expiry)
        await sleeps.waitForRequestCount(1)
        #expect(await sleeps.requestedDelays == [100])

        clock.set(Date(timeIntervalSince1970: -50))
        await sleeps.resumeNext()
        await sleeps.waitForRequestCount(2)
        #expect(await sleeps.requestedDelays == [100, 150])
        #expect(coordinator.serverSession?.phase == .parked(expiresAt: expiry))

        clock.set(expiry)
        await sleeps.resumeNext()
        for _ in 0 ..< 100 where coordinator.serverSession != nil {
            await Task.yield()
        }

        #expect(coordinator.serverSession == nil)
        #expect(actions.endCount == 1)
        #expect(coordinator.switchRequirement(to: .xboxCloudGaming) == .allowed)
    }

    @MainActor
    @Test("Only the current lease can mutate session ownership")
    func staleLeaseCannotMutateSession() throws {
        let coordinator = CloudSessionCoordinator()
        let lease = try coordinator.reserveServerSession(
            provider: .geForceNow,
            serverSessionID: "gfn-session"
        )
        let stale = CloudServerSessionLease(
            id: UUID(),
            provider: .geForceNow,
            serverSessionID: "gfn-session",
            phase: .active
        )

        coordinator.parkServerSession(stale, expiresAt: .distantFuture)
        coordinator.endServerSession(stale)
        #expect(coordinator.serverSession == lease)

        coordinator.endServerSession(lease)
        #expect(coordinator.serverSession == nil)
        #expect(
            coordinator.switchRequirement(to: .xboxCloudGaming) == .allowed
        )
    }

    @MainActor
    @Test("Leave executes provider work before parking the lease")
    func leaveExecutesProviderAction() async throws {
        let coordinator = CloudSessionCoordinator()
        let actions = SessionActionFixture()
        let expiry = Date.distantFuture
        let lease = try coordinator.reserveServerSession(
            provider: .xboxCloudGaming,
            serverSessionID: "xbox-session",
            actions: CloudServerSessionActions(
                leave: {
                    actions.leaveCount += 1
                    #expect(coordinator.serverSession?.phase == .active)
                    return expiry
                },
                end: {
                    actions.endCount += 1
                    return true
                }
            )
        )
        _ = try coordinator.attachLocalPeer(for: .xboxCloudGaming)

        let didLeave = await coordinator.leaveServerSession(lease)

        #expect(didLeave)
        #expect(actions.leaveCount == 1)
        #expect(actions.endCount == 0)
        #expect(coordinator.localPeerProvider == nil)
        #expect(coordinator.serverSession?.phase == .parked(expiresAt: expiry))
    }

    @MainActor
    @Test("End executes provider work before releasing the lease")
    func endExecutesProviderAction() async throws {
        let coordinator = CloudSessionCoordinator()
        let actions = SessionActionFixture()
        let leaseID = UUID()
        let lease = try coordinator.reserveServerSession(
            provider: .geForceNow,
            serverSessionID: "gfn-session",
            actions: CloudServerSessionActions(
                end: {
                    actions.endCount += 1
                    #expect(coordinator.serverSession?.id == leaseID)
                    return true
                }
            ),
            id: leaseID
        )
        _ = try coordinator.attachLocalPeer(for: .geForceNow)

        let didEnd = await coordinator.endServerSessionUsingProvider(lease)

        #expect(didEnd)
        #expect(actions.endCount == 1)
        #expect(coordinator.serverSession == nil)
        #expect(coordinator.localPeerProvider == nil)
    }

    @MainActor
    @Test("An in-flight provider End retains the global lease")
    func inFlightEndRetainsLease() async throws {
        let coordinator = CloudSessionCoordinator()
        let entered = CapabilityAsyncGate()
        let release = CapabilityAsyncGate()
        let lease = try coordinator.reserveServerSession(
            provider: .geForceNow,
            serverSessionID: "gfn-session",
            actions: CloudServerSessionActions(
                end: {
                    await entered.open()
                    await release.wait()
                    return true
                }
            )
        )
        let endTask = Task {
            await coordinator.endServerSessionUsingProvider(lease)
        }
        await entered.wait()

        #expect(throws: CloudSessionConflict.self) {
            _ = try coordinator.reserveServerSession(
                provider: .xboxCloudGaming,
                serverSessionID: "xbox-session"
            )
        }

        await release.open()
        #expect(await endTask.value)
        #expect(coordinator.serverSession == nil)
        #expect(
            try coordinator.reserveServerSession(
                provider: .xboxCloudGaming,
                serverSessionID: "xbox-session"
            ).provider == .xboxCloudGaming
        )
    }

    @MainActor
    @Test("Concurrent provider End calls share one operation")
    func concurrentEndIsSingleFlight() async throws {
        let coordinator = CloudSessionCoordinator()
        let actions = SessionActionFixture()
        let entered = CapabilityAsyncGate()
        let release = CapabilityAsyncGate()
        let lease = try coordinator.reserveServerSession(
            provider: .geForceNow,
            serverSessionID: "gfn-session",
            actions: CloudServerSessionActions(
                end: {
                    actions.endCount += 1
                    await entered.open()
                    await release.wait()
                    return true
                }
            )
        )
        let first = Task {
            await coordinator.endServerSessionUsingProvider(lease)
        }
        await entered.wait()
        let second = Task {
            await coordinator.endServerSessionUsingProvider(lease)
        }
        await Task.yield()

        #expect(actions.endCount == 1)
        #expect(coordinator.serverSession == lease)

        await release.open()
        #expect(await first.value)
        #expect(await second.value)
        #expect(actions.endCount == 1)
        #expect(coordinator.serverSession == nil)
    }

    @MainActor
    @Test("Failed provider End quarantines the lease for retry")
    func failedEndRetainsLease() async throws {
        let coordinator = CloudSessionCoordinator()
        let actions = SessionActionFixture()
        actions.endShouldSucceed = false
        let lease = try coordinator.reserveServerSession(
            provider: .geForceNow,
            serverSessionID: "gfn-session",
            actions: CloudServerSessionActions(
                end: {
                    actions.endCount += 1
                    return actions.endShouldSucceed
                }
            )
        )

        #expect(await !(coordinator.endServerSessionUsingProvider(lease)))
        #expect(coordinator.serverSession == lease)
        #expect(throws: CloudSessionConflict.self) {
            _ = try coordinator.reserveServerSession(
                provider: .xboxCloudGaming,
                serverSessionID: "xbox-session"
            )
        }

        actions.endShouldSucceed = true
        #expect(await coordinator.endServerSessionUsingProvider(lease))
        #expect(actions.endCount == 2)
        #expect(coordinator.serverSession == nil)
    }

    @MainActor
    @Test("A failed parked End suppresses approximate expiry until retry")
    func failedParkedEndRemainsQuarantinedPastExpiry() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let coordinator = CloudSessionCoordinator(now: { now })
        let actions = SessionActionFixture()
        actions.endShouldSucceed = false
        let lease = try coordinator.reserveServerSession(
            provider: .geForceNow,
            serverSessionID: "parked-failure",
            actions: CloudServerSessionActions(
                end: {
                    actions.endCount += 1
                    return actions.endShouldSucceed
                }
            )
        )
        let expiry = now.addingTimeInterval(60)
        coordinator.parkServerSession(lease, expiresAt: expiry)

        #expect(await !(coordinator.endServerSessionUsingProvider(lease)))
        coordinator.removeExpiredParkedSession(now: expiry)

        let retainedLease = try #require(coordinator.serverSession)
        #expect(retainedLease.id == lease.id)
        #expect(
            coordinator.switchRequirement(to: .xboxCloudGaming)
                == .endParkedSession(retainedLease)
        )

        actions.endShouldSucceed = true
        #expect(await coordinator.endServerSessionUsingProvider(lease))
        #expect(actions.endCount == 2)
        #expect(coordinator.serverSession == nil)
    }

    @MainActor
    @Test("Missing provider actions fail closed")
    func missingProviderActionsFailClosed() async throws {
        let coordinator = CloudSessionCoordinator()
        let lease = try coordinator.reserveServerSession(
            provider: .xboxCloudGaming,
            serverSessionID: "xbox-session"
        )

        #expect(!coordinator.canLeaveServerSession(lease))
        #expect(await !(coordinator.leaveServerSession(lease)))
        #expect(await !(coordinator.endServerSessionUsingProvider(lease)))
        #expect(coordinator.serverSession == lease)
    }

    @MainActor
    @Test("Input monitor fails closed and refreshes hot-swapped devices")
    func inputDeviceMonitor() {
        let fixture = InputSnapshotFixture(devices: [.controller])
        let monitor = CloudInputDeviceMonitor(
            notificationCenter: NotificationCenter(),
            snapshot: { fixture.devices }
        )

        #expect(monitor.supports([.controller]))
        #expect(!monitor.supports([]))
        #expect(!monitor.supports([.keyboardMouse]))

        monitor.start()
        monitor.start()
        fixture.devices = [.keyboardMouse, .textEntry]
        monitor.refresh()

        #expect(!monitor.supports([.controller]))
        #expect(monitor.supports([.keyboardMouse]))
        #expect(monitor.connectedDevices.contains(.textEntry))

        monitor.stop()
        monitor.stop()
    }

    private func configuredXboxEnvironment() -> XboxCloudEnvironment {
        XboxCloudEnvironment(
            authentication: XboxCloudEnvironment.productionMicrosoftAuthentication,
            makeAccountAuthorizationClient: {
                CapabilityAccountAuthorizationClient()
            },
            service: XboxCloudServiceConfiguration(
                makeCatalogClient: { CapabilityCatalogClient() },
                makeStreamController: { _ in
                    fatalError("Capability test does not construct a stream")
                }
            )
        )
    }
}

@MainActor
private final class SessionActionFixture {
    var leaveCount = 0
    var endCount = 0
    var endShouldSucceed = true
}

@MainActor
private final class CapabilityLaunchCounter {
    private(set) var createCount = 0

    func recordCreate() {
        createCount += 1
    }
}

private final class CapabilityDateClock: Sendable {
    private let value: Mutex<Date>

    init(_ value: Date) {
        self.value = Mutex(value)
    }

    var now: Date {
        value.withLock { $0 }
    }

    func set(_ newValue: Date) {
        value.withLock { $0 = newValue }
    }
}

private actor CapabilitySleepGate {
    private(set) var requestedDelays: [TimeInterval] = []
    private var continuations: [CheckedContinuation<Void, Error>] = []

    func sleep(for delay: TimeInterval) async throws {
        requestedDelays.append(delay)
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForRequestCount(_ expected: Int) async {
        while requestedDelays.count < expected {
            await Task.yield()
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor CapabilityAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

@MainActor
private final class InputSnapshotFixture {
    var devices: Set<CloudInputDeviceKind>

    init(devices: Set<CloudInputDeviceKind>) {
        self.devices = devices
    }
}

private nonisolated struct CapabilityAccountAuthorizationClient:
    XboxCloudAccountAuthorizationClient
{
    func authorize(
        microsoftToken _: MicrosoftOAuthToken
    ) async throws -> XboxCloudAuthorizedAccount {
        throw CancellationError()
    }
}

private nonisolated struct CapabilityCatalogClient: XboxCatalogClient {
    func fetchCatalog(
        _: XboxCatalogRequest,
        account _: XboxCloudAuthorizedAccount
    ) async throws -> XboxCatalogSnapshot {
        XboxCatalogSnapshot(items: [], fetchedAt: .distantPast)
    }

    func cancel() {}
}
