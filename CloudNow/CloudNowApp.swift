//
//  CloudNowApp.swift
//  CloudNow
//
//  Created by Owen Selles on 11/04/2026.
//

import BackgroundTasks
import SwiftUI

@main
struct CloudNowApp: App {
    @State private var authManager: AuthManager
    @State private var providerCoordinator: CloudGamingProviderCoordinator
    @State private var xboxAuthManager: XboxAuthManager
    @State private var cloudSessionCoordinator = CloudSessionCoordinator()
    @State private var hasRestoredApplicationState = false
    private let xboxEnvironment: XboxCloudEnvironment
    #if DEBUG
        private let usesUITestFixtures: Bool
        private let uiTestColorScheme: ColorScheme?
    #endif

    init() {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            let usesUITestFixtures =
                arguments.contains("--cloudnow-ui-testing")
                    || ProcessInfo.processInfo.environment["CLOUDNOW_UI_TESTING"] == "1"
            self.usesUITestFixtures = usesUITestFixtures
            uiTestColorScheme = Self.requestedUITestColorScheme(arguments: arguments)
            let authManager = usesUITestFixtures
                ? AuthManager(
                    backgroundScheduler: .disabled,
                    schedulesAutomaticRefresh: false,
                    initialSession: Self.uiTestAuthSession
                )
                : AuthManager()
            let showsServiceChooserFixture = ProcessInfo.processInfo.arguments.contains(
                "--cloudnow-ui-service-chooser"
            )
            let usesConfiguredXboxFixture = usesUITestFixtures
                && ProcessInfo.processInfo.arguments.contains(
                    "--cloudnow-ui-xbox-configured"
                )
            let usesXboxDeviceCodeFixture = usesUITestFixtures
                && showsServiceChooserFixture
                && !usesConfiguredXboxFixture
            let xboxEnvironment: XboxCloudEnvironment = if usesConfiguredXboxFixture {
                XboxUITestFixture.environment
            } else if usesXboxDeviceCodeFixture {
                XboxUITestFixture.deviceCodeEnvironment
            } else if usesUITestFixtures {
                .unconfigured
            } else {
                Self.productionXboxEnvironment
            }
            let providerCoordinator = CloudGamingProviderCoordinator(
                capabilityProviders: [
                    GFNCapabilityAdapter(),
                    XboxCapabilityAdapter(environment: xboxEnvironment),
                ],
                initialSelection: usesUITestFixtures && !showsServiceChooserFixture
                    ? .geForceNow
                    : nil,
                startsReady: usesUITestFixtures
            )
            let xboxAuthManager = XboxAuthManager(
                environment: xboxEnvironment,
                oauthClient: usesXboxDeviceCodeFixture
                    ? XboxUITestFixture.makeDeviceCodeOAuthClient()
                    : nil,
                persistence: AppPersistenceStore.shared,
                initialSession: usesConfiguredXboxFixture
                    ? XboxUITestFixture.session
                    : nil,
                initialAuthorizedAccount: usesConfiguredXboxFixture
                    ? XboxUITestFixture.account
                    : nil,
                startsReady: usesUITestFixtures
            )
        #else
            let authManager = AuthManager()
            let xboxEnvironment = Self.productionXboxEnvironment
            let providerCoordinator = CloudGamingProviderCoordinator(
                capabilityProviders: [
                    GFNCapabilityAdapter(),
                    XboxCapabilityAdapter(environment: xboxEnvironment),
                ]
            )
            let xboxAuthManager = XboxAuthManager(
                environment: xboxEnvironment,
                persistence: AppPersistenceStore.shared
            )
        #endif
        _authManager = State(initialValue: authManager)
        _providerCoordinator = State(initialValue: providerCoordinator)
        _xboxAuthManager = State(initialValue: xboxAuthManager)
        self.xboxEnvironment = xboxEnvironment

        URLCache.shared = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024
        )
        #if DEBUG
            guard !usesUITestFixtures else { return }
        #endif

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.owenselles.CloudNow.tokenRefresh",
            using: nil
        ) { [authManager, providerCoordinator] task in
            Task { @MainActor in
                let handler = GeForceNowBackgroundRefreshHandler(
                    providerCoordinator: providerCoordinator,
                    authManager: authManager
                )
                _ = await handler.perform()
                task.setTaskCompleted(success: true)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                    if usesUITestFixtures {
                        UITestRootView(
                            xboxServiceConfiguration: xboxEnvironment.service
                        )
                        .environment(authManager)
                        .environment(providerCoordinator)
                        .environment(xboxAuthManager)
                        .environment(\.locale, L10n.localizationLocale)
                        .environment(\.colorScheme, uiTestColorScheme ?? .dark)
                    } else {
                        productionRoot
                    }
                #else
                    productionRoot
                #endif
            }
            .environment(cloudSessionCoordinator)
            .environment(
                \.layoutDirection,
                L10n.isRightToLeft ? .rightToLeft : .leftToRight
            )
            .modifier(CloudAppLifecycleModifier())
            .alert(
                L10n.text("reset_failed"),
                isPresented: dataResetFailureBinding
            ) {
                Button(L10n.text("ok")) {
                    providerCoordinator.dismissDataResetFailure()
                }
            } message: {
                Text(providerCoordinator.dataResetFailureMessage ?? "")
            }
        }
    }

    private var dataResetFailureBinding: Binding<Bool> {
        Binding(
            get: { providerCoordinator.dataResetFailureMessage != nil },
            set: { isPresented in
                if !isPresented {
                    providerCoordinator.dismissDataResetFailure()
                }
            }
        )
    }

    private var productionRoot: some View {
        Group {
            if isRestoringApplicationState {
                AuthRestorationView()
            } else if let selectedProvider = providerCoordinator.selectedProvider {
                switch selectedProvider {
                case .geForceNow:
                    if authManager.isAuthenticated {
                        MainTabView()
                    } else {
                        LoginView()
                    }
                case .xboxCloudGaming:
                    if !xboxAuthManager.canRequestMicrosoftDeviceCode {
                        XboxCloudConfigurationRequiredView()
                    } else if xboxAuthManager.isXboxCloudAuthorized,
                              let account = xboxAuthManager.authorizedAccount,
                              let configuration = xboxEnvironment.service
                    {
                        XboxMainTabView(
                            configuration: configuration,
                            account: account,
                            fallbackProvider: authManager.isAuthenticated
                                ? .geForceNow
                                : nil
                        )
                    } else {
                        XboxLoginView(
                            fallbackProvider: authManager.isAuthenticated
                                ? .geForceNow
                                : nil
                        )
                    }
                }
            } else {
                CloudServiceSelectionView()
            }
        }
        .environment(authManager)
        .environment(providerCoordinator)
        .environment(xboxAuthManager)
        .task {
            await restoreInitialProviderState()
        }
        .task(
            id: ProviderActivationIdentity(
                provider: providerCoordinator.selectedProvider,
                isReady: hasRestoredApplicationState
            )
        ) {
            guard hasRestoredApplicationState else { return }
            await activateSelectedProvider()
        }
        .onChange(of: authManager.isAuthenticated) { _, authenticated in
            if !authenticated {
                MemoryLifecycleCoordinator.shared.releaseCachedArtwork()
            }
        }
        .onChange(of: xboxAuthManager.isXboxCloudAuthorized) { _, authorized in
            if !authorized {
                MemoryLifecycleCoordinator.shared.releaseCachedArtwork()
            }
        }
    }

    private var isRestoringApplicationState: Bool {
        guard providerCoordinator.startupPhase == .ready,
              hasRestoredApplicationState
        else {
            return true
        }
        switch providerCoordinator.selectedProvider {
        case .geForceNow:
            return authManager.startupPhase != .ready
        case .xboxCloudGaming:
            return xboxAuthManager.startupPhase != .ready
        case nil:
            return false
        }
    }

    private func restoreInitialProviderState() async {
        await providerCoordinator.initialize()
        guard !Task.isCancelled else { return }

        switch providerCoordinator.selectedProvider {
        case .geForceNow:
            await authManager.restorePersistedSession()
        case .xboxCloudGaming:
            await xboxAuthManager.restorePersistedSession()
        case nil where providerCoordinator.requiresLegacyGeForceNowMigration:
            await authManager.restorePersistedSession()
            guard !Task.isCancelled else { return }
            if authManager.isAuthenticated {
                providerCoordinator.adoptLegacyGeForceNowSessionIfNeeded()
            }
        case nil:
            break
        }

        guard !Task.isCancelled else { return }
        hasRestoredApplicationState = true
    }

    private func activateSelectedProvider() async {
        switch providerCoordinator.selectedProvider {
        case .geForceNow:
            await xboxAuthManager.deactivateForInactiveProvider()
            await authManager.restorePersistedSession()
            guard !Task.isCancelled,
                  providerCoordinator.selectedProvider == .geForceNow
            else {
                return
            }
            await authManager.activateForCurrentProvider()
        case .xboxCloudGaming:
            authManager.deactivateForInactiveProvider()
            await xboxAuthManager.restorePersistedSession()
            guard !Task.isCancelled,
                  providerCoordinator.selectedProvider == .xboxCloudGaming
            else {
                return
            }
            await xboxAuthManager.activateXboxCloudAccess()
        case nil:
            authManager.deactivateForInactiveProvider()
            await xboxAuthManager.deactivateForInactiveProvider()
        }
    }

    #if DEBUG
        private static func requestedUITestColorScheme(
            arguments: [String]
        ) -> ColorScheme? {
            guard let flagIndex = arguments.firstIndex(
                of: "--cloudnow-ui-color-scheme"
            ),
                arguments.indices.contains(flagIndex + 1)
            else {
                return nil
            }
            return switch arguments[flagIndex + 1] {
            case "light": .light
            case "dark": .dark
            default: nil
            }
        }

        private static let uiTestAuthSession = AuthSession(
            provider: LoginProvider(
                idpId: NVIDIAAuth.defaultIdpId,
                code: "NVIDIA",
                displayName: "NVIDIA",
                streamingServiceUrl: NVIDIAAuth.defaultStreamingUrl,
                priority: 0
            ),
            tokens: AuthTokens(
                accessToken: "fixture-access-token",
                refreshToken: nil,
                idToken: "fixture-id-token",
                expiresAt: .distantFuture,
                clientToken: nil,
                clientTokenExpiresAt: nil
            ),
            user: AuthUser(
                userId: "fixture-user",
                displayName: "Fixture User",
                email: nil,
                avatarUrl: nil,
                membershipTier: "FREE"
            )
        )
    #endif

    private static let productionXboxEnvironment: XboxCloudEnvironment = {
        do {
            return try XboxProductionRuntimeContext.microsoftProduction()
                .environment
        } catch {
            return .invalidCompatibilityProfile
        }
    }()
}

private struct ProviderActivationIdentity: Hashable {
    let provider: CloudGamingProvider?
    let isReady: Bool
}

private struct AuthRestorationView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ProgressView()
                .tint(.secondary)
        }
        .environment(\.colorScheme, .dark)
    }
}

#if DEBUG
    private struct UITestRootView: View {
        @Environment(AuthManager.self) private var authManager
        @Environment(CloudGamingProviderCoordinator.self) private var providerCoordinator
        @Environment(XboxAuthManager.self) private var xboxAuthManager
        @State private var viewModel: GamesViewModel
        private let showsServiceChooser: Bool
        private let showsXboxQualityHUD: Bool
        private let xboxServiceConfiguration: XboxCloudServiceConfiguration?
        private let xboxStreamFixtureState: CloudStreamPresentationState?

        init(
            xboxServiceConfiguration: XboxCloudServiceConfiguration?
        ) {
            let arguments = ProcessInfo.processInfo.arguments
            self.xboxServiceConfiguration = xboxServiceConfiguration
            showsServiceChooser = arguments.contains("--cloudnow-ui-service-chooser")
            showsXboxQualityHUD = arguments.contains(
                "--cloudnow-ui-xbox-quality-hud"
            )
            xboxStreamFixtureState = Self.xboxStreamFixtureState(
                arguments: arguments
            )
            let syncClientMode: UITestLibrarySyncClient.Mode =
                arguments.contains("--cloudnow-ui-library-refresh-empty")
                    ? .empty
                    : .partialFailure
            let refreshState = if arguments.contains("--cloudnow-ui-library-refresh-long-list") {
                Self.longRefreshState
            } else if arguments.contains("--cloudnow-ui-library-refresh-partial") {
                Self.partialRefreshState
            } else if arguments.contains("--cloudnow-ui-library-refresh-running") {
                Self.runningRefreshState
            } else if arguments.contains("--cloudnow-ui-library-refresh-empty") {
                Self.emptyRefreshState
            } else {
                FullLibraryRefreshState()
            }
            _viewModel = State(
                initialValue: GamesViewModel(
                    mainGames: Self.fixtureGames,
                    libraryGames: Self.fixtureGames,
                    favoriteIds: ["fixture-racer"],
                    persistenceEnabled: false,
                    librarySyncClient: UITestLibrarySyncClient(mode: syncClientMode),
                    libraryRefreshScheduler: LibraryRefreshScheduler(
                        now: { 0 },
                        sleep: { _ in }
                    ),
                    providerLibrarySyncEnabled: true,
                    initialLibraryRefreshState: refreshState,
                    libraryRefreshImporterOverride: {
                        LibraryImportResult(
                            finalGameCount: 81,
                            addedGameIDs: ["fixture-retry-new"],
                            removedGameIDs: []
                        )
                    }
                )
            )
        }

        var body: some View {
            Group {
                if showsXboxQualityHUD {
                    CloudStreamQualityHUDFixtureView()
                } else if let xboxStreamFixtureState {
                    CloudStreamPresentationFixtureView(
                        state: xboxStreamFixtureState
                    )
                } else if showsServiceChooser {
                    switch providerCoordinator.selectedProvider {
                    case .geForceNow:
                        MainTabView(viewModel: viewModel, loadsRemoteData: false)
                    case .xboxCloudGaming:
                        if !xboxAuthManager.canRequestMicrosoftDeviceCode {
                            XboxCloudConfigurationRequiredView()
                        } else if xboxAuthManager.isXboxCloudAuthorized,
                                  let account = xboxAuthManager.authorizedAccount,
                                  let configuration = xboxServiceConfiguration
                        {
                            XboxMainTabView(
                                configuration: configuration,
                                account: account,
                                fallbackProvider: .geForceNow
                            )
                        } else {
                            XboxLoginView(fallbackProvider: .geForceNow)
                        }
                    case nil:
                        CloudServiceSelectionView()
                    }
                } else {
                    MainTabView(viewModel: viewModel, loadsRemoteData: false)
                }
            }
            .task(id: providerCoordinator.selectedProvider) {
                switch providerCoordinator.selectedProvider {
                case .geForceNow:
                    await xboxAuthManager.deactivateForInactiveProvider()
                    await authManager.activateForCurrentProvider()
                case .xboxCloudGaming:
                    authManager.deactivateForInactiveProvider()
                    await xboxAuthManager.activateXboxCloudAccess()
                case nil:
                    authManager.deactivateForInactiveProvider()
                    await xboxAuthManager.deactivateForInactiveProvider()
                }
            }
        }

        private static func xboxStreamFixtureState(
            arguments: [String]
        ) -> CloudStreamPresentationState? {
            guard let flagIndex = arguments.firstIndex(
                of: "--cloudnow-ui-xbox-stream-state"
            ),
                arguments.indices.contains(flagIndex + 1)
            else {
                return nil
            }
            return switch arguments[flagIndex + 1] {
            case "idle": .idle
            case "allocating": .allocating
            case "queued": .queued(position: 4, estimatedWait: 90)
            case "provisioning": .provisioning(
                    progress: 0.42,
                    estimatedWait: 45
                )
            case "connecting": .connecting
            case "streaming": .streaming
            case "reconnecting": .reconnecting(
                    attempt: 2,
                    maximumAttempts: 3,
                    nextDelay: 2
                )
            case "resumable": .resumable(
                    expiresAt: Date().addingTimeInterval(600)
                )
            case "failure": .failure(
                    CloudStreamPresentationFailure(
                        localizationKey: "stream_failed",
                        isRetryable: true
                    )
                )
            case "stopping": .stopping
            default: nil
            }
        }

        private static let fixtureGames = [
            GameInfo(
                id: "fixture-racer",
                title: "Fixture Racer",
                longDescription: "Deterministic local fixture used by simulator UI automation.",
                genres: ["RACING"],
                developer: "CloudNow",
                publisher: "CloudNow",
                contentRating: "Everyone",
                boxArtUrl: nil,
                heroBannerUrl: nil,
                heroImageUrl: nil,
                supportedFeatures: [.hdr, .reflex],
                screenshots: [],
                isInLibrary: true,
                variants: [
                    GameVariant(
                        id: "fixture-racer-steam",
                        appStore: "STEAM",
                        appId: "fixture-app",
                        isOwned: true
                    ),
                ]
            ),
            GameInfo(
                id: "fixture-strategy",
                title: "Fixture Strategy",
                longDescription: "Second local fixture for stable navigation coverage.",
                genres: ["STRATEGY"],
                developer: "CloudNow",
                publisher: "CloudNow",
                contentRating: "Everyone",
                boxArtUrl: nil,
                heroBannerUrl: nil,
                heroImageUrl: nil,
                supportedFeatures: [.rtx],
                screenshots: [],
                isInLibrary: true,
                variants: [
                    GameVariant(
                        id: "fixture-strategy-epic",
                        appStore: "EPIC_GAMES_STORE",
                        appId: "fixture-app-2",
                        isOwned: true
                    ),
                ]
            ),
        ]

        private static let partialRefreshState = FullLibraryRefreshState(
            stage: .partialFailure,
            providers: [
                ProviderSyncProgress(
                    providerCode: "STEAM",
                    displayName: "Steam",
                    accountName: "Fixture Steam",
                    phase: .succeeded(gameCount: 42)
                ),
                ProviderSyncProgress(
                    providerCode: "XBOX",
                    displayName: "Xbox",
                    accountName: "Fixture Xbox",
                    phase: .failed(message: "Fixture provider failure")
                ),
                ProviderSyncProgress(
                    providerCode: "EPIC",
                    displayName: "Epic Games",
                    accountName: "Fixture Epic",
                    phase: .skipped
                ),
            ],
            finalPhase: .succeeded(gameCount: 80),
            summary: LibraryRefreshSummary(
                successfulProviderCount: 1,
                failedProviderCount: 1,
                skippedProviderCount: 1,
                finalGameCount: 80,
                addedGameIDs: ["fixture-new"],
                removedGameIDs: ["fixture-old"]
            )
        )

        private static let runningRefreshState = FullLibraryRefreshState(
            stage: .syncing,
            providers: [
                ProviderSyncProgress(
                    providerCode: "STEAM",
                    displayName: "Steam",
                    accountName: "Fixture Steam",
                    phase: .syncing
                ),
                ProviderSyncProgress(
                    providerCode: "XBOX",
                    displayName: "Xbox",
                    accountName: "Fixture Xbox",
                    phase: .succeeded(gameCount: 20)
                ),
            ],
            finalPhase: .queued
        )

        private static let longRefreshState = FullLibraryRefreshState(
            stage: .syncing,
            providers: [
                ProviderSyncProgress(
                    providerCode: "STEAM",
                    displayName: "Steam",
                    accountName: "Fixture Steam",
                    phase: .syncing
                ),
                ProviderSyncProgress(
                    providerCode: "XBOX",
                    displayName: "Xbox",
                    accountName: "Fixture Xbox",
                    phase: .succeeded(gameCount: 60)
                ),
                ProviderSyncProgress(
                    providerCode: "UBISOFT",
                    displayName: "Ubisoft Connect",
                    accountName: "Fixture Ubisoft",
                    phase: .succeeded(gameCount: 55)
                ),
                ProviderSyncProgress(
                    providerCode: "BATTLENET",
                    displayName: "Battle.net",
                    accountName: "Fixture Battle.net",
                    phase: .succeeded(gameCount: 21)
                ),
                ProviderSyncProgress(
                    providerCode: "GAIJIN",
                    displayName: "Gaijin.net",
                    accountName: "Fixture Gaijin",
                    phase: .succeeded(gameCount: 8)
                ),
                ProviderSyncProgress(
                    providerCode: "EPIC",
                    displayName: "Epic Games Store",
                    accountName: "Fixture Epic",
                    phase: .skipped
                ),
                ProviderSyncProgress(
                    providerCode: "EA",
                    displayName: "EA app",
                    accountName: "Fixture EA",
                    phase: .skipped
                ),
                ProviderSyncProgress(
                    providerCode: "GOG",
                    displayName: "GOG.com",
                    accountName: "Fixture GOG",
                    phase: .skipped
                ),
                ProviderSyncProgress(
                    providerCode: "AMAZON",
                    displayName: "Amazon Games",
                    accountName: "Fixture Amazon",
                    phase: .skipped
                ),
                ProviderSyncProgress(
                    providerCode: "ROCKSTAR",
                    displayName: "Rockstar Games",
                    accountName: "Fixture Rockstar",
                    phase: .skipped
                ),
                ProviderSyncProgress(
                    providerCode: "RIOT",
                    displayName: "Riot Games",
                    accountName: "Fixture Riot",
                    phase: .skipped
                ),
                ProviderSyncProgress(
                    providerCode: "HOYOVERSE",
                    displayName: "HoYoverse",
                    accountName: "Fixture HoYoverse",
                    phase: .skipped
                ),
            ],
            finalPhase: .queued
        )

        private static let emptyRefreshState = FullLibraryRefreshState(
            stage: .completed,
            providers: [],
            finalPhase: .succeeded(gameCount: 2),
            summary: LibraryRefreshSummary(
                successfulProviderCount: 0,
                failedProviderCount: 0,
                skippedProviderCount: 0,
                finalGameCount: 2,
                addedGameIDs: [],
                removedGameIDs: []
            )
        )
    }

    private actor UITestLibrarySyncClient: LibrarySyncClient {
        enum Mode: Sendable {
            case partialFailure
            case empty
        }

        private let baseline = Date(timeIntervalSince1970: 1000)
        private let mode: Mode
        private var requestCounts: [String: Int] = [:]

        init(mode: Mode) {
            self.mode = mode
        }

        func discover(token _: String, userId _: String) async throws -> [ConnectedGameLibrary] {
            guard mode == .partialFailure else { return [] }
            return [
                provider(
                    code: "STEAM",
                    displayName: "Steam",
                    supportsSync: true,
                    sortOrder: 0,
                    state: .success,
                    count: 42
                ),
                provider(
                    code: "XBOX",
                    displayName: "Xbox",
                    supportsSync: true,
                    sortOrder: 1,
                    state: .failed,
                    count: nil
                ),
                provider(
                    code: "EPIC",
                    displayName: "Epic Games",
                    supportsSync: false,
                    sortOrder: 2,
                    state: .unknown(nil),
                    count: nil
                ),
            ]
        }

        func requestSync(providerCode: String, token _: String) async throws {
            requestCounts[providerCode, default: 0] += 1
        }

        func fetchSnapshots(token _: String, userId _: String) async throws -> [ProviderSyncSnapshot] {
            guard mode == .partialFailure else { return [] }
            return [
                ProviderSyncSnapshot(
                    providerCode: "STEAM",
                    totalSyncedGames: 42,
                    state: .success,
                    syncDate: baseline.addingTimeInterval(1)
                ),
                ProviderSyncSnapshot(
                    providerCode: "XBOX",
                    totalSyncedGames: requestCounts["XBOX", default: 0] > 0
                        ? 55
                        : nil,
                    state: requestCounts["XBOX", default: 0] > 0
                        ? .success
                        : .failed,
                    syncDate: baseline.addingTimeInterval(
                        requestCounts["XBOX", default: 0] > 0 ? 2 : 1
                    )
                ),
            ]
        }

        private func provider(
            code: String,
            displayName: String,
            supportsSync: Bool,
            sortOrder: Int,
            state: ProviderAccountSyncState,
            count: Int?
        ) -> ConnectedGameLibrary {
            ConnectedGameLibrary(
                code: code,
                displayName: displayName,
                accountDisplayName: "Fixture \(displayName)",
                iconURL: nil,
                supportsSync: supportsSync,
                sortOrder: sortOrder,
                snapshot: ProviderSyncSnapshot(
                    providerCode: code,
                    totalSyncedGames: count,
                    state: state,
                    syncDate: baseline
                )
            )
        }
    }
#endif
