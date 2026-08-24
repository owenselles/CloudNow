import SwiftUI

private enum ProvidersState {
    case loading
    case loaded([LoginProvider])
}

struct LoginView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(CloudGamingProviderCoordinator.self) private var providerCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var providersState: ProvidersState = .loading
    @State private var selectedProvider: LoginProvider?

    var body: some View {
        ZStack {
            adaptiveBackgroundColor.ignoresSafeArea()

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
            let fetched = await (try? authManager.discoverLoginProviders()) ?? []
            providersState = .loaded(fetched)
        }
    }

    // MARK: Login Prompt

    private var loginPrompt: some View {
        LoginProviderPrompt {
            authManager.cancelLogin()
            providerCoordinator.select(nil)
        } providerContent: {
            switch providersState {
            case .loading:
                ProgressView()
                    .scaleEffect(1.35)
                    .tint(.green)
                    .frame(maxWidth: .infinity)
                    .frame(height: LoginProviderPicker.railHeight)
                    .accessibilityLabel(L10n.text("sign_in_to_geforce_now"))
                    .accessibilityIdentifier("login-provider-loading")
            case let .loaded(providers):
                LoginProviderPicker(
                    providers: providers,
                    onSelect: startLogin
                )
            }
        }
    }

    private func startLogin(with provider: LoginProvider) {
        selectedProvider = provider
        authManager.login(with: provider)
    }

    // MARK: PIN Display

    private func pinView(code: String, url: String, urlComplete: String) -> some View {
        CloudNowDeviceCodeView(
            title: L10n.text("sign_in_to_geforce_now"),
            code: code,
            verificationURL: url,
            verificationURLComplete: urlComplete,
            primaryForegroundColor: .primary,
            secondaryForegroundColor: .secondary,
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
                .tint(.primary)
            Text(L10n.text("signing_in"))
                .font(.title2)
                .foregroundStyle(.primary)
        }
    }

    // MARK: Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 32) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(colorScheme == .dark ? .yellow : .orange)
            Text(L10n.text("sign_in_failed"))
                .font(.title.weight(.semibold))
                .foregroundStyle(.primary)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 24) {
                Button(L10n.text("try_again")) {
                    authManager.login(with: selectedProvider)
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

    private var adaptiveBackgroundColor: Color {
        colorScheme == .dark ? .black : .white
    }
}

struct LoginProviderPrompt<ProviderContent: View>: View {
    let onChooseAnotherService: () -> Void
    @ViewBuilder let providerContent: ProviderContent

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            adaptiveBackgroundColor.ignoresSafeArea()

            VStack(spacing: 36) {
                CloudNowBrandHeader(
                    subtitle: L10n.text("app_tagline"),
                    primaryForegroundColor: .primary,
                    secondaryForegroundColor: .secondary
                )

                VStack(spacing: 18) {
                    Text(L10n.text("sign_in_to_geforce_now"))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)

                    providerContent

                    Text(L10n.text("requires_geforce_now_account"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button(
                            L10n.text("choose_another_service"),
                            action: onChooseAnotherService
                        )
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("login.choose-service")
                    }
                    .frame(maxWidth: .infinity)
                    .focusSection()
                }
            }
            .padding(.horizontal, 72)
            .padding(.vertical, 48)
        }
    }

    private var adaptiveBackgroundColor: Color {
        colorScheme == .dark ? .black : .white
    }
}

struct LoginProviderPicker: View {
    let providers: [LoginProvider]
    let onSelect: (LoginProvider) -> Void

    static let railHeight: CGFloat = 232

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedProvider: String?

    private var displayedProviders: [LoginProvider] {
        providers.isEmpty ? [.nvidiaDirect] : providers
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(displayedProviders, id: \.idpId) { provider in
                        Button {
                            onSelect(provider)
                        } label: {
                            LoginProviderChoiceLabel(
                                provider: provider,
                                isFocused: focusedProvider == provider.idpId
                            )
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .id(provider.idpId)
                        .focused($focusedProvider, equals: provider.idpId)
                        .accessibilityLabel(provider.displayName)
                        .accessibilityHint(L10n.text("sign_in_with_nvidia"))
                        .accessibilityIdentifier("login-provider.\(provider.idpId)")
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
            }
            .scrollTargetBehavior(.viewAligned)
            .defaultScrollAnchor(.center, for: .alignment)
            .scrollClipDisabled()
            .onChange(of: focusedProvider) { _, id in
                guard let id else { return }
                if reduceMotion {
                    proxy.scrollTo(id, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .frame(height: Self.railHeight)
        .focusSection()
        .defaultFocus($focusedProvider, displayedProviders.first?.idpId)
        .accessibilityIdentifier("login-provider-picker")
    }
}

private struct LoginProviderChoiceLabel: View {
    let provider: LoginProvider
    let isFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private let cardShape = RoundedRectangle(
        cornerRadius: 20,
        style: .continuous
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: provider.isNvidiaDirect ? "sparkles.tv.fill" : "network")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .green)
                    .accessibilityHidden(true)

                Spacer()

                Text(provider.code)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(isFocused ? .black.opacity(0.7) : .secondary)
                    .background(
                        isFocused ? Color.black.opacity(0.08) : idleBadgeColor,
                        in: Capsule()
                    )
            }

            Spacer(minLength: 0)

            Text(provider.displayName)
                .font(.system(size: 25, weight: .semibold))
                .lineLimit(2, reservesSpace: true)
                .minimumScaleFactor(0.8)
                .allowsTightening(true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            Label(L10n.text("sign_in_with_nvidia"), systemImage: "arrow.right")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isFocused ? .black.opacity(0.7) : .secondary)
        }
        .foregroundStyle(isFocused ? .black : .primary)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(width: 320, height: 184, alignment: .leading)
        .background(
            isFocused ? Color.green : idleBackgroundColor,
            in: cardShape
        )
        .overlay {
            cardShape.strokeBorder(
                isFocused ? Color.white.opacity(0.8) : idleBorderColor,
                lineWidth: isFocused ? 3 : 1
            )
        }
        .shadow(
            color: isFocused ? Color.green.opacity(0.3) : idleShadowColor,
            radius: isFocused ? 20 : 8,
            y: isFocused ? 8 : 4
        )
        .scaleEffect(isFocused && !reduceMotion ? 1.04 : 1)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: isFocused
        )
        .contentShape(cardShape)
    }

    private var idleBackgroundColor: Color {
        colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.06)
    }

    private var idleBadgeColor: Color {
        colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.06)
    }

    private var idleBorderColor: Color {
        colorScheme == .dark ? .white.opacity(0.2) : .black.opacity(0.16)
    }

    private var idleShadowColor: Color {
        .black.opacity(colorScheme == .dark ? 0.2 : 0.12)
    }
}
