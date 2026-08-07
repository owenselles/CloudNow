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

    @Test("Control frames retry on backpressure and reset after reopen")
    func controlFrameRetryAndReopen() {
        var state = XboxCloudControlSendState()

        #expect(!state.shouldSendAuthorization)
        #expect(!state.shouldSendResolutionUpdate)

        state.channelStateChanged(isOpen: true)
        #expect(state.shouldSendAuthorization)
        #expect(state.shouldSendResolutionUpdate)

        state.recordResolutionUpdate(disposition: .backpressured)
        state.recordAuthorization(disposition: .channelUnavailable)
        #expect(state.shouldSendAuthorization)
        #expect(state.shouldSendResolutionUpdate)

        state.recordResolutionUpdate(disposition: .accepted)
        state.recordAuthorization(disposition: .payloadTooLarge)
        #expect(state.shouldSendAuthorization)
        #expect(!state.shouldSendResolutionUpdate)

        state.recordAuthorization(disposition: .accepted)
        #expect(!state.shouldSendAuthorization)
        #expect(!state.shouldSendResolutionUpdate)

        state.channelStateChanged(isOpen: false)
        #expect(!state.shouldSendAuthorization)
        #expect(!state.shouldSendResolutionUpdate)

        state.channelStateChanged(isOpen: true)
        #expect(state.shouldSendAuthorization)
        #expect(state.shouldSendResolutionUpdate)
    }

    @Test("Authorization precedes the preferred-resolution update")
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
        #expect(!state.canSendResolutionUpdate)
        #expect(state.canSendAuthorization)

        state.didSendAuthorization = true
        #expect(state.canSendAuthorization)
        #expect(state.canSendResolutionUpdate)
        #expect(!state.isPublishedReady(
            isMessageChannelOpen: true,
            didReceiveMessageHandshake: true
        ))

        state.didSendResolutionUpdate = true
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
