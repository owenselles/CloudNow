import Foundation

// MARK: - CloudMatch Headers

private func gfnHeaders(token: String, clientId: String, deviceId: String, includeOrigin: Bool = true) -> [String: String] {
    var h: [String: String] = [
        "User-Agent": NVIDIAAuth.userAgent,
        "Authorization": "GFNJWT \(token)",
        "Content-Type": "application/json",
        "nv-browser-type": "CHROME",
        "nv-client-id": clientId,
        "nv-client-streamer": "NVIDIA-CLASSIC",
        "nv-client-type": "NATIVE",
        "nv-client-version": NVIDIAAuth.gfnClientVersion,
        "nv-device-make": "UNKNOWN",
        "nv-device-model": "UNKNOWN",
        "nv-device-os": "WINDOWS",
        "nv-device-type": "DESKTOP",
        "x-device-id": deviceId,
    ]
    if includeOrigin {
        h["Origin"] = NVIDIAAuth.webOrigin
        h["Referer"] = NVIDIAAuth.webReferer
    }
    return h
}

// MARK: - CloudMatch Response Types

private struct CloudMatchResponse: Decodable {
    let requestStatus: RequestStatus?
    let session: SessionPayload?
    struct RequestStatus: Decodable {
        let statusCode: Int
        let statusDescription: String?
    }

    struct SessionPayload: Decodable {
        let sessionId: String
        let status: Int
        let gpuType: String?
        let queuePosition: Int?
        let seatSetupStep: Int?
        let seatSetupInfo: SeatSetupInfo?
        let sessionProgress: SessionProgress?
        let progressInfo: SessionProgress?
        let connectionInfo: [ConnectionInfo]?
        let iceServerConfiguration: IceServerConfig?
        let sessionControlInfo: SessionControlInfo?

        var resolvedQueuePosition: Int? {
            queuePosition ?? seatSetupInfo?.queuePosition ?? sessionProgress?.queuePosition ?? progressInfo?.queuePosition
        }

        var resolvedSeatSetupStep: Int? {
            seatSetupStep ?? seatSetupInfo?.seatSetupStep
        }

        /// Estimated time remaining for queue/setup, in milliseconds (0 when unknown).
        var resolvedSeatSetupEtaMs: Int? {
            guard let eta = seatSetupInfo?.seatSetupEta, eta > 0 else { return nil }
            return eta
        }

        struct SeatSetupInfo: Decodable {
            let queuePosition: Int?
            let seatSetupStep: Int?
            let seatSetupEta: Int?
        }

        struct SessionProgress: Decodable {
            let queuePosition: Int?
        }

        struct ConnectionInfo: Decodable {
            let usage: Int
            let ip: AnyCodableString?
            let port: Int
            let resourcePath: String?
        }

        struct IceServerConfig: Decodable {
            let iceServers: [RawIceServer]?
            struct RawIceServer: Decodable {
                let urls: AnyCodableStringArray
                let username: String?
                let credential: String?
            }
        }

        struct SessionControlInfo: Decodable {
            let ip: AnyCodableString?
        }
    }
}

/// Ad action codes sent to CloudMatch
enum AdAction: Int {
    case start = 1
    case pause = 2
    case resume = 3
    case finish = 4
    case cancel = 5
}

/// GFN API returns ip as a string, array of strings, 32-bit integer, or {"value": ...} object
private struct AnyCodableString: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        // Nested object: {"value": "80.84.170.152"} or {"value": 1345682432}
        struct Nested: Decodable { let value: AnyCodableString? }
        if let nested = try? Nested(from: decoder), let v = nested.value?.value {
            value = v
            return
        }
        // Integer IP (32-bit big-endian, e.g. 1345682432 → "80.84.170.152")
        if let intVal = try? UInt32(from: decoder) {
            let b1 = (intVal >> 24) & 0xFF
            let b2 = (intVal >> 16) & 0xFF
            let b3 = (intVal >> 8) & 0xFF
            let b4 = intVal & 0xFF
            value = "\(b1).\(b2).\(b3).\(b4)"
            return
        }
        // String array or plain string
        if let arr = try? [String](from: decoder) {
            value = arr.first
        } else {
            value = try? String(from: decoder)
        }
    }
}

private struct AnyCodableStringArray: Decodable {
    let values: [String]
    init(from decoder: Decoder) throws {
        if let arr = try? [String](from: decoder) {
            values = arr
        } else if let single = try? String(from: decoder) {
            values = [single]
        } else {
            values = []
        }
    }
}

private struct GetSessionsResponse: Decodable {
    let requestStatus: RequestStatus
    let sessions: [SessionEntry]?
    struct RequestStatus: Decodable {
        let statusCode: Int
        let statusDescription: String?
    }

    struct SessionEntry: Decodable {
        let sessionId: String
        let status: Int
        let sessionRequestData: SessionRequestData?
        let connectionInfo: [ConnEntry]?
        let sessionControlInfo: CtrlEntry?

        struct SessionRequestData: Decodable { let appId: AnyCodableString? }
        struct ConnEntry: Decodable { let ip: AnyCodableString?; let port: Int?; let usage: Int?; let resourcePath: String? }
        struct CtrlEntry: Decodable { let ip: AnyCodableString? }
    }
}

// MARK: - Session Request Body

private func resolutionPixels(for settings: StreamSettings) -> (width: Int, height: Int) {
    let resolutionParts = settings.resolution.split(separator: "x")
    let width = Int(resolutionParts.first ?? "1920") ?? 1920
    let height = Int(resolutionParts.last ?? "1080") ?? 1080
    return (width, height)
}

private func buildSessionRequestBody(_ input: SessionCreateRequest, deviceId: String) -> [String: Any] {
    let (width, height) = resolutionPixels(for: input.settings)
    let tzOffset = TimeZone.current.secondsFromGMT() * 1000
    let audioChannels = input.settings.audioFormat.resolvedChannelCount
    let color = input.settings.colorRequest(
        localCapabilities: .detect(codec: input.settings.codec),
        accountAllowsHDR: input.accountAllowsHDR
    )

    return [
        "sessionRequestData": [
            "appId": input.appId,
            "internalTitle": input.internalTitle as Any,
            "availableSupportedControllers": [],
            "networkTestSessionId": NSNull(),
            "parentSessionId": NSNull(),
            "clientIdentification": "GFN-PC",
            "deviceHashId": deviceId,
            "clientVersion": "30.0",
            "sdkVersion": "1.0",
            "streamerVersion": 1,
            "clientPlatformName": "windows",
            "clientRequestMonitorSettings": [[
                "monitorId": 0,
                "positionX": 0,
                "positionY": 0,
                "widthInPixels": width,
                "heightInPixels": height,
                "framesPerSecond": input.settings.fps,
                "sdrHdrMode": cloudMatchSdrHdrMode(color),
                "displayData": cloudMatchDisplayData(color),
                "hdr10PlusGamingData": NSNull(),
                "dpi": 100,
            ]],
            "useOps": true,
            // Channel count, like the official client (audioMode = audioChannelCount).
            // surroundAudioInfo alone only switches the TRANSPORT to multiopus; audioMode
            // configures the rig's audio endpoint — leaving it at 2 makes games render
            // stereo, so the rear channels of a negotiated 5.1 stream stay silent.
            "audioMode": audioChannels,
            "metaData": [
                ["key": "SubSessionId", "value": UUID().uuidString],
                ["key": "wssignaling", "value": "1"],
                ["key": "GSStreamerType", "value": "WebRTC"],
                ["key": "networkType", "value": "Unknown"],
                ["key": "ClientImeSupport", "value": "0"],
                ["key": "clientPhysicalResolution", "value": "{\"horizontalPixels\":\(width),\"verticalPixels\":\(height)}"],
                ["key": "surroundAudioInfo", "value": "\(audioChannels)"],
            ],
            "sdrHdrMode": cloudMatchSdrHdrMode(color),
            "clientDisplayHdrCapabilities": cloudMatchDisplayCapabilities(color),
            // GameStream encoding (channelMask << 16) | channels: 5.1 = (0x3F << 16) | 6.
            // 0 (unset) keeps the server's stereo default. Probe-verified: with 5.1 the
            // server offers multiopus/48000/6 instead of stereo opus.
            "surroundAudioInfo": audioChannels >= 6 ? 4_128_774 : 0,
            "remoteControllersBitmap": 0,
            "clientTimezoneOffset": tzOffset,
            "enhancedStreamMode": 1,
            "appLaunchMode": input.settings.appLaunchMode.cloudMatchValue,
            "secureRTSPSupported": false,
            "partnerCustomData": "",
            "accountLinked": input.accountLinked,
            "enablePersistingInGameSettings": input.settings.persistInGameSettings,
            "userAge": 26,
            "requestedStreamingFeatures": [
                "reflex": input.settings.fps >= 120,
                "bitDepth": cloudMatchBitDepth(color),
                "cloudGsync": false,
                "enabledL4S": input.settings.enableL4S,
                "profile": 0,
                "fallbackToLogicalResolution": false,
                "chromaFormat": cloudMatchChromaFormat(color),
                "prefilterMode": 0,
                "prefilterSharpness": 0,
                "prefilterNoiseReduction": 0,
                "hudStreamingMode": 0,
            ],
        ],
    ]
}

private func buildResumeSessionRequestData(appId: String?, settings: StreamSettings, deviceId: String, accountAllowsHDR: Bool?) -> [String: Any] {
    let (width, height) = resolutionPixels(for: settings)
    let audioChannels = settings.audioFormat.resolvedChannelCount
    let color = settings.colorRequest(
        localCapabilities: .detect(codec: settings.codec),
        accountAllowsHDR: accountAllowsHDR
    )
    var requestData: [String: Any] = [
        "availableSupportedControllers": [],
        "networkTestSessionId": NSNull(),
        "parentSessionId": NSNull(),
        "clientIdentification": "GFN-PC",
        "deviceHashId": deviceId,
        "clientVersion": "30.0",
        "sdkVersion": "1.0",
        "streamerVersion": 1,
        "clientPlatformName": "windows",
        "clientRequestMonitorSettings": [[
            "monitorId": 0,
            "positionX": 0,
            "positionY": 0,
            "widthInPixels": width,
            "heightInPixels": height,
            "framesPerSecond": settings.fps,
            "sdrHdrMode": cloudMatchSdrHdrMode(color),
            "displayData": cloudMatchDisplayData(color),
            "hdr10PlusGamingData": NSNull(),
            "dpi": 100,
        ]],
        "clientTimezoneOffset": TimeZone.current.secondsFromGMT() * 1000,
        "metaData": [
            ["key": "SubSessionId", "value": UUID().uuidString],
            ["key": "wssignaling", "value": "1"],
            ["key": "GSStreamerType", "value": "WebRTC"],
            ["key": "networkType", "value": "Unknown"],
            ["key": "ClientImeSupport", "value": "0"],
            ["key": "clientPhysicalResolution", "value": "{\"horizontalPixels\":\(width),\"verticalPixels\":\(height)}"],
            ["key": "surroundAudioInfo", "value": "\(audioChannels)"],
        ],
        "sdrHdrMode": cloudMatchSdrHdrMode(color),
        "clientDisplayHdrCapabilities": cloudMatchDisplayCapabilities(color),
        "surroundAudioInfo": audioChannels >= 6 ? 4_128_774 : 0,
        "appLaunchMode": settings.appLaunchMode.cloudMatchValue,
        "enablePersistingInGameSettings": settings.persistInGameSettings,
        "requestedStreamingFeatures": [
            "reflex": settings.fps >= 120,
            "bitDepth": cloudMatchBitDepth(color),
            "cloudGsync": false,
            "enabledL4S": settings.enableL4S,
            "profile": 0,
            "fallbackToLogicalResolution": false,
            "chromaFormat": cloudMatchChromaFormat(color),
            "prefilterMode": 0,
            "prefilterSharpness": 0,
            "prefilterNoiseReduction": 0,
            "hudStreamingMode": 0,
        ],
    ]
    if let appId {
        requestData["appId"] = appId
    }
    return requestData
}

private func cloudMatchSdrHdrMode(_ color: StreamColorRequest) -> Int {
    color.hdrRequested ? 1 : 0
}

private func cloudMatchBitDepth(_ color: StreamColorRequest) -> Int {
    // CloudMatch has historically used 0 for 8-bit and 1 for 10-bit in this client.
    color.bitDepth >= 10 ? 1 : 0
}

private func cloudMatchChromaFormat(_ color: StreamColorRequest) -> Int {
    // Meaning is undocumented. Preserve the known-working 4:2:0 value for SDR8, SDR10, and HDR10.
    color.chromaFormat ?? 1
}

private func cloudMatchDisplayData(_ color: StreamColorRequest) -> Any {
    guard let capabilities = color.displayCapabilities else { return NSNull() }
    return [
        "desiredContentMaxLuminance": capabilities.desiredContentMaxLuminance,
        "desiredContentMinLuminance": capabilities.desiredContentMinLuminance,
        "desiredContentMaxFrameAverageLuminance": capabilities.desiredContentMaxFrameAverageLuminance,
    ]
}

private func cloudMatchDisplayCapabilities(_ color: StreamColorRequest) -> Any {
    guard let capabilities = color.displayCapabilities else { return NSNull() }
    return [
        "version": 1,
        "hdrEdrSupportedFlagsInUint32": capabilities.hdrEdrSupportedFlags,
        "staticMetadataDescriptorId": 0,
    ]
}

// MARK: - Signaling URL Resolution

private func resolveSignalingUrl(serverIp: String, resourcePath: String) -> String {
    if resourcePath.hasPrefix("rtsps://") || resourcePath.hasPrefix("rtsp://") {
        let withoutScheme = resourcePath.hasPrefix("rtsps://")
            ? String(resourcePath.dropFirst("rtsps://".count))
            : String(resourcePath.dropFirst("rtsp://".count))
        let host = withoutScheme.components(separatedBy: ":").first?
            .components(separatedBy: "/").first ?? ""
        if !host.isEmpty, !host.hasPrefix(".") {
            return "wss://\(host)/nvst/"
        }
    }
    if resourcePath.hasPrefix("wss://") { return resourcePath }
    if resourcePath.hasPrefix("/") { return "wss://\(serverIp):443\(resourcePath)" }
    return "wss://\(serverIp):443/nvst/"
}

private func hostFromResourcePath(_ resourcePath: String?) -> String? {
    guard let resourcePath, !resourcePath.isEmpty, !resourcePath.hasPrefix("/") else { return nil }
    return URL(string: resourcePath)?.host
}

// MARK: - CloudMatchClient

actor CloudMatchClient {
    private static let defaultBase = "https://prod.cloudmatchbeta.nvidiagrid.net"

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    private func validateHTTPStatus(_ response: URLResponse, data: Data, context: String) throws {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw CloudMatchError.requestFailed(context: context, message: raw)
        }
    }

    private func validateAPIStatus(_ payload: CloudMatchResponse, context: String) throws {
        guard let status = payload.requestStatus else {
            throw CloudMatchError.apiStatus(context: context, statusCode: -1, description: "Missing requestStatus")
        }
        guard status.statusCode == 1 else {
            throw CloudMatchError.apiStatus(
                context: context,
                statusCode: status.statusCode,
                description: status.statusDescription
            )
        }
    }

    private func validateAPIStatus(_ payload: GetSessionsResponse, context: String) throws {
        guard payload.requestStatus.statusCode == 1 else {
            throw CloudMatchError.apiStatus(
                context: context,
                statusCode: payload.requestStatus.statusCode,
                description: payload.requestStatus.statusDescription
            )
        }
    }

    private func shouldRepollThroughResolvedServer(currentBase: String, resolvedServer: String) -> Bool {
        guard !resolvedServer.isEmpty,
              let currentHost = URLComponents(string: currentBase)?.host?.lowercased()
        else { return false }
        let resolvedHost = resolvedServer.lowercased()
        return currentHost != resolvedHost
    }

    // MARK: Create Session

    func createSession(_ input: SessionCreateRequest) async throws -> SessionInfo {
        let clientId = UUID().uuidString
        let deviceId = GFNDeviceIdentity.stableDeviceId()
        let preferredBase = input.streamingBaseUrl.map {
            $0.hasSuffix("/") ? String($0.dropLast()) : $0
        } ?? Self.defaultBase
        let fallbackBase = Self.defaultBase
        let requestedRoutingZoneUrl = normalizedRoutingZoneUrl(input.routingZoneUrl)

        let body = buildSessionRequestBody(input, deviceId: deviceId)
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        print("[CloudMatch] bodySize: \(bodyData.count) bytes")
        print("[CloudMatch] createSession languageCode=\(input.settings.effectiveGameLanguage) keyboardLayout=\(input.settings.keyboardLayout)")
        let headers = gfnHeaders(token: input.token, clientId: clientId, deviceId: deviceId, includeOrigin: true)
        let queryItems = [
            URLQueryItem(name: "keyboardLayout", value: input.settings.keyboardLayout),
            URLQueryItem(name: "languageCode", value: input.settings.effectiveGameLanguage),
        ]

        let bases = preferredBase == fallbackBase ? [preferredBase] : [preferredBase, fallbackBase]
        var lastError: Error?

        for base in bases {
            let params = URLComponents(string: "\(base)/v2/session")!.url!
                .appending(queryItems: queryItems)
            var request = URLRequest(url: params)
            request.httpMethod = "POST"
            for (k, v) in headers {
                request.setValue(v, forHTTPHeaderField: k)
            }
            request.setValue("\(bodyData.count)", forHTTPHeaderField: "Content-Length")
            request.httpBody = bodyData
            print("[CloudMatch] createSession POST \(params), appId=\(input.appId)")

            let (data, resp) = try await urlSession.data(for: request)
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
            print("[CloudMatch] createSession response: HTTP \(statusCode)")
            if statusCode == 200 {
                let payload = try JSONDecoder().decode(CloudMatchResponse.self, from: data)
                try validateAPIStatus(payload, context: "createSession")
                let routingZoneUrl: String? = if base == preferredBase {
                    requestedRoutingZoneUrl ?? normalizedRoutingZoneUrl(base)
                } else {
                    nil
                }
                return try toSessionInfo(
                    base: base,
                    routingZoneUrl: routingZoneUrl,
                    payload: payload,
                    rawData: data,
                    clientId: clientId,
                    deviceId: deviceId
                )
            }
            let raw = String(data: data, encoding: .utf8) ?? ""
            print("[CloudMatch] createSession failed: HTTP \(statusCode) body: \(raw.prefix(500))")
            // Clean up phantom session the server allocated despite the error
            if let errPayload = try? JSONDecoder().decode(CloudMatchResponse.self, from: data),
               let session = errPayload.session,
               !session.sessionId.isEmpty
            {
                let sid = session.sessionId
                print("[CloudMatch] cleaning phantom session \(sid)")
                try? await stopSession(
                    sessionId: sid,
                    token: input.token,
                    base: base,
                    clientId: clientId,
                    deviceId: deviceId
                )
            }
            lastError = CloudMatchError.sessionCreateFailed(raw)
        }
        throw lastError!
    }

    // MARK: Poll Session

    func pollSession(
        sessionId: String,
        token: String,
        base: String,
        serverIp: String?,
        routingZoneUrl: String? = nil,
        clientId: String,
        deviceId: String
    ) async throws -> SessionInfo {
        let effectiveBase = serverIp.map { "https://\($0)" } ?? base
        let url = URL(string: "\(effectiveBase)/v2/session/\(sessionId)")!
        var request = URLRequest(url: url)
        for (k, v) in gfnHeaders(token: token, clientId: clientId, deviceId: deviceId, includeOrigin: false) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await urlSession.data(for: request)
        try validateHTTPStatus(response, data: data, context: "pollSession")
        let payload = try JSONDecoder().decode(CloudMatchResponse.self, from: data)
        try validateAPIStatus(payload, context: "pollSession")
        let sessionInfo = try toSessionInfo(
            base: effectiveBase,
            routingZoneUrl: routingZoneUrl,
            payload: payload,
            rawData: data,
            clientId: clientId,
            deviceId: deviceId
        )
        if serverIp == nil,
           sessionInfo.status == 2 || sessionInfo.status == 3,
           shouldRepollThroughResolvedServer(currentBase: effectiveBase, resolvedServer: sessionInfo.serverIp)
        {
            return try await pollSession(
                sessionId: sessionId,
                token: token,
                base: base,
                serverIp: sessionInfo.serverIp,
                routingZoneUrl: routingZoneUrl ?? sessionInfo.zone,
                clientId: clientId,
                deviceId: deviceId
            )
        }
        return sessionInfo
    }

    // MARK: Stop Session

    func stopSession(
        sessionId: String,
        token: String,
        base: String,
        serverIp: String? = nil,
        clientId: String? = nil,
        deviceId: String? = nil
    ) async throws {
        let effectiveBase = serverIp.map { "https://\($0)" } ?? base
        let url = URL(string: "\(effectiveBase)/v2/session/\(sessionId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let lifecycleClientId = clientId ?? UUID().uuidString
        let stableDeviceId = deviceId ?? GFNDeviceIdentity.stableDeviceId()
        for (k, v) in gfnHeaders(
            token: token,
            clientId: lifecycleClientId,
            deviceId: stableDeviceId,
            includeOrigin: false
        ) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        _ = try await urlSession.data(for: request)
    }

    // MARK: Active Sessions

    func getActiveSessions(token: String, base: String) async throws -> [ActiveSessionInfo] {
        let url = URL(string: "\(base)/v2/session")!
        var request = URLRequest(url: url)
        let clientId = UUID().uuidString
        let deviceId = GFNDeviceIdentity.stableDeviceId()
        let headers = gfnHeaders(token: token, clientId: clientId, deviceId: deviceId, includeOrigin: false)
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, resp) = try await urlSession.data(for: request)
        let httpStatus = (resp as? HTTPURLResponse)?.statusCode ?? -1
        print("[CloudMatch] getActiveSessions HTTP \(httpStatus), \(data.count) bytes")
        if let raw = String(data: data, encoding: .utf8) { print("[CloudMatch] getActiveSessions raw: \(raw.prefix(500))") }
        try validateHTTPStatus(resp, data: data, context: "getActiveSessions")
        let decoded = try JSONDecoder().decode(GetSessionsResponse.self, from: data)
        try validateAPIStatus(decoded, context: "getActiveSessions")
        return (decoded.sessions ?? []).filter { $0.status == 1 || $0.status == 2 || $0.status == 3 }.map { entry in
            let appId = entry.sessionRequestData?.appId?.value
            let sigConn = entry.connectionInfo?.first { $0.usage == 14 }
            let serverIp = sigConn.flatMap { $0.ip?.value ?? hostFromResourcePath($0.resourcePath) }
                ?? entry.sessionControlInfo?.ip?.value
            let signalingUrl = serverIp.map { resolveSignalingUrl(serverIp: $0, resourcePath: sigConn?.resourcePath ?? "/nvst/") }
            return ActiveSessionInfo(
                sessionId: entry.sessionId,
                status: entry.status,
                appId: appId,
                serverIp: serverIp,
                signalingUrl: signalingUrl
            )
        }
    }

    func stopActiveSessions(matchingAppId appId: String, token: String, base: String) async {
        do {
            let activeSessions = try await getActiveSessions(token: token, base: base)
            let matches = activeSessions.filter { $0.appId == appId }
            guard !matches.isEmpty else { return }

            print("[CloudMatch] stopping \(matches.count) active session(s) for appId=\(appId)")
            for session in matches {
                try? await stopSession(
                    sessionId: session.sessionId,
                    token: token,
                    base: base,
                    serverIp: session.serverIp
                )
            }
        } catch {
            print("[CloudMatch] stopActiveSessions failed: \(error)")
        }
    }

    // MARK: Claim / Resume Session

    /// Attaches to an existing session. Sends a RESUME PUT for ready sessions (status 2/3),
    /// or returns current state for sessions still in queue (status 1).
    /// The caller should continue polling via pollSession() until the session is streaming.
    func claimSession(
        sessionId: String,
        serverIp: String,
        token: String,
        base: String,
        routingZoneUrl: String? = nil,
        clientId existingClientId: String? = nil,
        deviceId existingDeviceId: String? = nil,
        appId: String? = nil,
        settings: StreamSettings,
        accountAllowsHDR: Bool? = nil
    ) async throws -> SessionInfo {
        let clientId = existingClientId ?? UUID().uuidString
        let deviceId = existingDeviceId ?? GFNDeviceIdentity.stableDeviceId()
        let initialBase = "https://\(serverIp)"
        let preservedRoutingZoneUrl = normalizedRoutingZoneUrl(routingZoneUrl) ?? normalizedRoutingZoneUrl(base)

        // Pre-flight: get current session state
        let preflight = try await pollSession(
            sessionId: sessionId,
            token: token,
            base: initialBase,
            serverIp: nil,
            routingZoneUrl: preservedRoutingZoneUrl,
            clientId: clientId,
            deviceId: deviceId
        )

        // If still queuing, return as-is — caller polls from here
        if preflight.status == 1 || preflight.isInQueue { return preflight }

        // Status 2 or 3: send RESUME PUT
        let resumeBase = preflight.streamingBaseUrl
        var comps = URLComponents(string: "\(resumeBase)/v2/session/\(sessionId)")!
        comps.queryItems = [
            URLQueryItem(name: "keyboardLayout", value: settings.keyboardLayout),
            URLQueryItem(name: "languageCode", value: settings.effectiveGameLanguage),
        ]
        print("[CloudMatch] claimSession languageCode=\(settings.effectiveGameLanguage) keyboardLayout=\(settings.keyboardLayout)")
        guard let url = comps.url else { throw CloudMatchError.sessionCreateFailed("Invalid resume URL") }
        let body: [String: Any] = [
            "action": 2,
            "data": "RESUME",
            "sessionRequestData": buildResumeSessionRequestData(appId: appId, settings: settings, deviceId: deviceId, accountAllowsHDR: accountAllowsHDR),
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (k, v) in gfnHeaders(token: token, clientId: clientId, deviceId: deviceId, includeOrigin: true) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await urlSession.data(for: request)
        try validateHTTPStatus(resp, data: data, context: "claimSession")
        let payload = try JSONDecoder().decode(CloudMatchResponse.self, from: data)
        try validateAPIStatus(payload, context: "claimSession")
        return try toSessionInfo(
            base: resumeBase,
            routingZoneUrl: preflight.zone,
            payload: payload,
            rawData: data,
            clientId: clientId,
            deviceId: deviceId
        )
    }

    // MARK: Private

    private func toSessionInfo(
        base: String,
        routingZoneUrl: String?,
        payload: CloudMatchResponse,
        rawData: Data,
        clientId: String,
        deviceId: String
    ) throws -> SessionInfo {
        guard let s = payload.session else {
            throw CloudMatchError.missingSession(context: "CloudMatch response")
        }
        let connections = s.connectionInfo ?? []
        let connInfoLog = connections.map { c -> String in
            let ipStr = c.ip.map { $0.value ?? "value_nil" } ?? "field_nil"
            return "usage=\(c.usage) ip=\(ipStr) port=\(c.port) path=\(c.resourcePath ?? "nil")"
        }.joined(separator: " | ")
        print("[CloudMatch] connectionInfo: \(connInfoLog)")

        // Diagnostic raw JSON dump (once per active session — status==2 or 3)
        if s.status == 2 || s.status == 3,
           let root = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
           let sess = root["session"] as? [String: Any]
        {
            if let iceConfig = sess["iceServerConfiguration"] {
                if let iceData = try? JSONSerialization.data(withJSONObject: iceConfig, options: .prettyPrinted),
                   let iceStr = String(data: iceData, encoding: .utf8)
                {
                    print("[CloudMatch] iceServerConfiguration:\n\(iceStr)")
                } else {
                    print("[CloudMatch] iceServerConfiguration: \(iceConfig)")
                }
            } else {
                print("[CloudMatch] iceServerConfiguration: absent")
            }
            if let sci = sess["sessionControlInfo"] {
                print("[CloudMatch] sessionControlInfo: \(sci)")
            }
        }

        // Signaling server: usage=14
        let sigConn = connections.first { $0.usage == 14 }
        let serverIp = sigConn.flatMap { serverHost(from: $0) }
            ?? s.sessionControlInfo?.ip?.value
            ?? ""
        let resourcePath = sigConn?.resourcePath ?? "/nvst/"
        let signalingUrl = resolveSignalingUrl(serverIp: serverIp, resourcePath: resourcePath)

        // ICE servers
        let rawIceServers = s.iceServerConfiguration?.iceServers ?? []
        let iceServers = rawIceServers.isEmpty
            ? defaultIceServers()
            : rawIceServers.map { IceServer(urls: $0.urls.values, username: $0.username, credential: $0.credential) }

        let media = mediaConnectionInfo(from: connections, fallbackServerIp: serverIp)
        print("[CloudMatch] mediaConnectionInfo: \(media.map { "\($0.ip):\($0.port)" } ?? "nil")")

        // Ad state — parse raw JSON for flexibility since ad schema varies
        let adState = extractAdState(from: rawData)

        return SessionInfo(
            sessionId: s.sessionId,
            status: s.status,
            zone: normalizedRoutingZoneUrl(routingZoneUrl) ?? "",
            streamingBaseUrl: base,
            serverIp: serverIp,
            signalingServer: serverIp.contains(":") ? serverIp : "\(serverIp):443",
            signalingUrl: signalingUrl,
            gpuType: s.gpuType,
            queuePosition: s.resolvedQueuePosition,
            seatSetupStep: s.resolvedSeatSetupStep,
            seatSetupEtaMs: s.resolvedSeatSetupEtaMs,
            iceServers: iceServers,
            mediaConnectionInfo: media,
            clientId: clientId,
            deviceId: deviceId,
            adState: adState
        )
    }

    private func normalizedRoutingZoneUrl(_ url: String?) -> String? {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              let host = components.host?.lowercased(),
              host.hasPrefix("np-"),
              host.hasSuffix(".nvidiagrid.net")
        else {
            return nil
        }
        return "\(scheme)://\(host)/"
    }

    /// Parses ad state from the raw response JSON, handling schema variations across GFN API versions.
    private func extractAdState(from data: Data) -> SessionAdState? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionObj = root["session"] as? [String: Any] else { return nil }

        /// isAdsRequired lives in several possible places
        func bool(_ key: String, in obj: [String: Any]) -> Bool? {
            guard let v = obj[key] else { return nil }
            if let b = v as? Bool { return b }
            if let i = v as? Int { return i != 0 }
            return nil
        }

        let isAdsRequired = bool("sessionAdsRequired", in: sessionObj)
            ?? bool("isAdsRequired", in: sessionObj)
            ?? bool("isAdsRequired", in: (sessionObj["sessionProgress"] as? [String: Any]) ?? [:])
            ?? bool("isAdsRequired", in: (sessionObj["progressInfo"] as? [String: Any]) ?? [:])
            ?? false

        let isQueuePaused = bool("isQueuePaused", in: sessionObj)
            ?? bool("queuePaused", in: (sessionObj["opportunity"] as? [String: Any]) ?? [:])

        let gracePeriodSeconds = (sessionObj["opportunity"] as? [String: Any])?["gracePeriodSeconds"] as? Int

        let message = (sessionObj["opportunity"] as? [String: Any]).flatMap {
            ($0["message"] ?? $0["description"]) as? String
        }

        let adsRaw = sessionObj["sessionAds"] as? [[String: Any]] ?? []
        let ads: [SessionAdInfo] = adsRaw.enumerated().compactMap { idx, ad in
            let adId = (ad["adId"] as? String) ?? "ad-\(idx + 1)"
            let mediaFiles = (ad["adMediaFiles"] as? [[String: Any]] ?? []).compactMap { f -> SessionAdMediaFile? in
                let url = f["mediaFileUrl"] as? String
                let profile = f["encodingProfile"] as? String
                guard url != nil || profile != nil else { return nil }
                return SessionAdMediaFile(mediaFileUrl: url, encodingProfile: profile)
            }.sorted {
                adMediaPreference($0.encodingProfile) < adMediaPreference($1.encodingProfile)
            }
            let adUrl = ad["adUrl"] as? String
            let mediaUrl = (ad["mediaUrl"] ?? ad["videoUrl"] ?? ad["url"]) as? String
            let lengthSeconds = doubleValue("adLengthInSeconds", in: ad)
                ?? doubleValue("durationMs", in: ad).map { $0 / 1000 }
                ?? doubleValue("durationInMs", in: ad).map { $0 / 1000 }
            return SessionAdInfo(adId: adId, adUrl: adUrl, mediaUrl: mediaUrl,
                                 adMediaFiles: mediaFiles, adLengthInSeconds: lengthSeconds)
        }

        // Only return an ad state if there's actually something to act on
        if !isAdsRequired, ads.isEmpty, isQueuePaused != true { return nil }

        return SessionAdState(
            isAdsRequired: isAdsRequired,
            isQueuePaused: isQueuePaused,
            gracePeriodSeconds: gracePeriodSeconds,
            message: message,
            ads: ads
        )
    }

    private func doubleValue(_ key: String, in obj: [String: Any]) -> Double? {
        if let number = obj[key] as? NSNumber { return number.doubleValue }
        if let string = obj[key] as? String { return Double(string) }
        return nil
    }

    private func adMediaPreference(_ profile: String?) -> Int {
        let profile = profile?.lowercased() ?? ""
        if profile.contains("mp4deinterlaced720p") { return 0 }
        if profile.contains("webm") { return 1 }
        if profile.contains("hlsadaptive") { return 2 }
        return 3
    }

    // MARK: Report Ad Event

    func reportAdEvent(
        sessionId: String,
        token: String,
        base: String,
        serverIp: String?,
        clientId: String,
        deviceId: String,
        adId: String,
        action: AdAction,
        watchedTimeMs: Int? = nil,
        pausedTimeMs: Int? = nil
    ) async {
        let effectiveBase = serverIp.map { "https://\($0)" } ?? base
        guard let url = URL(string: "\(effectiveBase)/v2/session/\(sessionId)") else { return }
        var adUpdate: [String: Any] = [
            "adId": adId,
            "adAction": action.rawValue,
            "clientTimestamp": Int(Date().timeIntervalSince1970),
        ]
        if let ms = watchedTimeMs { adUpdate["watchedTimeInMs"] = max(0, ms) }
        if let ms = pausedTimeMs { adUpdate["pausedTimeInMs"] = max(0, ms) }
        let body: [String: Any] = ["action": 6, "adUpdates": [adUpdate]]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (k, v) in gfnHeaders(token: token, clientId: clientId, deviceId: deviceId, includeOrigin: true) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = bodyData
        _ = try? await urlSession.data(for: request)
    }

    private func serverHost(from conn: CloudMatchResponse.SessionPayload.ConnectionInfo) -> String? {
        conn.ip?.value ?? hostFromResourcePath(conn.resourcePath)
    }

    private func mediaConnectionInfo(
        from connections: [CloudMatchResponse.SessionPayload.ConnectionInfo],
        fallbackServerIp: String
    ) -> MediaConnectionInfo? {
        if let usage2 = connections.first(where: { $0.usage == 2 }),
           let media = mediaConnectionInfo(from: usage2, fallbackServerIp: nil)
        {
            return media
        }
        if let usage17 = connections.first(where: { $0.usage == 17 }),
           let media = mediaConnectionInfo(from: usage17, fallbackServerIp: nil)
        {
            return media
        }

        return connections
            .filter { $0.usage == 14 }
            .compactMap { mediaConnectionInfo(from: $0, fallbackServerIp: fallbackServerIp) }
            .max(by: { $0.port < $1.port })
    }

    private func mediaConnectionInfo(
        from conn: CloudMatchResponse.SessionPayload.ConnectionInfo,
        fallbackServerIp: String?
    ) -> MediaConnectionInfo? {
        guard conn.port > 0 else { return nil }
        guard let host = conn.ip?.value
            ?? hostFromResourcePath(conn.resourcePath)
            ?? (conn.usage == 14 ? fallbackServerIp : nil),
            !host.isEmpty
        else {
            return nil
        }
        return MediaConnectionInfo(ip: extractIpFromDashHost(host) ?? host, port: conn.port)
    }

    /// Extracts a dotted-decimal IP from a dash-encoded hostname label.
    /// "80-84-170-153.cloudmatchbeta.nvidiagrid.net" → "80.84.170.153"
    private func extractIpFromDashHost(_ host: String) -> String? {
        let label = host.components(separatedBy: ".").first ?? host
        let parts = label.components(separatedBy: "-")
        guard parts.count == 4,
              parts.allSatisfy({ Int($0) != nil && (Int($0)! >= 0) && (Int($0)! <= 255) })
        else { return nil }
        return parts.joined(separator: ".")
    }

    private func defaultIceServers() -> [IceServer] {
        [
            IceServer(urls: ["stun:s1.stun.gamestream.nvidia.com:19308"], username: nil, credential: nil),
            IceServer(urls: ["stun:stun.l.google.com:19302"], username: nil, credential: nil),
        ]
    }
}

// MARK: - Errors

enum CloudMatchError: Error, LocalizedError {
    case sessionCreateFailed(String)
    case missingServerIp
    case missingSession(context: String)
    case requestFailed(context: String, message: String)
    case apiStatus(context: String, statusCode: Int, description: String?)

    var errorDescription: String? {
        switch self {
        case let .sessionCreateFailed(msg): "Session creation failed: \(msg)"
        case .missingServerIp: "CloudMatch response missing server IP."
        case let .missingSession(context): "\(context) missing session data."
        case let .requestFailed(context, message): "\(context) failed: \(message)"
        case let .apiStatus(context, statusCode, description):
            "\(context) rejected by CloudMatch: statusCode=\(statusCode) \(description ?? "")"
        }
    }
}
