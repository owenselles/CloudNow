import SwiftUI

struct LoginView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(CloudGamingProviderCoordinator.self) private var providerCoordinator
    @State private var providers: [LoginProvider]?
    @FocusState private var focusedProvider: String?

    var body: some View {
        ZStack {
            switch authManager.loginPhase {
            case .idle:
                loginPrompt
            case let .showingPIN(code, url, urlComplete):
                pinView(code: code, url: url, urlComplete: urlComplete)
            case .exchangingTokens:
                exchangingView
            case let .failed(message):
                failedView(message: message)
            }
        }
        .task {
            providers = try? await NVIDIAAuthAPI().fetchProviders()
        }
    }

    // MARK: Login Prompt

    private var loginPrompt: some View {
        VStack(spacing: 48) {
            CloudNowBrandHeader(subtitle: L10n.text("app_tagline"))

            VStack(spacing: 16) {
                if let providers, providers.count > 1 {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 16) {
                                ForEach(providers, id: \.idpId) { provider in
                                    Button {
                                        authManager.login(with: provider)
                                    } label: {
                                        Label(provider.displayName, systemImage: "person.badge.key")
                                            .font(.title2.weight(.semibold))
                                            .padding(.horizontal, 40)
                                            .padding(.vertical, 16)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.green)
                                    .id(provider.idpId)
                                    .focused($focusedProvider, equals: provider.idpId)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .onChange(of: focusedProvider) { _, id in
                            guard let id else { return }
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                } else {
                    Button {
                        authManager.login()
                    } label: {
                        Label(L10n.text("sign_in_with_nvidia"), systemImage: "person.badge.key")
                            .font(.title2.weight(.semibold))
                            .padding(.horizontal, 40)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                }

                Text(L10n.text("requires_geforce_now_account"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button(L10n.text("choose_another_service")) {
                    authManager.cancelLogin()
                    providerCoordinator.select(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(80)
    }

    // MARK: PIN Display

    private func pinView(code: String, url: String, urlComplete: String) -> some View {
        CloudNowDeviceCodeView(
            title: L10n.text("sign_in_to_geforce_now"),
            code: code,
            verificationURL: url,
            verificationURLComplete: urlComplete,
            onCancel: {
                authManager.cancelLogin()
            }
        )
    }

    // MARK: Exchanging Tokens

    private var exchangingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(2)
                .tint(.white)
            Text(L10n.text("signing_in"))
                .font(.title2)
                .foregroundStyle(.white)
        }
    }

    // MARK: Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 32) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.yellow)
            Text(L10n.text("sign_in_failed"))
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 24) {
                Button(L10n.text("try_again")) {
                    authManager.login()
                }
                .buttonStyle(.bordered)
                .tint(.green)

                Button(L10n.text("cancel")) {
                    authManager.cancelLogin()
                    providerCoordinator.select(nil)
                }
                .buttonStyle(.bordered)
                .tint(.gray)
            }
        }
        .padding(80)
    }
}
