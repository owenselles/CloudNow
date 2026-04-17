import Foundation

/// SDP manipulation for GeForce NOW WebRTC sessions.
/// Filters codec choice and injects bandwidth hints into the SDP answer.
enum SDPMunger {

    // MARK: - Codec Preference

    /// Removes all video payload types except the preferred codec.
    /// Apply to the remote offer before setRemoteDescription so the answer
    /// reflects the user's codec choice.
    static func preferCodec(_ sdp: String, codec: VideoCodec) -> String {
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
            if name == targetName { allowedPTs.insert(pt) }
        }

        guard !allowedPTs.isEmpty else { return sdp } // Codec not in offer; leave unchanged

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

        // For H.265, prefer Main profile (profile-id=1) by sorting its PTs to the front
        var h265MainPTs: [String] = []
        var h265OtherPTs: [String] = []
        if codec == .h265 {
            for pt in allowedPTs {
                let isMain = lines.contains(where: {
                    $0.hasPrefix("a=fmtp:\(pt) ") && $0.contains("profile-id=1")
                })
                if isMain { h265MainPTs.append(pt) } else { h265OtherPTs.append(pt) }
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
                        // Main profile first, then others, then their RTX counterparts
                        orderedPTs = h265MainPTs.sorted() + h265OtherPTs.sorted()
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
            if inVideo, let pt = videoLinePT(line), !allowedPTs.contains(pt) {
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
            if line.hasPrefix("m=video") && !next.hasPrefix("b=") {
                result.append("b=AS:\(videoKbps)")
            } else if line.hasPrefix("m=audio") && !next.hasPrefix("b=") {
                result.append("b=AS:\(audioKbps)")
            }
        }
        return result.joined(separator: sep)
    }

    // MARK: - Private

    private static func rtpName(for codec: VideoCodec) -> String {
        switch codec {
        case .h264: return "h264"
        case .h265: return "h265"
        case .av1:  return "av1"
        }
    }

    /// Extracts the payload type number from an rtpmap/fmtp/rtcp-fb attribute line.
    private static func videoLinePT(_ line: String) -> String? {
        for prefix in ["a=rtpmap:", "a=fmtp:", "a=rtcp-fb:"] {
            if line.hasPrefix(prefix) {
                return line.dropFirst(prefix.count)
                    .components(separatedBy: " ").first.map { String($0) }
            }
        }
        return nil
    }
}
