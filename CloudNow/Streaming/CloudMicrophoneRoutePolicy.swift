import Foundation

/// Pure microphone routing policy shared by every native cloud-stream provider.
/// Capture intent survives temporary route loss; only the operational audio path changes.
nonisolated struct CloudMicrophoneRoutePolicy: Equatable, Sendable {
    enum AudioPath: Equatable, Sendable {
        case playbackOnly
        case playbackAndCapture
    }

    enum InputKind: Equatable, Sendable {
        case continuityMicrophone
        case bluetoothHandsFree
        case other
    }

    struct InputCandidate: Equatable, Sendable {
        let kind: InputKind
        let matchesSelectedOutput: Bool
    }

    private(set) var hasCaptureIntent: Bool
    private(set) var hasUsableInputRoute: Bool
    private(set) var hasDiscoverableInput: Bool
    private(set) var hasBluetoothOutput: Bool
    private(set) var requiresInputDiscovery: Bool
    private(set) var isAcquisitionInProgress: Bool

    init(
        hasCaptureIntent: Bool = false,
        hasUsableInputRoute: Bool = false,
        hasDiscoverableInput: Bool = false,
        hasBluetoothOutput: Bool = false,
        requiresInputDiscovery: Bool = false,
        isAcquisitionInProgress: Bool = false
    ) {
        self.hasCaptureIntent = hasCaptureIntent
        self.hasUsableInputRoute = hasUsableInputRoute
        self.hasDiscoverableInput = hasDiscoverableInput
        self.hasBluetoothOutput = hasBluetoothOutput
        self.requiresInputDiscovery = requiresInputDiscovery
        self.isAcquisitionInProgress = isAcquisitionInProgress
    }

    static func shouldRequestPermission(microphoneEnabled: Bool) -> Bool {
        microphoneEnabled
    }

    var shouldEnableCapture: Bool {
        hasCaptureIntent && hasUsableInputRoute
    }

    var audioPath: AudioPath {
        shouldEnableCapture ? .playbackAndCapture : .playbackOnly
    }

    /// A playback-only category hides `AVAudioSession.availableInputs`, so an
    /// authorized capture request gets one bounded discovery transition even
    /// before a Continuity or wired input can be enumerated.
    var shouldAttemptInputAcquisition: Bool {
        hasCaptureIntent
            && !hasUsableInputRoute
            && (
                hasDiscoverableInput
                    || hasBluetoothOutput
                    || requiresInputDiscovery
                    || isAcquisitionInProgress
            )
    }

    mutating func updateInputRoute(isAvailable: Bool) {
        hasUsableInputRoute = isAvailable
    }

    static func preferredInputIndex(
        among candidates: [InputCandidate]
    ) -> Int? {
        var preferred: (index: Int, priority: Int)?
        for (index, candidate) in candidates.enumerated() {
            let priority = if candidate.matchesSelectedOutput {
                0
            } else {
                switch candidate.kind {
                case .continuityMicrophone: 1
                case .bluetoothHandsFree: 2
                case .other: 3
                }
            }
            if preferred.map({ priority < $0.priority }) ?? true {
                preferred = (index, priority)
            }
        }
        return preferred?.index
    }
}
