import SwiftUI

struct GameLaunchOptionsView: View {
    let gameID: String
    let gameTitle: String
    @Environment(GamesViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedRow: Row?

    private enum Row: Hashable {
        case launch
        case remote
        case done
    }

    private var preferences: GFNGamePreferences {
        viewModel.streamSettings.gamePreferences[gameID] ?? GFNGamePreferences()
    }

    private func binding<Value>(for keyPath: WritableKeyPath<GFNGamePreferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { value in
                var updated = preferences
                updated[keyPath: keyPath] = value
                viewModel.streamSettings.setGamePreferences(updated, for: gameID)
            }
        )
    }

    var body: some View {
        Form {
            CloudNowSettingsPageTitle(title: gameTitle, accessibilityIdentifier: "game.preferences.title")
            Section {
                CloudNowSettingSelectionRow(
                    L10n.text("game_launch_mode"),
                    description: L10n.text("game_preferences_launch_description"),
                    selection: binding(for: \.launchMode),
                    accessibilityIdentifier: "game.preferences.launch",
                    options: [
                        CloudNowSettingOption(value: nil, title: L10n.text("use_app_settings"), accessibilityIdentifier: "inherit"),
                        CloudNowSettingOption(value: AppLaunchMode.default, title: L10n.text("launch_mode_desktop"), accessibilityIdentifier: "desktop"),
                        CloudNowSettingOption(value: AppLaunchMode.bigPicture, title: L10n.appLaunchModeLabel(.bigPicture), accessibilityIdentifier: "tv"),
                    ]
                )
                .focused($focusedRow, equals: .launch)
                CloudNowSettingSelectionRow(
                    L10n.text("game_preferences_remote"),
                    description: L10n.text("game_preferences_remote_description"),
                    selection: binding(for: \.remoteMode),
                    accessibilityIdentifier: "game.preferences.remote",
                    options: [
                        CloudNowSettingOption(value: nil, title: L10n.text("use_app_settings"), accessibilityIdentifier: "inherit"),
                        CloudNowSettingOption(value: RemoteInputMode.gamepadMouse, title: L10n.remoteInputModeLabel(.gamepadMouse), accessibilityIdentifier: "mouse"),
                        CloudNowSettingOption(value: RemoteInputMode.gamepad, title: L10n.remoteInputModeLabel(.gamepad), accessibilityIdentifier: "gamepad"),
                        CloudNowSettingOption(value: RemoteInputMode.dualsense, title: L10n.remoteInputModeLabel(.dualsense), accessibilityIdentifier: "touchpad"),
                    ]
                )
                .focused($focusedRow, equals: .remote)
            } header: {
                Text(L10n.text("game_preferences"))
                    .foregroundStyle(.primary)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("game_preferences_mixed_input"))
                    Text(L10n.text("game_preferences_new_session"))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Section {
                Button(L10n.text("done")) { dismiss() }
                    .accessibilityIdentifier("game.preferences.done")
                    .focused($focusedRow, equals: .done)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .background((colorScheme == .dark ? Color.black : Color.white).ignoresSafeArea())
        .preferredColorScheme(colorScheme)
        .defaultFocus($focusedRow, .launch)
        .task {
            await Task.yield()
            focusedRow = .launch
        }
        .blocksGlobalControllerNavigation()
    }
}

#if DEBUG
    struct GamePreferencesUITestFixtureView: View {
        @State private var presented = false
        @State private var controllerNavigation = UIControllerNavigationCoordinator()

        var body: some View {
            Button(L10n.text("game_preferences")) { presented = true }
                .accessibilityIdentifier("game.preferences.open")
                .fullScreenCover(isPresented: $presented) {
                    NavigationStack {
                        GameLaunchOptionsView(gameID: "fixture-adventure", gameTitle: "Fixture Adventure")
                    }
                    .environment(controllerNavigation)
                }
        }
    }
#endif
