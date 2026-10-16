@testable import CloudNow
import Foundation
import Testing

@Suite("GFN store account connection client")
struct StoreConnectionClientTests {
    @Test("Device authorization sends the PC ALS identity and only uses the complete URI for QR")
    func authorizationRequest() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.url?.absoluteString == "https://als.geforcenow.com/v1/login_url")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer nvidia-token")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let body = try jsonObject(from: request)
            #expect(body["platform"] as? String == "STEAM")
            #expect(body["client_id"] as? String == "gfn-pc")
            #expect(body.count == 2)
            return StubbedHTTPResponse(json: authorizationResponse)
        }
        let authorization = try await GFNStoreConnectionClient(transport: transport)
            .requestAuthorization(providerCode: " steam ", token: "nvidia-token")

        #expect(authorization.deviceCode == "private-device-code")
        #expect(authorization.userCode == "ABCD-EFGH")
        #expect(authorization.verificationURL.absoluteString == "https://gfn.link/connect")
        #expect(authorization.verificationURLComplete.absoluteString == "https://login.nvidia.com/connect?user_code=ABCD-EFGH")
        #expect(!authorization.verificationURLComplete.absoluteString.contains(authorization.deviceCode))
        #expect(!authorization.verificationURLComplete.absoluteString.contains("nvidia-token"))
        #expect(authorization.expiresIn == 600)
        #expect(authorization.interval == 5)
    }

    @Test("Account-link polling sends no NVIDIA bearer token and does not expose returned tokens")
    func pollAuthorizationRequest() async throws {
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.url?.absoluteString == "https://als.geforcenow.com/v1/token")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = try jsonObject(from: request)
            #expect(body["client_id"] as? String == "gfn-pc")
            #expect(body["device_code"] as? String == "private-device-code")
            #expect(body.count == 2)
            return StubbedHTTPResponse(json: #"{"platform":"STEAM","access_token":"must-not-escape"}"#)
        }
        let status = try await GFNStoreConnectionClient(transport: transport)
            .pollAuthorization(deviceCode: "private-device-code")
        #expect(status == .authorized)
    }

    @Test("ALS device polling recognizes pending and slowdown responses", arguments: ["authorization_pending", "slow_down"])
    func pendingAuthorization(errorCode: String) async throws {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(statusCode: 400, json: """
            {"error":"\(errorCode)","error_description":"private details"}
            """)
        }
        let status = try await GFNStoreConnectionClient(transport: transport)
            .pollAuthorization(deviceCode: "device")
        #expect(status == (errorCode == "authorization_pending" ? .pending : .slowDown))
    }

    @Test("ALS polling rejects denied and expired authorizations", arguments: ["access_denied", "expired_token", "invalid_grant"])
    func terminalAuthorization(errorCode: String) async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(statusCode: 400, json: """
            {"error":"\(errorCode)","error_description":"private details"}
            """)
        }
        let client = GFNStoreConnectionClient(transport: transport)
        let expected: StoreConnectionError = errorCode == "access_denied" ? .denied : .expired
        await #expect(throws: expected) {
            _ = try await client.pollAuthorization(deviceCode: "device")
        }
    }

    @Test("Malformed device authorization and unsafe verification URLs fail closed", arguments: [
        StoreAuthorizationMutation(field: "device_code", value: ""),
        StoreAuthorizationMutation(field: "user_code", value: " "),
        StoreAuthorizationMutation(field: "expires_in", value: 0),
        StoreAuthorizationMutation(field: "expires_in", value: 3601),
        StoreAuthorizationMutation(field: "interval", value: 0),
        StoreAuthorizationMutation(field: "interval", value: 61),
        StoreAuthorizationMutation(field: "verification_uri_complete", value: "http://login.nvidia.com/connect"),
        StoreAuthorizationMutation(field: "verification_uri_complete", value: "https://nvidia.com.evil.example/connect"),
        StoreAuthorizationMutation(field: "verification_uri_complete", value: "https://private@login.nvidia.com/connect"),
        StoreAuthorizationMutation(field: "verification_uri_complete", value: "https://login.nvidia.com:8443/connect"),
        StoreAuthorizationMutation(field: "verification_uri_complete", value: "https://login.nvidia.com/connect?access_token=secret"),
        StoreAuthorizationMutation(field: "verification_uri_complete", value: "https://login.nvidia.com/connect#access_token=secret"),
        StoreAuthorizationMutation(field: "verification_uri_complete", value: "https://login.nvidia.com/connect?code=private-device-code"),
        StoreAuthorizationMutation(field: "verification_uri", value: "file:///tmp/connect"),
    ])
    func invalidAuthorization(mutation: StoreAuthorizationMutation) async throws {
        let data = try mutation.applying(to: authorizationResponse)
        let transport = RecordingHTTPTransport { _, _ in StubbedHTTPResponse(data: data) }
        let client = GFNStoreConnectionClient(transport: transport)
        await #expect(throws: StoreConnectionError.schema) {
            _ = try await client.requestAuthorization(providerCode: "STEAM", token: "token")
        }
    }

    @Test("Disconnect uses the encoded platform code with NVIDIA authentication", arguments: [200, 204])
    func disconnectRequest(statusCode: Int) async throws {
        let transport = RecordingHTTPTransport { request, _ in
            let url = try #require(request.url)
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
            #expect(path == "/v1/linking/XBOX%2FGAME%20PASS")
            #expect(request.httpMethod == "DELETE")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer nvidia-token")
            #expect(try jsonObject(from: request).isEmpty)
            return StubbedHTTPResponse(statusCode: statusCode)
        }
        try await GFNStoreConnectionClient(transport: transport)
            .disconnect(providerCode: "Xbox/Game Pass", token: "nvidia-token")
    }

    @Test("HTTP errors never become connection success", arguments: [
        StoreConnectionHTTPFailure(statusCode: 401, expected: .unauthorized),
        StoreConnectionHTTPFailure(statusCode: 403, expected: .forbidden),
        StoreConnectionHTTPFailure(statusCode: 404, expected: .schema),
        StoreConnectionHTTPFailure(statusCode: 405, expected: .schema),
        StoreConnectionHTTPFailure(statusCode: 410, expected: .schema),
        StoreConnectionHTTPFailure(statusCode: 429, expected: .rateLimited(retryAfter: 30)),
        StoreConnectionHTTPFailure(statusCode: 500, expected: .httpStatus(500)),
    ])
    func httpErrors(fixture: StoreConnectionHTTPFailure) async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                statusCode: fixture.statusCode,
                json: #"{"error":"private-server-response"}"#,
                headers: ["Retry-After": "30"]
            )
        }
        let client = GFNStoreConnectionClient(transport: transport)
        await #expect(throws: fixture.expected) {
            try await client.disconnect(providerCode: "STEAM", token: "token")
        }
        await #expect(throws: fixture.expected) {
            _ = try await client.pollAuthorization(deviceCode: "device")
        }
    }

    @Test("Unexpected OAuth error payloads fail without exposing server messages", arguments: [
        #"{"error":"unknown_error","error_description":"private-token"}"#,
        #"{"error":{"error":"authorization_pending"}}"#,
        "not-json",
    ])
    func unexpectedAuthorizationFailure(payload: String) async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(statusCode: 400, json: payload)
        }
        let client = GFNStoreConnectionClient(transport: transport)
        await #expect(throws: StoreConnectionError.httpStatus(400)) {
            _ = try await client.pollAuthorization(deviceCode: "device")
        }
    }

    @Test("Mutating transport failures remain ambiguous and polling failures remain retryable")
    func networkFailures() async {
        let transport = RecordingHTTPTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let client = GFNStoreConnectionClient(transport: transport)
        await #expect(throws: StoreConnectionError.networkAmbiguous) {
            _ = try await client.requestAuthorization(providerCode: "STEAM", token: "token")
        }
        await #expect(throws: StoreConnectionError.networkAmbiguous) {
            try await client.disconnect(providerCode: "STEAM", token: "token")
        }
        await #expect(throws: StoreConnectionError.network) {
            _ = try await client.pollAuthorization(deviceCode: "device")
        }
    }

    @Test("Transport cancellation is preserved", arguments: [false, true])
    func cancellation(urlCancellation: Bool) async {
        let transport = RecordingHTTPTransport { _, _ in
            if urlCancellation {
                throw URLError(.cancelled)
            }
            throw CancellationError()
        }
        let client = GFNStoreConnectionClient(transport: transport)
        await #expect(throws: CancellationError.self) {
            _ = try await client.requestAuthorization(providerCode: "STEAM", token: "token")
        }
        await #expect(throws: CancellationError.self) {
            _ = try await client.pollAuthorization(deviceCode: "device")
        }
        await #expect(throws: CancellationError.self) {
            try await client.disconnect(providerCode: "STEAM", token: "token")
        }
    }

    @Test("Empty provider codes never issue a mutation")
    func invalidProviderCode() async {
        let transport = RecordingHTTPTransport { _, _ in throw TestTransportError.unexpectedRequest("must not send") }
        let client = GFNStoreConnectionClient(transport: transport)
        await #expect(throws: StoreConnectionError.schema) {
            _ = try await client.requestAuthorization(providerCode: " ", token: "token")
        }
        await #expect(throws: StoreConnectionError.schema) {
            try await client.disconnect(providerCode: "", token: "token")
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test("Device responses are bounded before decoding")
    func responseSizeLimit() async {
        let transport = BoundedRecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Data(repeating: 65, count: 65537))
        }
        let client = GFNStoreConnectionClient(transport: transport)
        await #expect(throws: StoreConnectionError.schema) {
            _ = try await client.requestAuthorization(providerCode: "STEAM", token: "token")
        }
        #expect(await transport.unboundedRequestCount() == 0)
        #expect(await transport.maximumResponseSizes() == [65536])
    }
}

nonisolated struct StoreConnectionHTTPFailure: Sendable {
    let statusCode: Int
    let expected: StoreConnectionError
}

nonisolated struct StoreAuthorizationMutation: Sendable {
    let field: String
    private let stringValue: String?
    private let numberValue: Int?

    init(field: String, value: String) {
        self.field = field
        stringValue = value
        numberValue = nil
    }

    init(field: String, value: Int) {
        self.field = field
        stringValue = nil
        numberValue = value
    }

    func applying(to json: String) throws -> Data {
        var dictionary = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        dictionary[field] = stringValue.map { $0 as Any } ?? numberValue.map { $0 as Any }
        return try JSONSerialization.data(withJSONObject: dictionary)
    }
}

private let authorizationResponse = """
{
  "device_code": "private-device-code",
  "user_code": "ABCD-EFGH",
  "verification_uri_complete": "https://login.nvidia.com/connect?user_code=ABCD-EFGH",
  "expires_in": 600,
  "interval": 5
}
"""
