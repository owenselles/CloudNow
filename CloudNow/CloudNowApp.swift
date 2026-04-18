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
    #if os(visionOS)
    /// Drives the ImmersiveSpace immersion level. Seeded from AppStorage on launch;
    /// the user can also toggle between .full and .mixed with the Digital Crown at runtime.
    @AppStorage("gfn.immersionStyle") private var immersionStyleRaw: String = "full"
    @State private var immersionStyle: ImmersionStyle = .full
    #endif

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
        }
        .immersionStyle(selection: $immersionStyle, in: .full, .mixed)
        #endif
    }
}
