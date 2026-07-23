# CloudNow

A native GeForce NOW client for Apple TV. Stream your entire PC game library directly on tvOS with full controller support, no browser, no workarounds.

![CloudNow Home screen on Apple TV](App%20Store%20Media/Screenshot%201.png)

> **Personal use / sideload only.** This project is not affiliated with, endorsed by, or sponsored by NVIDIA. NVIDIA and GeForce NOW are trademarks of NVIDIA Corporation.

---

## Installation

### Option A — TestFlight (recommended)

Join the public beta via TestFlight — no sideloading or Xcode required:

**[Join TestFlight Beta](https://testflight.apple.com/join/hfm795kG)**

### Option B — Pre-built IPA

Download the latest `CloudNow.ipa` from the [Releases](https://github.com/owenselles/CloudNow/releases) page, then sideload it with [Sideloadly](https://sideloadly.io) or AltServer. No Xcode or Apple Developer account required — Sideloadly signs the IPA with your free Apple ID.

### Option C — Build from source

Follow the [Getting Started](#getting-started) steps below if you want to build and run directly from Xcode.

---

## Features

- **Tab bar navigation** — Home, Library, Store, and Settings; fully focus-engine compatible
- **Home screen** — "Continue Playing" row powered by live active sessions, plus a Favorites row
- **Library & Store** — browse your linked games separately from the full public catalog; search and sort by default order, recently played, A→Z, or Z→A; filter by collection, genre, game store, RTX, HDR, and Reflex with live result counts; long-press any card to add/remove from Favorites
- **Instant startup** — catalog, library, and subscription data are cached on device and shown immediately on launch while fresh data loads in the background
- **Bounded performance pipelines** — artwork requests are coalesced and downsampled through shared cost-bounded caches; input-latency sampling uses bounded storage and remains disabled unless statistics or diagnostics need it
- **Stream quality settings** — resolution up to 4K (tier-dependent), frame rate, codec (H.264/H.265/AV1), color mode, keyboard layout, game language, and Low Latency Mode (L4S) from the Settings tab
- **Color mode preferences** — Automatic, Prefer HDR, Prefer 10-bit SDR, and Compatibility SDR. CloudNow separates user preference, requested stream mode, negotiated server mode, and actual detected decoded format instead of assuming HDR from bit depth or Apple TV output mode
- **Decoded video format detection** — inspects the actual decoded pixel buffer for bit depth, transfer function, color primaries, matrix, and range. HDR is only treated as active when the decoded stream metadata supports it
- **Conservative HDR behavior** — requests HDR only when the local pipeline qualifies; accepts safe server-side fallback to SDR10 or SDR8 without treating every 10-bit stream as HDR
- **Codec-aware SDP negotiation** — the SDP answer is filtered to your chosen codec; H.265 Main10 is front-loaded for 10-bit/HDR requests with tier/level capped to hardware-safe values; bandwidth hints sent to prevent server overshoot
- **HDR-preserving H.265 decoder** — custom VideoToolbox decoder keeps 10-bit depth and VUI colorimetry intact (the bundled WebRTC decoder pins 8-bit NV12 and stamps BT.709), so HDR10 survives from the wire to the display
- **Renderer metadata preservation** — decoded color metadata is tracked through the render path and the format description cache is refreshed when color characteristics change, not just when resolution changes
- **Session diagnostics** — diagnostic HUD can show color preference, requested mode, detected mode, display HDR support, fallback reason, decoder path, pixel format, transfer function, and bit depth
- **Session queue UI** — shows queue phase ("In queue · Position X" → "Preparing your game"); waits indefinitely in queue with position updates; 180-second setup timeout after queue clears; requires two consecutive ready polls before presenting the stream; plays mandatory queue ads via AVPlayer and reports lifecycle events back to CloudMatch
- **Resilient session lifecycle** — session creation, Retry, polling, reconnect, and teardown are single-flight and cancellable; stale work cannot update a newer session, late-created server sessions are cleaned up, and signaling uses a bounded staggered endpoint race instead of serial timeout accumulation
- **Server location** — Settings → Server Location offers Automatic (default), Region, and Servers. Automatic lets NVIDIA route each session, Region pins one of the regions returned by NVIDIA, and Servers drills down through country → city → dedicated server with live ping and queue information; cached ping results appear immediately while stale entries refresh with bounded concurrency; includes a Test Network tool measuring ping, jitter, and packet loss to the selected route
- **Surround audio** — Audio Format setting with Automatic, Stereo, and 5.1 Surround; the selected source format is preserved when resuming a session. The diagnostics HUD reports the negotiated stream format separately from the active output route, so a 5.1 stream may correctly use stereo output while Bluetooth headphones are connected; removing them restores HDMI playback and surround where supported
- **Microphone support** — voice chat via AirPods or compatible Bluetooth HFP headsets; toggle in Settings with permission requested on first use. When a stream starts on speakers, microphone intent remains negotiated while capture waits for an input route. Connecting a compatible headset midstream activates capture and HUD activity; removing it restores playback-only audio without restarting the stream
- **Favorites** — long-press any game card in Library or Store to add/remove from Favorites; persisted locally
- **Full GFN streaming** — WebRTC-based, up to 4K@60fps depending on your GFN plan (tvOS caps at 60 Hz; 120fps ready for when Apple raises the limit)
- **Controller support** — up to 4 simultaneous MFi/Xbox/PlayStation controllers via the GameController framework; configurable analog stick deadzone (0–30%), rumble multiplier (`0.00×`–`2.00×` in `0.05×` steps), and overlay trigger button (Start/≡ or Options/Back ⊟, default: Start); LB/RB cycles the top-level app tabs in the pre-game menu
- **NVIDIA OAuth login** — device flow; TV shows a QR code and PIN; complete sign-in on any phone, tablet, or computer
- **Pause menu** — left-sidebar in-stream menu with Resume, input mode toggle, Statistics level, Leave Game, and End Session; open with Play/Pause or Menu on the Siri Remote, or hold the overlay trigger button (~2 s) on a controller (default: Start/≡, configurable in Settings)
- **Statistics HUD** — in-stream statistics overlay styled after the official client, with Compact and Standard levels cycled from the pause menu; Compact shows game/stream FPS, RTT, bitrate, packet loss, server location, and microphone state/activity; Standard adds jitter, connection path, resolution, drops/freezes, decoder, jitter-buffer, negotiated audio format, active output route, measured input/output latency, and session detail with live history graphs
- **Keychain persistence** — session tokens stored securely and auto-refreshed on launch
- **tvOS localization** — UI text follows the device language automatically using `Bundle.main.preferredLocalizations` with English fallback; translations live in one file per locale under `CloudNow/Localization`, and every locale table must contain the complete English key set

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

### 4. Run the required checks

Run both lint checks before building or opening a PR:

```bash
swiftformat --lint --config .swiftformat CloudNow
swiftlint --strict --config .swiftlint.yml CloudNow
```

These commands require the exact tool versions pinned by CI: SwiftFormat 0.62.1 and SwiftLint 0.65.0. See [Linting](#linting) for installation and version details.

### 5. Build & Run

Select your Apple TV as the run destination (USB-C or network) and hit **⌘R**.

On first launch the app prompts you to sign in. A QR code and PIN are displayed — scan the QR code or visit the URL on any device and enter the PIN to complete sign-in, then return to the TV.

CloudNow automatically localizes the entire UI to the active tvOS language. No app-side language picker is required for the interface. If a supported locale is unavailable, the app falls back to English.

The game language setting is separate from the app UI language. In Settings, choose `Automatic` if you want CloudNow to send the tvOS language to GeForce NOW, or pick a specific game language manually.

In the main app menu, LB/RB on a connected controller switches between Home, Library, Store, and Settings. Once a stream is open, those shoulder buttons stay with the streaming controller path instead of the menu.

### Supported tvOS languages

CloudNow includes per-locale translation files for the tvOS language set below.

- Arabic (`ar`)
- Catalan (`ca`)
- Chinese Simplified (`zh-Hans`)
- Chinese Traditional Hong Kong (`zh-Hant-HK`)
- Chinese Traditional Macao (`zh-Hant-MO`)
- Chinese Traditional Taiwan (`zh-Hant-TW`)
- Croatian (`hr`)
- Czech (`cs`)
- Danish (`da`)
- Dutch Belgium (`nl-BE`)
- Dutch Netherlands (`nl-NL`)
- English Australia (`en-AU`)
- English Canada (`en-CA`)
- English India (`en-IN`)
- English Ireland (`en-IE`)
- English New Zealand (`en-NZ`)
- English Singapore (`en-SG`)
- English South Africa (`en-ZA`)
- English United Kingdom (`en-GB`)
- English United States (`en-US`)
- Finnish (`fi`)
- French Belgium (`fr-BE`)
- French Canada (`fr-CA`)
- French France (`fr-FR`)
- French Switzerland (`fr-CH`)
- German Austria (`de-AT`)
- German Germany (`de-DE`)
- German Switzerland (`de-CH`)
- Greek (`el`)
- Hebrew (`he`)
- Hindi (`hi`)
- Hungarian (`hu`)
- Indonesian (`id`)
- Italian Italy (`it-IT`)
- Italian Switzerland (`it-CH`)
- Japanese (`ja`)
- Korean (`ko`)
- Malay (`ms`)
- Norwegian Bokmål (`nb`)
- Polish (`pl`)
- Portuguese Brazil (`pt-BR`)
- Portuguese Portugal (`pt-PT`)
- Romanian (`ro`)
- Russian (`ru`)
- Slovak (`sk`)
- Spanish Argentina (`es-AR`)
- Spanish Bolivia (`es-BO`)
- Spanish Chile (`es-CL`)
- Spanish Colombia (`es-CO`)
- Spanish Costa Rica (`es-CR`)
- Spanish Dominican Republic (`es-DO`)
- Spanish Ecuador (`es-EC`)
- Spanish El Salvador (`es-SV`)
- Spanish Guatemala (`es-GT`)
- Spanish Honduras (`es-HN`)
- Spanish Latin America (`es-419`)
- Spanish Mexico (`es-MX`)
- Spanish Nicaragua (`es-NI`)
- Spanish Panama (`es-PA`)
- Spanish Paraguay (`es-PY`)
- Spanish Peru (`es-PE`)
- Spanish Puerto Rico (`es-PR`)
- Spanish Spain (`es-ES`)
- Spanish United States (`es-US`)
- Spanish Uruguay (`es-UY`)
- Spanish Venezuela (`es-VE`)
- Swedish (`sv`)
- Thai (`th`)
- Turkish (`tr`)
- Ukrainian (`uk`)
- Vietnamese (`vi`)

---

## Linting

CloudNow uses SwiftLint and SwiftFormat. CI gates PRs on lint failures.

### Install (one-time)

```bash
brew install swiftlint swiftformat pre-commit
```

### Run locally

Run these checks before every build and before opening a PR:

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

CI and the pre-commit hooks use SwiftLint 0.65.0 and SwiftFormat 0.62.1. Local tools must match these exact versions; newer formatter or linter releases can enable additional rules and produce results that differ from CI. Verify before running the checks:

```bash
swiftformat --version  # expected: 0.62.1
swiftlint version      # expected: 0.65.0
```

When Homebrew provides a newer release, use the pinned pre-commit environments or the same release artifacts referenced in `.github/workflows/lint.yml`.

### Swift concurrency checking

Both Debug and Release targets use complete Swift concurrency checking (`SWIFT_STRICT_CONCURRENCY = complete`) while remaining in Swift 5 language mode. Concurrency-sensitive streaming changes should be built in both configurations before merging.

---

## Architecture

Shared real-time streaming state uses explicit lock or queue ownership, while stale peer, signaling, and data-channel callbacks are rejected by connection identity.

```
CloudNow/
├── PersistenceStore.swift          Actor-serialized Keychain, UserDefaults, JSON, and catalog-cache I/O
├── Auth/
│   ├── AuthManager.swift           @Observable auth state, Keychain persistence
│   └── NVIDIAAuthAPI.swift         OAuth 2.0 PKCE, token refresh, user info
├── Session/
│   ├── SessionState.swift          Models: GameInfo, SessionInfo, StreamSettings, color-mode state
│   ├── CloudMatchClient.swift      Session create/poll/resume/stop, active sessions, audio/color request fields
│   ├── GamesClient.swift           Game catalog via GraphQL persisted query
│   ├── MESClient.swift             Subscription tier + entitled resolutions/FPS from the MES API
│   └── ZoneClient.swift            Dedicated-server list, cancellation-safe ping cache, and queue data
├── Streaming/
│   ├── GFNStreamController.swift   Generation-bound WebRTC lifecycle, reconnect, input, microphone, and audio state
│   ├── SignalingClient.swift        WebSocket signaling with bounded staggered endpoint racing
│   ├── SDPMunger.swift             Codec filtering + bandwidth injection for WebRTC SDP
│   ├── InputSender.swift           GCController/keyboard/mouse/Siri Remote → XInput + GFN protocol (v2/v3) → data channel
│   ├── GFNAudioDevice.swift        Low-latency stereo/5.1 output, deferred Bluetooth capture, route recovery
│   ├── GFNVideoDecoderFactory.swift Advertises H.265 Main10 so the 10-bit payload survives negotiation
│   ├── GFNVideoDecoderH265.swift   VideoToolbox H.265 decoder preserving bit depth + VUI colorimetry
│   ├── ControllerHaptics.swift     Controller rumble output via CoreHaptics
│   └── GFNHapticsDecoder.swift     Decodes GFN rumble packets from the data channel
├── Video/
│   ├── VideoSurfaceView.swift      AVSampleBufferDisplayLayer video surface + decoded-format-aware renderer
│   ├── VideoColorFormat.swift      Local video capability detection + decoded pixel-buffer format inspection
│   ├── VideoPipelineDiagnostics.swift Render/decode pipeline diagnostics
│   └── I420FrameConverter.swift    Software I420 conversion fallback path
├── Localization/
│   ├── AppLocalization.swift       tvOS language selection, tvOS→GFN locale mapping, translation helpers
│   ├── L10nEN.swift                English fallback strings
│   └── L10nXX.swift                One file per supported locale, easy to edit independently
└── UI/
    ├── GamesViewModel.swift        Shared @Observable — games, sessions, favorites, settings
    ├── MainTabView.swift           Root TabView (Home / Library / Store / Settings) with controller tab cycling
    ├── GameFilters.swift           Shared catalog filtering, sorting, filter sheet, and result bar
    ├── HeroArtPrefetcher.swift     Shared downsampling artwork pipeline with bounded LRU caches
    ├── HomeView.swift              Hero banner + Continue Playing + Favorites rows
    ├── LibraryView.swift           LIBRARY panel grid with favorite toggles
    ├── StoreView.swift             MAIN catalog grid with "In Library" badges
    ├── SettingsView.swift          Stream quality pickers + account info + sign out
    ├── LoginView.swift             Sign-in screen with QR code + PIN display
    ├── QueueAdPlayerView.swift     AVPlayer queue-ad playback with CloudMatch lifecycle reporting
    ├── StatsHUDView.swift          Statistics, audio/microphone telemetry, and live history graphs
    └── StreamView.swift            Single-flight session orchestration, full-screen player, and pause menu
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
- **Server location.** Region names and addresses come from NVIDIA's serverInfo endpoint. The manual Servers browser gets queue-depth and location metadata from the PrintedWaste community API, which may lag behind actual queue conditions; ping values are measured locally after opening a city. Dedicated servers pinned by older builds remain selected after upgrading.
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
