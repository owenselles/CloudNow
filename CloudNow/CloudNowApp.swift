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
    private let usesUITestFixtures: Bool

    init() {
        let usesUITestFixtures =
            ProcessInfo.processInfo.arguments.contains("--cloudnow-ui-testing")
                || ProcessInfo.processInfo.environment["CLOUDNOW_UI_TESTING"] == "1"
        self.usesUITestFixtures = usesUITestFixtures

        let authManager = AuthManager()
        _authManager = State(initialValue: authManager)

        URLCache.shared = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024
        )
        guard !usesUITestFixtures else { return }

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
            if usesUITestFixtures {
                UITestRootView()
                    .environment(authManager)
            } else {
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
        }
    }
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

private struct UITestRootView: View {
    @State private var viewModel = GamesViewModel(
        mainGames: fixtureGames,
        libraryGames: fixtureGames,
        favoriteIds: ["fixture-racer"],
        persistenceEnabled: false
    )

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
}
