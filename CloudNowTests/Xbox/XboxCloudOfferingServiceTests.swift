@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox Cloud offering service")
struct XboxCloudOfferingServiceTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Logs into the fixed web default without requiring offering discovery")
    func defaultOfferingLogin() async throws {
        let credentialProvider = XboxCloudCredentialProviderStub(
            credential: makeCredential()
        )
        let transport = RecordingHTTPTransport { request, index in
            guard index == 0 else {
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
            #expect(request.url?.absoluteString == "https://xgpuweb.gssv-play-prod.xboxlive.com/v2/login/user")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            #expect(request.value(forHTTPHeaderField: "X-GSSV-Routing") == "AFD")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = try jsonObject(from: request)
            #expect(body["offeringId"] as? String == "xgpuweb")
            #expect(body["token"] as? String == "fixture-xsts-secret")
            return StubbedHTTPResponse(json: Self.loginResponseJSON)
        }
        let provider = try makeProvider(
            credentialProvider: credentialProvider,
            transport: transport
        )

        let session = try await provider.session(for: makeAccount())
        let cachedSession = try await provider.session(for: makeAccount())

        #expect(session == cachedSession)
        #expect(session.offeringID == "xgpuweb")
        #expect(session.market == "US")
        #expect(session.defaultRegion.name == "West US")
        #expect(session.defaultRegion.baseURL.absoluteString == "https://wus.gssv-play-prod.xboxlive.com")
        #expect(session.defaultRegion.systemUpdateGroups == ["flight-a", "flight-b"])
        #expect(session.fallbackRegionNames == ["North Europe", "East US"])
        #expect(session.expiresAt == fixedDate.addingTimeInterval(7200))
        #expect(session.description.contains("<redacted>"))
        #expect(!session.description.contains("fixture-gs-secret"))
        #expect(await transport.requests().count == 1)
        #expect(await credentialProvider.requestCount() == 1)
    }

    @Test("A failed web default discovers and logs into the entitled F2P fallback")
    func f2pFallbackAfterDefaultFailure() async throws {
        let transport = RecordingHTTPTransport { request, index in
            switch index {
            case 0:
                #expect(
                    request.url?.absoluteString
                        == "https://xgpuweb.gssv-play-prod.xboxlive.com/v2/login/user"
                )
                return StubbedHTTPResponse(
                    statusCode: 403,
                    json: #"{"code":"NoEntitlement"}"#
                )
            case 1:
                #expect(
                    request.url?.absoluteString
                        == "https://gssv-play-prod.xboxlive.com/v1/offerings/user"
                )
                let body = try jsonObject(from: request)
                #expect(body["authenticationType"] as? String == "Xbox")
                #expect(body["token"] as? String == "fixture-xsts-secret")
                return StubbedHTTPResponse(
                    json: #"{"offerings":["takehomeweb","xgpuweb","xgpuwebf2p"]}"#
                )
            case 2:
                #expect(request.url?.host == "xgpuwebf2p.gssv-play-prod.xboxlive.com")
                #expect(request.value(forHTTPHeaderField: "X-GSSV-Routing") == "AFD")
                let body = try jsonObject(from: request)
                #expect(body["offeringId"] as? String == "xgpuwebf2p")
                return StubbedHTTPResponse(json: Self.loginResponseJSON)
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let provider = try makeProvider(transport: transport)

        let session = try await provider.session(for: makeAccount())

        #expect(session.offeringID == "xgpuwebf2p")
        #expect(await transport.requests().count == 3)
    }

    @Test("Optional ATM routing uses the ATM host and matching header")
    func azureTrafficManagerRouting() async throws {
        let baseURL = try #require(
            URL(string: "https://gssv-play-prod.xboxlive.com")
        )
        let configuration = try XboxCloudOfferingServiceConfiguration(
            serviceBaseURL: baseURL,
            usesAzureTrafficManagerWhenEligible: true
        )
        let transport = RecordingHTTPTransport { request, index in
            guard index == 0 else {
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
            #expect(
                request.url?.absoluteString
                    == "https://atm.gssv-play-prod.xboxlive.com/v2/login/user"
            )
            #expect(request.value(forHTTPHeaderField: "X-GSSV-Routing") == "ATM")
            return StubbedHTTPResponse(json: Self.loginResponseJSON)
        }
        let provider = XboxCloudGSSessionProvider(
            credentialProvider: XboxCloudCredentialProviderStub(
                credential: makeCredential()
            ),
            configuration: configuration,
            transport: transport,
            now: { fixedDate }
        )

        let session = try await provider.session(for: makeAccount())

        #expect(session.offeringID == "xgpuweb")
    }

    @Test("Unknown offerings do not get sent blindly to login")
    func rejectsUnknownOffering() async throws {
        let transport = RecordingHTTPTransport { request, index in
            switch index {
            case 0:
                #expect(request.url?.host == "xgpuweb.gssv-play-prod.xboxlive.com")
                return StubbedHTTPResponse(
                    statusCode: 403,
                    json: #"{"code":"NoEntitlement"}"#
                )
            case 1:
                #expect(request.url?.host == "gssv-play-prod.xboxlive.com")
                return StubbedHTTPResponse(
                    json: #"{"offerings":[{"id":"internalexperiment"}]}"#
                )
            default:
                throw TestTransportError.unexpectedRequest("Login must not run")
            }
        }
        let provider = try makeProvider(transport: transport)

        await #expect(throws: XboxCloudOfferingServiceError.noSupportedOffering) {
            _ = try await provider.session(for: makeAccount())
        }

        #expect(await transport.requests().count == 2)
    }

    @Test("Service and region hosts must be credential-free Xbox HTTPS endpoints")
    func rejectsInvalidHosts() async throws {
        let invalidBaseURL = try #require(URL(string: "https://example.com"))
        #expect(throws: XboxCloudOfferingServiceError.invalidConfiguration) {
            _ = try XboxCloudOfferingServiceConfiguration(
                serviceBaseURL: invalidBaseURL
            )
        }

        let transport = RecordingHTTPTransport { _, index in
            switch index {
            case 0:
                StubbedHTTPResponse(
                    statusCode: 403,
                    json: #"{"code":"NoEntitlement"}"#
                )
            case 1:
                StubbedHTTPResponse(json: #"{"offerings":["xgpuwebf2p"]}"#)
            case 2:
                StubbedHTTPResponse(
                    json: Self.loginResponseJSON.replacingOccurrences(
                        of: "https://wus.gssv-play-prod.xboxlive.com",
                        with: "http://untrusted.example"
                    )
                )
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let provider = try makeProvider(transport: transport)

        await #expect(throws: XboxCloudOfferingServiceError.invalidPayload(.login)) {
            _ = try await provider.session(for: makeAccount())
        }
    }

    @Test("Offering and login responses are size and count bounded")
    func responseBounds() async throws {
        let tooManyOfferings = (0 ... 64).map { "offer\($0)" }
        let payload = try JSONSerialization.data(
            withJSONObject: ["offerings": tooManyOfferings]
        )
        let countTransport = RecordingHTTPTransport { _, index in
            index == 0
                ? StubbedHTTPResponse(statusCode: 403)
                : StubbedHTTPResponse(data: payload)
        }
        let countProvider = try makeProvider(transport: countTransport)

        await #expect(throws: XboxCloudOfferingServiceError.invalidPayload(.offerings)) {
            _ = try await countProvider.session(for: makeAccount())
        }

        let sizeTransport = RecordingHTTPTransport { _, index in
            index == 0
                ? StubbedHTTPResponse(statusCode: 403)
                : StubbedHTTPResponse(data: Data(repeating: 0x41, count: 524_289))
        }
        let sizeProvider = try makeProvider(transport: sizeTransport)
        await #expect(throws: XboxCloudOfferingServiceError.responseTooLarge(.offerings)) {
            _ = try await sizeProvider.session(for: makeAccount())
        }
    }

    @Test("Cancellation propagates without storing a partial GS session")
    func cancellation() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            try await Task.sleep(for: .seconds(60))
            return StubbedHTTPResponse(json: Self.loginResponseJSON)
        }
        let provider = try makeProvider(transport: transport)
        let task = Task {
            try await provider.session(for: makeAccount())
        }
        while await transport.requests().isEmpty {
            await Task.yield()
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await transport.requests().count == 1)
    }

    @Test("HTTP errors preserve only a safe service code")
    func errorsAreRedacted() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                statusCode: 403,
                json: #"{"code":"NoEntitlement","message":"fixture-xsts-secret","token":"response-secret"}"#
            )
        }
        let provider = try makeProvider(transport: transport)

        do {
            _ = try await provider.session(for: makeAccount())
            Issue.record("Expected offering discovery to fail")
        } catch {
            #expect((error as? XboxCloudOfferingServiceError) == .httpFailure(
                operation: .offerings,
                statusCode: 403,
                serviceCode: "NoEntitlement"
            ))
            #expect(error.localizedDescription.contains("NoEntitlement"))
            #expect(!error.localizedDescription.contains("fixture-xsts-secret"))
            #expect(!error.localizedDescription.contains("response-secret"))
        }
        #expect(await transport.requests().count == 2)
    }

    @Test("The memory-only GS store evicts the oldest account at its bound")
    func boundedAccountStorage() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: Self.loginResponseJSON)
        }
        let provider = try makeProvider(transport: transport)
        let accounts = ["account-a", "account-b", "account-c"].map(makeAccount)

        for account in accounts {
            _ = try await provider.session(for: account)
        }
        _ = try await provider.session(for: accounts[0])

        #expect(await transport.requests().count == 4)
    }

    @Test("Credential clearing fences an in-flight login from restoring a GS token")
    func clearFencesInFlightLogin() async throws {
        let gate = XboxCloudOfferingRequestGate()
        let transport = RecordingHTTPTransport { _, index in
            if index == 0 {
                await gate.suspend()
            }
            return StubbedHTTPResponse(json: Self.loginResponseJSON)
        }
        let provider = try makeProvider(transport: transport)
        let task = Task {
            try await provider.session(for: makeAccount())
        }
        await gate.waitUntilSuspended()

        await provider.clearSessions()
        await gate.release()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        _ = try await provider.session(for: makeAccount())
        #expect(await transport.requests().count == 2)
    }

    private func makeProvider(
        credentialProvider: XboxCloudCredentialProviderStub? = nil,
        transport: any HTTPTransport
    ) throws -> XboxCloudGSSessionProvider {
        let provider = credentialProvider ?? XboxCloudCredentialProviderStub(
            credential: makeCredential()
        )
        let configuration = try XboxCloudOfferingServiceConfiguration.microsoftProduction()
        return XboxCloudGSSessionProvider(
            credentialProvider: provider,
            configuration: configuration,
            transport: transport,
            now: { fixedDate }
        )
    }

    private func makeCredential() -> XboxXSTSCredential {
        XboxXSTSCredential(
            token: "fixture-xsts-secret",
            userHash: "fixture-user-hash",
            relyingParty: .cloudGaming,
            expiresAt: fixedDate.addingTimeInterval(3600),
            gamertag: "Cloud Player"
        )
    }

    private func makeAccount(identifier: String = "fixture-account") -> XboxCloudAuthorizedAccount {
        XboxCloudAuthorizedAccount(
            authorizationIdentifier: identifier,
            displayName: "Cloud Player",
            expiresAt: fixedDate.addingTimeInterval(3600)
        )
    }

    private static let loginResponseJSON = #"""
    {
      "gsToken": "fixture-gs-secret",
      "durationInSeconds": 7200,
      "market": "US",
      "offeringSettings": {
        "allowRegionSelection": true,
        "regions": [
          {
            "name": "East US",
            "baseUri": "https://eus.gssv-play-prod.xboxlive.com",
            "isDefault": false,
            "fallbackPriority": 2,
            "systemUpdateGroups": []
          },
          {
            "name": "West US",
            "baseUri": "https://wus.gssv-play-prod.xboxlive.com",
            "isDefault": true,
            "fallbackPriority": -1,
            "systemUpdateGroups": ["flight-a", "flight-b", "flight-a"]
          },
          {
            "name": "North Europe",
            "baseUri": "https://neu.gssv-play-prod.xboxlive.com",
            "isDefault": false,
            "fallbackPriority": 1,
            "systemUpdateGroups": []
          }
        ]
      }
    }
    """#
}

private actor XboxCloudCredentialProviderStub: XboxXSTSCredentialProviding {
    private let storedCredential: XboxXSTSCredential
    private var requests = 0

    init(credential: XboxXSTSCredential) {
        storedCredential = credential
    }

    func credential(
        for _: XboxCloudAuthorizedAccount,
        relyingParty: XboxLiveRelyingParty
    ) throws -> XboxXSTSCredential {
        requests += 1
        guard relyingParty == .cloudGaming else {
            throw XboxLiveAuthorizationError.credentialUnavailable(relyingParty)
        }
        return storedCredential
    }

    func requestCount() -> Int {
        requests
    }
}

private actor XboxCloudOfferingRequestGate {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
