@testable import CloudNow
import Foundation
import Testing

@Suite("Signaling message codec")
struct SignalingMessageCodecTests {
    @Test("Decodes an SDP offer")
    func decodesOffer() throws {
        let message = try envelope(payload: [
            "type": "offer",
            "sdp": "v=0\r\n",
        ])

        let decoded = try SignalingMessageCodec.decode(message)

        #expect(decoded.peerFrom == 7)
        #expect(decoded.payload == .offer(sdp: "v=0\r\n"))
    }

    @Test("Decodes ICE candidates with optional fields")
    func decodesICECandidate() throws {
        let message = try envelope(payload: [
            "candidate": "candidate:1 1 UDP 1 192.0.2.1 10000 typ host",
            "sdpMid": "video",
            "sdpMLineIndex": 2,
        ])

        let decoded = try SignalingMessageCodec.decode(message)

        #expect(decoded.payload == .ice(
            candidate: "candidate:1 1 UDP 1 192.0.2.1 10000 typ host",
            sdpMid: "video",
            sdpMLineIndex: 2
        ))
    }

    @Test("Preserves peer, acknowledgement, and heartbeat metadata")
    func decodesEnvelopeMetadata() throws {
        let text = """
        {
          "peer_info": {"id": 9, "name": "peer-nine"},
          "ackid": 41,
          "hb": 1
        }
        """

        let decoded = try SignalingMessageCodec.decode(text)

        #expect(decoded.peerInfo == SignalingPeerInfo(id: 9, name: "peer-nine"))
        #expect(decoded.acknowledgementId == 41)
        #expect(decoded.heartbeat)
        #expect(decoded.payload == nil)
    }

    @Test("Reports unknown payloads without losing their keys")
    func reportsUnknownPayload() throws {
        let message = try envelope(payload: [
            "type": "future_message",
            "sequence": 3,
        ])

        let decoded = try SignalingMessageCodec.decode(message)

        #expect(decoded.payload == .unknown(
            type: "future_message",
            keys: ["sequence", "type"]
        ))
    }

    @Test(
        "Rejects malformed and incomplete messages",
        arguments: [
            ("{", SignalingMessageCodecError.malformedJSON),
            (#"{"peer_info":{}}"#, .missingField("peer_info.id")),
            (#"{"peer_msg":{}}"#, .missingField("peer_msg.msg")),
            (#"{"peer_msg":{"msg":"{"}}"#, .invalidField("peer_msg.msg")),
        ]
    )
    func rejectsMalformedMessages(
        text: String,
        expectedError: SignalingMessageCodecError
    ) {
        #expect(throws: expectedError) {
            try SignalingMessageCodec.decode(text)
        }
    }

    @Test("Encodes answer messages with the nested wire payload")
    func encodesAnswer() throws {
        let data = try SignalingMessageCodec.encodeAnswer(
            sdp: "v=0\n",
            nvstSdp: "nvst",
            from: 2,
            to: 1,
            acknowledgementId: 8
        )
        let envelope = try jsonObject(data)
        let peerMessage = try #require(envelope["peer_msg"] as? [String: Any])
        let payloadText = try #require(peerMessage["msg"] as? String)
        let payloadData = try #require(payloadText.data(using: .utf8))
        let payload = try jsonObject(payloadData)

        #expect(envelope["ackid"] as? Int == 8)
        #expect(peerMessage["from"] as? Int == 2)
        #expect(peerMessage["to"] as? Int == 1)
        #expect(payload["type"] as? String == "answer")
        #expect(payload["sdp"] as? String == "v=0\n")
        #expect(payload["nvstSdp"] as? String == "nvst")
    }

    @Test(
        "Recognizes only TCP ICE candidates",
        arguments: [
            ("candidate:1 1 TCP 1 192.0.2.1 9 typ host tcptype active", true),
            ("candidate:2 1 udp 1 192.0.2.1 10000 typ host", false),
            ("not-a-candidate", false),
        ]
    )
    func recognizesTCPCandidates(candidate: String, expected: Bool) {
        #expect(SignalingMessageCodec.isTCPIceCandidate(candidate) == expected)
    }

    private func envelope(payload: [String: Any]) throws -> String {
        let payloadData = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        let payloadText = try #require(String(data: payloadData, encoding: .utf8))
        let data = try JSONSerialization.data(
            withJSONObject: [
                "peer_msg": [
                    "from": 7,
                    "to": 2,
                    "msg": payloadText,
                ],
            ],
            options: [.sortedKeys]
        )
        return try #require(String(data: data, encoding: .utf8))
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
