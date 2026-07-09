# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**CloudNow** is a native tvOS app — a reverse-engineered GeForce NOW client for Apple TV. It streams PC games over WebRTC using NVIDIA's GFN protocol over WebRTC, using [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework) as the WebRTC transport.

## Git

- **Upstream**: `origin` → `owenselles/CloudNow` (original author)
- **Fork**: `fork` → `yowmamasita/CloudNow` (our fork — push here)
- `project.pbxproj` contains our dev team ID (`7RX5G7H8DW`) and deployment target (`18.0`) — don't commit this to branches intended for upstream PRs

## Building

- **Xcode 16+**, targeting tvOS 17+
- Open `CloudNow.xcodeproj` in Xcode and build/run via Xcode (no command-line build setup)
- **Required SPM dependency**: Add [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework) via Xcode → File → Add Package Dependencies before building
- Distribution is sideload-only (no App Store target)
- No test suite, no linter configured

## Linting

Run lint after every Swift edit. CI fails PRs on violations.

```bash
# Format check (no mutation)
swiftformat --lint --config .swiftformat CloudNow
# Lint check
swiftlint --strict --config .swiftlint.yml CloudNow
# Auto-fix everything fixable
swiftformat --config .swiftformat CloudNow && swiftlint --fix --config .swiftlint.yml CloudNow
```

### Escape-hatch convention

When a rule genuinely cannot apply (e.g., a force-cast guarded by `layerClass`), use a single-line disable directive WITH a rationale:

```swift
// swiftlint:disable:next force_cast - reason: <one-sentence why>
```

Never use block `disable`/`enable` pairs and never omit the rationale.

### Pinned versions

Tools pinned in `.pre-commit-config.yaml` and `.github/workflows/lint.yml`: SwiftLint 0.63.3, SwiftFormat 0.61.1.

## Architecture

All source lives in `CloudNow/`. Five functional areas:

### Auth
- `AuthManager.swift` — `@Observable @MainActor` state holder. Checks Keychain on launch, drives device flow login, handles silent token refresh, and rebinds to a `client_token` grant so games.geforce.com GraphQL queries work.
- `NVIDIAAuthAPI.swift` — Raw NVIDIA OAuth endpoints: device authorization, token exchange, refresh, client_token rebinding.

### Session
- `GamesViewModel.swift` — Central `@Observable` shared across all tabs. Owns the games list, active sessions, favorites (UserDefaults), and stream settings.
- `CloudMatchClient.swift` — REST client for session lifecycle: create → poll queue position → active session → stop. Also retrieves and reports queue-ad lifecycle events.
- `GamesClient.swift` — GraphQL persisted queries for linked-library games and full store catalog.
- `ZoneClient.swift` — Fetches regions from the PrintedWaste community API; ranks them by 40% ping + 60% queue depth score.
- `SessionState.swift` — All data models: `StreamSettings`, `SessionInfo`, `GameInfo`, `QueueInfo`, etc.

### Streaming
- `GFNStreamController.swift` — `@Observable` WebRTC peer connection lifecycle. Opens the signaling WebSocket, negotiates SDP (server offer → munged answer), injects ICE candidates, attaches the video track, and collects live stats. Manages three data channels: `input_channel_v1` (reliable ordered), `input_channel_partially_reliable` (unordered, timed), and a server-opened `control_channel`. `InputSender` is started after receiving the server handshake on `input_channel_v1`.
- `SignalingClient.swift` — Low-level WebSocket via `NWConnection` + `NWProtocolWebSocket`. Manages TLS options (cipher negotiation, cert bypass for GFN endpoints) and the JSON signaling message protocol.
- `SDPMunger.swift` — Rewrites the client's SDP answer: filters to the preferred codec (H.264/H.265/AV1), front-loads H.265 Main10 for 10-bit/HDR requests, caps tier/level to hardware-safe values, injects max bitrate.
- `GFNVideoDecoderFactory.swift` — Decoder factory advertising H.265 Main10 (profile-id=2) alongside the LiveKit defaults so GFN's 10-bit payload survives answer negotiation; routes H.265 to `GFNVideoDecoderH265`.
- `GFNVideoDecoderH265.swift` — Custom VideoToolbox H.265 decoder preserving bit depth and VUI colorimetry (the bundled LiveKit decoder pins 8-bit NV12 and force-stamps BT.709/sRGB, breaking HDR10). Removable once the upstream webrtc-sdk fix ships.
- `InputSender.swift` — Encodes GCController/keyboard/mouse/Siri Remote input into GFN binary protocol packets (XInput for gamepads; protocol v2 plain or v3 partially-reliable wrapping) and sends over the WebRTC data channel. Starts only after receiving the server handshake on `input_channel_v1`. Configurable analog stick deadzone via `deadzone: Float` property (set from `StreamSettings.controllerDeadzone`).

### Video
- `VideoSurfaceView.swift` — `UIView` backed by `AVSampleBufferDisplayLayer` that receives decoded WebRTC frames via a `WebRTCFrameRenderer` (CVPixelBuffer → CMSampleBuffer). Also acts as first responder for hardware keyboard and Bluetooth mouse input, forwarding events to `InputSender` as GFN protocol packets.

### UI (SwiftUI)
- `MainTabView.swift` — Root tab bar (Home / Library / Store / Settings).
- `StreamView.swift` — Full-screen player. Menu button toggles pause menu with live stats (bitrate, resolution, FPS, RTT, packet loss %, remaining session time for Free/Priority tier).
- `HomeView.swift` — Hero banner, "Continue Playing" row (active sessions), Favorites row.
- `LibraryView.swift` — Library grid with search, A→Z/Z→A/Recently Played sort, and long-press context menus for Favorites.
- `StoreView.swift` — Full catalog grid with search, store filter chips, and long-press context menus for owned games.
- `SettingsView.swift` — Stream quality (resolution, FPS, codec, color, keyboard layout, game language, L4S), controller deadzone slider, zone picker, microphone toggle, account info.
- `QueueAdPlayerView.swift` — AVPlayer-based queue ad playback; reports lifecycle events to CloudMatch.
- `LoginView.swift` — Displays a QR code and PIN for NVIDIA device flow login; user scans the QR code or visits the URL on any device to complete OAuth.

## Key Patterns

- **State**: `@Observable + @MainActor` throughout (AuthManager, GFNStreamController, GamesViewModel). No Combine/Redux.
- **Auth flow**: NVIDIA device flow (TV shows QR code + PIN; user completes on any device) → token stored in Keychain → silent refresh on launch → `client_token` rebind for GraphQL.
- **Signaling**: Raw `NWConnection` WebSocket (not URLSessionWebSocketTask) to control TLS cipher suites and bypass cert pinning on GFN signaling endpoints.
- **SDP munging**: Applied to the client's **answer** (not the offer) to avoid orphaned FEC-FR SSRC lines. `SDPMunger.preferCodec` filters to the chosen codec and `injectBandwidth` sets max bitrate hints.
- **Input protocol**: XInput binary encoding over WebRTC data channel — see `InputSender` for byte layout.
- **Queue flow**: Session creation → poll queue position indefinitely (2 consecutive ready polls required) → 180 s setup timeout after queue clears → optional queue ad → stream start.

## Data Flow (game launch)

1. `GamesViewModel` calls `CloudMatchClient.createSession()`
2. Polls queue until `ACTIVE` (two consecutive) or timeout
3. `StreamView` appears → `GFNStreamController.connect()` opens `SignalingClient` WebSocket
4. SDP offer built → `SDPMunger` rewrites it → sent via signaling
5. Answer received → ICE exchange → peer connection established
6. Video track → `VideoSurfaceView` (Metal render)
7. `InputSender` encodes controller frames → data channel → GFN server
