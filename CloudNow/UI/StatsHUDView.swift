import SwiftUI

/// In-game statistics HUD mirroring the official GeForce NOW overlay. Compact shows
/// the three headline metrics and server, while Standard adds the release statistics
/// in one narrow column. Developer diagnostics append a final section to that column.
struct StatsHUDView: View {
    let streamController: GFNStreamController
    let microphoneEnabled: Bool
    let automaticServerId: String?

    var body: some View {
        Group {
            switch streamController.statsMode {
            case .off:
                EmptyView()
            case .compact:
                CompactStatsPanel(
                    stats: streamController.stats,
                    microphoneEnabled: microphoneEnabled,
                    serverLocation: serverLocation
                )
            case .standard:
                StandardStatsPanel(
                    stats: streamController.stats,
                    audioStats: streamController.audioStats,
                    colorState: streamController.colorState,
                    streamingStartedAt: streamController.streamingStartedAt,
                    microphoneEnabled: microphoneEnabled,
                    serverLocation: serverLocation,
                    diagnosticsEnabled: streamController.diagnosticsEnabled,
                    rtcEventLogActive: streamController.rtcEventLogURL != nil
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("statistics_level", streamController.statsMode.label))
    }

    private var serverLocation: String {
        let routedLocation = streamController.stats.serverZone.trimmingCharacters(in: .whitespacesAndNewlines)
        if !routedLocation.isEmpty {
            return routedLocation
        }

        let automaticLocation = automaticServerId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        return automaticLocation.isEmpty ? L10n.text("unknown") : automaticLocation
    }
}

private struct CompactStatsPanel: View {
    let stats: StreamStats
    let microphoneEnabled: Bool
    let serverLocation: String

    var body: some View {
        StatsPanel(contentWidth: StatsHUDLayout.columnWidth) {
            StatsPanelHeader(gpuName: gpuName, microphoneEnabled: microphoneEnabled)
            HeadlineMetricsView(stats: stats, contentWidth: StatsHUDLayout.columnWidth)
            Text(serverLocation)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StatsHUDPalette.secondaryText)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(StatsHUDPalette.metricBackground, ignoresSafeAreaEdges: [])
                .accessibilityLabel(L10n.text("server_location"))
                .accessibilityValue(serverLocation)
        }
    }

    private var gpuName: String {
        stats.gpuType.isEmpty ? L10n.text("gpu") : stats.gpuType
    }
}

private struct StandardStatsPanel: View {
    let stats: StreamStats
    let audioStats: AudioStats
    let colorState: StreamColorState
    let streamingStartedAt: Date?
    let microphoneEnabled: Bool
    let serverLocation: String
    let diagnosticsEnabled: Bool
    let rtcEventLogActive: Bool

    var body: some View {
        StatsPanel(contentWidth: StatsHUDLayout.columnWidth) {
            StatsPanelHeader(gpuName: gpuName, microphoneEnabled: microphoneEnabled)
            HeadlineMetricsView(stats: stats, contentWidth: StatsHUDLayout.columnWidth)
            VStack(alignment: .leading, spacing: 0) {
                CoreStatsColumn(
                    stats: stats,
                    audioStats: audioStats,
                    colorState: colorState,
                    streamingStartedAt: streamingStartedAt,
                    serverLocation: serverLocation
                )
                .frame(width: StatsHUDLayout.columnWidth, alignment: .topLeading)

                if showsDebugColumn {
                    Divider()
                        .overlay(StatsHUDPalette.divider, ignoresSafeAreaEdges: [])

                    DebugStatsColumn(
                        stats: stats,
                        colorState: colorState,
                        rtcEventLogActive: rtcEventLogActive
                    )
                    .frame(width: StatsHUDLayout.columnWidth, alignment: .topLeading)
                }
            }
        }
    }

    private var showsDebugColumn: Bool {
        #if DEBUG
            diagnosticsEnabled
        #else
            false
        #endif
    }

    private var gpuName: String {
        stats.gpuType.isEmpty ? L10n.text("gpu") : stats.gpuType
    }
}

private struct StatsPanel<Content: View>: View {
    let contentWidth: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: StatsHUDLayout.panelSpacing) {
            content
        }
        .frame(width: contentWidth, alignment: .topLeading)
        .padding(StatsHUDLayout.panelPadding)
        .background(StatsHUDPalette.panelBackground(for: colorScheme), ignoresSafeAreaEdges: [])
    }
}

private struct StatsPanelHeader: View {
    let gpuName: String
    let microphoneEnabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(StatsHUDPalette.accent)
                .frame(width: 6, height: 32)
                .accessibilityHidden(true)

            Text(gpuName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StatsHUDPalette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 8)

            MicrophoneStatusView(isRequested: microphoneEnabled)
        }
        .frame(height: 36)
    }
}

private struct MicrophoneStatusView: View {
    let isRequested: Bool
    @State private var activity = MicrophoneActivitySnapshot(isCapturing: false, level: 0)
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            MicrophoneActivityBar(
                level: isCapturing ? activity.level : 0,
                isActive: isCapturing
            )

            Image(systemName: isCapturing ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(StatsHUDPalette.primaryText)
                .frame(width: 34, height: 34)
                .background(
                    StatsHUDPalette.microphoneBackground(for: colorScheme),
                    ignoresSafeAreaEdges: []
                )
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(StatsHUDPalette.microphoneActive)
                        .frame(width: 7, height: 7)
                        .padding(3)
                        .opacity(isCapturing ? 1 : 0)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("microphone"))
        .accessibilityValue(L10n.text(isCapturing ? "on" : "off"))
        .task(id: isRequested) {
            guard isRequested else {
                activity = MicrophoneActivitySnapshot(isCapturing: false, level: 0)
                return
            }
            while !Task.isCancelled {
                let next = GFNAudioDevice.shared.microphoneTelemetry.snapshot
                if shouldPresent(next) {
                    activity = next
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private var isCapturing: Bool {
        isRequested && activity.isCapturing
    }

    private func shouldPresent(_ next: MicrophoneActivitySnapshot) -> Bool {
        next.isCapturing != activity.isCapturing
            || abs(next.level - activity.level) >= 0.015
            || next.level == 0 && activity.level != 0
    }
}

private struct MicrophoneActivityBar: View {
    let level: Double
    let isActive: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(StatsHUDPalette.microphoneTrack)
            Capsule()
                .fill(StatsHUDPalette.microphoneActive)
                .scaleEffect(x: min(1, max(0, level)), anchor: .leading)
                .opacity(isActive ? 1 : 0)
        }
        .frame(width: 28, height: 4)
        .animation(.linear(duration: 0.05), value: level)
        .accessibilityHidden(true)
    }
}

private struct HeadlineMetricsView: View {
    let stats: StreamStats
    let contentWidth: CGFloat

    var body: some View {
        HStack(spacing: StatsHUDLayout.metricSpacing) {
            HeadlineMetricCard(
                value: gameFPS,
                unit: "(\(L10n.text("fps").uppercased()))",
                label: L10n.text("game").uppercased(),
                valueColor: StatsHUDPalette.primaryText,
                width: metricWidth
            )
            HeadlineMetricCard(
                value: streamFPS,
                unit: "(\(L10n.text("fps").uppercased()))",
                label: L10n.text("hud_stream"),
                valueColor: StatsHUDPalette.primaryText,
                width: metricWidth
            )
            HeadlineMetricCard(
                value: ping,
                unit: "(ms)",
                label: L10n.text("hud_ping"),
                valueColor: stats.rttMs > 0
                    ? StatsFormat.pingColor(stats.rttMs)
                    : StatsHUDPalette.primaryText,
                width: metricWidth
            )
        }
        .frame(width: contentWidth, alignment: .leading)
    }

    private var gameFPS: String {
        stats.gameFps > 0 ? String(Int(stats.gameFps.rounded())) : "–"
    }

    private var streamFPS: String {
        stats.fps > 0 ? String(Int(stats.fps.rounded())) : "–"
    }

    private var ping: String {
        stats.rttMs > 0 ? String(Int(stats.rttMs.rounded())) : "–"
    }

    private var metricWidth: CGFloat {
        (contentWidth - StatsHUDLayout.metricSpacing * 2) / 3
    }
}

private struct HeadlineMetricCard: View {
    let value: String
    let unit: String
    let label: String
    let valueColor: Color
    let width: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(valueColor)
                .monospacedDigit()
            Text(unit)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StatsHUDPalette.secondaryText)
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(StatsHUDPalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: width, height: 88)
        .background(StatsHUDPalette.metricBackground, ignoresSafeAreaEdges: [])
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value) \(unit)")
    }
}

private struct CoreStatsColumn: View {
    let stats: StreamStats
    let audioStats: AudioStats
    let colorState: StreamColorState
    let streamingStartedAt: Date?
    let serverLocation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatsSection(title: L10n.text("network")) {
                StatsRow(
                    label: L10n.text("jitter_loss"),
                    value: String(format: "%.1f ms / %.1f %%", stats.jitterMs, stats.packetLossPercent)
                )
                StatsRow(label: L10n.text("bitrate"), value: bitrateValue)
                StatsRow(
                    label: L10n.text("connection"),
                    value: L10n.text(stats.selectedNetworkPath)
                )
                StatsRow(
                    label: L10n.text("server_location"),
                    value: serverLocation
                )
            }
            Divider()
                .overlay(StatsHUDPalette.divider, ignoresSafeAreaEdges: [])
            StatsSection(title: L10n.text("video")) {
                StatsRow(
                    label: L10n.text("resolution"),
                    value: "\(stats.resolutionWidth)×\(stats.resolutionHeight)"
                )
                StatsRow(
                    label: L10n.text("drops_freezes"),
                    value: "\(stats.framesDropped) / \(stats.freezeCount)"
                )
                StatsRow(
                    label: L10n.text("jitter_buffer"),
                    value: "\(Int(stats.jitterBufferDelayMs)) / \(Int(stats.jitterBufferTargetDelayMs)) ms"
                )
                StatsRow(
                    label: L10n.text("decode_time"),
                    value: String(format: "%.2f ms", stats.decodeTimeMs)
                )
                StatsRow(
                    label: L10n.text("processing_delay"),
                    value: String(format: "%.2f ms", stats.processingDelayMs)
                )
                StatsRow(label: L10n.text("format"), value: videoFormatValue)
            }
            Divider()
                .overlay(StatsHUDPalette.divider, ignoresSafeAreaEdges: [])
            StatsSection(title: L10n.text("audio")) {
                StatsRow(
                    label: L10n.text("jitter_buffer"),
                    value: "\(Int(audioStats.jitterBufferCurrentMs)) / \(Int(audioStats.jitterBufferTargetMs)) ms"
                )
                StatsRow(
                    label: L10n.text("conceal_stretch"),
                    value: String(
                        format: "%.0f · +%.0f/−%.0f ms/s",
                        audioStats.concealedMsPerSecond,
                        audioStats.stretchedMsPerSecond,
                        audioStats.acceleratedMsPerSecond
                    )
                )
                StatsRow(
                    label: L10n.text("input_latency"),
                    value: audioStats.inputLatencyMs.map { String(format: "%.0f ms", $0) } ?? "–"
                )
                StatsRow(
                    label: L10n.text("output_latency"),
                    value: String(format: "%.0f ms", audioStats.outputLatencyMs)
                )
                StatsRow(label: L10n.text("format"), value: audioFormatValue)
                StatsRow(label: L10n.text("output"), value: audioOutputValue)
            }
            Divider()
                .overlay(StatsHUDPalette.divider, ignoresSafeAreaEdges: [])
            StatsSection(title: L10n.text("session")) {
                SessionDurationRow(startedAt: streamingStartedAt)
            }
        }
    }

    private var bitrateValue: String {
        let current = "\(stats.bitrateKbps / 1000) Mbps"
        let available = stats.availableIncomingBitrateKbps
        return available > 0
            ? "\(current) (\(L10n.text("maximum_abbreviation")) \(available / 1000))"
            : current
    }

    private var colorModeValue: String {
        if let detected = colorState.detectedMode {
            return L10n.detectedColorModeLabel(detected)
        }
        return L10n.streamColorModeLabel(colorState.requestedMode)
    }

    private var videoFormatValue: String {
        var parts: [String] = []
        if !stats.codec.isEmpty {
            parts.append(stats.codec)
        }
        parts.append(colorModeValue)
        if stats.powerEfficientDecoder == true {
            parts.append("HW")
        }
        return parts.joined(separator: " · ")
    }

    private var audioOutputValue: String {
        guard audioStats.outputChannels > 0 else { return L10n.text("unknown") }
        var value = "\(channelLayoutLabel(audioStats.outputChannels)) @ \(Int(audioStats.outputSampleRateHz / 1000)) kHz"
        if !audioStats.outputRouteName.isEmpty {
            value += " · \(audioStats.outputRouteName)"
        }
        return value
    }

    private var audioFormatValue: String {
        guard !audioStats.codecName.isEmpty else { return L10n.text("unknown") }
        return "\(audioStats.codecName) \(channelLayoutLabel(audioStats.codecChannels))"
    }

    private func channelLayoutLabel(_ channels: Int) -> String {
        channels >= 6 ? L10n.text("surround_5_1") : L10n.text("stereo")
    }
}

private struct DebugStatsColumn: View {
    let stats: StreamStats
    let colorState: StreamColorState
    let rtcEventLogActive: Bool

    var body: some View {
        StatsSection(title: L10n.text("debug")) {
            StatsRow(
                label: "NACK/PLI/FIR",
                value: "\(stats.nackCount)/\(stats.pliCount)/\(stats.firCount)"
            )
            StatsRow(
                label: L10n.text("retransmits"),
                value: String(stats.retransmittedPackets)
            )
            StatsRow(
                label: L10n.text("input_queue"),
                value: String(
                    format: "p50 %.1f · p95 %.1f · max %.1f ms",
                    stats.inputQueueP50Ms,
                    stats.inputQueueP95Ms,
                    stats.inputQueueMaxMs
                )
            )
            StatsRow(
                label: L10n.text("input_buffer"),
                value: "\(stats.inputBufferedBytes) B (\(stats.inputChannelState))"
            )
            if !stats.decoderImplementation.isEmpty {
                StatsRow(
                    label: L10n.text("decoder"),
                    value: decoderValue
                )
            }
            if stats.inputDropped > 0 {
                StatsRow(
                    label: L10n.text("input_queue"),
                    value: L10n.format("input_drops_status", String(stats.inputDropped)),
                    warning: true
                )
            }
            if stats.inputSuperseded > 0 {
                StatsRow(
                    label: L10n.text("input_queue"),
                    value: L10n.format("analog_snapshots_coalesced_status", String(stats.inputSuperseded))
                )
            }
            if !stats.localCandidateType.isEmpty {
                StatsRow(
                    label: L10n.text("ice_path"),
                    value: "\(stats.localCandidateType) → \(stats.remoteCandidateType) (\(stats.selectedProtocol))"
                )
            }
            if let fallback = colorState.fallbackReason {
                StatsRow(
                    label: L10n.text("fallback"),
                    value: L10n.colorFallbackReasonLabel(fallback),
                    warning: true
                )
            }
            if rtcEventLogActive {
                StatsRow(
                    label: L10n.text("rtc_event_log"),
                    value: L10n.text("rtc_event_log_active")
                )
            }
        }
    }

    private var decoderValue: String {
        let hardware = stats.powerEfficientDecoder == true ? " (\(L10n.text("hardware")))" : ""
        return stats.decoderImplementation + hardware
    }
}

private struct StatsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(StatsHUDPalette.primaryText)
                .padding(.bottom, 2)

            content
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct StatsRow: View {
    let label: String
    let value: String
    var warning = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(StatsHUDPalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 6)
            Text(value)
                .foregroundStyle(warning ? StatsHUDPalette.warning : StatsHUDPalette.valueText)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .font(.system(size: 12, weight: .medium))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

private struct SessionDurationRow: View {
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            StatsRow(
                label: L10n.text("duration"),
                value: durationLabel(at: context.date)
            )
        }
    }

    private func durationLabel(at date: Date) -> String {
        let seconds = startedAt.map { max(0, Int(date.timeIntervalSince($0))) } ?? 0
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

private enum StatsHUDLayout {
    static let columnWidth: CGFloat = 310
    static let panelPadding: CGFloat = 12
    static let panelSpacing: CGFloat = 8
    static let metricSpacing: CGFloat = 8
}

private enum StatsFormat {
    /// Native GFN keeps healthy values neutral. NVIDIA recommends latency below
    /// 40 ms and requires it below 80 ms, which define the warning transitions.
    static func pingColor(_ ms: Double) -> Color {
        if ms < 40 {
            return StatsHUDPalette.primaryText
        }
        if ms < 80 {
            return StatsHUDPalette.warning
        }
        return .red
    }
}

private enum StatsHUDPalette {
    static let metricBackground = Color.primary.opacity(0.10)
    static let primaryText = Color.primary.opacity(0.88)
    static let valueText = Color.primary.opacity(0.72)
    static let secondaryText = Color.primary.opacity(0.60)
    static let divider = Color.primary.opacity(0.22)
    static let accent = Color(red: 0.48, green: 0.78, blue: 0.00)
    static let microphoneActive = Color.green
    static let microphoneTrack = Color.primary.opacity(0.18)
    static let warning = Color.orange

    static func panelBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.black.opacity(0.84) : Color.white.opacity(0.82)
    }

    static func microphoneBackground(for colorScheme: ColorScheme) -> Color {
        Color.black.opacity(colorScheme == .dark ? 0.34 : 0.08)
    }
}
