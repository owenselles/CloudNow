import Foundation

/// SDP manipulation for GeForce NOW WebRTC sessions.
/// Filters codec choice and injects bandwidth hints into the SDP answer.
enum SDPMunger {
    // MARK: - Codec Preference

    /// Removes all video payload types except the preferred codec.
    /// Apply to the remote offer before setRemoteDescription so the answer
    /// reflects the user's codec choice.
    static func preferCodec(_ sdp: String, codec: VideoCodec, preferTenBit: Bool = false) -> String {
        let targetName = rtpName(for: codec)
        let sep = sdp.contains("\r\n") ? "\r\n" : "\n"
        let lines = sdp.components(separatedBy: sep)

        // Collect payload types that match the target codec
        var allowedPTs = Set<String>()
        for line in lines where line.hasPrefix("a=rtpmap:") {
            let rest = line.dropFirst("a=rtpmap:".count)
            let parts = rest.components(separatedBy: " ")
            guard parts.count >= 2 else { continue }
            let pt = String(parts[0])
            let name = parts[1].components(separatedBy: "/").first?.lowercased() ?? ""
            let isMatch = name == targetName || (codec == .h265 && name == "hevc")
            if isMatch { allowedPTs.insert(pt) }
        }

        guard !allowedPTs.isEmpty else {
            if codec != .h264 { return preferCodec(sdp, codec: .h264) }
            return sdp
        }

        // Also include RTX payload types associated (via apt=) with allowed PTs
        for line in lines where line.hasPrefix("a=fmtp:") {
            let rest = line.dropFirst("a=fmtp:".count)
            let parts = rest.components(separatedBy: " ")
            guard parts.count >= 2 else { continue }
            let rtxPt = String(parts[0])
            let params = parts.dropFirst().joined(separator: " ")
            if let aptRange = params.range(of: "apt=") {
                let apt = String(params[aptRange.upperBound...])
                    .components(separatedBy: CharacterSet(charactersIn: "; ")).first ?? ""
                if allowedPTs.contains(apt) { allowedPTs.insert(rtxPt) }
            }
        }

        // For H.265, prefer a profile by sorting its PTs to the front (WebRTC picks the
        // first PT). HDR/10-bit needs Main10 (profile-id=2); SDR uses Main (profile-id=1).
        let preferredProfileId = preferTenBit ? "profile-id=2" : "profile-id=1"
        var h265PreferredPTs: [String] = []
        var h265OtherPTs: [String] = []
        if codec == .h265 {
            for pt in allowedPTs {
                let isPreferred = lines.contains(where: {
                    $0.hasPrefix("a=fmtp:\(pt) ") && $0.contains(preferredProfileId)
                })
                if isPreferred { h265PreferredPTs.append(pt) } else { h265OtherPTs.append(pt) }
            }
        }

        var result: [String] = []
        var inVideo = false

        for line in lines {
            if line.hasPrefix("m=video") {
                inVideo = true
                // Rewrite the m= line, preserving only allowed PTs
                let parts = line.components(separatedBy: " ")
                if parts.count > 3 {
                    let header = Array(parts.prefix(3))
                    var orderedPTs: [String]
                    if codec == .h265 {
                        // Preferred profile first, then others, then their RTX counterparts
                        orderedPTs = h265PreferredPTs.sorted() + h265OtherPTs.sorted()
                        let rtxPTs = allowedPTs.subtracting(Set(orderedPTs))
                        orderedPTs += rtxPTs.sorted()
                    } else {
                        orderedPTs = parts.dropFirst(3).filter { allowedPTs.contains($0) }
                    }
                    result.append((header + orderedPTs).joined(separator: " "))
                } else {
                    result.append(line)
                }
                continue
            }
            if line.hasPrefix("m=") { inVideo = false }

            // Drop attribute lines for non-allowed PTs in the video section
            if inVideo, let pt = attributeLinePT(line), !allowedPTs.contains(pt) {
                continue
            }
            result.append(line)
        }
        return result.joined(separator: sep)
    }

    // MARK: - Bandwidth Injection

    /// Appends b=AS: bandwidth hints after each m=video and m=audio line.
    /// Skips injection if a b= line already follows (idempotent).
    /// Also appends stereo=1 to the opus fmtp line for stereo audio.
    static func injectBandwidth(_ sdp: String, videoKbps: Int, audioKbps: Int = 128) -> String {
        let sep = sdp.contains("\r\n") ? "\r\n" : "\n"
        let lines = sdp.components(separatedBy: sep)
        var result: [String] = []
        for (i, line) in lines.enumerated() {
            // Append stereo=1 to the opus fmtp line if not already present
            if line.hasPrefix("a=fmtp:") && line.contains("minptime=") && !line.contains("stereo=1") {
                result.append(line + ";stereo=1")
                continue
            }
            result.append(line)
            // Inject b=AS: only if the very next line doesn't already start with b=
            let next = i + 1 < lines.count ? lines[i + 1] : ""
            if line.hasPrefix("m=video"), !next.hasPrefix("b=") {
                result.append("b=AS:\(videoKbps)")
            } else if line.hasPrefix("m=audio"), !next.hasPrefix("b=") {
                result.append("b=AS:\(audioKbps)")
            }
        }
        return result.joined(separator: sep)
    }

    // MARK: - Audio Answer Munging

    /// Rewrites the first audio section (the GFN game-audio m-line, mid 0) of the answer.
    ///
    /// Stereo offers: strips RED (redundant audio) from the accepted payloads. RED makes
    /// NetEQ hold extra jitter-buffer delay to exploit the redundancy — measurable latency
    /// for no benefit on a healthy network.
    ///
    /// Surround offers: WebRTC does not advertise `multiopus` as a receive codec, so
    /// createAnswer rejects the whole m-line (port 0, mid dropped from BUNDLE), which then
    /// breaks the bundle transport. Rebuilds the section to accept multiopus with the
    /// offer's exact fmtp — the same SDP-munging path the official GFN web client uses
    /// (libwebrtc explicitly supports it and ships the multiopus decoder).
    static func mungeAudioAnswer(_ answer: String, offer: String) -> String {
        let sep = answer.contains("\r\n") ? "\r\n" : "\n"
        if let multiopus = multiopusParameters(in: offer) {
            return rebuildSurroundAudioSection(answer, multiopus: multiopus, offer: offer, sep: sep)
        }
        return stripRedFromAudioAnswer(answer, sep: sep)
    }

    /// Payload number, rtpmap suffix (e.g. "multiopus/48000/6") and fmtp params of the
    /// offer's multiopus codec, or nil for stereo offers.
    private static func multiopusParameters(in offer: String) -> (pt: String, rtpmap: String, fmtp: String)? {
        let offerSep = offer.contains("\r\n") ? "\r\n" : "\n"
        let lines = offer.components(separatedBy: offerSep)
        guard let rtpmapLine = lines.first(where: { $0.hasPrefix("a=rtpmap:") && $0.contains("multiopus/") }) else {
            return nil
        }
        let rest = String(rtpmapLine.dropFirst("a=rtpmap:".count))
        let parts = rest.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let pt = parts[0]
        let rtpmap = parts[1]
        let fmtp = lines.first(where: { $0.hasPrefix("a=fmtp:\(pt) ") })
            .map { String($0.dropFirst("a=fmtp:\(pt) ".count)) } ?? ""
        return (pt: pt, rtpmap: rtpmap, fmtp: fmtp)
    }

    /// Removes the RED payload from the answer's first audio section so the server sends
    /// plain Opus. Only the game-audio section is touched; the mic section has no RED.
    private static func stripRedFromAudioAnswer(_ answer: String, sep: String) -> String {
        let lines = answer.components(separatedBy: sep)

        // RED payload numbers declared in the first audio section
        var redPTs = Set<String>()
        var audioSectionIndex = -1
        for line in lines {
            if line.hasPrefix("m=") { audioSectionIndex += line.hasPrefix("m=audio") ? 1 : 0 }
            guard audioSectionIndex == 0, line.hasPrefix("a=rtpmap:"), line.contains(" red/") else { continue }
            if let pt = line.dropFirst("a=rtpmap:".count).components(separatedBy: " ").first {
                redPTs.insert(String(pt))
            }
        }
        guard !redPTs.isEmpty else { return answer }

        var result: [String] = []
        var inFirstAudio = false
        var seenAudio = false
        for line in lines {
            if line.hasPrefix("m=audio"), !seenAudio {
                seenAudio = true
                inFirstAudio = true
                let parts = line.components(separatedBy: " ")
                let header = Array(parts.prefix(3))
                let pts = parts.dropFirst(3).filter { !redPTs.contains($0) }
                result.append((header + pts).joined(separator: " "))
                continue
            }
            if line.hasPrefix("m=") { inFirstAudio = false }
            if inFirstAudio, let pt = attributeLinePT(line), redPTs.contains(pt) { continue }
            result.append(line)
        }
        return result.joined(separator: sep)
    }

    /// Replaces the answer's (rejected) first audio section with one accepting the offer's
    /// multiopus codec, reusing the bundle's transport attributes and restoring the mid in
    /// the BUNDLE group. RED is intentionally not re-added (see stripRedFromAudioAnswer).
    private static func rebuildSurroundAudioSection(
        _ answer: String,
        multiopus: (pt: String, rtpmap: String, fmtp: String),
        offer: String,
        sep: String
    ) -> String {
        let lines = answer.components(separatedBy: sep)

        // Transport attributes shared by the bundle — copy from the video section, which
        // always negotiates successfully.
        var transport: [String] = []
        var inVideo = false
        for line in lines {
            if line.hasPrefix("m=video") { inVideo = true; continue }
            if line.hasPrefix("m=") { inVideo = false }
            guard inVideo else { continue }
            if line.hasPrefix("a=ice-ufrag:") || line.hasPrefix("a=ice-pwd:")
                || line.hasPrefix("a=ice-options:") || line.hasPrefix("a=fingerprint:")
                || line.hasPrefix("a=setup:")
            {
                transport.append(line)
            }
        }
        guard !transport.isEmpty else { return answer }

        // The mid of the offer's first audio section (GFN uses 0, but read it to be safe)
        let offerSep = offer.contains("\r\n") ? "\r\n" : "\n"
        var audioMid = "0"
        var inOfferAudio = false
        for line in offer.components(separatedBy: offerSep) {
            if line.hasPrefix("m=audio") { inOfferAudio = true; continue }
            if line.hasPrefix("m=") { inOfferAudio = false }
            if inOfferAudio, line.hasPrefix("a=mid:") {
                audioMid = String(line.dropFirst("a=mid:".count))
                break
            }
        }

        var section = ["m=audio 9 UDP/TLS/RTP/SAVPF \(multiopus.pt)"]
        section.append("b=AS:256")
        section.append("c=IN IP4 0.0.0.0")
        section.append("a=rtcp:9 IN IP4 0.0.0.0")
        section += transport
        section.append("a=mid:\(audioMid)")
        section.append("a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01")
        section.append("a=recvonly")
        section.append("a=rtcp-mux")
        section.append("a=rtcp-rsize")
        section.append("a=rtpmap:\(multiopus.pt) \(multiopus.rtpmap)")
        section.append("a=rtcp-fb:\(multiopus.pt) transport-cc")
        if !multiopus.fmtp.isEmpty {
            section.append("a=fmtp:\(multiopus.pt) \(multiopus.fmtp)")
        }

        // Swap the rejected section for the rebuilt one and restore the mid in BUNDLE
        var result: [String] = []
        var skippingRejected = false
        var replaced = false
        for line in lines {
            if line.hasPrefix("a=group:BUNDLE") {
                var mids = line.dropFirst("a=group:BUNDLE".count)
                    .components(separatedBy: " ").filter { !$0.isEmpty }
                if !mids.contains(audioMid) { mids.insert(audioMid, at: 0) }
                result.append("a=group:BUNDLE " + mids.joined(separator: " "))
                continue
            }
            if line.hasPrefix("m=audio"), !replaced {
                replaced = true
                skippingRejected = true
                result += section
                continue
            }
            if skippingRejected {
                if line.hasPrefix("m=") { skippingRejected = false } else { continue }
            }
            result.append(line)
        }
        return result.joined(separator: sep)
    }

    // MARK: - H.265 Safety Rewrites

    /// Rewrites `tier-flag=1` → `tier-flag=0` in all H.265 fmtp lines.
    /// The server may advertise High tier which Apple's hardware decoder may reject.
    static func rewriteH265TierFlag(_ sdp: String) -> String {
        let sep = sdp.contains("\r\n") ? "\r\n" : "\n"
        let lines = sdp.components(separatedBy: sep)
        var h265PTs = Set<String>()
        var inVideo = false

        for line in lines {
            if line.hasPrefix("m=video") { inVideo = true; continue }
            if line.hasPrefix("m=") { inVideo = false }
            guard inVideo, line.hasPrefix("a=rtpmap:") else { continue }
            let rest = String(line.dropFirst("a=rtpmap:".count))
            let parts = rest.components(separatedBy: " ")
            guard parts.count >= 2 else { continue }
            let name = parts[1].components(separatedBy: "/").first?.uppercased() ?? ""
            if name == "H265" || name == "HEVC" { h265PTs.insert(String(parts[0])) }
        }

        guard !h265PTs.isEmpty else { return sdp }

        let rewritten = lines.map { line -> String in
            guard line.hasPrefix("a=fmtp:") else { return line }
            let pt = String(line.dropFirst("a=fmtp:".count)).components(separatedBy: " ").first ?? ""
            guard h265PTs.contains(pt) else { return line }
            return line.replacingOccurrences(of: "tier-flag=1", with: "tier-flag=0",
                                             options: .caseInsensitive)
        }
        return rewritten.joined(separator: sep)
    }

    /// Caps H.265 `level-id` values to hardware-safe maximums per profile.
    /// Apple TV hardware decoder: Profile 1 (Main) → max 183 (L5.1); Profile 2 (Main10) → max 153 (L5.0).
    static func rewriteH265LevelId(_ sdp: String) -> String {
        let maxLevelByProfile: [Int: Int] = [1: 183, 2: 153]
        let sep = sdp.contains("\r\n") ? "\r\n" : "\n"
        let lines = sdp.components(separatedBy: sep)
        var h265PTs = Set<String>()
        var inVideo = false

        for line in lines {
            if line.hasPrefix("m=video") { inVideo = true; continue }
            if line.hasPrefix("m=") { inVideo = false }
            guard inVideo, line.hasPrefix("a=rtpmap:") else { continue }
            let rest = String(line.dropFirst("a=rtpmap:".count))
            let parts = rest.components(separatedBy: " ")
            guard parts.count >= 2 else { continue }
            let name = parts[1].components(separatedBy: "/").first?.uppercased() ?? ""
            if name == "H265" || name == "HEVC" { h265PTs.insert(String(parts[0])) }
        }

        guard !h265PTs.isEmpty else { return sdp }

        let rewritten = lines.map { line -> String in
            guard line.hasPrefix("a=fmtp:") else { return line }
            let afterColon = String(line.dropFirst("a=fmtp:".count))
            let parts = afterColon.components(separatedBy: " ")
            guard let pt = parts.first, h265PTs.contains(pt) else { return line }
            let params = parts.dropFirst().joined(separator: " ")

            guard let profileMatch = params.range(of: #"profile-id=(\d+)"#, options: .regularExpression),
                  let levelMatch = params.range(of: #"level-id=(\d+)"#, options: .regularExpression)
            else {
                return line
            }
            let profileNum = Int(String(params[profileMatch]).components(separatedBy: "=").last ?? "") ?? 0
            let levelNum = Int(String(params[levelMatch]).components(separatedBy: "=").last ?? "") ?? 0
            guard let maxLevel = maxLevelByProfile[profileNum], levelNum > maxLevel else { return line }
            return line.replacingOccurrences(of: "level-id=\(levelNum)", with: "level-id=\(maxLevel)",
                                             options: .caseInsensitive)
        }
        return rewritten.joined(separator: sep)
    }

    // MARK: - Private

    private static func rtpName(for codec: VideoCodec) -> String {
        switch codec {
        case .h264: "h264"
        case .h265: "h265"
        case .av1: "av1"
        }
    }

    /// Extracts the payload type number from an rtpmap/fmtp/rtcp-fb attribute line.
    private static func attributeLinePT(_ line: String) -> String? {
        for prefix in ["a=rtpmap:", "a=fmtp:", "a=rtcp-fb:"] {
            if line.hasPrefix(prefix) {
                return line.dropFirst(prefix.count)
                    .components(separatedBy: " ").first.map { String($0) }
            }
        }
        return nil
    }
}
