import GameController
import Observation

/// Shared, lightweight presentation monitor. Provider input drivers still own
/// packet encoding; this object only decides whether Play can be offered.
@Observable
@MainActor
final class CloudInputDeviceMonitor {
    private(set) var connectedDevices: Set<CloudInputDeviceKind> = []

    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let snapshot: @MainActor @Sendable () -> Set<
        CloudInputDeviceKind
    >
    @ObservationIgnored private var observations: [NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter = .default,
        snapshot: @escaping @MainActor @Sendable () -> Set<
            CloudInputDeviceKind
        > = CloudInputDeviceMonitor.systemSnapshot
    ) {
        self.notificationCenter = notificationCenter
        self.snapshot = snapshot
        connectedDevices = snapshot()
    }

    isolated deinit {
        stop()
    }

    func start() {
        guard observations.isEmpty else {
            refresh()
            return
        }
        let names: [Notification.Name] = [
            .GCControllerDidConnect,
            .GCControllerDidDisconnect,
            .GCKeyboardDidConnect,
            .GCKeyboardDidDisconnect,
            .GCMouseDidConnect,
            .GCMouseDidDisconnect,
        ]
        observations = names.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }
        refresh()
    }

    func stop() {
        observations.forEach { notificationCenter.removeObserver($0) }
        observations.removeAll(keepingCapacity: false)
    }

    func refresh() {
        connectedDevices = snapshot()
    }

    func supports(_ requiredDevices: Set<CloudInputDeviceKind>) -> Bool {
        !requiredDevices.isEmpty
            && !connectedDevices.isDisjoint(with: requiredDevices)
    }

    private static func systemSnapshot() -> Set<CloudInputDeviceKind> {
        var devices: Set<CloudInputDeviceKind> = []
        if GCController.controllers().contains(where: {
            $0.extendedGamepad != nil
        }) {
            devices.insert(.controller)
        }
        if GCKeyboard.coalesced != nil, !GCMouse.mice().isEmpty {
            devices.insert(.keyboardMouse)
            devices.insert(.textEntry)
        } else if GCKeyboard.coalesced != nil {
            devices.insert(.textEntry)
        }
        return devices
    }
}
