#if DEBUG
    import Foundation

    /// Deterministic, network-free Xbox configuration used only by simulator UI
    /// automation. It exercises CloudNow's injected contracts without shipping
    /// credentials, service endpoints, or an Xbox streaming implementation.
    nonisolated enum XboxUITestFixture {
        static let account = XboxCloudAuthorizedAccount(
            authorizationIdentifier: "cloudnow-ui-test-xbox-account",
            displayName: "CloudNow Xbox Fixture",
            expiresAt: .distantFuture
        )

        static let session = XboxAuthSession(
            configuration: authentication,
            token: MicrosoftOAuthToken(
                accessToken: "fixture-access-token",
                refreshToken: "fixture-refresh-token",
                idToken: nil,
                tokenType: "Bearer",
                scopes: ["openid"],
                expiresAt: .distantFuture
            )
        )

        private static let catalogScenario = XboxUITestCatalogScenario(
            mode: libraryRefreshMode,
            initialSnapshot: catalog,
            refreshedSnapshot: refreshedCatalog
        )

        private static let libraryRefreshMode: XboxUITestCatalogRefreshMode = {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--cloudnow-ui-xbox-library-refresh-running") {
                return .running
            }
            if arguments.contains(
                "--cloudnow-ui-xbox-library-refresh-access-failure-once"
            ) {
                return .accessFailureOnce
            }
            return .completes
        }()

        static let environment = XboxCloudEnvironment(
            authentication: authentication,
            makeAccountAuthorizationClient: {
                XboxUITestAccountAuthorizationClient(account: account)
            },
            service: XboxCloudServiceConfiguration(
                makeCatalogClient: {
                    XboxUITestCatalogClient(scenario: catalogScenario)
                },
                makeContentAccessClient: {
                    XboxUITestContentAccessClient(scenario: catalogScenario)
                },
                makeStreamController: { transferToken in
                    XboxCloudStreamController(
                        sessionProvider: XboxUITestGSSessionProvider(),
                        transferToken: transferToken,
                        deviceInformation: .cloudNowTV(
                            sdkInstallID: "cloudnow-ui-test-installation"
                        )
                    )
                }
            )
        )

        static let deviceCodeEnvironment = XboxCloudEnvironment(
            authentication: authentication,
            makeAccountAuthorizationClient: nil,
            // Keep provider availability enabled so the chooser can exercise
            // device-code sign-in. The injected OAuth client pauses before any
            // account authorization or service request can occur.
            service: environment.service
        )

        static func makeDeviceCodeOAuthClient() -> any XboxOAuthClient {
            XboxUITestDeviceCodeOAuthClient()
        }

        private static let authentication: MicrosoftDeviceCodeOAuthConfiguration = {
            guard let configuration = try? MicrosoftDeviceCodeOAuthConfiguration(
                tenant: "consumers",
                clientID: "cloudnow-ui-test-client",
                scopes: ["openid"]
            ) else {
                preconditionFailure("The deterministic Xbox UI-test configuration is invalid.")
            }
            return configuration
        }()

        private static let catalog = XboxCatalogSnapshot(
            items: [
                XboxCatalogItem(
                    id: "fixture-racer",
                    title: "Fixture Racer",
                    longDescription: "A deterministic racing fixture for CloudNow catalog testing.",
                    genres: ["Racing"],
                    developer: "CloudNow Test Studio",
                    publisher: "CloudNow",
                    contentRating: "Everyone",
                    artworkURL: nil,
                    supportedInputTypes: [.controller],
                    isOwned: true
                ),
                XboxCatalogItem(
                    id: "fixture-adventure",
                    title: "Fixture Adventure",
                    longDescription: "A deterministic adventure fixture with an ad-supported route.",
                    genres: ["Adventure"],
                    developer: "CloudNow Test Studio",
                    publisher: "CloudNow",
                    contentRating: "Teen",
                    artworkURL: nil,
                    supportedInputTypes: [.controller, .touch],
                    routes: [
                        XboxCloudTitleRoute(
                            titleID: "fixture-adventure",
                            accessKind: .freeWithAds
                        ),
                    ]
                ),
                XboxCatalogItem(
                    id: "fixture-preview-locked",
                    title: "Fixture Preview Locked",
                    genres: ["Adventure"],
                    artworkURL: nil,
                    supportedInputTypes: [.controller, .touch],
                    routes: [
                        XboxCloudTitleRoute(
                            titleID: "fixture-preview-locked",
                            accessKind: .freeWithAds,
                            availability: .requiresEligibility
                        ),
                    ]
                ),
                XboxCatalogItem(
                    id: "fixture-touch-only",
                    title: "Fixture Touch Only",
                    genres: ["Adventure"],
                    artworkURL: nil,
                    supportedInputTypes: [.touch]
                ),
                XboxCatalogItem(
                    id: "fixture-puzzle",
                    title: "Fixture Puzzle",
                    genres: ["Puzzle"],
                    artworkURL: nil,
                    supportedInputTypes: [.controller, .mouseAndKeyboard]
                ),
                XboxCatalogItem(
                    id: "fixture-dual-route",
                    title: "Fixture Dual Access",
                    genres: ["Action"],
                    artworkURL: nil,
                    supportedInputTypes: [.controller, .mouseAndKeyboard],
                    isOwned: true,
                    routes: [
                        XboxCloudTitleRoute(
                            titleID: "fixture-dual-standard",
                            accessKind: .standard
                        ),
                        XboxCloudTitleRoute(
                            titleID: "fixture-dual-ads",
                            accessKind: .freeWithAds
                        ),
                    ]
                ),
            ],
            fetchedAt: .distantFuture
        )

        private static let refreshedCatalog = XboxCatalogSnapshot(
            items: catalog.items + [
                XboxCatalogItem(
                    id: "fixture-refresh-new",
                    title: "Fixture Refresh Addition",
                    genres: ["Action"],
                    artworkURL: nil,
                    supportedInputTypes: [.controller],
                    isOwned: true
                ),
            ],
            fetchedAt: .distantFuture
        )
    }

    private enum XboxUITestCatalogRefreshMode: Sendable {
        case accessFailureOnce
        case completes
        case running
    }

    private enum XboxUITestLibraryRefreshError: Error {
        case accessUnavailable
    }

    private actor XboxUITestCatalogScenario {
        private let mode: XboxUITestCatalogRefreshMode
        private let initialSnapshot: XboxCatalogSnapshot
        private let refreshedSnapshot: XboxCatalogSnapshot
        private var shouldFailNextContentAccessRequest = false
        private var hasFailedContentAccessRequest = false

        init(
            mode: XboxUITestCatalogRefreshMode,
            initialSnapshot: XboxCatalogSnapshot,
            refreshedSnapshot: XboxCatalogSnapshot
        ) {
            self.mode = mode
            self.initialSnapshot = initialSnapshot
            self.refreshedSnapshot = refreshedSnapshot
        }

        func snapshot(forExplicitRefresh isExplicitRefresh: Bool) async throws
            -> XboxCatalogSnapshot
        {
            guard isExplicitRefresh else { return initialSnapshot }
            switch mode {
            case .accessFailureOnce:
                if !hasFailedContentAccessRequest {
                    shouldFailNextContentAccessRequest = true
                }
                return refreshedSnapshot
            case .completes:
                return refreshedSnapshot
            case .running:
                try await Task.sleep(nanoseconds: UInt64.max)
                throw CancellationError()
            }
        }

        func contentAccessSnapshot() throws -> XboxContentAccessSnapshot {
            if shouldFailNextContentAccessRequest {
                shouldFailNextContentAccessRequest = false
                hasFailedContentAccessRequest = true
                throw XboxUITestLibraryRefreshError.accessUnavailable
            }
            return XboxContentAccessSnapshot(
                membershipTier: .ultimate,
                fetchedAt: .distantFuture
            )
        }
    }

    private actor XboxUITestDeviceCodeOAuthClient: XboxOAuthClient {
        func authenticate(
            configuration _: MicrosoftDeviceCodeOAuthConfiguration,
            onState: @escaping @Sendable (MicrosoftDeviceCodeState) async -> Void
        ) async throws -> MicrosoftOAuthToken {
            guard let verificationURI = URL(
                string: "https://www.microsoft.com/link"
            ) else {
                preconditionFailure("The Xbox UI-test verification URL is invalid.")
            }
            let authorization = MicrosoftDeviceAuthorization(
                deviceCode: "fixture-device-code",
                userCode: "ABCD-EFGH",
                verificationURI: verificationURI,
                verificationURIComplete: nil,
                expiresAt: .distantFuture,
                pollingInterval: 5,
                message: nil
            )
            await onState(.awaitingUser(authorization))
            await onState(.polling(attempt: 1))
            try await Task.sleep(nanoseconds: UInt64.max)
            throw CancellationError()
        }

        func refreshToken(
            configuration _: MicrosoftDeviceCodeOAuthConfiguration,
            refreshToken _: String
        ) throws -> MicrosoftOAuthToken {
            throw MicrosoftDeviceCodeOAuthError.transportFailure
        }
    }

    private actor XboxUITestAccountAuthorizationClient: XboxCloudAccountAuthorizationClient {
        let account: XboxCloudAuthorizedAccount

        init(account: XboxCloudAuthorizedAccount) {
            self.account = account
        }

        func authorize(
            microsoftToken _: MicrosoftOAuthToken
        ) -> XboxCloudAuthorizedAccount {
            account
        }
    }

    private actor XboxUITestCatalogClient: XboxCatalogClient {
        private let scenario: XboxUITestCatalogScenario
        private var hasPendingExplicitRefresh = false

        init(scenario: XboxUITestCatalogScenario) {
            self.scenario = scenario
        }

        func fetchCatalog(
            _: XboxCatalogRequest,
            account _: XboxCloudAuthorizedAccount
        ) async throws -> XboxCatalogSnapshot {
            let isExplicitRefresh = hasPendingExplicitRefresh
            hasPendingExplicitRefresh = false
            return try await scenario.snapshot(
                forExplicitRefresh: isExplicitRefresh
            )
        }

        func refreshAccountState(for _: XboxCloudAuthorizedAccount) async {
            hasPendingExplicitRefresh = true
        }

        nonisolated func cancel() {}
    }

    private actor XboxUITestContentAccessClient: XboxContentAccessProviding {
        private let scenario: XboxUITestCatalogScenario

        init(scenario: XboxUITestCatalogScenario) {
            self.scenario = scenario
        }

        func fetchContentAccess(
            for _: XboxCloudAuthorizedAccount,
            market _: String,
            offeringID _: String
        ) async throws -> XboxContentAccessSnapshot {
            try await scenario.contentAccessSnapshot()
        }
    }

    /// Keeps deterministic UI launches in CloudNow's cancellable allocation
    /// state without contacting Microsoft or constructing a WebRTC peer.
    private actor XboxUITestGSSessionProvider: XboxCloudGSSessionProviding {
        func session(
            for _: XboxCloudAuthorizedAccount
        ) async throws -> XboxCloudGSSession {
            try await Task.sleep(nanoseconds: UInt64.max)
            throw CancellationError()
        }

        func removeSession(for _: XboxCloudAuthorizedAccount) {}

        func clearSessions() {}
    }
#endif
