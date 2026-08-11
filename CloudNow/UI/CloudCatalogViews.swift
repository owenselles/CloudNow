import SwiftUI

struct CloudCatalogCardBadge {
    let title: String
    let systemImage: String?
    let foregroundColor: Color
    let backgroundColor: Color
}

/// Provider-neutral CloudNow card chrome. Providers supply only presentation
/// data; account state and launch behavior stay outside this view.
struct CloudCatalogCardLabel: View {
    let title: String
    let artworkURL: String?
    var heroArtworkURL: String?
    var badge: CloudCatalogCardBadge?
    var networkCachePolicy: ArtworkNetworkCachePolicy = .shared

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SharedArtworkImage(
                urlString: artworkURL,
                maxPixelSize: ArtworkImagePipeline.boxArtPixelSize,
                networkCachePolicy: networkCachePolicy
            )
            .aspectRatio(2 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            LinearGradient(
                colors: [.black.opacity(0.7), .clear],
                startPoint: .bottom,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(10)

            if let badge {
                Label {
                    Text(badge.title)
                } icon: {
                    if let systemImage = badge.systemImage {
                        Image(systemName: systemImage)
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(badge.foregroundColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(badge.backgroundColor, in: Capsule())
                .padding(8)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topTrailing
                )
            }
        }
        .prefetchHeroArtOnFocus(heroArtworkURL)
    }
}

/// Shared Continue Playing chrome. Providers supply only the artwork, expiry
/// and resume action while retaining their own server-session lifecycle.
struct CloudResumableSessionBanner: View {
    let title: String
    let artworkURL: String?
    let expiresAt: Date
    var isResumeEnabled = true
    let onResume: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SharedArtworkImage(
                urlString: artworkURL,
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
            .frame(maxWidth: .infinity)
            .frame(height: 420)
            .clipped()
            .overlay(
                LinearGradient(
                    colors: [.black.opacity(0.8), .clear, .black.opacity(0.4)],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text(title)
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                        Text(L10n.text("session_active"))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.green, in: Capsule())
                    }
                    CloudSessionExpiryCountdownView(expiresAt: expiresAt)
                    Button(action: onResume) {
                        Label(
                            L10n.text("rejoin_session"),
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!isResumeEnabled)
                }
                Spacer()
            }
            .padding(60)
        }
        .focusSection()
        .accessibilityIdentifier("continue-playing")
    }
}

/// Keeps the once-per-second expiry update inside the single text leaf.
struct CloudSessionExpiryCountdownView: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let secondsRemaining = max(
                0,
                Int(expiresAt.timeIntervalSince(context.date))
            )
            Text(L10n.format("session_expires_in", secondsRemaining))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// Shared adaptive collection layout used by provider library/catalog screens.
struct CloudCatalogGrid<
    Item: Identifiable,
    Header: View,
    CardLabel: View,
    MenuContent: View
>: View where Item.ID == String {
    let items: [Item]
    var focusedId: FocusState<String?>.Binding
    var emptyActionFocus: FocusState<Bool>.Binding?
    var pageSize: Int?
    var loadMoreDistance = 12
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void
    let onSelect: (Item) -> Void
    let onItemVisible: (Item, Int) -> Void
    var accessibilityIdentifier: (Item) -> String = { $0.id }
    @ViewBuilder let header: Header
    @ViewBuilder let cardLabel: (Item) -> CardLabel
    @ViewBuilder let menuContent: (Item) -> MenuContent

    @State private var visibleItemCount = 0

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40),
    ]

    private var renderedItemCount: Int {
        guard let pageSize else { return items.count }
        return min(items.count, max(visibleItemCount, pageSize))
    }

    private var contentIdentity: [String] {
        [String(items.count)]
            + items.prefix(4).map(\.id)
            + items.suffix(4).map(\.id)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                if items.isEmpty {
                    FilteredGamesEmptyView(
                        hasActiveFilters: hasActiveFilters,
                        onClearFilters: onClearFilters,
                        clearFiltersFocus: emptyActionFocus
                    )
                    .frame(minHeight: 620)
                } else {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(
                            items.prefix(renderedItemCount).enumerated(),
                            id: \.element.id
                        ) { index, item in
                            Button { onSelect(item) } label: {
                                cardLabel(item)
                            }
                            .aspectRatio(2 / 3, contentMode: .fit)
                            .buttonStyle(.card)
                            .focused(focusedId, equals: item.id)
                            .accessibilityIdentifier(
                                accessibilityIdentifier(item)
                            )
                            .contextMenu {
                                menuContent(item)
                            }
                            .onAppear {
                                onItemVisible(item, index)
                                loadNextPageIfNeeded(index: index)
                            }
                        }
                    }
                    .padding(60)
                    .focusSection()
                }
            }
        }
        .onChange(of: contentIdentity) {
            visibleItemCount = pageSize ?? 0
        }
    }

    private func loadNextPageIfNeeded(index: Int) {
        guard let pageSize, renderedItemCount < items.count else { return }
        let threshold = max(0, renderedItemCount - max(loadMoreDistance, 12))
        guard index >= threshold else { return }
        visibleItemCount = min(items.count, renderedItemCount + pageSize)
    }
}

struct CloudCatalogLoadingGrid: View {
    var itemCount = 12

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 40) {
                ForEach(0 ..< itemCount, id: \.self) { _ in
                    GameCardSkeleton()
                }
            }
            .padding(60)
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("catalog-loading-grid")
    }
}

/// Shared CloudNow Home placeholder used when a provider has no favorites or
/// recently played games yet.
struct CloudCatalogHomeEmptyState: View {
    var message = L10n.text("empty_home_message")
    var actionTitle: String?
    var action: (() -> Void)?
    var actionFocus: FocusState<Bool>.Binding?

    init(
        message: String = L10n.text("empty_home_message"),
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        actionFocus: FocusState<Bool>.Binding? = nil
    ) {
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.actionFocus = actionFocus
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(L10n.text("nothing_here_yet"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            if let actionTitle, let action {
                if let actionFocus {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .focused(actionFocus)
                } else {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct CloudCatalogHeroBanner: View {
    let artworkURL: String?
    var prefetchArtworkURL: String?
    var networkCachePolicy: ArtworkNetworkCachePolicy = .shared
    var artworkContentMode: ContentMode = .fill
    var artworkAlignment: Alignment = .center
    let actionTitle: String
    let actionSystemImage: String
    var isActionEnabled = true
    var actionTint: Color = .green
    var actionFocus: FocusState<Bool>.Binding?
    let action: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            SharedArtworkImage(
                urlString: artworkURL,
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize,
                contentMode: artworkContentMode,
                networkCachePolicy: networkCachePolicy
            )
            .frame(maxWidth: .infinity)
            .frame(height: 420, alignment: artworkAlignment)
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0.85), .black.opacity(0.5), .clear],
                startPoint: .bottom,
                endPoint: UnitPoint(x: 0.5, y: 0.55)
            )

            HStack {
                if let actionFocus {
                    actionButton
                        .focused(actionFocus)
                } else {
                    actionButton
                }
                Spacer()
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 60)
        .focusSection()
    }

    private var actionButton: some View {
        Button(action: action) {
            Label(actionTitle, systemImage: actionSystemImage)
                .prefetchHeroArtOnFocus(
                    prefetchArtworkURL ?? artworkURL
                )
        }
        .buttonStyle(.borderedProminent)
        .tint(actionTint)
        .disabled(!isActionEnabled)
    }
}
