@testable import CloudNow
import CoreMedia
import Foundation
import Testing

struct H265AnnexBConverterTests {
    @Test("Annex-B parser recognizes mixed start-code lengths without copying payloads")
    func parsesMixedStartCodes() {
        let data = Data([
            0, 0, 0, 1, 0x40, 0x01, 0xAA,
            0, 0, 1, 0x42, 0x01, 0xBB,
            0, 0, 0, 1, 0x44, 0x01, 0xCC, 0xDD,
        ])

        let units = H265AnnexBConverter.nalUnits(in: data)

        #expect(units == [
            .init(range: 4 ..< 7, type: 32),
            .init(range: 10 ..< 13, type: 33),
            .init(range: 17 ..< 21, type: 34),
        ])
    }

    @Test("AVCC output has one big-endian length prefix per NAL unit")
    func createsExpectedAVCCBytes() throws {
        let data = Data([
            0, 0, 0, 1, 0x40, 0x01, 0xAA,
            0, 0, 1, 0x42, 0x01, 0xBB,
            0, 0, 0, 1, 0x44, 0x01, 0xCC, 0xDD,
        ])
        let units = H265AnnexBConverter.nalUnits(in: data)
        let blockBuffer = try #require(H265AnnexBConverter.makeAVCCBlockBuffer(data: data, nalus: units))

        #expect(try bytes(in: blockBuffer) == Data([
            0, 0, 0, 3, 0x40, 0x01, 0xAA,
            0, 0, 0, 3, 0x42, 0x01, 0xBB,
            0, 0, 0, 4, 0x44, 0x01, 0xCC, 0xDD,
        ]))
    }

    @Test(
        "Malformed access units yield no NAL units",
        arguments: [
            Data(),
            Data([0x40, 0x01, 0xAA]),
            Data([0, 0, 1]),
            Data([0, 0, 0, 1]),
        ]
    )
    func rejectsMalformedAccessUnits(_ data: Data) {
        #expect(H265AnnexBConverter.nalUnits(in: data).isEmpty)
    }

    @Test("Only VPS, SPS, or PPS payload changes alter the parameter-set signature")
    func detectsParameterSetChanges() throws {
        let baseline = Data([
            0, 0, 1, 0x40, 0x01, 0xAA,
            0, 0, 1, 0x42, 0x01, 0xBB,
            0, 0, 1, 0x44, 0x01, 0xCC,
            0, 0, 1, 0x26, 0x01, 0xDD,
        ])
        let differentFrame = Data([
            0, 0, 1, 0x40, 0x01, 0xAA,
            0, 0, 1, 0x42, 0x01, 0xBB,
            0, 0, 1, 0x44, 0x01, 0xCC,
            0, 0, 1, 0x26, 0x01, 0xEE,
        ])
        let changedPPS = Data([
            0, 0, 1, 0x40, 0x01, 0xAA,
            0, 0, 1, 0x42, 0x01, 0xBB,
            0, 0, 1, 0x44, 0x01, 0xCD,
            0, 0, 1, 0x26, 0x01, 0xDD,
        ])

        let baselineSets = try #require(parameterSets(in: baseline))
        let differentFrameSets = try #require(parameterSets(in: differentFrame))
        let changedSets = try #require(parameterSets(in: changedPPS))

        #expect(baselineSets.signature == differentFrameSets.signature)
        #expect(baselineSets.signature != changedSets.signature)
    }

    @Test("CoreMedia owns AVCC bytes after the input Data lifetime ends")
    func blockBufferOwnsConvertedBytes() throws {
        let expected = Data([0, 0, 0, 3, 0x26, 0x01, 0xAB])
        let blockBuffer: CMBlockBuffer = try {
            var source = Data([0, 0, 1, 0x26, 0x01, 0xAB])
            let units = H265AnnexBConverter.nalUnits(in: source)
            let block = try #require(H265AnnexBConverter.makeAVCCBlockBuffer(data: source, nalus: units))
            source.resetBytes(in: source.startIndex ..< source.endIndex)
            return block
        }()

        #expect(try bytes(in: blockBuffer) == expected)
    }

    private func parameterSets(in data: Data) -> H265AnnexBConverter.ParameterSets? {
        H265AnnexBConverter.parameterSets(
            in: data,
            nalus: H265AnnexBConverter.nalUnits(in: data)
        )
    }

    private func bytes(in blockBuffer: CMBlockBuffer) throws -> Data {
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var result = Data(count: length)
        let status = result.withUnsafeMutableBytes { destination in
            guard let baseAddress = destination.baseAddress else {
                return OSStatus(kCMBlockBufferBadPointerParameterErr)
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: baseAddress
            )
        }
        try #require(status == noErr)
        return result
    }
}
