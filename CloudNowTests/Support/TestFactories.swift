@testable import CloudNow
import Foundation

enum TestGameFactory {
    static func make(
        id: String,
        title: String,
        genres: [String] = [],
        stores: [(code: String, owned: Bool)] = [],
        features: [GameFeature] = [],
        isInLibrary: Bool = false
    ) -> GameInfo {
        GameInfo(
            id: id,
            title: title,
            longDescription: nil,
            genres: genres,
            developer: nil,
            publisher: nil,
            contentRating: nil,
            boxArtUrl: nil,
            heroBannerUrl: nil,
            heroImageUrl: nil,
            supportedFeatures: features,
            screenshots: [],
            isInLibrary: isInLibrary,
            variants: stores.enumerated().map { index, store in
                GameVariant(
                    id: "\(id)-variant-\(index)",
                    appStore: store.code,
                    appId: nil,
                    isOwned: store.owned
                )
            }
        )
    }
}

enum TestBytes {
    static func bytes(of packet: EncodedInputPacket) -> [UInt8] {
        [UInt8](Data(bytes: packet.storage.bytes, count: packet.count))
    }

    static func uint16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func uint16BE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func uint32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    static func uint64LE(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (0 ..< 8).reduce(UInt64(0)) { value, index in
            value | UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
    }

    static func uint64BE(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (0 ..< 8).reduce(UInt64(0)) { value, index in
            value | UInt64(bytes[offset + index]) << UInt64((7 - index) * 8)
        }
    }
}
