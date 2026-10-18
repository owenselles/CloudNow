import Foundation

/// Extracts the sequence header and AV1 ISOBMFF configuration needed by VideoToolbox.
/// WebRTC's AV1 depacketizer supplies low-overhead OBUs with their size fields restored.
nonisolated struct AV1StreamConfiguration: Equatable, Sendable {
    let width: Int32
    let height: Int32
    let codecConfigurationRecord: Data

    enum ParseError: Error {
        case malformedBitstream
    }

    static func parse(from data: Data) throws -> Self? {
        var offset = data.startIndex
        var configuration: Self?
        while offset < data.endIndex {
            let start = offset
            let header = data[offset]
            offset += 1
            // Forbidden/reserved bits must be zero; WebRTC always supplies a size field.
            guard header & 0x81 == 0, header & 0x02 != 0 else { throw ParseError.malformedBitstream }
            let type = (header >> 3) & 0x0F
            if header & 0x04 != 0 {
                guard offset < data.endIndex, data[offset] & 0x07 == 0 else { throw ParseError.malformedBitstream }
                if type == 1, data[offset] != 0 {
                    throw ParseError.malformedBitstream
                }
                offset += 1
            }
            let size = try readSize(data, offset: &offset)
            guard size <= data.endIndex - offset else { throw ParseError.malformedBitstream }
            let end = offset + size
            if type == 1 {
                // Even 32 operating points fit comfortably inside this bound.
                guard size > 0, size <= 4096 else { throw ParseError.malformedBitstream }
                let next = try parseSequenceHeader(Data(data[offset ..< end]), obu: Data(data[start ..< end]))
                guard configuration == nil || configuration == next else { throw ParseError.malformedBitstream }
                configuration = next
            }
            offset = end
        }
        return configuration
    }

    private static func readSize(_ data: Data, offset: inout Int) throws -> Int {
        var value: UInt64 = 0
        for byteIndex in 0 ..< 8 {
            guard offset < data.endIndex else { throw ParseError.malformedBitstream }
            let byte = data[offset]
            offset += 1
            value |= UInt64(byte & 0x7F) << (byteIndex * 7)
            if byte & 0x80 == 0 {
                guard value <= UInt32.max else { throw ParseError.malformedBitstream }
                return Int(value)
            }
        }
        throw ParseError.malformedBitstream
    }

    private static func parseSequenceHeader(_ payload: Data, obu: Data) throws -> Self {
        var bits = BitReader(data: payload)
        let profile = try bits.read(3)
        let stillPicture = try bits.read(1)
        let reduced = try bits.read(1) == 1
        guard profile <= 2, !reduced || stillPicture == 1 else { throw ParseError.malformedBitstream }
        let operatingPoint = try parseOperatingPoints(&bits, reduced: reduced)
        let widthBits = try bits.read(4) + 1
        let heightBits = try bits.read(4) + 1
        let width = try bits.read(widthBits) + 1
        let height = try bits.read(heightBits) + 1
        if !reduced, try bits.read(1) == 1 {
            try bits.skip(7)
        } // Frame ID lengths.
        try bits.skip(3) // Superblock size, intra filtering, intra edge filtering.
        if !reduced {
            try skipInterFrameTools(&bits)
        }
        try bits.skip(3) // Super-resolution, CDEF, restoration.
        let color = try parseColorConfiguration(&bits, profile: profile)
        try bits.skip(1) // Film grain parameters present.
        try bits.finishWithTrailingBits()
        // The presentation delay is unspecified: it cannot be inferred from a single sample.
        var record = Data([0x81, UInt8((profile << 5) | operatingPoint.level), UInt8((operatingPoint.tier << 7) | color), 0])
        record.append(obu)
        return Self(width: Int32(width), height: Int32(height), codecConfigurationRecord: record)
    }

    private static func parseOperatingPoints(_ bits: inout BitReader, reduced: Bool) throws -> (level: Int, tier: Int) {
        if reduced {
            return try (bits.read(5), 0)
        }
        var bufferDelayBits = 0
        if try bits.read(1) == 1 { // Timing information present.
            try bits.skip(64)
            if try bits.read(1) == 1 {
                try bits.skipUVLC()
            }
            if try bits.read(1) == 1 { // Decoder model information present.
                bufferDelayBits = try bits.read(5) + 1
                try bits.skip(42)
            }
        }
        let initialDelayPresent = try bits.read(1) == 1
        let count = try bits.read(5) + 1
        var first = (level: 0, tier: 0)
        for index in 0 ..< count {
            try bits.skip(12) // Operating point IDC.
            let level = try bits.read(5)
            let tier = try level > 7 ? bits.read(1) : 0
            if index == 0 {
                first = (level, tier)
            }
            if bufferDelayBits > 0, try bits.read(1) == 1 {
                try bits.skip(2 * bufferDelayBits + 1)
            }
            if initialDelayPresent, try bits.read(1) == 1 {
                try bits.skip(4)
            }
        }
        return first
    }

    private static func skipInterFrameTools(_ bits: inout BitReader) throws {
        try bits.skip(4) // Inter-intra, masked compound, warped motion, dual filter.
        let orderHint = try bits.read(1) == 1
        if orderHint {
            try bits.skip(2)
        }
        let chooseScreenContent = try bits.read(1) == 1
        let screenContent = try chooseScreenContent ? 2 : bits.read(1)
        if screenContent > 0, try bits.read(1) == 0 {
            try bits.skip(1)
        }
        if orderHint {
            try bits.skip(3)
        }
    }

    private static func parseColorConfiguration(_ bits: inout BitReader, profile: Int) throws -> Int {
        let highBitDepth = try bits.read(1)
        let twelveBit = try profile == 2 && highBitDepth == 1 ? bits.read(1) : 0
        let monochrome = try profile == 1 ? 0 : bits.read(1)
        var primaries = 2
        var transfer = 2
        var matrix = 2
        if try bits.read(1) == 1 {
            primaries = try bits.read(8)
            transfer = try bits.read(8)
            matrix = try bits.read(8)
        }
        var subX = 0
        var subY = 0
        var chromaPosition = 0
        if monochrome == 1 {
            try bits.skip(1) // Color range.
            subX = 1
            subY = 1
        } else {
            if !(primaries == 1 && transfer == 13 && matrix == 0) {
                try bits.skip(1) // Color range.
                if profile == 0 {
                    subX = 1
                    subY = 1
                } else if profile == 2 {
                    subX = try twelveBit == 1 ? bits.read(1) : 1
                    subY = try twelveBit == 1 && subX == 1 ? bits.read(1) : 0
                }
                if subX == 1, subY == 1 {
                    chromaPosition = try bits.read(2)
                }
            }
            try bits.skip(1) // Separate UV delta Q.
        }
        return (highBitDepth << 6) | (twelveBit << 5) | (monochrome << 4) | (subX << 3) | (subY << 2) | chromaPosition
    }

    private struct BitReader {
        let data: Data
        var offset = 0

        mutating func read(_ count: Int) throws -> Int {
            guard (0 ... 32).contains(count), count <= data.count * 8 - offset else { throw ParseError.malformedBitstream }
            var value = 0
            for _ in 0 ..< count {
                value = (value << 1) | Int((data[offset / 8] >> (7 - offset % 8)) & 1)
                offset += 1
            }
            return value
        }

        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= data.count * 8 - offset else { throw ParseError.malformedBitstream }
            offset += count
        }

        mutating func skipUVLC() throws {
            var zeros = 0
            while try read(1) == 0 {
                zeros += 1
            }
            // AV1 uvlc() consumes the terminating one even for the >=32-zero sentinel.
            // The bounded sequence payload and read() check also bound this scan.
            if zeros < 32 {
                try skip(zeros)
            }
        }

        mutating func finishWithTrailingBits() throws {
            guard try read(1) == 1 else { throw ParseError.malformedBitstream }
            while offset < data.count * 8 {
                guard try read(1) == 0 else { throw ParseError.malformedBitstream }
            }
        }
    }
}
