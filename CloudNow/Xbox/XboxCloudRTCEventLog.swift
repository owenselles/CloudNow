import Foundation
import os

private nonisolated let xboxRTCEventLog = Logger(
    subsystem: "com.owenselles.CloudNow2",
    category: "XboxRTCEventLog"
)

/// Allowlisted RTC lifecycle events. The file logger intentionally accepts no
/// arbitrary strings, URLs, SDP, ICE candidates, tokens, channel payloads, or
/// account/session identifiers, so sensitive service data cannot enter it.
nonisolated enum XboxCloudRTCEvent: String, Codable, Sendable {
    case connectionFailed = "connection_failed"
    case connectionStarted = "connection_started"
    case connectionStopped = "connection_stopped"
    case mediaConnected = "media_connected"
    case negotiationCompleted = "negotiation_completed"
    case peerPrepared = "peer_prepared"
}

@MainActor
protocol XboxCloudRTCEventLogging: AnyObject, Sendable {
    var activeURL: URL? { get }

    @discardableResult
    func start() -> URL?
    func record(_ event: XboxCloudRTCEvent)
    func stop()
}

/// Local, bounded and redacted Xbox RTC lifecycle log. Raw WebRTC event logs
/// can contain network candidates, so Xbox diagnostics record only allowlisted
/// lifecycle events rather than persisting native SDP/ICE traffic.
@MainActor
final class XboxCloudRedactedRTCEventLog: XboxCloudRTCEventLogging {
    static let standardMaximumFileBytes = 1_048_576
    static let standardRetainedFileCount = 2

    private struct Record: Encodable {
        let timestamp: Date
        let event: XboxCloudRTCEvent
    }

    private let directory: URL?
    private let fileManager: FileManager
    private let maximumFileBytes: Int
    private let retainedFileCount: Int
    private let now: @Sendable () -> Date
    private let makeIdentifier: @Sendable () -> UUID
    private let encoder: JSONEncoder
    private var fileHandle: FileHandle?
    private var writtenByteCount = 0

    private(set) var activeURL: URL?

    init(
        directory: URL? = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent(
            "XboxRTCEventLogs",
            isDirectory: true
        ),
        fileManager: FileManager = .default,
        maximumFileBytes: Int = standardMaximumFileBytes,
        retainedFileCount: Int = standardRetainedFileCount,
        now: @escaping @Sendable () -> Date = Date.init,
        makeIdentifier: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.maximumFileBytes = max(1, maximumFileBytes)
        self.retainedFileCount = max(1, retainedFileCount)
        self.now = now
        self.makeIdentifier = makeIdentifier
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    @discardableResult
    func start() -> URL? {
        stop()
        guard let directory else { return nil }

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try pruneLogs(
                in: directory,
                keeping: max(0, retainedFileCount - 1)
            )
            let url = directory.appendingPathComponent(filename())
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                return nil
            }
            fileHandle = try FileHandle(forWritingTo: url)
            activeURL = url
            writtenByteCount = 0
            record(.connectionStarted)
            return activeURL
        } catch {
            closeFile()
            xboxRTCEventLog.warning(
                "Unable to start redacted Xbox RTC event log: \(error, privacy: .private)"
            )
            return nil
        }
    }

    func record(_ event: XboxCloudRTCEvent) {
        guard let fileHandle else { return }
        do {
            var data = try encoder.encode(
                Record(timestamp: now(), event: event)
            )
            data.append(0x0A)
            guard writtenByteCount + data.count <= maximumFileBytes else {
                closeFile()
                return
            }
            try fileHandle.write(contentsOf: data)
            writtenByteCount += data.count
        } catch {
            closeFile()
            xboxRTCEventLog.warning(
                "Unable to append redacted Xbox RTC event log: \(error, privacy: .private)"
            )
        }
    }

    func stop() {
        guard fileHandle != nil else { return }
        record(.connectionStopped)
        closeFile()
    }

    isolated deinit {
        closeFile()
    }

    private func closeFile() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
        activeURL = nil
        writtenByteCount = 0
    }

    private func filename() -> String {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: now())
            .replacingOccurrences(of: ":", with: "-")
        return "xbox-rtc-\(timestamp)-\(makeIdentifier().uuidString).jsonl"
    }

    private func pruneLogs(in directory: URL, keeping count: Int) throws {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .creationDateKey,
            .isRegularFileKey,
        ]
        let logs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard url.lastPathComponent.hasPrefix("xbox-rtc-") else {
                return false
            }
            return (try? url.resourceValues(forKeys: keys).isRegularFile)
                == true
        }
        let sorted = logs.sorted { lhs, rhs in
            let left = try? lhs.resourceValues(forKeys: keys)
            let right = try? rhs.resourceValues(forKeys: keys)
            let leftDate = left?.contentModificationDate
                ?? left?.creationDate
                ?? .distantPast
            let rightDate = right?.contentModificationDate
                ?? right?.creationDate
                ?? .distantPast
            return leftDate > rightDate
        }
        for url in sorted.dropFirst(count) {
            try fileManager.removeItem(at: url)
        }
    }
}
