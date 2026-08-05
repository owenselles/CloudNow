import Foundation

nonisolated struct XboxCloudSignalingContext: Sendable, CustomStringConvertible {
    let endpointBaseURL: URL
    let sessionPath: String
    let gsToken: String
    let correlationVector: String

    init(
        endpointBaseURL: URL,
        sessionPath: String,
        gsToken: String,
        correlationVector: String
    ) throws {
        guard Self.isAllowedServiceURL(endpointBaseURL),
              Self.isSafeSessionPath(sessionPath),
              !gsToken.isEmpty,
              gsToken.utf8.count <= 16384,
              !correlationVector.isEmpty,
              correlationVector.utf8.count <= 256
        else {
            throw XboxCloudSignalingError.invalidContext
        }
        self.endpointBaseURL = endpointBaseURL
        self.sessionPath = sessionPath
        self.gsToken = gsToken
        self.correlationVector = correlationVector
    }

    var description: String {
        "XboxCloudSignalingContext(endpointBaseURL: \(endpointBaseURL), sessionPath: <redacted>, gsToken: <redacted>, correlationVector: <redacted>)"
    }

    fileprivate func endpoint(operation: String) throws -> URL {
        guard Self.isSafePathComponent(operation),
              var components = URLComponents(
                  url: endpointBaseURL,
                  resolvingAgainstBaseURL: false
              )
        else {
            throw XboxCloudSignalingError.invalidContext
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativePath = sessionPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, relativePath, operation]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let endpoint = components.url,
              Self.isAllowedServiceURL(endpoint)
        else {
            throw XboxCloudSignalingError.invalidContext
        }
        return endpoint
    }

    private static func isAllowedServiceURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "xboxlive.com" || host.hasSuffix(".xboxlive.com"),
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.fragment == nil
        else {
            return false
        }
        return true
    }

    private static func isSafeSessionPath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= 2048,
              !path.contains(".."),
              !path.contains("?"),
              !path.contains("#"),
              !path.contains("\\")
        else {
            return false
        }
        return path.split(separator: "/").allSatisfy {
            isSafePathComponent(String($0))
        }
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        guard !component.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._")
        )
        return component.unicodeScalars.allSatisfy(allowed.contains)
    }
}

nonisolated struct XboxCloudSDPConfiguration: Codable, Equatable, Sendable {
    struct VersionRange: Codable, Equatable, Sendable {
        let minVersion: Int
        let maxVersion: Int
    }

    struct ChatFormat: Codable, Equatable, Sendable {
        let codec: String
        let container: String
    }

    struct ChatConfiguration: Codable, Equatable, Sendable {
        let bytesPerSample: Int
        let format: ChatFormat
        let numChannels: Int
        let sampleFrequencyHz: Int
    }

    static let legacyInput = XboxCloudSDPConfiguration(
        chatStream: VersionRange(minVersion: 1, maxVersion: 1),
        control: VersionRange(minVersion: 1, maxVersion: 3),
        input: VersionRange(minVersion: 1, maxVersion: 10),
        unreliableinput: VersionRange(minVersion: 9, maxVersion: 10),
        useUnreliableInput: false,
        reliableinput: VersionRange(minVersion: 9, maxVersion: 10),
        message: VersionRange(minVersion: 1, maxVersion: 1),
        chatConfiguration: ChatConfiguration(
            bytesPerSample: 2,
            format: ChatFormat(codec: "opus", container: "webm"),
            numChannels: 1,
            sampleFrequencyHz: 24000
        ),
        chat: VersionRange(minVersion: 1, maxVersion: 1)
    )

    let chatStream: VersionRange
    let control: VersionRange
    let input: VersionRange
    let unreliableinput: VersionRange
    let useUnreliableInput: Bool
    let reliableinput: VersionRange
    let message: VersionRange
    let chatConfiguration: ChatConfiguration
    let chat: VersionRange
}

nonisolated struct XboxCloudSDPAnswer: Codable, Equatable, Sendable {
    let status: String
    let sdpType: String
    let sdp: String
    let chatStream: Int
    let control: Int
    let input: Int
    let unreliableinput: Int?
    let reliableinput: Int?
    let message: Int
    let chat: Int

    var isAccepted: Bool {
        status == "success"
            && sdpType == "answer"
            && !sdp.isEmpty
    }
}

nonisolated struct XboxCloudICECandidate: Codable, Equatable, Sendable {
    static let endOfCandidatesMarker = "a=end-of-candidates"

    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?
    let routingPreference: String?

    init(
        candidate: String,
        sdpMid: String? = nil,
        sdpMLineIndex: Int? = nil,
        routingPreference: String? = nil
    ) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.routingPreference = routingPreference
    }

    static var endOfCandidates: Self {
        Self(candidate: endOfCandidatesMarker)
    }

    /// WebRTC represents the remote end-of-candidates marker as an empty ICE
    /// candidate even though Microsoft's signaling payload uses an SDP marker.
    var rtcCandidateSDP: String {
        candidate == Self.endOfCandidatesMarker ? "" : candidate
    }
}

nonisolated enum XboxCloudSignalingError: Error, Equatable, LocalizedError, Sendable {
    case invalidContext
    case invalidPayload
    case payloadTooLarge
    case httpFailure(statusCode: Int)
    case rejected(status: String)
    case pollingTimedOut
    case transportFailure

    var errorDescription: String? {
        switch self {
        case .invalidContext:
            "Xbox Cloud signaling configuration is invalid."
        case .invalidPayload:
            "Xbox Cloud signaling returned an invalid response."
        case .payloadTooLarge:
            "Xbox Cloud signaling returned an oversized response."
        case let .httpFailure(statusCode):
            "Xbox Cloud signaling failed with HTTP \(statusCode)."
        case let .rejected(status):
            "Xbox Cloud rejected the media offer (\(status))."
        case .pollingTimedOut:
            "Xbox Cloud media negotiation timed out."
        case .transportFailure:
            "Xbox Cloud media negotiation could not reach the service."
        }
    }
}

/// Bounded correlation-vector cursor for one signaling context. The context's
/// vector is the first request value; each later HTTP request advances only its
/// terminal counter so the vector does not grow on the polling hot path.
nonisolated struct XboxCloudCorrelationVectorSequence: Sendable {
    private static let maximumLength = 256

    let seed: String
    private let prefix: String
    private var nextCounter: UInt64?

    init(seed: String) throws {
        let normalized = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized == seed,
              normalized.utf8.count <= Self.maximumLength
        else {
            throw XboxCloudSignalingError.invalidContext
        }

        if let separator = normalized.lastIndex(of: "."),
           separator != normalized.startIndex,
           let counter = UInt64(normalized[normalized.index(after: separator)...])
        {
            prefix = String(normalized[..<separator])
            nextCounter = counter
        } else {
            prefix = normalized
            nextCounter = 0
        }
        self.seed = normalized
    }

    mutating func next() throws -> String {
        guard let counter = nextCounter else {
            throw XboxCloudSignalingError.invalidContext
        }
        let value = "\(prefix).\(counter)"
        guard value.utf8.count <= Self.maximumLength else {
            throw XboxCloudSignalingError.invalidContext
        }
        nextCounter = counter == .max ? nil : counter + 1
        return value
    }
}

actor XboxCloudSignalingAPI {
    private struct SDPEnvelope: Encodable {
        let messageType = "offer"
        let requestId: Int
        let sdp: String
        let cv: String
        let configuration: XboxCloudSDPConfiguration
    }

    private struct ICEEnvelope: Encodable {
        let candidates: [String]
    }

    private struct ExchangeResponseEnvelope: Decodable {
        let exchangeResponse: String
    }

    private static let maximumResponseBytes = 2 * 1024 * 1024
    private static let maximumCandidates = 64
    private static let maximumCandidateBytes = 16384

    private let transport: any HTTPTransport
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let pollingInterval: TimeInterval
    private let maximumPollAttempts: Int
    private var requestID = 0
    private var correlationVectorSequence: XboxCloudCorrelationVectorSequence?

    init(
        transport: any HTTPTransport = URLSessionHTTPTransport(
            configuration: .ephemeral
        ),
        pollingInterval: TimeInterval = 0.1,
        maximumPollAttempts: Int = 300,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(
                nanoseconds: UInt64(max(0, $0) * 1_000_000_000)
            )
        }
    ) {
        self.transport = transport
        self.pollingInterval = max(0.05, min(pollingInterval, 2))
        self.maximumPollAttempts = max(1, min(maximumPollAttempts, 1200))
        self.sleep = sleep
    }

    func exchangeSDP(
        offer: String,
        context: XboxCloudSignalingContext,
        configuration: XboxCloudSDPConfiguration = .legacyInput
    ) async throws -> XboxCloudSDPAnswer {
        guard !offer.isEmpty,
              offer.utf8.count <= Self.maximumResponseBytes
        else {
            throw XboxCloudSignalingError.invalidPayload
        }
        requestID &+= 1
        let correlationVector = try nextCorrelationVector(for: context)
        let envelope = SDPEnvelope(
            requestId: requestID,
            sdp: offer,
            cv: correlationVector,
            configuration: configuration
        )
        let innerData = try encode(envelope)
        guard let innerJSON = String(data: innerData, encoding: .utf8) else {
            throw XboxCloudSignalingError.invalidPayload
        }
        try await postExchange(
            operation: "sdp",
            innerJSON: innerJSON,
            context: context,
            correlationVector: correlationVector
        )
        let responseData = try await pollExchange(
            operation: "sdp",
            context: context
        )
        let answer: XboxCloudSDPAnswer = try decode(
            XboxCloudSDPAnswer.self,
            from: responseData
        )
        guard answer.isAccepted else {
            throw XboxCloudSignalingError.rejected(status: answer.status)
        }
        return answer
    }

    func exchangeICE(
        candidates: [XboxCloudICECandidate],
        context: XboxCloudSignalingContext
    ) async throws -> [XboxCloudICECandidate] {
        guard !candidates.isEmpty,
              candidates.count <= Self.maximumCandidates
        else {
            throw XboxCloudSignalingError.invalidPayload
        }
        let candidateStrings = try candidates.map { candidate -> String in
            if candidate.candidate == XboxCloudICECandidate.endOfCandidatesMarker {
                return XboxCloudICECandidate.endOfCandidatesMarker
            }
            let data = try encode(candidate)
            guard data.count <= Self.maximumCandidateBytes,
                  let value = String(data: data, encoding: .utf8)
            else {
                throw XboxCloudSignalingError.invalidPayload
            }
            return value
        }
        let innerData = try encode(ICEEnvelope(candidates: candidateStrings))
        guard let innerJSON = String(data: innerData, encoding: .utf8) else {
            throw XboxCloudSignalingError.invalidPayload
        }
        let correlationVector = try nextCorrelationVector(for: context)
        try await postExchange(
            operation: "ice",
            innerJSON: innerJSON,
            context: context,
            correlationVector: correlationVector
        )
        let responseData = try await pollExchange(
            operation: "ice",
            context: context
        )
        return try decode([XboxCloudICECandidate].self, from: responseData)
    }

    private func postExchange(
        operation: String,
        innerJSON: String,
        context: XboxCloudSignalingContext,
        correlationVector: String
    ) async throws {
        let endpoint = try context.endpoint(operation: operation)
        var request = authorizedRequest(
            endpoint: endpoint,
            context: context,
            correlationVector: correlationVector
        )
        request.httpMethod = "POST"
        request.httpBody = try encode(innerJSON)
        let (_, response) = try await perform(request)
        let statusCode = try statusCode(from: response)
        guard (200 ..< 300).contains(statusCode) else {
            throw XboxCloudSignalingError.httpFailure(statusCode: statusCode)
        }
    }

    private func pollExchange(
        operation: String,
        context: XboxCloudSignalingContext
    ) async throws -> Data {
        let endpoint = try context.endpoint(operation: operation)
        for attempt in 0 ..< maximumPollAttempts {
            try Task.checkCancellation()
            let correlationVector = try nextCorrelationVector(for: context)
            var request = authorizedRequest(
                endpoint: endpoint,
                context: context,
                correlationVector: correlationVector
            )
            request.httpMethod = "GET"
            let (data, response) = try await perform(request)
            let statusCode = try statusCode(from: response)
            guard (200 ..< 300).contains(statusCode) else {
                throw XboxCloudSignalingError.httpFailure(statusCode: statusCode)
            }
            guard data.count <= Self.maximumResponseBytes else {
                throw XboxCloudSignalingError.payloadTooLarge
            }
            if !data.isEmpty {
                let envelope: ExchangeResponseEnvelope = try decode(
                    ExchangeResponseEnvelope.self,
                    from: data
                )
                guard let responseData = envelope.exchangeResponse.data(
                    using: .utf8
                ),
                    !responseData.isEmpty,
                    responseData.count <= Self.maximumResponseBytes
                else {
                    throw XboxCloudSignalingError.invalidPayload
                }
                return responseData
            }
            guard attempt + 1 < maximumPollAttempts else { break }
            try await sleep(pollingInterval)
        }
        throw XboxCloudSignalingError.pollingTimedOut
    }

    private func authorizedRequest(
        endpoint: URL,
        context: XboxCloudSignalingContext,
        correlationVector: String
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.setValue(
            "application/json; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Bearer \(context.gsToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            correlationVector,
            forHTTPHeaderField: "MS-CV"
        )
        request.timeoutInterval = 30
        return request
    }

    private func nextCorrelationVector(
        for context: XboxCloudSignalingContext
    ) throws -> String {
        if correlationVectorSequence?.seed != context.correlationVector {
            correlationVectorSequence = try XboxCloudCorrelationVectorSequence(
                seed: context.correlationVector
            )
        }
        guard var sequence = correlationVectorSequence else {
            throw XboxCloudSignalingError.invalidContext
        }
        let value = try sequence.next()
        correlationVectorSequence = sequence
        return value
    }

    private func perform(
        _ request: URLRequest
    ) async throws -> (Data, URLResponse) {
        do {
            return try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as XboxCloudSignalingError {
            throw error
        } catch {
            throw XboxCloudSignalingError.transportFailure
        }
    }

    private func statusCode(from response: URLResponse) throws -> Int {
        guard let response = response as? HTTPURLResponse else {
            throw XboxCloudSignalingError.invalidPayload
        }
        return response.statusCode
    }

    private func encode(_ value: some Encodable) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw XboxCloudSignalingError.invalidPayload
        }
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw XboxCloudSignalingError.invalidPayload
        }
    }
}
