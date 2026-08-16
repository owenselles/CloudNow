import Foundation
import os

private nonisolated let xboxSessionLog = Logger(
    subsystem: "com.owenselles.CloudNow2",
    category: "XboxSession"
)

/// Credentials and service metadata obtained during Xbox Cloud Gaming sign-in.
///
/// The GS token and Microsoft transfer-token closure are intentionally retained only by the
/// session actor. Value descriptions never include either credential.
nonisolated struct XboxCloudSessionAccessContext: Sendable, CustomStringConvertible {
    let gsToken: String
    let regionBaseURL: URL
    let market: String
    let fallbackRegionNames: [String]
    let systemUpdateGroups: [String]
    let routingHeader: String
    let deviceInformation: XboxCloudDeviceInformation
    let compatibilityProfile: XboxCloudSessionCompatibilityProfile
    let msaTransferToken: @Sendable () async throws -> String

    init(
        gsToken: String,
        regionBaseURL: URL,
        market: String,
        fallbackRegionNames: [String],
        systemUpdateGroups: [String],
        routingHeader: String = "AFD",
        deviceInformation: XboxCloudDeviceInformation = .cloudNowTV(),
        compatibilityProfile: XboxCloudSessionCompatibilityProfile = .nativeTVControl,
        msaTransferToken: @escaping @Sendable () async throws -> String
    ) throws {
        guard Self.isSafeCredential(gsToken) else {
            throw XboxCloudSessionAPIError.invalidAccessContext("Xbox Cloud GS token is missing or invalid.")
        }
        let normalizedMarket = market.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeLabel(normalizedMarket, maximumLength: 32) else {
            throw XboxCloudSessionAPIError.invalidAccessContext("Xbox Cloud market is missing or invalid.")
        }
        guard routingHeader == "AFD" || routingHeader == "ATM" else {
            throw XboxCloudSessionAPIError.invalidAccessContext(
                "Xbox Cloud routing mode is invalid."
            )
        }

        self.gsToken = gsToken
        self.regionBaseURL = try validatedXboxCloudServiceURL(regionBaseURL.absoluteString)
        self.market = normalizedMarket
        self.fallbackRegionNames = try Self.validatedLabels(
            fallbackRegionNames,
            name: "fallback region",
            maximumCount: 32
        )
        self.systemUpdateGroups = try Self.validatedLabels(
            systemUpdateGroups,
            name: "system update group",
            maximumCount: 32,
            permitsEmptyDefault: true
        )
        self.routingHeader = routingHeader
        self.deviceInformation = try deviceInformation.validated()
        self.compatibilityProfile = compatibilityProfile
        self.msaTransferToken = msaTransferToken
    }

    var description: String {
        "XboxCloudSessionAccessContext(gsToken: <redacted>, region: \(regionBaseURL.host ?? "unknown"), market: \(market), fallbackRegions: \(fallbackRegionNames.count), systemUpdateGroups: \(systemUpdateGroups.count), profile: \(compatibilityProfile.identifier), msaTransferToken: <redacted>)"
    }

    private static func validatedLabels(
        _ labels: [String],
        name: String,
        maximumCount: Int,
        permitsEmptyDefault: Bool = false
    ) throws -> [String] {
        guard labels.count <= maximumCount else {
            throw XboxCloudSessionAPIError.invalidAccessContext("Xbox Cloud \(name) list is too large.")
        }
        var seen = Set<String>()
        var output: [String] = []
        for label in labels {
            let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if permitsEmptyDefault, normalized.isEmpty {
                continue
            }
            guard isSafeLabel(normalized, maximumLength: 128) else {
                throw XboxCloudSessionAPIError.invalidAccessContext("Xbox Cloud \(name) is invalid.")
            }
            if seen.insert(normalized).inserted {
                output.append(normalized)
            }
        }
        return output
    }

    fileprivate static func isSafeCredential(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 16384
            && value.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    && scalar != "\r"
                    && scalar != "\n"
            }
    }

    fileprivate static func isSafeLabel(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty
            && value.count <= maximumLength
            && value.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    && scalar != "\r"
                    && scalar != "\n"
            }
    }
}

/// Non-secret values serialized into Microsoft's `X-MS-Device-Info` request header.
nonisolated struct XboxCloudDeviceInformation: Codable, Equatable, Sendable, CustomStringConvertible {
    let clientAppID: String
    let clientAppType: String
    let clientAppVersion: String
    let clientSDKVersion: String
    let sdkInstallID: String
    let make: String
    let model: String
    let platformType: String
    let sdkType: String
    let operatingSystemName: String
    let operatingSystemVersion: String
    let operatingSystemPlatform: String
    let browserName: String
    let browserVersion: String
    let displayWidthInPixels: Int
    let displayHeightInPixels: Int
    let pixelDensity: Double

    init(
        clientAppID: String,
        clientAppType: String,
        clientAppVersion: String,
        clientSDKVersion: String,
        sdkInstallID: String,
        make: String,
        model: String,
        platformType: String,
        sdkType: String,
        operatingSystemName: String,
        operatingSystemVersion: String,
        operatingSystemPlatform: String? = nil,
        browserName: String = "CloudNow",
        browserVersion: String? = nil,
        displayWidthInPixels: Int,
        displayHeightInPixels: Int,
        pixelDensity: Double
    ) {
        self.clientAppID = clientAppID
        self.clientAppType = clientAppType
        self.clientAppVersion = clientAppVersion
        self.clientSDKVersion = clientSDKVersion
        self.sdkInstallID = sdkInstallID
        self.make = make
        self.model = model
        self.platformType = platformType
        self.sdkType = sdkType
        self.operatingSystemName = operatingSystemName
        self.operatingSystemVersion = operatingSystemVersion
        self.operatingSystemPlatform = operatingSystemPlatform ?? platformType
        self.browserName = browserName
        self.browserVersion = browserVersion ?? clientAppVersion
        self.displayWidthInPixels = displayWidthInPixels
        self.displayHeightInPixels = displayHeightInPixels
        self.pixelDensity = pixelDensity
    }

    static func cloudNowTV(
        sdkInstallID: String = UUID().uuidString,
        displayWidthInPixels: Int = 1920,
        displayHeightInPixels: Int = 1080,
        pixelDensity: Double = 1
    ) -> Self {
        let profile = XboxCloudCompatibilityProfile.bundledV1
        return Self(
            clientAppID: "CloudNow",
            clientAppType: profile.streamingClientAppType,
            clientAppVersion: profile.streamingClientAppVersion,
            clientSDKVersion: profile.streamingClientSDKVersion,
            sdkInstallID: sdkInstallID,
            make: "Apple",
            model: "Apple TV",
            platformType: profile.streamingPlatformType,
            sdkType: profile.streamingSDKType,
            operatingSystemName: "tvOS",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            operatingSystemPlatform: profile.streamingPlatformType,
            browserName: "CloudNow",
            browserVersion: profile.streamingClientAppVersion,
            displayWidthInPixels: displayWidthInPixels,
            displayHeightInPixels: displayHeightInPixels,
            pixelDensity: pixelDensity
        )
    }

    var description: String {
        "XboxCloudDeviceInformation(app: \(clientAppID), platform: \(platformType), model: \(model))"
    }

    fileprivate func validated() throws -> Self {
        let strings = [
            clientAppID,
            clientAppType,
            clientAppVersion,
            clientSDKVersion,
            sdkInstallID,
            make,
            model,
            platformType,
            sdkType,
            operatingSystemName,
            operatingSystemVersion,
            operatingSystemPlatform,
            browserName,
            browserVersion,
        ]
        guard strings.allSatisfy({ XboxCloudSessionAccessContext.isSafeLabel($0, maximumLength: 256) }),
              (1 ... 16384).contains(displayWidthInPixels),
              (1 ... 16384).contains(displayHeightInPixels),
              pixelDensity.isFinite,
              (0.1 ... 16).contains(pixelDensity)
        else {
            throw XboxCloudSessionAPIError.invalidAccessContext("Xbox Cloud device information is invalid.")
        }
        return self
    }

    fileprivate func applying(
        _ profile: XboxCloudSessionCompatibilityProfile
    ) -> Self {
        guard let identity = profile.deviceIdentity else { return self }
        return Self(
            clientAppID: identity.clientAppID,
            clientAppType: identity.clientAppType,
            clientAppVersion: identity.clientAppVersion,
            clientSDKVersion: identity.clientSDKVersion,
            sdkInstallID: sdkInstallID,
            make: identity.hardwareMake,
            model: identity.hardwareModel,
            platformType: identity.platformType,
            sdkType: identity.sdkType,
            operatingSystemName: identity.operatingSystemName,
            operatingSystemVersion: identity.operatingSystemVersion,
            operatingSystemPlatform: identity.operatingSystemPlatform,
            browserName: identity.browserName,
            browserVersion: identity.browserVersion,
            displayWidthInPixels: identity.displayWidthInPixels,
            displayHeightInPixels: identity.displayHeightInPixels,
            pixelDensity: identity.pixelDensity
        )
    }
}

/// Service-side stream settings sent when allocating a cloud console.
nonisolated struct XboxCloudSessionLaunchSettings: Codable, Equatable, Sendable {
    let nanoVersion: String
    let enableTextToSpeech: Bool
    let magnifier: Bool
    let highContrast: Int
    let locale: String
    let useIceConnection: Bool
    let timezoneOffsetMinutes: Int
    let sdkType: String
    let osName: String
    let enableOptionalDataCollection: Bool

    init(
        nanoVersion: String = "V3;WebrtcTransport.dll",
        enableTextToSpeech: Bool = false,
        magnifier: Bool = false,
        highContrast: Int = 0,
        locale: String,
        useIceConnection: Bool = false,
        timezoneOffsetMinutes: Int,
        sdkType: String = "web",
        osName: String = "tvOS",
        enableOptionalDataCollection: Bool = false
    ) {
        self.nanoVersion = nanoVersion
        self.enableTextToSpeech = enableTextToSpeech
        self.magnifier = magnifier
        self.highContrast = highContrast
        self.locale = locale
        self.useIceConnection = useIceConnection
        self.timezoneOffsetMinutes = timezoneOffsetMinutes
        self.sdkType = sdkType
        self.osName = osName
        self.enableOptionalDataCollection = enableOptionalDataCollection
    }

    fileprivate func validate() throws {
        guard XboxCloudSessionAccessContext.isSafeLabel(nanoVersion, maximumLength: 128),
              XboxCloudSessionAccessContext.isSafeLabel(locale, maximumLength: 64),
              XboxCloudSessionAccessContext.isSafeLabel(sdkType, maximumLength: 32),
              XboxCloudSessionAccessContext.isSafeLabel(osName, maximumLength: 64),
              (-1440 ... 1440).contains(timezoneOffsetMinutes),
              (0 ... 2).contains(highContrast)
        else {
            throw XboxCloudSessionAPIError.invalidLaunchRequest("Xbox Cloud launch settings are invalid.")
        }
    }
}

nonisolated struct XboxCloudSessionLaunchRequest: Equatable, Sendable {
    let titleID: String
    let preferredSystemUpdateGroup: String?
    let clientSessionID: String
    let settings: XboxCloudSessionLaunchSettings

    init(
        titleID: String,
        preferredSystemUpdateGroup: String? = nil,
        clientSessionID: String = UUID().uuidString,
        settings: XboxCloudSessionLaunchSettings
    ) throws {
        let normalizedTitleID = titleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedClientSessionID = clientSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard XboxCloudSessionAccessContext.isSafeLabel(normalizedTitleID, maximumLength: 128),
              XboxCloudSessionAccessContext.isSafeLabel(normalizedClientSessionID, maximumLength: 128)
        else {
            throw XboxCloudSessionAPIError.invalidLaunchRequest("Xbox Cloud title or client session identifier is invalid.")
        }
        if let preferredSystemUpdateGroup {
            let normalizedGroup = preferredSystemUpdateGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            guard XboxCloudSessionAccessContext.isSafeLabel(normalizedGroup, maximumLength: 128) else {
                throw XboxCloudSessionAPIError.invalidLaunchRequest("Xbox Cloud system update group is invalid.")
            }
            self.preferredSystemUpdateGroup = normalizedGroup
        } else {
            self.preferredSystemUpdateGroup = nil
        }
        try settings.validate()

        self.titleID = normalizedTitleID
        self.clientSessionID = normalizedClientSessionID
        self.settings = settings
    }
}

private extension XboxCloudSessionCompatibilityProfile {
    // xbox-quality-beta-coverage:client-session-id:start
    nonisolated func clientSessionID(
        provided: String,
        generator: @Sendable () -> String
    ) throws -> String {
        switch clientSessionIDPolicy {
        case .provided:
            return provided
        case let .lowercaseHex(length):
            let generated = generator()
            let allowedCharacters = CharacterSet(
                charactersIn: "abcdef0123456789"
            )
            guard generated.utf8.count == length,
                  generated.unicodeScalars.allSatisfy(allowedCharacters.contains)
            else {
                throw XboxCloudSessionAPIError.invalidLaunchRequest(
                    "Xbox Cloud generated an invalid client session identifier."
                )
            }
            return generated
        }
    }
    // xbox-quality-beta-coverage:client-session-id:end
}

/// Opaque handle for one server-side Xbox Cloud session.
nonisolated struct XboxCloudSessionHandle: Hashable, Sendable, CustomStringConvertible {
    fileprivate let sessionPath: String

    var description: String {
        "XboxCloudSessionHandle(sessionPath: <redacted>)"
    }
}

nonisolated enum XboxCloudSessionState: Equatable, Sendable, CustomStringConvertible {
    case waitingForResources
    case readyToConnect
    case provisioning
    case provisioned
    case failed
    case unknown(String)

    var description: String {
        switch self {
        case .waitingForResources: "WaitingForResources"
        case .readyToConnect: "ReadyToConnect"
        case .provisioning: "Provisioning"
        case .provisioned: "Provisioned"
        case .failed: "Failed"
        case let .unknown(value): "Unknown(\(value))"
        }
    }
}

nonisolated struct XboxCloudSessionStateSnapshot: Equatable, Sendable {
    let state: XboxCloudSessionState
    let estimatedTotalWaitTime: TimeInterval?
    let retryAfter: TimeInterval?
    let serviceCode: String?
}

nonisolated struct XboxCloudSRTPDetails: Codable, Equatable, Sendable, CustomStringConvertible {
    let key: String

    var description: String {
        "XboxCloudSRTPDetails(key: <redacted>)"
    }
}

/// Network details returned after provisioning. Media negotiation is deliberately implemented elsewhere.
nonisolated struct XboxCloudServerDetails: Codable, Equatable, Sendable, CustomStringConvertible {
    let ipV4Address: String?
    let ipV4Port: Int?
    let ipV6Address: String?
    let ipV6Port: Int?
    let srtp: XboxCloudSRTPDetails?
    let uriPathAndQuery: String?
    let stunServerAddresses: [String]?

    var description: String {
        "XboxCloudServerDetails(ipV4: \(ipV4Address == nil ? "nil" : "present"), ipV6: \(ipV6Address == nil ? "nil" : "present"), srtp: \(srtp == nil ? "nil" : "<redacted>"), stunServers: \(stunServerAddresses?.count ?? 0))"
    }

    fileprivate func validate() throws {
        guard Self.isSafeOptionalNetworkValue(ipV4Address),
              Self.isSafeOptionalNetworkValue(ipV6Address),
              Self.isSafeOptionalNetworkValue(uriPathAndQuery, maximumLength: 2048),
              ipV4Address?.isEmpty == false || ipV6Address?.isEmpty == false,
              Self.isValidPort(ipV4Port),
              Self.isValidPort(ipV6Port),
              srtp == nil || XboxCloudSessionAccessContext.isSafeCredential(srtp?.key ?? ""),
              (stunServerAddresses?.count ?? 0) <= 32,
              (stunServerAddresses ?? []).allSatisfy({ Self.isSafeOptionalNetworkValue($0, maximumLength: 512) })
        else {
            throw XboxCloudSessionAPIError.invalidPayload(operation: .configuration)
        }
    }

    private static func isSafeOptionalNetworkValue(_ value: String?, maximumLength: Int = 512) -> Bool {
        guard let value else { return true }
        return XboxCloudSessionAccessContext.isSafeLabel(value, maximumLength: maximumLength)
    }

    private static func isValidPort(_ value: Int?) -> Bool {
        guard let value else { return true }
        return (1 ... 65535).contains(value)
    }
}

indirect nonisolated enum XboxCloudJSONValue: Codable, Equatable, Sendable {
    case object([String: XboxCloudJSONValue])
    case array([XboxCloudJSONValue])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: XboxCloudJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([XboxCloudJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

nonisolated struct XboxCloudSessionConfiguration: Equatable, Sendable, CustomStringConvertible {
    let serverDetails: XboxCloudServerDetails
    let keepAlivePulse: TimeInterval
    let clientStreamingConfigOverrides: XboxCloudJSONValue?

    var description: String {
        "XboxCloudSessionConfiguration(serverDetails: \(serverDetails), keepAlivePulse: \(keepAlivePulse), clientStreamingConfigOverrides: \(clientStreamingConfigOverrides == nil ? "nil" : "<redacted>"))"
    }
}

nonisolated struct XboxCloudProvisionedSession: Equatable, Sendable {
    let handle: XboxCloudSessionHandle
    let configuration: XboxCloudSessionConfiguration
}

nonisolated struct XboxCloudKeepAliveReceipt: Equatable, Sendable, CustomStringConvertible {
    let response: XboxCloudJSONValue

    var description: String {
        "XboxCloudKeepAliveReceipt(response: <redacted>)"
    }
}

nonisolated struct XboxCloudSessionPollingPolicy: Equatable, Sendable {
    let queueInterval: TimeInterval
    let provisioningInterval: TimeInterval
    let maximumRetryAfter: TimeInterval
    let maximumElapsedTime: TimeInterval
    let maximumStateRequests: Int

    static let standard = Self(
        uncheckedQueueInterval: 10,
        provisioningInterval: 2,
        maximumRetryAfter: 60,
        maximumElapsedTime: 15 * 60,
        maximumStateRequests: 300
    )

    init(
        queueInterval: TimeInterval,
        provisioningInterval: TimeInterval,
        maximumRetryAfter: TimeInterval,
        maximumElapsedTime: TimeInterval,
        maximumStateRequests: Int
    ) throws {
        guard queueInterval.isFinite,
              provisioningInterval.isFinite,
              maximumRetryAfter.isFinite,
              maximumElapsedTime.isFinite,
              (0 ... 60).contains(queueInterval),
              (0 ... 60).contains(provisioningInterval),
              (0 ... 300).contains(maximumRetryAfter),
              (1 ... 3600).contains(maximumElapsedTime),
              (1 ... 1000).contains(maximumStateRequests)
        else {
            throw XboxCloudSessionAPIError.invalidPollingPolicy
        }
        self.init(
            uncheckedQueueInterval: queueInterval,
            provisioningInterval: provisioningInterval,
            maximumRetryAfter: maximumRetryAfter,
            maximumElapsedTime: maximumElapsedTime,
            maximumStateRequests: maximumStateRequests
        )
    }

    private init(
        uncheckedQueueInterval queueInterval: TimeInterval,
        provisioningInterval: TimeInterval,
        maximumRetryAfter: TimeInterval,
        maximumElapsedTime: TimeInterval,
        maximumStateRequests: Int
    ) {
        self.queueInterval = queueInterval
        self.provisioningInterval = provisioningInterval
        self.maximumRetryAfter = maximumRetryAfter
        self.maximumElapsedTime = maximumElapsedTime
        self.maximumStateRequests = maximumStateRequests
    }
}

nonisolated enum XboxCloudSessionAPIOperation: String, Equatable, Sendable {
    case create
    case state
    case connect
    case configuration
    case keepAlive
    case delete
}

nonisolated enum XboxCloudSessionAPIError: Error, Equatable, Sendable, LocalizedError {
    case invalidAccessContext(String)
    case invalidLaunchRequest(String)
    case invalidPollingPolicy
    case unknownSession
    case invalidResponse(operation: XboxCloudSessionAPIOperation)
    case invalidPayload(operation: XboxCloudSessionAPIOperation)
    case responseTooLarge(operation: XboxCloudSessionAPIOperation)
    case httpFailure(operation: XboxCloudSessionAPIOperation, statusCode: Int, serviceCode: String?)
    case transportFailure(operation: XboxCloudSessionAPIOperation)
    case transferTokenUnavailable
    case sessionFailed(serviceCode: String?)
    case unsupportedState(String)
    case pollingTimedOut(maximumStateRequests: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidAccessContext(message): message
        case let .invalidLaunchRequest(message): message
        case .invalidPollingPolicy: "Xbox Cloud polling policy is invalid."
        case .unknownSession: "Xbox Cloud session is no longer active."
        case let .invalidResponse(operation): "Xbox Cloud \(operation.rawValue) returned an invalid HTTP response."
        case let .invalidPayload(operation): "Xbox Cloud \(operation.rawValue) returned an invalid response payload."
        case let .responseTooLarge(operation):
            "Xbox Cloud \(operation.rawValue) returned an oversized response."
        case let .httpFailure(operation, statusCode, serviceCode):
            if let serviceCode {
                "Xbox Cloud \(operation.rawValue) failed with \(serviceCode) (HTTP \(statusCode))."
            } else {
                "Xbox Cloud \(operation.rawValue) failed with HTTP \(statusCode)."
            }
        case let .transportFailure(operation): "Xbox Cloud \(operation.rawValue) could not be completed."
        case .transferTokenUnavailable: "Xbox Cloud could not obtain the Microsoft session transfer token."
        case let .sessionFailed(serviceCode):
            if let serviceCode {
                "Xbox Cloud session provisioning failed with \(serviceCode)."
            } else {
                "Xbox Cloud session provisioning failed."
            }
        case let .unsupportedState(state): "Xbox Cloud returned unsupported session state \(state)."
        case let .pollingTimedOut(maximumStateRequests):
            "Xbox Cloud session provisioning did not finish after \(maximumStateRequests) state requests."
        }
    }
}

/// Cancellation-aware client for the Xbox Cloud session-allocation REST lifecycle.
///
/// The actor owns credential access, correlation-vector sequencing, transfer-host updates,
/// and the bounded polling loop. SDP, ICE, and WebRTC negotiation are separate concerns.
actor XboxCloudSessionAPI {
    private static let requestTimeout: TimeInterval = 30
    private static let transientStateRetryInterval: TimeInterval = 2
    private static let maximumResponseBytes = 2 * 1024 * 1024
    private static let hardAllocationCeiling: TimeInterval = 15 * 60
    private static let minimumAdaptiveQueueBudget: TimeInterval = 60
    private static let estimatedQueueGracePeriod: TimeInterval = 30

    private struct SessionRecord {
        var baseURL: URL
        var didConnect = false
    }

    private let access: XboxCloudSessionAccessContext
    private let transport: any HTTPTransport
    private let pollingPolicy: XboxCloudSessionPollingPolicy
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let clientSessionIDGenerator: @Sendable () -> String
    private let correlationVectorBase: String
    private var correlationVectorSequence = 0
    private var sessions: [String: SessionRecord] = [:]

    init(
        access: XboxCloudSessionAccessContext,
        transport: any HTTPTransport = URLSessionHTTPTransport(configuration: .ephemeral),
        pollingPolicy: XboxCloudSessionPollingPolicy = .standard,
        correlationVectorBase: String? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        clientSessionIDGenerator: @escaping @Sendable () -> String = {
            String(
                UUID().uuidString
                    .replacingOccurrences(of: "-", with: "")
                    .lowercased()
                    .prefix(22)
            )
        },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.access = access
        self.transport = transport
        self.pollingPolicy = pollingPolicy
        self.correlationVectorBase = Self.validatedCorrelationVectorBase(correlationVectorBase)
        self.now = now
        self.clientSessionIDGenerator = clientSessionIDGenerator
        self.sleep = sleep
    }

    func createSession(_ launch: XboxCloudSessionLaunchRequest) async throws -> XboxCloudSessionHandle {
        try launch.settings.validate()
        let profile = access.compatibilityProfile
        #if XBOX_QUALITY_BETA
            let device = access.deviceInformation.applying(profile)
            xboxSessionLog.notice(
                "Xbox allocation profile=\(profile.identifier, privacy: .public) appType=\(device.clientAppType, privacy: .public) sdk=\(device.clientSDKVersion, privacy: .public)/\(device.sdkType, privacy: .public) platform=\(device.platformType, privacy: .public) display=\(device.displayWidthInPixels, privacy: .public)x\(device.displayHeightInPixels, privacy: .public) density=\(device.pixelDensity, privacy: .public)"
            )
            XboxCloudQualityTelemetry.shared.record(
                .compatibilityProfile(
                    XboxCloudQualityTelemetryProfile(
                        identifier: profile.identifier
                    )
                )
            )
            XboxCloudQualityTelemetry.shared.record(
                .display(
                    signal: .allocationHeader,
                    width: device.displayWidthInPixels,
                    height: device.displayHeightInPixels,
                    pixelDensity: device.pixelDensity
                )
            )
        #endif
        let selectedSystemUpdateGroup: String = if profile.usesRegionalAllocationHints,
                                                   let requested = launch.preferredSystemUpdateGroup,
                                                   access.systemUpdateGroups.contains(requested)
        {
            requested
        } else {
            ""
        }
        let clientSessionID = try profile.clientSessionID(
            provided: launch.clientSessionID,
            generator: clientSessionIDGenerator
        )
        let payload = CreateSessionPayload(
            titleId: launch.titleID,
            systemUpdateGroup: selectedSystemUpdateGroup,
            settings: CreateSessionSettingsPayload(
                settings: launch.settings,
                profile: profile
            ),
            serverId: "",
            fallbackRegionNames: profile.usesRegionalAllocationHints
                ? access.fallbackRegionNames
                : [],
            clientSessionId: clientSessionID
        )
        let body = try encode(payload, operation: .create)
        let url = try endpoint(
            baseURL: access.regionBaseURL,
            path: XboxCloudCompatibilityProfile.bundledV1
                .cloudSessionCreatePath
        )
        let (data, _) = try await send(
            method: "POST",
            url: url,
            operation: .create,
            body: body,
            includesDeviceInformation: true
        )
        guard let response = try? JSONDecoder().decode(CreateSessionResponse.self, from: data),
              let normalizedPath = Self.normalizedSessionPath(response.sessionPath)
        else {
            throw XboxCloudSessionAPIError.invalidPayload(operation: .create)
        }

        sessions[normalizedPath] = SessionRecord(baseURL: access.regionBaseURL)
        return XboxCloudSessionHandle(sessionPath: normalizedPath)
    }

    func state(
        for handle: XboxCloudSessionHandle,
        timeoutInterval: TimeInterval = XboxCloudSessionAPI.requestTimeout
    ) async throws -> XboxCloudSessionStateSnapshot {
        guard let record = sessions[handle.sessionPath] else {
            throw XboxCloudSessionAPIError.unknownSession
        }
        let url = try endpoint(baseURL: record.baseURL, sessionPath: handle.sessionPath, suffix: "state")
        let (data, response) = try await send(
            method: "GET",
            url: url,
            operation: .state,
            timeoutInterval: timeoutInterval
        )
        guard let payload = try? JSONDecoder().decode(StateResponse.self, from: data),
              !payload.state.isEmpty
        else {
            throw XboxCloudSessionAPIError.invalidPayload(operation: .state)
        }
        if let estimatedWait = payload.estimatedTotalWaitTimeInSeconds,
           !estimatedWait.isFinite || estimatedWait < 0 || estimatedWait > 86400
        {
            throw XboxCloudSessionAPIError.invalidPayload(operation: .state)
        }
        guard var currentRecord = sessions[handle.sessionPath] else {
            throw XboxCloudSessionAPIError.unknownSession
        }
        if let transferURI = payload.transferUri {
            do {
                currentRecord.baseURL = try validatedXboxCloudServiceURL(transferURI)
            } catch {
                throw XboxCloudSessionAPIError.invalidPayload(operation: .state)
            }
            sessions[handle.sessionPath] = currentRecord
        }

        return XboxCloudSessionStateSnapshot(
            state: Self.state(from: payload.state),
            estimatedTotalWaitTime: payload.estimatedTotalWaitTimeInSeconds,
            retryAfter: retryAfter(from: response),
            serviceCode: Self.sanitizedOptionalServiceValue(payload.errorDetails?.code ?? payload.code)
        )
    }

    func connect(_ handle: XboxCloudSessionHandle) async throws {
        guard let initialRecord = sessions[handle.sessionPath] else {
            throw XboxCloudSessionAPIError.unknownSession
        }
        guard !initialRecord.didConnect else { return }

        let transferToken: String
        do {
            transferToken = try await access.msaTransferToken()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw XboxCloudSessionAPIError.transferTokenUnavailable
        }
        try Task.checkCancellation()
        guard XboxCloudSessionAccessContext.isSafeCredential(transferToken) else {
            throw XboxCloudSessionAPIError.transferTokenUnavailable
        }
        guard let currentRecord = sessions[handle.sessionPath] else {
            throw XboxCloudSessionAPIError.unknownSession
        }
        let url = try endpoint(baseURL: currentRecord.baseURL, sessionPath: handle.sessionPath, suffix: "connect")
        let body = try encode(ConnectPayload(userToken: transferToken), operation: .connect)
        _ = try await send(method: "POST", url: url, operation: .connect, body: body)

        guard var latestRecord = sessions[handle.sessionPath] else {
            throw XboxCloudSessionAPIError.unknownSession
        }
        latestRecord.didConnect = true
        sessions[handle.sessionPath] = latestRecord
    }

    func configuration(for handle: XboxCloudSessionHandle) async throws -> XboxCloudSessionConfiguration {
        guard let record = sessions[handle.sessionPath] else {
            throw XboxCloudSessionAPIError.unknownSession
        }
        let url = try endpoint(
            baseURL: record.baseURL,
            sessionPath: handle.sessionPath,
            suffix: "configuration"
        )
        let (data, _) = try await send(method: "GET", url: url, operation: .configuration)
        guard let payload = try? JSONDecoder().decode(ConfigurationResponse.self, from: data),
              payload.keepAlivePulseInSeconds.isFinite,
              payload.keepAlivePulseInSeconds > 0,
              payload.keepAlivePulseInSeconds <= 3600
        else {
            throw XboxCloudSessionAPIError.invalidPayload(operation: .configuration)
        }
        try payload.serverDetails.validate()
        let overrides = try Self.normalizedOverrides(payload.clientStreamingConfigOverrides)
        return XboxCloudSessionConfiguration(
            serverDetails: payload.serverDetails,
            keepAlivePulse: payload.keepAlivePulseInSeconds,
            clientStreamingConfigOverrides: overrides
        )
    }

    /// Creates the credential-redacted signaling boundary for a provisioned
    /// session. The session actor remains the sole owner of transferred hosts,
    /// opaque paths, GS credentials, and correlation-vector sequencing.
    func signalingContext(
        for handle: XboxCloudSessionHandle
    ) throws -> XboxCloudSignalingContext {
        guard let record = sessions[handle.sessionPath] else {
            throw XboxCloudSessionAPIError.unknownSession
        }
        return try XboxCloudSignalingContext(
            endpointBaseURL: record.baseURL,
            sessionPath: handle.sessionPath,
            gsToken: access.gsToken,
            correlationVector: nextSignalingCorrelationVector(),
            routingHeader: access.routingHeader
        )
    }

    func pollUntilProvisioned(
        _ handle: XboxCloudSessionHandle,
        onState: @escaping @Sendable (XboxCloudSessionStateSnapshot) async -> Void = { _ in }
    ) async throws -> XboxCloudProvisionedSession {
        let allocationStartedAt = now()
        let hardDeadline = allocationStartedAt.addingTimeInterval(
            min(pollingPolicy.maximumElapsedTime, Self.hardAllocationCeiling)
        )
        var queueDeadline: Date?
        var provisioningRequests = 0
        var totalStateRequests = 0
        var consecutiveTransientFailures = 0

        while true {
            try Task.checkCancellation()
            let activeDeadline = queueDeadline ?? hardDeadline
            let timeoutInterval = try stateRequestTimeout(
                deadline: activeDeadline,
                provisioningRequests: provisioningRequests
            )
            let snapshot: XboxCloudSessionStateSnapshot
            do {
                snapshot = try await state(
                    for: handle,
                    timeoutInterval: timeoutInterval
                )
                consecutiveTransientFailures = 0
            } catch {
                guard Self.isTransientStatePollingError(error),
                      consecutiveTransientFailures == 0
                else {
                    throw error
                }
                consecutiveTransientFailures += 1
                xboxSessionLog.notice("Xbox state poll transient failure; retrying once")
                try await waitBeforeTransientStateRetry(
                    deadline: activeDeadline
                )
                continue
            }
            totalStateRequests += 1
            await onState(snapshot)
            try Task.checkCancellation()
            xboxSessionLog.info(
                "Xbox session state=\(Self.diagnosticName(for: snapshot.state), privacy: .public) poll=\(totalStateRequests, privacy: .public) estimateSeconds=\(Int(snapshot.estimatedTotalWaitTime ?? -1), privacy: .public)"
            )

            switch snapshot.state {
            case .provisioned:
                let sessionConfiguration = try await configuration(for: handle)
                return XboxCloudProvisionedSession(handle: handle, configuration: sessionConfiguration)
            case .readyToConnect:
                queueDeadline = nil
                provisioningRequests += 1
                let wasAlreadyConnected = sessions[handle.sessionPath]?.didConnect == true
                try await connect(handle)
                if wasAlreadyConnected {
                    try await waitBeforeNextProvisioningPoll(
                        pollingPolicy.provisioningInterval,
                        requests: provisioningRequests,
                        deadline: hardDeadline
                    )
                }
            case .waitingForResources:
                queueDeadline = Self.updatedWaitingDeadline(
                    current: queueDeadline,
                    allocationStartedAt: allocationStartedAt,
                    hardDeadline: hardDeadline,
                    estimatedTotalWaitTime: snapshot.estimatedTotalWaitTime,
                    queueInterval: pollingPolicy.queueInterval
                )
                try await waitBeforeNextQueuePoll(
                    pollingPolicy.queueInterval,
                    deadline: queueDeadline ?? hardDeadline
                )
            case .provisioning:
                queueDeadline = nil
                provisioningRequests += 1
                try await waitBeforeNextProvisioningPoll(
                    pollingPolicy.provisioningInterval,
                    requests: provisioningRequests,
                    deadline: hardDeadline
                )
            case .failed:
                throw XboxCloudSessionAPIError.sessionFailed(serviceCode: snapshot.serviceCode)
            case let .unknown(value):
                throw XboxCloudSessionAPIError.unsupportedState(value)
            }
        }
    }

    func keepAlive(_ handle: XboxCloudSessionHandle) async throws -> XboxCloudKeepAliveReceipt {
        guard let record = sessions[handle.sessionPath] else {
            throw XboxCloudSessionAPIError.unknownSession
        }
        let url = try endpoint(baseURL: record.baseURL, sessionPath: handle.sessionPath, suffix: "keepalive")
        let (data, _) = try await send(method: "POST", url: url, operation: .keepAlive)
        guard let response = try? JSONDecoder().decode(XboxCloudJSONValue.self, from: data) else {
            throw XboxCloudSessionAPIError.invalidPayload(operation: .keepAlive)
        }
        return XboxCloudKeepAliveReceipt(response: response)
    }

    func delete(_ handle: XboxCloudSessionHandle) async throws {
        guard let record = sessions[handle.sessionPath] else {
            throw XboxCloudSessionAPIError.unknownSession
        }
        let url = try endpoint(baseURL: record.baseURL, sessionPath: handle.sessionPath)
        _ = try await send(method: "DELETE", url: url, operation: .delete)
        sessions.removeValue(forKey: handle.sessionPath)
    }

    private func waitBeforeNextProvisioningPoll(
        _ requestedDelay: TimeInterval,
        requests: Int,
        deadline: Date
    ) async throws {
        guard requests < pollingPolicy.maximumStateRequests else {
            throw XboxCloudSessionAPIError.pollingTimedOut(
                maximumStateRequests: pollingPolicy.maximumStateRequests
            )
        }
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else {
            throw XboxCloudSessionAPIError.pollingTimedOut(
                maximumStateRequests: pollingPolicy.maximumStateRequests
            )
        }
        let delay = min(max(0, requestedDelay), pollingPolicy.maximumRetryAfter, remaining)
        if delay > 0 {
            try await sleep(delay)
            try Task.checkCancellation()
        }
    }

    private func stateRequestTimeout(
        deadline: Date,
        provisioningRequests: Int
    ) throws -> TimeInterval {
        guard provisioningRequests < pollingPolicy.maximumStateRequests else {
            throw XboxCloudSessionAPIError.pollingTimedOut(
                maximumStateRequests: pollingPolicy.maximumStateRequests
            )
        }
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else {
            throw XboxCloudSessionAPIError.pollingTimedOut(
                maximumStateRequests: pollingPolicy.maximumStateRequests
            )
        }
        return min(Self.requestTimeout, remaining)
    }

    private func waitBeforeTransientStateRetry(
        deadline: Date
    ) async throws {
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else {
            throw XboxCloudSessionAPIError.pollingTimedOut(
                maximumStateRequests: pollingPolicy.maximumStateRequests
            )
        }
        let delay = min(Self.transientStateRetryInterval, remaining)
        try await sleep(delay)
        try Task.checkCancellation()
    }

    private func waitBeforeNextQueuePoll(
        _ requestedDelay: TimeInterval,
        deadline: Date
    ) async throws {
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else {
            throw XboxCloudSessionAPIError.pollingTimedOut(
                maximumStateRequests: pollingPolicy.maximumStateRequests
            )
        }
        let delay = min(
            max(0, requestedDelay),
            pollingPolicy.maximumRetryAfter,
            remaining
        )
        if delay > 0 {
            try await sleep(delay)
            try Task.checkCancellation()
        }
    }

    /// Microsoft's estimate is a total allocation estimate, not an unbounded
    /// lease extension. A revised estimate may extend the soft queue deadline,
    /// but never past the absolute allocation ceiling.
    nonisolated static func updatedWaitingDeadline(
        current: Date?,
        allocationStartedAt: Date,
        hardDeadline: Date,
        estimatedTotalWaitTime: TimeInterval?,
        queueInterval: TimeInterval
    ) -> Date? {
        guard let estimatedTotalWaitTime,
              estimatedTotalWaitTime.isFinite,
              estimatedTotalWaitTime >= 0
        else {
            return current
        }
        let gracePeriod = max(
            estimatedQueueGracePeriod,
            min(queueInterval * 3, minimumAdaptiveQueueBudget)
        )
        let budget = max(
            minimumAdaptiveQueueBudget,
            estimatedTotalWaitTime + gracePeriod
        )
        let candidate = min(
            allocationStartedAt.addingTimeInterval(budget),
            hardDeadline
        )
        guard let current else { return candidate }
        return min(max(current, candidate), hardDeadline)
    }

    private func send(
        method: String,
        url: URL,
        operation: XboxCloudSessionAPIOperation,
        body: Data? = nil,
        includesDeviceInformation: Bool = false,
        timeoutInterval: TimeInterval = XboxCloudSessionAPI.requestTimeout
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        let positiveTimeout = timeoutInterval.isFinite && timeoutInterval > 0
            ? timeoutInterval
            : Self.requestTimeout
        request.timeoutInterval = min(positiveTimeout, Self.requestTimeout)
        request.httpMethod = method
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(access.gsToken)", forHTTPHeaderField: "Authorization")
        request.setValue(nextCorrelationVector(), forHTTPHeaderField: "MS-CV")
        request.setValue(access.market, forHTTPHeaderField: "x-xbl-market")
        request.setValue(
            access.routingHeader,
            forHTTPHeaderField: "X-GSSV-Routing"
        )
        // xbox-quality-beta-coverage:profile-user-agent-header:start
        if let userAgent = access.compatibilityProfile.httpUserAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        // xbox-quality-beta-coverage:profile-user-agent-header:end
        request.httpBody = body
        if includesDeviceInformation {
            try request.setValue(encodedDeviceInformation(), forHTTPHeaderField: "X-MS-Device-Info")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(
                for: request,
                maximumResponseSize: Self.maximumResponseBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch HTTPTransportError.responseTooLarge {
            throw XboxCloudSessionAPIError.responseTooLarge(operation: operation)
        } catch {
            throw XboxCloudSessionAPIError.transportFailure(operation: operation)
        }
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw XboxCloudSessionAPIError.invalidResponse(operation: operation)
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw XboxCloudSessionAPIError.httpFailure(
                operation: operation,
                statusCode: httpResponse.statusCode,
                serviceCode: Self.serviceCode(from: data)
            )
        }
        return (data, httpResponse)
    }

    private static func isTransientStatePollingError(_ error: Error) -> Bool {
        switch error as? XboxCloudSessionAPIError {
        case .transportFailure(operation: .state):
            true
        case let .httpFailure(operation: .state, statusCode, _):
            [408, 429, 500, 502, 503, 504].contains(statusCode)
        default:
            false
        }
    }

    private static func diagnosticName(for state: XboxCloudSessionState) -> String {
        switch state {
        case .waitingForResources: "WaitingForResources"
        case .readyToConnect: "ReadyToConnect"
        case .provisioning: "Provisioning"
        case .provisioned: "Provisioned"
        case .failed: "Failed"
        case .unknown: "Unknown"
        }
    }

    private func encodedDeviceInformation() throws -> String {
        let info = access.deviceInformation.applying(access.compatibilityProfile)
        let payload = DeviceInformationHeader(
            appInfo: .init(
                env: .init(
                    clientAppId: info.clientAppID,
                    clientAppType: info.clientAppType,
                    clientAppVersion: info.clientAppVersion,
                    clientSdkVersion: info.clientSDKVersion,
                    httpEnvironment: "prod",
                    sdkInstallId: info.sdkInstallID
                )
            ),
            dev: .init(
                displayInfo: .init(
                    dimensions: .init(
                        heightInPixels: info.displayHeightInPixels,
                        widthInPixels: info.displayWidthInPixels
                    ),
                    pixelDensity: .init(dpiX: info.pixelDensity, dpiY: info.pixelDensity)
                ),
                browser: .init(
                    browserName: info.browserName,
                    browserVersion: info.browserVersion
                ),
                hw: .init(
                    make: info.make,
                    model: info.model,
                    platformType: info.platformType,
                    sdkType: info.sdkType
                ),
                os: .init(
                    name: info.operatingSystemName,
                    ver: info.operatingSystemVersion,
                    platform: info.operatingSystemPlatform
                )
            )
        )
        let data = try encode(payload, operation: .create)
        guard let value = String(data: data, encoding: .utf8), value.utf8.count <= 16384 else {
            throw XboxCloudSessionAPIError.invalidAccessContext("Xbox Cloud device information is too large.")
        }
        return value
    }

    private func encode(
        _ value: some Encodable,
        operation: XboxCloudSessionAPIOperation
    ) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw XboxCloudSessionAPIError.invalidPayload(operation: operation)
        }
    }

    private func endpoint(
        baseURL: URL,
        path: String
    ) throws -> URL {
        guard let normalizedPath = Self.normalizedSessionPath(path) else {
            throw XboxCloudSessionAPIError.invalidPayload(operation: .create)
        }
        return Self.appending(path: normalizedPath, to: baseURL)
    }

    private func endpoint(
        baseURL: URL,
        sessionPath: String,
        suffix: String? = nil
    ) throws -> URL {
        guard let normalizedPath = Self.normalizedSessionPath(sessionPath),
              suffix == nil || Self.normalizedSessionPath(suffix ?? "") != nil
        else {
            throw XboxCloudSessionAPIError.invalidPayload(operation: .state)
        }
        let combinedPath = [normalizedPath, suffix].compactMap(\.self).joined(separator: "/")
        return Self.appending(path: combinedPath, to: baseURL)
    }

    private func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return min(seconds, pollingPolicy.maximumRetryAfter)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return min(max(0, date.timeIntervalSince(now())), pollingPolicy.maximumRetryAfter)
    }

    private func nextCorrelationVector() -> String {
        defer { correlationVectorSequence += 1 }
        return "\(correlationVectorBase).\(correlationVectorSequence)"
    }

    private func nextSignalingCorrelationVector() -> String {
        "\(nextCorrelationVector()).0"
    }

    private static func validatedCorrelationVectorBase(_ proposed: String?) -> String {
        if let proposed,
           (1 ... 118).contains(proposed.count),
           proposed.unicodeScalars.allSatisfy({ scalar in
               CharacterSet.alphanumerics.contains(scalar)
                   || CharacterSet(charactersIn: "+/=_-").contains(scalar)
           })
        {
            return proposed
        }
        return String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(22))
    }

    private static func normalizedSessionPath(_ path: String) -> String? {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty,
              normalized.count <= 512,
              !normalized.contains(":"),
              !normalized.contains("?"),
              !normalized.contains("#"),
              !normalized.contains("\\")
        else {
            return nil
        }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.count <= 16,
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && component.count <= 128
                      && component.unicodeScalars.allSatisfy { scalar in
                          CharacterSet.alphanumerics.contains(scalar)
                              || CharacterSet(charactersIn: "-._").contains(scalar)
                      }
              })
        else {
            return nil
        }
        return normalized
    }

    private static func appending(path: String, to baseURL: URL) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component), isDirectory: false)
        }
    }

    private static func state(from value: String) -> XboxCloudSessionState {
        switch value {
        case "WaitingForResources": .waitingForResources
        case "ReadyToConnect": .readyToConnect
        case "Provisioning": .provisioning
        case "Provisioned": .provisioned
        case "Failed": .failed
        default: .unknown(sanitizedServiceValue(value))
        }
    }

    private static func serviceCode(from data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(ServiceErrorResponse.self, from: data) else {
            return nil
        }
        return sanitizedOptionalServiceValue(payload.errorDetails?.code ?? payload.code)
    }

    private static func sanitizedOptionalServiceValue(_ value: String?) -> String? {
        guard let value else { return nil }
        return sanitizedServiceValue(value)
    }

    private static func sanitizedServiceValue(_ value: String) -> String {
        let output = String(value.prefix(128).unicodeScalars.map { scalar in
            if CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet(charactersIn: "-._:/").contains(scalar)
            {
                return Character(scalar)
            }
            return "_"
        })
        return output.isEmpty ? "unrecognized" : output
    }

    private static func normalizedOverrides(_ value: XboxCloudJSONValue?) throws -> XboxCloudJSONValue? {
        guard case let .string(raw)? = value else { return value }
        guard raw.utf8.count <= 1_048_576,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(XboxCloudJSONValue.self, from: data)
        else {
            throw XboxCloudSessionAPIError.invalidPayload(operation: .configuration)
        }
        return decoded
    }
}

private nonisolated func validatedXboxCloudServiceURL(_ rawValue: String) throws -> URL {
    let normalized: String = if rawValue.contains("://") {
        rawValue
    } else {
        "https://\(rawValue)"
    }
    guard var components = URLComponents(string: normalized),
          components.scheme?.lowercased() == "https",
          let host = components.host?.lowercased(),
          host == "xboxlive.com" || host.hasSuffix(".xboxlive.com"),
          components.user == nil,
          components.password == nil,
          components.port == nil || components.port == 443,
          components.query == nil,
          components.fragment == nil,
          components.path.isEmpty || components.path == "/"
    else {
        throw XboxCloudSessionAPIError.invalidAccessContext("Xbox Cloud service URL is invalid.")
    }
    components.scheme = "https"
    components.host = host
    components.path = ""
    guard let url = components.url else {
        throw XboxCloudSessionAPIError.invalidAccessContext("Xbox Cloud service URL is invalid.")
    }
    return url
}

private nonisolated struct CreateSessionPayload: Encodable {
    let titleId: String
    let systemUpdateGroup: String
    let settings: CreateSessionSettingsPayload
    let serverId: String
    let fallbackRegionNames: [String]
    let clientSessionId: String
}

private nonisolated struct CreateSessionSettingsPayload: Encodable {
    private enum CodingKeys: String, CodingKey {
        case nanoVersion
        case enableTextToSpeech
        case magnifier
        case highContrast
        case locale
        case useIceConnection
        case timezoneOffsetMinutes
        case sdkType
        case osName
        case enableOptionalDataCollection
    }

    let settings: XboxCloudSessionLaunchSettings
    let profile: XboxCloudSessionCompatibilityProfile

    // xbox-quality-beta-coverage:session-settings-envelope:start
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(settings.nanoVersion, forKey: .nanoVersion)
        try container.encode(
            settings.enableTextToSpeech,
            forKey: .enableTextToSpeech
        )
        if profile.launchEnvelope == .nativeTVControl || settings.magnifier {
            try container.encode(settings.magnifier, forKey: .magnifier)
        }
        try container.encode(settings.highContrast, forKey: .highContrast)
        try container.encode(settings.locale, forKey: .locale)
        try container.encode(
            settings.useIceConnection,
            forKey: .useIceConnection
        )
        try container.encode(
            settings.timezoneOffsetMinutes,
            forKey: .timezoneOffsetMinutes
        )
        try container.encode(profile.launchSDKType, forKey: .sdkType)
        try container.encode(profile.launchOSName, forKey: .osName)
        if profile.launchEnvelope == .nativeTVControl {
            try container.encode(
                settings.enableOptionalDataCollection,
                forKey: .enableOptionalDataCollection
            )
        }
    }
    // xbox-quality-beta-coverage:session-settings-envelope:end
}

private nonisolated struct CreateSessionResponse: Decodable {
    let sessionPath: String
}

private nonisolated struct StateResponse: Decodable {
    struct Details: Decodable {
        let code: String?
    }

    let state: String
    let transferUri: String?
    let estimatedTotalWaitTimeInSeconds: TimeInterval?
    let code: String?
    let errorDetails: Details?
}

private nonisolated struct ConnectPayload: Encodable {
    let userToken: String
}

private nonisolated struct ConfigurationResponse: Decodable {
    let serverDetails: XboxCloudServerDetails
    let keepAlivePulseInSeconds: TimeInterval
    let clientStreamingConfigOverrides: XboxCloudJSONValue?
}

private nonisolated struct ServiceErrorResponse: Decodable {
    struct Details: Decodable {
        let code: String?
    }

    let code: String?
    let errorDetails: Details?
}

private nonisolated struct DeviceInformationHeader: Encodable {
    struct AppInfo: Encodable {
        struct Environment: Encodable {
            let clientAppId: String
            let clientAppType: String
            let clientAppVersion: String
            let clientSdkVersion: String
            let httpEnvironment: String
            let sdkInstallId: String
        }

        let env: Environment
    }

    struct Device: Encodable {
        struct DisplayInfo: Encodable {
            struct Dimensions: Encodable {
                let heightInPixels: Int
                let widthInPixels: Int
            }

            struct PixelDensity: Encodable {
                let dpiX: Double
                let dpiY: Double
            }

            let dimensions: Dimensions
            let pixelDensity: PixelDensity
        }

        struct Browser: Encodable {
            let browserName: String
            let browserVersion: String
        }

        struct Hardware: Encodable {
            let make: String
            let model: String
            let platformType: String
            let sdkType: String
        }

        struct OperatingSystem: Encodable {
            let name: String
            let ver: String
            let platform: String
        }

        let displayInfo: DisplayInfo
        let browser: Browser
        let hw: Hardware
        let os: OperatingSystem
    }

    let appInfo: AppInfo
    let dev: Device
}
