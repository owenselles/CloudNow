import SwiftUI

// MARK: - Request model

struct CarouselRequest: Identifiable {
    let id = UUID()
    let games: [GameInfo]
    let startId: String
}

// MARK: - GameCarouselView

struct GameCarouselView: View {
    let request: CarouselRequest
    let onPlay: (GameInfo) -> Void
    let onDismiss: (String?) -> Void

    var body: some View {
        CloudGameCarouselView(
            items: request.games,
            startID: request.startId,
            onDismiss: onDismiss
        ) { context in
            CarouselCard(
                game: context.item,
                focusedId: context.focusedID,
                onExpand: context.expand,
                onPlay: { game in
                    onDismiss(context.currentID)
                    onPlay(game)
                },
                onCollapseExpanded: context.collapse,
                isCurrent: context.isCurrent,
                isExpanded: context.isExpanded,
                imageAlignment: context.imageAlignment
            )
        }
    }
}

// MARK: - Shared carousel engine

/// Provider-neutral state and actions for one card rendered by ``CloudGameCarouselView``.
struct CloudGameCarouselCardContext<Item: Identifiable> {
    let item: Item
    let focusedID: FocusState<Item.ID?>.Binding
    let currentID: Item.ID?
    let expandedID: Item.ID?
    let imageAlignment: HorizontalAlignment
    let expand: () -> Void
    let collapse: () -> Void

    var isCurrent: Bool {
        item.id == currentID
    }

    var isExpanded: Bool {
        item.id == expandedID
    }
}

/// CloudNow's shared full-screen carousel interaction and layout engine.
///
/// Providers supply their own card content while this view owns neighbour positioning,
/// focus, expand/collapse, remote movement, controller shoulder navigation, and dismissal.
struct CloudGameCarouselView<Item: Identifiable, Card: View>: View {
    let items: [Item]
    let startID: Item.ID
    let onDismiss: (Item.ID?) -> Void
    let card: (CloudGameCarouselCardContext<Item>) -> Card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentID: Item.ID?
    @State private var expandedID: Item.ID?
    @FocusState private var focusedID: Item.ID?

    private var expandAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.72)
    }

    private var navigationAnimation: Animation? {
        reduceMotion ? nil : .interactiveSpring(response: 0.35, dampingFraction: 0.8)
    }

    private var positionedItems: [PositionedItem] {
        guard let currentID,
              let currentIndex = items.firstIndex(where: { $0.id == currentID })
        else { return [] }

        let lowerBound = max(items.startIndex, currentIndex - 1)
        let upperBound = min(items.index(before: items.endIndex), currentIndex + 1)

        return (lowerBound ... upperBound).map { index in
            PositionedItem(
                item: items[index],
                distance: index - currentIndex
            )
        }
    }

    init(
        items: [Item],
        startID: Item.ID,
        onDismiss: @escaping (Item.ID?) -> Void,
        @ViewBuilder card: @escaping (CloudGameCarouselCardContext<Item>) -> Card
    ) {
        self.items = items
        self.startID = startID
        self.onDismiss = onDismiss
        self.card = card
        _currentID = State(initialValue: startID)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.82).ignoresSafeArea()

                // Accordion layout : current 80%, neighbours 10% each side
                // ZStack centres items → offset x = dist * (0.40W + 0.05W) = dist * 0.45W
                ZStack(alignment: .center) {
                    ForEach(positionedItems) { positionedItem in
                        let distance = positionedItem.distance
                        let context = CloudGameCarouselCardContext(
                            item: positionedItem.item,
                            focusedID: $focusedID,
                            currentID: currentID,
                            expandedID: expandedID,
                            imageAlignment: Self.imageAlignment(for: distance),
                            expand: { expand(positionedItem.item.id) },
                            collapse: collapseExpandedCard
                        )

                        card(context)
                            .frame(
                                width: context.isExpanded ? geo.size.width : (distance == 0 ? geo.size.width * 0.90 : geo.size.width * 0.10),
                                height: context.isExpanded ? geo.size.height : geo.size.height * 0.92,
                                alignment: Self.alignment(for: distance)
                            )
                            .clipShape(Self.cardShape(isExpanded: context.isExpanded))
                            .offset(x: context.isExpanded ? 0 : CGFloat(distance) * (geo.size.width * 0.50 + 20))
                            .zIndex(context.isExpanded ? 10 : (distance == 0 ? 1 : 0))
                            .opacity(expandedID == nil || context.isExpanded ? 1 : 0)
                            .animation(expandAnimation, value: expandedID)
                            .animation(navigationAnimation, value: currentID)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.top, expandedID == nil ? geo.size.height * 0.08 : 0)
            }
        }
        .ignoresSafeArea()
        .defaultFocus($focusedID, startID)
        .onMoveCommand(perform: handleMoveCommand)
        .handlesCarouselControllerNavigation(
            isEnabled: expandedID == nil,
            onPrevious: { moveCurrentCard(by: -1) },
            onNext: { moveCurrentCard(by: 1) }
        )
        .onExitCommand {
            if expandedID != nil {
                collapseExpandedCard()
            } else {
                onDismiss(currentID)
            }
        }
    }

    private func expand(_ id: Item.ID) {
        withAnimation(expandAnimation) {
            expandedID = id
        }
    }

    private func collapseExpandedCard() {
        withAnimation(expandAnimation) {
            expandedID = nil
        }
        Task { @MainActor in
            await Task.yield()
            focusedID = currentID
        }
    }

    private func moveCurrentCard(by offset: Int) {
        guard !items.isEmpty,
              expandedID == nil,
              let currentIndex = items.firstIndex(where: { $0.id == currentID })
        else { return }

        let destinationIndex = min(
            max(currentIndex + offset, items.startIndex),
            items.index(before: items.endIndex)
        )
        let destinationID = items[destinationIndex].id

        guard destinationID != currentID else {
            focusedID = currentID
            return
        }

        withAnimation(navigationAnimation) {
            currentID = destinationID
        }
        focusedID = destinationID
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        guard expandedID == nil else { return }

        switch direction {
        case .left:
            moveCurrentCard(by: -1)
        case .right:
            moveCurrentCard(by: 1)
        case .down:
            expandedID = items.first(where: { $0.id == currentID })?.id
        default:
            break
        }
    }

    private static func imageAlignment(for distance: Int) -> HorizontalAlignment {
        if distance < 0 {
            return .leading
        }
        if distance > 0 {
            return .trailing
        }
        return .center
    }

    private static func alignment(for distance: Int) -> Alignment {
        Alignment(horizontal: imageAlignment(for: distance), vertical: .center)
    }

    private static func cardShape(isExpanded: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: isExpanded ? 0 : 20,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: isExpanded ? 0 : 20
        )
    }

    private struct PositionedItem: Identifiable {
        let item: Item
        let distance: Int

        var id: Item.ID {
            item.id
        }
    }
}

// MARK: - CarouselCard

private struct CarouselCard: View {
    let game: GameInfo
    var focusedId: FocusState<String?>.Binding
    let onExpand: () -> Void
    let onPlay: (GameInfo) -> Void
    let onCollapseExpanded: () -> Void
    let isCurrent: Bool
    let isExpanded: Bool
    let imageAlignment: HorizontalAlignment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showContent = false

    var body: some View {
        ZStack {
            cardBody

            if !isExpanded {
                Button { onExpand() } label: {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(PassthroughButtonStyle())
                .focusEffectDisabled()
                .focused(focusedId, equals: game.id)
                .accessibilityLabel(game.title)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .focusSection()
        .task(id: isCurrent) {
            showContent = false
            guard isCurrent else { return }
            if reduceMotion {
                showContent = true
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(360))
            } catch {
                return
            }
            showContent = true
        }
        .onChange(of: isExpanded) { _, newValue in
            if !newValue, isCurrent {
                showContent = true
            }
        }
    }

    private var cardBody: some View {
        ZStack(alignment: .bottomLeading) {
            if isExpanded {
                GameDetailView(
                    game: game,
                    onPlay: onPlay,
                    presentationStyle: .carouselExpanded,
                    onCollapse: onCollapseExpanded
                )
                .environment(viewModel)
            } else {
                carouselArtwork

                GameDetailArtworkScrim()
                    .opacity(isCurrent ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isCurrent)

                if isCurrent {
                    GameDetailView(
                        game: game,
                        onPlay: onPlay,
                        presentationStyle: .embeddedCarousel,
                        rendersBackground: false
                    )
                    .environment(viewModel)
                    .opacity(showContent ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: showContent)
                }
            }

            if !isExpanded {
                UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 20)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.65), location: 0),
                                .init(color: .white.opacity(0.25), location: 0.35),
                                .init(color: .clear, location: 0.65),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                    .allowsHitTesting(false)
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: isExpanded ? 0 : 20, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: isExpanded ? 0 : 20))
        .shadow(
            color: .black.opacity(isCurrent ? 0.5 : 0.15),
            radius: isCurrent ? 20 : 4,
            x: 0,
            y: isCurrent ? 10 : 2
        )
    }

    /// Keeps one artwork view alive while a card moves between neighbour and current positions.
    /// The detail scrim and content are overlays, so revealing metadata cannot reload or rescale
    /// the underlying image.
    private var carouselArtwork: some View {
        GeometryReader { geo in
            SharedArtworkImage(
                urlString: game.heroBannerUrl.flatMap(URL.init) == nil
                    ? game.boxArtUrl
                    : game.heroBannerUrl,
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
            .frame(height: geo.size.height)
            .frame(
                width: geo.size.width,
                alignment: Alignment(horizontal: imageAlignment, vertical: .center)
            )
            .clipped()
        }
    }

    @Environment(GamesViewModel.self) var viewModel
}
