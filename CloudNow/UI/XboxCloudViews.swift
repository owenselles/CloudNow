import Observation
import SwiftUI

struct XboxLoginView: View {
    @Environment(AuthManager.self) private var geForceNowAuthManager
    @Environment(CloudGamingProviderCoordinator.self) private var providerCoordinator
    @Environment(XboxAuthManager.self) private var xboxAuthManager

    var body: some View {
        ZStack {
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
                failureView(message: error.localizedDescription)
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
            CloudNowBrandHeader(subtitle: L10n.text("xbox_cloud_gaming"))

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

    private func progressView(message: String) -> some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(2)
                .tint(.white)
            Text(message)
                .font(.title2)
                .foregroundStyle(.white)
        }
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 32) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.yellow)
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
        providerCoordinator.select(
            geForceNowAuthManager.isAuthenticated ? .geForceNow : nil
        )
    }

    private func displayURL(_ url: URL) -> String {
        url.absoluteString.replacingOccurrences(of: "https://", with: "")
    }
}

struct XboxMainTabView: View {
    @Environment(XboxAuthManager.self) private var xboxAuthManager
    @State private var modeViewModel: XboxCloudModeViewModel
    @State private var playbackRequest: XboxCloudPlaybackRequest?
    @State private var selectedTab: XboxAppTab = .home
    @State private var controllerNavigation = UIControllerNavigationCoordinator()
    private let account: XboxCloudAuthorizedAccount

    init(
        configuration: XboxCloudServiceConfiguration,
        account: XboxCloudAuthorizedAccount
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
                makeStreamController: configuration.makeStreamController
            )
        )
        self.account = account
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
                    standardItems: modeViewModel.catalogViewModel.homeStandardItems,
                    freeWithAdsItems: modeViewModel.catalogViewModel.homeFreeWithAdsItems,
                    phase: modeViewModel.catalogViewModel.phase,
                    showsRefreshWarning: modeViewModel.catalogViewModel.showsRefreshWarning,
                    onRetry: retryCatalog,
                    onPlay: play
                )
                .accessibilityIdentifier("xbox-home-screen")
            }
            Tab(L10n.text("browse"), systemImage: "rectangle.stack.fill", value: XboxAppTab.browse) {
                XboxCatalogGrid(
                    title: L10n.text("xbox_cloud_catalog"),
                    items: modeViewModel.catalogViewModel.visibleItems,
                    phase: modeViewModel.catalogViewModel.phase,
                    showsRefreshWarning: modeViewModel.catalogViewModel.showsRefreshWarning,
                    filter: Binding(
                        get: { modeViewModel.catalogViewModel.browseFilter },
                        set: { modeViewModel.catalogViewModel.browseFilter = $0 }
                    ),
                    onItemVisible: modeViewModel.catalogViewModel.loadNextPageIfNeeded,
                    onRetry: retryCatalog,
                    onPlay: play
                )
                .accessibilityIdentifier("xbox-browse-screen")
            }
            Tab(L10n.text("settings"), systemImage: "gearshape.fill", value: XboxAppTab.settings) {
                XboxSettingsView()
                    .accessibilityIdentifier("xbox-settings-screen")
            }
        }
        .environment(modeViewModel)
        .environment(modeViewModel.catalogViewModel)
        .task {
            await modeViewModel.load()
        }
        .onDisappear {
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
        .fullScreenCover(item: $playbackRequest) { request in
            XboxCloudPlayerView(
                item: request.item,
                route: request.route,
                account: account,
                settings: request.settings,
                controller: request.controller,
                onDismiss: { playbackRequest = nil }
            )
            .blocksGlobalControllerNavigation(mode: .streaming)
            .environment(controllerNavigation)
        }
    }

    private func play(
        _ item: XboxCatalogItem,
        route: XboxCloudTitleRoute
    ) {
        guard route.isPlayable else { return }

        playbackRequest = XboxCloudPlaybackRequest(
            item: item,
            route: route,
            settings: modeViewModel.streamSettings,
            controller: modeViewModel.streamController { [weak xboxAuthManager] in
                guard let xboxAuthManager else { throw CancellationError() }
                return try await xboxAuthManager.xboxCloudTransferToken()
            }
        )
    }

    private func retryCatalog() {
        Task {
            await modeViewModel.catalogViewModel.reload()
        }
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
    var streamSettings = XboxCloudStreamSettings() {
        didSet {
            scheduleSettingsSave(oldValue: oldValue)
        }
    }

    @ObservationIgnored private let makeStreamController: @MainActor @Sendable (
        @escaping @Sendable () async throws -> String
    ) -> XboxCloudStreamController
    @ObservationIgnored private let makeContentAccessClient: (
        @Sendable () -> any XboxContentAccessProviding
    )?
    @ObservationIgnored private let account: XboxCloudAuthorizedAccount
    @ObservationIgnored private let persistence: AppPersistenceStore
    @ObservationIgnored private var activeStreamController: XboxCloudStreamController?
    @ObservationIgnored private var contentAccessClient: (any XboxContentAccessProviding)?
    @ObservationIgnored private var contentAccessTask: Task<XboxContentAccessSnapshot, Error>?
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var hasLoadedSettings = false
    @ObservationIgnored private var activationGeneration: UInt64 = 0
    @ObservationIgnored private var contentAccessGeneration: UInt64 = 0

    init(
        catalogViewModel: XboxCatalogViewModel,
        account: XboxCloudAuthorizedAccount,
        makeContentAccessClient: (
            @Sendable () -> any XboxContentAccessProviding
        )? = nil,
        makeStreamController: @escaping @MainActor @Sendable (
            @escaping @Sendable () async throws -> String
        ) -> XboxCloudStreamController,
        persistence: AppPersistenceStore = .shared
    ) {
        self.catalogViewModel = catalogViewModel
        self.account = account
        self.makeContentAccessClient = makeContentAccessClient
        self.makeStreamController = makeStreamController
        self.persistence = persistence
    }

    func load() async {
        activationGeneration &+= 1
        let generation = activationGeneration
        if !hasLoadedSettings {
            let settings = await persistence.loadXboxCloudStreamSettings()
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
            return activeStreamController
        }
        let controller = makeStreamController(transferToken)
        activeStreamController = controller
        return controller
    }

    func stopStream() async {
        guard let controller = activeStreamController else { return }
        await controller.stop()
        if activeStreamController === controller {
            activeStreamController = nil
        }
    }

    func deactivateForInactiveProvider() async {
        activationGeneration &+= 1
        cancelContentAccessRequest()
        await flushSettings()
        await stopStream()
        await catalogViewModel.deactivateForInactiveProvider()
        contentAccessClient = nil
        membershipTier = nil
        contentAccessPhase = .idle
    }

    func prepareForPersistentDataClear() {
        activationGeneration &+= 1
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
        guard activationGeneration == generation else { return }
        streamSettings = settings
        hasLoadedSettings = true
    }

    func refreshContentAccess() async {
        guard contentAccessPhase == .unavailable else { return }
        await loadContentAccess()
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
        let task = Task {
            // Content Access intentionally uses the first-party web offering even
            // when Game Streaming selected a different fallback offering.
            try await client.fetchContentAccess(
                for: account,
                market: Locale.current.region?.identifier ?? "US",
                offeringID: XboxCloudOfferingServiceConfiguration.defaultConsumerOfferingID
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

    var id: String {
        "\(item.id)|\(route.titleID)|\(route.accessKind)"
    }
}

nonisolated enum XboxCatalogBrowseFilter: Hashable, Sendable {
    case all
    case freeWithAds
}

@Observable
@MainActor
final class XboxCatalogViewModel: CloudGamingProviderModeLifecycle {
    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    private(set) var visibleItems: [XboxCatalogItem] = []
    private(set) var homeStandardItems: [XboxCatalogItem] = []
    private(set) var homeFreeWithAdsItems: [XboxCatalogItem] = []
    private(set) var availableAccessKinds: Set<XboxCloudAccessKind> = []
    private(set) var phase: LoadPhase = .idle
    private(set) var showsRefreshWarning = false
    var browseFilter: XboxCatalogBrowseFilter = .all {
        didSet {
            guard browseFilter != oldValue else { return }
            visibleItemLimit = 96
            publishVisibleItems()
        }
    }

    @ObservationIgnored private let makeClient: @Sendable () -> any XboxCatalogClient
    @ObservationIgnored private var client: (any XboxCatalogClient)?
    @ObservationIgnored private let account: XboxCloudAuthorizedAccount
    @ObservationIgnored private let cache: any XboxCatalogCaching
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let freshnessInterval: TimeInterval
    @ObservationIgnored private var allItems: [XboxCatalogItem] = []
    @ObservationIgnored private var visibleItemLimit = 96
    @ObservationIgnored private var loadGeneration: UInt64 = 0

    init(
        client: any XboxCatalogClient,
        account: XboxCloudAuthorizedAccount,
        cache: any XboxCatalogCaching = XboxCatalogMemoryCache.shared,
        now: @escaping @Sendable () -> Date = Date.init,
        freshnessInterval: TimeInterval = 15 * 60
    ) {
        makeClient = { client }
        self.account = account
        self.cache = cache
        self.now = now
        self.freshnessInterval = freshnessInterval
    }

    init(
        makeClient: @escaping @Sendable () -> any XboxCatalogClient,
        account: XboxCloudAuthorizedAccount,
        cache: any XboxCatalogCaching = XboxCatalogMemoryCache.shared,
        now: @escaping @Sendable () -> Date = Date.init,
        freshnessInterval: TimeInterval = 15 * 60
    ) {
        self.makeClient = makeClient
        self.account = account
        self.cache = cache
        self.now = now
        self.freshnessInterval = freshnessInterval
    }

    func load() async {
        guard phase == .idle else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        let request = XboxCatalogRequest(
            localeIdentifier: L10n.localeCode,
            market: Locale.current.region?.identifier
        )
        let cacheKey = XboxCatalogCacheKey(
            accountAuthorizationIdentifier: account.authorizationIdentifier,
            localeIdentifier: request.localeIdentifier,
            market: request.market
        )
        var loadedCachedSnapshot = false
        showsRefreshWarning = false
        if let cached = await cache.snapshot(for: cacheKey) {
            guard loadGeneration == generation else { return }
            loadedCachedSnapshot = true
            allItems = cached.items
            publishVisibleItems()
            phase = .loaded
            if now().timeIntervalSince(cached.fetchedAt) < freshnessInterval {
                return
            }
        } else {
            phase = .loading
        }
        do {
            let client = resolvedClient()
            let snapshot = try await client.fetchCatalog(
                request,
                account: account
            )
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            await cache.store(snapshot, for: cacheKey)
            guard loadGeneration == generation else { return }
            allItems = snapshot.items
            publishVisibleItems()
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard loadGeneration == generation else { return }
            phase = loadedCachedSnapshot ? .loaded : .failed
            showsRefreshWarning = loadedCachedSnapshot
        }
    }

    func reload() async {
        cancel()
        phase = .idle
        showsRefreshWarning = false
        await load()
    }

    func loadNextPageIfNeeded(_ item: XboxCatalogItem) {
        guard item.id == visibleItems.last?.id,
              visibleItems.count < browseItems.count
        else {
            return
        }
        visibleItemLimit = min(visibleItemLimit + 96, browseItems.count)
        publishVisibleItems()
    }

    func cancel() {
        loadGeneration &+= 1
        client?.cancel()
        client = nil
    }

    func prepareForCacheClear() {
        cancel()
        allItems.removeAll(keepingCapacity: false)
        visibleItems.removeAll(keepingCapacity: false)
        homeStandardItems.removeAll(keepingCapacity: false)
        homeFreeWithAdsItems.removeAll(keepingCapacity: false)
        availableAccessKinds.removeAll(keepingCapacity: false)
        phase = .idle
        showsRefreshWarning = false
        visibleItemLimit = 96
    }

    func deactivateForInactiveProvider() async {
        prepareForCacheClear()
        await cache.remove(
            accountAuthorizationIdentifier: account.authorizationIdentifier
        )
    }

    private func publishVisibleItems() {
        let availableAccessKinds = Set(allItems.flatMap(\.accessKinds))
        let freeWithAdsItems = allItems.filter(\.supportsFreeWithAds)
        let standardItems = allItems.filter {
            $0.accessKinds.contains(.standard)
        }
        let homeFreeWithAdsItems = Array(freeWithAdsItems.prefix(12))
        let homeStandardItems = Array(standardItems.prefix(12))
        let items = Array(browseItems.prefix(visibleItemLimit))
        if availableAccessKinds != self.availableAccessKinds {
            self.availableAccessKinds = availableAccessKinds
        }
        if homeFreeWithAdsItems != self.homeFreeWithAdsItems {
            self.homeFreeWithAdsItems = homeFreeWithAdsItems
        }
        if homeStandardItems != self.homeStandardItems {
            self.homeStandardItems = homeStandardItems
        }
        guard items != visibleItems else { return }
        visibleItems = items
    }

    private var browseItems: [XboxCatalogItem] {
        switch browseFilter {
        case .all:
            allItems
        case .freeWithAds:
            allItems.filter(\.supportsFreeWithAds)
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
}

private struct XboxCatalogHome: View {
    let standardItems: [XboxCatalogItem]
    let freeWithAdsItems: [XboxCatalogItem]
    let phase: XboxCatalogViewModel.LoadPhase
    let showsRefreshWarning: Bool
    let onRetry: () -> Void
    let onPlay: (XboxCatalogItem, XboxCloudTitleRoute) -> Void
    @State private var selection: XboxCatalogSelection?
    @State private var sourceFocusID: String?
    @FocusState private var focusedCardID: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                Text(L10n.text("xbox_cloud_gaming"))
                    .font(.largeTitle.bold())
                    .padding(.horizontal, 70)

                if showsRefreshWarning {
                    XboxCatalogRefreshWarning()
                        .padding(.horizontal, 70)
                }

                content
            }
            .padding(.vertical, 50)
        }
        .sheet(item: $selection, onDismiss: restoreSourceFocus) { selection in
            XboxCatalogPreview(
                selection: selection,
                onPlay: {
                    self.selection = nil
                    Task { @MainActor in
                        await Task.yield()
                        onPlay(selection.item, selection.route)
                    }
                }
            )
            .blocksGlobalControllerNavigation()
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 360)
        case .failed:
            XboxCatalogFailureView(onRetry: onRetry)
                .padding(.horizontal, 70)
        case .loaded where standardItems.isEmpty && freeWithAdsItems.isEmpty:
            XboxCatalogEmptyView()
                .padding(.horizontal, 70)
        case .loaded:
            if !freeWithAdsItems.isEmpty {
                XboxCatalogRail(
                    title: L10n.text("stream_free_with_ads"),
                    items: freeWithAdsItems,
                    accessKind: .freeWithAds,
                    focusedCardID: $focusedCardID,
                    onSelect: select
                )
                .accessibilityIdentifier("xbox-home.free-with-ads")
            }

            if !standardItems.isEmpty {
                XboxCatalogRail(
                    title: L10n.text("xbox_cloud_catalog"),
                    items: standardItems,
                    accessKind: .standard,
                    focusedCardID: $focusedCardID,
                    onSelect: select
                )
                .accessibilityIdentifier("xbox-home.standard")
            }
        }
    }

    private func select(_ selection: XboxCatalogSelection) {
        sourceFocusID = selection.id
        self.selection = selection
    }

    private func restoreSourceFocus() {
        guard let sourceFocusID else { return }
        self.sourceFocusID = nil
        Task { @MainActor in
            await Task.yield()
            focusedCardID = sourceFocusID
        }
    }
}

private struct XboxCatalogRail: View {
    let title: String
    let items: [XboxCatalogItem]
    let accessKind: XboxCloudAccessKind
    var focusedCardID: FocusState<String?>.Binding
    let onSelect: (XboxCatalogSelection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 70)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 26) {
                    ForEach(items) { item in
                        if let route = item.route(for: accessKind) {
                            let selection = XboxCatalogSelection(item: item, route: route)
                            XboxCatalogCard(
                                item: item,
                                route: route,
                                onSelect: { onSelect(selection) }
                            )
                            .frame(width: 200)
                            .id(selection.id)
                            .focused(focusedCardID, equals: selection.id)
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 18)
            }
            .focusSection()
            .scrollClipDisabled()
        }
    }
}

private struct XboxCatalogGrid: View {
    let title: String
    let items: [XboxCatalogItem]
    let phase: XboxCatalogViewModel.LoadPhase
    let showsRefreshWarning: Bool
    let filter: Binding<XboxCatalogBrowseFilter>?
    let onItemVisible: (XboxCatalogItem) -> Void
    let onRetry: () -> Void
    let onPlay: (XboxCatalogItem, XboxCloudTitleRoute) -> Void
    @State private var selection: XboxCatalogSelection?
    @State private var sourceFocusID: String?
    @FocusState private var focusedCardID: String?

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                Text(title)
                    .font(.largeTitle.bold())

                if let filter {
                    Picker(L10n.text("filters"), selection: filter) {
                        Text(L10n.text("all"))
                            .tag(XboxCatalogBrowseFilter.all)
                        Text(L10n.text("free_with_ads"))
                            .tag(XboxCatalogBrowseFilter.freeWithAds)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 660)
                    .focusSection()
                    .accessibilityIdentifier("xbox-browse-filter")
                }

                if showsRefreshWarning {
                    XboxCatalogRefreshWarning()
                }

                content
            }
            .padding(.horizontal, 70)
            .padding(.vertical, 50)
        }
        .sheet(item: $selection, onDismiss: restoreSourceFocus) { selection in
            XboxCatalogPreview(
                selection: selection,
                onPlay: {
                    self.selection = nil
                    Task { @MainActor in
                        await Task.yield()
                        onPlay(selection.item, selection.route)
                    }
                }
            )
            .blocksGlobalControllerNavigation()
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 360)
        case .failed:
            XboxCatalogFailureView(onRetry: onRetry)
        case .loaded where items.isEmpty:
            XboxCatalogEmptyView()
        case .loaded:
            LazyVGrid(columns: columns, spacing: 40) {
                ForEach(items) { item in
                    if let route = preferredRoute(for: item) {
                        let selection = XboxCatalogSelection(item: item, route: route)
                        XboxCatalogCard(
                            item: item,
                            route: route,
                            onSelect: { select(selection) }
                        )
                        .focused($focusedCardID, equals: selection.id)
                        .onAppear {
                            onItemVisible(item)
                        }
                    }
                }
            }
            .focusSection()
        }
    }

    private func preferredRoute(for item: XboxCatalogItem) -> XboxCloudTitleRoute? {
        if filter?.wrappedValue == .freeWithAds {
            return item.route(for: .freeWithAds)
        }
        return item.preferredRoute
    }

    private func select(_ selection: XboxCatalogSelection) {
        sourceFocusID = selection.id
        self.selection = selection
    }

    private func restoreSourceFocus() {
        guard let sourceFocusID else { return }
        self.sourceFocusID = nil
        Task { @MainActor in
            await Task.yield()
            focusedCardID = sourceFocusID
        }
    }
}

private struct XboxCatalogCard: View {
    let item: XboxCatalogItem
    let route: XboxCloudTitleRoute
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect, label: {
            ZStack(alignment: .bottomLeading) {
                SharedArtworkImage(
                    urlString: item.artworkURL?.absoluteString,
                    maxPixelSize: ArtworkImagePipeline.boxArtPixelSize,
                    networkCachePolicy: .ephemeral
                )
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                LinearGradient(
                    colors: [.black.opacity(0.7), .clear],
                    startPoint: .bottom,
                    endPoint: .center
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(10)

                if route.accessKind == .freeWithAds {
                    if route.isPlayable {
                        Text(L10n.text("free_with_ads"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.green, in: Capsule())
                            .padding(8)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .topTrailing
                            )
                    } else {
                        Label(L10n.text("not_eligible"), systemImage: "lock.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.gray, in: Capsule())
                            .padding(8)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .topTrailing
                            )
                    }
                }
            }
        })
        .aspectRatio(2 / 3, contentMode: .fit)
        .buttonStyle(.card)
        .accessibilityLabel(item.title)
        .accessibilityValue(accessibilityStatus)
        .accessibilityIdentifier(
            "xbox-game-card.\(item.id).\(route.accessKind).\(route.titleID)"
        )
    }

    private var accessibilityStatus: String {
        guard route.accessKind == .freeWithAds else { return "" }
        return route.isPlayable
            ? L10n.text("free_with_ads")
            : L10n.text("not_eligible")
    }
}

private struct XboxCatalogPreview: View {
    @Environment(\.dismiss) private var dismiss
    let selection: XboxCatalogSelection
    let onPlay: () -> Void

    private var item: XboxCatalogItem {
        selection.item
    }

    var body: some View {
        VStack(spacing: 30) {
            SharedArtworkImage(
                urlString: item.artworkURL?.absoluteString,
                maxPixelSize: ArtworkImagePipeline.boxArtPixelSize,
                networkCachePolicy: .ephemeral
            )
            .frame(width: 260, height: 320)
            .clipped()
            .clipShape(.rect(cornerRadius: 14))

            Text(item.title)
                .font(.largeTitle.bold())
                .accessibilityIdentifier("xbox-game-preview")

            Text(description)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)

            HStack(spacing: 24) {
                Button {
                    onPlay()
                } label: {
                    Label(
                        playTitle,
                        systemImage: selection.route.isPlayable ? "play.fill" : "lock.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(selection.route.isPlayable ? .green : .gray)
                .disabled(!selection.route.isPlayable)
                .accessibilityValue(
                    selection.route.isPlayable ? "" : L10n.text("not_eligible")
                )
                .accessibilityHint(
                    selection.route.isPlayable
                        ? ""
                        : L10n.text("xbox_free_with_ads_candidate_description")
                )
                .accessibilityIdentifier("xbox-game.play.\(item.id)")

                Button(L10n.text("cancel")) {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(70)
    }

    private var description: String {
        guard selection.route.accessKind == .freeWithAds else {
            return L10n.text("requires_xbox_cloud_subscription")
        }
        return selection.route.isPlayable
            ? L10n.text("free_with_ads_session_description")
            : L10n.text("xbox_free_with_ads_candidate_description")
    }

    private var playTitle: String {
        guard selection.route.isPlayable else { return L10n.text("not_eligible") }
        return selection.route.accessKind == .freeWithAds
            ? L10n.text("stream_free_with_ads")
            : L10n.text("play")
    }
}

private struct XboxCatalogSelection: Identifiable {
    let item: XboxCatalogItem
    let route: XboxCloudTitleRoute

    var id: String {
        "\(item.id)|\(route.titleID)|\(route.accessKind)"
    }
}

private struct XboxCatalogRefreshWarning: View {
    var body: some View {
        Label(
            L10n.text("xbox_cloud_catalog_unavailable"),
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.yellow)
    }
}

private struct XboxCatalogFailureView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            ContentUnavailableView(
                L10n.text("failed_to_load_games"),
                systemImage: "exclamationmark.triangle",
                description: Text(L10n.text("xbox_cloud_catalog_unavailable"))
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

private extension XboxCatalogItem {
    func route(for accessKind: XboxCloudAccessKind) -> XboxCloudTitleRoute? {
        routes
            .filter { $0.accessKind == accessKind }
            .min { left, right in
                if left.isPlayable != right.isPlayable {
                    return left.isPlayable
                }
                return left.titleID < right.titleID
            }
    }
}

private struct XboxSettingsView: View {
    @Environment(AuthManager.self) private var geForceNowAuthManager
    @Environment(CloudGamingProviderCoordinator.self) private var providerCoordinator
    @Environment(XboxAuthManager.self) private var xboxAuthManager
    @Environment(XboxCloudModeViewModel.self) private var modeViewModel
    @Environment(XboxCatalogViewModel.self) private var viewModel
    @State private var isSigningOut = false
    @State private var dataDialog: CloudNowDataDialog?
    @State private var isPerformingDataAction = false

    var body: some View {
        @Bindable var modeViewModel = modeViewModel

        NavigationStack {
            Form {
                CloudNowCloudServiceSection(
                    activeProvider: providerCoordinator.selectedProvider ?? .xboxCloudGaming,
                    isInteractionDisabled: isBusy,
                    onSelectProvider: switchProvider
                )

                CloudNowControllerSettingsSection(
                    rumbleEnabled: $modeViewModel.streamSettings.rumbleEnabled,
                    rumbleIntensity: $modeViewModel.streamSettings.rumbleIntensity,
                    controllerDeadzone: $modeViewModel.streamSettings.controllerDeadzone,
                    policy: .xboxCloudGaming,
                    isDisabled: isBusy,
                    footer: L10n.text("xbox_controller_changes_next_session")
                )

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
                    Text(L10n.text("xbox_accessibility"))
                }
                .disabled(isBusy)

                Section {
                    Toggle(
                        L10n.text("share_optional_diagnostic_data"),
                        isOn: $modeViewModel.streamSettings.enableOptionalDataCollection
                    )
                    .accessibilityIdentifier("xbox-settings.optional-data")
                } header: {
                    Text(L10n.text("xbox_privacy"))
                } footer: {
                    Text(L10n.text("xbox_optional_data_description"))
                }
                .disabled(isBusy)

                CloudNowStorageAndDataSection(
                    isPerformingAction: isBusy,
                    clearCache: { dataDialog = .confirmClearCache },
                    resetAllData: { dataDialog = .confirmResetAllData }
                )

                Section(L10n.text("account")) {
                    LabeledContent(
                        L10n.text("microsoft_account"),
                        value: xboxAuthManager.authorizedAccount?.displayName
                            ?? L10n.text("connected")
                    )
                    LabeledContent {
                        HStack(spacing: 12) {
                            Text(membershipDescription)
                            if modeViewModel.contentAccessPhase == .unavailable {
                                Button(L10n.text("try_again")) {
                                    Task { @MainActor in
                                        await modeViewModel.refreshContentAccess()
                                    }
                                }
                                .accessibilityIdentifier("xbox-settings.membership-retry")
                            }
                        }
                    } label: {
                        Text(L10n.text("membership"))
                    }
                    .accessibilityIdentifier("xbox-settings.membership")

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
                    .disabled(isBusy)
                    .accessibilityIdentifier("settings.sign-out")
                }
            }
            .navigationTitle("")
            .task {
                await modeViewModel.refreshContentAccess()
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
        let kinds = viewModel.availableAccessKinds
        let hasStandard = kinds.contains(.standard)
        let hasFreeWithAds = kinds.contains(.freeWithAds)
        switch (hasStandard, hasFreeWithAds) {
        case (true, true):
            return "\(L10n.text("xbox_cloud_gaming")) · \(L10n.text("free_with_ads"))"
        case (true, false):
            return L10n.text("xbox_cloud_gaming")
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
        isPerformingDataAction = true
        viewModel.prepareForCacheClear()
        Task {
            do {
                try await AppDataManager.shared.clearCaches()
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
                        error.localizedDescription
                    )
                )
            }
            isPerformingDataAction = false
        }
    }

    private func switchProvider(to provider: CloudGamingProvider?) {
        guard !isSigningOut,
              !isPerformingDataAction,
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
        guard let mutation = providerCoordinator.beginCredentialMutation() else {
            return
        }
        isPerformingDataAction = true
        geForceNowAuthManager.prepareForDataReset()
        xboxAuthManager.prepareForDataReset()
        viewModel.prepareForCacheClear()
        modeViewModel.prepareForPersistentDataClear()

        Task {
            defer {
                providerCoordinator.finishCredentialMutation(mutation)
                isPerformingDataAction = false
            }
            await modeViewModel.stopStream()
            do {
                try await AppDataManager.shared.clearCaches()
                let result = await AppDataManager.shared.clearPersistentData()
                let remainingProvider = result.remainingProvider(
                    preferring: .xboxCloudGaming
                )
                if result.geForceNowCredentialsRemoved {
                    geForceNowAuthManager.finishDataReset()
                } else {
                    geForceNowAuthManager.abortDataResetWithoutActivation()
                }
                if result.xboxCredentialsRemoved {
                    await xboxAuthManager.finishDataReset()
                } else {
                    xboxAuthManager.abortDataResetWithoutActivation()
                }
                if result.isComplete {
                    providerCoordinator.select(nil)
                } else if let remainingProvider {
                    providerCoordinator.preserveSelectionAfterFailedDataReset(
                        remainingProvider
                    )
                    providerCoordinator.presentDataResetFailure(
                        result.failureDescription ?? L10n.text("reset_failed")
                    )
                    if remainingProvider == .xboxCloudGaming {
                        await modeViewModel.restoreSettingsAfterDataClearAttempt()
                        await xboxAuthManager.activateXboxCloudAccess()
                        await modeViewModel.load()
                    }
                }
            } catch {
                geForceNowAuthManager.abortDataResetWithoutActivation()
                xboxAuthManager.abortDataResetWithoutActivation()
                await modeViewModel.restoreSettingsAfterDataClearAttempt()
                await xboxAuthManager.activateXboxCloudAccess()
                await modeViewModel.load()
                dataDialog = .result(
                    title: L10n.text("reset_failed"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func signOut() {
        guard let mutation = providerCoordinator.beginCredentialMutation() else {
            return
        }
        isSigningOut = true
        viewModel.prepareForCacheClear()
        Task {
            defer {
                providerCoordinator.finishCredentialMutation(mutation)
                isSigningOut = false
            }
            do {
                await modeViewModel.deactivateForInactiveProvider()
                try await xboxAuthManager.logout()
                providerCoordinator.select(
                    geForceNowAuthManager.isAuthenticated ? .geForceNow : nil
                )
            } catch {
                await modeViewModel.load()
                dataDialog = .result(
                    title: L10n.text("sign_out"),
                    message: error.localizedDescription
                )
            }
        }
    }
}

private nonisolated enum XboxAppTab: CloudNowTabSelection {
    case home
    case browse
    case settings

    static let first = XboxAppTab.home
    static let last = XboxAppTab.settings

    var next: XboxAppTab {
        switch self {
        case .home:
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
        case .browse:
            .home
        case .settings:
            .browse
        }
    }
}
