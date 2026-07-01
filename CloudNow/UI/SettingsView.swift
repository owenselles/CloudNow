import SwiftUI

struct SettingsView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(GamesViewModel.self) var viewModel

    @State private var showZonePicker = false

    var body: some View {
        @Bindable var vm = viewModel

        NavigationStack {
            Form {
                Section("Stream Quality") {
                    Picker("Resolution", selection: $vm.streamSettings.resolution) {
                        let common = commonResolutions.filter { viewModel.availableResolutions.contains($0.res) }
                        let other = viewModel.availableResolutions.filter { res in !commonResolutions.map(\.res).contains(res) }
                        if !common.isEmpty {
                            Section("TV Standards") {
                                ForEach(common, id: \.res) { item in
                                    Label("\(item.res)  —  \(item.badge)", systemImage: item.symbol)
                                        .tag(item.res)
                                }
                            }
                        }
                        if !other.isEmpty {
                            Section("Other") {
                                ForEach(other, id: \.self) { res in
                                    Text(res).tag(res)
                                }
                            }
                        }
                    }

                    Picker("Frame Rate", selection: $vm.streamSettings.fps) {
                        ForEach(viewModel.availableFps, id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }

                    Picker("Codec", selection: $vm.streamSettings.codec) {
                        ForEach(VideoCodec.allCases, id: \.self) { codec in
                            Text(codec.rawValue).tag(codec)
                        }
                    }

                    Picker(selection: $vm.streamSettings.colorPreference) {
                        ForEach(ColorModePreference.allCases, id: \.self) { preference in
                            Text(preference.label).tag(preference)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Color Mode")
                            if vm.streamSettings.codec == .av1 {
                                Text("AV1 currently uses the software I420 path and will fall back to SDR 8-bit BT.709.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else {
                                Text(vm.streamSettings.colorPreference.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    Picker("Keyboard Layout", selection: $vm.streamSettings.keyboardLayout) {
                        Text("English (US)").tag("en-US")
                        Text("English (UK)").tag("en-GB")
                        Text("French").tag("fr-FR")
                        Text("German").tag("de-DE")
                        Text("Spanish").tag("es-ES")
                        Text("Italian").tag("it-IT")
                        Text("Portuguese (Brazil)").tag("pt-BR")
                        Text("Hindi (India)").tag("hi-IN")
                        Text("Japanese").tag("ja-JP")
                        Text("Korean").tag("ko-KR")
                    }

                    Picker("Game Language", selection: $vm.streamSettings.gameLanguage) {
                        Text("English (US)").tag("en_US")
                        Text("English (UK)").tag("en_GB")
                        Text("French").tag("fr_FR")
                        Text("German").tag("de_DE")
                        Text("Spanish").tag("es_ES")
                        Text("Italian").tag("it_IT")
                        Text("Portuguese").tag("pt_BR")
                        Text("Hindi").tag("hi_IN")
                        Text("Japanese").tag("ja_JP")
                        Text("Korean").tag("ko_KR")
                    }

                    LabeledContent("Max Bitrate") {
                        HStack(spacing: 16) {
                            Button {
                                vm.streamSettings.maxBitrateKbps = max(15000, vm.streamSettings.maxBitrateKbps - 5000)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            Text("\(vm.streamSettings.maxBitrateKbps / 1000) Mbps")
                                .monospacedDigit()
                                .frame(minWidth: 72)
                                .padding(.horizontal, 24)
                            Button {
                                vm.streamSettings.maxBitrateKbps = min(100_000, vm.streamSettings.maxBitrateKbps + 5000)
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Toggle(isOn: $vm.streamSettings.enableL4S) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Low Latency Mode (L4S)")
                            Text("Reduces buffering on networks with L4S support (requires a compatible router and ISP).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }

                Section("Server Region") {
                    Button {
                        showZonePicker = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Preferred Zone")
                                Text("Auto routing picks the best balance of ping and queue depth. Tap to pin a specific region.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            Spacer()
                            Text(zoneLabel(vm.streamSettings.preferredZoneUrl))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    if vm.streamSettings.preferredZoneUrl != nil {
                        Button("Clear — use automatic routing") {
                            vm.streamSettings.preferredZoneUrl = nil
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Microphone") {
                    Toggle(isOn: $vm.streamSettings.micEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Use Microphone")
                            Text("Enables voice chat via a connected Bluetooth headset or AirPods. Requires microphone permission.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }

                Section("Controller") {
                    LabeledContent {
                        HStack(spacing: 16) {
                            Button {
                                vm.streamSettings.controllerDeadzone = max(0.05, vm.streamSettings.controllerDeadzone - 0.01)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            Text("\(Int(vm.streamSettings.controllerDeadzone * 100))%")
                                .monospacedDigit()
                                .frame(minWidth: 44)
                                .padding(.horizontal, 24)
                            Button {
                                vm.streamSettings.controllerDeadzone = min(0.30, vm.streamSettings.controllerDeadzone + 0.01)
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Deadzone")
                            Text("Increase if your controller drifts at rest. Default: 15%.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Picker(selection: $vm.streamSettings.overlayTriggerButton) {
                        ForEach(OverlayTriggerButton.allCases, id: \.self) { btn in
                            Text(btn.rawValue).tag(btn)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Overlay Button")
                            Text("Long-press this button during play to open the app overlay. Switch if it conflicts with an in-game action.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Toggle(isOn: $vm.streamSettings.enableSteamOverlayGesture) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Steam Overlay Gesture")
                            Text("Long-press the OTHER button (the one not set as Overlay Button) to send Shift+Tab and open the Steam overlay. e.g. with Overlay on Start, long-press View/Back.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Picker(selection: $vm.streamSettings.defaultRemoteInputMode) {
                        Text("Mouse").tag(RemoteInputMode.mouse)
                        Text("Gamepad").tag(RemoteInputMode.gamepad)
                        Text("Touchpad").tag(RemoteInputMode.dualsense)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Default Input Mode")
                            Text("Input mode at stream start. Touchpad mode supports DualShock 4 and DualSense trackpads.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    LabeledContent("Protocol", value: "XInput over GFN v2/v3")
                }

                Section("Diagnostics") {
                    Picker(selection: $vm.streamSettings.statsMode) {
                        ForEach(StreamStatsMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Statistics Mode")
                            Text(statsModeDescription(vm.streamSettings.statsMode))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: vm.streamSettings.statsMode) { _, mode in
                        if mode != .diagnostic {
                            vm.streamSettings.enableRtcEventLog = false
                        }
                    }

                    Toggle(isOn: $vm.streamSettings.enableRtcEventLog) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("RTC Event Log")
                            Text("Writes a bounded WebRTC event log to the app caches directory for the next stream.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    .disabled(vm.streamSettings.statsMode != .diagnostic)
                }

                Section("Account") {
                    if let user = authManager.session?.user {
                        LabeledContent("Name", value: user.displayName)
                        if let email = user.email {
                            LabeledContent("Email", value: email)
                        }
                        if let sub = viewModel.subscription {
                            LabeledContent("Membership", value: sub.membershipTier)
                            if !sub.isUnlimited, let remaining = sub.remainingMinutes {
                                let hours = remaining / 60
                                let mins = remaining % 60
                                LabeledContent("Time Remaining", value: hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m")
                            }
                        } else {
                            LabeledContent("Membership", value: user.membershipTier)
                        }
                    }

                    Button(role: .destructive) {
                        authManager.logout()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("")
            .sheet(isPresented: $showZonePicker) {
                ZonePickerView(selectedZoneUrl: $vm.streamSettings.preferredZoneUrl)
            }
        }
    }

    private func zoneLabel(_ url: String?) -> String {
        guard let url else { return "Automatic" }
        // Extract zone ID from URL like "https://np-aws-us-n-virginia-1.cloudmatchbeta.nvidiagrid.net/"
        let host = URL(string: url)?.host ?? url
        return host.components(separatedBy: ".").first?.uppercased() ?? url
    }

    private struct ResolutionEntry { let res: String; let badge: String; let symbol: String }
    private let commonResolutions: [ResolutionEntry] = [
        ResolutionEntry(res: "1280x720", badge: "HD", symbol: "tv"),
        ResolutionEntry(res: "1920x1080", badge: "Full HD", symbol: "tv"),
        ResolutionEntry(res: "2560x1440", badge: "2K", symbol: "tv"),
        ResolutionEntry(res: "3840x2160", badge: "4K", symbol: "4k.tv"),
    ]

    private func statsModeDescription(_ mode: StreamStatsMode) -> String {
        switch mode {
        case .off: "Disables periodic WebRTC statistics collection."
        case .hud: "Collects the lightweight statistics shown in the in-stream overlay."
        case .diagnostic: "Adds receiver timing, renderer metrics, frame counters, and Instruments signposts."
        }
    }
}

// MARK: - Zone Picker

private struct ZonePickerView: View {
    @Binding var selectedZoneUrl: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(GamesViewModel.self) private var viewModel

    @State private var zones: [GFNZone] = []
    @State private var isLoading = true
    @State private var error: String?

    private var groupedZones: [(region: String, label: String, flag: String, zones: [GFNZone])] {
        let grouped = Dictionary(grouping: zones) { $0.region }
        let order = ["US", "CA", "EU", "JP", "KR", "THAI", "MY"]
        let sortedRegions = order.filter { grouped[$0] != nil }
            + grouped.keys.filter { !order.contains($0) }.sorted()
        return sortedRegions.map { region in
            let meta = GFNZone.regionMeta[region] ?? (label: region, flag: "🌐")
            let sorted = grouped[region, default: []].sorted {
                ($0.pingMs ?? .max) < ($1.pingMs ?? .max)
            }
            return (region, meta.label, meta.flag, sorted)
        }
    }

    private var autoZone: GFNZone? {
        zones.autoZone(isUnlimited: viewModel.subscription?.isUnlimited ?? false)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading servers…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView("Can't Load Servers", systemImage: "wifi.exclamationmark",
                                           description: Text(error))
                } else {
                    List {
                        // Auto option
                        Section {
                            Button {
                                select(nil)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text("Automatic")
                                            .font(.body.weight(.semibold))
                                        if let best = autoZone {
                                            Text("Best: \(best.id) · Q\(best.queuePosition)\(best.pingMs.map { " · \($0) ms" } ?? "")")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selectedZoneUrl == nil {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }

                        // Zones by region
                        ForEach(groupedZones, id: \.region) { group in
                            Section("\(group.flag) \(group.label)") {
                                ForEach(group.zones) { zone in
                                    Button {
                                        select(zone.zoneUrl)
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(zone.id)
                                                    .font(.body)
                                                HStack(spacing: 8) {
                                                    Label("Q \(zone.queuePosition)", systemImage: "person.3.fill")
                                                        .foregroundStyle(queueColor(zone.queuePosition))
                                                    if let ping = zone.pingMs {
                                                        Label("\(ping) ms", systemImage: "wifi")
                                                            .foregroundStyle(pingColor(ping))
                                                    } else if zone.isMeasuring {
                                                        Label("…", systemImage: "wifi")
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                                .font(.caption)
                                            }
                                            Spacer()
                                            if selectedZoneUrl == zone.zoneUrl {
                                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                            } else if autoZone?.id == zone.id {
                                                Text("Best")
                                                    .font(.caption.bold())
                                                    .foregroundStyle(.green)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.green.opacity(0.15), in: Capsule())
                                            }
                                        }
                                    }
                                    .foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Server Region")
            .task {
                await loadZones()
            }
        }
    }

    private func select(_ url: String?) {
        selectedZoneUrl = url
        Task { @MainActor in
            dismiss()
        }
    }

    private func loadZones() async {
        isLoading = true
        error = nil
        do {
            zones = try await ZoneClient.shared.fetchZones()
            isLoading = false
            let batchSize = 6
            for start in stride(from: 0, to: zones.count, by: batchSize) {
                if Task.isCancelled { return }
                let end = min(start + batchSize, zones.count)
                let batch = zones[start ..< end]
                await withTaskGroup(of: (String, Int?).self) { group in
                    for zone in batch {
                        group.addTask {
                            let ping = await ZoneClient.shared.measurePing(to: zone.zoneUrl)
                            return (zone.id, ping)
                        }
                    }
                    for await (id, ping) in group {
                        if Task.isCancelled { return }
                        if let idx = zones.firstIndex(where: { $0.id == id }) {
                            zones[idx].pingMs = ping
                            zones[idx].isMeasuring = false
                        }
                    }
                }
            }
            await ZoneClient.shared.cacheAutomaticSelections(from: zones)
        } catch {
            isLoading = false
            self.error = error.localizedDescription
        }
    }

    private func queueColor(_ q: Int) -> Color {
        if q <= 5 { return .green }
        if q <= 15 { return .yellow }
        if q <= 30 { return .orange }
        return .red
    }

    private func pingColor(_ ms: Int) -> Color {
        if ms < 30 { return .green }
        if ms < 80 { return .yellow }
        if ms < 150 { return .orange }
        return .red
    }
}
