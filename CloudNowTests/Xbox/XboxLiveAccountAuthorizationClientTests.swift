@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox Live account authorization")
struct XboxLiveAccountAuthorizationClientTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Microsoft production configuration centralizes first-party endpoints")
    func productionConfiguration() throws {
        let configuration = try XboxLiveAuthorizationConfiguration.microsoftProduction()

        #expect(
            configuration.userAuthenticationEndpoint.absoluteString
                == "https://user.auth.xboxlive.com/user/authenticate"
        )
        #expect(
            configuration.xstsAuthorizationEndpoint.absoluteString
                == "https://xsts.auth.xboxlive.com/xsts/authorize"
        )
        #expect(configuration.userTokenRelyingParty == .userAuthentication)
        #expect(configuration.contractVersion == "1")
        #expect(configuration.sandboxID == "RETAIL")
        #expect(XboxLiveRelyingParty.cloudGaming.identifier == "http://gssv.xboxlive.com/")
        #expect(
            XboxLiveRelyingParty.cloudGamingWebPortal.identifier
                == "rp://gswp.xboxlive.com/"
        )
        #expect(XboxLiveRelyingParty.contentAccess.identifier == "http://mp.microsoft.com/")
    }

    @Test("Configuration rejects unsafe endpoints and audience values")
    func invalidConfiguration() throws {
        let secureEndpoint = try #require(URL(string: "https://fixture.xboxlive.com/auth"))
        let insecureEndpoint = try #require(URL(string: "http://fixture.xboxlive.com/auth"))
        let credentialEndpoint = try #require(
            URL(string: "https://user:password@fixture.xboxlive.com/auth")
        )

        #expect(throws: XboxLiveAuthorizationError.self) {
            _ = try XboxLiveAuthorizationConfiguration(
                userAuthenticationEndpoint: insecureEndpoint,
                xstsAuthorizationEndpoint: secureEndpoint
            )
        }
        #expect(throws: XboxLiveAuthorizationError.self) {
            _ = try XboxLiveAuthorizationConfiguration(
                userAuthenticationEndpoint: secureEndpoint,
                xstsAuthorizationEndpoint: credentialEndpoint
            )
        }
        #expect(throws: XboxLiveAuthorizationError.self) {
            _ = try XboxLiveRelyingParty(identifier: "https://user:secret@example.com/")
        }
    }

    @Test("Account authorization performs User Token then Cloud XSTS exchange")
    func accountAuthorization() async throws {
        let fixedDate = fixedDate
        let transport = RecordingHTTPTransport { request, index in
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "x-xbl-contract-version") == "1")
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")

            let body = try jsonObject(from: request)
            switch index {
            case 0:
                #expect(
                    request.url?.absoluteString
                        == "https://user.auth.xboxlive.com/user/authenticate"
                )
                #expect(body["RelyingParty"] as? String == "http://auth.xboxlive.com")
                #expect(body["TokenType"] as? String == "JWT")
                let properties = try #require(body["Properties"] as? [String: Any])
                #expect(properties["AuthMethod"] as? String == "RPS")
                #expect(properties["SiteName"] as? String == "user.auth.xboxlive.com")
                #expect(properties["RpsTicket"] as? String == "d=fixture-microsoft-access")
                return StubbedHTTPResponse(json: Self.userTokenJSON)
            default:
                #expect(
                    request.url?.absoluteString
                        == "https://xsts.auth.xboxlive.com/xsts/authorize"
                )
                #expect(body["RelyingParty"] as? String == "http://gssv.xboxlive.com/")
                #expect(body["TokenType"] as? String == "JWT")
                let properties = try #require(body["Properties"] as? [String: Any])
                #expect(properties["SandboxId"] as? String == "RETAIL")
                #expect(properties["UserTokens"] as? [String] == ["fixture-user-token"])
                return StubbedHTTPResponse(json: Self.xstsTokenJSON)
            }
        }
        let vault = XboxLiveCredentialVault(now: { fixedDate })
        let client = try makeAccountClient(transport: transport, vault: vault)

        let account = try await client.authorize(microsoftToken: makeMicrosoftToken())
        let credential = try await vault.credential(
            for: account,
            relyingParty: .cloudGaming
        )

        #expect(account.authorizationIdentifier == "fixture-authorization")
        #expect(account.displayName == "Fixture Gamer")
        #expect(account.expiresAt == fixedDate.addingTimeInterval(14400))
        #expect(
            credential.authorizationHeaderValue
                == "XBL3.0 x=fixture-user-hash;fixture-xsts-token"
        )
        #expect(!credential.description.contains("fixture-user-hash"))
        #expect(!credential.description.contains("fixture-xsts-token"))
        #expect(!credential.description.contains("Fixture Gamer"))
        #expect(await transport.requests().count == 2)

        await client.clearLocalCredentials()
        await #expect(throws: XboxLiveAuthorizationError.accountNotAuthorized) {
            _ = try await vault.credential(for: account, relyingParty: .cloudGaming)
        }
    }

    @Test("Xbox service errors preserve only status and numeric XErr")
    func serviceErrorIsTypedAndRedacted() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                statusCode: 401,
                json: #"{"XErr":2148916233,"Message":"fixture-access-token must never escape"}"#
            )
        }
        let configuration = try XboxLiveAuthorizationConfiguration.microsoftProduction()
        let client = XboxLiveTokenClient(
            configuration: configuration,
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let expected = XboxLiveAuthorizationError.service(
            statusCode: 401,
            xboxErrorCode: 2_148_916_233
        )

        do {
            _ = try await client.requestUserToken(microsoftAccessToken: "fixture-access-token")
            Issue.record("Expected Xbox User Token request to fail")
        } catch {
            #expect((error as? XboxLiveAuthorizationError) == expected)
            #expect(error.localizedDescription.contains("2148916233"))
            #expect(!error.localizedDescription.contains("fixture-access-token"))
        }
    }

    @Test("Expired Microsoft credentials fail before any Xbox request")
    func expiredMicrosoftToken() async throws {
        let fixedDate = fixedDate
        let transport = RecordingHTTPTransport { _, _ in
            throw TestTransportError.unexpectedRequest("No request expected")
        }
        let vault = XboxLiveCredentialVault(now: { fixedDate })
        let client = try makeAccountClient(transport: transport, vault: vault)
        let token = MicrosoftOAuthToken(
            accessToken: "fixture-microsoft-access",
            refreshToken: nil,
            idToken: nil,
            tokenType: "Bearer",
            scopes: ["xboxlive.signin"],
            expiresAt: fixedDate
        )

        await #expect(throws: XboxLiveAuthorizationError.microsoftTokenExpired) {
            _ = try await client.authorize(microsoftToken: token)
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test("A failed multi-audience exchange stores no partial authorization")
    func failedExchangeIsAtomic() async throws {
        let fixedDate = fixedDate
        let transport = RecordingHTTPTransport { request, index in
            guard index > 0 else {
                return StubbedHTTPResponse(json: Self.userTokenJSON)
            }
            let body = try jsonObject(from: request)
            if body["RelyingParty"] as? String == XboxLiveRelyingParty.xboxLive.identifier {
                return StubbedHTTPResponse(json: Self.xstsTokenJSON)
            }
            return StubbedHTTPResponse(statusCode: 403, json: #"{"XErr":"2148916238"}"#)
        }
        let vault = XboxLiveCredentialVault(now: { fixedDate })
        let client = try makeAccountClient(
            transport: transport,
            vault: vault,
            relyingParties: [.xboxLive, .cloudGaming]
        )

        await #expect(
            throws: XboxLiveAuthorizationError.service(
                statusCode: 403,
                xboxErrorCode: 2_148_916_238
            )
        ) {
            _ = try await client.authorize(microsoftToken: makeMicrosoftToken())
        }

        let account = XboxCloudAuthorizedAccount(
            authorizationIdentifier: "fixture-authorization",
            displayName: nil,
            expiresAt: fixedDate.addingTimeInterval(3600)
        )
        await #expect(throws: XboxLiveAuthorizationError.accountNotAuthorized) {
            _ = try await vault.credential(for: account, relyingParty: .xboxLive)
        }
    }

    @Test("An optional XSTS failure does not block required authorization")
    func optionalFailureIsBestEffort() async throws {
        let fixedDate = fixedDate
        let transport = RecordingHTTPTransport { request, index in
            guard index > 0 else {
                return StubbedHTTPResponse(json: Self.userTokenJSON)
            }
            let body = try jsonObject(from: request)
            if body["RelyingParty"] as? String == XboxLiveRelyingParty.contentAccess.identifier {
                return StubbedHTTPResponse(statusCode: 403, json: #"{"XErr":"2148916238"}"#)
            }
            return StubbedHTTPResponse(json: Self.xstsTokenJSON)
        }
        let vault = XboxLiveCredentialVault(now: { fixedDate })
        let client = try makeAccountClient(
            transport: transport,
            vault: vault,
            optionalRelyingParties: [.contentAccess]
        )

        let account = try await client.authorize(microsoftToken: makeMicrosoftToken())

        #expect(
            try await vault.credential(for: account, relyingParty: .cloudGaming).token
                == "fixture-xsts-token"
        )
        await #expect(
            throws: XboxLiveAuthorizationError.credentialUnavailable(.contentAccess)
        ) {
            _ = try await vault.credential(for: account, relyingParty: .contentAccess)
        }
        #expect(await transport.requests().count == 3)
    }

    @Test("A suspended optional XSTS request does not delay authorization")
    func optionalSuspensionDoesNotDelayAuthorization() async throws {
        let fixedDate = fixedDate
        let suspension = XboxAuthorizationTestSuspension()
        let transport = RecordingHTTPTransport { request, index in
            guard index > 0 else {
                return StubbedHTTPResponse(json: Self.userTokenJSON)
            }
            let body = try jsonObject(from: request)
            if body["RelyingParty"] as? String == XboxLiveRelyingParty.contentAccess.identifier {
                try await suspension.suspend()
                return StubbedHTTPResponse(json: Self.contentAccessXSTSTokenJSON)
            }
            return StubbedHTTPResponse(json: Self.xstsTokenJSON)
        }
        let vault = XboxLiveCredentialVault(now: { fixedDate })
        let client = try makeAccountClient(
            transport: transport,
            vault: vault,
            optionalRelyingParties: [.contentAccess]
        )

        let account = try await client.authorize(microsoftToken: makeMicrosoftToken())
        #expect(
            try await vault.credential(for: account, relyingParty: .cloudGaming).token
                == "fixture-xsts-token"
        )

        await suspension.waitUntilStarted()
        await suspension.release()
        #expect(
            try await vault.credential(for: account, relyingParty: .contentAccess).token
                == "fixture-content-access-token"
        )
    }

    @Test("A successful optional XSTS credential is retained")
    func optionalSuccessIsStored() async throws {
        let fixedDate = fixedDate
        let transport = RecordingHTTPTransport { request, index in
            guard index > 0 else {
                return StubbedHTTPResponse(json: Self.userTokenJSON)
            }
            let body = try jsonObject(from: request)
            if body["RelyingParty"] as? String == XboxLiveRelyingParty.contentAccess.identifier {
                return StubbedHTTPResponse(json: Self.contentAccessXSTSTokenJSON)
            }
            return StubbedHTTPResponse(json: Self.xstsTokenJSON)
        }
        let vault = XboxLiveCredentialVault(now: { fixedDate })
        let client = try makeAccountClient(
            transport: transport,
            vault: vault,
            optionalRelyingParties: [.contentAccess]
        )

        let account = try await client.authorize(microsoftToken: makeMicrosoftToken())
        let credential = try await vault.credential(
            for: account,
            relyingParty: .contentAccess
        )

        #expect(credential.token == "fixture-content-access-token")
        #expect(credential.relyingParty == .contentAccess)
    }

    @Test("Optional credential metadata cannot shorten or rename the account")
    func optionalMetadataDoesNotAffectAccount() async throws {
        let fixedDate = fixedDate
        let transport = RecordingHTTPTransport { request, index in
            guard index > 0 else {
                return StubbedHTTPResponse(json: Self.userTokenJSON)
            }
            let body = try jsonObject(from: request)
            if body["RelyingParty"] as? String == XboxLiveRelyingParty.contentAccess.identifier {
                return StubbedHTTPResponse(json: Self.shortContentAccessXSTSTokenJSON)
            }
            return StubbedHTTPResponse(json: Self.xstsTokenJSON)
        }
        let vault = XboxLiveCredentialVault(now: { fixedDate })
        let client = try makeAccountClient(
            transport: transport,
            vault: vault,
            optionalRelyingParties: [.contentAccess]
        )

        let account = try await client.authorize(microsoftToken: makeMicrosoftToken())

        #expect(account.expiresAt == fixedDate.addingTimeInterval(14400))
        #expect(account.displayName == "Fixture Gamer")
        #expect(
            try await vault.credential(for: account, relyingParty: .contentAccess).expiresAt
                == fixedDate.addingTimeInterval(3600)
        )
    }

    @Test("Optional XSTS cancellation does not invalidate required authorization")
    func optionalCancellationIsBestEffort() async throws {
        let fixedDate = fixedDate
        let transport = RecordingHTTPTransport { request, index in
            guard index > 0 else {
                return StubbedHTTPResponse(json: Self.userTokenJSON)
            }
            let body = try jsonObject(from: request)
            if body["RelyingParty"] as? String == XboxLiveRelyingParty.contentAccess.identifier {
                throw CancellationError()
            }
            return StubbedHTTPResponse(json: Self.xstsTokenJSON)
        }
        let vault = XboxLiveCredentialVault(now: { fixedDate })
        let client = try makeAccountClient(
            transport: transport,
            vault: vault,
            optionalRelyingParties: [.contentAccess]
        )

        let account = try await client.authorize(microsoftToken: makeMicrosoftToken())

        #expect(
            try await vault.credential(for: account, relyingParty: .cloudGaming).token
                == "fixture-xsts-token"
        )
        await #expect(
            throws: XboxLiveAuthorizationError.credentialUnavailable(.contentAccess)
        ) {
            _ = try await vault.credential(for: account, relyingParty: .contentAccess)
        }
    }

    @Test("Clearing the vault cancels optional enrichment without resurrection")
    func clearCancelsOptionalEnrichment() async throws {
        let fixedDate = fixedDate
        let suspension = XboxAuthorizationTestSuspension()
        let transport = RecordingHTTPTransport { request, index in
            guard index > 0 else {
                return StubbedHTTPResponse(json: Self.userTokenJSON)
            }
            let body = try jsonObject(from: request)
            if body["RelyingParty"] as? String == XboxLiveRelyingParty.contentAccess.identifier {
                try await suspension.suspend()
                return StubbedHTTPResponse(json: Self.contentAccessXSTSTokenJSON)
            }
            return StubbedHTTPResponse(json: Self.xstsTokenJSON)
        }
        let vault = XboxLiveCredentialVault(now: { fixedDate })
        let client = try makeAccountClient(
            transport: transport,
            vault: vault,
            optionalRelyingParties: [.contentAccess]
        )
        let account = try await client.authorize(microsoftToken: makeMicrosoftToken())
        await suspension.waitUntilStarted()

        await client.clearLocalCredentials()
        await suspension.waitUntilCancelled()

        await #expect(throws: XboxLiveAuthorizationError.accountNotAuthorized) {
            _ = try await vault.credential(for: account, relyingParty: .cloudGaming)
        }
        await #expect(throws: XboxLiveAuthorizationError.accountNotAuthorized) {
            _ = try await vault.credential(for: account, relyingParty: .contentAccess)
        }
    }

    @Test("Required and optional audiences must be unique together")
    func duplicateRequiredAndOptionalAudienceIsRejected() throws {
        let fixedDate = fixedDate
        let transport = RecordingHTTPTransport { _, _ in
            throw TestTransportError.unexpectedRequest("No request expected")
        }
        let vault = XboxLiveCredentialVault(now: { fixedDate })

        #expect(
            throws: XboxLiveAuthorizationError.invalidConfiguration(
                "Xbox relying-party requirements are invalid."
            )
        ) {
            _ = try makeAccountClient(
                transport: transport,
                vault: vault,
                relyingParties: [.cloudGaming],
                optionalRelyingParties: [.cloudGaming]
            )
        }
    }

    @Test("Transport cancellation propagates without becoming a service failure")
    func cancellation() async throws {
        let fixedDate = fixedDate
        let transport = RecordingHTTPTransport { _, _ in
            throw CancellationError()
        }
        let configuration = try XboxLiveAuthorizationConfiguration.microsoftProduction()
        let client = XboxLiveTokenClient(
            configuration: configuration,
            transport: transport,
            now: { fixedDate }
        )

        await #expect(throws: CancellationError.self) {
            _ = try await client.requestUserToken(
                microsoftAccessToken: "fixture-microsoft-access"
            )
        }
    }

    @Test("Credential vault is bounded and sign-out removes authorization")
    func credentialVaultLifecycle() async throws {
        let fixedDate = fixedDate
        let vault = XboxLiveCredentialVault(now: { fixedDate })
        let first = try await vault.store(
            identifier: "first",
            credentials: [makeCredential(token: "one")]
        )
        let second = try await vault.store(
            identifier: "second",
            credentials: [makeCredential(token: "two")]
        )
        let third = try await vault.store(
            identifier: "third",
            credentials: [makeCredential(token: "three")]
        )

        await #expect(throws: XboxLiveAuthorizationError.accountNotAuthorized) {
            _ = try await vault.credential(for: first, relyingParty: .cloudGaming)
        }
        #expect(
            try await vault.credential(for: second, relyingParty: .cloudGaming).token
                == "two"
        )

        await vault.remove(account: third)
        await #expect(throws: XboxLiveAuthorizationError.accountNotAuthorized) {
            _ = try await vault.credential(for: third, relyingParty: .cloudGaming)
        }

        let lifecycle: any XboxLocalCredentialLifecycle = vault
        await lifecycle.clearLocalCredentials()
        await #expect(throws: XboxLiveAuthorizationError.accountNotAuthorized) {
            _ = try await vault.credential(for: second, relyingParty: .cloudGaming)
        }
    }

    private func makeAccountClient(
        transport: RecordingHTTPTransport,
        vault: XboxLiveCredentialVault,
        relyingParties: [XboxLiveRelyingParty] = [.cloudGaming],
        optionalRelyingParties: [XboxLiveRelyingParty] = []
    ) throws -> XboxLiveAccountAuthorizationClient {
        let fixedDate = fixedDate
        let configuration = try XboxLiveAuthorizationConfiguration.microsoftProduction()
        let tokenClient = XboxLiveTokenClient(
            configuration: configuration,
            transport: transport,
            now: { fixedDate }
        )
        return try XboxLiveAccountAuthorizationClient(
            tokenClient: tokenClient,
            credentialVault: vault,
            relyingParties: relyingParties,
            optionalRelyingParties: optionalRelyingParties,
            now: { fixedDate },
            makeAuthorizationIdentifier: { "fixture-authorization" }
        )
    }

    private func makeMicrosoftToken() -> MicrosoftOAuthToken {
        MicrosoftOAuthToken(
            accessToken: "fixture-microsoft-access",
            refreshToken: "fixture-microsoft-refresh",
            idToken: nil,
            tokenType: "Bearer",
            scopes: ["xboxlive.signin", "offline_access"],
            expiresAt: fixedDate.addingTimeInterval(3600)
        )
    }

    private func makeCredential(token: String) -> XboxXSTSCredential {
        XboxXSTSCredential(
            token: token,
            userHash: "fixture-user-hash",
            relyingParty: .cloudGaming,
            expiresAt: fixedDate.addingTimeInterval(3600),
            gamertag: nil
        )
    }

    private static let userTokenJSON = #"{"NotAfter":"2023-11-15T22:13:20.000Z","Token":"fixture-user-token","DisplayClaims":{"xui":[{"uhs":"fixture-user-hash"}]}}"#
    private static let xstsTokenJSON = #"{"NotAfter":"2023-11-15T02:13:20.000Z","Token":"fixture-xsts-token","DisplayClaims":{"xui":[{"uhs":"fixture-user-hash","gtg":"Fixture Gamer"}]}}"#
    private static let contentAccessXSTSTokenJSON = #"{"NotAfter":"2023-11-15T03:13:20.000Z","Token":"fixture-content-access-token","DisplayClaims":{"xui":[{"uhs":"fixture-user-hash","gtg":"Content Gamer"}]}}"#
    private static let shortContentAccessXSTSTokenJSON = #"{"NotAfter":"2023-11-14T23:13:20.000Z","Token":"fixture-content-access-token","DisplayClaims":{"xui":[{"uhs":"fixture-user-hash","gtg":"Content Gamer"}]}}"#
}

private actor XboxAuthorizationTestSuspension {
    private var continuation: CheckedContinuation<Void, Error>?
    private var started = false
    private var cancelled = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async throws {
        started = true
        for waiter in startedWaiters {
            waiter.resume()
        }
        startedWaiters.removeAll(keepingCapacity: false)

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        cancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        for waiter in cancellationWaiters {
            waiter.resume()
        }
        cancellationWaiters.removeAll(keepingCapacity: false)
    }
}
