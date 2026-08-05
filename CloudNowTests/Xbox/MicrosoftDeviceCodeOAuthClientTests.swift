@testable import CloudNow
import Foundation
import Testing

@Suite("Microsoft device-code OAuth client")
struct MicrosoftDeviceCodeOAuthClientTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Configuration builds only documented Entra device-code endpoints")
    func configurationEndpoints() throws {
        let configuration = try makeConfiguration()

        #expect(configuration.deviceAuthorizationEndpoint.absoluteString == "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode")
        #expect(configuration.tokenEndpoint.absoluteString == "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")
        #expect(!configuration.description.contains("fixture-client"))
    }

    @Test(
        "Configuration rejects missing or unsafe values",
        arguments: [
            OAuthConfigurationCase(tenant: "", clientID: "fixture", scopes: ["openid"]),
            OAuthConfigurationCase(tenant: "consumers/path", clientID: "fixture", scopes: ["openid"]),
            OAuthConfigurationCase(tenant: "consumers", clientID: "", scopes: ["openid"]),
            OAuthConfigurationCase(tenant: "consumers", clientID: "fixture", scopes: []),
            OAuthConfigurationCase(tenant: "consumers", clientID: "fixture", scopes: ["two scopes"]),
        ]
    )
    func invalidConfiguration(testCase: OAuthConfigurationCase) {
        #expect(throws: MicrosoftDeviceCodeOAuthError.self) {
            _ = try MicrosoftDeviceCodeOAuthConfiguration(
                tenant: testCase.tenant,
                clientID: testCase.clientID,
                scopes: testCase.scopes
            )
        }
    }

    @Test("Device authorization sends a form and derives expiry from the injected clock")
    func requestAuthorization() async throws {
        let fixedDate = fixedDate
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.url?.absoluteString == "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded; charset=UTF-8")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            let form = try formValues(from: request)
            #expect(form["client_id"] == "fixture-client")
            #expect(form["scope"] == "openid api://fixture/read")
            return StubbedHTTPResponse(json: Self.authorizationJSON)
        }
        let client = MicrosoftDeviceCodeOAuthClient(transport: transport, now: { fixedDate })

        let authorization = try await client.requestAuthorization(configuration: makeConfiguration())

        #expect(authorization.deviceCode == "fixture-device-code")
        #expect(authorization.userCode == "ABCD-EFGH")
        #expect(authorization.verificationURI.absoluteString == "https://microsoft.com/devicelogin")
        #expect(authorization.verificationURIComplete?.absoluteString == "https://microsoft.com/devicelogin?otc=ABCD-EFGH")
        #expect(authorization.expiresAt == fixedDate.addingTimeInterval(900))
        #expect(authorization.pollingInterval == 2)
    }

    @Test("Device authorization accepts an omitted completion URL and defaults the poll interval")
    func optionalAuthorizationFields() async throws {
        let fixedDate = fixedDate
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                json: #"{"device_code":"fixture-device-code","user_code":"ABCD-EFGH","verification_uri":"https://microsoft.com/devicelogin","expires_in":900}"#
            )
        }
        let client = MicrosoftDeviceCodeOAuthClient(transport: transport, now: { fixedDate })

        let authorization = try await client.requestAuthorization(configuration: makeConfiguration())

        #expect(authorization.verificationURIComplete == nil)
        #expect(authorization.pollingInterval == 5)
    }

    @Test("QR verification uses Microsoft's server-provided completion URL")
    func qrVerificationCompleteURLWins() throws {
        let completeURL = try #require(URL(string: "https://login.example.test/complete?code=server-value"))
        let authorization = try makeQRAuthorization(
            verificationURI: #require(URL(string: "https://www.microsoft.com/link")),
            verificationURIComplete: completeURL
        )

        #expect(authorization.qrVerificationURI == completeURL)
    }

    @Test("QR verification pre-fills Microsoft's consumer device-code page")
    func qrVerificationPrefillsMicrosoftLink() throws {
        let authorization = try makeQRAuthorization(
            verificationURI: #require(URL(string: "https://www.microsoft.com/link"))
        )

        #expect(authorization.qrVerificationURI.absoluteString == "https://www.microsoft.com/link?otc=ABCD-EFGH")
    }

    @Test("QR verification preserves query items and replaces every stale OTC value")
    func qrVerificationPreservesQueryAndReplacesOTC() throws {
        let authorization = try makeQRAuthorization(
            verificationURI: #require(
                URL(string: "https://www.microsoft.com/link?source=tv&OTC=stale&locale=en-US&otc=older")
            )
        )

        let components = try #require(
            URLComponents(url: authorization.qrVerificationURI, resolvingAgainstBaseURL: false)
        )
        let queryItems = try #require(components.queryItems)

        #expect(queryItems == [
            URLQueryItem(name: "source", value: "tv"),
            URLQueryItem(name: "locale", value: "en-US"),
            URLQueryItem(name: "otc", value: "ABCD-EFGH"),
        ])
    }

    @Test(
        "QR verification leaves unsupported or unsafe URLs unchanged",
        arguments: [
            "http://www.microsoft.com/link",
            "https://microsoft.com/link",
            "https://www.microsoft.com/devicelogin",
            "https://user@www.microsoft.com/link",
            "https://www.microsoft.com:443/link",
        ]
    )
    func qrVerificationRejectsUnknownURL(urlString: String) throws {
        let verificationURI = try #require(URL(string: urlString))
        let authorization = makeQRAuthorization(verificationURI: verificationURI)

        #expect(authorization.qrVerificationURI == verificationURI)
    }

    @Test("Polling handles pending and slow-down without wall-clock sleeping")
    func pollPendingAndSlowDown() async throws {
        let fixedDate = fixedDate
        let delays = MicrosoftOAuthDelayRecorder()
        let transport = RecordingHTTPTransport { request, index in
            let form = try formValues(from: request)
            #expect(request.url?.absoluteString == "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")
            #expect(form["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
            #expect(form["client_id"] == "fixture-client")
            #expect(form["device_code"] == "fixture-device-code")
            switch index {
            case 0:
                return StubbedHTTPResponse(statusCode: 400, json: #"{"error":"authorization_pending"}"#)
            case 1:
                return StubbedHTTPResponse(statusCode: 400, json: #"{"error":"slow_down"}"#)
            default:
                return StubbedHTTPResponse(json: Self.tokenJSON)
            }
        }
        let client = MicrosoftDeviceCodeOAuthClient(
            transport: transport,
            now: { fixedDate },
            sleep: { delay in await delays.record(delay) }
        )

        let token = try await client.pollForToken(
            configuration: makeConfiguration(),
            authorization: makeAuthorization(expiresAt: fixedDate.addingTimeInterval(30))
        )

        #expect(token.accessToken == "fixture-access-token")
        #expect(token.refreshToken == "fixture-refresh-token")
        #expect(token.idToken == "fixture-id-token")
        #expect(token.expiresAt == fixedDate.addingTimeInterval(3600))
        #expect(await delays.values() == [2, 2, 7])
    }

    @Test("Refresh safely encodes credentials and preserves a rotated-token fallback")
    func refresh() async throws {
        let fixedDate = fixedDate
        let transport = RecordingHTTPTransport { request, _ in
            let form = try formValues(from: request)
            #expect(request.url?.absoluteString == "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")
            #expect(form["grant_type"] == "refresh_token")
            #expect(form["client_id"] == "fixture-client")
            #expect(form["refresh_token"] == "fixture +&=refresh")
            #expect(form["scope"] == "openid api://fixture/read")
            return StubbedHTTPResponse(
                json: #"{"access_token":"new-access","token_type":"Bearer","expires_in":120}"#
            )
        }
        let client = MicrosoftDeviceCodeOAuthClient(transport: transport, now: { fixedDate })

        let token = try await client.refreshToken(
            configuration: makeConfiguration(),
            refreshToken: "fixture +&=refresh"
        )

        #expect(token.accessToken == "new-access")
        #expect(token.refreshToken == "fixture +&=refresh")
        #expect(token.scopes == ["openid", "api://fixture/read"])
        #expect(token.expiresAt == fixedDate.addingTimeInterval(120))
    }

    @Test("OAuth error parsing retains diagnostics but never response credentials")
    func errorsAreParsedAndRedacted() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                statusCode: 400,
                json: #"{"error":"invalid_client","error_description":"Rejected","access_token":"do-not-leak","refresh_token":"also-secret"}"#
            )
        }
        let client = MicrosoftDeviceCodeOAuthClient(transport: transport)

        do {
            _ = try await client.requestAuthorization(configuration: makeConfiguration())
            Issue.record("Expected device authorization to fail")
        } catch {
            #expect((error as? MicrosoftDeviceCodeOAuthError) == .server(statusCode: 400, code: "invalid_client"))
            #expect(error.localizedDescription.contains("invalid_client"))
            #expect(!error.localizedDescription.contains("do-not-leak"))
            #expect(!error.localizedDescription.contains("also-secret"))
        }
    }

    @Test("Authorization payload and token descriptions redact every credential")
    func valueDescriptionsAreRedacted() {
        let authorization = makeAuthorization(expiresAt: fixedDate)
        let token = MicrosoftOAuthToken(
            accessToken: "access-secret",
            refreshToken: "refresh-secret",
            idToken: "id-secret",
            tokenType: "Bearer",
            scopes: ["openid"],
            expiresAt: fixedDate
        )

        #expect(!authorization.description.contains("fixture-device-code"))
        #expect(!authorization.description.contains("ABCD-EFGH"))
        #expect(!token.description.contains("access-secret"))
        #expect(!token.description.contains("refresh-secret"))
        #expect(!token.description.contains("id-secret"))
        #expect(!MicrosoftDeviceCodeState.awaitingUser(authorization).description.contains("fixture-device-code"))
    }

    @Test("OAuth token persistence round-trips independently while descriptions stay redacted")
    func tokenCodingRoundTrip() throws {
        let token = MicrosoftOAuthToken(
            accessToken: "access-secret",
            refreshToken: "refresh-secret",
            idToken: "id-secret",
            tokenType: "Bearer",
            scopes: ["openid", "offline_access"],
            expiresAt: fixedDate
        )

        let encoded = try JSONEncoder().encode(token)
        let decoded = try JSONDecoder().decode(MicrosoftOAuthToken.self, from: encoded)

        #expect(decoded == token)
        #expect(!decoded.description.contains("access-secret"))
        #expect(!decoded.description.contains("refresh-secret"))
        #expect(!decoded.description.contains("id-secret"))
    }

    @Test(
        "Terminal polling errors map to stable domain errors",
        arguments: [
            OAuthPollingErrorCase(serverCode: "authorization_declined", expected: .authorizationDeclined),
            OAuthPollingErrorCase(serverCode: "access_denied", expected: .authorizationDeclined),
            OAuthPollingErrorCase(serverCode: "expired_token", expected: .authorizationExpired),
        ]
    )
    func terminalPollingError(testCase: OAuthPollingErrorCase) async throws {
        let fixedDate = fixedDate
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(statusCode: 400, json: #"{"error":"\#(testCase.serverCode)"}"#)
        }
        let client = MicrosoftDeviceCodeOAuthClient(
            transport: transport,
            now: { fixedDate },
            sleep: { _ in }
        )

        await #expect(throws: testCase.expected) {
            _ = try await client.pollForToken(
                configuration: makeConfiguration(),
                authorization: makeAuthorization(expiresAt: fixedDate.addingTimeInterval(30))
            )
        }
    }

    @Test("Cancellation propagates and reports a cancelled state without polling transport")
    func cancellation() async throws {
        let fixedDate = fixedDate
        let states = MicrosoftOAuthStateRecorder()
        let transport = RecordingHTTPTransport { _, index in
            #expect(index == 0)
            return StubbedHTTPResponse(json: Self.authorizationJSON)
        }
        let client = MicrosoftDeviceCodeOAuthClient(
            transport: transport,
            now: { fixedDate },
            sleep: { _ in throw CancellationError() }
        )

        await #expect(throws: CancellationError.self) {
            _ = try await client.authenticate(configuration: makeConfiguration()) { state in
                await states.record(state)
            }
        }

        #expect(await transport.requests().count == 1)
        #expect(await states.values() == [
            .requestingCode,
            .awaitingUser(makeAuthorization(expiresAt: fixedDate.addingTimeInterval(900))),
            .polling(attempt: 1),
            .cancelled,
        ])
    }

    @Test("Malformed success payloads fail closed")
    func malformedPayload() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: #"{"device_code":"secret","expires_in":"wrong-type"}"#)
        }
        let client = MicrosoftDeviceCodeOAuthClient(transport: transport)

        await #expect(throws: MicrosoftDeviceCodeOAuthError.invalidPayload) {
            _ = try await client.requestAuthorization(configuration: makeConfiguration())
        }
    }

    private func makeConfiguration() throws -> MicrosoftDeviceCodeOAuthConfiguration {
        try MicrosoftDeviceCodeOAuthConfiguration(
            tenant: "consumers",
            clientID: "fixture-client",
            scopes: ["openid", "api://fixture/read"]
        )
    }

    private func makeAuthorization(expiresAt: Date) -> MicrosoftDeviceAuthorization {
        MicrosoftDeviceAuthorization(
            deviceCode: "fixture-device-code",
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://microsoft.com/devicelogin")!,
            verificationURIComplete: URL(string: "https://microsoft.com/devicelogin?otc=ABCD-EFGH")!,
            expiresAt: expiresAt,
            pollingInterval: 2,
            message: "Use a browser to continue."
        )
    }

    private func makeQRAuthorization(
        verificationURI: URL,
        verificationURIComplete: URL? = nil
    ) -> MicrosoftDeviceAuthorization {
        MicrosoftDeviceAuthorization(
            deviceCode: "fixture-device-code",
            userCode: "ABCD-EFGH",
            verificationURI: verificationURI,
            verificationURIComplete: verificationURIComplete,
            expiresAt: fixedDate.addingTimeInterval(900),
            pollingInterval: 5,
            message: nil
        )
    }

    private static let authorizationJSON = #"{"device_code":"fixture-device-code","user_code":"ABCD-EFGH","verification_uri":"https://microsoft.com/devicelogin","verification_uri_complete":"https://microsoft.com/devicelogin?otc=ABCD-EFGH","expires_in":900,"interval":2,"message":"Use a browser to continue."}"#

    private static let tokenJSON = #"{"access_token":"fixture-access-token","refresh_token":"fixture-refresh-token","id_token":"fixture-id-token","token_type":"Bearer","scope":"openid api://fixture/read","expires_in":3600}"#
}

private actor MicrosoftOAuthDelayRecorder {
    private var recordedValues: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        recordedValues.append(value)
    }

    func values() -> [TimeInterval] {
        recordedValues
    }
}

private actor MicrosoftOAuthStateRecorder {
    private var recordedValues: [MicrosoftDeviceCodeState] = []

    func record(_ value: MicrosoftDeviceCodeState) {
        recordedValues.append(value)
    }

    func values() -> [MicrosoftDeviceCodeState] {
        recordedValues
    }
}

nonisolated struct OAuthConfigurationCase: Sendable {
    let tenant: String
    let clientID: String
    let scopes: [String]
}

nonisolated struct OAuthPollingErrorCase: Sendable {
    let serverCode: String
    let expected: MicrosoftDeviceCodeOAuthError
}
