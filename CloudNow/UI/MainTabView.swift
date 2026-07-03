import SwiftUI

struct MainTabView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = GamesViewModel()
    @State private var gameToPlay: GameInfo?
    @State private var sessionToResume: ActiveSessionInfo? = nil
    @State private var directSessionToResume: SessionInfo? = nil

    var body: some View {
        TabView {
            Tab(L10n.text("home"), systemImage: "house.fill") {
                HomeView(
                    onPlay: { game in
                        directSessionToResume = nil
                        sessionToResume = viewModel.activeSessions.first { session in
                            game.variants.contains { v in
                                guard let appId = v.appId, let sessionAppId = session.appId else { return false }
                                return appId == sessionAppId
                            }
                        }
                        gameToPlay = game
                    },
                    onResume: { rs in
                        directSessionToResume = rs.session
                        sessionToResume = nil
                        gameToPlay = rs.game
                    }
                )
            }
            Tab(L10n.text("library"), systemImage: "books.vertical.fill") {
                LibraryView(games: viewModel.libraryGames, onPlay: { gameToPlay = $0 })
            }
            Tab(L10n.text("store"), systemImage: "bag.fill") {
                StoreView(games: viewModel.mainGames, onPlay: { gameToPlay = $0 })
            }
            Tab(L10n.text("settings"), systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
        .environment(viewModel)
        .task { await viewModel.load(authManager: authManager) }
        .task { await viewModel.measureTopZones() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await viewModel.refreshLibrary(authManager: authManager) }
        }
        .onChange(of: viewModel.streamSettings) { viewModel.saveSettings() }
        .onChange(of: gameToPlay) { _, new in
            if new == nil {
                directSessionToResume = nil
                Task { await viewModel.refreshActiveSessions(authManager: authManager) }
            }
        }
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
    }
}
