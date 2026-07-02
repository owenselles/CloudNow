# CloudNow

A native GeForce NOW client for Apple TV. Stream your entire PC game library directly on tvOS with full controller support, no browser, no workarounds.

> **Personal use / sideload only.** This project is not affiliated with, endorsed by, or sponsored by NVIDIA. NVIDIA and GeForce NOW are trademarks of NVIDIA Corporation.

> [!WARNING]
> CloudNow is under active development. Expect bugs, lots of them

---

## Installation

### Option A — Pre-built IPA (recommended for most users)

Download the latest `CloudNow.ipa` from the [Releases](https://github.com/owenselles/CloudNow/releases) page, then sideload it with [Sideloadly](https://sideloadly.io) or AltServer. No Xcode or Apple Developer account required — Sideloadly signs the IPA with your free Apple ID.

### Option B — Build from source

Follow the [Getting Started](#getting-started) steps below if you want to build and run directly from Xcode.

---

## Features

- **Tab bar navigation** — Home, Library, Store, and Settings; fully focus-engine compatible
- **Home screen** — "Continue Playing" row powered by live active sessions, plus a Favorites row
- **Library & Store** — browse your linked games separately from the full public catalog; Library and Store both have search; Library supports A→Z, Z→A, and Recently Played sort orders; long-press any card to add/remove from Favorites
- **Stream quality settings** — resolution up to 4K (tier-dependent), frame rate, codec (H.264/H.265/AV1), color mode, keyboard layout, game language, and Low Latency Mode (L4S) from the Settings tab
- **Color mode preferences** — Automatic, Prefer HDR, Prefer 10-bit SDR, and Compatibility SDR. CloudNow separates user preference, requested stream mode, negotiated server mode, and actual detected decoded format instead of assuming HDR from bit depth or Apple TV output mode
- **Decoded video format detection** — inspects the actual decoded pixel buffer for bit depth, transfer function, color primaries, matrix, and range. HDR is only treated as active when the decoded stream metadata supports it
- **Conservative HDR behavior** — requests HDR only when the local pipeline qualifies; accepts safe server-side fallback to SDR10 or SDR8 without treating every 10-bit stream as HDR
- **Codec-aware SDP negotiation** — offer is filtered to your chosen codec before WebRTC negotiation; H.265 prefers Main profile; bandwidth hints sent to prevent server overshoot
- **Renderer metadata preservation** — decoded color metadata is tracked through the render path and the format description cache is refreshed when color characteristics change, not just when resolution changes
- **Session diagnostics** — diagnostic HUD can show color preference, requested mode, detected mode, display HDR support, fallback reason, decoder path, pixel format, transfer function, and bit depth
- **Session queue UI** — shows queue phase ("In queue · Position X" → "Preparing your game"); waits indefinitely in queue with position updates; 180-second setup timeout after queue clears; requires two consecutive ready polls before presenting the stream; plays mandatory queue ads via AVPlayer and reports lifecycle events back to CloudMatch
- **Zone/region selection** — Settings → Server Region shows live queue depths and ping per zone; Automatic mode picks the best zone by weighted score (40% ping + 60% queue depth); powered by the PrintedWaste community API
- **Microphone support** — voice chat via AirPods or any Bluetooth headset; toggle in Settings; permission requested on first use; if no valid input route exists, CloudNow falls back to playback-only audio instead of breaking session audio
- **Favorites** — long-press any game card in Library or Store to add/remove from Favorites; persisted locally
- **Full GFN streaming** — WebRTC-based, up to 4K@60fps depending on your GFN plan (tvOS caps at 60 Hz; 120fps ready for when Apple raises the limit)
- **Controller support** — up to 4 simultaneous MFi/Xbox/PlayStation controllers via the GameController framework; configurable analog stick deadzone (5–30%) and overlay trigger button (Start/≡ or Options/Back ⊟, default: Start)
- **NVIDIA OAuth login** — device flow; TV shows a QR code and PIN; complete sign-in on any phone, tablet, or computer
- **Live stats overlay** — bitrate, resolution, FPS, RTT, real packet loss %, decoder info, and remaining session time (Free/Priority tier) — toggle with Play/Pause (Siri Remote) or long-press the overlay button (controller, default: Start/≡, configurable in Settings)
- **Keychain persistence** — session tokens stored securely and auto-refreshed on launch

## Requirements

- Apple TV 4K (2nd generation or later) running tvOS 17+
- Active GeForce NOW account (Free, Priority, or Ultimate)
- **Build from source only:** Xcode 16+ on a Mac, Apple Developer account (free tier works)

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

Copy the local config template and fill in your Apple Developer Team ID:

```bash
cp Local.xcconfig.example Local.xcconfig
```

Edit `Local.xcconfig` and replace `YOUR_TEAM_ID_HERE` with your Team ID (find it at [developer.apple.com](https://developer.apple.com) → Account → Membership).

Then attach it to the project in Xcode:
**Project navigator → CloudNow project → Info tab → Configurations → expand Debug and Release → set "Based on" to `Local.xcconfig`** for both.

`Local.xcconfig` is gitignored and should never be committed.

### 4. Build & Run

Select your Apple TV as the run destination (USB-C or network) and hit **⌘R**.

On first launch the app prompts you to sign in. A QR code and PIN are displayed — scan the QR code or visit the URL on any device and enter the PIN to complete sign-in, then return to the TV.

---

## Linting

CloudNow uses SwiftLint and SwiftFormat. CI gates PRs on lint failures.

### Install (one-time)

```bash
brew install swiftlint swiftformat pre-commit
```

### Run locally

```bash
# Format check (no mutation)
swiftformat --lint --config .swiftformat CloudNow
# Lint check
swiftlint --strict --config .swiftlint.yml CloudNow
# Auto-fix everything fixable
swiftformat --config .swiftformat CloudNow && swiftlint --fix --config .swiftlint.yml CloudNow
```

### Optional pre-commit hook

```bash
pre-commit install
```

After installing, every `git commit` runs SwiftFormat then SwiftLint --fix against your staged files. On fixable issues, files are auto-corrected in the working tree and the commit is aborted with "Files were modified by this hook" — run `git add` and `git commit` again to land the fixed version. On unfixable issues, the hook prints the violation and aborts; edit the file manually and try again.

### Pinned versions

CI uses SwiftLint 0.63.3 and SwiftFormat 0.61.1. Local installs via Homebrew should match or exceed these; verify with `swiftlint version` and `swiftformat --version`.

---

## Architecture

```
CloudNow/
├── Auth/
│   ├── AuthManager.swift           @Observable auth state, Keychain persistence
│   └── NVIDIAAuthAPI.swift         OAuth 2.0 PKCE, token refresh, user info
├── Session/
│   ├── SessionState.swift          Models: GameInfo, SessionInfo, StreamSettings, color-mode state
│   ├── CloudMatchClient.swift      Session create/poll/stop/active-sessions, color-aware request fields
│   └── GamesClient.swift           Game catalog via GraphQL persisted query
├── Streaming/
│   ├── GFNStreamController.swift   WebRTC peer connection lifecycle, color negotiation state, audio session setup
│   ├── SignalingClient.swift        WebSocket signaling — SDP offer/answer + ICE
│   ├── SDPMunger.swift             Codec filtering + bandwidth injection for WebRTC SDP
│   └── InputSender.swift           GCController/keyboard/mouse/Siri Remote → XInput + GFN protocol (v2/v3) → data channel
├── Video/
│   ├── VideoSurfaceView.swift      AVSampleBufferDisplayLayer video surface + decoded-format-aware renderer
│   ├── VideoColorFormat.swift      Local video capability detection + decoded pixel-buffer format inspection
│   ├── VideoPipelineDiagnostics.swift Render/decode pipeline diagnostics
│   └── I420FrameConverter.swift    Software I420 conversion fallback path
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

## Color and HDR Notes

CloudNow does **not** treat a stream as HDR merely because:

- the stream is 10-bit
- the connected display supports HDR
- tvOS is currently outputting HDR or Dolby Vision
- the user selected an HDR-related setting

CloudNow uses three separate pieces of information:

1. **What to request** — based on user preference and local capabilities
2. **What the server negotiated** — based on session and signaling state
3. **What is actually being rendered** — based on decoded video metadata from the real pixel buffer

This means an HDR request can legitimately fall back to SDR10 or SDR8, and the app will report that instead of falsely claiming HDR is active.

---

## Known Limitations

- **No App Store.** NVIDIA has not published a public API for third-party GFN clients. Sideloading only.
- **Queue ad playback.** During high demand GFN shows ads while in queue. The app plays them via AVPlayer and reports lifecycle events (start/pause/finish) back to CloudMatch.
- **Zone/region selection.** Settings → Server Region lets you pick a specific zone or leave it on Automatic (40% ping + 60% queue depth scoring). Zone list + queue depths fetched from the PrintedWaste community API.
- **HDR depends on the full pipeline.** A selected HDR-capable mode does not guarantee the server will deliver HDR, and a 10-bit stream is not automatically HDR.
- **AV1 currently uses the software I420 path.** On the current implementation this falls back to SDR 8-bit BT.709 rather than preserving SDR10 or HDR metadata.
- **Color diagnostics are only as good as decoded metadata.** If the decoder or software conversion path strips metadata, CloudNow will conservatively report fallback or unknown modes instead of guessing.

## Contributing

PRs welcome, especially for:

- macOS Catalyst or visionOS port
- Better verified HDR negotiation evidence and decoder-path coverage
- Additional diagnostics and test coverage for tvOS playback paths

## Sponsoring

If this project is useful to you, consider sponsoring to help keep it maintained.

[![GitHub Sponsors](https://img.shields.io/badge/Sponsor%20on%20GitHub-%E2%9D%A4-pink?style=flat-square&logo=github)](https://github.com/sponsors/owenselles)

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

- [PrintedWaste](https://printedwaste.com) — community API for GFN zone queue depths and region mapping
- [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework) — WebRTC for Apple platforms
