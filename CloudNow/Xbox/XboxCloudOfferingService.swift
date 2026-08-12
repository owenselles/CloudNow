import Foundation

/// Versioned first-party wire compatibility values shipped with CloudNow.
/// Keeping these values in one immutable profile makes service updates explicit
/// and prevents one Xbox adapter from silently drifting from the others.
nonisolated struct XboxCloudCompatibilityProfile: Equatable, Sendable {
    static let bundledV1: Self = {
        guard let profile = try? validatedBundledV1() else {
            preconditionFailure("CloudNow's bundled Xbox compatibility profile is invalid.")
        }
        return profile
    }()

    static func validatedBundledV1() throws -> Self {
        guard let offeringServiceBaseURL = URL(
            string: "https://gssv-play-prod.xboxlive.com"
        ),
            let gamePassCatalogProductsURL = URL(
                string: "https://catalog.gamepass.com/v3/products"
            ),
            let fresnoCatalogURL = URL(
                string: "https://catalog.gamepass.com/sigls/v3"
            ),
            let displayCatalogProductsURL = URL(
                string: "https://displaycatalog.mp.microsoft.com/v7.0/products"
            ),
            let userAuthenticationEndpoint = URL(
                string: "https://user.auth.xboxlive.com/user/authenticate"
            ),
            let xstsAuthorizationEndpoint = URL(
                string: "https://xsts.auth.xboxlive.com/xsts/authorize"
            )
        else {
            throw XboxCloudCompatibilityProfileError.invalidProfile
        }
        return try Self(
            version: 1,
            offeringServiceBaseURL: offeringServiceBaseURL,
            gamePassCatalogProductsURL: gamePassCatalogProductsURL,
            fresnoCatalogURL: fresnoCatalogURL,
            displayCatalogProductsURL: displayCatalogProductsURL,
            defaultNetworkTestTargetURL: offeringServiceBaseURL,
            contentAccessServiceHost: "contentaccess.exp.xboxservices.com",
            userAuthenticationEndpoint: userAuthenticationEndpoint,
            xstsAuthorizationEndpoint: xstsAuthorizationEndpoint,
            cloudSessionCreatePath: "v5/sessions/cloud/play",
            fresnoPlatformContext: "Cloud:XGPUWEB",
            fresnoStreamWithAdsRailID: "51f14e5d-bdcb-4e04-b9cb-76e5057702df",
            fresnoSupportedSubscriptionProductIDs: [
                "CFQ7TTC10QFD",
                "CFQ7TTC0K5DJ",
                "CFQ7TTC0P85B",
                "CFQ7TTC0KHS0",
            ],
            defaultConsumerOfferingID: "xgpuweb",
            preferredOfferingIDs: [
                "xgpuweb",
                "cloudgaming",
                "xgpu",
                "xgpuwebf2p",
            ],
            contentAccessOfferingIDs: ["xgpuweb", "xgpuwebf2p"],
            azureTrafficManagerOfferingIDs: [
                "xgpuweb",
                "cloudgaming",
                "xgpuwebf2p",
                "takehomeweb",
            ],
            gamePassCatalogCallingAppName: "Xbox Cloud Gaming Web",
            gamePassCatalogCallingAppVersion: "29.19.17",
            contentAccessCallingAppName: "CloudNow",
            contentAccessCallingAppVersion: "1.0",
            streamingClientAppType: "browser",
            streamingClientAppVersion: "29.19.17",
            streamingClientSDKVersion: "10.6.57",
            streamingPlatformType: "smarttv",
            streamingSDKType: "web",
            minimumGSSessionLifetime: 5 * 60,
            maximumControllerSlots: 4,
            signalingConfiguration: XboxCloudSDPConfiguration
                .microsoftWebInputV1,
            dataChannelDescriptors: XboxCloudDataChannelDescriptor
                .microsoftWebRTCChannelsV1,
            membershipTierByProductID: [
                "CFQ7TTC0KHS0": .ultimate,
                "CFQ7TTC0P85B": .premium,
                "CFQ7TTC0K5DJ": .essential,
                "CFQ7TTC0KGQ8": .pcGamePass,
            ]
        )
    }

    let version: Int
    let offeringServiceBaseURL: URL
    let gamePassCatalogProductsURL: URL
    let fresnoCatalogURL: URL
    let displayCatalogProductsURL: URL
    let defaultNetworkTestTargetURL: URL
    let contentAccessServiceHost: String
    let userAuthenticationEndpoint: URL
    let xstsAuthorizationEndpoint: URL
    let cloudSessionCreatePath: String
    let fresnoPlatformContext: String
    let fresnoStreamWithAdsRailID: String
    let fresnoSupportedSubscriptionProductIDs: Set<String>
    let defaultConsumerOfferingID: String
    let preferredOfferingIDs: [String]
    let contentAccessOfferingIDs: Set<String>
    let azureTrafficManagerOfferingIDs: Set<String>
    let gamePassCatalogCallingAppName: String
    let gamePassCatalogCallingAppVersion: String
    let contentAccessCallingAppName: String
    let contentAccessCallingAppVersion: String
    let streamingClientAppType: String
    let streamingClientAppVersion: String
    let streamingClientSDKVersion: String
    let streamingPlatformType: String
    let streamingSDKType: String
    let minimumGSSessionLifetime: TimeInterval
    let maximumControllerSlots: Int
    let signalingConfiguration: XboxCloudSDPConfiguration
    let dataChannelDescriptors: [XboxCloudDataChannelDescriptor]
    let membershipTierByProductID: [String: XboxMembershipTier]

    init(
        version: Int,
        offeringServiceBaseURL: URL,
        gamePassCatalogProductsURL: URL,
        fresnoCatalogURL: URL,
        displayCatalogProductsURL: URL,
        defaultNetworkTestTargetURL: URL,
        contentAccessServiceHost: String,
        userAuthenticationEndpoint: URL,
        xstsAuthorizationEndpoint: URL,
        cloudSessionCreatePath: String,
        fresnoPlatformContext: String,
        fresnoStreamWithAdsRailID: String,
        fresnoSupportedSubscriptionProductIDs: Set<String>,
        defaultConsumerOfferingID: String,
        preferredOfferingIDs: [String],
        contentAccessOfferingIDs: Set<String>,
        azureTrafficManagerOfferingIDs: Set<String>,
        gamePassCatalogCallingAppName: String,
        gamePassCatalogCallingAppVersion: String,
        contentAccessCallingAppName: String,
        contentAccessCallingAppVersion: String,
        streamingClientAppType: String,
        streamingClientAppVersion: String,
        streamingClientSDKVersion: String,
        streamingPlatformType: String,
        streamingSDKType: String,
        minimumGSSessionLifetime: TimeInterval,
        maximumControllerSlots: Int,
        signalingConfiguration: XboxCloudSDPConfiguration,
        dataChannelDescriptors: [XboxCloudDataChannelDescriptor],
        membershipTierByProductID: [String: XboxMembershipTier]
    ) throws {
        let endpoints = [
            offeringServiceBaseURL,
            gamePassCatalogProductsURL,
            fresnoCatalogURL,
            displayCatalogProductsURL,
            defaultNetworkTestTargetURL,
            userAuthenticationEndpoint,
            xstsAuthorizationEndpoint,
        ]
        let preferredOfferingSet = Set(preferredOfferingIDs)
        let channelKinds = Set(dataChannelDescriptors.map(\.kind))
        let channelLabels = Set(dataChannelDescriptors.map(\.label))
        let requiredInputChannels: Set<XboxCloudDataChannelKind> = [
            .input,
            .reliableInput,
            .unreliableInput,
        ]
        guard version > 0,
              endpoints.allSatisfy(Self.isSecureEndpoint),
              Self.hasHost(offeringServiceBaseURL, suffix: "xboxlive.com"),
              Self.hasHost(gamePassCatalogProductsURL, suffix: "gamepass.com"),
              Self.hasHost(fresnoCatalogURL, suffix: "gamepass.com"),
              displayCatalogProductsURL.host?.lowercased()
              == "displaycatalog.mp.microsoft.com",
              Self.hasHost(defaultNetworkTestTargetURL, suffix: "xboxlive.com"),
              Self.hasHost(userAuthenticationEndpoint, suffix: "xboxlive.com"),
              Self.hasHost(xstsAuthorizationEndpoint, suffix: "xboxlive.com"),
              offeringServiceBaseURL.path.isEmpty
              || offeringServiceBaseURL.path == "/",
              gamePassCatalogProductsURL.path == "/v3/products",
              fresnoCatalogURL.path == "/sigls/v3",
              displayCatalogProductsURL.path == "/v7.0/products",
              defaultNetworkTestTargetURL.path.isEmpty
              || defaultNetworkTestTargetURL.path == "/",
              userAuthenticationEndpoint.path == "/user/authenticate",
              xstsAuthorizationEndpoint.path == "/xsts/authorize",
              Self.isSafeDNSHost(contentAccessServiceHost),
              contentAccessServiceHost == "xboxservices.com"
              || contentAccessServiceHost.hasSuffix(".xboxservices.com"),
              Self.isSafeRelativePath(cloudSessionCreatePath),
              Self.isSafeQueryValue(fresnoPlatformContext, maximumBytes: 128),
              UUID(uuidString: fresnoStreamWithAdsRailID) != nil,
              !fresnoSupportedSubscriptionProductIDs.isEmpty,
              fresnoSupportedSubscriptionProductIDs.count <= 128,
              fresnoSupportedSubscriptionProductIDs.allSatisfy(Self.isSafeProductID),
              !preferredOfferingIDs.isEmpty,
              preferredOfferingIDs.count <= 32,
              preferredOfferingSet.count == preferredOfferingIDs.count,
              preferredOfferingIDs.allSatisfy(XboxCloudServiceURL.isSafeDNSLabel),
              preferredOfferingSet.contains(defaultConsumerOfferingID),
              !contentAccessOfferingIDs.isEmpty,
              contentAccessOfferingIDs.isSubset(of: preferredOfferingSet),
              contentAccessOfferingIDs.allSatisfy(XboxCloudServiceURL.isSafeDNSLabel),
              !azureTrafficManagerOfferingIDs.isEmpty,
              azureTrafficManagerOfferingIDs.count <= 32,
              azureTrafficManagerOfferingIDs.allSatisfy(
                  XboxCloudServiceURL.isSafeDNSLabel
              ),
              azureTrafficManagerOfferingIDs.contains(defaultConsumerOfferingID),
              Self.isSafeHeaderValue(gamePassCatalogCallingAppName, maximumBytes: 128),
              Self.isSafeHeaderValue(gamePassCatalogCallingAppVersion, maximumBytes: 64),
              Self.isSafeHeaderValue(contentAccessCallingAppName, maximumBytes: 128),
              Self.isSafeHeaderValue(contentAccessCallingAppVersion, maximumBytes: 64),
              streamingClientAppType == "browser",
              Self.isSafeHeaderValue(streamingClientAppVersion, maximumBytes: 64),
              Self.isSafeHeaderValue(streamingClientSDKVersion, maximumBytes: 64),
              streamingPlatformType == "smarttv",
              streamingSDKType == "web",
              minimumGSSessionLifetime.isFinite,
              minimumGSSessionLifetime >= 30,
              (1 ... 4).contains(maximumControllerSlots),
              Self.isValid(signalingConfiguration),
              !dataChannelDescriptors.isEmpty,
              channelKinds.count == dataChannelDescriptors.count,
              channelLabels.count == dataChannelDescriptors.count,
              requiredInputChannels.isSubset(of: channelKinds),
              !membershipTierByProductID.isEmpty,
              membershipTierByProductID.keys.allSatisfy(Self.isSafeProductID)
        else {
            throw XboxCloudCompatibilityProfileError.invalidProfile
        }
        self.version = version
        self.offeringServiceBaseURL = offeringServiceBaseURL
        self.gamePassCatalogProductsURL = gamePassCatalogProductsURL
        self.fresnoCatalogURL = fresnoCatalogURL
        self.displayCatalogProductsURL = displayCatalogProductsURL
        self.defaultNetworkTestTargetURL = defaultNetworkTestTargetURL
        self.contentAccessServiceHost = contentAccessServiceHost
        self.userAuthenticationEndpoint = userAuthenticationEndpoint
        self.xstsAuthorizationEndpoint = xstsAuthorizationEndpoint
        self.cloudSessionCreatePath = cloudSessionCreatePath
        self.fresnoPlatformContext = fresnoPlatformContext
        self.fresnoStreamWithAdsRailID = fresnoStreamWithAdsRailID
        self.fresnoSupportedSubscriptionProductIDs = fresnoSupportedSubscriptionProductIDs
        self.defaultConsumerOfferingID = defaultConsumerOfferingID
        self.preferredOfferingIDs = preferredOfferingIDs
        self.contentAccessOfferingIDs = contentAccessOfferingIDs
        self.azureTrafficManagerOfferingIDs = azureTrafficManagerOfferingIDs
        self.gamePassCatalogCallingAppName = gamePassCatalogCallingAppName
        self.gamePassCatalogCallingAppVersion = gamePassCatalogCallingAppVersion
        self.contentAccessCallingAppName = contentAccessCallingAppName
        self.contentAccessCallingAppVersion = contentAccessCallingAppVersion
        self.streamingClientAppType = streamingClientAppType
        self.streamingClientAppVersion = streamingClientAppVersion
        self.streamingClientSDKVersion = streamingClientSDKVersion
        self.streamingPlatformType = streamingPlatformType
        self.streamingSDKType = streamingSDKType
        self.minimumGSSessionLifetime = minimumGSSessionLifetime
        self.maximumControllerSlots = maximumControllerSlots
        self.signalingConfiguration = signalingConfiguration
        self.dataChannelDescriptors = dataChannelDescriptors
        self.membershipTierByProductID = membershipTierByProductID
    }

    private static func isSecureEndpoint(_ url: URL) -> Bool {
        url.absoluteString.utf8.count <= 2048
            && url.scheme?.lowercased() == "https"
            && url.host != nil
            && url.user == nil
            && url.password == nil
            && url.port == nil
            && url.query == nil
            && url.fragment == nil
    }

    private static func hasHost(_ url: URL, suffix: String) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == suffix || host.hasSuffix(".\(suffix)")
    }

    private static func isSafeDNSHost(_ value: String) -> Bool {
        guard value.utf8.count <= 253,
              !value.isEmpty,
              !value.hasPrefix("."),
              !value.hasSuffix(".")
        else {
            return false
        }
        return value.split(separator: ".").allSatisfy {
            XboxCloudServiceURL.isSafeDNSLabel(String($0))
        }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 256
            && !value.hasPrefix("/")
            && !value.contains("..")
            && value.split(separator: "/").allSatisfy {
                XboxCloudServiceURL.isSafeDNSLabel(String($0))
            }
    }

    private static func isSafeHeaderValue(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isSafeQueryValue(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._:")
        )
        return !value.isEmpty
            && value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy(allowedCharacters.contains)
    }

    private static func isValid(_ configuration: XboxCloudSDPConfiguration) -> Bool {
        let ranges = [
            configuration.chatStream,
            configuration.control,
            configuration.input,
            configuration.unreliableinput,
            configuration.reliableinput,
            configuration.message,
            configuration.chat,
        ]
        return ranges.allSatisfy {
            $0.minVersion > 0 && $0.minVersion <= $0.maxVersion
        }
    }

    private static func isSafeProductID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value == value.uppercased()
            && value.allSatisfy { $0.isLetter || $0.isNumber }
    }
}

nonisolated enum XboxCloudCompatibilityProfileError: Error, Equatable, Sendable {
    case invalidProfile
}

/// Microsoft-owned Xbox Cloud endpoints and the supported consumer offering
/// preference order. The current Xbox web client uses `xgpuweb` as its fixed
/// consumer default; offering discovery is only a fallback after that login
/// fails.
nonisolated struct XboxCloudOfferingServiceConfiguration: Equatable, Sendable {
    static let compatibilityProfile = XboxCloudCompatibilityProfile.bundledV1
    static let defaultConsumerOfferingID = compatibilityProfile.defaultConsumerOfferingID

    static let defaultPreferredOfferingIDs = compatibilityProfile.preferredOfferingIDs

    let serviceBaseURL: URL
    let preferredOfferingIDs: [String]
    let usesAzureTrafficManagerWhenEligible: Bool
    private let azureTrafficManagerOfferingIDs: Set<String>

    init(
        serviceBaseURL: URL,
        preferredOfferingIDs: [String] = Self.defaultPreferredOfferingIDs,
        usesAzureTrafficManagerWhenEligible: Bool = false,
        azureTrafficManagerOfferingIDs: Set<String> = Self.compatibilityProfile
            .azureTrafficManagerOfferingIDs
    ) throws {
        self.serviceBaseURL = try XboxCloudServiceURL.validateBaseURL(serviceBaseURL)
        guard !preferredOfferingIDs.isEmpty,
              preferredOfferingIDs.count <= 32
        else {
            throw XboxCloudOfferingServiceError.invalidConfiguration
        }

        var normalizedIDs: [String] = []
        var seenIDs = Set<String>()
        for offeringID in preferredOfferingIDs {
            let normalizedID = offeringID.lowercased()
            guard XboxCloudServiceURL.isSafeDNSLabel(normalizedID),
                  seenIDs.insert(normalizedID).inserted
            else {
                throw XboxCloudOfferingServiceError.invalidConfiguration
            }
            normalizedIDs.append(normalizedID)
        }
        guard !azureTrafficManagerOfferingIDs.isEmpty,
              azureTrafficManagerOfferingIDs.count <= 32,
              azureTrafficManagerOfferingIDs.allSatisfy(
                  XboxCloudServiceURL.isSafeDNSLabel
              )
        else {
            throw XboxCloudOfferingServiceError.invalidConfiguration
        }
        self.preferredOfferingIDs = normalizedIDs
        self.usesAzureTrafficManagerWhenEligible = usesAzureTrafficManagerWhenEligible
        self.azureTrafficManagerOfferingIDs = Set(
            azureTrafficManagerOfferingIDs.map { $0.lowercased() }
        )
    }

    static func microsoftProduction(
        profile: XboxCloudCompatibilityProfile = .bundledV1
    ) throws -> Self {
        try Self(
            serviceBaseURL: profile.offeringServiceBaseURL,
            preferredOfferingIDs: profile.preferredOfferingIDs,
            azureTrafficManagerOfferingIDs: profile.azureTrafficManagerOfferingIDs
        )
    }

    func selectOffering(
        from entitledOfferingIDs: [String],
        excluding excludedOfferingIDs: Set<String> = []
    ) throws -> String {
        let entitledIDs = Set(entitledOfferingIDs.map { $0.lowercased() })
        let excludedIDs = Set(excludedOfferingIDs.map { $0.lowercased() })
        guard let selectedID = preferredOfferingIDs.first(where: {
            entitledIDs.contains($0) && !excludedIDs.contains($0)
        }) else {
            throw XboxCloudOfferingServiceError.noSupportedOffering
        }
        return selectedID
    }

    func shouldUseAzureTrafficManager(for offeringID: String) -> Bool {
        usesAzureTrafficManagerWhenEligible
            && azureTrafficManagerOfferingIDs.contains(offeringID.lowercased())
    }

    fileprivate var offeringsEndpoint: URL {
        serviceBaseURL.appending(path: "v1/offerings/user")
    }

    fileprivate func loginEndpoint(for offeringID: String) throws -> URL {
        guard XboxCloudServiceURL.isSafeDNSLabel(offeringID),
              let baseHost = serviceBaseURL.host
        else {
            throw XboxCloudOfferingServiceError.invalidConfiguration
        }
        var components = URLComponents(url: serviceBaseURL, resolvingAgainstBaseURL: false)
        let dnsPrefix = shouldUseAzureTrafficManager(for: offeringID)
            ? "atm"
            : offeringID
        components?.host = "\(dnsPrefix).\(baseHost)"
        components?.path = "/v2/login/user"
        guard let endpoint = components?.url else {
            throw XboxCloudOfferingServiceError.invalidConfiguration
        }
        return try XboxCloudServiceURL.validate(endpoint)
    }

    fileprivate func routingHeader(for offeringID: String) -> String {
        shouldUseAzureTrafficManager(for: offeringID) ? "ATM" : "AFD"
    }
}

nonisolated struct XboxCloudGSRegion: Equatable, Sendable, CustomStringConvertible {
    let name: String
    let baseURL: URL
    let isDefault: Bool
    let fallbackPriority: Int
    let systemUpdateGroups: [String]

    var description: String {
        "XboxCloudGSRegion(name: \(name), host: \(baseURL.host ?? "unknown"), isDefault: \(isDefault), fallbackPriority: \(fallbackPriority), systemUpdateGroups: \(systemUpdateGroups.count))"
    }
}

/// Short-lived Game Streaming credential and service routing metadata. This
/// value deliberately has no Codable conformance so it cannot be persisted by
/// convenience APIs. Descriptions redact the GS token.
nonisolated struct XboxCloudGSSession: Equatable, Sendable, CustomStringConvertible {
    let gsToken: String
    let offeringID: String
    let routingHeader: String
    let market: String
    let regions: [XboxCloudGSRegion]
    let defaultRegion: XboxCloudGSRegion
    let fallbackRegionNames: [String]
    let expiresAt: Date

    init(
        gsToken: String,
        offeringID: String,
        routingHeader: String = "AFD",
        market: String,
        regions: [XboxCloudGSRegion],
        defaultRegion: XboxCloudGSRegion,
        fallbackRegionNames: [String],
        expiresAt: Date
    ) {
        self.gsToken = gsToken
        self.offeringID = offeringID
        self.routingHeader = routingHeader
        self.market = market
        self.regions = regions
        self.defaultRegion = defaultRegion
        self.fallbackRegionNames = fallbackRegionNames
        self.expiresAt = expiresAt
    }

    func isUsable(at date: Date, minimumLifetime: TimeInterval = 30) -> Bool {
        expiresAt.timeIntervalSince(date) > minimumLifetime
    }

    func makeSessionAccessContext(
        deviceInformation: XboxCloudDeviceInformation = .cloudNowTV(),
        msaTransferToken: @escaping @Sendable () async throws -> String
    ) throws -> XboxCloudSessionAccessContext {
        try XboxCloudSessionAccessContext(
            gsToken: gsToken,
            regionBaseURL: defaultRegion.baseURL,
            market: market,
            fallbackRegionNames: fallbackRegionNames,
            systemUpdateGroups: defaultRegion.systemUpdateGroups,
            routingHeader: routingHeader,
            deviceInformation: deviceInformation,
            msaTransferToken: msaTransferToken
        )
    }

    var description: String {
        "XboxCloudGSSession(gsToken: <redacted>, offeringID: \(offeringID), market: \(market), regions: \(regions.count), expiresAt: \(expiresAt))"
    }
}

nonisolated protocol XboxCloudGSSessionProviding: Sendable {
    func session(for account: XboxCloudAuthorizedAccount) async throws -> XboxCloudGSSession
    func removeSession(for account: XboxCloudAuthorizedAccount) async
    func clearSessions() async
}

/// Bounded, process-memory-only provider for Xbox Game Streaming credentials.
/// It keeps provider construction lazy and drops the least-recently-created
/// account when the small account bound is exceeded.
actor XboxCloudGSSessionProvider: XboxCloudGSSessionProviding, XboxLocalCredentialLifecycle {
    private static let maximumRetainedAccountCount = 2

    private struct StoredSession: Sendable {
        let sequence: UInt64
        let session: XboxCloudGSSession
    }

    private struct PendingSession: Sendable {
        let sequence: UInt64
        let task: Task<XboxCloudGSSession, Error>
    }

    private let credentialProvider: any XboxXSTSCredentialProviding
    private let configuration: XboxCloudOfferingServiceConfiguration
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private var sequence: UInt64 = 0
    private var generation: UInt64 = 0
    private var sessions: [String: StoredSession] = [:]
    private var pendingSessions: [String: PendingSession] = [:]

    init(
        credentialProvider: any XboxXSTSCredentialProviding,
        configuration: XboxCloudOfferingServiceConfiguration,
        transport: any HTTPTransport = URLSessionHTTPTransport(configuration: .ephemeral),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentialProvider = credentialProvider
        self.configuration = configuration
        self.transport = transport
        self.now = now
    }

    func session(for account: XboxCloudAuthorizedAccount) async throws -> XboxCloudGSSession {
        try Task.checkCancellation()
        let currentDate = now()
        guard account.isUsable(at: currentDate) else {
            throw XboxCloudOfferingServiceError.accountUnavailable
        }
        if let storedSession = sessions[account.authorizationIdentifier],
           storedSession.session.isUsable(
               at: currentDate,
               minimumLifetime: XboxCloudOfferingServiceConfiguration
                   .compatibilityProfile.minimumGSSessionLifetime
           )
        {
            return storedSession.session
        }

        if let pendingSession = pendingSessions[account.authorizationIdentifier] {
            let session = try await pendingSession.task.value
            try Task.checkCancellation()
            return session
        }

        sessions.removeValue(forKey: account.authorizationIdentifier)
        let operationGeneration = generation
        sequence &+= 1
        let operationSequence = sequence
        let credentialProvider = credentialProvider
        let configuration = configuration
        let transport = transport
        let now = now
        let task = Task<XboxCloudGSSession, Error> { @concurrent in
            let credential = try await credentialProvider.credential(
                for: account,
                relyingParty: .cloudGaming
            )
            guard credential.relyingParty == .cloudGaming,
                  credential.isUsable(at: now())
            else {
                throw XboxCloudOfferingServiceError.accountUnavailable
            }

            let service = XboxCloudOfferingService(
                configuration: configuration,
                transport: transport,
                now: now
            )
            return try await service.authenticate(with: credential)
        }
        pendingSessions[account.authorizationIdentifier] = PendingSession(
            sequence: operationSequence,
            task: task
        )

        let gsSession: XboxCloudGSSession
        do {
            gsSession = try await task.value
        } catch {
            if pendingSessions[account.authorizationIdentifier]?.sequence
                == operationSequence
            {
                pendingSessions.removeValue(forKey: account.authorizationIdentifier)
            }
            throw error
        }
        guard generation == operationGeneration else {
            throw CancellationError()
        }

        if pendingSessions[account.authorizationIdentifier]?.sequence
            == operationSequence
        {
            pendingSessions.removeValue(forKey: account.authorizationIdentifier)
        }
        sessions[account.authorizationIdentifier] = StoredSession(
            sequence: operationSequence,
            session: gsSession
        )
        trimSessionsIfNeeded()
        try Task.checkCancellation()
        return gsSession
    }

    func removeSession(for account: XboxCloudAuthorizedAccount) {
        pendingSessions.removeValue(forKey: account.authorizationIdentifier)?.task.cancel()
        sessions.removeValue(forKey: account.authorizationIdentifier)
    }

    func clearSessions() {
        generation &+= 1
        for pendingSession in pendingSessions.values {
            pendingSession.task.cancel()
        }
        pendingSessions.removeAll(keepingCapacity: false)
        sessions.removeAll(keepingCapacity: false)
    }

    func clearLocalCredentials() {
        clearSessions()
    }

    private func trimSessionsIfNeeded() {
        while sessions.count > Self.maximumRetainedAccountCount,
              let oldestIdentifier = sessions.min(
                  by: { $0.value.sequence < $1.value.sequence }
              )?.key
        {
            sessions.removeValue(forKey: oldestIdentifier)
        }
    }
}

nonisolated enum XboxCloudOfferingServiceOperation: String, Equatable, Sendable {
    case offerings
    case login
}

nonisolated enum XboxCloudOfferingServiceError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration
    case accountUnavailable
    case noSupportedOffering
    case invalidResponse(XboxCloudOfferingServiceOperation)
    case responseTooLarge(XboxCloudOfferingServiceOperation)
    case invalidPayload(XboxCloudOfferingServiceOperation)
    case httpFailure(
        operation: XboxCloudOfferingServiceOperation,
        statusCode: Int,
        serviceCode: String?
    )
    case transportFailure(XboxCloudOfferingServiceOperation)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Xbox Cloud offering service configuration is invalid."
        case .accountUnavailable:
            "Xbox Cloud account authorization is unavailable or expired."
        case .noSupportedOffering:
            "This account does not currently expose a supported Xbox Cloud Gaming offering."
        case let .invalidResponse(operation):
            "Xbox Cloud \(operation.rawValue) returned an invalid HTTP response."
        case let .responseTooLarge(operation):
            "Xbox Cloud \(operation.rawValue) returned too much data."
        case let .invalidPayload(operation):
            "Xbox Cloud \(operation.rawValue) returned an invalid payload."
        case let .httpFailure(operation, statusCode, serviceCode):
            if let serviceCode {
                "Xbox Cloud \(operation.rawValue) failed with \(serviceCode) (HTTP \(statusCode))."
            } else {
                "Xbox Cloud \(operation.rawValue) failed with HTTP \(statusCode)."
            }
        case let .transportFailure(operation):
            "Xbox Cloud \(operation.rawValue) could not be completed."
        }
    }
}

private nonisolated struct XboxCloudOfferingService: Sendable {
    private static let maximumResponseSize = 524_288
    private static let maximumOfferingCount = 64
    private static let maximumRegionCount = 64
    private static let maximumSystemUpdateGroupCount = 32
    private static let maximumCredentialSize = 131_072
    private static let maximumDuration: TimeInterval = 604_800

    let configuration: XboxCloudOfferingServiceConfiguration
    let transport: any HTTPTransport
    let now: @Sendable () -> Date

    func authenticate(with credential: XboxXSTSCredential) async throws -> XboxCloudGSSession {
        try Task.checkCancellation()
        guard Self.isSafeCredential(credential.token) else {
            throw XboxCloudOfferingServiceError.accountUnavailable
        }

        let defaultOfferingID = XboxCloudOfferingServiceConfiguration.defaultConsumerOfferingID
        do {
            return try await login(
                with: credential.token,
                offeringID: defaultOfferingID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
        }

        let entitledOfferingIDs = try await fetchOfferings(with: credential.token)
        let offeringID = try configuration.selectOffering(
            from: entitledOfferingIDs,
            excluding: [defaultOfferingID]
        )
        return try await login(with: credential.token, offeringID: offeringID)
    }

    private func fetchOfferings(with xstsToken: String) async throws -> [String] {
        guard Self.isSafeCredential(xstsToken) else {
            throw XboxCloudOfferingServiceError.accountUnavailable
        }
        let body = try Self.encodeJSON([
            "authenticationType": "Xbox",
            "token": xstsToken,
        ])
        let data = try await request(
            configuration.offeringsEndpoint,
            operation: .offerings,
            body: body,
            additionalHeaders: [:]
        )

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let offerings = object["offerings"] as? [Any],
              offerings.count <= Self.maximumOfferingCount
        else {
            throw XboxCloudOfferingServiceError.invalidPayload(.offerings)
        }

        var offeringIDs: [String] = []
        var seenIDs = Set<String>()
        for value in offerings {
            let rawID: String? = if let string = value as? String {
                string
            } else if let dictionary = value as? [String: Any] {
                dictionary["id"] as? String
                    ?? dictionary["offeringId"] as? String
            } else {
                nil
            }
            guard let normalizedID = rawID?.lowercased(),
                  XboxCloudServiceURL.isSafeDNSLabel(normalizedID)
            else {
                continue
            }
            if seenIDs.insert(normalizedID).inserted {
                offeringIDs.append(normalizedID)
            }
        }
        return offeringIDs
    }

    private func login(
        with xstsToken: String,
        offeringID: String
    ) async throws -> XboxCloudGSSession {
        let endpoint = try configuration.loginEndpoint(for: offeringID)
        let body = try Self.encodeJSON([
            "offeringId": offeringID,
            "token": xstsToken,
        ])
        let headers = [
            "X-GSSV-Routing": configuration.routingHeader(for: offeringID),
        ]
        let data = try await request(
            endpoint,
            operation: .login,
            body: body,
            additionalHeaders: headers
        )
        return try parseLoginResponse(data, offeringID: offeringID)
    }

    private func request(
        _ endpoint: URL,
        operation: XboxCloudOfferingServiceOperation,
        body: Data,
        additionalHeaders: [String: String]
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        for (field, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let data: Data
        let response: URLResponse
        do {
            try Task.checkCancellation()
            (data, response) = try await transport.data(
                for: request,
                maximumResponseSize: Self.maximumResponseSize
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch HTTPTransportError.responseTooLarge {
            throw XboxCloudOfferingServiceError.responseTooLarge(operation)
        } catch {
            throw XboxCloudOfferingServiceError.transportFailure(operation)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw XboxCloudOfferingServiceError.invalidResponse(operation)
        }
        guard data.count <= Self.maximumResponseSize else {
            throw XboxCloudOfferingServiceError.responseTooLarge(operation)
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw XboxCloudOfferingServiceError.httpFailure(
                operation: operation,
                statusCode: httpResponse.statusCode,
                serviceCode: Self.serviceCode(from: data)
            )
        }
        return data
    }

    private func parseLoginResponse(
        _ data: Data,
        offeringID: String
    ) throws -> XboxCloudGSSession {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gsToken = object["gsToken"] as? String,
              Self.isSafeCredential(gsToken),
              let duration = Self.timeInterval(from: object["durationInSeconds"]),
              duration > 0,
              duration <= Self.maximumDuration,
              let market = Self.safeLabel(object["market"], maximumLength: 32),
              let offeringSettings = object["offeringSettings"] as? [String: Any],
              let regionValues = offeringSettings["regions"] as? [Any],
              !regionValues.isEmpty,
              regionValues.count <= Self.maximumRegionCount
        else {
            throw XboxCloudOfferingServiceError.invalidPayload(.login)
        }

        let regions = try regionValues.map(parseRegion)
        let defaultRegions = regions.filter(\.isDefault)
        guard defaultRegions.count == 1,
              let defaultRegion = defaultRegions.first
        else {
            throw XboxCloudOfferingServiceError.invalidPayload(.login)
        }

        let fallbackRegionNames = regions
            .filter { !$0.isDefault && $0.fallbackPriority >= 0 }
            .sorted {
                if $0.fallbackPriority == $1.fallbackPriority {
                    return $0.name < $1.name
                }
                return $0.fallbackPriority < $1.fallbackPriority
            }
            .map(\.name)

        let expiresAt = now().addingTimeInterval(duration)
        guard expiresAt > now() else {
            throw XboxCloudOfferingServiceError.invalidPayload(.login)
        }
        return XboxCloudGSSession(
            gsToken: gsToken,
            offeringID: offeringID,
            routingHeader: configuration.routingHeader(for: offeringID),
            market: market,
            regions: regions,
            defaultRegion: defaultRegion,
            fallbackRegionNames: fallbackRegionNames,
            expiresAt: expiresAt
        )
    }

    private func parseRegion(_ value: Any) throws -> XboxCloudGSRegion {
        guard let object = value as? [String: Any],
              let name = Self.safeLabel(object["name"], maximumLength: 128),
              let rawBaseURL = object["baseUri"] as? String,
              let baseURL = URL(string: rawBaseURL),
              let isDefault = object["isDefault"] as? Bool,
              let fallbackPriority = Self.integer(from: object["fallbackPriority"]),
              (-1 ... 10000).contains(fallbackPriority)
        else {
            throw XboxCloudOfferingServiceError.invalidPayload(.login)
        }
        let validatedBaseURL: URL
        do {
            validatedBaseURL = try XboxCloudServiceURL.validateBaseURL(baseURL)
        } catch {
            throw XboxCloudOfferingServiceError.invalidPayload(.login)
        }

        let groupValues = object["systemUpdateGroups"] as? [Any] ?? []
        guard groupValues.count <= Self.maximumSystemUpdateGroupCount else {
            throw XboxCloudOfferingServiceError.invalidPayload(.login)
        }
        var groups: [String] = []
        var seenGroups = Set<String>()
        for value in groupValues {
            guard let group = Self.safeLabel(value, maximumLength: 128) else {
                throw XboxCloudOfferingServiceError.invalidPayload(.login)
            }
            if seenGroups.insert(group).inserted {
                groups.append(group)
            }
        }
        return XboxCloudGSRegion(
            name: name,
            baseURL: validatedBaseURL,
            isDefault: isDefault,
            fallbackPriority: fallbackPriority,
            systemUpdateGroups: groups
        )
    }

    private static func encodeJSON(_ object: [String: String]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            throw XboxCloudOfferingServiceError.invalidConfiguration
        }
        return data
    }

    private static func isSafeCredential(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumCredentialSize
            && value.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
            }
    }

    private static func safeLabel(_ value: Any?, maximumLength: Int) -> String? {
        guard let string = value as? String else { return nil }
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumLength,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        return normalized
    }

    private static func integer(from value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded() == doubleValue,
              doubleValue >= Double(Int.min),
              doubleValue <= Double(Int.max)
        else {
            return nil
        }
        return Int(doubleValue)
    }

    private static func timeInterval(from value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else {
            return nil
        }
        return number.doubleValue
    }

    private static func serviceCode(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let rawCode = object["code"] as? String
            ?? (object["error"] as? [String: Any])?["code"] as? String
            ?? (object["errorDetails"] as? [String: Any])?["code"] as? String
        guard let code = rawCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty,
              code.utf8.count <= 128,
              code.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(
                      CharacterSet(charactersIn: "-._:/")
                  ).contains($0)
              })
        else {
            return nil
        }
        return code
    }
}

private nonisolated enum XboxCloudServiceURL {
    static func validateBaseURL(_ url: URL) throws -> URL {
        let validatedURL = try validate(url)
        guard validatedURL.query == nil,
              validatedURL.fragment == nil,
              validatedURL.path.isEmpty || validatedURL.path == "/"
        else {
            throw XboxCloudOfferingServiceError.invalidConfiguration
        }
        var components = URLComponents(url: validatedURL, resolvingAgainstBaseURL: false)
        components?.path = ""
        guard let normalizedURL = components?.url else {
            throw XboxCloudOfferingServiceError.invalidConfiguration
        }
        return normalizedURL
    }

    static func validate(_ url: URL) throws -> URL {
        guard url.absoluteString.utf8.count <= 2048,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              isXboxLiveHost(host),
              url.user == nil,
              url.password == nil,
              url.port == nil
        else {
            throw XboxCloudOfferingServiceError.invalidConfiguration
        }
        return url
    }

    static func isSafeDNSLabel(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 30
            && value.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }

    private static func isXboxLiveHost(_ host: String) -> Bool {
        host == "xboxlive.com" || host.hasSuffix(".xboxlive.com")
    }
}
