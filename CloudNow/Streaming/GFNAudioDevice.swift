import AVFAudio
import Foundation
import LiveKitWebRTC
import os.log

private let audioDeviceLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "AudioDevice")

/// Owns a preallocated Int16 conversion buffer; deallocates when the capturing
/// render closure (and thus the audio node) is released.
private final class ScratchBuffer {
    let pointer: UnsafeMutablePointer<Int16>

    init(capacity: Int) {
        pointer = .allocate(capacity: capacity)
    }

    deinit {
        pointer.deallocate()
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
final class GFNAudioDevice: NSObject {
    static let shared = GFNAudioDevice()

    /// Output channels the next stream wants (2 or 6), set from the negotiated offer before
    /// playout initializes. The effective count is capped by the active route's capability.
    var requestedOutputChannels = 2

    private var delegate: LKRTCAudioDeviceDelegate?
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var sinkNode: AVAudioSinkNode?
    private var playoutFormat: AVAudioFormat?
    private var captureFormat: AVAudioFormat?
    private var playoutInitializedFlag = false
    private var recordingInitializedFlag = false
    private var playingFlag = false
    private var recordingFlag = false
    private var routeChangeObserver: NSObjectProtocol?

    // MARK: Playout graph

    private func buildPlayoutGraph(on engine: AVAudioEngine, delegate: LKRTCAudioDeviceDelegate) -> Bool {
        let session = AVAudioSession.sharedInstance()
        let wanted = max(2, requestedOutputChannels)
        let routeMax = max(1, session.maximumOutputNumberOfChannels)
        do {
            try session.setPreferredOutputNumberOfChannels(min(wanted, routeMax))
            try session.setPreferredIOBufferDuration(0.01)
        } catch {
            audioDeviceLog.error("preferred output configuration failed: \(error, privacy: .public)")
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
        let hwFormat = engine.inputNode.inputFormat(forBus: 0)
        let channels = min(2, max(1, Int(hwFormat.channelCount)))
        guard hwFormat.sampleRate > 0 else {
            audioDeviceLog.info("capture unavailable: zero-rate input format")
            return false
        }

        let maxFrames = 4096
        let scratchBox = ScratchBuffer(capacity: maxFrames * channels)
        let scratch = scratchBox.pointer
        let deliver = delegate.deliverRecordedData
        let sink = AVAudioSinkNode { [scratchBox] timestamp, frameCount, inputData -> OSStatus in
            _ = scratchBox // owns the scratch allocation for the node's lifetime
            let frames = min(Int(frameCount), maxFrames)
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData)
            )
            // Float32 (interleaved or deinterleaved) → interleaved Int16
            if buffers.count == 1, let data = buffers[0].mData {
                let floats = data.assumingMemoryBound(to: Float.self)
                for i in 0 ..< frames * channels {
                    scratch[i] = Int16(max(-1, min(1, floats[i])) * 32767)
                }
            } else {
                for (channel, buffer) in buffers.enumerated() where channel < channels {
                    guard let data = buffer.mData else { continue }
                    let floats = data.assumingMemoryBound(to: Float.self)
                    for frame in 0 ..< frames {
                        scratch[frame * channels + channel] = Int16(max(-1, min(1, floats[frame])) * 32767)
                    }
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
            return deliver(&flags, timestamp, 1, UInt32(frames), &outList, nil, nil)
        }

        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: hwFormat)
        sinkNode = sink
        captureFormat = hwFormat
        audioDeviceLog.info("capture: \(channels)ch @\(Int(hwFormat.sampleRate))Hz")
        return true
    }

    // MARK: Engine lifecycle

    private func activeEngine() -> AVAudioEngine {
        if let engine { return engine }
        let engine = AVAudioEngine()
        self.engine = engine
        return engine
    }

    private func tearDownEngine() {
        engine?.stop()
        if let engine {
            if let sourceNode { engine.detach(sourceNode) }
            if let sinkNode { engine.detach(sinkNode) }
        }
        sourceNode = nil
        sinkNode = nil
        engine = nil
        playoutFormat = nil
        captureFormat = nil
    }

    private func startEngineIfNeeded() -> Bool {
        guard let engine else { return false }
        guard !engine.isRunning else { return true }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            audioDeviceLog.error("engine start failed: \(error, privacy: .public)")
            return false
        }
        return true
    }

    /// Route changes (e.g. HDMI re-plug, receiver power) can alter the granted channel count
    /// and latency. Rebuild the graph and let the native ADM re-read our parameters.
    private func handleRouteChange() {
        guard let delegate else { return }
        delegate.dispatchAsync { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            let wasPlaying = playingFlag
            let wasRecording = recordingFlag
            tearDownEngine()
            let engine = activeEngine()
            if playoutInitializedFlag, !buildPlayoutGraph(on: engine, delegate: delegate) {
                audioDeviceLog.error("playout rebuild after route change failed")
            }
            if recordingInitializedFlag, !buildCaptureGraph(on: engine, delegate: delegate) {
                recordingInitializedFlag = false
                recordingFlag = false
            }
            if wasPlaying || wasRecording {
                _ = startEngineIfNeeded()
            }
            delegate.notifyAudioOutputParametersChange()
            if wasRecording { delegate.notifyAudioInputParametersChange() }
        }
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
        self.delegate = delegate
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleRouteChange()
        }
        return true
    }

    func terminateDevice() -> Bool {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
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
        if let sourceNode, let engine {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        guard buildPlayoutGraph(on: activeEngine(), delegate: delegate) else { return false }
        playoutInitializedFlag = true
        return true
    }

    var isPlaying: Bool {
        playingFlag
    }

    func startPlayout() -> Bool {
        guard startEngineIfNeeded() else { return false }
        playingFlag = true
        return true
    }

    func stopPlayout() -> Bool {
        playingFlag = false
        if !recordingFlag { engine?.stop() }
        return true
    }

    var isRecordingInitialized: Bool {
        recordingInitializedFlag
    }

    func initializeRecording() -> Bool {
        guard let delegate else { return false }
        if let sinkNode, let engine {
            engine.detach(sinkNode)
            self.sinkNode = nil
        }
        guard buildCaptureGraph(on: activeEngine(), delegate: delegate) else { return false }
        recordingInitializedFlag = true
        return true
    }

    var isRecording: Bool {
        recordingFlag
    }

    func startRecording() -> Bool {
        guard startEngineIfNeeded() else { return false }
        recordingFlag = true
        return true
    }

    func stopRecording() -> Bool {
        recordingFlag = false
        if !playingFlag { engine?.stop() }
        return true
    }
}
