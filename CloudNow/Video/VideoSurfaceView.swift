// NOTE: Requires WebRTC SPM package (https://github.com/livekit/webrtc-xcframework)

import AVFoundation
import LiveKitWebRTC
import UIKit

// MARK: - VideoSurfaceView

/// Full-screen video renderer.
/// Uses AVSampleBufferDisplayLayer as the backing layer (reliable on tvOS).
/// LKRTCMTLVideoView (MTKView wrapper) does not render on tvOS — bypassed entirely.
///
/// Also acts as first responder for hardware keyboard input and pointer (mouse)
/// input, forwarding events to `inputHandler` as GFN protocol packets.
final class VideoSurfaceView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    // swiftlint:disable:next force_cast - reason: layerClass override above guarantees self.layer is AVSampleBufferDisplayLayer
    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    private let renderer = WebRTCFrameRenderer()
    private var currentTrack: LKRTCVideoTrack?

    /// Set by GFNStreamController once the input data channel handshake completes.
    weak var inputHandler: InputEventHandler?

    /// Called when the user presses the Menu button on the Siri Remote.
    /// GFNStreamController sets this to toggle the overlay rather than letting
    /// the press bubble up to the system (which opens the Apple TV control center).
    var menuPressHandler: (() -> Void)?

    /// When true, an extended gamepad owns input. UIKit presses from the controller
    /// (e.g. Options mapping to .playPause) are suppressed to avoid double-firing the overlay.
    var gamepadModeActive = false

    /// Tracks whether the pause overlay is currently visible. Used to decide whether a
    /// .menu press should close the overlay or be silently consumed.
    var overlayVisible: Bool = false

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

    /// Become first responder as soon as the view enters a window so hardware
    /// keyboard events are directed here rather than the focus engine.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
        }
    }

    // MARK: - First Responder / Keyboard

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if press.type == .menu {
                // Always consume .menu — never let it bubble to the system as a back/dismiss
                // gesture. The only valid exits are the in-overlay "Exit Session" button or
                // force-quitting the app. If the overlay is open, treat this as "close overlay".
                if overlayVisible { menuPressHandler?() }
                handled = true
            } else if press.type == .playPause, !gamepadModeActive {
                // Play/Pause toggles the HUD overlay (Siri Remote only).
                // Suppressed when a gamepad is in control — the overlay is toggled there
                // via Options long press detected in InputSender.tick().
                menuPressHandler?()
                handled = true
            } else if let key = press.key {
                inputHandler?.sendKeyEvent(
                    down: true,
                    keyCode: key.keyCode,
                    modifiers: key.modifierFlags
                )
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key {
                inputHandler?.sendKeyEvent(
                    down: false,
                    keyCode: key.keyCode,
                    modifiers: key.modifierFlags
                )
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }
}

// MARK: - WebRTC Video Renderer

/// Implements LKRTCVideoRenderer to receive decoded WebRTC frames and feed them
/// to an AVSampleBufferDisplayLayer via CMSampleBuffer.
private final class WebRTCFrameRenderer: NSObject, LKRTCVideoRenderer {
    weak var displayLayer: AVSampleBufferDisplayLayer?

    func setSize(_: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }

        // Hardware-decoded H.264/H.265/AV1 frames arrive as CVPixelBuffer (NV12/420v).
        // H.265/HDR/AV1 can fall back to software decoding (LKRTCI420Buffer) on some
        // hardware — convert to a planar CVPixelBuffer so the display layer can render it.
        let cvBuf: CVPixelBuffer
        if let hwBuf = frame.buffer as? LKRTCCVPixelBuffer {
            cvBuf = hwBuf.pixelBuffer
        } else if let i420 = frame.buffer as? LKRTCI420Buffer {
            guard let converted = i420ToCVPixelBuffer(i420) else { return }
            cvBuf = converted
        } else {
            print("[WebRTCFrameRenderer] Unhandled frame type: \(type(of: frame.buffer))")
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

    private func i420ToCVPixelBuffer(_ i420: LKRTCI420Buffer) -> CVPixelBuffer? {
        let w = Int(i420.width), h = Int(i420.height)
        var pb: CVPixelBuffer?
        // AVSampleBufferDisplayLayer on tvOS requires biplanar NV12, not three-plane I420
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb) == kCVReturnSuccess,
            let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        // Y plane
        if let dst = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let src = i420.dataY
            let dstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for row in 0 ..< h {
                memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * Int(i420.strideY)), w)
            }
        }

        // UV plane: interleave I420 U and V into NV12 UV
        if let dst = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) {
            let srcU = i420.dataU
            let srcV = i420.dataV
            let dstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let uvRows = h / 2, uvCols = w / 2
            for row in 0 ..< uvRows {
                let uRow = srcU.advanced(by: row * Int(i420.strideU))
                let vRow = srcV.advanced(by: row * Int(i420.strideV))
                let dstRow = dst.advanced(by: row * dstStride)
                for col in 0 ..< uvCols {
                    dstRow[col * 2] = uRow[col]
                    dstRow[col * 2 + 1] = vRow[col]
                }
            }
        }
        return pb
    }
}

// MARK: - Streaming View Controller

import GameController

/// GCEventViewController subclass whose view IS the VideoSurfaceView.
/// controllerUserInteractionEnabled is toggled dynamically: false during streaming
/// (prevents O/Circle → system back) and true when the pause overlay is open
/// (allows D-pad to navigate SwiftUI overlay buttons via the focus engine).
final class StreamingViewController: GCEventViewController {
    let videoSurface = VideoSurfaceView()

    override func loadView() {
        controllerUserInteractionEnabled = false
        view = videoSurface
    }
}

// MARK: - SwiftUI Wrapper

import SwiftUI

struct VideoSurfaceViewRepresentable: UIViewControllerRepresentable {
    let streamController: GFNStreamController
    var showOverlay: Bool = false

    func makeUIViewController(context _: Context) -> StreamingViewController {
        let vc = StreamingViewController()
        Task { @MainActor in
            streamController.bindVideoView(vc.videoSurface)
        }
        return vc
    }

    func updateUIViewController(_ vc: StreamingViewController, context _: Context) {
        vc.videoSurface.videoTrack = streamController.videoTrack
        vc.controllerUserInteractionEnabled = showOverlay
        vc.videoSurface.overlayVisible = showOverlay
    }
}
