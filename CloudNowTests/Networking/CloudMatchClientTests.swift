@testable import CloudNow
import Foundation
import Testing

@Suite("CloudMatch session HTTP client")
struct CloudMatchClientTests {
    @Test("Session creation maps stream settings into deterministic request fields")
    func createSessionRequest() async throws {
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
            #expect(session["audioMode"] as? Int == 2)
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

        let session = try await client.createSession(makeSessionRequest())

        #expect(session.sessionId == "fixture-session")
        #expect(session.status == 2)
        #expect(session.zone == "https://np-test.cloudmatchbeta.nvidiagrid.net/")
        #expect(session.serverIp == "203.0.113.10")
        #expect(session.signalingUrl == "wss://203.0.113.10:443/nvst/")
        #expect(session.mediaConnectionInfo?.ip == "203.0.113.11")
        #expect(session.mediaConnectionInfo?.port == 49005)
        #expect(session.iceServers.first?.urls == ["stun:stun.example.invalid:3478"])
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
            accountAllowsHDR: input.accountAllowsHDR
        )

        let session = try await client.createSession(input)

        #expect(session.streamingBaseUrl == "https://prod.cloudmatchbeta.nvidiagrid.net")
        #expect(session.zone.isEmpty)
        #expect(await transport.requests().count == 2)
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

    @Test("Claim sends a minimal resume body after ready preflight")
    func claimReadySession() async throws {
        let fixture = try NetworkingFixture.data("cloudmatch-session.json")
        let transport = RecordingHTTPTransport { _, _ in StubbedHTTPResponse(data: fixture) }
        var settings = StreamSettings()
        settings.audioFormat = .stereo
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

        #expect(requests.count == 2)
        #expect(resume.httpMethod == "PUT")
        #expect(root["action"] as? Int == 2)
        #expect(requestData["appId"] as? Int == 12345)
        #expect(requestData["requestedStreamingFeatures"] == nil)
        #expect(requestData["clientRequestMonitorSettings"] == nil)
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

    private func makeSessionRequest() -> SessionCreateRequest {
        var settings = StreamSettings()
        settings.resolution = "2560x1440"
        settings.fps = 120
        settings.maxBitrateKbps = 75000
        settings.codec = .h265
        settings.colorPreference = .forceSDR8
        settings.keyboardLayout = "en-US"
        settings.gameLanguage = "en-US"
        settings.enableL4S = true
        settings.audioFormat = .stereo
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
            accountAllowsHDR: true
        )
    }
}
