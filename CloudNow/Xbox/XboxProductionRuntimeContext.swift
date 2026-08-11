import Foundation
import Synchronization
import UIKit

nonisolated struct XboxCloudDisplayMetadata: Equatable, Sendable {
    static let fallback = XboxCloudDisplayMetadata(
        widthInPixels: 1920,
        heightInPixels: 1080,
        pixelDensity: 1
    )

    let widthInPixels: Int
    let heightInPixels: Int
    let pixelDensity: Double

    static func resolved(
        currentModeSize: CGSize?,
        nativeBoundsSize: CGSize?,
        nativeScale: CGFloat
    ) -> Self {
        let dimensions = validDimensions(currentModeSize)
            ?? validDimensions(nativeBoundsSize)
            ?? (fallback.widthInPixels, fallback.heightInPixels)
        let scale = Double(nativeScale)
        return Self(
            widthInPixels: dimensions.0,
            heightInPixels: dimensions.1,
            pixelDensity: scale.isFinite && scale > 0
                ? scale
                : fallback.pixelDensity
        )
    }

    private static func validDimensions(_ size: CGSize?) -> (Int, Int)? {
        guard let size,
              size.width.isFinite,
              size.height.isFinite
        else {
            return nil
        }
        let width = size.width.rounded()
        let height = size.height.rounded()
        guard (1 ... 16384).contains(width),
              (1 ... 16384).contains(height)
        else {
            return nil
        }
        return (Int(width), Int(height))
    }
}

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

    @MainActor
    private struct RetainedStreamController {
        let accountScopeIdentifier: String
        let controller: XboxCloudStreamController
    }

    private let authorizationConfiguration: XboxLiveAuthorizationConfiguration
    private let offeringConfiguration: XboxCloudOfferingServiceConfiguration
    private let makeTransport: @Sendable () -> any HTTPTransport
    private let makeInstallationIdentity: @Sendable () -> XboxCloudInstallationIdentityStore
    private let runtimeGraph = Mutex<RuntimeGraph?>(nil)
    @MainActor private var retainedStreamController: RetainedStreamController?

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
        let profile = try XboxCloudCompatibilityProfile.validatedBundledV1()
        return try XboxProductionRuntimeContext(
            authorizationConfiguration: XboxLiveAuthorizationConfiguration
                .microsoftProduction(profile: profile),
            offeringConfiguration: XboxCloudOfferingServiceConfiguration
                .microsoftProduction(profile: profile)
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
                },
                streamControllerRetention: XboxCloudStreamControllerRetention(
                    retainedController: { [self] account in
                        retainedController(for: account)
                    },
                    retainController: { [self] controller, account in
                        retainController(controller, for: account)
                    },
                    releaseController: { [self] controller in
                        releaseController(controller)
                    }
                ),
                resolveContentAccessOfferingID: { [self] account in
                    try await resolvedGraph().gsSessionProvider
                        .session(for: account).offeringID
                },
                resolveNetworkTestTarget: { [self] account in
                    let session = try await resolvedGraph().gsSessionProvider
                        .session(for: account)
                    return CloudNetworkTestTarget(
                        address: session.defaultRegion.baseURL.absoluteString,
                        displayName: session.defaultRegion.name
                    )
                }
            )
        )
    }

    /// A full credential clear also drops any controller retained across a
    /// provider switch. Sign-out and Reset All Data confirm End before this
    /// boundary, so no remote session ownership may survive the credential.
    func clearLocalCredentials() async {
        await MainActor.run {
            retainedStreamController = nil
        }
        await detachAndClearRuntimeGraph()
    }

    /// Provider switching releases the shared Xbox transport graph while
    /// preserving a resumable or deletion-quarantined stream controller.
    /// Clearing an unused context never constructs that graph.
    func deactivateForInactiveProvider() async {
        await detachAndClearRuntimeGraph()
    }

    private func detachAndClearRuntimeGraph() async {
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
        let installationIdentity = graph.installationIdentity
        return XboxCloudStreamController(
            sessionProvider: graph.gsSessionProvider,
            transferToken: transferToken,
            deviceInformationProvider: {
                let display = Self.currentDisplayMetadata
                return .cloudNowTV(
                    sdkInstallID: installationIdentity.loadOrCreateSDKInstallID(),
                    displayWidthInPixels: display.widthInPixels,
                    displayHeightInPixels: display.heightInPixels,
                    pixelDensity: display.pixelDensity
                )
            },
            makeSessionLifecycle: { access in
                XboxCloudSessionLifecycleClient(
                    api: XboxCloudSessionAPI(
                        access: access,
                        transport: transport
                    )
                )
            },
            makeRuntime: { settings in
                Self.makeNativeStreamRuntime(
                    settings: settings,
                    transport: transport
                )
            }
        )
    }

    @MainActor
    private func retainedController(
        for account: XboxCloudAuthorizedAccount
    ) -> XboxCloudStreamController? {
        guard let retainedStreamController else { return nil }
        guard retainedStreamController.accountScopeIdentifier
            == account.activityScopeIdentifier
        else {
            return nil
        }
        let controller = retainedStreamController.controller
        if controller.hasUnconfirmedSessionDeletion {
            return controller
        }
        guard controller.canContinueSession else {
            self.retainedStreamController = nil
            return nil
        }
        return controller
    }

    @MainActor
    private func retainController(
        _ controller: XboxCloudStreamController,
        for account: XboxCloudAuthorizedAccount
    ) {
        if let retainedStreamController {
            let retainedController = retainedStreamController.controller
            let isProtected = retainedController.canContinueSession
                || retainedController.hasUnconfirmedSessionDeletion
            if retainedController !== controller, isProtected {
                return
            }
        }
        retainedStreamController = RetainedStreamController(
            accountScopeIdentifier: account.activityScopeIdentifier,
            controller: controller
        )
    }

    @MainActor
    private func releaseController(_ controller: XboxCloudStreamController) {
        guard retainedStreamController?.controller === controller else { return }
        retainedStreamController = nil
    }

    @MainActor
    static func makeNativeStreamRuntime(
        settings: XboxCloudStreamSettings,
        transport: any HTTPTransport
    ) -> XboxCloudNativeStreamRuntime {
        let settings = settings.normalizedForClient
        return XboxCloudNativeStreamRuntime(
            transport: XboxCloudWebRTCTransport(
                signaling: XboxCloudSignalingAPI(
                    transport: transport
                )
            ),
            inputDriver: XboxCloudInputDriver(
                deadzone: Float(settings.controllerDeadzone),
                rumbleEnabled: settings.rumbleEnabled,
                rumbleIntensity: Float(settings.rumbleIntensity),
                preferredResolution: settings.displayResolution
            ),
            microphoneRequested: settings.microphoneEnabled,
            diagnosticsEnabled: settings.diagnosticsEnabled,
            rtcEventLogRequested: settings.enableRtcEventLog
        )
    }

    @MainActor
    private static var currentDisplayMetadata: XboxCloudDisplayMetadata {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .screen
        return XboxCloudDisplayMetadata.resolved(
            currentModeSize: screen?.currentMode?.size,
            nativeBoundsSize: screen?.nativeBounds.size,
            nativeScale: screen?.nativeScale ?? 1
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
