import AVFAudio
import Foundation
@preconcurrency import LiveKitWebRTC
import os.log
import Synchronization

private nonisolated let audioDeviceLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "AudioDevice")

nonisolated struct MicrophoneActivitySnapshot: Equatable, Sendable {
    let isCapturing: Bool
    let level: Double
}

/// Lock-free bridge from the realtime capture callback to the HUD. Each capture graph gets
/// an immutable writer generation, so a callback from an engine being replaced cannot make
/// stale microphone state visible after a route change.
final nonisolated class MicrophoneTelemetry: Sendable {
    struct Writer: Sendable {
        fileprivate let telemetry: MicrophoneTelemetry
        fileprivate let generation: UInt32

        @inline(__always)
        var isEnabled: Bool {
            telemetry.isEnabled(generation: generation)
        }

        @inline(__always)
        func publish(sumSquares: Float, sampleCount: Int) {
            telemetry.publish(
                generation: generation,
                sumSquares: sumSquares,
                sampleCount: sampleCount
            )
        }
    }

    private static let enabledBit: UInt64 = 1 << 16
    private static let activeBit: UInt64 = 1 << 17
    private static let levelMask: UInt64 = 0xFFFF
    private static let generationShift: UInt64 = 32
    private static let generationMask: UInt64 = 0xFFFF_FFFF << generationShift
    private static let maximumLevel = Float(UInt16.max)
    private static let activityTimeoutNanoseconds: UInt64 = 350_000_000

    private let nextGeneration = Atomic<UInt32>(0)
    private let state = Atomic<UInt64>(0)
    private let lastActivityUptimeNanoseconds = Atomic<UInt64>(0)

    var snapshot: MicrophoneActivitySnapshot {
        let packed = state.load(ordering: .relaxed)
        let lastActivity = lastActivityUptimeNanoseconds.load(ordering: .relaxed)
        let now = DispatchTime.now().uptimeNanoseconds
        let isFresh = lastActivity > 0
            && now >= lastActivity
            && now - lastActivity <= Self.activityTimeoutNanoseconds
        let isCapturing = packed & Self.activeBit != 0 && isFresh
        let encodedLevel = packed & Self.levelMask
        return MicrophoneActivitySnapshot(
            isCapturing: isCapturing,
            level: isCapturing ? Double(encodedLevel) / Double(UInt16.max) : 0
        )
    }

    func makeWriter() -> Writer {
        let generation = nextGeneration.wrappingAdd(1, ordering: .relaxed).newValue
        lastActivityUptimeNanoseconds.store(0, ordering: .relaxed)
        state.store(Self.packedGeneration(generation), ordering: .relaxed)
        return Writer(telemetry: self, generation: generation)
    }

    func setEnabled(_ enabled: Bool, for writer: Writer) {
        let generation = Self.packedGeneration(writer.generation)
        guard state.load(ordering: .relaxed) & Self.generationMask == generation else { return }
        state.store(generation | (enabled ? Self.enabledBit : 0), ordering: .relaxed)
    }

    func invalidate() {
        let generation = state.load(ordering: .relaxed) & Self.generationMask
        lastActivityUptimeNanoseconds.store(0, ordering: .relaxed)
        state.store(generation, ordering: .relaxed)
    }

    @inline(__always)
    private func isEnabled(generation: UInt32) -> Bool {
        let packed = state.load(ordering: .relaxed)
        return packed & Self.generationMask == Self.packedGeneration(generation)
            && packed & Self.enabledBit != 0
    }

    /// Publishes one envelope sample after WebRTC accepts the corresponding PCM buffer.
    /// A bounded compare/exchange avoids unbounded work if start/stop races the callback.
    @inline(__always)
    private func publish(generation: UInt32, sumSquares: Float, sampleCount: Int) {
        guard sampleCount > 0 else { return }

        let rms = sqrt(max(sumSquares / Float(sampleCount), 0.000_000_01))
        let decibels = 20 * log10(max(rms, 0.000_01))
        let instantaneous = min(1, max(0, (decibels + 50) / 44))
        let expectedGeneration = Self.packedGeneration(generation)
        var current = state.load(ordering: .relaxed)

        for _ in 0 ..< 2 {
            guard current & Self.generationMask == expectedGeneration,
                  current & Self.enabledBit != 0
            else { return }

            let previous = Float(current & Self.levelMask) / Self.maximumLevel
            let smoothed = max(instantaneous, previous * 0.92)
            let encoded = UInt64(min(Self.maximumLevel, max(0, smoothed * Self.maximumLevel)))
            let desired = expectedGeneration | Self.enabledBit | Self.activeBit | encoded
            let result = state.compareExchange(
                expected: current,
                desired: desired,
                ordering: .relaxed
            )
            if result.exchanged {
                lastActivityUptimeNanoseconds.store(
                    DispatchTime.now().uptimeNanoseconds,
                    ordering: .relaxed
                )
                return
            }
            current = result.original
        }
    }

    @inline(__always)
    private static func packedGeneration(_ generation: UInt32) -> UInt64 {
        UInt64(generation) << generationShift
    }
}

/// Owns a preallocated Int16 conversion buffer; deallocates when the capturing
/// render closure (and thus the audio node) is released.
private final nonisolated class ScratchBuffer: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Int16>

    init(capacity: Int) {
        pointer = .allocate(capacity: capacity)
    }

    deinit {
        pointer.deallocate()
    }
}

private nonisolated struct AudioRouteFingerprint: Equatable, Sendable {
    private struct Port: Equatable, Sendable {
        let type: String
        let uid: String
        let channels: Int

        init(_ port: AVAudioSessionPortDescription) {
            type = port.portType.rawValue
            uid = port.uid
            channels = port.channels?.count ?? 0
        }
    }

    private let category: String
    private let mode: String
    private let sampleRate: Int
    private let inputChannels: Int
    private let outputChannels: Int
    private let ioBufferMicroseconds: Int
    private let inputLatencyMicroseconds: Int
    private let outputLatencyMicroseconds: Int
    private let inputs: [Port]
    private let outputs: [Port]

    init(session: AVAudioSession) {
        category = session.category.rawValue
        mode = session.mode.rawValue
        sampleRate = Int(session.sampleRate.rounded())
        inputChannels = session.inputNumberOfChannels
        outputChannels = session.outputNumberOfChannels
        ioBufferMicroseconds = Self.microseconds(session.ioBufferDuration)
        inputLatencyMicroseconds = Self.microseconds(session.inputLatency)
        outputLatencyMicroseconds = Self.microseconds(session.outputLatency)
        inputs = session.currentRoute.inputs.map(Port.init)
        outputs = session.currentRoute.outputs.map(Port.init)
    }

    var logDescription: String {
        let input = inputs.map { "\($0.type):\($0.channels)ch" }.joined(separator: ",")
        let output = outputs.map { "\($0.type):\($0.channels)ch" }.joined(separator: ",")
        return "\(category)/\(mode) \(sampleRate)Hz \(ioBufferMicroseconds)us "
            + "latency \(inputLatencyMicroseconds)/\(outputLatencyMicroseconds)us "
            + "in[\(input)] out[\(output)]"
    }

    func hasSameGraphIdentity(as other: Self) -> Bool {
        category == other.category
            && mode == other.mode
            && sampleRate == other.sampleRate
            && inputChannels == other.inputChannels
            && outputChannels == other.outputChannels
            && inputs == other.inputs
            && outputs == other.outputs
    }

    private static func microseconds(_ duration: TimeInterval) -> Int {
        Int((duration * 1_000_000).rounded())
    }
}

/// Custom WebRTC audio device: an AVAudioEngine render path replacing the built-in audio
/// device module, whose playout is hard-coded MONO on Apple platforms (audio_device_ios.mm
/// pins `playout_parameters_.channels()` to 1, so the stereo we negotiate via `stereo=1`
/// was silently downmixed before reaching the speaker).
///
/// Owning the device unlocks:
/// - true stereo playout of GFN's stereo Opus,
/// - 5.1 playout of multiopus when the route supports ≥6 output channels,
/// - direct control over the output render quantum (latency).
///
/// Threading contract (RTCAudioDevice.h): all protocol members are called from the native
/// ADM thread between `initializeWithDelegate` and `terminateDevice`. The render closures
/// run on the audio I/O thread; they capture the delegate blocks and buffers at
/// node-creation time so the realtime path never reads mutable state on `self`.
final nonisolated class GFNAudioDevice: NSObject, @unchecked Sendable {
    static let shared = GFNAudioDevice()

    let microphoneTelemetry = MicrophoneTelemetry()

    /// Output channels the next stream wants (2 or 6), set from the negotiated offer before
    /// playout initializes. The effective count is capped by the active route's capability.
    var requestedOutputChannels = 2

    private var delegate: LKRTCAudioDeviceDelegate?
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var sinkNode: AVAudioSinkNode?
    private var captureWriter: MicrophoneTelemetry.Writer?
    private var playoutFormat: AVAudioFormat?
    private var captureFormat: AVAudioFormat?
    private var playoutInitializedFlag = false
    private var recordingInitializedFlag = false
    private var playingFlag = false
    /// Logical WebRTC start/stop intent. Operational capture is represented by the
    /// current sink/writer and `microphoneTelemetry`, so route loss does not erase intent.
    private var recordingFlag = false
    private var routeChangeObserver: NSObjectProtocol?
    private var engineConfigurationObserver: NSObjectProtocol?
    private var activeRouteFingerprint: AudioRouteFingerprint?
    private let deviceLifetimeGeneration = Atomic<UInt64>(0)
    private let routeRecoveryGeneration = Atomic<UInt64>(0)
    private let routeRecoveryQueue = DispatchQueue(
        label: "com.owenselles.CloudNow2.audio-route-recovery",
        qos: .userInitiated
    )

    private static let routeRecoveryDelays: [TimeInterval] = [0.1, 0.25, 0.5, 1.0]

    private enum RouteRecoveryResult {
        case restored
        case awaitingInput
        case failed
    }

    // MARK: Playout graph

    private func buildPlayoutGraph(on engine: AVAudioEngine, delegate: LKRTCAudioDeviceDelegate) -> Bool {
        let session = AVAudioSession.sharedInstance()
        let wanted = max(2, requestedOutputChannels)
        let routeMax = max(1, session.maximumOutputNumberOfChannels)
        do {
            try session.setPreferredOutputNumberOfChannels(min(wanted, routeMax))
            try session.setPreferredIOBufferDuration(0.01)
        } catch {
            audioDeviceLog.error("preferred output configuration failed: \(error, privacy: .private)")
        }
        let granted = max(1, session.outputNumberOfChannels)
        let channels = min(wanted, granted)

        // Above 2 channels an AVAudioFormat needs an explicit layout. MPEG_5_1_A is
        // L R C LFE Ls Rs — the same 5.1 order WebRTC's multiopus decode delivers.
        let format: AVAudioFormat?
        if channels >= 6, let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A) {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(2 * channels),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(2 * channels),
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 16,
                mReserved: 0
            )
            format = AVAudioFormat(streamDescription: &asbd, channelLayout: layout)
        } else {
            format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 48000,
                channels: AVAudioChannelCount(min(channels, 2)),
                interleaved: true
            )
        }
        guard let format else {
            audioDeviceLog.error("could not create Int16 playout format (\(channels)ch)")
            return false
        }

        // Capture the pull block once; the render closure must not touch `self` state.
        let pullPlayoutData = delegate.getPlayoutData
        let source = AVAudioSourceNode(format: format) { _, timestamp, frameCount, outputData -> OSStatus in
            var flags = AudioUnitRenderActionFlags()
            return pullPlayoutData(&flags, timestamp, 0, frameCount, outputData)
        }

        engine.attach(source)
        if channels >= 6 {
            // Surround must bypass the main mixer: AVAudioMixerNode folds multichannel
            // input into the front channels when layouts differ, silencing the rears
            // while the HDMI output stays 6-channel. The output node maps by layout.
            engine.connect(source, to: engine.outputNode, format: format)
        } else {
            engine.connect(source, to: engine.mainMixerNode, format: format)
        }
        sourceNode = source
        playoutFormat = format
        let hwFormat = engine.outputNode.outputFormat(forBus: 0)
        let hwLayoutTag = hwFormat.channelLayout?.layoutTag
        audioDeviceLog.info(
            "output hw: \(hwFormat.channelCount)ch @\(hwFormat.sampleRate)Hz layoutTag=\(hwLayoutTag.map(String.init) ?? "none", privacy: .public)"
        )
        // portChannels is the EDID-derived channel count of the connected sink (unlike
        // maximumOutputNumberOfChannels, which reports the OS mixer's 32-ch capability).
        let portChannels = session.currentRoute.outputs.first?.channels?.count ?? 0
        audioDeviceLog.info(
            "playout: \(channels)ch @48kHz (wanted \(wanted), route max \(routeMax), granted \(granted), port \(portChannels)) | route [\(session.currentRoute.outputs.map(\.portName).joined(separator: ", "), privacy: .public)]"
        )
        return true
    }

    // MARK: Capture graph (GFN microphone)

    /// The sink receives buffers in the hardware input format (Float32, typically mono);
    /// WebRTC expects interleaved Int16, so the closure converts into a preallocated
    /// scratch buffer before handing the samples to the native ADM.
    private func buildCaptureGraph(on engine: AVAudioEngine, delegate: LKRTCAudioDeviceDelegate) -> Bool {
        let session = AVAudioSession.sharedInstance()
        guard session.isInputAvailable else {
            audioDeviceLog.info("capture unavailable: no input route")
            return false
        }

        // AVAudioEngine's I/O unit leaves hardware input disabled by default. Reading the
        // input node before enabling it produces a 0 Hz format and poisons the shared
        // playout/capture graph, so RemoteIO then fails to start playback as well.
        guard !engine.isRunning else {
            audioDeviceLog.error("capture graph mutation rejected while engine is running")
            return false
        }
        let ioUnit = engine.outputNode.auAudioUnit
        guard ioUnit.canPerformInput else {
            audioDeviceLog.info("capture unavailable: I/O unit cannot perform input")
            return false
        }
        ioUnit.isInputEnabled = true
        var captureReady = false
        defer {
            if !captureReady {
                ioUnit.isInputEnabled = false
            }
        }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)
        let channels = min(2, max(1, Int(hwFormat.channelCount)))
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            audioDeviceLog.info(
                "capture unavailable: invalid input format (\(hwFormat.channelCount)ch @\(hwFormat.sampleRate)Hz)"
            )
            return false
        }

        let maxFrames = 4096
        let scratchBox = ScratchBuffer(capacity: maxFrames * channels)
        let scratch = scratchBox.pointer
        let deliver = delegate.deliverRecordedData
        let writer = microphoneTelemetry.makeWriter()
        let sink = AVAudioSinkNode { [scratchBox, writer] timestamp, frameCount, inputData -> OSStatus in
            _ = scratchBox // owns the scratch allocation for the node's lifetime
            guard writer.isEnabled else { return noErr }

            let frames = min(Int(frameCount), maxFrames)
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData)
            )
            var sumSquares: Float = 0
            var sampleCount = 0
            // Float32 (interleaved or deinterleaved) → interleaved Int16
            if buffers.count == 1, let data = buffers[0].mData {
                let floats = data.assumingMemoryBound(to: Float.self)
                for i in 0 ..< frames * channels {
                    let sample = max(-1, min(1, floats[i]))
                    scratch[i] = Int16(sample * 32767)
                    sumSquares += sample * sample
                }
                sampleCount = frames * channels
            } else {
                for (channel, buffer) in buffers.enumerated() where channel < channels {
                    guard let data = buffer.mData else { continue }
                    let floats = data.assumingMemoryBound(to: Float.self)
                    for frame in 0 ..< frames {
                        let sample = max(-1, min(1, floats[frame]))
                        scratch[frame * channels + channel] = Int16(sample * 32767)
                        sumSquares += sample * sample
                    }
                    sampleCount += frames
                }
            }
            var outList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(frames * channels * MemoryLayout<Int16>.size),
                    mData: UnsafeMutableRawPointer(scratch)
                )
            )
            var flags = AudioUnitRenderActionFlags()
            let status = deliver(&flags, timestamp, 1, UInt32(frames), &outList, nil, nil)
            if status == noErr {
                writer.publish(sumSquares: sumSquares, sampleCount: sampleCount)
            }
            return status
        }

        engine.attach(sink)
        engine.connect(inputNode, to: sink, format: hwFormat)
        sinkNode = sink
        captureWriter = writer
        captureFormat = hwFormat
        captureReady = true
        audioDeviceLog.info(
            "capture: \(channels)ch @\(Int(hwFormat.sampleRate))Hz (input enabled \(ioUnit.isInputEnabled))"
        )
        return true
    }

    // MARK: Engine lifecycle

    private func activeEngine() -> AVAudioEngine {
        if let engine {
            return engine
        }
        let engine = AVAudioEngine()
        self.engine = engine
        return engine
    }

    private func tearDownEngine() {
        microphoneTelemetry.invalidate()
        engine?.stop()
        if let engine {
            if let sourceNode {
                engine.detach(sourceNode)
            }
            if let sinkNode {
                engine.detach(sinkNode)
            }
        }
        sourceNode = nil
        sinkNode = nil
        captureWriter = nil
        engine = nil
        playoutFormat = nil
        captureFormat = nil
        activeRouteFingerprint = nil
    }

    private func startEngineIfNeeded() -> Bool {
        guard let engine else { return false }
        if engine.isRunning {
            activeRouteFingerprint = AudioRouteFingerprint(session: .sharedInstance())
            return true
        }
        engine.prepare()
        do {
            try engine.start()
            activeRouteFingerprint = AudioRouteFingerprint(session: .sharedInstance())
        } catch {
            audioDeviceLog.error("engine start failed: \(error, privacy: .private)")
            return false
        }
        return true
    }

    private func setCaptureEnabled(_ enabled: Bool) {
        guard let captureWriter else {
            microphoneTelemetry.invalidate()
            return
        }
        microphoneTelemetry.setEnabled(enabled, for: captureWriter)
    }

    /// A failed duplex graph must never take game audio down with it. Recreate the
    /// engine without its input node because a failed I/O engine may retain invalid
    /// hardware formats even after capture is detached.
    private func restorePlayoutOnlyAfterCaptureFailure(restart: Bool) -> Bool {
        guard let delegate else { return false }
        audioDeviceLog.error("microphone graph failed; rebuilding playout-only engine")

        if sinkNode != nil {
            delegate.notifyAudioInputInterrupted()
        }
        if sourceNode != nil {
            delegate.notifyAudioOutputInterrupted()
        }
        tearDownEngine()

        if playoutInitializedFlag {
            guard buildPlayoutGraph(on: activeEngine(), delegate: delegate) else {
                audioDeviceLog.error("playout-only recovery graph failed")
                return false
            }
            delegate.notifyAudioOutputParametersChange()
        }
        if recordingInitializedFlag {
            delegate.notifyAudioInputParametersChange()
        }

        guard restart else {
            activeRouteFingerprint = AudioRouteFingerprint(session: .sharedInstance())
            return true
        }
        return startEngineIfNeeded()
    }

    /// Route notifications may arrive after the engine already adopted that route. Coalesce
    /// them off the ADM thread, then rebuild only when the settled hardware fingerprint differs
    /// or the engine actually stopped. This avoids destroying a healthy HFP duplex graph in
    /// response to its own delayed category/configuration notification.
    private func scheduleRouteRecovery(
        trigger: String,
        delegate: LKRTCAudioDeviceDelegate,
        lifetime: UInt64? = nil
    ) {
        let currentLifetime = deviceLifetimeGeneration.load(ordering: .relaxed)
        guard lifetime == nil || lifetime == currentLifetime else { return }

        let generation = routeRecoveryGeneration.wrappingAdd(1, ordering: .relaxed).newValue
        enqueueRouteRecovery(
            trigger: trigger,
            delegate: delegate,
            lifetime: currentLifetime,
            generation: generation,
            attempt: 0
        )
    }

    private func enqueueRouteRecovery(
        trigger: String,
        delegate: LKRTCAudioDeviceDelegate,
        lifetime: UInt64,
        generation: UInt64,
        attempt: Int
    ) {
        guard attempt < Self.routeRecoveryDelays.count else {
            audioDeviceLog.error(
                "route recovery paused after \(attempt) attempts; intent retained until the next route event (\(trigger, privacy: .public))"
            )
            return
        }
        let delay = Self.routeRecoveryDelays[attempt]
        routeRecoveryQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  deviceLifetimeGeneration.load(ordering: .relaxed) == lifetime,
                  routeRecoveryGeneration.load(ordering: .relaxed) == generation
            else { return }

            delegate.dispatchAsync { [weak self] in
                guard let self,
                      deviceLifetimeGeneration.load(ordering: .relaxed) == lifetime,
                      routeRecoveryGeneration.load(ordering: .relaxed) == generation,
                      let activeDelegate = self.delegate,
                      activeDelegate === delegate
                else { return }

                recoverRoute(
                    trigger: trigger,
                    delegate: activeDelegate,
                    lifetime: lifetime,
                    generation: generation,
                    attempt: attempt
                )
            }
        }
    }

    private func recoverRoute(
        trigger: String,
        delegate: LKRTCAudioDeviceDelegate,
        lifetime: UInt64,
        generation: UInt64,
        attempt: Int
    ) {
        guard playoutInitializedFlag || recordingInitializedFlag else { return }

        let session = AVAudioSession.sharedInstance()
        let currentRoute = AudioRouteFingerprint(session: session)
        let engineRunning = engine?.isRunning == true
        let outputGraphMatches = !playoutInitializedFlag || sourceNode != nil && playoutFormat != nil
        let inputGraphMatches = !recordingInitializedFlag || sinkNode != nil && captureFormat != nil
        let engineShouldRun = playingFlag || recordingFlag && inputGraphMatches
        var routeMatches = currentRoute == activeRouteFingerprint
        let graphIdentityMatches = activeRouteFingerprint.map {
            currentRoute.hasSameGraphIdentity(as: $0)
        } ?? false

        // A buffer-duration or latency notification changes WebRTC's parameters, but not
        // the AVAudioEngine topology. Synchronize ADM without introducing an audible rebuild.
        if !routeMatches,
           graphIdentityMatches,
           engineRunning == engineShouldRun,
           outputGraphMatches,
           inputGraphMatches || !hasUsableInputRoute(session)
        {
            if playoutInitializedFlag {
                delegate.notifyAudioOutputParametersChange()
            }
            if recordingInitializedFlag {
                delegate.notifyAudioInputParametersChange()
            }
            activeRouteFingerprint = currentRoute
            routeMatches = true
            audioDeviceLog.info(
                "audio parameters refreshed without graph rebuild (\(trigger, privacy: .public)) | \(currentRoute.logDescription, privacy: .public)"
            )
        }

        if routeMatches,
           engineRunning == engineShouldRun,
           outputGraphMatches,
           inputGraphMatches
        {
            if recordingFlag {
                setCaptureEnabled(true)
            }
            audioDeviceLog.info(
                "route notification ignored; graph is current (\(trigger, privacy: .public)) | \(currentRoute.logDescription, privacy: .public)"
            )
            return
        }

        if routeMatches,
           engineRunning == engineShouldRun,
           outputGraphMatches,
           recordingInitializedFlag,
           !inputGraphMatches,
           !hasUsableInputRoute(session)
        {
            setCaptureEnabled(false)
            audioDeviceLog.info(
                "route settled without microphone; waiting for input (\(trigger, privacy: .public)) | \(currentRoute.logDescription, privacy: .public)"
            )
            enqueueRouteRecovery(
                trigger: trigger,
                delegate: delegate,
                lifetime: lifetime,
                generation: generation,
                attempt: attempt + 1
            )
            return
        }

        audioDeviceLog.info(
            "route recovery attempt \(attempt + 1) (\(trigger, privacy: .public)) running=\(engineRunning) | \(currentRoute.logDescription, privacy: .public)"
        )

        let result = rebuildGraphsForCurrentRoute(delegate: delegate)
        if result != .restored {
            enqueueRouteRecovery(
                trigger: trigger,
                delegate: delegate,
                lifetime: lifetime,
                generation: generation,
                attempt: attempt + 1
            )
        }
    }

    private func hasUsableInputRoute(_ session: AVAudioSession) -> Bool {
        session.isInputAvailable
            && !session.currentRoute.inputs.isEmpty
            && session.inputNumberOfChannels > 0
    }

    private func rebuildGraphsForCurrentRoute(delegate: LKRTCAudioDeviceDelegate) -> RouteRecoveryResult {
        let shouldPlay = playingFlag
        let shouldRecord = recordingFlag

        if sinkNode != nil || shouldRecord {
            delegate.notifyAudioInputInterrupted()
        }
        if sourceNode != nil || shouldPlay {
            delegate.notifyAudioOutputInterrupted()
        }

        tearDownEngine()
        let newEngine = activeEngine()
        if playoutInitializedFlag, !buildPlayoutGraph(on: newEngine, delegate: delegate) {
            audioDeviceLog.error("playout rebuild after route change failed")
            return .failed
        }

        var captureReady = false
        if recordingInitializedFlag, hasUsableInputRoute(.sharedInstance()) {
            if buildCaptureGraph(on: newEngine, delegate: delegate) {
                captureReady = true
            } else {
                let restored = restorePlayoutOnlyAfterCaptureFailure(restart: shouldPlay)
                return restored ? .awaitingInput : .failed
            }
        }

        // Native ADM must re-read every changed parameter before either callback resumes.
        if playoutInitializedFlag {
            delegate.notifyAudioOutputParametersChange()
        }
        if recordingInitializedFlag {
            delegate.notifyAudioInputParametersChange()
        }

        setCaptureEnabled(shouldRecord && captureReady)
        let shouldRun = shouldPlay || shouldRecord && captureReady
        if shouldRun, !startEngineIfNeeded() {
            setCaptureEnabled(false)
            if captureReady {
                let restored = restorePlayoutOnlyAfterCaptureFailure(restart: shouldPlay)
                return restored ? .awaitingInput : .failed
            }
            return .failed
        }

        if !shouldRun {
            activeRouteFingerprint = AudioRouteFingerprint(session: .sharedInstance())
        }
        return recordingInitializedFlag && !captureReady ? .awaitingInput : .restored
    }
}

// MARK: - LKRTCAudioDevice

extension GFNAudioDevice: LKRTCAudioDevice {
    var deviceInputSampleRate: Double {
        captureFormat?.sampleRate ?? 48000
    }

    var inputIOBufferDuration: TimeInterval {
        AVAudioSession.sharedInstance().ioBufferDuration
    }

    var inputNumberOfChannels: Int {
        min(2, max(1, Int(captureFormat?.channelCount ?? 1)))
    }

    var inputLatency: TimeInterval {
        AVAudioSession.sharedInstance().inputLatency
    }

    var deviceOutputSampleRate: Double {
        playoutFormat?.sampleRate ?? 48000
    }

    var outputIOBufferDuration: TimeInterval {
        AVAudioSession.sharedInstance().ioBufferDuration
    }

    var outputNumberOfChannels: Int {
        Int(playoutFormat?.channelCount ?? 2)
    }

    var outputLatency: TimeInterval {
        AVAudioSession.sharedInstance().outputLatency
    }

    /// Human-readable output port name(s) of the active route, e.g. "HDMI".
    var outputRouteName: String {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .map(\.portName)
            .joined(separator: ", ")
    }

    var isInitialized: Bool {
        delegate != nil
    }

    func initialize(with delegate: LKRTCAudioDeviceDelegate) -> Bool {
        let lifetime = deviceLifetimeGeneration.wrappingAdd(1, ordering: .relaxed).newValue
        _ = routeRecoveryGeneration.wrappingAdd(1, ordering: .relaxed)
        self.delegate = delegate
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) ?? .unknown
            self?.scheduleRouteRecovery(
                trigger: "routeChange:\(reason.rawValue)",
                delegate: delegate,
                lifetime: lifetime
            )
        }
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleRouteRecovery(
                trigger: "engineConfigurationChange",
                delegate: delegate,
                lifetime: lifetime
            )
        }
        return true
    }

    func terminateDevice() -> Bool {
        _ = deviceLifetimeGeneration.wrappingAdd(1, ordering: .relaxed)
        _ = routeRecoveryGeneration.wrappingAdd(1, ordering: .relaxed)
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
            self.engineConfigurationObserver = nil
        }
        tearDownEngine()
        playoutInitializedFlag = false
        recordingInitializedFlag = false
        playingFlag = false
        recordingFlag = false
        delegate = nil
        return true
    }

    var isPlayoutInitialized: Bool {
        playoutInitializedFlag
    }

    func initializePlayout() -> Bool {
        guard let delegate else { return false }
        playoutInitializedFlag = false
        let wasRunning = engine?.isRunning == true
        if wasRunning {
            if sinkNode != nil {
                delegate.notifyAudioInputInterrupted()
            }
            if sourceNode != nil {
                delegate.notifyAudioOutputInterrupted()
            }
            engine?.stop()
        }
        if let sourceNode, let engine {
            engine.detach(sourceNode)
            self.sourceNode = nil
            playoutFormat = nil
        }
        guard buildPlayoutGraph(on: activeEngine(), delegate: delegate) else {
            if recordingInitializedFlag {
                delegate.notifyAudioInputParametersChange()
                setCaptureEnabled(recordingFlag)
            }
            if wasRunning {
                _ = startEngineIfNeeded()
            }
            return false
        }
        playoutInitializedFlag = true

        delegate.notifyAudioOutputParametersChange()
        if recordingInitializedFlag {
            delegate.notifyAudioInputParametersChange()
        }
        setCaptureEnabled(recordingFlag)
        activeRouteFingerprint = AudioRouteFingerprint(session: .sharedInstance())

        if wasRunning, !startEngineIfNeeded() {
            let restored = restorePlayoutOnlyAfterCaptureFailure(restart: false)
            if restored {
                scheduleRouteRecovery(trigger: "playoutInitialization", delegate: delegate)
            }
            return restored
        }
        return true
    }

    var isPlaying: Bool {
        playingFlag
    }

    func startPlayout() -> Bool {
        if !startEngineIfNeeded() {
            guard recordingInitializedFlag,
                  restorePlayoutOnlyAfterCaptureFailure(restart: false),
                  startEngineIfNeeded()
            else {
                return false
            }
        }
        playingFlag = true
        if recordingFlag, sinkNode == nil, let delegate {
            scheduleRouteRecovery(trigger: "playoutStart", delegate: delegate)
        }
        return true
    }

    func stopPlayout() -> Bool {
        playingFlag = false
        if !recordingFlag {
            engine?.stop()
        }
        return true
    }

    var isRecordingInitialized: Bool {
        recordingInitializedFlag
    }

    func initializeRecording() -> Bool {
        guard let delegate else { return false }
        recordingInitializedFlag = false
        setCaptureEnabled(false)
        let wasRunning = engine?.isRunning == true
        if wasRunning {
            if sinkNode != nil {
                delegate.notifyAudioInputInterrupted()
            }
            if sourceNode != nil {
                delegate.notifyAudioOutputInterrupted()
            }
            engine?.stop()
        }
        if let sinkNode, let engine {
            engine.detach(sinkNode)
            self.sinkNode = nil
            captureWriter = nil
            captureFormat = nil
        }
        guard buildCaptureGraph(on: activeEngine(), delegate: delegate) else {
            guard restorePlayoutOnlyAfterCaptureFailure(restart: playingFlag) else {
                return false
            }
            // The controller only creates the mic track after AVAudioSession exposes an
            // input route. A 0 Hz format here is therefore a transient HFP/engine race:
            // accept initialization, keep playback alive, and recover capture asynchronously.
            recordingInitializedFlag = true
            delegate.notifyAudioInputParametersChange()
            scheduleRouteRecovery(trigger: "recordingInitializationDeferred", delegate: delegate)
            audioDeviceLog.info("recording initialization deferred until input route settles")
            return true
        }
        recordingInitializedFlag = true
        setCaptureEnabled(recordingFlag)

        if playoutInitializedFlag {
            delegate.notifyAudioOutputParametersChange()
        }
        delegate.notifyAudioInputParametersChange()
        activeRouteFingerprint = AudioRouteFingerprint(session: .sharedInstance())

        if wasRunning, !startEngineIfNeeded() {
            recordingInitializedFlag = false
            _ = restorePlayoutOnlyAfterCaptureFailure(restart: playingFlag)
            return false
        }
        return true
    }

    var isRecording: Bool {
        recordingFlag
    }

    func startRecording() -> Bool {
        guard recordingInitializedFlag else {
            audioDeviceLog.info("recording start rejected: capture graph is unavailable")
            return false
        }
        recordingFlag = true
        if sinkNode == nil {
            setCaptureEnabled(false)
            if let delegate {
                scheduleRouteRecovery(trigger: "recordingStart", delegate: delegate)
            }
            return true
        }
        setCaptureEnabled(true)
        guard startEngineIfNeeded() else {
            setCaptureEnabled(false)
            _ = restorePlayoutOnlyAfterCaptureFailure(restart: playingFlag)
            if let delegate {
                scheduleRouteRecovery(trigger: "recordingStartFailure", delegate: delegate)
            }
            return true
        }
        return true
    }

    func stopRecording() -> Bool {
        recordingFlag = false
        setCaptureEnabled(false)
        if !playingFlag {
            engine?.stop()
        }
        return true
    }
}
