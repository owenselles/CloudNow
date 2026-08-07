import Foundation

nonisolated enum XboxCloudDisplayResolution: String, Codable, CaseIterable, Sendable {
    case automatic
    case hd = "1280x720"
    case fullHD = "1920x1080"
    case qhd = "2560x1440"

    var width: Int? {
        switch self {
        case .automatic:
            nil
        case .hd:
            1280
        case .fullHD:
            1920
        case .qhd:
            2560
        }
    }

    var height: Int? {
        switch self {
        case .automatic:
            nil
        case .hd:
            720
        case .fullHD:
            1080
        case .qhd:
            1440
        }
    }

    @MainActor var label: String {
        switch self {
        case .automatic:
            L10n.text("automatic")
        case .hd, .fullHD, .qhd:
            rawValue
        }
    }

    var badge: String? {
        switch self {
        case .automatic:
            nil
        case .hd:
            "HD"
        case .fullHD:
            "Full HD"
        case .qhd:
            "QHD"
        }
    }

    var systemImage: String? {
        switch self {
        case .automatic:
            nil
        case .hd, .fullHD, .qhd:
            "tv"
        }
    }
}

nonisolated enum XboxCloudVideoCodecPreference: String, Codable, CaseIterable, Sendable {
    case automatic
    case h264 = "H264"
    case h265 = "H265"

    @MainActor var label: String {
        switch self {
        case .automatic:
            L10n.text("automatic")
        case .h264:
            "H264"
        case .h265:
            "H265"
        }
    }
}

/// Account-visible Xbox capabilities. These are request ceilings rather than
/// promises: Microsoft can still lower the negotiated result for a title,
/// region, device, or live network condition.
nonisolated struct XboxCloudStreamCapabilities: Equatable, Sendable {
    let resolutions: [XboxCloudDisplayResolution]
    let codecs: [XboxCloudVideoCodecPreference]

    static func resolved(
        for membershipTier: XboxMembershipTier?,
        isMembershipKnown: Bool
    ) -> Self {
        var resolutions: [XboxCloudDisplayResolution] = [
            .automatic,
            .hd,
            .fullHD,
        ]
        if !isMembershipKnown || membershipTier == .ultimate {
            resolutions.append(.qhd)
        }
        return Self(
            resolutions: resolutions,
            codecs: XboxCloudVideoCodecPreference.allCases
        )
    }

    func normalized(_ settings: XboxCloudStreamSettings) -> XboxCloudStreamSettings {
        var normalized = settings
        if !resolutions.contains(normalized.displayResolution) {
            normalized.displayResolution = .automatic
        }
        if !codecs.contains(normalized.codecPreference) {
            normalized.codecPreference = .automatic
        }
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
