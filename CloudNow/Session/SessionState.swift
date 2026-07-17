import AVFAudio
import Foundation

// MARK: - Stream Settings

nonisolated struct StreamSettings: Codable, Equatable {
    static let maxSelectableBitrateKbps = 100_000
    static let minControllerDeadzone = 0.0
    static let maxControllerDeadzone = 0.30
    static let minRumbleIntensity = 0.0
    static let maxRumbleIntensity = 2.0
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
    var rumbleEnabled: Bool = true
    /// Rumble power multiplier (0.0–2.0, 1.0 = default). Higher values stress controller motors.
    var rumbleIntensity: Double = 1.0 {
        didSet { rumbleIntensity = min(max(rumbleIntensity, Self.minRumbleIntensity), Self.maxRumbleIntensity) }
    }

    /// Radial deadzone applied to analog stick axes (0.0–1.0). Default 15%.
    var controllerDeadzone: Double = 0.15 {
        didSet { controllerDeadzone = min(max(controllerDeadzone, Self.minControllerDeadzone), Self.maxControllerDeadzone) }
    }

    /// Which controller button triggers the GFN overlay on long-press. Default: Start (≡).
    var overlayTriggerButton: OverlayTriggerButton = .start
    /// Default remote/controller input mode when a stream session starts.
    var defaultRemoteInputMode: RemoteInputMode = .gamepad
    /// Preferred zone URL, e.g. "https://np-aws-us-n-virginia-1.cloudmatchbeta.nvidiagrid.net/"
    /// nil = choose an automatic zone when available, otherwise let the GFN default VPC route.
    var preferredZoneUrl: String? = nil
    /// Long-press the button that is NOT the overlay trigger to send Shift+Tab (opens the
    /// Steam in-game overlay). e.g. with overlay on Start, long-press View/Back triggers Steam.
    var enableSteamOverlayGesture: Bool = true
    /// Level of the in-game statistics HUD (cycled from the pause menu, like the
    /// official client's Statistics overlay).
    var statsMode: StreamStatsMode = .off
    /// Developer diagnostics: video-pipeline tracing, AudioSync logging, debug stats rows,
    /// and RTC event log eligibility. Independent of the statistics HUD level.
    var diagnosticsEnabled: Bool = false
    /// Captures a bounded WebRTC event log for the duration of the next stream.
    var enableRtcEventLog: Bool = false
    /// How the GFN server presents launched games. Big Picture requests the "GamepadFriendly"
    /// mode that NVIDIA's TV clients (e.g. Shield TV) use, opening launchers such as Steam
    /// in their TV interface — the natural default for a TV client.
    var appLaunchMode: AppLaunchMode = .bigPicture
    /// Persist in-game graphics settings across sessions on the cloud rig. A premium-tier
    /// (Performance/Ultimate) feature; the server ignores the flag for non-entitled accounts.
    var persistInGameSettings: Bool = true
    /// Requested audio channel layout. Automatic follows the connected audio system's
    /// capability (5.1 only when the route reports ≥6 output channels).
    var audioFormat: AudioFormatPreference = .automatic

    var normalizedForClient: StreamSettings {
        var normalized = self
        #if !DEBUG
            // Developer diagnostics are unavailable in Release builds. Ignore persisted
            // values that may have been saved by a Debug build.
            normalized.diagnosticsEnabled = false
        #endif
        if !normalized.diagnosticsEnabled {
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
        case gameLanguage, enableL4S, micEnabled, rumbleEnabled, rumbleIntensity, controllerDeadzone, overlayTriggerButton
        case defaultRemoteInputMode, preferredZoneUrl
        case enableSteamOverlayGesture
        case statsMode, diagnosticsEnabled, enableRtcEventLog
        case appLaunchMode
        case persistInGameSettings
        case audioFormat
        case colorQuality
    }

    nonisolated init(from decoder: Decoder) throws {
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
        rumbleEnabled = try c.decodeIfPresent(Bool.self, forKey: .rumbleEnabled) ?? d.rumbleEnabled
        rumbleIntensity = try c.decodeIfPresent(Double.self, forKey: .rumbleIntensity) ?? d.rumbleIntensity
        controllerDeadzone = try c.decodeIfPresent(Double.self, forKey: .controllerDeadzone) ?? d.controllerDeadzone
        overlayTriggerButton = try c.decodeIfPresent(OverlayTriggerButton.self, forKey: .overlayTriggerButton) ?? d.overlayTriggerButton
        defaultRemoteInputMode = try c.decodeIfPresent(RemoteInputMode.self, forKey: .defaultRemoteInputMode) ?? d.defaultRemoteInputMode
        preferredZoneUrl = try c.decodeIfPresent(String.self, forKey: .preferredZoneUrl)
        enableSteamOverlayGesture = try c.decodeIfPresent(Bool.self, forKey: .enableSteamOverlayGesture) ?? d.enableSteamOverlayGesture
        // statsMode is decoded as a raw string: older builds persisted "hud" (pause-menu-only
        // stats, now unconditional → .off) and "diagnostic" (now the separate diagnosticsEnabled
        // flag, with the HUD at .standard so those users keep full visibility).
        let rawStatsMode = (try? c.decodeIfPresent(String.self, forKey: .statsMode)) ?? nil
        switch rawStatsMode {
        case "hud": statsMode = .off
        case "diagnostic": statsMode = .standard
        case let raw?: statsMode = StreamStatsMode(rawValue: raw) ?? d.statsMode
        case nil: statsMode = d.statsMode
        }
        let storedDiagnostics = try c.decodeIfPresent(Bool.self, forKey: .diagnosticsEnabled)
        diagnosticsEnabled = rawStatsMode == "diagnostic" || (storedDiagnostics ?? d.diagnosticsEnabled)
        enableRtcEventLog = try c.decodeIfPresent(Bool.self, forKey: .enableRtcEventLog) ?? d.enableRtcEventLog
        appLaunchMode = try c.decodeIfPresent(AppLaunchMode.self, forKey: .appLaunchMode) ?? d.appLaunchMode
        persistInGameSettings = try c.decodeIfPresent(Bool.self, forKey: .persistInGameSettings) ?? d.persistInGameSettings
        audioFormat = try c.decodeIfPresent(AudioFormatPreference.self, forKey: .audioFormat) ?? d.audioFormat
    }

    nonisolated func encode(to encoder: Encoder) throws {
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
        try c.encode(rumbleEnabled, forKey: .rumbleEnabled)
        try c.encode(rumbleIntensity, forKey: .rumbleIntensity)
        try c.encode(controllerDeadzone, forKey: .controllerDeadzone)
        try c.encode(overlayTriggerButton, forKey: .overlayTriggerButton)
        try c.encode(defaultRemoteInputMode, forKey: .defaultRemoteInputMode)
        try c.encodeIfPresent(preferredZoneUrl, forKey: .preferredZoneUrl)
        try c.encode(enableSteamOverlayGesture, forKey: .enableSteamOverlayGesture)
        try c.encode(statsMode, forKey: .statsMode)
        try c.encode(diagnosticsEnabled, forKey: .diagnosticsEnabled)
        try c.encode(enableRtcEventLog, forKey: .enableRtcEventLog)
        try c.encode(appLaunchMode, forKey: .appLaunchMode)
        try c.encode(persistInGameSettings, forKey: .persistInGameSettings)
        try c.encode(audioFormat, forKey: .audioFormat)
    }
}

/// Level of the in-game statistics HUD, mirroring the official client's Statistics
/// overlay (Off → Compact → Standard).
nonisolated enum StreamStatsMode: String, Codable, CaseIterable {
    case off
    case compact
    case standard

    @MainActor var label: String {
        switch self {
        case .off: L10n.text("off")
        case .compact: L10n.text("compact")
        case .standard: L10n.text("standard")
        }
    }

    /// Pause-menu cycle order, matching the official client's stats hotkey.
    var nextHUDLevel: StreamStatsMode {
        switch self {
        case .off: .compact
        case .compact: .standard
        case .standard: .off
        }
    }
}

nonisolated enum OverlayTriggerButton: String, Codable, CaseIterable {
    case start = "Start (≡)"
    case options = "Options/Back (⊟)"

    @MainActor var label: String {
        L10n.overlayTriggerButtonLabel(self)
    }
}

nonisolated enum AppLaunchMode: String, Codable, CaseIterable {
    case `default`
    case bigPicture

    /// CloudMatch sessionRequestData wire values: 1 = Default, 2 = GamepadFriendly, 3 = TouchFriendly.
    var cloudMatchValue: Int {
        self == .bigPicture ? 2 : 1
    }

    @MainActor var label: String {
        L10n.appLaunchModeLabel(self)
    }
}

nonisolated enum AudioFormatPreference: String, Codable, CaseIterable {
    case automatic
    case stereo
    case surround51

    @MainActor var label: String {
        switch self {
        case .automatic: L10n.text("automatic")
        case .stereo: L10n.text("stereo")
        case .surround51: L10n.text("surround_5_1")
        }
    }

    /// Output channels to request from GFN (2 or 6). tvOS exposes no reliable sink-capability
    /// API (device-verified: the port's channel count reports the currently active format —
    /// always 2 before anything requests more — and maximumOutputNumberOfChannels reports the
    /// OS mixer's 32 on one setup but the sink chain's 8 on another). Automatic therefore
    /// requests 5.1 on any surround-capable route and lets tvOS downmix to the actual
    /// speakers — the benign failure mode: real 5.1 rooms get discrete surround, stereo
    /// rooms get the same graceful 6→2 downmix every video app uses for 5.1 content.
    var resolvedChannelCount: Int {
        switch self {
        case .stereo:
            2
        case .surround51:
            6
        case .automatic:
            AVAudioSession.sharedInstance().maximumOutputNumberOfChannels >= 6 ? 6 : 2
        }
    }
}

nonisolated enum VideoCodec: String, Codable, CaseIterable {
    case h264 = "H264"
    case h265 = "H265"
    case av1 = "AV1"

    @MainActor var label: String {
        L10n.videoCodecLabel(self)
    }
}

nonisolated enum ColorModePreference: String, Codable, CaseIterable {
    case automatic
    case preferHDR
    case preferSDR10
    case forceSDR8

    @MainActor var label: String {
        L10n.colorModeLabel(self)
    }

    @MainActor var description: String {
        L10n.colorModeDescription(self)
    }
}

nonisolated enum StreamColorMode: String, Codable, Equatable {
    case sdr8
    case sdr10
    case hdr10

    var bitDepth: Int {
        self == .sdr8 ? 8 : 10
    }

    @MainActor var diagnosticLabel: String {
        L10n.streamColorModeLabel(self)
    }
}

nonisolated enum DetectedColorMode: String, Codable, Equatable {
    case sdr8
    case sdr10
    case hdr10
    case unknown8Bit
    case unknown10Bit

    @MainActor var diagnosticLabel: String {
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

nonisolated enum HDRSupport: String, Codable {
    case supported
    case unsupported
    case unknown
}

nonisolated enum ColorFallbackReason: String, Codable {
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

nonisolated struct StreamColorState: Codable, Equatable {
    let preference: ColorModePreference
    var requestedMode: StreamColorMode
    var negotiatedMode: StreamColorMode?
    var detectedMode: DetectedColorMode?
    var displayHDRSupport: HDRSupport
    var fallbackReason: ColorFallbackReason?
}

nonisolated struct StreamColorCapabilities {
    let gameHDRSupport: HDRSupport
    let accountAllowsHDR: Bool?
    let serverAllowsHDR: Bool?
    let decoderSupports10Bit: Bool
    let hdrRenderPipelineAvailable: Bool
    let displaySupportsHDR: Bool
}

nonisolated struct HDRDisplayCapabilities: Codable, Equatable {
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

nonisolated struct StreamColorRequest: Codable, Equatable {
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
            // Game and server HDR support are permissive on unknown — GFN falls back to an
            // SDR encode inside an HDR-capable session when the title doesn't support HDR.
            // Account entitlement must be positively known so Free tiers don't request HDR.
            if capabilities.gameHDRSupport != .unsupported,
               capabilities.decoderSupports10Bit,
               capabilities.hdrRenderPipelineAvailable,
               capabilities.displaySupportsHDR,
               capabilities.accountAllowsHDR == true,
               capabilities.serverAllowsHDR != false
            {
                return .hdr10
            }
            return capabilities.decoderSupports10Bit ? .sdr10 : .sdr8
        }
    }
}

extension StreamSettings {
    nonisolated func colorRequest(
        localCapabilities: LocalVideoCapabilities,
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

nonisolated enum ColorQuality: String, Codable, CaseIterable {
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

nonisolated struct IceServer: Codable {
    let urls: [String]
    let username: String?
    let credential: String?
}

// MARK: - Queue Ads

nonisolated struct SessionAdMediaFile: Codable, Equatable {
    let mediaFileUrl: String?
    let encodingProfile: String?
}

nonisolated struct SessionAdInfo: Codable, Equatable, Identifiable {
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
        if let url = adMediaFiles.compactMap({ $0.mediaFileUrl.flatMap(URL.init) }).first {
            return url
        }
        if let url = adUrl.flatMap(URL.init) {
            return url
        }
        return mediaUrl.flatMap(URL.init)
    }
}

nonisolated struct SessionAdState: Codable, Equatable {
    let isAdsRequired: Bool
    let isQueuePaused: Bool?
    let gracePeriodSeconds: Int?
    let message: String?
    let ads: [SessionAdInfo]
}

// MARK: - Session Info (returned by CloudMatch)

nonisolated struct SessionInfo {
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
    /// Estimated queue/setup time remaining, in milliseconds (nil when unknown).
    let seatSetupEtaMs: Int?
    let iceServers: [IceServer]
    let mediaConnectionInfo: MediaConnectionInfo?
    let clientId: String
    let deviceId: String
    let adState: SessionAdState?

    /// True while the session is sitting in the GFN queue (no timeout applies).
    var isInQueue: Bool {
        if seatSetupStep == 1 {
            return true
        }
        return (queuePosition ?? 0) > 1
    }

    /// ETA remaining as a TimeInterval, when the server provides one.
    var seatSetupEta: TimeInterval? {
        seatSetupEtaMs.map { TimeInterval($0) / 1000 }
    }

    /// Setup stage derived from seatSetupStep, for the loading UI label.
    var setupStage: SetupStage {
        SetupStage(seatSetupStep: seatSetupStep)
    }
}

/// Server-reported setup stage during session provisioning, matching the official client's
/// seatSetupStep values (0 Connecting, 1 InQueue, 5 PreviousSessionCleanup, 6 WaitingForStorage;
/// anything else is treated as generic Configuring).
nonisolated enum SetupStage: Equatable {
    case connecting
    case inQueue
    case configuring
    case waitingForStorage
    case previousSessionCleanup

    init(seatSetupStep: Int?) {
        switch seatSetupStep {
        case 0: self = .connecting
        case 1: self = .inQueue
        case 5: self = .previousSessionCleanup
        case 6: self = .waitingForStorage
        default: self = .configuring
        }
    }

    @MainActor var label: String {
        L10n.setupStageLabel(self)
    }
}

nonisolated struct MediaConnectionInfo {
    let ip: String
    let port: Int
}

// MARK: - Active Session Info

nonisolated struct ActiveSessionInfo {
    let sessionId: String
    let status: Int
    let appId: String?
    let serverIp: String?
    let signalingUrl: String?
}

// MARK: - Subscription / Entitlements

nonisolated struct EntitledResolution: Equatable, Codable {
    let widthInPixels: Int
    let heightInPixels: Int
    let framesPerSecond: Int

    var resolutionLabel: String {
        "\(widthInPixels)x\(heightInPixels)"
    }
}

nonisolated struct SubscriptionInfo: Codable {
    let membershipTier: String
    let isUnlimited: Bool
    let remainingMinutes: Int?
    let totalMinutes: Int?
    let entitledResolutions: [EntitledResolution]

    /// HDR entitlement by tier: Ultimate and Performance (formerly Priority) stream HDR,
    /// Free is SDR-only. Unrecognized tiers stay undetermined (nil).
    var allowsHDR: Bool? {
        let tier = membershipTier.uppercased()
        if tier.contains("ULTIMATE") || tier.contains("PERFORMANCE") || tier.contains("PRIORITY") {
            return true
        }
        return tier.contains("FREE") ? false : nil
    }

    /// Whether the tier includes in-game graphics settings persistence: premium tiers
    /// (Ultimate/Performance, formerly Priority) yes, Free no, unrecognized tiers nil.
    var allowsInGameSettingsPersistence: Bool? {
        let tier = membershipTier.uppercased()
        if tier.contains("ULTIMATE") || tier.contains("PERFORMANCE") || tier.contains("PRIORITY") {
            return true
        }
        return tier.contains("FREE") ? false : nil
    }
}

// MARK: - Games

/// A streaming feature GFN surfaces as a loading-screen badge. Matches the three feature keys
/// the official client shows there (RTX_ENABLED, HDR, REFLEX_ENABLED); labels are brand terms
/// shown untranslated. Symbols are Apple SF Symbols to avoid third-party badge artwork.
nonisolated enum GameFeature: String, Codable, CaseIterable, Hashable {
    case rtx
    case hdr
    case reflex

    var label: String {
        switch self {
        case .rtx: "RTX"
        case .hdr: "HDR"
        case .reflex: "Reflex"
        }
    }

    var symbol: String {
        switch self {
        case .rtx: "sparkles"
        case .hdr: "sun.max.fill"
        case .reflex: "bolt.fill"
        }
    }
}

nonisolated struct GameInfo: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let longDescription: String?
    var genres: [String]?
    let developer: String?
    let publisher: String?
    let contentRating: String?
    let boxArtUrl: String?
    /// Wide 16:9 banner (GFN TV_BANNER) for tiles and Home rows.
    let heroBannerUrl: String?
    /// Full-bleed cinematic key art (GFN HERO_IMAGE) for the full-screen loading background,
    /// matching the official client. Optional Codable field: absent in older persisted JSON → nil.
    let heroImageUrl: String?
    /// Streaming features the game supports (RTX/HDR/Reflex), from GFN's per-variant feature flags.
    /// Optional Codable field: absent in older persisted JSON → nil.
    let supportedFeatures: [GameFeature]?
    var screenshots: [String]
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

extension GameInfo {
    var genreCodes: [String] {
        Array(Set((genres ?? []).map(Self.normalizedGenreCode).filter { !$0.isEmpty })).sorted()
    }

    @MainActor var genreItems: [String] {
        let mapped = genreCodes.map { GameInfo.genreLabel($0) }
        return mapped.isEmpty ? variants.map(\.storeName) : mapped
    }

    @MainActor static func genreLabel(_ code: String) -> String {
        let normalizedCode = normalizedGenreCode(code)
        return switch normalizedCode {
        case "ACTION": L10n.text("genre_action")
        case "ADVENTURE": L10n.text("genre_adventure")
        case "ARCADE": L10n.text("genre_arcade")
        case "FAMILY": L10n.text("genre_family")
        case "FIRST_PERSON_SHOOTER": L10n.text("genre_first_person_shooter")
        case "FREE_TO_PLAY": L10n.text("genre_free_to_play")
        case "ROLE_PLAYING": L10n.text("genre_role_playing")
        case "STRATEGY": L10n.text("genre_strategy")
        case "SPORTS": L10n.text("genre_sports")
        case "RACING": L10n.text("genre_racing")
        case "SIMULATION": L10n.text("genre_simulation")
        case "PUZZLE": L10n.text("genre_puzzle")
        case "SHOOTER": L10n.text("genre_shooter")
        case "FIGHTING": L10n.text("genre_fighting")
        case "PLATFORMER": L10n.text("genre_platformer")
        case "HORROR": L10n.text("genre_horror")
        case "CASUAL": L10n.text("genre_casual")
        case "INDIE": L10n.text("genre_indie")
        case "MASSIVELY_MULTIPLAYER", "MASSIVELY_MULTIPLAYER_ONLINE": L10n.text("genre_mmo")
        case "MULTIPLAYER_ONLINE_BATTLE_ARENA": L10n.text("genre_moba")
        case "TECH_DEMO": L10n.text("genre_tech_demo")
        default: normalizedCode.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private nonisolated static func normalizedGenreCode(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "_")
    }
}

// MARK: - Game cache compatibility

extension GameInfo {
    private enum CodingKeys: String, CodingKey {
        case id, title, longDescription, genres, developer, publisher, contentRating
        case boxArtUrl, heroBannerUrl, heroImageUrl, supportedFeatures, screenshots
        case isInLibrary, variants
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        longDescription = try c.decodeIfPresent(String.self, forKey: .longDescription)
        genres = try c.decodeIfPresent([String].self, forKey: .genres)
        developer = try c.decodeIfPresent(String.self, forKey: .developer)
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        contentRating = try c.decodeIfPresent(String.self, forKey: .contentRating)
        boxArtUrl = try c.decodeIfPresent(String.self, forKey: .boxArtUrl)
        heroBannerUrl = try c.decodeIfPresent(String.self, forKey: .heroBannerUrl)
        heroImageUrl = try c.decodeIfPresent(String.self, forKey: .heroImageUrl)
        supportedFeatures = try c.decodeIfPresent([GameFeature].self, forKey: .supportedFeatures)
        screenshots = try c.decodeIfPresent([String].self, forKey: .screenshots) ?? []
        isInLibrary = try c.decode(Bool.self, forKey: .isInLibrary)
        variants = try c.decode([GameVariant].self, forKey: .variants)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(longDescription, forKey: .longDescription)
        try c.encodeIfPresent(genres, forKey: .genres)
        try c.encodeIfPresent(developer, forKey: .developer)
        try c.encodeIfPresent(publisher, forKey: .publisher)
        try c.encodeIfPresent(contentRating, forKey: .contentRating)
        try c.encodeIfPresent(boxArtUrl, forKey: .boxArtUrl)
        try c.encodeIfPresent(heroBannerUrl, forKey: .heroBannerUrl)
        try c.encodeIfPresent(heroImageUrl, forKey: .heroImageUrl)
        try c.encodeIfPresent(supportedFeatures, forKey: .supportedFeatures)
        try c.encode(screenshots, forKey: .screenshots)
        try c.encode(isInLibrary, forKey: .isInLibrary)
        try c.encode(variants, forKey: .variants)
    }
}

nonisolated struct GameVariant: Equatable, Codable {
    let id: String
    let appStore: String
    var appId: String?
    /// True when GFN reports MANUAL, PLATFORM_SYNC, or IN_LIBRARY for this variant.
    var isOwned: Bool = false

    @MainActor var storeName: String {
        L10n.storeName(for: appStore)
    }
}

extension GameVariant {
    private enum CodingKeys: String, CodingKey {
        case id, appStore, appId, isOwned
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        appStore = try c.decode(String.self, forKey: .appStore)
        appId = try c.decodeIfPresent(String.self, forKey: .appId)
        isOwned = try c.decodeIfPresent(Bool.self, forKey: .isOwned) ?? false
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(appStore, forKey: .appStore)
        try c.encodeIfPresent(appId, forKey: .appId)
        try c.encode(isOwned, forKey: .isOwned)
    }
}

// MARK: - Session Create Request

nonisolated struct SessionCreateRequest {
    let appId: String
    let internalTitle: String?
    let token: String
    let streamingBaseUrl: String?
    let routingZoneUrl: String?
    let settings: StreamSettings
    let localVideoCapabilities: LocalVideoCapabilities
    let accountLinked: Bool
    let accountAllowsHDR: Bool?
}
