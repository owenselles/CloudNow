@testable import CloudNow
import Foundation
import Testing

@Suite("CloudMatch session HTTP client")
struct CloudMatchClientTests {
    @Test("Shared GFN headers retain native capabilities with WebRTC transport", arguments: [true, false])
    func nativeWebRTCHeaders(includeOrigin: Bool) {
        let headers = gfnHeaders(
            token: "fixture-token",
            clientId: "fixture-client",
            deviceId: "fixture-device",
            includeOrigin: includeOrigin
        )

        #expect(headers["nv-client-streamer"] == "WEBRTC")
        #expect(headers["nv-client-type"] == "NATIVE")
        #expect(headers["Authorization"] == "GFNJWT fixture-token")
        #expect(headers["nv-client-id"] == "fixture-client")
        #expect(headers["x-device-id"] == "fixture-device")
        #expect(headers["Origin"] == (includeOrigin ? NVIDIAAuth.webOrigin : nil))
        #expect(headers["Referer"] == (includeOrigin ? NVIDIAAuth.webReferer : nil))
    }

    @Test(
        "Session creation maps stream settings into deterministic request fields",
        arguments: [
            (AudioFormatPreference.stereo, 2, 0),
            (.surround51, 6, 4_128_774),
            (.surround71, 8, 104_792_072),
        ]
    )
    func createSessionRequest(format: AudioFormatPreference, channels: Int, surroundInfo: Int) async throws {
        let fixture = try NetworkingFixture.data("cloudmatch-session.json")
        let fixedUUID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.url?.host == "np-test.cloudmatchbeta.nvidiagrid.net")
            #expect(request.url?.path == "/v2/session")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT fixture-token")
            #expect(request.value(forHTTPHeaderField: "nv-client-id") == fixedUUID.uuidString)
            #expect(request.value(forHTTPHeaderField: "x-device-id") == "fixture-device")
            #expect(request.value(forHTTPHeaderField: "nv-client-streamer") == "NVIDIA-CLASSIC")
            #expect(request.value(forHTTPHeaderField: "nv-client-type") == "NATIVE")
            let requestURL = try #require(request.url)
            let query = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
            #expect(query.queryItems?.first { $0.name == "keyboardLayout" }?.value == "en-US")
            #expect(query.queryItems?.first { $0.name == "languageCode" }?.value == "en-US")

            let root = try jsonObject(from: request)
            let session = try #require(root["sessionRequestData"] as? [String: Any])
            let monitors = try #require(session["clientRequestMonitorSettings"] as? [[String: Any]])
            let monitor = try #require(monitors.first)
            let features = try #require(session["requestedStreamingFeatures"] as? [String: Any])
            let metadata = try #require(session["metaData"] as? [[String: Any]])
            #expect(session["appId"] as? String == "12345")
            #expect(session["deviceHashId"] as? String == "fixture-device")
            #expect(session["audioMode"] as? Int == channels)
            #expect(session["surroundAudioInfo"] as? Int == surroundInfo)
            #expect(metadata.first { $0["key"] as? String == "surroundAudioInfo" }?["value"] as? String == "\(channels)")
            #expect(session["clientTimezoneOffset"] as? Int == 3_600_000)
            #expect(session["appLaunchMode"] as? Int == 1)
            #expect(session["enablePersistingInGameSettings"] as? Bool == false)
            #expect(monitor["widthInPixels"] as? Int == 3840)
            #expect(monitor["heightInPixels"] as? Int == 2160)
            #expect(monitor["framesPerSecond"] as? Int == 120)
            #expect(metadata.first { $0["key"] as? String == "clientPhysicalResolution" }?["value"] as? String == "{\"horizontalPixels\":3840,\"verticalPixels\":2160}")
            #expect(monitor["sdrHdrMode"] as? Int == 0)
            #expect(features["enabledL4S"] as? Bool == true)
            #expect(features["reflex"] as? Bool == true)
            #expect(features["bitDepth"] as? Int == 0)
            #expect(features["chromaFormat"] as? Int == 1)
            #expect(session["codec"] == nil)
            #expect(session["maxBitrateKbps"] == nil)
            #expect(features["codec"] == nil)
            #expect(features["maxBitrateKbps"] == nil)
            let requestBody = try #require(request.httpBody)
            let body = try #require(String(bytes: requestBody, encoding: .utf8)).lowercased()
            #expect(!body.contains("codec"))
            #expect(!body.contains("bitrate"))
            #expect(metadata.first { $0["key"] as? String == "SubSessionId" }?["value"] as? String == fixedUUID.uuidString)
            return StubbedHTTPResponse(data: fixture)
        }
        let client = CloudMatchClient(
            transport: transport,
            uuid: { fixedUUID },
            deviceId: { "fixture-device" },
            timezoneOffsetMilliseconds: { 3_600_000 }
        )

        let session = try await client.createSession(makeSessionRequest(audioFormat: format))

        #expect(session.sessionId == "fixture-session")
        #expect(session.status == 2)
        #expect(session.zone == "https://np-test.cloudmatchbeta.nvidiagrid.net/")
        #expect(session.serverIp == "203.0.113.10")
        #expect(session.signalingUrl == "wss://203.0.113.10:443/nvst/")
        #expect(session.mediaConnectionInfo?.ip == "203.0.113.11")
        #expect(session.mediaConnectionInfo?.port == 49005)
        #expect(session.iceServers.first?.urls == ["stun:stun.example.invalid:3478"])
    }

    @Test(
        "Session chroma request respects selection and codec without changing color precision",
        arguments: [
            (VideoCodec.automatic, ChromaFormat.yuv420, 0),
            (.automatic, .yuv444, 1),
            (VideoCodec.h265, ChromaFormat.yuv420, 0),
            (.h265, .yuv444, 1),
            (.h264, .yuv444, 0),
            (.av1, .yuv444, 0),
        ],
        [ColorModePreference.forceSDR8, .preferSDR10, .preferHDR]
    )
    func chromaSessionRequest(
        configuration: (VideoCodec, ChromaFormat, Int),
        color: ColorModePreference
    ) async throws {
        let (codec, chromaFormat, expectedChroma) = configuration
        let usesHEVC = codec == .automatic || codec == .h265
        let fixture = try NetworkingFixture.data("cloudmatch-session.json")
        let transport = RecordingHTTPTransport { request, _ in
            let root = try jsonObject(from: request)
            let session = try #require(root["sessionRequestData"] as? [String: Any])
            let features = try #require(session["requestedStreamingFeatures"] as? [String: Any])
            #expect(features["chromaFormat"] as? Int == expectedChroma)
            #expect(features["bitDepth"] as? Int == (usesHEVC && color != .forceSDR8 ? 1 : 0))
            #expect(session["sdrHdrMode"] as? Int == (usesHEVC && color == .preferHDR ? 1 : 0))
            return StubbedHTTPResponse(data: fixture)
        }
        let client = CloudMatchClient(transport: transport, deviceId: { "fixture-device" })

        _ = try await client.createSession(makeSessionRequest(
            codec: codec,
            colorPreference: color,
            chromaFormat: chromaFormat
        ))
    }

    @Test("Failed preferred endpoint falls back to default routing endpoint")
    func createFallback() async throws {
        let fixture = try NetworkingFixture.data("cloudmatch-session.json")
        let transport = RecordingHTTPTransport { request, _ in
            if request.url?.host == "preferred.example.invalid" {
                return StubbedHTTPResponse(statusCode: 503, json: #"{"error":"unavailable"}"#)
            }
            #expect(request.url?.host == "prod.cloudmatchbeta.nvidiagrid.net")
            return StubbedHTTPResponse(data: fixture)
        }
        let client = CloudMatchClient(transport: transport, deviceId: { "device" })
        var input = makeSessionRequest()
        input = SessionCreateRequest(
            appId: input.appId,
            internalTitle: input.internalTitle,
            token: input.token,
            streamingBaseUrl: "https://preferred.example.invalid/",
            routingZoneUrl: "https://np-test.cloudmatchbeta.nvidiagrid.net/",
            settings: input.settings,
            localVideoCapabilities: input.localVideoCapabilities,
            accountLinked: input.accountLinked,
            accountAllowsHDR: input.accountAllowsHDR,
            skipNvidiaFallback: false
        )

        let session = try await client.createSession(input)

        #expect(session.streamingBaseUrl == "https://prod.cloudmatchbeta.nvidiagrid.net")
        #expect(session.zone.isEmpty)
        #expect(await transport.requests().count == 2)
    }

    @Test("Partner session failure never falls back to the NVIDIA endpoint")
    func partnerFailureSkipsNvidiaFallback() async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(statusCode: 503, json: #"{"error":"partner-unavailable"}"#)
        }
        let client = CloudMatchClient(transport: transport, deviceId: { "device" })
        let input = makeSessionRequest()
        let partnerRequest = SessionCreateRequest(
            appId: input.appId,
            internalTitle: input.internalTitle,
            token: input.token,
            streamingBaseUrl: "https://prod.dig.geforcenow.nvidiagrid.net/",
            routingZoneUrl: nil,
            settings: input.settings,
            localVideoCapabilities: input.localVideoCapabilities,
            accountLinked: input.accountLinked,
            accountAllowsHDR: input.accountAllowsHDR,
            skipNvidiaFallback: true
        )

        do {
            _ = try await client.createSession(partnerRequest)
            Issue.record("Expected the partner endpoint failure to propagate")
        } catch {
            // The partner's own error surfaces, not one from a retry elsewhere.
            #expect(error.localizedDescription.contains("partner-unavailable"))
        }

        // Exactly one attempt, and it stayed on the partner's streaming service.
        let requests = await transport.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.host == "prod.dig.geforcenow.nvidiagrid.net")
        #expect(!requests.contains { $0.url?.host == "prod.cloudmatchbeta.nvidiagrid.net" })
    }

    @Test("CloudMatch API status errors retain structured context")
    func apiStatusFailure() async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                json: #"{"requestStatus":{"statusCode":42,"statusDescription":"NO_CAPACITY"},"session":null}"#
            )
        }

        do {
            _ = try await CloudMatchClient(
                transport: transport,
                deviceId: { "fixture-device" }
            ).createSession(makeSessionRequest())
            Issue.record("Expected CloudMatch API rejection")
        } catch {
            #expect(error.localizedDescription.contains("statusCode=42"))
            #expect(error.localizedDescription.contains("NO_CAPACITY"))
        }
    }

    @Test("Polling switches once to the resolved server and preserves routing zone")
    func pollResolvedServer() async throws {
        let fixture = try NetworkingFixture.data("cloudmatch-session.json")
        let transport = RecordingHTTPTransport { _, _ in StubbedHTTPResponse(data: fixture) }
        let client = CloudMatchClient(
            transport: transport,
            deviceId: { "fixture-device" }
        )

        let session = try await client.pollSession(
            sessionId: "fixture-session",
            token: "token",
            base: "https://region.example.invalid",
            serverIp: nil,
            routingZoneUrl: "https://np-test.cloudmatchbeta.nvidiagrid.net/",
            clientId: "client",
            deviceId: "device"
        )
        let requests = await transport.requests()

        #expect(requests.map { $0.url?.host } == ["region.example.invalid", "203.0.113.10"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Origin") == nil })
        #expect(session.streamingBaseUrl == "https://203.0.113.10")
        #expect(session.zone == "https://np-test.cloudmatchbeta.nvidiagrid.net/")
    }

    @Test(
        "Queued WebRTC sessions ignore the unassigned rig placeholder host",
        arguments: [
            ("control.example.invalid", "control.example.invalid"),
            (" control.example.invalid \n", "control.example.invalid"),
            (nil, ""),
        ] as [(String?, String)]
    )
    func queuedSessionIgnoresPlaceholderHost(controlHost: String?, expectedServerIp: String) async throws {
        let data = try placeholderSessionResponse(controlHost: controlHost)
        let transport = RecordingHTTPTransport { _, _ in StubbedHTTPResponse(data: data) }
        let client = CloudMatchClient(transport: transport, deviceId: { "device" })

        let session = try await client.createSession(makeSessionRequest())

        #expect(session.serverIp == expectedServerIp)
        #expect(session.controlServerIp == (expectedServerIp.isEmpty ? nil : expectedServerIp))
        #expect(session.mediaConnectionInfo?.ip.hasPrefix(".") != true)
        if !expectedServerIp.isEmpty {
            #expect(session.signalingUrl == "wss://\(expectedServerIp):443/nvst/")
            #expect(session.mediaConnectionInfo?.ip == expectedServerIp)
        }
    }

    @Test("Polling a queued WebRTC session stays on the routing endpoint")
    func pollQueuedPlaceholderSession() async throws {
        let data = try placeholderSessionResponse(controlHost: "control.example.invalid")
        let transport = RecordingHTTPTransport { _, _ in StubbedHTTPResponse(data: data) }
        let client = CloudMatchClient(transport: transport, deviceId: { "device" })

        let session = try await client.pollSession(
            sessionId: "session-id",
            token: "token",
            base: "https://region.example.invalid",
            serverIp: nil,
            clientId: "client",
            deviceId: "device"
        )

        #expect(await transport.requests().map { $0.url?.host } == ["region.example.invalid"])
        #expect(session.serverIp == "control.example.invalid")
    }

    @Test("Active-session discovery ignores the unassigned rig placeholder host")
    func activeSessionsIgnorePlaceholderHost() async throws {
        let response: [String: Any] = [
            "requestStatus": ["statusCode": 1],
            "sessions": [[
                "sessionId": "queued-session",
                "status": 1,
                "sessionRequestData": ["appId": 12345],
                "connectionInfo": [[
                    "usage": 14,
                    "ip": ".cloudmatchbeta.nvidiagrid.net",
                    "port": 443,
                    "resourcePath": "/nvst/",
                ]],
                "sessionControlInfo": ["ip": "control.example.invalid"],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        let transport = RecordingHTTPTransport { _, _ in StubbedHTTPResponse(data: data) }

        let sessions = try await CloudMatchClient(
            transport: transport,
            deviceId: { "device" }
        ).getActiveSessions(token: "token", base: "https://region.example.invalid")

        #expect(sessions.map(\.serverIp) == ["control.example.invalid"])
        #expect(sessions.map(\.signalingUrl) == ["wss://control.example.invalid:443/nvst/"])
    }

    @Test("Active-session decoding filters ended sessions and resolves signaling host")
    func activeSessions() async throws {
        let fixture = try NetworkingFixture.data("cloudmatch-active-sessions.json")
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.httpMethod == "GET")
            return StubbedHTTPResponse(data: fixture)
        }

        let sessions = try await CloudMatchClient(
            transport: transport,
            deviceId: { "device" }
        ).getActiveSessions(token: "token", base: "https://region.example.invalid")

        #expect(sessions.count == 1)
        #expect(sessions[0].sessionId == "active-session")
        #expect(sessions[0].appId == "12345")
        #expect(sessions[0].serverIp == "203.0.113.20")
        #expect(sessions[0].signalingUrl == "wss://signaling.example.invalid/nvst/")
    }

    @MainActor
    @Test(
        "Created sessions stop through their control endpoint without changing signaling",
        arguments: [
            (nil, nil),
            ("", nil),
            (" \n", nil),
            ("control.example.invalid", "control.example.invalid"),
            (" control.example.invalid \n", "control.example.invalid"),
        ] as [(String?, String?)]
    )
    func stopCreatedSessionUsesControlEndpoint(controlHost: String?, expectedControlHost: String?) async throws {
        let response: [String: Any] = [
            "requestStatus": ["statusCode": 1],
            "session": [
                "sessionId": "session-id",
                "status": 2,
                "connectionInfo": [["usage": 14, "ip": "203.0.113.10", "port": 443]],
                "sessionControlInfo": ["ip": controlHost as Any? ?? NSNull()],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        let transport = RecordingHTTPTransport { request, index in
            if index == 0 {
                #expect(request.httpMethod == "POST")
                return StubbedHTTPResponse(data: data)
            }
            #expect(request.url?.host == (index == 1 ? (expectedControlHost ?? "203.0.113.10") : "np-test.cloudmatchbeta.nvidiagrid.net"))
            #expect(request.url?.path == (index == 1 ? "/v2/session/session-id" : "/v2/session"))
            #expect(request.httpMethod == (index == 1 ? "DELETE" : "GET"))
            #expect(request.timeoutInterval <= 5)
            #expect(request.value(forHTTPHeaderField: "x-device-id") == "device")
            return index == 1 ? StubbedHTTPResponse(statusCode: 204)
                : StubbedHTTPResponse(json: #"{"requestStatus":{"statusCode":1},"sessions":[]}"#)
        }
        let client = CloudMatchClient(transport: transport, deviceId: { "device" })
        let session = try await client.createSession(makeSessionRequest())
        #expect(session.serverIp == "203.0.113.10")
        #expect(session.signalingServer == "203.0.113.10:443")
        #expect(session.controlServerIp == expectedControlHost)
        let orchestrator = SessionOrchestrator(client: client)
        orchestrator.adopt(session, token: "token")

        #expect(await orchestrator.stopOwnedSession())
        #expect(await transport.requests().count == 3)
    }

    @Test("Active-session cleanup preserves its control endpoint")
    func stopActiveSessionUsesControlEndpoint() async throws {
        let transport = RecordingHTTPTransport { request, index in
            if index == 0 {
                #expect(request.url?.host == "region.example.invalid")
                #expect(request.httpMethod == "GET")
                return StubbedHTTPResponse(json: """
                {"requestStatus":{"statusCode":1},"sessions":[{
                    "sessionId":"session-id","status":2,
                    "sessionRequestData":{"appId":"12345"},
                    "connectionInfo":[{"usage":14,"ip":"203.0.113.10","port":443}],
                    "sessionControlInfo":{"ip":"control.example.invalid"}
                }]}
                """)
            }
            #expect(request.url?.host == (index == 1 ? "control.example.invalid" : "region.example.invalid"))
            #expect(request.url?.path == (index == 1 ? "/v2/session/session-id" : "/v2/session"))
            #expect(request.httpMethod == (index == 1 ? "DELETE" : "GET"))
            return index == 1 ? StubbedHTTPResponse(statusCode: 204)
                : StubbedHTTPResponse(json: #"{"requestStatus":{"statusCode":1},"sessions":[]}"#)
        }
        try await CloudMatchClient(transport: transport).stopActiveSessions(
            matchingAppId: "12345", token: "token", base: "https://region.example.invalid"
        )
        #expect(await transport.requests().count == 3)
    }

    @Test("Stop sends DELETE and rejects non-success HTTP status")
    func stopSessionStatus() async {
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.absoluteString == "https://203.0.113.10/v2/session/session-id")
            return StubbedHTTPResponse(statusCode: 500, json: #"{"error":"failed"}"#)
        }

        await #expect(throws: CloudMatchError.self) {
            try await CloudMatchClient(
                transport: transport,
                deviceId: { "fixture-device" }
            ).stopSession(
                sessionId: "session-id",
                token: "token",
                base: "https://region.example.invalid",
                serverIp: "203.0.113.10",
                clientId: "client",
                deviceId: "device"
            )
        }
    }

    @Test(
        "Stop accepts an already-ended server session",
        arguments: [404, 410]
    )
    func stopSessionAlreadyEnded(statusCode: Int) async throws {
        let transport = RecordingHTTPTransport { request, _ in
            #expect(request.httpMethod == "DELETE")
            return StubbedHTTPResponse(statusCode: statusCode)
        }

        try await CloudMatchClient(
            transport: transport,
            deviceId: { "fixture-device" }
        ).stopSession(
            sessionId: "ended-session",
            token: "token",
            base: "https://region.example.invalid",
            clientId: "client",
            deviceId: "device"
        )
    }

    @Test("Stop waits for absence from the provider active list using the same identity")
    func stopSessionWaitsForTermination() async throws {
        let transport = RecordingHTTPTransport { request, index in
            #expect(request.url?.absoluteString == (index == 0
                    ? "https://203.0.113.10/v2/session/session-id" : "https://region.example.invalid/v2/session"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT token")
            #expect(request.value(forHTTPHeaderField: "nv-client-id") == "client")
            #expect(request.value(forHTTPHeaderField: "x-device-id") == "device")
            #expect(request.value(forHTTPHeaderField: "Origin") == nil)
            if index == 0 {
                #expect(request.httpMethod == "DELETE")
                return StubbedHTTPResponse(json: #"{"requestStatus":{"statusCode":1}}"#)
            }
            #expect(request.httpMethod == "GET")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.timeoutInterval <= 5)
            let sessions = index == 1 ? #"[{"sessionId":"session-id","status":2}]"# : "[]"
            return StubbedHTTPResponse(json: "{\"requestStatus\":{\"statusCode\":1},\"sessions\":\(sessions)}")
        }
        let client = CloudMatchClient(transport: transport, sleep: { seconds in
            #expect(seconds == 2)
        })

        try await client.stopSession(
            sessionId: "session-id",
            token: "token",
            base: "https://region.example.invalid",
            serverIp: "203.0.113.10",
            clientId: "client",
            deviceId: "device"
        )

        #expect(await transport.requests().count == 3)
    }

    @Test("Stop immediately confirms absence of the exact session", arguments: [
        "[]", #"[{"sessionId":"another-session","status":2}]"#,
    ])
    func stopSessionDisappears(sessions: String) async throws {
        let transport = RecordingHTTPTransport { request, index in
            #expect(request.httpMethod == (index == 0 ? "DELETE" : "GET"))
            return index == 0 ? StubbedHTTPResponse(statusCode: 204)
                : StubbedHTTPResponse(json: "{\"requestStatus\":{\"statusCode\":1},\"sessions\":\(sessions)}")
        }
        try await CloudMatchClient(transport: transport, sleep: { _ in
            Issue.record("Confirmed absence must not incur a polling delay")
        }).stopSession(sessionId: "session-id", token: "token", base: "https://region.example.invalid")
        #expect(await transport.requests().count == 2)
    }

    @Test("Failed active-list requests cannot confirm termination", arguments: [401, 404, 410, 500])
    func stopSessionListHTTPFailure(statusCode: Int) async {
        let transport = RecordingHTTPTransport { _, index in
            StubbedHTTPResponse(statusCode: index == 0 ? 204 : statusCode)
        }
        await #expect(throws: CloudMatchError.self) {
            try await CloudMatchClient(transport: transport).stopSession(
                sessionId: "session-id", token: "token", base: "https://region.example.invalid"
            )
        }
        #expect(await transport.requests().count == 2)
    }

    @Test("Incomplete active lists cannot confirm termination", arguments: [
        #"{"requestStatus":{"statusCode":1}}"#,
        #"{"requestStatus":{"statusCode":1},"sessions":null}"#,
        #"{"requestStatus":{"statusCode":1},"sessions":[{}]}"#,
        #"{"sessions":[]}"#,
    ])
    func stopSessionListInvalid(body: String) async {
        let transport = RecordingHTTPTransport { _, index in
            index == 0 ? StubbedHTTPResponse(statusCode: 204) : StubbedHTTPResponse(json: body)
        }
        await #expect(throws: (any Error).self) {
            try await CloudMatchClient(transport: transport).stopSession(
                sessionId: "session-id", token: "token", base: "https://region.example.invalid"
            )
        }
        #expect(await transport.requests().count == 2)
    }

    @Test("Stop preserves API rejection despite HTTP success", arguments: ["DELETE", "GET"])
    func stopSessionAPIRejection(failingMethod: String) async {
        let transport = RecordingHTTPTransport { request, _ in
            if request.httpMethod == failingMethod {
                return StubbedHTTPResponse(
                    json: #"{"requestStatus":{"statusCode":42,"statusDescription":"STOP_REJECTED"}}"#
                )
            }
            return StubbedHTTPResponse(statusCode: 204)
        }

        do {
            try await CloudMatchClient(transport: transport, sleep: { _ in }).stopSession(
                sessionId: "session-id",
                token: "token",
                base: "https://region.example.invalid"
            )
            Issue.record("Expected stop rejection to propagate")
        } catch let CloudMatchError.apiStatus(context, statusCode, description) {
            #expect(context == "stopSession")
            #expect(statusCode == 42)
            #expect(description == "STOP_REJECTED")
        } catch {
            Issue.record(error)
        }

        #expect(await transport.requests().count == (failingMethod == "DELETE" ? 1 : 2))
    }

    @Test("Stop stays pending while the exact session is listed regardless of status", arguments: [2, 4, 99])
    func stopSessionConfirmationTimeout(status: Int) async {
        let transport = RecordingHTTPTransport { _, index in
            if index == 0 {
                return StubbedHTTPResponse(statusCode: 204)
            }
            return StubbedHTTPResponse(
                json: "{\"requestStatus\":{\"statusCode\":1},\"sessions\":[{\"sessionId\":\"session-id\",\"status\":\(status)}]}"
            )
        }

        do {
            try await CloudMatchClient(transport: transport, sleep: { _ in }).stopSession(
                sessionId: "session-id",
                token: "token",
                base: "https://region.example.invalid"
            )
            Issue.record("An active session must not be reported as stopped")
        } catch CloudMatchError.sessionStopTimedOut {
            #expect(await transport.requests().count == 16)
        } catch {
            Issue.record(error)
        }
    }

    @Test("Stop propagates cancellation between confirmation attempts")
    func stopSessionConfirmationCancellation() async {
        let transport = RecordingHTTPTransport { _, index in
            if index == 0 {
                return StubbedHTTPResponse(statusCode: 204)
            }
            return StubbedHTTPResponse(
                json: #"{"requestStatus":{"statusCode":1},"sessions":[{"sessionId":"session-id","status":2}]}"#
            )
        }
        let client = CloudMatchClient(transport: transport, sleep: { _ in throw CancellationError() })

        await #expect(throws: CancellationError.self) {
            try await client.stopSession(
                sessionId: "session-id",
                token: "token",
                base: "https://region.example.invalid"
            )
        }

        #expect(await transport.requests().count == 2)
    }

    @Test(
        "Creation conflicts are recognized in HTTP-success API responses",
        arguments: ["SESSION_LIMIT_EXCEEDED_STATUS", "REQUEST_LIMIT_EXCEEDED_STATUS"]
    )
    func createSessionAPIConflict(description: String) async {
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(
                json: "{\"requestStatus\":{\"statusCode\":42,\"statusDescription\":\"\(description)\"}}"
            )
        }

        do {
            _ = try await CloudMatchClient(transport: transport).createSession(makeSessionRequest())
            Issue.record("Expected session conflict")
        } catch let error as CloudMatchError {
            #expect(error.isSessionConflict)
        } catch {
            Issue.record(error)
        }
    }

    @Test("Unrelated API errors do not trigger session-conflict recovery")
    func unrelatedErrorsAreNotSessionConflicts() {
        #expect(!CloudMatchError.apiStatus(
            context: "stopSession", statusCode: 42, description: "SESSION_LIMIT_EXCEEDED_STATUS"
        ).isSessionConflict)
        #expect(!CloudMatchError.apiStatus(
            context: "createSession", statusCode: 42, description: "NO_CAPACITY"
        ).isSessionConflict)
        #expect(!CloudMatchError.sessionStopTimedOut.isSessionConflict)
    }

    @Test(
        "Claim sends a minimal resume body after ready preflight",
        arguments: [
            (AudioFormatPreference.stereo, 2, 0),
            (.surround51, 6, 4_128_774),
            (.surround71, 8, 104_792_072),
        ]
    )
    func claimReadySession(format: AudioFormatPreference, channels: Int, surroundInfo: Int) async throws {
        let fixture = try NetworkingFixture.data("cloudmatch-session.json")
        let transport = RecordingHTTPTransport { _, _ in StubbedHTTPResponse(data: fixture) }
        var settings = StreamSettings()
        settings.audioFormat = format
        settings.chromaFormat = .yuv444
        settings.keyboardLayout = "en-US"
        settings.gameLanguage = "en-US"
        let client = CloudMatchClient(
            transport: transport,
            deviceId: { "device" },
            timezoneOffsetMilliseconds: { 0 }
        )

        _ = try await client.claimSession(
            sessionId: "fixture-session",
            serverIp: "203.0.113.10",
            token: "token",
            base: "https://region.example.invalid",
            clientId: "client",
            deviceId: "device",
            appId: "12345",
            settings: settings
        )
        let requests = await transport.requests()
        let resume = try #require(requests.last)
        let root = try jsonObject(from: resume)
        let requestData = try #require(root["sessionRequestData"] as? [String: Any])
        let metadata = try #require(requestData["metaData"] as? [[String: Any]])

        #expect(requests.count == 2)
        #expect(resume.httpMethod == "PUT")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "nv-client-streamer") == "WEBRTC" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "nv-client-type") == "NATIVE" })
        #expect(root["action"] as? Int == 2)
        #expect(requestData["appId"] as? Int == 12345)
        #expect(requestData["sdrHdrMode"] as? Int == 0)
        #expect(requestData["requestedStreamingFeatures"] == nil)
        #expect(requestData["clientRequestMonitorSettings"] == nil)
        #expect(requestData["audioMode"] as? Int == channels)
        #expect(requestData["surroundAudioInfo"] as? Int == surroundInfo)
        #expect(metadata.first { $0["key"] as? String == "surroundAudioInfo" }?["value"] as? String == "\(channels)")
    }

    @Test(
        "Resume preserves allocated color instead of renegotiating from current preferences",
        arguments: [
            (ColorModePreference.forceSDR8, 1, 1),
            (.preferHDR, 0, 0),
            (.preferHDR, 99, 0),
        ]
    )
    func claimPreservesAllocatedColor(preference: ColorModePreference, reportedMode: Int, expectedMode: Int) async throws {
        let fixture = try NetworkingFixture.data("cloudmatch-session.json")
        var response = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        var payload = try #require(response["session"] as? [String: Any])
        payload["monitorSettings"] = [[
            "widthInPixels": 3840,
            "heightInPixels": 2160,
            "framesPerSecond": 60,
            "sdrHdrMode": reportedMode,
        ]]
        response["session"] = payload
        let data = try JSONSerialization.data(withJSONObject: response)
        let transport = RecordingHTTPTransport { _, _ in StubbedHTTPResponse(data: data) }
        var settings = StreamSettings()
        settings.colorPreference = preference
        settings.audioFormat = .surround51
        let client = CloudMatchClient(transport: transport)

        let session = try await client.claimSession(
            sessionId: "fixture-session",
            serverIp: "203.0.113.10",
            token: "token",
            base: "https://region.example.invalid",
            settings: settings
        )
        let requests = await transport.requests()
        let resume = try #require(requests.last)
        let body = try jsonObject(from: resume)
        let requestData = try #require(body["sessionRequestData"] as? [String: Any])
        let metadata = try #require(requestData["metaData"] as? [[String: Any]])

        #expect(requests.count == 2)
        #expect(resume.httpMethod == "PUT")
        #expect(resume.value(forHTTPHeaderField: "nv-client-streamer") == "WEBRTC")
        #expect(resume.value(forHTTPHeaderField: "nv-client-type") == "NATIVE")
        #expect(requestData["sdrHdrMode"] as? Int == expectedMode)
        #expect(session.acceptedSdrHdrMode == (reportedMode == 99 ? nil : reportedMode))
        #expect(requestData["clientRequestMonitorSettings"] == nil)
        #expect(requestData["requestedStreamingFeatures"] == nil)
        #expect(requestData["clientDisplayHdrCapabilities"] is NSNull)
        #expect(metadata.first { $0["key"] as? String == "clientPhysicalResolution" } == nil)
        #expect(requestData["audioMode"] as? Int == 6)
        #expect(requestData["surroundAudioInfo"] as? Int == 4_128_774)
        #expect(metadata.first { $0["key"] as? String == "surroundAudioInfo" }?["value"] as? String == "6")
    }

    @Test(
        "Sparse or malformed preflight retains accepted HDR only for the same server session",
        arguments: ["missing", "true", "false", "1.5", #""1""#]
    )
    func sparsePreflightPreservesSessionScopedHDR(reportedModeJSON: String) async throws {
        let fixture = try NetworkingFixture.data("cloudmatch-session.json")
        var response = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        var payload = try #require(response["session"] as? [String: Any])
        payload["monitorSettings"] = [["sdrHdrMode": 1]]
        response["session"] = payload
        let hdrData = try JSONSerialization.data(withJSONObject: response)
        if reportedModeJSON == "missing" {
            payload.removeValue(forKey: "monitorSettings")
        } else {
            let mode = try JSONSerialization.jsonObject(with: Data(reportedModeJSON.utf8), options: .fragmentsAllowed)
            payload["monitorSettings"] = [["sdrHdrMode": mode]]
        }
        response["session"] = payload
        let sparseData = try JSONSerialization.data(withJSONObject: response)
        payload["sessionId"] = "different-session"
        response["session"] = payload
        let differentSessionData = try JSONSerialization.data(withJSONObject: response)
        let transport = RecordingHTTPTransport { _, index in
            switch index {
            case 0: StubbedHTTPResponse(data: hdrData)
            case 1, 2: StubbedHTTPResponse(data: sparseData)
            case 3, 4: StubbedHTTPResponse(data: differentSessionData)
            default: throw TestTransportError.unexpectedRequest("Unexpected session request \(index)")
            }
        }
        let client = CloudMatchClient(transport: transport)
        let polled = try await client.pollSession(
            sessionId: "fixture-session",
            token: "token",
            base: "https://region.example.invalid",
            serverIp: "203.0.113.10",
            clientId: "client",
            deviceId: "device"
        )
        var settings = StreamSettings()
        settings.colorPreference = .forceSDR8
        let resumed = try await client.claimSession(
            sessionId: "fixture-session",
            serverIp: "203.0.113.10",
            token: "token",
            base: "https://region.example.invalid",
            settings: settings
        )
        settings.colorPreference = .preferHDR
        let different = try await client.claimSession(
            sessionId: "different-session",
            serverIp: "203.0.113.10",
            token: "token",
            base: "https://region.example.invalid",
            settings: settings
        )
        let requests = await transport.requests()
        let resumes = try requests.filter { $0.httpMethod == "PUT" }.map { request in
            let body = try jsonObject(from: request)
            return try #require(body["sessionRequestData"] as? [String: Any])
        }

        #expect(requests.map(\.httpMethod) == ["GET", "GET", "PUT", "GET", "PUT"])
        #expect(polled.acceptedSdrHdrMode == 1)
        #expect(resumed.acceptedSdrHdrMode == 1)
        #expect(different.acceptedSdrHdrMode == nil)
        try #require(resumes.count == 2)
        #expect(resumes[0]["sdrHdrMode"] as? Int == 1)
        #expect(resumes[1]["sdrHdrMode"] as? Int == 0)
    }

    @Test("Ad event uses injected timestamp and clamps negative durations")
    func reportAdEvent() async throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_123)
        let transport = RecordingHTTPTransport { _, _ in StubbedHTTPResponse() }
        let client = CloudMatchClient(
            transport: transport,
            deviceId: { "fixture-device" },
            now: { fixedDate }
        )

        await client.reportAdEvent(
            sessionId: "session",
            token: "token",
            base: "https://region.example.invalid",
            serverIp: nil,
            clientId: "client",
            deviceId: "device",
            adId: "ad",
            action: .finish,
            watchedTimeMs: -5,
            pausedTimeMs: 12
        )
        let request = try #require(await transport.requests().first)
        let root = try jsonObject(from: request)
        let updates = try #require(root["adUpdates"] as? [[String: Any]])
        let update = try #require(updates.first)

        #expect(request.httpMethod == "PUT")
        #expect(root["action"] as? Int == 6)
        #expect(update["adId"] as? String == "ad")
        #expect(update["adAction"] as? Int == AdAction.finish.rawValue)
        #expect(update["clientTimestamp"] as? Int == 1_700_000_123)
        #expect(update["watchedTimeInMs"] as? Int == 0)
        #expect(update["pausedTimeInMs"] as? Int == 12)
    }

    @Test("Cancellation reaches caller without state mutation")
    func cancellation() async {
        let transport = RecordingHTTPTransport { _, _ in throw CancellationError() }

        await #expect(throws: CancellationError.self) {
            _ = try await CloudMatchClient(
                transport: transport,
                deviceId: { "fixture-device" }
            ).getActiveSessions(
                token: "token",
                base: "https://region.example.invalid"
            )
        }
    }

    private func placeholderSessionResponse(controlHost: String?) throws -> Data {
        let response: [String: Any] = [
            "requestStatus": ["statusCode": 1],
            "session": [
                "sessionId": "session-id",
                "status": 1,
                "connectionInfo": [[
                    "usage": 14,
                    "ip": ".cloudmatchbeta.nvidiagrid.net",
                    "port": 443,
                    "resourcePath": "/nvst/",
                ]],
                "sessionControlInfo": ["ip": controlHost as Any? ?? NSNull()],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: response)
    }

    private func makeSessionRequest(
        audioFormat: AudioFormatPreference = .stereo,
        codec: VideoCodec = .h265,
        colorPreference: ColorModePreference = .forceSDR8,
        chromaFormat: ChromaFormat = .yuv444
    ) -> SessionCreateRequest {
        var settings = StreamSettings()
        settings.resolution = "3840x2160"
        settings.fps = 120
        settings.maxBitrateKbps = 100_000
        settings.codec = codec
        settings.colorPreference = colorPreference
        settings.chromaFormat = chromaFormat
        settings.keyboardLayout = "en-US"
        settings.gameLanguage = "en-US"
        settings.enableL4S = true
        settings.audioFormat = audioFormat
        settings.appLaunchMode = .default
        settings.persistInGameSettings = false
        let capabilities = LocalVideoCapabilities(
            supportsHardware10BitDecode: true,
            supportsHDRRendering: true,
            supportsExtendedDynamicRange: true,
            displaySupportsHDR: true,
            supportedPixelFormats: [],
            supportedCodecs: [.h264, .h265]
        )
        return SessionCreateRequest(
            appId: "12345",
            internalTitle: "Fixture Game",
            token: "fixture-token",
            streamingBaseUrl: "https://np-test.cloudmatchbeta.nvidiagrid.net/",
            routingZoneUrl: "https://np-test.cloudmatchbeta.nvidiagrid.net/",
            settings: settings,
            localVideoCapabilities: capabilities,
            accountLinked: true,
            accountAllowsHDR: true,
            skipNvidiaFallback: false
        )
    }
}
