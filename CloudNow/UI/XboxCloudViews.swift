import Observation
import SwiftUI

struct XboxLoginView: View {
    @Environment(CloudGamingProviderCoordinator.self) private var providerCoordinator
    @Environment(XboxAuthManager.self) private var xboxAuthManager
    @Environment(\.colorScheme) private var colorScheme
    let fallbackProvider: CloudGamingProvider?

    init(fallbackProvider: CloudGamingProvider? = nil) {
        self.fallbackProvider = fallbackProvider
    }

    var body: some View {
        ZStack {
            adaptiveBackgroundColor.ignoresSafeArea()

            switch xboxAuthManager.signInState {
            case .idle, .cancelled:
                loginPrompt
            case .requestingCode:
                progressView(message: L10n.text("requesting_microsoft_sign_in_code"))
            case .awaitingUser, .polling:
                if let authorization = xboxAuthManager.authorization {
                    CloudNowDeviceCodeView(
                        title: L10n.text("sign_in_to_xbox_cloud_gaming"),
                        code: authorization.userCode,
                        verificationURL: displayURL(authorization.verificationURI),
                        verificationURLComplete: authorization.qrVerificationURI.absoluteString,
                        accentColor: .blue,
                        accessibilityIdentifier: "xbox-device-code-login",
                        primaryForegroundColor: .primary,
                        secondaryForegroundColor: .secondary,
                        onCancel: cancel
                    )
                } else {
                    progressView(message: L10n.text("waiting_for_microsoft_sign_in"))
                }
            case .authorized:
                progressView(message: L10n.text("signing_in"))
            case .validatingXboxCloudAccess:
                progressView(message: L10n.text("verifying_xbox_cloud_access"))
            case .declined:
                failureView(message: L10n.text("microsoft_sign_in_declined"))
            case .expired:
                failureView(message: L10n.text("microsoft_sign_in_code_expired"))
            case let .failed(error):
                failureView(message: signInFailureMessage(error))
            }
        }
        .task {
            guard xboxAuthManager.signInState == .idle,
                  !xboxAuthManager.isMicrosoftSignedIn
            else {
                return
            }
            await xboxAuthManager.login().value
        }
    }

    private var loginPrompt: some View {
        VStack(spacing: 48) {
            CloudNowBrandHeader(
                subtitle: L10n.text("xbox_cloud_gaming"),
                primaryForegroundColor: .primary,
                secondaryForegroundColor: .secondary
            )

            VStack(spacing: 16) {
                Button {
                    xboxAuthManager.login()
                } label: {
                    Label(L10n.text("sign_in_with_microsoft"), systemImage: "person.badge.key")
                        .font(.title2.weight(.semibold))
                        .padding(.horizontal, 40)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.bordered)
                .tint(.blue)

                Text(L10n.text("requires_xbox_cloud_subscription"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button(L10n.text("choose_another_service"), action: cancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(80)
    }

    private func signInFailureMessage(_ error: Error) -> String {
        #if DEBUG
            return error.localizedDescription
        #else
            return L10n.text("sign_in_failed")
        #endif
    }

    private func progressView(message: String) -> some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(2)
                .tint(.primary)
            Text(message)
                .font(.title2)
                .foregroundStyle(.primary)
        }
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 32) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.red)
            Text(L10n.text("sign_in_failed"))
                .font(.title.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 24) {
                Button(L10n.text("try_again")) {
                    if xboxAuthManager.isMicrosoftSignedIn {
                        Task {
                            await xboxAuthManager.activateXboxCloudAccess()
                        }
                    } else {
                        xboxAuthManager.login()
                    }
                }
                .buttonStyle(.bordered)
                .tint(.blue)

                if xboxAuthManager.isMicrosoftSignedIn {
                    Button(
                        L10n.format(
                            "switch_to_service",
                            L10n.text("microsoft_account")
                        )
                    ) {
                        Task {
                            await xboxAuthManager.signInWithAnotherMicrosoftAccount()
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                }

                Button(L10n.text("cancel"), action: cancel)
                    .buttonStyle(.bordered)
                    .tint(.gray)
            }
        }
        .padding(80)
    }

    private func cancel() {
        xboxAuthManager.cancelLogin()
        providerCoordinator.select(fallbackProvider)
    }

    private func displayURL(_ url: URL) -> String {
        url.absoluteString.replacingOccurrences(of: "https://", with: "")
    }

    private var adaptiveBackgroundColor: Color {
        colorScheme == .dark ? .black : .white
    }
}

struct XboxMainTabView: View {
    @Environment(XboxAuthManager.self) private var xboxAuthManager
    @State private var modeViewModel: XboxCloudModeViewModel
    @State private var playbackRequest: XboxCloudPlaybackRequest?
    @State private var pendingPlaybackFocusRestoreID: String?
    @State private var pendingPlaybackSourceTab: XboxAppTab?
    @State private var libraryPlaybackFocusRestoreID: String?
    @State private var browsePlaybackFocusRestoreID: String?
    @State private var selectedTab: XboxAppTab = .home
    @State private var controllerNavigation = UIControllerNavigationCoordinator()
    @State private var inputDeviceMonitor: CloudInputDeviceMonitor
    private let account: XboxCloudAuthorizedAccount
    private let fallbackProvider: CloudGamingProvider?

    init(
        configuration: XboxCloudServiceConfiguration,
        account: XboxCloudAuthorizedAccount,
        fallbackProvider: CloudGamingProvider? = nil
    ) {
        let catalogViewModel = XboxCatalogViewModel(
            makeClient: configuration.makeCatalogClient,
            account: account
        )
        _modeViewModel = State(
            initialValue: XboxCloudModeViewModel(
                catalogViewModel: catalogViewModel,
                account: account,
                makeContentAccessClient: configuration.makeContentAccessClient,
                resolveContentAccessOfferingID: configuration
                    .resolveContentAccessOfferingID,
                resolveNetworkTestTarget: configuration
                    .resolveNetworkTestTarget,
                makeStreamController: configuration.makeStreamController,
                streamControllerRetention: configuration
                    .streamControllerRetention
            )
        )
        #if DEBUG
            let usesUITestFixtures = ProcessInfo.processInfo.arguments.contains(
                "--cloudnow-ui-testing"
            )
            _inputDeviceMonitor = State(
                initialValue: usesUITestFixtures
                    ? CloudInputDeviceMonitor(snapshot: { [.controller] })
                    : CloudInputDeviceMonitor()
            )
        #else
            _inputDeviceMonitor = State(
                initialValue: CloudInputDeviceMonitor()
            )
        #endif
        self.account = account
        self.fallbackProvider = fallbackProvider
    }

    var body: some View {
        CloudNowTabShell(
            selection: $selectedTab,
            controllerNavigation: controllerNavigation,
            accessibilityIdentifier: "service-shell.xbox-cloud-gaming",
            modeLifecycle: modeViewModel
        ) {
            Tab(L10n.text("home"), systemImage: "house.fill", value: XboxAppTab.home) {
                XboxCatalogHome(
                    recentlyPlayedItems: modeViewModel.catalogViewModel.recentlyPlayedItems,
                    favoriteItems: modeViewModel.catalogViewModel.favoriteItems,
                    phase: modeViewModel.catalogViewModel.phase,
                    showsRefreshWarning: modeViewModel.catalogViewModel.showsRefreshWarning,
                    resumableSession: resumableSession,
                    onBrowse: { selectedTab = .browse },
                    onRetry: retryCatalog,
                    onContinue: continuePlaying,
                    onPlay: play,
                    onToggleFavorite: modeViewModel.catalogViewModel.toggleFavorite
                )
                .accessibilityIdentifier("xbox-home-screen")
            }
            Tab(L10n.text("library"), systemImage: "rectangle.stack.fill", value: XboxAppTab.library) {
                XboxCatalogGrid(
                    scope: .library,
                    onRetry: retryCatalog,
                    onPlay: play,
                    playbackFocusRestoreID: $libraryPlaybackFocusRestoreID
                )
                .accessibilityIdentifier("xbox-library-screen")
            }
            Tab(L10n.text("browse"), systemImage: "square.grid.2x2.fill", value: XboxAppTab.browse) {
                XboxCatalogGrid(
                    scope: .browse,
                    onRetry: retryCatalog,
                    onPlay: play,
                    playbackFocusRestoreID: $browsePlaybackFocusRestoreID
                )
                .accessibilityIdentifier("xbox-browse-screen")
            }
            Tab(L10n.text("settings"), systemImage: "gearshape.fill", value: XboxAppTab.settings) {
                XboxSettingsView(fallbackProvider: fallbackProvider)
                    .accessibilityIdentifier("xbox-settings-screen")
            }
        }
        .environment(modeViewModel)
        .environment(modeViewModel.catalogViewModel)
        .environment(inputDeviceMonitor)
        .onAppear {
            inputDeviceMonitor.start()
        }
        .task {
            await modeViewModel.load()
        }
        .onDisappear {
            inputDeviceMonitor.stop()
            // Full-screen game/detail presentations can make the shell
            // disappear temporarily. Only tear down here when authorization
            // was actually lost; provider switches already deactivate before
            // committing navigation.
            guard !xboxAuthManager.isXboxCloudAuthorized else { return }
            Task {
                await modeViewModel.deactivateForInactiveProvider()
            }
        }
        .onChange(of: playbackRequest?.id) { _, gameID in
            if gameID == nil {
                MemoryLifecycleCoordinator.shared.streamDidClose()
            } else {
                MemoryLifecycleCoordinator.shared.streamWillOpen()
            }
        }
        .onChange(of: selectedTab) { _, tab in
            guard let scope = tab.catalogScope else { return }
            modeViewModel.catalogViewModel.setCatalogScope(scope)
        }
        .fullScreenCover(
            item: $playbackRequest,
            onDismiss: restorePlaybackFocus
        ) { request in
            XboxCloudPlayerView(
                item: request.item,
                route: request.route,
                account: account,
                settings: request.settings,
                controller: request.controller,
                continuesExistingSession: request.continuesExistingSession,
                onStreamStarted: {
                    modeViewModel.catalogViewModel.recordPlayed(request.item)
                },
                onStatsModeChanged: { mode in
                    modeViewModel.streamSettings.statsMode = mode
                },
                onDismiss: { playbackRequest = nil }
            )
            .blocksGlobalControllerNavigation(mode: .streaming)
            .environment(controllerNavigation)
            .environment(inputDeviceMonitor)
        }
    }

    private func play(
        _ item: XboxCatalogItem,
        route: XboxCloudTitleRoute
    ) {
        guard route.isPlayable,
              item.hasCompatibleInput(
                  connectedDevices: inputDeviceMonitor.connectedDevices
              )
        else {
            return
        }

        pendingPlaybackFocusRestoreID = item.id
        pendingPlaybackSourceTab = selectedTab
        let settings = modeViewModel.streamCapabilities.normalized(
            modeViewModel.streamSettings
        )
        playbackRequest = XboxCloudPlaybackRequest(
            item: item,
            route: route,
            settings: settings,
            controller: modeViewModel.streamController { [weak xboxAuthManager] in
                guard let xboxAuthManager else { throw CancellationError() }
                return try await xboxAuthManager.xboxCloudTransferToken()
            },
            continuesExistingSession: false
        )
    }

    private var resumableSession: XboxCloudResumableSessionPresentation? {
        guard let controller = modeViewModel.resumableStreamController,
              let titleID = controller.activeGameID,
              let expiresAt = controller.resumableSessionExpiresAt,
              let item = modeViewModel.catalogViewModel.item(
                  forTitleID: titleID
              ),
              let route = item.routes.first(where: { $0.titleID == titleID })
        else {
            return nil
        }
        return XboxCloudResumableSessionPresentation(
            item: item,
            route: route,
            controller: controller,
            expiresAt: expiresAt,
            hasCompatibleInput: item.hasCompatibleInput(
                connectedDevices: inputDeviceMonitor.connectedDevices
            )
        )
    }

    private func continuePlaying(
        _ session: XboxCloudResumableSessionPresentation
    ) {
        guard session.hasCompatibleInput else { return }
        pendingPlaybackFocusRestoreID = session.item.id
        pendingPlaybackSourceTab = selectedTab
        playbackRequest = XboxCloudPlaybackRequest(
            item: session.item,
            route: session.route,
            settings: modeViewModel.streamSettings,
            controller: session.controller,
            continuesExistingSession: true
        )
    }

    private func restorePlaybackFocus() {
        defer {
            pendingPlaybackFocusRestoreID = nil
            pendingPlaybackSourceTab = nil
        }
        guard selectedTab == pendingPlaybackSourceTab else { return }
        switch pendingPlaybackSourceTab {
        case .library:
            libraryPlaybackFocusRestoreID = pendingPlaybackFocusRestoreID
        case .browse:
            browsePlaybackFocusRestoreID = pendingPlaybackFocusRestoreID
        case .home, .settings, nil:
            break
        }
    }

    private func retryCatalog() {
        modeViewModel.startFreshLibraryRefresh()
    }
}

@Observable
@MainActor
final class XboxCloudModeViewModel: CloudGamingProviderModeLifecycle {
    enum ContentAccessPhase: Equatable {
        case idle
        case loading
        case loaded
        case unavailable
    }

    let catalogViewModel: XboxCatalogViewModel
    private(set) var membershipTier: XboxMembershipTier?
    private(set) var contentAccessPhase: ContentAccessPhase = .idle
    private(set) var libraryRefreshState: XboxLibraryRefreshState = .idle
    var streamSettings = XboxCloudStreamSettings() {
        didSet {
            scheduleSettingsSave(oldValue: oldValue)
        }
    }

    var streamCapabilities: XboxCloudStreamCapabilities {
        .resolved(
            for: membershipTier,
            isMembershipKnown: contentAccessPhase == .loaded
        )
    }

    @ObservationIgnored private let makeStreamController: @MainActor @Sendable (
        @escaping @Sendable () async throws -> String
    ) -> XboxCloudStreamController
    @ObservationIgnored private let streamControllerRetention: XboxCloudStreamControllerRetention
    @ObservationIgnored private let makeContentAccessClient: (
        @Sendable () -> any XboxContentAccessProviding
    )?
    @ObservationIgnored private let resolveContentAccessOfferingID: @Sendable (
        XboxCloudAuthorizedAccount
    ) async throws -> String
    @ObservationIgnored private let resolveNetworkTestTarget: @Sendable (
        XboxCloudAuthorizedAccount
    ) async throws -> CloudNetworkTestTarget
    @ObservationIgnored private let account: XboxCloudAuthorizedAccount
    @ObservationIgnored private let persistence: AppPersistenceStore
    @ObservationIgnored private var activeStreamController: XboxCloudStreamController?
    @ObservationIgnored private var contentAccessClient: (any XboxContentAccessProviding)?
    @ObservationIgnored private var contentAccessTask: Task<XboxContentAccessSnapshot, Error>?
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var hasLoadedSettings = false
    @ObservationIgnored private var activationGeneration: UInt64 = 0
    @ObservationIgnored private var contentAccessGeneration: UInt64 = 0
    @ObservationIgnored private var libraryRefreshGeneration: UInt64 = 0
    @ObservationIgnored private var libraryRefreshTask: Task<Void, Never>?

    init(
        catalogViewModel: XboxCatalogViewModel,
        account: XboxCloudAuthorizedAccount,
        makeContentAccessClient: (
            @Sendable () -> any XboxContentAccessProviding
        )? = nil,
        resolveContentAccessOfferingID: @escaping @Sendable (
            XboxCloudAuthorizedAccount
        ) async throws -> String = { _ in
            XboxCloudOfferingServiceConfiguration.defaultConsumerOfferingID
        },
        resolveNetworkTestTarget: @escaping @Sendable (
            XboxCloudAuthorizedAccount
        ) async throws -> CloudNetworkTestTarget = { _ in
            CloudNetworkTestTarget(
                address: XboxCloudCompatibilityProfile.bundledV1
                    .defaultNetworkTestTargetURL.absoluteString
            )
        },
        makeStreamController: @escaping @MainActor @Sendable (
            @escaping @Sendable () async throws -> String
        ) -> XboxCloudStreamController,
        streamControllerRetention: XboxCloudStreamControllerRetention = .none,
        persistence: AppPersistenceStore = .shared
    ) {
        self.catalogViewModel = catalogViewModel
        self.account = account
        self.makeContentAccessClient = makeContentAccessClient
        self.resolveContentAccessOfferingID = resolveContentAccessOfferingID
        self.resolveNetworkTestTarget = resolveNetworkTestTarget
        self.makeStreamController = makeStreamController
        self.streamControllerRetention = streamControllerRetention
        self.persistence = persistence
    }

    func load() async {
        activationGeneration &+= 1
        let generation = activationGeneration
        if !hasLoadedSettings {
            let settings = await persistence.loadXboxCloudStreamSettings()
                .normalizedForClient
            guard activationGeneration == generation,
                  !Task.isCancelled
            else {
                return
            }
            streamSettings = settings
            hasLoadedSettings = true
        }
        guard activationGeneration == generation,
              !Task.isCancelled
        else {
            return
        }
        async let catalogLoad: Void = catalogViewModel.load()
        async let contentAccessLoad: Void = loadContentAccess()
        _ = await (catalogLoad, contentAccessLoad)
    }

    func streamController(
        transferToken: @escaping @Sendable () async throws -> String
    ) -> XboxCloudStreamController {
        if let activeStreamController {
            if activeStreamController.state != .idle
                || activeStreamController.canContinueSession
                || activeStreamController.hasUnconfirmedSessionDeletion
            {
                return activeStreamController
            }
            streamControllerRetention.releaseController(
                activeStreamController
            )
            self.activeStreamController = nil
        }
        if let retainedController = streamControllerRetention
            .retainedController(account)
        {
            activeStreamController = retainedController
            return retainedController
        }
        let controller = makeStreamController(transferToken)
        activeStreamController = controller
        streamControllerRetention.retainController(controller, account)
        return controller
    }

    var resumableStreamController: XboxCloudStreamController? {
        let controller: XboxCloudStreamController
        if let activeStreamController {
            controller = activeStreamController
        } else if let retainedController = streamControllerRetention
            .retainedController(account)
        {
            activeStreamController = retainedController
            controller = retainedController
        } else {
            return nil
        }
        guard controller.canContinueSession
        else {
            return nil
        }
        return controller
    }

    func stopStream() async {
        guard let controller = activeStreamController else { return }
        let didStop = await controller.stop()
        if didStop {
            streamControllerRetention.releaseController(controller)
        }
        if activeStreamController === controller {
            activeStreamController = nil
        }
    }

    func deactivateForInactiveProvider() async {
        activationGeneration &+= 1
        cancelLibraryRefresh()
        cancelContentAccessRequest()
        await flushSettings()
        if let activeStreamController {
            let requiresRetention = activeStreamController.canContinueSession
                || activeStreamController.hasUnconfirmedSessionDeletion
            if requiresRetention {
                streamControllerRetention.retainController(
                    activeStreamController,
                    account
                )
                self.activeStreamController = nil
            } else {
                await stopStream()
            }
        } else {
            await stopStream()
        }
        await catalogViewModel.deactivateForInactiveProvider()
        contentAccessClient = nil
        membershipTier = nil
        contentAccessPhase = .idle
    }

    func prepareForPersistentDataClear() {
        activationGeneration &+= 1
        cancelLibraryRefresh()
        cancelContentAccessRequest()
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        hasLoadedSettings = false
        streamSettings = XboxCloudStreamSettings()
        contentAccessClient = nil
        membershipTier = nil
        contentAccessPhase = .idle
    }

    func restoreSettingsAfterDataClearAttempt() async {
        activationGeneration &+= 1
        let generation = activationGeneration
        let settings = await persistence.loadXboxCloudStreamSettings()
            .normalizedForClient
        guard activationGeneration == generation else { return }
        streamSettings = settings
        hasLoadedSettings = true
    }

    func refreshContentAccess() async {
        guard contentAccessPhase == .unavailable else { return }
        await loadContentAccess()
    }

    var isLibraryRefreshRunning: Bool {
        libraryRefreshState.isRunning
    }

    var canStartLibraryRefresh: Bool {
        guard libraryRefreshState == .idle,
              libraryRefreshTask == nil,
              !catalogViewModel.isRefreshing
        else {
            return false
        }
        switch catalogViewModel.phase {
        case .loaded, .failed:
            return true
        case .idle, .loading:
            return false
        }
    }

    var canPresentLibraryRefresh: Bool {
        libraryRefreshState != .idle || canStartLibraryRefresh
    }

    var canStartFreshLibraryRefresh: Bool {
        guard !libraryRefreshState.isRunning,
              libraryRefreshTask == nil,
              !catalogViewModel.isRefreshing
        else {
            return false
        }
        switch catalogViewModel.phase {
        case .loaded, .failed:
            return true
        case .idle, .loading:
            return false
        }
    }

    func startLibraryRefresh() {
        guard canStartLibraryRefresh else { return }
        beginLibraryRefresh()
    }

    func startFreshLibraryRefresh() {
        guard canStartFreshLibraryRefresh else { return }
        if libraryRefreshState != .idle {
            acknowledgeLibraryRefresh()
        }
        beginLibraryRefresh()
    }

    func retryLibraryRefresh() {
        let canRetry = switch libraryRefreshState {
        case .failed, .completed(_, accountAccessAvailable: false):
            true
        case .idle, .refreshingCatalog, .refreshingAccountAccess,
             .completed(_, accountAccessAvailable: true):
            false
        }
        guard canRetry, canStartFreshLibraryRefresh else {
            return
        }
        beginLibraryRefresh()
    }

    func acknowledgeLibraryRefresh() {
        guard !libraryRefreshState.isRunning else { return }
        libraryRefreshGeneration &+= 1
        libraryRefreshTask?.cancel()
        libraryRefreshTask = nil
        libraryRefreshState = .idle
    }

    func cancelLibraryRefresh() {
        libraryRefreshGeneration &+= 1
        libraryRefreshTask?.cancel()
        libraryRefreshTask = nil
        if libraryRefreshState.isRunning {
            catalogViewModel.cancel()
            cancelContentAccessRequest()
        }
        libraryRefreshState = .idle
    }

    func waitForLibraryRefresh() async {
        await libraryRefreshTask?.value
    }

    func networkTestTarget() async -> CloudNetworkTestTarget {
        do {
            return try await resolveNetworkTestTarget(account)
        } catch {
            return CloudNetworkTestTarget(
                address: XboxCloudCompatibilityProfile.bundledV1
                    .defaultNetworkTestTargetURL.absoluteString
            )
        }
    }

    @discardableResult
    func reloadContentAccessAfterCatalogRefresh() async -> Bool {
        cancelContentAccessRequest()
        membershipTier = nil
        contentAccessPhase = .idle
        await loadContentAccess()
        return contentAccessPhase == .loaded
    }

    private func beginLibraryRefresh() {
        libraryRefreshGeneration &+= 1
        let generation = libraryRefreshGeneration
        libraryRefreshState = .refreshingCatalog
        let catalogViewModel = catalogViewModel
        libraryRefreshTask = Task { @MainActor [weak self] in
            let outcome = await catalogViewModel.reload()
            guard let self,
                  libraryRefreshGeneration == generation,
                  !Task.isCancelled
            else {
                return
            }

            switch outcome {
            case let .refreshed(summary):
                libraryRefreshState = .refreshingAccountAccess(summary)
                let accountAccessAvailable = await reloadContentAccessAfterCatalogRefresh()
                guard libraryRefreshGeneration == generation,
                      !Task.isCancelled
                else {
                    return
                }
                libraryRefreshState = .completed(
                    summary,
                    accountAccessAvailable: accountAccessAvailable
                )
            case let .failed(retainedLastGoodCatalog):
                libraryRefreshState = .failed(
                    retainedLastGoodCatalog: retainedLastGoodCatalog
                )
            case .cancelled, .alreadyRunning:
                libraryRefreshState = .idle
            }
            libraryRefreshTask = nil
        }
    }

    private func scheduleSettingsSave(oldValue: XboxCloudStreamSettings) {
        guard hasLoadedSettings, streamSettings != oldValue else { return }
        settingsSaveTask?.cancel()
        let settings = streamSettings
        let persistence = persistence
        settingsSaveTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            await persistence.saveXboxCloudStreamSettings(settings)
        }
    }

    private func flushSettings() async {
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        guard hasLoadedSettings else { return }
        await persistence.saveXboxCloudStreamSettings(streamSettings)
    }

    private func loadContentAccess() async {
        guard contentAccessPhase != .loaded,
              contentAccessPhase != .loading
        else {
            return
        }
        guard makeContentAccessClient != nil else {
            contentAccessPhase = .unavailable
            return
        }
        contentAccessGeneration &+= 1
        let generation = contentAccessGeneration
        contentAccessPhase = .loading
        let client = resolvedContentAccessClient()
        let account = account
        let resolveOfferingID = resolveContentAccessOfferingID
        let task = Task {
            let offeringID = try await resolveOfferingID(account)
            return try await client.fetchContentAccess(
                for: account,
                market: Locale.current.region?.identifier ?? "US",
                offeringID: offeringID
            )
        }
        contentAccessTask = task
        do {
            let snapshot = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard contentAccessGeneration == generation else { return }
            contentAccessTask = nil
            membershipTier = snapshot.membershipTier
            contentAccessPhase = .loaded
        } catch is CancellationError {
            if contentAccessGeneration == generation {
                contentAccessTask = nil
                contentAccessPhase = .unavailable
            }
            return
        } catch {
            guard contentAccessGeneration == generation else { return }
            contentAccessTask = nil
            membershipTier = nil
            contentAccessPhase = .unavailable
        }
    }

    private func cancelContentAccessRequest() {
        contentAccessGeneration &+= 1
        contentAccessTask?.cancel()
        contentAccessTask = nil
    }

    private func resolvedContentAccessClient() -> any XboxContentAccessProviding {
        if let contentAccessClient {
            return contentAccessClient
        }
        guard let makeContentAccessClient else {
            preconditionFailure("Xbox Content Access is unavailable.")
        }
        let client = makeContentAccessClient()
        contentAccessClient = client
        return client
    }
}

private struct XboxCloudPlaybackRequest: Identifiable {
    let item: XboxCatalogItem
    let route: XboxCloudTitleRoute
    let settings: XboxCloudStreamSettings
    let controller: XboxCloudStreamController
    let continuesExistingSession: Bool

    var id: String {
        "\(item.id)|\(route.titleID)|\(route.accessKind)"
    }
}

private struct XboxCloudResumableSessionPresentation {
    let item: XboxCatalogItem
    let route: XboxCloudTitleRoute
    let controller: XboxCloudStreamController
    let expiresAt: Date
    let hasCompatibleInput: Bool
}

nonisolated enum XboxCatalogScope: Equatable, Sendable {
    case library
    case browse
}

nonisolated struct XboxLibraryRefreshSummary: Equatable, Sendable {
    let addedGameCount: Int
    let removedGameCount: Int
    let playableGameCount: Int
    let catalogGameCount: Int
    let fetchedAt: Date
}

nonisolated enum XboxCatalogReloadOutcome: Equatable, Sendable {
    case refreshed(XboxLibraryRefreshSummary)
    case failed(retainedLastGoodCatalog: Bool)
    case cancelled
    case alreadyRunning
}

nonisolated enum XboxLibraryRefreshStage: Equatable, Sendable {
    case idle
    case refreshingCatalog
    case refreshingAccountAccess
    case completed
    case failed
}

nonisolated enum XboxLibraryRefreshState: Equatable, Sendable {
    case idle
    case refreshingCatalog
    case refreshingAccountAccess(XboxLibraryRefreshSummary)
    case completed(
        XboxLibraryRefreshSummary,
        accountAccessAvailable: Bool
    )
    case failed(retainedLastGoodCatalog: Bool)

    var stage: XboxLibraryRefreshStage {
        switch self {
        case .idle:
            .idle
        case .refreshingCatalog:
            .refreshingCatalog
        case .refreshingAccountAccess:
            .refreshingAccountAccess
        case .completed:
            .completed
        case .failed:
            .failed
        }
    }

    var summary: XboxLibraryRefreshSummary? {
        switch self {
        case let .refreshingAccountAccess(summary),
             let .completed(summary, _):
            summary
        case .idle, .refreshingCatalog, .failed:
            nil
        }
    }

    var isRunning: Bool {
        switch self {
        case .refreshingCatalog, .refreshingAccountAccess:
            true
        case .idle, .completed, .failed:
            false
        }
    }
}

nonisolated enum XboxCatalogCollectionFilter: CaseIterable, Hashable, Sendable {
    case favorites
}

nonisolated enum XboxCatalogAccessFilter: CaseIterable, Hashable, Sendable {
    case standard
    case freeWithAds
    case owned
}

nonisolated enum XboxCatalogPlayabilityFilter: CaseIterable, Hashable, Sendable {
    case playable
    case unavailable
}

nonisolated struct XboxCatalogFilterState: Equatable, Sendable {
    var collections: Set<XboxCatalogCollectionFilter> = []
    var access: Set<XboxCatalogAccessFilter> = []
    var playability: Set<XboxCatalogPlayabilityFilter> = []
    var unavailableReasons: Set<XboxCloudRoutePlayabilityReason> = []
    var inputTypes: Set<XboxCloudInputType> = []
    var genres: Set<String> = []

    var activeSelectionCount: Int {
        collections.count
            + access.count
            + playability.count
            + unavailableReasons.count
            + inputTypes.count
            + genres.count
    }

    var isEmpty: Bool {
        activeSelectionCount == 0
    }

    mutating func clear() {
        collections.removeAll()
        access.removeAll()
        playability.removeAll()
        unavailableReasons.removeAll()
        inputTypes.removeAll()
        genres.removeAll()
    }
}

nonisolated struct XboxCatalogGenreFilterOption: Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let count: Int
}

nonisolated struct XboxCatalogFilterOptions: Equatable, Sendable {
    let genres: [XboxCatalogGenreFilterOption]
    let inputTypeCounts: [XboxCloudInputType: Int]
    let favoriteCount: Int
    let standardCount: Int
    let freeWithAdsCount: Int
    let ownedCount: Int
    let playableCount: Int
    let unavailableCount: Int
    let unavailableReasonCounts: [XboxCloudRoutePlayabilityReason: Int]

    static let empty = XboxCatalogFilterOptions(
        genres: [],
        inputTypeCounts: [:],
        favoriteCount: 0,
        standardCount: 0,
        freeWithAdsCount: 0,
        ownedCount: 0,
        playableCount: 0,
        unavailableCount: 0,
        unavailableReasonCounts: [:]
    )

    var showsCollectionsSection: Bool {
        favoriteCount > 0
    }

    var availableAccessFilters: [XboxCatalogAccessFilter] {
        XboxCatalogAccessFilter.allCases.filter { accessCount($0) > 0 }
    }

    func accessCount(_ filter: XboxCatalogAccessFilter) -> Int {
        switch filter {
        case .standard:
            standardCount
        case .freeWithAds:
            freeWithAdsCount
        case .owned:
            ownedCount
        }
    }
}

nonisolated enum XboxCatalogSortOrder: CaseIterable, Hashable, Sendable {
    case `default`
    case titleAZ
    case titleZA
    case recentFirst
}

@Observable
@MainActor
final class XboxCatalogViewModel: CloudGamingProviderModeLifecycle {
    private struct DetailLoad {
        let token: UUID
        let task: Task<XboxCatalogItem?, Never>
    }

    private static let maximumDetailCacheCount = 32

    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    private(set) var visibleItems: [XboxCatalogItem] = []
    private(set) var carouselItems: [XboxCatalogItem] = []
    private(set) var selectedRoutesByItemID: [String: XboxCloudTitleRoute] = [:]
    private(set) var favoriteItems: [XboxCatalogItem] = []
    private(set) var recentlyPlayedItems: [XboxCatalogItem] = []
    private(set) var favoriteIDs: Set<String> = []
    private(set) var recentlyPlayedIDs: [String] = []
    private(set) var availableAccessKinds: Set<XboxCloudAccessKind> = []
    private(set) var playableAccessKinds: Set<XboxCloudAccessKind> = []
    private(set) var filterOptions: XboxCatalogFilterOptions = .empty
    private(set) var phase: LoadPhase = .idle
    private(set) var isRefreshing = false
    private(set) var showsRefreshWarning = false
    private(set) var catalogLastUpdatedAt: Date?
    private(set) var totalItemCount = 0
    private(set) var browseFilterBaseCount = 0
    private(set) var filteredItemCount = 0
    private(set) var catalogScope: XboxCatalogScope = .browse
    private(set) var presentedCatalogScope: XboxCatalogScope?
    private var librarySearchText = ""
    private var browseSearchText = ""
    private var librarySortOrder: XboxCatalogSortOrder = .default
    private var browseSortOrder: XboxCatalogSortOrder = .default
    private var libraryFilterState = XboxCatalogFilterState()
    private var browseFilterState = XboxCatalogFilterState()

    var searchText: String {
        get { searchText(for: catalogScope) }
        set { setSearchText(newValue, for: catalogScope) }
    }

    var sortOrder: XboxCatalogSortOrder {
        get { sortOrder(for: catalogScope) }
        set { setSortOrder(newValue, for: catalogScope) }
    }

    var filterState: XboxCatalogFilterState {
        get { filterState(for: catalogScope) }
        set { setFilterState(newValue, for: catalogScope) }
    }

    var activeBrowseFilterCount: Int {
        activeFilterCount(for: catalogScope)
    }

    var hasActiveBrowseFilters: Bool {
        activeBrowseFilterCount > 0
    }

    func searchText(for scope: XboxCatalogScope) -> String {
        switch scope {
        case .library:
            librarySearchText
        case .browse:
            browseSearchText
        }
    }

    func setSearchText(_ value: String, for scope: XboxCatalogScope) {
        guard value != searchText(for: scope) else { return }
        switch scope {
        case .library:
            librarySearchText = value
        case .browse:
            browseSearchText = value
        }
        resetPagination(for: scope, debouncesSearch: true)
    }

    func sortOrder(for scope: XboxCatalogScope) -> XboxCatalogSortOrder {
        switch scope {
        case .library:
            librarySortOrder
        case .browse:
            browseSortOrder
        }
    }

    func setSortOrder(
        _ value: XboxCatalogSortOrder,
        for scope: XboxCatalogScope
    ) {
        guard value != sortOrder(for: scope) else { return }
        switch scope {
        case .library:
            librarySortOrder = value
        case .browse:
            browseSortOrder = value
        }
        resetPagination(for: scope)
    }

    func filterState(for scope: XboxCatalogScope) -> XboxCatalogFilterState {
        switch scope {
        case .library:
            libraryFilterState
        case .browse:
            browseFilterState
        }
    }

    func setFilterState(
        _ value: XboxCatalogFilterState,
        for scope: XboxCatalogScope
    ) {
        guard value != filterState(for: scope) else { return }
        switch scope {
        case .library:
            libraryFilterState = value
        case .browse:
            browseFilterState = value
        }
        resetPagination(for: scope)
    }

    func activeFilterCount(for scope: XboxCatalogScope) -> Int {
        filterState(for: scope).activeSelectionCount
    }

    func hasActiveFilters(for scope: XboxCatalogScope) -> Bool {
        activeFilterCount(for: scope) > 0
    }

    @ObservationIgnored private let makeClient: @Sendable () -> any XboxCatalogClient
    @ObservationIgnored private var client: (any XboxCatalogClient)?
    @ObservationIgnored private let account: XboxCloudAuthorizedAccount
    @ObservationIgnored private let cache: any XboxCatalogCaching
    @ObservationIgnored private let activityPersistence: any XboxCatalogActivityPersistence
    @ObservationIgnored private let presentationBuilder: any XboxCatalogPresentationBuilding
    @ObservationIgnored private let searchDebounce: @Sendable () async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let freshnessInterval: TimeInterval
    @ObservationIgnored private var allItems: [XboxCatalogItem] = []
    @ObservationIgnored private var libraryVisibleItemLimit = 96
    @ObservationIgnored private var browseVisibleItemLimit = 96
    @ObservationIgnored private var presentationGeneration: UInt64 = 0
    @ObservationIgnored private var presentationTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration: UInt64 = 0
    @ObservationIgnored private var needsAutomaticRevalidation = false
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private var activityGeneration: UInt64 = 0
    @ObservationIgnored private var hasLoadedActivity = false
    @ObservationIgnored private var activityPersistenceGeneration: UInt64?
    @ObservationIgnored private var activityLoadTask: Task<CloudCatalogActivityLease, Never>?
    @ObservationIgnored private var activitySaveTask: Task<Void, Never>?
    @ObservationIgnored private var detailItems: [String: XboxCatalogItem] = [:]
    @ObservationIgnored private var detailCacheOrder: [String] = []
    @ObservationIgnored private var detailLoads: [String: DetailLoad] = [:]

    init(
        client: any XboxCatalogClient,
        account: XboxCloudAuthorizedAccount,
        cache: any XboxCatalogCaching = XboxCatalogCache.shared,
        activityPersistence: any XboxCatalogActivityPersistence = AppPersistenceStore.shared,
        presentationBuilder: any XboxCatalogPresentationBuilding = XboxCatalogPresentationWorker(),
        searchDebounce: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(150))
        },
        now: @escaping @Sendable () -> Date = Date.init,
        freshnessInterval: TimeInterval = 15 * 60
    ) {
        makeClient = { client }
        self.account = account
        self.cache = cache
        self.activityPersistence = activityPersistence
        self.presentationBuilder = presentationBuilder
        self.searchDebounce = searchDebounce
        self.now = now
        self.freshnessInterval = freshnessInterval
    }

    init(
        makeClient: @escaping @Sendable () -> any XboxCatalogClient,
        account: XboxCloudAuthorizedAccount,
        cache: any XboxCatalogCaching = XboxCatalogCache.shared,
        activityPersistence: any XboxCatalogActivityPersistence = AppPersistenceStore.shared,
        presentationBuilder: any XboxCatalogPresentationBuilding = XboxCatalogPresentationWorker(),
        searchDebounce: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(150))
        },
        now: @escaping @Sendable () -> Date = Date.init,
        freshnessInterval: TimeInterval = 15 * 60
    ) {
        self.makeClient = makeClient
        self.account = account
        self.cache = cache
        self.activityPersistence = activityPersistence
        self.presentationBuilder = presentationBuilder
        self.searchDebounce = searchDebounce
        self.now = now
        self.freshnessInterval = freshnessInterval
    }

    func load() async {
        await loadActivityIfNeeded()
        guard !Task.isCancelled else { return }
        await load(forceRefresh: false)
    }

    @discardableResult
    func reload() async -> XboxCatalogReloadOutcome {
        guard !isRefreshing else { return .alreadyRunning }
        let previousPlayableIDs = playableItemIDs
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isRefreshing = true
        defer {
            if refreshGeneration == generation {
                isRefreshing = false
            }
        }

        cancelCatalogRequest()
        if phase != .loaded {
            phase = .idle
        }
        showsRefreshWarning = false
        await loadActivityIfNeeded()
        guard !Task.isCancelled else { return .cancelled }
        await load(forceRefresh: true)
        guard refreshGeneration == generation,
              !Task.isCancelled
        else {
            return .cancelled
        }
        guard phase == .loaded, !showsRefreshWarning else {
            return .failed(retainedLastGoodCatalog: phase == .loaded)
        }

        let refreshedPlayableIDs = playableItemIDs
        return .refreshed(
            XboxLibraryRefreshSummary(
                addedGameCount: refreshedPlayableIDs
                    .subtracting(previousPlayableIDs).count,
                removedGameCount: previousPlayableIDs
                    .subtracting(refreshedPlayableIDs).count,
                playableGameCount: refreshedPlayableIDs.count,
                catalogGameCount: allItems.count,
                fetchedAt: catalogLastUpdatedAt ?? now()
            )
        )
    }

    private var playableItemIDs: Set<String> {
        Set(allItems.lazy.compactMap { item in
            guard !item.isTouchOnlyOnTVOS,
                  item.routes.contains(where: \.isPlayable)
            else {
                return nil
            }
            return item.id
        })
    }

    private func load(forceRefresh: Bool) async {
        let canRetryAutomaticRevalidation = !forceRefresh
            && phase == .loaded
            && needsAutomaticRevalidation
        guard phase == .idle
            || canRetryAutomaticRevalidation
            || (forceRefresh && phase == .loaded)
        else {
            return
        }
        needsAutomaticRevalidation = false
        loadGeneration &+= 1
        let generation = loadGeneration
        let request = XboxCatalogRequest(
            localeIdentifier: L10n.localeCode,
            market: Locale.current.region?.identifier
        )
        let cacheKey = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: account.activityScopeIdentifier,
            localeIdentifier: request.localeIdentifier,
            market: request.market
        )
        var loadedCachedSnapshot = forceRefresh && phase == .loaded
        showsRefreshWarning = false
        do {
            if forceRefresh {
                if !loadedCachedSnapshot {
                    phase = .loading
                }
            } else if let cached = await cache.snapshot(for: cacheKey) {
                try Task.checkCancellation()
                guard loadGeneration == generation else { return }
                loadedCachedSnapshot = true
                allItems = cached.items
                catalogLastUpdatedAt = cached.fetchedAt
                try await rebuildPresentation()
                guard loadGeneration == generation else { return }
                phase = .loaded
                let cacheAge = now().timeIntervalSince(cached.fetchedAt)
                let isStale = cacheAge < 0 || cacheAge >= freshnessInterval
                showsRefreshWarning = isStale
                if !isStale {
                    return
                }
            } else {
                phase = .loading
            }
            let client = resolvedClient()
            if forceRefresh {
                await client.refreshAccountState(for: account)
                try Task.checkCancellation()
                guard loadGeneration == generation else { return }
            }
            let snapshot = try await client.fetchCatalog(
                request,
                account: account
            )
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            await cache.store(snapshot, for: cacheKey)
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            allItems = snapshot.items
            catalogLastUpdatedAt = snapshot.fetchedAt
            try await rebuildPresentation()
            guard loadGeneration == generation else { return }
            phase = .loaded
            showsRefreshWarning = false
        } catch is CancellationError {
            guard loadGeneration == generation else { return }
            if loadedCachedSnapshot {
                phase = .loaded
                showsRefreshWarning = true
                needsAutomaticRevalidation = true
            } else {
                phase = .idle
            }
            return
        } catch {
            guard loadGeneration == generation else { return }
            phase = loadedCachedSnapshot ? .loaded : .failed
            showsRefreshWarning = loadedCachedSnapshot
        }
    }

    func loadNextPageIfNeeded(_ item: XboxCatalogItem) {
        loadNextPageIfNeeded(item, in: catalogScope)
    }

    func loadNextPageIfNeeded(
        _ item: XboxCatalogItem,
        in scope: XboxCatalogScope
    ) {
        guard catalogScope == scope,
              presentedCatalogScope == scope
        else {
            return
        }
        let itemLimit = visibleItemLimit(for: scope)
        guard item.id == visibleItems.last?.id,
              itemLimit <= visibleItems.count,
              visibleItems.count < carouselItems.count
        else {
            return
        }
        setVisibleItemLimit(
            min(itemLimit + 96, carouselItems.count),
            for: scope
        )
        schedulePresentationUpdate()
    }

    private var visibleItemLimit: Int {
        get { visibleItemLimit(for: catalogScope) }
        set { setVisibleItemLimit(newValue, for: catalogScope) }
    }

    private func visibleItemLimit(for scope: XboxCatalogScope) -> Int {
        switch scope {
        case .library:
            libraryVisibleItemLimit
        case .browse:
            browseVisibleItemLimit
        }
    }

    private func setVisibleItemLimit(
        _ value: Int,
        for scope: XboxCatalogScope
    ) {
        switch scope {
        case .library:
            libraryVisibleItemLimit = value
        case .browse:
            browseVisibleItemLimit = value
        }
    }

    func isFavorite(_ item: XboxCatalogItem) -> Bool {
        isFavorite(item.id)
    }

    func isFavorite(_ itemID: String) -> Bool {
        favoriteIDs.contains(itemID)
    }

    func toggleFavorite(_ item: XboxCatalogItem) {
        toggleFavorite(item.id)
    }

    func toggleFavorite(_ itemID: String) {
        if favoriteIDs.contains(itemID) {
            favoriteIDs.remove(itemID)
        } else {
            favoriteIDs.insert(itemID)
            if favoriteIDs.count > CloudCatalogActivitySnapshot.maximumFavoriteCount,
               let evictedID = favoriteIDs
               .filter({ $0 != itemID })
               .sorted()
               .first
            {
                favoriteIDs.remove(evictedID)
            }
        }
        schedulePresentationUpdate()
        enqueueFavoriteSave()
    }

    func recordPlayed(_ item: XboxCatalogItem) {
        var itemIDs = recentlyPlayedIDs
        itemIDs.removeAll { $0 == item.id }
        itemIDs.insert(item.id, at: 0)
        recentlyPlayedIDs = Array(
            itemIDs.prefix(CloudCatalogActivitySnapshot.maximumRecentlyPlayedCount)
        )
        schedulePresentationUpdate()
        enqueueRecentlyPlayedSave()
    }

    func fetchDetail(for item: XboxCatalogItem) async -> XboxCatalogItem? {
        if let detail = detailItems[item.id] {
            touchCachedDetail(item.id)
            return detail
        }
        if let load = detailLoads[item.id] {
            return await load.task.value
        }

        let request = XboxCatalogRequest(
            localeIdentifier: L10n.localeCode,
            market: Locale.current.region?.identifier
        )
        let client = resolvedClient()
        let token = UUID()
        let task = Task<XboxCatalogItem?, Never> {
            do {
                let detail = try await client.fetchDetail(
                    for: item,
                    request: request
                )
                return detail.id == item.id ? detail : nil
            } catch {
                return nil
            }
        }
        detailLoads[item.id] = DetailLoad(token: token, task: task)
        let detail = await task.value
        if detailLoads[item.id]?.token == token {
            detailLoads.removeValue(forKey: item.id)
            if let detail {
                cacheDetail(detail)
            }
        }
        return detail
    }

    func flushActivityPersistence() async {
        await activitySaveTask?.value
    }

    func cancel() {
        refreshGeneration &+= 1
        isRefreshing = false
        cancelPresentationUpdate()
        cancelDetailLoads()
        cancelCatalogRequest()
    }

    private func cancelCatalogRequest() {
        loadGeneration &+= 1
        needsAutomaticRevalidation = false
        client?.cancel()
        client = nil
    }

    func prepareForCacheClear() {
        cancel()
        detailItems.removeAll(keepingCapacity: false)
        detailCacheOrder.removeAll(keepingCapacity: false)
        allItems.removeAll(keepingCapacity: false)
        visibleItems.removeAll(keepingCapacity: false)
        carouselItems.removeAll(keepingCapacity: false)
        selectedRoutesByItemID.removeAll(keepingCapacity: false)
        presentedCatalogScope = nil
        favoriteItems.removeAll(keepingCapacity: false)
        recentlyPlayedItems.removeAll(keepingCapacity: false)
        availableAccessKinds.removeAll(keepingCapacity: false)
        playableAccessKinds.removeAll(keepingCapacity: false)
        filterOptions = .empty
        phase = .idle
        showsRefreshWarning = false
        catalogLastUpdatedAt = nil
        totalItemCount = 0
        browseFilterBaseCount = 0
        filteredItemCount = 0
        libraryVisibleItemLimit = 96
        browseVisibleItemLimit = 96
        needsAutomaticRevalidation = false
    }

    func prepareForPersistentDataClear() {
        prepareForCacheClear()
        activityGeneration &+= 1
        activityLoadTask?.cancel()
        activityLoadTask = nil
        activitySaveTask?.cancel()
        activitySaveTask = nil
        activityPersistenceGeneration = nil
        hasLoadedActivity = false
        favoriteIDs.removeAll(keepingCapacity: false)
        recentlyPlayedIDs.removeAll(keepingCapacity: false)
    }

    func deactivateForInactiveProvider() async {
        await flushActivityPersistence()
        prepareForCacheClear()
    }

    func item(forTitleID titleID: String) -> XboxCatalogItem? {
        allItems.first { item in
            item.routes.contains { $0.titleID == titleID }
        }
    }

    func setCatalogScope(_ scope: XboxCatalogScope) {
        guard catalogScope != scope else { return }
        catalogScope = scope
        schedulePresentationUpdate()
    }

    func selectedRoute(for item: XboxCatalogItem) -> XboxCloudTitleRoute? {
        selectedRoutesByItemID[item.id]
    }

    func clearBrowseFilters() {
        clearFilters(for: catalogScope)
    }

    func clearFilters(for scope: XboxCatalogScope) {
        var state = filterState(for: scope)
        state.clear()
        setFilterState(state, for: scope)
    }

    func waitForPendingPresentationUpdate() async {
        await presentationTask?.value
    }

    private func resetPagination(
        for scope: XboxCatalogScope,
        debouncesSearch: Bool = false
    ) {
        setVisibleItemLimit(96, for: scope)
        guard catalogScope == scope else { return }
        schedulePresentationUpdate(debouncesSearch: debouncesSearch)
    }

    private func rebuildPresentation() async throws {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        presentationTask?.cancel()
        presentationTask = nil
        do {
            let snapshot = try await presentationBuilder.build(
                presentationInput()
            )
            try Task.checkCancellation()
            guard presentationGeneration == generation else { return }
            applyPresentation(snapshot)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return
        }
    }

    private func schedulePresentationUpdate(
        debouncesSearch: Bool = false
    ) {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        presentationTask?.cancel()
        let builder = presentationBuilder
        let input = presentationInput()
        let debounce = searchDebounce
        presentationTask = Task { @concurrent [weak self] in
            do {
                if debouncesSearch {
                    try await debounce()
                }
                try Task.checkCancellation()
                let snapshot = try await builder.build(input)
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    self?.applyPresentation(
                        snapshot,
                        generation: generation
                    )
                }
            } catch {
                return
            }
        }
    }

    private func cancelPresentationUpdate() {
        presentationGeneration &+= 1
        presentationTask?.cancel()
        presentationTask = nil
    }

    private func presentationInput() -> XboxCatalogPresentationInput {
        XboxCatalogPresentationInput(
            items: allItems,
            favoriteIDs: favoriteIDs,
            recentlyPlayedIDs: recentlyPlayedIDs,
            scope: catalogScope,
            searchText: searchText,
            sortOrder: sortOrder,
            filterState: filterState,
            visibleItemLimit: visibleItemLimit
        )
    }

    private func applyPresentation(
        _ snapshot: XboxCatalogPresentationSnapshot,
        generation: UInt64
    ) {
        guard presentationGeneration == generation else { return }
        presentationTask = nil
        applyPresentation(snapshot)
    }

    private func applyPresentation(
        _ snapshot: XboxCatalogPresentationSnapshot
    ) {
        if snapshot.scope != presentedCatalogScope {
            presentedCatalogScope = snapshot.scope
        }
        if snapshot.visibleItems != visibleItems {
            visibleItems = snapshot.visibleItems
        }
        if snapshot.carouselItems != carouselItems {
            carouselItems = snapshot.carouselItems
        }
        if snapshot.selectedRoutesByItemID != selectedRoutesByItemID {
            selectedRoutesByItemID = snapshot.selectedRoutesByItemID
        }
        if snapshot.favoriteItems != favoriteItems {
            favoriteItems = snapshot.favoriteItems
        }
        if snapshot.recentlyPlayedItems != recentlyPlayedItems {
            recentlyPlayedItems = snapshot.recentlyPlayedItems
        }
        if snapshot.availableAccessKinds != availableAccessKinds {
            availableAccessKinds = snapshot.availableAccessKinds
        }
        if snapshot.playableAccessKinds != playableAccessKinds {
            playableAccessKinds = snapshot.playableAccessKinds
        }
        if snapshot.filterOptions != filterOptions {
            filterOptions = snapshot.filterOptions
        }
        if snapshot.totalItemCount != totalItemCount {
            totalItemCount = snapshot.totalItemCount
        }
        if snapshot.browseFilterBaseCount != browseFilterBaseCount {
            browseFilterBaseCount = snapshot.browseFilterBaseCount
        }
        if snapshot.filteredItemCount != filteredItemCount {
            filteredItemCount = snapshot.filteredItemCount
        }
    }

    private func loadActivityIfNeeded() async {
        guard !hasLoadedActivity else { return }
        let generation = activityGeneration
        let task: Task<CloudCatalogActivityLease, Never>
        if let activityLoadTask {
            task = activityLoadTask
        } else {
            let persistence = activityPersistence
            let accountScope = account.activityScopeIdentifier
            task = Task {
                await persistence.loadXboxCatalogActivityLease(
                    accountScope: accountScope
                )
            }
            activityLoadTask = task
        }

        let lease = await task.value
        guard generation == activityGeneration,
              !Task.isCancelled
        else {
            return
        }
        activityLoadTask = nil
        activityPersistenceGeneration = lease.generation
        favoriteIDs = lease.snapshot.favoriteIDs
        recentlyPlayedIDs = lease.snapshot.recentlyPlayedIDs
        hasLoadedActivity = true
        do {
            try await rebuildPresentation()
        } catch {
            guard generation == activityGeneration else { return }
            hasLoadedActivity = false
        }
    }

    private func enqueueFavoriteSave() {
        guard let expectedGeneration = activityPersistenceGeneration else {
            return
        }
        let persistence = activityPersistence
        let accountScope = account.activityScopeIdentifier
        let favoriteIDs = favoriteIDs
        enqueueActivitySave {
            await persistence.saveXboxFavoriteIDs(
                favoriteIDs,
                accountScope: accountScope,
                expectedGeneration: expectedGeneration
            )
        }
    }

    private func enqueueRecentlyPlayedSave() {
        guard let expectedGeneration = activityPersistenceGeneration else {
            return
        }
        let persistence = activityPersistence
        let accountScope = account.activityScopeIdentifier
        let recentlyPlayedIDs = recentlyPlayedIDs
        enqueueActivitySave {
            await persistence.saveXboxRecentlyPlayedIDs(
                recentlyPlayedIDs,
                accountScope: accountScope,
                expectedGeneration: expectedGeneration
            )
        }
    }

    private func enqueueActivitySave(
        _ operation: @escaping @Sendable () async -> Void
    ) {
        let previousTask = activitySaveTask
        activitySaveTask = Task { @concurrent in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    private func resolvedClient() -> any XboxCatalogClient {
        if let client {
            return client
        }
        let client = makeClient()
        self.client = client
        return client
    }

    private func cacheDetail(_ detail: XboxCatalogItem) {
        detailItems[detail.id] = detail
        touchCachedDetail(detail.id)
        while detailCacheOrder.count > Self.maximumDetailCacheCount {
            let evictedID = detailCacheOrder.removeFirst()
            detailItems.removeValue(forKey: evictedID)
        }
    }

    private func touchCachedDetail(_ itemID: String) {
        detailCacheOrder.removeAll { $0 == itemID }
        detailCacheOrder.append(itemID)
    }

    private func cancelDetailLoads() {
        detailLoads.values.forEach { $0.task.cancel() }
        detailLoads.removeAll(keepingCapacity: false)
    }
}

nonisolated struct XboxHomeHeroPresentation: Equatable, Sendable {
    let item: XboxCatalogItem
    let artworkURL: URL?
    let usesHeroArtwork: Bool

    static func requiresDetailEnrichment(_ item: XboxCatalogItem) -> Bool {
        item.heroArtworkURL == nil
    }

    init(
        catalogItem: XboxCatalogItem,
        detailItem: XboxCatalogItem?
    ) {
        item = if let detailItem, detailItem.id == catalogItem.id {
            detailItem
        } else {
            catalogItem
        }
        if let heroArtworkURL = item.heroArtworkURL {
            artworkURL = heroArtworkURL
            usesHeroArtwork = true
        } else {
            artworkURL = item.artworkURL
            usesHeroArtwork = false
        }
    }
}

private struct XboxCatalogHome: View {
    let recentlyPlayedItems: [XboxCatalogItem]
    let favoriteItems: [XboxCatalogItem]
    let phase: XboxCatalogViewModel.LoadPhase
    let showsRefreshWarning: Bool
    let resumableSession: XboxCloudResumableSessionPresentation?
    let onBrowse: () -> Void
    let onRetry: () -> Void
    let onContinue: (XboxCloudResumableSessionPresentation) -> Void
    let onPlay: (XboxCatalogItem, XboxCloudTitleRoute) -> Void
    let onToggleFavorite: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(XboxCatalogViewModel.self) private var viewModel
    @Environment(CloudInputDeviceMonitor.self) private var inputDeviceMonitor
    @State private var carouselRequest: XboxCatalogCarouselRequest?
    @State private var carouselSourceFocus: XboxHomeGameFocus?
    @State private var carouselRestoreFocus: XboxHomeGameFocus?
    @State private var heroDetailItem: XboxCatalogItem?
    @State private var restoresHeroActionFocus = false
    @State private var restoresEmptyActionFocus = false
    @State private var restoreScrollTarget: XboxHomeGameFocus?
    @FocusState private var focusedCard: XboxHomeGameFocus?
    @FocusState private var heroActionFocused: Bool
    @FocusState private var emptyActionFocused: Bool

    private var heroSelection: XboxCatalogSelection? {
        selection(for: recentlyPlayedItems.first)
            ?? selection(for: favoriteItems.first)
    }

    private var heroPresentation: XboxHomeHeroPresentation? {
        guard let heroSelection else { return nil }
        return XboxHomeHeroPresentation(
            catalogItem: heroSelection.item,
            detailItem: heroDetailItem
        )
    }

    private var emptyStateMessage: String {
        L10n.text("xbox_empty_home_message")
    }

    private var recentlyPlayedWithoutHero: [XboxCatalogItem] {
        recentlyPlayedItems.filter { $0.id != heroSelection?.item.id }
    }

    var body: some View {
        ZStack {
            if resumableSession != nil {
                loadedContent
            } else {
                switch phase {
                case .idle, .loading:
                    XboxCatalogHomeSkeleton()
                case .failed:
                    emptyState
                        .accessibilityIdentifier("xbox-home-empty")
                case .loaded where heroSelection == nil:
                    emptyState
                        .accessibilityIdentifier("xbox-home-empty")
                case .loaded:
                    loadedContent
                }
            }
        }
        .fullScreenCover(
            item: $carouselRequest,
            onDismiss: restoreCarouselFocus
        ) { request in
            XboxCatalogCarousel(
                request: request,
                onPlay: onPlay,
                onDismiss: { selectionID in
                    dismissCarousel(request: request, after: selectionID)
                }
            )
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.25),
            value: carouselRequest?.id
        )
        .task(id: heroSelection?.item) {
            await loadHeroDetail(for: heroSelection?.item)
        }
    }

    private var emptyState: some View {
        CloudCatalogHomeEmptyState(
            message: emptyStateMessage,
            actionTitle: L10n.text("browse"),
            action: onBrowse,
            actionFocus: $emptyActionFocused
        )
    }

    private var loadedContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let resumableSession {
                        CloudResumableSessionBanner(
                            title: resumableSession.item.title,
                            artworkURL: resumableSession.item.heroArtworkURL?
                                .absoluteString
                                ?? resumableSession.item.artworkURL?
                                .absoluteString,
                            expiresAt: resumableSession.expiresAt,
                            isResumeEnabled: resumableSession
                                .hasCompatibleInput,
                            onResume: { onContinue(resumableSession) }
                        )
                    }

                    if let heroSelection, let heroPresentation {
                        CloudCatalogHeroBanner(
                            artworkURL: heroPresentation.artworkURL?.absoluteString,
                            artworkContentMode: heroPresentation.usesHeroArtwork
                                ? .fill
                                : .fit,
                            artworkAlignment: .center,
                            actionTitle: heroSelection.playTitle,
                            actionSystemImage: heroSelection.isPlayable
                                ? "play.fill"
                                : "lock.fill",
                            isActionEnabled: heroSelection.isPlayable,
                            actionTint: heroSelection.isPlayable
                                ? .green
                                : .gray,
                            actionFocus: $heroActionFocused,
                            action: {
                                onPlay(heroPresentation.item, heroSelection.route)
                            }
                        )
                        .accessibilityIdentifier("xbox-home.hero")
                    }

                    if showsRefreshWarning {
                        XboxCatalogRefreshWarning(
                            lastUpdatedAt: viewModel.catalogLastUpdatedAt,
                            onRetry: onRetry
                        )
                        .padding(.horizontal, 60)
                        .padding(.top, 24)
                    }

                    VStack(alignment: .leading, spacing: 48) {
                        if !recentlyPlayedWithoutHero.isEmpty {
                            XboxCatalogRail(
                                row: .recent,
                                title: L10n.text("recently_played"),
                                items: recentlyPlayedWithoutHero,
                                focusedCard: $focusedCard,
                                onPlay: onPlay,
                                onShowInfo: showCarousel,
                                onToggleFavorite: onToggleFavorite
                            )
                            .accessibilityIdentifier("xbox-home.recent")
                        }

                        if !favoriteItems.isEmpty {
                            XboxCatalogRail(
                                row: .favorites,
                                title: L10n.text("favorites"),
                                items: favoriteItems,
                                isFavoritesRow: true,
                                focusedCard: $focusedCard,
                                onPlay: onPlay,
                                onShowInfo: showCarousel,
                                onToggleFavorite: onToggleFavorite
                            )
                            .accessibilityIdentifier("xbox-home.favorites")
                        }
                    }
                    .padding(.top, 48)
                    .padding(.bottom, 60)
                }
            }
            .onChange(of: restoreScrollTarget) { _, target in
                guard let target else { return }
                if reduceMotion {
                    proxy.scrollTo(target, anchor: .center)
                } else {
                    withAnimation {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
                restoreScrollTarget = nil
            }
        }
    }

    private func loadHeroDetail(for item: XboxCatalogItem?) async {
        heroDetailItem = nil
        guard let item,
              XboxHomeHeroPresentation.requiresDetailEnrichment(item)
        else {
            return
        }
        let detailItem = await viewModel.fetchDetail(for: item)
        guard !Task.isCancelled,
              heroSelection?.item.id == item.id
        else {
            return
        }
        heroDetailItem = detailItem
    }

    private func showCarousel(
        selections: [XboxCatalogSelection],
        sourceFocus: XboxHomeGameFocus
    ) {
        guard let start = selections.first(where: {
            $0.item.id == sourceFocus.itemID
        }) else {
            return
        }
        carouselSourceFocus = sourceFocus
        carouselRequest = XboxCatalogCarouselRequest(
            selections: selections,
            startID: start.id
        )
    }

    private func dismissCarousel(
        request: XboxCatalogCarouselRequest,
        after selectionID: String?
    ) {
        carouselRequest = nil
        let source = carouselSourceFocus
        carouselSourceFocus = nil
        guard let source else { return }
        let selectedItemID = request.selections.first(where: {
            $0.id == selectionID
        })?.item.id ?? source.itemID
        let survivingIDs = Set(
            (source.row == .recent
                ? recentlyPlayedWithoutHero
                : favoriteItems).map(\.id)
        )
        guard let itemID = nearestSurvivingCatalogItemID(
            orderedIDs: request.selections.map(\.item.id),
            preferredID: selectedItemID,
            survivingIDs: survivingIDs
        ) else {
            if let itemID = recentlyPlayedWithoutHero.first?.id {
                carouselRestoreFocus = XboxHomeGameFocus(
                    row: .recent,
                    itemID: itemID
                )
            } else if let itemID = favoriteItems.first?.id {
                carouselRestoreFocus = XboxHomeGameFocus(
                    row: .favorites,
                    itemID: itemID
                )
            } else if heroSelection?.isPlayable == true {
                restoresHeroActionFocus = true
            } else if heroSelection != nil {
                onBrowse()
            } else {
                restoresEmptyActionFocus = true
            }
            return
        }
        carouselRestoreFocus = XboxHomeGameFocus(
            row: source.row,
            itemID: itemID
        )
    }

    private func restoreCarouselFocus() {
        if restoresHeroActionFocus {
            restoresHeroActionFocus = false
            Task { @MainActor in
                await Task.yield()
                guard carouselRequest == nil else { return }
                heroActionFocused = true
            }
            return
        }
        if restoresEmptyActionFocus {
            restoresEmptyActionFocus = false
            Task { @MainActor in
                await Task.yield()
                guard carouselRequest == nil else { return }
                emptyActionFocused = true
            }
            return
        }
        guard let target = carouselRestoreFocus else { return }
        carouselRestoreFocus = nil
        restoreScrollTarget = target
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(150))
            guard carouselRequest == nil else { return }
            focusedCard = nil
            await Task.yield()
            focusedCard = target
        }
    }

    private func selection(
        for item: XboxCatalogItem?
    ) -> XboxCatalogSelection? {
        guard let item, let route = item.preferredRoute else { return nil }
        return XboxCatalogSelection(
            item: item,
            route: route,
            connectedDevices: inputDeviceMonitor.connectedDevices
        )
    }
}

private struct XboxCatalogHomeSkeleton: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Color.gray.opacity(0.2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shimmer()
                    .padding(.horizontal, 60)

                VStack(alignment: .leading, spacing: 48) {
                    skeletonRail
                    skeletonRail
                }
                .padding(.top, 48)
                .padding(.bottom, 60)
            }
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("xbox-home-loading")
    }

    private var skeletonRail: some View {
        VStack(alignment: .leading, spacing: 20) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.25))
                .frame(width: 180, height: 24)
                .shimmer()
                .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(0 ..< 6, id: \.self) { _ in
                        GameCardSkeleton()
                            .frame(width: 200)
                    }
                }
                .padding(.horizontal, 60)
            }
        }
    }
}

private struct XboxCatalogRail: View {
    let row: XboxHomeGameRow
    let title: String
    let items: [XboxCatalogItem]
    var isFavoritesRow = false
    var focusedCard: FocusState<XboxHomeGameFocus?>.Binding
    let onPlay: (XboxCatalogItem, XboxCloudTitleRoute) -> Void
    let onShowInfo: ([XboxCatalogSelection], XboxHomeGameFocus) -> Void
    let onToggleFavorite: (String) -> Void

    @Environment(CloudInputDeviceMonitor.self) private var inputDeviceMonitor

    private var selections: [XboxCatalogSelection] {
        items.compactMap { item in
            item.preferredRoute.map {
                XboxCatalogSelection(
                    item: item,
                    route: $0,
                    connectedDevices: inputDeviceMonitor.connectedDevices
                )
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(selections) { selection in
                        let focus = XboxHomeGameFocus(
                            row: row,
                            itemID: selection.item.id
                        )
                        Button {
                            if selection.isPlayable {
                                onPlay(selection.item, selection.route)
                            } else {
                                onShowInfo(selections, focus)
                            }
                        } label: {
                            XboxCatalogCardLabel(selection: selection)
                        }
                        .frame(width: 200)
                        .buttonStyle(.card)
                        .id(focus)
                        .focused(focusedCard, equals: focus)
                        .contextMenu {
                            Button {
                                onShowInfo(selections, focus)
                            } label: {
                                Label(L10n.text("info"), systemImage: "info.circle")
                            }
                            if isFavoritesRow {
                                Button {
                                    onToggleFavorite(selection.item.id)
                                } label: {
                                    Label(
                                        L10n.text("remove_from_favorites"),
                                        systemImage: "star.slash.fill"
                                    )
                                }
                            }
                        }
                        .accessibilityIdentifier(selection.cardAccessibilityID)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
            }
            .focusSection()
            .scrollClipDisabled()
        }
    }
}

private enum XboxHomeGameRow: Hashable {
    case recent
    case favorites
}

private struct XboxHomeGameFocus: Hashable {
    let row: XboxHomeGameRow
    let itemID: String
}

private struct XboxCatalogGrid: View {
    let scope: XboxCatalogScope
    let onRetry: () -> Void
    let onPlay: (XboxCatalogItem, XboxCloudTitleRoute) -> Void
    @Binding var playbackFocusRestoreID: String?

    @Environment(XboxCatalogViewModel.self) private var viewModel
    @Environment(CloudInputDeviceMonitor.self) private var inputDeviceMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var carouselRequest: XboxCatalogCarouselRequest?
    @State private var carouselRestoreFocusID: String?
    @State private var restoresEmptyActionFocus = false
    @State private var expandedSelection: XboxCatalogSelection?
    @State private var detailRestoreFocusID: String?
    @State private var detailRestoresEmptyActionFocus = false
    @State private var detailSourceItemIDs: [String] = []
    @FocusState private var focusedCardID: String?
    @FocusState private var emptyActionFocused: Bool
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        ZStack {
            switch viewModel.phase {
            case .idle, .loading:
                CloudCatalogLoadingGrid()
            case .failed:
                XboxCatalogFailureView(onRetry: onRetry)
                    .padding(60)
            case .loaded where viewModel.presentedCatalogScope != scope:
                CloudCatalogLoadingGrid()
            case .loaded where viewModel.totalItemCount == 0:
                XboxCatalogEmptyView()
                    .padding(60)
            case .loaded:
                catalogGrid
            }
        }
        .searchable(
            text: searchTextBinding,
            prompt: Text(
                L10n.format("search_games_count", viewModel.totalItemCount)
            )
        )
        .overlay(alignment: .topLeading) {
            searchFocusFixture
        }
        .fullScreenCover(
            item: $carouselRequest,
            onDismiss: restoreCarouselFocus
        ) { request in
            XboxCatalogCarousel(
                request: request,
                onPlay: onPlay,
                onDismiss: { selectionID in
                    dismissCarousel(request: request, after: selectionID)
                }
            )
        }
        .fullScreenCover(
            item: $expandedSelection,
            onDismiss: restoreStandaloneDetailFocus
        ) { selection in
            XboxCatalogStandaloneDetail(
                selection: selection,
                onPlay: {
                    expandedSelection = nil
                    onPlay(selection.item, selection.route)
                },
                onDismiss: {
                    detailRestoreFocusID = nearestSurvivingCatalogItemID(
                        orderedIDs: detailSourceItemIDs,
                        preferredID: selection.item.id,
                        survivingIDs: Set(viewModel.visibleItems.map(\.id))
                    )
                    detailRestoresEmptyActionFocus = detailRestoreFocusID == nil
                    detailSourceItemIDs.removeAll(keepingCapacity: false)
                    expandedSelection = nil
                }
            )
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.25),
            value: carouselRequest?.id
        )
        .task(id: playbackFocusRestoreID) {
            guard let itemID = playbackFocusRestoreID else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, carouselRequest == nil else { return }
            focusedCardID = nil
            await Task.yield()
            focusedCardID = itemID
            playbackFocusRestoreID = nil
        }
        .task(id: scope) {
            viewModel.setCatalogScope(scope)
            await viewModel.waitForPendingPresentationUpdate()
        }
        .task(id: focusesSearchForUITesting) {
            guard focusesSearchForUITesting else { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            searchFieldFocused = true
        }
    }

    private var catalogGrid: some View {
        CloudCatalogGrid(
            items: viewModel.visibleItems,
            focusedId: $focusedCardID,
            emptyActionFocus: $emptyActionFocused,
            hasActiveFilters: viewModel.hasActiveFilters(for: scope),
            onClearFilters: { viewModel.clearFilters(for: scope) },
            onSelect: showCarousel(startingAt:),
            onItemVisible: { item, _ in
                viewModel.loadNextPageIfNeeded(item, in: scope)
            },
            accessibilityIdentifier: { item in
                selection(for: item)?.cardAccessibilityID ?? item.id
            },
            header: { filterHeader },
            cardLabel: { item in
                if let selection = selection(for: item) {
                    XboxCatalogCardLabel(selection: selection)
                }
            },
            menuContent: { item in
                Button {
                    detailSourceItemIDs = viewModel.visibleItems.map(\.id)
                    expandedSelection = selection(for: item)
                } label: {
                    Label(L10n.text("info"), systemImage: "info.circle")
                }

                Button {
                    viewModel.toggleFavorite(item)
                } label: {
                    Label(
                        viewModel.isFavorite(item)
                            ? L10n.text("remove_from_favorites")
                            : L10n.text("add_to_favorites"),
                        systemImage: viewModel.isFavorite(item)
                            ? "star.slash.fill"
                            : "star"
                    )
                }
            }
        )
    }

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { viewModel.searchText(for: scope) },
            set: { viewModel.setSearchText($0, for: scope) }
        )
    }

    private var focusesSearchForUITesting: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains(
                "--cloudnow-ui-xbox-search-focused"
            )
        #else
            false
        #endif
    }

    @ViewBuilder
    private var searchFocusFixture: some View {
        #if DEBUG
            if focusesSearchForUITesting {
                TextField("", text: searchTextBinding)
                    .focused($searchFieldFocused)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .accessibilityHidden(true)
            }
        #endif
    }

    private var filterHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.showsRefreshWarning {
                XboxCatalogRefreshWarning(
                    lastUpdatedAt: viewModel.catalogLastUpdatedAt,
                    onRetry: onRetry
                )
                .padding(.horizontal, 60)
                .padding(.top, 24)
            }
            XboxCatalogFilterBar(scope: scope)
        }
    }

    private func selection(for item: XboxCatalogItem) -> XboxCatalogSelection? {
        viewModel.selectedRoute(for: item).map {
            XboxCatalogSelection(
                item: item,
                route: $0,
                connectedDevices: inputDeviceMonitor.connectedDevices
            )
        }
    }

    private func showCarousel(startingAt item: XboxCatalogItem) {
        let selections = viewModel.carouselItems.compactMap(selection(for:))
        guard let start = selection(for: item) else { return }
        carouselRequest = XboxCatalogCarouselRequest(
            selections: selections,
            startID: start.id
        )
    }

    private func dismissCarousel(
        request: XboxCatalogCarouselRequest,
        after selectionID: String?
    ) {
        carouselRequest = nil
        guard let selectionID else { return }
        let selectedItemID = request.selections.first(where: {
            $0.id == selectionID
        })?.item.id
        guard
            let selectedItemID,
            let itemID = nearestSurvivingCatalogItemID(
                orderedIDs: request.selections.map(\.item.id),
                preferredID: selectedItemID,
                survivingIDs: Set(viewModel.visibleItems.map(\.id))
            )
        else {
            restoresEmptyActionFocus = true
            return
        }
        carouselRestoreFocusID = itemID
    }

    private func restoreCarouselFocus() {
        if restoresEmptyActionFocus {
            restoresEmptyActionFocus = false
            restoreEmptyActionFocus()
            return
        }
        guard let itemID = carouselRestoreFocusID else { return }
        carouselRestoreFocusID = nil
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(150))
            guard carouselRequest == nil else { return }
            focusedCardID = nil
            await Task.yield()
            focusedCardID = itemID
        }
    }

    private func restoreStandaloneDetailFocus() {
        if detailRestoresEmptyActionFocus {
            detailRestoresEmptyActionFocus = false
            restoreEmptyActionFocus()
            return
        }
        guard let itemID = detailRestoreFocusID else { return }
        detailRestoreFocusID = nil
        restoreFocus(to: itemID)
    }

    private func restoreFocus(to itemID: String) {
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(150))
            guard carouselRequest == nil, expandedSelection == nil else {
                return
            }
            focusedCardID = nil
            await Task.yield()
            focusedCardID = itemID
        }
    }

    private func restoreEmptyActionFocus() {
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(150))
            guard carouselRequest == nil, expandedSelection == nil else {
                return
            }
            emptyActionFocused = true
        }
    }
}

nonisolated func nearestSurvivingCatalogItemID(
    orderedIDs: [String],
    preferredID: String,
    survivingIDs: Set<String>
) -> String? {
    guard !survivingIDs.isEmpty else { return nil }
    guard let preferredIndex = orderedIDs.firstIndex(of: preferredID) else {
        return orderedIDs.first(where: survivingIDs.contains)
    }
    if survivingIDs.contains(preferredID) {
        return preferredID
    }
    for offset in 1 ..< orderedIDs.count {
        let nextIndex = preferredIndex + offset
        if orderedIDs.indices.contains(nextIndex),
           survivingIDs.contains(orderedIDs[nextIndex])
        {
            return orderedIDs[nextIndex]
        }
        let previousIndex = preferredIndex - offset
        if orderedIDs.indices.contains(previousIndex),
           survivingIDs.contains(orderedIDs[previousIndex])
        {
            return orderedIDs[previousIndex]
        }
    }
    return orderedIDs.first(where: survivingIDs.contains)
}

private struct XboxCatalogFilterBar: View {
    let scope: XboxCatalogScope

    @Environment(XboxCloudModeViewModel.self) private var modeViewModel
    @Environment(XboxCatalogViewModel.self) private var viewModel
    @State private var isShowingFilters = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideToolbar
            compactToolbar
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 22)
        .focusSection()
        .fullScreenCover(isPresented: $isShowingFilters) {
            XboxCatalogFilterSheet(
                scope: scope,
                state: filterStateBinding,
                options: viewModel.filterOptions,
                totalCount: viewModel.browseFilterBaseCount,
                previewCount: viewModel.filteredItemCount,
                onClose: { isShowingFilters = false }
            )
        }
    }

    private var wideToolbar: some View {
        HStack(spacing: 20) {
            resultSummary
            activeFilterScroll
            Spacer(minLength: 12)
            actionControls(compactRefresh: false)
        }
    }

    private var compactToolbar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                resultSummary
                activeFilterScroll
            }
            actionControls(compactRefresh: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var resultSummary: some View {
        Text(
            L10n.format(
                "games_result_count",
                viewModel.filteredItemCount,
                viewModel.totalItemCount
            )
        )
        .font(.headline.monospacedDigit())
        .foregroundStyle(.primary)
        .fixedSize()
        .accessibilityIdentifier("catalog-result-count")
    }

    @ViewBuilder
    private var activeFilterScroll: some View {
        if !activeFilters.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(activeFilters) { filter in
                        XboxCatalogActiveFilterChip(
                            label: filter.label,
                            onRemove: filter.onRemove
                        )
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private func actionControls(compactRefresh: Bool) -> some View {
        HStack(spacing: 20) {
            Menu {
                Picker(L10n.text("sort"), selection: sortOrderBinding) {
                    ForEach(XboxCatalogSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
            } label: {
                Label(
                    selectedSortLabel,
                    systemImage: "line.3.horizontal.decrease"
                )
                .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("catalog-sort-menu")

            Button {
                isShowingFilters = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(L10n.text("filters"))
                        .lineLimit(1)
                    if viewModel.activeFilterCount(for: scope) > 0 {
                        Text("\(viewModel.activeFilterCount(for: scope))")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.green, in: Capsule())
                    }
                }
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("catalog-filter-button")

            Button {
                modeViewModel.startFreshLibraryRefresh()
            } label: {
                if compactRefresh {
                    Image(systemName: "arrow.clockwise")
                } else {
                    Label(
                        L10n.text("refresh_library"),
                        systemImage: "arrow.clockwise"
                    )
                    .lineLimit(1)
                }
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!modeViewModel.canStartFreshLibraryRefresh)
            .accessibilityLabel(L10n.text("refresh_library"))
            .accessibilityIdentifier("reloadXboxCloudCatalogButton")
        }
    }

    private var selectedSortLabel: String {
        viewModel.sortOrder(for: scope).label
    }

    private var sortOrderBinding: Binding<XboxCatalogSortOrder> {
        Binding(
            get: { viewModel.sortOrder(for: scope) },
            set: { viewModel.setSortOrder($0, for: scope) }
        )
    }

    private var filterStateBinding: Binding<XboxCatalogFilterState> {
        Binding(
            get: { viewModel.filterState(for: scope) },
            set: { viewModel.setFilterState($0, for: scope) }
        )
    }

    private var currentFilterState: XboxCatalogFilterState {
        viewModel.filterState(for: scope)
    }

    private var activeFilters: [CloudCatalogActiveFilter] {
        var filters: [CloudCatalogActiveFilter] = []

        for collection in currentFilterState.collections {
            filters.append(CloudCatalogActiveFilter(
                id: "xbox-collection-\(collection.id)",
                label: collection.label,
                onRemove: { remove(collection) }
            ))
        }
        for access in currentFilterState.access.sorted(by: {
            $0.sortOrder < $1.sortOrder
        }) {
            filters.append(CloudCatalogActiveFilter(
                id: "xbox-access-\(access.id)",
                label: access.label,
                onRemove: { remove(access) }
            ))
        }
        for playability in currentFilterState.playability.sorted(by: {
            $0.sortOrder < $1.sortOrder
        }) {
            filters.append(CloudCatalogActiveFilter(
                id: "xbox-playability-\(playability.id)",
                label: playability.label,
                onRemove: { remove(playability) }
            ))
        }
        for reason in currentFilterState.unavailableReasons.sorted(by: {
            $0.sortOrder < $1.sortOrder
        }) {
            filters.append(CloudCatalogActiveFilter(
                id: "xbox-unavailable-reason-\(reason.id)",
                label: reason.label,
                onRemove: { remove(reason) }
            ))
        }
        for inputType in currentFilterState.inputTypes.sorted(by: {
            $0.sortOrder < $1.sortOrder
        }) {
            filters.append(CloudCatalogActiveFilter(
                id: "xbox-input-\(inputType.id)",
                label: inputType.label,
                onRemove: { remove(inputType) }
            ))
        }
        for genreID in currentFilterState.genres.sorted() {
            let label = viewModel.filterOptions.genres.first {
                $0.id == genreID
            }?.label ?? genreID
            filters.append(CloudCatalogActiveFilter(
                id: "xbox-genre-\(genreID)",
                label: label,
                onRemove: { removeGenre(genreID) }
            ))
        }
        return filters
    }

    private func remove(_ collection: XboxCatalogCollectionFilter) {
        var state = currentFilterState
        state.collections.remove(collection)
        viewModel.setFilterState(state, for: scope)
    }

    private func remove(_ access: XboxCatalogAccessFilter) {
        var state = currentFilterState
        state.access.remove(access)
        viewModel.setFilterState(state, for: scope)
    }

    private func remove(_ inputType: XboxCloudInputType) {
        var state = currentFilterState
        state.inputTypes.remove(inputType)
        viewModel.setFilterState(state, for: scope)
    }

    private func remove(_ playability: XboxCatalogPlayabilityFilter) {
        var state = currentFilterState
        state.playability.remove(playability)
        viewModel.setFilterState(state, for: scope)
    }

    private func remove(_ reason: XboxCloudRoutePlayabilityReason) {
        var state = currentFilterState
        state.unavailableReasons.remove(reason)
        viewModel.setFilterState(state, for: scope)
    }

    private func removeGenre(_ genreID: String) {
        var state = currentFilterState
        state.genres.remove(genreID)
        viewModel.setFilterState(state, for: scope)
    }
}

private struct XboxCatalogActiveFilterChip: View {
    let label: String
    let onRemove: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 7) {
                Text(label)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.black.opacity(0.84))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.green, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(isFocused ? Color.white : Color.clear, lineWidth: 3)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.07 : 1)
        .shadow(color: isFocused ? Color.white.opacity(0.25) : .clear, radius: 12)
        .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

private struct XboxCatalogFilterSheet: View {
    let scope: XboxCatalogScope
    @Binding var state: XboxCatalogFilterState
    let options: XboxCatalogFilterOptions
    let totalCount: Int
    let previewCount: Int
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedSections: Set<XboxCatalogFilterSection> = [
        .collections,
        .playability,
        .access,
        .input,
        .genres,
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: sheetBackgroundColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 16) {
                        if options.showsCollectionsSection {
                            collectionsSection
                        }
                        if scope == .browse, showsPlayabilityFilters {
                            playabilitySection
                        }
                        if scope == .browse,
                           !availableUnavailableReasons.isEmpty
                        {
                            unavailableReasonsSection
                        }
                        if !options.availableAccessFilters.isEmpty {
                            accessSection
                        }
                        if !availableInputTypes.isEmpty {
                            inputSection
                        }
                        if !options.genres.isEmpty {
                            genresSection
                        }
                    }
                    .padding(.horizontal, 70)
                    .padding(.vertical, 22)
                }
            }
        }
        .onExitCommand(perform: onClose)
        .blocksGlobalControllerNavigation()
        .accessibilityIdentifier("xbox-catalog-filter-sheet")
    }

    private var header: some View {
        HStack(spacing: 20) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
            Text(L10n.text("filters"))
                .font(.title2.weight(.bold))

            if !state.isEmpty {
                Text("\(state.activeSelectionCount)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.green, in: Capsule())
            }

            Text(
                L10n.format(
                    "games_result_count",
                    previewCount,
                    totalCount
                )
            )
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                state.clear()
            } label: {
                Label(
                    L10n.text("clear_all"),
                    systemImage: "arrow.counterclockwise"
                )
            }
            .buttonStyle(.bordered)
            .disabled(state.isEmpty)

            Button(action: onClose) {
                Label(L10n.text("done"), systemImage: "checkmark")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 70)
        .padding(.vertical, 18)
        .background(Color.black.opacity(colorScheme == .dark ? 0.38 : 0.04))
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    private var sheetBackgroundColors: [Color] {
        colorScheme == .dark
            ? [Color(white: 0.055), Color(white: 0.11)]
            : [Color(white: 0.98), Color(white: 0.9)]
    }

    private var collectionsSection: some View {
        FilterAccordionSection(
            title: L10n.text("collections"),
            selectedCount: state.collections.count,
            isExpanded: expansionBinding(for: .collections)
        ) {
            WrappingFilterLayout(
                horizontalSpacing: 14,
                verticalSpacing: 14
            ) {
                FilterOptionButton(
                    label: XboxCatalogCollectionFilter.favorites.label,
                    count: options.favoriteCount,
                    isSelected: state.collections.contains(.favorites),
                    action: { toggle(.favorites) }
                )
            }
        }
    }

    private var accessSection: some View {
        FilterAccordionSection(
            title: L10n.text("cloud_gaming_access"),
            selectedCount: state.access.count,
            isExpanded: expansionBinding(for: .access)
        ) {
            WrappingFilterLayout(
                horizontalSpacing: 14,
                verticalSpacing: 14
            ) {
                ForEach(options.availableAccessFilters, id: \.self) { option in
                    FilterOptionButton(
                        label: option.label,
                        count: options.accessCount(option),
                        isSelected: state.access.contains(option),
                        action: { toggle(option) }
                    )
                }
            }
        }
    }

    private var playabilitySection: some View {
        FilterAccordionSection(
            title: L10n.text("playability"),
            selectedCount: state.playability.count,
            isExpanded: expansionBinding(for: .playability)
        ) {
            WrappingFilterLayout(
                horizontalSpacing: 14,
                verticalSpacing: 14
            ) {
                ForEach(availablePlayabilityOptions, id: \.self) { option in
                    FilterOptionButton(
                        label: option.label,
                        count: playabilityCount(option),
                        isSelected: state.playability.contains(option),
                        action: { toggle(option) }
                    )
                }
            }
        }
    }

    private var unavailableReasonsSection: some View {
        FilterAccordionSection(
            title: L10n.text("unavailable_reasons"),
            selectedCount: state.unavailableReasons.count,
            isExpanded: expansionBinding(for: .unavailableReasons)
        ) {
            WrappingFilterLayout(
                horizontalSpacing: 14,
                verticalSpacing: 14
            ) {
                ForEach(availableUnavailableReasons, id: \.self) { reason in
                    FilterOptionButton(
                        label: reason.label,
                        count: options.unavailableReasonCounts[reason] ?? 0,
                        isSelected: state.unavailableReasons.contains(reason),
                        action: { toggle(reason) }
                    )
                }
            }
        }
    }

    private var genresSection: some View {
        FilterAccordionSection(
            title: L10n.text("genres"),
            selectedCount: state.genres.count,
            isExpanded: expansionBinding(for: .genres)
        ) {
            WrappingFilterLayout(
                horizontalSpacing: 14,
                verticalSpacing: 14
            ) {
                ForEach(options.genres) { option in
                    FilterOptionButton(
                        label: option.label,
                        count: option.count,
                        isSelected: state.genres.contains(option.id),
                        action: { toggleGenre(option.id) }
                    )
                }
            }
        }
    }

    private var inputSection: some View {
        FilterAccordionSection(
            title: L10n.text("input"),
            selectedCount: state.inputTypes.count,
            isExpanded: expansionBinding(for: .input)
        ) {
            WrappingFilterLayout(
                horizontalSpacing: 14,
                verticalSpacing: 14
            ) {
                ForEach(availableInputTypes, id: \.self) { inputType in
                    FilterOptionButton(
                        label: inputType.label,
                        count: options.inputTypeCounts[inputType] ?? 0,
                        isSelected: state.inputTypes.contains(inputType),
                        action: { toggle(inputType) }
                    )
                }
            }
        }
    }

    private var availablePlayabilityOptions: [XboxCatalogPlayabilityFilter] {
        XboxCatalogPlayabilityFilter.allCases.filter {
            playabilityCount($0) > 0
        }
    }

    private var showsPlayabilityFilters: Bool {
        options.playableCount > 0 || options.unavailableCount > 0
    }

    private var availableUnavailableReasons: [
        XboxCloudRoutePlayabilityReason
    ] {
        XboxCloudRoutePlayabilityReason.unavailableFilterCases.filter {
            (options.unavailableReasonCounts[$0] ?? 0) > 0
        }
    }

    private var availableInputTypes: [XboxCloudInputType] {
        XboxCloudInputType.allCases
            .filter { (options.inputTypeCounts[$0] ?? 0) > 0 }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func playabilityCount(
        _ option: XboxCatalogPlayabilityFilter
    ) -> Int {
        switch option {
        case .playable:
            options.playableCount
        case .unavailable:
            options.unavailableCount
        }
    }

    private func toggle(_ collection: XboxCatalogCollectionFilter) {
        if state.collections.contains(collection) {
            state.collections.remove(collection)
        } else {
            state.collections.insert(collection)
        }
    }

    private func toggle(_ access: XboxCatalogAccessFilter) {
        if state.access.contains(access) {
            state.access.remove(access)
        } else {
            state.access.insert(access)
        }
    }

    private func toggle(_ inputType: XboxCloudInputType) {
        if state.inputTypes.contains(inputType) {
            state.inputTypes.remove(inputType)
        } else {
            state.inputTypes.insert(inputType)
        }
    }

    private func toggle(_ playability: XboxCatalogPlayabilityFilter) {
        if state.playability.contains(playability) {
            state.playability.remove(playability)
        } else {
            state.playability.insert(playability)
        }
    }

    private func toggle(_ reason: XboxCloudRoutePlayabilityReason) {
        if state.unavailableReasons.contains(reason) {
            state.unavailableReasons.remove(reason)
        } else {
            state.unavailableReasons.insert(reason)
        }
    }

    private func toggleGenre(_ genreID: String) {
        if state.genres.contains(genreID) {
            state.genres.remove(genreID)
        } else {
            state.genres.insert(genreID)
        }
    }

    private func expansionBinding(
        for section: XboxCatalogFilterSection
    ) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(section) },
            set: { isExpanded in
                if isExpanded {
                    expandedSections.insert(section)
                } else {
                    expandedSections.remove(section)
                }
            }
        )
    }
}

private enum XboxCatalogFilterSection: Hashable {
    case collections
    case playability
    case unavailableReasons
    case access
    case input
    case genres
}

private struct XboxCatalogCardLabel: View {
    let selection: XboxCatalogSelection

    var body: some View {
        CloudCatalogCardLabel(
            title: selection.item.title,
            artworkURL: selection.item.artworkURL?.absoluteString,
            heroArtworkURL: selection.item.heroArtworkURL?.absoluteString,
            badge: selection.badge
        )
        .accessibilityLabel(selection.item.title)
        .accessibilityValue(selection.accessibilityStatus)
    }
}

private struct XboxCatalogCarousel: View {
    let request: XboxCatalogCarouselRequest
    let onPlay: (XboxCatalogItem, XboxCloudTitleRoute) -> Void
    let onDismiss: (String?) -> Void

    @Environment(XboxCatalogViewModel.self) private var viewModel
    @Environment(CloudInputDeviceMonitor.self) private var inputDeviceMonitor
    @State private var detailItems: [String: XboxCatalogItem] = [:]
    @State private var detailCacheOrder: [String] = []
    @State private var detailLoadTokens: [String: UUID] = [:]
    @State private var detailLoadFailures: Set<String> = []

    private let maximumDetailCacheCount = 24

    var body: some View {
        CloudGameCarouselView(
            items: request.selections,
            startID: request.startID,
            onDismiss: onDismiss
        ) { context in
            let item = detailItems[context.item.item.id]
                ?? context.item.item
            XboxCatalogCarouselCard(
                selection: XboxCatalogSelection(
                    item: item,
                    route: context.item.route,
                    connectedDevices: inputDeviceMonitor.connectedDevices
                ),
                focusedID: context.focusedID,
                isCurrent: context.isCurrent,
                isExpanded: context.isExpanded,
                isFavorite: viewModel.isFavorite(context.item.item),
                isLoadingDetail: detailLoadTokens[context.item.item.id] != nil,
                detailLoadFailed: detailLoadFailures.contains(
                    context.item.item.id
                ),
                imageAlignment: context.imageAlignment,
                onExpand: context.expand,
                onCollapse: context.collapse,
                onToggleFavorite: {
                    viewModel.toggleFavorite(context.item.item)
                },
                onRetryDetail: {
                    Task {
                        await loadDetail(
                            for: context.item.item,
                            force: true
                        )
                    }
                },
                onPlay: {
                    onDismiss(context.currentID)
                    onPlay(context.item.item, context.item.route)
                }
            )
            .task(id: context.isCurrent) {
                guard context.isCurrent else { return }
                await loadDetail(for: context.item.item)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("xbox-game-carousel")
    }

    private func loadDetail(
        for item: XboxCatalogItem,
        force: Bool = false
    ) async {
        guard detailItems[item.id] == nil,
              force || !detailLoadFailures.contains(item.id)
        else {
            return
        }
        if force {
            detailLoadFailures.remove(item.id)
        }
        let token = UUID()
        detailLoadTokens[item.id] = token
        defer {
            if detailLoadTokens[item.id] == token {
                detailLoadTokens.removeValue(forKey: item.id)
            }
        }

        let detail = await viewModel.fetchDetail(for: item)
        guard !Task.isCancelled,
              detailLoadTokens[item.id] == token
        else {
            return
        }
        guard let detail else {
            detailLoadFailures.insert(item.id)
            return
        }
        detailLoadFailures.remove(item.id)
        detailItems[item.id] = detail
        detailCacheOrder.removeAll { $0 == item.id }
        detailCacheOrder.append(item.id)

        while detailCacheOrder.count > maximumDetailCacheCount {
            let evictedID = detailCacheOrder.removeFirst()
            detailItems.removeValue(forKey: evictedID)
        }
    }
}

private struct XboxCatalogStandaloneDetail: View {
    let selection: XboxCatalogSelection
    let onPlay: () -> Void
    let onDismiss: () -> Void

    @Environment(XboxCatalogViewModel.self) private var viewModel
    @State private var detailItem: XboxCatalogItem?
    @State private var isLoadingDetail = true
    @State private var detailLoadFailed = false
    @State private var detailLoadToken: UUID?

    var body: some View {
        let item = detailItem ?? selection.item
        XboxCatalogDetailView(
            item: item,
            route: selection.route,
            isInputAvailable: selection.isInputAvailable,
            isFavorite: viewModel.isFavorite(selection.item),
            isLoadingDetail: isLoadingDetail,
            detailLoadFailed: detailLoadFailed,
            presentationStyle: .fullScreen,
            onPlay: onPlay,
            onToggleFavorite: {
                viewModel.toggleFavorite(selection.item)
            },
            onRetryDetail: {
                Task { await loadDetail() }
            },
            onCollapse: onDismiss
        )
        .task(id: selection.item.id) {
            await loadDetail()
        }
    }

    private func loadDetail() async {
        let token = UUID()
        detailLoadToken = token
        detailLoadFailed = false
        isLoadingDetail = true
        let detail = await viewModel.fetchDetail(for: selection.item)
        guard !Task.isCancelled, detailLoadToken == token else { return }
        detailItem = detail
        detailLoadFailed = detail == nil
        isLoadingDetail = false
        detailLoadToken = nil
    }
}

private struct XboxCatalogCarouselCard: View {
    let selection: XboxCatalogSelection
    var focusedID: FocusState<String?>.Binding
    let isCurrent: Bool
    let isExpanded: Bool
    let isFavorite: Bool
    let isLoadingDetail: Bool
    let detailLoadFailed: Bool
    let imageAlignment: HorizontalAlignment
    let onExpand: () -> Void
    let onCollapse: () -> Void
    let onToggleFavorite: () -> Void
    let onRetryDetail: () -> Void
    let onPlay: () -> Void

    var body: some View {
        ZStack {
            cardBody

            if !isExpanded {
                Button(action: onExpand) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(PassthroughButtonStyle())
                .focusEffectDisabled()
                .focused(focusedID, equals: selection.id)
                .accessibilityLabel(selection.item.title)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .accessibilityIdentifier(
                    "xbox-carousel-card.\(selection.item.id)"
                )
            }
        }
        .focusSection()
    }

    private var cardBody: some View {
        ZStack(alignment: .bottomLeading) {
            if isExpanded {
                XboxCatalogDetailView(
                    item: selection.item,
                    route: selection.route,
                    isInputAvailable: selection.isInputAvailable,
                    isFavorite: isFavorite,
                    isLoadingDetail: isLoadingDetail,
                    detailLoadFailed: detailLoadFailed,
                    presentationStyle: .carouselExpanded,
                    onPlay: onPlay,
                    onToggleFavorite: onToggleFavorite,
                    onRetryDetail: onRetryDetail,
                    onCollapse: onCollapse
                )
            } else {
                carouselArtwork

                GameDetailArtworkScrim()
                    .opacity(isCurrent ? 1 : 0)

                if isCurrent {
                    XboxCatalogDetailView(
                        item: selection.item,
                        route: selection.route,
                        isInputAvailable: selection.isInputAvailable,
                        isFavorite: isFavorite,
                        isLoadingDetail: isLoadingDetail,
                        detailLoadFailed: detailLoadFailed,
                        presentationStyle: .embeddedCarousel,
                        onPlay: onPlay,
                        onToggleFavorite: onToggleFavorite,
                        onRetryDetail: onRetryDetail,
                        onCollapse: onCollapse
                    )
                }
            }

            if !isExpanded {
                UnevenRoundedRectangle(
                    topLeadingRadius: 20,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 20
                )
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.65), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
                .allowsHitTesting(false)
            }
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: isExpanded ? 0 : 20,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: isExpanded ? 0 : 20
            )
        )
        .shadow(
            color: .black.opacity(isCurrent ? 0.5 : 0.15),
            radius: isCurrent ? 20 : 4,
            x: 0,
            y: isCurrent ? 10 : 2
        )
    }

    private var carouselArtwork: some View {
        GeometryReader { geometry in
            SharedArtworkImage(
                urlString: selection.item.heroArtworkURL?.absoluteString
                    ?? selection.item.artworkURL?.absoluteString,
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
            .frame(height: geometry.size.height)
            .frame(
                width: geometry.size.width,
                alignment: Alignment(
                    horizontal: imageAlignment,
                    vertical: .center
                )
            )
            .clipped()
        }
    }
}

private struct XboxCatalogCarouselRequest: Identifiable {
    let id = UUID()
    let selections: [XboxCatalogSelection]
    let startID: String
}

private struct XboxCatalogSelection: Identifiable {
    let item: XboxCatalogItem
    let route: XboxCloudTitleRoute
    let isInputAvailable: Bool

    init(
        item: XboxCatalogItem,
        route: XboxCloudTitleRoute,
        connectedDevices: Set<CloudInputDeviceKind>
    ) {
        self.item = item
        self.route = route
        isInputAvailable = item.hasCompatibleInput(
            connectedDevices: connectedDevices
        )
    }

    var isPlayable: Bool {
        route.isPlayable && isInputAvailable
    }

    var id: String {
        "\(item.id)|\(route.titleID)|\(route.accessKind)"
    }

    var badge: CloudCatalogCardBadge? {
        guard isInputAvailable else {
            return CloudCatalogCardBadge(
                title: L10n.text("input"),
                systemImage: "gamecontroller",
                foregroundColor: .black,
                backgroundColor: .white.opacity(0.9)
            )
        }
        guard route.isPlayable else {
            return CloudCatalogCardBadge(
                title: route.playabilityReason.label,
                systemImage: "lock.fill",
                foregroundColor: .black,
                backgroundColor: .white.opacity(0.9)
            )
        }
        guard route.accessKind == .freeWithAds else { return nil }
        return CloudCatalogCardBadge(
            title: L10n.text("free_with_ads"),
            systemImage: nil,
            foregroundColor: .black,
            backgroundColor: .green
        )
    }

    var accessibilityStatus: String {
        guard isInputAvailable else {
            return L10n.text("compatible_input_required")
        }
        guard route.isPlayable else {
            return route.playabilityReason.label
        }
        if route.accessKind == .freeWithAds {
            return L10n.text("free_with_ads")
        }
        return L10n.text("cloud_gaming_access")
    }

    var playTitle: String {
        guard isInputAvailable else {
            return L10n.text("compatible_input_required")
        }
        guard route.isPlayable else {
            return route.playabilityReason.label
        }
        return route.accessKind == .freeWithAds
            ? L10n.text("stream_free_with_ads")
            : L10n.text("play")
    }

    var cardAccessibilityID: String {
        "xbox-game-card.\(item.id).\(route.accessKind).\(route.titleID)"
    }
}

private extension XboxCatalogCollectionFilter {
    var id: String {
        "favorites"
    }

    var label: String {
        L10n.text("favorites")
    }
}

private extension XboxCatalogAccessFilter {
    var id: String {
        switch self {
        case .standard:
            "game-pass"
        case .freeWithAds:
            "free-with-ads"
        case .owned:
            "owned"
        }
    }

    var label: String {
        switch self {
        case .standard:
            L10n.text("cloud_gaming_access")
        case .freeWithAds:
            L10n.text("free_with_ads")
        case .owned:
            L10n.text("owned")
        }
    }

    var sortOrder: Int {
        switch self {
        case .standard:
            0
        case .owned:
            1
        case .freeWithAds:
            2
        }
    }
}

private extension XboxCatalogPlayabilityFilter {
    var id: String {
        switch self {
        case .playable:
            "playable"
        case .unavailable:
            "unavailable"
        }
    }

    var label: String {
        switch self {
        case .playable:
            L10n.text("playable")
        case .unavailable:
            L10n.text("unavailable")
        }
    }

    var sortOrder: Int {
        switch self {
        case .playable:
            0
        case .unavailable:
            1
        }
    }
}

extension XboxCloudRoutePlayabilityReason {
    static let unavailableFilterCases: [Self] = [
        .entitlementRequired,
        .unsupportedStreamingProgram,
        .gameplayTimeExhausted,
        .eligibilityUnconfirmed,
    ]

    var id: String {
        switch self {
        case .authenticatedCatalog:
            "authenticated-catalog"
        case .fresnoServiceConfirmed:
            "service-confirmed"
        case .contentAccessConfirmed:
            "content-access-confirmed"
        case .entitlementRequired:
            "entitlement-required"
        case .unsupportedStreamingProgram:
            "unsupported-streaming-program"
        case .gameplayTimeExhausted:
            "gameplay-time-exhausted"
        case .eligibilityUnconfirmed:
            "eligibility-unconfirmed"
        }
    }

    var label: String {
        switch self {
        case .authenticatedCatalog,
             .fresnoServiceConfirmed,
             .contentAccessConfirmed:
            L10n.text("playable")
        case .entitlementRequired:
            L10n.text("not_in_cloud_library")
        case .unsupportedStreamingProgram:
            L10n.text("cloud_play_unavailable")
        case .gameplayTimeExhausted:
            L10n.text("gameplay_time_exhausted")
        case .eligibilityUnconfirmed:
            L10n.text("access_not_confirmed")
        }
    }

    var sortOrder: Int {
        switch self {
        case .entitlementRequired:
            0
        case .unsupportedStreamingProgram:
            1
        case .gameplayTimeExhausted:
            2
        case .eligibilityUnconfirmed:
            3
        case .authenticatedCatalog:
            4
        case .fresnoServiceConfirmed:
            5
        case .contentAccessConfirmed:
            6
        }
    }
}

private extension XboxCloudInputType {
    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .controller:
            L10n.text("controller")
        case .touch:
            L10n.text("touch")
        case .mouseAndKeyboard:
            L10n.text("keyboard_and_mouse")
        }
    }

    var sortOrder: Int {
        switch self {
        case .controller:
            0
        case .touch:
            1
        case .mouseAndKeyboard:
            2
        }
    }
}

private extension XboxCatalogSortOrder {
    var label: String {
        switch self {
        case .default:
            L10n.text("default")
        case .titleAZ:
            L10n.text("title_az")
        case .titleZA:
            L10n.text("title_za")
        case .recentFirst:
            L10n.text("recently_played_sort")
        }
    }
}

private struct XboxCatalogRefreshWarning: View {
    let lastUpdatedAt: Date?
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(L10n.text("catalog_may_be_out_of_date"))
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let lastUpdatedAt {
                    Text(
                        L10n.format(
                            "catalog_last_updated",
                            lastUpdatedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            Button(L10n.text("refresh_library"), action: onRetry)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("xbox-catalog.refresh-retry")
        }
    }
}

private struct XboxCatalogFailureView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            ContentUnavailableView(
                L10n.text("failed_to_load_games"),
                systemImage: "exclamationmark.triangle",
                description: Text(L10n.text("cloud_service_unavailable"))
            )

            Button(L10n.text("try_again"), action: onRetry)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityIdentifier("xbox-catalog.retry")
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}

private struct XboxCatalogEmptyView: View {
    var body: some View {
        ContentUnavailableView(
            L10n.text("no_games_available"),
            systemImage: "gamecontroller"
        )
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}

@MainActor
enum XboxSettingsSignOutWorkflow {
    static func run(
        endSession: () async -> Bool,
        deactivate: () async -> Void,
        logout: () async throws -> Void,
        clearCatalog: () -> Void,
        selectFallback: () -> Void
    ) async throws -> Bool {
        guard await endSession() else { return false }
        await deactivate()
        try await logout()
        clearCatalog()
        selectFallback()
        return true
    }
}

private struct XboxSettingsView: View {
    @Environment(CloudGamingProviderCoordinator.self) private var providerCoordinator
    @Environment(CloudSessionCoordinator.self) private var sessionCoordinator
    @Environment(XboxAuthManager.self) private var xboxAuthManager
    @Environment(XboxCloudModeViewModel.self) private var modeViewModel
    @Environment(XboxCatalogViewModel.self) private var viewModel
    @State private var isSigningOut = false
    @State private var dataDialog: CloudNowDataDialog?
    @State private var isPerformingDataAction = false
    @State private var showNetworkTest = false
    @State private var showLibraryRefreshProgress = false
    let fallbackProvider: CloudGamingProvider?

    var body: some View {
        @Bindable var modeViewModel = modeViewModel

        NavigationStack {
            Form {
                CloudNowCloudServiceSection(
                    activeProvider: providerCoordinator.selectedProvider ?? .xboxCloudGaming,
                    isInteractionDisabled: isBusy
                        || modeViewModel.isLibraryRefreshRunning,
                    onSelectProvider: switchProvider
                )

                if supportsManualResolution {
                    CloudNowStreamQualitySection {
                        CloudNowSettingSelectionRow(
                            L10n.text("resolution"),
                            selection: xboxResolutionSelection,
                            accessibilityIdentifier: "settings.stream-quality.resolution",
                            options: xboxResolutionOptions,
                            onRecoveryAction: {
                                Task { @MainActor in
                                    await modeViewModel.refreshContentAccess()
                                }
                            }
                        )
                    }
                    .disabled(isBusy)
                }

                Section(L10n.text("game")) {
                    CloudNowGameLanguageSelectionRow(
                        selection: $modeViewModel.streamSettings.gameLanguage,
                        automaticValue: XboxCloudStreamSettings.automaticGameLanguage
                    )
                }
                .disabled(isBusy)

                CloudNowControllerSettingsSection(
                    rumbleEnabled: $modeViewModel.streamSettings.rumbleEnabled,
                    rumbleIntensity: $modeViewModel.streamSettings.rumbleIntensity,
                    controllerDeadzone: $modeViewModel.streamSettings.controllerDeadzone,
                    policy: .xboxCloudGaming,
                    isDisabled: isBusy,
                    footer: L10n.text("controller_changes_next_session")
                )

                if supportsMicrophone {
                    CloudNowMicrophoneSettingsSection(
                        isEnabled: $modeViewModel.streamSettings.microphoneEnabled,
                        isDisabled: isBusy
                    )
                }

                if supportsNetworkTest {
                    Section(L10n.text("server_location")) {
                        Button {
                            showNetworkTest = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.text("test_network"))
                                Text(L10n.text("test_network_description"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("xbox-settings.network-test")
                    }
                    .disabled(isBusy)
                }

                Section {
                    Toggle(
                        L10n.text("text_to_speech"),
                        isOn: $modeViewModel.streamSettings.enableTextToSpeech
                    )
                    .accessibilityIdentifier("xbox-settings.text-to-speech")

                    Toggle(
                        L10n.text("magnifier"),
                        isOn: $modeViewModel.streamSettings.magnifier
                    )
                    .accessibilityIdentifier("xbox-settings.magnifier")

                    Toggle(
                        L10n.text("high_contrast"),
                        isOn: $modeViewModel.streamSettings.highContrast
                    )
                    .accessibilityIdentifier("xbox-settings.high-contrast")
                } header: {
                    Text(L10n.text("accessibility"))
                }
                .disabled(isBusy)

                #if DEBUG
                    CloudNowDiagnosticsSettingsSection(
                        diagnosticsEnabled: $modeViewModel.streamSettings
                            .diagnosticsEnabled,
                        enableRtcEventLog: $modeViewModel.streamSettings
                            .enableRtcEventLog,
                        isDisabled: isBusy
                    )
                #endif

                Section(L10n.text("library")) {
                    Button {
                        modeViewModel.startLibraryRefresh()
                        showLibraryRefreshProgress = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(
                                    L10n.text("refresh_library"),
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                                if let refreshStatusText {
                                    Text(refreshStatusText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.vertical, 8)
                            Spacer()
                            if modeViewModel.isLibraryRefreshRunning {
                                ProgressView()
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .disabled(
                        isBusy || !modeViewModel.canPresentLibraryRefresh
                    )
                    .accessibilityIdentifier("xbox-settings.refresh-library")
                    .accessibilityLabel(L10n.text("refresh_library"))
                    .accessibilityValue(refreshStatusText ?? "")
                }

                CloudNowStorageAndDataSection(
                    isPerformingAction: isBusy,
                    clearCache: { dataDialog = .confirmClearCache },
                    resetAllData: { dataDialog = .confirmResetAllData }
                )
                .disabled(modeViewModel.isLibraryRefreshRunning)

                Section(L10n.text("account")) {
                    LabeledContent(
                        L10n.text("microsoft_account"),
                        value: xboxAuthManager.authorizedAccount?.displayName
                            ?? L10n.text("connected")
                    )
                    #if DEBUG
                        LabeledContent {
                            HStack(spacing: 12) {
                                Text(membershipDescription)
                                if modeViewModel.contentAccessPhase == .unavailable {
                                    Button(L10n.text("try_again")) {
                                        Task { @MainActor in
                                            await modeViewModel.refreshContentAccess()
                                        }
                                    }
                                    .accessibilityIdentifier(
                                        "xbox-settings.membership-retry"
                                    )
                                }
                            }
                        } label: {
                            Text(L10n.text("membership"))
                        }
                        .accessibilityIdentifier("xbox-settings.membership")
                    #endif

                    LabeledContent(
                        L10n.text("cloud_gaming_access"),
                        value: cloudGamingAccessDescription
                    )
                    .accessibilityIdentifier("xbox-settings.cloud-gaming-access")
                    Button(role: .destructive) {
                        signOut()
                    } label: {
                        HStack {
                            Label(
                                L10n.text("sign_out"),
                                systemImage: "rectangle.portrait.and.arrow.right"
                            )
                            if isSigningOut {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isBusy || modeViewModel.isLibraryRefreshRunning)
                    .accessibilityIdentifier("settings.sign-out")
                }
            }
            .navigationTitle("")
            .task {
                await modeViewModel.refreshContentAccess()
            }
            .sheet(isPresented: $showNetworkTest) {
                CloudNetworkTestView {
                    await self.modeViewModel.networkTestTarget()
                }
            }
            .fullScreenCover(isPresented: $showLibraryRefreshProgress) {
                XboxLibraryRefreshProgressView()
                    .environment(modeViewModel)
            }
            .alert(
                dataDialog?.title ?? "",
                isPresented: dataDialogBinding,
                presenting: dataDialog
            ) { dialog in
                switch dialog {
                case .confirmClearCache:
                    Button(L10n.text("clear_cache"), role: .destructive) {
                        clearCache()
                    }
                    Button(L10n.text("cancel"), role: .cancel) {}
                case .confirmResetAllData:
                    Button(L10n.text("reset_all_data"), role: .destructive) {
                        resetAllData()
                    }
                    Button(L10n.text("cancel"), role: .cancel) {}
                case .result:
                    Button(L10n.text("ok")) {}
                }
            } message: { dialog in
                Text(dialog.message)
            }
        }
    }

    private var isBusy: Bool {
        isSigningOut
            || isPerformingDataAction
            || providerCoordinator.isProviderInteractionBlocked
    }

    private var refreshStatusText: String? {
        switch modeViewModel.libraryRefreshState {
        case .idle:
            nil
        case .refreshingCatalog, .refreshingAccountAccess:
            L10n.text("provider_sync_syncing")
        case let .completed(_, accountAccessAvailable):
            switch accountAccessAvailable {
            case true:
                L10n.text("refresh_completed")
            case false:
                L10n.text("access_not_confirmed")
            }
        case .failed:
            L10n.text("refresh_failed")
        }
    }

    private var xboxCapabilities: CloudGamingProviderCapabilities {
        providerCoordinator.capabilities(for: .xboxCloudGaming)
    }

    private var supportsManualResolution: Bool {
        xboxCapabilities.streamOptions.value?.qualityControls.contains(
            .resolution
        ) == true
    }

    private var supportsMicrophone: Bool {
        xboxCapabilities.microphone.value?.supportsVoiceChat == true
    }

    private var supportsNetworkTest: Bool {
        xboxCapabilities.diagnostics.value?.supportsNetworkTest == true
    }

    private var xboxResolutionOptions: [
        CloudNowSettingOption<XboxCloudDisplayResolution>
    ] {
        let available = Set(modeViewModel.streamCapabilities.resolutions)
        return [
            .automatic,
            .qhd,
            .fullHDHighQuality,
            .fullHD,
            .hdHighQuality,
            .hd,
        ]
        .map { resolution in
            resolutionOption(
                resolution,
                restriction: XboxSettingsEligibilityPolicy.resolutionRestriction(
                    for: resolution,
                    availableResolutions: available,
                    context: xboxResolutionEligibilityContext
                )
            )
        }
    }

    private var xboxResolutionEligibilityContext: XboxResolutionEligibilityContext {
        switch modeViewModel.contentAccessPhase {
        case .idle, .loading:
            .checking
        case .unavailable:
            .unavailable
        case .loaded:
            .loaded(modeViewModel.membershipTier)
        }
    }

    private var xboxResolutionSelection: Binding<XboxCloudDisplayResolution> {
        Binding(
            get: {
                modeViewModel.streamCapabilities.selectableResolution(
                    for: modeViewModel.streamSettings.displayResolution
                )
            },
            set: { resolution in
                modeViewModel.streamSettings.displayResolution = resolution
            }
        )
    }

    private func resolutionOption(
        _ resolution: XboxCloudDisplayResolution,
        restriction: XboxResolutionRestriction?
    ) -> CloudNowSettingOption<XboxCloudDisplayResolution> {
        let badge = resolution == .qhd
            ? L10n.text("maximum_abbreviation")
            : resolution.badge
        let displayTitle = badge.map {
            "\(resolution.label)  —  \($0)"
        } ?? resolution.label
        return CloudNowSettingOption(
            value: resolution,
            title: resolution.label,
            badge: badge,
            systemImage: resolution.systemImage,
            accessibilityIdentifier: resolution.rawValue,
            unavailability: xboxResolutionUnavailability(
                restriction,
                displayTitle: displayTitle
            )
        )
    }

    private func xboxResolutionUnavailability(
        _ restriction: XboxResolutionRestriction?,
        displayTitle: String
    ) -> CloudNowSettingUnavailability? {
        guard let restriction else { return nil }
        return switch restriction {
        case .checkingMembership:
            CloudNowSettingUnavailability(
                reason: L10n.text("xbox_resolution_checking_membership")
            )
        case .membershipUnavailable:
            CloudNowSettingUnavailability(
                reason: L10n.text("xbox_resolution_membership_unavailable"),
                recoveryActionTitle: L10n.text("try_again")
            )
        case let .requiresUltimate(currentMembership):
            CloudNowSettingUnavailability(
                reason: L10n.format(
                    "xbox_resolution_requires_ultimate",
                    displayTitle,
                    currentMembership.displayName
                )
            )
        case .requiresConfirmedUltimate:
            CloudNowSettingUnavailability(
                reason: L10n.format(
                    "xbox_resolution_requires_confirmed_ultimate",
                    displayTitle
                )
            )
        }
    }

    private var membershipDescription: String {
        switch modeViewModel.contentAccessPhase {
        case .idle, .unavailable:
            "—"
        case .loading:
            "…"
        case .loaded:
            modeViewModel.membershipTier?.displayName ?? L10n.text("unknown")
        }
    }

    private var cloudGamingAccessDescription: String {
        let kinds = viewModel.playableAccessKinds
        let hasStandard = kinds.contains(.standard)
        let hasFreeWithAds = kinds.contains(.freeWithAds)
        switch (hasStandard, hasFreeWithAds) {
        case (true, true):
            return L10n.localizedList([
                L10n.text("connected"),
                L10n.text("free_with_ads"),
            ])
        case (true, false):
            return L10n.text("connected")
        case (false, true):
            return L10n.text("free_with_ads")
        case (false, false):
            return L10n.text("unknown")
        }
    }

    private var dataDialogBinding: Binding<Bool> {
        Binding(
            get: { dataDialog != nil },
            set: { isPresented in
                if !isPresented {
                    dataDialog = nil
                }
            }
        )
    }

    private func clearCache() {
        guard !modeViewModel.isLibraryRefreshRunning else { return }
        isPerformingDataAction = true
        modeViewModel.cancelLibraryRefresh()
        viewModel.prepareForCacheClear()
        Task {
            do {
                try await AppDataManager.shared.clearCaches(
                    for: .xboxCloudGaming
                )
                await viewModel.load()
                dataDialog = .result(
                    title: L10n.text("cache_cleared"),
                    message: L10n.text("cache_cleared_message")
                )
            } catch {
                await viewModel.load()
                dataDialog = .result(
                    title: L10n.text("cache_clear_failed"),
                    message: L10n.format(
                        "cache_clear_failed_message",
                        localizedFailure(
                            error,
                            fallbackKey: "cloud_service_unavailable"
                        )
                    )
                )
            }
            isPerformingDataAction = false
        }
    }

    private func switchProvider(to provider: CloudGamingProvider) {
        guard !isSigningOut,
              !isPerformingDataAction,
              !modeViewModel.isLibraryRefreshRunning,
              let intent = providerCoordinator.beginProviderSwitch(to: provider)
        else {
            return
        }
        Task { @MainActor in
            await modeViewModel.deactivateForInactiveProvider()
            guard !Task.isCancelled else {
                providerCoordinator.cancelProviderSwitch(intent)
                return
            }
            _ = providerCoordinator.commitProviderSwitch(intent)
        }
    }

    private func resetAllData() {
        guard !modeViewModel.isLibraryRefreshRunning,
              let mutation = providerCoordinator.beginCredentialMutation()
        else {
            return
        }
        isPerformingDataAction = true
        xboxAuthManager.prepareForDataReset()
        viewModel.prepareForPersistentDataClear()
        modeViewModel.prepareForPersistentDataClear()

        Task {
            defer {
                providerCoordinator.finishCredentialMutation(mutation)
                isPerformingDataAction = false
            }
            do {
                guard await endProviderSessionIfNeeded() else {
                    xboxAuthManager.abortDataResetWithoutActivation()
                    await modeViewModel.restoreSettingsAfterDataClearAttempt()
                    await xboxAuthManager.activateXboxCloudAccess()
                    await modeViewModel.load()
                    dataDialog = .result(
                        title: L10n.text("reset_failed"),
                        message: L10n.text("end_session_before_sign_out")
                    )
                    return
                }
                await modeViewModel.stopStream()
                try await AppDataManager.shared.clearCaches(
                    for: .xboxCloudGaming
                )
                let result = await AppDataManager.shared.clearPersistentData(
                    for: .xboxCloudGaming
                )
                if result.credentialsRemoved {
                    await xboxAuthManager.finishDataReset()
                    providerCoordinator.select(fallbackProvider)
                } else {
                    xboxAuthManager.abortDataResetWithoutActivation()
                    providerCoordinator.preserveSelectionAfterFailedDataReset(
                        .xboxCloudGaming
                    )
                    providerCoordinator.presentDataResetFailure(
                        persistentResetFailureMessage(result.failureDescription)
                    )
                    await modeViewModel.restoreSettingsAfterDataClearAttempt()
                    await xboxAuthManager.activateXboxCloudAccess()
                    await modeViewModel.load()
                }
            } catch {
                xboxAuthManager.abortDataResetWithoutActivation()
                await modeViewModel.restoreSettingsAfterDataClearAttempt()
                await xboxAuthManager.activateXboxCloudAccess()
                await modeViewModel.load()
                dataDialog = .result(
                    title: L10n.text("reset_failed"),
                    message: localizedFailure(
                        error,
                        fallbackKey: "reset_failed"
                    )
                )
            }
        }
    }

    private func signOut() {
        guard !modeViewModel.isLibraryRefreshRunning,
              let mutation = providerCoordinator.beginCredentialMutation()
        else {
            return
        }
        isSigningOut = true
        Task {
            defer {
                providerCoordinator.finishCredentialMutation(mutation)
                isSigningOut = false
            }
            do {
                let didSignOut = try await XboxSettingsSignOutWorkflow.run(
                    endSession: { await endProviderSessionIfNeeded() },
                    deactivate: {
                        await modeViewModel.deactivateForInactiveProvider()
                    },
                    logout: { try await xboxAuthManager.logout() },
                    clearCatalog: { viewModel.prepareForCacheClear() },
                    selectFallback: {
                        providerCoordinator.select(fallbackProvider)
                    }
                )
                guard didSignOut else {
                    dataDialog = .result(
                        title: L10n.text("sign_out"),
                        message: L10n.text("end_session_before_sign_out")
                    )
                    return
                }
            } catch {
                await modeViewModel.load()
                dataDialog = .result(
                    title: L10n.text("sign_out"),
                    message: localizedFailure(
                        error,
                        fallbackKey: "cloud_service_unavailable"
                    )
                )
            }
        }
    }

    private func localizedFailure(
        _ error: Error,
        fallbackKey: String
    ) -> String {
        #if DEBUG
            return error.localizedDescription
        #else
            return L10n.text(fallbackKey)
        #endif
    }

    private func persistentResetFailureMessage(_ message: String?) -> String {
        #if DEBUG
            return message ?? L10n.text("reset_failed")
        #else
            return L10n.text("reset_failed")
        #endif
    }

    private func endProviderSessionIfNeeded() async -> Bool {
        guard let lease = sessionCoordinator.serverSession,
              lease.provider == .xboxCloudGaming
        else {
            return true
        }
        return await sessionCoordinator.endServerSessionUsingProvider(lease)
    }
}

private nonisolated enum XboxAppTab: CloudNowTabSelection {
    case home
    case library
    case browse
    case settings

    static let first = XboxAppTab.home
    static let last = XboxAppTab.settings

    var next: XboxAppTab {
        switch self {
        case .home:
            .library
        case .library:
            .browse
        case .browse:
            .settings
        case .settings:
            .home
        }
    }

    var previous: XboxAppTab {
        switch self {
        case .home:
            .settings
        case .library:
            .home
        case .browse:
            .library
        case .settings:
            .browse
        }
    }

    var catalogScope: XboxCatalogScope? {
        switch self {
        case .library:
            .library
        case .browse:
            .browse
        case .home, .settings:
            nil
        }
    }
}
