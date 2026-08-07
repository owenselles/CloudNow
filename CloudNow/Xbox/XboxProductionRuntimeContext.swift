import Foundation
import Synchronization

/// Owns production-only Xbox dependencies without loading their transports on
/// GeForce NOW launches. The environment retains this lightweight context;
/// the first Xbox authorization, catalog, or stream request creates one graph.
final nonisolated class XboxProductionRuntimeContext: XboxLocalCredentialLifecycle, Sendable {
    private struct RuntimeGraph: Sendable {
        let credentialVault: XboxLiveCredentialVault
        let gsSessionProvider: XboxCloudGSSessionProvider
        let contentAccessStore: XboxContentAccessStore
        let installationIdentity: XboxCloudInstallationIdentityStore
        let transport: any HTTPTransport
    }

    private let authorizationConfiguration: XboxLiveAuthorizationConfiguration
    private let offeringConfiguration: XboxCloudOfferingServiceConfiguration
    private let makeTransport: @Sendable () -> any HTTPTransport
    private let makeInstallationIdentity: @Sendable () -> XboxCloudInstallationIdentityStore
    private let runtimeGraph = Mutex<RuntimeGraph?>(nil)

    init(
        authorizationConfiguration: XboxLiveAuthorizationConfiguration,
        offeringConfiguration: XboxCloudOfferingServiceConfiguration,
        makeTransport: @escaping @Sendable () -> any HTTPTransport = {
            URLSessionHTTPTransport(configuration: .ephemeral)
        },
        makeInstallationIdentity: @escaping @Sendable () -> XboxCloudInstallationIdentityStore = {
            XboxCloudInstallationIdentityStore()
        }
    ) {
        self.authorizationConfiguration = authorizationConfiguration
        self.offeringConfiguration = offeringConfiguration
        self.makeTransport = makeTransport
        self.makeInstallationIdentity = makeInstallationIdentity
    }

    static func microsoftProduction() throws -> XboxProductionRuntimeContext {
        try XboxProductionRuntimeContext(
            authorizationConfiguration: XboxLiveAuthorizationConfiguration
                .microsoftProduction(),
            offeringConfiguration: XboxCloudOfferingServiceConfiguration
                .microsoftProduction()
        )
    }

    /// Public Microsoft sign-in remains available without resolving the Xbox
    /// graph. Every factory captures this context instead of its dependencies.
    var environment: XboxCloudEnvironment {
        XboxCloudEnvironment(
            authentication: XboxCloudEnvironment.productionMicrosoftAuthentication,
            makeAccountAuthorizationClient: { [self] in
                makeAccountAuthorizationClient()
            },
            credentialLifecycle: self,
            service: XboxCloudServiceConfiguration(
                makeCatalogClient: { [self] in
                    makeCatalogClient()
                },
                makeContentAccessClient: { [self] in
                    makeContentAccessClient()
                },
                makeStreamController: { [self] transferToken in
                    makeStreamController(transferToken: transferToken)
                }
            )
        )
    }

    /// Detaching first ensures provider deactivation releases the shared Xbox
    /// transport graph. Clearing an unused context never constructs that graph.
    func clearLocalCredentials() async {
        let detachedGraph = runtimeGraph.withLock { graph in
            defer { graph = nil }
            return graph
        }
        guard let detachedGraph else { return }

        async let clearVault: Void = detachedGraph.credentialVault
            .clearLocalCredentials()
        async let clearSessions: Void = detachedGraph.gsSessionProvider
            .clearLocalCredentials()
        async let clearContentAccess: Void = detachedGraph.contentAccessStore.clear()
        _ = await (clearVault, clearSessions, clearContentAccess)
    }

    private func makeAccountAuthorizationClient() -> any XboxCloudAccountAuthorizationClient {
        let graph = resolvedGraph()
        let tokenClient = XboxLiveTokenClient(
            configuration: authorizationConfiguration,
            transport: graph.transport
        )
        do {
            return try XboxLiveAccountAuthorizationClient(
                tokenClient: tokenClient,
                credentialVault: graph.credentialVault,
                relyingParties: [.cloudGaming],
                optionalRelyingParties: [.contentAccess]
            )
        } catch {
            preconditionFailure(
                "CloudNow's Xbox account authorization configuration is invalid."
            )
        }
    }

    private func makeCatalogClient() -> any XboxCatalogClient {
        let graph = resolvedGraph()
        return XboxCloudCatalogClient(
            sessionProvider: graph.gsSessionProvider,
            contentAccessProvider: graph.contentAccessStore,
            fresnoDiscovery: XboxFresnoCatalogDiscoveryClient(
                transport: graph.transport
            ),
            transport: graph.transport
        )
    }

    private func makeContentAccessClient() -> any XboxContentAccessProviding {
        resolvedGraph().contentAccessStore
    }

    @MainActor
    private func makeStreamController(
        transferToken: @escaping @Sendable () async throws -> String
    ) -> XboxCloudStreamController {
        let graph = resolvedGraph()
        let transport = graph.transport
        return XboxCloudStreamController(
            sessionProvider: graph.gsSessionProvider,
            transferToken: transferToken,
            deviceInformation: .cloudNowTV(
                sdkInstallID: graph.installationIdentity.loadOrCreateSDKInstallID()
            ),
            makeSessionLifecycle: { access in
                XboxCloudSessionLifecycleClient(
                    api: XboxCloudSessionAPI(
                        access: access,
                        transport: transport
                    )
                )
            },
            makeRuntime: { settings in
                XboxCloudNativeStreamRuntime(
                    transport: XboxCloudWebRTCTransport(
                        signaling: XboxCloudSignalingAPI(
                            transport: transport
                        ),
                        codecPreference: settings.codecPreference
                    ),
                    inputDriver: XboxCloudInputDriver(
                        deadzone: Float(settings.controllerDeadzone),
                        rumbleEnabled: settings.rumbleEnabled,
                        rumbleIntensity: Float(settings.rumbleIntensity),
                        preferredResolution: settings.displayResolution
                    )
                )
            }
        )
    }

    private func resolvedGraph() -> RuntimeGraph {
        runtimeGraph.withLock { graph in
            if let graph {
                return graph
            }

            let transport = makeTransport()
            let credentialVault = XboxLiveCredentialVault()
            let contentAccessStore = XboxContentAccessStore(
                upstream: XboxContentAccessClient(
                    credentialProvider: credentialVault,
                    transport: transport
                )
            )
            let resolvedGraph = RuntimeGraph(
                credentialVault: credentialVault,
                gsSessionProvider: XboxCloudGSSessionProvider(
                    credentialProvider: credentialVault,
                    configuration: offeringConfiguration,
                    transport: transport
                ),
                contentAccessStore: contentAccessStore,
                installationIdentity: makeInstallationIdentity(),
                transport: transport
            )
            graph = resolvedGraph
            return resolvedGraph
        }
    }
}
