import SwiftUI

struct HomeView: View {
    let onPlay: (GameInfo) -> Void
    let onResume: (ResumableSession) -> Void

    @Environment(GamesViewModel.self) var viewModel
    @Environment(AuthManager.self) private var authManager
    @Environment(CloudSessionCoordinator.self) private var cloudSessionCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var carouselRequest: CarouselRequest?
    @State private var carouselSourceFocus: HomeGameFocus?
    @State private var restoreScrollTarget: HomeGameFocus?
    @State private var sessionToEnd: String?
    @State private var endingDiscoveredSessionID: String?
    @State private var failedSessionEndID: String?
    @State private var isRefreshingSessionStatus = false
    @FocusState private var focusedGame: HomeGameFocus?

    var body: some View {
        ZStack {
            if viewModel.isLoading {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.gray.opacity(0.2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .shimmer()
                            .padding(.horizontal, 60)
                        VStack(alignment: .leading, spacing: 48) {
                            skeletonRow
                            skeletonRow
                        }
                        .padding(.top, 48)
                        .padding(.bottom, 60)
                    }
                }
            } else if viewModel.continuePlaying.isEmpty, viewModel.recentlyPlayedGames.isEmpty, viewModel.favoriteGames.isEmpty, activeResumable == nil, !showsSessionStatusNotice {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if showsSessionStatusNotice {
                                sessionStatusNotice
                            }
                            let heroGame: GameInfo? = activeResumable == nil && discoveredSessionGame == nil
                                ? (viewModel.continuePlaying.first ?? viewModel.recentlyPlayedGames.first ?? viewModel.favoriteGames.first)
                                : nil
                            if let rs = activeResumable {
                                resumeBanner(rs)
                            } else if let session = discoveredSession,
                                      let game = discoveredSessionGame
                            {
                                discoveredSessionBanner(session, game: game)
                            } else if let hero = heroGame {
                                heroBanner(hero)
                            }

                            VStack(alignment: .leading, spacing: 48) {
                                if !viewModel.continuePlaying.isEmpty {
                                    gameRow(
                                        row: .continuePlaying,
                                        title: L10n.text("resume_stream"),
                                        games: viewModel.continuePlaying,
                                        badge: viewModel.activeSessionsLoadPhase == .loaded
                                            ? L10n.text("session_active")
                                            : L10n.text("last_known_session")
                                    )
                                }
                                let recentWithoutHero = viewModel.recentlyPlayedGames.filter { $0.id != heroGame?.id }
                                if !recentWithoutHero.isEmpty {
                                    gameRow(
                                        row: .recent,
                                        title: L10n.text("recently_played"),
                                        games: recentWithoutHero
                                    )
                                }
                                if !viewModel.favoriteGames.isEmpty {
                                    gameRow(
                                        row: .favorites,
                                        title: L10n.text("favorites"),
                                        games: viewModel.favoriteGames,
                                        isFavoritesRow: true
                                    )
                                }
                            }
                            .padding(.top, 48)
                            .padding(.bottom, 60)
                        }
                    }
                    .onChange(of: restoreScrollTarget) { _, newValue in
                        guard let newValue else { return }
                        if reduceMotion {
                            proxy.scrollTo(newValue, anchor: .center)
                        } else {
                            withAnimation {
                                proxy.scrollTo(newValue, anchor: .center)
                            }
                        }
                        restoreScrollTarget = nil
                    }
                }
            }
        }
        .fullScreenCover(item: $carouselRequest) { req in
            GameCarouselView(request: req, onPlay: onPlay, onDismiss: { lastId in
                carouselRequest = nil
                let source = carouselSourceFocus
                carouselSourceFocus = nil
                guard let lastId, let source else { return }
                let target = HomeGameFocus(row: source.row, gameId: lastId)
                restoreScrollTarget = target
                Task { @MainActor in
                    await Task.yield()
                    focusedGame = target
                }
            })
            .environment(viewModel)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: carouselRequest?.id)
        .toolbar(.hidden, for: .navigationBar)
        .alert(
            L10n.text("end_session_title"),
            isPresented: Binding(
                get: { sessionToEnd != nil },
                set: {
                    if !$0 {
                        sessionToEnd = nil
                    }
                }
            ),
            presenting: sessionToEnd
        ) { sessionID in
            Button(L10n.text("end_session"), role: .destructive) {
                endSession(sessionID)
            }
            Button(L10n.text("cancel"), role: .cancel) {}
        } message: { _ in
            Text(L10n.text("end_session_from_home_message"))
        }
        .task(id: viewModel.resumableSession?.expiryIdentity) {
            guard let resumableSession = viewModel.resumableSession else { return }
            let remaining = max(
                ResumableSession.gracePeriod
                    - Date().timeIntervalSince(resumableSession.leftAt),
                0
            )
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  viewModel.resumableSession?.session.sessionId
                  == resumableSession.session.sessionId,
                  viewModel.resumableSession?.isExpired == true
            else {
                return
            }
            viewModel.resumableSession = nil
        }
    }

    private var activeResumable: ResumableSession? {
        guard let rs = viewModel.resumableSession, !rs.isExpired,
              cloudSessionCoordinator.sessionPendingEnd?.serverSessionID != rs.session.sessionId
        else { return nil }
        return rs
    }

    private var managedSession: CloudServerSessionLease? {
        guard let lease = cloudSessionCoordinator.serverSession,
              lease.provider == .geForceNow
        else { return nil }
        return lease
    }

    private var showsManagedSessionNotice: Bool {
        managedSession != nil && activeResumable == nil
    }

    private var discoveredSession: ActiveSessionInfo? {
        guard managedSession == nil else { return nil }
        return viewModel.activeSessions.first
    }

    private var discoveredSessionGame: GameInfo? {
        guard let appID = discoveredSession?.appId else { return nil }
        return viewModel.mainGames.first { game in
            game.variants.contains { $0.appId == appID }
        }
    }

    private var unresolvedEndFailure: String? {
        guard let failedSessionEndID,
              viewModel.activeSessionsLoadPhase != .loaded
              || viewModel.activeSessions.contains(where: { $0.sessionId == failedSessionEndID })
        else { return nil }
        return failedSessionEndID
    }

    private var unlistedSession: ActiveSessionInfo? {
        let listedAppIDs = Set(viewModel.mainGames.flatMap { $0.variants.compactMap(\.appId) })
        return viewModel.activeSessions.first { session in
            guard let appID = session.appId else { return true }
            return !listedAppIDs.contains(appID)
        }
    }

    private var hasUnlistedSessions: Bool {
        unlistedSession != nil
    }

    private var showsSessionStatusNotice: Bool {
        if showsManagedSessionNotice || hasUnlistedSessions
            || endingDiscoveredSessionID != nil || unresolvedEndFailure != nil
        {
            return true
        }
        switch viewModel.activeSessionsLoadPhase {
        case .failed: return true
        case .loading: return !viewModel.activeSessions.isEmpty
        case .idle, .loaded: return false
        }
    }

    private var sessionStatusTitle: String {
        if endingDiscoveredSessionID != nil {
            return L10n.text("ending_session")
        }
        if unresolvedEndFailure != nil {
            return L10n.text("session_cleanup_pending")
        }
        if showsManagedSessionNotice {
            if cloudSessionCoordinator.isEndingServerSession {
                return L10n.text("ending_session")
            }
            if cloudSessionCoordinator.sessionPendingEnd != nil {
                return L10n.text("session_cleanup_pending")
            }
            return L10n.text("session_active")
        }
        switch viewModel.activeSessionsLoadPhase {
        case .failed: return L10n.text("session_status_unavailable")
        case .idle, .loading: return L10n.text("checking_session_status")
        case .loaded: return L10n.text("session_active")
        }
    }

    private var sessionStatusMessage: String? {
        if endingDiscoveredSessionID != nil {
            return L10n.text("session_cleanup_in_progress_message")
        }
        if unresolvedEndFailure != nil {
            return L10n.text("session_cleanup_pending_message")
        }
        if showsManagedSessionNotice {
            if cloudSessionCoordinator.isEndingServerSession {
                return L10n.text("session_cleanup_in_progress_message")
            }
            if cloudSessionCoordinator.sessionPendingEnd != nil {
                return L10n.text("session_cleanup_pending_message")
            }
            return nil
        }
        if case .failed = viewModel.activeSessionsLoadPhase {
            return L10n.text("session_status_unavailable_message")
        }
        return hasUnlistedSessions ? L10n.text("session_not_in_catalog") : nil
    }

    private var sessionStatusNotice: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(sessionStatusTitle, systemImage: "cloud")
                .font(.title3.weight(.semibold))
            if let sessionStatusMessage {
                Text(sessionStatusMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            if showsManagedSessionNotice, let managedSession {
                Button(L10n.text("end_session"), role: .destructive) {
                    sessionToEnd = managedSession.serverSessionID
                }
                .buttonStyle(.bordered)
                .disabled(!canEndSession(managedSession.serverSessionID))
                .accessibilityIdentifier("home.session-status.end-session")
            } else if let sessionID = unresolvedEndFailure ?? unlistedSession?.sessionId {
                Button(L10n.text("end_session"), role: .destructive) {
                    sessionToEnd = sessionID
                }
                .buttonStyle(.bordered)
                .disabled(!canEndSession(sessionID))
                .accessibilityIdentifier("home.session-status.end-session")
            } else {
                Button(L10n.text("retry")) {
                    refreshSessionStatus()
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshingSessionStatus || viewModel.activeSessionsLoadPhase == .loading)
                .accessibilityIdentifier("home.session-status.retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(32)
        .background(.thinMaterial, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 60)
        .padding(.bottom, 32)
        .accessibilityIdentifier("home.session-status")
    }

    private func refreshSessionStatus() {
        guard !isRefreshingSessionStatus else { return }
        isRefreshingSessionStatus = true
        Task { @MainActor in
            defer { isRefreshingSessionStatus = false }
            await viewModel.refreshActiveSessions(authManager: authManager)
        }
    }

    private func canEndSession(_ sessionID: String) -> Bool {
        guard endingDiscoveredSessionID == nil,
              !cloudSessionCoordinator.isEndingServerSession
        else { return false }
        guard let lease = cloudSessionCoordinator.serverSession else { return true }
        return lease.provider == .geForceNow && lease.serverSessionID == sessionID
    }

    private func endSession(_ sessionID: String) {
        guard let account = authManager.session else { return }
        guard canEndSession(sessionID) else { return }
        endingDiscoveredSessionID = sessionID
        failedSessionEndID = nil
        Task { @MainActor in
            defer { endingDiscoveredSessionID = nil }
            let didEnd: Bool
            if let lease = managedSession, lease.serverSessionID == sessionID {
                didEnd = await cloudSessionCoordinator.endServerSessionUsingProvider(lease)
            } else if let session = viewModel.activeSessions.first(where: { $0.sessionId == sessionID }) {
                didEnd = await viewModel.endActiveSession(
                    session,
                    authManager: authManager,
                    coordinator: cloudSessionCoordinator
                )
            } else {
                await viewModel.refreshActiveSessions(authManager: authManager)
                return
            }
            guard let currentAccount = authManager.session,
                  currentAccount.provider.idpId == account.provider.idpId,
                  currentAccount.user.userId == account.user.userId
            else { return }
            guard didEnd else {
                failedSessionEndID = sessionID
                return
            }
            viewModel.markSessionStopped(
                sessionID,
                idpId: account.provider.idpId,
                userId: account.user.userId
            )
            await viewModel.refreshActiveSessions(authManager: authManager)
        }
    }

    // MARK: Resume Banner

    private func resumeBanner(_ rs: ResumableSession) -> some View {
        CloudResumableSessionBanner(
            title: rs.game.title,
            artworkURL: rs.game.heroBannerUrl,
            expiresAt: rs.leftAt.addingTimeInterval(
                ResumableSession.gracePeriod
            ),
            isEndEnabled: managedSession.map { canEndSession($0.serverSessionID) } ?? false,
            onResume: { onResume(rs) },
            onEnd: managedSession.map { lease in
                { sessionToEnd = lease.serverSessionID }
            }
        )
    }

    private func discoveredSessionBanner(_ session: ActiveSessionInfo, game: GameInfo) -> some View {
        CloudResumableSessionBanner(
            title: game.title,
            artworkURL: game.heroBannerUrl,
            expiresAt: nil,
            isResumeEnabled: endingDiscoveredSessionID == nil,
            isEndEnabled: canEndSession(session.sessionId),
            onResume: { onPlay(game) },
            onEnd: { sessionToEnd = session.sessionId },
            statusTitle: viewModel.activeSessionsLoadPhase == .loaded
                ? L10n.text("session_active")
                : L10n.text("last_known_session")
        )
    }

    // MARK: Hero Banner

    private func heroBanner(_ game: GameInfo) -> some View {
        HeroBannerView(game: game, onPlay: onPlay)
    }

    // MARK: Game Row

    private func gameRow(
        row: HomeGameRow,
        title: String,
        games: [GameInfo],
        badge: String? = nil,
        isFavoritesRow: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green, in: Capsule())
                }
            }
            .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(games) { game in
                        let focus = HomeGameFocus(row: row, gameId: game.id)
                        GameCardView(game: game) { onPlay(game) }
                            .frame(width: 200)
                            .id(focus)
                            .focused($focusedGame, equals: focus)
                            .contextMenu {
                                Button {
                                    carouselSourceFocus = focus
                                    carouselRequest = CarouselRequest(games: games, startId: game.id)
                                } label: {
                                    Label("Info", systemImage: "info.circle")
                                }
                                if let session = viewModel.activeSessions.first(where: { session in
                                    guard let appID = session.appId else { return false }
                                    return game.variants.contains { $0.appId == appID }
                                }) {
                                    Button(L10n.text("end_session"), role: .destructive) {
                                        sessionToEnd = session.sessionId
                                    }
                                    .disabled(!canEndSession(session.sessionId))
                                }
                                if isFavoritesRow {
                                    Button {
                                        viewModel.toggleFavorite(game.id)
                                    } label: {
                                        Label(L10n.text("remove_from_favorites"), systemImage: "star.slash.fill")
                                    }
                                }
                            }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
            }
            .focusSection()
            .scrollClipDisabled()
        }
    }

    private enum HomeGameRow: Hashable {
        case continuePlaying
        case recent
        case favorites
    }

    private struct HomeGameFocus: Hashable {
        let row: HomeGameRow
        let gameId: String
    }

    // MARK: Skeleton Row

    private var skeletonRow: some View {
        VStack(alignment: .leading, spacing: 20) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.25))
                .frame(width: 180, height: 24)
                .shimmer()
                .padding(.horizontal, 60)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(0 ..< 6, id: \.self) { _ in
                        GameCardSkeleton().frame(width: 200)
                    }
                }
                .padding(.horizontal, 60)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Empty State

    private var emptyState: some View {
        CloudCatalogHomeEmptyState()
    }
}

// MARK: - Hero Banner View

private struct HeroBannerView: View {
    let game: GameInfo
    let onPlay: (GameInfo) -> Void

    var body: some View {
        CloudCatalogHeroBanner(
            artworkURL: game.heroBannerUrl,
            prefetchArtworkURL: game.heroImageUrl ?? game.heroBannerUrl,
            actionTitle: L10n.text("play"),
            actionSystemImage: "play.fill",
            action: { onPlay(game) }
        )
    }
}
