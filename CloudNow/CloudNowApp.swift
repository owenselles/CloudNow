//
//  CloudNowApp.swift
//  CloudNow
//
//  Created by Owen Selles on 11/04/2026.
//

#if os(tvOS)
import BackgroundTasks
#endif
import SwiftUI

@main
struct CloudNowApp: App {
    @State private var authManager = AuthManager()
    /// Owned here so it can be injected into both WindowGroup and ImmersiveSpace (visionOS),
    /// sharing the same instance (pendingGame visibility). On tvOS this is the single owner too.
    @State private var viewModel = GamesViewModel()
    #if os(visionOS)
    /// Drives the ImmersiveSpace immersion level. Seeded from AppStorage on launch;
    /// the user can also toggle between .full and .mixed with the Digital Crown at runtime.
    @AppStorage("gfn.immersionStyle") private var immersionStyleRaw: String = "full"
    @State private var immersionStyle: ImmersionStyle = .full
    #endif

    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isAuthenticated {
                    MainTabView()
                } else {
                    LoginView()
                }
            }
            .environment(authManager)
            .environment(viewModel)
            #if os(tvOS)
            .onAppear { registerBGTasks() }
            #endif
            .task { await authManager.initialize() }
            #if os(visionOS)
            .task {
                immersionStyle = immersionStyleRaw == "mixed" ? .mixed : .full
            }
            .onChange(of: immersionStyleRaw) { _, raw in
                immersionStyle = raw == "mixed" ? .mixed : .full
            }
            #endif
        }

        #if os(visionOS)
        ImmersiveSpace(id: "stream") {
            ImmersiveStreamView()
                .environment(authManager)
                .environment(viewModel)
        }
        .immersionStyle(selection: $immersionStyle, in: .full, .mixed)
        #endif
    }

    #if os(tvOS)
    private func registerBGTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.owenselles.CloudNow.tokenRefresh",
            using: nil
        ) { task in
            Task { @MainActor in
                await authManager.refreshIfNeeded()
                authManager.scheduleBackgroundRefresh()
                task.setTaskCompleted(success: true)
            }
        }
    }
    #endif
}
