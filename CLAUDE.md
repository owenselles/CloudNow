# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**OpenTVPlay** (branded OpenNowTV) is a native tvOS app — a reverse-engineered GeForce NOW client for Apple TV. It streams PC games over WebRTC using NVIDIA's GFN protocol over WebRTC, using [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework) as the WebRTC transport.

## Building

- **Xcode 16+**, targeting tvOS 17+
- Open `OpenTVPlay.xcodeproj` in Xcode and build/run via Xcode (no command-line build setup)
- **Required SPM dependency**: Add [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework) via Xcode → File → Add Package Dependencies before building
- Distribution is sideload-only (no App Store target)
- No test suite, no linter configured

## Architecture

All source lives in `OpenTVPlay/`. Five functional areas:

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
- `SDPMunger.swift` — Rewrites the SDP offer before sending: filters to preferred codec (H.264/H.265/AV1), clamps H.265 to Main profile, injects max bitrate.
- `InputSender.swift` — Encodes GCController/keyboard/mouse/Siri Remote input into GFN binary protocol packets (XInput for gamepads; protocol v2 plain or v3 partially-reliable wrapping) and sends over the WebRTC data channel. Starts only after receiving the server handshake on `input_channel_v1`.

### Video
- `VideoSurfaceView.swift` — `UIView` backed by `AVSampleBufferDisplayLayer` that receives decoded WebRTC frames via a `WebRTCFrameRenderer` (CVPixelBuffer → CMSampleBuffer). Also acts as first responder for hardware keyboard and Bluetooth mouse input, forwarding events to `InputSender` as GFN protocol packets.

### UI (SwiftUI)
- `MainTabView.swift` — Root tab bar (Home / Library / Store / Settings).
- `StreamView.swift` — Full-screen player. Menu button toggles live stats overlay (bitrate, resolution, FPS, RTT, packet loss %).
- `HomeView.swift` — Hero banner, "Continue Playing" row (active sessions), Favorites row.
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
