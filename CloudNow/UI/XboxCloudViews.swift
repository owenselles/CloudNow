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
    @State private var pendingPlaybackFocusRestoreID: String?
    @State private var browsePlaybackFocusRestoreID: String?
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
                    recentlyPlayedItems: modeViewModel.catalogViewModel.recentlyPlayedItems,
                    favoriteItems: modeViewModel.catalogViewModel.favoriteItems,
                    phase: modeViewModel.catalogViewModel.phase,
                    showsRefreshWarning: modeViewModel.catalogViewModel.showsRefreshWarning,
                    onBrowse: { selectedTab = .browse },
                    onRetry: retryCatalog,
                    onPlay: play,
                    onToggleFavorite: modeViewModel.catalogViewModel.toggleFavorite
                )
                .accessibilityIdentifier("xbox-home-screen")
            }
            Tab(L10n.text("browse"), systemImage: "rectangle.stack.fill", value: XboxAppTab.browse) {
                XboxCatalogGrid(
                    onRetry: retryCatalog,
                    onPlay: play,
                    playbackFocusRestoreID: $browsePlaybackFocusRestoreID
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
                onStreamStarted: {
                    modeViewModel.catalogViewModel.recordPlayed(request.item)
                },
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

        pendingPlaybackFocusRestoreID = item.id
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

    private func restorePlaybackFocus() {
        defer { pendingPlaybackFocusRestoreID = nil }
        guard selectedTab == .browse else { return }
        browsePlaybackFocusRestoreID = pendingPlaybackFocusRestoreID
    }

    private func retryCatalog() {
        Task {
            await modeViewModel.catalogViewModel.reload()
            await modeViewModel.reloadContentAccessAfterCatalogRefresh()
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

    var streamCapabilities: XboxCloudStreamCapabilities {
        .resolved(
            for: membershipTier,
            isMembershipKnown: contentAccessPhase == .loaded
        )
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

    func reloadContentAccessAfterCatalogRefresh() async {
        cancelContentAccessRequest()
        membershipTier = nil
        contentAccessPhase = .idle
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
            streamSettings = streamCapabilities.normalized(streamSettings)
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

nonisolated enum XboxCatalogCollectionFilter: CaseIterable, Hashable, Sendable {
    case favorites
}

nonisolated enum XboxCatalogAccessFilter: CaseIterable, Hashable, Sendable {
    case standard
    case freeWithAds
    case owned
}

nonisolated struct XboxCatalogFilterState: Equatable, Sendable {
    var collections: Set<XboxCatalogCollectionFilter> = []
    var access: Set<XboxCatalogAccessFilter> = []
    var inputTypes: Set<XboxCloudInputType> = []
    var genres: Set<String> = []

    var activeSelectionCount: Int {
        collections.count + access.count + inputTypes.count + genres.count
    }

    var isEmpty: Bool {
        activeSelectionCount == 0
    }

    mutating func clear() {
        collections.removeAll()
        access.removeAll()
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

    static let empty = XboxCatalogFilterOptions(
        genres: [],
        inputTypeCounts: [:],
        favoriteCount: 0,
        standardCount: 0,
        freeWithAdsCount: 0,
        ownedCount: 0
    )
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
    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    private(set) var visibleItems: [XboxCatalogItem] = []
    private(set) var carouselItems: [XboxCatalogItem] = []
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
    private(set) var totalItemCount = 0
    private(set) var browseFilterBaseCount = 0
    private(set) var filteredItemCount = 0
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            resetBrowsePagination()
        }
    }

    var sortOrder: XboxCatalogSortOrder = .default {
        didSet {
            guard sortOrder != oldValue else { return }
            resetBrowsePagination()
        }
    }

    var filterState = XboxCatalogFilterState() {
        didSet {
            guard filterState != oldValue else { return }
            resetBrowsePagination()
        }
    }

    var activeBrowseFilterCount: Int {
        filterState.activeSelectionCount
    }

    var hasActiveBrowseFilters: Bool {
        activeBrowseFilterCount > 0
    }

    @ObservationIgnored private let makeClient: @Sendable () -> any XboxCatalogClient
    @ObservationIgnored private var client: (any XboxCatalogClient)?
    @ObservationIgnored private let account: XboxCloudAuthorizedAccount
    @ObservationIgnored private let cache: any XboxCatalogCaching
    @ObservationIgnored private let activityPersistence: any XboxCatalogActivityPersistence
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let freshnessInterval: TimeInterval
    @ObservationIgnored private var allItems: [XboxCatalogItem] = []
    @ObservationIgnored private var visibleItemLimit = 96
    @ObservationIgnored private var loadGeneration: UInt64 = 0
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private var activityGeneration: UInt64 = 0
    @ObservationIgnored private var hasLoadedActivity = false
    @ObservationIgnored private var activityPersistenceGeneration: UInt64?
    @ObservationIgnored private var activityLoadTask: Task<CloudCatalogActivityLease, Never>?
    @ObservationIgnored private var activitySaveTask: Task<Void, Never>?

    init(
        client: any XboxCatalogClient,
        account: XboxCloudAuthorizedAccount,
        cache: any XboxCatalogCaching = XboxCatalogMemoryCache.shared,
        activityPersistence: any XboxCatalogActivityPersistence = AppPersistenceStore.shared,
        now: @escaping @Sendable () -> Date = Date.init,
        freshnessInterval: TimeInterval = 15 * 60
    ) {
        makeClient = { client }
        self.account = account
        self.cache = cache
        self.activityPersistence = activityPersistence
        self.now = now
        self.freshnessInterval = freshnessInterval
    }

    init(
        makeClient: @escaping @Sendable () -> any XboxCatalogClient,
        account: XboxCloudAuthorizedAccount,
        cache: any XboxCatalogCaching = XboxCatalogMemoryCache.shared,
        activityPersistence: any XboxCatalogActivityPersistence = AppPersistenceStore.shared,
        now: @escaping @Sendable () -> Date = Date.init,
        freshnessInterval: TimeInterval = 15 * 60
    ) {
        self.makeClient = makeClient
        self.account = account
        self.cache = cache
        self.activityPersistence = activityPersistence
        self.now = now
        self.freshnessInterval = freshnessInterval
    }

    func load() async {
        await loadActivityIfNeeded()
        guard !Task.isCancelled else { return }
        await load(forceRefresh: false)
    }

    func reload() async {
        guard !isRefreshing else { return }
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
        guard !Task.isCancelled else { return }
        await load(forceRefresh: true)
    }

    private func load(forceRefresh: Bool) async {
        guard phase == .idle || (forceRefresh && phase == .loaded) else {
            return
        }
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
        if forceRefresh {
            if !loadedCachedSnapshot {
                phase = .loading
            }
        } else if let cached = await cache.snapshot(for: cacheKey) {
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

    func loadNextPageIfNeeded(_ item: XboxCatalogItem) {
        guard item.id == visibleItems.last?.id,
              visibleItems.count < carouselItems.count
        else {
            return
        }
        visibleItemLimit = min(visibleItemLimit + 96, carouselItems.count)
        publishVisibleItems()
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
        publishVisibleItems()
        enqueueFavoriteSave()
    }

    func recordPlayed(_ item: XboxCatalogItem) {
        var itemIDs = recentlyPlayedIDs
        itemIDs.removeAll { $0 == item.id }
        itemIDs.insert(item.id, at: 0)
        recentlyPlayedIDs = Array(
            itemIDs.prefix(CloudCatalogActivitySnapshot.maximumRecentlyPlayedCount)
        )
        publishVisibleItems()
        enqueueRecentlyPlayedSave()
    }

    func fetchDetail(for item: XboxCatalogItem) async -> XboxCatalogItem? {
        let request = XboxCatalogRequest(
            localeIdentifier: L10n.localeCode,
            market: Locale.current.region?.identifier
        )
        do {
            let detail = try await resolvedClient().fetchDetail(
                for: item,
                request: request
            )
            guard detail.id == item.id else { return nil }
            return detail
        } catch {
            return nil
        }
    }

    func flushActivityPersistence() async {
        await activitySaveTask?.value
    }

    func cancel() {
        refreshGeneration &+= 1
        isRefreshing = false
        cancelCatalogRequest()
    }

    private func cancelCatalogRequest() {
        loadGeneration &+= 1
        client?.cancel()
        client = nil
    }

    func prepareForCacheClear() {
        cancel()
        allItems.removeAll(keepingCapacity: false)
        visibleItems.removeAll(keepingCapacity: false)
        carouselItems.removeAll(keepingCapacity: false)
        favoriteItems.removeAll(keepingCapacity: false)
        recentlyPlayedItems.removeAll(keepingCapacity: false)
        availableAccessKinds.removeAll(keepingCapacity: false)
        playableAccessKinds.removeAll(keepingCapacity: false)
        filterOptions = .empty
        phase = .idle
        showsRefreshWarning = false
        totalItemCount = 0
        browseFilterBaseCount = 0
        filteredItemCount = 0
        visibleItemLimit = 96
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

    private func publishVisibleItems() {
        let availableAccessKinds = Set(allItems.flatMap(\.accessKinds))
        let playableAccessKinds = Set(allItems.flatMap { item in
            item.routes.compactMap { route in
                route.isPlayable ? route.accessKind : nil
            }
        })
        let searchedItems = search(allItems)
        let carouselItems = sort(filter(searchedItems, state: filterState))
        let items = Array(carouselItems.prefix(visibleItemLimit))
        let favoriteItems = allItems.filter { favoriteIDs.contains($0.id) }
        let itemsByID = Dictionary(
            allItems.map { ($0.id, $0) },
            uniquingKeysWith: { retained, _ in retained }
        )
        let recentlyPlayedItems = recentlyPlayedIDs.compactMap { itemsByID[$0] }
        let filterOptions = makeFilterOptions()
        totalItemCount = allItems.count
        browseFilterBaseCount = searchedItems.count
        filteredItemCount = carouselItems.count
        if availableAccessKinds != self.availableAccessKinds {
            self.availableAccessKinds = availableAccessKinds
        }
        if playableAccessKinds != self.playableAccessKinds {
            self.playableAccessKinds = playableAccessKinds
        }
        if carouselItems != self.carouselItems {
            self.carouselItems = carouselItems
        }
        if favoriteItems != self.favoriteItems {
            self.favoriteItems = favoriteItems
        }
        if recentlyPlayedItems != self.recentlyPlayedItems {
            self.recentlyPlayedItems = recentlyPlayedItems
        }
        if filterOptions != self.filterOptions {
            self.filterOptions = filterOptions
        }
        guard items != visibleItems else { return }
        visibleItems = items
    }

    func browsePreviewCount(for state: XboxCatalogFilterState) -> Int {
        filter(search(allItems), state: state).count
    }

    func clearBrowseFilters() {
        filterState.clear()
    }

    private func resetBrowsePagination() {
        visibleItemLimit = 96
        publishVisibleItems()
    }

    private func search(_ items: [XboxCatalogItem]) -> [XboxCatalogItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
        }
    }

    private func filter(
        _ items: [XboxCatalogItem],
        state: XboxCatalogFilterState
    ) -> [XboxCatalogItem] {
        guard !state.isEmpty else { return items }
        return items.filter { item in
            if !state.collections.isEmpty {
                let matchesCollection =
                    state.collections.contains(.favorites)
                        && favoriteIDs.contains(item.id)
                if !matchesCollection {
                    return false
                }
            }

            if !state.access.isEmpty {
                let matchesAccess = state.access.contains { access in
                    switch access {
                    case .standard:
                        item.accessKinds.contains(.standard)
                    case .freeWithAds:
                        item.supportsFreeWithAds
                    case .owned:
                        item.isOwned
                    }
                }
                if !matchesAccess {
                    return false
                }
            }

            if !state.inputTypes.isEmpty,
               state.inputTypes.isDisjoint(with: item.supportedInputTypes)
            {
                return false
            }

            if !state.genres.isEmpty {
                let itemGenres = Set(item.genres.compactMap(genreID))
                if state.genres.isDisjoint(with: itemGenres) {
                    return false
                }
            }

            return true
        }
    }

    private func sort(_ items: [XboxCatalogItem]) -> [XboxCatalogItem] {
        switch sortOrder {
        case .default:
            items
        case .titleAZ:
            items.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .titleZA:
            items.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedDescending
            }
        case .recentFirst:
            items.sorted { left, right in
                let leftRank = recentlyPlayedIDs.firstIndex(of: left.id) ?? .max
                let rightRank = recentlyPlayedIDs.firstIndex(of: right.id) ?? .max
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return left.title.localizedStandardCompare(right.title)
                    == .orderedAscending
            }
        }
    }

    private func makeFilterOptions() -> XboxCatalogFilterOptions {
        var genreLabels: [String: String] = [:]
        var genreCounts: [String: Int] = [:]
        var inputTypeCounts: [XboxCloudInputType: Int] = [:]

        for item in allItems {
            for inputType in item.supportedInputTypes {
                inputTypeCounts[inputType, default: 0] += 1
            }
            var itemGenreIDs: Set<String> = []
            for genre in item.genres {
                let label = genre.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let id = genreID(label), itemGenreIDs.insert(id).inserted else {
                    continue
                }
                genreLabels[id] = genreLabels[id] ?? label
                genreCounts[id, default: 0] += 1
            }
        }

        let genres = genreCounts.compactMap { id, count in
            genreLabels[id].map {
                XboxCatalogGenreFilterOption(id: id, label: $0, count: count)
            }
        }.sorted {
            $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }

        return XboxCatalogFilterOptions(
            genres: genres,
            inputTypeCounts: inputTypeCounts,
            favoriteCount: allItems.count { favoriteIDs.contains($0.id) },
            standardCount: allItems.count { $0.accessKinds.contains(.standard) },
            freeWithAdsCount: allItems.count(where: \.supportsFreeWithAds),
            ownedCount: allItems.count(where: \.isOwned)
        )
    }

    private func genreID(_ genre: String) -> String? {
        let genre = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !genre.isEmpty else { return nil }
        return genre.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale.current
        ).lowercased()
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
        publishVisibleItems()
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
}

private struct XboxCatalogHome: View {
    let recentlyPlayedItems: [XboxCatalogItem]
    let favoriteItems: [XboxCatalogItem]
    let phase: XboxCatalogViewModel.LoadPhase
    let showsRefreshWarning: Bool
    let onBrowse: () -> Void
    let onRetry: () -> Void
    let onPlay: (XboxCatalogItem, XboxCloudTitleRoute) -> Void
    let onToggleFavorite: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var carouselRequest: XboxCatalogCarouselRequest?
    @State private var carouselSourceFocus: XboxHomeGameFocus?
    @State private var carouselRestoreFocus: XboxHomeGameFocus?
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

    private var emptyStateMessage: String {
        L10n.text("xbox_empty_home_message")
    }

    private var recentlyPlayedWithoutHero: [XboxCatalogItem] {
        recentlyPlayedItems.filter { $0.id != heroSelection?.item.id }
    }

    var body: some View {
        ZStack {
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
                    if let heroSelection {
                        let heroArtworkURL = heroSelection.item
                            .heroArtworkURL?.absoluteString
                        CloudCatalogHeroBanner(
                            artworkURL: heroArtworkURL
                                ?? heroSelection.item.artworkURL?.absoluteString,
                            artworkContentMode: heroArtworkURL == nil
                                ? .fit
                                : .fill,
                            artworkAlignment: .center,
                            actionTitle: heroSelection.playTitle,
                            actionSystemImage: heroSelection.route.isPlayable
                                ? "play.fill"
                                : "lock.fill",
                            isActionEnabled: heroSelection.route.isPlayable,
                            actionTint: heroSelection.route.isPlayable
                                ? .green
                                : .gray,
                            actionFocus: $heroActionFocused,
                            action: {
                                onPlay(heroSelection.item, heroSelection.route)
                            }
                        )
                        .accessibilityIdentifier("xbox-home.hero")
                    }

                    if showsRefreshWarning {
                        XboxCatalogRefreshWarning(onRetry: onRetry)
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
            } else if heroSelection?.route.isPlayable == true {
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
        return XboxCatalogSelection(item: item, route: route)
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

    private var selections: [XboxCatalogSelection] {
        items.compactMap { item in
            item.preferredRoute.map {
                XboxCatalogSelection(item: item, route: $0)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(selections) { selection in
                        let focus = XboxHomeGameFocus(
                            row: row,
                            itemID: selection.item.id
                        )
                        Button {
                            onPlay(selection.item, selection.route)
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
    let onRetry: () -> Void
    let onPlay: (XboxCatalogItem, XboxCloudTitleRoute) -> Void
    @Binding var playbackFocusRestoreID: String?

    @Environment(XboxCatalogViewModel.self) private var viewModel
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

    var body: some View {
        @Bindable var viewModel = viewModel

        ZStack {
            switch viewModel.phase {
            case .idle, .loading:
                CloudCatalogLoadingGrid()
            case .failed:
                XboxCatalogFailureView(onRetry: onRetry)
                    .padding(60)
            case .loaded where viewModel.totalItemCount == 0:
                XboxCatalogEmptyView()
                    .padding(60)
            case .loaded:
                catalogGrid
            }
        }
        .searchable(
            text: $viewModel.searchText,
            prompt: Text(
                L10n.format("search_games_count", viewModel.totalItemCount)
            )
        )
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
    }

    private var catalogGrid: some View {
        CloudCatalogGrid(
            items: viewModel.visibleItems,
            focusedId: $focusedCardID,
            emptyActionFocus: $emptyActionFocused,
            hasActiveFilters: viewModel.hasActiveBrowseFilters,
            onClearFilters: viewModel.clearBrowseFilters,
            onSelect: showCarousel(startingAt:),
            onItemVisible: { item, _ in
                viewModel.loadNextPageIfNeeded(item)
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

    private var filterHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.showsRefreshWarning {
                XboxCatalogRefreshWarning(onRetry: onRetry)
                    .padding(.horizontal, 60)
                    .padding(.top, 24)
            }
            XboxCatalogFilterBar()
        }
    }

    private func selection(for item: XboxCatalogItem) -> XboxCatalogSelection? {
        let selectedAccess = viewModel.filterState.access
        let route: XboxCloudTitleRoute? = if selectedAccess == [.standard] {
            item.route(for: .standard)
        } else if selectedAccess == [.freeWithAds] {
            item.route(for: .freeWithAds)
        } else {
            item.preferredRoute
        }
        return route.map { XboxCatalogSelection(item: item, route: $0) }
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
    @Environment(XboxCatalogViewModel.self) private var viewModel

    var body: some View {
        @Bindable var viewModel = viewModel

        CloudCatalogFilterBar(
            totalCount: viewModel.totalItemCount,
            resultCount: viewModel.filteredItemCount,
            sortOptions: XboxCatalogSortOrder.allCases.map {
                CloudCatalogSortOption(value: $0, label: $0.label)
            },
            activeFilters: activeFilters,
            activeSelectionCount: viewModel.activeBrowseFilterCount,
            sortOrder: $viewModel.sortOrder,
            refreshTitle: L10n.text("refresh_library"),
            isRefreshDisabled: viewModel.phase == .loading
                || viewModel.isRefreshing,
            refreshAccessibilityIdentifier: "reloadXboxCloudCatalogButton",
            onRefresh: {
                Task { await viewModel.reload() }
            },
            filterSheet: { isPresented in
                XboxCatalogFilterSheet(
                    state: $viewModel.filterState,
                    options: viewModel.filterOptions,
                    totalCount: viewModel.browseFilterBaseCount,
                    previewCount: viewModel.browsePreviewCount,
                    onClose: { isPresented.wrappedValue = false }
                )
            }
        )
    }

    private var activeFilters: [CloudCatalogActiveFilter] {
        var filters: [CloudCatalogActiveFilter] = []

        for collection in viewModel.filterState.collections {
            filters.append(CloudCatalogActiveFilter(
                id: "xbox-collection-\(collection.id)",
                label: collection.label,
                onRemove: { remove(collection) }
            ))
        }
        for access in viewModel.filterState.access.sorted(by: {
            $0.sortOrder < $1.sortOrder
        }) {
            filters.append(CloudCatalogActiveFilter(
                id: "xbox-access-\(access.id)",
                label: access.label,
                onRemove: { remove(access) }
            ))
        }
        for inputType in viewModel.filterState.inputTypes.sorted(by: {
            $0.sortOrder < $1.sortOrder
        }) {
            filters.append(CloudCatalogActiveFilter(
                id: "xbox-input-\(inputType.id)",
                label: inputType.label,
                onRemove: { remove(inputType) }
            ))
        }
        for genreID in viewModel.filterState.genres.sorted() {
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
        var state = viewModel.filterState
        state.collections.remove(collection)
        viewModel.filterState = state
    }

    private func remove(_ access: XboxCatalogAccessFilter) {
        var state = viewModel.filterState
        state.access.remove(access)
        viewModel.filterState = state
    }

    private func remove(_ inputType: XboxCloudInputType) {
        var state = viewModel.filterState
        state.inputTypes.remove(inputType)
        viewModel.filterState = state
    }

    private func removeGenre(_ genreID: String) {
        var state = viewModel.filterState
        state.genres.remove(genreID)
        viewModel.filterState = state
    }
}

private struct XboxCatalogFilterSheet: View {
    @Binding var state: XboxCatalogFilterState
    let options: XboxCatalogFilterOptions
    let totalCount: Int
    let previewCount: (XboxCatalogFilterState) -> Int
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedSections: Set<XboxCatalogFilterSection> = [
        .collections,
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
                        collectionsSection
                        accessSection
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
                    previewCount(state),
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
                ForEach(availableAccessOptions, id: \.self) { option in
                    FilterOptionButton(
                        label: option.label,
                        count: accessCount(option),
                        isSelected: state.access.contains(option),
                        action: { toggle(option) }
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

    private var availableAccessOptions: [XboxCatalogAccessFilter] {
        XboxCatalogAccessFilter.allCases.filter { accessCount($0) > 0 }
    }

    private var availableInputTypes: [XboxCloudInputType] {
        XboxCloudInputType.allCases
            .filter { (options.inputTypeCounts[$0] ?? 0) > 0 }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func accessCount(_ option: XboxCatalogAccessFilter) -> Int {
        switch option {
        case .standard:
            options.standardCount
        case .freeWithAds:
            options.freeWithAdsCount
        case .owned:
            options.ownedCount
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
                    route: context.item.route
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

    var id: String {
        "\(item.id)|\(route.titleID)|\(route.accessKind)"
    }

    var badge: CloudCatalogCardBadge? {
        guard route.accessKind == .freeWithAds else { return nil }
        return route.isPlayable
            ? CloudCatalogCardBadge(
                title: L10n.text("free_with_ads"),
                systemImage: nil,
                foregroundColor: .black,
                backgroundColor: .green
            )
            : CloudCatalogCardBadge(
                title: L10n.text("not_eligible"),
                systemImage: "lock.fill",
                foregroundColor: .white,
                backgroundColor: .gray
            )
    }

    var accessibilityStatus: String {
        if route.accessKind == .freeWithAds {
            return route.isPlayable
                ? L10n.text("free_with_ads")
                : L10n.text("not_eligible")
        }
        return L10n.text("xbox_cloud_catalog")
    }

    var playTitle: String {
        guard route.isPlayable else { return L10n.text("not_eligible") }
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
            L10n.text("game_pass")
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
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            Label(
                L10n.text("xbox_cloud_catalog_unavailable"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.yellow)

            Button(L10n.text("try_again"), action: onRetry)
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

                CloudNowStreamQualitySection {
                    CloudNowStreamQualityPicker(
                        L10n.text("resolution"),
                        selection: $modeViewModel.streamSettings.displayResolution,
                        accessibilityIdentifier: "settings.stream-quality.resolution",
                        options: xboxAutomaticResolutionOption,
                        groups: xboxResolutionGroups
                    )

                    CloudNowStreamQualityPicker(
                        L10n.text("codec"),
                        selection: $modeViewModel.streamSettings.codecPreference,
                        accessibilityIdentifier: "settings.stream-quality.codec",
                        options: modeViewModel.streamCapabilities.codecs.map {
                            CloudNowStreamQualityOption(value: $0, title: $0.label)
                        }
                    )

                    CloudNowGameLanguagePicker(
                        selection: $modeViewModel.streamSettings.gameLanguage
                    )
                }
                .disabled(isBusy)

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

    private var xboxAutomaticResolutionOption: [
        CloudNowStreamQualityOption<XboxCloudDisplayResolution>
    ] {
        guard modeViewModel.streamCapabilities.resolutions.contains(.automatic) else {
            return []
        }
        return [
            CloudNowStreamQualityOption(
                value: .automatic,
                title: XboxCloudDisplayResolution.automatic.label
            ),
        ]
    }

    private var xboxResolutionGroups: [
        CloudNowStreamQualityOptionGroup<XboxCloudDisplayResolution>
    ] {
        let options: [CloudNowStreamQualityOption<XboxCloudDisplayResolution>] = modeViewModel
            .streamCapabilities.resolutions.compactMap { resolution in
                guard resolution != .automatic else { return nil }
                return CloudNowStreamQualityOption(
                    value: resolution,
                    title: resolution.label,
                    badge: resolution.badge,
                    systemImage: resolution.systemImage
                )
            }
        return [
            CloudNowStreamQualityOptionGroup(
                title: L10n.text("tv_standards"),
                options: options
            ),
        ]
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

    private func switchProvider(to provider: CloudGamingProvider) {
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
        viewModel.prepareForPersistentDataClear()
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
