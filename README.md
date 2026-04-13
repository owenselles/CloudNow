# OpenNowTV

A native GeForce NOW client for Apple TV. Stream your entire PC game library directly on tvOS with full controller support — no browser, no workarounds.

> **Personal use / sideload only.** This project is not affiliated with, endorsed by, or sponsored by NVIDIA. NVIDIA and GeForce NOW are trademarks of NVIDIA Corporation.

> [!WARNING]
> OpenNowTV is under active development. Expect bugs, lots of them
---

## Features

- **Tab bar navigation** — Home, Library, Store, and Settings; fully focus-engine compatible
- **Home screen** — "Continue Playing" row powered by live active sessions, plus a Favorites row
- **Library & Store** — browse your linked games separately from the full public catalog
- **Stream quality settings** — resolution (720p/1080p/4K), frame rate, codec (H.264/H.265/AV1), and color quality (SDR/HDR) from the Settings tab
- **Favorites** — heart any game in your Library; persisted locally
- **Full GFN streaming** — WebRTC-based, up to 4K@60fps (subject to your GFN subscription tier)
- **Controller support** — up to 4 simultaneous MFi/Xbox/PlayStation controllers via the GameController framework
- **NVIDIA OAuth login** — PKCE flow; authentication completes on your paired iPhone via Handoff
- **Live stats overlay** — bitrate, resolution, FPS, RTT, packet loss — toggle with the Menu button
- **Keychain persistence** — session tokens stored securely and auto-refreshed on launch

## Requirements

- Apple TV 4K (2nd generation or later) running tvOS 17+
- Xcode 16+ on a Mac
- Active GeForce NOW account (Free, Priority, or Ultimate)
- Apple Developer account (free tier works for sideloading)
- iPhone paired with your Apple TV (for initial login via Handoff)

## Getting Started

### 1. Clone

```bash
git clone https://github.com/owenselles/OpenNowTV.git
cd OpenNowTV
```

### 2. Add the WebRTC package

Open `OpenNowTV.xcodeproj` in Xcode, then:

**File → Add Package Dependencies…**
Paste: `https://github.com/livekit/webrtc-xcframework`
Target: **WebRTC**

### 3. Set your Team

Xcode → OpenNowTV target → **Signing & Capabilities** → select your Apple Developer team.

### 4. Build & Run

Select your Apple TV as the run destination (USB-C or network) and hit **⌘R**.

On first launch the app prompts you to sign in. A notification appears on your paired iPhone — tap it to complete OAuth in Safari, then return to the TV.

---

## Architecture

```
OpenNowTV/
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
│   └── InputSender.swift           GCController → XInput binary protocol → data channel
├── Video/
│   └── VideoSurfaceView.swift      Metal-backed video surface (UIViewRepresentable)
└── UI/
    ├── GamesViewModel.swift        Shared @Observable — games, sessions, favorites, settings
    ├── MainTabView.swift           Root TabView (Home / Library / Store / Settings)
    ├── HomeView.swift              Hero banner + Continue Playing + Favorites rows
    ├── LibraryView.swift           LIBRARY panel grid with favorite toggles
    ├── StoreView.swift             MAIN catalog grid with "In Library" badges
    ├── SettingsView.swift          Stream quality pickers + account info + sign out
    ├── LoginView.swift             Sign-in screen with Handoff instructions
    └── StreamView.swift            Full-screen player + HUD stats overlay
```

### Protocol

The GFN streaming protocol was reverse-engineered by [OpenNOW](https://github.com/OpenCloudGaming/OpenNOW) (TypeScript/Electron). This project ports their work to native Swift/tvOS.

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
- **SDP munging not yet implemented.** Advanced codec negotiation (AV1, partial reliability) from OpenNOW's `sdp.ts` is not yet ported.
- **No microphone support.** The server supports mic input over a second data channel; not implemented yet.
- **No queue/ad handling.** During high demand, GFN queues sessions and shows ads. The app shows a spinner only.

## Contributing

PRs welcome, especially for:

- SDP munging (`Streaming/SDPProcessor.swift`)
- Microphone support
- Session queue / ad state UI
- macOS Catalyst or visionOS port

## Sponsoring

If this project is useful to you, consider sponsoring to help keep it maintained.

[![GitHub Sponsors](https://img.shields.io/badge/Sponsor%20on%20GitHub-%E2%9D%A4-pink?style=flat-square&logo=github)](https://github.com/sponsors/owenselles)

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

- [OpenNOW](https://github.com/OpenCloudGaming/OpenNOW) — GFN protocol reverse engineering
- [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework) — WebRTC for Apple platforms
