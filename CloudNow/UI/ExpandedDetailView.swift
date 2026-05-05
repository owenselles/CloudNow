import SwiftUI

// MARK: - ExpandedDetailView

struct ExpandedDetailView: View {
    let game: GameInfo
    let onPlay: (GameInfo) -> Void

    @Environment(GamesViewModel.self) var viewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showFullDescription = false
    @FocusState private var heroFocused: Bool
    @FocusState private var detailFocused: Bool
    @State private var backgroundBlurred = false
    @State private var appeared = false
    @State private var dismissing = false

    var body: some View {
        ZStack {
            GameDetailBackground(game: game, blurred: backgroundBlurred)

            ScrollViewReader { proxy in
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
                                .animation(.easeOut(duration: 0.35).delay(0.1), value: backgroundBlurred)

                            if !game.screenshots.isEmpty { screenshotsRow }
                            if let desc = game.longDescription, !desc.isEmpty { aboutPanel(desc) }
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .onChange(of: heroFocused) { _, focused in
                    if focused {
                        backgroundBlurred = false
                        withAnimation(.smooth) { proxy.scrollTo("hero", anchor: .top) }
                    }
                }
                .onChange(of: detailFocused) { _, focused in
                    if focused {
                        backgroundBlurred = true
                        withAnimation(.smooth) { proxy.scrollTo("detail", anchor: .top) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(appeared && !dismissing ? 1 : 0)
            .offset(y: appeared && !dismissing ? 0 : 40)
            .animation(.easeOut(duration: 0.4), value: appeared)
            .animation(.easeIn(duration: 0.28), value: dismissing)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation { appeared = true }
        }
        .onExitCommand {
            withAnimation { dismissing = true }
            Task {
                try? await Task.sleep(for: .milliseconds(280))
                dismiss()
            }
        }
        .sheet(isPresented: $showFullDescription) {
            if let desc = game.longDescription { FullDescriptionView(description: desc) }
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

                    if let desc = game.longDescription, !desc.isEmpty {
                        Text(desc)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(3)
                            .frame(maxWidth: 560, alignment: .leading)
                    }

                    if game.isInLibrary {
                        Label("In Library", systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Text("Not in your GeForce NOW library")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if game.isInLibrary {
                        HStack(spacing: 16) {
                            Button {
                                onPlay(viewModel.gameWithPreferredStore(game))
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .focused($heroFocused)

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
                            .focused($heroFocused)
                        }
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

    private var screenshotsRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Screenshots").font(.title3.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(game.screenshots.enumerated()), id: \.offset) { _, url in
                        Button {} label: {
                            AsyncImage(url: URL(string: url)) { phase in
                                switch phase {
                                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                                default: Color.gray.opacity(0.3)
                                }
                            }
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
        let genres = game.genreItems
        let items: [(String, String)] = [
            game.contentRating.map { ("Rating", $0) },
            game.developer.map { ("Developer", $0) },
            game.publisher.flatMap { $0 != game.developer ? ("Publisher", $0) : nil },
            genres.isEmpty ? nil : ("Genres", genres.joined(separator: ", ")),
            game.variants.isEmpty ? nil : ("Available on", game.variants.map(\.storeName).joined(separator: ", ")),
        ].compactMap { $0 }

        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Details").font(.title3.weight(.semibold))
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 20) {
                    ForEach(items, id: \.0) { label, value in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label.uppercased())
                                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(1)
                            Text(value)
                                .font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: À propos panel

    private func aboutPanel(_ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About").font(.title3.weight(.semibold))
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
            .focused($detailFocused)
        }
    }

    // MARK: Genre line

    @ViewBuilder
    private var genreLine: some View {
        let items = game.genreItems
        if !items.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, label in
                    if idx > 0 { Text("  ·  ").foregroundStyle(.white.opacity(0.45)).font(.callout) }
                    Text(label).font(.callout).foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }

    // MARK: Right column

    @ViewBuilder
    private var rightColumn: some View {
        VStack(alignment: .trailing, spacing: 14) {
            if let dev = game.developer { rightInfo("Developer", dev) }
            if let pub = game.publisher, pub != game.developer { rightInfo("Publisher", pub) }
            if let rating = game.contentRating { rightInfo("Rating", rating) }
            if game.variants.count > 1 && game.isInLibrary {
                Divider().frame(width: 200).opacity(0.3)
                variantPicker
            }
        }
    }

    private func rightInfo(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(1)
            Text(value).font(.callout).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.trailing)
        }
    }

    private var variantPicker: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text("LAUNCH VIA").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(1)
            ForEach(game.variants, id: \.id) { variant in
                let isSelected = viewModel.preferredVariantId(for: game) == variant.id
                Button {
                    viewModel.setPreferredStore(gameId: game.id, variantId: variant.id)
                } label: {
                    HStack(spacing: 6) {
                        if isSelected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                        Text(variant.storeName).font(.callout.weight(isSelected ? .semibold : .regular))
                    }
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Shared background

struct GameDetailBackground: View {
    let game: GameInfo
    let blurred: Bool

    var body: some View {
        ZStack {
            AsyncImage(url: game.heroBannerUrl.flatMap(URL.init) ?? game.boxArtUrl.flatMap(URL.init)) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                default: Color.black
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .blur(radius: blurred ? 20 : 0)
            .animation(.easeInOut(duration: 0.4), value: blurred)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.92), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.35),
                    .init(color: .clear,               location: 0.7),
                ],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Full Description Sheet

struct FullDescriptionView: View {
    let description: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusable()
            }
            .padding(80)
        }
        .background(Color.black.ignoresSafeArea())
    }
}
