@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox Cloud session REST API")
struct XboxCloudSessionAPITests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Create sends the cloud play contract with redacted credentials")
    func createSession() async throws {
        let access = try makeAccessContext()
        let transport = RecordingHTTPTransport { request, index in
            #expect(index == 0)
            #expect(request.url?.absoluteString == "https://region.gssv-play-prod.xboxlive.com/v5/sessions/cloud/play")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-gs-secret")
            #expect(request.value(forHTTPHeaderField: "MS-CV") == "ABCDEFGHIJKLMNOPQRSTUV.0")
            #expect(request.value(forHTTPHeaderField: "x-xbl-market") == "US")

            let deviceHeader = try #require(request.value(forHTTPHeaderField: "X-MS-Device-Info"))
            let device = try #require(
                JSONSerialization.jsonObject(with: Data(deviceHeader.utf8)) as? [String: Any]
            )
            let appInfo = try #require(device["appInfo"] as? [String: Any])
            let environment = try #require(appInfo["env"] as? [String: Any])
            #expect(environment["clientAppId"] as? String == "CloudNowTests")
            #expect(environment["sdkInstallId"] as? String == "fixture-install-id")
            let dev = try #require(device["dev"] as? [String: Any])
            let hardware = try #require(dev["hw"] as? [String: Any])
            #expect(hardware["platformType"] as? String == "tvOS")

            let body = try jsonObject(from: request)
            #expect(body["titleId"] as? String == "123456789")
            #expect(body["systemUpdateGroup"] as? String == "flight-a")
            #expect(body["serverId"] as? String == "")
            #expect(body["clientSessionId"] as? String == "fixture-client-session")
            #expect(body["fallbackRegionNames"] as? [String] == ["West US", "North Europe"])
            let settings = try #require(body["settings"] as? [String: Any])
            #expect(settings["nanoVersion"] as? String == "V3;WebrtcTransport.dll")
            #expect(settings["locale"] as? String == "en-US")
            #expect(settings["timezoneOffsetMinutes"] as? Int == 120)
            #expect(settings["useIceConnection"] as? Bool == false)
            #expect(settings["sdkType"] as? String == "web")
            return StubbedHTTPResponse(json: Self.createResponseJSON)
        }
        let api = XboxCloudSessionAPI(
            access: access,
            transport: transport,
            correlationVectorBase: "ABCDEFGHIJKLMNOPQRSTUV"
        )

        let handle = try await api.createSession(makeLaunchRequest())

        #expect(!handle.description.contains("fixture-session"))
        #expect(!access.description.contains("fixture-gs-secret"))
        #expect(!access.description.contains("fixture-transfer-secret"))
    }

    @Test("Polling follows transfer URI, connects, and returns configuration")
    func provisionedLifecycle() async throws {
        let delays = XboxCloudDelayRecorder()
        let transferTokens = XboxTransferTokenRecorder(token: "fixture-transfer-secret")
        let access = try makeAccessContext {
            try await transferTokens.token()
        }
        let transport = RecordingHTTPTransport { request, index in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-gs-secret")
            #expect(request.value(forHTTPHeaderField: "MS-CV") == "ABCDEFGHIJKLMNOPQRSTUV.\(index)")
            switch index {
            case 0:
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            case 1:
                #expect(request.url?.absoluteString == "https://region.gssv-play-prod.xboxlive.com/v5/sessions/cloud/fixture-session/state")
                #expect(request.httpMethod == "GET")
                return StubbedHTTPResponse(
                    json: #"{"state":"ReadyToConnect","transferUri":"https://transfer.gssv-play-prod.xboxlive.com"}"#
                )
            case 2:
                #expect(request.url?.absoluteString == "https://transfer.gssv-play-prod.xboxlive.com/v5/sessions/cloud/fixture-session/connect")
                #expect(request.httpMethod == "POST")
                let body = try jsonObject(from: request)
                #expect(body["userToken"] as? String == "fixture-transfer-secret")
                return StubbedHTTPResponse(statusCode: 204)
            case 3:
                #expect(request.url?.host == "transfer.gssv-play-prod.xboxlive.com")
                return StubbedHTTPResponse(
                    json: #"{"state":"Provisioning","estimatedTotalWaitTimeInSeconds":18}"#,
                    headers: ["Retry-After": "2"]
                )
            case 4:
                return StubbedHTTPResponse(json: #"{"state":"Provisioned"}"#)
            case 5:
                #expect(request.url?.absoluteString == "https://transfer.gssv-play-prod.xboxlive.com/v5/sessions/cloud/fixture-session/configuration")
                return StubbedHTTPResponse(json: Self.configurationJSON)
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let api = XboxCloudSessionAPI(
            access: access,
            transport: transport,
            correlationVectorBase: "ABCDEFGHIJKLMNOPQRSTUV",
            sleep: { delay in await delays.record(delay) }
        )
        let states = XboxCloudStateRecorder()
        let handle = try await api.createSession(makeLaunchRequest())

        let provisioned = try await api.pollUntilProvisioned(handle) { state in
            await states.record(state)
        }
        let signaling = try await api.signalingContext(for: handle)

        #expect(provisioned.configuration.keepAlivePulse == 15)
        #expect(provisioned.configuration.serverDetails.ipV4Address == "203.0.113.7")
        #expect(provisioned.configuration.serverDetails.ipV4Port == 9002)
        #expect(provisioned.configuration.clientStreamingConfigOverrides == .object([
            "videoConfiguration": .object(["enableHevc": .boolean(true)]),
        ]))
        #expect(!provisioned.configuration.description.contains("fixture-srtp-secret"))
        #expect(signaling.endpointBaseURL.host == "transfer.gssv-play-prod.xboxlive.com")
        #expect(signaling.sessionPath == "v5/sessions/cloud/fixture-session")
        #expect(signaling.correlationVector == "ABCDEFGHIJKLMNOPQRSTUV.6")
        #expect(!signaling.description.contains("fixture-gs-secret"))
        #expect(!signaling.description.contains("fixture-session"))
        #expect(await transferTokens.requestCount() == 1)
        #expect(await delays.values() == [2])
        #expect(await states.values().map(\.state) == [
            .readyToConnect,
            .provisioning,
            .provisioned,
        ])
    }

    @Test("Retry-After controls polling and is bounded by policy")
    func retryAfterIsBounded() async throws {
        let delays = XboxCloudDelayRecorder()
        let policy = try XboxCloudSessionPollingPolicy(
            queueInterval: 1,
            provisioningInterval: 1,
            maximumRetryAfter: 5,
            maximumElapsedTime: 60,
            maximumStateRequests: 4
        )
        let transport = RecordingHTTPTransport { _, index in
            switch index {
            case 0: StubbedHTTPResponse(json: Self.createResponseJSON)
            case 1:
                StubbedHTTPResponse(
                    json: #"{"state":"WaitingForResources"}"#,
                    headers: ["Retry-After": "120"]
                )
            case 2: StubbedHTTPResponse(json: #"{"state":"Provisioned"}"#)
            case 3: StubbedHTTPResponse(json: Self.configurationJSON)
            default: throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport,
            pollingPolicy: policy,
            sleep: { delay in await delays.record(delay) }
        )
        let handle = try await api.createSession(makeLaunchRequest())

        _ = try await api.pollUntilProvisioned(handle)

        #expect(await delays.values() == [5])
    }

    @Test("Polling stops at its request bound without an extra delay")
    func pollingIsBounded() async throws {
        let delays = XboxCloudDelayRecorder()
        let policy = try XboxCloudSessionPollingPolicy(
            queueInterval: 1,
            provisioningInterval: 1,
            maximumRetryAfter: 5,
            maximumElapsedTime: 60,
            maximumStateRequests: 2
        )
        let transport = RecordingHTTPTransport { _, index in
            if index == 0 {
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            }
            return StubbedHTTPResponse(json: #"{"state":"WaitingForResources"}"#)
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport,
            pollingPolicy: policy,
            sleep: { delay in await delays.record(delay) }
        )
        let handle = try await api.createSession(makeLaunchRequest())

        await #expect(throws: XboxCloudSessionAPIError.pollingTimedOut(maximumStateRequests: 2)) {
            _ = try await api.pollUntilProvisioned(handle)
        }

        #expect(await transport.requests().count == 3)
        #expect(await delays.values() == [1])
    }

    @Test("Cancellation propagates out of the polling delay")
    func pollingCancellation() async throws {
        let transport = RecordingHTTPTransport { _, index in
            index == 0
                ? StubbedHTTPResponse(json: Self.createResponseJSON)
                : StubbedHTTPResponse(json: #"{"state":"WaitingForResources"}"#)
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport,
            sleep: { _ in throw CancellationError() }
        )
        let handle = try await api.createSession(makeLaunchRequest())

        await #expect(throws: CancellationError.self) {
            _ = try await api.pollUntilProvisioned(handle)
        }

        #expect(await transport.requests().count == 2)
    }

    @Test("Keepalive and delete use the transferred session endpoint")
    func keepAliveAndDelete() async throws {
        let transport = RecordingHTTPTransport { request, index in
            switch index {
            case 0:
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            case 1:
                return StubbedHTTPResponse(
                    json: #"{"state":"Provisioning","transferUri":"transfer.gssv-play-prod.xboxlive.com"}"#
                )
            case 2:
                #expect(request.httpMethod == "POST")
                #expect(request.url?.absoluteString == "https://transfer.gssv-play-prod.xboxlive.com/v5/sessions/cloud/fixture-session/keepalive")
                return StubbedHTTPResponse(json: #"{"token":"receipt-secret","accepted":true}"#)
            case 3:
                #expect(request.httpMethod == "DELETE")
                #expect(request.url?.absoluteString == "https://transfer.gssv-play-prod.xboxlive.com/v5/sessions/cloud/fixture-session")
                return StubbedHTTPResponse(statusCode: 204)
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let api = try XboxCloudSessionAPI(access: makeAccessContext(), transport: transport)
        let handle = try await api.createSession(makeLaunchRequest())
        _ = try await api.state(for: handle)

        let receipt = try await api.keepAlive(handle)
        try await api.delete(handle)

        #expect(!receipt.description.contains("receipt-secret"))
        await #expect(throws: XboxCloudSessionAPIError.unknownSession) {
            _ = try await api.keepAlive(handle)
        }
        #expect(await transport.requests().count == 4)
    }

    @Test("HTTP failures preserve safe service codes and redact response tokens")
    func errorsAreRedacted() async throws {
        let access = try makeAccessContext()
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                statusCode: 403,
                json: #"{"code":"NoEntitlement","message":"fixture-gs-secret fixture-transfer-secret","token":"response-secret"}"#
            )
        }
        let api = XboxCloudSessionAPI(access: access, transport: transport)

        do {
            _ = try await api.createSession(makeLaunchRequest())
            Issue.record("Expected create to fail")
        } catch {
            #expect((error as? XboxCloudSessionAPIError) == .httpFailure(
                operation: .create,
                statusCode: 403,
                serviceCode: "NoEntitlement"
            ))
            #expect(error.localizedDescription.contains("NoEntitlement"))
            #expect(!error.localizedDescription.contains("fixture-gs-secret"))
            #expect(!error.localizedDescription.contains("fixture-transfer-secret"))
            #expect(!error.localizedDescription.contains("response-secret"))
        }
    }

    @Test("State rejects an insecure transfer endpoint")
    func rejectsInsecureTransferEndpoint() async throws {
        let transport = RecordingHTTPTransport { _, index in
            if index == 0 {
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            }
            return StubbedHTTPResponse(
                json: #"{"state":"ReadyToConnect","transferUri":"http://untrusted.example"}"#
            )
        }
        let api = try XboxCloudSessionAPI(access: makeAccessContext(), transport: transport)
        let handle = try await api.createSession(makeLaunchRequest())

        await #expect(throws: XboxCloudSessionAPIError.invalidPayload(operation: .state)) {
            _ = try await api.state(for: handle)
        }
    }

    @Test("Failed provisioning returns a sanitized service code")
    func failedProvisioning() async throws {
        let transport = RecordingHTTPTransport { _, index in
            if index == 0 {
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            }
            return StubbedHTTPResponse(
                json: #"{"state":"Failed","errorDetails":{"code":"BlockedByParentalControls","message":"token-secret"}}"#
            )
        }
        let api = try XboxCloudSessionAPI(access: makeAccessContext(), transport: transport)
        let handle = try await api.createSession(makeLaunchRequest())

        await #expect(throws: XboxCloudSessionAPIError.sessionFailed(serviceCode: "BlockedByParentalControls")) {
            _ = try await api.pollUntilProvisioned(handle)
        }
    }

    private func makeAccessContext(
        transferToken: @escaping @Sendable () async throws -> String = { "fixture-transfer-secret" }
    ) throws -> XboxCloudSessionAccessContext {
        try XboxCloudSessionAccessContext(
            gsToken: "fixture-gs-secret",
            regionBaseURL: URL(string: "https://region.gssv-play-prod.xboxlive.com")!,
            market: "US",
            fallbackRegionNames: ["West US", "North Europe", "West US"],
            systemUpdateGroups: ["", "flight-a", "flight-b"],
            deviceInformation: XboxCloudDeviceInformation(
                clientAppID: "CloudNowTests",
                clientAppType: "native",
                clientAppVersion: "1.0",
                clientSDKVersion: "1.0",
                sdkInstallID: "fixture-install-id",
                make: "Apple",
                model: "Apple TV",
                platformType: "tvOS",
                sdkType: "native",
                operatingSystemName: "tvOS",
                operatingSystemVersion: "26.0",
                displayWidthInPixels: 1920,
                displayHeightInPixels: 1080,
                pixelDensity: 1
            ),
            msaTransferToken: transferToken
        )
    }

    private func makeLaunchRequest() throws -> XboxCloudSessionLaunchRequest {
        try XboxCloudSessionLaunchRequest(
            titleID: "123456789",
            preferredSystemUpdateGroup: "flight-a",
            clientSessionID: "fixture-client-session",
            settings: XboxCloudSessionLaunchSettings(
                locale: "en-US",
                timezoneOffsetMinutes: 120
            )
        )
    }

    private static let createResponseJSON = #"{"sessionPath":"v5/sessions/cloud/fixture-session"}"#

    private static let configurationJSON = #"{"serverDetails":{"ipV4Address":"203.0.113.7","ipV4Port":9002,"ipV6Address":"[2001:db8::7]","ipV6Port":9002,"srtp":{"key":"fixture-srtp-secret"},"uriPathAndQuery":"/stream","stunServerAddresses":["stun.example.test:3478"]},"keepAlivePulseInSeconds":15,"clientStreamingConfigOverrides":"{\"videoConfiguration\":{\"enableHevc\":true}}"}"#
}

private actor XboxCloudDelayRecorder {
    private var recordedValues: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        recordedValues.append(value)
    }

    func values() -> [TimeInterval] {
        recordedValues
    }
}

private actor XboxCloudStateRecorder {
    private var recordedValues: [XboxCloudSessionStateSnapshot] = []

    func record(_ value: XboxCloudSessionStateSnapshot) {
        recordedValues.append(value)
    }

    func values() -> [XboxCloudSessionStateSnapshot] {
        recordedValues
    }
}

private actor XboxTransferTokenRecorder {
    private let value: String
    private var count = 0

    init(token: String) {
        value = token
    }

    func token() throws -> String {
        count += 1
        return value
    }

    func requestCount() -> Int {
        count
    }
}
