import SwiftUI

struct InstallToPlaySettingsView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(GamesViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    @State private var subscription: SubscriptionInfo?
    @State private var isLoading = true
    @State private var refreshFailed = false
    @State private var refreshRevision = 0
    @State private var showAccount = false

    var body: some View {
        Form {
            Section {
                Button {
                    refreshRevision += 1
                } label: {
                    HStack {
                        Label(L10n.text("gfn_game_check_status"), systemImage: "arrow.clockwise")
                        Spacer()
                        if isLoading {
                            ProgressView()
                        }
                    }
                }
                .disabled(isLoading)
                .accessibilityIdentifier("install-to-play.refresh")

                LabeledContent(L10n.text("access"), value: accessDescription)
                    .accessibilityIdentifier("install-to-play.access")
                if let membership = subscription?.membershipTier {
                    LabeledContent(L10n.text("membership"), value: membership)
                }
                if refreshFailed {
                    Text(L10n.text("install_to_play_status_failed"))
                        .foregroundStyle(.red)
                }
            } header: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("install_to_play"))
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                    Text(L10n.text("install_to_play_settings_description"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .textCase(nil)
            }

            Section(L10n.text("cloud_storage")) {
                if let storage = subscription?.cloudStorage {
                    LabeledContent(L10n.text("cloud_storage"), value: storageDescription(storage))
                    if !storage.isUsable {
                        Text(L10n.text("unavailable"))
                            .foregroundStyle(.secondary)
                    }
                    if let total = storage.totalGB {
                        LabeledContent(L10n.text("cloud_storage_capacity"), value: "\(total.formatted()) GB")
                    }
                    if let used = storage.usedGB {
                        LabeledContent(L10n.text("cloud_storage_used"), value: "\(used.formatted()) GB")
                    }
                    if let remaining = storage.remainingGB {
                        LabeledContent(L10n.text("cloud_storage_remaining"), value: "\(remaining.formatted()) GB")
                    }
                    if storage.isPersistent, let region = storage.regionName, !region.isEmpty {
                        LabeledContent(L10n.text("region"), value: region)
                    }
                    if storage.kind == .singleSession {
                        Text(L10n.text("install_to_play_session_warning"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.text(isLoading ? "install_to_play_checking" : "unknown"))
                        .foregroundStyle(.secondary)
                }

                Button {
                    showAccount = true
                } label: {
                    Label(L10n.text("manage_cloud_storage"), systemImage: "qrcode")
                }
                .accessibilityIdentifier("install-to-play.manage-storage")
            }
        }
        .navigationTitle("")
        .accessibilityIdentifier("settings.install-to-play.page")
        .task(id: refreshRevision) {
            await refreshStatus()
        }
        .fullScreenCover(
            isPresented: $showAccount,
            onDismiss: { refreshRevision += 1 },
            content: { InstallToPlayAccountView() }
        )
        .onExitCommand {
            dismiss()
        }
        .blocksGlobalControllerNavigation()
    }

    private var accessDescription: String {
        if isLoading {
            return L10n.text("install_to_play_checking")
        }
        switch subscription?.installToPlayAccess {
        case true: return L10n.text("install_to_play_available")
        case false: return L10n.text("not_eligible")
        default: return L10n.text("access_not_confirmed")
        }
    }

    private func storageDescription(_ storage: GFNCloudStorage) -> String {
        switch storage.kind {
        case .persistent: L10n.text("cloud_storage_persistent")
        case .singleSession: L10n.text("cloud_storage_single_session")
        case .unknown: L10n.text("unknown")
        }
    }

    private func refreshStatus() async {
        let revision = refreshRevision
        isLoading = true
        refreshFailed = false
        subscription = nil
        defer {
            if refreshRevision == revision {
                isLoading = false
            }
        }
        do {
            let updated = try await viewModel.refreshInstallToPlayStatus(authManager: authManager)
            try Task.checkCancellation()
            subscription = updated
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            refreshFailed = true
        }
    }
}

struct InstallToPlayAccountView: View {
    @Environment(\.dismiss) private var dismiss

    private let accountURL = "https://gfn.link/cloudstorage"

    var body: some View {
        VStack(spacing: 32) {
            Text(L10n.text("manage_cloud_storage"))
                .font(.title.weight(.semibold))
            QRCodeView(payload: accountURL)
                .frame(width: 280, height: 280)
                .clipShape(.rect(cornerRadius: 16))
                .accessibilityLabel(L10n.text("scan_qr_or_go_to"))
                .accessibilityValue(accountURL)
            Text(L10n.text("cloud_storage_phone_description"))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(accountURL)
                .font(.system(size: 32, weight: .semibold, design: .monospaced))
            Button(L10n.text("close")) {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityIdentifier("install-to-play.account")
        .onExitCommand {
            dismiss()
        }
        .blocksGlobalControllerNavigation()
    }
}
