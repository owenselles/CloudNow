import SwiftUI
import UIKit

/// Owns memory lifecycle policy above provider-specific navigation so switching
/// services cannot bypass cache suspension or memory-pressure handling.
struct CloudAppLifecycleModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    MemoryLifecycleCoordinator.shared.appDidBecomeActive()
                case .background:
                    MemoryLifecycleCoordinator.shared.appDidEnterBackground()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification
            )) { _ in
                MemoryLifecycleCoordinator.shared.didReceiveMemoryWarning()
            }
    }
}
