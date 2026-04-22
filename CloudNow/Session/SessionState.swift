import Foundation

// MARK: - Stream Settings

struct StreamSettings: Codable, Equatable {
    var resolution: String = "1920x1080"
    var fps: Int = 60
    var maxBitrateKbps: Int = 20_000 { didSet { maxBitrateKbps = min(maxBitrateKbps, 100_000) } }
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
}

enum OverlayTriggerButton: String, Codable, CaseIterable {
    case start   = "Start (≡)"
    case options = "Options/Back (⊟)"
}

enum VideoCodec: String, Codable, CaseIterable {
    case h264 = "H264"
    case h265 = "H265"
    case av1  = "AV1"
}

enum ColorQuality: String, Codable, CaseIterable {
    case sdr8bit  = "SDR8bit"
    case sdr10bit = "SDR10bit"
    case hdr10bit = "HDR10bit"

    var bitDepth: Int { self == .sdr8bit ? 8 : 10 }
    var chromaFormat: Int { self == .hdr10bit ? 2 : 1 }
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
    var id: String { adId }

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

    var resolutionLabel: String { "\(widthInPixels)x\(heightInPixels)" }
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
}

struct GameVariant: Equatable {
    let id: String
    let appStore: String
    var appId: String?
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
