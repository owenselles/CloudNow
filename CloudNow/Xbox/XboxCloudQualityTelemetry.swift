import Foundation
import os
import Synchronization

private nonisolated let xboxQualityTelemetryLog = Logger(
    subsystem: "com.owenselles.CloudNow2",
    category: "XboxQualityBeta"
)

nonisolated enum XboxQualityBetaBuild {
    #if XBOX_QUALITY_BETA
        static let isEnabled = true
    #else
        static let isEnabled = false
    #endif
}

// xbox-quality-beta-coverage:telemetry-sanitization:start
/// Fixed identifiers keep profile telemetry useful without accepting arbitrary
/// strings that could accidentally contain account or session information.
nonisolated enum XboxCloudQualityTelemetryProfile: String, Sendable {
    case microsoftWeb = "xbox-web-www-29.19.17-sdk-10.6.57"
    case nativeTV = "xbox-native-tvos-control-v1"
    case unknown

    init(identifier: String) {
        self = Self(rawValue: identifier) ?? .unknown
    }
}

nonisolated enum XboxCloudQualityTelemetryCodec: String, Sendable {
    case av1
    case h264
    case h265
    case multiopus
    case opus
    case unknown
    case vp8
    case vp9

    init(name: String) {
        let normalized = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        self = switch normalized {
        case "av1", "av1x": .av1
        case "h264": .h264
        case "h265", "hevc": .h265
        case "multiopus": .multiopus
        case "opus": .opus
        case "vp8": .vp8
        case "vp9": .vp9
        default: .unknown
        }
    }
}

nonisolated enum XboxCloudQualityDisplaySignal: String, Sendable {
    case allocationHeader = "allocation_header"
    case messageDimensions = "message_dimensions"
}

/// Sanitized codec and resolution-limit summary. Raw SDP never leaves the
/// parser and is never retained or logged.
nonisolated struct XboxCloudQualitySDPSummary: Equatable, Sendable {
    let videoCodecs: [XboxCloudQualityTelemetryCodec]
    let audioCodecs: [XboxCloudQualityTelemetryCodec]
    let firstVideoCodec: XboxCloudQualityTelemetryCodec?
    let firstAudioCodec: XboxCloudQualityTelemetryCodec?
    let firstAudioChannels: Int?
    let hasImageAttribute: Bool
    let hasMaximumFrameSize: Bool

    init(sdp: String) {
        let lines = sdp.split(whereSeparator: \.isNewline).map(String.init)
        var codecByPayload: [String: (XboxCloudQualityTelemetryCodec, Int?)] = [:]
        for line in lines {
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.lowercased().hasPrefix("a=rtpmap:"),
                  let separator = normalized.firstIndex(of: " ")
            else {
                continue
            }
            let payloadStart = normalized.index(
                normalized.startIndex,
                offsetBy: "a=rtpmap:".count
            )
            let payload = String(normalized[payloadStart ..< separator])
            let mapping = normalized[normalized.index(after: separator)...]
                .split(separator: "/")
            guard let codecName = mapping.first else { continue }
            let channels = mapping.count >= 3 ? Int(mapping[2]) : nil
            codecByPayload[payload] = (
                XboxCloudQualityTelemetryCodec(name: String(codecName)),
                channels
            )
        }

        let videoPayloads = Self.payloads(for: "video", in: lines)
        let audioPayloads = Self.payloads(for: "audio", in: lines)
        videoCodecs = Self.uniqueCodecs(videoPayloads, mapping: codecByPayload)
        audioCodecs = Self.uniqueCodecs(audioPayloads, mapping: codecByPayload)
        firstVideoCodec = videoPayloads.compactMap { codecByPayload[$0]?.0 }.first
        firstAudioCodec = audioPayloads.compactMap { codecByPayload[$0]?.0 }.first
        firstAudioChannels = audioPayloads.compactMap { codecByPayload[$0]?.1 }.first
        let normalizedSDP = sdp.lowercased()
        hasImageAttribute = normalizedSDP.contains("a=imageattr:")
        hasMaximumFrameSize = normalizedSDP.contains("max-fs=")
    }

    private static func payloads(for media: String, in lines: [String]) -> [String] {
        guard let line = lines.first(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().hasPrefix("m=\(media) ")
        }) else {
            return []
        }
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count > 3 else { return [] }
        return fields.dropFirst(3).map(String.init)
    }

    private static func uniqueCodecs(
        _ payloads: [String],
        mapping: [String: (XboxCloudQualityTelemetryCodec, Int?)]
    ) -> [XboxCloudQualityTelemetryCodec] {
        var seen = Set<XboxCloudQualityTelemetryCodec>()
        return payloads.compactMap { mapping[$0]?.0 }.filter {
            seen.insert($0).inserted
        }
    }
}

// xbox-quality-beta-coverage:telemetry-sanitization:end

nonisolated enum XboxCloudQualityTelemetryEvent: Equatable, Sendable {
    case compatibilityProfile(XboxCloudQualityTelemetryProfile)
    case display(
        signal: XboxCloudQualityDisplaySignal,
        width: Int,
        height: Int,
        pixelDensity: Double
    )
    case localOffer(XboxCloudQualitySDPSummary)
    case qualityRequest(
        resolution: XboxCloudDisplayResolution,
        maximumBitrateKbps: Int?
    )
    case remoteAnswer(XboxCloudQualitySDPSummary)
    case streamDelivery(
        width: Int,
        height: Int,
        framesPerSecond: Int,
        bitrateKbps: Int,
        codec: XboxCloudQualityTelemetryCodec,
        colorMode: DetectedColorMode?,
        audioChannels: Int
    )
}

// xbox-quality-beta-coverage:telemetry-buffer:start
/// Process-local, fixed-capacity Xbox quality trace. The event model contains
/// only allowlisted enums and bounded numeric media facts; no endpoint, SDP,
/// ICE, credential, account, session, or data-channel payload can be stored.
final nonisolated class XboxCloudQualityTelemetry: Sendable {
    static let shared = XboxCloudQualityTelemetry(
        isEnabled: XboxQualityBetaBuild.isEnabled
    )

    private struct State: Sendable {
        var records: [XboxCloudQualityTelemetryEvent] = []
    }

    private let isEnabled: Bool
    private let maximumRecordCount: Int
    private let state = Mutex(State())

    init(isEnabled: Bool, maximumRecordCount: Int = 256) {
        self.isEnabled = isEnabled
        self.maximumRecordCount = max(1, maximumRecordCount)
    }

    func record(_ event: XboxCloudQualityTelemetryEvent) {
        guard isEnabled else { return }
        state.withLock { state in
            if state.records.count == maximumRecordCount {
                state.records.removeFirst()
            }
            state.records.append(event)
        }
        log(event)
    }

    func snapshot() -> [XboxCloudQualityTelemetryEvent] {
        state.withLock { $0.records }
    }

    func reset() {
        state.withLock { $0.records.removeAll(keepingCapacity: true) }
    }

    // xbox-quality-beta-coverage:telemetry-buffer:end

    private func log(_ event: XboxCloudQualityTelemetryEvent) {
        switch event {
        case let .compatibilityProfile(profile):
            xboxQualityTelemetryLog.notice(
                "profile=\(profile.rawValue, privacy: .public)"
            )
        case let .display(signal, width, height, density):
            xboxQualityTelemetryLog.notice(
                "display signal=\(signal.rawValue, privacy: .public) size=\(width, privacy: .public)x\(height, privacy: .public) density=\(density, privacy: .public)"
            )
        case let .localOffer(summary):
            xboxQualityTelemetryLog.notice(
                "offer video=\(Self.codecList(summary.videoCodecs), privacy: .public) audio=\(Self.codecList(summary.audioCodecs), privacy: .public) imageattr=\(summary.hasImageAttribute, privacy: .public) maxFs=\(summary.hasMaximumFrameSize, privacy: .public)"
            )
        case let .qualityRequest(resolution, maximumBitrateKbps):
            xboxQualityTelemetryLog.notice(
                "request resolution=\(resolution.rawValue, privacy: .public) bandwidthKbps=\(maximumBitrateKbps ?? 0, privacy: .public)"
            )
        case let .remoteAnswer(summary):
            xboxQualityTelemetryLog.notice(
                "answer video=\(summary.firstVideoCodec?.rawValue ?? "unknown", privacy: .public) audio=\(summary.firstAudioCodec?.rawValue ?? "unknown", privacy: .public)/\(summary.firstAudioChannels ?? 0, privacy: .public)"
            )
        case let .streamDelivery(width, height, fps, bitrateKbps, codec, colorMode, audioChannels):
            xboxQualityTelemetryLog.notice(
                "delivery=\(width, privacy: .public)x\(height, privacy: .public) fps=\(fps, privacy: .public) bitrateKbps=\(bitrateKbps, privacy: .public) codec=\(codec.rawValue, privacy: .public) color=\(colorMode?.rawValue ?? "unknown", privacy: .public) audioChannels=\(audioChannels, privacy: .public)"
            )
        }
    }

    private static func codecList(
        _ codecs: [XboxCloudQualityTelemetryCodec]
    ) -> String {
        codecs.map(\.rawValue).joined(separator: ",")
    }
}
