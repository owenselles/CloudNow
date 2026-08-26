@testable import CloudNow
import Foundation
import Testing

@Suite("Input sender keyboard replay transport", .timeLimit(.minutes(1)))
struct InputSenderKeyboardReplayTests {
    @Test("Accepted sends preserve order and gate replay completion")
    func acceptedSendsPreserveOrder() async throws {
        let channel = ManualReplayChannel()
        let sender = makeSender(channel: channel)
        let completion = ReplayCompletionProbe()
        var sendIterator = channel.sends.makeAsyncIterator()
        var completionIterator = completion.values.makeAsyncIterator()
        let expectedEvents = try replayEvents(for: "a")

        #expect(sender.replaySubmittedText("a") { completion.record($0) } == .supported)

        for (index, expectedEvent) in expectedEvents.enumerated() {
            let observed = try #require(await sendIterator.next())

            #expect(try keyboardEvent(from: observed) == expectedEvent)
            #expect(channel.recordedSends().count == index + 1)
            #expect(completion.recordedResults().isEmpty)
            #expect(channel.resolve(observed, with: .accepted))
        }

        #expect(try #require(await completionIterator.next()) == .completed)
        #expect(channel.recordedSends().count == expectedEvents.count)
        #expect(completion.recordedResults() == [.completed])
    }

    @Test("Rejected sends retry three times and stop before Enter")
    func rejectionStopsBeforeEnter() async throws {
        let channel = ManualReplayChannel()
        let sender = makeSender(channel: channel)
        let completion = ReplayCompletionProbe()
        var sendIterator = channel.sends.makeAsyncIterator()
        var completionIterator = completion.values.makeAsyncIterator()

        #expect(sender.replaySubmittedText("a") { completion.record($0) } == .supported)

        var attempts: [KeyboardReplayEvent] = []
        for _ in 0 ..< 3 {
            let observed = try #require(await sendIterator.next())
            let event = try keyboardEvent(from: observed)
            attempts.append(event)
            #expect(channel.resolve(observed, with: .rejected))
        }

        #expect(try #require(await completionIterator.next()) == .transportFailure)
        let expectedEvents = try replayEvents(for: "a")
        let firstExpectedEvent = try #require(expectedEvents.first)
        #expect(attempts == Array(repeating: firstExpectedEvent, count: 3))
        #expect(channel.recordedSends().count == 3)
        #expect(attempts.allSatisfy { $0.virtualKey != 0x0D })
    }

    @Test("A failed replay releases an accepted modifier best-effort")
    func failureReleasesAcceptedModifier() async throws {
        let channel = ManualReplayChannel()
        let sender = makeSender(channel: channel)
        let completion = ReplayCompletionProbe()
        var sendIterator = channel.sends.makeAsyncIterator()
        var completionIterator = completion.values.makeAsyncIterator()

        #expect(sender.replaySubmittedText("A") { completion.record($0) } == .supported)

        let shiftDown = try #require(await sendIterator.next())
        #expect(try keyboardEvent(from: shiftDown) == event(true, 0xA0, 0x2A, 0x0001))
        #expect(channel.resolve(shiftDown, with: .accepted))

        for _ in 0 ..< 3 {
            let letterDown = try #require(await sendIterator.next())
            #expect(try keyboardEvent(from: letterDown) == event(true, 0x41, 0x1E, 0x0001))
            #expect(channel.resolve(letterDown, with: .rejected))
        }

        let shiftUp = try #require(await sendIterator.next())
        #expect(try keyboardEvent(from: shiftUp) == event(false, 0xA0, 0x2A, 0))
        #expect(completion.recordedResults().isEmpty)
        #expect(channel.resolve(shiftUp, with: .rejected))

        #expect(try #require(await completionIterator.next()) == .transportFailure)
        #expect(channel.recordedSends().count == 5)
    }

    @Test("Channel unavailability exhausts retries as transport failure")
    func unavailableChannelCompletesAsTransportFailure() async throws {
        let channel = ManualReplayChannel()
        let sender = makeSender(channel: channel)
        let completion = ReplayCompletionProbe()
        var sendIterator = channel.sends.makeAsyncIterator()
        var completionIterator = completion.values.makeAsyncIterator()

        #expect(sender.replaySubmittedText("a") { completion.record($0) } == .supported)

        for _ in 0 ..< 3 {
            let observed = try #require(await sendIterator.next())
            #expect(channel.resolve(observed, with: .channelUnavailable))
        }

        #expect(try #require(await completionIterator.next()) == .transportFailure)
        #expect(channel.recordedSends().count == 3)
    }

    @Test("Stopping an in-flight replay completes as cancelled")
    func stopCancelsInFlightReplay() async throws {
        let channel = ManualReplayChannel()
        let sender = makeSender(channel: channel)
        let completion = ReplayCompletionProbe()
        var sendIterator = channel.sends.makeAsyncIterator()
        var completionIterator = completion.values.makeAsyncIterator()

        #expect(sender.replaySubmittedText("a") { completion.record($0) } == .supported)

        let observed = try #require(await sendIterator.next())
        sender.stop()
        #expect(channel.resolve(observed, with: .accepted))

        #expect(try #require(await completionIterator.next()) == .cancelled)
        #expect(channel.recordedSends().count == 1)
        #expect(completion.recordedResults() == [.cancelled])
    }

    private func makeSender(channel: DataChannelSender) -> InputSender {
        let sender = InputSender(channel: channel)
        sender.configure(
            protocolVersion: 2,
            deadzone: 0.15,
            overlayTriggerButton: .start,
            textInputTriggerSequence: StreamSettings.defaultTextInputTriggerSequence,
            textInputTriggerDelayMs: StreamSettings.defaultTextInputTriggerDelayMs,
            keyboardLayout: "en-US",
            steamOverlayGestureEnabled: true,
            remoteMode: .gamepad
        )
        return sender
    }

    private func replayEvents(for text: String) throws -> [KeyboardReplayEvent] {
        guard case let .supported(plan) = KeyboardReplayPlanner.plan(
            for: text,
            keyboardLayout: "en-US"
        ) else {
            Issue.record("Expected a supported replay plan")
            return []
        }
        return plan.events
    }

    private func keyboardEvent(from send: ObservedReplaySend) throws -> KeyboardReplayEvent {
        try #require(send.category == InputPacketCategory.keyboard.rawValue)
        try #require(send.bytes.count == 18 || send.bytes.count == 28)
        let payloadOffset = send.bytes.count - 18
        let packetType = TestBytes.uint32LE(send.bytes, at: payloadOffset)
        try #require(packetType == 3 || packetType == 4)
        return KeyboardReplayEvent(
            down: packetType == 3,
            virtualKey: TestBytes.uint16BE(send.bytes, at: payloadOffset + 4),
            scanCode: TestBytes.uint16BE(send.bytes, at: payloadOffset + 8),
            modifiers: TestBytes.uint16BE(send.bytes, at: payloadOffset + 6)
        )
    }

    private func event(
        _ down: Bool,
        _ virtualKey: UInt16,
        _ scanCode: UInt16,
        _ modifiers: UInt16
    ) -> KeyboardReplayEvent {
        KeyboardReplayEvent(
            down: down,
            virtualKey: virtualKey,
            scanCode: scanCode,
            modifiers: modifiers
        )
    }
}

private struct ObservedReplaySend: Sendable {
    let id: Int
    let category: String
    let bytes: [UInt8]
}

private final class ManualReplayChannel: DataChannelSender, @unchecked Sendable {
    let sends: AsyncStream<ObservedReplaySend>

    private let sendContinuation: AsyncStream<ObservedReplaySend>.Continuation
    private let lock = NSLock()
    private var nextID = 0
    private var observations: [ObservedReplaySend] = []
    private var completions: [Int: @Sendable (InputSendDisposition) -> Void] = [:]

    init() {
        let stream = AsyncStream.makeStream(of: ObservedReplaySend.self)
        sends = stream.stream
        sendContinuation = stream.continuation
    }

    func sendData(
        _ packet: EncodedInputPacket,
        completion: @escaping @Sendable (InputSendDisposition) -> Void
    ) {
        guard packet.category.rawValue == InputPacketCategory.keyboard.rawValue else {
            completion(.accepted)
            return
        }

        lock.lock()
        let observation = ObservedReplaySend(
            id: nextID,
            category: packet.category.rawValue,
            bytes: TestBytes.bytes(of: packet)
        )
        nextID += 1
        observations.append(observation)
        completions[observation.id] = completion
        lock.unlock()

        sendContinuation.yield(observation)
    }

    func resolve(_ observation: ObservedReplaySend, with disposition: InputSendDisposition) -> Bool {
        lock.lock()
        let completion = completions.removeValue(forKey: observation.id)
        lock.unlock()

        guard let completion else { return false }
        completion(disposition)
        return true
    }

    func recordedSends() -> [ObservedReplaySend] {
        lock.lock()
        defer { lock.unlock() }
        return observations
    }
}

private final class ReplayCompletionProbe: @unchecked Sendable {
    let values: AsyncStream<KeyboardReplayCompletionResult>

    private let valueContinuation: AsyncStream<KeyboardReplayCompletionResult>.Continuation
    private let lock = NSLock()
    private var results: [KeyboardReplayCompletionResult] = []

    init() {
        let stream = AsyncStream.makeStream(of: KeyboardReplayCompletionResult.self)
        values = stream.stream
        valueContinuation = stream.continuation
    }

    func record(_ result: KeyboardReplayCompletionResult) {
        lock.lock()
        results.append(result)
        lock.unlock()

        valueContinuation.yield(result)
    }

    func recordedResults() -> [KeyboardReplayCompletionResult] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }
}
