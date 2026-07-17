import Charts
import SwiftUI

/// Shared color/format helpers for stream statistics, used by the HUD and the pause menu.
enum StatsFormat {
    static func pingColor(_ ms: Double) -> Color {
        if ms < 30 {
            return .green
        }
        if ms < 80 {
            return .yellow
        }
        if ms < 150 {
            return .orange
        }
        return .red
    }

    static func fpsColor(_ fps: Double) -> Color {
        if fps >= 55 {
            return .green
        }
        if fps >= 30 {
            return .yellow
        }
        return .red
    }

    static func formatMs(_ value: Double) -> String {
        String(format: "%.2f ms", value)
    }
}

/// In-game statistics HUD mirroring the official client's Statistics overlay:
/// Compact shows the vital signs, Standard the full sectioned panel. Rendered
/// while streaming (hidden behind the pause menu) and strictly passive — it
/// never takes focus and never pauses input.
struct StatsHUDView: View {
    let streamController: GFNStreamController

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch streamController.statsMode {
        case .off:
            EmptyView()
        case .compact:
            panel { column { compactRows } }
        case .standard:
            // Diagnostics roughly doubles the panel height by appending the Debug section,
            // which can run off the bottom of the screen. Split into two columns then —
            // core stats on the left, Debug on the right — so it stays on screen.
            if streamController.diagnosticsEnabled {
                panel {
                    HStack(alignment: .top, spacing: 28) {
                        column { coreSections }
                        column { debugSection }
                    }
                }
            } else {
                panel { column { coreSections } }
            }
        }
    }

    // MARK: Compact

    @ViewBuilder private var compactRows: some View {
        let stats = streamController.stats
        row(
            L10n.text("fps_game_stream"), fpsValue,
            color: StatsFormat.fpsColor(stats.fps), history: streamController.fpsHistory
        )
        row(
            L10n.text("rtt"), "\(Int(stats.rttMs)) ms",
            color: StatsFormat.pingColor(stats.rttMs), history: streamController.pingHistory
        )
        row(L10n.text("bitrate"), "\(stats.bitrateKbps / 1000) Mbps", history: streamController.bitrateHistory)
        row(L10n.text("packet_loss"), String(format: "%.1f %%", stats.packetLossPercent))
        if !stats.serverZone.isEmpty {
            row(L10n.text("server_location"), stats.serverZone)
        }
    }

    // MARK: Standard

    @ViewBuilder private var coreSections: some View {
        networkSection
        videoSection
        audioSection
        sessionSection
    }

    @ViewBuilder private var networkSection: some View {
        let stats = streamController.stats
        header(L10n.text("network"))
        row(
            L10n.text("rtt"), "\(Int(stats.rttMs)) ms",
            color: StatsFormat.pingColor(stats.rttMs), history: streamController.pingHistory
        )
        row(
            L10n.text("jitter_loss"),
            String(format: "%.1f ms / %.1f %%", stats.jitterMs, stats.packetLossPercent)
        )
        row(L10n.text("bitrate"), bitrateValue, history: streamController.bitrateHistory)
        row(L10n.text("connection"), L10n.text(stats.selectedNetworkPath))
        if !stats.serverZone.isEmpty {
            row(L10n.text("server_location"), stats.serverZone)
        }
    }

    @ViewBuilder private var videoSection: some View {
        let stats = streamController.stats
        header(L10n.text("video"))
        row(L10n.text("resolution"), "\(stats.resolutionWidth)×\(stats.resolutionHeight)")
        row(
            L10n.text("fps_game_stream"), fpsValue,
            color: StatsFormat.fpsColor(stats.fps), history: streamController.fpsHistory
        )
        row(L10n.text("drops_freezes"), "\(stats.framesDropped) / \(stats.freezeCount)")
        row(
            L10n.text("jitter_buffer"),
            "\(Int(stats.jitterBufferDelayMs)) / \(Int(stats.jitterBufferTargetDelayMs)) ms"
        )
        row(L10n.text("decode_time"), StatsFormat.formatMs(stats.decodeTimeMs))
        row(L10n.text("processing_delay"), StatsFormat.formatMs(stats.processingDelayMs))
        row(L10n.text("format"), videoFormatValue)
    }

    @ViewBuilder private var audioSection: some View {
        let audio = streamController.audioStats
        header(L10n.text("audio"))
        row(
            L10n.text("jitter_buffer"),
            "\(Int(audio.jitterBufferCurrentMs)) / \(Int(audio.jitterBufferTargetMs)) ms"
        )
        row(
            L10n.text("conceal_stretch"),
            String(
                format: "%.0f · +%.0f/−%.0f ms/s",
                audio.concealedMsPerSecond, audio.stretchedMsPerSecond, audio.acceleratedMsPerSecond
            )
        )
        row(L10n.text("output_latency"), String(format: "%.0f ms", audio.outputLatencyMs))
        if !audio.codecName.isEmpty {
            row(L10n.text("format"), "\(audio.codecName) \(channelLayoutLabel(audio.codecChannels))")
        }
        if audio.outputChannels > 0 {
            row(L10n.text("output"), audioOutputValue)
        }
    }

    @ViewBuilder private var sessionSection: some View {
        header(L10n.text("session"))
        if !streamController.stats.gpuType.isEmpty {
            row(L10n.text("gpu"), streamController.stats.gpuType)
        }
        if let start = streamController.streamingStartedAt {
            row(L10n.text("duration"), durationLabel(since: start))
        }
    }

    @ViewBuilder private var debugSection: some View {
        let stats = streamController.stats
        header(L10n.text("debug"))
        row("NACK/PLI/FIR", "\(stats.nackCount)/\(stats.pliCount)/\(stats.firCount)")
        row(L10n.text("retransmits"), "\(stats.retransmittedPackets)")
        row(
            L10n.text("input_queue"),
            String(
                format: "p50 %.1f · p95 %.1f · max %.1f ms",
                stats.inputQueueP50Ms,
                stats.inputQueueP95Ms,
                stats.inputQueueMaxMs
            )
        )
        row(L10n.text("input_buffer"), "\(stats.inputBufferedBytes) B (\(stats.inputChannelState))")
        if !stats.decoderImplementation.isEmpty {
            let hardware = stats.powerEfficientDecoder == true ? " (\(L10n.text("hardware")))" : ""
            row(L10n.text("decoder"), stats.decoderImplementation + hardware)
        }
        if stats.inputDropped > 0 {
            line(L10n.format("input_drops_status", String(stats.inputDropped)), color: .orange)
        }
        if stats.inputSuperseded > 0 {
            line(L10n.format("analog_snapshots_coalesced_status", String(stats.inputSuperseded)))
        }
        if !stats.localCandidateType.isEmpty {
            row(
                L10n.text("ice_path"),
                "\(stats.localCandidateType) → \(stats.remoteCandidateType) (\(stats.selectedProtocol))"
            )
        }
        if let fallback = streamController.colorState.fallbackReason {
            line("\(L10n.text("fallback")) \(L10n.colorFallbackReasonLabel(fallback))", color: .orange)
        }
        if streamController.rtcEventLogURL != nil {
            line(L10n.text("rtc_event_log_active"))
        }
    }

    // MARK: Building blocks

    private let columnWidth: CGFloat = 380

    private func panel(@ViewBuilder content: () -> some View) -> some View {
        content()
            .font(.system(size: 21).monospacedDigit())
            .padding(20)
            .background(panelBackgroundColor, in: RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(false)
    }

    private func column(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .frame(width: columnWidth, alignment: .leading)
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(secondaryForegroundColor.opacity(0.75))
            .padding(.top, 8)
    }

    private func row(
        _ label: String, _ value: String, color: Color? = nil, history: [Double] = []
    ) -> some View {
        let valueColor = color ?? primaryForegroundColor

        return HStack(alignment: .center, spacing: 12) {
            Text(label)
                .foregroundStyle(secondaryForegroundColor)
            Spacer(minLength: 8)
            if history.count > 1 {
                Chart {
                    ForEach(Array(history.enumerated()), id: \.offset) { idx, val in
                        LineMark(x: .value("t", idx), y: .value("v", val))
                            .foregroundStyle(valueColor)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(width: 64, height: 18)
            }
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    /// Full-width sentence line for the moved pause-menu diagnostics (Debug section).
    private func line(_ text: String, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 18).monospacedDigit())
            .foregroundStyle(color ?? secondaryForegroundColor)
    }

    private var panelBackgroundColor: Color {
        colorScheme == .dark ? .black.opacity(0.65) : .white.opacity(0.82)
    }

    private var primaryForegroundColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var secondaryForegroundColor: Color {
        primaryForegroundColor.opacity(0.68)
    }

    private var colorModeValue: String {
        if let detected = streamController.colorState.detectedMode {
            return L10n.detectedColorModeLabel(detected)
        }
        return L10n.streamColorModeLabel(streamController.colorState.requestedMode)
    }

    /// "58 / 60" — game FPS (server render rate from the stats channel) / stream
    /// FPS (WebRTC decode rate), in the official overlay's order (game engine first).
    private var fpsValue: String {
        let stream = Int(streamController.stats.fps)
        let game = streamController.stats.gameFps
        return game > 0 ? "\(Int(game.rounded())) / \(stream)" : "– / \(stream)"
    }

    /// "45 Mbps (max 87)" — current receive bitrate plus the estimated available
    /// bandwidth when WebRTC reports one.
    private var bitrateValue: String {
        let current = "\(streamController.stats.bitrateKbps / 1000) Mbps"
        let available = streamController.stats.availableIncomingBitrateKbps
        return available > 0 ? "\(current) (max \(available / 1000))" : current
    }

    /// "H265 · HDR10 · HW" — codec, detected color mode, decode path in one line.
    private var videoFormatValue: String {
        var parts: [String] = []
        if !streamController.stats.codec.isEmpty {
            parts.append(streamController.stats.codec)
        }
        parts.append(colorModeValue)
        if streamController.stats.powerEfficientDecoder == true {
            parts.append("HW")
        }
        return parts.joined(separator: " · ")
    }

    /// "5.1 Surround @ 48 kHz · HDMI" — playout layout, sample rate, and route.
    private var audioOutputValue: String {
        let audio = streamController.audioStats
        var value = "\(channelLayoutLabel(audio.outputChannels)) @ \(Int(audio.outputSampleRateHz / 1000)) kHz"
        if !audio.outputRouteName.isEmpty {
            value += " · \(audio.outputRouteName)"
        }
        return value
    }

    private func channelLayoutLabel(_ channels: Int) -> String {
        channels >= 6 ? L10n.text("surround_5_1") : L10n.text("stereo")
    }

    private func durationLabel(since start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}
