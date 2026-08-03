@testable import CloudNow
import Foundation
import Testing

@Suite("NVIDIA authentication HTTP client")
struct NVIDIAAuthAPITests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Provider request sets expected headers, sorts priority, and normalizes URLs")
    func providers() async throws {
        let fixture = try NetworkingFixture.data("auth-providers.json")
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.url?.absoluteString == NVIDIAAuth.serviceUrlsEndpoint)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == NVIDIAAuth.userAgent)
            return StubbedHTTPResponse(data: fixture)
        }

        let providers = try await NVIDIAAuthAPI(transport: transport).fetchProviders()

        #expect(providers.map(\.idpId) == ["primary-idp", "secondary-idp"])
        #expect(providers.map(\.streamingServiceUrl) == [
            "https://primary.example.invalid/",
            "https://secondary.example.invalid/",
        ])
        #expect(providers[1].displayName == "bro.game")
    }

    @Test("Device authorization encodes identity and provider without live credentials")
    func deviceAuthorization() async throws {
        let fixture = try NetworkingFixture.data("auth-device.json")
        let fixedUUID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.url?.absoluteString == NVIDIAAuth.deviceAuthorizeEndpoint)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded; charset=UTF-8")
            let form = try formValues(from: request)
            #expect(form["client_id"] == NVIDIAAuth.deviceFlowClientID)
            #expect(form["device_id"] == fixedUUID.uuidString)
            #expect(form["display_name"] == "Apple TV")
            #expect(form["idp_id"] == "fixture-idp")
            return StubbedHTTPResponse(data: fixture)
        }
        let api = NVIDIAAuthAPI(transport: transport, uuid: { fixedUUID })

        let response = try await api.requestDeviceAuthorization(idpId: "fixture-idp")

        #expect(response.userCode == "ABCD-EFGH")
        #expect(response.deviceCode == "fixture-device-code")
        #expect(response.interval == 5)
    }

    @Test("Authorization-code exchange safely encodes reserved form values and uses the injected clock")
    func authorizationCodeExchange() async throws {
        let fixture = try NetworkingFixture.data("auth-token.json")
        let fixedDate = fixedDate
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.url?.absoluteString == NVIDIAAuth.tokenEndpoint)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Origin") == NVIDIAAuth.nvFileOrigin)
            let form = try formValues(from: request)
            #expect(form["grant_type"] == "authorization_code")
            #expect(form["code"] == "fixture +&=code")
            #expect(form["redirect_uri"] == "cloudnow://callback?state=a+b&value=x")
            #expect(form["code_verifier"] == "fixture/verifier?")
            return StubbedHTTPResponse(data: fixture)
        }
        let api = NVIDIAAuthAPI(transport: transport, now: { fixedDate })

        let tokens = try await api.exchangeCode(
            "fixture +&=code",
            verifier: "fixture/verifier?",
            redirectURI: "cloudnow://callback?state=a+b&value=x"
        )

        #expect(tokens.accessToken == "fixture-access-token")
        #expect(tokens.refreshToken == "fixture-refresh-token")
        #expect(tokens.expiresAt == fixedDate.addingTimeInterval(3600))
        #expect(tokens.clientTokenExpiresAt == fixedDate.addingTimeInterval(7200))
    }

    @Test(
        "Form encoding is deterministic for reserved characters and UTF-8",
        arguments: [
            FormEncodingCase(input: "space value", expected: "space+value"),
            FormEncodingCase(input: "plus+amp&equals=", expected: "plus%2Bamp%26equals%3D"),
            FormEncodingCase(input: "slash/path?query#fragment", expected: "slash%2Fpath%3Fquery%23fragment"),
            FormEncodingCase(input: "Grüße", expected: "Gr%C3%BC%C3%9Fe"),
            FormEncodingCase(input: "~-._", expected: "~-._"),
        ]
    )
    func formEncoding(testCase: FormEncodingCase) throws {
        let body = NVIDIAAuthAPI.formURLEncoded([("value", testCase.input)])
        let bodyString = try #require(String(bytes: body, encoding: .utf8))

        #expect(bodyString == "value=\(testCase.expected)")
    }

    @Test("Refresh retries only a rejected client ID")
    func refreshClientIdFallback() async throws {
        let fixture = try NetworkingFixture.data("auth-token.json")
        let transport = RecordingHTTPTransport { _, index in
            if index == 0 {
                return StubbedHTTPResponse(statusCode: 400, json: #"{"error":"invalid_client"}"#)
            }
            return StubbedHTTPResponse(data: fixture)
        }
        let api = NVIDIAAuthAPI(transport: transport)

        let tokens = try await api.refreshTokens("fixture-refresh")
        let requests = await transport.requests()

        #expect(tokens.accessToken == "fixture-access-token")
        #expect(requests.count == 2)
        #expect(try formValues(from: requests[0])["client_id"] == NVIDIAAuth.deviceFlowClientID)
        #expect(try formValues(from: requests[1])["client_id"] == NVIDIAAuth.clientID)
    }

    @Test("Refresh does not retry server failures")
    func refreshServerFailureDoesNotRetry() async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(statusCode: 503, json: #"{"error":"temporarily_unavailable"}"#)
        }
        let api = NVIDIAAuthAPI(transport: transport)

        await #expect(throws: AuthError.self) {
            _ = try await api.refreshTokens("fixture-refresh")
        }
        #expect(await transport.requests().count == 1)
    }

    @Test("Provider HTTP failure reports status and redacts credentials")
    func providerHTTPFailure() async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                statusCode: 503,
                json: #"{"error":"unavailable","client_token":"do-not-leak"}"#
            )
        }

        do {
            _ = try await NVIDIAAuthAPI(transport: transport).fetchProviders()
            Issue.record("Expected provider discovery to fail")
        } catch {
            #expect(error.localizedDescription.contains("HTTP 503"))
            #expect(error.localizedDescription.contains("unavailable"))
            #expect(!error.localizedDescription.contains("do-not-leak"))
        }
    }

    @Test("Client-token response and rebind use deterministic expiration and fallback")
    func clientTokenAndRebind() async throws {
        let fixedDate = fixedDate
        let tokenFixture = try NetworkingFixture.data("auth-token.json")
        let transport = RecordingHTTPTransport { request, index in
            if request.url?.absoluteString == NVIDIAAuth.clientTokenEndpoint {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
                return StubbedHTTPResponse(json: #"{"client_token":"bound-token","expires_in":90}"#)
            }
            if index == 1 {
                return StubbedHTTPResponse(statusCode: 400, json: #"{"error":"invalid_client"}"#)
            }
            return StubbedHTTPResponse(data: tokenFixture)
        }
        let api = NVIDIAAuthAPI(transport: transport, now: { fixedDate })

        let clientToken = try await api.fetchClientToken(accessToken: "fixture-access")
        let rebound = try await api.refreshWithClientToken("bound-token", userId: "fixture-user")
        let requests = await transport.requests()

        #expect(clientToken.token == "bound-token")
        #expect(clientToken.expiresAt == fixedDate.addingTimeInterval(90))
        #expect(rebound.accessToken == "fixture-access-token")
        #expect(try formValues(from: requests[1])["client_id"] == NVIDIAAuth.clientID)
        #expect(try formValues(from: requests[2])["client_id"] == NVIDIAAuth.deviceFlowClientID)
    }

    @Test("OAuth failures redact response credentials")
    func responseSecretsAreRedacted() async throws {
        let body = """
        {"error":"invalid_grant","error_description":"Rejected","access_token":"do-not-leak","refresh_token":"also-secret"}
        """
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(statusCode: 400, json: body)
        }
        let api = NVIDIAAuthAPI(transport: transport)

        do {
            _ = try await api.exchangeCode("secret-code", verifier: "secret-verifier", redirectURI: "cloudnow://callback")
            Issue.record("Expected token exchange to fail")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("invalid_grant"))
            #expect(message.contains("Rejected"))
            #expect(!message.contains("do-not-leak"))
            #expect(!message.contains("also-secret"))
            #expect(message.contains("<redacted>"))
        }
    }

    @Test("Malformed success JSON reports decoding failure")
    func malformedTokenResponse() async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: #"{"expires_in":"not-a-number"}"#)
        }

        await #expect(throws: DecodingError.self) {
            _ = try await NVIDIAAuthAPI(transport: transport).exchangeCode(
                "code",
                verifier: "verifier",
                redirectURI: "cloudnow://callback"
            )
        }
    }

    @Test("Device polling handles slow-down without real sleeping")
    func devicePollingSlowDown() async throws {
        let fixture = try NetworkingFixture.data("auth-token.json")
        let delays = DelayRecorder()
        let transport = RecordingHTTPTransport { _, index in
            if index == 0 {
                return StubbedHTTPResponse(
                    statusCode: 400,
                    json: #"{"error":"slow_down","error_description":"Poll less often"}"#
                )
            }
            return StubbedHTTPResponse(data: fixture)
        }
        let fixedDate = fixedDate
        let api = NVIDIAAuthAPI(
            transport: transport,
            now: { fixedDate },
            sleep: { delay in await delays.record(delay) }
        )

        let tokens = try await api.pollForDeviceToken(deviceCode: "fixture-device", interval: 2, expiresIn: 30)

        #expect(tokens.accessToken == "fixture-access-token")
        #expect(await delays.values() == [2, 7])
    }

    @Test("Cancellation propagates without retry or error remapping")
    func cancellation() async {
        let transport = RecordingHTTPTransport { _, _ in
            try Task.checkCancellation()
            throw CancellationError()
        }
        let api = NVIDIAAuthAPI(transport: transport)
        let task = Task {
            try await api.requestDeviceAuthorization()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await transport.requests().count == 1)
    }
}

private actor DelayRecorder {
    private var recordedValues: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        recordedValues.append(value)
    }

    func values() -> [TimeInterval] {
        recordedValues
    }
}

struct FormEncodingCase: Sendable {
    let input: String
    let expected: String
}
