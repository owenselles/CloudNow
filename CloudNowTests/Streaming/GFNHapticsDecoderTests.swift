@testable import CloudNow
import Foundation
import Testing

@Suite("GFN haptics decoding")
struct GFNHapticsDecoderTests {
    struct FixtureCase: Sendable {
        let name: String
        let expected: RumbleExpectation
    }

    struct RumbleExpectation: Sendable {
        let controllerId: Int
        let weak: UInt16
        let strong: UInt16
    }

    @Test(
        "Recognized haptics packet layouts decode little-endian motor values",
        arguments: [
            FixtureCase(
                name: "legacy.hex",
                expected: RumbleExpectation(controllerId: 2, weak: 0x1234, strong: 0xABCD)
            ),
            FixtureCase(
                name: "prefixed-legacy.hex",
                expected: RumbleExpectation(controllerId: 3, weak: 0x2211, strong: 0x4433)
            ),
            FixtureCase(
                name: "submessage-267.hex",
                expected: RumbleExpectation(controllerId: 1, weak: 0x3456, strong: 0x789A)
            ),
            FixtureCase(
                name: "oc-report-17.hex",
                expected: RumbleExpectation(controllerId: 2, weak: 0x1200, strong: 0x3400)
            ),
        ]
    )
    func recognizedFixtures(testCase: FixtureCase) throws {
        let data = try TestFixture.hexData(testCase.name, subdirectory: "Haptics")
        let command = try #require(GFNHapticsDecoder.decode(data))

        #expect(command.controllerId == testCase.expected.controllerId)
        #expect(command.weak == testCase.expected.weak)
        #expect(command.strong == testCase.expected.strong)
    }

    @Test(
        "Recognized non-haptics message kinds are intentionally ignored",
        arguments: [UInt8(0x20), 0x21, 0x23, 0x24, 0xFF]
    )
    func ignoredMessageKinds(kind: UInt8) {
        #expect(GFNHapticsDecoder.decode(Data([kind, 0])) == nil)
    }

    @Test("Unknown submessage types are ignored")
    func unknownSubmessageType() {
        let packet = Data([0x22, 0xFE, 0xCA, 0x00, 0x00])

        #expect(GFNHapticsDecoder.decode(packet) == nil)
    }

    @Test(
        "Invalid legacy kind and length are rejected",
        arguments: [
            Data([2, 0, 6, 0, 0, 0, 1, 0, 2, 0]),
            Data([1, 0, 5, 0, 0, 0, 1, 0, 2, 0]),
        ]
    )
    func invalidLegacyPacket(packet: Data) {
        #expect(GFNHapticsDecoder.decode(packet) == nil)
    }

    @Test(
        "Invalid OC report bounds, kind, and flags are rejected",
        arguments: [
            ocPacket(controllerByte: 5, reportKind: 5, flags: 0),
            ocPacket(controllerByte: 10, reportKind: 5, flags: 0),
            ocPacket(controllerByte: 6, reportKind: 4, flags: 0),
            ocPacket(controllerByte: 6, reportKind: 5, flags: 2),
        ]
    )
    func invalidOCReport(packet: Data) {
        #expect(GFNHapticsDecoder.decode(packet) == nil)
    }

    @Test(
        "Truncation at every boundary never yields a partial command",
        arguments: [
            "legacy.hex",
            "prefixed-legacy.hex",
            "submessage-267.hex",
            "oc-report-17.hex",
        ]
    )
    func everyTruncationBoundary(name: String) throws {
        let complete = try TestFixture.hexData(name, subdirectory: "Haptics")

        for length in 0 ..< complete.count {
            let truncated = complete.prefix(length)
            #expect(
                GFNHapticsDecoder.decode(Data(truncated)) == nil,
                "\(name) unexpectedly decoded at truncated length \(length)"
            )
        }
    }

    @Test("Empty and one-byte inputs are rejected")
    func shortestInputs() {
        #expect(GFNHapticsDecoder.decode(Data()) == nil)
        #expect(GFNHapticsDecoder.decode(Data([0x22])) == nil)
    }

    @Test("Deterministic short-input fuzzing never traps")
    func deterministicFuzzing() {
        var state: UInt64 = 0xC10D_CAFE_5EED

        for sample in 0 ..< 1024 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let length = sample % 18
            var bytes: [UInt8] = []
            bytes.reserveCapacity(length)
            for _ in 0 ..< length {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                bytes.append(UInt8(truncatingIfNeeded: state >> 32))
            }

            if let command = GFNHapticsDecoder.decode(Data(bytes)) {
                #expect((0 ... Int(UInt16.max)).contains(command.controllerId))
            }
        }
    }

    private static func ocPacket(
        controllerByte: UInt8,
        reportKind: UInt8,
        flags: UInt8
    ) -> Data {
        Data([
            0x22,
            17, 0, 0, 0,
            controllerByte, 0, 0, reportKind, flags, 0, 0, 1, 2,
        ])
    }
}
