import SwiftUI

struct CloudNowStorageAndDataSection: View {
    let isPerformingAction: Bool
    let clearCache: () -> Void
    let resetAllData: () -> Void

    var body: some View {
        Section(L10n.text("storage_and_data")) {
            Button(action: clearCache) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            L10n.text("clear_cache"),
                            systemImage: "externaldrive.badge.xmark"
                        )
                        Text(L10n.text("clear_cache_description"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    Spacer()
                    if isPerformingAction {
                        ProgressView()
                    }
                }
            }
            .disabled(isPerformingAction)

            Button(role: .destructive, action: resetAllData) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.text("reset_all_data"), systemImage: "trash")
                    Text(L10n.text("reset_all_data_description"))
                        .font(.caption)
                }
                .padding(.vertical, 8)
            }
            .disabled(isPerformingAction)
            .accessibilityIdentifier("settings.reset-all-data")
        }
    }
}

struct CloudNowCloudServiceSection: View {
    @Environment(CloudGamingProviderCoordinator.self) private var providerCoordinator
    @Environment(CloudSessionCoordinator.self) private var sessionCoordinator
    let activeProvider: CloudGamingProvider
    let isInteractionDisabled: Bool
    let onSelectProvider: @MainActor @Sendable (CloudGamingProvider) -> Void
    @State private var providerSwitchPrompt: CloudProviderSwitchPrompt?

    var body: some View {
        Section(L10n.text("cloud_service")) {
            LabeledContent(
                L10n.text("active_service"),
                value: activeProvider.displayName
            )

            ForEach(CloudGamingProvider.allCases) { provider in
                if provider != activeProvider {
                    Button {
                        requestProviderSwitch(to: provider)
                    } label: {
                        Label(
                            L10n.format("switch_to_service", provider.displayName),
                            systemImage: provider.systemImage
                        )
                    }
                    .accessibilityIdentifier("service-switch.\(provider.rawValue)")
                    .accessibilityHint(
                        providerCoordinator.capabilities(
                            for: provider
                        ).availability.unavailableReason.map {
                            L10n.text($0.localizationKey)
                        } ?? ""
                    )
                    .disabled(
                        isInteractionDisabled
                            || !providerCoordinator.capabilities(
                                for: provider
                            ).availability.isSupported
                    )
                }
            }
        }
        .cloudProviderSwitchConfirmation(
            prompt: $providerSwitchPrompt,
            onSwitch: onSelectProvider
        )
    }

    private func requestProviderSwitch(to provider: CloudGamingProvider) {
        let requirement = sessionCoordinator.switchRequirement(to: provider)
        switch requirement {
        case .allowed:
            onSelectProvider(provider)
        case .leaveOrEnd, .endParkedSession:
            providerSwitchPrompt = CloudProviderSwitchPrompt(
                targetProvider: provider,
                requirement: requirement
            )
        }
    }
}

nonisolated struct CloudNowControllerSettingsPolicy: Equatable, Sendable {
    nonisolated enum RumbleValueStyle: Equatable, Sendable {
        case multiplier
        case percentage
    }

    let rumbleRange: ClosedRange<Double>
    let rumbleStep: Double
    let rumbleValueStyle: RumbleValueStyle
    let deadzoneRange: ClosedRange<Double>
    let deadzoneStep: Double

    static let geForceNow = CloudNowControllerSettingsPolicy(
        rumbleRange: StreamSettings.minRumbleIntensity ... StreamSettings.maxRumbleIntensity,
        rumbleStep: 0.05,
        rumbleValueStyle: .multiplier,
        deadzoneRange: StreamSettings.minControllerDeadzone ... StreamSettings.maxControllerDeadzone,
        deadzoneStep: 0.01
    )

    static let xboxCloudGaming = CloudNowControllerSettingsPolicy(
        rumbleRange: XboxCloudStreamSettings.minimumRumbleIntensity ... XboxCloudStreamSettings.maximumRumbleIntensity,
        rumbleStep: 0.05,
        rumbleValueStyle: .percentage,
        deadzoneRange: XboxCloudStreamSettings.minimumControllerDeadzone ... 0.30,
        deadzoneStep: 0.01
    )

    func rumbleLabel(for value: Double) -> String {
        switch rumbleValueStyle {
        case .multiplier:
            String(format: "%.2f×", value)
        case .percentage:
            percentageLabel(for: value)
        }
    }

    func deadzoneLabel(for value: Double) -> String {
        percentageLabel(for: value)
    }

    func adjustedRumbleValue(_ value: Double, direction: Double) -> Double {
        clamped(value + (rumbleStep * direction), to: rumbleRange)
    }

    func adjustedDeadzoneValue(_ value: Double, direction: Double) -> Double {
        clamped(value + (deadzoneStep * direction), to: deadzoneRange)
    }

    private func percentageLabel(for value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private struct CloudNowSettingLabel: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

struct CloudNowDiagnosticsSettingsSection: View {
    @Binding var diagnosticsEnabled: Bool
    @Binding var enableRtcEventLog: Bool
    let isDisabled: Bool

    var body: some View {
        Section(L10n.text("diagnostics")) {
            Toggle(isOn: $diagnosticsEnabled) {
                CloudNowSettingLabel(
                    title: L10n.text("diagnostic"),
                    description: L10n.text(
                        "adds_receiver_timing_renderer_metrics_frame_counters_and_instruments_signposts"
                    )
                )
            }
            .onChange(of: diagnosticsEnabled) { _, enabled in
                if !enabled {
                    enableRtcEventLog = false
                }
            }

            Toggle(isOn: $enableRtcEventLog) {
                CloudNowSettingLabel(
                    title: L10n.text("rtc_event_log"),
                    description: L10n.text("rtc_event_log_description")
                )
            }
            .disabled(!diagnosticsEnabled)
        }
        .disabled(isDisabled)
    }
}

private struct CloudNowAdjustableControllerRow: View {
    enum ValueKind {
        case rumble
        case deadzone
    }

    let title: String
    let description: String
    let accessibilityIdentifier: String
    @Binding var value: Double
    let policy: CloudNowControllerSettingsPolicy
    let valueKind: ValueKind

    var body: some View {
        LabeledContent {
            HStack(spacing: 16) {
                Button {
                    adjust(direction: -1)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)

                Text(formattedValue)
                    .monospacedDigit()
                    .frame(minWidth: valueKind == .rumble ? 64 : 44)
                    .padding(.horizontal, 24)

                Button {
                    adjust(direction: 1)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
            }
        } label: {
            CloudNowSettingLabel(title: title, description: description)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var formattedValue: String {
        switch valueKind {
        case .rumble:
            policy.rumbleLabel(for: value)
        case .deadzone:
            policy.deadzoneLabel(for: value)
        }
    }

    private func adjust(direction: Double) {
        switch valueKind {
        case .rumble:
            value = policy.adjustedRumbleValue(value, direction: direction)
        case .deadzone:
            value = policy.adjustedDeadzoneValue(value, direction: direction)
        }
    }
}

struct CloudNowControllerSettingsSection<AdditionalContent: View>: View {
    @Binding var rumbleEnabled: Bool
    @Binding var rumbleIntensity: Double
    @Binding var controllerDeadzone: Double
    let policy: CloudNowControllerSettingsPolicy
    let isDisabled: Bool
    let footer: String?
    let additionalContent: AdditionalContent

    init(
        rumbleEnabled: Binding<Bool>,
        rumbleIntensity: Binding<Double>,
        controllerDeadzone: Binding<Double>,
        policy: CloudNowControllerSettingsPolicy,
        isDisabled: Bool = false,
        footer: String? = nil,
        @ViewBuilder additionalContent: () -> AdditionalContent
    ) {
        _rumbleEnabled = rumbleEnabled
        _rumbleIntensity = rumbleIntensity
        _controllerDeadzone = controllerDeadzone
        self.policy = policy
        self.isDisabled = isDisabled
        self.footer = footer
        self.additionalContent = additionalContent()
    }

    var body: some View {
        Section {
            Toggle(isOn: $rumbleEnabled) {
                CloudNowSettingLabel(
                    title: L10n.text("controller_rumble"),
                    description: L10n.text("controller_rumble_description")
                )
            }
            .accessibilityIdentifier("settings.rumble-enabled")

            if rumbleEnabled {
                CloudNowAdjustableControllerRow(
                    title: L10n.text("controller_rumble_intensity"),
                    description: L10n.text("controller_rumble_intensity_description"),
                    accessibilityIdentifier: "settings.rumble-intensity",
                    value: $rumbleIntensity,
                    policy: policy,
                    valueKind: .rumble
                )
            }

            CloudNowAdjustableControllerRow(
                title: L10n.text("deadzone"),
                description: L10n.text("deadzone_description"),
                accessibilityIdentifier: "settings.controller-deadzone",
                value: $controllerDeadzone,
                policy: policy,
                valueKind: .deadzone
            )

            additionalContent
        } header: {
            Text(L10n.text("controller"))
        } footer: {
            if let footer {
                Text(footer)
            }
        }
        .disabled(isDisabled)
    }
}

extension CloudNowControllerSettingsSection where AdditionalContent == EmptyView {
    init(
        rumbleEnabled: Binding<Bool>,
        rumbleIntensity: Binding<Double>,
        controllerDeadzone: Binding<Double>,
        policy: CloudNowControllerSettingsPolicy,
        isDisabled: Bool = false,
        footer: String? = nil
    ) {
        self.init(
            rumbleEnabled: rumbleEnabled,
            rumbleIntensity: rumbleIntensity,
            controllerDeadzone: controllerDeadzone,
            policy: policy,
            isDisabled: isDisabled,
            footer: footer,
            additionalContent: { EmptyView() }
        )
    }
}

struct CloudNowStreamQualityOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let badge: String?
    let systemImage: String?

    var id: Value {
        value
    }

    init(
        value: Value,
        title: String,
        badge: String? = nil,
        systemImage: String? = nil
    ) {
        self.value = value
        self.title = title
        self.badge = badge
        self.systemImage = systemImage
    }
}

struct CloudNowStreamQualityOptionGroup<Value: Hashable>: Identifiable {
    let title: String
    let options: [CloudNowStreamQualityOption<Value>]

    var id: String {
        title
    }
}

struct CloudNowStreamQualityPicker<Value: Hashable>: View {
    let title: String
    let accessibilityIdentifier: String
    @Binding var selection: Value
    let options: [CloudNowStreamQualityOption<Value>]
    let groups: [CloudNowStreamQualityOptionGroup<Value>]

    init(
        _ title: String,
        selection: Binding<Value>,
        accessibilityIdentifier: String,
        options: [CloudNowStreamQualityOption<Value>] = [],
        groups: [CloudNowStreamQualityOptionGroup<Value>] = []
    ) {
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        _selection = selection
        self.options = options
        self.groups = groups
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options) { option in
                optionLabel(option)
                    .tag(option.value)
            }
            ForEach(groups) { group in
                if !group.options.isEmpty {
                    Section(group.title) {
                        ForEach(group.options) { option in
                            optionLabel(option)
                                .tag(option.value)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private func optionLabel(_ option: CloudNowStreamQualityOption<Value>) -> some View {
        if let systemImage = option.systemImage {
            Label(optionDisplayTitle(option), systemImage: systemImage)
        } else {
            Text(optionDisplayTitle(option))
        }
    }

    private func optionDisplayTitle(_ option: CloudNowStreamQualityOption<Value>) -> String {
        guard let badge = option.badge else { return option.title }
        return "\(option.title)  —  \(badge)"
    }
}

struct CloudNowGameLanguagePicker: View {
    @Binding var selection: String

    var body: some View {
        Picker(L10n.text("game_language"), selection: $selection) {
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
        .accessibilityIdentifier("settings.stream-quality.game-language")
    }
}

struct CloudNowStreamQualitySection<Content: View>: View {
    let content: Content

    init(@ViewBuilder _ contentBuilder: () -> Content) {
        content = contentBuilder()
    }

    var body: some View {
        Section(L10n.text("stream_quality")) {
            content
        }
    }
}

/// Shared microphone preference presentation. Providers keep independent
/// persisted values and decide whether a requested microphone can be attached
/// to their own stream transport.
struct CloudNowMicrophoneSettingsSection: View {
    @Binding var isEnabled: Bool
    var isDisabled = false

    var body: some View {
        Section(L10n.text("microphone")) {
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("use_microphone"))
                    Text(L10n.text("microphone_description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
        .disabled(isDisabled)
    }
}

enum CloudNowDataDialog: Equatable {
    case confirmClearCache
    case confirmResetAllData
    case result(title: String, message: String)

    var title: String {
        switch self {
        case .confirmClearCache:
            L10n.text("clear_cache_confirmation_title")
        case .confirmResetAllData:
            L10n.text("reset_all_data_confirmation_title")
        case let .result(title, _):
            title
        }
    }

    var message: String {
        switch self {
        case .confirmClearCache:
            L10n.text("clear_cache_confirmation_message")
        case .confirmResetAllData:
            L10n.text("reset_active_service_confirmation_message")
        case let .result(_, message):
            message
        }
    }
}

struct SettingsView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(CloudGamingProviderCoordinator.self) private var providerCoordinator
    @Environment(CloudSessionCoordinator.self) private var sessionCoordinator
    @Environment(GamesViewModel.self) var viewModel

    @State private var showServerLocationPicker = false
    @State private var showNetworkTest = false
    @State private var showLibraryRefreshProgress = false
    @State private var dataDialog: CloudNowDataDialog?
    @State private var isPerformingDataAction = false

    var body: some View {
        @Bindable var vm = viewModel

        NavigationStack {
            Form {
                CloudNowCloudServiceSection(
                    activeProvider: providerCoordinator.selectedProvider ?? .geForceNow,
                    isInteractionDisabled: isProviderActionBusy,
                    onSelectProvider: switchProvider
                )

                CloudNowStreamQualitySection {
                    CloudNowStreamQualityPicker(
                        L10n.text("resolution"),
                        selection: $vm.streamSettings.resolution,
                        accessibilityIdentifier: "settings.stream-quality.resolution",
                        groups: geForceNowResolutionGroups
                    )

                    Picker(L10n.text("frame_rate"), selection: $vm.streamSettings.fps) {
                        ForEach(viewModel.availableFps, id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }

                    CloudNowStreamQualityPicker(
                        L10n.text("codec"),
                        selection: $vm.streamSettings.codec,
                        accessibilityIdentifier: "settings.stream-quality.codec",
                        options: VideoCodec.allCases.map {
                            CloudNowStreamQualityOption(value: $0, title: $0.label)
                        }
                    )

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

                    CloudNowGameLanguagePicker(
                        selection: $vm.streamSettings.gameLanguage
                    )

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
                        showServerLocationPicker = true
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

                CloudNowMicrophoneSettingsSection(
                    isEnabled: $vm.streamSettings.micEnabled
                )

                CloudNowControllerSettingsSection(
                    rumbleEnabled: $vm.streamSettings.rumbleEnabled,
                    rumbleIntensity: $vm.streamSettings.rumbleIntensity,
                    controllerDeadzone: $vm.streamSettings.controllerDeadzone,
                    policy: .geForceNow
                ) {
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
                        Text(L10n.remoteInputModeLabel(.gamepad)).tag(RemoteInputMode.gamepad)
                        Text(L10n.remoteInputModeLabel(.dualsense)).tag(RemoteInputMode.dualsense)
                        Text(L10n.remoteInputModeLabel(.gamepadMouse)).tag(RemoteInputMode.gamepadMouse)
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

                if viewModel.isProviderLibrarySyncEnabled {
                    Section(L10n.text("library")) {
                        Button {
                            viewModel.startFullLibraryRefresh(authManager: authManager)
                            showLibraryRefreshProgress = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(L10n.text("refresh_library"), systemImage: "arrow.triangle.2.circlepath")
                                    Text(L10n.text("refresh_library_description"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                                .padding(.vertical, 8)
                                Spacer()
                                if viewModel.isFullLibraryRefreshRunning {
                                    ProgressView()
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .disabled(!viewModel.canPresentFullLibraryRefresh)
                        .accessibilityIdentifier("libraryRefreshButton")
                        .accessibilityLabel(L10n.text("refresh_library"))
                        .accessibilityHint(L10n.text("refresh_library_description"))
                        .accessibilityValue(
                            viewModel.isFullLibraryRefreshRunning
                                ? L10n.text("refresh_syncing")
                                : ""
                        )
                    }
                }

                #if DEBUG
                    CloudNowDiagnosticsSettingsSection(
                        diagnosticsEnabled: $vm.streamSettings.diagnosticsEnabled,
                        enableRtcEventLog: $vm.streamSettings.enableRtcEventLog,
                        isDisabled: false
                    )
                #endif

                CloudNowStorageAndDataSection(
                    isPerformingAction: isProviderActionBusy,
                    clearCache: { dataDialog = .confirmClearCache },
                    resetAllData: { dataDialog = .confirmResetAllData }
                )

                Section(L10n.text("account")) {
                    if let user = authManager.session?.user {
                        LabeledContent(L10n.text("name"), value: user.displayName)
                        if let email = user.email {
                            LabeledContent(L10n.text("email"), value: email)
                        }
                        if let sub = viewModel.subscription {
                            if let best = sub.entitledResolutions.max(by: {
                                ($0.widthInPixels, $0.framesPerSecond) < ($1.widthInPixels, $1.framesPerSecond)
                            }) {
                                LabeledContent(
                                    L10n.text("max_stream_quality"),
                                    value: "\(best.resolutionLabel) @ \(best.framesPerSecond)fps"
                                )
                            }
                            if !sub.isUnlimited, let remaining = sub.remainingMinutes {
                                let hours = remaining / 60
                                let mins = remaining % 60
                                LabeledContent(L10n.text("time_remaining"), value: hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m")
                            }
                        }
                    }

                    Button(role: .destructive) {
                        signOut()
                    } label: {
                        Label(L10n.text("sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(isProviderActionBusy)
                    .accessibilityIdentifier("settings.sign-out")
                }
            }
            .navigationTitle("")
            .sheet(isPresented: $showServerLocationPicker) {
                ServerLocationPickerView()
            }
            .sheet(isPresented: $showNetworkTest) {
                NetworkTestView()
            }
            .fullScreenCover(isPresented: $showLibraryRefreshProgress) {
                LibraryRefreshProgressView()
                    .environment(authManager)
                    .environment(viewModel)
            }
            .alert(
                dataDialog?.title ?? "",
                isPresented: dataDialogBinding,
                presenting: dataDialog
            ) { dialog in
                switch dialog {
                case .confirmClearCache:
                    Button(L10n.text("clear_cache"), role: .destructive) {
                        clearCache()
                    }
                    Button(L10n.text("cancel"), role: .cancel) {}
                case .confirmResetAllData:
                    Button(L10n.text("reset_all_data"), role: .destructive) {
                        resetAllData()
                    }
                    Button(L10n.text("cancel"), role: .cancel) {}
                case .result:
                    Button(L10n.text("ok")) {}
                }
            } message: { dialog in
                Text(dialog.message)
            }
        }
    }

    private var dataDialogBinding: Binding<Bool> {
        Binding(
            get: { dataDialog != nil },
            set: { isPresented in
                if !isPresented {
                    dataDialog = nil
                }
            }
        )
    }

    private var isProviderActionBusy: Bool {
        isPerformingDataAction || providerCoordinator.isProviderInteractionBlocked
    }

    private func switchProvider(to provider: CloudGamingProvider) {
        guard !isPerformingDataAction,
              let intent = providerCoordinator.beginProviderSwitch(to: provider)
        else {
            return
        }
        Task { @MainActor in
            await viewModel.deactivateForInactiveProvider()
            guard !Task.isCancelled else {
                providerCoordinator.cancelProviderSwitch(intent)
                return
            }
            _ = providerCoordinator.commitProviderSwitch(intent)
        }
    }

    private func clearCache() {
        isPerformingDataAction = true
        viewModel.prepareForCacheClear()
        Task {
            do {
                try await AppDataManager.shared.clearCaches(for: .geForceNow)
                dataDialog = .result(
                    title: L10n.text("cache_cleared"),
                    message: L10n.text("cache_cleared_message")
                )
            } catch {
                dataDialog = .result(
                    title: L10n.text("cache_clear_failed"),
                    message: L10n.format("cache_clear_failed_message", error.localizedDescription)
                )
            }
            isPerformingDataAction = false
        }
    }

    private func resetAllData() {
        guard let mutation = providerCoordinator.beginCredentialMutation() else {
            return
        }
        isPerformingDataAction = true
        authManager.prepareForDataReset()
        viewModel.prepareForDataReset()

        Task {
            defer {
                providerCoordinator.finishCredentialMutation(mutation)
                isPerformingDataAction = false
            }
            do {
                guard await endProviderSessionIfNeeded(.geForceNow) else {
                    authManager.abortDataResetWithoutActivation()
                    await authManager.activateForCurrentProvider()
                    await viewModel.load(authManager: authManager)
                    dataDialog = .result(
                        title: L10n.text("reset_failed"),
                        message: L10n.text("end_session_before_sign_out")
                    )
                    return
                }
                try await AppDataManager.shared.clearCaches(for: .geForceNow)
                let result = await AppDataManager.shared.clearPersistentData(
                    for: .geForceNow
                )
                if result.credentialsRemoved {
                    await viewModel.resetAllData()
                    authManager.finishDataReset()
                    providerCoordinator.select(nil)
                } else {
                    authManager.abortDataResetWithoutActivation()
                    providerCoordinator.preserveSelectionAfterFailedDataReset(
                        .geForceNow
                    )
                    providerCoordinator.presentDataResetFailure(
                        result.failureDescription ?? L10n.text("reset_failed")
                    )
                    await authManager.activateForCurrentProvider()
                    await viewModel.load(authManager: authManager)
                }
            } catch {
                authManager.abortDataResetWithoutActivation()
                await authManager.activateForCurrentProvider()
                await viewModel.load(authManager: authManager)
                dataDialog = .result(
                    title: L10n.text("reset_failed"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func signOut() {
        guard let mutation = providerCoordinator.beginCredentialMutation() else {
            return
        }
        isPerformingDataAction = true
        viewModel.prepareForLogout()
        Task {
            defer {
                providerCoordinator.finishCredentialMutation(mutation)
                isPerformingDataAction = false
            }
            do {
                guard await endProviderSessionIfNeeded(.geForceNow) else {
                    dataDialog = .result(
                        title: L10n.text("sign_out"),
                        message: L10n.text("end_session_before_sign_out")
                    )
                    return
                }
                try await authManager.logout()
            } catch {
                await viewModel.load(authManager: authManager)
                dataDialog = .result(
                    title: L10n.text("sign_out"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func endProviderSessionIfNeeded(
        _ provider: CloudGamingProvider
    ) async -> Bool {
        guard let lease = sessionCoordinator.serverSession,
              lease.provider == provider
        else {
            return true
        }
        return await sessionCoordinator.endServerSessionUsingProvider(lease)
    }

    private var serverLocationValue: String {
        let settings = viewModel.streamSettings
        return switch settings.serverRoutingMode {
        case .serverAuto:
            settings.serverRoutingMode.label
        case .client:
            zoneLabel(settings.preferredZoneUrl) ?? settings.serverRoutingMode.label
        case .region:
            settings.preferredRegionName ?? L10n.text("region")
        }
    }

    private var serverLocationDescription: String {
        switch viewModel.streamSettings.serverRoutingMode {
        case .serverAuto:
            L10n.text("automatic_server_decides_description")
        case .client:
            L10n.text("servers_description")
        case .region:
            L10n.text("server_selection_warning")
        }
    }

    private func zoneLabel(_ url: String?) -> String? {
        guard let url else { return nil }
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

    private var geForceNowResolutionGroups: [CloudNowStreamQualityOptionGroup<String>] {
        let common = commonResolutions
            .filter { viewModel.availableResolutions.contains($0.res) }
            .map {
                CloudNowStreamQualityOption(
                    value: $0.res,
                    title: $0.res,
                    badge: $0.badge,
                    systemImage: $0.symbol
                )
            }
        let commonValues = Set(commonResolutions.map(\.res))
        let other = viewModel.availableResolutions
            .filter { !commonValues.contains($0) }
            .map { CloudNowStreamQualityOption(value: $0, title: $0) }
        return [
            CloudNowStreamQualityOptionGroup(
                title: L10n.text("tv_standards"),
                options: common
            ),
            CloudNowStreamQualityOptionGroup(
                title: L10n.text("other"),
                options: other
            ),
        ]
    }
}

// MARK: - Server Location Picker

private struct ServerLocationPickerView: View {
    private enum Route: Hashable {
        case region
        case servers
        case country(String)
        case city(countryCode: String, city: String)
    }

    private enum Choice: Hashable {
        case automatic
        case region
        case servers
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(GamesViewModel.self) private var viewModel
    @Environment(AuthManager.self) private var authManager

    @State private var path: [Route] = []
    @State private var serverInfo: GFNServerInfo?
    @State private var isLoadingRegions = true
    @State private var regionError: String?
    @State private var serverZones: [GFNZone] = []
    @State private var isLoadingServers = true
    @State private var serverError: String?
    @FocusState private var focusedChoice: Choice?

    init() {
        let cached = ServerInfoClient.shared.cached
        _serverInfo = State(initialValue: cached)
        _isLoadingRegions = State(initialValue: cached == nil)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ServerPickerScreen(title: L10n.text("server_location")) {
                List {
                    Section {
                        choiceRow(
                            title: L10n.text("automatic"),
                            subtitle: serverAutoSubtitle,
                            selected: viewModel.streamSettings.serverRoutingMode == .serverAuto,
                            choice: .automatic
                        ) {
                            selectServerAutomatic()
                        }

                        choiceRow(
                            title: L10n.text("region"),
                            subtitle: regionChoiceSubtitle,
                            selected: viewModel.streamSettings.serverRoutingMode == .region,
                            choice: .region,
                            showsDisclosure: true
                        ) {
                            path.append(.region)
                        }

                        choiceRow(
                            title: L10n.text("servers"),
                            subtitle: serversChoiceSubtitle,
                            selected: viewModel.streamSettings.serverRoutingMode == .client,
                            choice: .servers,
                            showsDisclosure: true
                        ) {
                            path.append(.servers)
                        }
                    }
                }
            }
            .defaultFocus($focusedChoice, selectedChoice)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .region:
                    RegionPickerView(
                        serverInfo: serverInfo,
                        isLoading: isLoadingRegions,
                        error: regionError
                    ) { region in
                        selectRegion(region)
                    }
                case .servers:
                    ServerCountryPickerView(
                        zones: serverZones,
                        isLoading: isLoadingServers,
                        error: serverError
                    ) { countryCode in
                        path.append(.country(countryCode))
                    }
                    .task {
                        await loadServers()
                    }
                case let .country(countryCode):
                    ServerCityPickerView(
                        countryCode: countryCode,
                        zones: serverZones.filter { $0.countryCode == countryCode }
                    ) { city in
                        path.append(.city(countryCode: countryCode, city: city))
                    }
                case let .city(countryCode, city):
                    DedicatedServerPickerView(
                        city: city,
                        zones: serverZones.filter { $0.countryCode == countryCode && $0.city == city }
                    ) { zone in
                        selectDedicatedZone(zone)
                    }
                }
            }
            .task {
                await loadRegions()
            }
        }
        .blocksGlobalControllerNavigation()
    }

    private var selectedChoice: Choice {
        switch viewModel.streamSettings.serverRoutingMode {
        case .serverAuto: .automatic
        case .client: .servers
        case .region: .region
        }
    }

    private var serverAutoSubtitle: String {
        if let local = serverInfo?.localRegionName, !local.isEmpty {
            return L10n.format("detected_region", local)
        }
        return L10n.text("automatic_server_decides_description")
    }

    private var serversChoiceSubtitle: String {
        if viewModel.streamSettings.serverRoutingMode == .client,
           let zone = displayZone(viewModel.streamSettings.preferredZoneUrl)
        {
            return zone
        }
        return L10n.text("servers_description")
    }

    private var regionChoiceSubtitle: String {
        if viewModel.streamSettings.serverRoutingMode == .region,
           let region = viewModel.streamSettings.preferredRegionName
        {
            return region
        }
        return L10n.text("server_selection_warning")
    }

    private func choiceRow(
        title: String,
        subtitle: String,
        selected: Bool,
        choice: Choice,
        showsDisclosure: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if selected {
                    Image(systemName: "checkmark")
                }
                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(ServerRowButtonStyle())
        .focused($focusedChoice, equals: choice)
    }

    private func selectServerAutomatic() {
        viewModel.streamSettings.serverRoutingMode = .serverAuto
        viewModel.streamSettings.preferredZoneUrl = nil
        viewModel.streamSettings.preferredRegionName = nil
        viewModel.streamSettings.preferredRegionAddress = nil
        dismiss()
    }

    private func selectDedicatedZone(_ zone: GFNZone) {
        viewModel.streamSettings.serverRoutingMode = .client
        viewModel.streamSettings.preferredZoneUrl = zone.zoneUrl
        viewModel.streamSettings.preferredRegionName = nil
        viewModel.streamSettings.preferredRegionAddress = nil
        dismiss()
    }

    private func selectRegion(_ region: GFNRegion) {
        viewModel.streamSettings.serverRoutingMode = .region
        viewModel.streamSettings.preferredZoneUrl = nil
        viewModel.streamSettings.preferredRegionName = region.name
        viewModel.streamSettings.preferredRegionAddress = region.address
        dismiss()
    }

    private func loadRegions() async {
        if let cached = ServerInfoClient.shared.cached {
            serverInfo = cached
            isLoadingRegions = false
        }

        let base = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
        guard let token = try? await authManager.resolveToken() else {
            isLoadingRegions = false
            if serverInfo == nil {
                regionError = L10n.text("sign_in_to_geforce_now")
            }
            return
        }

        do {
            serverInfo = try await ServerInfoClient.shared.fetch(baseUrl: base, token: token)
            regionError = nil
        } catch {
            if serverInfo == nil {
                regionError = error.localizedDescription
            }
        }
        isLoadingRegions = false
    }

    private func loadServers() async {
        if !serverZones.isEmpty {
            isLoadingServers = false
            return
        }

        isLoadingServers = true
        serverError = nil
        do {
            serverZones = try await ZoneClient.shared.fetchZones()
        } catch {
            serverError = error.localizedDescription
        }
        isLoadingServers = false
    }

    private func displayZone(_ url: String?) -> String? {
        guard let url else { return nil }
        let host = URL(string: url)?.host ?? url
        return host.components(separatedBy: ".").first?.uppercased() ?? url
    }
}

struct ServerPickerScreen<Content: View>: View {
    let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 64)
                .padding(.top, 36)
                .padding(.bottom, 20)
            content
        }
        .navigationTitle("")
    }
}

struct ServerRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
                .padding(.vertical, 14)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isFocused
                        ? AnyShapeStyle(.white)
                        : AnyShapeStyle(Color.primary.opacity(0.08))
                )
                .clipShape(.rect(cornerRadius: 14))
                .scaleEffect(isFocused && !reduceMotion ? 1.03 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
        }
    }
}

// MARK: - Dedicated Server Browser

private struct ServerCountryPickerView: View {
    private struct Country: Identifiable {
        let code: String
        let name: String
        var id: String {
            code
        }
    }

    let zones: [GFNZone]
    let isLoading: Bool
    let error: String?
    let onSelect: (String) -> Void

    @Environment(GamesViewModel.self) private var viewModel
    @FocusState private var focusedCountryCode: String?

    private var countries: [Country] {
        Set(zones.map(\.countryCode))
            .map { Country(code: $0, name: localizedServerCountryName($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var selectedCountryCode: String? {
        guard viewModel.streamSettings.serverRoutingMode == .client,
              let selectedURL = viewModel.streamSettings.preferredZoneUrl
        else { return nil }
        return zones.first { $0.zoneUrl == selectedURL }?.countryCode
    }

    var body: some View {
        ServerPickerScreen(title: L10n.text("servers")) {
            Group {
                if isLoading {
                    ProgressView {
                        Text(L10n.text("loading_servers"))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView(
                        L10n.text("cant_load_servers"),
                        systemImage: "wifi.exclamationmark",
                        description: Text(error)
                    )
                } else {
                    List {
                        Section {
                            ForEach(countries) { country in
                                Button {
                                    onSelect(country.code)
                                } label: {
                                    HStack {
                                        Text(country.name)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if selectedCountryCode == country.code {
                                            Image(systemName: "checkmark")
                                        }
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(ServerRowButtonStyle())
                                .focused($focusedCountryCode, equals: country.code)
                            }
                        }
                    }
                }
            }
            .task(id: isLoading) {
                guard !isLoading else { return }
                await Task.yield()
                focusedCountryCode = selectedCountryCode ?? countries.first?.code
            }
        }
        .defaultFocus($focusedCountryCode, selectedCountryCode ?? countries.first?.code)
    }
}

private struct ServerCityPickerView: View {
    let countryCode: String
    let zones: [GFNZone]
    let onSelect: (String) -> Void

    @Environment(GamesViewModel.self) private var viewModel
    @FocusState private var focusedCity: String?

    private var cities: [String] {
        Set(zones.map(\.city)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var selectedCity: String? {
        guard viewModel.streamSettings.serverRoutingMode == .client,
              let selectedURL = viewModel.streamSettings.preferredZoneUrl
        else { return nil }
        return zones.first { $0.zoneUrl == selectedURL }?.city
    }

    var body: some View {
        ServerPickerScreen(title: localizedServerCountryName(countryCode)) {
            List {
                Section {
                    ForEach(cities, id: \.self) { city in
                        Button {
                            onSelect(city)
                        } label: {
                            HStack {
                                Text(city)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if selectedCity == city {
                                    Image(systemName: "checkmark")
                                }
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(ServerRowButtonStyle())
                        .focused($focusedCity, equals: city)
                    }
                }
            }
        }
        .defaultFocus($focusedCity, selectedCity ?? cities.first)
    }
}

private struct DedicatedServerPickerView: View {
    private static let maximumConcurrentPingMeasurements = 6

    let city: String
    let onSelect: (GFNZone) -> Void

    @Environment(GamesViewModel.self) private var viewModel

    @State private var zones: [GFNZone]
    @FocusState private var focusedZoneURL: String?

    init(city: String, zones: [GFNZone], onSelect: @escaping (GFNZone) -> Void) {
        self.city = city
        self.onSelect = onSelect
        _zones = State(initialValue: zones.sorted { $0.id < $1.id })
    }

    private var recommendedZone: GFNZone? {
        zones.recommendedZone(isUnlimited: viewModel.subscription?.isUnlimited ?? false)
    }

    private var selectedZoneURL: String? {
        guard viewModel.streamSettings.serverRoutingMode == .client else { return nil }
        return viewModel.streamSettings.preferredZoneUrl
    }

    private var defaultFocusZoneURL: String? {
        selectedZoneURL ?? recommendedZone?.zoneUrl ?? zones.first?.zoneUrl
    }

    var body: some View {
        ServerPickerScreen(title: city) {
            List {
                Section {
                    ForEach(zones) { zone in
                        Button {
                            onSelect(zone)
                        } label: {
                            HStack(spacing: 20) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(zone.id)
                                        .font(.body)
                                    HStack(spacing: 28) {
                                        serverMetric(
                                            "Q \(zone.queuePosition)",
                                            systemImage: "person.3.fill",
                                            color: queueColor(zone.queuePosition),
                                            isFocused: focusedZoneURL == zone.zoneUrl
                                        )
                                        if let ping = zone.pingMs {
                                            serverMetric(
                                                "\(ping) ms",
                                                systemImage: "timer",
                                                color: pingColor(ping),
                                                isFocused: focusedZoneURL == zone.zoneUrl
                                            )
                                        } else if zone.isMeasuring {
                                            serverMetric(
                                                "…",
                                                systemImage: "timer",
                                                color: .secondary,
                                                isFocused: focusedZoneURL == zone.zoneUrl
                                            )
                                        }
                                    }
                                    .font(.caption)
                                }
                                Spacer()
                                if selectedZoneURL == zone.zoneUrl {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(focusedZoneURL == zone.zoneUrl ? .black : .green)
                                } else if recommendedZone?.id == zone.id {
                                    Text(L10n.text("best"))
                                        .font(.caption.bold())
                                        .foregroundStyle(focusedZoneURL == zone.zoneUrl ? .black : .green)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            focusedZoneURL == zone.zoneUrl
                                                ? Color.black.opacity(0.12)
                                                : Color.green.opacity(0.15),
                                            in: Capsule()
                                        )
                                }
                            }
                        }
                        .buttonStyle(ServerRowButtonStyle())
                        .focused($focusedZoneURL, equals: zone.zoneUrl)
                    }
                }
            }
            .task {
                focusedZoneURL = defaultFocusZoneURL
                await measurePings()
            }
        }
        .defaultFocus($focusedZoneURL, defaultFocusZoneURL)
    }

    private func serverMetric(
        _ text: String,
        systemImage: String,
        color: Color,
        isFocused: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
                .monospacedDigit()
        }
        .foregroundStyle(isFocused ? .black : color)
    }

    private func measurePings() async {
        let staleZones = zones.filter(\.isMeasuring)
        await withTaskGroup(of: (String, Int?).self) { group in
            var pendingZones = staleZones.makeIterator()

            for _ in 0 ..< min(Self.maximumConcurrentPingMeasurements, staleZones.count) {
                guard let zone = pendingZones.next() else { break }
                group.addTask {
                    let ping = await ZoneClient.shared.measurePing(to: zone.zoneUrl)
                    return (zone.id, ping)
                }
            }

            for await (id, ping) in group {
                guard !Task.isCancelled else { return }
                if let index = zones.firstIndex(where: { $0.id == id }) {
                    zones[index].pingMs = ping
                    zones[index].isMeasuring = false
                }

                if let zone = pendingZones.next() {
                    group.addTask {
                        let ping = await ZoneClient.shared.measurePing(to: zone.zoneUrl)
                        return (zone.id, ping)
                    }
                }
            }
        }
    }

    private func queueColor(_ queuePosition: Int) -> Color {
        if queuePosition <= 5 {
            return .green
        }
        if queuePosition <= 15 {
            return .yellow
        }
        if queuePosition <= 30 {
            return .orange
        }
        return .red
    }

    private func pingColor(_ milliseconds: Int) -> Color {
        if milliseconds < 30 {
            return .green
        }
        if milliseconds < 80 {
            return .yellow
        }
        if milliseconds < 150 {
            return .orange
        }
        return .red
    }
}

private func localizedServerCountryName(_ countryCode: String) -> String {
    let locale = Locale(identifier: L10n.localeCode)
    return locale.localizedString(forRegionCode: countryCode)
        ?? GFNZone.regionMeta[countryCode]?.label
        ?? countryCode
}

// MARK: - Region Picker

private struct RegionPickerView: View {
    let serverInfo: GFNServerInfo?
    let isLoading: Bool
    let error: String?
    let onSelect: (GFNRegion) -> Void

    @Environment(GamesViewModel.self) private var viewModel
    @FocusState private var focusedRegionID: String?

    private var selectedRegionID: String? {
        guard viewModel.streamSettings.serverRoutingMode == .region else { return nil }
        return viewModel.streamSettings.preferredRegionName
    }

    var body: some View {
        ServerPickerScreen(title: L10n.text("region")) {
            Group {
                if let regions = serverInfo?.regions, !regions.isEmpty {
                    List {
                        Section {
                            ForEach(regions) { region in
                                Button {
                                    onSelect(region)
                                } label: {
                                    HStack {
                                        Text(region.name)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if selectedRegionID == region.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                        }
                                    }
                                }
                                .buttonStyle(ServerRowButtonStyle())
                                .focused($focusedRegionID, equals: region.id)
                            }
                        } footer: {
                            Text(L10n.text("server_selection_warning"))
                        }
                    }
                } else if isLoading {
                    ProgressView {
                        Text(L10n.text("loading_servers"))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        L10n.text("cant_load_servers"),
                        systemImage: "wifi.exclamationmark",
                        description: Text(error ?? "")
                    )
                }
            }
            .task(id: isLoading) {
                guard !isLoading else { return }
                await Task.yield()
                focusedRegionID = selectedRegionID ?? serverInfo?.regions.first?.id
            }
        }
        .defaultFocus(
            $focusedRegionID,
            selectedRegionID ?? serverInfo?.regions.first?.id
        )
    }
}

// MARK: - Network Test

private struct NetworkTestView: View {
    @Environment(GamesViewModel.self) private var viewModel
    @Environment(AuthManager.self) private var authManager

    var body: some View {
        CloudNetworkTestView {
            let target = await resolveTarget()
            return CloudNetworkTestTarget(
                address: target.address,
                displayName: target.name
            )
        }
    }

    private func resolveTarget() async -> (address: String, name: String?) {
        let settings = viewModel.streamSettings
        switch settings.serverRoutingMode {
        case .client:
            if let address = settings.preferredZoneUrl {
                return (address, displayZone(address))
            }
        case .region:
            if let address = settings.preferredRegionAddress {
                return (address, settings.preferredRegionName)
            }
        case .serverAuto:
            break
        }

        let base = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
        let cached = ServerInfoClient.shared.cached
        let info: GFNServerInfo? = if let token = try? await authManager.resolveToken() {
            await (try? ServerInfoClient.shared.fetch(baseUrl: base, token: token)) ?? cached
        } else {
            cached
        }
        if let local = info?.localRegionName,
           let region = info?.regions.first(where: { $0.name == local })
        {
            return (region.address, local)
        }
        return (base, info?.localRegionName)
    }

    private func displayZone(_ url: String) -> String {
        let host = URL(string: url)?.host ?? url
        return host.components(separatedBy: ".").first?.uppercased() ?? url
    }
}
