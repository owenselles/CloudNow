import Foundation

nonisolated struct RumbleCommand: Equatable {
    let controllerId: Int
    let weak: UInt16
    let strong: UInt16
}

nonisolated enum GFNHapticsDecoder {
    static func decode(_ data: Data) -> RumbleCommand? {
        let bytes = [UInt8](data)
        guard let firstWord = readUInt16LE(bytes, at: 0) else { return nil }

        if firstWord == 267 {
            return parseLegacy(bytes, at: 2)
        }

        switch firstWord & 0x00FF {
        case 0x22:
            return parseSubMessage(bytes, at: 1)
        case 0x20, 0x21, 0x23, 0x24, 0xFF:
            return nil
        default:
            return parseLegacy(bytes, at: 0)
        }
    }

    private static func parseSubMessage(_ bytes: [UInt8], at offset: Int) -> RumbleCommand? {
        guard let type = readUInt32LE(bytes, at: offset) else { return nil }

        switch type {
        case 267:
            return parseLegacy(bytes, at: offset + 4)
        case 17:
            return parseOc(bytes, at: offset + 4)
        default:
            return nil
        }
    }

    private static func parseLegacy(_ bytes: [UInt8], at offset: Int) -> RumbleCommand? {
        guard
            let kind = readUInt16LE(bytes, at: offset),
            let length = readUInt16LE(bytes, at: offset + 2),
            let controllerId = readUInt16LE(bytes, at: offset + 4),
            let weak = readUInt16LE(bytes, at: offset + 6),
            let strong = readUInt16LE(bytes, at: offset + 8)
        else { return nil }

        guard kind == 1, length >= 6 else { return nil }

        return RumbleCommand(
            controllerId: Int(controllerId),
            weak: weak,
            strong: strong
        )
    }

    private static func parseOc(_ bytes: [UInt8], at offset: Int) -> RumbleCommand? {
        guard
            let cb = readUInt8(bytes, at: offset),
            let reportKind = readUInt8(bytes, at: offset + 3),
            let flags = readUInt8(bytes, at: offset + 4),
            let weakHighByte = readUInt8(bytes, at: offset + 7),
            let strongHighByte = readUInt8(bytes, at: offset + 8)
        else { return nil }

        guard (UInt8(6) ..< UInt8(10)).contains(cb), reportKind == 5, flags & ~UInt8(1) == 0 else { return nil }

        return RumbleCommand(
            controllerId: Int(cb) - 6,
            weak: UInt16(weakHighByte) << 8,
            strong: UInt16(strongHighByte) << 8
        )
    }

    private static func readUInt8(_ bytes: [UInt8], at offset: Int) -> UInt8? {
        guard offset >= 0, offset < bytes.count else { return nil }
        return bytes[offset]
    }

    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard
            let low = readUInt8(bytes, at: offset),
            let high = readUInt8(bytes, at: offset + 1)
        else { return nil }

        return UInt16(low) | UInt16(high) << 8
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard
            let byte0 = readUInt8(bytes, at: offset),
            let byte1 = readUInt8(bytes, at: offset + 1),
            let byte2 = readUInt8(bytes, at: offset + 2),
            let byte3 = readUInt8(bytes, at: offset + 3)
        else { return nil }

        return UInt32(byte0)
            | UInt32(byte1) << 8
            | UInt32(byte2) << 16
            | UInt32(byte3) << 24
    }
}
