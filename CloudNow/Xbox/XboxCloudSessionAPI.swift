import Foundation

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
    let msaTransferToken: @Sendable () async throws -> String

    init(
        gsToken: String,
        regionBaseURL: URL,
        market: String,
        fallbackRegionNames: [String],
        systemUpdateGroups: [String],
        routingHeader: String = "AFD",
        deviceInformation: XboxCloudDeviceInformation = .cloudNowTV(),
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
        self.msaTransferToken = msaTransferToken
    }

    var description: String {
        "XboxCloudSessionAccessContext(gsToken: <redacted>, region: \(regionBaseURL.host ?? "unknown"), market: \(market), fallbackRegions: \(fallbackRegionNames.count), systemUpdateGroups: \(systemUpdateGroups.count), msaTransferToken: <redacted>)"
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
    let displayWidthInPixels: Int
    let displayHeightInPixels: Int
    let pixelDensity: Double

    static func cloudNowTV(
        sdkInstallID: String = UUID().uuidString,
        displayWidthInPixels: Int = 1920,
        displayHeightInPixels: Int = 1080,
        pixelDensity: Double = 1
    ) -> Self {
        Self(
            clientAppID: "CloudNow",
            clientAppType: "native",
            clientAppVersion: "1",
            clientSDKVersion: "1",
            sdkInstallID: sdkInstallID,
            make: "Apple",
            model: "Apple TV",
            platformType: "tvOS",
            sdkType: "native",
            operatingSystemName: "tvOS",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
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
        return (0 ... 65535).contains(value)
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
    private struct SessionRecord {
        var baseURL: URL
        var didConnect = false
    }

    private let access: XboxCloudSessionAccessContext
    private let transport: any HTTPTransport
    private let pollingPolicy: XboxCloudSessionPollingPolicy
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let correlationVectorBase: String
    private var correlationVectorSequence = 0
    private var sessions: [String: SessionRecord] = [:]

    init(
        access: XboxCloudSessionAccessContext,
        transport: any HTTPTransport = URLSessionHTTPTransport(configuration: .ephemeral),
        pollingPolicy: XboxCloudSessionPollingPolicy = .standard,
        correlationVectorBase: String? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.access = access
        self.transport = transport
        self.pollingPolicy = pollingPolicy
        self.correlationVectorBase = Self.validatedCorrelationVectorBase(correlationVectorBase)
        self.now = now
        self.sleep = sleep
    }

    func createSession(_ launch: XboxCloudSessionLaunchRequest) async throws -> XboxCloudSessionHandle {
        try launch.settings.validate()
        let selectedSystemUpdateGroup: String = if let requested = launch.preferredSystemUpdateGroup,
                                                   access.systemUpdateGroups.contains(requested)
        {
            requested
        } else {
            ""
        }
        let payload = CreateSessionPayload(
            titleId: launch.titleID,
            systemUpdateGroup: selectedSystemUpdateGroup,
            settings: launch.settings,
            serverId: "",
            fallbackRegionNames: access.fallbackRegionNames,
            clientSessionId: launch.clientSessionID
        )
        let body = try encode(payload, operation: .create)
        let url = try endpoint(baseURL: access.regionBaseURL, path: "v5/sessions/cloud/play")
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

    func state(for handle: XboxCloudSessionHandle) async throws -> XboxCloudSessionStateSnapshot {
        guard let record = sessions[handle.sessionPath] else {
            throw XboxCloudSessionAPIError.unknownSession
        }
        let url = try endpoint(baseURL: record.baseURL, sessionPath: handle.sessionPath, suffix: "state")
        let (data, response) = try await send(method: "GET", url: url, operation: .state)
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
        let startedAt = now()
        var requests = 0

        while true {
            try Task.checkCancellation()
            guard requests < pollingPolicy.maximumStateRequests,
                  now().timeIntervalSince(startedAt) < pollingPolicy.maximumElapsedTime
            else {
                throw XboxCloudSessionAPIError.pollingTimedOut(
                    maximumStateRequests: pollingPolicy.maximumStateRequests
                )
            }

            let snapshot = try await state(for: handle)
            requests += 1
            await onState(snapshot)

            switch snapshot.state {
            case .provisioned:
                let sessionConfiguration = try await configuration(for: handle)
                return XboxCloudProvisionedSession(handle: handle, configuration: sessionConfiguration)
            case .readyToConnect:
                try await connect(handle)
                try await waitBeforeNextPoll(
                    snapshot.retryAfter ?? 0,
                    requests: requests,
                    startedAt: startedAt
                )
            case .waitingForResources:
                try await waitBeforeNextPoll(
                    snapshot.retryAfter ?? pollingPolicy.queueInterval,
                    requests: requests,
                    startedAt: startedAt
                )
            case .provisioning:
                try await waitBeforeNextPoll(
                    snapshot.retryAfter ?? pollingPolicy.provisioningInterval,
                    requests: requests,
                    startedAt: startedAt
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

    private func waitBeforeNextPoll(
        _ requestedDelay: TimeInterval,
        requests: Int,
        startedAt: Date
    ) async throws {
        guard requests < pollingPolicy.maximumStateRequests else {
            throw XboxCloudSessionAPIError.pollingTimedOut(
                maximumStateRequests: pollingPolicy.maximumStateRequests
            )
        }
        let elapsed = now().timeIntervalSince(startedAt)
        let remaining = pollingPolicy.maximumElapsedTime - elapsed
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

    private func send(
        method: String,
        url: URL,
        operation: XboxCloudSessionAPIOperation,
        body: Data? = nil,
        includesDeviceInformation: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
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
        request.httpBody = body
        if includesDeviceInformation {
            try request.setValue(encodedDeviceInformation(), forHTTPHeaderField: "X-MS-Device-Info")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
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

    private func encodedDeviceInformation() throws -> String {
        let info = access.deviceInformation
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
                browser: .init(browserName: "CloudNow", browserVersion: info.clientAppVersion),
                hw: .init(
                    make: info.make,
                    model: info.model,
                    platformType: info.platformType,
                    sdkType: info.sdkType
                ),
                os: .init(
                    name: info.operatingSystemName,
                    ver: info.operatingSystemVersion,
                    platform: info.platformType
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
    let settings: XboxCloudSessionLaunchSettings
    let serverId: String
    let fallbackRegionNames: [String]
    let clientSessionId: String
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
