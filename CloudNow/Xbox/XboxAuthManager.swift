import Foundation
import Observation

/// Persisted generic Microsoft OAuth state. This does not prove Xbox Cloud
/// identity, entitlement, or streaming authorization.
nonisolated struct XboxAuthSession: Codable, Equatable, Sendable {
    let tenant: String
    let clientID: String
    let scopes: [String]
    var token: MicrosoftOAuthToken
    var activityScopeIdentifier: String?

    init(
        configuration: MicrosoftDeviceCodeOAuthConfiguration,
        token: MicrosoftOAuthToken,
        activityScopeIdentifier: String? = nil
    ) {
        tenant = configuration.tenant
        clientID = configuration.clientID
        scopes = configuration.scopes
        self.token = token
        self.activityScopeIdentifier = activityScopeIdentifier
    }

    func matches(_ configuration: MicrosoftDeviceCodeOAuthConfiguration) -> Bool {
        tenant == configuration.tenant
            && clientID == configuration.clientID
            && Set(scopes) == Set(configuration.scopes)
    }
}

nonisolated enum XboxAuthStartupPhase: Equatable, Sendable {
    case pending
    case restoringSession
    case ready
}

nonisolated enum XboxAuthError: Error, Equatable, LocalizedError, Sendable {
    case notConfigured
    case noSession
    case sessionExpired
    case persistenceUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Microsoft sign-in is not configured for Xbox Cloud Gaming."
        case .noSession:
            "No Microsoft account is signed in."
        case .sessionExpired:
            "The Microsoft sign-in expired. Please sign in again."
        case .persistenceUnavailable:
            "Secure Xbox account storage is unavailable."
        }
    }
}

nonisolated enum XboxSignInFailure: Error, Equatable, LocalizedError, Sendable {
    case notConfigured
    case microsoft(MicrosoftDeviceCodeOAuthError)
    case xboxCloudAuthorizationUnavailable
    case xboxCloudAuthorizationFailed
    case secureStorageUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Microsoft sign-in is not configured for Xbox Cloud Gaming."
        case let .microsoft(error):
            error.localizedDescription
        case .xboxCloudAuthorizationUnavailable:
            "Microsoft sign-in completed, but Xbox Cloud authorization is not available yet."
        case .xboxCloudAuthorizationFailed:
            "Microsoft could not verify Xbox Cloud Gaming access for this account."
        case .secureStorageUnavailable:
            "CloudNow could not securely store the Microsoft account."
        }
    }
}

nonisolated enum XboxSignInState: Equatable, Sendable {
    case idle
    case requestingCode
    case awaitingUser(MicrosoftDeviceAuthorization)
    case polling(attempt: Int)
    case validatingXboxCloudAccess
    case authorized
    case declined
    case expired
    case cancelled
    case failed(XboxSignInFailure)
}

nonisolated protocol XboxOAuthClient: Sendable {
    func authenticate(
        configuration: MicrosoftDeviceCodeOAuthConfiguration,
        onState: @escaping @Sendable (MicrosoftDeviceCodeState) async -> Void
    ) async throws -> MicrosoftOAuthToken
    func refreshToken(
        configuration: MicrosoftDeviceCodeOAuthConfiguration,
        refreshToken: String
    ) async throws -> MicrosoftOAuthToken
}

extension MicrosoftDeviceCodeOAuthClient: XboxOAuthClient {}

nonisolated protocol XboxAuthSessionPersistence: Sendable {
    func loadXboxAuthSession() async throws -> XboxAuthSession?
    func saveXboxAuthSession(
        _ session: XboxAuthSession,
        generation: UInt64
    ) async throws
    func deleteXboxAuthSession(generation: UInt64) async throws
}

extension AppPersistenceStore: XboxAuthSessionPersistence {}

nonisolated struct UnavailableXboxAuthSessionPersistence: XboxAuthSessionPersistence {
    func loadXboxAuthSession() async throws -> XboxAuthSession? {
        nil
    }

    func saveXboxAuthSession(
        _: XboxAuthSession,
        generation _: UInt64
    ) async throws {
        throw XboxAuthError.persistenceUnavailable
    }

    func deleteXboxAuthSession(generation _: UInt64) async throws {}
}

@Observable
@MainActor
final class XboxAuthManager {
    private struct ActiveLogin {
        let generation: UInt64
        let priorSession: XboxAuthSession?
        let priorAuthorizedAccount: XboxCloudAuthorizedAccount?
    }

    private(set) var session: XboxAuthSession?
    private(set) var authorizedAccount: XboxCloudAuthorizedAccount?
    private(set) var authorization: MicrosoftDeviceAuthorization?
    private(set) var signInState: XboxSignInState = .idle
    private(set) var startupPhase: XboxAuthStartupPhase

    var isMicrosoftSignedIn: Bool {
        session != nil
    }

    var isXboxCloudAuthorized: Bool {
        guard let authorizedAccount else { return false }
        return authorizedAccount.isUsable(at: now())
    }

    var canRequestMicrosoftDeviceCode: Bool {
        configuration != nil
    }

    var canAuthorizeXboxCloud: Bool {
        accountAuthorizationClientFactory != nil
    }

    var isConfigured: Bool {
        canRequestMicrosoftDeviceCode
    }

    @ObservationIgnored private let configuration: MicrosoftDeviceCodeOAuthConfiguration?
    @ObservationIgnored private var oauthClient: (any XboxOAuthClient)?
    @ObservationIgnored private let retainsInjectedOAuthClient: Bool
    @ObservationIgnored private let accountAuthorizationClientFactory: (@Sendable () -> any XboxCloudAccountAuthorizationClient)?
    @ObservationIgnored private let credentialLifecycle: (any XboxLocalCredentialLifecycle)?
    @ObservationIgnored private var accountAuthorizationClient: (any XboxCloudAccountAuthorizationClient)?
    @ObservationIgnored private let persistence: any XboxAuthSessionPersistence
    @ObservationIgnored private let catalogCache: any XboxCatalogCaching
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private var credentialGeneration: UInt64 = 0
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var activeLogin: ActiveLogin?
    @ObservationIgnored private var activeRefreshTask: Task<XboxAuthSession, Error>?
    @ObservationIgnored private var refreshTaskGeneration: UInt64 = 0
    @ObservationIgnored private var activeTransferTokenTask: Task<MicrosoftOAuthToken, Error>?
    @ObservationIgnored private var transferTokenTaskGeneration: UInt64 = 0
    @ObservationIgnored private var activeXboxAuthorizationTask: Task<XboxCloudAuthorizedAccount, Error>?
    @ObservationIgnored private var activeXboxAuthorizationCredentialGeneration: UInt64?
    @ObservationIgnored private var xboxAuthorizationTaskGeneration: UInt64 = 0
    @ObservationIgnored private var authorizedAccountRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var authorizedAccountRefreshGeneration: UInt64 = 0
    @ObservationIgnored private var catalogAccountScopeIdentifier: String?
    @ObservationIgnored private var isDeletingCredentials = false
    @ObservationIgnored private var isDataResetInProgress = false

    private var isCredentialMutationInProgress: Bool {
        isDeletingCredentials || isDataResetInProgress
    }

    init(
        environment: XboxCloudEnvironment = .unconfigured,
        oauthClient: (any XboxOAuthClient)? = nil,
        persistence: any XboxAuthSessionPersistence = UnavailableXboxAuthSessionPersistence(),
        catalogCache: any XboxCatalogCaching = XboxCatalogMemoryCache.shared,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            let boundedSeconds = min(
                max(0, seconds),
                24 * 60 * 60
            )
            try await Task.sleep(
                nanoseconds: UInt64(boundedSeconds * 1_000_000_000)
            )
        },
        initialSession: XboxAuthSession? = nil,
        initialAuthorizedAccount: XboxCloudAuthorizedAccount? = nil,
        startsReady: Bool = false
    ) {
        configuration = environment.authentication
        accountAuthorizationClientFactory = environment.makeAccountAuthorizationClient
        credentialLifecycle = environment.credentialLifecycle
        self.oauthClient = oauthClient
        retainsInjectedOAuthClient = oauthClient != nil
        self.persistence = persistence
        self.catalogCache = catalogCache
        self.now = now
        self.sleep = sleep
        session = initialSession
        let restoredAuthorizedAccount = initialSession == nil
            ? nil
            : initialAuthorizedAccount
        authorizedAccount = restoredAuthorizedAccount
        catalogAccountScopeIdentifier = restoredAuthorizedAccount?
            .activityScopeIdentifier
        startupPhase = startsReady || initialSession != nil ? .ready : .pending
        if let restoredAuthorizedAccount {
            scheduleAuthorizedAccountRefresh(for: restoredAuthorizedAccount)
        }
    }

    isolated deinit {
        loginTask?.cancel()
        activeRefreshTask?.cancel()
        activeTransferTokenTask?.cancel()
        activeXboxAuthorizationTask?.cancel()
        authorizedAccountRefreshTask?.cancel()
    }

    func restorePersistedSession() async {
        guard !isCredentialMutationInProgress,
              startupPhase == .pending
        else {
            return
        }
        startupPhase = .restoringSession
        defer { startupPhase = .ready }
        guard let configuration else { return }
        let generation = credentialGeneration
        do {
            guard let restored = try await persistence.loadXboxAuthSession() else {
                return
            }
            guard !isCredentialMutationInProgress,
                  credentialGeneration == generation
            else {
                return
            }
            guard restored.matches(configuration) else {
                try? await persistence.deleteXboxAuthSession(generation: generation)
                return
            }
            session = restored
        } catch {
            guard credentialGeneration == generation else { return }
            try? await persistence.deleteXboxAuthSession(generation: generation)
            return
        }
    }

    func initialize() async {
        await restorePersistedSession()
    }

    @discardableResult
    func login() -> Task<Void, Never> {
        guard !isCredentialMutationInProgress else { return Task {} }
        guard let configuration else {
            publish(.failed(.notConfigured))
            return Task {}
        }
        if activeLogin != nil {
            cancelLogin()
        } else {
            cancelActiveXboxAuthorization()
        }
        cancelAuthorizedAccountRefresh()
        releaseRuntimeClients()
        let oauthClient = resolvedOAuthClient()
        credentialGeneration &+= 1
        let generation = credentialGeneration
        activeLogin = ActiveLogin(
            generation: generation,
            priorSession: session,
            priorAuthorizedAccount: authorizedAccount
        )
        authorizedAccount = nil
        authorization = nil
        publish(.requestingCode)

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if activeLogin?.generation == generation {
                    activeLogin = nil
                    loginTask = nil
                }
            }
            do {
                let token = try await oauthClient.authenticate(
                    configuration: configuration
                ) { [weak self] state in
                    await self?.publishMicrosoftState(
                        state,
                        generation: generation
                    )
                }
                try Task.checkCancellation()
                guard credentialGeneration == generation else {
                    throw CancellationError()
                }
                let newSession = XboxAuthSession(
                    configuration: configuration,
                    token: token
                )
                do {
                    try await persistence.saveXboxAuthSession(
                        newSession,
                        generation: generation
                    )
                } catch {
                    guard credentialGeneration == generation else { return }
                    publish(.failed(.secureStorageUnavailable))
                    return
                }
                try Task.checkCancellation()
                guard credentialGeneration == generation else {
                    throw CancellationError()
                }
                session = newSession
                authorization = nil
                guard let accountAuthorizationClientFactory else {
                    publish(.failed(.xboxCloudAuthorizationUnavailable))
                    return
                }
                publish(.validatingXboxCloudAccess)
                let accountAuthorizationClient = resolvedAccountAuthorizationClient(
                    factory: accountAuthorizationClientFactory
                )
                let authorizedAccount: XboxCloudAuthorizedAccount
                do {
                    authorizedAccount = try await authorizeXboxCloud(
                        microsoftToken: token,
                        client: accountAuthorizationClient,
                        generation: generation
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard credentialGeneration == generation else { return }
                    publish(.failed(.xboxCloudAuthorizationFailed))
                    return
                }
                try Task.checkCancellation()
                guard credentialGeneration == generation else {
                    throw CancellationError()
                }
                guard authorizedAccount.isUsable(at: now()) else {
                    publish(.failed(.xboxCloudAuthorizationFailed))
                    return
                }
                let account = try await accountWithPersistedActivityScope(
                    authorizedAccount,
                    generation: generation
                )
                let replacedCatalogAccount = acceptAuthorizedAccount(account)
                publish(.authorized)
                if let replacedCatalogAccount {
                    await catalogCache.remove(
                        accountAuthorizationIdentifier: replacedCatalogAccount
                    )
                }
            } catch is CancellationError {
                if credentialGeneration == generation {
                    authorization = nil
                    publish(.cancelled)
                }
            } catch let error as MicrosoftDeviceCodeOAuthError {
                if credentialGeneration == generation {
                    publish(.failed(.microsoft(error)))
                }
            } catch {
                if credentialGeneration == generation {
                    publish(.failed(.microsoft(.transportFailure)))
                }
            }
        }
        loginTask = task
        return task
    }

    func cancelLogin() {
        cancelActiveXboxAuthorization()
        guard let activeLogin else {
            loginTask?.cancel()
            loginTask = nil
            authorization = nil
            publish(.idle)
            return
        }
        credentialGeneration &+= 1
        let rollbackGeneration = credentialGeneration
        loginTask?.cancel()
        loginTask = nil
        self.activeLogin = nil
        session = activeLogin.priorSession
        authorizedAccount = activeLogin.priorAuthorizedAccount
        authorization = nil
        publish(.idle)
        if let authorizedAccount,
           authorizedAccount.isUsable(at: now())
        {
            scheduleAuthorizedAccountRefresh(for: authorizedAccount)
        }

        Task { [persistence] in
            if let priorSession = activeLogin.priorSession {
                try? await persistence.saveXboxAuthSession(
                    priorSession,
                    generation: rollbackGeneration
                )
            } else {
                try? await persistence.deleteXboxAuthSession(
                    generation: rollbackGeneration
                )
            }
        }
    }

    func logout() async throws {
        guard !isCredentialMutationInProgress else { return }
        isDeletingCredentials = true
        defer { isDeletingCredentials = false }
        let accountScopeIdentifier = catalogAccountScopeIdentifier
        invalidateAuthenticationWork()
        let generation = credentialGeneration
        do {
            try await persistence.deleteXboxAuthSession(
                generation: generation
            )
        } catch {
            guard credentialGeneration == generation else { return }
            isDeletingCredentials = false
            if let authorizedAccount,
               authorizedAccount.isUsable(at: now())
            {
                scheduleAuthorizedAccountRefresh(for: authorizedAccount)
            }
            throw XboxAuthError.persistenceUnavailable
        }
        guard credentialGeneration == generation else { return }
        session = nil
        authorizedAccount = nil
        catalogAccountScopeIdentifier = nil
        authorization = nil
        publish(.idle)
        releaseRuntimeClients()
        await credentialLifecycle?.clearLocalCredentials()
        if let accountScopeIdentifier {
            await catalogCache.remove(
                accountAuthorizationIdentifier: accountScopeIdentifier
            )
        }
    }

    /// Removes the current Microsoft credential before starting a fresh device
    /// flow so a rejected or non-entitled account never traps the user.
    @discardableResult
    func signInWithAnotherMicrosoftAccount() async -> Task<Void, Never>? {
        do {
            try await logout()
        } catch {
            publish(.failed(.secureStorageUnavailable))
            return nil
        }
        guard !Task.isCancelled else { return nil }
        return login()
    }

    /// Performs network authorization only when Xbox is the active service.
    /// A restored generic Microsoft token never activates the Xbox shell alone.
    func activateXboxCloudAccess() async {
        guard !isCredentialMutationInProgress,
              var session
        else {
            return
        }
        if let authorizedAccount {
            if authorizedAccount.isUsable(at: now()) {
                scheduleAuthorizedAccountRefresh(for: authorizedAccount)
                return
            }
            let expiredCatalogAccount = catalogAccountScopeIdentifier
                ?? authorizedAccount.activityScopeIdentifier
            cancelAuthorizedAccountRefresh()
            self.authorizedAccount = nil
            catalogAccountScopeIdentifier = nil
            await catalogCache.remove(
                accountAuthorizationIdentifier: expiredCatalogAccount
            )
        }
        guard let accountAuthorizationClientFactory else {
            publish(.failed(.xboxCloudAuthorizationUnavailable))
            return
        }
        let accountAuthorizationClient = resolvedAccountAuthorizationClient(
            factory: accountAuthorizationClientFactory
        )

        let generation = credentialGeneration
        publish(.validatingXboxCloudAccess)
        do {
            if session.token.expiresAt.timeIntervalSince(now()) < 10 * 60 {
                session = try await refresh(session: session)
            }
            let authorizedAccount = try await authorizeXboxCloud(
                microsoftToken: session.token,
                client: accountAuthorizationClient,
                generation: generation
            )
            try Task.checkCancellation()
            guard credentialGeneration == generation else { return }
            guard authorizedAccount.isUsable(at: now()) else {
                publish(.failed(.xboxCloudAuthorizationFailed))
                return
            }
            let account = try await accountWithPersistedActivityScope(
                authorizedAccount,
                generation: generation
            )
            let replacedCatalogAccount = acceptAuthorizedAccount(account)
            publish(.authorized)
            if let replacedCatalogAccount {
                await catalogCache.remove(
                    accountAuthorizationIdentifier: replacedCatalogAccount
                )
            }
        } catch is CancellationError {
            return
        } catch let error as MicrosoftDeviceCodeOAuthError {
            guard credentialGeneration == generation else { return }
            if error.invalidatesPersistedCredentials {
                await clearTerminalMicrosoftSession(
                    error: error,
                    generation: generation
                )
            } else {
                publish(.failed(.microsoft(error)))
            }
        } catch {
            guard credentialGeneration == generation else { return }
            publish(.failed(.xboxCloudAuthorizationFailed))
        }
    }

    /// Cancels Xbox-owned network work and releases lazily-created transports
    /// while retaining only the generic persisted Microsoft session.
    func deactivateForInactiveProvider() async {
        if isCredentialMutationInProgress {
            releaseRuntimeClients()
            await credentialLifecycle?.clearLocalCredentials()
            return
        }
        if activeLogin != nil {
            cancelLogin()
        } else {
            invalidateAuthenticationWork()
        }
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        cancelActiveXboxAuthorization()
        authorizedAccount = nil
        authorization = nil
        publish(.idle)
        releaseRuntimeClients()
        await credentialLifecycle?.clearLocalCredentials()
    }

    /// Stops work before Reset All Data removes both provider credentials.
    func prepareForDataReset() {
        isDataResetInProgress = true
        invalidateAuthenticationWork()
    }

    func finishDataReset() async {
        invalidateAuthenticationWork()
        session = nil
        authorizedAccount = nil
        catalogAccountScopeIdentifier = nil
        authorization = nil
        publish(.idle)
        releaseRuntimeClients()
        await credentialLifecycle?.clearLocalCredentials()
        isDataResetInProgress = false
    }

    func resumeAfterDataResetFailure() async {
        abortDataResetWithoutActivation()
        if let authorizedAccount,
           authorizedAccount.isUsable(at: now())
        {
            scheduleAuthorizedAccountRefresh(for: authorizedAccount)
            return
        }
        await activateXboxCloudAccess()
    }

    /// Leaves the reset barrier without restoring or authorizing an inactive
    /// provider. A later provider-selection task owns that network work.
    func abortDataResetWithoutActivation() {
        isDataResetInProgress = false
    }

    func refreshIfNeeded() async {
        guard !isCredentialMutationInProgress,
              let session,
              session.token.expiresAt.timeIntervalSince(now()) < 10 * 60
        else {
            return
        }
        let generation = credentialGeneration
        do {
            _ = try await refresh(session: session)
        } catch is CancellationError {
            return
        } catch let error as MicrosoftDeviceCodeOAuthError
            where error.invalidatesPersistedCredentials
        {
            await clearTerminalMicrosoftSession(
                error: error,
                generation: generation
            )
        } catch {
            guard credentialGeneration == generation,
                  session.token.expiresAt <= now()
            else {
                return
            }
            isDeletingCredentials = true
            defer { isDeletingCredentials = false }
            self.session = nil
            let accountScopeIdentifier = catalogAccountScopeIdentifier
            cancelAuthorizedAccountRefresh()
            authorizedAccount = nil
            catalogAccountScopeIdentifier = nil
            releaseRuntimeClients()
            await credentialLifecycle?.clearLocalCredentials()
            try? await persistence.deleteXboxAuthSession(
                generation: generation
            )
            if let accountScopeIdentifier {
                await catalogCache.remove(
                    accountAuthorizationIdentifier: accountScopeIdentifier
                )
            }
        }
    }

    /// Exchanges the persisted Microsoft refresh credential for the narrowly
    /// scoped console-transfer token required by Xbox Cloud session `/connect`.
    /// The resource token remains memory-only; only refresh-token rotation is
    /// committed back to the primary Microsoft session.
    func xboxCloudTransferToken() async throws -> String {
        guard !isCredentialMutationInProgress else {
            throw CancellationError()
        }
        if let activeTransferTokenTask {
            let token = try await activeTransferTokenTask.value
            try Task.checkCancellation()
            return try Self.validatedTransferAccessToken(token.accessToken)
        }
        if let activeRefreshTask {
            _ = try await activeRefreshTask.value
        }
        guard let configuration else {
            throw XboxAuthError.notConfigured
        }
        guard let session,
              let refreshToken = session.token.refreshToken,
              !refreshToken.isEmpty
        else {
            throw XboxAuthError.sessionExpired
        }

        let transferConfiguration = try MicrosoftDeviceCodeOAuthConfiguration(
            tenant: configuration.tenant,
            clientID: configuration.clientID,
            scopes: [Self.xboxCloudTransferTokenScope]
        )
        let oauthClient = resolvedOAuthClient()
        let generation = credentialGeneration
        transferTokenTaskGeneration &+= 1
        let taskGeneration = transferTokenTaskGeneration
        let task = Task<MicrosoftOAuthToken, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            defer {
                if transferTokenTaskGeneration == taskGeneration {
                    activeTransferTokenTask = nil
                }
            }
            let token = try await oauthClient.refreshToken(
                configuration: transferConfiguration,
                refreshToken: refreshToken
            )
            try Task.checkCancellation()
            guard credentialGeneration == generation,
                  let latestSession = self.session
            else {
                throw CancellationError()
            }
            if let rotatedRefreshToken = token.refreshToken,
               rotatedRefreshToken != latestSession.token.refreshToken
            {
                let latestToken = latestSession.token
                let updatedToken = MicrosoftOAuthToken(
                    accessToken: latestToken.accessToken,
                    refreshToken: rotatedRefreshToken,
                    idToken: latestToken.idToken,
                    tokenType: latestToken.tokenType,
                    scopes: latestToken.scopes,
                    expiresAt: latestToken.expiresAt
                )
                let updatedSession = XboxAuthSession(
                    configuration: configuration,
                    token: updatedToken,
                    activityScopeIdentifier: latestSession.activityScopeIdentifier
                )
                do {
                    try await persistence.saveXboxAuthSession(
                        updatedSession,
                        generation: generation
                    )
                } catch {
                    throw XboxAuthError.persistenceUnavailable
                }
                try Task.checkCancellation()
                guard credentialGeneration == generation else {
                    throw CancellationError()
                }
                self.session = updatedSession
            }
            return token
        }
        activeTransferTokenTask = task

        do {
            let token = try await withTaskCancellationHandler {
                let value = try await task.value
                try Task.checkCancellation()
                return value
            } onCancel: {
                task.cancel()
            }
            return try Self.validatedTransferAccessToken(token.accessToken)
        } catch let error as MicrosoftDeviceCodeOAuthError
            where error.invalidatesPersistedCredentials
        {
            await clearTerminalMicrosoftSession(
                error: error,
                generation: generation
            )
            throw error
        }
    }

    private func refresh(
        session: XboxAuthSession
    ) async throws -> XboxAuthSession {
        guard !isCredentialMutationInProgress else {
            throw CancellationError()
        }
        if let activeRefreshTask {
            return try await activeRefreshTask.value
        }
        if let activeTransferTokenTask {
            do {
                _ = try await activeTransferTokenTask.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A resource-specific exchange failure must not prevent the
                // primary OAuth token from refreshing independently.
            }
            guard let latestSession = self.session else {
                throw XboxAuthError.noSession
            }
            return try await refresh(session: latestSession)
        }
        guard let configuration else {
            throw XboxAuthError.notConfigured
        }
        let oauthClient = resolvedOAuthClient()
        guard let refreshToken = session.token.refreshToken else {
            if session.token.expiresAt <= now() {
                throw XboxAuthError.sessionExpired
            }
            return session
        }
        let generation = credentialGeneration
        refreshTaskGeneration &+= 1
        let taskGeneration = refreshTaskGeneration
        let task = Task<XboxAuthSession, Error> { @MainActor [weak self] in
            guard let self else { throw XboxAuthError.noSession }
            defer {
                if refreshTaskGeneration == taskGeneration {
                    activeRefreshTask = nil
                }
            }
            let token = try await oauthClient.refreshToken(
                configuration: configuration,
                refreshToken: refreshToken
            )
            try Task.checkCancellation()
            guard credentialGeneration == generation else {
                throw CancellationError()
            }
            let updated = XboxAuthSession(
                configuration: configuration,
                token: token,
                activityScopeIdentifier: session.activityScopeIdentifier
            )
            try await persistence.saveXboxAuthSession(
                updated,
                generation: generation
            )
            try Task.checkCancellation()
            guard credentialGeneration == generation else {
                throw CancellationError()
            }
            self.session = updated
            let accountScopeIdentifier = catalogAccountScopeIdentifier
            cancelAuthorizedAccountRefresh()
            authorizedAccount = nil
            catalogAccountScopeIdentifier = nil
            if let accountScopeIdentifier {
                await catalogCache.remove(
                    accountAuthorizationIdentifier: accountScopeIdentifier
                )
            }
            return updated
        }
        activeRefreshTask = task
        return try await task.value
    }

    private func invalidateAuthenticationWork() {
        credentialGeneration &+= 1
        activeLogin = nil
        loginTask?.cancel()
        loginTask = nil
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        activeTransferTokenTask?.cancel()
        activeTransferTokenTask = nil
        cancelActiveXboxAuthorization()
        cancelAuthorizedAccountRefresh()
    }

    private func resolvedOAuthClient() -> any XboxOAuthClient {
        if let oauthClient {
            return oauthClient
        }
        let client = MicrosoftDeviceCodeOAuthClient()
        oauthClient = client
        return client
    }

    private static let xboxCloudTransferTokenScope =
        "service::http://Passport.NET/purpose::PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN"

    private static func validatedTransferAccessToken(
        _ value: String
    ) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= 16384,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw MicrosoftDeviceCodeOAuthError.invalidPayload
        }
        return value
    }

    private func releaseRuntimeClients() {
        if !retainsInjectedOAuthClient {
            oauthClient = nil
        }
        accountAuthorizationClient = nil
    }

    private func authorizeXboxCloud(
        microsoftToken: MicrosoftOAuthToken,
        client: any XboxCloudAccountAuthorizationClient,
        generation: UInt64
    ) async throws -> XboxCloudAuthorizedAccount {
        if let activeXboxAuthorizationTask,
           activeXboxAuthorizationCredentialGeneration == generation
        {
            return try await activeXboxAuthorizationTask.value
        }
        cancelActiveXboxAuthorization()
        xboxAuthorizationTaskGeneration &+= 1
        let taskGeneration = xboxAuthorizationTaskGeneration
        let task = Task<XboxCloudAuthorizedAccount, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            defer {
                if xboxAuthorizationTaskGeneration == taskGeneration {
                    activeXboxAuthorizationTask = nil
                    activeXboxAuthorizationCredentialGeneration = nil
                }
            }
            let account = try await client.authorize(
                microsoftToken: microsoftToken
            )
            try Task.checkCancellation()
            guard credentialGeneration == generation else {
                throw CancellationError()
            }
            return account
        }
        activeXboxAuthorizationTask = task
        activeXboxAuthorizationCredentialGeneration = generation
        return try await task.value
    }

    private func cancelActiveXboxAuthorization() {
        activeXboxAuthorizationTask?.cancel()
        activeXboxAuthorizationTask = nil
        activeXboxAuthorizationCredentialGeneration = nil
    }

    private func acceptAuthorizedAccount(
        _ account: XboxCloudAuthorizedAccount
    ) -> String? {
        let replacedCatalogAccount = catalogAccountScopeIdentifier
        authorizedAccount = account
        catalogAccountScopeIdentifier = account.activityScopeIdentifier
        scheduleAuthorizedAccountRefresh(for: account)
        guard replacedCatalogAccount != account.activityScopeIdentifier else {
            return nil
        }
        return replacedCatalogAccount
    }

    private func accountWithPersistedActivityScope(
        _ account: XboxCloudAuthorizedAccount,
        generation: UInt64
    ) async throws -> XboxCloudAuthorizedAccount {
        guard var session else {
            throw XboxAuthError.noSession
        }
        let activityScopeIdentifier = Self.validActivityScopeIdentifier(
            session.activityScopeIdentifier
        ) ?? account.activityScopeIdentifier
        let scopedAccount = XboxCloudAuthorizedAccount(
            authorizationIdentifier: account.authorizationIdentifier,
            activityScopeIdentifier: activityScopeIdentifier,
            displayName: account.displayName,
            expiresAt: account.expiresAt
        )
        guard session.activityScopeIdentifier != activityScopeIdentifier else {
            return scopedAccount
        }

        session.activityScopeIdentifier = activityScopeIdentifier
        do {
            try await persistence.saveXboxAuthSession(
                session,
                generation: generation
            )
        } catch {
            // The already-authorized runtime remains usable if an injected or
            // temporarily unavailable credential store cannot commit this
            // continuity hint. The next successful authorization can retry.
        }
        try Task.checkCancellation()
        guard credentialGeneration == generation else {
            throw CancellationError()
        }
        self.session = session
        return scopedAccount
    }

    private static func validActivityScopeIdentifier(
        _ value: String?
    ) -> String? {
        guard let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value.utf8.count <= 1024
        else {
            return nil
        }
        return value
    }

    private func scheduleAuthorizedAccountRefresh(
        for account: XboxCloudAuthorizedAccount
    ) {
        cancelAuthorizedAccountRefresh()
        guard !isCredentialMutationInProgress else { return }
        let delay = max(0, account.expiresAt.timeIntervalSince(now()))
        let accountIdentifier = account.authorizationIdentifier
        let accountScopeIdentifier = account.activityScopeIdentifier
        let sleep = sleep
        authorizedAccountRefreshGeneration &+= 1
        let generation = authorizedAccountRefreshGeneration
        authorizedAccountRefreshTask = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  !isCredentialMutationInProgress,
                  authorizedAccountRefreshGeneration == generation,
                  authorizedAccount?.authorizationIdentifier == accountIdentifier
            else {
                return
            }
            authorizedAccountRefreshTask = nil
            if account.isUsable(at: now()) {
                scheduleAuthorizedAccountRefresh(for: account)
                return
            }
            authorizedAccount = nil
            catalogAccountScopeIdentifier = nil
            await catalogCache.remove(
                accountAuthorizationIdentifier: accountScopeIdentifier
            )
            await activateXboxCloudAccess()
        }
    }

    private func cancelAuthorizedAccountRefresh() {
        authorizedAccountRefreshGeneration &+= 1
        authorizedAccountRefreshTask?.cancel()
        authorizedAccountRefreshTask = nil
    }

    private func clearTerminalMicrosoftSession(
        error: MicrosoftDeviceCodeOAuthError,
        generation: UInt64
    ) async {
        guard credentialGeneration == generation else { return }
        isDeletingCredentials = true
        defer { isDeletingCredentials = false }
        let accountScopeIdentifier = catalogAccountScopeIdentifier
        credentialGeneration &+= 1
        let deletionGeneration = credentialGeneration
        cancelAuthorizedAccountRefresh()
        session = nil
        authorizedAccount = nil
        catalogAccountScopeIdentifier = nil
        authorization = nil
        releaseRuntimeClients()
        await credentialLifecycle?.clearLocalCredentials()
        if let accountScopeIdentifier {
            await catalogCache.remove(
                accountAuthorizationIdentifier: accountScopeIdentifier
            )
        }
        do {
            try await persistence.deleteXboxAuthSession(
                generation: deletionGeneration
            )
        } catch {
            guard credentialGeneration == deletionGeneration else { return }
            publish(.failed(.secureStorageUnavailable))
            return
        }
        guard credentialGeneration == deletionGeneration else { return }
        publish(.failed(.microsoft(error)))
    }

    private func resolvedAccountAuthorizationClient(
        factory: @Sendable () -> any XboxCloudAccountAuthorizationClient
    ) -> any XboxCloudAccountAuthorizationClient {
        if let accountAuthorizationClient {
            return accountAuthorizationClient
        }
        let client = factory()
        accountAuthorizationClient = client
        return client
    }

    private func publishMicrosoftState(
        _ state: MicrosoftDeviceCodeState,
        generation: UInt64
    ) {
        guard credentialGeneration == generation else { return }
        switch state {
        case .idle:
            publish(.idle)
        case .requestingCode:
            publish(.requestingCode)
        case let .awaitingUser(authorization):
            publish(.awaitingUser(authorization))
        case let .polling(attempt):
            publish(.polling(attempt: attempt))
        case .authorized:
            publish(.validatingXboxCloudAccess)
        case .declined:
            publish(.declined)
        case .expired:
            publish(.expired)
        case .cancelled:
            publish(.cancelled)
        case let .failed(error):
            publish(.failed(.microsoft(error)))
        }
    }

    private func publish(_ state: XboxSignInState) {
        if case let .awaitingUser(authorization) = state {
            self.authorization = authorization
        } else if case .polling = state {
            // Keep the QR code and PIN visible while polling.
        } else {
            authorization = nil
        }
        guard signInState != state else { return }
        signInState = state
    }
}
