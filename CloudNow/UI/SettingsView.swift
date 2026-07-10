import SwiftUI

struct SettingsView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(GamesViewModel.self) var viewModel

    @State private var showZonePicker = false
    @State private var showNetworkTest = false

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

                    Picker(selection: $vm.streamSettings.audioFormat) {
                        ForEach(AudioFormatPreference.allCases, id: \.self) { format in
                            Text(format.label).tag(format)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("audio_format"))
                            Text(L10n.text("audio_format_description"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                    Picker(selection: $vm.streamSettings.appLaunchMode) {
                        ForEach(AppLaunchMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("game_launch_mode"))
                            Text(L10n.text("game_launch_mode_description"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
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

                Section(L10n.text("server_location")) {
                    Button {
                        showZonePicker = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.text("server_location"))
                                Text(serverLocationDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            Spacer()
                            Text(serverLocationValue)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        showNetworkTest = true
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("test_network"))
                            Text(L10n.text("test_network_description"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    .foregroundStyle(.primary)
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
                    Toggle(isOn: $vm.streamSettings.rumbleEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("controller_rumble"))
                            Text(L10n.text("controller_rumble_description"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    if vm.streamSettings.rumbleEnabled {
                        LabeledContent {
                            HStack(spacing: 16) {
                                Button {
                                    vm.streamSettings.rumbleIntensity = max(StreamSettings.minRumbleIntensity, vm.streamSettings.rumbleIntensity - 0.05)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                Text("\(Int((vm.streamSettings.rumbleIntensity * 100).rounded()))%")
                                    .monospacedDigit()
                                    .frame(minWidth: 44)
                                    .padding(.horizontal, 24)
                                Button {
                                    vm.streamSettings.rumbleIntensity = min(StreamSettings.maxRumbleIntensity, vm.streamSettings.rumbleIntensity + 0.05)
                                } label: {
                                    Image(systemName: "plus.circle")
                                }
                                .buttonStyle(.plain)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.text("controller_rumble_intensity"))
                                Text(L10n.text("controller_rumble_intensity_description"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                    }
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

                Section(L10n.text("game")) {
                    if viewModel.subscription?.allowsInGameSettingsPersistence == false {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("save_in_game_settings"))
                            Text(L10n.text("save_in_game_settings_free_unavailable"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        Toggle(isOn: $vm.streamSettings.persistInGameSettings) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.text("save_in_game_settings"))
                                Text(L10n.text("save_in_game_settings_description"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }

                Section(L10n.text("diagnostics")) {
                    Toggle(isOn: $vm.streamSettings.diagnosticsEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("diagnostic"))
                            Text(L10n.text("adds_receiver_timing_renderer_metrics_frame_counters_and_instruments_signposts"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: vm.streamSettings.diagnosticsEnabled) { _, enabled in
                        if !enabled {
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
                    .disabled(!vm.streamSettings.diagnosticsEnabled)
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
                ServerLocationPickerView()
            }
            .sheet(isPresented: $showNetworkTest) {
                NetworkTestView()
            }
        }
    }

    private var serverLocationValue: String {
        switch viewModel.streamSettings.serverRoutingMode {
        case .region: viewModel.streamSettings.preferredRegionName ?? L10n.text("automatic")
        case .serverAuto, .clientAuto: viewModel.streamSettings.serverRoutingMode.label
        }
    }

    private var serverLocationDescription: String {
        switch viewModel.streamSettings.serverRoutingMode {
        case .serverAuto: L10n.text("automatic_server_decides_description")
        case .clientAuto: L10n.text("automatic_client_decides_description")
        case .region: L10n.text("server_selection_warning")
        }
    }

    private struct ResolutionEntry { let res: String; let badge: String; let symbol: String }
    private let commonResolutions: [ResolutionEntry] = [
        ResolutionEntry(res: "1280x720", badge: "HD", symbol: "tv"),
        ResolutionEntry(res: "1920x1080", badge: "Full HD", symbol: "tv"),
        ResolutionEntry(res: "2560x1440", badge: "2K", symbol: "tv"),
        ResolutionEntry(res: "3840x2160", badge: "4K", symbol: "4k.tv"),
    ]
}

// MARK: - Server Location Picker

/// Full-screen selection list mirroring tvOS Settings' own pickers (e.g. Sleep
/// After): two Automatic entries then one row per region from /v2/serverInfo,
/// opening focused on and scrolled to the active entry, which carries a
/// checkmark. SwiftUI's native Picker can't reproduce this on tvOS (it opens at
/// the top with no selection mark), so the list is built by hand.
private struct ServerLocationPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(GamesViewModel.self) private var viewModel
    @Environment(AuthManager.self) private var authManager

    @State private var serverInfo: GFNServerInfo?
    @State private var isLoading = true
    @State private var error: String?
    @FocusState private var focusedRow: String?

    init() {
        // Seed from the app-run cache so a previously-picked region row can exist
        // at first layout.
        let cached = ServerInfoClient.shared.cached
        _serverInfo = State(initialValue: cached)
        _isLoading = State(initialValue: cached == nil)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        autoRow(.serverAuto, subtitle: serverAutoSubtitle)
                        autoRow(.clientAuto, subtitle: L10n.text("automatic_client_decides_description"))
                    }

                    if let regions = serverInfo?.regions, !regions.isEmpty {
                        Section {
                            ForEach(regions) { region in
                                regionRow(region)
                            }
                        } footer: {
                            if viewModel.streamSettings.serverRoutingMode == .region {
                                Text(L10n.text("server_selection_warning"))
                            }
                        }
                    } else if isLoading {
                        Section {
                            ProgressView { Text(L10n.text("loading_servers")) }
                                .frame(maxWidth: .infinity)
                        }
                    } else if let error {
                        Section {
                            ContentUnavailableView(
                                L10n.text("cant_load_servers"),
                                systemImage: "wifi.exclamationmark",
                                description: Text(error)
                            )
                        }
                    }
                }
                .navigationTitle(L10n.text("server_location"))
                .task { await load() }
                .task { await focusActiveRow(proxy: proxy) }
            }
        }
    }

    /// Opens on the current selection: waits until its row exists (region rows
    /// arrive asynchronously), then scrolls it into view and focuses it — retrying
    /// until focus actually settles there, since the sheet's initial auto-focus
    /// (and the re-layout when regions finish loading) can steal it back to the
    /// first row.
    private func focusActiveRow(proxy: ScrollViewProxy) async {
        for _ in 0 ..< 60 {
            if selectedRowExists { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard selectedRowExists else { return }

        let key = selectedRowKey
        for _ in 0 ..< 8 {
            proxy.scrollTo(key, anchor: .center)
            focusedRow = key
            try? await Task.sleep(nanoseconds: 150_000_000)
            if focusedRow == key { return }
        }
    }

    private var selectedRowKey: String {
        let settings = viewModel.streamSettings
        if settings.serverRoutingMode == .region, let name = settings.preferredRegionName {
            return "region:\(name)"
        }
        return settings.serverRoutingMode.rawValue
    }

    private var selectedRowExists: Bool {
        switch viewModel.streamSettings.serverRoutingMode {
        case .serverAuto, .clientAuto:
            return true
        case .region:
            guard let name = viewModel.streamSettings.preferredRegionName else { return false }
            return serverInfo?.regions.contains { $0.name == name } ?? false
        }
    }

    private var serverAutoSubtitle: String {
        if let local = serverInfo?.localRegionName, !local.isEmpty {
            return L10n.format("detected_region", local)
        }
        return L10n.text("automatic_server_decides_description")
    }

    private func autoRow(_ mode: ServerRoutingMode, subtitle: String) -> some View {
        Button {
            viewModel.streamSettings.serverRoutingMode = mode
            viewModel.streamSettings.preferredRegionName = nil
            viewModel.streamSettings.preferredRegionAddress = nil
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.label).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.streamSettings.serverRoutingMode == mode {
                    Image(systemName: "checkmark")
                }
            }
        }
        .buttonStyle(ServerRowButtonStyle())
        .focused($focusedRow, equals: mode.rawValue)
        .id(mode.rawValue)
    }

    private func regionRow(_ region: GFNRegion) -> some View {
        let selected = viewModel.streamSettings.serverRoutingMode == .region
            && viewModel.streamSettings.preferredRegionName == region.name
        return Button {
            viewModel.streamSettings.serverRoutingMode = .region
            viewModel.streamSettings.preferredRegionName = region.name
            viewModel.streamSettings.preferredRegionAddress = region.address
            dismiss()
        } label: {
            HStack {
                Text(region.name)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                }
            }
        }
        .buttonStyle(ServerRowButtonStyle())
        .focused($focusedRow, equals: "region:\(region.name)")
        .id("region:\(region.name)")
    }

    private func load() async {
        if let cached = ServerInfoClient.shared.cached {
            serverInfo = cached
            isLoading = false
        }
        let base = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
        guard let token = try? await authManager.resolveToken() else {
            isLoading = false
            if serverInfo == nil { error = "Sign-in required" }
            return
        }
        do {
            serverInfo = try await ServerInfoClient.shared.fetch(baseUrl: base, token: token)
            isLoading = false
        } catch {
            isLoading = false
            if serverInfo == nil { self.error = error.localizedDescription }
        }
    }
}

/// Row button style for the Server Location list and the Network Test Close
/// button. It draws its own focus platter and text colour instead of relying on
/// the system button platter: inside a presented sheet, tvOS does not auto-invert
/// custom label content to dark-on-white on focus, so a focused row would
/// otherwise read as a blank white bar.
private struct ServerRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
                .padding(.vertical, 14)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.06)))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .scaleEffect(isFocused ? 1.03 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

// MARK: - Network Test

/// Official-client-style network test: probes the region you would stream from
/// and reports ping, jitter, and loss (HTTP HEAD samples against the region
/// endpoint — no streaming session required).
private struct NetworkTestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(GamesViewModel.self) private var viewModel
    @Environment(AuthManager.self) private var authManager

    @State private var isRunning = true
    @State private var routedTo: String?
    @State private var pingMs: Double?
    @State private var jitterMs: Double?
    @State private var lossPercent: Double?

    private static let sampleCount = 10

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let routedTo {
                        LabeledContent(L10n.text("routed_to"), value: routedTo)
                    }
                    LabeledContent(L10n.text("rtt")) {
                        resultText(pingMs.map { String(format: "%.0f ms", $0) }, color: pingMs.map(pingColor))
                    }
                    LabeledContent(L10n.text("jitter")) {
                        resultText(jitterMs.map { String(format: "%.1f ms", $0) }, color: nil)
                    }
                    LabeledContent(L10n.text("loss")) {
                        resultText(lossPercent.map { String(format: "%.0f %%", $0) },
                                   color: lossPercent.map { $0 > 0 ? .orange : .green })
                    }
                } footer: {
                    if isRunning {
                        Label(L10n.text("test_running"), systemImage: "wifi")
                    }
                }

                Section {
                    Button {
                        dismiss()
                    } label: {
                        Text(L10n.text("close"))
                    }
                    .buttonStyle(ServerRowButtonStyle())
                }
            }
            .navigationTitle(L10n.text("test_network"))
            .task { await run() }
        }
    }

    @ViewBuilder
    private func resultText(_ value: String?, color: Color?) -> some View {
        if let value {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(color ?? .primary)
        } else {
            Text("…").foregroundStyle(.secondary)
        }
    }

    private func run() async {
        let (targetAddress, targetName) = await resolveTarget()
        routedTo = targetName

        _ = await probe(targetAddress) // connection warm-up, not counted

        var samples: [Double] = []
        var failures = 0
        for _ in 0 ..< Self.sampleCount {
            if let ms = await probe(targetAddress) {
                samples.append(ms)
                pingMs = samples.reduce(0, +) / Double(samples.count)
            } else {
                failures += 1
            }
            lossPercent = Double(failures) / Double(Self.sampleCount) * 100
        }
        if samples.count > 1 {
            let diffs = zip(samples.dropFirst(), samples).map { abs($0 - $1) }
            jitterMs = diffs.reduce(0, +) / Double(diffs.count)
        } else if !samples.isEmpty {
            jitterMs = 0
        }
        isRunning = false
    }

    /// Pinned region when set; otherwise the server-detected local region from
    /// /v2/serverInfo (what Automatic would route to), falling back to the
    /// account's default endpoint.
    private func resolveTarget() async -> (address: String, name: String?) {
        let settings = viewModel.streamSettings
        if settings.serverRoutingMode == .region,
           let address = settings.preferredRegionAddress
        {
            return (address, settings.preferredRegionName)
        }
        let base = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
        let info: GFNServerInfo? = if let cached = ServerInfoClient.shared.cached {
            cached
        } else if let token = try? await authManager.resolveToken() {
            try? await ServerInfoClient.shared.fetch(baseUrl: base, token: token)
        } else {
            nil
        }
        if let local = info?.localRegionName,
           let region = info?.regions.first(where: { $0.name == local })
        {
            return (region.address, local)
        }
        return (base, info?.localRegionName)
    }

    private func probe(_ urlString: String) async -> Double? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        let start = Date()
        do {
            _ = try await URLSession.shared.data(for: request)
            return Date().timeIntervalSince(start) * 1000
        } catch {
            return nil
        }
    }

    private func pingColor(_ ms: Double) -> Color {
        if ms < 30 { return .green }
        if ms < 80 { return .yellow }
        if ms < 150 { return .orange }
        return .red
    }
}
