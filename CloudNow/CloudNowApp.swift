//
//  CloudNowApp.swift
//  CloudNow
//
//  Created by Owen Selles on 11/04/2026.
//

import SwiftUI

@main
struct CloudNowApp: App {
    @State private var authManager = AuthManager()

    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024
        )
    }

    var body: some Scene {
        WindowGroup {
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
        .backgroundTask(.appRefresh("com.owenselles.CloudNow.tokenRefresh")) {
            await authManager.refreshIfNeeded()
            await authManager.scheduleBackgroundRefresh()
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
