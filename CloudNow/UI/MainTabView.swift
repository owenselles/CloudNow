import GameController
import SwiftUI
import UIKit

struct MainTabView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = GamesViewModel()
    @State private var gameToPlay: GameInfo?
    @State private var sessionToResume: ActiveSessionInfo? = nil
    @State private var directSessionToResume: SessionInfo? = nil
    @State private var selectedTab: AppTab = .home

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
            }
            Tab(L10n.text("library"), systemImage: "books.vertical.fill", value: AppTab.library) {
                LibraryView(games: viewModel.libraryGames, onPlay: { gameToPlay = $0 })
            }
            Tab(L10n.text("store"), systemImage: "bag.fill", value: AppTab.store) {
                StoreView(games: viewModel.mainGames, onPlay: { gameToPlay = $0 })
            }
            Tab(L10n.text("settings"), systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
        .background(
            ControllerTabNavigationBridge(
                isEnabled: gameToPlay == nil,
                onPrevious: { selectedTab = selectedTab.previous },
                onNext: { selectedTab = selectedTab.next }
            )
        )
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

private struct ControllerTabNavigationBridge: UIViewControllerRepresentable {
    let isEnabled: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPrevious: onPrevious, onNext: onNext)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        context.coordinator.viewController
    }

    func updateUIViewController(_: UIViewController, context: Context) {
        context.coordinator.onPrevious = onPrevious
        context.coordinator.onNext = onNext
        context.coordinator.isEnabled = isEnabled
        context.coordinator.refreshControllerHandlers()
    }

    final class Coordinator {
        let viewController = UIViewController()

        var onPrevious: () -> Void
        var onNext: () -> Void

        var isEnabled: Bool = false {
            didSet {
                refreshControllerHandlers()
            }
        }

        private var observers: [NSObjectProtocol] = []

        init(onPrevious: @escaping () -> Void, onNext: @escaping () -> Void) {
            self.onPrevious = onPrevious
            self.onNext = onNext
            registerForControllerNotifications()
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            clearControllerHandlers()
        }

        func refreshControllerHandlers() {
            for controller in GCController.controllers() {
                installHandlers(on: controller)
            }
        }

        private func registerForControllerNotifications() {
            let center = NotificationCenter.default
            observers.append(
                center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] notification in
                    guard let controller = notification.object as? GCController else { return }
                    self?.installHandlers(on: controller)
                }
            )
            observers.append(
                center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                    self?.clearControllerHandlers()
                    self?.refreshControllerHandlers()
                }
            )
            refreshControllerHandlers()
        }

        private func clearControllerHandlers() {
            for controller in GCController.controllers() {
                controller.extendedGamepad?.leftShoulder.pressedChangedHandler = nil
                controller.extendedGamepad?.rightShoulder.pressedChangedHandler = nil
            }
        }

        private func installHandlers(on controller: GCController) {
            guard let gamepad = controller.extendedGamepad else { return }

            if isEnabled {
                gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
                    guard pressed else { return }
                    self?.triggerPrevious()
                }
                gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
                    guard pressed else { return }
                    self?.triggerNext()
                }
            } else {
                gamepad.leftShoulder.pressedChangedHandler = nil
                gamepad.rightShoulder.pressedChangedHandler = nil
            }
        }

        private func triggerPrevious() {
            let action = onPrevious
            DispatchQueue.main.async {
                action()
            }
        }

        private func triggerNext() {
            let action = onNext
            DispatchQueue.main.async {
                action()
            }
        }
    }
}
