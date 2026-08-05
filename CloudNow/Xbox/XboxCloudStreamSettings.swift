import Foundation

/// Xbox-only stream preferences. Keeping these separate prevents Microsoft
/// accessibility and privacy controls from leaking into GeForce NOW settings.
nonisolated struct XboxCloudStreamSettings: Codable, Equatable, Sendable {
    static let minimumControllerDeadzone = 0.0
    static let maximumControllerDeadzone = 0.95
    static let minimumRumbleIntensity = 0.0
    static let maximumRumbleIntensity = 1.0

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
        controllerDeadzone: Double = 0.15,
        rumbleEnabled: Bool = true,
        rumbleIntensity: Double = 1,
        enableTextToSpeech: Bool = false,
        magnifier: Bool = false,
        highContrast: Bool = false,
        enableOptionalDataCollection: Bool = false
    ) {
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
