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

    @Environment(GamesViewModel.self) var viewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentId: String?
    @State private var expandedGame: GameInfo?
    @FocusState private var focusedId: String?

    private var expandAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.72)
    }

    private var navigationAnimation: Animation? {
        reduceMotion ? nil : .interactiveSpring(response: 0.35, dampingFraction: 0.8)
    }

    private var positionedGames: [PositionedGame] {
        guard let currentId,
              let currentIndex = request.games.firstIndex(where: { $0.id == currentId })
        else { return [] }

        let lowerBound = max(request.games.startIndex, currentIndex - 1)
        let upperBound = min(request.games.index(before: request.games.endIndex), currentIndex + 1)

        return (lowerBound ... upperBound).map { index in
            PositionedGame(
                game: request.games[index],
                distance: index - currentIndex
            )
        }
    }

    private func collapseExpandedCard() {
        withAnimation(expandAnimation) {
            expandedGame = nil
        }
        Task { @MainActor in
            await Task.yield()
            focusedId = currentId
        }
    }

    private func moveCurrentCard(by offset: Int) {
        guard !request.games.isEmpty,
              expandedGame == nil,
              let currentIndex = request.games.firstIndex(where: { $0.id == currentId })
        else { return }

        let destinationIndex = min(
            max(currentIndex + offset, request.games.startIndex),
            request.games.index(before: request.games.endIndex)
        )
        let destinationId = request.games[destinationIndex].id

        guard destinationId != currentId else {
            focusedId = currentId
            return
        }

        withAnimation(navigationAnimation) {
            currentId = destinationId
        }
        focusedId = destinationId
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        guard expandedGame == nil else { return }

        switch direction {
        case .left:
            moveCurrentCard(by: -1)
        case .right:
            moveCurrentCard(by: 1)
        case .down:
            expandedGame = request.games.first(where: { $0.id == currentId })
        default:
            break
        }
    }

    init(request: CarouselRequest, onPlay: @escaping (GameInfo) -> Void, onDismiss: @escaping (String?) -> Void) {
        self.request = request
        self.onPlay = onPlay
        self.onDismiss = onDismiss
        _currentId = State(initialValue: request.startId)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.82).ignoresSafeArea()

                // Accordion layout : current 80%, neighbours 10% each side
                // ZStack centres items → offset x = dist * (0.40W + 0.05W) = dist * 0.45W
                ZStack(alignment: .center) {
                    ForEach(positionedGames) { positionedGame in
                        let game = positionedGame.game
                        let dist = positionedGame.distance
                        let isExpanded = expandedGame?.id == game.id
                        CarouselCard(
                            game: game,
                            focusedId: $focusedId,
                            onExpand: {
                                withAnimation(expandAnimation) {
                                    expandedGame = game
                                }
                            },
                            onPlay: { g in onDismiss(currentId); onPlay(g) },
                            onCollapseExpanded: collapseExpandedCard,
                            isCurrent: game.id == currentId,
                            isExpanded: isExpanded,
                            imageAlignment: dist < 0 ? .leading : (dist > 0 ? .trailing : .center)
                        )
                        .frame(
                            width: isExpanded ? geo.size.width : (dist == 0 ? geo.size.width * 0.90 : geo.size.width * 0.10),
                            height: isExpanded ? geo.size.height : geo.size.height * 0.92,
                            alignment: dist < 0 ? .leading : (dist > 0 ? .trailing : .center)
                        )
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: isExpanded ? 0 : 20, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: isExpanded ? 0 : 20))
                        .offset(x: isExpanded ? 0 : CGFloat(dist) * (geo.size.width * 0.50 + 20))
                        .zIndex(isExpanded ? 10 : (dist == 0 ? 1 : 0))
                        .opacity(expandedGame == nil || isExpanded ? 1 : 0)
                        .animation(expandAnimation, value: expandedGame?.id)
                        .animation(navigationAnimation, value: currentId)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.top, expandedGame == nil ? geo.size.height * 0.08 : 0)
            }
        }
        .ignoresSafeArea()
        .defaultFocus($focusedId, request.startId)
        .onMoveCommand(perform: handleMoveCommand)
        .handlesCarouselControllerNavigation(
            isEnabled: expandedGame == nil,
            onPrevious: { moveCurrentCard(by: -1) },
            onNext: { moveCurrentCard(by: 1) }
        )
        .onExitCommand {
            if expandedGame != nil {
                collapseExpandedCard()
            } else {
                onDismiss(currentId)
            }
        }
    }

    private struct PositionedGame: Identifiable {
        let game: GameInfo
        let distance: Int

        var id: String {
            game.id
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
