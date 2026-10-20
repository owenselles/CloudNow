import SwiftUI

// MARK: - GameDetailView

enum ExpandedDetailPresentationStyle {
    case fullScreen
    case embeddedCarousel
    case carouselExpanded
}

struct GameDetailView: View {
    let game: GameInfo
    let onPlay: (GameInfo) -> Void
    var presentationStyle: ExpandedDetailPresentationStyle = .fullScreen
    var onCollapse: (() -> Void)?
    var rendersBackground = true

    @Environment(GamesViewModel.self) var viewModel
    @Environment(AuthManager.self) private var authManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showFullDescription = false
    @State private var showFullDetails = false
    @FocusState private var focusedElement: DetailFocus?
    @State private var backgroundBlurred = false
    @State private var appeared = false
    @State private var dismissing = false
    @State private var availabilityByVariant: [String: GFNGameAvailability] = [:]
    @State private var didLoadAvailability = false
    @State private var availabilityFailed = false
    @State private var availabilityLoading = false
    @State private var availabilityRevision = 0
    @State private var availabilityRequestID: UUID?
    @State private var installToPlayInfo: GameInfo?
    @State private var installToPlayInfoFailed = false
    @State private var installToPlayInfoLoading = false

    private struct AvailabilityRequest: Hashable {
        let gameId: String
        let revision: Int
        let active: Bool
    }

    private var effectiveGame: GameInfo {
        installToPlayInfo ?? game
    }

    private var selectedAvailability: GFNGameAvailability? {
        guard let variant = viewModel.gameWithPreferredStore(effectiveGame).variants.first else { return nil }
        return availabilityByVariant[variant.id] ?? (didLoadAvailability ? nil : variant.availability)
    }

    private var isSelectedGameUnavailable: Bool {
        didLoadAvailability && !availabilityFailed && selectedAvailability?.isUnavailable == true
    }

    private var isInstallToPlay: Bool {
        (installToPlayInfo?.playType ?? game.playType) == .installToPlay
    }

    private var selectedInstallVariant: GameVariant? {
        guard var variant = viewModel.gameWithPreferredStore(effectiveGame).variants.first else { return nil }
        if installToPlayInfo != nil, !installToPlayInfoLoading, !installToPlayInfoFailed {
            return variant
        }
        variant.isInstalled = nil
        return variant
    }

    private var playActionTitle: String {
        guard isInstallToPlay else { return L10n.text("play") }
        switch selectedInstallVariant?.isInstalled {
        case true: return L10n.text("play")
        case false: return L10n.text("install_game")
        default: return L10n.text("open_in_steam")
        }
    }

    private enum DetailFocus: Hashable {
        case play
        case favorite
        case about
        case details
        case availability
        case variant(String)
        case exitCatcher
    }

    private var isEmbeddedCarousel: Bool {
        presentationStyle == .embeddedCarousel
    }

    private var isCarouselExpanded: Bool {
        presentationStyle == .carouselExpanded
    }

    private var preferredFocusTarget: DetailFocus {
        if effectiveGame.isInLibrary {
            return isSelectedGameUnavailable ? .favorite : .play
        }
        if let description = game.longDescription, !description.isEmpty {
            return .about
        }
        if !detailItems.isEmpty {
            return .details
        }
        return .exitCatcher
    }

    private var detailItems: [(String, String)] {
        let genres = game.genreItems
        return [
            game.contentRating.map { ("Rating", $0) },
            game.developer.map { ("Developer", $0) },
            game.publisher.flatMap { $0 != game.developer ? ("Publisher", $0) : nil },
            genres.isEmpty ? nil : ("Genres", genres.joined(separator: ", ")),
            effectiveGame.variants.isEmpty
                ? nil
                : ("Available on", effectiveGame.variants.map(\.storeName).joined(separator: ", ")),
        ].compactMap { $0 }
    }

    var body: some View {
        Group {
            if isEmbeddedCarousel {
                embeddedBody
            } else if isCarouselExpanded {
                carouselExpandedBody
            } else {
                fullScreenBody
            }
        }
        .task(id: AvailabilityRequest(gameId: game.id, revision: availabilityRevision, active: scenePhase == .active)) {
            guard !isEmbeddedCarousel, scenePhase == .active else { return }
            await refreshAvailability()
            if authManager.session?.provider.isNvidiaDirect == true {
                await refreshInstallToPlayInfo()
            }
        }
        .onChange(of: isSelectedGameUnavailable) { _, unavailable in
            if unavailable, focusedElement == .play {
                focusedElement = .favorite
            }
        }
    }

    private func refreshAvailability() async {
        let requestID = UUID()
        availabilityRequestID = requestID
        availabilityLoading = true
        defer {
            if availabilityRequestID == requestID {
                availabilityLoading = false
            }
        }
        do {
            let result = try await viewModel.fetchGameAvailability(for: game, authManager: authManager)
            try Task.checkCancellation()
            availabilityByVariant = result
            didLoadAvailability = true
            availabilityFailed = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            availabilityFailed = true
        }
    }

    private func refreshInstallToPlayInfo() async {
        guard !Task.isCancelled else { return }
        installToPlayInfoFailed = false
        installToPlayInfoLoading = true
        defer {
            if !Task.isCancelled {
                installToPlayInfoLoading = false
            }
        }
        do {
            let updated = try await viewModel.fetchGameLaunchInfo(for: game, authManager: authManager)
            try Task.checkCancellation()
            if var updated {
                if updated.playType == nil || updated.playType == .unknown {
                    updated.playType = effectiveGame.playType
                }
                installToPlayInfo = updated
            } else {
                installToPlayInfoFailed = isInstallToPlay
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            installToPlayInfoFailed = isInstallToPlay
        }
    }

    private var fullScreenBody: some View {
        ZStack {
            GameDetailBackground(game: game, blurred: backgroundBlurred)
            exitFocusCatcher(action: dismissFullScreen)

            ScrollViewReader { proxy in
                detailScrollContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .onChange(of: focusedElement) { _, focus in
                        handleFocusChange(focus, proxy: proxy)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(appeared && !dismissing ? 1 : 0)
            .offset(y: appeared && !dismissing ? 0 : 40)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: appeared)
            .animation(reduceMotion ? nil : .easeIn(duration: 0.28), value: dismissing)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(reduceMotion ? nil : .default) {
                appeared = true
            }
        }
        .defaultFocus($focusedElement, preferredFocusTarget)
        .onExitCommand {
            dismissFullScreen()
        }
        .fullScreenCover(isPresented: $showFullDescription) {
            if let desc = game.longDescription {
                FullDescriptionView(description: desc)
            }
        }
        .fullScreenCover(isPresented: $showFullDetails) {
            FullDetailsView(title: game.title, items: detailItems)
        }
    }

    private var embeddedBody: some View {
        ZStack {
            if rendersBackground {
                GameDetailBackground(game: game, blurred: false)
            }

            detailScrollContent
                .scrollDisabled(true)
                .allowsHitTesting(false)
                .padding(.top, 36)
        }
    }

    private var carouselExpandedBody: some View {
        ZStack {
            GameDetailBackground(game: game, blurred: backgroundBlurred)

            // Invisible focus catcher: guarantees that this subtree always has
            // a focused descendant on tvOS, so onExitCommand below always fires
            // (Menu/back), regardless of whether the hero buttons exist or are
            // laid out yet.
            exitFocusCatcher { onCollapse?() }

            ScrollViewReader { proxy in
                detailScrollContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .onChange(of: focusedElement) { _, focus in
                        handleFocusChange(focus, proxy: proxy)
                    }
            }
        }
        .ignoresSafeArea()
        .defaultFocus($focusedElement, preferredFocusTarget)
        .onExitCommand {
            onCollapse?()
        }
        .fullScreenCover(isPresented: $showFullDescription) {
            if let desc = game.longDescription {
                FullDescriptionView(description: desc)
            }
        }
        .fullScreenCover(isPresented: $showFullDetails) {
            FullDetailsView(title: game.title, items: detailItems)
        }
    }

    private func exitFocusCatcher(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Color.clear.frame(width: 1, height: 1)
        }
        .buttonStyle(.plain)
        .focused($focusedElement, equals: .exitCatcher)
        .focusEffectDisabled()
        .opacity(0.001)
        .accessibilityHidden(true)
    }

    private func handleFocusChange(_ focus: DetailFocus?, proxy: ScrollViewProxy) {
        switch focus {
        case .play, .favorite, .availability, .variant:
            backgroundBlurred = false
            withAnimation(reduceMotion ? nil : .smooth) {
                proxy.scrollTo("hero", anchor: .top)
            }
        case .about, .details:
            backgroundBlurred = true
            withAnimation(reduceMotion ? nil : .smooth) {
                proxy.scrollTo("detail", anchor: .top)
            }
        case .exitCatcher, nil:
            break
        }
    }

    private func dismissFullScreen() {
        guard !dismissing else { return }
        if reduceMotion {
            dismiss()
            return
        }
        withAnimation { dismissing = true }
        Task {
            try? await Task.sleep(for: .milliseconds(280))
            dismiss()
        }
    }

    private var detailScrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection
                    .id("hero")

                VStack(alignment: .leading, spacing: 32) {
                    Text(game.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .opacity(backgroundBlurred ? 1 : 0)
                        .offset(y: backgroundBlurred ? 0 : 30)
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.35).delay(0.1),
                            value: backgroundBlurred
                        )

                    if !game.screenshots.isEmpty {
                        screenshotsRow
                    }
                    if let desc = game.longDescription, !desc.isEmpty {
                        aboutPanel(desc)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 60)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("detail")

                infoGrid
                    .padding(.horizontal, 80)
                    .padding(.vertical, 60)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.55))
            }
        }
    }

    // MARK: Hero section

    private var heroSection: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 60) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(game.title)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4)

                    genreLine
                    subscriptionLabels
                    installToPlayNotice

                    if let desc = game.longDescription, !desc.isEmpty {
                        Text(desc)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(3)
                            .frame(maxWidth: 560, alignment: .leading)
                    }

                    if effectiveGame.isInLibrary {
                        Label("In Library", systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Text(L10n.text("not_in_cloud_library"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    availabilityNotice

                    if effectiveGame.isInLibrary {
                        HStack(spacing: 16) {
                            Button {
                                onPlay(viewModel.gameWithPreferredStore(effectiveGame))
                            } label: {
                                Label(
                                    playActionTitle,
                                    systemImage: isInstallToPlay && selectedInstallVariant?.isInstalled != true
                                        ? "arrow.down.circle.fill"
                                        : "play.fill"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(isSelectedGameUnavailable)
                            .focused($focusedElement, equals: .play)

                            let isFav = viewModel.favoriteIds.contains(game.id)
                            Button {
                                viewModel.toggleFavorite(game.id)
                            } label: {
                                Label(
                                    isFav ? "Remove from Favorites" : "Add to Favorites",
                                    systemImage: isFav ? "star.fill" : "star"
                                )
                            }
                            .buttonStyle(.bordered)
                            .focused($focusedElement, equals: .favorite)
                        }
                        .allowsHitTesting(!isEmbeddedCarousel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                rightColumn.frame(width: 240)
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 80)
        }
        .containerRelativeFrame(.vertical)
        .frame(maxWidth: .infinity)
    }

    // MARK: Screenshots

    @ViewBuilder
    private var availabilityNotice: some View {
        if let availability = selectedAvailability, availability.isUnavailable {
            GFNGameAvailabilityNotice(availability: availability)
        }
        if availabilityFailed {
            Text(L10n.text("gfn_game_status_failed"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if !isEmbeddedCarousel,
           selectedAvailability?.isUnavailable == true || availabilityFailed || installToPlayInfoFailed
        {
            Button {
                availabilityRevision += 1
            } label: {
                Label(L10n.text("gfn_game_check_status"), systemImage: "arrow.clockwise")
            }
            .disabled(availabilityLoading || installToPlayInfoLoading)
            .focused($focusedElement, equals: .availability)
        }
    }

    private var screenshotsRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Screenshots")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(Array(game.screenshots.enumerated()), id: \.offset) { _, url in
                        Button {} label: {
                            SharedArtworkImage(
                                urlString: url,
                                maxPixelSize: ArtworkImagePipeline.screenshotPixelSize
                            )
                            .frame(width: 426, height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.card)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
    }

    // MARK: Info grid

    @ViewBuilder
    private var infoGrid: some View {
        if !detailItems.isEmpty {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Details")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)

                    Button {
                        showFullDetails = true
                    } label: {
                        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 20) {
                            ForEach(detailItems, id: \.0) { label, value in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(label.uppercased())
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .kerning(1)
                                    Text(value)
                                        .font(.callout)
                                        .foregroundStyle(.white.opacity(0.9))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(PassthroughButtonStyle())
                    .focused($focusedElement, equals: .details)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear.frame(maxWidth: .infinity)
                Color.clear.frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: À propos panel

    private func aboutPanel(_ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Button {
                showFullDescription = true
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(game.title).font(.callout.weight(.semibold)).lineLimit(1)
                    let genres = game.genreItems
                    if !genres.isEmpty {
                        Text(genres.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    HStack { Spacer(); Text("+").font(.title2.weight(.thin)).foregroundStyle(.secondary) }
                }
                .padding(24)
                .frame(maxWidth: 600, alignment: .leading)
            }
            .buttonStyle(.card)
            .focused($focusedElement, equals: .about)
        }
    }

    // MARK: Genre line

    @ViewBuilder
    private var genreLine: some View {
        let items = game.genreItems
        if !items.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, label in
                    if idx > 0 {
                        Text("  ·  ").foregroundStyle(.white.opacity(0.45)).font(.callout)
                    }
                    Text(label).font(.callout).foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }

    // MARK: Right column

    @ViewBuilder
    private var installToPlayNotice: some View {
        if isInstallToPlay {
            VStack(alignment: .leading, spacing: 6) {
                Label(L10n.text("install_to_play"), systemImage: "arrow.down.circle")
                    .font(.callout.weight(.semibold))
                if let size = selectedInstallVariant?.minimumSizeInBytes, size > 0 {
                    Text(L10n.format(
                        "install_to_play_minimum_size",
                        ByteCountFormatter.string(fromByteCount: size, countStyle: .binary)
                    ))
                }
                if !installToPlayInfoLoading, !installToPlayInfoFailed,
                   installToPlayInfo?.playabilityState == "UNPLAYABLE_DUE_TO_UPGRADE"
                {
                    if let tier = installToPlayInfo?.minimumMembershipTierLabel, !tier.isEmpty {
                        Text(L10n.format("install_to_play_requires_membership", tier))
                    } else {
                        Text(L10n.text("not_eligible"))
                    }
                }
                if viewModel.subscription?.cloudStorage?.isPersistent != true {
                    Text(L10n.text("install_to_play_session_warning"))
                }
                if selectedInstallVariant?.cloudSaveSupported == false {
                    Text(L10n.text("install_to_play_save_warning"))
                }
                if installToPlayInfoLoading {
                    Text(L10n.text("install_to_play_checking"))
                } else if installToPlayInfoFailed {
                    Text(L10n.text("install_to_play_status_failed"))
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 560, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("game-install-to-play")
        }
    }

    private var subscriptionLabels: some View {
        let variants = effectiveGame.isInLibrary
            ? Array(viewModel.gameWithPreferredStore(effectiveGame).variants.prefix(1))
            : effectiveGame.variants
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(variants, id: \.id) { variant in
                if let subscriptions = variant.subscriptions, !subscriptions.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(variant.storeName)
                            .font(.caption.weight(.semibold))
                        Text(L10n.format(
                            "available_with_subscription",
                            subscriptions.map(\.label).joined(separator: ", ")
                        ))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("game-subscriptions-\(variant.id)")
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var rightColumn: some View {
        VStack(alignment: .trailing, spacing: 14) {
            if let dev = game.developer {
                rightInfo("Developer", dev)
            }
            if let pub = game.publisher, pub != game.developer {
                rightInfo("Publisher", pub)
            }
            if let rating = game.contentRating {
                rightInfo("Rating", rating)
            }
            if effectiveGame.variants.count > 1, effectiveGame.isInLibrary {
                Divider()
                    .overlay(Color.white.opacity(0.35))
                    .frame(width: 200)
                variantPicker
            }
        }
    }

    private func rightInfo(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .kerning(1)
            Text(value)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.trailing)
        }
    }

    private var variantPicker: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text("LAUNCH VIA")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .kerning(1)
            ForEach(effectiveGame.variants, id: \.id) { variant in
                let isSelected = viewModel.gameWithPreferredStore(effectiveGame).variants.first?.id == variant.id
                Button {
                    viewModel.setPreferredStore(gameId: game.id, variantId: variant.id)
                } label: {
                    HStack(spacing: 6) {
                        if isSelected {
                            Image(systemName: "checkmark").font(.caption.weight(.bold))
                        }
                        Text(variant.storeName)
                            .font(.callout.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(
                        focusedElement == .variant(variant.id) ? .black : (isSelected ? .white : .white.opacity(0.55))
                    )
                }
                .buttonStyle(.plain)
                .focused($focusedElement, equals: .variant(variant.id))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

private struct GFNGameAvailabilityNotice: View {
    let availability: GFNGameAvailability

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let key = availability.titleKey {
                Label(L10n.text(key), systemImage: "wrench.and.screwdriver")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if let key = availability.messageKey {
                Text(L10n.text(key))
                    .font(.callout)
            }
            if let deadline = availability.estimatedEndDate {
                let countdown = GFNSessionCountdown(endsAt: deadline)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(countdown.secondsRemaining(at: context.date) > 0
                        ? L10n.format("gfn_game_estimated_remaining", countdown.formattedTimeRemaining(at: context.date))
                        : L10n.text("gfn_game_eta_elapsed"))
                        .monospacedDigit()
                }
            } else {
                Text(L10n.text("gfn_game_eta_unavailable"))
            }
        }
        .font(.callout)
        .foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: 560, alignment: .leading)
    }
}

// MARK: - Shared background

struct GameDetailBackground: View {
    let game: GameInfo
    let blurred: Bool

    var body: some View {
        ZStack {
            SharedArtworkImage(
                urlString: game.heroBannerUrl.flatMap(URL.init) == nil
                    ? game.boxArtUrl
                    : game.heroBannerUrl,
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .blur(radius: blurred ? 20 : 0)
            .animation(.easeInOut(duration: 0.4), value: blurred)

            GameDetailArtworkScrim()
        }
        .ignoresSafeArea()
    }
}

struct GameDetailArtworkScrim: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.92), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.35),
                    .init(color: .clear, location: 0.7),
                ],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.55),
                    .init(color: .black.opacity(0.2), location: 0.72),
                    .init(color: .black.opacity(0.74), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Full Description Sheet

struct FullDescriptionView: View {
    let description: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(1400, max(proxy.size.width - 120, 320))
            let cardHeight = min(920, max(proxy.size.height - 96, 320))
            let cardColor = Color(white: 0.12)

            ZStack {
                Color.black.opacity(0.75).ignoresSafeArea()

                ScrollableText(text: description)
                    .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
                    .background(cardColor)
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [cardColor.opacity(0.95), cardColor.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 64)
                        .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            colors: [cardColor.opacity(0), cardColor],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 88)
                        .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(color: .black.opacity(0.5), radius: 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 60)
                    .padding(.vertical, 48)
            }
        }
        .onExitCommand { dismiss() }
    }
}

struct FullDetailsView: View {
    let title: String
    let items: [(String, String)]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(980, max(proxy.size.width - 120, 320))
            let cardHeight = min(820, max(proxy.size.height - 96, 320))
            let cardColor = Color(white: 0.12)

            ZStack {
                Color.black.opacity(0.75).ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 28) {
                        Text(title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)

                        ForEach(items, id: \.0) { label, value in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(label.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .kerning(1)
                                Text(value)
                                    .font(.body)
                                    .foregroundStyle(.white.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 80)
                    .padding(.top, 72)
                    .padding(.bottom, 96)
                }
                .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
                .background(cardColor)
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [cardColor.opacity(0.95), cardColor.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 64)
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [cardColor.opacity(0), cardColor],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 88)
                    .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.5), radius: 30)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 60)
                .padding(.vertical, 48)
            }
        }
        .onExitCommand { dismiss() }
    }
}
