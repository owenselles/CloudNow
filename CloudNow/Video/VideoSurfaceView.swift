// NOTE: Requires WebRTC SPM package (https://github.com/livekit/webrtc-xcframework)

import AVFoundation
import UIKit
import LiveKitWebRTC

// MARK: - VideoSurfaceView

/// Full-screen video renderer.
/// Uses AVSampleBufferDisplayLayer as the backing layer (reliable on tvOS).
/// LKRTCMTLVideoView (MTKView wrapper) does not render on tvOS — bypassed entirely.
///
/// Also acts as first responder for hardware keyboard input and pointer (mouse)
/// input, forwarding events to `inputHandler` as GFN protocol packets.
final class VideoSurfaceView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
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

    // Become first responder as soon as the view enters a window so hardware
    // keyboard events are directed here rather than the focus engine.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
        }
    }

    // MARK: - First Responder / Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if press.type == .menu && gamepadModeActive {
                // In gamepad mode, O/Circle generates a .menu UIKit press that would trigger
                // system back navigation. Consume it here so the OS never sees it.
                // The button input still reaches the game via GCController polling.
                handled = true
            } else if press.type == .playPause && !gamepadModeActive {
                // Play/Pause toggles the HUD overlay (Siri Remote only).
                // Suppressed when a gamepad is in control — the overlay is toggled there
                // via Options long press detected in InputSender.tick().
                menuPressHandler?()
                handled = true
            } else if let key = press.key, let mapping = Self.hidToKeyMapping[key.keyCode] {
                inputHandler?.sendKeyEvent(
                    down: true,
                    vk: mapping.vk,
                    scancode: mapping.scancode,
                    modifiers: gfnModifiers(from: key.modifierFlags)
                )
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let mapping = Self.hidToKeyMapping[key.keyCode] {
                inputHandler?.sendKeyEvent(
                    down: false,
                    vk: mapping.vk,
                    scancode: mapping.scancode,
                    modifiers: gfnModifiers(from: key.modifierFlags)
                )
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    // MARK: - Helpers

    private func gfnModifiers(from flags: UIKeyModifierFlags) -> UInt16 {
        var mods: UInt16 = 0
        if flags.contains(.shift)     { mods |= 0x0001 }
        if flags.contains(.control)   { mods |= 0x0002 }
        if flags.contains(.alternate) { mods |= 0x0004 }
        if flags.contains(.command)   { mods |= 0x0008 }
        return mods
    }

    // MARK: - HID → (VK, Scancode) Table
    //
    // Maps UIKeyboardHIDUsage (USB HID Usage codes) to Windows Virtual Key codes
    // and PS/2 Set-1 scancodes.
    // Extended scancodes (0xE0 prefix) are stored as-is in the UInt16 high byte (0xE0__).

    private static let hidToKeyMapping: [UIKeyboardHIDUsage: (vk: UInt16, scancode: UInt16)] = [
        // Letters A–Z  (VK = ASCII uppercase, scancode = PS/2 Set-1)
        .keyboardA: (0x41, 0x1E), .keyboardB: (0x42, 0x30), .keyboardC: (0x43, 0x2E),
        .keyboardD: (0x44, 0x20), .keyboardE: (0x45, 0x12), .keyboardF: (0x46, 0x21),
        .keyboardG: (0x47, 0x22), .keyboardH: (0x48, 0x23), .keyboardI: (0x49, 0x17),
        .keyboardJ: (0x4A, 0x24), .keyboardK: (0x4B, 0x25), .keyboardL: (0x4C, 0x26),
        .keyboardM: (0x4D, 0x32), .keyboardN: (0x4E, 0x31), .keyboardO: (0x4F, 0x18),
        .keyboardP: (0x50, 0x19), .keyboardQ: (0x51, 0x10), .keyboardR: (0x52, 0x13),
        .keyboardS: (0x53, 0x1F), .keyboardT: (0x54, 0x14), .keyboardU: (0x55, 0x16),
        .keyboardV: (0x56, 0x2F), .keyboardW: (0x57, 0x11), .keyboardX: (0x58, 0x2D),
        .keyboardY: (0x59, 0x15), .keyboardZ: (0x5A, 0x2C),

        // Digit row  (VK = ASCII digit)
        .keyboard1: (0x31, 0x02), .keyboard2: (0x32, 0x03), .keyboard3: (0x33, 0x04),
        .keyboard4: (0x34, 0x05), .keyboard5: (0x35, 0x06), .keyboard6: (0x36, 0x07),
        .keyboard7: (0x37, 0x08), .keyboard8: (0x38, 0x09), .keyboard9: (0x39, 0x0A),
        .keyboard0: (0x30, 0x0B),

        // Control / whitespace
        .keyboardReturnOrEnter:     (0x0D, 0x1C),
        .keyboardEscape:            (0x1B, 0x01),
        .keyboardDeleteOrBackspace: (0x08, 0x0E),
        .keyboardTab:               (0x09, 0x0F),
        .keyboardSpacebar:          (0x20, 0x39),
        .keyboardCapsLock:          (0x14, 0x3A),

        // Symbols
        .keyboardHyphen:               (0xBD, 0x0C),
        .keyboardEqualSign:            (0xBB, 0x0D),
        .keyboardOpenBracket:          (0xDB, 0x1A),
        .keyboardCloseBracket:         (0xDD, 0x1B),
        .keyboardBackslash:            (0xDC, 0x2B),
        .keyboardNonUSPound:           (0xE2, 0x56),   // IntlBackslash / non-US #
        .keyboardSemicolon:            (0xBA, 0x27),
        .keyboardQuote:                (0xDE, 0x28),
        .keyboardGraveAccentAndTilde:  (0xC0, 0x29),
        .keyboardComma:                (0xBC, 0x33),
        .keyboardPeriod:               (0xBE, 0x34),
        .keyboardSlash:                (0xBF, 0x35),

        // Function keys F1–F13
        .keyboardF1:  (0x70, 0x3B), .keyboardF2:  (0x71, 0x3C), .keyboardF3:  (0x72, 0x3D),
        .keyboardF4:  (0x73, 0x3E), .keyboardF5:  (0x74, 0x3F), .keyboardF6:  (0x75, 0x40),
        .keyboardF7:  (0x76, 0x41), .keyboardF8:  (0x77, 0x42), .keyboardF9:  (0x78, 0x43),
        .keyboardF10: (0x79, 0x44), .keyboardF11: (0x7A, 0x57), .keyboardF12: (0x7B, 0x58),
        .keyboardF13: (0x7C, 0x64),

        // Navigation cluster (extended scancodes: 0xE0 in high byte)
        .keyboardInsert:      (0x2D, 0xE052), .keyboardHome:     (0x24, 0xE047),
        .keyboardPageUp:      (0x21, 0xE049), .keyboardDeleteForward: (0x2E, 0xE053),
        .keyboardEnd:         (0x23, 0xE04F), .keyboardPageDown:  (0x22, 0xE051),
        .keyboardRightArrow:  (0x27, 0xE04D), .keyboardLeftArrow: (0x25, 0xE04B),
        .keyboardDownArrow:   (0x28, 0xE050), .keyboardUpArrow:   (0x26, 0xE048),

        // System keys
        .keyboardPrintScreen: (0x2C, 0xE037),
        .keyboardScrollLock:  (0x91, 0x46),
        .keyboardPause:       (0x13, 0x45),
        .keyboardApplication: (0x5D, 0xE05D),  // ContextMenu

        // Numpad
        .keypadNumLock:   (0x90, 0xE045),
        .keypadSlash:     (0x6F, 0xE035),
        .keypadAsterisk:  (0x6A, 0x37),
        .keypadHyphen:    (0x6D, 0x4A),
        .keypadPlus:      (0x6B, 0x4E),
        .keypadEnter:     (0x0D, 0xE01C),
        .keypad1:         (0x61, 0x4F), .keypad2: (0x62, 0x50), .keypad3: (0x63, 0x51),
        .keypad4:         (0x64, 0x4B), .keypad5: (0x65, 0x4C), .keypad6: (0x66, 0x4D),
        .keypad7:         (0x67, 0x47), .keypad8: (0x68, 0x48), .keypad9: (0x69, 0x49),
        .keypad0:         (0x60, 0x52), .keypadPeriod: (0x6E, 0x53),

        // Modifier keys
        .keyboardLeftControl:  (0xA2, 0x1D),   .keyboardRightControl: (0xA3, 0xE01D),
        .keyboardLeftShift:    (0xA0, 0x2A),   .keyboardRightShift:   (0xA1, 0x36),
        .keyboardLeftAlt:      (0xA4, 0x38),   .keyboardRightAlt:     (0xA5, 0xE038),
        .keyboardLeftGUI:      (0x5B, 0xE05B), .keyboardRightGUI:     (0x5C, 0xE05C),
    ]
}

// MARK: - WebRTC Video Renderer

/// Implements LKRTCVideoRenderer to receive decoded WebRTC frames and feed them
/// to an AVSampleBufferDisplayLayer via CMSampleBuffer.
private final class WebRTCFrameRenderer: NSObject, LKRTCVideoRenderer {
    weak var displayLayer: AVSampleBufferDisplayLayer?

    func setSize(_ size: CGSize) {}

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
        if let src = i420.dataY, let dst = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let dstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for row in 0..<h {
                memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * Int(i420.strideY)), w)
            }
        }

        // UV plane: interleave I420 U and V into NV12 UV
        if let srcU = i420.dataU, let srcV = i420.dataV,
           let dst = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) {
            let dstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let uvRows = h / 2, uvCols = w / 2
            for row in 0..<uvRows {
                let uRow = srcU.advanced(by: row * Int(i420.strideU))
                let vRow = srcV.advanced(by: row * Int(i420.strideV))
                let dstRow = dst.advanced(by: row * dstStride)
                for col in 0..<uvCols {
                    dstRow[col * 2]     = uRow[col]
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

    func makeUIViewController(context: Context) -> StreamingViewController {
        let vc = StreamingViewController()
        Task { @MainActor in
            streamController.bindVideoView(vc.videoSurface)
        }
        return vc
    }

    func updateUIViewController(_ vc: StreamingViewController, context: Context) {
        vc.videoSurface.videoTrack = streamController.videoTrack
        vc.controllerUserInteractionEnabled = showOverlay
    }
}
