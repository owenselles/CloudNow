import Foundation
@preconcurrency import LiveKitWebRTC

/// The single WebRTC runtime shared by every CloudNow streaming provider.
///
/// Keeping factory ownership at the app level avoids loading duplicate media
/// stacks when users keep both provider accounts signed in. Provider adapters
/// still own their signaling and data-channel protocols independently.
@MainActor
enum CloudRTCRuntime {
    static let peerConnectionFactory: LKRTCPeerConnectionFactory = {
        LKRTCInitializeSSL()
        let encoderFactory = LKRTCDefaultVideoEncoderFactory()
        let decoderFactory = GFNVideoDecoderFactory()
        return LKRTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory,
            audioDevice: GFNAudioDevice.shared
        )
    }()
}
