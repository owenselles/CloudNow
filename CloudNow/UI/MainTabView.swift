import SwiftUI

struct MainTabView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(GamesViewModel.self) var viewModel
    @State private var gameToPlay: GameInfo?
    @State private var sessionToResume: ActiveSessionInfo? = nil
    @State private var directSessionToResume: SessionInfo? = nil
    #if os(visionOS)
    @Environment(\.openImmersiveSpace) var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace
    #endif

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                HomeView(
                    onPlay: { game in
                        directSessionToResume = nil
                        sessionToResume = viewModel.activeSessions.first { session in
                            game.variants.contains { v in
                                guard let appId = v.appId, let sessionAppId = session.appId else { return false }
                                return appId == sessionAppId
                            }
                        }
                        play(game, session: sessionToResume)
                    },
                    onResume: { rs in
                        directSessionToResume = rs.session
                        sessionToResume = nil
                        gameToPlay = rs.game
                    }
                )
            }
            Tab("Library", systemImage: "books.vertical.fill") {
                LibraryView(games: viewModel.libraryGames, onPlay: { play($0) })
            }
            Tab("Store", systemImage: "bag.fill") {
                StoreView(games: viewModel.mainGames, onPlay: { play($0) })
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
        .task { await viewModel.load(authManager: authManager) }
        .onChange(of: viewModel.streamSettings) { viewModel.saveSettings() }
        .onChange(of: gameToPlay) { _, new in
            if new == nil {
                directSessionToResume = nil
                Task { await viewModel.refreshActiveSessions(authManager: authManager) }
            }
        }
        #if os(visionOS)
        .onChange(of: gameToPlay) { _, game in
            guard let game else { return }
            viewModel.pendingGame = game
            viewModel.pendingSession = sessionToResume
            Task { await openImmersiveSpace(id: "stream") }
        }
        .onChange(of: viewModel.pendingGame) { _, pending in
            if pending == nil {
                gameToPlay = nil
                sessionToResume = nil
            }
        }
        #else
        .fullScreenCover(item: $gameToPlay) { game in
            StreamView(
                game: game,
                settings: viewModel.streamSettings,
                existingSession: sessionToResume,
                directSession: directSessionToResume,
                onDismiss: {
                    gameToPlay = nil
                    sessionToResume = nil
                },
                onLeave: { leftGame, session in
                    viewModel.resumableSession = ResumableSession(
                        game: leftGame,
                        session: session,
                        leftAt: Date()
                    )
                }
            )
            .environment(authManager)
            .environment(viewModel)
        }
        #endif
    }

    private func play(_ game: GameInfo, session: ActiveSessionInfo? = nil) {
        sessionToResume = session
        gameToPlay = game
    }
}
