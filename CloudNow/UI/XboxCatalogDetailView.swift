import SwiftUI

/// Xbox presentation adapter for CloudNow's existing detail experience.
/// Catalog/network state remains in ``XboxCatalogViewModel``; this view owns
/// only the focus and presentation behavior shared conceptually with GFN.
struct XboxCatalogDetailView: View {
    let item: XboxCatalogItem
    let route: XboxCloudTitleRoute
    let isInputAvailable: Bool
    let isFavorite: Bool
    let isLoadingDetail: Bool
    let detailLoadFailed: Bool
    let presentationStyle: ExpandedDetailPresentationStyle
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void
    let onRetryDetail: () -> Void
    let onCollapse: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showFullDescription = false
    @State private var showFullDetails = false
    @State private var backgroundBlurred = false
    @FocusState private var focusedElement: DetailFocus?

    private enum DetailFocus: Hashable {
        case play
        case favorite
        case retryDetail
        case about
        case details
        case exitCatcher
    }

    private var isEmbeddedCarousel: Bool {
        presentationStyle == .embeddedCarousel
    }

    private var isPlayable: Bool {
        route.isPlayable && isInputAvailable
    }

    private var preferredFocusTarget: DetailFocus {
        if isPlayable {
            return .play
        }
        if detailLoadFailed {
            return .retryDetail
        }
        if item.longDescription?.isEmpty == false {
            return .about
        }
        if !detailItems.isEmpty {
            return .details
        }
        return .favorite
    }

    private var detailItems: [(String, String)] {
        let inputTypes = item.supportedInputTypes
            .sorted { $0.rawValue < $1.rawValue }
            .map(localizedInputName)
            .joined(separator: ", ")
        return [
            item.contentRating.map { (L10n.text("rating"), $0) },
            item.developer.map { (L10n.text("developer"), $0) },
            item.publisher.flatMap {
                $0 == item.developer ? nil : (L10n.text("publisher"), $0)
            },
            item.genres.isEmpty
                ? nil
                : (L10n.text("genres"), item.genres.joined(separator: ", ")),
            inputTypes.isEmpty ? nil : (L10n.text("input"), inputTypes),
            (L10n.text("access"), accessDescription),
        ].compactMap { $0 }
    }

    var body: some View {
        if isEmbeddedCarousel {
            detailScrollContent
                .scrollDisabled(true)
                .allowsHitTesting(false)
                .padding(.top, 36)
        } else {
            expandedBody
        }
    }

    private var expandedBody: some View {
        ZStack {
            detailBackground
            exitFocusCatcher

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
        .onExitCommand(perform: onCollapse)
        .fullScreenCover(isPresented: $showFullDescription) {
            if let description = item.longDescription {
                FullDescriptionView(description: description)
            }
        }
        .fullScreenCover(isPresented: $showFullDetails) {
            FullDetailsView(title: item.title, items: detailItems)
        }
    }

    private var exitFocusCatcher: some View {
        Button(action: onCollapse) {
            Color.clear.frame(width: 1, height: 1)
        }
        .buttonStyle(.plain)
        .focused($focusedElement, equals: .exitCatcher)
        .focusEffectDisabled()
        .opacity(0.001)
        .accessibilityHidden(true)
    }

    private var detailBackground: some View {
        ZStack {
            SharedArtworkImage(
                urlString: item.heroArtworkURL?.absoluteString
                    ?? item.artworkURL?.absoluteString,
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .blur(radius: backgroundBlurred ? 20 : 0)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.4),
                value: backgroundBlurred
            )

            GameDetailArtworkScrim()
        }
        .ignoresSafeArea()
    }

    private var detailScrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection
                    .id("hero")

                VStack(alignment: .leading, spacing: 32) {
                    Text(item.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .opacity(backgroundBlurred ? 1 : 0)
                        .offset(y: backgroundBlurred ? 0 : 30)

                    if !item.screenshotURLs.isEmpty {
                        screenshotsRow
                    }
                    if let description = item.longDescription,
                       !description.isEmpty
                    {
                        aboutPanel(description)
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

    private var heroSection: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            HStack(alignment: .bottom, spacing: 60) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.title)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4)

                    genreLine

                    if let description = item.longDescription,
                       !description.isEmpty
                    {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(3)
                            .frame(maxWidth: 560, alignment: .leading)
                    } else if isLoadingDetail {
                        ProgressView()
                            .tint(.white)
                    }

                    Label(accessDescription, systemImage: accessSystemImage)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(isPlayable ? .green : .secondary)

                    HStack(spacing: 16) {
                        Button(action: onPlay) {
                            Label(
                                isPlayable
                                    ? L10n.text("play")
                                    : unavailablePlayTitle,
                                systemImage: isPlayable
                                    ? "play.fill"
                                    : "lock.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isPlayable ? .green : .gray)
                        .disabled(!isPlayable)
                        .focused($focusedElement, equals: .play)
                        .accessibilityIdentifier("xbox-game.play.\(item.id)")

                        Button(action: onToggleFavorite) {
                            Label(
                                isFavorite
                                    ? L10n.text("remove_from_favorites")
                                    : L10n.text("add_to_favorites"),
                                systemImage: isFavorite ? "star.fill" : "star"
                            )
                        }
                        .buttonStyle(.bordered)
                        .focused($focusedElement, equals: .favorite)

                        if detailLoadFailed {
                            Button(action: onRetryDetail) {
                                Label(
                                    L10n.text("try_again"),
                                    systemImage: "arrow.clockwise"
                                )
                            }
                            .buttonStyle(.bordered)
                            .focused($focusedElement, equals: .retryDetail)
                            .accessibilityIdentifier(
                                "xbox-game.detail-retry.\(item.id)"
                            )
                        }
                    }
                    .allowsHitTesting(!isEmbeddedCarousel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                rightColumn
                    .frame(width: 240)
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 80)
        }
        .containerRelativeFrame(.vertical)
        .frame(maxWidth: .infinity)
    }

    private var screenshotsRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("screenshots"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(item.screenshotURLs, id: \.absoluteString) { url in
                        Button {} label: {
                            SharedArtworkImage(
                                urlString: url.absoluteString,
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

    private func aboutPanel(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("about"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            Button {
                showFullDescription = true
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if !item.genres.isEmpty {
                        Text(item.genres.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Spacer()
                        Text("+")
                            .font(.title2.weight(.thin))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: 600, alignment: .leading)
            }
            .buttonStyle(.card)
            .focused($focusedElement, equals: .about)
        }
    }

    @ViewBuilder
    private var infoGrid: some View {
        if !detailItems.isEmpty {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("details"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)

                    Button {
                        showFullDetails = true
                    } label: {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), alignment: .topLeading),
                            ],
                            alignment: .leading,
                            spacing: 20
                        ) {
                            ForEach(detailItems, id: \.0) { label, value in
                                detailValue(label: label, value: value)
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

    private func detailValue(label: String, value: String) -> some View {
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

    @ViewBuilder
    private var genreLine: some View {
        if !item.genres.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(item.genres.enumerated()), id: \.offset) {
                    index,
                    genre in
                    if index > 0 {
                        Text("  ·  ")
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Text(genre)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .font(.callout)
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .trailing, spacing: 14) {
            if let developer = item.developer {
                rightInfo(L10n.text("developer"), developer)
            }
            if let publisher = item.publisher,
               publisher != item.developer
            {
                rightInfo(L10n.text("publisher"), publisher)
            }
            if let rating = item.contentRating {
                rightInfo(L10n.text("rating"), rating)
            }
            if item.isOwned {
                rightInfo(L10n.text("access"), L10n.text("owned"))
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

    private var accessDescription: String {
        guard isInputAvailable else {
            return L10n.text("compatible_input_required")
        }
        if item.isOwned {
            return "\(L10n.text("owned")) · \(routeDescription)"
        }
        return routeDescription
    }

    private func localizedInputName(_ inputType: XboxCloudInputType) -> String {
        switch inputType {
        case .controller:
            L10n.text("controller")
        case .touch:
            L10n.text("touch")
        case .mouseAndKeyboard:
            L10n.text("keyboard_and_mouse")
        }
    }

    private var routeDescription: String {
        switch route.accessKind {
        case .standard:
            L10n.text("cloud_gaming_access")
        case .freeWithAds:
            if route.isPlayable {
                L10n.text("free_with_ads")
            } else {
                route.playabilityReason.label
            }
        }
    }

    private var accessSystemImage: String {
        if !isPlayable {
            return "lock.fill"
        }
        return route.accessKind == .freeWithAds
            ? "play.rectangle.on.rectangle"
            : "checkmark.circle.fill"
    }

    private var unavailablePlayTitle: String {
        guard isInputAvailable else {
            return L10n.text("compatible_input_required")
        }
        return route.playabilityReason.label
    }

    private func handleFocusChange(
        _ focus: DetailFocus?,
        proxy: ScrollViewProxy
    ) {
        switch focus {
        case .play, .favorite, .retryDetail:
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
}
