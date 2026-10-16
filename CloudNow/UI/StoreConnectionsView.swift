import SwiftUI

struct StoreConnectionsView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(GamesViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    @State private var hasRequestedConnections = false
    @State private var pendingDisconnect: StoreConnection?
    @State private var showLibraryRefreshProgress = false

    private var connections: StoreConnectionsCoordinator {
        viewModel.storeConnections
    }

    private var actionsDisabled: Bool {
        connections.isBusy || !viewModel.canManageStoreConnections
    }

    var body: some View {
        Form {
            title

            Section {
                Button {
                    viewModel.refreshStoreConnections(authManager: authManager)
                } label: {
                    HStack {
                        Label(L10n.text("refresh_connections"), systemImage: "arrow.clockwise")
                        Spacer()
                        if connections.isLoading {
                            ProgressView()
                        }
                    }
                }
                .disabled(actionsDisabled)
                .accessibilityIdentifier("store-connections.refresh")

                if viewModel.libraryRefreshState.stage != .idle {
                    Button {
                        showLibraryRefreshProgress = true
                    } label: {
                        Label(L10n.text("library_refresh_progress"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityIdentifier("store-connections.progress")
                }

                if let error = connections.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("store-connections.error")
                }
            }

            ForEach(connections.stores) { store in
                storeSection(store)
            }
        }
        .navigationTitle("")
        .accessibilityIdentifier("settings.store-connections.page")
        .task(id: viewModel.canManageStoreConnections) {
            guard !hasRequestedConnections, viewModel.canManageStoreConnections else { return }
            hasRequestedConnections = true
            viewModel.refreshStoreConnections(authManager: authManager)
        }
        .onChange(of: viewModel.isFullLibraryRefreshRunning) { wasRunning, isRunning in
            if wasRunning, !isRunning, !showLibraryRefreshProgress {
                viewModel.refreshStoreConnections(authManager: authManager)
            }
        }
        .fullScreenCover(isPresented: authorizationIsPresented) {
            authorizationView
        }
        .fullScreenCover(
            isPresented: $showLibraryRefreshProgress,
            onDismiss: { viewModel.refreshStoreConnections(authManager: authManager) },
            content: { LibraryRefreshProgressView() }
        )
        .alert(
            pendingDisconnect.map { L10n.format("disconnect_store_title", $0.displayName) } ?? "",
            isPresented: disconnectIsPresented,
            presenting: pendingDisconnect
        ) { store in
            Button(L10n.text("disconnect_store"), role: .destructive) {
                viewModel.disconnectStore(store, authManager: authManager)
                pendingDisconnect = nil
            }
            Button(L10n.text("cancel"), role: .cancel) {
                pendingDisconnect = nil
            }
        } message: { store in
            Text(L10n.format("disconnect_store_message", store.displayName))
        }
        .onExitCommand {
            viewModel.cancelStoreConnection()
            dismiss()
        }
        .onDisappear {
            if connections.authorization == nil, !showLibraryRefreshProgress {
                viewModel.cancelStoreConnection()
            }
        }
        .blocksGlobalControllerNavigation()
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("connected_stores"))
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(L10n.text("store_linking_phone_description"))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
    }

    private func storeSection(_ store: StoreConnection) -> some View {
        Section {
            storeStatus(store)

            if store.supportsLinking {
                if !store.isConnected || store.requiresReconnect {
                    Button {
                        viewModel.connectStore(store, authManager: authManager)
                    } label: {
                        Label(
                            store.requiresReconnect ? L10n.text("reconnect_store") : L10n.text("connect_store"),
                            systemImage: "link"
                        )
                    }
                    .disabled(actionsDisabled)
                    .accessibilityIdentifier("store-connections.connect.\(store.code)")
                }

                if store.isConnected {
                    if store.supportsSync, !store.requiresReconnect {
                        Button {
                            viewModel.startStoreLibraryRefresh(providerCode: store.code, authManager: authManager)
                            showLibraryRefreshProgress = true
                        } label: {
                            Label(L10n.text("resync_store"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(actionsDisabled)
                        .accessibilityIdentifier("store-connections.resync.\(store.code)")
                    }

                    Button(role: .destructive) {
                        pendingDisconnect = store
                    } label: {
                        Label(L10n.text("disconnect_store"), systemImage: "xmark.circle")
                    }
                    .disabled(actionsDisabled)
                    .accessibilityIdentifier("store-connections.disconnect.\(store.code)")
                }
            }
        } header: {
            Text(store.displayName)
        } footer: {
            Text(capabilities(for: store))
        }
    }

    private func storeStatus(_ store: StoreConnection) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(status(for: store))
                if let account = store.accountDisplayName, !account.isEmpty {
                    Text(account)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let count = store.snapshot?.totalSyncedGames,
                   store.snapshot?.state == .success,
                   store.supportsSync
                {
                    Text(L10n.format("provider_sync_succeeded_count", count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if connections.activeStoreCode == store.code {
                ProgressView()
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("store-connections.status.\(store.code)")
    }

    @ViewBuilder
    private var authorizationView: some View {
        if let authorization = connections.authorization {
            let storeName = connections.stores.first { $0.code == connections.activeStoreCode }?.displayName ?? ""
            ZStack {
                Color.black.ignoresSafeArea()
                CloudNowDeviceCodeView(
                    title: L10n.format("store_connect_title", storeName),
                    code: authorization.userCode,
                    verificationURL: authorization.verificationURL.absoluteString,
                    verificationURLComplete: authorization.verificationURLComplete.absoluteString,
                    accessibilityIdentifier: "store-device-code-login",
                    secondaryForegroundColor: .white.opacity(0.7),
                    onCancel: viewModel.cancelStoreConnection
                )
            }
            .onExitCommand {
                viewModel.cancelStoreConnection()
            }
            .blocksGlobalControllerNavigation()
        }
    }

    private var authorizationIsPresented: Binding<Bool> {
        Binding(
            get: { connections.authorization != nil },
            set: { isPresented in
                if !isPresented, connections.authorization != nil {
                    viewModel.cancelStoreConnection()
                }
            }
        )
    }

    private var disconnectIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDisconnect != nil },
            set: {
                if !$0 {
                    pendingDisconnect = nil
                }
            }
        )
    }

    private func status(for store: StoreConnection) -> String {
        if !store.supportsLinking {
            return L10n.text("store_sign_in_when_launching")
        }
        if store.requiresReconnect {
            return L10n.text("provider_sync_relink_required")
        }
        return store.isConnected ? L10n.text("connected") : L10n.text("disconnected")
    }

    private func capabilities(for store: StoreConnection) -> String {
        guard store.supportsLinking else {
            return L10n.text("store_linking_unavailable")
        }
        var descriptions: [String] = []
        if store.supportsSync {
            descriptions.append(L10n.text("store_library_sync"))
        }
        descriptions.append(
            store.supportsAutomaticSignIn
                ? L10n.text("store_automatic_sign_in")
                : L10n.text("store_sign_in_when_launching")
        )
        return descriptions.joined(separator: " · ")
    }
}
