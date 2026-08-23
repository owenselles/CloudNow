import Foundation

/// Converts Xbox runtime readiness into provider-neutral capabilities. Service
/// options remain conservative until the bundled profile or live service has
/// explicitly confirmed them.
nonisolated struct XboxCapabilityAdapter: CloudGamingCapabilityProviding {
    let provider = CloudGamingProvider.xboxCloudGaming
    let capabilities: CloudGamingProviderCapabilities

    init(environment: XboxCloudEnvironment) {
        let unavailableReason = switch environment
            .serviceConfigurationFailure
        {
        case .invalidCompatibilityProfile:
            CloudCapabilityReason(
                .profileInvalid,
                localizationKey: "xbox_compatibility_profile_invalid"
            )
        case nil:
            CloudCapabilityReason(
                .serviceUnavailable,
                localizationKey: "cloud_service_unavailable"
            )
        }
        guard environment.service != nil else {
            capabilities = Self.unavailableCapabilities(
                reason: unavailableReason
            )
            return
        }

        let accountCapability: CloudCapability<CloudAccountCapability> = if
            environment.canRequestMicrosoftDeviceCode,
            environment.canAuthorizeXboxCloud
        {
            .supported(
                CloudAccountCapability(
                    maximumAccounts: 1,
                    persistsSignIn: true
                )
            )
        } else {
            .unavailable(
                CloudCapabilityReason(
                    .accountRequired,
                    localizationKey: "account_access_required"
                )
            )
        }

        capabilities = CloudGamingProviderCapabilities(
            provider: .xboxCloudGaming,
            availability: .supported(.available),
            account: accountCapability,
            catalog: .supported(
                CloudCatalogCapability(
                    filters: [
                        .ads,
                        .favorite,
                        .genre,
                        .input,
                        .owned,
                        .playable,
                        .subscription,
                        .unavailableReason,
                    ],
                    keepsUnavailableTitlesVisible: true,
                    reasonedPlayability: true,
                    supportsExplicitRefresh: true,
                    supportsFavorites: true,
                    supportsRecentlyPlayed: true
                )
            ),
            streamOptions: .supported(
                CloudStreamOptionsCapability(
                    qualityControls: [.automatic, .resolution],
                    audioControls: [.automatic],
                    hdrControls: [.automatic],
                    supportsServiceConfirmedRegions: false
                )
            ),
            input: .supported(
                CloudInputCapability(
                    devices: [.controller, .keyboardMouse],
                    controllerFeatures: [
                        .independentRumble,
                        .menu,
                        .share,
                        .stablePlayerIndex,
                        .view,
                    ],
                    maximumControllerSlots: nil
                )
            ),
            microphone: .supported(
                CloudMicrophoneCapability(
                    defaultsEnabled: false,
                    supportsAutomaticRouteHotSwap: true,
                    supportsVoiceChat: true
                )
            ),
            session: .supported(
                CloudSessionCapability(
                    supportsBackgroundLeave: true,
                    supportsResume: true,
                    reconnectPolicy: .standard
                )
            ),
            diagnostics: .supported(
                CloudDiagnosticsCapability(
                    supportsLocalExport: false,
                    supportsNetworkTest: true,
                    supportsStreamHUD: true
                )
            )
        )
    }

    private static func unavailableCapabilities(
        reason: CloudCapabilityReason
    ) -> CloudGamingProviderCapabilities {
        CloudGamingProviderCapabilities(
            provider: .xboxCloudGaming,
            availability: .unavailable(reason),
            account: .unavailable(reason),
            catalog: .unavailable(reason),
            streamOptions: .unavailable(reason),
            input: .unavailable(reason),
            microphone: .unavailable(reason),
            session: .unavailable(reason),
            diagnostics: .unavailable(reason)
        )
    }
}

nonisolated extension XboxCatalogItem {
    var cloudRequiredInputDevices: Set<CloudInputDeviceKind> {
        var devices: Set<CloudInputDeviceKind> = []
        if supportedInputTypes.contains(.controller) {
            devices.insert(.controller)
        }
        if supportedInputTypes.contains(.mouseAndKeyboard) {
            devices.insert(.keyboardMouse)
        }
        return devices
    }

    var isTouchOnlyOnTVOS: Bool {
        supportedInputTypes == [.touch]
    }

    func hasCompatibleInput(
        connectedDevices: Set<CloudInputDeviceKind>
    ) -> Bool {
        let required = cloudRequiredInputDevices
        return !required.isEmpty
            && !connectedDevices.isDisjoint(with: required)
    }
}

nonisolated extension XboxCloudStreamState {
    var cloudPresentationState: CloudStreamPresentationState {
        switch self {
        case .idle:
            .idle
        case .requestingAccess, .allocating:
            .allocating
        case let .waiting(estimatedSeconds):
            .queued(position: nil, estimatedWait: estimatedSeconds)
        case let .provisioning(estimatedSeconds):
            .provisioning(
                progress: nil,
                estimatedWait: estimatedSeconds
            )
        case .connecting:
            .connecting
        case .streaming:
            .streaming
        case let .reconnecting(attempt, maximumAttempts, nextDelay):
            .reconnecting(
                attempt: attempt,
                maximumAttempts: maximumAttempts,
                nextDelay: nextDelay
            )
        case .stopping:
            .stopping
        case .failed:
            .failure(
                CloudStreamPresentationFailure(
                    localizationKey: "stream_failed",
                    isRetryable: false
                )
            )
        }
    }
}

@MainActor
extension XboxCloudStreamController {
    var cloudPresentationState: CloudStreamPresentationState {
        if canContinueSession, let resumableSessionExpiresAt {
            return .resumable(expiresAt: resumableSessionExpiresAt)
        }
        return state.cloudPresentationState
    }
}
