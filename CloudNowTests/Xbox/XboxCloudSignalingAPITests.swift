@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox Cloud REST signaling")
struct XboxCloudSignalingAPITests {
    @Test("SDP exchange sends the Microsoft REST payload and polls")
    func exchangesSDP() async throws {
        let transport = SignalingRecordingTransport { request, index in
            #expect(request.url?.absoluteString == "https://wus.gssv-play-prod.xboxlive.com/session/path/sdp")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-gs-token")
            #expect(request.value(forHTTPHeaderField: "X-GSSV-Routing") == "AFD")
            if index == 0 {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "MS-CV") == "fixture-cv.2")
                let body = try #require(request.httpBody)
                let object = try #require(
                    JSONSerialization.jsonObject(with: body)
                        as? [String: Any]
                )
                #expect(object["messageType"] as? String == "offer")
                #expect(object["requestId"] as? Int == 1)
                #expect(object["sdp"] as? String == "fixture-offer")
                #expect(object["cv"] as? String == "fixture-cv.1")
                let configuration = try #require(
                    object["configuration"] as? [String: Any]
                )
                #expect(configuration["useUnreliableInput"] as? Bool == true)
                return signalingResponse(statusCode: 204)
            }
            if index == 1 {
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "MS-CV") == "fixture-cv.3")
                return signalingResponse(data: Data())
            }
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "MS-CV") == "fixture-cv.4")
            let answer = #"{"status":"success","sdpType":"answer","sdp":"fixture-answer","chatStream":1,"control":3,"unreliableinput":10,"reliableinput":10,"message":1}"#
            return signalingResponse(
                json: #"{"exchangeResponse":\#(answer)}"#
            )
        }
        let delays = SignalingDelayRecorder()
        let api = XboxCloudSignalingAPI(
            transport: transport,
            sleep: { await delays.record($0) }
        )

        let context = try makeContext()
        let answer = try await api.exchangeSDP(
            offer: "fixture-offer",
            context: context
        )

        #expect(answer.sdp == "fixture-answer")
        #expect(answer.input == nil)
        #expect(answer.unreliableinput == 10)
        #expect(answer.reliableinput == 10)
        #expect(answer.chat == nil)
        #expect(await delays.values() == [0.1])
        #expect(await transport.requests().count == 3)
    }

    @Test("Legacy SDP input remains decodable")
    func decodesLegacySDPInput() throws {
        let data = Data(
            #"{"status":"success","sdpType":"answer","sdp":"fixture-answer","chatStream":1,"control":3,"input":10,"message":1}"#.utf8
        )

        let answer = try JSONDecoder().decode(XboxCloudSDPAnswer.self, from: data)

        #expect(answer.input == 10)
        #expect(answer.unreliableinput == nil)
        #expect(answer.reliableinput == nil)
    }

    @Test("ICE exchange sends candidate strings and decodes remote candidates")
    func exchangesICE() async throws {
        let transport = SignalingRecordingTransport { request, index in
            if index == 0 {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "MS-CV") == "fixture-cv.1")
                let body = try #require(request.httpBody)
                let object = try #require(
                    JSONSerialization.jsonObject(with: body)
                        as? [String: Any]
                )
                let candidates = try #require(object["candidates"] as? [String])
                #expect(candidates.count == 2)
                #expect(candidates[0].contains("fixture-local-candidate"))
                #expect(candidates[1] == "a=end-of-candidates")
                return signalingResponse(statusCode: 204)
            }
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "MS-CV") == "fixture-cv.2")
            let payloads = [
                #"{"candidate":"fixture-remote-candidate","sdpMid":"0","sdpMLineIndex":0,"routingPreference":"AZURE"}"#,
                #"{"candidate":"a=end-of-candidates"}"#,
            ]
            let payloadData = try JSONEncoder().encode(payloads)
            let payload = try #require(String(data: payloadData, encoding: .utf8))
            let response = try JSONEncoder().encode(["exchangeResponse": payload])
            return signalingResponse(data: response)
        }
        let api = XboxCloudSignalingAPI(transport: transport)

        let context = try makeContext()
        let candidates = try await api.exchangeICE(
            candidates: [
                XboxCloudICECandidate(
                    candidate: "fixture-local-candidate",
                    sdpMid: "0",
                    sdpMLineIndex: 0
                ),
                .endOfCandidates,
            ],
            context: context
        )

        #expect(candidates == [
            XboxCloudICECandidate(
                candidate: "fixture-remote-candidate",
                sdpMid: "0",
                sdpMLineIndex: 0,
                routingPreference: "AZURE"
            ),
            .endOfCandidates,
        ])
    }

    @Test(
        "ICE accepts Microsoft object and string response shapes",
        arguments: [
            ICEPayloadShape.stringWrappedObjects,
            ICEPayloadShape.directObjects,
            ICEPayloadShape.stringElements,
        ]
    )
    private func acceptsICEPayloadShapes(shape: ICEPayloadShape) async throws {
        let candidate = XboxCloudICECandidate(
            candidate: "fixture-remote-candidate",
            sdpMid: "0",
            sdpMLineIndex: 0,
            routingPreference: "AZURE"
        )
        let transport = SignalingRecordingTransport { _, index in
            if index == 0 {
                return signalingResponse(statusCode: 204)
            }
            return try signalingResponse(data: shape.response(candidate: candidate))
        }
        let api = XboxCloudSignalingAPI(transport: transport)

        let candidates = try await api.exchangeICE(
            candidates: [XboxCloudICECandidate(candidate: "candidate-local")],
            context: makeContext()
        )

        #expect(candidates == [candidate])
    }

    @Test("ICE rejects an oversized candidate in an object response")
    func rejectsOversizedObjectCandidate() async throws {
        let candidate = XboxCloudICECandidate(
            candidate: String(repeating: "x", count: 17000)
        )
        let transport = SignalingRecordingTransport { _, index in
            if index == 0 {
                return signalingResponse(statusCode: 204)
            }
            let response = try JSONEncoder().encode([
                "exchangeResponse": [candidate],
            ])
            return signalingResponse(data: response)
        }
        let api = XboxCloudSignalingAPI(transport: transport)

        await #expect(throws: XboxCloudSignalingError.invalidPayload) {
            _ = try await api.exchangeICE(
                candidates: [XboxCloudICECandidate(candidate: "candidate-local")],
                context: makeContext()
            )
        }
    }

    @Test(
        "Signaling rejects oversized POST responses before diagnostics",
        arguments: [204, 500]
    )
    func rejectsOversizedPOSTResponse(statusCode: Int) async throws {
        let transport = SignalingRecordingTransport { _, _ in
            signalingResponse(
                statusCode: statusCode,
                data: Data(repeating: 0, count: 2 * 1024 * 1024 + 1)
            )
        }
        let api = XboxCloudSignalingAPI(transport: transport)

        await #expect(throws: XboxCloudSignalingError.payloadTooLarge) {
            _ = try await api.exchangeICE(
                candidates: [XboxCloudICECandidate(candidate: "candidate-local")],
                context: makeContext()
            )
        }
    }

    @Test("A reused signaling context advances from its last HTTP request")
    func advancesAcrossExchanges() async throws {
        let transport = SignalingRecordingTransport { request, index in
            #expect(
                request.value(forHTTPHeaderField: "MS-CV")
                    == "fixture-cv.\(index + 1)"
            )
            if index.isMultiple(of: 2) {
                return signalingResponse(statusCode: 204)
            }
            return signalingResponse(json: #"{"exchangeResponse":"[]"}"#)
        }
        let api = XboxCloudSignalingAPI(transport: transport)
        let context = try makeContext()

        _ = try await api.exchangeICE(
            candidates: [XboxCloudICECandidate(candidate: "candidate-one")],
            context: context
        )
        _ = try await api.exchangeICE(
            candidates: [XboxCloudICECandidate(candidate: "candidate-two")],
            context: context
        )

        #expect(await transport.requests().count == 4)
    }

    @Test("Correlation-vector sequencing stays bounded and deterministic")
    func correlationVectorSequence() throws {
        var sequence = try XboxCloudCorrelationVectorSequence(seed: "fixture.41")

        #expect(try sequence.next() == "fixture.41")
        #expect(try sequence.next() == "fixture.42")

        var unsuffixed = try XboxCloudCorrelationVectorSequence(seed: "fixture")
        #expect(try unsuffixed.next() == "fixture.0")
        var oversized = try XboxCloudCorrelationVectorSequence(
            seed: String(repeating: "a", count: 256)
        )
        #expect(throws: XboxCloudSignalingError.invalidContext) {
            _ = try oversized.next()
        }
    }

    @Test("Signaling context rejects non-Xbox hosts and unsafe session paths")
    func validatesContext() throws {
        let invalidHost = try #require(URL(string: "https://example.com"))
        let xboxHost = try #require(
            URL(string: "https://gssv-play-prod.xboxlive.com")
        )
        #expect(throws: XboxCloudSignalingError.invalidContext) {
            _ = try XboxCloudSignalingContext(
                endpointBaseURL: invalidHost,
                sessionPath: "session/path",
                gsToken: "token",
                correlationVector: "cv.1"
            )
        }
        #expect(throws: XboxCloudSignalingError.invalidContext) {
            _ = try XboxCloudSignalingContext(
                endpointBaseURL: xboxHost,
                sessionPath: "../unsafe",
                gsToken: "token",
                correlationVector: "cv.1"
            )
        }
    }

    @Test("Polling is bounded and cancellation is preserved")
    func boundsPollingAndPreservesCancellation() async throws {
        let timeoutTransport = SignalingRecordingTransport { _, index in
            index == 0
                ? signalingResponse(statusCode: 204)
                : signalingResponse(data: Data())
        }
        let timeoutAPI = XboxCloudSignalingAPI(
            transport: timeoutTransport,
            maximumPollAttempts: 2,
            sleep: { _ in }
        )
        await #expect(throws: XboxCloudSignalingError.pollingTimedOut) {
            _ = try await timeoutAPI.exchangeSDP(
                offer: "fixture-offer",
                context: makeContext()
            )
        }

        let cancelledTransport = SignalingRecordingTransport { _, _ in
            throw CancellationError()
        }
        let cancelledAPI = XboxCloudSignalingAPI(transport: cancelledTransport)
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledAPI.exchangeICE(
                candidates: [XboxCloudICECandidate(candidate: "candidate")],
                context: makeContext()
            )
        }
    }

    @Test("Descriptions and failures never expose the GS token")
    func redactsCredentials() throws {
        let context = try makeContext()

        #expect(!context.description.contains("fixture-gs-token"))
        #expect(!XboxCloudSignalingError.transportFailure.localizedDescription.contains("fixture-gs-token"))
    }

    @Test("HTTP diagnostics expose only bounded service codes")
    func sanitizesServiceErrorDiagnostics() {
        let supported = Data(#"{"errorInfo":{"RtcError":"Bad-CV.42"}}"#.utf8)
        let unsafe = Data(#"{"error":{"code":"token value must never log"}}"#.utf8)

        #expect(XboxCloudSignalingAPI.hasDiagnosticServiceErrorCode(in: supported))
        #expect(!XboxCloudSignalingAPI.hasDiagnosticServiceErrorCode(in: unsafe))
    }

    @Test("SDP diagnostics expose only fixed field-presence flags")
    func diagnosticSDPAnswerFieldsAreSafe() {
        let data = Data(#"{"status":"success","sdp":"private-value","input":10}"#.utf8)

        #expect(
            XboxCloudSignalingAPI.diagnosticSDPAnswerFieldSummary(from: data)
                == "status=1,sdpType=0,sdp=1,chatStream=0,control=0,input=1,unreliableinput=0,reliableinput=0,message=0,chat=0"
        )
    }

    private func makeContext() throws -> XboxCloudSignalingContext {
        try XboxCloudSignalingContext(
            endpointBaseURL: URL(
                string: "https://wus.gssv-play-prod.xboxlive.com"
            )!,
            sessionPath: "session/path",
            gsToken: "fixture-gs-token",
            correlationVector: "fixture-cv.1"
        )
    }
}

private enum ICEPayloadShape: Sendable {
    case stringWrappedObjects
    case directObjects
    case stringElements

    func response(candidate: XboxCloudICECandidate) throws -> Data {
        switch self {
        case .stringWrappedObjects:
            let payloadData = try JSONEncoder().encode([candidate])
            guard let payload = String(bytes: payloadData, encoding: .utf8) else {
                throw XboxCloudSignalingError.invalidPayload
            }
            return try JSONEncoder().encode(["exchangeResponse": payload])
        case .directObjects:
            return try JSONEncoder().encode([
                "exchangeResponse": [candidate],
            ])
        case .stringElements:
            let candidateData = try JSONEncoder().encode(candidate)
            guard let candidatePayload = String(
                bytes: candidateData,
                encoding: .utf8
            ) else {
                throw XboxCloudSignalingError.invalidPayload
            }
            let payloadData = try JSONEncoder().encode([candidatePayload])
            guard let payload = String(bytes: payloadData, encoding: .utf8) else {
                throw XboxCloudSignalingError.invalidPayload
            }
            return try JSONEncoder().encode(["exchangeResponse": payload])
        }
    }
}

private actor SignalingRecordingTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest, Int) async throws -> (Data, URLResponse)

    private let handler: Handler
    private var recordedRequests: [URLRequest] = []

    init(
        handler: @escaping @Sendable (URLRequest, Int) throws -> (Data, URLResponse)
    ) {
        self.handler = { request, index in
            try handler(request, index)
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let index = recordedRequests.count
        recordedRequests.append(request)
        return try await handler(request, index)
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

private actor SignalingDelayRecorder {
    private var delays: [TimeInterval] = []

    func record(_ delay: TimeInterval) {
        delays.append(delay)
    }

    func values() -> [TimeInterval] {
        delays
    }
}

private func signalingResponse(
    statusCode: Int = 200,
    data: Data
) -> (Data, URLResponse) {
    let response = HTTPURLResponse(
        url: URL(string: "https://wus.gssv-play-prod.xboxlive.com")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
    return (data, response)
}

private func signalingResponse(
    statusCode: Int = 200,
    json: String = ""
) -> (Data, URLResponse) {
    signalingResponse(statusCode: statusCode, data: Data(json.utf8))
}
