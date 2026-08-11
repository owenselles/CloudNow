import SwiftUI

struct CloudServiceSelectionView: View {
    @Environment(CloudGamingProviderCoordinator.self) private var providerCoordinator
    @FocusState private var focusedProvider: CloudGamingProvider?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 48) {
                CloudNowBrandHeader(subtitle: L10n.text("choose_cloud_gaming_service"))

                HStack(spacing: 28) {
                    ForEach(CloudGamingProvider.allCases) { provider in
                        let availability = providerCoordinator.capabilities(
                            for: provider
                        ).availability
                        Button {
                            providerCoordinator.select(provider)
                        } label: {
                            CloudServiceChoiceLabel(
                                provider: provider,
                                isFocused: focusedProvider == provider,
                                availability: availability
                            )
                        }
                        .buttonStyle(.bordered)
                        .tint(provider == .geForceNow ? .green : .blue)
                        .focused($focusedProvider, equals: provider)
                        .disabled(!availability.isSupported)
                        .accessibilityLabel(provider.displayName)
                        .accessibilityValue(
                            availability.unavailableReason.map {
                                L10n.text($0.localizationKey)
                            } ?? ""
                        )
                        .accessibilityIdentifier("service-choice.\(provider.rawValue)")
                    }
                }
                .defaultFocus($focusedProvider, .geForceNow)

                Text(L10n.text("accounts_stay_signed_in_when_switching_services"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(80)
        }
        .accessibilityIdentifier("service-chooser")
    }
}

struct XboxCloudConfigurationRequiredView: View {
    @Environment(CloudGamingProviderCoordinator.self) private var providerCoordinator

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 36) {
                Image(systemName: CloudGamingProvider.xboxCloudGaming.systemImage)
                    .font(.system(size: 72))
                    .foregroundStyle(.blue)

                VStack(spacing: 12) {
                    Text(CloudGamingProvider.xboxCloudGaming.displayName)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    Text(L10n.text("awaiting_official_xbox_cloud_support"))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text(
                    availabilityMessage
                )
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 920)

                HStack(spacing: 24) {
                    Button {
                        providerCoordinator.select(.geForceNow)
                    } label: {
                        Label(L10n.text("use_geforce_now"), systemImage: "sparkles.tv")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button(L10n.text("choose_another_service")) {
                        providerCoordinator.select(nil)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(80)
        }
        .accessibilityIdentifier("service-shell.xbox-cloud-gaming")
    }

    private var availabilityMessage: String {
        providerCoordinator.capabilities(
            for: .xboxCloudGaming
        ).availability.unavailableReason.map {
            L10n.text($0.localizationKey)
        } ?? L10n.text("xbox_cloud_runtime_inactive_message")
    }
}

struct CloudNowBrandHeader: View {
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 80))
                .foregroundStyle(.white)
            Text(L10n.text("app_name"))
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CloudServiceChoiceLabel: View {
    let provider: CloudGamingProvider
    let isFocused: Bool
    let availability: CloudCapability<CloudProviderAvailabilityCapability>

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: provider.systemImage)
                .font(.system(size: 42, weight: .semibold))
            Text(provider.displayName)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let reason = availability.unavailableReason {
                Text(L10n.text(reason.localizationKey))
                    .font(.caption)
                    .foregroundStyle(isFocused ? .black.opacity(0.7) : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(isFocused ? .black : .white)
        .frame(width: 410, height: 150)
        .contentShape(Rectangle())
    }
}
