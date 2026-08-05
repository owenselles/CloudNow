import Foundation

/// Clears independently-owned, memory-only Xbox credentials as one lifecycle
/// boundary without forcing any lazy network client to be constructed.
nonisolated struct XboxLocalCredentialLifecycleGroup: XboxLocalCredentialLifecycle {
    private let lifecycles: [any XboxLocalCredentialLifecycle]

    init(_ lifecycles: [any XboxLocalCredentialLifecycle]) {
        self.lifecycles = lifecycles
    }

    func clearLocalCredentials() async {
        await withTaskGroup(of: Void.self) { group in
            for lifecycle in lifecycles {
                group.addTask {
                    await lifecycle.clearLocalCredentials()
                }
            }
        }
    }
}
