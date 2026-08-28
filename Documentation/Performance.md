# Performance

This guide records the performance work tracked by [issue 66](https://github.com/owenselles/CloudNow/issues/66), the limits that protect the app from unbounded work, and the checks required when changing a performance-sensitive path.

The architecture-level rules remain in [Architecture.md](Architecture.md#performance-invariants). Provider behavior remains in [GeForceNOW.md](GeForceNOW.md) and [XboxCloudGaming.md](XboxCloudGaming.md). This guide is the consolidated issue 66 implementation map and index of current performance limits. When a limit changes, update this guide and the owning provider guide together.

## Current status

The `14/18 (78%)` table in issue 66 is a historical baseline recorded after PR 104. It was intentionally retained when the issue title changed to "Baseline reference".

Current code contains implementations for all 18 checklist areas. This does not mean that every runtime target has been proven. Physical-device profiling, Instruments validation, and several long-running acceptance checks are still open.

Use these terms consistently:

- **Implementation complete** means the intended ownership, bounds, cancellation, caching, or rendering behavior exists in source and is covered by deterministic tests where practical.
- **Acceptance complete** means the relevant behavior has also been measured on representative hardware with retained evidence.

Do not turn historical package sizes, test counts, or one-device observations into current guarantees. Re-measure them on the same device, operating system, build configuration, account, provider state, and network conditions before making a comparison.

## Non-regression rules

Performance changes must preserve correctness and provider isolation. Faster behavior is not an improvement if it publishes stale work, leaks state between accounts, or weakens teardown.

- Keep queues, caches, histories, retries, candidate sets, and concurrent work explicitly bounded.
- Move persistence, decoding, image processing, and large catalog derivations away from the main actor.
- Bind asynchronous results to the generation, account, locale, virtual PC, session, or request that created them.
- Cancel superseded work and prevent stale work from publishing after a newer request or teardown.
- Coalesce identical in-flight requests instead of starting duplicate work.
- Prefer cache-first presentation followed by a guarded refresh when stale data remains safe to display.
- Keep high-frequency state local to the smallest view or component that needs it.
- Treat diagnostics as optional work. Disabled diagnostics must not retain unbounded data or perform avoidable per-frame processing.
- Preserve provider-specific cache scopes and lifecycle rules.
- Measure before and after on comparable inputs. Record the raw result and the exact setup.

## Implemented work

### 1. Release packaging

App Store media is excluded from normal app builds and release archives. Release validation must confirm that screenshots and other submission-only assets are not copied into the product bundle.

Relevant configuration is in `CloudNow.xcodeproj`, with the release check described in [ReleaseValidation.md](ReleaseValidation.md).

### 2. Stream ownership and teardown

Stream controller callbacks do not create a permanent ownership cycle. Session teardown stops provider work, releases delegates and callbacks, and prevents late results from reviving a finished session.

`CloudNow/Session/SessionAttemptState.swift` and `CloudNow/Session/SessionOrchestrator.swift` implement generation-bound, single-flight session attempts. Superseded attempts are cancelled, stale sessions are stopped, and reconnect attempts are bounded.

### 3. Catalog cache and stale-while-refresh loading

Catalog and library state can be restored from file-backed persistence so the first useful screen does not always wait for the network. A refresh then updates the cache and visible state if it still belongs to the active generation.

`CloudNow/UI/GamesViewModel.swift` owns cache-first presentation, guarded refreshes, and loading phases. `CloudNow/PersistenceStore.swift` isolates persistence work from UI ownership.

Cache keys must continue to include every value that changes the result, including provider, account, locale, and virtual PC where applicable.

### 4. Launch networking and request coalescing

Independent startup requests run concurrently. Catalog, library, session, subscription, and routing data are not serialized when no dependency requires it.

Virtual PC discovery is shared across consumers through coalesced work. GeForce NOW catalog browsing requests 500-item pages and retains the 200-item compatibility fallback.

Do not restore fixed serial request chains or duplicate virtual PC lookups during startup.

### 5. Latest-frame rendering

`CloudNow/Video/VideoSurfaceView.swift` uses a capacity-one latest-frame mailbox. When rendering falls behind, a newer frame replaces the pending frame instead of allowing an unbounded backlog to grow.

Generation checks prevent frames from an old stream or surface from publishing after replacement or teardown.

### 6. Per-frame color work

The renderer caches color-related inspection that does not need to be repeated for every frame. Format or parameter changes invalidate the cached decision.

Any new per-frame work must be justified with a profile. Values derived from stable stream metadata should be cached at the narrowest correct scope.

### 7. H.265 data movement

`CloudNow/Streaming/GFNVideoDecoderH265.swift` parses H.265 NAL ranges without first copying every unit into separate buffers. It then performs one deliberate AVCC assembly copy for Core Media.

Describe this as zero-copy parsing or a lower-copy decode path. The complete H.265 path is not zero-copy.

### 8. Haptics and high-frequency logging

Haptic delivery is isolated from rendering and input handling so device feedback does not block those paths. High-frequency rumble output is not written to general logs.

New diagnostics in input, haptic, audio, or video loops must be gated and bounded.

### 9. Input latency history

The in-memory input latency history is capped at 4,096 samples and is retained only for the diagnostics and heads-up display paths that consume it.

`CloudNow/Streaming/BoundedSampleHistory.swift` provides the reusable bounded-history behavior. Do not replace it with an ever-growing sample array.

### 10. Catalog derivations and loading phases

Repeated GeForce NOW catalog groupings, filters, and lookups are cached by `GamesViewModel`. Store presentation uses lazy rows and paged loading rather than eagerly creating every visible hierarchy.

Store reveals items in pages of 96, prefetches the next 24 artwork URLs, and limits box-art prefetch to 6 concurrent requests.

### 11. Incremental metadata enrichment

Library metadata enrichment reuses fresh locale and virtual-PC-scoped results. Missing records use short-lived tombstones so an absent result does not trigger an immediate request loop. A failed refresh may continue using a bounded stale value.

Current metadata limits are:

| Limit | Value |
| --- | ---: |
| Fresh successful entry | 24 hours |
| Missing-record tombstone | 1 hour |
| Maximum stale fallback | 30 days |
| Entries retained per locale and virtual PC scope | 2,000 |
| IDs per enrichment request | 40 |

Generation checks prevent an earlier enrichment response from overwriting newer catalog state.

### 12. Artwork loading and memory bounds

Artwork decoding, downsampling, request coalescing, and cache ownership live in the shared image pipeline. Home and catalog rows request artwork lazily. Superseded prefetch work is cancelled, and lifecycle transitions trim or release retained images.

Current cache and scheduling limits are:

| Resource | Limit |
| --- | ---: |
| Foreground box art | 96 MiB and 96 images |
| Background box art | 32 MiB and 32 images |
| Hero art | 32 MiB and 4 images |
| Active hero requests | 2 |
| Pending hero requests | 2 |
| Active box-art requests | 6 |

These are subsystem budgets, not whole-process memory guarantees.

### 13. Persistence and decoding isolation

Large persistence and decoding operations do not run as synchronous main-actor work. `CloudNow/PersistenceStore.swift` owns serialized file access, while UI state changes return to their appropriate owner after the data is ready.

Keep file I/O and large `Codable` operations outside view update paths.

### 14. Single-flight session startup

Only the current session attempt may publish or retain resources. Retry, dismissal, provider changes, and explicit cancellation invalidate earlier work. Reconnect attempts are capped at 3.

Session tests cover cancellation, replacement, stale completion, and teardown. Physical validation must still check rapid Retry and dismissal against provider request logs.

### 15. SwiftUI invalidation scope

High-frequency clocks and counters are confined to leaf views or non-observable bookkeeping:

- `StreamLoadingProgressView` owns its 100 ms progress clock and skips unchanged progress values.
- `QueueAdPlaybackLifecycle` keeps 250 ms watched-time bookkeeping non-observable and guards visible `isPlaying` updates.
- `CloudSessionExpiryCountdownView` confines its one-second timeline to the countdown text.

The structural remedies are present. SwiftUI Instruments confirmation that only the intended leaf subtrees update remains an open acceptance check.

### 16. Localization loading

Localization lazily materializes the active locale and its English fallback when first needed instead of materializing every bundled table at launch.

Cold-launch and fallback behavior still require comparable physical-device measurement when this path changes.

### 17. Signaling and routing latency

Signaling considers at most 8 candidates, starts at most 3 candidate attempts concurrently, and staggers attempts by 250 ms. Losing attempts are cancelled after a winner is selected. The TCP connection timeout remains 4 seconds.

Zone latency measurement runs at most 6 probes concurrently. Zone mapping, queue retrieval, and other independent routing work may run concurrently when their ownership permits it.

Failure injection and before-and-after p95 measurements remain required for changes to this scheduler.

### 18. Isolation and observation cleanup

Concurrency ownership is explicit across session, catalog, diagnostics, persistence, and provider runtime state. Observable updates are batched or guarded so internal bookkeeping does not cause avoidable UI invalidation.

Warnings must not be silenced by weakening isolation. Resolve ownership, cancellation, and `Sendable` boundaries at the responsible layer.

## Xbox Cloud Gaming additions

The Xbox Cloud Gaming implementation merged after the original issue 66 baseline and was reviewed against the same constraints.

- The provider runtime graph is created lazily, shared where required, and detached during teardown.
- Catalog validation and presentation derivation run away from UI ownership through `XboxCatalogPresentationWorker`.
- Derived presentation snapshots are generation-fenced and cancellable.
- Catalog snapshots retain at most 4,096 validated products.
- Encoded catalog input is rejected above 16 MiB, and the decoded cache uses an 8 MiB estimated-cost ceiling with at most two retained entries.
- Store and catalog presentation reuse the shared paging and artwork bounds instead of creating provider-specific unbounded paths.

See [XboxCloudGaming.md](XboxCloudGaming.md) for provider behavior and lifecycle details.

## Validation

### Automated checks

Run the deterministic repository checks described in [Development.md](Development.md#testing). For the broadest local test pass:

```bash
Scripts/test.sh --full
```

The unit, integration, and UI suites verify behavior such as bounds, coalescing, stale-result rejection, cancellation, and teardown. They do not prove startup time, frame pacing, CPU use, resident memory, or end-to-end latency on physical hardware.

The repository coverage gate protects the capability model and adapter surface. It is not a performance benchmark.

### Outstanding profiling and acceptance

Retain an evidence record using the format in [ReleaseValidation.md](ReleaseValidation.md#evidence-record). The current open checks are:

- Profile a live 4K60 GeForce NOW HEVC stream on Apple TV, including decode and render p95, dropped frames, AV delay, CPU, resident memory, and glass-to-glass latency.
- Use SwiftUI Instruments to confirm that loading progress, queue-ad bookkeeping, and session-expiry updates invalidate only their intended leaf views.
- Repeat stream entry and exit for 20 cycles and inspect Memory Graph results after the current teardown hardening.
- Run multi-hour input diagnostics and confirm the sample history and process memory remain stable.
- Exercise signaling failure injection and compare candidate-selection p95 with a retained baseline.
- Repeat rapid Retry and dismissal while checking provider request logs for cancelled or duplicate work.
- Verify locale and virtual-PC-scoped caches while offline and across account, locale, and virtual PC changes.
- Profile artwork request coalescing, cancellation, retry behavior, and cache-budget enforcement during sustained browsing.
- Validate cancellation and logging with a large server list.
- Exercise sustained physical-controller haptics without affecting input or frame delivery.
- Inspect a release archive and confirm that App Store media is absent.
- Compare cold-launch localization and English-fallback behavior on the same hardware and build configuration.

Provider smoke tests and source-level regression guards do not replace the GeForce NOW 4K60 acceptance matrix.

## Changing performance-sensitive code

Before merging a change to one of these paths:

1. Identify the invariant, owner, and explicit resource bound affected by the change.
2. Capture a baseline on a fixed device, operating system, build configuration, account, provider state, and network setup.
3. Change one performance variable at a time when practical.
4. Record raw measurements, not only a percentage or qualitative result.
5. Run deterministic tests for correctness, cancellation, bounds, and stale-result rejection.
6. Repeat the relevant physical-device or Instruments check.
7. Record regressions and inconclusive results as clearly as improvements.
8. Update this guide if an invariant, limit, owner, or acceptance requirement changes.

## Implementation history

The issue comments contain useful investigation detail, but pull requests are the clearer implementation record.

| Change | Performance work |
| --- | --- |
| [PR 68](https://github.com/owenselles/CloudNow/pull/68) | Cache-first startup and fewer catalog round trips |
| [PR 70](https://github.com/owenselles/CloudNow/pull/70) | Unified logging and removal of high-frequency console output |
| [PR 74](https://github.com/owenselles/CloudNow/pull/74) | Hero-art prefetching through the shared pipeline |
| [PR 75](https://github.com/owenselles/CloudNow/pull/75) | App Store media excluded from release packaging |
| [PR 84](https://github.com/owenselles/CloudNow/pull/84) | Startup, catalog, artwork, input, localization, persistence, and concurrency work |
| [PR 85](https://github.com/owenselles/CloudNow/pull/85) | Library cache moved from preferences to file-backed storage |
| [PR 94](https://github.com/owenselles/CloudNow/pull/94) | Diagnostics and session lifecycle redesign |
| [PR 99](https://github.com/owenselles/CloudNow/pull/99) | Session, signaling, teardown, and strict-concurrency hardening |
| [PR 104](https://github.com/owenselles/CloudNow/pull/104) | Incremental Library metadata enrichment |
| [PR 109](https://github.com/owenselles/CloudNow/pull/109) | Latest-frame rendering, lower-copy H.265 parsing, UI invalidation scope, and bounded Xbox catalog work |

The final issue update references commit [`1a1c4b1`](https://github.com/owenselles/CloudNow/commit/1a1c4b1605b93909451559e3511bcfd35be362b3), whose changes landed through PR 109's squash merge. Later feature work must preserve the same bounds and lifecycle rules even when it is not part of the original checklist.
