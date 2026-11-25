@testable import CloudNow
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite("Video surface binding")
struct VideoSurfaceBindingTests {
    @Test("Format callback is installed during view creation before video can attach")
    func bindsFormatCallbackSynchronously() async throws {
        let controller = GFNStreamController()
        let host = AppearanceHostingController(rootView: VideoSurfaceViewRepresentable(streamController: controller))
        let foregroundScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        let previousKeyWindow = foregroundScenes.compactMap(\.keyWindow).first
        let scene = try #require(previousKeyWindow?.windowScene ?? foregroundScenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        // No actor suspension: a deferred binding task cannot satisfy this assertion.
        let surface = try #require(videoSurface(in: host.view))
        #expect(surface.onDecodedVideoFormatChanged != nil)
        #expect(surface.videoTrack == nil)

        await host.waitUntilAppeared()
        surface.resignFirstResponder()
    }

    private func videoSurface(in view: UIView) -> VideoSurfaceView? {
        if let surface = view as? VideoSurfaceView {
            return surface
        }
        for child in view.subviews {
            if let surface = videoSurface(in: child) {
                return surface
            }
        }
        return nil
    }
}

@MainActor
private final class AppearanceHostingController<Content: View>: UIHostingController<Content> {
    private var hasAppeared = false
    private var appearanceContinuation: CheckedContinuation<Void, Never>?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        appearanceContinuation?.resume()
        appearanceContinuation = nil
    }

    func waitUntilAppeared() async {
        guard !hasAppeared else { return }
        await withCheckedContinuation { appearanceContinuation = $0 }
    }
}
