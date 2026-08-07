@testable import CloudNow
import Foundation
@preconcurrency import LiveKitWebRTC
import Testing

@Suite("Xbox Cloud stream controller")
@MainActor
struct XboxCloudStreamControllerTests {
    @Test("Xbox settings stay separate, bounded, and resilient")
    func xboxSettings() throws {
        let defaults = try JSONDecoder().decode(
            XboxCloudStreamSettings.self,
            from: Data("{}".utf8)
        )
        #expect(defaults == XboxCloudStreamSettings())

        let settings = XboxCloudStreamSettings(
            displayResolution: .qhd,
            codecPreference: .h265,
            gameLanguage: "fr_FR",
            controllerDeadzone: 4,
            rumbleIntensity: -2,
            enableTextToSpeech: true,
            magnifier: true,
            highContrast: true,
            enableOptionalDataCollection: true
        )
        #expect(settings.controllerDeadzone == 0.95)
        #expect(settings.rumbleIntensity == 0)
        let roundTrip = try JSONDecoder().decode(
            XboxCloudStreamSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(roundTrip == settings)
        #expect(roundTrip.displayResolution == .qhd)
        #expect(roundTrip.codecPreference == .h265)
        #expect(roundTrip.effectiveGameLanguage(defaultLocale: "en-US") == "fr-FR")

        let futureValues = try JSONDecoder().decode(
            XboxCloudStreamSettings.self,
            from: Data(#"{"displayResolution":"future","codecPreference":"future"}"#.utf8)
        )
        #expect(futureValues.displayResolution == .automatic)
        #expect(futureValues.codecPreference == .automatic)
        #expect(
            futureValues.effectiveGameLanguage(defaultLocale: "de-DE") == "de-DE"
        )
    }

    @Test("Xbox quality capabilities preserve unknown membership and gate 1440p")
    func xboxQualityCapabilities() {
        let unknown = XboxCloudStreamCapabilities.resolved(
            for: nil,
            isMembershipKnown: false
        )
        #expect(unknown.resolutions.contains(.qhd))
        #expect(
            unknown.normalized(
                XboxCloudStreamSettings(displayResolution: .qhd)
            ).displayResolution == .qhd
        )

        let ultimate = XboxCloudStreamCapabilities.resolved(
            for: .ultimate,
            isMembershipKnown: true
        )
        #expect(ultimate.resolutions == [.automatic, .hd, .fullHD, .qhd])

        let pcGamePass = XboxCloudStreamCapabilities.resolved(
            for: .pcGamePass,
            isMembershipKnown: true
        )
        #expect(pcGamePass.resolutions == [.automatic, .hd, .fullHD])
        #expect(
            pcGamePass.normalized(
                XboxCloudStreamSettings(displayResolution: .qhd)
            ).displayResolution == .automatic
        )
    }

    @Test("Start composes access, allocation, media, settings, and teardown")
    func successfulLifecycle() async throws {
        let lifecycle = try XboxStreamLifecycleStub()
        let runtime = XboxStreamRuntimeStub()
        let lifecycleFactory = XboxLifecycleFactoryStub([lifecycle])
        let runtimeFactory = XboxRuntimeFactoryStub([runtime])
        let controller = makeController(
            lifecycleFactory: lifecycleFactory,
            runtimeFactory: runtimeFactory
        )
        let settings = XboxCloudStreamSettings(
            displayResolution: .qhd,
            controllerDeadzone: 0.24,
            rumbleEnabled: false,
            rumbleIntensity: 0.4,
            enableTextToSpeech: true,
            magnifier: true,
            highContrast: true,
            enableOptionalDataCollection: true
        )

        try await controller.start(
            gameID: "fixture-title",
            account: Self.account,
            locale: "en-US",
            settings: settings
        )

        #expect(controller.state == .streaming)
        #expect(controller.activeGameID == "fixture-title")
        #expect(controller.videoTrack === runtime.videoTrack)
        #expect(runtimeFactory.receivedSettings == [settings])
        let access = try #require(lifecycleFactory.receivedAccess.first)
        #expect(access.deviceInformation.displayWidthInPixels == 2560)
        #expect(access.deviceInformation.displayHeightInPixels == 1440)
        let request = try #require(await lifecycle.requests().first)
        #expect(request.titleID == "fixture-title")
        #expect(request.settings.locale == "en-US")
        #expect(request.settings.timezoneOffsetMinutes == 120)
        #expect(request.settings.enableTextToSpeech)
        #expect(request.settings.magnifier)
        #expect(request.settings.highContrast == 1)
        #expect(request.settings.enableOptionalDataCollection)

        await controller.stop()

        #expect(controller.state == .idle)
        #expect(controller.videoTrack == nil)
        #expect(controller.activeGameID == nil)
        #expect(runtime.disconnectCount == 1)
        #expect(await lifecycle.deleteCount() == 1)
    }

    @Test("A replacement launch releases the previous provider runtime first")
    func replacementLaunch() async throws {
        let firstLifecycle = try XboxStreamLifecycleStub()
        let secondLifecycle = try XboxStreamLifecycleStub()
        let firstRuntime = XboxStreamRuntimeStub()
        let secondRuntime = XboxStreamRuntimeStub()
        let controller = makeController(
            lifecycleFactory: XboxLifecycleFactoryStub([
                firstLifecycle,
                secondLifecycle,
            ]),
            runtimeFactory: XboxRuntimeFactoryStub([
                firstRuntime,
                secondRuntime,
            ])
        )

        try await controller.start(
            gameID: "first-title",
            account: Self.account,
            locale: "en-US",
            settings: XboxCloudStreamSettings()
        )
        try await controller.start(
            gameID: "second-title",
            account: Self.account,
            locale: "en-US",
            settings: XboxCloudStreamSettings()
        )

        #expect(firstRuntime.disconnectCount == 1)
        #expect(await firstLifecycle.deleteCount() == 1)
        #expect(secondRuntime.connectCount == 1)
        #expect(await secondLifecycle.deleteCount() == 0)
        #expect(controller.activeGameID == "second-title")
        #expect(controller.videoTrack === secondRuntime.videoTrack)

        await controller.stop()
    }

    @Test("Cancellation during provisioning deletes outside the cancelled task")
    func cancellationCleanup() async throws {
        let entered = XboxStreamAsyncLatch()
        let release = XboxStreamAsyncLatch()
        let lifecycle = try XboxStreamLifecycleStub(
            provisionBehavior: .suspended(entered: entered, release: release)
        )
        let controller = makeController(
            lifecycleFactory: XboxLifecycleFactoryStub([lifecycle]),
            runtimeFactory: XboxRuntimeFactoryStub([XboxStreamRuntimeStub()])
        )
        let startTask = Task { @MainActor in
            try await controller.start(
                gameID: "fixture-title",
                account: Self.account,
                locale: "en-US",
                settings: XboxCloudStreamSettings()
            )
        }
        await entered.wait()

        startTask.cancel()
        await release.signal()

        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }
        #expect(controller.state == .idle)
        #expect(await lifecycle.deleteCancellationStates() == [false])
    }

    @Test("Unknown failures are redacted and post-create sessions are deleted")
    func redactedFailure() async throws {
        let secret = "fixture-private-token"
        let lifecycle = try XboxStreamLifecycleStub(
            provisionBehavior: .failure(message: secret)
        )
        let controller = makeController(
            lifecycleFactory: XboxLifecycleFactoryStub([lifecycle]),
            runtimeFactory: XboxRuntimeFactoryStub([XboxStreamRuntimeStub()])
        )

        do {
            try await controller.start(
                gameID: "fixture-title",
                account: Self.account,
                locale: "en-US",
                settings: XboxCloudStreamSettings()
            )
            Issue.record("Expected Xbox Cloud launch to fail")
        } catch {
            #expect(!error.localizedDescription.contains(secret))
            #expect(error.localizedDescription == "Xbox Cloud streaming could not be started.")
        }

        guard case let .failed(message) = controller.state else {
            Issue.record("Expected a failed controller state")
            return
        }
        #expect(!message.contains(secret))
        #expect(await lifecycle.deleteCount() == 1)
        #expect(controller.activeGameID == nil)
    }

    @Test("Repeated keepalive failure tears down media and server state")
    func keepAliveFailure() async throws {
        let keepAliveThreshold = XboxStreamAsyncLatch()
        let lifecycle = try XboxStreamLifecycleStub(
            keepAliveFails: true,
            keepAliveThreshold: 2,
            keepAliveThresholdReached: keepAliveThreshold
        )
        let runtime = XboxStreamRuntimeStub()
        let policy = try XboxCloudStreamControllerPolicy(
            maximumConsecutiveKeepAliveFailures: 2,
            minimumKeepAliveInterval: 0.01,
            maximumKeepAliveInterval: 3600,
            mediaMonitorInterval: 5
        )
        let controller = makeController(
            lifecycleFactory: XboxLifecycleFactoryStub([lifecycle]),
            runtimeFactory: XboxRuntimeFactoryStub([runtime]),
            policy: policy,
            keepAliveSleep: { _ in await Task.yield() }
        )

        try await controller.start(
            gameID: "fixture-title",
            account: Self.account,
            locale: "en-US",
            settings: XboxCloudStreamSettings()
        )
        await keepAliveThreshold.wait()
        let didFail = await waitUntil {
            if case .failed = controller.state {
                return true
            }
            return false
        }

        #expect(didFail)
        #expect(runtime.disconnectCount == 1)
        #expect(await lifecycle.deleteCount() == 1)
        #expect(controller.videoTrack == nil)
    }

    @Test("Session heartbeat also keeps the idle input channel active")
    func keepAlivePulsesInputChannel() async throws {
        let lifecycle = try XboxStreamLifecycleStub()
        let runtime = XboxStreamRuntimeStub()
        let sleep = XboxStreamOneImmediateSleep()
        let controller = makeController(
            lifecycleFactory: XboxLifecycleFactoryStub([lifecycle]),
            runtimeFactory: XboxRuntimeFactoryStub([runtime]),
            keepAliveSleep: { _ in try await sleep.call() }
        )

        try await controller.start(
            gameID: "fixture-title",
            account: Self.account,
            locale: "en-US",
            settings: XboxCloudStreamSettings()
        )

        let didPulseInput = await waitUntil {
            runtime.inputKeepAliveCount == 1
        }
        #expect(didPulseInput)

        await controller.stop()
    }

    private func makeController(
        lifecycleFactory: XboxLifecycleFactoryStub,
        runtimeFactory: XboxRuntimeFactoryStub,
        policy: XboxCloudStreamControllerPolicy = .standard,
        keepAliveSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in
            try await Task.sleep(for: .seconds(60))
        }
    ) -> XboxCloudStreamController {
        XboxCloudStreamController(
            sessionProvider: XboxStreamSessionProviderStub(session: Self.gsSession),
            transferToken: { "fixture-transfer-token" },
            makeSessionLifecycle: { access in
                lifecycleFactory.make(access: access)
            },
            makeRuntime: { settings in
                runtimeFactory.make(settings: settings)
            },
            policy: policy,
            timezoneOffsetMinutes: { 120 },
            keepAliveSleep: keepAliveSleep,
            monitorSleep: { _ in
                try await Task.sleep(for: .seconds(60))
            }
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0 ..< 1000 {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }

    private nonisolated static let account = XboxCloudAuthorizedAccount(
        authorizationIdentifier: "fixture-account",
        displayName: "Player",
        expiresAt: .distantFuture
    )

    private nonisolated static let gsSession: XboxCloudGSSession = {
        let region = XboxCloudGSRegion(
            name: "West US",
            baseURL: URL(string: "https://region.gssv-play-prod.xboxlive.com")!,
            isDefault: true,
            fallbackPriority: 0,
            systemUpdateGroups: []
        )
        return XboxCloudGSSession(
            gsToken: "fixture-gs-token",
            offeringID: "xgpuweb",
            market: "US",
            regions: [region],
            defaultRegion: region,
            fallbackRegionNames: [],
            expiresAt: .distantFuture
        )
    }()
}

private actor XboxStreamSessionProviderStub: XboxCloudGSSessionProviding {
    let value: XboxCloudGSSession

    init(session: XboxCloudGSSession) {
        value = session
    }

    func session(
        for _: XboxCloudAuthorizedAccount
    ) async throws -> XboxCloudGSSession {
        value
    }

    func removeSession(for _: XboxCloudAuthorizedAccount) async {}
    func clearSessions() async {}
}

private actor XboxStreamAsyncLatch {
    private var isSignaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let waiting = continuations
        continuations.removeAll(keepingCapacity: false)
        waiting.forEach { $0.resume() }
    }
}

private actor XboxStreamOneImmediateSleep {
    private var callCount = 0

    func call() async throws {
        callCount += 1
        guard callCount > 1 else { return }
        try await Task.sleep(for: .seconds(60))
    }
}

private enum XboxStreamProvisionBehavior: Sendable {
    case immediate
    case suspended(entered: XboxStreamAsyncLatch, release: XboxStreamAsyncLatch)
    case failure(message: String)
}

private struct XboxStreamFixtureError: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

private actor XboxStreamLifecycleStub: XboxCloudSessionLifecycleServing {
    private let preparedStream: XboxCloudPreparedStream
    private let provisionBehavior: XboxStreamProvisionBehavior
    private let keepAliveFails: Bool
    private let keepAliveThreshold: Int?
    private let keepAliveThresholdReached: XboxStreamAsyncLatch?
    private var launchRequests: [XboxCloudSessionLaunchRequest] = []
    private var deletions = 0
    private var deletionCancellationStates: [Bool] = []
    private var keepAliveCalls = 0

    init(
        provisionBehavior: XboxStreamProvisionBehavior = .immediate,
        keepAliveFails: Bool = false,
        keepAliveThreshold: Int? = nil,
        keepAliveThresholdReached: XboxStreamAsyncLatch? = nil
    ) throws {
        preparedStream = try Self.makePreparedStream()
        self.provisionBehavior = provisionBehavior
        self.keepAliveFails = keepAliveFails
        self.keepAliveThreshold = keepAliveThreshold
        self.keepAliveThresholdReached = keepAliveThresholdReached
    }

    func createSession(
        _ request: XboxCloudSessionLaunchRequest
    ) async throws -> XboxCloudStreamSessionToken {
        launchRequests.append(request)
        return XboxCloudStreamSessionToken()
    }

    func provisionSession(
        _: XboxCloudStreamSessionToken,
        onState: @escaping @Sendable (XboxCloudSessionStateSnapshot) async -> Void
    ) async throws -> XboxCloudPreparedStream {
        await onState(XboxCloudSessionStateSnapshot(
            state: .provisioning,
            estimatedTotalWaitTime: 4,
            retryAfter: nil,
            serviceCode: nil
        ))
        switch provisionBehavior {
        case .immediate:
            break
        case let .suspended(entered, release):
            await entered.signal()
            await release.wait()
            try Task.checkCancellation()
        case let .failure(message):
            throw XboxStreamFixtureError(message: message)
        }
        return preparedStream
    }

    func keepAlive(_: XboxCloudStreamSessionToken) async throws {
        keepAliveCalls += 1
        if keepAliveCalls >= keepAliveThreshold ?? .max {
            await keepAliveThresholdReached?.signal()
        }
        if keepAliveFails {
            throw XboxStreamFixtureError(message: "fixture-keepalive-secret")
        }
    }

    func delete(_: XboxCloudStreamSessionToken) async {
        deletions += 1
        deletionCancellationStates.append(Task.isCancelled)
    }

    func requests() -> [XboxCloudSessionLaunchRequest] {
        launchRequests
    }

    func deleteCount() -> Int {
        deletions
    }

    func deleteCancellationStates() -> [Bool] {
        deletionCancellationStates
    }

    private nonisolated static func makePreparedStream() throws -> XboxCloudPreparedStream {
        let configuration = XboxCloudSessionConfiguration(
            serverDetails: XboxCloudServerDetails(
                ipV4Address: "203.0.113.10",
                ipV4Port: 9002,
                ipV6Address: nil,
                ipV6Port: nil,
                srtp: nil,
                uriPathAndQuery: nil,
                stunServerAddresses: ["stun.example.test:3478"]
            ),
            keepAlivePulse: 15,
            clientStreamingConfigOverrides: nil
        )
        let signaling = try XboxCloudSignalingContext(
            endpointBaseURL: URL(
                string: "https://region.gssv-play-prod.xboxlive.com"
            )!,
            sessionPath: "v5/sessions/cloud/fixture-session",
            gsToken: "fixture-gs-token",
            correlationVector: "fixture-cv.1"
        )
        return XboxCloudPreparedStream(
            configuration: configuration,
            signalingContext: signaling
        )
    }
}

@MainActor
private final class XboxStreamRuntimeStub: XboxCloudStreamRuntime {
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var inputKeepAliveCount = 0
    private(set) var connectionState: XboxCloudWebRTCConnectionState = .connected
    let videoTrack: LKRTCVideoTrack?

    init() {
        let factory = CloudRTCRuntime.peerConnectionFactory
        videoTrack = factory.videoTrack(
            with: factory.videoSource(),
            trackId: UUID().uuidString
        )
    }

    func connect(
        configuration _: XboxCloudSessionConfiguration,
        signalingContext _: XboxCloudSignalingContext
    ) async throws {
        connectCount += 1
        connectionState = .connected
    }

    func disconnect() {
        disconnectCount += 1
        connectionState = .idle
    }

    func sendInputKeepAlive() {
        inputKeepAliveCount += 1
    }
}

@MainActor
private final class XboxLifecycleFactoryStub {
    private var lifecycles: [any XboxCloudSessionLifecycleServing]
    private(set) var receivedAccess: [XboxCloudSessionAccessContext] = []

    init(_ lifecycles: [any XboxCloudSessionLifecycleServing]) {
        self.lifecycles = lifecycles
    }

    func make(
        access: XboxCloudSessionAccessContext
    ) -> any XboxCloudSessionLifecycleServing {
        receivedAccess.append(access)
        return lifecycles.removeFirst()
    }
}

@MainActor
private final class XboxRuntimeFactoryStub {
    private var runtimes: [XboxStreamRuntimeStub]
    private(set) var receivedSettings: [XboxCloudStreamSettings] = []

    init(_ runtimes: [XboxStreamRuntimeStub]) {
        self.runtimes = runtimes
    }

    func make(settings: XboxCloudStreamSettings) -> any XboxCloudStreamRuntime {
        receivedSettings.append(settings)
        return runtimes.removeFirst()
    }
}
