import SwiftUI

// MARK: - Request model

struct CarouselRequest: Identifiable {
    let id = UUID()
    let games: [GameInfo]
    let startId: String

    init(games: [GameInfo], startId: String) {
        self.startId = startId
        self.games = games
    }
}

// MARK: - GameCarouselView

struct GameCarouselView: View {
    let request: CarouselRequest
    let onPlay: (GameInfo) -> Void
    let onDismiss: (String?) -> Void

    @Environment(GamesViewModel.self) var viewModel
    @State private var currentId: String?
    @State private var expandedGame: GameInfo?
    @FocusState private var focusedId: String?

    private let expandAnimation = Animation.easeInOut(duration: 0.72)

    private func collapseExpandedCard() {
        withAnimation(expandAnimation) {
            expandedGame = nil
        }
        Task { @MainActor in
            focusedId = currentId
        }
    }

    init(request: CarouselRequest, onPlay: @escaping (GameInfo) -> Void, onDismiss: @escaping (String?) -> Void) {
        self.request = request
        self.onPlay = onPlay
        self.onDismiss = onDismiss
        self._currentId = State(initialValue: request.startId)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.82).ignoresSafeArea()

                // Accordion layout : current 80%, neighbours 10% each side
                // ZStack centres items → offset x = dist * (0.40W + 0.05W) = dist * 0.45W
                ZStack(alignment: .center) {
                    ForEach(request.games) { game in
                        let dist = distanceFromCurrent(game.id)
                        let isExpanded = expandedGame?.id == game.id
                        if abs(dist) <= 1 || isExpanded {
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
                                containerWidth: geo.size.width,
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
                            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.8), value: currentId)
                            .transition(.opacity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.top, expandedGame == nil ? geo.size.height * 0.08 : 0)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            Task { @MainActor in
                focusedId = request.startId
            }
        }
        .modifier(CarouselMoveCommandHandler(
            isEnabled: expandedGame == nil,
            games: request.games,
            currentId: $currentId,
            focusedId: $focusedId,
            expandedGame: $expandedGame
        ))
        .onExitCommand {
            if expandedGame != nil {
                collapseExpandedCard()
            } else {
                onDismiss(currentId)
            }
        }
    }

    private func distanceFromCurrent(_ gameId: String) -> Int {
        guard let ci = request.games.firstIndex(where: { $0.id == currentId }),
              let gi = request.games.firstIndex(where: { $0.id == gameId })
        else { return Int.max }
        return gi - ci
    }
}

// MARK: - CarouselCard

private struct CarouselMoveCommandHandler: ViewModifier {
    let isEnabled: Bool
    let games: [GameInfo]
    @Binding var currentId: String?
    var focusedId: FocusState<String?>.Binding
    @Binding var expandedGame: GameInfo?

    func body(content: Content) -> some View {
        if isEnabled {
            content.onMoveCommand { dir in
                guard let ci = games.firstIndex(where: { $0.id == currentId }) else { return }
                switch dir {
                case .left:
                    if ci == 0 {
                        focusedId.wrappedValue = currentId
                    } else {
                        let newId = games[ci - 1].id
                        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.8)) {
                            currentId = newId
                        }
                        focusedId.wrappedValue = newId
                    }
                case .right:
                    if ci == games.count - 1 {
                        focusedId.wrappedValue = currentId
                    } else {
                        let newId = games[ci + 1].id
                        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.8)) {
                            currentId = newId
                        }
                        focusedId.wrappedValue = newId
                    }
                case .down:
                    expandedGame = games.first(where: { $0.id == currentId })
                default:
                    break
                }
            }
        } else {
            content
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
    let containerWidth: CGFloat
    let imageAlignment: HorizontalAlignment

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
            }
        }
        .focusSection()
        .onAppear {
            showContent = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    showContent = true
                }
            }
        }
        .onChange(of: isCurrent) { _, newValue in
            if newValue {
                showContent = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        showContent = true
                    }
                }
            }
        }
        .onChange(of: isExpanded) { _, newValue in
            if !newValue && isCurrent {
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
                } else if isCurrent && showContent {
                    GameDetailView(
                        game: game,
                        onPlay: onPlay,
                        presentationStyle: .embeddedCarousel
                    )
                    .environment(viewModel)
                } else {
                    // Fixed height lets the image overflow its natural width; the outer frame clips to the aligned region for the parallax effect.
                    GeometryReader { geo in
                        AsyncImage(url: game.heroBannerUrl.flatMap(URL.init) ?? game.boxArtUrl.flatMap(URL.init)) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(height: geo.size.height)
                                    .frame(width: geo.size.width, alignment: Alignment(horizontal: imageAlignment, vertical: .center))
                                    .clipped()
                            default:
                                Color.gray.opacity(0.25)
                                    .frame(width: geo.size.width, height: geo.size.height)
                            }
                        }
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

    @Environment(GamesViewModel.self) var viewModel
}
