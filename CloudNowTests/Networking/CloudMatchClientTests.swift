@testable import CloudNow
import Foundation
import Testing

@Suite("CloudMatch session HTTP client")
struct CloudMatchClientTests {
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
            #expect(monitor["widthInPixels"] as? Int == 2560)
            #expect(monitor["heightInPixels"] as? Int == 1440)
            #expect(monitor["framesPerSecond"] as? Int == 120)
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

    @Test("Stop waits for confirmed termination using the same endpoint and identity")
    func stopSessionWaitsForTermination() async throws {
        let transport = RecordingHTTPTransport { request, index in
            #expect(request.url?.absoluteString == "https://203.0.113.10/v2/session/session-id")
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
            return StubbedHTTPResponse(
                json: "{\"requestStatus\":{\"statusCode\":1},\"session\":{\"sessionId\":\"session-id\",\"status\":\(index == 1 ? 2 : 4)}}"
            )
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

    @Test("Stop confirms termination when subsequent polling finds no session", arguments: [404, 410])
    func stopSessionDisappears(statusCode: Int) async throws {
        let transport = RecordingHTTPTransport { request, index in
            #expect(request.httpMethod == (index == 0 ? "DELETE" : "GET"))
            return StubbedHTTPResponse(statusCode: index == 0 ? 204 : statusCode)
        }

        try await CloudMatchClient(transport: transport, sleep: { _ in }).stopSession(
            sessionId: "session-id",
            token: "token",
            base: "https://region.example.invalid"
        )

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

    @Test("Stop fails after bounded confirmation attempts when the session stays active")
    func stopSessionConfirmationTimeout() async {
        let transport = RecordingHTTPTransport { _, index in
            if index == 0 {
                return StubbedHTTPResponse(statusCode: 204)
            }
            return StubbedHTTPResponse(
                json: #"{"requestStatus":{"statusCode":1},"session":{"sessionId":"session-id","status":2}}"#
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
                json: #"{"requestStatus":{"statusCode":1},"session":{"sessionId":"session-id","status":2}}"#
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
        #expect(root["action"] as? Int == 2)
        #expect(requestData["appId"] as? Int == 12345)
        #expect(requestData["requestedStreamingFeatures"] == nil)
        #expect(requestData["clientRequestMonitorSettings"] == nil)
        #expect(requestData["audioMode"] as? Int == channels)
        #expect(requestData["surroundAudioInfo"] as? Int == surroundInfo)
        #expect(metadata.first { $0["key"] as? String == "surroundAudioInfo" }?["value"] as? String == "\(channels)")
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

    private func makeSessionRequest(
        audioFormat: AudioFormatPreference = .stereo,
        codec: VideoCodec = .h265,
        colorPreference: ColorModePreference = .forceSDR8,
        chromaFormat: ChromaFormat = .yuv444
    ) -> SessionCreateRequest {
        var settings = StreamSettings()
        settings.resolution = "2560x1440"
        settings.fps = 120
        settings.maxBitrateKbps = 75000
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
