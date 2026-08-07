@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox modern input codec")
struct XboxModernInputCodecTests {
    @Test("Version 10 encodes an exact 61-byte controller frame")
    func encodesExactVersionTenFrame() throws {
        let timestamp = 123.5
        let frame = XboxModernInputFrame(
            frameID: 0x8877_6655,
            gamepad: XboxModernGamepadReport(
                transitionCounters: XboxModernGamepadTransitionCounters(
                    dpadUp: 1,
                    dpadDown: 2,
                    dpadLeft: 3,
                    dpadRight: 4,
                    menu: 5,
                    view: 6,
                    leftThumb: 7,
                    rightThumb: 8,
                    leftShoulder: 9,
                    rightShoulder: 10,
                    nexus: 11,
                    share: 12,
                    a: 13,
                    b: 14,
                    x: 15,
                    y: 16
                ),
                leftTrigger: 0x2211,
                rightTrigger: 0x4433,
                leftThumbX: Int16(bitPattern: 0x6655),
                leftThumbY: Int16(bitPattern: 0x8877),
                rightThumbX: Int16(bitPattern: 0xAA99),
                rightThumbY: Int16(bitPattern: 0xCCBB),
                physicalPhysicality: XboxGamepadPhysicality(
                    rawValue: 0x4433_2211
                ),
                virtualPhysicality: XboxGamepadPhysicality(
                    rawValue: 0x8877_6655
                )
            )
        )

        let data = try XboxModernInputEncoder.encode(
            frame,
            version: 10,
            inputToken: 0x4433_2211,
            timestampMilliseconds: timestamp
        )

        var expected = Data([
            0x00, 0x02,
            0x11, 0x22, 0x33, 0x44,
        ])
        expected.append(contentsOf: littleEndianBytes(timestamp.bitPattern))
        expected.append(contentsOf: [
            0x55, 0x66, 0x77, 0x88,
            0x01,
            0x00,
            0x01, 0x02, 0x03, 0x04,
            0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C,
            0x0D, 0x0E, 0x0F, 0x10,
            0x11, 0x22,
            0x33, 0x44,
            0x55, 0x66,
            0x77, 0x88,
            0x99, 0xAA,
            0xBB, 0xCC,
            0x11, 0x22, 0x33, 0x44,
            0x55, 0x66, 0x77, 0x88,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
        ])

        #expect(data.count == 61)
        #expect(data == expected)
    }

    @Test("Version 9 omits only the lock-key presence byte")
    func encodesVersionNineFrame() throws {
        let frame = XboxModernInputFrame(
            frameID: 1,
            gamepad: XboxModernGamepadReport()
        )

        let data = try XboxModernInputEncoder.encode(
            frame,
            version: 9,
            inputToken: 1,
            timestampMilliseconds: 0
        )

        #expect(data.count == 60)
        #expect(data.suffix(4) == Data(repeating: 0, count: 4))
    }

    @Test("Unsupported modern protocol versions are rejected", arguments: [8, 11])
    func rejectsUnsupportedVersion(_ version: Int) {
        #expect(throws: XboxModernInputCodecError.unsupportedVersion) {
            _ = try XboxModernInputEncoder.encode(
                XboxModernInputFrame(
                    frameID: 1,
                    gamepad: XboxModernGamepadReport()
                ),
                version: version,
                inputToken: 1,
                timestampMilliseconds: 0
            )
        }
    }

    @Test("Tracker preserves protocol button-counter order and slot zero")
    func tracksButtonTransitions() throws {
        var tracker = XboxModernInputStateTracker()
        let initial = tracker.attach()
        #expect(initial.frameID == 1)
        #expect(initial.gamepad.transitionCounters == .init())

        let pressedValue = tracker.record(XboxGamepadState(
            index: 3,
            buttons: [
                .dpadUp,
                .dpadDown,
                .dpadLeft,
                .dpadRight,
                .menu,
                .view,
                .leftThumbstick,
                .rightThumbstick,
                .leftShoulder,
                .rightShoulder,
                .nexus,
                .a,
                .b,
                .x,
                .y,
            ]
        ))
        let pressed = try #require(pressedValue)
        #expect(pressed.gamepad.transitionCounters == .init(
            dpadUp: 1,
            dpadDown: 1,
            dpadLeft: 1,
            dpadRight: 1,
            menu: 1,
            view: 1,
            leftThumb: 1,
            rightThumb: 1,
            leftShoulder: 1,
            rightShoulder: 1,
            nexus: 1,
            share: 0,
            a: 1,
            b: 1,
            x: 1,
            y: 1
        ))

        let releasedValue = tracker.record(XboxGamepadState(index: 3))
        let released = try #require(releasedValue)
        #expect(released.gamepad.transitionCounters == .init(
            dpadUp: 2,
            dpadDown: 2,
            dpadLeft: 2,
            dpadRight: 2,
            menu: 2,
            view: 2,
            leftThumb: 2,
            rightThumb: 2,
            leftShoulder: 2,
            rightShoulder: 2,
            nexus: 2,
            share: 0,
            a: 2,
            b: 2,
            x: 2,
            y: 2
        ))

        let encoded = try XboxModernInputEncoder.encode(
            pressed,
            version: 10,
            inputToken: 1,
            timestampMilliseconds: 0
        )
        #expect(encoded[19] == 0)
    }

    @Test("Tracker retransmits the newest frame until acknowledged")
    func retransmitsUntilAcknowledged() throws {
        var tracker = XboxModernInputStateTracker()
        let initial = tracker.attach()

        #expect(tracker.frameForTransmission() == initial)
        #expect(tracker.frameForTransmission() == initial)
        let rejectedUnknownFrame = tracker.acknowledge(frameID: 999)
        #expect(!rejectedUnknownFrame)
        #expect(tracker.frameForTransmission() == initial)
        let acceptedInitialFrame = tracker.acknowledge(
            frameID: initial.frameID
        )
        #expect(acceptedInitialFrame)
        #expect(tracker.frameForTransmission() == nil)

        let pressedState = XboxGamepadState(index: 0, buttons: [.a])
        let pressedValue = tracker.record(pressedState)
        let pressed = try #require(pressedValue)
        #expect(pressed.frameID == 2)
        #expect(tracker.record(pressedState) == nil)
        #expect(tracker.frameForTransmission() == pressed)
        let acceptedPressedFrame = tracker.acknowledge(
            frameID: pressed.frameID
        )
        #expect(acceptedPressedFrame)
        #expect(tracker.frameForTransmission() == nil)
        #expect(tracker.lastAcknowledgedFrameID == pressed.frameID)
    }

    @Test("Modern send cadence distinguishes changes from retransmission")
    func modernSendCadence() {
        var cadence = XboxModernInputSendCadence()

        #expect(cadence.canAttempt(frameID: 1, at: 1_000_000))
        cadence.recordAccepted(frameID: 1, at: 1_000_000)
        #expect(!cadence.canAttempt(frameID: 2, at: 8_999_999))
        #expect(cadence.canAttempt(frameID: 2, at: 9_000_000))

        cadence.recordAccepted(frameID: 2, at: 9_000_000)
        #expect(!cadence.canAttempt(frameID: 2, at: 24_999_999))
        #expect(cadence.canAttempt(frameID: 2, at: 25_000_000))

        cadence.reset()
        #expect(cadence.canAttempt(frameID: 2, at: 0))
    }

    @Test("Virtual keepalive creates a reversible axis delta")
    func virtualKeepAlive() throws {
        var tracker = XboxModernInputStateTracker()
        _ = tracker.attach()
        let physicalState = XboxGamepadState(
            index: 0,
            buttons: [.a],
            leftThumbX: 0,
            physicalPhysicality: [.a]
        )
        _ = tracker.record(physicalState)

        let keepAliveValue = tracker.recordVirtualKeepAlive()
        let keepAlive = try #require(keepAliveValue)
        #expect(keepAlive.gamepad.leftThumbX == 3277)
        #expect(keepAlive.gamepad.transitionCounters.a == 1)
        #expect(keepAlive.gamepad.virtualPhysicality.isEmpty)

        let restoredValue = tracker.record(physicalState)
        let restored = try #require(restoredValue)
        #expect(restored.gamepad.leftThumbX == 0)
        #expect(restored.gamepad.transitionCounters.a == 1)
        #expect(restored.gamepad.virtualPhysicality.isEmpty)
    }

    @Test("Tracker retains no more than 120 acknowledgement snapshots")
    func boundsAcknowledgementHistory() throws {
        var tracker = XboxModernInputStateTracker()
        _ = tracker.attach()
        var isPressed = false

        for _ in 0 ..< 130 {
            isPressed.toggle()
            _ = tracker.record(XboxGamepadState(
                index: 0,
                buttons: isPressed ? [.a] : []
            ))
        }

        #expect(
            tracker.pendingSnapshotCount
                == XboxModernInputStateTracker.maximumPendingSnapshotCount
        )
        let acceptedEvictedFrame = tracker.acknowledge(frameID: 1)
        #expect(!acceptedEvictedFrame)
        #expect(tracker.pendingSnapshotCount == 120)

        let latest = try #require(tracker.frameForTransmission())
        #expect(latest.frameID == 131)
        let acceptedLatestFrame = tracker.acknowledge(
            frameID: latest.frameID
        )
        #expect(acceptedLatestFrame)
        #expect(tracker.pendingSnapshotCount == 0)
    }

    @Test("Hotplug clears controller state but reset restarts frame IDs")
    func handlesHotplugAndSessionReset() {
        var tracker = XboxModernInputStateTracker()
        _ = tracker.attach()
        _ = tracker.record(XboxGamepadState(index: 0, buttons: [.a]))

        tracker.detach()
        #expect(!tracker.isAttached)
        #expect(tracker.pendingSnapshotCount == 0)
        #expect(tracker.record(XboxGamepadState(index: 0)) == nil)

        let reattached = tracker.attach()
        #expect(reattached.frameID == 3)
        #expect(reattached.gamepad.transitionCounters == .init())

        tracker.reset()
        #expect(!tracker.isAttached)
        #expect(tracker.pendingSnapshotCount == 0)
        #expect(tracker.attach().frameID == 1)
    }
}

private func littleEndianBytes(_ value: UInt64) -> [UInt8] {
    [
        UInt8(truncatingIfNeeded: value),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 32),
        UInt8(truncatingIfNeeded: value >> 40),
        UInt8(truncatingIfNeeded: value >> 48),
        UInt8(truncatingIfNeeded: value >> 56),
    ]
}
