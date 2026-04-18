#if os(visionOS)
import SwiftUI

/// Root content view for the streaming ImmersiveSpace scene.
/// Reads the pending game set by MainTabView before the space was opened,
/// hosts StreamView full-screen, and dismisses the space when the stream ends.
struct ImmersiveStreamView: View {
    @Environment(GamesViewModel.self) var viewModel
    @Environment(AuthManager.self) var authManager
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace

    var body: some View {
        if let game = viewModel.pendingGame {
            ZStack {
                Color.black.ignoresSafeArea()
                StreamView(
                    game: game,
                    settings: viewModel.streamSettings,
                    existingSession: viewModel.pendingSession,
                    onDismiss: {
                        viewModel.pendingGame = nil
                        viewModel.pendingSession = nil
                        Task { await dismissImmersiveSpace() }
                    }
                )
                .environment(authManager)
                .environment(viewModel)
            }
        }
    }
}
#endif
