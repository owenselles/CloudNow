@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox Cloud REST signaling")
struct XboxCloudSignalingAPITests {
    @Test("SDP exchange double-encodes the Microsoft REST payload and polls")
    func exchangesSDP() async throws {
        let transport = SignalingRecordingTransport { request, index in
            #expect(request.url?.absoluteString == "https://wus.gssv-play-prod.xboxlive.com/session/path/sdp")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-gs-token")
            if index == 0 {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "MS-CV") == "fixture-cv.1")
                let outer = try #require(request.httpBody)
                let inner = try JSONDecoder().decode(String.self, from: outer)
                let object = try #require(
                    JSONSerialization.jsonObject(with: Data(inner.utf8))
                        as? [String: Any]
                )
                #expect(object["messageType"] as? String == "offer")
                #expect(object["requestId"] as? Int == 1)
                #expect(object["sdp"] as? String == "fixture-offer")
                #expect(object["cv"] as? String == "fixture-cv.1")
                let configuration = try #require(
                    object["configuration"] as? [String: Any]
                )
                #expect(configuration["useUnreliableInput"] as? Bool == false)
                return signalingResponse(statusCode: 204)
            }
            if index == 1 {
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "MS-CV") == "fixture-cv.2")
                return signalingResponse(data: Data())
            }
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "MS-CV") == "fixture-cv.3")
            let answer = #"{"status":"success","sdpType":"answer","sdp":"fixture-answer","chatStream":1,"control":3,"input":10,"unreliableinput":10,"reliableinput":10,"message":1,"chat":1}"#
            return signalingResponse(
                json: #"{"exchangeResponse":\#(String(reflecting: answer))}"#
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
        #expect(answer.input == 10)
        #expect(await delays.values() == [0.1])
        #expect(await transport.requests().count == 3)
    }

    @Test("ICE exchange sends candidate strings and decodes remote candidates")
    func exchangesICE() async throws {
        let transport = SignalingRecordingTransport { request, index in
            if index == 0 {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "MS-CV") == "fixture-cv.1")
                let outer = try #require(request.httpBody)
                let inner = try JSONDecoder().decode(String.self, from: outer)
                let object = try #require(
                    JSONSerialization.jsonObject(with: Data(inner.utf8))
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
            let remote = #"[{"candidate":"fixture-remote-candidate","sdpMid":"0","sdpMLineIndex":0,"routingPreference":"AZURE"}]"#
            return signalingResponse(
                json: #"{"exchangeResponse":\#(String(reflecting: remote))}"#
            )
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
        ])
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
