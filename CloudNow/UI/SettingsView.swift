import SwiftUI

struct SettingsView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(GamesViewModel.self) var viewModel

    @State private var showZonePicker = false

    var body: some View {
        @Bindable var vm = viewModel

        NavigationStack {
            Form {
                Section(L10n.text("stream_quality")) {
                    Picker(L10n.text("resolution"), selection: $vm.streamSettings.resolution) {
                        let common = commonResolutions.filter { viewModel.availableResolutions.contains($0.res) }
                        let other = viewModel.availableResolutions.filter { res in !commonResolutions.map(\.res).contains(res) }
                        if !common.isEmpty {
                            Section(L10n.text("tv_standards")) {
                                ForEach(common, id: \.res) { item in
                                    Label("\(item.res)  —  \(item.badge)", systemImage: item.symbol)
                                        .tag(item.res)
                                }
                            }
                        }
                        if !other.isEmpty {
                            Section(L10n.text("other")) {
                                ForEach(other, id: \.self) { res in
                                    Text(res).tag(res)
                                }
                            }
                        }
                    }

                    Picker(L10n.text("frame_rate"), selection: $vm.streamSettings.fps) {
                        ForEach(viewModel.availableFps, id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }

                    Picker(L10n.text("codec"), selection: $vm.streamSettings.codec) {
                        ForEach(VideoCodec.allCases, id: \.self) { codec in
                            Text(codec.label).tag(codec)
                        }
                    }

                    Picker(selection: $vm.streamSettings.colorPreference) {
                        ForEach(ColorModePreference.allCases, id: \.self) { preference in
                            Text(preference.label).tag(preference)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("color_mode"))
                            if vm.streamSettings.codec == .av1 {
                                Text(L10n.text("av1_software_path_warning"))
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

                    Picker(L10n.text("keyboard_layout"), selection: $vm.streamSettings.keyboardLayout) {
                        ForEach(L10n.supportedLanguageCodes, id: \.self) { code in
                            Text(L10n.localizedLanguageName(for: code)).tag(code)
                        }
                    }

                    Picker(L10n.text("game_language"), selection: $vm.streamSettings.gameLanguage) {
                        Text(L10n.text("automatic")).tag(StreamSettings.automaticGameLanguage)
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
                        Text("Chinese (Simplified)").tag("zh_CN")
                        Text("Chinese (Traditional)").tag("zh_TW")
                        Text("Russian").tag("ru_RU")
                        Text("Arabic").tag("ar_SA")
                        Text("Dutch").tag("nl_NL")
                        Text("Polish").tag("pl_PL")
                        Text("Swedish").tag("sv_SE")
                        Text("Finnish").tag("fi_FI")
                        Text("Turkish").tag("tr_TR")
                        Text("Greek").tag("el_GR")
                        Text("Hebrew").tag("he_IL")
                        Text("Czech").tag("cs_CZ")
                        Text("Danish").tag("da_DK")
                        Text("Croatian").tag("hr_HR")
                        Text("Hungarian").tag("hu_HU")
                        Text("Indonesian").tag("id_ID")
                        Text("Malay").tag("ms_MY")
                        Text("Romanian").tag("ro_RO")
                        Text("Slovak").tag("sk_SK")
                        Text("Vietnamese").tag("vi_VN")
                        Text("Ukrainian").tag("uk_UA")
                    }
                    LabeledContent(L10n.text("max_bitrate")) {
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
                                vm.streamSettings.maxBitrateKbps = min(StreamSettings.maxSelectableBitrateKbps, vm.streamSettings.maxBitrateKbps + 5000)
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Toggle(isOn: $vm.streamSettings.enableL4S) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("low_latency_mode"))
                            Text(L10n.text("low_latency_mode_description"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }

                Section(L10n.text("server_region")) {
                    Button {
                        showZonePicker = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.text("preferred_zone"))
                                Text(L10n.text("preferred_zone_description"))
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
                        Button(L10n.text("clear_use_automatic_routing")) {
                            vm.streamSettings.preferredZoneUrl = nil
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                Section(L10n.text("microphone")) {
                    Toggle(isOn: $vm.streamSettings.micEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("use_microphone"))
                            Text(L10n.text("microphone_description"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }

                Section(L10n.text("controller")) {
                    LabeledContent {
                        HStack(spacing: 16) {
                            Button {
                                vm.streamSettings.controllerDeadzone = max(StreamSettings.minControllerDeadzone, vm.streamSettings.controllerDeadzone - 0.01)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            Text("\(Int(vm.streamSettings.controllerDeadzone * 100))%")
                                .monospacedDigit()
                                .frame(minWidth: 44)
                                .padding(.horizontal, 24)
                            Button {
                                vm.streamSettings.controllerDeadzone = min(StreamSettings.maxControllerDeadzone, vm.streamSettings.controllerDeadzone + 0.01)
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("deadzone"))
                            Text(L10n.text("deadzone_description"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Picker(selection: $vm.streamSettings.overlayTriggerButton) {
                        ForEach(OverlayTriggerButton.allCases, id: \.self) { btn in
                            Text(btn.label).tag(btn)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("overlay_button"))
                            Text(L10n.text("overlay_button_description"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Toggle(isOn: $vm.streamSettings.enableSteamOverlayGesture) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("steam_overlay_gesture"))
                            Text(L10n.text("steam_overlay_gesture_description"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Picker(selection: $vm.streamSettings.defaultRemoteInputMode) {
                        Text(L10n.remoteInputModeLabel(.mouse)).tag(RemoteInputMode.mouse)
                        Text(L10n.remoteInputModeLabel(.gamepad)).tag(RemoteInputMode.gamepad)
                        Text(L10n.remoteInputModeLabel(.dualsense)).tag(RemoteInputMode.dualsense)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("default_input_mode"))
                            Text(L10n.text("default_input_mode_description"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    LabeledContent(L10n.text("protocol"), value: "XInput over GFN v2/v3")
                }

                Section(L10n.text("diagnostics")) {
                    Picker(selection: $vm.streamSettings.statsMode) {
                        ForEach(StreamStatsMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("statistics_mode"))
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
                            Text(L10n.text("rtc_event_log"))
                            Text(L10n.text("rtc_event_log_description"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    .disabled(vm.streamSettings.statsMode != .diagnostic)
                }

                Section(L10n.text("account")) {
                    if let user = authManager.session?.user {
                        LabeledContent(L10n.text("name"), value: user.displayName)
                        if let email = user.email {
                            LabeledContent(L10n.text("email"), value: email)
                        }
                        if let sub = viewModel.subscription {
                            LabeledContent(L10n.text("membership"), value: sub.membershipTier)
                            if !sub.isUnlimited, let remaining = sub.remainingMinutes {
                                let hours = remaining / 60
                                let mins = remaining % 60
                                LabeledContent(L10n.text("time_remaining"), value: hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m")
                            }
                        } else {
                            LabeledContent(L10n.text("membership"), value: user.membershipTier)
                        }
                    }

                    Button(role: .destructive) {
                        authManager.logout()
                    } label: {
                        Label(L10n.text("sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
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
        guard let url else { return L10n.text("automatic") }
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
        L10n.streamStatsModeDescription(mode)
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
                    ProgressView {
                        Text(L10n.text("loading_servers"))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView(L10n.text("cant_load_servers"), systemImage: "wifi.exclamationmark",
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
                                        Text(L10n.text("automatic"))
                                            .font(.body.weight(.semibold))
                                        if let best = autoZone {
                                            Text("\(L10n.text("best_prefix")) \(best.id) · Q\(best.queuePosition)\(best.pingMs.map { " · \($0) ms" } ?? "")")
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
                                                Text(L10n.text("best"))
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
            .navigationTitle(L10n.text("server_region"))
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
