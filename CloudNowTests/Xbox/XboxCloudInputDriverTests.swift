@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox Cloud channel protocol")
struct XboxCloudInputDriverTests {
    @Test("Control authorization uses Microsoft's public Xbox web contract")
    func controlAuthorization() throws {
        let data = try XboxCloudChannelProtocolCodec.authorizationRequest()
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object.count == 2)
        #expect(object["message"] as? String == "authorizationRequest")
        #expect(
            object["accessKey"] as? String
                == "4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E"
        )
    }

    @Test("Resolution backpressure blocks control authorization")
    func resolutionBackpressureBlocksAuthorization() {
        var state = XboxCloudControlSendState()

        #expect(!state.shouldSendAuthorization)
        #expect(!state.shouldSendResolutionUpdate)

        state.channelStateChanged(isOpen: true)
        #expect(!state.shouldSendAuthorization)
        #expect(state.shouldSendResolutionUpdate)

        state.recordAuthorization(disposition: .accepted)
        state.recordResolutionUpdate(disposition: .backpressured)
        #expect(!state.didSendAuthorization)
        #expect(!state.didSendResolutionUpdate)
        #expect(!state.shouldSendAuthorization)
        #expect(state.shouldSendResolutionUpdate)

        state.recordResolutionUpdate(disposition: .accepted)
        #expect(state.didSendResolutionUpdate)
        #expect(state.shouldSendAuthorization)
        #expect(!state.shouldSendResolutionUpdate)

        state.recordAuthorization(disposition: .backpressured)
        #expect(state.shouldSendAuthorization)
        #expect(!state.didSendAuthorization)

        state.recordAuthorization(disposition: .accepted)
        #expect(state.didSendAuthorization)
        #expect(!state.shouldSendAuthorization)
        #expect(!state.shouldSendResolutionUpdate)
    }

    @Test("Control bootstrap restarts with resolution after channel reopen")
    func controlBootstrapAfterReopen() {
        var state = XboxCloudControlSendState()

        state.channelStateChanged(isOpen: true)
        state.recordResolutionUpdate(disposition: .accepted)
        state.recordAuthorization(disposition: .accepted)
        #expect(state.didSendResolutionUpdate)
        #expect(state.didSendAuthorization)

        state.channelStateChanged(isOpen: false)
        #expect(!state.didSendResolutionUpdate)
        #expect(!state.didSendAuthorization)
        #expect(!state.shouldSendAuthorization)
        #expect(!state.shouldSendResolutionUpdate)

        state.channelStateChanged(isOpen: true)
        #expect(!state.shouldSendAuthorization)
        #expect(state.shouldSendResolutionUpdate)
    }

    @Test("Preferred resolution follows input bootstrap and precedes authorization")
    func bootstrapOrdering() {
        var state = XboxCloudInputBootstrapState(
            isTransportReady: false,
            hasInputVersion: true,
            isInputChannelOpen: true,
            didSendClientMetadata: false,
            hasPendingControlUpdates: true,
            hasAttachedController: true,
            didSendInitialControllerReport: false,
            didSendAuthorization: false,
            didSendResolutionUpdate: false
        )

        #expect(!state.canSendControlUpdates)
        #expect(!state.canSendControllerReport)
        #expect(!state.canSendResolutionUpdate)
        #expect(!state.canSendAuthorization)

        state.didSendClientMetadata = true
        #expect(!state.canSendControlUpdates)
        #expect(!state.canSendControllerReport)
        #expect(!state.canSendResolutionUpdate)
        #expect(!state.canSendAuthorization)

        state.isTransportReady = true
        #expect(state.canSendControlUpdates)
        #expect(!state.canSendControllerReport)
        #expect(!state.canSendResolutionUpdate)
        #expect(!state.canSendAuthorization)

        state.hasPendingControlUpdates = false
        #expect(state.canSendControllerReport)
        #expect(!state.canSendResolutionUpdate)
        #expect(!state.canSendAuthorization)

        state.didSendInitialControllerReport = true
        #expect(state.canSendResolutionUpdate)
        #expect(!state.canSendAuthorization)

        state.didSendResolutionUpdate = true
        #expect(state.canSendAuthorization)
        #expect(state.canSendResolutionUpdate)
        #expect(!state.isPublishedReady(
            isMessageChannelOpen: true,
            didReceiveMessageHandshake: true
        ))

        state.didSendAuthorization = true
        #expect(!state.isPublishedReady(
            isMessageChannelOpen: true,
            didReceiveMessageHandshake: false
        ))
        #expect(state.isPublishedReady(
            isMessageChannelOpen: true,
            didReceiveMessageHandshake: true
        ))

        state.isTransportReady = false
        #expect(!state.canSendAuthorization)
        #expect(!state.isPublishedReady(
            isMessageChannelOpen: true,
            didReceiveMessageHandshake: true
        ))
    }

    @Test("No controller makes the initial input snapshot vacuously complete")
    func controllerFreeBootstrap() {
        let state = XboxCloudInputBootstrapState(
            isTransportReady: true,
            hasInputVersion: true,
            isInputChannelOpen: true,
            didSendClientMetadata: true,
            hasPendingControlUpdates: false,
            hasAttachedController: false,
            didSendInitialControllerReport: false,
            didSendAuthorization: true,
            didSendResolutionUpdate: true
        )

        #expect(state.initialControllerReportSatisfied)
        #expect(state.canSendResolutionUpdate)
        #expect(state.canSendAuthorization)
    }

    @Test(
        "Controller presence never removes an unregistered gamepad",
        arguments: [
            (isAttached: true, isRegistered: false, expected: Bool?(true)),
            (isAttached: true, isRegistered: true, expected: nil),
            (isAttached: false, isRegistered: false, expected: nil),
            (isAttached: false, isRegistered: true, expected: Bool?(false)),
        ]
    )
    func controllerRegistrationPolicy(
        isAttached: Bool,
        isRegistered: Bool,
        expected: Bool?
    ) {
        #expect(XboxCloudControllerRegistrationPolicy.pendingUpdate(
            isAttached: isAttached,
            isRegistered: isRegistered
        ) == expected)
    }

    @Test("Paused V2 input retries until its neutral frame is acknowledged")
    func pausedModernInputPolicy() {
        #expect(XboxModernPausedInputPolicy.shouldAttemptSend(
            needsNeutralSnapshot: true,
            hasUnacknowledgedFrame: false
        ))
        #expect(XboxModernPausedInputPolicy.shouldAttemptSend(
            needsNeutralSnapshot: false,
            hasUnacknowledgedFrame: true
        ))
        #expect(!XboxModernPausedInputPolicy.shouldAttemptSend(
            needsNeutralSnapshot: false,
            hasUnacknowledgedFrame: false
        ))
    }

    @Test("Modern input keeps one logical controller across physical hot-plug")
    func modernControllerSlotPolicy() {
        #expect(XboxModernControllerSlotPolicy.selectedSlot(
            current: nil,
            occupiedSlots: [false, true]
        ) == 1)
        #expect(XboxModernControllerSlotPolicy.selectedSlot(
            current: 1,
            occupiedSlots: [true, true]
        ) == 1)
        #expect(XboxModernControllerSlotPolicy.selectedSlot(
            current: 1,
            occupiedSlots: [true, false]
        ) == 0)
        #expect(XboxModernControllerSlotPolicy.selectedSlot(
            current: 1,
            occupiedSlots: [false, false]
        ) == nil)
    }

    @Test("A short Start press produces one remote Menu down then up")
    func shortOverlayPress() {
        var sequence = XboxCloudOverlayInputSequence()
        let start: UInt64 = 1000

        #expect(sequence.update(isPressed: true, at: start) == .none)
        #expect(sequence.remoteMenuOverride == false)

        let pressedAction = sequence.update(
            isPressed: false,
            at: start + 20_000_000
        )
        guard case let .remoteMenu(isPressed, replayToken) = pressedAction
        else {
            Issue.record("Short press did not begin a remote Menu replay")
            return
        }
        #expect(isPressed)
        #expect(sequence.remoteMenuOverride == true)

        let releasedAction = sequence.finishReplay(token: replayToken)
        #expect(releasedAction == .remoteMenu(
            isPressed: false,
            replayToken: replayToken
        ))
        #expect(sequence.remoteMenuOverride == nil)
        #expect(sequence.finishReplay(token: replayToken) == .none)

        let transitions = [pressedAction, releasedAction].compactMap {
            action -> Bool? in
            guard case let .remoteMenu(isPressed, _) = action else {
                return nil
            }
            return isPressed
        }
        #expect(transitions == [true, false])
    }

    @Test("A 1.8 second Start hold toggles once with no remote Menu event")
    func longOverlayPress() {
        var sequence = XboxCloudOverlayInputSequence()
        let start: UInt64 = 5000
        let threshold = XboxCloudOverlayGestureState
            .longPressDurationNanoseconds

        let actions = [
            sequence.update(isPressed: true, at: start),
            sequence.update(
                isPressed: true,
                at: start + threshold - 1
            ),
            sequence.update(
                isPressed: true,
                at: start + threshold
            ),
            sequence.update(
                isPressed: true,
                at: start + threshold + 1
            ),
            sequence.update(
                isPressed: false,
                at: start + threshold + 2
            ),
        ]

        #expect(actions.filter { $0 == .toggleOverlay }.count == 1)
        #expect(!actions.contains { action in
            if case .remoteMenu = action {
                return true
            }
            return false
        })
        #expect(sequence.remoteMenuOverride == nil)
    }

    @Test("Overlay filtering changes both Xbox menu fields only")
    func overlayMenuFiltering() {
        let original = XboxGamepadState(
            index: 2,
            buttons: [.menu, .a],
            leftThumbX: 123,
            physicalPhysicality: [.menu, .a],
            virtualPhysicality: [.leftThumbXAxis]
        )

        let suppressed = XboxCloudOverlayInputPolicy.settingMenuPressed(
            false,
            in: original
        )
        #expect(!suppressed.buttons.contains(.menu))
        #expect(suppressed.buttons.contains(.a))
        #expect(!suppressed.physicalPhysicality.contains(.menu))
        #expect(suppressed.physicalPhysicality.contains(.a))
        #expect(suppressed.leftThumbX == original.leftThumbX)
        #expect(suppressed.virtualPhysicality == original.virtualPhysicality)

        let replayed = XboxCloudOverlayInputPolicy.settingMenuPressed(
            true,
            in: suppressed
        )
        #expect(replayed.buttons.contains(.menu))
        #expect(replayed.physicalPhysicality.contains(.menu))
        #expect(replayed.buttons.contains(.a))
        #expect(replayed.physicalPhysicality.contains(.a))
    }

    @Test("Overlay replay reaches legacy and modern Xbox wire encoders")
    func overlayReplayWireEncoding() throws {
        var sequence = XboxCloudOverlayInputSequence()
        let neutral = XboxGamepadState(index: 0)

        #expect(sequence.update(isPressed: true, at: 0) == .none)
        let replayAction = sequence.update(isPressed: false, at: 1)
        guard case let .remoteMenu(isPressed, replayToken) = replayAction
        else {
            Issue.record("Short press did not begin a remote Menu replay")
            return
        }
        #expect(isPressed)
        let remoteDown = XboxCloudOverlayInputPolicy.settingMenuPressed(
            sequence.remoteMenuOverride == true,
            in: neutral
        )

        #expect(sequence.finishReplay(token: replayToken) == .remoteMenu(
            isPressed: false,
            replayToken: replayToken
        ))
        let remoteUp = XboxCloudOverlayInputPolicy.settingMenuPressed(
            sequence.remoteMenuOverride == true,
            in: neutral
        )

        var legacyEncoder = XboxLegacyInputEncoder()
        let legacyDown = try legacyEncoder.encodeGamepads(
            [remoteDown],
            version: 10,
            timestampMilliseconds: 0
        )
        let legacyUp = try legacyEncoder.encodeGamepads(
            [remoteUp],
            version: 10,
            timestampMilliseconds: 1
        )
        #expect(legacyDown[16] == UInt8(XboxGamepadButtons.menu.rawValue))
        #expect(legacyDown[17] == 0)
        #expect(legacyDown[30] == UInt8(
            XboxGamepadPhysicality.menu.rawValue
        ))
        #expect(legacyUp[16] == 0)
        #expect(legacyUp[17] == 0)
        #expect(legacyUp[30] == 0)

        var modernTracker = XboxModernInputStateTracker()
        _ = modernTracker.attach()
        let recordedModernDown = modernTracker.record(remoteDown)
        let modernDownFrame = try #require(recordedModernDown)
        let recordedModernUp = modernTracker.record(remoteUp)
        let modernUpFrame = try #require(recordedModernUp)
        let modernDown = try XboxModernInputEncoder.encode(
            modernDownFrame,
            version: 10,
            inputToken: 1,
            timestampMilliseconds: 0
        )
        let modernUp = try XboxModernInputEncoder.encode(
            modernUpFrame,
            version: 10,
            inputToken: 2,
            timestampMilliseconds: 1
        )
        #expect(modernDown[24] == 1)
        #expect(modernDown[48] == UInt8(
            XboxGamepadPhysicality.menu.rawValue
        ))
        #expect(modernUp[24] == 2)
        #expect(modernUp[48] == 0)
    }

    @Test("Pause or generation reset invalidates a pending replay token")
    func resetOverlayPress() {
        var sequence = XboxCloudOverlayInputSequence()

        #expect(sequence.update(isPressed: true, at: 10) == .none)
        let action = sequence.update(isPressed: false, at: 20)
        guard case let .remoteMenu(_, staleToken) = action else {
            Issue.record("Short press did not create a replay token")
            return
        }

        sequence.reset()
        #expect(sequence.remoteMenuOverride == nil)
        #expect(sequence.finishReplay(token: staleToken) == .none)

        #expect(sequence.update(isPressed: true, at: 30) == .none)
        let nextAction = sequence.update(isPressed: false, at: 40)
        guard case let .remoteMenu(_, currentToken) = nextAction else {
            Issue.record("New session did not create a replay token")
            return
        }
        #expect(currentToken != staleToken)
        #expect(sequence.finishReplay(token: staleToken) == .none)
        #expect(sequence.remoteMenuOverride == true)
        #expect(sequence.finishReplay(token: currentToken) == .remoteMenu(
            isPressed: false,
            replayToken: currentToken
        ))
    }

    @Test("Inbound input work is bounded under a packet burst")
    func inboundMessageBudget() {
        var budget = XboxCloudInboundMessageBudget(capacity: 2)
        budget.activate(generation: 1)

        let firstReservation = budget.reserve(generation: 1)
        let secondReservation = budget.reserve(generation: 1)
        let overCapacityReservation = budget.reserve(generation: 1)
        let handshakeReservation = budget.reserveHandshake(generation: 1)
        let duplicateHandshakeReservation = budget.reserveHandshake(
            generation: 1
        )
        #expect(firstReservation)
        #expect(secondReservation)
        #expect(!overCapacityReservation)
        #expect(handshakeReservation)
        #expect(!duplicateHandshakeReservation)
        #expect(budget.pendingCount == 2)
        #expect(budget.hasPendingHandshake)

        budget.complete(generation: 1)
        let replacementReservation = budget.reserve(generation: 1)
        #expect(replacementReservation)
        #expect(budget.pendingCount == 2)

        budget.complete(generation: 1)
        budget.complete(generation: 1)
        budget.complete(generation: 1)
        budget.completeHandshake(generation: 1)
        #expect(budget.pendingCount == 0)
        #expect(!budget.hasPendingHandshake)

        let nextHandshakeReservation = budget.reserveHandshake(generation: 1)
        #expect(nextHandshakeReservation)

        budget.activate(generation: 2)
        let staleHandshakeReservation = budget.reserveHandshake(generation: 1)
        let currentHandshakeReservation = budget.reserveHandshake(generation: 2)
        budget.completeHandshake(generation: 1)
        #expect(!staleHandshakeReservation)
        #expect(currentHandshakeReservation)
        #expect(budget.hasPendingHandshake)

        budget.deactivate(generation: 1)
        #expect(budget.activeGeneration == 2)
        budget.deactivate(generation: 2)
        #expect(budget.activeGeneration == nil)
    }

    @Test("Message handshake uses messageV1 and increments an extended CV")
    func messageHandshake() throws {
        let id = try #require(
            UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")
        )
        let data = try XboxCloudChannelProtocolCodec.messageHandshake(
            id: id,
            correlationVector: "fixture.3"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["type"] as? String == "Handshake")
        #expect(object["version"] as? String == "messageV1")
        #expect(object["id"] as? String == id.uuidString)
        #expect(object["cv"] as? String == "fixture.3.1")
    }

    @Test("Only an exact messageV1 handshake acknowledgement opens messages")
    func handshakeAcknowledgement() {
        var acknowledgement = Data(
            #"{"type":"HandshakeAck","version":"messageV1"}"#.utf8
        )
        acknowledgement.append(0)
        #expect(XboxCloudChannelProtocolCodec.isHandshakeAcknowledgement(
            acknowledgement
        ))
        #expect(!XboxCloudChannelProtocolCodec.isHandshakeAcknowledgement(
            Data(#"{"type":"HandshakeAck","version":"V2"}"#.utf8)
        ))
        #expect(!XboxCloudChannelProtocolCodec.isHandshakeAcknowledgement(
            Data(#"{"type":"Message","version":"messageV1"}"#.utf8)
        ))
        #expect(!XboxCloudChannelProtocolCodec.isHandshakeAcknowledgement(
            Data(repeating: 0, count: 4097)
        ))
    }

    @Test("Correlation vectors remain below the Microsoft 127-byte bound")
    func correlationVectorBound() throws {
        let id = UUID()
        let maximumCurrentVector = String(repeating: "a", count: 124)
        let data = try XboxCloudChannelProtocolCodec.messageHandshake(
            id: id,
            correlationVector: maximumCurrentVector
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(
            (object["cv"] as? String)?.utf8.count == 126
        )

        #expect(
            throws: XboxCloudChannelProtocolError.invalidCorrelationVector
        ) {
            try XboxCloudChannelProtocolCodec.messageHandshake(
                id: id,
                correlationVector: String(repeating: "a", count: 125)
            )
        }
        #expect(
            throws: XboxCloudChannelProtocolError.invalidCorrelationVector
        ) {
            try XboxCloudChannelProtocolCodec.messageHandshake(
                id: id,
                correlationVector: "fixture vector"
            )
        }
        #expect(
            throws: XboxCloudChannelProtocolError.invalidCorrelationVector
        ) {
            try XboxCloudChannelProtocolCodec.messageHandshake(
                id: id,
                correlationVector: "fixture.é"
            )
        }
    }

    @Test("Controller presence uses the Xbox control-channel contract")
    func gamepadChanged() throws {
        let data = try XboxCloudChannelProtocolCodec.gamepadChanged(
            index: 2,
            wasAdded: true
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["message"] as? String == "gamepadChanged")
        #expect(object["gamepadIndex"] as? Int == 2)
        #expect(object["wasAdded"] as? Bool == true)
    }

    @Test(
        "Resolution aliases use Microsoft's current Xbox control contract",
        arguments: [
            (XboxCloudDisplayResolution.automatic, "Auto"),
            (.hd, "720"),
            (.hdHighQuality, "720HQ"),
            (.fullHD, "1080"),
            (.fullHDHighQuality, "1080HQ"),
            (.qhd, "1440"),
        ]
    )
    func requestedResolutionAlias(
        resolution: XboxCloudDisplayResolution,
        expectedAlias: String
    ) throws {
        let data = try XboxCloudChannelProtocolCodec
            .userRequestedResolutionUpdate(resolution: resolution)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object.count == 2)
        #expect(
            object["message"] as? String
                == "userRequestedResolutionUpdate"
        )
        #expect(object["resolutionAlias"] as? String == expectedAlias)
        #expect(object["maxFPS"] == nil)
        #expect(object["dimensions"] == nil)
    }

    @Test("Controller axes clamp symmetrically")
    func symmetricControllerAxes() {
        #expect(XboxCloudInputValueMapper.signedAxis(-2) == -32767)
        #expect(XboxCloudInputValueMapper.signedAxis(-1) == -32767)
        #expect(XboxCloudInputValueMapper.signedAxis(0) == 0)
        #expect(XboxCloudInputValueMapper.signedAxis(1) == 32767)
        #expect(XboxCloudInputValueMapper.signedAxis(2) == 32767)
    }

    @Test("Injected deadzone removes resting thumbstick drift")
    func controllerDeadzone() {
        let resting = XboxCloudInputValueMapper.thumbstickValues(
            x: 0.1,
            y: -0.1,
            deadzone: 0.15
        )
        #expect(resting.x == 0)
        #expect(resting.y == 0)

        let active = XboxCloudInputValueMapper.thumbstickValues(
            x: 0.5,
            y: 0,
            deadzone: 0.15
        )
        #expect(active.x > 0)
        #expect(active.y == 0)
    }

    @Test("GameController vertical axes use Xbox wire orientation")
    func controllerYAxisOrientation() {
        let pushedUp = XboxCloudInputValueMapper.thumbstickValues(
            x: 0,
            y: 1,
            deadzone: 0
        )
        let pushedDown = XboxCloudInputValueMapper.thumbstickValues(
            x: 0,
            y: -1,
            deadzone: 0
        )

        #expect(pushedUp.y == 32767)
        #expect(pushedDown.y == -32767)
    }

    @Test("An active stick marks both Xbox physicality axes")
    func controllerStickPhysicality() {
        #expect(XboxCloudInputValueMapper.thumbstickPhysicality(
            x: 100,
            y: 0,
            xAxis: .leftThumbXAxis,
            yAxis: .leftThumbYAxis
        ) == [.leftThumbXAxis, .leftThumbYAxis])
        #expect(XboxCloudInputValueMapper.thumbstickPhysicality(
            x: 0,
            y: 0,
            xAxis: .rightThumbXAxis,
            yAxis: .rightThumbYAxis
        ).isEmpty)
    }

    @Test("Only changed controller mappings enter the next report")
    func cachesAcknowledgedControllerMappings() {
        var cache = XboxCloudInputStateCache()
        let resting = XboxGamepadState(index: 0)
        let pressed = XboxGamepadState(index: 0, buttons: [.a])
        var dirtyStates: [XboxGamepadState] = []
        dirtyStates.reserveCapacity(4)

        cache.appendIfDirty(resting, to: &dirtyStates)
        #expect(dirtyStates == [resting])
        cache.recordSendAttempt(dirtyStates, at: 1, accepted: true)

        dirtyStates.removeAll(keepingCapacity: true)
        cache.appendIfDirty(resting, to: &dirtyStates)
        #expect(dirtyStates.isEmpty)

        cache.appendIfDirty(pressed, to: &dirtyStates)
        #expect(dirtyStates == [pressed])
        cache.recordSendAttempt(dirtyStates, at: 8_000_001, accepted: false)

        dirtyStates.removeAll(keepingCapacity: true)
        cache.appendIfDirty(pressed, to: &dirtyStates)
        #expect(dirtyStates == [pressed])

        cache.recordSendAttempt(
            dirtyStates,
            at: 16_000_001,
            accepted: true
        )
        dirtyStates.removeAll(keepingCapacity: true)
        cache.appendIfDirty(pressed, to: &dirtyStates)
        #expect(dirtyStates.isEmpty)

        cache.invalidate(index: 0)
        cache.appendIfDirty(pressed, to: &dirtyStates)
        #expect(dirtyStates == [pressed])
    }

    @Test("Input send attempts observe an eight millisecond floor")
    func minimumInputSendInterval() {
        var cache = XboxCloudInputStateCache()
        let initialTimestamp: UInt64 = 42

        #expect(cache.canAttemptSend(at: initialTimestamp))
        cache.recordSendAttempt(
            [XboxGamepadState(index: 0)],
            at: initialTimestamp,
            accepted: true
        )
        #expect(!cache.canAttemptSend(at: initialTimestamp + 7_999_999))
        #expect(cache.canAttemptSend(at: initialTimestamp + 8_000_000))

        cache.reset()
        #expect(cache.canAttemptSend(at: initialTimestamp))
    }
}
