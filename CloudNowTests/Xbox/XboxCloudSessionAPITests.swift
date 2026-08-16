@testable import CloudNow
import Foundation
import Synchronization
import Testing

@Suite("Xbox Cloud session REST API")
struct XboxCloudSessionAPITests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Device information keeps physical output metadata")
    func physicalDisplayMetadata() {
        let information = XboxCloudDeviceInformation.cloudNowTV(
            sdkInstallID: "fixture-install-id",
            displayWidthInPixels: 3840,
            displayHeightInPixels: 2160,
            pixelDensity: 2
        )

        #expect(information.displayWidthInPixels == 3840)
        #expect(information.displayHeightInPixels == 2160)
        #expect(information.pixelDensity == 2)
        #expect(information.clientAppType == "browser")
        #expect(information.clientAppVersion == "29.19.17")
        #expect(information.clientSDKVersion == "10.6.57")
        #expect(information.platformType == "smarttv")
        #expect(information.sdkType == "web")
    }

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
            #expect(request.value(forHTTPHeaderField: "X-GSSV-Routing") == "AFD")

            let deviceHeader = try #require(request.value(forHTTPHeaderField: "X-MS-Device-Info"))
            let device = try #require(
                JSONSerialization.jsonObject(with: Data(deviceHeader.utf8)) as? [String: Any]
            )
            let appInfo = try #require(device["appInfo"] as? [String: Any])
            let environment = try #require(appInfo["env"] as? [String: Any])
            #expect(Set(environment.keys) == [
                "clientAppId",
                "clientAppType",
                "clientAppVersion",
                "clientSdkVersion",
                "httpEnvironment",
                "sdkInstallId",
            ])
            #expect(environment["clientAppId"] as? String == "www.xbox.com")
            #expect(environment["sdkInstallId"] as? String == "fixture-install-id")
            let dev = try #require(device["dev"] as? [String: Any])
            let displayInfo = try #require(dev["displayInfo"] as? [String: Any])
            let dimensions = try #require(
                displayInfo["dimensions"] as? [String: Any]
            )
            #expect(dimensions["widthInPixels"] as? Int == 3024)
            #expect(dimensions["heightInPixels"] as? Int == 1964)
            let hardware = try #require(dev["hw"] as? [String: Any])
            #expect(hardware["platformType"] as? String == "desktop")

            let body = try jsonObject(from: request)
            #expect(body["titleId"] as? String == "123456789")
            #expect(body["systemUpdateGroup"] as? String == "")
            #expect(body["serverId"] as? String == "")
            #expect(body["clientSessionId"] as? String == "abcdef0123456789abcdef")
            #expect(body["fallbackRegionNames"] as? [String] == [])
            let settings = try #require(body["settings"] as? [String: Any])
            #expect(settings["nanoVersion"] as? String == "V3;WebrtcTransport.dll")
            #expect(settings["locale"] as? String == "en-US")
            #expect(settings["timezoneOffsetMinutes"] as? Int == 120)
            #expect(settings["useIceConnection"] as? Bool == false)
            #expect(settings["sdkType"] as? String == "web")
            #expect(settings["osName"] as? String == "macOS")
            #expect(settings["magnifier"] == nil)
            #expect(settings["enableOptionalDataCollection"] == nil)
            return StubbedHTTPResponse(json: Self.createResponseJSON)
        }
        let api = XboxCloudSessionAPI(
            access: access,
            transport: transport,
            correlationVectorBase: "ABCDEFGHIJKLMNOPQRSTUV",
            clientSessionIDGenerator: { "abcdef0123456789abcdef" }
        )

        let handle = try await api.createSession(makeLaunchRequest())

        #expect(!handle.description.contains("fixture-session"))
        #expect(!access.description.contains("fixture-gs-secret"))
        #expect(!access.description.contains("fixture-transfer-secret"))
    }

    @Test("Microsoft web production sends the exact safe device and launch envelope")
    func microsoftWebCreateSession() async throws {
        let access = try makeAccessContext(profile: .microsoftWeb)
        let transport = RecordingHTTPTransport { request, index in
            #expect(index == 0)
            #expect(
                request.url?.absoluteString
                    == "https://region.gssv-play-prod.xboxlive.com/v5/sessions/cloud/play"
            )
            #expect(request.httpMethod == "POST")
            let headers = Dictionary(uniqueKeysWithValues:
                (request.allHTTPHeaderFields ?? [:]).map {
                    ($0.key.lowercased(), $0.value)
                })
            #expect(Set(headers.keys) == [
                "accept",
                "authorization",
                "content-type",
                "ms-cv",
                "user-agent",
                "x-gssv-routing",
                "x-ms-device-info",
                "x-xbl-market",
            ])
            #expect(headers["accept"] == "application/json")
            #expect(headers["authorization"] == "Bearer fixture-gs-secret")
            #expect(headers["content-type"] == "application/json; charset=utf-8")
            #expect(headers["ms-cv"] == "ABCDEFGHIJKLMNOPQRSTUV.0")
            #expect(headers["x-gssv-routing"] == "AFD")
            #expect(headers["x-xbl-market"] == "US")
            #expect(
                headers["user-agent"]
                    == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
            )

            let deviceHeader = try #require(
                request.value(forHTTPHeaderField: "X-MS-Device-Info")
            )
            let device = try #require(
                JSONSerialization.jsonObject(
                    with: Data(deviceHeader.utf8)
                ) as? [String: Any]
            )
            #expect(Set(device.keys) == ["appInfo", "dev"])
            let appInfo = try #require(device["appInfo"] as? [String: Any])
            let environment = try #require(appInfo["env"] as? [String: Any])
            #expect(Set(environment.keys) == [
                "clientAppId",
                "clientAppType",
                "clientAppVersion",
                "clientSdkVersion",
                "httpEnvironment",
                "sdkInstallId",
            ])
            #expect(environment["clientAppId"] as? String == "www.xbox.com")
            #expect(environment["clientAppType"] as? String == "browser")
            #expect(environment["clientAppVersion"] as? String == "29.19.17")
            #expect(environment["clientSdkVersion"] as? String == "10.6.57")
            #expect(environment["httpEnvironment"] as? String == "prod")
            #expect(environment["sdkInstallId"] as? String == "fixture-install-id")

            let dev = try #require(device["dev"] as? [String: Any])
            #expect(Set(dev.keys) == ["browser", "displayInfo", "hw", "os"])
            let displayInfo = try #require(dev["displayInfo"] as? [String: Any])
            let dimensions = try #require(
                displayInfo["dimensions"] as? [String: Any]
            )
            let density = try #require(
                displayInfo["pixelDensity"] as? [String: Any]
            )
            #expect(dimensions["widthInPixels"] as? Int == 3024)
            #expect(dimensions["heightInPixels"] as? Int == 1964)
            #expect(density["dpiX"] as? Double == 1)
            #expect(density["dpiY"] as? Double == 1)
            let browser = try #require(dev["browser"] as? [String: Any])
            #expect(browser["browserName"] as? String == "chrome")
            #expect(browser["browserVersion"] as? String == "148.0.0.0")
            let hardware = try #require(dev["hw"] as? [String: Any])
            #expect(hardware["make"] as? String == "Apple")
            #expect(hardware["model"] as? String == "unknown")
            #expect(hardware["platformType"] as? String == "desktop")
            #expect(hardware["sdkType"] as? String == "web")
            let operatingSystem = try #require(dev["os"] as? [String: Any])
            #expect(operatingSystem["name"] as? String == "macOS")
            #expect(operatingSystem["ver"] as? String == "10.15.7")
            #expect(operatingSystem["platform"] as? String == "desktop")

            let body = try jsonObject(from: request)
            #expect(Set(body.keys) == [
                "clientSessionId",
                "fallbackRegionNames",
                "serverId",
                "settings",
                "systemUpdateGroup",
                "titleId",
            ])
            #expect(body["clientSessionId"] as? String == "abcdef0123456789abcdef")
            #expect(body["fallbackRegionNames"] as? [String] == [])
            #expect(body["systemUpdateGroup"] as? String == "")
            #expect(body["serverId"] as? String == "")
            #expect(body["titleId"] as? String == "123456789")
            let settings = try #require(body["settings"] as? [String: Any])
            #expect(Set(settings.keys) == [
                "enableTextToSpeech",
                "highContrast",
                "locale",
                "nanoVersion",
                "osName",
                "sdkType",
                "timezoneOffsetMinutes",
                "useIceConnection",
            ])
            #expect(settings["nanoVersion"] as? String == "V3;WebrtcTransport.dll")
            #expect(settings["enableTextToSpeech"] as? Bool == false)
            #expect(settings["highContrast"] as? Int == 0)
            #expect(settings["locale"] as? String == "en-US")
            #expect(settings["useIceConnection"] as? Bool == false)
            #expect(settings["timezoneOffsetMinutes"] as? Int == 120)
            #expect(settings["sdkType"] as? String == "web")
            #expect(settings["osName"] as? String == "macOS")
            return StubbedHTTPResponse(json: Self.createResponseJSON)
        }
        let api = XboxCloudSessionAPI(
            access: access,
            transport: transport,
            correlationVectorBase: "ABCDEFGHIJKLMNOPQRSTUV",
            clientSessionIDGenerator: { "abcdef0123456789abcdef" }
        )

        _ = try await api.createSession(makeLaunchRequest())
    }

    @Test("Microsoft web production preserves an enabled magnifier request")
    func microsoftWebMagnifier() async throws {
        let transport = RecordingHTTPTransport { request, index in
            #expect(index == 0)
            let body = try jsonObject(from: request)
            let settings = try #require(body["settings"] as? [String: Any])
            #expect(settings["magnifier"] as? Bool == true)
            return StubbedHTTPResponse(json: Self.createResponseJSON)
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(profile: .microsoftWeb),
            transport: transport,
            clientSessionIDGenerator: { "abcdef0123456789abcdef" }
        )

        _ = try await api.createSession(makeLaunchRequest(magnifier: true))
    }

    @Test("Microsoft web production rejects an invalid generated session identifier")
    func invalidGeneratedClientSessionID() async throws {
        let transport = RecordingHTTPTransport { _, index in
            throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(profile: .microsoftWeb),
            transport: transport,
            clientSessionIDGenerator: { "INVALID-SESSION-ID" }
        )

        await #expect(
            throws: XboxCloudSessionAPIError.invalidLaunchRequest(
                "Xbox Cloud generated an invalid client session identifier."
            )
        ) {
            _ = try await api.createSession(makeLaunchRequest())
        }
    }

    @Test("Every session response uses the streaming size boundary")
    func responsesAreBoundedBeforeBuffering() async throws {
        let transport = BoundedRecordingHTTPTransport { _, index in
            switch index {
            case 0:
                StubbedHTTPResponse(json: Self.createResponseJSON)
            case 1:
                StubbedHTTPResponse(json: #"{"state":"Provisioned"}"#)
            case 2:
                StubbedHTTPResponse(json: Self.configurationJSON)
            case 3:
                StubbedHTTPResponse(json: #"{"accepted":true}"#)
            case 4:
                StubbedHTTPResponse(statusCode: 204)
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport
        )

        let handle = try await api.createSession(makeLaunchRequest())
        _ = try await api.pollUntilProvisioned(handle)
        _ = try await api.keepAlive(handle)
        try await api.delete(handle)

        #expect(await transport.unboundedRequestCount() == 0)
        #expect(await transport.maximumResponseSizes() == Array(
            repeating: 2 * 1024 * 1024,
            count: 5
        ))
    }

    @Test("Oversized session responses preserve a specific bounded error")
    func oversizedResponse() async throws {
        let transport = BoundedRecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(data: Data(repeating: 0, count: 2 * 1024 * 1024 + 1))
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport
        )

        await #expect(throws: XboxCloudSessionAPIError.responseTooLarge(operation: .create)) {
            _ = try await api.createSession(makeLaunchRequest())
        }
    }

    @Test("Lifecycle rejects a concurrent second allocation while the first is in flight")
    func lifecycleEnforcesOneSession() async throws {
        let entered = XboxCloudSessionGate()
        let release = XboxCloudSessionGate()
        let transport = RecordingHTTPTransport { _, index in
            switch index {
            case 0:
                await entered.signal()
                await release.wait()
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            case 1:
                return StubbedHTTPResponse(statusCode: 204)
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport
        )
        let lifecycle = XboxCloudSessionLifecycleClient(api: api)
        let request = try makeLaunchRequest()
        let first = Task {
            try await lifecycle.createSession(request)
        }
        await entered.wait()

        await #expect(throws: XboxCloudStreamLifecycleError.sessionAlreadyActive) {
            _ = try await lifecycle.createSession(request)
        }
        await release.signal()
        let token = try await first.value
        #expect(await lifecycle.delete(token))

        #expect(await transport.requests().count == 2)
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
            #expect(request.value(forHTTPHeaderField: "X-GSSV-Routing") == "AFD")
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
        #expect(
            XboxCloudServiceStreamingOverrides(
                provisioned.configuration.clientStreamingConfigOverrides
            ).enableHEVC == true
        )
        #expect(!provisioned.configuration.description.contains("fixture-srtp-secret"))
        #expect(signaling.endpointBaseURL.host == "transfer.gssv-play-prod.xboxlive.com")
        #expect(signaling.sessionPath == "v5/sessions/cloud/fixture-session")
        #expect(signaling.correlationVector == "ABCDEFGHIJKLMNOPQRSTUV.6.0")
        #expect(signaling.routingHeader == "AFD")
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

    @Test("A repeated ready-to-connect state is paced without reconnecting")
    func repeatedReadyToConnectIsPaced() async throws {
        let delays = XboxCloudDelayRecorder()
        let transferTokens = XboxTransferTokenRecorder(token: "fixture-transfer-secret")
        let access = try makeAccessContext {
            try await transferTokens.token()
        }
        let policy = try XboxCloudSessionPollingPolicy(
            queueInterval: 1,
            provisioningInterval: 1,
            maximumRetryAfter: 5,
            maximumElapsedTime: 60,
            maximumStateRequests: 6
        )
        let transport = RecordingHTTPTransport { _, index in
            switch index {
            case 0:
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            case 1, 3:
                return StubbedHTTPResponse(
                    json: #"{"state":"ReadyToConnect","transferUri":"https://transfer.gssv-play-prod.xboxlive.com"}"#
                )
            case 2:
                return StubbedHTTPResponse(statusCode: 204)
            case 4:
                return StubbedHTTPResponse(json: #"{"state":"Provisioned"}"#)
            case 5:
                return StubbedHTTPResponse(json: Self.configurationJSON)
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let api = XboxCloudSessionAPI(
            access: access,
            transport: transport,
            pollingPolicy: policy,
            sleep: { delay in await delays.record(delay) }
        )
        let handle = try await api.createSession(makeLaunchRequest())

        _ = try await api.pollUntilProvisioned(handle)

        #expect(await transferTokens.requestCount() == 1)
        #expect(await delays.values() == [1])
        #expect(await transport.requests().count == 6)
    }

    @Test("Signaling extends a reserved vector while lifecycle HTTP advances its root")
    func correlationVectorBranches() async throws {
        let transport = RecordingHTTPTransport { request, index in
            switch index {
            case 0:
                #expect(request.value(forHTTPHeaderField: "MS-CV") == "ABCDEFGHIJKLMNOPQRSTUV.0")
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            case 1:
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "MS-CV") == "ABCDEFGHIJKLMNOPQRSTUV.2")
                return StubbedHTTPResponse(json: #"{"accepted":true}"#)
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport,
            correlationVectorBase: "ABCDEFGHIJKLMNOPQRSTUV"
        )
        let handle = try await api.createSession(makeLaunchRequest())

        let signaling = try await api.signalingContext(for: handle)
        _ = try await api.keepAlive(handle)

        #expect(signaling.correlationVector == "ABCDEFGHIJKLMNOPQRSTUV.1.0")
        #expect(await transport.requests().count == 2)
    }

    @Test("Capacity polling uses Microsoft's ten-second phase cadence instead of Retry-After")
    func capacityPollingUsesConfiguredPhaseCadence() async throws {
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

        #expect(await delays.values() == [1])
    }

    @Test("Provisioning stops at its request bound without an extra delay")
    func provisioningIsBounded() async throws {
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
            return StubbedHTTPResponse(json: #"{"state":"Provisioning"}"#)
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

    @Test("A valid capacity queue does not consume the provisioning request budget")
    func capacityQueueDoesNotConsumeProvisioningBudget() async throws {
        let delays = XboxCloudDelayRecorder()
        let policy = try XboxCloudSessionPollingPolicy(
            queueInterval: 1,
            provisioningInterval: 1,
            maximumRetryAfter: 5,
            maximumElapsedTime: 60,
            maximumStateRequests: 2
        )
        let transport = RecordingHTTPTransport { _, index in
            switch index {
            case 0:
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            case 1 ... 3:
                return StubbedHTTPResponse(json: #"{"state":"WaitingForResources"}"#)
            case 4:
                return StubbedHTTPResponse(json: #"{"state":"Provisioned"}"#)
            case 5:
                return StubbedHTTPResponse(json: Self.configurationJSON)
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
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

        #expect(await transport.requests().count == 6)
        #expect(await delays.values() == [1, 1, 1])
    }

    @Test("Capacity ETA creates a soft queue deadline")
    func capacityQueueUsesAdaptiveDeadline() async throws {
        let clock = XboxCloudSessionTestClock(fixedDate)
        let delays = XboxCloudDelayRecorder()
        let policy = try XboxCloudSessionPollingPolicy(
            queueInterval: 10,
            provisioningInterval: 1,
            maximumRetryAfter: 60,
            maximumElapsedTime: 15 * 60,
            maximumStateRequests: 300
        )
        let transport = RecordingHTTPTransport { _, index in
            index == 0
                ? StubbedHTTPResponse(json: Self.createResponseJSON)
                : StubbedHTTPResponse(
                    json: #"{"state":"WaitingForResources","estimatedTotalWaitTimeInSeconds":0}"#
                )
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport,
            pollingPolicy: policy,
            now: { clock.now() },
            sleep: { delay in
                await delays.record(delay)
                clock.advance(by: delay)
            }
        )
        let handle = try await api.createSession(makeLaunchRequest())

        await #expect(throws: XboxCloudSessionAPIError.pollingTimedOut(maximumStateRequests: 300)) {
            _ = try await api.pollUntilProvisioned(handle)
        }

        #expect(await delays.values() == [10, 10, 10, 10, 10, 10])
        #expect(await transport.requests().count == 7)
    }

    @Test("Revised capacity estimates extend only to the hard deadline")
    func revisedCapacityEstimateExtendsDeadline() throws {
        let hardDeadline = fixedDate.addingTimeInterval(15 * 60)
        let first = try #require(XboxCloudSessionAPI.updatedWaitingDeadline(
            current: nil,
            allocationStartedAt: fixedDate,
            hardDeadline: hardDeadline,
            estimatedTotalWaitTime: 0,
            queueInterval: 10
        ))
        let revised = try #require(XboxCloudSessionAPI.updatedWaitingDeadline(
            current: first,
            allocationStartedAt: fixedDate,
            hardDeadline: hardDeadline,
            estimatedTotalWaitTime: 240,
            queueInterval: 10
        ))
        let capped = try #require(XboxCloudSessionAPI.updatedWaitingDeadline(
            current: revised,
            allocationStartedAt: fixedDate,
            hardDeadline: hardDeadline,
            estimatedTotalWaitTime: 3600,
            queueInterval: 10
        ))

        #expect(first == fixedDate.addingTimeInterval(60))
        #expect(revised == fixedDate.addingTimeInterval(270))
        #expect(capped == hardDeadline)
    }

    @Test("Capacity polling has an absolute fifteen-minute ceiling")
    func capacityQueueHasHardCeiling() async throws {
        let clock = XboxCloudSessionTestClock(fixedDate)
        let policy = try XboxCloudSessionPollingPolicy(
            queueInterval: 60,
            provisioningInterval: 1,
            maximumRetryAfter: 60,
            maximumElapsedTime: 3600,
            maximumStateRequests: 1000
        )
        let transport = RecordingHTTPTransport { _, index in
            index == 0
                ? StubbedHTTPResponse(json: Self.createResponseJSON)
                : StubbedHTTPResponse(json: #"{"state":"WaitingForResources"}"#)
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport,
            pollingPolicy: policy,
            now: { clock.now() },
            sleep: { clock.advance(by: $0) }
        )
        let handle = try await api.createSession(makeLaunchRequest())

        await #expect(throws: XboxCloudSessionAPIError.pollingTimedOut(maximumStateRequests: 1000)) {
            _ = try await api.pollUntilProvisioned(handle)
        }

        #expect(clock.now() == fixedDate.addingTimeInterval(15 * 60))
        #expect(await transport.requests().count == 16)
    }

    @Test("A transient capacity-state transport failure is retried once")
    func transientStateFailureRetriesOnce() async throws {
        let delays = XboxCloudDelayRecorder()
        let transport = RecordingHTTPTransport { _, index in
            switch index {
            case 0:
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            case 1:
                throw TestTransportError.unexpectedRequest("Transient fixture failure")
            case 2:
                return StubbedHTTPResponse(json: #"{"state":"Provisioned"}"#)
            case 3:
                return StubbedHTTPResponse(json: Self.configurationJSON)
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport,
            sleep: { delay in await delays.record(delay) }
        )
        let handle = try await api.createSession(makeLaunchRequest())

        _ = try await api.pollUntilProvisioned(handle)

        #expect(await transport.requests().count == 4)
        #expect(await delays.values() == [2])
    }

    @Test(
        "A transient capacity-state service response is retried once",
        arguments: [408, 429, 500, 502, 503, 504]
    )
    func transientStateHTTPFailureRetriesOnce(statusCode: Int) async throws {
        let delays = XboxCloudDelayRecorder()
        let transport = RecordingHTTPTransport { _, index in
            switch index {
            case 0:
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            case 1:
                return StubbedHTTPResponse(statusCode: statusCode)
            case 2:
                return StubbedHTTPResponse(json: #"{"state":"Provisioned"}"#)
            case 3:
                return StubbedHTTPResponse(json: Self.configurationJSON)
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport,
            sleep: { delay in await delays.record(delay) }
        )
        let handle = try await api.createSession(makeLaunchRequest())

        _ = try await api.pollUntilProvisioned(handle)

        #expect(await transport.requests().count == 4)
        #expect(await delays.values() == [2])
    }

    @Test("Two consecutive capacity-state failures stop polling")
    func repeatedTransientStateFailuresStopPolling() async throws {
        let delays = XboxCloudDelayRecorder()
        let transport = RecordingHTTPTransport { _, index in
            switch index {
            case 0:
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            case 1, 2:
                throw TestTransportError.unexpectedRequest("Transient fixture failure")
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport,
            sleep: { delay in await delays.record(delay) }
        )
        let handle = try await api.createSession(makeLaunchRequest())

        await #expect(throws: XboxCloudSessionAPIError.transportFailure(operation: .state)) {
            _ = try await api.pollUntilProvisioned(handle)
        }

        #expect(await transport.requests().count == 3)
        #expect(await delays.values() == [2])
    }

    @Test("State requests have a finite per-request timeout")
    func stateRequestHasFiniteTimeout() async throws {
        let transport = RecordingHTTPTransport { request, index in
            switch index {
            case 0:
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            case 1:
                #expect(request.timeoutInterval == 30)
                return StubbedHTTPResponse(json: #"{"state":"Provisioned"}"#)
            case 2:
                return StubbedHTTPResponse(json: Self.configurationJSON)
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport
        )
        let handle = try await api.createSession(makeLaunchRequest())

        _ = try await api.pollUntilProvisioned(handle)
    }

    @Test("Provisioning state requests use only their remaining deadline")
    func stateRequestUsesRemainingProvisioningDeadline() async throws {
        let clock = XboxCloudSessionTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let policy = try XboxCloudSessionPollingPolicy(
            queueInterval: 1,
            provisioningInterval: 0.75,
            maximumRetryAfter: 5,
            maximumElapsedTime: 1,
            maximumStateRequests: 4
        )
        let transport = RecordingHTTPTransport { request, index in
            switch index {
            case 0:
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            case 1:
                return StubbedHTTPResponse(json: #"{"state":"Provisioning"}"#)
            case 2:
                #expect(abs(request.timeoutInterval - 0.25) < 0.001)
                return StubbedHTTPResponse(json: #"{"state":"Provisioned"}"#)
            case 3:
                return StubbedHTTPResponse(json: Self.configurationJSON)
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport,
            pollingPolicy: policy,
            now: { clock.now() },
            sleep: { delay in clock.advance(by: delay) }
        )
        let handle = try await api.createSession(makeLaunchRequest())

        _ = try await api.pollUntilProvisioned(handle)
    }

    @Test("A transient provisioning retry cannot exceed the polling deadline")
    func transientRetryUsesRemainingProvisioningDeadline() async throws {
        let clock = XboxCloudSessionTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let delays = XboxCloudDelayRecorder()
        let policy = try XboxCloudSessionPollingPolicy(
            queueInterval: 1,
            provisioningInterval: 0,
            maximumRetryAfter: 5,
            maximumElapsedTime: 1,
            maximumStateRequests: 4
        )
        let transport = RecordingHTTPTransport { _, index in
            switch index {
            case 0:
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            case 1:
                return StubbedHTTPResponse(json: #"{"state":"Provisioning"}"#)
            case 2:
                clock.advance(by: 0.75)
                throw TestTransportError.unexpectedRequest("Transient fixture failure")
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport,
            pollingPolicy: policy,
            now: { clock.now() },
            sleep: { delay in
                await delays.record(delay)
                clock.advance(by: delay)
            }
        )
        let handle = try await api.createSession(makeLaunchRequest())

        await #expect(throws: XboxCloudSessionAPIError.pollingTimedOut(maximumStateRequests: 4)) {
            _ = try await api.pollUntilProvisioned(handle)
        }

        let recordedDelays = await delays.values()
        #expect(recordedDelays.count == 1)
        #expect(abs(recordedDelays[0] - 0.25) < 0.001)
        #expect(await transport.requests().count == 3)
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
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )
        let handle = try await api.createSession(makeLaunchRequest())
        let pollingTask = Task {
            try await api.pollUntilProvisioned(handle)
        }

        #expect(await waitForRequestCount(2, transport: transport))
        pollingTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await pollingTask.value
        }

        #expect(await transport.requests().count == 2)
    }

    @Test("Cancellation propagates out of an in-flight state request without retrying")
    func inFlightStateRequestCancellation() async throws {
        let transport = RecordingHTTPTransport { _, index in
            switch index {
            case 0:
                return StubbedHTTPResponse(json: Self.createResponseJSON)
            case 1:
                try await Task.sleep(for: .seconds(60))
                return StubbedHTTPResponse(json: #"{"state":"Provisioned"}"#)
            default:
                throw TestTransportError.unexpectedRequest("Unexpected request \(index)")
            }
        }
        let api = try XboxCloudSessionAPI(
            access: makeAccessContext(),
            transport: transport
        )
        let handle = try await api.createSession(makeLaunchRequest())
        let pollingTask = Task {
            try await api.pollUntilProvisioned(handle)
        }

        #expect(await waitForRequestCount(2, transport: transport))
        pollingTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await pollingTask.value
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
        profile: XboxCloudSessionCompatibilityProfile = .microsoftWeb,
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
            compatibilityProfile: profile,
            msaTransferToken: transferToken
        )
    }

    private func makeLaunchRequest(
        magnifier: Bool = false
    ) throws -> XboxCloudSessionLaunchRequest {
        try XboxCloudSessionLaunchRequest(
            titleID: "123456789",
            preferredSystemUpdateGroup: "flight-a",
            clientSessionID: "fixture-client-session",
            settings: XboxCloudSessionLaunchSettings(
                magnifier: magnifier,
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

private final class XboxCloudSessionTestClock: Sendable {
    private let value: Mutex<Date>

    init(_ date: Date) {
        value = Mutex(date)
    }

    func now() -> Date {
        value.withLock { $0 }
    }

    func advance(by interval: TimeInterval) {
        value.withLock { date in
            date = date.addingTimeInterval(interval)
        }
    }
}

private func waitForRequestCount(
    _ expectedCount: Int,
    transport: RecordingHTTPTransport
) async -> Bool {
    for _ in 0 ..< 1000 {
        if await transport.requests().count >= expectedCount {
            return true
        }
        await Task.yield()
    }
    return false
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

private actor XboxCloudSessionGate {
    private var isSignaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let waiting = continuations
        continuations.removeAll(keepingCapacity: false)
        waiting.forEach { $0.resume() }
    }
}
