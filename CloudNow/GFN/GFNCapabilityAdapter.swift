import Foundation

/// Behavior-preserving declaration of the capabilities already implemented by
/// the native provider path. It does not own auth, settings or streaming state.
nonisolated struct GFNCapabilityAdapter: CloudGamingCapabilityProviding {
    let provider = CloudGamingProvider.geForceNow
    let capabilities: CloudGamingProviderCapabilities

    init() {
        capabilities = CloudGamingProviderCapabilities(
            provider: .geForceNow,
            availability: .supported(.available),
            account: .supported(
                CloudAccountCapability(
                    maximumAccounts: 1,
                    persistsSignIn: true
                )
            ),
            catalog: .supported(
                CloudCatalogCapability(
                    filters: [
                        .favorite,
                        .genre,
                        .owned,
                        .playable,
                    ],
                    keepsUnavailableTitlesVisible: false,
                    reasonedPlayability: true,
                    supportsExplicitRefresh: true,
                    supportsFavorites: true,
                    supportsRecentlyPlayed: true
                )
            ),
            streamOptions: .supported(
                CloudStreamOptionsCapability(
                    qualityControls: [
                        .automatic,
                        .bitrate,
                        .codec,
                        .frameRate,
                        .resolution,
                    ],
                    audioControls: [.automatic, .stereo, .surround51],
                    hdrControls: [.automatic, .hdr, .sdr],
                    supportsServiceConfirmedRegions: true
                )
            ),
            input: .supported(
                CloudInputCapability(
                    devices: [
                        .controller,
                        .keyboardMouse,
                        .remotePointer,
                        .textEntry,
                    ],
                    controllerFeatures: [
                        .independentRumble,
                        .menu,
                        .stablePlayerIndex,
                        .view,
                    ],
                    maximumControllerSlots: 4
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
}

nonisolated extension StreamState {
    var cloudPresentationState: CloudStreamPresentationState {
        switch self {
        case .idle:
            .idle
        case .connecting:
            .connecting
        case .streaming:
            .streaming
        case let .reconnecting(attempt):
            .reconnecting(
                attempt: attempt,
                maximumAttempts: 3,
                nextDelay: CloudReconnectPolicy.standard.delay(
                    beforeAttempt: attempt
                )
            )
        case .disconnected, .failed:
            .failure(
                CloudStreamPresentationFailure(
                    localizationKey: "stream_failed",
                    isRetryable: true
                )
            )
        case .sessionEnded:
            .stopping
        }
    }
}
