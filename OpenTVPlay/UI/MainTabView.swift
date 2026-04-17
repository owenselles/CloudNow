import SwiftUI

struct MainTabView: View {
    @Environment(AuthManager.self) var authManager
    @State private var viewModel = GamesViewModel()
    @State private var gameToPlay: GameInfo?
    @State private var sessionToResume: ActiveSessionInfo? = nil

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                HomeView(onPlay: { game in
                    // If this game has an active session, set it up for resume
                    sessionToResume = viewModel.activeSessions.first { session in
                        game.variants.contains { v in
                            guard let appId = v.appId, let sessionAppId = session.appId else { return false }
                            return appId == sessionAppId
                        }
                    }
                    gameToPlay = game
                })
            }
            Tab("Library", systemImage: "books.vertical.fill") {
                LibraryView(games: viewModel.libraryGames, onPlay: { gameToPlay = $0 })
            }
            Tab("Store", systemImage: "bag.fill") {
                StoreView(games: viewModel.mainGames, onPlay: { gameToPlay = $0 })
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
        .environment(viewModel)
        .task { await viewModel.load(authManager: authManager) }
        .onChange(of: viewModel.streamSettings) { viewModel.saveSettings() }
        .onChange(of: gameToPlay) { _, new in
            // Refresh active sessions when the user exits a game
            if new == nil {
                Task { await viewModel.refreshActiveSessions(authManager: authManager) }
            }
        }
        .fullScreenCover(item: $gameToPlay) { game in
            StreamView(
                game: game,
                settings: viewModel.streamSettings,
                existingSession: sessionToResume,
                onDismiss: {
                    gameToPlay = nil
                    sessionToResume = nil
                }
            )
            .environment(authManager)
            .environment(viewModel)
        }
    }
}
