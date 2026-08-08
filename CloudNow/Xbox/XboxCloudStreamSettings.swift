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

/// Account-visible Xbox quality aliases. These are preferences rather than
/// promises: Microsoft can still adapt the negotiated stream for the title,
/// region, device, and live network condition. Higher-quality aliases are
/// shown only when CloudNow has confirmed the account's Ultimate membership.
nonisolated struct XboxCloudStreamCapabilities: Equatable, Sendable {
    let standardResolutions: [XboxCloudDisplayResolution]
    let higherQualityResolutions: [XboxCloudDisplayResolution]

    var resolutions: [XboxCloudDisplayResolution] {
        standardResolutions + higherQualityResolutions
    }

    static func resolved(
        for membershipTier: XboxMembershipTier?,
        isMembershipKnown: Bool
    ) -> Self {
        let hasHigherQuality = isMembershipKnown && membershipTier == .ultimate
        let higherQualityResolutions: [XboxCloudDisplayResolution] = if hasHigherQuality {
            [.hdHighQuality, .fullHDHighQuality, .qhd]
        } else {
            []
        }
        return Self(
            standardResolutions: [
                .automatic,
                .hd,
                .fullHD,
            ],
            higherQualityResolutions: higherQualityResolutions
        )
    }

    func selectableResolution(
        for persistedResolution: XboxCloudDisplayResolution
    ) -> XboxCloudDisplayResolution {
        resolutions.contains(persistedResolution)
            ? persistedResolution
            : .automatic
    }

    func normalized(_ settings: XboxCloudStreamSettings) -> XboxCloudStreamSettings {
        var normalized = settings
        normalized.displayResolution = selectableResolution(
            for: settings.displayResolution
        )
        // Xbox selects the negotiated WebRTC codec. Retain this legacy field
        // only so older persisted settings remain decodable.
        normalized.codecPreference = .automatic
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

    init(
        displayResolution: XboxCloudDisplayResolution = .automatic,
        codecPreference: XboxCloudVideoCodecPreference = .automatic,
        gameLanguage: String = Self.automaticGameLanguage,
        statsMode: StreamStatsMode = .off,
        controllerDeadzone: Double = 0.15,
        rumbleEnabled: Bool = true,
        rumbleIntensity: Double = 1,
        enableTextToSpeech: Bool = false,
        magnifier: Bool = false,
        highContrast: Bool = false,
        enableOptionalDataCollection: Bool = false
    ) {
        self.displayResolution = displayResolution
        self.codecPreference = codecPreference
        self.gameLanguage = gameLanguage
        self.statsMode = statsMode
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
    }

    func effectiveGameLanguage(defaultLocale: String) -> String {
        let locale = gameLanguage == Self.automaticGameLanguage
            ? defaultLocale
            : gameLanguage
        return locale.replacingOccurrences(of: "_", with: "-")
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
        case codecPreference
        case gameLanguage
        case statsMode
        case controllerDeadzone
        case rumbleEnabled
        case rumbleIntensity
        case enableTextToSpeech
        case magnifier
        case highContrast
        case enableOptionalDataCollection
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
            ) ?? defaults.enableOptionalDataCollection
        )
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(displayResolution, forKey: .displayResolution)
        try values.encode(codecPreference, forKey: .codecPreference)
        try values.encode(gameLanguage, forKey: .gameLanguage)
        try values.encode(statsMode, forKey: .statsMode)
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
    }
}
