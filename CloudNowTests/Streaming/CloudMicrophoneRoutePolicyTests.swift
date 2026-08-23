@testable import CloudNow
import Testing

@Suite("Cloud microphone route recovery")
struct CloudMicrophoneRoutePolicyTests {
    struct AcquisitionFixture: Sendable {
        let hasDiscoverableInput: Bool
        let hasBluetoothOutput: Bool
        let requiresInputDiscovery: Bool
        let isAcquisitionInProgress: Bool
    }

    struct InputSelectionFixture: Sendable {
        let candidates: [CloudMicrophoneRoutePolicy.InputCandidate]
        let expectedIndex: Int?
    }

    @Test("Microphone off requests neither permission nor capture")
    func microphoneOff() {
        let policy = CloudMicrophoneRoutePolicy()

        #expect(!CloudMicrophoneRoutePolicy.shouldRequestPermission(microphoneEnabled: false))
        #expect(!policy.hasCaptureIntent)
        #expect(!policy.shouldEnableCapture)
        #expect(policy.audioPath == .playbackOnly)
    }

    @Test("Authorized capture intent survives input-route loss and restoration")
    func routeRecovery() {
        var policy = CloudMicrophoneRoutePolicy(hasCaptureIntent: true)

        #expect(CloudMicrophoneRoutePolicy.shouldRequestPermission(microphoneEnabled: true))
        #expect(policy.hasCaptureIntent)
        #expect(!policy.shouldEnableCapture)
        #expect(policy.audioPath == .playbackOnly)

        policy.updateInputRoute(isAvailable: true)

        #expect(policy.hasCaptureIntent)
        #expect(policy.shouldEnableCapture)
        #expect(policy.audioPath == .playbackAndCapture)

        policy.updateInputRoute(isAvailable: false)

        #expect(policy.hasCaptureIntent)
        #expect(!policy.shouldEnableCapture)
        #expect(policy.audioPath == .playbackOnly)

        policy.updateInputRoute(isAvailable: true)

        #expect(policy.hasCaptureIntent)
        #expect(policy.shouldEnableCapture)
        #expect(policy.audioPath == .playbackAndCapture)
    }

    @Test(
        "Capture intent attempts every supported route-acquisition source",
        arguments: [
            AcquisitionFixture(
                hasDiscoverableInput: true,
                hasBluetoothOutput: false,
                requiresInputDiscovery: false,
                isAcquisitionInProgress: false
            ),
            AcquisitionFixture(
                hasDiscoverableInput: false,
                hasBluetoothOutput: true,
                requiresInputDiscovery: false,
                isAcquisitionInProgress: false
            ),
            AcquisitionFixture(
                hasDiscoverableInput: false,
                hasBluetoothOutput: false,
                requiresInputDiscovery: true,
                isAcquisitionInProgress: false
            ),
            AcquisitionFixture(
                hasDiscoverableInput: false,
                hasBluetoothOutput: false,
                requiresInputDiscovery: false,
                isAcquisitionInProgress: true
            ),
        ]
    )
    func supportedAcquisitionSources(_ fixture: AcquisitionFixture) {
        let policy = CloudMicrophoneRoutePolicy(
            hasCaptureIntent: true,
            hasDiscoverableInput: fixture.hasDiscoverableInput,
            hasBluetoothOutput: fixture.hasBluetoothOutput,
            requiresInputDiscovery: fixture.requiresInputDiscovery,
            isAcquisitionInProgress: fixture.isAcquisitionInProgress
        )

        #expect(policy.shouldAttemptInputAcquisition)
        #expect(policy.audioPath == .playbackOnly)
    }

    @Test("Acquisition requires capture intent and an unavailable route")
    func acquisitionPreconditions() {
        let disabled = CloudMicrophoneRoutePolicy(
            hasCaptureIntent: false,
            hasDiscoverableInput: true,
            hasBluetoothOutput: true,
            requiresInputDiscovery: true,
            isAcquisitionInProgress: true
        )
        let alreadyRouted = CloudMicrophoneRoutePolicy(
            hasCaptureIntent: true,
            hasUsableInputRoute: true,
            hasDiscoverableInput: true
        )

        #expect(!disabled.shouldAttemptInputAcquisition)
        #expect(!alreadyRouted.shouldAttemptInputAcquisition)
    }

    @Test(
        "Input selection prefers a matching output, then Continuity, HFP, and fallback",
        arguments: [
            InputSelectionFixture(
                candidates: [
                    .init(kind: .other, matchesSelectedOutput: false),
                    .init(
                        kind: .continuityMicrophone,
                        matchesSelectedOutput: false
                    ),
                    .init(
                        kind: .bluetoothHandsFree,
                        matchesSelectedOutput: false
                    ),
                ],
                expectedIndex: 1
            ),
            InputSelectionFixture(
                candidates: [
                    .init(
                        kind: .continuityMicrophone,
                        matchesSelectedOutput: false
                    ),
                    .init(
                        kind: .bluetoothHandsFree,
                        matchesSelectedOutput: true
                    ),
                ],
                expectedIndex: 1
            ),
            InputSelectionFixture(
                candidates: [
                    .init(kind: .other, matchesSelectedOutput: false),
                ],
                expectedIndex: 0
            ),
            InputSelectionFixture(candidates: [], expectedIndex: nil),
        ]
    )
    func preferredInputSelection(_ fixture: InputSelectionFixture) {
        #expect(
            CloudMicrophoneRoutePolicy.preferredInputIndex(
                among: fixture.candidates
            ) == fixture.expectedIndex
        )
    }
}
