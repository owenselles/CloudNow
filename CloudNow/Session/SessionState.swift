import Foundation

// MARK: - Stream Settings

struct StreamSettings: Codable, Equatable {
    static let maxSelectableBitrateKbps = 100_000
    static let minControllerDeadzone = 0.0
    static let maxControllerDeadzone = 0.30
    static let defaultKeyboardLayout = L10n.keyboardLayoutCode()
    static let automaticGameLanguage = "automatic"
    static let defaultGameLanguage = automaticGameLanguage

    var resolution: String = "1920x1080"
    var fps: Int = 60
    var maxBitrateKbps: Int = 20000 {
        didSet { maxBitrateKbps = min(maxBitrateKbps, Self.maxSelectableBitrateKbps) }
    }

    var codec: VideoCodec = .h264
    var colorPreference: ColorModePreference = .automatic
    var keyboardLayout: String = Self.defaultKeyboardLayout
    var gameLanguage: String = Self.defaultGameLanguage
    var enableL4S: Bool = false
    var micEnabled: Bool = false
    /// Radial deadzone applied to analog stick axes (0.0–1.0). Default 15%.
    var controllerDeadzone: Double = 0.15 {
        didSet { controllerDeadzone = min(max(controllerDeadzone, Self.minControllerDeadzone), Self.maxControllerDeadzone) }
    }

    /// Which controller button triggers the GFN overlay on long-press. Default: Start (≡).
    var overlayTriggerButton: OverlayTriggerButton = .start
    /// Default remote/controller input mode when a stream session starts.
    var defaultRemoteInputMode: RemoteInputMode = .mouse
    /// Preferred zone URL, e.g. "https://np-aws-us-n-virginia-1.cloudmatchbeta.nvidiagrid.net/"
    /// nil = choose an automatic zone when available, otherwise let the GFN default VPC route.
    var preferredZoneUrl: String? = nil
    /// Long-press the button that is NOT the overlay trigger to send Shift+Tab (opens the
    /// Steam in-game overlay). e.g. with overlay on Start, long-press View/Back triggers Steam.
    var enableSteamOverlayGesture: Bool = true
    /// Controls receiver statistics collection. Diagnostic mode also enables video-pipeline tracing.
    var statsMode: StreamStatsMode = .hud
    /// Captures a bounded WebRTC event log for the duration of the next stream.
    var enableRtcEventLog: Bool = false

    var normalizedForClient: StreamSettings {
        var normalized = self
        if normalized.statsMode != .diagnostic {
            normalized.enableRtcEventLog = false
        }
        return normalized
    }

    var effectiveGameLanguage: String {
        gameLanguage == Self.automaticGameLanguage ? L10n.nvidiaLocaleCode() : gameLanguage
    }
}

// MARK: - StreamSettings: resilient decoding

///
/// Synthesized Decodable throws keyNotFound when a newly-added field is missing from
/// previously-persisted JSON, which would silently reset ALL settings to defaults on upgrade.
/// decodeIfPresent + default fallbacks keep existing settings intact across versions.
extension StreamSettings {
    enum CodingKeys: String, CodingKey {
        case resolution, fps, maxBitrateKbps, codec, colorPreference, keyboardLayout
        case gameLanguage, enableL4S, micEnabled, controllerDeadzone, overlayTriggerButton
        case defaultRemoteInputMode, preferredZoneUrl
        case enableSteamOverlayGesture
        case statsMode, enableRtcEventLog
        case colorQuality
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StreamSettings()
        self.init()
        resolution = try c.decodeIfPresent(String.self, forKey: .resolution) ?? d.resolution
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        maxBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .maxBitrateKbps) ?? d.maxBitrateKbps
        codec = try c.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? d.codec
        colorPreference = try c.decodeIfPresent(ColorModePreference.self, forKey: .colorPreference)
            ?? (c.decodeIfPresent(ColorQuality.self, forKey: .colorQuality))?.preference
            ?? d.colorPreference
        keyboardLayout = try c.decodeIfPresent(String.self, forKey: .keyboardLayout) ?? d.keyboardLayout
        gameLanguage = try c.decodeIfPresent(String.self, forKey: .gameLanguage) ?? d.gameLanguage
        enableL4S = try c.decodeIfPresent(Bool.self, forKey: .enableL4S) ?? d.enableL4S
        micEnabled = try c.decodeIfPresent(Bool.self, forKey: .micEnabled) ?? d.micEnabled
        controllerDeadzone = try c.decodeIfPresent(Double.self, forKey: .controllerDeadzone) ?? d.controllerDeadzone
        overlayTriggerButton = try c.decodeIfPresent(OverlayTriggerButton.self, forKey: .overlayTriggerButton) ?? d.overlayTriggerButton
        defaultRemoteInputMode = try c.decodeIfPresent(RemoteInputMode.self, forKey: .defaultRemoteInputMode) ?? d.defaultRemoteInputMode
        preferredZoneUrl = try c.decodeIfPresent(String.self, forKey: .preferredZoneUrl)
        enableSteamOverlayGesture = try c.decodeIfPresent(Bool.self, forKey: .enableSteamOverlayGesture) ?? d.enableSteamOverlayGesture
        statsMode = try c.decodeIfPresent(StreamStatsMode.self, forKey: .statsMode) ?? d.statsMode
        enableRtcEventLog = try c.decodeIfPresent(Bool.self, forKey: .enableRtcEventLog) ?? d.enableRtcEventLog
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(resolution, forKey: .resolution)
        try c.encode(fps, forKey: .fps)
        try c.encode(maxBitrateKbps, forKey: .maxBitrateKbps)
        try c.encode(codec, forKey: .codec)
        try c.encode(colorPreference, forKey: .colorPreference)
        try c.encode(keyboardLayout, forKey: .keyboardLayout)
        try c.encode(gameLanguage, forKey: .gameLanguage)
        try c.encode(enableL4S, forKey: .enableL4S)
        try c.encode(micEnabled, forKey: .micEnabled)
        try c.encode(controllerDeadzone, forKey: .controllerDeadzone)
        try c.encode(overlayTriggerButton, forKey: .overlayTriggerButton)
        try c.encode(defaultRemoteInputMode, forKey: .defaultRemoteInputMode)
        try c.encodeIfPresent(preferredZoneUrl, forKey: .preferredZoneUrl)
        try c.encode(enableSteamOverlayGesture, forKey: .enableSteamOverlayGesture)
        try c.encode(statsMode, forKey: .statsMode)
        try c.encode(enableRtcEventLog, forKey: .enableRtcEventLog)
    }
}

enum StreamStatsMode: String, Codable, CaseIterable {
    case off
    case hud
    case diagnostic

    var label: String {
        switch self {
        case .off: L10n.text("off")
        case .hud: L10n.text("hud")
        case .diagnostic: L10n.text("diagnostic")
        }
    }
}

enum OverlayTriggerButton: String, Codable, CaseIterable {
    case start = "Start (≡)"
    case options = "Options/Back (⊟)"

    var label: String {
        L10n.overlayTriggerButtonLabel(self)
    }
}

enum VideoCodec: String, Codable, CaseIterable {
    case h264 = "H264"
    case h265 = "H265"
    case av1 = "AV1"

    var label: String {
        L10n.videoCodecLabel(self)
    }
}

enum ColorModePreference: String, Codable, CaseIterable {
    case automatic
    case preferHDR
    case preferSDR10
    case forceSDR8

    var label: String {
        L10n.colorModeLabel(self)
    }

    var description: String {
        L10n.colorModeDescription(self)
    }
}

enum StreamColorMode: String, Codable, Equatable {
    case sdr8
    case sdr10
    case hdr10

    var bitDepth: Int {
        self == .sdr8 ? 8 : 10
    }

    var diagnosticLabel: String {
        L10n.streamColorModeLabel(self)
    }
}

enum DetectedColorMode: String, Codable, Equatable {
    case sdr8
    case sdr10
    case hdr10
    case unknown8Bit
    case unknown10Bit

    var diagnosticLabel: String {
        L10n.detectedColorModeLabel(self)
    }

    var isUnknown: Bool {
        switch self {
        case .unknown8Bit, .unknown10Bit:
            true
        default:
            false
        }
    }
}

enum HDRSupport: String, Codable {
    case supported
    case unsupported
    case unknown
}

enum ColorFallbackReason: String, Codable {
    case gameHDRUnknown
    case gameHDRUnsupported
    case accountHDRUnavailable
    case serverHDRUnavailable
    case displayHDRUnavailable
    case decoder10BitUnavailable
    case hdrRenderPipelineUnavailable
    case serverReturnedSDR
    case decoderReturned8Bit
    case softwareDecoder
    case missingColorMetadata
    case unsupportedPixelFormat
    case unstablePlayback
    case sessionNegotiationFailed
}

struct StreamColorState: Codable, Equatable {
    let preference: ColorModePreference
    var requestedMode: StreamColorMode
    var negotiatedMode: StreamColorMode?
    var detectedMode: DetectedColorMode?
    var displayHDRSupport: HDRSupport
    var fallbackReason: ColorFallbackReason?
}

struct StreamColorCapabilities {
    let gameHDRSupport: HDRSupport
    let accountAllowsHDR: Bool?
    let serverAllowsHDR: Bool?
    let decoderSupports10Bit: Bool
    let hdrRenderPipelineAvailable: Bool
    let displaySupportsHDR: Bool
}

struct HDRDisplayCapabilities: Codable, Equatable {
    let desiredContentMaxLuminance: Int
    let desiredContentMinLuminance: Int
    let desiredContentMaxFrameAverageLuminance: Int
    let hdrEdrSupportedFlags: Int

    static let conservativeHDR10 = HDRDisplayCapabilities(
        desiredContentMaxLuminance: 1000,
        desiredContentMinLuminance: 0,
        desiredContentMaxFrameAverageLuminance: 500,
        hdrEdrSupportedFlags: 1
    )
}

struct StreamColorRequest: Codable, Equatable {
    let mode: StreamColorMode
    let bitDepth: Int
    let hdrRequested: Bool
    let chromaFormat: Int?
    let displayCapabilities: HDRDisplayCapabilities?

    static func resolve(
        preference: ColorModePreference,
        capabilities: StreamColorCapabilities
    ) -> StreamColorRequest {
        let mode = resolveColorMode(preference: preference, capabilities: capabilities)
        return StreamColorRequest(
            mode: mode,
            bitDepth: mode.bitDepth,
            hdrRequested: mode == .hdr10,
            chromaFormat: 1,
            displayCapabilities: mode == .hdr10 ? .conservativeHDR10 : nil
        )
    }

    static func resolveColorMode(
        preference: ColorModePreference,
        capabilities: StreamColorCapabilities
    ) -> StreamColorMode {
        switch preference {
        case .forceSDR8:
            return .sdr8
        case .preferSDR10:
            return capabilities.decoderSupports10Bit ? .sdr10 : .sdr8
        case .preferHDR:
            if capabilities.decoderSupports10Bit,
               capabilities.hdrRenderPipelineAvailable,
               capabilities.displaySupportsHDR,
               capabilities.accountAllowsHDR != false,
               capabilities.serverAllowsHDR != false
            {
                return .hdr10
            }
            return capabilities.decoderSupports10Bit ? .sdr10 : .sdr8
        case .automatic:
            if capabilities.gameHDRSupport == .supported,
               capabilities.decoderSupports10Bit,
               capabilities.hdrRenderPipelineAvailable,
               capabilities.displaySupportsHDR,
               capabilities.accountAllowsHDR == true,
               capabilities.serverAllowsHDR == true
            {
                return .hdr10
            }
            return capabilities.decoderSupports10Bit ? .sdr10 : .sdr8
        }
    }
}

extension StreamSettings {
    func colorRequest(
        localCapabilities: LocalVideoCapabilities = .detect(codec: nil),
        gameHDRSupport: HDRSupport = .unknown,
        accountAllowsHDR: Bool? = nil,
        serverAllowsHDR: Bool? = nil
    ) -> StreamColorRequest {
        let capabilities = StreamColorCapabilities(
            gameHDRSupport: gameHDRSupport,
            accountAllowsHDR: accountAllowsHDR,
            serverAllowsHDR: serverAllowsHDR,
            // 10-bit (sdr10/hdr10) requires H.265 — H.264 is 8-bit only and AV1 is excluded
            // from the 10-bit decode path, so either forces an 8-bit SDR downgrade.
            decoderSupports10Bit: localCapabilities.supportsHardware10BitDecode && codec == .h265,
            hdrRenderPipelineAvailable: localCapabilities.supportsHDRRendering,
            displaySupportsHDR: localCapabilities.displaySupportsHDR
        )
        return StreamColorRequest.resolve(preference: colorPreference, capabilities: capabilities)
    }
}

enum ColorQuality: String, Codable, CaseIterable {
    case sdr8bit = "SDR8bit"
    case sdr10bit = "SDR10bit"
    case hdr10bit = "HDR10bit"

    var preference: ColorModePreference {
        switch self {
        case .sdr8bit: .forceSDR8
        case .sdr10bit: .preferSDR10
        case .hdr10bit: .preferHDR
        }
    }
}

// MARK: - ICE Server

struct IceServer: Codable {
    let urls: [String]
    let username: String?
    let credential: String?
}

// MARK: - Queue Ads

struct SessionAdMediaFile: Codable, Equatable {
    let mediaFileUrl: String?
    let encodingProfile: String?
}

struct SessionAdInfo: Codable, Equatable, Identifiable {
    let adId: String
    let adUrl: String?
    let mediaUrl: String?
    let adMediaFiles: [SessionAdMediaFile]
    let adLengthInSeconds: Double?
    var id: String {
        adId
    }

    /// Returns the best available media URL.
    var preferredMediaURL: URL? {
        if let url = adMediaFiles.compactMap({ $0.mediaFileUrl.flatMap(URL.init) }).first { return url }
        if let url = adUrl.flatMap(URL.init) { return url }
        return mediaUrl.flatMap(URL.init)
    }
}

struct SessionAdState: Codable, Equatable {
    let isAdsRequired: Bool
    let isQueuePaused: Bool?
    let gracePeriodSeconds: Int?
    let message: String?
    let ads: [SessionAdInfo]
}

// MARK: - Session Info (returned by CloudMatch)

struct SessionInfo {
    let sessionId: String
    let status: Int
    let zone: String
    let streamingBaseUrl: String
    let serverIp: String
    let signalingServer: String
    let signalingUrl: String
    let gpuType: String?
    let queuePosition: Int?
    let seatSetupStep: Int?
    let iceServers: [IceServer]
    let mediaConnectionInfo: MediaConnectionInfo?
    let clientId: String
    let deviceId: String
    let adState: SessionAdState?

    /// True while the session is sitting in the GFN queue (no timeout applies).
    var isInQueue: Bool {
        if seatSetupStep == 1 { return true }
        return (queuePosition ?? 0) > 1
    }
}

struct MediaConnectionInfo {
    let ip: String
    let port: Int
}

// MARK: - Active Session Info

struct ActiveSessionInfo {
    let sessionId: String
    let status: Int
    let appId: String?
    let serverIp: String?
    let signalingUrl: String?
}

// MARK: - Subscription / Entitlements

struct EntitledResolution: Equatable {
    let widthInPixels: Int
    let heightInPixels: Int
    let framesPerSecond: Int

    var resolutionLabel: String {
        "\(widthInPixels)x\(heightInPixels)"
    }
}

struct SubscriptionInfo {
    let membershipTier: String
    let isUnlimited: Bool
    let remainingMinutes: Int?
    let totalMinutes: Int?
    let entitledResolutions: [EntitledResolution]
}

// MARK: - Games

struct GameInfo: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let boxArtUrl: String?
    let heroBannerUrl: String?
    var isInLibrary: Bool
    var variants: [GameVariant]

    /// Whether this game belongs under a store filter. Owned games match only the store they're
    /// owned through; unowned catalog games match any store they're available on.
    func matchesStore(_ store: String) -> Bool {
        if isInLibrary {
            return variants.contains { $0.appStore == store && $0.isOwned }
        }
        return variants.contains { $0.appStore == store }
    }

    /// Stores this game is owned through (drives the Library filter chips).
    var ownedStores: [String] {
        variants.filter(\.isOwned).map(\.appStore)
    }
}

struct GameVariant: Equatable, Codable {
    let id: String
    let appStore: String
    var appId: String?
    /// True when GFN reports MANUAL, PLATFORM_SYNC, or IN_LIBRARY for this variant.
    var isOwned: Bool = false

    var storeName: String {
        L10n.storeName(for: appStore)
    }
}

// MARK: - Session Create Request

struct SessionCreateRequest {
    let appId: String
    let internalTitle: String?
    let token: String
    let streamingBaseUrl: String?
    let routingZoneUrl: String?
    let settings: StreamSettings
    let accountLinked: Bool
}
