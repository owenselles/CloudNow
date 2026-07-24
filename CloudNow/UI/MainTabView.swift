import SwiftUI
import UIKit

struct MainTabView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: GamesViewModel
    @State private var gameToPlay: GameInfo?
    @State private var sessionToResume: ActiveSessionInfo? = nil
    @State private var directSessionToResume: SessionInfo? = nil
    @State private var selectedTab: AppTab = .home
    @State private var controllerNavigation = UIControllerNavigationCoordinator()
    private let loadsRemoteData: Bool

    init(
        viewModel: GamesViewModel = GamesViewModel(),
        loadsRemoteData: Bool = true
    ) {
        _viewModel = State(initialValue: viewModel)
        self.loadsRemoteData = loadsRemoteData
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(L10n.text("home"), systemImage: "house.fill", value: AppTab.home) {
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
                .accessibilityIdentifier("home-screen")
            }
            Tab(L10n.text("library"), systemImage: "books.vertical.fill", value: AppTab.library) {
                LibraryView(onPlay: { gameToPlay = $0 })
                    .accessibilityIdentifier("library-screen")
            }
            Tab(L10n.text("store"), systemImage: "bag.fill", value: AppTab.store) {
                StoreView(onPlay: { gameToPlay = $0 })
                    .accessibilityIdentifier("store-screen")
            }
            Tab(L10n.text("settings"), systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
                    .accessibilityIdentifier("settings-screen")
            }
        }
        .accessibilityIdentifier("main-navigation")
        .environment(viewModel)
        .environment(controllerNavigation)
        .onAppear {
            controllerNavigation.start(
                onPreviousTab: { selectedTab = selectedTab.previous },
                onNextTab: { selectedTab = selectedTab.next }
            )
        }
        .task {
            guard loadsRemoteData else { return }
            await viewModel.load(authManager: authManager)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                MemoryLifecycleCoordinator.shared.appDidBecomeActive()
                if loadsRemoteData {
                    Task { await viewModel.refreshLibrary(authManager: authManager) }
                }
            case .background:
                MemoryLifecycleCoordinator.shared.appDidEnterBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            MemoryLifecycleCoordinator.shared.didReceiveMemoryWarning()
        }
        .onChange(of: viewModel.streamSettings) { viewModel.saveSettings() }
        .onChange(of: gameToPlay) { _, new in
            if new == nil {
                MemoryLifecycleCoordinator.shared.streamDidClose()
                directSessionToResume = nil
                Task { await viewModel.refreshActiveSessions(authManager: authManager) }
            } else {
                MemoryLifecycleCoordinator.shared.streamWillOpen()
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
            .blocksGlobalControllerNavigation(mode: .streaming)
            .environment(controllerNavigation)
        }
    }
}

private enum AppTab: Hashable {
    case home
    case library
    case store
    case settings

    var next: AppTab {
        switch self {
        case .home:
            .library
        case .library:
            .store
        case .store:
            .settings
        case .settings:
            .home
        }
    }

    var previous: AppTab {
        switch self {
        case .home:
            .settings
        case .library:
            .home
        case .store:
            .library
        case .settings:
            .store
        }
    }
}
