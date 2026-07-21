// NOTE: Requires WebRTC SPM package (https://github.com/livekit/webrtc-xcframework)

import AVFoundation
@preconcurrency import CoreVideo
@preconcurrency import LiveKitWebRTC
import os
import UIKit

private nonisolated let videoLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "Video")

// MARK: - VideoSurfaceView

/// Full-screen video renderer.
/// Uses AVSampleBufferDisplayLayer as the backing layer (reliable on tvOS).
/// LKRTCMTLVideoView (MTKView wrapper) does not render on tvOS — bypassed entirely.
///
/// Also acts as first responder for hardware keyboard input and pointer (mouse)
/// input, forwarding events to `inputHandler` as GFN protocol packets.
final class VideoSurfaceView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    private let pipelineDiagnostics = VideoPipelineDiagnostics()
    private lazy var renderer = WebRTCFrameRenderer(diagnostics: pipelineDiagnostics)
    private var currentTrack: LKRTCVideoTrack?
    private var notificationTokens: [NSObjectProtocol] = []
    private var activeRemoteTouch: UITouch?
    private var lastRemoteTouchLocation: CGPoint?
    private var remoteSelectMouseDown = false

    private static let remoteTouchSensitivity: CGFloat = 1.0

    /// Set by GFNStreamController once the input data channel handshake completes.
    weak var inputHandler: InputEventHandler?

    /// Called when the user presses the Menu button on the Siri Remote.
    /// GFNStreamController sets this to toggle the overlay rather than letting
    /// the press bubble up to the system (which opens the Apple TV control center).
    var menuPressHandler: (() -> Void)?

    var onDecodedVideoFormatChanged: (@Sendable (DecodedVideoFormat) -> Void)? {
        didSet {
            let handler = onDecodedVideoFormatChanged
            renderer.onDecodedVideoFormatChanged = { format in
                handler?(format)
            }
        }
    }

    /// When true, an extended gamepad owns input. UIKit presses from the controller
    /// (e.g. Options mapping to .playPause) are suppressed to avoid double-firing the overlay.
    var gamepadModeActive = false {
        didSet {
            if gamepadModeActive {
                cancelRemoteMouseTracking()
            }
        }
    }

    /// Tracks whether the pause overlay is currently visible. Used to decide whether a
    /// .menu press should close the overlay or be silently consumed.
    var overlayVisible: Bool = false {
        didSet {
            if overlayVisible {
                cancelRemoteMouseTracking()
            }
        }
    }

    var videoTrack: LKRTCVideoTrack? {
        didSet {
            guard oldValue !== videoTrack else { return }
            let hadTrack = currentTrack != nil
            currentTrack?.remove(renderer)
            if hadTrack {
                renderer.reset(preservingDisplayedImage: videoTrack != nil)
            }
            currentTrack = videoTrack
            if let track = videoTrack {
                track.add(renderer)
                videoLog.info("[VideoSurfaceView] Track attached")
            }
        }
    }

    func captureDiagnostics(_ completion: @escaping @Sendable (VideoPipelineSnapshot) -> Void) {
        renderer.capturePerformanceMetrics { [pipelineDiagnostics] in
            completion(pipelineDiagnostics.snapshot())
        }
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        pipelineDiagnostics.setEnabled(enabled)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.controlTimebase = nil

        let sampleBufferRenderer = displayLayer.sampleBufferRenderer
        renderer.sampleBufferRenderer = sampleBufferRenderer
        notificationTokens = [
            NotificationCenter.default.addObserver(
                forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
                object: sampleBufferRenderer,
                queue: nil
            ) { [weak renderer] _ in
                renderer?.recoverAfterFailure()
            },
            NotificationCenter.default.addObserver(
                forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
                object: sampleBufferRenderer,
                queue: nil
            ) { [weak renderer] _ in
                renderer?.recoverIfRequired()
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak renderer] _ in
                renderer?.recoverIfRequired()
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: nil
            ) { [weak renderer] _ in
                renderer?.releaseUnusedBuffers()
            },
        ]
    }

    isolated deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    /// Become first responder as soon as the view enters a window so hardware
    /// keyboard events are directed here rather than the focus engine.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
        }
    }

    // MARK: - First Responder / Keyboard

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if press.type == .menu {
                // Always consume .menu — never let it bubble to the system as a back/dismiss
                // gesture. Use it as the universal overlay toggle so the user can both open
                // and close the diagnostics overlay from Siri Remote or a controller.
                menuPressHandler?()
                handled = true
            } else if press.type == .playPause {
                // Play/Pause also toggles the overlay so Siri Remote users always have a
                // direct way to open diagnostics, even when a controller is connected.
                menuPressHandler?()
                handled = true
            } else if press.type == .select, remoteMouseInputEnabled {
                inputHandler?.sendMouseButton(down: true, button: 1)
                remoteSelectMouseDown = true
                handled = true
            } else if let key = press.key {
                inputHandler?.sendKeyEvent(
                    down: true,
                    keyCode: key.keyCode,
                    modifiers: key.modifierFlags
                )
                handled = true
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if press.type == .select, remoteSelectMouseDown {
                inputHandler?.sendMouseButton(down: false, button: 1)
                remoteSelectMouseDown = false
                handled = true
            } else if let key = press.key {
                inputHandler?.sendKeyEvent(
                    down: false,
                    keyCode: key.keyCode,
                    modifiers: key.modifierFlags
                )
                handled = true
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    // MARK: - Siri Remote Touch Surface

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard remoteMouseInputEnabled,
              activeRemoteTouch == nil,
              let touch = touches.first(where: isRemoteTouch)
        else {
            super.touchesBegan(touches, with: event)
            return
        }

        activeRemoteTouch = touch
        lastRemoteTouchLocation = touch.location(in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard remoteMouseInputEnabled else {
            clearRemoteTouchTracking()
            super.touchesMoved(touches, with: event)
            return
        }
        guard let trackedTouch = activeRemoteTouch,
              touches.contains(where: { $0 === trackedTouch })
        else {
            super.touchesMoved(touches, with: event)
            return
        }

        let location = trackedTouch.location(in: self)
        let previous = lastRemoteTouchLocation ?? trackedTouch.previousLocation(in: self)
        lastRemoteTouchLocation = location
        forwardRemoteTouchDelta(from: previous, to: location)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let trackedTouch = activeRemoteTouch,
              touches.contains(where: { $0 === trackedTouch })
        else {
            super.touchesEnded(touches, with: event)
            return
        }

        activeRemoteTouch = nil
        lastRemoteTouchLocation = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let trackedTouch = activeRemoteTouch,
              touches.contains(where: { $0 === trackedTouch })
        else {
            super.touchesCancelled(touches, with: event)
            return
        }

        activeRemoteTouch = nil
        lastRemoteTouchLocation = nil
    }

    private func isRemoteTouch(_ touch: UITouch) -> Bool {
        switch touch.type {
        case .indirect, .indirectPointer:
            true
        default:
            false
        }
    }

    private func forwardRemoteTouchDelta(from previous: CGPoint, to location: CGPoint) {
        let dx = (location.x - previous.x) * Self.remoteTouchSensitivity
        let dy = (location.y - previous.y) * Self.remoteTouchSensitivity
        let packetDX = Int16(clamping: Int(dx.rounded()))
        let packetDY = Int16(clamping: Int(dy.rounded()))
        guard packetDX != 0 || packetDY != 0 else { return }
        inputHandler?.sendMouseMove(dx: packetDX, dy: packetDY)
    }

    private var remoteMouseInputEnabled: Bool {
        !gamepadModeActive && !overlayVisible
    }

    private func clearRemoteTouchTracking() {
        activeRemoteTouch = nil
        lastRemoteTouchLocation = nil
    }

    private func cancelRemoteMouseTracking() {
        clearRemoteTouchTracking()
        if remoteSelectMouseDown {
            inputHandler?.sendMouseButton(down: false, button: 1)
            remoteSelectMouseDown = false
        }
    }
}

// MARK: - WebRTC Video Renderer

private nonisolated enum VideoPresentationMode: String {
    case paced
    case immediate

    static var configured: VideoPresentationMode {
        let value = ProcessInfo.processInfo.environment["CLOUDNOW_VIDEO_PRESENTATION_MODE"]?
            .lowercased()
        return value == paced.rawValue ? .paced : .immediate
    }
}

private nonisolated struct VideoPresentationTimeline {
    private static let nominalFrameDurationNanoseconds: Int64 = 16_666_667
    private static let lateRebaseThreshold = CMTime(value: 40_000_000, timescale: 1_000_000_000)
    private static let futureRebaseThreshold = CMTime(value: 100_000_000, timescale: 1_000_000_000)

    private var anchorSourceNanoseconds: Int64?
    private var anchorHostTime = CMTime.invalid
    private var lastSourceNanoseconds: Int64?
    private var lastRawRTPTimestamp: UInt32?
    private var unwrappedRTPTicks: Int64 = 0

    mutating func presentationTime(
        frameTimestampNanoseconds: Int64,
        rtpTimestamp: Int32,
        hostTime: CMTime
    ) -> CMTime {
        var sourceNanoseconds = sourceTimestampNanoseconds(
            frameTimestampNanoseconds: frameTimestampNanoseconds,
            rtpTimestamp: rtpTimestamp
        )
        if let lastSourceNanoseconds, sourceNanoseconds <= lastSourceNanoseconds {
            sourceNanoseconds = lastSourceNanoseconds + Self.nominalFrameDurationNanoseconds
        }
        lastSourceNanoseconds = sourceNanoseconds

        guard let anchorSourceNanoseconds else {
            rebase(sourceNanoseconds: sourceNanoseconds, hostTime: hostTime)
            return hostTime
        }

        let sourceDelta = CMTime(
            value: sourceNanoseconds - anchorSourceNanoseconds,
            timescale: 1_000_000_000
        )
        let desiredTime = CMTimeAdd(anchorHostTime, sourceDelta)
        let earliestUsefulTime = CMTimeSubtract(hostTime, Self.lateRebaseThreshold)
        let latestUsefulTime = CMTimeAdd(hostTime, Self.futureRebaseThreshold)
        guard CMTimeCompare(desiredTime, earliestUsefulTime) >= 0,
              CMTimeCompare(desiredTime, latestUsefulTime) <= 0
        else {
            rebase(sourceNanoseconds: sourceNanoseconds, hostTime: hostTime)
            return hostTime
        }
        return desiredTime
    }

    mutating func reset() {
        self = Self()
    }

    private mutating func sourceTimestampNanoseconds(
        frameTimestampNanoseconds: Int64,
        rtpTimestamp: Int32
    ) -> Int64 {
        if frameTimestampNanoseconds > 0 {
            return frameTimestampNanoseconds
        }

        let rawTimestamp = UInt32(bitPattern: rtpTimestamp)
        if let lastRawRTPTimestamp {
            unwrappedRTPTicks += Int64(Int32(bitPattern: rawTimestamp &- lastRawRTPTimestamp))
        } else {
            unwrappedRTPTicks = Int64(rawTimestamp)
        }
        lastRawRTPTimestamp = rawTimestamp
        return unwrappedRTPTicks * 1_000_000_000 / 90000
    }

    private mutating func rebase(sourceNanoseconds: Int64, hostTime: CMTime) {
        anchorSourceNanoseconds = sourceNanoseconds
        anchorHostTime = hostTime
    }
}

/// Implements LKRTCVideoRenderer to receive decoded WebRTC frames and feed them
/// to the display layer's background-safe AVSampleBufferVideoRenderer.
private final nonisolated class WebRTCFrameRenderer: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private struct FlushRequest {
        let generation: UInt64
        let removeDisplayedImage: Bool
    }

    private struct State {
        var formatDescription: CMVideoFormatDescription?
        var formatSignature: VideoFormatSignature?
        var decodedFormatSignature: VideoFormatSignature?
        var isFlushing = false
        var generation: UInt64 = 0
        var metricsRequestInFlight = false
        var presentationTimeline = VideoPresentationTimeline()
    }

    private final nonisolated class PreparedFrame: @unchecked Sendable {
        let sampleBuffer: CMSampleBuffer
        let generation: UInt64
        let trace: VideoFrameTrace?

        init(sampleBuffer: CMSampleBuffer, generation: UInt64, trace: VideoFrameTrace?) {
            self.sampleBuffer = sampleBuffer
            self.generation = generation
            self.trace = trace
        }
    }

    private struct AdmissionState {
        var pendingFrame: PreparedFrame?
        var drainScheduled = false
    }

    /// AVSampleBufferVideoRenderer documents background-safe enqueueing. This box carries the
    /// fixed renderer identity onto its dedicated serial queue without weakening AVFoundation's
    /// concurrency checking for the rest of the file.
    private final nonisolated class SampleBufferRendererBox: @unchecked Sendable {
        let renderer: AVSampleBufferVideoRenderer

        init(_ renderer: AVSampleBufferVideoRenderer) {
            self.renderer = renderer
        }
    }

    var sampleBufferRenderer: AVSampleBufferVideoRenderer? {
        didSet {
            oldValue?.stopRequestingMediaData()
            sampleBufferRendererBox = nil
            guard let sampleBufferRenderer else { return }
            sampleBufferRendererBox = SampleBufferRendererBox(sampleBufferRenderer)
        }
    }

    var onDecodedVideoFormatChanged: (@Sendable (DecodedVideoFormat) -> Void)?
    private let diagnostics: VideoPipelineDiagnostics
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let admissionState = OSAllocatedUnfairLock(initialState: AdmissionState())
    private let i420Converter = I420FrameConverter()
    private let presentationMode = VideoPresentationMode.configured
    private let enqueueQueue = DispatchQueue(
        label: "com.cloudnow.video.enqueue",
        qos: .userInteractive
    )
    private var sampleBufferRendererBox: SampleBufferRendererBox?
    private var isRequestingMediaData = false

    init(diagnostics: VideoPipelineDiagnostics) {
        self.diagnostics = diagnostics
        diagnostics.updatePresentationMode(presentationMode.rawValue)
    }

    deinit {
        sampleBufferRenderer?.stopRequestingMediaData()
    }

    func setSize(_: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame, let rendererBox = sampleBufferRendererBox else { return }
        let sampleBufferRenderer = rendererBox.renderer
        let trace = diagnostics.beginFrame()

        if sampleBufferRenderer.status == .failed || sampleBufferRenderer.requiresFlushToResumeDecoding {
            recoverAfterFailure()
            diagnostics.recordDrop(trace)
            return
        }
        guard let renderGeneration = state.withLock({ state -> UInt64? in
            guard !state.isFlushing else { return nil }
            return state.generation
        }) else {
            diagnostics.recordDrop(trace)
            return
        }

        // Hardware-decoded H.264/H.265/AV1 frames arrive as CVPixelBuffer (NV12/420v).
        // H.265/HDR/AV1 can fall back to software decoding (LKRTCI420Buffer) on some
        // hardware — convert to a planar CVPixelBuffer so the display layer can render it.
        let cvBuf: CVPixelBuffer
        let decoderPath: VideoDecoderPath
        if let hwBuf = frame.buffer as? LKRTCCVPixelBuffer {
            cvBuf = hwBuf.pixelBuffer
            decoderPath = .hardware
        } else if let i420 = frame.buffer as? LKRTCI420Buffer {
            let conversionStart = diagnostics.beginConversion(trace)
            guard let converted = i420Converter.convert(i420) else {
                diagnostics.cancelConversion(trace)
                diagnostics.recordDrop(trace)
                return
            }
            diagnostics.endConversion(trace, startedAt: conversionStart)
            cvBuf = converted
            decoderPath = .softwareI420
        } else {
            videoLog.warning("[WebRTCFrameRenderer] Unhandled frame type: \(String(describing: type(of: frame.buffer)), privacy: .public)")
            diagnostics.recordDrop(trace)
            return
        }

        let decodedFormat = DecodedVideoFormatInspector.inspect(pixelBuffer: cvBuf, decoderPath: decoderPath)
        let decodedSignature = DecodedVideoFormatInspector.signature(for: decodedFormat)
        let shouldPublishFormat = state.withLock { state -> Bool in
            guard state.decodedFormatSignature != decodedSignature else { return false }
            state.decodedFormatSignature = decodedSignature
            return true
        }
        if shouldPublishFormat {
            diagnostics.updateDecodedVideoFormat(decodedFormat)
            onDecodedVideoFormatChanged?(decodedFormat)
        }

        let sampleCreationStart = diagnostics.beginSampleCreation(trace)
        guard let formatDescription = formatDescription(for: cvBuf, signature: decodedSignature) else {
            diagnostics.endSampleCreation(trace, startedAt: sampleCreationStart)
            diagnostics.recordDrop(trace)
            return
        }

        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        guard let presentationTime = state.withLock({ state -> CMTime? in
            guard !state.isFlushing, state.generation == renderGeneration else { return nil }
            switch presentationMode {
            case .paced:
                return state.presentationTimeline.presentationTime(
                    frameTimestampNanoseconds: frame.timeStampNs,
                    rtpTimestamp: frame.timeStamp,
                    hostTime: hostTime
                )
            case .immediate:
                return .zero
            }
        }) else {
            diagnostics.endSampleCreation(trace, startedAt: sampleCreationStart)
            diagnostics.recordDrop(trace)
            return
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: nil,
            imageBuffer: cvBuf,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else {
            diagnostics.endSampleCreation(trace, startedAt: sampleCreationStart)
            diagnostics.recordDrop(trace)
            return
        }
        if presentationMode == .immediate {
            markForImmediatePresentation(sampleBuffer)
        }
        diagnostics.endSampleCreation(trace, startedAt: sampleCreationStart)
        let preparedFrame = PreparedFrame(
            sampleBuffer: sampleBuffer,
            generation: renderGeneration,
            trace: trace
        )
        admit(preparedFrame, with: rendererBox)
    }

    func reset(preservingDisplayedImage: Bool) {
        i420Converter.flushExcessBuffers()
        flush(preservingDisplayedImage: preservingDisplayedImage, recordFailure: false)
    }

    func releaseUnusedBuffers() {
        i420Converter.flushExcessBuffers()
    }

    func recoverAfterFailure() {
        flush(preservingDisplayedImage: true, recordFailure: true)
    }

    func recoverIfRequired() {
        guard let sampleBufferRenderer,
              sampleBufferRenderer.status == .failed || sampleBufferRenderer.requiresFlushToResumeDecoding
        else {
            return
        }
        recoverAfterFailure()
    }

    func capturePerformanceMetrics(completion: @escaping @Sendable () -> Void) {
        guard let sampleBufferRenderer else {
            completion()
            return
        }
        let shouldRequest = state.withLock { state -> Bool in
            guard !state.metricsRequestInFlight else { return false }
            state.metricsRequestInFlight = true
            return true
        }
        guard shouldRequest else {
            completion()
            return
        }
        sampleBufferRenderer.loadVideoPerformanceMetrics { [weak self, weak diagnostics] metrics in
            if let metrics {
                diagnostics?.updateAVMetrics(
                    totalFrames: metrics.totalNumberOfFrames,
                    droppedFrames: metrics.numberOfDroppedFrames,
                    corruptedFrames: metrics.numberOfCorruptedFrames,
                    optimizedFrames: metrics.numberOfFramesDisplayedUsingOptimizedCompositing,
                    accumulatedFrameDelaySeconds: metrics.totalAccumulatedFrameDelay
                )
            }
            self?.state.withLock { $0.metricsRequestInFlight = false }
            completion()
        }
    }

    private func flush(preservingDisplayedImage: Bool, recordFailure: Bool) {
        guard sampleBufferRenderer != nil else { return }
        let (didBeginFlush, requestToRun) = state.withLock { state -> (Bool, FlushRequest?) in
            guard !state.isFlushing else { return (false, nil) }
            state.isFlushing = true
            state.generation &+= 1
            state.formatDescription = nil
            state.formatSignature = nil
            state.decodedFormatSignature = nil
            state.presentationTimeline.reset()
            let request = FlushRequest(
                generation: state.generation,
                removeDisplayedImage: !preservingDisplayedImage
            )
            return (true, request)
        }
        guard didBeginFlush else { return }

        if recordFailure {
            diagnostics.recordRendererFailure()
        }
        guard let requestToRun else { return }
        enqueueQueue.async { [weak self] in
            self?.discardPendingFrame()
            self?.performFlush(requestToRun)
        }
    }

    private func admit(
        _ frame: PreparedFrame,
        with rendererBox: SampleBufferRendererBox
    ) {
        let (supersededFrame, shouldScheduleDrain) = admissionState.withLock { state in
            let supersededFrame = state.pendingFrame
            state.pendingFrame = frame
            guard !state.drainScheduled else {
                return (supersededFrame, false)
            }
            state.drainScheduled = true
            return (supersededFrame, true)
        }

        if let supersededFrame {
            diagnostics.recordSupersededFrame(supersededFrame.trace)
        }
        diagnostics.updatePendingFrames(1)

        guard shouldScheduleDrain else { return }
        enqueueQueue.async { [weak self, rendererBox] in
            self?.drainLatestFrame(with: rendererBox)
        }
    }

    private func startRequestingMediaData(with rendererBox: SampleBufferRendererBox) {
        guard !isRequestingMediaData else { return }
        isRequestingMediaData = true
        rendererBox.renderer.requestMediaDataWhenReady(on: enqueueQueue) { [weak self, weak rendererBox] in
            guard let self, let rendererBox else { return }
            drainLatestFrame(with: rendererBox)
        }
    }

    private func drainLatestFrame(with rendererBox: SampleBufferRendererBox) {
        let sampleBufferRenderer = rendererBox.renderer
        guard sampleBufferRenderer.isReadyForMoreMediaData else {
            diagnostics.recordBackpressure()
            startRequestingMediaData(with: rendererBox)
            return
        }

        let pendingFrame = admissionState.withLock { state -> PreparedFrame? in
            let pendingFrame = state.pendingFrame
            state.pendingFrame = nil
            return pendingFrame
        }
        guard let pendingFrame else {
            finishDrainCycle(with: rendererBox)
            return
        }

        diagnostics.updatePendingFrames(0)
        enqueueIfCurrent(pendingFrame, with: sampleBufferRenderer)
        finishDrainCycle(with: rendererBox)
    }

    private func finishDrainCycle(with rendererBox: SampleBufferRendererBox) {
        let hasPendingFrame = admissionState.withLock { state in
            guard state.pendingFrame == nil else { return true }
            state.drainScheduled = false
            return false
        }
        guard hasPendingFrame else {
            stopRequestingMediaData(with: rendererBox)
            return
        }

        if isRequestingMediaData {
            return
        }
        if rendererBox.renderer.isReadyForMoreMediaData {
            enqueueQueue.async { [weak self, rendererBox] in
                self?.drainLatestFrame(with: rendererBox)
            }
        } else {
            diagnostics.recordBackpressure()
            startRequestingMediaData(with: rendererBox)
        }
    }

    private func stopRequestingMediaData(with rendererBox: SampleBufferRendererBox) {
        guard isRequestingMediaData else { return }
        rendererBox.renderer.stopRequestingMediaData()
        isRequestingMediaData = false
    }

    private func enqueueIfCurrent(
        _ frame: PreparedFrame,
        with sampleBufferRenderer: AVSampleBufferVideoRenderer
    ) {
        let isCurrent = state.withLock {
            !$0.isFlushing && $0.generation == frame.generation
        }
        guard isCurrent else {
            diagnostics.recordDrop(frame.trace)
            return
        }
        sampleBufferRenderer.enqueue(frame.sampleBuffer)
        diagnostics.recordEnqueue(frame.trace)
    }

    private func discardPendingFrame() {
        if isRequestingMediaData {
            sampleBufferRenderer?.stopRequestingMediaData()
            isRequestingMediaData = false
        }
        let pendingFrame = admissionState.withLock { state -> PreparedFrame? in
            let pendingFrame = state.pendingFrame
            state.pendingFrame = nil
            state.drainScheduled = false
            return pendingFrame
        }
        diagnostics.updatePendingFrames(0)
        guard let pendingFrame else { return }
        diagnostics.recordDrop(pendingFrame.trace)
    }

    private func performFlush(_ request: FlushRequest) {
        guard let sampleBufferRenderer else {
            state.withLock { state in
                if state.generation == request.generation {
                    state.isFlushing = false
                }
            }
            return
        }
        sampleBufferRenderer.flush(removingDisplayedImage: request.removeDisplayedImage) { [weak self] in
            self?.state.withLock { state in
                if state.generation == request.generation {
                    state.isFlushing = false
                }
            }
            self?.diagnostics.recordRendererFlush()
        }
    }

    private func formatDescription(
        for pixelBuffer: CVPixelBuffer,
        signature: VideoFormatSignature
    ) -> CMVideoFormatDescription? {
        let (generation, cached) = state.withLock {
            ($0.generation, $0.formatSignature == signature ? $0.formatDescription : nil)
        }
        if let cached,
           CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: pixelBuffer)
        {
            return cached
        }

        var created: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &created
        )
        guard status == noErr, let created else { return nil }
        return state.withLock { state in
            guard state.generation == generation, !state.isFlushing else { return nil }
            state.formatDescription = created
            state.formatSignature = signature
            return created
        }
    }

    private func markForImmediatePresentation(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 else { return }

        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

// MARK: - Streaming View Controller

import GameController

/// GCEventViewController subclass whose view IS the VideoSurfaceView.
/// controllerUserInteractionEnabled is toggled dynamically: false during streaming
/// (prevents O/Circle → system back) and true when the pause overlay is open
/// (allows D-pad to navigate SwiftUI overlay buttons via the focus engine).
final class StreamingViewController: GCEventViewController {
    let videoSurface = VideoSurfaceView()

    override func loadView() {
        controllerUserInteractionEnabled = false
        view = videoSurface
    }
}

// MARK: - SwiftUI Wrapper

import SwiftUI

struct VideoSurfaceViewRepresentable: UIViewControllerRepresentable {
    let streamController: GFNStreamController
    var showOverlay: Bool = false

    func makeUIViewController(context _: Context) -> StreamingViewController {
        let vc = StreamingViewController()
        Task { @MainActor in
            streamController.bindVideoView(vc.videoSurface)
        }
        return vc
    }

    func updateUIViewController(_ vc: StreamingViewController, context _: Context) {
        vc.videoSurface.videoTrack = streamController.videoTrack
        // Route controller input to the GameController layer during gameplay so the
        // overlay trigger button can be sampled. Switch to the responder chain only
        // while the overlay is visible so SwiftUI focus navigation works there.
        vc.controllerUserInteractionEnabled = showOverlay
        vc.videoSurface.overlayVisible = showOverlay
    }
}
