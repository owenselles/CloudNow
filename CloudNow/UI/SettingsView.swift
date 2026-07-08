import AVFoundation
import GameController
import SwiftUI
import UIKit

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

struct CloudNowSettingUnavailability: Equatable {
    let reason: String
    let recoveryActionTitle: String?

    init(reason: String, recoveryActionTitle: String? = nil) {
        self.reason = reason
        self.recoveryActionTitle = recoveryActionTitle
    }
}

struct CloudNowSettingOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let badge: String?
    let systemImage: String?
    let accessibilityIdentifier: String?
    let unavailability: CloudNowSettingUnavailability?

    var id: Value {
        value
    }

    init(
        value: Value,
        title: String,
        badge: String? = nil,
        systemImage: String? = nil,
        accessibilityIdentifier: String? = nil,
        unavailability: CloudNowSettingUnavailability? = nil
    ) {
        self.value = value
        self.title = title
        self.badge = badge
        self.systemImage = systemImage
        self.accessibilityIdentifier = accessibilityIdentifier
        self.unavailability = unavailability
    }

    var displayTitle: String {
        guard let badge else { return title }
        return "\(title)  —  \(badge)"
    }

    var isAvailable: Bool {
        unavailability == nil
    }
}

struct CloudNowSettingOptionGroup<Value: Hashable>: Identifiable {
    let title: String?
    let options: [CloudNowSettingOption<Value>]

    var id: String {
        title ?? "__default"
    }
}

struct CloudNowSettingSelectionRow<Value: Hashable>: View {
    let title: String
    let description: String?
    let descriptionIsWarning: Bool
    let accessibilityIdentifier: String
    @Binding var selection: Value
    let groups: [CloudNowSettingOptionGroup<Value>]
    let onRecoveryAction: (() -> Void)?

    init(
        _ title: String,
        description: String? = nil,
        descriptionIsWarning: Bool = false,
        selection: Binding<Value>,
        accessibilityIdentifier: String,
        options: [CloudNowSettingOption<Value>],
        onRecoveryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.description = description
        self.descriptionIsWarning = descriptionIsWarning
        self.accessibilityIdentifier = accessibilityIdentifier
        _selection = selection
        groups = [CloudNowSettingOptionGroup(title: nil, options: options)]
        self.onRecoveryAction = onRecoveryAction
    }

    init(
        _ title: String,
        description: String? = nil,
        descriptionIsWarning: Bool = false,
        selection: Binding<Value>,
        accessibilityIdentifier: String,
        groups: [CloudNowSettingOptionGroup<Value>],
        onRecoveryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.description = description
        self.descriptionIsWarning = descriptionIsWarning
        self.accessibilityIdentifier = accessibilityIdentifier
        _selection = selection
        self.groups = groups
        self.onRecoveryAction = onRecoveryAction
    }

    var body: some View {
        NavigationLink {
            CloudNowSettingSelectionPage(
                title: title,
                selection: $selection,
                groups: groups,
                accessibilityIdentifier: accessibilityIdentifier,
                onRecoveryAction: onRecoveryAction
            )
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    if let description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(
                                descriptionIsWarning ? .orange : .secondary
                            )
                    }
                }
                .padding(.vertical, 8)
                Spacer()
                Text(selectedOption?.displayTitle ?? "")
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(title)
        .accessibilityValue(selectedOption?.displayTitle ?? "")
        .accessibilityHint(description ?? "")
    }

    private var selectedOption: CloudNowSettingOption<Value>? {
        groups.lazy.flatMap(\.options).first { $0.value == selection }
    }
}

private struct CloudNowSettingSelectionPage<Value: Hashable>: View {
    private struct UnavailableSelection {
        let title: String
        let unavailability: CloudNowSettingUnavailability
    }

    let title: String
    @Binding var selection: Value
    let groups: [CloudNowSettingOptionGroup<Value>]
    let accessibilityIdentifier: String
    let onRecoveryAction: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedValue: Value?
    @State private var unavailableSelection: UnavailableSelection?

    var body: some View {
        Form {
            CloudNowSettingsPageTitle(
                title: title,
                accessibilityIdentifier: "\(accessibilityIdentifier).title"
            )

            ForEach(groups) { group in
                if !group.options.isEmpty {
                    Section {
                        ForEach(group.options) { option in
                            optionButton(option)
                        }
                    } header: {
                        if let title = group.title {
                            Text(title)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .navigationTitle("")
        .accessibilityIdentifier("\(accessibilityIdentifier).page")
        .task {
            await Task.yield()
            focusedValue = selection
        }
        .defaultFocus($focusedValue, selection)
        .blocksGlobalControllerNavigation()
        .alert(
            unavailableSelection?.title ?? "",
            isPresented: unavailableSelectionBinding,
            presenting: unavailableSelection
        ) { selection in
            if selection.unavailability.recoveryActionTitle != nil,
               let onRecoveryAction
            {
                Button(selection.unavailability.recoveryActionTitle ?? "") {
                    onRecoveryAction()
                }
            }
            Button(L10n.text("ok"), role: .cancel) {}
        } message: { selection in
            Text(selection.unavailability.reason)
        }
    }

    private func optionButton(_ option: CloudNowSettingOption<Value>) -> some View {
        Button {
            if let unavailability = option.unavailability {
                unavailableSelection = UnavailableSelection(
                    title: option.displayTitle,
                    unavailability: unavailability
                )
                return
            }
            selection = option.value
            dismiss()
        } label: {
            HStack(spacing: 20) {
                if let systemImage = option.systemImage {
                    Image(systemName: systemImage)
                        .font(.headline)
                        .frame(width: 56, alignment: .center)
                        .accessibilityHidden(true)
                }
                Text(option.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()
                if option.value == selection {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }
                if !option.isAvailable {
                    Label(
                        L10n.text("unavailable"),
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(option.isAvailable ? .primary : .secondary)
        }
        .focused($focusedValue, equals: option.value)
        .accessibilityLabel(option.displayTitle)
        .accessibilityValue(
            option.isAvailable ? "" : L10n.text("unavailable")
        )
        .accessibilityHint(option.unavailability?.reason ?? "")
        .accessibilityAddTraits(option.value == selection ? .isSelected : [])
        .accessibilityIdentifier(optionIdentifier(option))
    }

    private var unavailableSelectionBinding: Binding<Bool> {
        Binding(
            get: { unavailableSelection != nil },
            set: { isPresented in
                if !isPresented {
                    unavailableSelection = nil
                }
            }
        )
    }

    private func optionIdentifier(_ option: CloudNowSettingOption<Value>) -> String {
        let optionIdentifier = option.accessibilityIdentifier
            ?? String(describing: option.value)
        return "\(accessibilityIdentifier).option.\(optionIdentifier)"
    }
}

private struct CloudNowSettingsPageTitle: View {
    let title: String
    let accessibilityIdentifier: String

    var body: some View {
        Text(title)
            .font(.title2.bold())
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct CloudNowGameLanguageSelectionRow: View {
    @Binding var selection: String
    let automaticValue: String

    private static let languageCodes = [
        "en_US", "en_GB", "fr_FR", "de_DE", "es_ES", "it_IT", "pt_BR",
        "hi_IN", "ja_JP", "ko_KR", "zh_CN", "zh_TW", "ru_RU", "ar_SA",
        "nl_NL", "pl_PL", "sv_SE", "fi_FI", "tr_TR", "el_GR", "he_IL",
        "cs_CZ", "da_DK", "hr_HR", "hu_HU", "id_ID", "ms_MY", "ro_RO",
        "sk_SK", "vi_VN", "uk_UA",
    ]

    var body: some View {
        CloudNowSettingSelectionRow(
            L10n.text("game_language"),
            selection: $selection,
            accessibilityIdentifier: "settings.stream-quality.game-language",
            options: [
                CloudNowSettingOption(
                    value: automaticValue,
                    title: L10n.text("automatic"),
                    accessibilityIdentifier: "automatic"
                ),
            ] + Self.languageCodes.map { code in
                CloudNowSettingOption(
                    value: code,
                    title: L10n.localizedLanguageName(for: code),
                    accessibilityIdentifier: code
                )
            }
        )
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
    let isDisabled: Bool

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var permissionStatus: CloudNowMicrophonePermissionStatus
    @State private var isRequestingPermission = false

    init(isEnabled: Binding<Bool>, isDisabled: Bool = false) {
        _isEnabled = isEnabled
        self.isDisabled = isDisabled
        _permissionStatus = State(
            initialValue: Self.currentMicrophonePermissionStatus
        )
    }

    var body: some View {
        Section(L10n.text("microphone")) {
            Toggle(isOn: permissionAwareBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("use_microphone"))
                    Text(microphoneDescription)
                        .font(.caption)
                        .foregroundStyle(
                            permissionStatus == .denied ? .orange : .secondary
                        )
                }
                .padding(.vertical, 8)
            }
            .disabled(
                permissionStatus == .denied || isRequestingPermission
            )
            .accessibilityIdentifier("settings.microphone.enabled")

            if permissionStatus == .denied {
                Button(action: openApplicationSettings) {
                    Label(
                        L10n.text("open_settings"),
                        systemImage: "gear"
                    )
                }
                .accessibilityIdentifier("settings.microphone.open-settings")
            }
        }
        .disabled(isDisabled)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            permissionStatus = Self.currentMicrophonePermissionStatus
        }
    }

    private var permissionAwareBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: handlePreferenceChange
        )
    }

    private var microphoneDescription: String {
        permissionStatus == .denied
            ? L10n.text("microphone_permission_denied_message")
            : L10n.text("microphone_description")
    }

    private func handlePreferenceChange(_ requestedValue: Bool) {
        switch CloudNowMicrophoneSettingsPolicy.action(
            requestedValue: requestedValue,
            permissionStatus: permissionStatus
        ) {
        case let .setEnabled(isEnabled):
            self.isEnabled = isEnabled
        case .requestPermission:
            requestMicrophonePermission()
        case .blocked:
            break
        }
    }

    private func requestMicrophonePermission() {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        Task { @MainActor in
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            permissionStatus = granted ? .granted : .denied
            if granted {
                isEnabled = true
            }
            isRequestingPermission = false
        }
    }

    private func openApplicationSettings() {
        guard let settingsURL = URL(
            string: UIApplication.openSettingsURLString
        ) else {
            return
        }
        openURL(settingsURL)
    }

    private static var currentMicrophonePermissionStatus: CloudNowMicrophonePermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            .undetermined
        case .denied:
            .denied
        case .granted:
            .granted
        @unknown default:
            .denied
        }
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

private enum SettingsNavigationRoute: Hashable {
    case serverLocation
}

struct SettingsView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(CloudGamingProviderCoordinator.self) private var providerCoordinator
    @Environment(CloudSessionCoordinator.self) private var sessionCoordinator
    @Environment(GamesViewModel.self) var viewModel

    @State private var showNetworkTest = false
    @State private var showLibraryRefreshProgress = false
    @State private var dataDialog: CloudNowDataDialog?
    @State private var isPerformingDataAction = false
    @State private var navigationPath: [SettingsNavigationRoute] = []
    @State private var showTextInputSequenceCapture = false

    var body: some View {
        @Bindable var vm = viewModel

        NavigationStack(path: $navigationPath) {
            Form {
                CloudNowCloudServiceSection(
                    activeProvider: providerCoordinator.selectedProvider ?? .geForceNow,
                    isInteractionDisabled: isProviderActionBusy,
                    onSelectProvider: switchProvider
                )

                CloudNowStreamQualitySection {
                    CloudNowSettingSelectionRow(
                        L10n.text("resolution"),
                        selection: $vm.streamSettings.resolution,
                        accessibilityIdentifier: "settings.stream-quality.resolution",
                        groups: geForceNowResolutionGroups
                    )

                    CloudNowSettingSelectionRow(
                        L10n.text("frame_rate"),
                        selection: $vm.streamSettings.fps,
                        accessibilityIdentifier: "settings.stream-quality.frame-rate",
                        options: viewModel.frameRateEligibility.map { eligibility in
                            CloudNowSettingOption(
                                value: eligibility.framesPerSecond,
                                title: "\(eligibility.framesPerSecond) fps",
                                accessibilityIdentifier: "\(eligibility.framesPerSecond)",
                                unavailability: frameRateUnavailability(
                                    eligibility
                                )
                            )
                        }
                    )

                    CloudNowSettingSelectionRow(
                        L10n.text("codec"),
                        selection: $vm.streamSettings.codec,
                        accessibilityIdentifier: "settings.stream-quality.codec",
                        options: VideoCodec.allCases.map {
                            CloudNowSettingOption(
                                value: $0,
                                title: $0.label,
                                accessibilityIdentifier: $0.rawValue
                            )
                        }
                    )

                    CloudNowSettingSelectionRow(
                        L10n.text("color_mode"),
                        description: vm.streamSettings.codec == .av1
                            ? L10n.text("av1_software_path_warning")
                            : vm.streamSettings.colorPreference.description,
                        descriptionIsWarning: vm.streamSettings.codec == .av1,
                        selection: $vm.streamSettings.colorPreference,
                        accessibilityIdentifier: "settings.stream-quality.color-mode",
                        options: ColorModePreference.allCases.map {
                            CloudNowSettingOption(
                                value: $0,
                                title: $0.label,
                                accessibilityIdentifier: $0.rawValue
                            )
                        }
                    )

                    CloudNowSettingSelectionRow(
                        L10n.text("audio_format"),
                        description: L10n.text("audio_format_description"),
                        selection: $vm.streamSettings.audioFormat,
                        accessibilityIdentifier: "settings.stream-quality.audio-format",
                        options: AudioFormatPreference.allCases.map {
                            CloudNowSettingOption(
                                value: $0,
                                title: $0.label,
                                accessibilityIdentifier: $0.rawValue
                            )
                        }
                    )

                    CloudNowSettingSelectionRow(
                        L10n.text("keyboard_layout"),
                        selection: $vm.streamSettings.keyboardLayout,
                        accessibilityIdentifier: "settings.stream-quality.keyboard-layout",
                        options: L10n.supportedLanguageCodes.map { code in
                            CloudNowSettingOption(
                                value: code,
                                title: L10n.localizedLanguageName(for: code),
                                accessibilityIdentifier: code
                            )
                        }
                    )

                    CloudNowGameLanguageSelectionRow(
                        selection: $vm.streamSettings.gameLanguage,
                        automaticValue: StreamSettings.automaticGameLanguage
                    )

                    CloudNowSettingSelectionRow(
                        L10n.text("game_launch_mode"),
                        description: L10n.text("game_launch_mode_description"),
                        selection: $vm.streamSettings.appLaunchMode,
                        accessibilityIdentifier: "settings.stream-quality.game-launch-mode",
                        options: AppLaunchMode.allCases.map {
                            CloudNowSettingOption(
                                value: $0,
                                title: $0.label,
                                accessibilityIdentifier: $0.rawValue
                            )
                        }
                    )

                    LabeledContent(L10n.text("max_bitrate")) {
                        HStack(spacing: 16) {
                            Button {
                                vm.streamSettings.maxBitrateKbps = max(15000, vm.streamSettings.maxBitrateKbps - 5000)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .disabled(vm.streamSettings.maxBitrateKbps <= 15000)
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
                            .disabled(
                                vm.streamSettings.maxBitrateKbps
                                    >= StreamSettings.maxSelectableBitrateKbps
                            )
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
                    if isNvidiaDirectSession {
                        NavigationLink(value: SettingsNavigationRoute.serverLocation) {
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
                        .accessibilityIdentifier("settings.server-location")
                        .accessibilityLabel(L10n.text("server_location"))
                        .accessibilityValue(serverLocationValue)
                        .accessibilityHint(serverLocationDescription)
                    } else {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.text("server_location"))
                                Text(
                                    L10n.format(
                                        "managed_by_partner",
                                        authManager.session?.provider.displayName
                                            ?? CloudGamingProvider.geForceNow.displayName
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            Spacer()
                            Label(
                                L10n.text("unavailable"),
                                systemImage: "lock.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

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
                    CloudNowSettingSelectionRow(
                        L10n.text("overlay_button"),
                        description: L10n.text("overlay_button_description"),
                        selection: $vm.streamSettings.overlayTriggerButton,
                        accessibilityIdentifier: "settings.controller.overlay-button",
                        options: OverlayTriggerButton.allCases.map {
                            CloudNowSettingOption(
                                value: $0,
                                title: $0.label,
                                accessibilityIdentifier: $0.rawValue
                            )
                        }
                    )
                    Button {
                        showTextInputSequenceCapture = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.text("text_input_buttons"))
                                Text(L10n.text("text_input_buttons_description"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            Spacer()
                            Text(vm.streamSettings.textInputTriggerSequence.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    Toggle(isOn: $vm.streamSettings.enableSteamOverlayGesture) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("steam_overlay_gesture"))
                            Text(L10n.text("steam_overlay_gesture_description"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    CloudNowSettingSelectionRow(
                        L10n.text("default_input_mode"),
                        description: L10n.text("default_input_mode_description"),
                        selection: $vm.streamSettings.defaultRemoteInputMode,
                        accessibilityIdentifier: "settings.controller.default-input-mode",
                        options: [
                            CloudNowSettingOption(
                                value: RemoteInputMode.gamepad,
                                title: L10n.remoteInputModeLabel(.gamepad),
                                accessibilityIdentifier: RemoteInputMode.gamepad.rawValue
                            ),
                            CloudNowSettingOption(
                                value: RemoteInputMode.dualsense,
                                title: L10n.remoteInputModeLabel(.dualsense),
                                accessibilityIdentifier: RemoteInputMode.dualsense.rawValue
                            ),
                            CloudNowSettingOption(
                                value: RemoteInputMode.gamepadMouse,
                                title: L10n.remoteInputModeLabel(.gamepadMouse),
                                accessibilityIdentifier: RemoteInputMode.gamepadMouse.rawValue
                            ),
                        ]
                    )
                    LabeledContent(L10n.text("protocol"), value: "XInput over GFN v2/v3")
                }

                Section(L10n.text("game")) {
                    Toggle(isOn: $vm.streamSettings.persistInGameSettings) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("save_in_game_settings"))
                            Text(saveInGameSettingsDescription)
                                .font(.caption)
                                .foregroundStyle(
                                    viewModel.subscription?
                                        .allowsInGameSettingsPersistence == false
                                        ? .orange
                                        : .secondary
                                )
                        }
                        .padding(.vertical, 8)
                    }
                    .disabled(
                        viewModel.subscription?
                            .allowsInGameSettingsPersistence == false
                    )
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
            .navigationDestination(for: SettingsNavigationRoute.self) { route in
                switch route {
                case .serverLocation:
                    ServerLocationPickerView {
                        navigationPath.removeAll()
                    }
                }
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
            .sheet(isPresented: $showTextInputSequenceCapture) {
                TextInputTriggerSequenceCaptureSheet(
                    sequence: $vm.streamSettings.textInputTriggerSequence,
                    overlayTriggerButton: vm.streamSettings.overlayTriggerButton,
                    steamOverlayGestureEnabled: vm.streamSettings.enableSteamOverlayGesture
                )
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

    private var isNvidiaDirectSession: Bool {
        authManager.session?.provider.isNvidiaDirect ?? true
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
        ResolutionEntry(res: "5120x2880", badge: "5K", symbol: "tv"),
    ]

    private var geForceNowResolutionGroups: [CloudNowSettingOptionGroup<String>] {
        let availableResolutions = Set(viewModel.availableResolutions)
        let hasMembershipData = viewModel.subscription != nil
        let common = commonResolutions
            .filter { hasMembershipData || availableResolutions.contains($0.res) }
            .map {
                CloudNowSettingOption(
                    value: $0.res,
                    title: $0.res,
                    badge: $0.badge,
                    systemImage: $0.symbol,
                    accessibilityIdentifier: $0.res,
                    unavailability: availableResolutions.contains($0.res)
                        ? nil
                        : resolutionMembershipUnavailability($0.res)
                )
            }
        let commonValues = Set(commonResolutions.map(\.res))
        let other = viewModel.availableResolutions
            .filter { !commonValues.contains($0) }
            .map {
                CloudNowSettingOption(
                    value: $0,
                    title: $0,
                    accessibilityIdentifier: $0
                )
            }
        return [
            CloudNowSettingOptionGroup(
                title: L10n.text("tv_standards"),
                options: common
            ),
            CloudNowSettingOptionGroup(
                title: L10n.text("other"),
                options: other
            ),
        ]
    }

    private var geForceNowMembershipName: String {
        guard let rawValue = viewModel.subscription?.membershipTier
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty
        else {
            return L10n.text("unknown")
        }
        let normalizedValue = rawValue.uppercased()
        if normalizedValue.contains("ULTIMATE") {
            return "Ultimate"
        }
        if normalizedValue.contains("PERFORMANCE") {
            return "Performance"
        }
        if normalizedValue.contains("PRIORITY") {
            return "Priority"
        }
        if normalizedValue.contains("FREE") {
            return "Free"
        }
        return rawValue
    }

    private var saveInGameSettingsDescription: String {
        guard viewModel.subscription?.allowsInGameSettingsPersistence == false else {
            return L10n.text("save_in_game_settings_description")
        }
        return L10n.format(
            "save_in_game_settings_free_unavailable",
            geForceNowMembershipName
        )
    }

    private func resolutionMembershipUnavailability(
        _ resolution: String
    ) -> CloudNowSettingUnavailability {
        CloudNowSettingUnavailability(
            reason: L10n.format(
                "gfn_resolution_membership_unavailable",
                resolution,
                geForceNowMembershipName
            )
        )
    }

    private func frameRateUnavailability(
        _ eligibility: GFNFrameRateEligibility
    ) -> CloudNowSettingUnavailability? {
        guard let restriction = eligibility.restriction else { return nil }
        let framesPerSecond = eligibility.framesPerSecond
        let reason = switch restriction {
        case let .display(maximumFramesPerSecond):
            L10n.format(
                "gfn_frame_rate_display_unavailable",
                framesPerSecond,
                framesPerSecond,
                maximumFramesPerSecond
            )
        case .membership:
            L10n.format(
                "gfn_frame_rate_membership_unavailable",
                framesPerSecond,
                viewModel.streamSettings.resolution,
                geForceNowMembershipName
            )
        case let .displayAndMembership(maximumFramesPerSecond):
            L10n.format(
                "gfn_frame_rate_display_and_membership_unavailable",
                framesPerSecond,
                maximumFramesPerSecond,
                geForceNowMembershipName,
                viewModel.streamSettings.resolution
            )
        }
        return CloudNowSettingUnavailability(reason: reason)
    }
}

// MARK: - Text Input Trigger Capture

private struct TextInputTriggerSequenceCaptureSheet: View {
    @Binding var sequence: ControllerButtonSequence
    let overlayTriggerButton: OverlayTriggerButton
    let steamOverlayGestureEnabled: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var capturePhase: CapturePhase = .waiting
    @State private var liveButtons = Set<ControllerSequenceButton>()
    @State private var lastDetectedSequence: ControllerButtonSequence?
    @State private var validationMessage: String?

    private enum CapturePhase {
        case waiting
        case collecting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(
                        L10n.text("current_sequence"),
                        value: sequence.label
                    )
                }

                Section {
                    Text(L10n.text("capture_text_input_buttons_instructions"))
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Text(statusText)
                        .foregroundStyle(.primary)

                    if let detectedSequence {
                        LabeledContent(
                            L10n.text("detected_sequence"),
                            value: detectedSequence.label
                        )
                    }

                    if let validationMessage {
                        Text(validationMessage)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(L10n.text("capture_text_input_buttons"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("cancel")) {
                        dismiss()
                    }
                }
            }
            .task {
                await monitorControllerButtons()
            }
        }
    }

    private var statusText: String {
        switch capturePhase {
        case .waiting:
            L10n.text("press_buttons_now")
        case .collecting:
            L10n.text("release_buttons_to_save")
        }
    }

    private var detectedSequence: ControllerButtonSequence? {
        if !liveButtons.isEmpty {
            return ControllerButtonSequence(buttons: Array(liveButtons))
        }
        return lastDetectedSequence
    }

    @MainActor
    private func updateCapture(with pressedButtons: Set<ControllerSequenceButton>) {
        switch capturePhase {
        case .waiting:
            guard !pressedButtons.isEmpty else { return }
            capturePhase = .collecting
            validationMessage = nil
            liveButtons = pressedButtons
            lastDetectedSequence = ControllerButtonSequence(buttons: Array(pressedButtons))

        case .collecting:
            if !pressedButtons.isEmpty {
                liveButtons.formUnion(pressedButtons)
                lastDetectedSequence = ControllerButtonSequence(buttons: Array(liveButtons))
                return
            }
            finalizeCapture()
        }
    }

    @MainActor
    private func finalizeCapture() {
        let capturedSequence = ControllerButtonSequence(buttons: Array(liveButtons))
        liveButtons.removeAll()
        capturePhase = .waiting

        if let validationMessage = validationMessage(for: capturedSequence) {
            self.validationMessage = validationMessage
            lastDetectedSequence = capturedSequence
            return
        }

        sequence = capturedSequence
        dismiss()
    }

    private func validationMessage(for capturedSequence: ControllerButtonSequence) -> String? {
        guard !capturedSequence.isEmpty else {
            return L10n.text("button_sequence_empty")
        }
        guard capturedSequence.count <= ControllerButtonSequence.maxButtons else {
            return L10n.text("button_sequence_too_long")
        }
        if capturedSequence.count == 1, capturedSequence.contains(overlayConflictButton) {
            return L10n.text("button_sequence_conflicts_overlay")
        }
        if steamOverlayGestureEnabled,
           capturedSequence.count == 1,
           capturedSequence.contains(steamConflictButton)
        {
            return L10n.text("button_sequence_conflicts_steam")
        }
        return nil
    }

    private var overlayConflictButton: ControllerSequenceButton {
        switch overlayTriggerButton {
        case .start:
            .menu
        case .options:
            .options
        }
    }

    private var steamConflictButton: ControllerSequenceButton {
        switch overlayTriggerButton {
        case .start:
            .options
        case .options:
            .menu
        }
    }

    private func monitorControllerButtons() async {
        while !Task.isCancelled {
            let pressedButtons = currentPressedButtons()
            await MainActor.run {
                updateCapture(with: pressedButtons)
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func currentPressedButtons() -> Set<ControllerSequenceButton> {
        guard let pad = GCController.controllers().compactMap(\.extendedGamepad).first else {
            return []
        }

        var pressedButtons = Set<ControllerSequenceButton>()
        if pad.dpad.up.isPressed { pressedButtons.insert(.dpadUp) }
        if pad.dpad.down.isPressed { pressedButtons.insert(.dpadDown) }
        if pad.dpad.left.isPressed { pressedButtons.insert(.dpadLeft) }
        if pad.dpad.right.isPressed { pressedButtons.insert(.dpadRight) }
        if pad.buttonA.isPressed { pressedButtons.insert(.buttonA) }
        if pad.buttonB.isPressed { pressedButtons.insert(.buttonB) }
        if pad.buttonX.isPressed { pressedButtons.insert(.buttonX) }
        if pad.buttonY.isPressed { pressedButtons.insert(.buttonY) }
        if pad.buttonMenu.isPressed { pressedButtons.insert(.menu) }
        if pad.buttonOptions?.isPressed == true { pressedButtons.insert(.options) }
        if pad.leftShoulder.isPressed { pressedButtons.insert(.leftShoulder) }
        if pad.rightShoulder.isPressed { pressedButtons.insert(.rightShoulder) }
        if pad.leftThumbstickButton?.isPressed == true { pressedButtons.insert(.leftThumbstick) }
        if pad.rightThumbstickButton?.isPressed == true { pressedButtons.insert(.rightThumbstick) }
        return pressedButtons
    }
}

// MARK: - Server Location Picker

#if DEBUG
    struct CloudNowServerLocationFixture {
        let serverInfo: GFNServerInfo
        let zones: [GFNZone]
    }

    private struct CloudNowServerLocationFixtureKey: EnvironmentKey {
        static let defaultValue: CloudNowServerLocationFixture? = nil
    }

    extension EnvironmentValues {
        var cloudNowServerLocationFixture: CloudNowServerLocationFixture? {
            get { self[CloudNowServerLocationFixtureKey.self] }
            set { self[CloudNowServerLocationFixtureKey.self] = newValue }
        }
    }
#endif

private struct ServerLocationPickerView: View {
    private enum Choice: Hashable {
        case automatic
        case region
        case servers
    }

    @Environment(GamesViewModel.self) private var viewModel
    @Environment(AuthManager.self) private var authManager
    #if DEBUG
        @Environment(\.cloudNowServerLocationFixture) private var fixture
    #endif

    let onSelectionComplete: () -> Void

    @State private var serverInfo: GFNServerInfo?
    @State private var isLoadingRegions = true
    @State private var regionError: String?
    @State private var serverZones: [GFNZone] = []
    @State private var isLoadingServers = true
    @State private var serverError: String?
    @FocusState private var focusedChoice: Choice?

    var body: some View {
        ServerPickerScreen(
            title: L10n.text("server_location"),
            accessibilityIdentifier: "settings.server-location.page"
        ) {
            Section {
                Button {
                    selectServerAutomatic()
                } label: {
                    choiceLabel(
                        title: L10n.text("automatic"),
                        subtitle: serverAutoSubtitle,
                        selected: viewModel.streamSettings.serverRoutingMode == .serverAuto
                    )
                }
                .focused($focusedChoice, equals: .automatic)
                .accessibilityLabel(L10n.text("automatic"))
                .accessibilityValue(serverAutoSubtitle)

                NavigationLink {
                    RegionPickerView(
                        serverInfo: serverInfo,
                        isLoading: isLoadingRegions,
                        error: regionError
                    ) { region in
                        selectRegion(region)
                    }
                    .task {
                        await loadRegions()
                    }
                } label: {
                    choiceLabel(
                        title: L10n.text("region"),
                        subtitle: regionChoiceSubtitle,
                        selected: viewModel.streamSettings.serverRoutingMode == .region
                    )
                }
                .focused($focusedChoice, equals: .region)
                .accessibilityIdentifier("settings.server-location.region")
                .accessibilityLabel(L10n.text("region"))
                .accessibilityValue(regionChoiceSubtitle)

                NavigationLink {
                    ServerCountryPickerView(
                        zones: serverZones,
                        isLoading: isLoadingServers,
                        error: serverError,
                        onSelect: selectDedicatedZone
                    )
                    .task {
                        await loadServers()
                    }
                } label: {
                    choiceLabel(
                        title: L10n.text("servers"),
                        subtitle: serversChoiceSubtitle,
                        selected: viewModel.streamSettings.serverRoutingMode == .client
                    )
                }
                .focused($focusedChoice, equals: .servers)
                .accessibilityIdentifier("settings.server-location.servers")
                .accessibilityLabel(L10n.text("servers"))
                .accessibilityValue(serversChoiceSubtitle)
            }
        }
        .defaultFocus($focusedChoice, selectedChoice)
        .task {
            await Task.yield()
            focusedChoice = selectedChoice
            await loadRegions()
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

    private func choiceLabel(
        title: String,
        subtitle: String,
        selected: Bool
    ) -> some View {
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
        }
    }

    private func selectServerAutomatic() {
        viewModel.streamSettings.serverRoutingMode = .serverAuto
        viewModel.streamSettings.preferredZoneUrl = nil
        viewModel.streamSettings.preferredRegionName = nil
        viewModel.streamSettings.preferredRegionAddress = nil
        onSelectionComplete()
    }

    private func selectDedicatedZone(_ zone: GFNZone) {
        viewModel.streamSettings.serverRoutingMode = .client
        viewModel.streamSettings.preferredZoneUrl = zone.zoneUrl
        viewModel.streamSettings.preferredRegionName = nil
        viewModel.streamSettings.preferredRegionAddress = nil
        onSelectionComplete()
    }

    private func selectRegion(_ region: GFNRegion) {
        viewModel.streamSettings.serverRoutingMode = .region
        viewModel.streamSettings.preferredZoneUrl = nil
        viewModel.streamSettings.preferredRegionName = region.name
        viewModel.streamSettings.preferredRegionAddress = region.address
        onSelectionComplete()
    }

    private func loadRegions() async {
        #if DEBUG
            if let fixture {
                serverInfo = fixture.serverInfo
                regionError = nil
                isLoadingRegions = false
                return
            }
        #endif

        let base = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
        if let cached = ServerInfoClient.shared.cachedForBase(base) {
            serverInfo = cached
            isLoadingRegions = false
        }

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
        #if DEBUG
            if let fixture {
                serverZones = fixture.zones
                serverError = nil
                isLoadingServers = false
                return
            }
        #endif

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
    let accessibilityIdentifier: String
    private let content: Content

    init(
        title: String,
        accessibilityIdentifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content()
    }

    var body: some View {
        Form {
            CloudNowSettingsPageTitle(
                title: title,
                accessibilityIdentifier: "\(accessibilityIdentifier).title"
            )
            content
        }
        .navigationTitle("")
        .accessibilityIdentifier(accessibilityIdentifier)
        .blocksGlobalControllerNavigation()
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
    let onSelect: (GFNZone) -> Void

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
        ServerPickerScreen(
            title: L10n.text("servers"),
            accessibilityIdentifier: "settings.server-location.servers.page"
        ) {
            if isLoading {
                ProgressView {
                    Text(L10n.text("loading_servers"))
                }
                .frame(maxWidth: .infinity, minHeight: 320)
                .listRowBackground(Color.clear)
            } else if let error {
                ContentUnavailableView(
                    L10n.text("cant_load_servers"),
                    systemImage: "wifi.exclamationmark",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, minHeight: 320)
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(countries) { country in
                        NavigationLink {
                            ServerCityPickerView(
                                countryCode: country.code,
                                zones: zones.filter {
                                    $0.countryCode == country.code
                                },
                                onSelect: onSelect
                            )
                        } label: {
                            HStack {
                                Text(country.name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if selectedCountryCode == country.code {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .focused($focusedCountryCode, equals: country.code)
                        .accessibilityIdentifier(
                            "settings.server-location.country.\(country.code)"
                        )
                        .accessibilityAddTraits(
                            selectedCountryCode == country.code ? .isSelected : []
                        )
                    }
                }
            }
        }
        .task(id: isLoading) {
            guard !isLoading else { return }
            await Task.yield()
            focusedCountryCode = selectedCountryCode ?? countries.first?.code
        }
        .defaultFocus($focusedCountryCode, selectedCountryCode ?? countries.first?.code)
    }
}

private struct ServerCityPickerView: View {
    let countryCode: String
    let zones: [GFNZone]
    let onSelect: (GFNZone) -> Void

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
        ServerPickerScreen(
            title: localizedServerCountryName(countryCode),
            accessibilityIdentifier: "settings.server-location.country.page"
        ) {
            Section {
                ForEach(cities, id: \.self) { city in
                    NavigationLink {
                        DedicatedServerPickerView(
                            city: city,
                            zones: zones.filter { $0.city == city },
                            onSelect: onSelect
                        )
                    } label: {
                        HStack {
                            Text(city)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if selectedCity == city {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .focused($focusedCity, equals: city)
                    .accessibilityIdentifier(
                        "settings.server-location.city.\(countryCode).\(city)"
                    )
                    .accessibilityAddTraits(
                        selectedCity == city ? .isSelected : []
                    )
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
        ServerPickerScreen(
            title: city,
            accessibilityIdentifier: "settings.server-location.city.page"
        ) {
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
                    .focused($focusedZoneURL, equals: zone.zoneUrl)
                    .accessibilityIdentifier(
                        "settings.server-location.zone.\(zone.id)"
                    )
                    .accessibilityAddTraits(
                        selectedZoneURL == zone.zoneUrl ? .isSelected : []
                    )
                }
            }
        }
        .task {
            focusedZoneURL = defaultFocusZoneURL
            await measurePings()
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
        ServerPickerScreen(
            title: L10n.text("region"),
            accessibilityIdentifier: "settings.server-location.region.page"
        ) {
            if let regions = serverInfo?.regions, !regions.isEmpty {
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
                        .focused($focusedRegionID, equals: region.id)
                        .accessibilityIdentifier(
                            "settings.server-location.region.\(region.id)"
                        )
                        .accessibilityAddTraits(
                            selectedRegionID == region.id ? .isSelected : []
                        )
                    }
                } footer: {
                    Text(L10n.text("server_selection_warning"))
                }
            } else if isLoading {
                ProgressView {
                    Text(L10n.text("loading_servers"))
                }
                .frame(maxWidth: .infinity, minHeight: 320)
                .listRowBackground(Color.clear)
            } else {
                ContentUnavailableView(
                    L10n.text("cant_load_servers"),
                    systemImage: "wifi.exclamationmark",
                    description: Text(error ?? "")
                )
                .frame(maxWidth: .infinity, minHeight: 320)
                .listRowBackground(Color.clear)
            }
        }
        .task(id: isLoading) {
            guard !isLoading else { return }
            await Task.yield()
            focusedRegionID = selectedRegionID ?? serverInfo?.regions.first?.id
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
        // Routing-mode pins only apply to NVIDIA-direct sessions; partner providers
        // manage their own routing and do not expose zone/region selection.
        let isNvidiaSession = authManager.session?.provider.isNvidiaDirect ?? true
        if isNvidiaSession {
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
        }

        let base = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
        let cached = ServerInfoClient.shared.cachedForBase(base)
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
