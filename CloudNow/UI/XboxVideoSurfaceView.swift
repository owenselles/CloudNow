@preconcurrency import GameController
@preconcurrency import LiveKitWebRTC
import SwiftUI

/// Xbox mode's thin SwiftUI bridge to CloudNow's tvOS-native video renderer.
/// The renderer and decoder are shared infrastructure; input and session
/// behavior remain owned by the Xbox provider mode.
struct XboxVideoSurfaceView: UIViewControllerRepresentable {
    let videoTrack: LKRTCVideoTrack?
    let showsOverlay: Bool
    let onMenuPress: () -> Void
    let onDecodedVideoFormatChanged: @Sendable (DecodedVideoFormat) -> Void

    func makeUIViewController(context _: Context) -> StreamingViewController {
        let controller = StreamingViewController()
        controller.videoSurface.gamepadModeActive = true
        controller.videoSurface.menuPressHandler = onMenuPress
        controller.videoSurface.onDecodedVideoFormatChanged = onDecodedVideoFormatChanged
        return controller
    }

    func updateUIViewController(
        _ controller: StreamingViewController,
        context _: Context
    ) {
        controller.videoSurface.videoTrack = videoTrack
        controller.videoSurface.gamepadModeActive = true
        controller.videoSurface.menuPressHandler = onMenuPress
        controller.videoSurface.onDecodedVideoFormatChanged = onDecodedVideoFormatChanged
        controller.controllerUserInteractionEnabled = showsOverlay
        controller.videoSurface.overlayVisible = showsOverlay
    }

    static func dismantleUIViewController(
        _ controller: StreamingViewController,
        coordinator _: ()
    ) {
        controller.videoSurface.prepareForDismantle()
    }
}
