@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox Cloud redacted RTC event log")
@MainActor
struct XboxCloudRTCEventLogTests {
    @Test("Event log is explicit, bounded, local, and allowlisted")
    func boundedRedactedLog() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = XboxCloudRedactedRTCEventLog(
            directory: directory,
            maximumFileBytes: 512,
            retainedFileCount: 2,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            makeIdentifier: {
                UUID(uuidString: "11111111-2222-3333-4444-555555555555")
                    ?? UUID()
            }
        )

        #expect(logger.activeURL == nil)
        let url = try #require(logger.start())
        #expect(logger.activeURL == url)
        for _ in 0 ..< 100 {
            logger.record(.peerPrepared)
        }
        logger.stop()

        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let byteCount = try #require(attributes[.size] as? NSNumber).intValue
        #expect(byteCount > 0)
        #expect(byteCount <= 512)
        #expect(logger.activeURL == nil)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("connection_started"))
        #expect(text.contains("peer_prepared"))
        #expect(!text.localizedCaseInsensitiveContains("token"))
        #expect(!text.localizedCaseInsensitiveContains("candidate"))
        #expect(!text.localizedCaseInsensitiveContains("sdp"))
        #expect(!text.localizedCaseInsensitiveContains("session"))
        #expect(!text.localizedCaseInsensitiveContains("account"))
    }

    @Test("Starting a new log prunes provider-owned files to the limit")
    func retainedFileLimit() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identifiers = [
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222",
            "33333333-3333-3333-3333-333333333333",
        ]

        for identifier in identifiers {
            let logger = XboxCloudRedactedRTCEventLog(
                directory: directory,
                maximumFileBytes: 1024,
                retainedFileCount: 2,
                now: { Date(timeIntervalSince1970: 1_700_000_000) },
                makeIdentifier: { UUID(uuidString: identifier) ?? UUID() }
            )
            #expect(logger.start() != nil)
            logger.record(.negotiationCompleted)
            logger.stop()
        }

        let logs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasPrefix("xbox-rtc-") }
        #expect(logs.count == 2)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "XboxRTCEventLogTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
