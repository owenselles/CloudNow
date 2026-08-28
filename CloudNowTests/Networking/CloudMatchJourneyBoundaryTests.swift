@testable import CloudNow
import Foundation
import Testing

@Suite("CloudMatch journey boundaries")
struct CloudMatchJourneyBoundaryTests {
    @Test("A queued claim stays read-only until the session is ready")
    func queuedClaimDoesNotResume() async throws {
        let transport = RecordingHTTPTransport { request, index in
            #expect(index == 0)
            #expect(request.httpMethod == "GET")
            #expect(
                request.url?.absoluteString
                    == "https://203.0.113.10/v2/session/queued-session"
            )
            return StubbedHTTPResponse(
                json: #"{"requestStatus":{"statusCode":1},"session":{"sessionId":"queued-session","status":1,"queuePosition":7,"seatSetupStep":2}}"#
            )
        }
        let client = CloudMatchClient(
            transport: transport,
            deviceId: { "fixture-device" }
        )

        let session = try await client.claimSession(
            sessionId: "queued-session",
            serverIp: "203.0.113.10",
            token: "fixture-token",
            base: "https://region.example.invalid",
            clientId: "fixture-client",
            deviceId: "fixture-device",
            appId: "12345",
            settings: StreamSettings()
        )

        #expect(session.status == 1)
        #expect(session.queuePosition == 7)
        #expect(session.seatSetupStep == 2)
        let requests = await transport.requests()
        #expect(requests.count == 1)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test(
        "App-scoped cleanup skips other titles and continues after a failed delete"
    )
    func appScopedCleanup() async {
        let activeSessionsJSON = #"{"requestStatus":{"statusCode":1},"sessions":[{"sessionId":"target-a","status":2,"sessionRequestData":{"appId":"12345"},"connectionInfo":[{"ip":"203.0.113.21","port":443,"usage":14,"resourcePath":"/nvst/"}]},{"sessionId":"other-title","status":2,"sessionRequestData":{"appId":"99999"},"connectionInfo":[{"ip":"203.0.113.22","port":443,"usage":14,"resourcePath":"/nvst/"}]},{"sessionId":"target-b","status":3,"sessionRequestData":{"appId":12345},"connectionInfo":[{"ip":"203.0.113.23","port":443,"usage":14,"resourcePath":"/nvst/"}]}]}"#
        let transport = RecordingHTTPTransport { request, index in
            switch index {
            case 0:
                #expect(request.httpMethod == "GET")
                return StubbedHTTPResponse(json: activeSessionsJSON)
            case 1:
                #expect(request.httpMethod == "DELETE")
                #expect(request.url?.host == "203.0.113.21")
                #expect(request.url?.path == "/v2/session/target-a")
                return StubbedHTTPResponse(
                    statusCode: 503,
                    json: #"{"error":"temporary"}"#
                )
            case 2:
                #expect(request.httpMethod == "DELETE")
                #expect(request.url?.host == "203.0.113.23")
                #expect(request.url?.path == "/v2/session/target-b")
                return StubbedHTTPResponse(statusCode: 204)
            default:
                throw TestTransportError.unexpectedRequest(
                    "Unexpected cleanup request \(index)"
                )
            }
        }
        let client = CloudMatchClient(
            transport: transport,
            deviceId: { "fixture-device" }
        )

        await client.stopActiveSessions(
            matchingAppId: "12345",
            token: "fixture-token",
            base: "https://region.example.invalid"
        )

        let requests = await transport.requests()
        #expect(requests.count == 3)
        #expect(
            !requests.contains {
                $0.url?.path == "/v2/session/other-title"
            }
        )
    }

    @Test("Queue ad variants resolve into a playable preferred media order")
    func queueAdVariants() async throws {
        let responseJSON = #"{"requestStatus":{"statusCode":1},"session":{"sessionId":"ad-session","status":1,"sessionAdsRequired":1,"opportunity":{"queuePaused":true,"gracePeriodSeconds":12,"description":"Sponsored break"},"sessionAds":[{"adUrl":"https://ads.example.invalid/details","durationMs":"2500","adMediaFiles":[{"mediaFileUrl":"https://ads.example.invalid/ad.m3u8","encodingProfile":"hlsAdaptive"},{"mediaFileUrl":"https://ads.example.invalid/ad-720.mp4","encodingProfile":"mp4Deinterlaced720p"},{"mediaFileUrl":"https://ads.example.invalid/ad.webm","encodingProfile":"webm"},{"ignored":"entry"}]},{"adId":"second-ad","videoUrl":"https://ads.example.invalid/second.mp4","durationInMs":4000}]}}"#
        let transport = RecordingHTTPTransport { _, _ in
            StubbedHTTPResponse(json: responseJSON)
        }
        let client = CloudMatchClient(
            transport: transport,
            deviceId: { "fixture-device" }
        )

        let session = try await client.pollSession(
            sessionId: "ad-session",
            token: "fixture-token",
            base: "https://region.example.invalid",
            serverIp: nil,
            clientId: "fixture-client",
            deviceId: "fixture-device"
        )
        let adState = try #require(session.adState)
        let firstAd = try #require(adState.ads.first)
        let secondAd = try #require(adState.ads.last)

        #expect(adState.isAdsRequired)
        #expect(adState.isQueuePaused == true)
        #expect(adState.gracePeriodSeconds == 12)
        #expect(adState.message == "Sponsored break")
        #expect(adState.ads.count == 2)
        #expect(firstAd.adId == "ad-1")
        #expect(firstAd.adLengthInSeconds == 2.5)
        #expect(
            firstAd.adMediaFiles.compactMap(\.encodingProfile) == [
                "mp4Deinterlaced720p",
                "webm",
                "hlsAdaptive",
            ]
        )
        #expect(
            firstAd.preferredMediaURL?.absoluteString
                == "https://ads.example.invalid/ad-720.mp4"
        )
        #expect(secondAd.adLengthInSeconds == 4)
        #expect(
            secondAd.preferredMediaURL?.absoluteString
                == "https://ads.example.invalid/second.mp4"
        )
    }
}
