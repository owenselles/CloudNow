// NOTE: Requires WebRTC SPM package (https://github.com/livekit/webrtc-xcframework)

import AVFoundation
import UIKit
import LiveKitWebRTC

// MARK: - VideoSurfaceView

/// Full-screen video renderer.
/// Uses AVSampleBufferDisplayLayer as the backing layer (reliable on tvOS).
/// LKRTCMTLVideoView (MTKView wrapper) does not render on tvOS — bypassed entirely.
final class VideoSurfaceView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    private let renderer = WebRTCFrameRenderer()
    private var currentTrack: LKRTCVideoTrack?

    var videoTrack: LKRTCVideoTrack? {
        didSet {
            guard oldValue !== videoTrack else { return }
            currentTrack?.remove(renderer)
            currentTrack = videoTrack
            if let track = videoTrack {
                track.add(renderer)
                print("[VideoSurfaceView] Track attached")
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
        displayLayer.videoGravity = .resizeAspectFill
        // Set timebase so the layer displays frames at host-clock time (real-time playback)
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        if let tb {
            CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(tb, rate: 1.0)
            displayLayer.controlTimebase = tb
        }
        renderer.displayLayer = displayLayer
    }
}

// MARK: - WebRTC Video Renderer

/// Implements LKRTCVideoRenderer to receive decoded WebRTC frames and feed them
/// to an AVSampleBufferDisplayLayer via CMSampleBuffer.
private final class WebRTCFrameRenderer: NSObject, LKRTCVideoRenderer {
    weak var displayLayer: AVSampleBufferDisplayLayer?

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }

        // Hardware-decoded H.264/H.265/AV1 frames arrive as CVPixelBuffer (NV12/420v)
        guard let cvBuf = (frame.buffer as? LKRTCCVPixelBuffer)?.pixelBuffer else {
            print("[WebRTCFrameRenderer] Non-CVPixelBuffer frame: \(type(of: frame.buffer))")
            return
        }

        var fmtDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: cvBuf, formatDescriptionOut: &fmtDesc)
        guard let fmtDesc else { return }

        // Use current host-clock time as presentation timestamp → display immediately
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: nil,
            imageBuffer: cvBuf,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmtDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { return }
        displayLayer?.enqueue(sampleBuffer)
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
