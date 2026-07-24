import Foundation

nonisolated struct SignalingPeerInfo: Equatable, Sendable {
    let id: Int
    let name: String?
}

nonisolated enum SignalingPeerPayload: Equatable, Sendable {
    case offer(sdp: String)
    case ice(candidate: String, sdpMid: String?, sdpMLineIndex: Int?)
    case unknown(type: String?, keys: [String])
}

nonisolated struct DecodedSignalingMessage: Equatable, Sendable {
    let peerInfo: SignalingPeerInfo?
    let acknowledgementId: Int?
    let heartbeat: Bool
    let peerFrom: Int?
    let payload: SignalingPeerPayload?
}

nonisolated enum SignalingMessageCodecError: Error, Equatable {
    case invalidUTF8
    case malformedJSON
    case missingField(String)
    case invalidField(String)
}

/// Transport-independent JSON codec for GFN signaling envelopes.
nonisolated enum SignalingMessageCodec {
    static func decode(_ text: String) throws -> DecodedSignalingMessage {
        guard let data = text.data(using: .utf8) else {
            throw SignalingMessageCodecError.invalidUTF8
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else {
            throw SignalingMessageCodecError.malformedJSON
        }

        let peerInfo: SignalingPeerInfo?
        if let rawPeerInfo = root["peer_info"] {
            guard let peerInfoObject = rawPeerInfo as? [String: Any] else {
                throw SignalingMessageCodecError.invalidField("peer_info")
            }
            guard let id = peerInfoObject["id"] as? Int else {
                throw SignalingMessageCodecError.missingField("peer_info.id")
            }
            peerInfo = SignalingPeerInfo(
                id: id,
                name: peerInfoObject["name"] as? String
            )
        } else {
            peerInfo = nil
        }

        let payload: SignalingPeerPayload?
        let peerFrom: Int?
        if let rawPeerMessage = root["peer_msg"] {
            guard let peerMessage = rawPeerMessage as? [String: Any] else {
                throw SignalingMessageCodecError.invalidField("peer_msg")
            }
            peerFrom = peerMessage["from"] as? Int
            guard let message = peerMessage["msg"] as? String else {
                throw SignalingMessageCodecError.missingField("peer_msg.msg")
            }
            guard let messageData = message.data(using: .utf8),
                  let rawPayload = try? JSONSerialization.jsonObject(with: messageData),
                  let payloadObject = rawPayload as? [String: Any]
            else {
                throw SignalingMessageCodecError.invalidField("peer_msg.msg")
            }

            if payloadObject["type"] as? String == "offer" {
                guard let sdp = payloadObject["sdp"] as? String else {
                    throw SignalingMessageCodecError.missingField("peer_msg.msg.sdp")
                }
                payload = .offer(sdp: sdp)
            } else if let candidate = payloadObject["candidate"] as? String {
                payload = .ice(
                    candidate: candidate,
                    sdpMid: payloadObject["sdpMid"] as? String,
                    sdpMLineIndex: payloadObject["sdpMLineIndex"] as? Int
                )
            } else {
                payload = .unknown(
                    type: payloadObject["type"] as? String,
                    keys: payloadObject.keys.sorted()
                )
            }
        } else {
            peerFrom = nil
            payload = nil
        }

        return DecodedSignalingMessage(
            peerInfo: peerInfo,
            acknowledgementId: root["ackid"] as? Int,
            heartbeat: root["hb"] != nil,
            peerFrom: peerFrom,
            payload: payload
        )
    }

    static func encodeAnswer(
        sdp: String,
        nvstSdp: String?,
        from: Int,
        to: Int,
        acknowledgementId: Int
    ) throws -> Data {
        var payload: [String: Any] = [
            "type": "answer",
            "sdp": sdp,
        ]
        if let nvstSdp {
            payload["nvstSdp"] = nvstSdp
        }
        return try encodePeerPayload(
            payload,
            from: from,
            to: to,
            acknowledgementId: acknowledgementId
        )
    }

    static func encodeICECandidate(
        candidate: String,
        sdpMid: String?,
        sdpMLineIndex: Int?,
        from: Int,
        to: Int,
        acknowledgementId: Int
    ) throws -> Data {
        var payload: [String: Any] = ["candidate": candidate]
        if let sdpMid {
            payload["sdpMid"] = sdpMid
        }
        if let sdpMLineIndex {
            payload["sdpMLineIndex"] = sdpMLineIndex
        }
        return try encodePeerPayload(
            payload,
            from: from,
            to: to,
            acknowledgementId: acknowledgementId
        )
    }

    static func encodeKeyframeRequest(
        reason: String,
        backlogFrames: Int,
        attempt: Int,
        from: Int,
        to: Int,
        acknowledgementId: Int
    ) throws -> Data {
        try encodePeerPayload(
            [
                "type": "request_keyframe",
                "reason": reason,
                "backlogFrames": backlogFrames,
                "attempt": attempt,
            ],
            from: from,
            to: to,
            acknowledgementId: acknowledgementId
        )
    }

    static func isTCPIceCandidate(_ candidate: String) -> Bool {
        candidate
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .contains("tcp")
    }

    private static func encodePeerPayload(
        _ payload: [String: Any],
        from: Int,
        to: Int,
        acknowledgementId: Int
    ) throws -> Data {
        let payloadData = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        guard let payloadString = String(data: payloadData, encoding: .utf8) else {
            throw SignalingMessageCodecError.invalidUTF8
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "peer_msg": [
                    "from": from,
                    "to": to,
                    "msg": payloadString,
                ],
                "ackid": acknowledgementId,
            ],
            options: [.sortedKeys]
        )
    }
}
