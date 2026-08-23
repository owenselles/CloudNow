import Foundation
@preconcurrency import LiveKitWebRTC

/// Decoder factory that advertises H.265 Main10 in addition to the LiveKit defaults.
///
/// `LKRTCDefaultVideoDecoderFactory` only advertises H.265 Main (profile-id=1), so
/// `createAnswer` drops a Main10 payload offered by a cloud service and a 10-bit/HDR session negotiates
/// an 8-bit stream: the server-side seat runs HDR while the client receives tone-mapped
/// SDR, and `SDPMunger.preferCodec(preferTenBit:)` has no Main10 payload left to front-load.
/// Apple TV 4K decodes HEVC Main10 in hardware with the same VideoToolbox decoder, so the
/// Main entry is cloned with profile-id=2 to keep the payload alive through negotiation.
final class CloudVideoDecoderFactory: NSObject, LKRTCVideoDecoderFactory {
    private let base = LKRTCDefaultVideoDecoderFactory()

    func createDecoder(_ info: LKRTCVideoCodecInfo) -> LKRTCVideoDecoder? {
        // H.265 uses our own VideoToolbox decoder: the built-in one crushes Main10/HDR
        // to 8-bit BT.709 — see CloudVideoDecoderH265.
        isH265(info) ? CloudVideoDecoderH265() : base.createDecoder(info)
    }

    func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        var codecs = base.supportedCodecs()
        guard !codecs.contains(where: { isH265($0) && $0.parameters["profile-id"] == "2" }) else {
            return codecs
        }
        let main10 = codecs
            .filter { isH265($0) && ($0.parameters["profile-id"] ?? "1") == "1" }
            .map { info -> LKRTCVideoCodecInfo in
                var parameters = info.parameters
                parameters["profile-id"] = "2"
                return LKRTCVideoCodecInfo(name: info.name, parameters: parameters)
            }
        codecs.append(contentsOf: main10)
        return codecs
    }

    private func isH265(_ info: LKRTCVideoCodecInfo) -> Bool {
        let name = info.name.uppercased()
        return name == "H265" || name == "HEVC"
    }
}

/// Source compatibility for the native provider while new shared runtime code
/// depends only on provider-neutral media types.
typealias GFNVideoDecoderFactory = CloudVideoDecoderFactory
