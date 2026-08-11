import Foundation
@preconcurrency import LiveKitWebRTC

/// Opaque controller-facing identity for one server-side Xbox Cloud session.
/// The Microsoft session path remains owned by `XboxCloudSessionAPI`.
nonisolated struct XboxCloudStreamSessionToken: Hashable, Sendable, CustomStringConvertible {
    fileprivate let identifier: UUID

    init(identifier: UUID = UUID()) {
        self.identifier = identifier
    }

    /// Stable, non-service-secret identity for the concrete handle represented
    /// by this token. The real Microsoft session path never leaves the actor.
    var coordinatorSessionID: String {
        "xbox-service-\(identifier.uuidString.lowercased())"
    }

    var description: String {
        "XboxCloudStreamSessionToken(identifier: <redacted>)"
    }
}

nonisolated struct XboxCloudPreparedStream: Sendable, CustomStringConvertible {
    let configuration: XboxCloudSessionConfiguration
    let signalingContext: XboxCloudSignalingContext

    var description: String {
        "XboxCloudPreparedStream(configuration: \(configuration), signalingContext: \(signalingContext))"
    }
}

/// Testable, credential-redacted boundary around session allocation, polling,
/// configuration, signaling context creation, keepalive, and deletion.
nonisolated protocol XboxCloudSessionLifecycleServing: Sendable {
    func createSession(
        _ request: XboxCloudSessionLaunchRequest
    ) async throws -> XboxCloudStreamSessionToken

    func provisionSession(
        _ token: XboxCloudStreamSessionToken,
        onState: @escaping @Sendable (XboxCloudSessionStateSnapshot) async -> Void
    ) async throws -> XboxCloudPreparedStream

    func keepAlive(_ token: XboxCloudStreamSessionToken) async throws
    /// Returns true only when the service confirms the session is gone.
    func delete(_ token: XboxCloudStreamSessionToken) async -> Bool
}

/// One-instance adapter over `XboxCloudSessionAPI`. The map is bounded to one
/// handle because a controller constructs a fresh lifecycle for each launch.
actor XboxCloudSessionLifecycleClient: XboxCloudSessionLifecycleServing {
    private let api: XboxCloudSessionAPI
    private var handle: (token: XboxCloudStreamSessionToken, value: XboxCloudSessionHandle)?
    private var isCreatingSession = false

    init(api: XboxCloudSessionAPI) {
        self.api = api
    }

    func createSession(
        _ request: XboxCloudSessionLaunchRequest
    ) async throws -> XboxCloudStreamSessionToken {
        guard handle == nil, !isCreatingSession else {
            throw XboxCloudStreamLifecycleError.sessionAlreadyActive
        }
        isCreatingSession = true
        defer { isCreatingSession = false }
        let sessionHandle = try await api.createSession(request)
        let token = XboxCloudStreamSessionToken()
        handle = (token, sessionHandle)
        return token
    }

    func provisionSession(
        _ token: XboxCloudStreamSessionToken,
        onState: @escaping @Sendable (XboxCloudSessionStateSnapshot) async -> Void
    ) async throws -> XboxCloudPreparedStream {
        let sessionHandle = try resolvedHandle(for: token)
        let provisioned = try await api.pollUntilProvisioned(
            sessionHandle,
            onState: onState
        )
        try Task.checkCancellation()
        let signalingContext = try await api.signalingContext(for: sessionHandle)
        return XboxCloudPreparedStream(
            configuration: provisioned.configuration,
            signalingContext: signalingContext
        )
    }

    func keepAlive(_ token: XboxCloudStreamSessionToken) async throws {
        let sessionHandle = try resolvedHandle(for: token)
        _ = try await api.keepAlive(sessionHandle)
    }

    func delete(_ token: XboxCloudStreamSessionToken) async -> Bool {
        guard let current = handle else { return true }
        guard current.token == token else { return false }

        do {
            try await api.delete(current.value)
            if handle?.token == token {
                handle = nil
            }
            return true
        } catch XboxCloudSessionAPIError.unknownSession {
            if handle?.token == token {
                handle = nil
            }
            return true
        } catch let XboxCloudSessionAPIError.httpFailure(
            operation: .delete,
            statusCode,
            _
        ) where statusCode == 404 || statusCode == 410 {
            if handle?.token == token {
                handle = nil
            }
            return true
        } catch {
            return false
        }
    }

    private func resolvedHandle(
        for token: XboxCloudStreamSessionToken
    ) throws -> XboxCloudSessionHandle {
        guard let handle, handle.token == token else {
            throw XboxCloudStreamLifecycleError.unknownSession
        }
        return handle.value
    }
}

nonisolated struct XboxCloudMediaReadinessPolicy: Equatable, Sendable {
    static let standard = XboxCloudMediaReadinessPolicy(
        uncheckedMaximumChecks: 600,
        interval: 0.05
    )

    let maximumChecks: Int
    let interval: TimeInterval

    init(maximumChecks: Int, interval: TimeInterval) throws {
        guard (1 ... 2000).contains(maximumChecks),
              interval.isFinite,
              (0.01 ... 1).contains(interval)
        else {
            throw XboxCloudStreamLifecycleError.invalidPolicy
        }
        self.init(
            uncheckedMaximumChecks: maximumChecks,
            interval: interval
        )
    }

    private init(
        uncheckedMaximumChecks maximumChecks: Int,
        interval: TimeInterval
    ) {
        self.maximumChecks = maximumChecks
        self.interval = interval
    }
}

/// Minimal media boundary injected into the observable controller. Tests use a
/// lightweight fake; production uses exactly one native WebRTC peer and input
/// driver through `XboxCloudNativeStreamRuntime`.
@MainActor
protocol XboxCloudStreamRuntime: AnyObject, Sendable {
    var videoTrack: LKRTCVideoTrack? { get }
    var connectionState: XboxCloudWebRTCConnectionState { get }
    var isMediaReady: Bool { get }
    var microphoneEnabled: Bool { get }
    var diagnosticsEnabled: Bool { get }
    var rtcEventLogActive: Bool { get }

    func connect(
        configuration: XboxCloudSessionConfiguration,
        signalingContext: XboxCloudSignalingContext
    ) async throws
    func sampleStatistics() async -> XboxCloudRTCStatsSnapshot
    func recordDecodedVideoFrame()
    func setMenuToggleHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    )
    func setInputPaused(_ isPaused: Bool)
    @discardableResult func sendTextEntry(_ text: String) -> Bool
    func sendInputKeepAlive()
    func disconnect()
}

/// Owns the provider-specific data-channel lifecycle around CloudNow's shared
/// WebRTC factory, decoder, audio device, controller sampling, and haptics.
@MainActor
final class XboxCloudNativeStreamRuntime: XboxCloudStreamRuntime {
    private let transport: XboxCloudWebRTCTransport
    private let inputDriver: XboxCloudInputDriver
    private let microphoneRequested: Bool
    private let diagnostics: XboxCloudDiagnosticsConfiguration
    private let readinessPolicy: XboxCloudMediaReadinessPolicy
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    var videoTrack: LKRTCVideoTrack? {
        transport.videoTrack
    }

    var connectionState: XboxCloudWebRTCConnectionState {
        transport.state
    }

    var isMediaReady: Bool {
        transport.readiness.isReady
    }

    var microphoneEnabled: Bool {
        transport.microphoneEnabled
    }

    var diagnosticsEnabled: Bool {
        diagnostics.isEnabled
    }

    var rtcEventLogActive: Bool {
        transport.rtcEventLogActive
    }

    var microphoneRequestedForConnection: Bool {
        microphoneRequested
    }

    var rtcEventLogRequestedForConnection: Bool {
        diagnostics.isRTCEventLogEnabled
    }

    init(
        transport: XboxCloudWebRTCTransport = XboxCloudWebRTCTransport(),
        inputDriver: XboxCloudInputDriver = XboxCloudInputDriver(),
        microphoneRequested: Bool = false,
        diagnosticsEnabled: Bool = false,
        rtcEventLogRequested: Bool = false,
        readinessPolicy: XboxCloudMediaReadinessPolicy = .standard,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.transport = transport
        self.inputDriver = inputDriver
        self.microphoneRequested = microphoneRequested
        diagnostics = XboxCloudDiagnosticsPolicy.resolve(
            diagnosticsEnabled: diagnosticsEnabled,
            rtcEventLogEnabled: rtcEventLogRequested,
            allowsDiagnostics: XboxCloudDiagnosticsPolicy
                .currentBuildAllowsDiagnostics
        )
        self.readinessPolicy = readinessPolicy
        self.sleep = sleep
    }

    func connect(
        configuration: XboxCloudSessionConfiguration,
        signalingContext: XboxCloudSignalingContext
    ) async throws {
        disconnect()
        inputDriver.attach(to: transport, signalingContext: signalingContext)
        inputDriver.setPaused(false)

        do {
            try await transport.connect(
                configuration: configuration,
                signalingContext: signalingContext,
                microphoneRequested: microphoneRequested,
                rtcEventLogRequested: diagnostics.isRTCEventLogEnabled
            )
            try Task.checkCancellation()
            inputDriver.setNegotiatedOptionalChannels(
                transport.negotiatedOptionalChannels
            )
            try inputDriver.setNegotiatedInputMode(
                transport.negotiatedInputMode
            )

            for check in 0 ..< readinessPolicy.maximumChecks {
                try Task.checkCancellation()
                if transport.readiness.isReady,
                   transport.videoTrack != nil
                {
                    return
                }
                if let failure = Self.connectionFailure(from: transport.state) {
                    throw failure
                }
                guard check + 1 < readinessPolicy.maximumChecks else { break }
                try await sleep(readinessPolicy.interval)
            }
            throw XboxCloudStreamLifecycleError.mediaReadinessTimedOut
        } catch is CancellationError {
            disconnect()
            throw CancellationError()
        } catch {
            disconnect()
            throw Self.sanitizedRuntimeError(error)
        }
    }

    func disconnect() {
        inputDriver.stop()
        transport.disconnect()
    }

    func sampleStatistics() async -> XboxCloudRTCStatsSnapshot {
        await transport.sampleStatistics()
    }

    func recordDecodedVideoFrame() {
        inputDriver.setVideoFlowing()
    }

    func setMenuToggleHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) {
        inputDriver.menuToggleHandler = handler
    }

    func setInputPaused(_ isPaused: Bool) {
        inputDriver.setPaused(isPaused)
    }

    @discardableResult
    func sendTextEntry(_ text: String) -> Bool {
        inputDriver.sendTextEntry(text)
    }

    func sendInputKeepAlive() {
        inputDriver.sendKeepAlive()
    }

    private static func connectionFailure(
        from state: XboxCloudWebRTCConnectionState
    ) -> XboxCloudStreamLifecycleError? {
        switch state {
        case let .disconnected(reason):
            .mediaConnectionFailed(message: reason)
        case let .failed(message):
            .mediaConnectionFailed(message: message)
        case .idle, .preparing, .negotiating, .connecting, .connected:
            nil
        }
    }

    private static func sanitizedRuntimeError(_ error: Error) -> Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let error = error as? XboxCloudStreamLifecycleError {
            return error
        }
        if let error = error as? XboxCloudWebRTCTransportError {
            return error
        }
        if let error = error as? XboxCloudSignalingError {
            return error
        }
        if let error = error as? XboxLegacyInputCodecError {
            return error
        }
        if let error = error as? XboxModernInputCodecError {
            return error
        }
        return XboxCloudStreamLifecycleError.mediaConnectionFailed(
            message: "Xbox Cloud media could not be started."
        )
    }
}

nonisolated enum XboxCloudStreamLifecycleError: Error, Equatable, Sendable, LocalizedError {
    case invalidPolicy
    case sessionAlreadyActive
    case unknownSession
    case mediaReadinessTimedOut
    case mediaConnectionFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidPolicy:
            "Xbox Cloud stream lifecycle policy is invalid."
        case .sessionAlreadyActive:
            "An Xbox Cloud session is already active."
        case .unknownSession:
            "The Xbox Cloud session is no longer active."
        case .mediaReadinessTimedOut:
            "Xbox Cloud media did not become ready in time."
        case let .mediaConnectionFailed(message):
            message
        }
    }
}
