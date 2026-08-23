import Foundation
import Observation

/// Provider-neutral reason attached to an unavailable capability. Presentation
/// resolves `localizationKey` through `L10n`; provider wire errors never cross
/// this boundary.
nonisolated struct CloudCapabilityReason: Equatable, Hashable, Sendable {
    nonisolated enum Code: String, Codable, CaseIterable, Sendable {
        case accountRequired
        case inputUnavailable
        case microphonePermissionDenied
        case notOwned
        case planRequired
        case profileInvalid
        case regionUnavailable
        case serviceUnavailable
        case titleUnavailable
        case touchOnly
        case unsupportedByDevice
        case unsupportedByService
    }

    let code: Code
    let localizationKey: String

    init(_ code: Code, localizationKey: String) {
        self.code = code
        self.localizationKey = localizationKey
    }
}

/// Capabilities are intentionally three-state. An unknown optional capability
/// stays hidden; an unknown required capability cannot be treated as supported.
nonisolated enum CloudCapability<Value: Equatable & Sendable>: Equatable, Sendable {
    case supported(Value)
    case unavailable(CloudCapabilityReason)
    case unknown

    var value: Value? {
        guard case let .supported(value) = self else { return nil }
        return value
    }

    var unavailableReason: CloudCapabilityReason? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }

    var isSupported: Bool {
        value != nil
    }
}

nonisolated struct CloudProviderAvailabilityCapability: Equatable, Sendable {
    static let available = CloudProviderAvailabilityCapability()
}

nonisolated struct CloudAccountCapability: Equatable, Sendable {
    let maximumAccounts: Int
    let persistsSignIn: Bool
}

nonisolated enum CloudCatalogFilterCapability: String, CaseIterable, Hashable, Sendable {
    case ads
    case favorite
    case genre
    case input
    case owned
    case playable
    case subscription
    case unavailableReason
}

nonisolated struct CloudCatalogCapability: Equatable, Sendable {
    let filters: Set<CloudCatalogFilterCapability>
    let keepsUnavailableTitlesVisible: Bool
    let reasonedPlayability: Bool
    let supportsExplicitRefresh: Bool
    let supportsFavorites: Bool
    let supportsRecentlyPlayed: Bool
}

nonisolated enum CloudQualityControl: String, CaseIterable, Hashable, Sendable {
    case automatic
    case bitrate
    case codec
    case frameRate
    case resolution
}

nonisolated enum CloudAudioControl: String, CaseIterable, Hashable, Sendable {
    case automatic
    case stereo
    case surround51
}

nonisolated enum CloudHDRControl: String, CaseIterable, Hashable, Sendable {
    case automatic
    case hdr
    case sdr
}

nonisolated struct CloudStreamOptionsCapability: Equatable, Sendable {
    let qualityControls: Set<CloudQualityControl>
    let audioControls: Set<CloudAudioControl>
    let hdrControls: Set<CloudHDRControl>
    let supportsServiceConfirmedRegions: Bool
}

nonisolated enum CloudInputDeviceKind: String, CaseIterable, Hashable, Sendable {
    case controller
    case keyboardMouse
    case remotePointer
    case textEntry
    case touch
}

nonisolated enum CloudControllerFeature: String, CaseIterable, Hashable, Sendable {
    case independentRumble
    case menu
    case share
    case stablePlayerIndex
    case view
}

nonisolated struct CloudInputCapability: Equatable, Sendable {
    let devices: Set<CloudInputDeviceKind>
    let controllerFeatures: Set<CloudControllerFeature>
    /// `nil` means the service has not confirmed a slot count.
    let maximumControllerSlots: Int?
}

nonisolated struct CloudMicrophoneCapability: Equatable, Sendable {
    let defaultsEnabled: Bool
    let supportsAutomaticRouteHotSwap: Bool
    let supportsVoiceChat: Bool
}

nonisolated struct CloudReconnectPolicy: Equatable, Sendable {
    static let standard = CloudReconnectPolicy(
        maximumAttempts: 3,
        attemptWindow: 30,
        initialBackoff: 1
    )

    let maximumAttempts: Int
    let attemptWindow: TimeInterval
    let initialBackoff: TimeInterval

    func delay(beforeAttempt attempt: Int) -> TimeInterval? {
        guard attempt > 0, attempt <= maximumAttempts else { return nil }
        return min(initialBackoff * pow(2, Double(attempt - 1)), attemptWindow)
    }
}

nonisolated struct CloudSessionCapability: Equatable, Sendable {
    let supportsBackgroundLeave: Bool
    let supportsResume: Bool
    let reconnectPolicy: CloudReconnectPolicy?
}

nonisolated struct CloudDiagnosticsCapability: Equatable, Sendable {
    let supportsLocalExport: Bool
    let supportsNetworkTest: Bool
    let supportsStreamHUD: Bool
}

nonisolated struct CloudNetworkTestTarget: Equatable, Sendable {
    let address: String
    let displayName: String?

    init(address: String, displayName: String? = nil) {
        self.address = address
        self.displayName = displayName
    }
}

/// Complete capability snapshot for one provider. Keeping the fields narrow
/// allows settings and player UI to reuse only the behavior each surface needs.
nonisolated struct CloudGamingProviderCapabilities: Equatable, Sendable {
    let provider: CloudGamingProvider
    let availability: CloudCapability<CloudProviderAvailabilityCapability>
    let account: CloudCapability<CloudAccountCapability>
    let catalog: CloudCapability<CloudCatalogCapability>
    let streamOptions: CloudCapability<CloudStreamOptionsCapability>
    let input: CloudCapability<CloudInputCapability>
    let microphone: CloudCapability<CloudMicrophoneCapability>
    let session: CloudCapability<CloudSessionCapability>
    let diagnostics: CloudCapability<CloudDiagnosticsCapability>

    static func unknown(for provider: CloudGamingProvider) -> Self {
        Self(
            provider: provider,
            availability: .unknown,
            account: .unknown,
            catalog: .unknown,
            streamOptions: .unknown,
            input: .unknown,
            microphone: .unknown,
            session: .unknown,
            diagnostics: .unknown
        )
    }
}

nonisolated protocol CloudGamingCapabilityProviding: Sendable {
    var provider: CloudGamingProvider { get }
    var capabilities: CloudGamingProviderCapabilities { get }
}

/// Shared lifecycle states consumed by launch UI, fixtures and accessibility.
/// Providers retain their wire-level state machines and adapt into this model.
nonisolated enum CloudStreamPresentationState: Equatable, Sendable {
    case idle
    case allocating
    case queued(position: Int?, estimatedWait: TimeInterval?)
    case provisioning(progress: Double?, estimatedWait: TimeInterval?)
    case connecting
    case streaming
    case reconnecting(attempt: Int, maximumAttempts: Int, nextDelay: TimeInterval?)
    case resumable(expiresAt: Date)
    case failure(CloudStreamPresentationFailure)
    case stopping

    var isUsingLocalPeer: Bool {
        switch self {
        case .connecting, .streaming, .reconnecting:
            true
        case .idle, .allocating, .queued, .provisioning, .resumable, .failure, .stopping:
            false
        }
    }
}

nonisolated struct CloudStreamPresentationFailure: Equatable, Sendable {
    let localizationKey: String
    let isRetryable: Bool
}

nonisolated enum CloudServerSessionPhase: Equatable, Sendable {
    case active
    case parked(expiresAt: Date)
}

nonisolated struct CloudServerSessionLease: Equatable, Identifiable, Sendable {
    let id: UUID
    let provider: CloudGamingProvider
    let serverSessionID: String
    let phase: CloudServerSessionPhase
}

/// A unique capability for the one local WebRTC peer. Releasing by provider is
/// intentionally insufficient: an obsolete view must never detach a newer
/// peer owned by another launch of the same provider.
nonisolated struct CloudLocalPeerLease: Equatable, Identifiable, Sendable {
    let id: UUID
    let provider: CloudGamingProvider
    fileprivate let serverSessionLeaseID: UUID?

    init(
        id: UUID = UUID(),
        provider: CloudGamingProvider,
        serverSessionLeaseID: UUID? = nil
    ) {
        self.id = id
        self.provider = provider
        self.serverSessionLeaseID = serverSessionLeaseID
    }
}

/// Provider work attached to a shared session lease. The coordinator owns the
/// cross-provider policy while each adapter remains responsible for invoking
/// its service's real Leave and End operations.
nonisolated struct CloudServerSessionActions: Sendable {
    let leave: (@MainActor @Sendable () async -> Date?)?
    /// Returns true only when the provider confirms the server session is gone.
    let end: @MainActor @Sendable () async -> Bool

    init(
        leave: (@MainActor @Sendable () async -> Date?)? = nil,
        end: @escaping @MainActor @Sendable () async -> Bool
    ) {
        self.leave = leave
        self.end = end
    }
}

nonisolated enum CloudSessionConflict: Error, Equatable, Sendable {
    case serverSessionAlreadyReserved(CloudServerSessionLease)
    case serverSessionUnavailableForAdoption
    case serverSessionLeaseNotOwned
    case localPeerAlreadyAttached(CloudLocalPeerLease)
}

nonisolated enum CloudProviderSwitchRequirement: Equatable, Sendable {
    case allowed
    case leaveOrEnd(CloudServerSessionLease)
    case endParkedSession(CloudServerSessionLease)
}

/// Provider-neutral enforcement for the one-server-session/one-peer invariant.
/// It owns policy only; provider adapters still perform the actual Leave/End.
@Observable
@MainActor
final class CloudSessionCoordinator {
    private struct EndOperation {
        let id: UUID
        let leaseID: UUID
        let task: Task<Bool, Never>
    }

    private(set) var serverSession: CloudServerSessionLease?
    private(set) var localPeerLease: CloudLocalPeerLease?
    var localPeerProvider: CloudGamingProvider? {
        localPeerLease?.provider
    }

    @ObservationIgnored private var serverSessionActions: CloudServerSessionActions?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var endOperation: EndOperation?
    @ObservationIgnored private var expiryQuarantineLeaseID: UUID?

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
        sleep = { delay in
            try await Task.sleep(for: .seconds(delay))
        }
    }

    init(
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    isolated deinit {
        expiryTask?.cancel()
    }

    func reserveServerSession(
        provider: CloudGamingProvider,
        serverSessionID: String,
        actions: CloudServerSessionActions? = nil,
        id: UUID = UUID()
    ) throws -> CloudServerSessionLease {
        let currentTime = now()
        if let expiredLease = expiredParkedSession(at: currentTime) {
            requestEndForExpiredParkedSession(expiredLease)
            throw CloudSessionConflict.serverSessionAlreadyReserved(
                expiredLease
            )
        }
        if let serverSession {
            throw CloudSessionConflict.serverSessionAlreadyReserved(
                serverSession
            )
        }
        let lease = CloudServerSessionLease(
            id: id,
            provider: provider,
            serverSessionID: serverSessionID,
            phase: .active
        )
        serverSession = lease
        if let actions {
            serverSessionActions = actions
        }
        return lease
    }

    /// Reclaims a specifically identified parked allocation. This is separate
    /// from reservation so concurrent launches can never mistake equality for
    /// ownership.
    func adoptParkedServerSession(
        provider: CloudGamingProvider,
        serverSessionID: String,
        actions: CloudServerSessionActions? = nil
    ) throws -> CloudServerSessionLease {
        let currentTime = now()
        if let expiredLease = expiredParkedSession(at: currentTime) {
            requestEndForExpiredParkedSession(expiredLease)
            throw CloudSessionConflict.serverSessionAlreadyReserved(
                expiredLease
            )
        }
        guard let current = serverSession,
              current.provider == provider,
              current.serverSessionID == serverSessionID,
              case .parked = current.phase,
              endOperation?.leaseID != current.id,
              expiryQuarantineLeaseID != current.id
        else {
            throw CloudSessionConflict.serverSessionUnavailableForAdoption
        }

        expiryTask?.cancel()
        expiryTask = nil
        let adopted = CloudServerSessionLease(
            id: current.id,
            provider: current.provider,
            serverSessionID: current.serverSessionID,
            phase: .active
        )
        serverSession = adopted
        if let actions {
            serverSessionActions = actions
        }
        return adopted
    }

    /// Replaces a provisional reservation identity with the opaque identity
    /// created by the service, while retaining the same ownership capability.
    func bindServerSession(
        _ lease: CloudServerSessionLease,
        to serverSessionID: String
    ) throws -> CloudServerSessionLease {
        guard !serverSessionID.isEmpty,
              let current = serverSession,
              current.id == lease.id,
              current.provider == lease.provider,
              current.phase == lease.phase,
              endOperation?.leaseID != lease.id
        else {
            throw CloudSessionConflict.serverSessionLeaseNotOwned
        }
        let bound = CloudServerSessionLease(
            id: current.id,
            provider: current.provider,
            serverSessionID: serverSessionID,
            phase: current.phase
        )
        serverSession = bound
        return bound
    }

    func attachLocalPeer(
        for provider: CloudGamingProvider,
        id: UUID = UUID()
    ) throws -> CloudLocalPeerLease {
        if let localPeerLease {
            throw CloudSessionConflict.localPeerAlreadyAttached(
                localPeerLease
            )
        }
        if let serverSession,
           endOperation?.leaseID == serverSession.id
        {
            throw CloudSessionConflict.serverSessionLeaseNotOwned
        }
        if let serverSession, serverSession.provider != provider {
            throw CloudSessionConflict.serverSessionAlreadyReserved(
                serverSession
            )
        }
        let lease = CloudLocalPeerLease(
            id: id,
            provider: provider,
            serverSessionLeaseID: serverSession?.provider == provider
                ? serverSession?.id
                : nil
        )
        localPeerLease = lease
        return lease
    }

    func releaseLocalPeer(_ lease: CloudLocalPeerLease) {
        guard localPeerLease?.id == lease.id else { return }
        localPeerLease = nil
    }

    func parkServerSession(
        _ lease: CloudServerSessionLease,
        expiresAt: Date
    ) {
        guard let current = serverSession,
              current.id == lease.id,
              endOperation?.leaseID != lease.id
        else {
            return
        }
        expiryQuarantineLeaseID = nil
        serverSession = CloudServerSessionLease(
            id: current.id,
            provider: current.provider,
            serverSessionID: current.serverSessionID,
            phase: .parked(expiresAt: expiresAt)
        )
        releaseLocalPeerOwned(by: current)
        scheduleExpiry(for: lease.id, at: expiresAt)
    }

    func endServerSession(_ lease: CloudServerSessionLease) {
        guard serverSession?.id == lease.id else { return }
        serverSession = nil
        serverSessionActions = nil
        endOperation = nil
        expiryQuarantineLeaseID = nil
        expiryTask?.cancel()
        expiryTask = nil
        releaseLocalPeerOwned(by: lease)
    }

    /// Performs the provider's real Leave before changing shared policy state.
    /// A lease without a Leave adapter fails closed and remains active.
    @discardableResult
    func leaveServerSession(
        _ lease: CloudServerSessionLease
    ) async -> Bool {
        guard serverSession?.id == lease.id,
              let leave = serverSessionActions?.leave
        else {
            return false
        }
        guard let expiresAt = await leave(),
              expiresAt > now(),
              serverSession?.id == lease.id
        else {
            return false
        }
        parkServerSession(lease, expiresAt: expiresAt)
        return serverSession?.id == lease.id
            && serverSession?.phase == .parked(expiresAt: expiresAt)
    }

    /// Performs the provider's real End before releasing the global lease.
    /// This prevents a provider switch from merely forgetting a parked server
    /// session while it is still consuming service capacity.
    @discardableResult
    func endServerSessionUsingProvider(_ lease: CloudServerSessionLease) async -> Bool {
        guard let operation = beginEndOperation(for: lease) else { return false }
        return await finishEndOperation(operation, lease: lease)
    }

    /// Requests confirmed provider teardown for an observed expired lease.
    /// The lease remains authoritative until that asynchronous End succeeds.
    func removeExpiredParkedSession(now currentTime: Date? = nil) {
        guard let lease = expiredParkedSession(at: currentTime ?? now()) else {
            return
        }
        requestEndForExpiredParkedSession(lease)
    }

    func switchRequirement(
        to provider: CloudGamingProvider
    ) -> CloudProviderSwitchRequirement {
        removeExpiredParkedSession(now: now())
        guard let serverSession, serverSession.provider != provider else {
            return .allowed
        }
        switch serverSession.phase {
        case .active:
            return .leaveOrEnd(serverSession)
        case .parked:
            return .endParkedSession(serverSession)
        }
    }

    func canLeaveServerSession(_ lease: CloudServerSessionLease) -> Bool {
        removeExpiredParkedSession(now: now())
        return serverSession?.id == lease.id
            && endOperation?.leaseID != lease.id
            && serverSessionActions?.leave != nil
    }

    private func scheduleExpiry(for leaseID: UUID, at expiresAt: Date) {
        expiryTask?.cancel()
        guard expiresAt > now() else {
            removeExpiredParkedSession(now: now())
            return
        }
        expiryTask = Task { [weak self] in
            guard let self else { return }
            await expireParkedSession(leaseID: leaseID, expiresAt: expiresAt)
        }
    }

    private func expireParkedSession(leaseID: UUID, expiresAt: Date) async {
        while true {
            guard let serverSession,
                  serverSession.id == leaseID,
                  case let .parked(currentExpiry) = serverSession.phase,
                  currentExpiry == expiresAt
            else {
                return
            }

            let delay = expiresAt.timeIntervalSince(now())
            guard delay > 0 else {
                guard expiryQuarantineLeaseID != leaseID else { return }
                _ = await endServerSessionUsingProvider(serverSession)
                return
            }

            do {
                try await sleep(delay)
            } catch {
                return
            }
        }
    }

    private func expiredParkedSession(
        at currentTime: Date
    ) -> CloudServerSessionLease? {
        guard let serverSession,
              case let .parked(expiresAt) = serverSession.phase,
              expiresAt <= currentTime
        else {
            return nil
        }
        return serverSession
    }

    private func requestEndForExpiredParkedSession(
        _ lease: CloudServerSessionLease
    ) {
        guard expiryQuarantineLeaseID != lease.id,
              endOperation?.leaseID != lease.id,
              let operation = beginEndOperation(for: lease)
        else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            _ = await finishEndOperation(operation, lease: lease)
        }
    }

    private func beginEndOperation(
        for lease: CloudServerSessionLease
    ) -> EndOperation? {
        guard serverSession?.id == lease.id else { return nil }
        if let current = endOperation, current.leaseID == lease.id {
            return current
        }
        guard let end = serverSessionActions?.end else { return nil }
        // Once deletion starts, an approximate parked expiry must not release
        // the lease if the provider later fails to confirm server teardown.
        expiryQuarantineLeaseID = lease.id
        expiryTask?.cancel()
        expiryTask = nil
        let task = Task {
            await end()
        }
        let operation = EndOperation(
            id: UUID(),
            leaseID: lease.id,
            task: task
        )
        endOperation = operation
        return operation
    }

    private func finishEndOperation(
        _ operation: EndOperation,
        lease: CloudServerSessionLease
    ) async -> Bool {
        let didEnd = await operation.task.value
        if endOperation?.id == operation.id {
            endOperation = nil
        }
        guard didEnd else { return false }
        guard serverSession?.id == lease.id else { return true }
        endServerSession(lease)
        return true
    }

    private func releaseLocalPeerOwned(
        by serverLease: CloudServerSessionLease
    ) {
        guard let localPeerLease,
              localPeerLease.serverSessionLeaseID == serverLease.id
        else {
            return
        }
        releaseLocalPeer(localPeerLease)
    }
}
