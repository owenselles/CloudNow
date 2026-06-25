import AVKit
import SwiftUI

/// Shown during the queue wait when GFN requires ad playback.
/// Reports start / pause / finish lifecycle events back to CloudMatch.
struct QueueAdPlayerView: View {
    let ad: SessionAdInfo
    let onStart: (String) -> Void // adId
    let onPause: (String) -> Void // adId
    let onResume: (String) -> Void // adId
    let onFinish: (String, Int) -> Void // adId, watchedTimeMs
    let message: String?

    @State private var player = AVPlayer()
    @State private var periodicObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var loadedAdId: String?
    @State private var watchedTimeMs = 0
    @State private var isPlaying = false
    @State private var isMuted = false
    @State private var hasReportedStart = false
    @State private var hasSentFinish = false
    @State private var isPaused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Watch an ad to stay in queue", systemImage: "play.rectangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if let url = ad.preferredMediaURL {
                ZStack(alignment: .bottomLeading) {
                    AVPlayerViewRepresentable(player: player)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    HStack(spacing: 12) {
                        Button {
                            isPlaying ? player.pause() : player.play()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            isMuted.toggle()
                            player.isMuted = isMuted
                        } label: {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                }
                .onAppear { loadPlayer(url: url) }
                .onChange(of: ad.adId) { _ in reload(url: url) }
                .onDisappear { teardown() }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 200)
                    .overlay(
                        Label("Ad media unavailable", systemImage: "video.slash.fill")
                            .foregroundStyle(.secondary)
                    )
            }

            if let msg = message, !msg.isEmpty {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.4), lineWidth: 1))
        )
    }

    // MARK: Player lifecycle

    private func loadPlayer(url: URL) {
        guard loadedAdId != ad.adId else { return }
        teardown()
        loadedAdId = ad.adId
        watchedTimeMs = 0
        isPlaying = false
        hasReportedStart = false
        hasSentFinish = false
        isPaused = false

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.isMuted = isMuted
        player.volume = 0.5
        player.play()

        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { _ in
            let currentMs = max(0, Int(player.currentTime().seconds * 1000))
            watchedTimeMs = currentMs
            let playing = player.rate > 0.01
            isPlaying = playing

            if playing, !hasReportedStart {
                hasReportedStart = true
                isPaused = false
                onStart(ad.adId)
            } else if !playing, hasReportedStart, !hasSentFinish, !isPaused {
                isPaused = true
                onPause(ad.adId)
            } else if playing, isPaused {
                isPaused = false
                onResume(ad.adId)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            guard !hasSentFinish else { return }
            hasSentFinish = true
            isPlaying = false
            onFinish(ad.adId, watchedTimeMs)
        }
    }

    private func reload(url: URL) {
        loadedAdId = nil
        hasSentFinish = false
        hasReportedStart = false
        isPaused = false
        isPlaying = false
        loadPlayer(url: url)
    }

    private func teardown() {
        player.pause()
        if let o = periodicObserver { player.removeTimeObserver(o); periodicObserver = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
    }
}

// MARK: - AVPlayer wrapper (tvOS)

private struct AVPlayerViewRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context _: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = false
        vc.videoGravity = .resizeAspect
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context _: Context) {
        vc.player = player
    }
}
