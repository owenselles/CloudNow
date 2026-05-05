import SwiftUI

private struct _PassthroughButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Request model

struct CarouselRequest: Identifiable {
    let id = UUID()
    let games: [GameInfo]
    let startId: String

    init(games: [GameInfo], startId: String) {
        self.startId = startId
        if let idx = games.firstIndex(where: { $0.id == startId }) {
            let start = max(0, idx - 15)
            let end = min(games.count, idx + 16)
            self.games = Array(games[start..<end])
        } else {
            self.games = games
        }
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
    @State private var directExpandedGame: GameInfo?
    @State private var bounceOffset: CGFloat = 0

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
                        if abs(dist) <= 1 {
                            CarouselCard(
                                game: game,
                                focusedId: $focusedId,
                                onExpand: { expandedGame = game },
                                onPlay: { g in onDismiss(currentId); onPlay(g) },
                                onDirectExpand: { directExpandedGame = game },
                                isCurrent: game.id == currentId,
                                containerWidth: geo.size.width,
                                imageAlignment: dist < 0 ? .leading : (dist > 0 ? .trailing : .center)
                            )
                            .frame(
                                width: dist == 0 ? geo.size.width * 0.90 : geo.size.width * 0.10,
                                height: geo.size.height * 0.92,
                                alignment: dist < 0 ? .leading : (dist > 0 ? .trailing : .center)
                            )
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 20))
                            .offset(x: CGFloat(dist) * (geo.size.width * 0.50 + 20))
                            .zIndex(dist == 0 ? 1 : 0)
                            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.8), value: currentId)
                            .transition(.opacity)
                        }
                    }
                }
                .offset(x: bounceOffset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.top, geo.size.height * 0.08)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            Task { @MainActor in
                focusedId = request.startId
            }
        }
        .onMoveCommand { dir in
            guard let ci = request.games.firstIndex(where: { $0.id == currentId }) else { return }
            switch dir {
            case .left:
                if ci == 0 {
                    focusedId = currentId
                    bounceOffset = -40
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1))
                        withAnimation(.spring(duration: 0.5, bounce: 0.65)) { bounceOffset = 0 }
                    }
                } else {
                    let newId = request.games[ci - 1].id
                    withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.8)) { currentId = newId }
                    focusedId = newId
                }
            case .right:
                if ci == request.games.count - 1 {
                    focusedId = currentId
                    bounceOffset = 40
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1))
                        withAnimation(.spring(duration: 0.5, bounce: 0.65)) { bounceOffset = 0 }
                    }
                } else {
                    let newId = request.games[ci + 1].id
                    withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.8)) { currentId = newId }
                    focusedId = newId
                }
            case .down:
                expandedGame = request.games.first(where: { $0.id == currentId })
            default:
                break
            }
        }
        .onExitCommand { onDismiss(currentId) }
        .fullScreenCover(item: $expandedGame) { game in
            ExpandedDetailView(game: game, onPlay: { g in
                expandedGame = nil
                onDismiss(currentId)
                onPlay(g)
            })
            .environment(viewModel)
        }
        .fullScreenCover(item: $directExpandedGame) { game in
            ExpandedDetailView(game: game, onPlay: { g in
                directExpandedGame = nil
                onDismiss(currentId)
                onPlay(g)
            })
            .environment(viewModel)
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

private struct CarouselCard: View {
    let game: GameInfo
    var focusedId: FocusState<String?>.Binding
    let onExpand: () -> Void
    let onPlay: (GameInfo) -> Void
    let onDirectExpand: () -> Void
    let isCurrent: Bool
    let containerWidth: CGFloat
    let imageAlignment: HorizontalAlignment

    @State private var showContent = false

    var body: some View {
        Button { onExpand() } label: {
            ZStack(alignment: .bottomLeading) {
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

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.92), location: 0),
                        .init(color: .black.opacity(0.5), location: 0.45),
                        .init(color: .clear, location: 0.75),
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )

                if isCurrent && showContent {
                    contentView
                        .transition(.opacity)
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 20))
            .shadow(
                color: .black.opacity(isCurrent ? 0.5 : 0.15),
                radius: isCurrent ? 20 : 4,
                x: 0,
                y: isCurrent ? 10 : 2
            )
        }
        .buttonStyle(_PassthroughButtonStyle())
        .focusEffectDisabled()
        .focused(focusedId, equals: game.id)
        .contextMenu {
            Button {
                onDirectExpand()
            } label: {
                Label("Info", systemImage: "info.circle")
            }
            if game.isInLibrary {
                let isFav = viewModel.favoriteIds.contains(game.id)
                Button { viewModel.toggleFavorite(game.id) } label: {
                    Label(
                        isFav ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: isFav ? "star.slash.fill" : "star"
                    )
                }
                if game.variants.count > 1 {
                    Menu("Launch via...") {
                        ForEach(game.variants, id: \.id) { variant in
                            Button {
                                viewModel.setPreferredStore(gameId: game.id, variantId: variant.id)
                            } label: {
                                if viewModel.preferredVariantId(for: game) == variant.id {
                                    Label(variant.storeName, systemImage: "checkmark")
                                } else {
                                    Text(variant.storeName)
                                }
                            }
                        }
                    }
                }
            }
        }
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
    }

    private var contentView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(game.title)
                .font(isCurrent ? .largeTitle.weight(.bold) : .title2.weight(.bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 4)

            if isCurrent {
                genreLine

                if let desc = game.longDescription, !desc.isEmpty {
                    Text(desc)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                        .frame(maxWidth: 600, alignment: .leading)
                }

                if game.isInLibrary {
                    Label("In Library", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Text("Not in your Geforce NOW library")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(isCurrent ? 50 : 25)
        .opacity(isCurrent ? 1.0 : 0.6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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

    @Environment(GamesViewModel.self) var viewModel
}
