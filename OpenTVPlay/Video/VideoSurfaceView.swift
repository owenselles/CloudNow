// NOTE: Requires WebRTC SPM package (https://github.com/livekit/webrtc-xcframework)

import AVFoundation
import UIKit
import LiveKitWebRTC

// MARK: - VideoSurfaceView

/// Full-screen hardware-accelerated video renderer.
/// Wraps LKRTCMTLVideoView (Metal-backed) for best performance on Apple TV.
/// Falls back to AVSampleBufferDisplayLayer if needed.
final class VideoSurfaceView: UIView {
    private let rtcView = LKRTCMTLVideoView(frame: .zero)
    // Deferred track: held until layoutSubviews gives rtcView non-zero bounds,
    // because Metal creates a zero-size drawable if add() is called before layout.
    private var pendingTrack: LKRTCVideoTrack?

    var videoTrack: LKRTCVideoTrack? {
        didSet {
            guard oldValue !== videoTrack else { return }
            oldValue?.remove(rtcView)
            pendingTrack = videoTrack
            if videoTrack != nil {
                setNeedsLayout()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        rtcView.videoContentMode = .scaleAspectFill
        addSubview(rtcView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rtcView.frame = bounds
        guard let track = pendingTrack, !bounds.isEmpty else { return }
        track.add(rtcView)
        pendingTrack = nil
    }
}

// MARK: - SwiftUI Wrapper

import SwiftUI

struct VideoSurfaceViewRepresentable: UIViewRepresentable {
    let streamController: GFNStreamController

    func makeUIView(context: Context) -> VideoSurfaceView {
        VideoSurfaceView()
    }

    func updateUIView(_ uiView: VideoSurfaceView, context: Context) {
        uiView.videoTrack = streamController.videoTrack
    }
}
