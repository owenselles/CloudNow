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
    @State private var lifecycle = QueueAdPlaybackLifecycle()
    @State private var isPlaying = false
    @State private var isMuted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.text("watch_ad_to_stay_in_queue"), systemImage: "play.rectangle.fill")
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
                .onChange(of: ad.adId) { reload(url: url) }
                .onDisappear { teardown() }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 200)
                    .overlay(
                        Label(L10n.text("ad_media_unavailable"), systemImage: "video.slash.fill")
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
        guard lifecycle.loadedAdId != ad.adId else { return }
        teardown()
        lifecycle.loadedAdId = ad.adId
        lifecycle.watchedTimeMs = 0
        isPlaying = false
        lifecycle.hasReportedStart = false
        lifecycle.hasSentFinish = false
        lifecycle.isPaused = false

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.isMuted = isMuted
        player.volume = 0.5
        player.play()

        lifecycle.periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let currentMs = max(0, Int(player.currentTime().seconds * 1000))
                lifecycle.watchedTimeMs = currentMs
                let playing = player.rate > 0.01
                if isPlaying != playing {
                    isPlaying = playing
                }

                if playing, !lifecycle.hasReportedStart {
                    lifecycle.hasReportedStart = true
                    lifecycle.isPaused = false
                    onStart(ad.adId)
                } else if !playing,
                          lifecycle.hasReportedStart,
                          !lifecycle.hasSentFinish,
                          !lifecycle.isPaused
                {
                    lifecycle.isPaused = true
                    onPause(ad.adId)
                } else if playing, lifecycle.isPaused {
                    lifecycle.isPaused = false
                    onResume(ad.adId)
                }
            }
        }

        lifecycle.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard !lifecycle.hasSentFinish else { return }
                lifecycle.hasSentFinish = true
                if isPlaying {
                    isPlaying = false
                }
                onFinish(ad.adId, lifecycle.watchedTimeMs)
            }
        }
    }

    private func reload(url: URL) {
        lifecycle.loadedAdId = nil
        lifecycle.hasSentFinish = false
        lifecycle.hasReportedStart = false
        lifecycle.isPaused = false
        isPlaying = false
        loadPlayer(url: url)
    }

    private func teardown() {
        player.pause()
        lifecycle.loadedAdId = nil
        if let observer = lifecycle.periodicObserver {
            player.removeTimeObserver(observer)
            lifecycle.periodicObserver = nil
        }
        if let observer = lifecycle.endObserver {
            NotificationCenter.default.removeObserver(observer)
            lifecycle.endObserver = nil
        }
        player.replaceCurrentItem(with: nil)
    }
}

/// Operational AVPlayer bookkeeping is intentionally non-observable. Only the
/// two values rendered by the view (`isPlaying` and `isMuted`) live in SwiftUI
/// state, so the 4 Hz time observer cannot invalidate the ad card.
@MainActor
private final class QueueAdPlaybackLifecycle {
    var periodicObserver: Any?
    var endObserver: NSObjectProtocol?
    var loadedAdId: String?
    var watchedTimeMs = 0
    var hasReportedStart = false
    var hasSentFinish = false
    var isPaused = false
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
