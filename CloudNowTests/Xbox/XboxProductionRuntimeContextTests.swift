@testable import CloudNow
import Foundation
import Synchronization
import Testing

@Suite("Xbox production runtime context")
struct XboxProductionRuntimeContextTests {
    @Test("Production stream runtime forwards the microphone preference")
    @MainActor
    func productionRuntimeForwardsMicrophonePreference() {
        let transportFactory = XboxRuntimeTransportFactoryProbe()
        let enabledRuntime = XboxProductionRuntimeContext.makeNativeStreamRuntime(
            settings: XboxCloudStreamSettings(microphoneEnabled: true),
            transport: transportFactory.makeTransport()
        )
        let disabledRuntime = XboxProductionRuntimeContext.makeNativeStreamRuntime(
            settings: XboxCloudStreamSettings(microphoneEnabled: false),
            transport: transportFactory.makeTransport()
        )

        #expect(enabledRuntime.microphoneRequestedForConnection)
        #expect(!disabledRuntime.microphoneRequestedForConnection)
    }

    @Test("Production stream runtime applies the build bandwidth gate")
    @MainActor
    func productionRuntimeAppliesBandwidthGate() {
        let transportFactory = XboxRuntimeTransportFactoryProbe()
        let preference = XboxCloudBandwidthPreference.manual(
            maximumBitrateKbps: 100_000
        )
        let runtime = XboxProductionRuntimeContext.makeNativeStreamRuntime(
            settings: XboxCloudStreamSettings(
                bandwidthPreference: preference
            ),
            transport: transportFactory.makeTransport()
        )

        #if XBOX_QUALITY_BETA
            #expect(runtime.bandwidthPreference == preference)
        #else
            #expect(runtime.bandwidthPreference == .automatic)
        #endif
    }

    @Test("Production stream runtime normalizes diagnostics for this build")
    @MainActor
    func productionRuntimeNormalizesDiagnostics() {
        let transportFactory = XboxRuntimeTransportFactoryProbe()
        let runtime = XboxProductionRuntimeContext.makeNativeStreamRuntime(
            settings: XboxCloudStreamSettings(
                diagnosticsEnabled: true,
                enableRtcEventLog: true
            ),
            transport: transportFactory.makeTransport()
        )

        #if DEBUG
            #expect(runtime.diagnosticsEnabled)
            #expect(runtime.rtcEventLogRequestedForConnection)
        #else
            #expect(!runtime.diagnosticsEnabled)
            #expect(!runtime.rtcEventLogRequestedForConnection)
        #endif
        #expect(!runtime.rtcEventLogActive)
    }

    @Test("GeForce NOW-only setup leaves the Xbox graph dormant")
    @MainActor
    func geForceNowSetupDoesNotBuildXboxRuntime() async throws {
        let transportFactory = XboxRuntimeTransportFactoryProbe()
        let context = try makeContext(transportFactory: transportFactory)
        let environment = context.environment
        _ = CloudGamingProviderCoordinator(
            capabilityProviders: [
                GFNCapabilityAdapter(),
                XboxCapabilityAdapter(environment: environment),
            ],
            initialSelection: .geForceNow,
            startsReady: true
        )
        let authManager = XboxAuthManager(
            environment: environment,
            startsReady: true
        )

        await authManager.deactivateForInactiveProvider()

        #expect(environment.availability == .configured)
        #expect(transportFactory.constructionCount == 0)
    }

    @Test("Xbox factories share one lazily-created runtime graph")
    @MainActor
    func xboxFactoriesReuseRuntime() throws {
        let transportFactory = XboxRuntimeTransportFactoryProbe()
        let context = try makeContext(transportFactory: transportFactory)
        let environment = context.environment
        let makeAccountClient = try #require(
            environment.makeAccountAuthorizationClient
        )
        let service = try #require(environment.service)
        let makeContentAccessClient = try #require(service.makeContentAccessClient)

        _ = makeAccountClient()
        _ = service.makeCatalogClient()
        _ = makeContentAccessClient()
        let streamController = service.makeStreamController {
            "fixture-transfer-token"
        }

        #expect(streamController.state == .idle)
        #expect(transportFactory.constructionCount == 1)
    }

    @Test("Concurrent first access constructs one Xbox runtime graph")
    func concurrentFactoryAccessConstructsOnce() async throws {
        let transportFactory = XboxRuntimeTransportFactoryProbe()
        let context = try makeContext(transportFactory: transportFactory)
        let makeAccountClient = try #require(
            context.environment.makeAccountAuthorizationClient
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    _ = makeAccountClient()
                }
            }
        }

        #expect(transportFactory.constructionCount == 1)
    }

    @Test("Credential clearing detaches without constructing the graph")
    func credentialClearDetachesRuntimeGraph() async throws {
        let transportFactory = XboxRuntimeTransportFactoryProbe()
        let context = try makeContext(transportFactory: transportFactory)
        let environment = context.environment
        let service = try #require(environment.service)

        await context.clearLocalCredentials()
        #expect(transportFactory.constructionCount == 0)

        _ = service.makeCatalogClient()
        #expect(transportFactory.constructionCount == 1)

        await context.clearLocalCredentials()
        await context.clearLocalCredentials()
        #expect(transportFactory.constructionCount == 1)

        let makeAccountClient = try #require(
            environment.makeAccountAuthorizationClient
        )
        _ = makeAccountClient()
        #expect(transportFactory.constructionCount == 2)
    }

    @Test("Provider deactivation preserves retention; credential clear releases it")
    @MainActor
    func credentialClearReleasesRetainedStreamController() async throws {
        let transportFactory = XboxRuntimeTransportFactoryProbe()
        let context = try makeContext(transportFactory: transportFactory)
        let service = try #require(context.environment.service)
        let account = XboxCloudAuthorizedAccount(
            authorizationIdentifier: "fixture-account",
            displayName: "Fixture Player",
            expiresAt: .distantFuture
        )
        var controller: XboxCloudStreamController? = service.makeStreamController {
            "fixture-transfer-token"
        }
        weak var retainedController: XboxCloudStreamController?
        retainedController = controller
        try service.streamControllerRetention.retainController(
            #require(controller),
            account
        )
        controller = nil

        #expect(retainedController != nil)
        await context.deactivateForInactiveProvider()
        #expect(retainedController != nil)

        await context.clearLocalCredentials()
        #expect(retainedController == nil)
    }

    @Test("Detached graph purges both XSTS and cached GS credentials")
    func credentialClearPurgesDerivedCredentials() async throws {
        let transportFactory = XboxRuntimeTransportFactoryProbe { request, index in
            switch request.url?.path {
            case "/user/authenticate":
                StubbedHTTPResponse(json: Self.userTokenJSON)
            case "/xsts/authorize":
                StubbedHTTPResponse(json: Self.xstsTokenJSON)
            case "/v2/login/user":
                StubbedHTTPResponse(json: Self.gsLoginResponseJSON)
            case "/v2/titles":
                StubbedHTTPResponse(json: #"{"results":[]}"#)
            default:
                throw TestTransportError.unexpectedRequest(
                    "Unexpected Xbox runtime request \(index)"
                )
            }
        }
        let context = try makeContext(transportFactory: transportFactory)
        let environment = context.environment
        let makeAccountClient = try #require(
            environment.makeAccountAuthorizationClient
        )
        let service = try #require(environment.service)
        let account = try await makeAccountClient().authorize(
            microsoftToken: MicrosoftOAuthToken(
                accessToken: "fixture-microsoft-access",
                refreshToken: "fixture-microsoft-refresh",
                idToken: nil,
                tokenType: "Bearer",
                scopes: ["xboxlive.signin", "offline_access"],
                expiresAt: .distantFuture
            )
        )
        let catalog = service.makeCatalogClient()
        let request = XboxCatalogRequest(
            localeIdentifier: "en-US",
            market: "US"
        )

        let snapshot = try await catalog.fetchCatalog(
            request,
            account: account
        )
        let transport = try #require(transportFactory.transport(at: 0))
        #expect(snapshot.items.isEmpty)
        #expect(await transport.requests().count >= 4)
        #expect(transportFactory.constructionCount == 1)

        await context.clearLocalCredentials()
        let requestCountAfterClear = await transport.requests().count

        await #expect(throws: XboxLiveAuthorizationError.accountNotAuthorized) {
            _ = try await catalog.fetchCatalog(request, account: account)
        }
        #expect(await transport.requests().count == requestCountAfterClear)
    }

    private func makeContext(
        transportFactory: XboxRuntimeTransportFactoryProbe
    ) throws -> XboxProductionRuntimeContext {
        let preferences = XboxRuntimeMemoryPreferencesStore()
        return try XboxProductionRuntimeContext(
            authorizationConfiguration: .microsoftProduction(),
            offeringConfiguration: .microsoftProduction(),
            makeTransport: {
                transportFactory.makeTransport()
            },
            makeInstallationIdentity: {
                XboxCloudInstallationIdentityStore(
                    preferences: preferences
                )
            }
        )
    }

    private static let userTokenJSON =
        #"{"NotAfter":"2099-01-01T00:00:00.000Z","Token":"fixture-user-token","DisplayClaims":{"xui":[{"uhs":"fixture-user-hash"}]}}"#

    private static let xstsTokenJSON =
        #"{"NotAfter":"2099-01-01T00:00:00.000Z","Token":"fixture-xsts-token","DisplayClaims":{"xui":[{"uhs":"fixture-user-hash","gtg":"Fixture Gamer"}]}}"#

    private static let gsLoginResponseJSON = #"""
    {
      "gsToken": "fixture-gs-token",
      "durationInSeconds": 7200,
      "market": "US",
      "offeringSettings": {
        "regions": [{
          "name": "West US",
          "baseUri": "https://wus.gssv-play-prod.xboxlive.com",
          "isDefault": true,
          "fallbackPriority": -1,
          "systemUpdateGroups": []
        }]
      }
    }
    """#
}

private final nonisolated class XboxRuntimeTransportFactoryProbe: Sendable {
    typealias Handler = RecordingHTTPTransport.Handler

    private struct State: Sendable {
        var transports: [RecordingHTTPTransport] = []
    }

    private let handler: Handler
    private let state = Mutex(State())

    var constructionCount: Int {
        state.withLock { $0.transports.count }
    }

    init(
        handler: @escaping Handler = { _, index in
            throw TestTransportError.unexpectedRequest(
                "Unexpected Xbox runtime request \(index)"
            )
        }
    ) {
        self.handler = handler
    }

    func makeTransport() -> any HTTPTransport {
        let transport = RecordingHTTPTransport(handler: handler)
        state.withLock { $0.transports.append(transport) }
        return transport
    }

    func transport(at index: Int) -> RecordingHTTPTransport? {
        state.withLock { state in
            guard state.transports.indices.contains(index) else { return nil }
            return state.transports[index]
        }
    }
}

private final nonisolated class XboxRuntimeMemoryPreferencesStore: PreferencesStore, Sendable {
    private enum Value: Sendable {
        case data(Data)
        case string(String)
    }

    private let values = Mutex<[String: Value]>([:])

    func data(forKey key: String) -> Data? {
        values.withLock { values in
            guard case let .data(value) = values[key] else { return nil }
            return value
        }
    }

    func string(forKey key: String) -> String? {
        values.withLock { values in
            guard case let .string(value) = values[key] else { return nil }
            return value
        }
    }

    func setData(_ data: Data, forKey key: String) {
        values.withLock { $0[key] = .data(data) }
    }

    func setString(_ value: String, forKey key: String) {
        values.withLock { $0[key] = .string(value) }
    }

    func removeObject(forKey key: String) {
        _ = values.withLock { $0.removeValue(forKey: key) }
    }

    func keys() -> [String] {
        values.withLock { Array($0.keys) }
    }
}
