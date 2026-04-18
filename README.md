# CloudNow

A native GeForce NOW client for Apple TV. Stream your entire PC game library directly on tvOS with full controller support, no browser, no workarounds.

> **Personal use / sideload only.** This project is not affiliated with, endorsed by, or sponsored by NVIDIA. NVIDIA and GeForce NOW are trademarks of NVIDIA Corporation.

> [!WARNING]
> CloudNow is under active development. Expect bugs, lots of them




---

## Features

- **Tab bar navigation** — Home, Library, Store, and Settings; fully focus-engine compatible
- **Home screen** — "Continue Playing" row powered by live active sessions, plus a Favorites row
- **Library & Store** — browse your linked games separately from the full public catalog; Store has search
- **Stream quality settings** — resolution up to 4K (tier-dependent), frame rate, codec (H.264/H.265/AV1), and color quality (SDR/HDR) from the Settings tab
- **Codec-aware SDP negotiation** — offer is filtered to your chosen codec before WebRTC negotiation; H.265 prefers Main profile; bandwidth hints sent to prevent server overshoot
- **Session queue UI** — shows queue phase ("In queue · Position X" → "Preparing your game"); waits indefinitely in queue with position updates; 180-second setup timeout after queue clears; requires two consecutive ready polls before presenting the stream; plays mandatory queue ads via AVPlayer and reports lifecycle events back to CloudMatch
- **Zone/region selection** — Settings → Server Region shows live queue depths and ping per zone; Automatic mode picks the best zone by weighted score (40% ping + 60% queue depth); powered by the PrintedWaste community API
- **Microphone support** — voice chat via AirPods or any Bluetooth headset; toggle in Settings; permission requested on first use
- **Favorites** — heart any game in your Library; persisted locally
- **Full GFN streaming** — WebRTC-based, up to 4K@60fps or 1080p@120fps depending on your GFN plan
- **Controller support** — up to 4 simultaneous MFi/Xbox/PlayStation controllers via the GameController framework
- **NVIDIA OAuth login** — device flow; TV shows a QR code and PIN; complete sign-in on any phone, tablet, or computer
- **Live stats overlay** — bitrate, resolution, FPS, RTT, real packet loss % — toggle with the Play/Pause button
- **Keychain persistence** — session tokens stored securely and auto-refreshed on launch

## Requirements

- Apple TV 4K (2nd generation or later) running tvOS 17+
- Xcode 16+ on a Mac
- Active GeForce NOW account (Free, Priority, or Ultimate)
- Apple Developer account (free tier works for sideloading)

## Getting Started

### 1. Clone

```bash
git clone https://github.com/owenselles/CloudNow.git
cd CloudNow
```

### 2. Add the WebRTC package

Open `CloudNow.xcodeproj` in Xcode, then:

**File → Add Package Dependencies…**
Paste: `https://github.com/livekit/webrtc-xcframework`
Target: **WebRTC**

### 3. Set your Team

Xcode → CloudNow target → **Signing & Capabilities** → select your Apple Developer team.

### 4. Build & Run

Select your Apple TV as the run destination (USB-C or network) and hit **⌘R**.

On first launch the app prompts you to sign in. A QR code and PIN are displayed — scan the QR code or visit the URL on any device and enter the PIN to complete sign-in, then return to the TV.

---

## Architecture

```
CloudNow/
├── Auth/
│   ├── AuthManager.swift           @Observable auth state, Keychain persistence
│   └── NVIDIAAuthAPI.swift         OAuth 2.0 PKCE, token refresh, user info
├── Session/
│   ├── SessionState.swift          Models: GameInfo, SessionInfo, StreamSettings
│   ├── CloudMatchClient.swift      Session create/poll/stop/active-sessions
│   └── GamesClient.swift           Game catalog via GraphQL persisted query
├── Streaming/
│   ├── GFNStreamController.swift   WebRTC peer connection lifecycle (@Observable)
│   ├── SignalingClient.swift        WebSocket signaling — SDP offer/answer + ICE
│   ├── SDPMunger.swift             Codec filtering + bandwidth injection for WebRTC SDP
│   └── InputSender.swift           GCController/keyboard/mouse/Siri Remote → XInput + GFN protocol (v2/v3) → data channel
├── Video/
│   └── VideoSurfaceView.swift      AVSampleBufferDisplayLayer video surface + keyboard/mouse first responder
└── UI/
    ├── GamesViewModel.swift        Shared @Observable — games, sessions, favorites, settings
    ├── MainTabView.swift           Root TabView (Home / Library / Store / Settings)
    ├── HomeView.swift              Hero banner + Continue Playing + Favorites rows
    ├── LibraryView.swift           LIBRARY panel grid with favorite toggles
    ├── StoreView.swift             MAIN catalog grid with "In Library" badges
    ├── SettingsView.swift          Stream quality pickers + account info + sign out
    ├── LoginView.swift             Sign-in screen with QR code + PIN display
    └── StreamView.swift            Full-screen player + HUD stats overlay
```

### Protocol

The GFN streaming protocol was independently reverse-engineered from NVIDIA's network traffic. The WebRTC transport is provided by [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework).

| Layer | Implementation |
|-------|---------------|
| Auth | OAuth 2.0 PKCE → `login.nvidia.com` |
| Session | REST → CloudMatch (`cloudmatchbeta.nvidiagrid.net`) |
| Signaling | WebSocket (`/nvst/sign_in`) — SDP offer/answer + ICE |
| Streaming | WebRTC via [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework) |
| Input | XInput binary protocol over WebRTC data channel |
| Game catalog | GraphQL persisted query → `games.geforce.com` |

---

## Known Limitations

- **No App Store.** NVIDIA has not published a public API for third-party GFN clients. Sideloading only.
- **Queue ad playback.** During high demand GFN shows ads while in queue. The app plays them via AVPlayer and reports lifecycle events (start/pause/finish) back to CloudMatch.
- **Zone/region selection.** Settings → Server Region lets you pick a specific zone or leave it on Automatic (40% ping + 60% queue depth scoring). Zone list + queue depths fetched from the PrintedWaste community API.
## Contributing

PRs welcome, especially for:

- macOS Catalyst or visionOS port

## Sponsoring

If this project is useful to you, consider sponsoring to help keep it maintained.

[![GitHub Sponsors](https://img.shields.io/badge/Sponsor%20on%20GitHub-%E2%9D%A4-pink?style=flat-square&logo=github)](https://github.com/sponsors/owenselles)

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

- [PrintedWaste](https://printedwaste.com) — community API for GFN zone queue depths and region mapping
- [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework) — WebRTC for Apple platforms
