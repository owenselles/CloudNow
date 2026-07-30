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
    #if DEBUG
        private let usesUITestFixtures: Bool
    #endif

    init() {
        #if DEBUG
            let usesUITestFixtures =
                ProcessInfo.processInfo.arguments.contains("--cloudnow-ui-testing")
                    || ProcessInfo.processInfo.environment["CLOUDNOW_UI_TESTING"] == "1"
            self.usesUITestFixtures = usesUITestFixtures
            let authManager = usesUITestFixtures
                ? AuthManager(
                    backgroundScheduler: .disabled,
                    schedulesAutomaticRefresh: false,
                    initialSession: Self.uiTestAuthSession
                )
                : AuthManager()
        #else
            let authManager = AuthManager()
        #endif
        _authManager = State(initialValue: authManager)

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
        ) { [authManager] task in
            Task { @MainActor in
                await authManager.refreshIfNeeded()
                authManager.scheduleBackgroundRefresh()
                task.setTaskCompleted(success: true)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
                if usesUITestFixtures {
                    UITestRootView()
                        .environment(authManager)
                } else {
                    productionRoot
                }
            #else
                productionRoot
            #endif
        }
    }

    private var productionRoot: some View {
        Group {
            switch authManager.startupPhase {
            case .pending, .restoringSession:
                AuthRestorationView()
            case .ready:
                if authManager.isAuthenticated {
                    MainTabView()
                } else {
                    LoginView()
                }
            }
        }
        .environment(authManager)
        .task { await authManager.initialize() }
        .onChange(of: authManager.isAuthenticated) { _, authenticated in
            if !authenticated {
                MemoryLifecycleCoordinator.shared.releaseCachedArtwork()
            }
        }
    }

    #if DEBUG
        private static let uiTestAuthSession = AuthSession(
            provider: LoginProvider(
                idpId: "fixture",
                code: "FIXTURE",
                displayName: "Fixture",
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
}

private struct AuthRestorationView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ProgressView()
                .tint(.secondary)
        }
    }
}

#if DEBUG
    private struct UITestRootView: View {
        @State private var viewModel: GamesViewModel

        init() {
            let arguments = ProcessInfo.processInfo.arguments
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
            MainTabView(viewModel: viewModel, loadsRemoteData: false)
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
