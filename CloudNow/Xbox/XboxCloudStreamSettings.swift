import Foundation

nonisolated enum XboxCloudDisplayResolution: String, CaseIterable, Sendable {
    case automatic = "Auto"
    case hd = "720"
    case hdHighQuality = "720HQ"
    case fullHD = "1080"
    case fullHDHighQuality = "1080HQ"
    case qhd = "1440"

    var width: Int? {
        switch self {
        case .automatic:
            nil
        case .hd, .hdHighQuality:
            1280
        case .fullHD, .fullHDHighQuality:
            1920
        case .qhd:
            2560
        }
    }

    var height: Int? {
        switch self {
        case .automatic:
            nil
        case .hd, .hdHighQuality:
            720
        case .fullHD, .fullHDHighQuality:
            1080
        case .qhd:
            1440
        }
    }

    @MainActor var label: String {
        switch self {
        case .automatic:
            L10n.text("automatic")
        case .hd, .hdHighQuality:
            "720p"
        case .fullHD, .fullHDHighQuality:
            "1080p"
        case .qhd:
            "1440p"
        }
    }

    var badge: String? {
        switch self {
        case .automatic, .hd, .fullHD:
            nil
        case .hdHighQuality, .fullHDHighQuality:
            "HQ"
        case .qhd:
            nil
        }
    }

    var systemImage: String? {
        switch self {
        case .automatic:
            nil
        case .hd, .hdHighQuality, .fullHD, .fullHDHighQuality, .qhd:
            "tv"
        }
    }
}

extension XboxCloudDisplayResolution: Codable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = switch value {
        case "Auto", "automatic":
            .automatic
        case "720", "1280x720":
            .hd
        case "720HQ":
            .hdHighQuality
        case "1080", "1920x1080":
            .fullHD
        case "1080HQ":
            .fullHDHighQuality
        case "1440", "2560x1440":
            .qhd
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown Xbox Cloud quality alias"
            )
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Legacy persistence shape retained so settings written by earlier builds
/// remain decodable. Xbox now manages codec negotiation automatically.
nonisolated enum XboxCloudVideoCodecPreference: String, Codable, Sendable {
    case automatic
    case h264 = "H264"
    case h265 = "H265"
}

nonisolated struct XboxCloudDiagnosticsConfiguration: Equatable, Sendable {
    let isEnabled: Bool
    let isRTCEventLogEnabled: Bool
}

/// Keeps developer-only diagnostics fail-closed across Debug/Release settings
/// persistence. The explicit availability parameter makes both build branches
/// deterministic in unit tests without relying on compiler configuration.
nonisolated enum XboxCloudDiagnosticsPolicy {
    static var currentBuildAllowsDiagnostics: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    static func resolve(
        diagnosticsEnabled: Bool,
        rtcEventLogEnabled: Bool,
        allowsDiagnostics: Bool
    ) -> XboxCloudDiagnosticsConfiguration {
        let isEnabled = allowsDiagnostics && diagnosticsEnabled
        return XboxCloudDiagnosticsConfiguration(
            isEnabled: isEnabled,
            isRTCEventLogEnabled: isEnabled && rtcEventLogEnabled
        )
    }
}

/// Account-aware Xbox request ceilings. Resolution aliases are preferences,
/// not requirements: the service can still adapt below the requested value for
/// the title, region, device, or live network condition.
nonisolated struct XboxCloudStreamCapabilities: Equatable, Sendable {
    let standardResolutions: [XboxCloudDisplayResolution]
    let higherQualityResolutions: [XboxCloudDisplayResolution]
    private let automaticRequestedResolution: XboxCloudDisplayResolution

    var resolutions: [XboxCloudDisplayResolution] {
        standardResolutions + higherQualityResolutions
    }

    static func resolved(
        for membershipTier: XboxMembershipTier?,
        isMembershipKnown: Bool
    ) -> Self {
        guard isMembershipKnown else {
            return Self(
                standardResolutions: [.automatic],
                higherQualityResolutions: [],
                // A maximum preference is safe while access metadata loads:
                // Xbox may adapt it down without failing session allocation.
                automaticRequestedResolution: .qhd
            )
        }

        let isUltimate = membershipTier == .ultimate
        return Self(
            standardResolutions: [.automatic, .fullHD, .hd],
            higherQualityResolutions: isUltimate
                ? [.qhd, .fullHDHighQuality, .hdHighQuality]
                : [],
            automaticRequestedResolution: isUltimate ? .qhd : .fullHD
        )
    }

    func selectableResolution(
        for persistedResolution: XboxCloudDisplayResolution
    ) -> XboxCloudDisplayResolution {
        guard !resolutions.contains(persistedResolution) else {
            return persistedResolution
        }
        return .automatic
    }

    /// Converts the persisted picker selection into the service preference
    /// sent before authorization. "Automatic" requests the account ceiling;
    /// selections that became unavailable downgrade to that safe ceiling.
    func requestedResolution(
        for persistedResolution: XboxCloudDisplayResolution
    ) -> XboxCloudDisplayResolution {
        guard persistedResolution != .automatic,
              resolutions.contains(persistedResolution)
        else {
            return automaticRequestedResolution
        }
        return persistedResolution
    }

    func normalized(_ settings: XboxCloudStreamSettings) -> XboxCloudStreamSettings {
        var normalized = settings.normalizedForClient
        normalized.displayResolution = requestedResolution(
            for: settings.displayResolution
        )
        // Xbox selects the negotiated WebRTC codec. Retain this legacy field
        // only so older persisted settings remain decodable.
        normalized.codecPreference = .automatic
        // Optional provider telemetry is not part of CloudNow diagnostics.
        // Retain the legacy field only for backward-compatible decoding.
        normalized.enableOptionalDataCollection = false
        return normalized
    }
}

/// Xbox-only stream preferences. Keeping these separate prevents Microsoft
/// accessibility and privacy controls from leaking into GeForce NOW settings.
nonisolated struct XboxCloudStreamSettings: Codable, Equatable, Sendable {
    static let minimumControllerDeadzone = 0.0
    static let maximumControllerDeadzone = 0.95
    static let minimumRumbleIntensity = 0.0
    static let maximumRumbleIntensity = 1.0
    static let automaticGameLanguage = "automatic"

    var displayResolution: XboxCloudDisplayResolution = .automatic
    var codecPreference: XboxCloudVideoCodecPreference = .automatic
    var gameLanguage = Self.automaticGameLanguage
    var statsMode: StreamStatsMode = .off
    var diagnosticsEnabled = false
    var enableRtcEventLog = false

    var controllerDeadzone: Double = 0.15 {
        didSet {
            controllerDeadzone = Self.bounded(
                controllerDeadzone,
                default: 0.15,
                range: Self.minimumControllerDeadzone ... Self.maximumControllerDeadzone
            )
        }
    }

    var rumbleEnabled = true
    var rumbleIntensity: Double = 1.0 {
        didSet {
            rumbleIntensity = Self.bounded(
                rumbleIntensity,
                default: 1,
                range: Self.minimumRumbleIntensity ... Self.maximumRumbleIntensity
            )
        }
    }

    var enableTextToSpeech = false
    var magnifier = false
    var highContrast = false
    var enableOptionalDataCollection = false
    var microphoneEnabled = false

    init(
        displayResolution: XboxCloudDisplayResolution = .automatic,
        codecPreference: XboxCloudVideoCodecPreference = .automatic,
        gameLanguage: String = Self.automaticGameLanguage,
        statsMode: StreamStatsMode = .off,
        diagnosticsEnabled: Bool = false,
        enableRtcEventLog: Bool = false,
        controllerDeadzone: Double = 0.15,
        rumbleEnabled: Bool = true,
        rumbleIntensity: Double = 1,
        enableTextToSpeech: Bool = false,
        magnifier: Bool = false,
        highContrast: Bool = false,
        enableOptionalDataCollection: Bool = false,
        microphoneEnabled: Bool = false
    ) {
        self.displayResolution = displayResolution
        self.codecPreference = codecPreference
        self.gameLanguage = gameLanguage
        self.statsMode = statsMode
        self.diagnosticsEnabled = diagnosticsEnabled
        self.enableRtcEventLog = enableRtcEventLog
        self.controllerDeadzone = Self.bounded(
            controllerDeadzone,
            default: 0.15,
            range: Self.minimumControllerDeadzone ... Self.maximumControllerDeadzone
        )
        self.rumbleEnabled = rumbleEnabled
        self.rumbleIntensity = Self.bounded(
            rumbleIntensity,
            default: 1,
            range: Self.minimumRumbleIntensity ... Self.maximumRumbleIntensity
        )
        self.enableTextToSpeech = enableTextToSpeech
        self.magnifier = magnifier
        self.highContrast = highContrast
        self.enableOptionalDataCollection = enableOptionalDataCollection
        self.microphoneEnabled = microphoneEnabled
    }

    func effectiveGameLanguage(defaultLocale: String) -> String {
        let locale = gameLanguage == Self.automaticGameLanguage
            ? defaultLocale
            : gameLanguage
        return locale.replacingOccurrences(of: "_", with: "-")
    }

    var normalizedForClient: Self {
        var normalized = self
        let diagnostics = XboxCloudDiagnosticsPolicy.resolve(
            diagnosticsEnabled: diagnosticsEnabled,
            rtcEventLogEnabled: enableRtcEventLog,
            allowsDiagnostics: XboxCloudDiagnosticsPolicy
                .currentBuildAllowsDiagnostics
        )
        normalized.diagnosticsEnabled = diagnostics.isEnabled
        normalized.enableRtcEventLog = diagnostics.isRTCEventLogEnabled
        normalized.enableOptionalDataCollection = false
        return normalized
    }

    private static func bounded(
        _ value: Double,
        default defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Resilient decoding preserves existing preferences when new Xbox-specific
/// options are added in later CloudNow versions.
extension XboxCloudStreamSettings {
    private enum CodingKeys: String, CodingKey {
        case displayResolution
        // Legacy experiment keys remain known so persisted Beta settings can
        // be decoded and replaced without affecting the production profile.
        case bandwidthPreference
        case qualityProfile
        case codecPreference
        case gameLanguage
        case statsMode
        case diagnosticsEnabled
        case enableRtcEventLog
        case controllerDeadzone
        case rumbleEnabled
        case rumbleIntensity
        case enableTextToSpeech
        case magnifier
        case highContrast
        case enableOptionalDataCollection
        case microphoneEnabled
    }

    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = XboxCloudStreamSettings()
        try self.init(
            displayResolution: (try? values.decodeIfPresent(
                XboxCloudDisplayResolution.self,
                forKey: .displayResolution
            )) ?? defaults.displayResolution,
            codecPreference: (try? values.decodeIfPresent(
                XboxCloudVideoCodecPreference.self,
                forKey: .codecPreference
            )) ?? defaults.codecPreference,
            gameLanguage: (try? values.decodeIfPresent(
                String.self,
                forKey: .gameLanguage
            )) ?? defaults.gameLanguage,
            statsMode: (try? values.decodeIfPresent(
                StreamStatsMode.self,
                forKey: .statsMode
            )) ?? defaults.statsMode,
            diagnosticsEnabled: (try? values.decodeIfPresent(
                Bool.self,
                forKey: .diagnosticsEnabled
            )) ?? defaults.diagnosticsEnabled,
            enableRtcEventLog: (try? values.decodeIfPresent(
                Bool.self,
                forKey: .enableRtcEventLog
            )) ?? defaults.enableRtcEventLog,
            controllerDeadzone: values.decodeIfPresent(
                Double.self,
                forKey: .controllerDeadzone
            ) ?? defaults.controllerDeadzone,
            rumbleEnabled: values.decodeIfPresent(
                Bool.self,
                forKey: .rumbleEnabled
            ) ?? defaults.rumbleEnabled,
            rumbleIntensity: values.decodeIfPresent(
                Double.self,
                forKey: .rumbleIntensity
            ) ?? defaults.rumbleIntensity,
            enableTextToSpeech: values.decodeIfPresent(
                Bool.self,
                forKey: .enableTextToSpeech
            ) ?? defaults.enableTextToSpeech,
            magnifier: values.decodeIfPresent(
                Bool.self,
                forKey: .magnifier
            ) ?? defaults.magnifier,
            highContrast: values.decodeIfPresent(
                Bool.self,
                forKey: .highContrast
            ) ?? defaults.highContrast,
            enableOptionalDataCollection: values.decodeIfPresent(
                Bool.self,
                forKey: .enableOptionalDataCollection
            ) ?? defaults.enableOptionalDataCollection,
            microphoneEnabled: (try? values.decodeIfPresent(
                Bool.self,
                forKey: .microphoneEnabled
            )) ?? defaults.microphoneEnabled
        )
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(displayResolution, forKey: .displayResolution)
        try values.encode(codecPreference, forKey: .codecPreference)
        try values.encode(gameLanguage, forKey: .gameLanguage)
        try values.encode(statsMode, forKey: .statsMode)
        try values.encode(diagnosticsEnabled, forKey: .diagnosticsEnabled)
        try values.encode(enableRtcEventLog, forKey: .enableRtcEventLog)
        try values.encode(controllerDeadzone, forKey: .controllerDeadzone)
        try values.encode(rumbleEnabled, forKey: .rumbleEnabled)
        try values.encode(rumbleIntensity, forKey: .rumbleIntensity)
        try values.encode(enableTextToSpeech, forKey: .enableTextToSpeech)
        try values.encode(magnifier, forKey: .magnifier)
        try values.encode(highContrast, forKey: .highContrast)
        try values.encode(
            enableOptionalDataCollection,
            forKey: .enableOptionalDataCollection
        )
        try values.encode(microphoneEnabled, forKey: .microphoneEnabled)
    }
}
