@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox Cloud channel protocol")
struct XboxCloudInputDriverTests {
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
