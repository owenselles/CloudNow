@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox authentication state")
struct XboxAuthManagerTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @MainActor
    @Test("Unconfigured builds fail closed without touching OAuth or persistence")
    func unconfiguredBuildFailsClosed() async {
        let oauth = XboxOAuthClientStub(token: makeToken())
        let persistence = XboxAuthPersistenceStub()
        let manager = XboxAuthManager(
            oauthClient: oauth,
            persistence: persistence,
            now: { fixedDate }
        )

        await manager.initialize()
        await manager.login().value

        #expect(manager.startupPhase == .ready)
        #expect(!manager.isConfigured)
        #expect(!manager.isMicrosoftSignedIn)
        #expect(!manager.isXboxCloudAuthorized)
        #expect(await oauth.authenticationCount == 0)
        #expect(await persistence.loadCount == 0)
        guard case .failed = manager.signInState else {
            Issue.record("Expected a fail-closed configuration error")
            return
        }
    }

    @MainActor
    @Test("Microsoft device-code sign-in stays independent from Xbox authorization")
    func deviceCodeSignInDoesNotClaimXboxAuthorization() async throws {
        let oauth = XboxOAuthClientStub(
            token: makeToken(),
            blocksAuthentication: true
        )
        let persistence = XboxAuthPersistenceStub()
        let manager = try XboxAuthManager(
            environment: XboxCloudEnvironment(
                authentication: makeConfiguration(),
                makeAccountAuthorizationClient: nil,
                service: nil
            ),
            oauthClient: oauth,
            persistence: persistence,
            now: { fixedDate }
        )
        await manager.restorePersistedSession()

        let login = manager.login()
        await oauth.waitForBlockedAuthentication()

        #expect(manager.canRequestMicrosoftDeviceCode)
        #expect(!manager.canAuthorizeXboxCloud)
        #expect(manager.authorization?.userCode == "ABCD-EFGH")
        #expect(manager.signInState == .polling(attempt: 1))
        #expect(!manager.isMicrosoftSignedIn)
        #expect(!manager.isXboxCloudAuthorized)

        await oauth.releaseAuthentication()
        await login.value

        #expect(manager.isMicrosoftSignedIn)
        #expect(!manager.isXboxCloudAuthorized)
        #expect(
            manager.signInState
                == .failed(.xboxCloudAuthorizationUnavailable)
        )
        #expect(await persistence.savedSession != nil)
    }

    @MainActor
    @Test("An initial Xbox authorization requires its Microsoft session")
    func initialAuthorizationRequiresMicrosoftSession() throws {
        let environment = try makeEnvironment()
        let account = makeAccount()
        let withoutSession = XboxAuthManager(
            environment: environment,
            now: { fixedDate },
            initialAuthorizedAccount: account,
            startsReady: true
        )
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken()
        )
        let withSession = XboxAuthManager(
            environment: environment,
            now: { fixedDate },
            initialSession: session,
            initialAuthorizedAccount: account
        )

        #expect(withoutSession.authorizedAccount == nil)
        #expect(!withoutSession.isXboxCloudAuthorized)
        #expect(withSession.session == session)
        #expect(withSession.authorizedAccount == account)
        #expect(withSession.isXboxCloudAuthorized)
    }

    @MainActor
    @Test("A distant-future authorization schedules without overflowing")
    func distantFutureAuthorizationDoesNotOverflow() async throws {
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken()
        )
        let account = XboxCloudAuthorizedAccount(
            authorizationIdentifier: "long-lived-account",
            displayName: "Fixture Player",
            expiresAt: .distantFuture
        )
        let manager = try XboxAuthManager(
            environment: makeEnvironment(),
            now: { fixedDate },
            initialSession: session,
            initialAuthorizedAccount: account
        )

        await Task.yield()

        #expect(manager.authorizedAccount == account)
        #expect(manager.isXboxCloudAuthorized)
    }

    @MainActor
    @Test("An early bounded wake does not reauthorize a valid account")
    func boundedWakeRechecksAccountExpiry() async throws {
        let clock = XboxAuthDateProbe(fixedDate)
        let sleeper = XboxAuthSleepProbe()
        let authorization = XboxAccountAuthorizationStub(
            account: makeAccount(authorizationIdentifier: "unused-account")
        )
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken()
        )
        let account = XboxCloudAuthorizedAccount(
            authorizationIdentifier: "two-day-account",
            displayName: "Fixture Player",
            expiresAt: fixedDate.addingTimeInterval(2 * 24 * 60 * 60)
        )
        let manager = try XboxAuthManager(
            environment: makeEnvironment(
                accountAuthorizationClient: authorization
            ),
            now: { clock.value },
            sleep: { delay in try await sleeper.sleep(delay) },
            initialSession: session,
            initialAuthorizedAccount: account
        )

        await sleeper.waitForRequestCount(1)
        clock.value = fixedDate.addingTimeInterval(24 * 60 * 60)
        await sleeper.resumeFirstRequest()
        await sleeper.waitForRequestCount(2)

        #expect(manager.authorizedAccount == account)
        #expect(await authorization.authorizationCount == 0)
        #expect(await sleeper.delays == [2 * 24 * 60 * 60, 24 * 60 * 60])
    }

    @MainActor
    @Test("A matching saved account restores without network refresh")
    func restoresMatchingSession() async throws {
        let environment = try makeEnvironment()
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken(expiresAt: fixedDate.addingTimeInterval(3600))
        )
        let persistence = XboxAuthPersistenceStub(session: session)
        let oauth = XboxOAuthClientStub(token: makeToken())
        let manager = XboxAuthManager(
            environment: environment,
            oauthClient: oauth,
            persistence: persistence,
            now: { fixedDate }
        )

        await manager.initialize()

        #expect(manager.startupPhase == .ready)
        #expect(manager.session == session)
        #expect(manager.isMicrosoftSignedIn)
        #expect(!manager.isXboxCloudAuthorized)
        #expect(await oauth.refreshCount == 0)
    }

    @MainActor
    @Test("A usable Xbox authorization does not construct another client")
    func usableAuthorizationSkipsClientCreation() async throws {
        let account = makeAccount()
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken()
        )
        let factory = XboxAccountAuthorizationFactoryProbe(
            clients: [XboxAccountAuthorizationStub(account: account)]
        )
        let manager = try XboxAuthManager(
            environment: makeEnvironment(
                makeAccountAuthorizationClient: { factory.makeClient() }
            ),
            now: { fixedDate },
            initialSession: session,
            initialAuthorizedAccount: account
        )

        await manager.activateXboxCloudAccess()

        #expect(factory.creationCount == 0)
        #expect(manager.authorizedAccount == account)
    }

    @MainActor
    @Test("Xbox authorization expiry reauthorizes while the provider remains active")
    func accountExpiryReauthorizesActiveProvider() async throws {
        let clock = XboxAuthDateProbe(fixedDate)
        let sleeper = XboxAuthSleepProbe()
        let expiringAccount = XboxCloudAuthorizedAccount(
            authorizationIdentifier: "expiring-account",
            displayName: "Fixture Player",
            expiresAt: fixedDate.addingTimeInterval(10)
        )
        let renewedAccount = makeAccount(
            authorizationIdentifier: "renewed-account"
        )
        let authorization = XboxAccountAuthorizationStub(
            account: renewedAccount
        )
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken()
        )
        let manager = try XboxAuthManager(
            environment: makeEnvironment(
                accountAuthorizationClient: authorization
            ),
            now: { clock.value },
            sleep: { delay in try await sleeper.sleep(delay) },
            initialSession: session,
            initialAuthorizedAccount: expiringAccount
        )

        await sleeper.waitForRequestCount(1)
        #expect(await sleeper.delays == [10])

        clock.value = expiringAccount.expiresAt
        await sleeper.resumeFirstRequest()
        while await authorization.authorizationCount == 0 {
            await Task.yield()
        }
        for _ in 0 ..< 100 {
            guard manager.authorizedAccount == nil else { break }
            await Task.yield()
        }

        #expect(manager.authorizedAccount == renewedAccount)
        #expect(manager.signInState == .authorized)
        #expect(await authorization.authorizationCount == 1)
    }

    @MainActor
    @Test("Configuration changes reject credentials issued to another client")
    func rejectsMismatchedSession() async throws {
        let oldConfiguration = try MicrosoftDeviceCodeOAuthConfiguration(
            tenant: "consumers",
            clientID: "old-client",
            scopes: ["openid"]
        )
        let session = XboxAuthSession(
            configuration: oldConfiguration,
            token: makeToken()
        )
        let persistence = XboxAuthPersistenceStub(session: session)
        let manager = try XboxAuthManager(
            environment: makeEnvironment(),
            oauthClient: XboxOAuthClientStub(token: makeToken()),
            persistence: persistence,
            now: { fixedDate }
        )

        await manager.initialize()

        #expect(manager.startupPhase == .ready)
        #expect(!manager.isMicrosoftSignedIn)
        #expect(!manager.isXboxCloudAuthorized)
        #expect(await persistence.deleteGenerations == [0])
    }

    @MainActor
    @Test("Polling keeps the device code visible and persists the completed login")
    func loginPreservesAuthorizationWhilePolling() async throws {
        let oauth = XboxOAuthClientStub(
            token: makeToken(),
            blocksAuthentication: true
        )
        let persistence = XboxAuthPersistenceStub()
        let manager = try XboxAuthManager(
            environment: makeEnvironment(),
            oauthClient: oauth,
            persistence: persistence,
            now: { fixedDate }
        )
        await manager.restorePersistedSession()

        let login = manager.login()
        await oauth.waitForBlockedAuthentication()

        #expect(manager.authorization?.userCode == "ABCD-EFGH")
        #expect(manager.signInState == .polling(attempt: 1))

        await oauth.releaseAuthentication()
        await login.value

        #expect(manager.isMicrosoftSignedIn)
        #expect(manager.isXboxCloudAuthorized)
        #expect(manager.authorization == nil)
        #expect(manager.signInState == .authorized)
        #expect(await persistence.savedSession == manager.session)
        #expect(await persistence.saveGenerations == [1])
    }

    @MainActor
    @Test("Cancelling a delayed login cannot restore its credentials")
    func cancellationRejectsLateLogin() async throws {
        let oauth = XboxOAuthClientStub(
            token: makeToken(),
            blocksAuthentication: true
        )
        let persistence = XboxAuthPersistenceStub()
        let manager = try XboxAuthManager(
            environment: makeEnvironment(),
            oauthClient: oauth,
            persistence: persistence,
            now: { fixedDate }
        )
        await manager.restorePersistedSession()
        let login = manager.login()
        await oauth.waitForBlockedAuthentication()

        manager.cancelLogin()
        await oauth.releaseAuthentication()
        await login.value
        await persistence.waitForDeleteCount(1)

        #expect(!manager.isMicrosoftSignedIn)
        #expect(!manager.isXboxCloudAuthorized)
        #expect(manager.authorization == nil)
        #expect(manager.signInState == .idle)
        #expect(await persistence.savedSession == nil)
        #expect(await persistence.deleteGenerations == [2])
    }

    @MainActor
    @Test("An expired restored token refreshes once and persists atomically")
    func refreshesExpiredSession() async throws {
        let configuration = try makeConfiguration()
        let old = XboxAuthSession(
            configuration: configuration,
            token: makeToken(expiresAt: fixedDate.addingTimeInterval(-1))
        )
        let replacement = makeToken(
            accessToken: "replacement-access",
            expiresAt: fixedDate.addingTimeInterval(3600)
        )
        let oauth = XboxOAuthClientStub(token: replacement)
        let persistence = XboxAuthPersistenceStub(session: old)
        let credentialLifecycle = XboxLocalCredentialLifecycleProbe()
        let manager = try XboxAuthManager(
            environment: makeEnvironment(
                makeAccountAuthorizationClient: {
                    XboxAccountAuthorizationStub(account: makeAccount())
                },
                credentialLifecycle: credentialLifecycle
            ),
            oauthClient: oauth,
            persistence: persistence,
            now: { fixedDate }
        )

        await manager.initialize()
        await manager.activateXboxCloudAccess()

        #expect(manager.session?.token.accessToken == "replacement-access")
        #expect(await oauth.refreshCount == 1)
        #expect(await persistence.savedSession?.token.accessToken == "replacement-access")
        #expect(manager.isXboxCloudAuthorized)
        #expect(await credentialLifecycle.clearCount == 0)
    }

    @MainActor
    @Test("Generic Microsoft OAuth alone never unlocks Xbox Cloud Gaming")
    func genericMicrosoftTokenDoesNotAuthorizeXboxCloud() async throws {
        let accountAuthorization = XboxAccountAuthorizationStub(
            account: makeAccount(),
            failsAuthorization: true
        )
        let persistence = XboxAuthPersistenceStub()
        let manager = try XboxAuthManager(
            environment: makeEnvironment(
                accountAuthorizationClient: accountAuthorization
            ),
            oauthClient: XboxOAuthClientStub(token: makeToken()),
            persistence: persistence,
            now: { fixedDate }
        )
        await manager.restorePersistedSession()

        await manager.login().value

        #expect(manager.isMicrosoftSignedIn)
        #expect(!manager.isXboxCloudAuthorized)
        #expect(await persistence.savedSession != nil)
        #expect(await accountAuthorization.authorizationCount == 1)
        #expect(manager.signInState == .failed(.xboxCloudAuthorizationFailed))
    }

    @MainActor
    @Test("A rejected account can be replaced with another Microsoft account")
    func rejectedAccountCanBeReplaced() async throws {
        let rejectedClient = XboxAccountAuthorizationStub(
            account: makeAccount(authorizationIdentifier: "rejected"),
            failsAuthorization: true
        )
        let acceptedAccount = makeAccount(
            authorizationIdentifier: "accepted"
        )
        let acceptedClient = XboxAccountAuthorizationStub(
            account: acceptedAccount
        )
        let factory = XboxAccountAuthorizationFactoryProbe(
            clients: [rejectedClient, acceptedClient]
        )
        let oauth = XboxOAuthClientStub(token: makeToken())
        let persistence = XboxAuthPersistenceStub()
        let manager = try XboxAuthManager(
            environment: makeEnvironment(
                makeAccountAuthorizationClient: { factory.makeClient() }
            ),
            oauthClient: oauth,
            persistence: persistence,
            now: { fixedDate }
        )
        await manager.restorePersistedSession()

        await manager.login().value
        #expect(manager.isMicrosoftSignedIn)
        #expect(!manager.isXboxCloudAuthorized)

        let replacementLogin = await manager.signInWithAnotherMicrosoftAccount()
        await replacementLogin?.value

        #expect(await oauth.authenticationCount == 2)
        #expect(factory.creationCount == 2)
        #expect(manager.authorizedAccount == acceptedAccount)
        #expect(manager.signInState == .authorized)
        #expect(await persistence.saveGenerations == [1, 3])
        #expect(await persistence.deleteGenerations == [2])
    }

    @MainActor
    @Test("A new login cannot reuse authorization work from an older credential")
    func newLoginDoesNotReuseOldAuthorization() async throws {
        let staleClient = ControllableXboxAuthorizationClient()
        let currentClient = ControllableXboxAuthorizationClient()
        let factory = XboxAccountAuthorizationFactoryProbe(
            clients: [staleClient, currentClient]
        )
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken(accessToken: "stale-token")
        )
        let oauth = XboxOAuthClientStub(
            token: makeToken(accessToken: "current-token")
        )
        let persistence = XboxAuthPersistenceStub(session: session)
        let manager = try XboxAuthManager(
            environment: makeEnvironment(
                makeAccountAuthorizationClient: { factory.makeClient() }
            ),
            oauthClient: oauth,
            persistence: persistence,
            now: { fixedDate },
            initialSession: session
        )

        let staleActivation = Task { @MainActor in
            await manager.activateXboxCloudAccess()
        }
        await staleClient.waitForAuthorizationRequest()

        let currentLogin = manager.login()
        await staleClient.resolve(
            with: makeAccount(authorizationIdentifier: "stale-account")
        )
        await staleActivation.value

        await currentClient.waitForAuthorizationRequest()
        #expect(factory.creationCount == 2)
        let currentAccount = makeAccount(
            authorizationIdentifier: "current-account"
        )
        await currentClient.resolve(with: currentAccount)
        await currentLogin.value

        #expect(factory.creationCount == 2)
        #expect(manager.authorizedAccount == currentAccount)
        #expect(manager.signInState == .authorized)
    }

    @MainActor
    @Test("Microsoft invalid_grant removes the unusable saved session")
    func invalidGrantClearsSavedSession() async throws {
        let error = MicrosoftDeviceCodeOAuthError.server(
            statusCode: 400,
            code: "invalid_grant"
        )
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken(
                expiresAt: fixedDate.addingTimeInterval(5 * 60)
            )
        )
        let persistence = XboxAuthPersistenceStub(session: session)
        let credentialLifecycle = XboxLocalCredentialLifecycleProbe()
        let manager = try XboxAuthManager(
            environment: makeEnvironment(
                makeAccountAuthorizationClient: {
                    XboxAccountAuthorizationStub(account: makeAccount())
                },
                credentialLifecycle: credentialLifecycle
            ),
            oauthClient: XboxOAuthClientStub(
                token: makeToken(),
                refreshError: error
            ),
            persistence: persistence,
            now: { fixedDate }
        )

        await manager.initialize()
        await manager.activateXboxCloudAccess()

        #expect(!manager.isMicrosoftSignedIn)
        #expect(!manager.isXboxCloudAuthorized)
        #expect(manager.signInState == .failed(.microsoft(error)))
        #expect(await persistence.savedSession == nil)
        #expect(await persistence.deleteGenerations == [1])
        #expect(await credentialLifecycle.clearCount == 1)
    }

    @MainActor
    @Test("An expired terminal Microsoft session clears derived Xbox credentials")
    func expiredTerminalSessionClearsDerivedCredentials() async throws {
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken(expiresAt: fixedDate.addingTimeInterval(-1))
        )
        let account = makeAccount()
        let persistence = XboxAuthPersistenceStub(session: session)
        let credentialLifecycle = XboxLocalCredentialLifecycleProbe()
        let manager = try XboxAuthManager(
            environment: makeEnvironment(
                makeAccountAuthorizationClient: {
                    XboxAccountAuthorizationStub(account: account)
                },
                credentialLifecycle: credentialLifecycle
            ),
            oauthClient: XboxOAuthClientStub(
                token: makeToken(),
                refreshError: .transportFailure
            ),
            persistence: persistence,
            now: { fixedDate },
            initialSession: session,
            initialAuthorizedAccount: account
        )

        await manager.refreshIfNeeded()

        #expect(!manager.isMicrosoftSignedIn)
        #expect(!manager.isXboxCloudAuthorized)
        #expect(await persistence.savedSession == nil)
        #expect(await credentialLifecycle.clearCount == 1)
    }

    @MainActor
    @Test("Terminal Microsoft revocation evicts the authorized account catalog")
    func invalidGrantEvictsAccountCatalog() async throws {
        let error = MicrosoftDeviceCodeOAuthError.server(
            statusCode: 400,
            code: "invalid_grant"
        )
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken(
                expiresAt: fixedDate.addingTimeInterval(5 * 60)
            )
        )
        let account = makeAccount()
        let cache = XboxCatalogMemoryCache()
        let key = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: account.authorizationIdentifier,
            localeIdentifier: "en-US",
            market: "US"
        )
        await cache.store(
            XboxCatalogSnapshot(items: [], fetchedAt: fixedDate),
            for: key
        )
        let manager = try XboxAuthManager(
            environment: makeEnvironment(),
            oauthClient: XboxOAuthClientStub(
                token: makeToken(),
                refreshError: error
            ),
            persistence: XboxAuthPersistenceStub(session: session),
            catalogCache: cache,
            now: { fixedDate },
            initialSession: session,
            initialAuthorizedAccount: account
        )

        await manager.refreshIfNeeded()

        #expect(!manager.isMicrosoftSignedIn)
        #expect(!manager.isXboxCloudAuthorized)
        #expect(await cache.snapshot(for: key) == nil)
    }

    @MainActor
    @Test("Provider re-entry rejects late authorization and recreates clients lazily")
    func providerReentryRejectsLateAuthorization() async throws {
        let staleAccount = makeAccount(
            authorizationIdentifier: "stale-account"
        )
        let currentAccount = makeAccount(
            authorizationIdentifier: "current-account"
        )
        let reenteredAccount = makeAccount(
            authorizationIdentifier: "reentered-account"
        )
        let firstClient = ControllableXboxAuthorizationClient()
        let secondClient = ControllableXboxAuthorizationClient()
        let thirdClient = ControllableXboxAuthorizationClient()
        let factory = XboxAccountAuthorizationFactoryProbe(
            clients: [firstClient, secondClient, thirdClient]
        )
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken()
        )
        let manager = try XboxAuthManager(
            environment: makeEnvironment(
                makeAccountAuthorizationClient: { factory.makeClient() }
            ),
            oauthClient: XboxOAuthClientStub(token: makeToken()),
            now: { fixedDate },
            initialSession: session
        )

        #expect(factory.creationCount == 0)

        let firstActivation = Task { @MainActor in
            await manager.activateXboxCloudAccess()
        }
        await firstClient.waitForAuthorizationRequest()
        #expect(factory.creationCount == 1)

        await manager.deactivateForInactiveProvider()
        #expect(manager.session == session)
        #expect(manager.authorizedAccount == nil)
        #expect(manager.signInState == .idle)

        let secondActivation = Task { @MainActor in
            await manager.activateXboxCloudAccess()
        }
        await secondClient.waitForAuthorizationRequest()
        #expect(factory.creationCount == 2)

        await secondClient.resolve(with: currentAccount)
        await secondActivation.value
        #expect(manager.authorizedAccount == currentAccount)
        #expect(manager.signInState == .authorized)

        await firstClient.resolve(with: staleAccount)
        await firstActivation.value
        #expect(manager.authorizedAccount == currentAccount)
        #expect(manager.signInState == .authorized)

        await manager.deactivateForInactiveProvider()
        let thirdActivation = Task { @MainActor in
            await manager.activateXboxCloudAccess()
        }
        await thirdClient.waitForAuthorizationRequest()
        #expect(factory.creationCount == 3)

        await thirdClient.resolve(with: reenteredAccount)
        await thirdActivation.value
        #expect(manager.authorizedAccount == reenteredAccount)
        #expect(manager.signInState == .authorized)
    }

    @MainActor
    @Test("Ten provider re-entries retain Microsoft state and recreate one client each")
    func repeatedProviderReentryIsLightweight() async throws {
        let clients = (0 ..< 10).map { _ in
            ControllableXboxAuthorizationClient()
        }
        let factory = XboxAccountAuthorizationFactoryProbe(clients: clients)
        let credentialLifecycle = XboxLocalCredentialLifecycleProbe()
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken()
        )
        let manager = try XboxAuthManager(
            environment: makeEnvironment(
                makeAccountAuthorizationClient: { factory.makeClient() },
                credentialLifecycle: credentialLifecycle
            ),
            oauthClient: XboxOAuthClientStub(token: makeToken()),
            now: { fixedDate },
            initialSession: session
        )

        #expect(factory.creationCount == 0)
        #expect(manager.session == session)
        #expect(manager.authorizedAccount == nil)

        for (index, client) in clients.enumerated() {
            let activation = Task { @MainActor in
                await manager.activateXboxCloudAccess()
            }
            await client.waitForAuthorizationRequest()

            #expect(factory.creationCount == index + 1)
            #expect(manager.session == session)

            let account = makeAccount(
                authorizationIdentifier: "cycle-\(index)-account"
            )
            await client.resolve(with: account)
            await activation.value

            #expect(manager.session == session)
            #expect(manager.authorizedAccount == account)
            #expect(manager.signInState == .authorized)

            await manager.deactivateForInactiveProvider()

            #expect(factory.creationCount == index + 1)
            #expect(manager.session == session)
            #expect(manager.isMicrosoftSignedIn)
            #expect(manager.authorizedAccount == nil)
            #expect(manager.signInState == .idle)
            #expect(await credentialLifecycle.clearCount == index + 1)
        }
    }

    @MainActor
    @Test("A secure-storage failure cannot look like an Xbox logout")
    func logoutFailureKeepsTheMicrosoftAccountVisible() async throws {
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken()
        )
        let persistence = XboxAuthPersistenceStub(
            session: session,
            failsDelete: true
        )
        let manager = try XboxAuthManager(
            environment: makeEnvironment(),
            oauthClient: XboxOAuthClientStub(token: makeToken()),
            persistence: persistence,
            now: { fixedDate }
        )
        await manager.initialize()
        await manager.activateXboxCloudAccess()

        await #expect(throws: XboxAuthError.persistenceUnavailable) {
            try await manager.logout()
        }

        #expect(manager.isMicrosoftSignedIn)
        #expect(manager.isXboxCloudAuthorized)
        #expect(await persistence.savedSession == session)
    }

    @MainActor
    @Test("A cold data-reset rollback blocks producers, then restores normally")
    func coldDataResetRollbackRestoresAuthentication() async throws {
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken(
                accessToken: "stale-access",
                expiresAt: fixedDate.addingTimeInterval(5 * 60)
            )
        )
        let refreshedToken = makeToken(accessToken: "refreshed-access")
        let oauth = XboxOAuthClientStub(token: refreshedToken)
        let account = makeAccount()
        let authorization = XboxAccountAuthorizationStub(account: account)
        let factory = XboxAccountAuthorizationFactoryProbe(
            clients: [authorization]
        )
        let persistence = XboxAuthPersistenceStub(session: session)
        let manager = try XboxAuthManager(
            environment: makeEnvironment(
                makeAccountAuthorizationClient: { factory.makeClient() }
            ),
            oauthClient: oauth,
            persistence: persistence,
            now: { fixedDate }
        )

        manager.prepareForDataReset()
        await manager.login().value
        await manager.activateXboxCloudAccess()
        await manager.refreshIfNeeded()

        #expect(manager.startupPhase == .pending)
        #expect(await persistence.loadCount == 0)
        #expect(await oauth.authenticationCount == 0)
        #expect(await oauth.refreshCount == 0)
        #expect(factory.creationCount == 0)
        #expect(await authorization.authorizationCount == 0)

        manager.abortDataResetWithoutActivation()

        #expect(manager.startupPhase == .pending)
        #expect(await persistence.loadCount == 0)
        #expect(await oauth.authenticationCount == 0)
        #expect(await oauth.refreshCount == 0)
        #expect(factory.creationCount == 0)

        await manager.restorePersistedSession()
        await manager.activateXboxCloudAccess()

        #expect(manager.startupPhase == .ready)
        #expect(manager.session?.token.accessToken == "refreshed-access")
        #expect(manager.authorizedAccount == account)
        #expect(manager.isXboxCloudAuthorized)
        #expect(await persistence.loadCount == 1)
        #expect(await oauth.authenticationCount == 0)
        #expect(await oauth.refreshCount == 1)
        #expect(factory.creationCount == 1)
        #expect(await authorization.authorizationCount == 1)
    }

    @MainActor
    @Test("A failed secure delete restores authorized-account expiry refresh")
    func logoutFailureRestoresExpiryRefresh() async throws {
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken()
        )
        let account = makeAccount()
        let sleeper = XboxAuthSleepProbe()
        let persistence = XboxAuthPersistenceStub(
            session: session,
            failsDelete: true
        )
        let manager = try XboxAuthManager(
            environment: makeEnvironment(),
            oauthClient: XboxOAuthClientStub(token: makeToken()),
            persistence: persistence,
            now: { fixedDate },
            sleep: { delay in try await sleeper.sleep(delay) },
            initialSession: session,
            initialAuthorizedAccount: account
        )
        await sleeper.waitForRequestCount(1)

        await #expect(throws: XboxAuthError.persistenceUnavailable) {
            try await manager.logout()
        }
        await sleeper.waitForRequestCount(2)

        #expect(manager.session == session)
        #expect(manager.authorizedAccount == account)
        #expect(manager.isXboxCloudAuthorized)
        #expect(await sleeper.delays == [3600, 3600])

        await sleeper.resumeFirstRequest()
        await manager.deactivateForInactiveProvider()
    }

    @MainActor
    @Test("A suspended secure delete blocks every authentication producer")
    func blockedLogoutBlocksAuthenticationProducers() async throws {
        let session = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: makeToken(
                expiresAt: fixedDate.addingTimeInterval(5 * 60)
            )
        )
        let oauth = XboxOAuthClientStub(token: makeToken())
        let authorization = XboxAccountAuthorizationStub(
            account: makeAccount()
        )
        let factory = XboxAccountAuthorizationFactoryProbe(
            clients: [authorization]
        )
        let credentialLifecycle = XboxLocalCredentialLifecycleProbe()
        let persistence = XboxAuthPersistenceStub(
            session: session,
            blocksDelete: true
        )
        let manager = try XboxAuthManager(
            environment: makeEnvironment(
                makeAccountAuthorizationClient: { factory.makeClient() },
                credentialLifecycle: credentialLifecycle
            ),
            oauthClient: oauth,
            persistence: persistence,
            now: { fixedDate },
            initialSession: session
        )
        let logout = Task { @MainActor in
            try await manager.logout()
        }
        await persistence.waitForBlockedDelete()

        await manager.login().value
        await manager.activateXboxCloudAccess()
        await manager.refreshIfNeeded()

        #expect(await oauth.authenticationCount == 0)
        #expect(await oauth.refreshCount == 0)
        #expect(factory.creationCount == 0)
        #expect(await authorization.authorizationCount == 0)
        #expect(await credentialLifecycle.clearCount == 0)
        #expect(await persistence.savedSession == session)

        await persistence.releaseDelete()
        try await logout.value

        #expect(manager.session == nil)
        #expect(!manager.isMicrosoftSignedIn)
        #expect(await credentialLifecycle.clearCount == 1)
        #expect(await persistence.savedSession == nil)
    }

    @MainActor
    @Test("Cloud console transfer tokens stay scoped and memory-only")
    func cloudConsoleTransferTokenPreservesPrimarySession() async throws {
        let primaryToken = makeToken(accessToken: "primary-access")
        let initialSession = try XboxAuthSession(
            configuration: makeConfiguration(),
            token: primaryToken
        )
        let transferToken = MicrosoftOAuthToken(
            accessToken: "console-transfer-access",
            refreshToken: "rotated-refresh",
            idToken: nil,
            tokenType: "Bearer",
            scopes: [
                "service::http://Passport.NET/purpose::PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN",
            ],
            expiresAt: fixedDate.addingTimeInterval(300)
        )
        let oauth = XboxOAuthClientStub(
            token: primaryToken,
            resourceToken: transferToken
        )
        let account = makeAccount()
        let persistence = XboxAuthPersistenceStub(session: initialSession)
        let credentialLifecycle = XboxLocalCredentialLifecycleProbe()
        let manager = try XboxAuthManager(
            environment: makeEnvironment(
                makeAccountAuthorizationClient: {
                    XboxAccountAuthorizationStub(account: account)
                },
                credentialLifecycle: credentialLifecycle
            ),
            oauthClient: oauth,
            persistence: persistence,
            now: { fixedDate },
            initialSession: initialSession,
            initialAuthorizedAccount: account
        )

        let value = try await manager.xboxCloudTransferToken()

        #expect(value == "console-transfer-access")
        #expect(await oauth.refreshCount == 1)
        #expect(await oauth.lastRefreshScopes == transferToken.scopes)
        #expect(manager.session?.token.accessToken == "primary-access")
        #expect(manager.session?.token.refreshToken == "rotated-refresh")
        #expect(manager.session?.token.scopes == primaryToken.scopes)
        #expect(manager.authorizedAccount == account)
        #expect(await persistence.savedSession == manager.session)
        #expect(await persistence.savedSession?.token.accessToken != "console-transfer-access")
        #expect(await credentialLifecycle.clearCount == 0)
    }

    private func makeConfiguration() throws -> MicrosoftDeviceCodeOAuthConfiguration {
        try MicrosoftDeviceCodeOAuthConfiguration(
            tenant: "consumers",
            clientID: "fixture-client",
            scopes: ["openid", "offline_access"]
        )
    }

    private func makeEnvironment(
        accountAuthorizationClient: (any XboxCloudAccountAuthorizationClient)? = nil
    ) throws -> XboxCloudEnvironment {
        let authorizationClient = accountAuthorizationClient
            ?? XboxAccountAuthorizationStub(account: makeAccount())
        return try makeEnvironment(
            makeAccountAuthorizationClient: { authorizationClient }
        )
    }

    private func makeEnvironment(
        makeAccountAuthorizationClient: @escaping @Sendable () -> any XboxCloudAccountAuthorizationClient,
        credentialLifecycle: (any XboxLocalCredentialLifecycle)? = nil
    ) throws -> XboxCloudEnvironment {
        try XboxCloudEnvironment(
            authentication: makeConfiguration(),
            makeAccountAuthorizationClient: makeAccountAuthorizationClient,
            credentialLifecycle: credentialLifecycle,
            service: XboxCloudServiceConfiguration(
                makeCatalogClient: { XboxCatalogClientNoop() },
                makeStreamController: { transferToken in
                    XboxCloudStreamController(
                        sessionProvider: XboxCloudGSSessionProviderNoop(),
                        transferToken: transferToken
                    )
                }
            )
        )
    }

    private func makeAccount(
        authorizationIdentifier: String = "fixture-account"
    ) -> XboxCloudAuthorizedAccount {
        XboxCloudAuthorizedAccount(
            authorizationIdentifier: authorizationIdentifier,
            displayName: "Fixture Player",
            expiresAt: fixedDate.addingTimeInterval(3600)
        )
    }

    private func makeToken(
        accessToken: String = "fixture-access",
        expiresAt: Date? = nil
    ) -> MicrosoftOAuthToken {
        MicrosoftOAuthToken(
            accessToken: accessToken,
            refreshToken: "fixture-refresh",
            idToken: nil,
            tokenType: "Bearer",
            scopes: ["openid", "offline_access"],
            expiresAt: expiresAt ?? fixedDate.addingTimeInterval(3600)
        )
    }
}

private actor XboxCloudGSSessionProviderNoop: XboxCloudGSSessionProviding {
    func session(
        for _: XboxCloudAuthorizedAccount
    ) throws -> XboxCloudGSSession {
        throw XboxCloudOfferingServiceError.accountUnavailable
    }

    func removeSession(for _: XboxCloudAuthorizedAccount) {}

    func clearSessions() {}
}

private actor XboxLocalCredentialLifecycleProbe: XboxLocalCredentialLifecycle {
    private(set) var clearCount = 0

    func clearLocalCredentials() {
        clearCount += 1
    }
}

private final class XboxAuthDateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Date

    var value: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }

    init(_ value: Date) {
        storedValue = value
    }
}

private actor XboxAuthSleepProbe {
    private(set) var delays: [TimeInterval] = []
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?
    private var requestWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    func sleep(_ delay: TimeInterval) async throws {
        delays.append(delay)
        resumeRequestWaiters()
        guard delays.count == 1 else {
            throw CancellationError()
        }
        await withCheckedContinuation { continuation in
            firstRequestContinuation = continuation
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard delays.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func resumeFirstRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { delays.count >= $0.count }
        requestWaiters.removeAll { delays.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

private actor XboxOAuthClientStub: XboxOAuthClient {
    private let token: MicrosoftOAuthToken
    private let resourceToken: MicrosoftOAuthToken?
    private let blocksAuthentication: Bool
    private let refreshError: MicrosoftDeviceCodeOAuthError?
    private var isAuthenticationBlocked = false
    private var authenticationContinuation: CheckedContinuation<Void, Never>?
    private(set) var authenticationCount = 0
    private(set) var refreshCount = 0
    private(set) var lastRefreshScopes: [String] = []

    init(
        token: MicrosoftOAuthToken,
        resourceToken: MicrosoftOAuthToken? = nil,
        blocksAuthentication: Bool = false,
        refreshError: MicrosoftDeviceCodeOAuthError? = nil
    ) {
        self.token = token
        self.resourceToken = resourceToken
        self.blocksAuthentication = blocksAuthentication
        self.refreshError = refreshError
    }

    func authenticate(
        configuration _: MicrosoftDeviceCodeOAuthConfiguration,
        onState: @escaping @Sendable (MicrosoftDeviceCodeState) async -> Void
    ) async throws -> MicrosoftOAuthToken {
        authenticationCount += 1
        let authorization = MicrosoftDeviceAuthorization(
            deviceCode: "fixture-device-code",
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://microsoft.com/devicelogin")!,
            verificationURIComplete: nil,
            expiresAt: .distantFuture,
            pollingInterval: 5,
            message: nil
        )
        await onState(.awaitingUser(authorization))
        await onState(.polling(attempt: 1))
        if blocksAuthentication {
            isAuthenticationBlocked = true
            await withCheckedContinuation { continuation in
                authenticationContinuation = continuation
            }
        }
        return token
    }

    func refreshToken(
        configuration: MicrosoftDeviceCodeOAuthConfiguration,
        refreshToken _: String
    ) throws -> MicrosoftOAuthToken {
        refreshCount += 1
        lastRefreshScopes = configuration.scopes
        if let refreshError {
            throw refreshError
        }
        if configuration.scopes.contains(where: {
            $0.contains("PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN")
        }), let resourceToken {
            return resourceToken
        }
        return token
    }

    func waitForBlockedAuthentication() async {
        while !isAuthenticationBlocked {
            await Task.yield()
        }
    }

    func releaseAuthentication() {
        authenticationContinuation?.resume()
        authenticationContinuation = nil
        isAuthenticationBlocked = false
    }
}

private actor XboxAuthPersistenceStub: XboxAuthSessionPersistence {
    private(set) var savedSession: XboxAuthSession?
    private(set) var saveGenerations: [UInt64] = []
    private(set) var deleteGenerations: [UInt64] = []
    private(set) var loadCount = 0
    private let failsDelete: Bool
    private let blocksDelete: Bool
    private var credentialGeneration: UInt64 = 0
    private var deleteWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var isDeleteBlocked = false
    private var deleteBlockContinuation: CheckedContinuation<Void, Never>?
    private var deleteBlockWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        session: XboxAuthSession? = nil,
        failsDelete: Bool = false,
        blocksDelete: Bool = false
    ) {
        savedSession = session
        self.failsDelete = failsDelete
        self.blocksDelete = blocksDelete
    }

    func loadXboxAuthSession() -> XboxAuthSession? {
        loadCount += 1
        return savedSession
    }

    func saveXboxAuthSession(
        _ session: XboxAuthSession,
        generation: UInt64
    ) {
        guard generation >= credentialGeneration else { return }
        credentialGeneration = generation
        saveGenerations.append(generation)
        savedSession = session
    }

    func deleteXboxAuthSession(generation: UInt64) async throws {
        if blocksDelete {
            isDeleteBlocked = true
            let waiters = deleteBlockWaiters
            deleteBlockWaiters.removeAll(keepingCapacity: false)
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                deleteBlockContinuation = continuation
            }
            isDeleteBlocked = false
        }
        if failsDelete {
            throw XboxAuthPersistenceStubError.deleteFailed
        }
        guard generation >= credentialGeneration else { return }
        credentialGeneration = generation
        deleteGenerations.append(generation)
        savedSession = nil
        let ready = deleteWaiters.filter { deleteGenerations.count >= $0.0 }
        deleteWaiters.removeAll { deleteGenerations.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func waitForDeleteCount(_ count: Int) async {
        guard deleteGenerations.count < count else { return }
        await withCheckedContinuation { continuation in
            deleteWaiters.append((count, continuation))
        }
    }

    func waitForBlockedDelete() async {
        guard !isDeleteBlocked else { return }
        await withCheckedContinuation { continuation in
            deleteBlockWaiters.append(continuation)
        }
    }

    func releaseDelete() {
        deleteBlockContinuation?.resume()
        deleteBlockContinuation = nil
    }
}

private enum XboxAuthPersistenceStubError: Error {
    case deleteFailed
}

private actor XboxAccountAuthorizationStub: XboxCloudAccountAuthorizationClient {
    private let account: XboxCloudAuthorizedAccount
    private let failsAuthorization: Bool
    private(set) var authorizationCount = 0

    init(
        account: XboxCloudAuthorizedAccount,
        failsAuthorization: Bool = false
    ) {
        self.account = account
        self.failsAuthorization = failsAuthorization
    }

    func authorize(
        microsoftToken _: MicrosoftOAuthToken
    ) throws -> XboxCloudAuthorizedAccount {
        authorizationCount += 1
        if failsAuthorization {
            throw XboxAccountAuthorizationStubError.rejected
        }
        return account
    }
}

private enum XboxAccountAuthorizationStubError: Error {
    case rejected
}

private actor ControllableXboxAuthorizationClient: XboxCloudAccountAuthorizationClient {
    private var pendingAuthorization: CheckedContinuation<XboxCloudAuthorizedAccount, Error>?
    private var authorizationRequestCount = 0
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func authorize(
        microsoftToken _: MicrosoftOAuthToken
    ) async throws -> XboxCloudAuthorizedAccount {
        authorizationRequestCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            precondition(pendingAuthorization == nil)
            pendingAuthorization = continuation
            let waiters = requestWaiters
            requestWaiters.removeAll(keepingCapacity: false)
            waiters.forEach { $0.resume() }
        }
    }

    func waitForAuthorizationRequest() async {
        guard authorizationRequestCount == 0 else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resolve(with account: XboxCloudAuthorizedAccount) {
        let continuation = pendingAuthorization
        pendingAuthorization = nil
        precondition(continuation != nil)
        continuation?.resume(returning: account)
    }
}

private final class XboxAccountAuthorizationFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [any XboxCloudAccountAuthorizationClient]
    private var createdClientCount = 0

    var creationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return createdClientCount
    }

    init(clients: [any XboxCloudAccountAuthorizationClient]) {
        self.clients = clients
    }

    func makeClient() -> any XboxCloudAccountAuthorizationClient {
        lock.lock()
        defer { lock.unlock() }
        precondition(!clients.isEmpty)
        createdClientCount += 1
        return clients.removeFirst()
    }
}

private actor XboxCatalogClientNoop: XboxCatalogClient {
    func fetchCatalog(
        _: XboxCatalogRequest,
        account _: XboxCloudAuthorizedAccount
    ) -> XboxCatalogSnapshot {
        XboxCatalogSnapshot(items: [], fetchedAt: .distantPast)
    }

    nonisolated func cancel() {}
}
