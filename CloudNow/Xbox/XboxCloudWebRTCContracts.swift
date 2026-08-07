import Foundation

nonisolated enum XboxCloudDataChannelKind: String, CaseIterable, Hashable, Sendable {
    case chat
    case control
    case message
    case input
    case unreliableInput
    case reliableInput
}

nonisolated struct XboxCloudDataChannelDescriptor: Equatable, Sendable {
    static let microsoftWebRTCChannels: [Self] = [
        Self(kind: .chat, label: "chat", subprotocol: "chatV1", isOrdered: true),
        Self(kind: .control, label: "control", subprotocol: "controlV1", isOrdered: true),
        Self(kind: .message, label: "message", subprotocol: "messageV1", isOrdered: true),
        Self(kind: .input, label: "input", subprotocol: "1.0", isOrdered: true),
        Self(
            kind: .unreliableInput,
            label: "unreliableinput",
            subprotocol: "2.0",
            isOrdered: false,
            maximumRetransmits: 0
        ),
        Self(
            kind: .reliableInput,
            label: "reliableinput",
            subprotocol: "2.0",
            isOrdered: true
        ),
    ]

    let kind: XboxCloudDataChannelKind
    let label: String
    let subprotocol: String
    let isOrdered: Bool
    let maximumRetransmits: Int?

    init(
        kind: XboxCloudDataChannelKind,
        label: String,
        subprotocol: String,
        isOrdered: Bool,
        maximumRetransmits: Int? = nil
    ) {
        self.kind = kind
        self.label = label
        self.subprotocol = subprotocol
        self.isOrdered = isOrdered
        self.maximumRetransmits = maximumRetransmits
    }
}

nonisolated enum XboxCloudIncomingDataPolicy {
    private static let maximumInputFeedbackBytes = 4096
    private static let maximumProtocolMessageBytes = 64 * 1024
    private static let maximumChatBytes = 256 * 1024

    static func channelKind(for label: String) -> XboxCloudDataChannelKind? {
        switch label {
        case "chat": .chat
        case "control": .control
        case "message": .message
        case "input": .input
        case "unreliableinput": .unreliableInput
        case "reliableinput": .reliableInput
        default: nil
        }
    }

    static func accepts(label: String, byteCount: Int) -> Bool {
        guard byteCount >= 0,
              let kind = channelKind(for: label)
        else {
            return false
        }
        let maximum = switch kind {
        case .input, .reliableInput, .unreliableInput:
            maximumInputFeedbackBytes
        case .control, .message:
            maximumProtocolMessageBytes
        case .chat:
            maximumChatBytes
        }
        return byteCount <= maximum
    }
}

/// Input transport selected by Microsoft's SDP answer. New Xbox sessions use
/// the reliable/unreliable channel pair; the original reliable channel remains
/// a bounded fallback for servers that do not negotiate the newer pair.
nonisolated enum XboxCloudInputTransportMode: Equatable, Sendable {
    case legacy(version: Int)
    case unreliable(reliableVersion: Int, unreliableVersion: Int)

    var reportVersion: Int {
        switch self {
        case let .legacy(version):
            version
        case let .unreliable(_, unreliableVersion):
            unreliableVersion
        }
    }

    var metadataVersion: Int {
        // Microsoft's V2 reporter encodes reliable-channel metadata and
        // feedback using the unreliable report channel's negotiated version.
        reportVersion
    }

    var requiredChannels: Set<XboxCloudDataChannelKind> {
        switch self {
        case .legacy:
            [.control, .message, .input]
        case .unreliable:
            [.control, .message, .unreliableInput, .reliableInput]
        }
    }

    var diagnosticName: String {
        switch self {
        case .legacy:
            "legacy"
        case .unreliable:
            "unreliable"
        }
    }

    init(answer: XboxCloudSDPAnswer) throws {
        guard (1 ... 10).contains(answer.input) else {
            throw XboxCloudWebRTCTransportError.unsupportedInputVersion(
                answer.input
            )
        }
        if let unreliableVersion = answer.unreliableinput,
           let reliableVersion = answer.reliableinput
        {
            guard (9 ... 10).contains(unreliableVersion) else {
                throw XboxCloudWebRTCTransportError.unsupportedInputVersion(
                    unreliableVersion
                )
            }
            guard (9 ... 10).contains(reliableVersion) else {
                throw XboxCloudWebRTCTransportError.unsupportedInputVersion(
                    reliableVersion
                )
            }
            self = .unreliable(
                reliableVersion: reliableVersion,
                unreliableVersion: unreliableVersion
            )
        } else {
            self = .legacy(version: answer.input)
        }
    }
}

nonisolated struct XboxCloudWebRTCReadiness: Equatable, Sendable {
    private(set) var isPeerConnected = false
    private(set) var hasActiveMedia = false
    private(set) var openChannels: Set<XboxCloudDataChannelKind> = []
    private(set) var negotiatedInputMode: XboxCloudInputTransportMode?

    var isReady: Bool {
        guard let negotiatedInputMode else { return false }
        return isPeerConnected
            && hasActiveMedia
            && negotiatedInputMode.requiredChannels.isSubset(of: openChannels)
    }

    mutating func setPeerConnected(_ isConnected: Bool) {
        isPeerConnected = isConnected
    }

    mutating func setActiveMedia(_ isActive: Bool) {
        hasActiveMedia = isActive
    }

    mutating func setChannel(_ channel: XboxCloudDataChannelKind, isOpen: Bool) {
        if isOpen {
            openChannels.insert(channel)
        } else {
            openChannels.remove(channel)
        }
    }

    mutating func setNegotiatedInputMode(_ mode: XboxCloudInputTransportMode?) {
        negotiatedInputMode = mode
    }
}

nonisolated enum XboxCloudWebRTCTransportError: Error, Equatable, LocalizedError, Sendable {
    case invalidSTUNConfiguration
    case unableToCreatePeer
    case unableToCreateTransceiver(media: String)
    case unableToCreateDataChannel(label: String)
    case unableToCreateOffer
    case peerOperationFailed(operation: String)
    case unsupportedInputVersion(Int)
    case noLocalICECandidates
    case tooManyICECandidates
    case invalidICECandidate
    case iceGatheringTimedOut
    case dataPayloadTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidSTUNConfiguration:
            "Xbox Cloud returned an invalid media relay configuration."
        case .unableToCreatePeer:
            "CloudNow could not create the Xbox Cloud media connection."
        case let .unableToCreateTransceiver(media):
            "CloudNow could not create the Xbox Cloud \(media) stream."
        case let .unableToCreateDataChannel(label):
            "CloudNow could not create the Xbox Cloud \(label) channel."
        case .unableToCreateOffer:
            "CloudNow could not create the Xbox Cloud media offer."
        case let .peerOperationFailed(operation):
            "The Xbox Cloud media connection failed while \(operation)."
        case let .unsupportedInputVersion(version):
            "Xbox Cloud selected unsupported input protocol version \(version)."
        case .noLocalICECandidates:
            "CloudNow could not find a network path to Xbox Cloud."
        case .tooManyICECandidates:
            "Xbox Cloud media negotiation returned too many network candidates."
        case .invalidICECandidate:
            "Xbox Cloud media negotiation returned an invalid network candidate."
        case .iceGatheringTimedOut:
            "CloudNow timed out while finding a network path to Xbox Cloud."
        case .dataPayloadTooLarge:
            "The Xbox Cloud channel payload is too large."
        }
    }
}

nonisolated protocol XboxCloudSignalingProviding: Sendable {
    func exchangeSDP(
        offer: String,
        context: XboxCloudSignalingContext,
        configuration: XboxCloudSDPConfiguration
    ) async throws -> XboxCloudSDPAnswer

    func exchangeICE(
        candidates: [XboxCloudICECandidate],
        context: XboxCloudSignalingContext
    ) async throws -> [XboxCloudICECandidate]
}

extension XboxCloudSignalingAPI: XboxCloudSignalingProviding {}

@MainActor
protocol XboxCloudWebRTCNegotiatingPeer: AnyObject {
    func createAndSetLocalOffer() async throws -> String
    func setRemoteAnswer(_ answer: XboxCloudSDPAnswer) async throws
    func waitForLocalICECandidates() async throws -> [XboxCloudICECandidate]
    func addRemoteICECandidates(_ candidates: [XboxCloudICECandidate]) async throws
}

@MainActor
struct XboxCloudWebRTCNegotiationPipeline {
    private static let maximumCandidates = 64
    private static let maximumCandidateBytes = 16384

    private let signaling: any XboxCloudSignalingProviding

    init(signaling: any XboxCloudSignalingProviding) {
        self.signaling = signaling
    }

    func negotiate(
        peer: any XboxCloudWebRTCNegotiatingPeer,
        context: XboxCloudSignalingContext
    ) async throws -> XboxCloudSDPAnswer {
        try Task.checkCancellation()
        let offer = try await peer.createAndSetLocalOffer()
        try Task.checkCancellation()

        let answer = try await signaling.exchangeSDP(
            offer: offer,
            context: context,
            configuration: .webInput
        )
        _ = try XboxCloudInputTransportMode(answer: answer)

        try Task.checkCancellation()
        try await peer.setRemoteAnswer(answer)
        let localCandidates = try await peer.waitForLocalICECandidates()
        try Self.validateCandidates(localCandidates, permitsEmpty: false)

        try Task.checkCancellation()
        let remoteCandidates = try await signaling.exchangeICE(
            candidates: localCandidates,
            context: context
        )
        try Self.validateCandidates(remoteCandidates, permitsEmpty: true)

        try Task.checkCancellation()
        try await peer.addRemoteICECandidates(remoteCandidates)
        return answer
    }

    private static func validateCandidates(
        _ candidates: [XboxCloudICECandidate],
        permitsEmpty: Bool
    ) throws {
        guard permitsEmpty || !candidates.isEmpty else {
            throw XboxCloudWebRTCTransportError.noLocalICECandidates
        }
        guard candidates.count <= maximumCandidates else {
            throw XboxCloudWebRTCTransportError.tooManyICECandidates
        }
        guard candidates.allSatisfy({ candidate in
            !candidate.candidate.isEmpty
                && candidate.candidate.utf8.count <= maximumCandidateBytes
                && !candidate.candidate.unicodeScalars.contains(where: { scalar in
                    scalar == "\r" || scalar == "\n"
                })
        }) else {
            throw XboxCloudWebRTCTransportError.invalidICECandidate
        }
    }
}
