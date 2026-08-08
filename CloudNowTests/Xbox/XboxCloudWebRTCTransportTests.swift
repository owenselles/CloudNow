@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox Cloud native WebRTC transport")
@MainActor
struct XboxCloudWebRTCTransportTests {
    @Test("Microsoft end-of-candidates marker is omitted from native WebRTC")
    func endOfCandidatesMarker() {
        let marker = XboxCloudICECandidate.endOfCandidates

        #expect(marker.candidate == "a=end-of-candidates")
        #expect(marker.rtcCandidateSDP == nil)
        #expect(
            XboxCloudICECandidate(candidate: "candidate:remote")
                .rtcCandidateSDP == "candidate:remote"
        )
    }

    @Test("Microsoft channel labels, protocols, and reliability are exact")
    func channelDescriptors() {
        #expect(XboxCloudDataChannelDescriptor.microsoftWebRTCChannels == [
            XboxCloudDataChannelDescriptor(
                kind: .chat,
                label: "chat",
                subprotocol: "chatV1",
                isOrdered: true
            ),
            XboxCloudDataChannelDescriptor(
                kind: .control,
                label: "control",
                subprotocol: "controlV1",
                isOrdered: true
            ),
            XboxCloudDataChannelDescriptor(
                kind: .message,
                label: "message",
                subprotocol: "messageV1",
                isOrdered: true
            ),
            XboxCloudDataChannelDescriptor(
                kind: .input,
                label: "input",
                subprotocol: "1.0",
                isOrdered: true
            ),
            XboxCloudDataChannelDescriptor(
                kind: .unreliableInput,
                label: "unreliableinput",
                subprotocol: "2.0",
                isOrdered: false,
                maximumRetransmits: 0
            ),
            XboxCloudDataChannelDescriptor(
                kind: .reliableInput,
                label: "reliableinput",
                subprotocol: "2.0",
                isOrdered: true
            ),
        ])
    }

    @Test("Incoming data is bounded by channel purpose")
    func incomingDataBounds() {
        #expect(
            XboxCloudIncomingDataPolicy.channelKind(for: "reliableinput")
                == .reliableInput
        )
        #expect(XboxCloudIncomingDataPolicy.channelKind(for: "unexpected") == nil)
        #expect(XboxCloudIncomingDataPolicy.accepts(
            label: "reliableinput",
            byteCount: 4096
        ))
        #expect(!XboxCloudIncomingDataPolicy.accepts(
            label: "reliableinput",
            byteCount: 4097
        ))
        #expect(XboxCloudIncomingDataPolicy.accepts(
            label: "message",
            byteCount: 64 * 1024
        ))
        #expect(!XboxCloudIncomingDataPolicy.accepts(
            label: "message",
            byteCount: 64 * 1024 + 1
        ))
        #expect(!XboxCloudIncomingDataPolicy.accepts(
            label: "unexpected",
            byteCount: 1
        ))
    }

    @Test("Readiness requires the channels selected by the input mode")
    func readinessGate() {
        var readiness = XboxCloudWebRTCReadiness()
        readiness.setPeerConnected(true)
        readiness.setActiveMedia(true)
        readiness.setNegotiatedInputMode(.legacy(version: 10))
        readiness.setChannel(.control, isOpen: true)
        readiness.setChannel(.message, isOpen: true)
        #expect(!readiness.isReady)

        readiness.setChannel(.input, isOpen: true)
        #expect(readiness.isReady)

        readiness.setChannel(.chat, isOpen: false)
        #expect(readiness.isReady)

        readiness.setChannel(.unreliableInput, isOpen: false)
        readiness.setChannel(.reliableInput, isOpen: false)
        #expect(readiness.isReady)

        readiness.setNegotiatedInputMode(.unreliable(
            reliableVersion: 10,
            unreliableVersion: 10
        ))
        #expect(!readiness.isReady)
        readiness.setChannel(.unreliableInput, isOpen: true)
        readiness.setChannel(.reliableInput, isOpen: true)
        #expect(readiness.isReady)
        readiness.setChannel(.input, isOpen: false)
        #expect(readiness.isReady)

        readiness.setActiveMedia(false)
        #expect(!readiness.isReady)
    }

    @Test("SDP selects modern input only when both V2 channels negotiate")
    func negotiatedInputMode() throws {
        #expect(
            try XboxCloudInputTransportMode(answer: Self.answer())
                == .unreliable(
                    reliableVersion: 10,
                    unreliableVersion: 10
                )
        )
        #expect(
            try XboxCloudInputTransportMode(answer: Self.answer(
                inputVersion: nil
            ))
                == .unreliable(
                    reliableVersion: 10,
                    unreliableVersion: 10
                )
        )
        #expect(
            try XboxCloudInputTransportMode(answer: Self.answer(
                unreliableInputVersion: nil,
                reliableInputVersion: 10
            )) == .legacy(version: 10)
        )
        #expect(
            try XboxCloudInputTransportMode(answer: Self.answer(
                unreliableInputVersion: 10,
                reliableInputVersion: nil
            )) == .legacy(version: 10)
        )
        #expect(throws: XboxCloudWebRTCTransportError.missingInputTransport) {
            _ = try XboxCloudInputTransportMode(answer: Self.answer(
                inputVersion: nil,
                unreliableInputVersion: 10,
                reliableInputVersion: nil
            ))
        }

        let mixedVersionMode = XboxCloudInputTransportMode.unreliable(
            reliableVersion: 9,
            unreliableVersion: 10
        )
        #expect(mixedVersionMode.reportVersion == 10)
        #expect(mixedVersionMode.metadataVersion == 10)
    }

    @Test("Required channel closure is terminal throughout active setup")
    func requiredChannelClosurePolicy() {
        let activeStates: [XboxCloudWebRTCConnectionState] = [
            .preparing,
            .negotiating,
            .connecting,
            .connected,
        ]
        for state in activeStates {
            #expect(
                XboxCloudRequiredChannelClosurePolicy.shouldTerminate(
                    channel: .control,
                    state: state,
                    inputMode: .unreliable(
                        reliableVersion: 10,
                        unreliableVersion: 10
                    )
                )
            )
        }

        #expect(
            !XboxCloudRequiredChannelClosurePolicy.shouldTerminate(
                channel: .chat,
                state: .connected,
                inputMode: .legacy(version: 10)
            )
        )
        #expect(
            XboxCloudRequiredChannelClosurePolicy.shouldTerminate(
                channel: .unreliableInput,
                state: .connected,
                inputMode: .unreliable(
                    reliableVersion: 10,
                    unreliableVersion: 10
                )
            )
        )
        #expect(
            !XboxCloudRequiredChannelClosurePolicy.shouldTerminate(
                channel: .input,
                state: .connected,
                inputMode: .unreliable(
                    reliableVersion: 10,
                    unreliableVersion: 10
                )
            )
        )
        #expect(
            XboxCloudRequiredChannelClosurePolicy.shouldTerminate(
                channel: .input,
                state: .connected,
                inputMode: .legacy(version: 10)
            )
        )
        #expect(
            !XboxCloudRequiredChannelClosurePolicy.shouldTerminate(
                channel: .control,
                state: .idle,
                inputMode: .legacy(version: 10)
            )
        )
        #expect(
            !XboxCloudRequiredChannelClosurePolicy.shouldTerminate(
                channel: .control,
                state: .failed(message: "fixture"),
                inputMode: .legacy(version: 10)
            )
        )
    }

    @Test("Session STUN hosts are normalized without accepting arbitrary URLs")
    func stunConfiguration() throws {
        #expect(try XboxCloudWebRTCTransport.validatedSTUNURLs([
            "stun.example.test:3478",
            "stuns:[2001:db8::7]:5349",
            "STUN:stun.example.test:3478",
        ]) == [
            "stun:stun.example.test:3478",
            "stuns:[2001:db8::7]:5349",
        ])

        #expect(throws: XboxCloudWebRTCTransportError.invalidSTUNConfiguration) {
            _ = try XboxCloudWebRTCTransport.validatedSTUNURLs([
                "https://example.com/relay",
            ])
        }
    }

    @Test("Negotiation orders offer, SDP, ICE, and remote candidate application")
    func negotiationOrder() async throws {
        let events = XboxWebRTCEventRecorder()
        let peer = XboxWebRTCPeerStub(events: events)
        let signaling = XboxWebRTCSignalingStub(
            events: events,
            answer: Self.answer(inputVersion: nil)
        )
        let pipeline = XboxCloudWebRTCNegotiationPipeline(signaling: signaling)

        let answer = try await pipeline.negotiate(
            peer: peer,
            context: makeSignalingContext()
        )

        #expect(answer.input == nil)
        #expect(answer.unreliableinput == 10)
        #expect(answer.reliableinput == 10)
        #expect(peer.remoteAnswer?.sdp == "fixture-answer")
        #expect(peer.appliedRemoteCandidates == [Self.remoteCandidate])
        #expect(await events.values() == [
            "peer.offer",
            "signaling.sdp",
            "peer.answer",
            "peer.local-ice",
            "signaling.ice",
            "peer.remote-ice",
        ])
    }

    @Test("Unsupported negotiated input stops before applying the answer")
    func rejectsUnsupportedInputVersion() async throws {
        let events = XboxWebRTCEventRecorder()
        let peer = XboxWebRTCPeerStub(events: events)
        let signaling = XboxWebRTCSignalingStub(
            events: events,
            answer: Self.answer(
                inputVersion: 11,
                unreliableInputVersion: nil,
                reliableInputVersion: nil
            )
        )
        let pipeline = XboxCloudWebRTCNegotiationPipeline(signaling: signaling)

        await #expect(
            throws: XboxCloudWebRTCTransportError.unsupportedInputVersion(11)
        ) {
            _ = try await pipeline.negotiate(
                peer: peer,
                context: makeSignalingContext()
            )
        }

        #expect(peer.remoteAnswer == nil)
        #expect(await events.values() == ["peer.offer", "signaling.sdp"])
    }

    @Test("Candidate exchange is bounded before an ICE request")
    func boundsCandidates() async throws {
        let events = XboxWebRTCEventRecorder()
        let candidates = (0 ... 64).map { index in
            XboxCloudICECandidate(candidate: "candidate:\(index)")
        }
        let peer = XboxWebRTCPeerStub(
            events: events,
            localCandidates: candidates
        )
        let signaling = XboxWebRTCSignalingStub(events: events)
        let pipeline = XboxCloudWebRTCNegotiationPipeline(signaling: signaling)

        await #expect(
            throws: XboxCloudWebRTCTransportError.tooManyICECandidates
        ) {
            _ = try await pipeline.negotiate(
                peer: peer,
                context: makeSignalingContext()
            )
        }

        #expect(await events.values() == [
            "peer.offer",
            "signaling.sdp",
            "peer.answer",
            "peer.local-ice",
        ])
    }

    @Test("Signaling cancellation propagates without applying remote state")
    func preservesCancellation() async throws {
        let events = XboxWebRTCEventRecorder()
        let peer = XboxWebRTCPeerStub(events: events)
        let signaling = XboxWebRTCSignalingStub(
            events: events,
            cancelsSDP: true
        )
        let pipeline = XboxCloudWebRTCNegotiationPipeline(signaling: signaling)

        await #expect(throws: CancellationError.self) {
            _ = try await pipeline.negotiate(
                peer: peer,
                context: makeSignalingContext()
            )
        }

        #expect(peer.remoteAnswer == nil)
        #expect(await events.values() == ["peer.offer", "signaling.sdp"])
    }

    @Test("Idle teardown is idempotent and input sends stay unavailable")
    func idleTeardown() {
        let transport = XboxCloudWebRTCTransport(
            signaling: XboxWebRTCSignalingStub(events: XboxWebRTCEventRecorder())
        )

        transport.disconnect()
        transport.disconnect()

        #expect(transport.state == .idle)
        #expect(transport.videoTrack == nil)
        #expect(transport.negotiatedInputVersion == nil)
        #expect(transport.sendInput(Data([1, 2, 3])) == .channelUnavailable)
    }

    @Test("Peer failure during connect remains a terminal transport error")
    func peerFailureDuringConnect() async throws {
        let signaling = XboxWebRTCBlockingSignalingStub()
        let transport = XboxCloudWebRTCTransport(signaling: signaling)
        let signalingContext = try makeSignalingContext()
        let connectTask = Task { @MainActor in
            try await transport.connect(
                configuration: Self.sessionConfiguration,
                signalingContext: signalingContext
            )
        }

        await signaling.waitUntilSDPStarts()
        transport.terminateActivePeer(
            reason: "Xbox Cloud network negotiation failed."
        )
        await signaling.releaseSDP()

        let expected = XboxCloudWebRTCTransportError.peerOperationFailed(
            operation: "maintaining the network path"
        )
        await #expect(throws: expected) {
            try await connectTask.value
        }
        #expect(
            transport.state == .failed(
                message: "Xbox Cloud network negotiation failed."
            )
        )
    }

    @Test("Transient disconnect recovers before its grace period expires")
    func transientDisconnectRecovers() async {
        let transport = XboxCloudWebRTCTransport(
            signaling: XboxWebRTCSignalingStub(
                events: XboxWebRTCEventRecorder()
            ),
            disconnectGracePeriod: .seconds(60)
        )

        transport.beginPeerConnectionLossGracePeriod(
            reason: "fixture transient disconnect"
        )
        transport.recoverPeerConnection()
        await Task.yield()

        #expect(transport.readiness.isPeerConnected)
        #expect(transport.state != .failed(message: "fixture transient disconnect"))
        transport.disconnect()
    }

    @Test("Transient disconnect becomes terminal after a fenced grace period")
    func transientDisconnectExpires() async {
        let transport = XboxCloudWebRTCTransport(
            signaling: XboxWebRTCSignalingStub(
                events: XboxWebRTCEventRecorder()
            ),
            sleep: { _ in }
        )

        transport.beginPeerConnectionLossGracePeriod(
            reason: "fixture expired disconnect"
        )
        for _ in 0 ..< 20 where transport.state != .failed(
            message: "fixture expired disconnect"
        ) {
            await Task.yield()
        }

        #expect(
            transport.state == .failed(message: "fixture expired disconnect")
        )
    }

    @Test("Explicit disconnect invalidates an outstanding grace timer")
    func explicitDisconnectInvalidatesGraceTimer() async {
        let transport = XboxCloudWebRTCTransport(
            signaling: XboxWebRTCSignalingStub(
                events: XboxWebRTCEventRecorder()
            ),
            sleep: { _ in }
        )

        transport.beginPeerConnectionLossGracePeriod(
            reason: "stale disconnect"
        )
        transport.disconnect()
        for _ in 0 ..< 5 {
            await Task.yield()
        }

        #expect(transport.state == .idle)
    }

    @Test("WebRTC callback bridge times out instead of hanging")
    func callbackTimeout() async {
        let expected = XboxCloudWebRTCTransportError.peerOperationFailed(
            operation: "fixture callback"
        )
        let callback = XboxCloudBoundedCallback<Int>(
            timeout: .seconds(1),
            timeoutError: expected,
            sleep: { _ in }
        )

        await #expect(throws: expected) {
            try await callback.value { _ in }
        }
    }

    @Test("WebRTC callback bridge resumes once for duplicate callbacks")
    func callbackDoubleResumeIsIgnored() async throws {
        let callback = XboxCloudBoundedCallback<Int>(
            timeout: .seconds(60),
            timeoutError: .unableToCreateOffer
        )

        let value = try await callback.value { completion in
            completion(.success(7))
            completion(.success(8))
        }
        await Task.yield()

        #expect(value == 7 || value == 8)
    }

    @Test("WebRTC callback bridge observes task cancellation")
    func callbackCancellation() async {
        let callback = XboxCloudBoundedCallback<Int>(
            timeout: .seconds(60),
            timeoutError: .unableToCreateOffer
        )
        let operation = Task { @MainActor in
            try await callback.value { _ in }
        }
        await Task.yield()

        operation.cancel()

        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
    }

    private func makeSignalingContext() throws -> XboxCloudSignalingContext {
        try XboxCloudSignalingContext(
            endpointBaseURL: URL(
                string: "https://region.gssv-play-prod.xboxlive.com"
            )!,
            sessionPath: "v5/sessions/cloud/fixture-session",
            gsToken: "fixture-gs-token",
            correlationVector: "fixture-cv.1"
        )
    }

    fileprivate nonisolated static let localCandidate = XboxCloudICECandidate(
        candidate: "candidate:local",
        sdpMid: "0",
        sdpMLineIndex: 0
    )

    fileprivate nonisolated static let remoteCandidate = XboxCloudICECandidate(
        candidate: "candidate:remote",
        sdpMid: "0",
        sdpMLineIndex: 0,
        routingPreference: "AZURE"
    )

    fileprivate nonisolated static let sessionConfiguration = XboxCloudSessionConfiguration(
        serverDetails: XboxCloudServerDetails(
            ipV4Address: "203.0.113.10",
            ipV4Port: 9002,
            ipV6Address: nil,
            ipV6Port: nil,
            srtp: nil,
            uriPathAndQuery: nil,
            stunServerAddresses: ["stun.example.test:3478"]
        ),
        keepAlivePulse: 15,
        clientStreamingConfigOverrides: nil
    )

    fileprivate nonisolated static func answer(
        inputVersion: Int? = 10,
        unreliableInputVersion: Int? = 10,
        reliableInputVersion: Int? = 10
    ) -> XboxCloudSDPAnswer {
        XboxCloudSDPAnswer(
            status: "success",
            sdpType: "answer",
            sdp: "fixture-answer",
            chatStream: 1,
            control: 3,
            input: inputVersion,
            unreliableinput: unreliableInputVersion,
            reliableinput: reliableInputVersion,
            message: 1,
            chat: 1
        )
    }
}

private actor XboxWebRTCBlockingSignalingStub: XboxCloudSignalingProviding {
    private let startedStream: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let releaseStream: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        (startedStream, startedContinuation) = AsyncStream.makeStream()
        (releaseStream, releaseContinuation) = AsyncStream.makeStream()
    }

    func waitUntilSDPStarts() async {
        for await _ in startedStream {
            return
        }
    }

    func releaseSDP() {
        releaseContinuation.yield()
    }

    func exchangeSDP(
        offer _: String,
        context _: XboxCloudSignalingContext,
        configuration _: XboxCloudSDPConfiguration
    ) async throws -> XboxCloudSDPAnswer {
        startedContinuation.yield()
        for await _ in releaseStream {
            try Task.checkCancellation()
            return XboxCloudWebRTCTransportTests.answer()
        }
        throw CancellationError()
    }

    func exchangeICE(
        candidates _: [XboxCloudICECandidate],
        context _: XboxCloudSignalingContext
    ) async throws -> [XboxCloudICECandidate] {
        []
    }
}

private actor XboxWebRTCEventRecorder {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func values() -> [String] {
        events
    }
}

@MainActor
private final class XboxWebRTCPeerStub: XboxCloudWebRTCNegotiatingPeer {
    private let events: XboxWebRTCEventRecorder
    private let localCandidates: [XboxCloudICECandidate]

    private(set) var remoteAnswer: XboxCloudSDPAnswer?
    private(set) var appliedRemoteCandidates: [XboxCloudICECandidate] = []

    init(
        events: XboxWebRTCEventRecorder,
        localCandidates: [XboxCloudICECandidate] = [
            XboxCloudWebRTCTransportTests.localCandidate,
        ]
    ) {
        self.events = events
        self.localCandidates = localCandidates
    }

    func createAndSetLocalOffer() async throws -> String {
        await events.record("peer.offer")
        return "fixture-offer"
    }

    func setRemoteAnswer(_ answer: XboxCloudSDPAnswer) async throws {
        await events.record("peer.answer")
        remoteAnswer = answer
    }

    func waitForLocalICECandidates() async throws -> [XboxCloudICECandidate] {
        await events.record("peer.local-ice")
        return localCandidates
    }

    func addRemoteICECandidates(
        _ candidates: [XboxCloudICECandidate]
    ) async throws {
        await events.record("peer.remote-ice")
        appliedRemoteCandidates = candidates
    }
}

private actor XboxWebRTCSignalingStub: XboxCloudSignalingProviding {
    private let events: XboxWebRTCEventRecorder
    private let answer: XboxCloudSDPAnswer
    private let cancelsSDP: Bool

    init(
        events: XboxWebRTCEventRecorder,
        answer: XboxCloudSDPAnswer = XboxCloudWebRTCTransportTests.answer(),
        cancelsSDP: Bool = false
    ) {
        self.events = events
        self.answer = answer
        self.cancelsSDP = cancelsSDP
    }

    func exchangeSDP(
        offer: String,
        context _: XboxCloudSignalingContext,
        configuration: XboxCloudSDPConfiguration
    ) async throws -> XboxCloudSDPAnswer {
        await events.record("signaling.sdp")
        #expect(offer == "fixture-offer")
        #expect(configuration == .webInput)
        if cancelsSDP {
            throw CancellationError()
        }
        return answer
    }

    func exchangeICE(
        candidates: [XboxCloudICECandidate],
        context _: XboxCloudSignalingContext
    ) async throws -> [XboxCloudICECandidate] {
        await events.record("signaling.ice")
        #expect(candidates == [XboxCloudWebRTCTransportTests.localCandidate])
        return [XboxCloudWebRTCTransportTests.remoteCandidate]
    }
}
