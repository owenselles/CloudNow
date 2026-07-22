# Repository Agent Checklist

For every task that changes repository content, complete this checklist before reporting the task as finished:

1. Read the pinned SwiftFormat and SwiftLint versions from the `README.md` **Linting** section. The README is the source of truth; do not assume previously installed versions are current.
2. Verify the executables match those exact versions.
3. Run the non-mutating checks from the repository root:

   ```bash
   swiftformat --lint --config .swiftformat CloudNow
   swiftlint --strict --config .swiftlint.yml CloudNow
   ```

4. Do not mark the task complete until both checks pass. If a local executable has the wrong version, use the pinned CI/pre-commit tool environment instead of running the mismatched executable.
5. Report both check results in the final response.

## Performance-Sensitive Runtime Paths

Treat the following callbacks as protected hot paths. They run for every video frame, audio
render quantum, or input sample, so a small per-call cost can become visible latency, frame
loss, audio underruns, or sustained memory growth:

- `GFNVideoDecoderH265.decode` and its VideoToolbox output handler.
- `WebRTCFrameRenderer.renderFrame`, `admit`, and the renderer drain methods.
- `I420FrameConverter.convert` and its plane-copy helpers.
- The `AVAudioSourceNode` and `AVAudioSinkNode` callbacks in `GFNAudioDevice`.
- `InputSender` sampling/encoding and `GFNStreamController.sendData`.

Agents must apply a higher evidence and review bar when changing these paths:

1. Read the nearby hot-path comments and preserve their queueing, ownership, and allocation
   invariants. Explain in the commit message why the structure is necessary.
2. Do not add unbounded `Task` or `DispatchQueue.async` production, MainActor hops, blocking
   waits, per-callback logging/string serialization, generic bridge round-trips, or full-frame
   allocations without device measurements that justify the cost.
3. Keep video admission latest-frame-wins and *before* dispatch. At most one pending prepared
   frame and one drain operation may be retained by application code; queued closures must not
   capture a frame or pixel buffer.
4. Keep the imported `RTCVideoDecoderCallback` stored and invoked as its concrete block type.
   A generic synchronization round-trip previously accumulated reabstraction thunks and caused
   repeatable stack-overflow crashes during sustained decoding.
5. Keep audio render callbacks allocation-free, lock-free, log-free, and independent of actor
   scheduling. Allocate scratch storage and capture delegate blocks when building the graph.
6. Keep replaceable input snapshots bounded and coalesced on the existing serial queue. Never
   turn temporary WebRTC backpressure into an unbounded application retry queue.
7. For behavioral changes, stress a high-motion 4K60 scene on Apple TV and inspect real FPS,
   renderer pending depth, dropped/superseded frames, memory high-water, and device crash logs.
   A successful compile alone is not enough evidence for a hot-path rewrite.
