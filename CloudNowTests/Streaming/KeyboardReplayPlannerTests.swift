@testable import CloudNow
import Testing

@Suite("Keyboard replay planner")
struct KeyboardReplayPlannerTests {
    @Test("US layout emits shifted ASCII and appends Enter")
    func englishUS() throws {
        let events = try supportedEvents(for: "A@", layout: "en-US")

        #expect(events == [
            event(true, 0xA0, 0x2A, 0x0001),
            event(true, 0x41, 0x1E, 0x0001),
            event(false, 0x41, 0x1E, 0x0001),
            event(false, 0xA0, 0x2A, 0),
            event(true, 0xA0, 0x2A, 0x0001),
            event(true, 0x32, 0x03, 0x0001),
            event(false, 0x32, 0x03, 0x0001),
            event(false, 0xA0, 0x2A, 0),
            event(true, 0x0D, 0x1C, 0),
            event(false, 0x0D, 0x1C, 0),
        ])
    }

    @Test("UK layout uses the quote key for at-sign")
    func englishGB() throws {
        let events = try supportedEvents(for: "@", layout: "en_GB", appendEnter: false)

        #expect(events == [
            event(true, 0xA0, 0x2A, 0x0001),
            event(true, 0xDE, 0x28, 0x0001),
            event(false, 0xDE, 0x28, 0x0001),
            event(false, 0xA0, 0x2A, 0),
        ])
    }

    @Test("German layout swaps Z and uses AltGr plus a completed dead key")
    func germanAltGrAndDeadKey() throws {
        let events = try supportedEvents(for: "z@^", layout: "de-DE", appendEnter: false)

        #expect(events == [
            event(true, 0x59, 0x15, 0),
            event(false, 0x59, 0x15, 0),
            event(true, 0xA5, 0xE038, 0x0004),
            event(true, 0x51, 0x10, 0x0004),
            event(false, 0x51, 0x10, 0x0004),
            event(false, 0xA5, 0xE038, 0),
            event(true, 0xC0, 0x29, 0),
            event(false, 0xC0, 0x29, 0),
            event(true, 0x20, 0x39, 0),
            event(false, 0x20, 0x39, 0),
        ])
    }

    @Test("French layout maps AZERTY, shifted digits, accents, AltGr, and dead keys")
    func frenchLayout() throws {
        let events = try supportedEvents(for: "a1é€^", layout: "fr-FR", appendEnter: false)

        #expect(Array(events.prefix(2)) == [
            event(true, 0x51, 0x10, 0),
            event(false, 0x51, 0x10, 0),
        ])
        #expect(Array(events[2 ..< 6]) == [
            event(true, 0xA0, 0x2A, 0x0001),
            event(true, 0x31, 0x02, 0x0001),
            event(false, 0x31, 0x02, 0x0001),
            event(false, 0xA0, 0x2A, 0),
        ])
        #expect(Array(events[6 ..< 8]) == [
            event(true, 0x32, 0x03, 0),
            event(false, 0x32, 0x03, 0),
        ])
        #expect(Array(events[8 ..< 12]) == [
            event(true, 0xA5, 0xE038, 0x0004),
            event(true, 0x45, 0x12, 0x0004),
            event(false, 0x45, 0x12, 0x0004),
            event(false, 0xA5, 0xE038, 0),
        ])
        #expect(Array(events.suffix(4)) == [
            event(true, 0xDB, 0x1A, 0),
            event(false, 0xDB, 0x1A, 0),
            event(true, 0x20, 0x39, 0),
            event(false, 0x20, 0x39, 0),
        ])
    }

    @Test("Unsupported layouts and characters are rejected before a plan exists")
    func rejectsUnsupportedInput() {
        #expect(KeyboardReplayPlanner.plan(
            for: "hello",
            keyboardLayout: "es-ES"
        ) == .unsupportedLayout)
        #expect(KeyboardReplayPlanner.plan(
            for: "hello 🎮",
            keyboardLayout: "en-US"
        ) == .unsupportedCharacters)
    }

    @Test("Replay event count is capped including the appended Enter")
    func eventLimit() {
        let maximumText = String(repeating: "a", count: 127)
        let excessiveText = String(repeating: "a", count: 128)

        let maximumResult = KeyboardReplayPlanner.plan(
            for: maximumText,
            keyboardLayout: "en-US"
        )
        #expect(maximumResult.supportedPlan?.events.count == KeyboardReplayPlanner.maxEventCount)
        #expect(KeyboardReplayPlanner.plan(
            for: excessiveText,
            keyboardLayout: "en-US"
        ) == .tooLong)
        #expect(KeyboardReplayPlanner.plan(
            for: String(repeating: "a", count: KeyboardReplayPlanner.maxTextUTF8ByteCount + 1),
            keyboardLayout: "en-US"
        ) == .tooLong)
    }

    private func supportedEvents(
        for text: String,
        layout: String,
        appendEnter: Bool = true
    ) throws -> [KeyboardReplayEvent] {
        let result = KeyboardReplayPlanner.plan(
            for: text,
            keyboardLayout: layout,
            appendEnter: appendEnter
        )
        return try #require(result.supportedPlan).events
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

private extension KeyboardReplayPlanningResult {
    var supportedPlan: KeyboardReplayPlan? {
        guard case let .supported(plan) = self else { return nil }
        return plan
    }
}
