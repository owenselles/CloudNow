import Foundation

// MARK: - Stream Settings

struct StreamSettings: Codable, Equatable {
    var resolution: String = "1920x1080"
    var fps: Int = 60
    var maxBitrateKbps: Int = 20000 {
        didSet { maxBitrateKbps = min(maxBitrateKbps, 100_000) }
    }

    var codec: VideoCodec = .h264
    var colorQuality: ColorQuality = .sdr8bit
    var keyboardLayout: String = "en-US"
    var gameLanguage: String = "en_US"
    var enableL4S: Bool = false
    var micEnabled: Bool = false
    /// Radial deadzone applied to analog stick axes (0.0–1.0). Default 15%.
    var controllerDeadzone: Double = 0.15
    /// Which controller button triggers the GFN overlay on long-press. Default: Start (≡).
    var overlayTriggerButton: OverlayTriggerButton = .start
    /// Default Siri Remote input mode when a stream session starts.
    var defaultRemoteInputMode: RemoteInputMode = .mouse
    /// Preferred zone URL, e.g. "https://np-aws-us-n-virginia-1.cloudmatchbeta.nvidiagrid.net/"
    /// nil = let the GFN default VPC handle routing.
    var preferredZoneUrl: String? = nil
    /// Long-press the button that is NOT the overlay trigger to send Shift+Tab (opens the
    /// Steam in-game overlay). e.g. with overlay on Start, long-press View/Back triggers Steam.
    var enableSteamOverlayGesture: Bool = true
}

// MARK: - StreamSettings: resilient decoding

///
/// Synthesized Decodable throws keyNotFound when a newly-added field is missing from
/// previously-persisted JSON, which would silently reset ALL settings to defaults on upgrade.
/// decodeIfPresent + default fallbacks keep existing settings intact across versions.
extension StreamSettings {
    enum CodingKeys: String, CodingKey {
        case resolution, fps, maxBitrateKbps, codec, colorQuality, keyboardLayout
        case gameLanguage, enableL4S, micEnabled, controllerDeadzone, overlayTriggerButton
        case defaultRemoteInputMode, preferredZoneUrl
        case enableSteamOverlayGesture
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StreamSettings()
        self.init()
        resolution = try c.decodeIfPresent(String.self, forKey: .resolution) ?? d.resolution
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        maxBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .maxBitrateKbps) ?? d.maxBitrateKbps
        codec = try c.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? d.codec
        colorQuality = try c.decodeIfPresent(ColorQuality.self, forKey: .colorQuality) ?? d.colorQuality
        keyboardLayout = try c.decodeIfPresent(String.self, forKey: .keyboardLayout) ?? d.keyboardLayout
        gameLanguage = try c.decodeIfPresent(String.self, forKey: .gameLanguage) ?? d.gameLanguage
        enableL4S = try c.decodeIfPresent(Bool.self, forKey: .enableL4S) ?? d.enableL4S
        micEnabled = try c.decodeIfPresent(Bool.self, forKey: .micEnabled) ?? d.micEnabled
        controllerDeadzone = try c.decodeIfPresent(Double.self, forKey: .controllerDeadzone) ?? d.controllerDeadzone
        overlayTriggerButton = try c.decodeIfPresent(OverlayTriggerButton.self, forKey: .overlayTriggerButton) ?? d.overlayTriggerButton
        defaultRemoteInputMode = try c.decodeIfPresent(RemoteInputMode.self, forKey: .defaultRemoteInputMode) ?? d.defaultRemoteInputMode
        preferredZoneUrl = try c.decodeIfPresent(String.self, forKey: .preferredZoneUrl)
        enableSteamOverlayGesture = try c.decodeIfPresent(Bool.self, forKey: .enableSteamOverlayGesture) ?? d.enableSteamOverlayGesture
    }
}

enum OverlayTriggerButton: String, Codable, CaseIterable {
    case start = "Start (≡)"
    case options = "Options/Back (⊟)"
}

enum VideoCodec: String, Codable, CaseIterable {
    case h264 = "H264"
    case h265 = "H265"
    case av1 = "AV1"
}

enum ColorQuality: String, Codable, CaseIterable {
    case sdr8bit = "SDR8bit"
    case sdr10bit = "SDR10bit"
    case hdr10bit = "HDR10bit"

    var bitDepth: Int {
        self == .sdr8bit ? 8 : 10
    }

    var chromaFormat: Int {
        self == .hdr10bit ? 2 : 1
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

struct GameInfo: Identifiable, Equatable {
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

struct GameVariant: Equatable {
    let id: String
    let appStore: String
    var appId: String?
    /// True when GFN reports a library status other than `NOT_OWNED` for this variant.
    var isOwned: Bool = false

    var storeName: String {
        switch appStore {
        case "STEAM": "Steam"
        case "EPIC_GAMES_STORE": "Epic Games"
        case "GOG": "GOG"
        case "EA_APP": "EA App"
        case "UBISOFT": "Ubisoft Connect"
        case "MICROSOFT": "Xbox"
        case "BATTLENET": "Battle.net"
        default: appStore.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - Session Create Request

struct SessionCreateRequest {
    let appId: String
    let internalTitle: String?
    let token: String
    let zone: String
    let streamingBaseUrl: String?
    let settings: StreamSettings
    let accountLinked: Bool
}
