@testable import CloudNow
import Foundation
import Testing

@Suite("GFN session countdown")
struct GFNSessionCountdownTests {
    struct TierCase: Sendable {
        let membershipTier: String?
        let expectedSeconds: Int?
    }

    struct WarningCase: Sendable {
        let rawCode: Int
        let expectedCode: Int
        let reportsSessionLimit: Bool
    }

    @Test(
        "Membership tiers map to fixed session lengths",
        arguments: [
            TierCase(membershipTier: "FREE", expectedSeconds: 3600),
            TierCase(membershipTier: "Performance", expectedSeconds: 21600),
            TierCase(membershipTier: "legacy priority member", expectedSeconds: 21600),
            TierCase(membershipTier: "Founders", expectedSeconds: 21600),
            TierCase(membershipTier: "GFN_ULTIMATE", expectedSeconds: 28800),
            TierCase(membershipTier: "unknown", expectedSeconds: nil),
            TierCase(membershipTier: nil, expectedSeconds: nil),
        ]
    )
    func membershipTierSessionLength(testCase: TierCase) {
        #expect(
            GFNSessionLimit.seconds(for: testCase.membershipTier)
                == testCase.expectedSeconds
        )
    }

    @Test("Countdown derives its deadline from tier and stream start")
    func tierDeadline() throws {
        let startedAt = Date(timeIntervalSince1970: 1000)
        let countdown = try #require(
            GFNSessionCountdown(
                membershipTier: "Ultimate",
                startedAt: startedAt
            )
        )

        #expect(countdown.endsAt == Date(timeIntervalSince1970: 29800))
    }

    @Test("Warning appears at configured threshold and expires at zero")
    func warningVisibility() throws {
        let startedAt = Date(timeIntervalSince1970: 1000)
        let countdown = try #require(
            GFNSessionCountdown(
                membershipTier: "Free",
                startedAt: startedAt
            )
        )

        #expect(
            !countdown.shouldShow(
                at: Date(timeIntervalSince1970: 3699),
                warningMinutes: 15
            )
        )
        #expect(
            countdown.shouldShow(
                at: Date(timeIntervalSince1970: 3700),
                warningMinutes: 15
            )
        )
        #expect(
            countdown.shouldShow(
                at: Date(timeIntervalSince1970: 4599),
                warningMinutes: 15
            )
        )
        #expect(
            !countdown.shouldShow(
                at: Date(timeIntervalSince1970: 4600),
                warningMinutes: 15
            )
        )
    }

    @Test("Displayed minutes count down without reaching zero early")
    func displayedMinutes() throws {
        let countdown = try #require(
            GFNSessionCountdown(
                secondsLeft: 900,
                receivedAt: Date(timeIntervalSince1970: 1000)
            )
        )

        #expect(
            countdown.minutesRemaining(
                at: Date(timeIntervalSince1970: 1000)
            ) == 15
        )
        #expect(
            countdown.minutesRemaining(
                at: Date(timeIntervalSince1970: 1001)
            ) == 15
        )
        #expect(
            countdown.minutesRemaining(
                at: Date(timeIntervalSince1970: 1060)
            ) == 14
        )
        #expect(
            countdown.minutesRemaining(
                at: Date(timeIntervalSince1970: 1899)
            ) == 1
        )
        #expect(
            countdown.minutesRemaining(
                at: Date(timeIntervalSince1970: 1900)
            ) == 0
        )
    }

    @Test("Server warning resynchronizes estimated deadline")
    func serverResynchronization() throws {
        let countdown = try #require(
            GFNSessionCountdown(
                membershipTier: "Free",
                startedAt: Date(timeIntervalSince1970: 1000)
            )
        )

        let synchronized = countdown.synchronized(
            secondsLeft: 275,
            receivedAt: Date(timeIntervalSince1970: 2000)
        )

        #expect(synchronized.endsAt == Date(timeIntervalSince1970: 2275))
        #expect(
            countdown.synchronized(
                secondsLeft: -1,
                receivedAt: Date(timeIntervalSince1970: 2000)
            ) == countdown
        )
    }

    @Test("Persisted sessions retain their original countdown anchor on resume")
    func persistedSessionAnchor() throws {
        let createdAt = Date(timeIntervalSince1970: 1000)
        let startedAt = Date(timeIntervalSince1970: 1100)
        let record = LastSessionRecord(
            sessionId: "session",
            serverIp: "192.0.2.1",
            appId: "app",
            base: "https://stream.example.invalid",
            routingZoneUrl: nil,
            clientId: "client",
            deviceId: "device",
            createdAt: createdAt,
            idpId: "provider",
            userId: "user"
        ).recordingSessionStart(startedAt)

        let decoded = try JSONDecoder().decode(
            LastSessionRecord.self,
            from: JSONEncoder().encode(record)
        )

        #expect(decoded.createdAt == createdAt)
        #expect(decoded.sessionStartedAt == startedAt)
    }

    @Test(
        "Server timer codes map to warning severity",
        arguments: [
            WarningCase(rawCode: 1, expectedCode: 1, reportsSessionLimit: true),
            WarningCase(rawCode: 2, expectedCode: 1, reportsSessionLimit: true),
            WarningCase(rawCode: 4, expectedCode: 2, reportsSessionLimit: false),
            WarningCase(rawCode: 6, expectedCode: 3, reportsSessionLimit: true),
        ]
    )
    func timerNotificationParsing(testCase: WarningCase) throws {
        let data = Data(
            """
            {"timerNotification":{"code":\(testCase.rawCode),"secondsLeft":300}}
            """.utf8
        )

        let warning = try #require(
            StreamTimeWarning(timerNotificationData: data)
        )
        #expect(warning.code == testCase.expectedCode)
        #expect(warning.secondsLeft == 300)
        #expect(warning.reportsSessionLimit == testCase.reportsSessionLimit)
    }

    @Test("Invalid server timer payloads do not create countdown anchors")
    func invalidTimerNotifications() throws {
        let unsupportedCode = Data(
            #"{"timerNotification":{"code":99,"secondsLeft":300}}"#.utf8
        )
        let negativeSeconds = Data(
            #"{"timerNotification":{"code":6,"secondsLeft":-1}}"#.utf8
        )

        #expect(
            StreamTimeWarning(timerNotificationData: unsupportedCode) == nil
        )
        let warning = try #require(
            StreamTimeWarning(timerNotificationData: negativeSeconds)
        )
        #expect(warning.secondsLeft == nil)
    }
}
