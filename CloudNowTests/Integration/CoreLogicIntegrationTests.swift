@testable import CloudNow
import CoreVideo
import Foundation
import Testing

@Suite("Deterministic cross-layer integration")
@MainActor
struct CoreLogicIntegrationTests {
    @Test("Cached catalog publishes before a real GamesClient refresh completes")
    func cachedCatalogThenHTTPRefresh() async throws {
        let harness = try IntegrationPersistenceHarness()
        defer { harness.cleanup() }
        let cached = TestGameFactory.make(
            id: "cached-game",
            title: "Cached Game",
            stores: [("STEAM", false)],
            isInLibrary: false
        )
        let vpcId = "fixture-vpc"
        let accountScope = nvidiaAccountScope(for: "fixture-user")
        await harness.store.saveVpcId(vpcId)
        await harness.store.saveCatalog(
            [cached],
            localeCode: L10n.nvidiaLocaleCode(),
            vpcId: vpcId,
            accountScope: accountScope,
            expectedGeneration: 0
        )

        let browseFixture = try NetworkingFixture.data("games-browse.json")
        let refreshGate = IntegrationRequestGate()
        let transport = RecordingHTTPTransport { request, _ in
            if request.url?.host == "static.nvidiagrid.net" {
                return StubbedHTTPResponse(json: #"{"games":[]}"#)
            }
            guard request.url?.host == "games.geforce.com" else {
                throw TestTransportError.unexpectedRequest(
                    request.url?.absoluteString ?? "(nil)"
                )
            }
            let body = try jsonObject(from: request)
            let variables = try #require(body["variables"] as? [String: Any])
            let filters = try #require(variables["filters"] as? [String: Any])
            if filters.isEmpty {
                await refreshGate.suspendRequest()
                return StubbedHTTPResponse(data: browseFixture)
            }
            return StubbedHTTPResponse(
                json: integrationBrowsePage(items: [])
            )
        }
        let viewModel = GamesViewModel(
            gamesClient: GamesClient(transport: transport),
            cloudMatchClient: IntegrationActiveSessionsClient(),
            membershipClient: IntegrationMembershipClient(),
            persistence: harness.store
        )
        let authManager = await makeIntegrationAuthManager()

        let load = Task { @MainActor in
            await viewModel.load(authManager: authManager)
        }
        await refreshGate.waitUntilSuspended()

        #expect(viewModel.mainGames == [cached])
        #expect(viewModel.catalogLoadPhase == .loading)

        await refreshGate.releaseRequest()
        await load.value

        #expect(viewModel.mainGames.map(\.id) == ["101", "fallback-title"])
        #expect(viewModel.catalogLoadPhase == .loaded)
        #expect(
            await harness.store.loadCatalog(
                localeCode: L10n.nvidiaLocaleCode(),
                vpcId: vpcId,
                accountScope: accountScope
            )?.map(\.id) == ["101", "fallback-title"]
        )
        #expect(await transport.requests().allSatisfy {
            $0.url?.host == "games.geforce.com"
                || $0.url?.host == "static.nvidiagrid.net"
        })
    }

    @Test("Legacy persisted settings construct a normalized CloudMatch session request")
    func legacyPersistenceToCloudMatchRequest() async throws {
        let harness = try IntegrationPersistenceHarness()
        defer { harness.cleanup() }
        try harness.defaults.set(
            TestFixture.data("legacy-color.json", subdirectory: "Settings"),
            forKey: "gfn.streamSettings"
        )
        let settings = try #require(
            await harness.store.loadGamesSnapshot(accountScope: nil).streamSettings
        ).normalizedForClient
        await harness.store.saveStreamSettings(settings)
        let restored = try #require(
            await harness.store.loadGamesSnapshot(accountScope: nil).streamSettings
        )
        let response = try NetworkingFixture.data("cloudmatch-session.json")
        let fixedUUID = try #require(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )
        let transport = RecordingHTTPTransport { request, _ in
            let root = try jsonObject(from: request)
            let session = try #require(
                root["sessionRequestData"] as? [String: Any]
            )
            let monitor = try #require(
                (session["clientRequestMonitorSettings"] as? [[String: Any]])?.first
            )
            let features = try #require(
                session["requestedStreamingFeatures"] as? [String: Any]
            )

            #expect(session["appId"] as? String == "12345")
            #expect(monitor["widthInPixels"] as? Int == 3840)
            #expect(monitor["heightInPixels"] as? Int == 2160)
            #expect(monitor["framesPerSecond"] as? Int == 120)
            #expect(monitor["sdrHdrMode"] as? Int == 1)
            #expect(features["bitDepth"] as? Int == 1)
            #expect(session["appLaunchMode"] as? Int == AppLaunchMode.bigPicture.cloudMatchValue)
            return StubbedHTTPResponse(data: response)
        }
        let capabilities = LocalVideoCapabilities(
            supportsHardware10BitDecode: true,
            supportsHDRRendering: true,
            supportsExtendedDynamicRange: true,
            displaySupportsHDR: true,
            supportedPixelFormats: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange],
            supportedCodecs: [.h264, .h265]
        )
        let client = CloudMatchClient(
            transport: transport,
            uuid: { fixedUUID },
            deviceId: { "fixture-device" },
            timezoneOffsetMilliseconds: { 0 }
        )

        let session = try await client.createSession(
            SessionCreateRequest(
                appId: "12345",
                internalTitle: "Fixture Game",
                token: "fixture-token",
                streamingBaseUrl: "https://np-test.cloudmatchbeta.nvidiagrid.net/",
                routingZoneUrl: nil,
                settings: restored,
                localVideoCapabilities: capabilities,
                accountLinked: true,
                accountAllowsHDR: true
            )
        )

        #expect(restored.maxBitrateKbps == StreamSettings.maxSelectableBitrateKbps)
        #expect(restored.rumbleIntensity == StreamSettings.maxRumbleIntensity)
        #expect(restored.controllerDeadzone == StreamSettings.minControllerDeadzone)
        #expect(restored.colorPreference == .preferHDR)
        #expect(session.sessionId == "fixture-session")
    }

    @Test("Legacy settings normalize into an HDR-capable Main10 SDP preference")
    func legacySettingsToSDP() throws {
        let settings = try JSONDecoder().decode(
            StreamSettings.self,
            from: TestFixture.data("legacy-color.json", subdirectory: "Settings")
        )
        let capabilities = LocalVideoCapabilities(
            supportsHardware10BitDecode: true,
            supportsHDRRendering: true,
            supportsExtendedDynamicRange: true,
            displaySupportsHDR: true,
            supportedPixelFormats: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange],
            supportedCodecs: [.h264, .h265]
        )
        let request = settings.colorRequest(
            localCapabilities: capabilities,
            gameHDRSupport: .supported,
            accountAllowsHDR: true,
            serverAllowsHDR: true
        )
        let offer = try TestFixture.string("mixed-codecs.sdp", subdirectory: "SDP")

        let preferred = SDPMunger.preferCodec(
            offer,
            codec: settings.codec,
            preferTenBit: request.bitDepth == 10
        )
        let mediaLine = try #require(
            preferred.split(whereSeparator: \.isNewline)
                .first(where: { $0.hasPrefix("m=video") })
        )
        let payloads = mediaLine.components(separatedBy: " ")
        let main10Index = try #require(payloads.firstIndex(of: "100"))
        let mainIndex = try #require(payloads.firstIndex(of: "98"))

        #expect(request.mode == .hdr10)
        #expect(request.hdrRequested)
        #expect(main10Index < mainIndex)
        #expect(preferred.contains("a=fmtp:101 apt=100"))
    }

    @Test("Catalog fixtures decode, normalize, filter, sort, and preserve favorites")
    func catalogFilteringAndFavorites() throws {
        let games = try JSONDecoder().decode(
            [GameInfo].self,
            from: TestFixture.data("games.json", subdirectory: "Catalog")
        )
        var state = GameFilterState()
        state.genres = ["ACTION"]
        state.stores = ["STEAM"]
        state.features = [.hdr]
        let favorites: Set = ["fixture-alpha"]

        let filtered = GameFilterEngine.apply(
            to: games,
            context: .library,
            state: state,
            searchText: " orbit ",
            sortOrder: .titleAZ,
            favoriteIds: favorites,
            recentlyPlayedIds: []
        )
        let encodedFavorites = try JSONEncoder().encode(favorites.sorted())
        let restoredFavorites = try Set(JSONDecoder().decode([String].self, from: encodedFavorites))

        #expect(filtered.map(\.id) == ["fixture-alpha"])
        #expect(filtered.first?.genreCodes == ["ACTION"])
        #expect(restoredFavorites == favorites)
    }

    @Test("A client input packet and a server haptics packet agree on controller identity")
    func inputAndHapticsProtocolRoundTrip() throws {
        let encoder = InputEncoder(timestampProvider: { 42 })
        encoder.setProtocolVersion(3)
        let packet = EncodedInputPacket()
        encoder.encodeGamepad(
            controllerId: 2,
            buttons: 0x1000,
            leftTrigger: 8,
            rightTrigger: 9,
            leftStickX: -10,
            leftStickY: 10,
            rightStickX: -20,
            rightStickY: 20,
            gamepadBitmap: 0x0404,
            into: packet
        )
        let outgoing = TestBytes.bytes(of: packet)
        try #require(outgoing.count == 54)
        let incoming = try #require(
            GFNHapticsDecoder.decode(
                TestFixture.hexData("legacy.hex", subdirectory: "Haptics")
            )
        )

        #expect(outgoing[10] == 2)
        #expect(TestBytes.uint16LE(outgoing, at: 22) == 2)
        #expect(incoming.controllerId == 2)
        #expect(incoming.weak == 0x1234)
        #expect(incoming.strong == 0xABCD)
    }

    @Test("Synthetic decoded video produces stable diagnostic state")
    func syntheticVideoDiagnostics() throws {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            9,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            nil,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate
        )

        let format = DecodedVideoFormatInspector.inspect(
            pixelBuffer: buffer,
            decoderPath: .hardware
        )
        let signature = DecodedVideoFormatInspector.signature(for: format)
        let diagnostics = VideoPipelineDiagnostics()
        diagnostics.setEnabled(true)
        diagnostics.updateDecodedVideoFormat(format)
        let trace = diagnostics.beginFrame()
        diagnostics.recordEnqueue(trace)
        let snapshot = diagnostics.snapshot()

        #expect(format.mode == .hdr10)
        #expect(format.pixelFormatName == "x420")
        #expect(signature.bitDepth == 10)
        #expect(signature.colorRange == "Video")
        #expect(snapshot.callbackFrames == 1)
        #expect(snapshot.enqueuedFrames == 1)
        let snapshotFormat = try #require(snapshot.decodedVideoFormat)
        #expect(snapshotFormat == format)
        #expect(DecodedVideoFormatInspector.signature(for: snapshotFormat) == signature)
    }

    private func makeIntegrationAuthManager() async -> AuthManager {
        let session = AuthSession(
            provider: LoginProvider(
                idpId: "fixture",
                code: "NVIDIA",
                displayName: "Fixture",
                streamingServiceUrl: "https://stream.invalid/",
                priority: 0
            ),
            tokens: AuthTokens(
                accessToken: "fixture-access-token",
                refreshToken: "fixture-refresh-token",
                idToken: nil,
                expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
                clientToken: nil,
                clientTokenExpiresAt: nil
            ),
            user: AuthUser(
                userId: "fixture-user",
                displayName: "Fixture User",
                email: nil,
                avatarUrl: nil,
                membershipTier: "FREE"
            )
        )
        let manager = AuthManager(
            api: UnavailableIntegrationAuthAPI(),
            persistence: IntegrationAuthPersistence(session: session),
            backgroundScheduler: .disabled,
            schedulesAutomaticRefresh: false
        )
        await manager.initialize()
        return manager
    }
}

private actor IntegrationRequestGate {
    private var isSuspended = false
    private var isReleased = false
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendRequest() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters = []
        waiters.forEach { $0.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            requestContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func releaseRequest() {
        isReleased = true
        requestContinuation?.resume()
        requestContinuation = nil
    }
}

private actor IntegrationActiveSessionsClient: ActiveSessionsClient {
    func getActiveSessions(
        token _: String,
        base _: String
    ) -> [ActiveSessionInfo] {
        []
    }
}

private actor IntegrationMembershipClient: MembershipClient {
    func fetchVpcId(token _: String, base _: String) -> String? {
        nil
    }

    func fetchSubscription(
        token _: String,
        vpcId _: String,
        userId _: String
    ) throws -> SubscriptionInfo {
        throw IntegrationTestError.unavailable
    }
}

private actor IntegrationAuthPersistence: AuthSessionPersistence {
    private var session: AuthSession?

    init(session: AuthSession) {
        self.session = session
    }

    func loadAuthSession() throws -> AuthSession {
        guard let session else {
            throw IntegrationTestError.unavailable
        }
        return session
    }

    func saveAuthSession(
        _ session: AuthSession,
        generation _: UInt64
    ) {
        self.session = session
    }

    func deleteAuthSession(generation _: UInt64) {
        session = nil
    }
}

private nonisolated struct UnavailableIntegrationAuthAPI: NVIDIAAuthAPIClient {
    func fetchProviders() async throws -> [LoginProvider] {
        throw IntegrationTestError.unavailable
    }

    func refreshTokens(_: String) async throws -> AuthTokens {
        throw IntegrationTestError.unavailable
    }

    func fetchClientToken(accessToken _: String) async throws -> (
        token: String,
        expiresAt: Date
    ) {
        throw IntegrationTestError.unavailable
    }

    func refreshWithClientToken(
        _: String,
        userId _: String
    ) async throws -> AuthTokens {
        throw IntegrationTestError.unavailable
    }

    func requestDeviceAuthorization(
        idpId _: String?
    ) async throws -> DeviceFlowResponse {
        throw IntegrationTestError.unavailable
    }

    func pollForDeviceToken(
        deviceCode _: String,
        interval _: Int,
        expiresIn _: Int
    ) async throws -> AuthTokens {
        throw IntegrationTestError.unavailable
    }

    func fetchUserInfo(tokens _: AuthTokens) async throws -> AuthUser {
        throw IntegrationTestError.unavailable
    }
}

private struct IntegrationPersistenceHarness {
    let defaults: UserDefaults
    let cacheDirectory: URL
    let store: AppPersistenceStore
    private let suiteName: String

    init() throws {
        suiteName = "CloudNowIntegrationTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudNowIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        store = AppPersistenceStore(
            preferences: UserDefaultsPreferencesStore(defaults: defaults),
            cacheDirectory: cacheDirectory,
            credentialStore: UnavailableIntegrationCredentialStore()
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}

private nonisolated struct UnavailableIntegrationCredentialStore: SecureCredentialStore {
    func load() throws -> Data {
        throw IntegrationTestError.unavailable
    }

    func save(_: Data) throws {
        throw IntegrationTestError.unavailable
    }

    func delete() throws {}
}

private nonisolated enum IntegrationTestError: Error {
    case unavailable
}

private nonisolated func integrationBrowsePage(items: [String]) -> String {
    """
    {
      "data": {
        "apps": {
          "numberReturned": \(items.count),
          "pageInfo": {
            "hasNextPage": false,
            "endCursor": "",
            "totalCount": \(items.count)
          },
          "items": [\(items.joined(separator: ","))]
        }
      }
    }
    """
}
