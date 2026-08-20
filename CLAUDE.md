# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**CloudNow** is a native tvOS cloud gaming app for Apple TV. It provides
separate GeForce NOW and Xbox Cloud Gaming provider modes behind a
provider-neutral app shell. Each provider owns its account, catalog, session,
signaling, quality, input, and lifecycle protocol. Both native transports use
[livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework).

## Git

- `origin` → `owenselles/CloudNow`
- Push feature branches to `origin` and open PRs against `main`

## Building

- **Xcode 26.2+**, targeting tvOS 26.2+
- Open `CloudNow.xcodeproj` in Xcode, or use `Scripts/test.sh` for command-line simulator testing
- **Required SPM dependency**: [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework), resolved automatically from the shared project and tracked `Package.resolved`
- Current distribution options are TestFlight, release IPA, and source builds;
  no App Store availability is claimed
- `CloudNowTests` uses Swift Testing for unit/integration coverage; `CloudNowUITests` uses XCTest for deterministic tvOS UI automation
- SwiftLint, SwiftFormat, and the simulator test suite are required by CI

## Linting

Run both non-mutating checks before completing every task that changes repository content. CI fails PRs on violations.

First read the pinned versions from the `README.md` **Linting** section and verify the local executables match exactly. If a local tool has the wrong version, use the pinned CI/pre-commit environment instead.

```bash
# Format check (no mutation)
swiftformat --lint --config .swiftformat CloudNow CloudNowTests CloudNowUITests
# Lint check
swiftlint --strict --config .swiftlint.yml CloudNow CloudNowTests CloudNowUITests
# Auto-fix everything fixable
swiftformat --config .swiftformat CloudNow CloudNowTests CloudNowUITests
swiftlint --fix --config .swiftlint.yml CloudNow CloudNowTests CloudNowUITests
```

### Escape-hatch convention

When a rule genuinely cannot apply (e.g., a force-cast guarded by `layerClass`), use a single-line disable directive WITH a rationale:

```swift
// swiftlint:disable:next force_cast - reason: <one-sentence why>
```

Never use block `disable`/`enable` pairs and never omit the rationale.

### Pinned versions

Tools pinned in `.pre-commit-config.yaml` and `.github/workflows/lint.yml`: SwiftLint 0.65.0, SwiftFormat 0.62.1.

## Testing

Run the complete deterministic tvOS simulator suite from any current directory:

```bash
/path/to/CloudNow/Scripts/test.sh
```

Use `--unit`, `--ui`, or `--full` to select a mode. The runner discovers and
boots a compatible simulator, resolves packages, disables code signing, enables
coverage, and writes ignored results under `TestArtifacts/`. Tests must use
injected fakes and fixtures; they must never contact live provider
authentication, catalog, signaling, image, media, or community services. See
the README **Testing** section for fixture conventions and hardware-only
exclusions.

## Architecture

All source lives in one `CloudNow` app target. There is no separate shared-core
framework. Boundaries are enforced by provider-neutral contracts, lazy provider
graphs, dependency direction, deterministic tests, and the GFN frozen-source CI
guard.

### Shared/provider-neutral

- `CloudNowApp.swift` retains both independent account managers and capability
  adapters, restores the selected provider, and activates only that provider's
  UI and transport/network work. The Xbox production context is lightweight;
  its service graph remains lazy.
- `Services/CloudGamingProvider.swift` owns provider identity, selection, and
  provider configuration; `CloudGamingCapabilities.swift` defines narrow
  account/catalog/stream/input/diagnostic contracts and global server-session
  and local-peer leases.
- `Streaming/CloudRTCRuntime.swift` owns the one process-level WebRTC factory.
  The audio device, passive video surface, decoded-format inspection, controller
  haptics, artwork pipeline, persistence boundaries, app lifecycle, pause
  chrome, network-test UI, and HUD value models are reusable primitives—not a
  shared provider protocol.
- `CloudNowTabShell`, `CloudServiceSelectionView`, and neutral catalog/device-code
  components provide shared presentation. Provider screens and wire state remain
  separate.

### GeForce NOW

- `Auth/` owns the established OAuth/refresh path; `Session/` owns GFN catalog,
  cloud-library sync, account capabilities, game-server discovery, CloudMatch,
  and `SessionOrchestrator`.
- `Streaming/GFNStreamController.swift` remains the established WebRTC answerer.
  It receives a server offer, applies the GFN-only `SDPMunger`, returns an
  answer, exchanges ICE, attaches media, and owns reconnect, microphone, audio,
  and data-channel state.
- `SignalingClient`, `SignalingEndpointRace`, and `SignalingMessageCodec` own the
  GFN WebSocket path. `InputSender` owns GFN controller/keyboard/mouse/Siri
  Remote/text encoding. `GFNVideoDecoderFactory` and `GFNVideoDecoderH265`
  preserve H.265 Main10 and decoded color metadata.
- `UI/MainTabView`, `GamesViewModel`, `HomeView`, `LibraryView`, `StoreView`,
  `SettingsView`, and `StreamView` are the established GFN experience. They are
  not shared Xbox view models.

### Xbox Cloud Gaming

- `Xbox/MicrosoftDeviceCodeOAuthClient`, `XboxAuthManager`, Xbox Live/XSTS
  clients, and the local credential group own the Xbox account path.
- `XboxCloudOfferingService` owns the validated endpoint/protocol/identity
  compatibility profile. Content Access, Fresno discovery, catalog, detail, and
  cache clients own account access, Max Stream Quality, routes, and the
  confirmed-route Library/full-catalog Browse projections.
- `XboxCloudSessionAPI` owns allocation, queue/configuration, keepalive, and
  deletion. `XboxCloudSignalingAPI` owns bounded REST SDP/ICE exchange.
- `XboxCloudWebRTCTransport` is the client-offer WebRTC path and owns service
  overrides, data-channel versions, media readiness, microphone attachment, and
  teardown. `XboxCloudInputDriver` plus legacy/modern codecs own Xbox control,
  dimensions, controller/keyboard/mouse, feedback, and rumble wire behavior.
- `XboxCloudStreamController`, lifecycle contracts, and
  `XboxProductionRuntimeContext` own launch, reconnect, Leave/Continue/End, and
  the lazy production graph. `XboxCloudRTCStatsSampler` reports delivered media.
- `UI/XboxCloudViews`, `XboxCatalogDetailView`, `XboxCloudPlayerView`, and
  `XboxVideoSurfaceView` own Xbox Home/Library/Browse/Settings, route-correlated
  catalog presentation, player, and Simulator input bridge.

GFN and Xbox share the factory and passive media primitives, but they do not
import or translate one another's authentication, session, signaling, SDP,
data-channel, input, reconnect, resume, or stream-setting behavior. See the
README **Architecture** section for the detailed source tree and
`Documentation/XboxCloudGaming.md` for the Xbox request path.

## Agent Rules

- **Language**: All code, comments, commit messages, PR titles, and PR descriptions must be written in **English US**.
- **Commits and PRs**: Do not add `Co-Authored-By: Claude` lines to commits. Do not add "🤖 Generated with Claude Code" footers to PR descriptions.

## Key Patterns

- **State ownership**: observable UI state is main-actor isolated; high-frequency
  media/input work uses actors, locks, or serial queues. Connection generations
  reject stale callbacks.
- **Provider selection**: persist only the selected provider; keep credentials,
  settings, cache, session leases, and runtime dependencies provider-scoped.
- **GFN flow**: provider device authorization → secure token/refresh → cloud
  library/session → server WebSocket offer → GFN-munged client answer → GFN
  data-channel input.
- **Xbox flow**: Microsoft device authorization → Xbox Live/XSTS → offering and
  access discovery → v5 allocation → local WebRTC offer/REST answer → Xbox
  control/message/input channels.
- **SDP direction matters**: GFN munges its client **answer**; Xbox owns a
  separate client **offer** policy. Never reuse one provider's SDP behavior in
  the other.
- **Session safety**: server-session and local-peer leases are unique, token
  owned, and failure-aware. A failed End remains quarantined instead of allowing
  a second session.
- **Quality truth**: distinguish preference, request, negotiation, and delivered
  media. GFN has advanced codec/color/audio controls; Xbox exposes only proven
  controls and shows requested versus delivered resolution.

## Data Flow (game launch)

### GeForce NOW

1. `GamesViewModel` and `SessionOrchestrator` reserve ownership and create the
   CloudMatch session.
2. Queue/provisioning polls require two consecutive ready results; the setup
   timeout begins after queue exit.
3. `GFNStreamController` opens the bounded signaling endpoint race and receives
   the server SDP offer.
4. `SDPMunger` rewrites the client answer for the chosen GFN codec/color/bitrate
   policy; the answer and ICE return through signaling.
5. The received track renders through `VideoSurfaceView`; `InputSender` starts
   after the GFN input-channel handshake.

### Xbox Cloud Gaming

1. The Xbox player reserves one global server lease; the session API creates one
   allocation and polls queue/provisioning within the absolute deadline.
2. Configuration and signaling context create the Xbox native runtime and local
   WebRTC offer; the service answer and ICE arrive over REST.
3. The control path sends the resolution preference before authorization.
   `messageV1` sends active display dimensions after its handshake; gameplay
   input still waits for media readiness.
4. The passive video surface renders the received track while RTC statistics
   report delivered resolution/FPS/bitrate/codec/color/audio independently of
   the requested ceiling.
5. Leave parks the unexpired allocation, Continue reuses it, and End deletes it
   before releasing the global lease.
