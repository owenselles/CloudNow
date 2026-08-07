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

nonisolated struct XboxCloudWebRTCReadiness: Equatable, Sendable {
    static let requiredChannels: Set<XboxCloudDataChannelKind> = [
        .control,
        .message,
        .input,
    ]

    private(set) var isPeerConnected = false
    private(set) var hasActiveMedia = false
    private(set) var openChannels: Set<XboxCloudDataChannelKind> = []
    private(set) var negotiatedInputVersion: Int?

    var isReady: Bool {
        isPeerConnected
            && hasActiveMedia
            && negotiatedInputVersion != nil
            && Self.requiredChannels.isSubset(of: openChannels)
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

    mutating func setNegotiatedInputVersion(_ version: Int?) {
        negotiatedInputVersion = version
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
            configuration: .legacyInput
        )
        guard (1 ... 10).contains(answer.input) else {
            throw XboxCloudWebRTCTransportError.unsupportedInputVersion(answer.input)
        }

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
