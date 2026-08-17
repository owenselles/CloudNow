# CloudNow

A native cloud gaming app for Apple TV. CloudNow keeps GeForce NOW and Xbox
Cloud Gaming in separate provider modes behind one
provider-neutral app shell; each provider retains its own account, catalog,
session, signaling, quality, and input behavior.

![CloudNow Home screen on Apple TV](App%20Store%20Media/Screenshot%201.png)

> **Independent, unofficial client.** This project is not affiliated with,
> endorsed by, or sponsored by NVIDIA or Microsoft. NVIDIA and GeForce NOW are
> trademarks of NVIDIA Corporation. Microsoft, Xbox, and Xbox Cloud Gaming are
> trademarks of the Microsoft group of companies. Current distribution options
> are TestFlight, release IPA, and source builds; no App Store availability is
> claimed.

> **Xbox Cloud Gaming status:** CloudNow's native Xbox mode includes Microsoft QR/PIN sign-in, catalog, session, WebRTC media, controller input, and rumble. Microsoft does not currently list Apple TV as an officially supported Xbox Cloud Gaming client platform, so consumer service changes may break interoperability. No third-party Xbox client code, UI, assets, or dependency is included. See [Xbox Cloud Gaming integration](Documentation/XboxCloudGaming.md).

Provider and service names remain in this documentation where they identify an
integration, sign-in path, protocol, or compatibility requirement. For generic
account, access, quality, library, server, and session concepts, this
documentation follows the neutral terminology established on `main`: **cloud
gaming account**, **cloud library**, **current plan**, **Max Stream Quality**,
**game server**, and **streaming session**.

---

## Community

Join the [CloudNow Community on Discord](https://discord.gg/5d9wDJdtBa) for installation help, troubleshooting, release updates, feature discussion, and contributor chat.

<a href="https://discord.gg/5d9wDJdtBa">
  <img src="https://img.shields.io/badge/Discord-Join%20Us-7289da?style=for-the-badge&logo=discord&logoColor=white" alt="Discord">
</a>

Use [GitHub Issues](https://github.com/owenselles/CloudNow/issues) for tracked bugs and final project decisions. Report security vulnerabilities through [GitHub private vulnerability reporting](https://github.com/owenselles/CloudNow/security/advisories/new), not Discord.

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

### Shared CloudNow experience

- **Separate provider modes** — choose a provider on first launch, keep both
  accounts signed in, and switch from the top-left menu. Home, cloud library,
  settings, launch state, and player state stay provider-scoped.
- **One native app shell** — navigation, focus, dialogs, bounded artwork caches,
  persistence, passive video rendering, controller haptics, session arbitration,
  pause chrome, network testing, and HUD presentation are reusable. Provider
  wire protocols and stream settings are not translated or merged.
- **Safe session ownership** — one global coordinator permits at most one cloud
  server session and one local WebRTC peer. Leave, Continue, End, switching,
  reconnect, and failed deletion paths retain explicit ownership.
- **Fast, bounded catalog UI** — cached rows appear immediately; artwork is
  coalesced, validated, and downsampled through cost-bounded caches; provider
  filters appear only when backed by catalog data.
- **Secure local state** — credentials use provider-separated Keychain records;
  preferences, cache clearing, sign-out, and Reset All Data preserve provider
  boundaries.
- **Native tvOS experience** — focus-engine navigation, controller tab cycling,
  localized UI, Favorites, Continue Playing, pause controls, microphone route
  recovery, and Compact or Standard statistics HUD modes.

### GeForce NOW

- **Established GFN behavior is preserved** — its OAuth, catalog, cloud-library
  refresh, CloudMatch lifecycle, signaling, SDP answer policy, NVST input,
  reconnect, audio, microphone, and settings implementations remain the frozen
  compatibility baseline while Xbox work stays provider-owned.
- **Cloud library and public catalog** — Home, Library, Store, linked-store
  refresh, search, sorting, Favorites, collection/genre/store filters, and
  data-backed RTX, HDR, and Reflex filters.
- **Account-aware stream controls** — up to 4K at 60 fps when the account,
  title, game server, display, and network allow it; resolution, frame rate,
  H.264/H.265/AV1, color mode, keyboard layout, game language, maximum bitrate,
  Low Latency Mode (L4S), and server location controls.
- **Verified media pipeline** — H.265 Main10 and decoded color metadata are
  preserved through VideoToolbox and the renderer; HDR, SDR10, or SDR8 is
  reported from actual decoded buffers instead of inferred from the display.
- **Audio and input** — Automatic, Stereo, and 5.1 Surround stream formats;
  controller, keyboard, mouse, Siri Remote, native text input, rumble, and
  permission-gated microphone capture with route recovery.
- **Queue and lifecycle handling** — live queue position, provisioning timeout,
  required queue-ad playback, resumable Leave, explicit End, bounded endpoint
  racing, single-flight Retry, and reconnect protection against stale work.

### Xbox Cloud Gaming

- **Clean-room native transport** — Microsoft device authorization, Xbox
  Live/XSTS, offering and access discovery, catalog, session allocation, REST
  SDP/ICE signaling, WebRTC media, Xbox data channels, controller input, and
  rumble; no browser, JavaScript runtime, backend, or copied client code.
- **Access-aware Library** — standard, owned, and confirmed ad-supported routes
  remain distinct through launch. Unavailable games stay visible with neutral
  account, access, region, input, time-limit, or service reasons.
- **Production 1440p path** — the validated Microsoft-web compatibility profile
  requests the account's Max Stream Quality. `Best` sends `1440` when that
  ceiling is available (and while optional access metadata is still unknown),
  otherwise `1080`; the service may adapt lower.
- **Honest delivered-media reporting** — Standard HUD shows requested and
  delivered resolution separately, plus delivered bitrate, FPS, codec, color
  format, and audio channels. The validated 1440p route currently uses H.264,
  SDR8, and Opus stereo; Xbox does not expose HEVC, HDR/Main10, or 5.1 controls.
- **Xbox-owned input and resume** — controller, physical keyboard/mouse,
  rumble, reconnect, background Leave, Continue, and End use the negotiated Xbox
  protocol. Simulator keyboard input and Siri Remote click-drag pointer
  emulation are development aids, not physical mouse emulation.
- **Automatic bandwidth policy** — CloudNow sends no Xbox client bitrate cap or
  periodic bitrate-control message. Delivered bitrate remains visible in the
  HUD; unproven controls stay hidden.

### Provider capability summary

| Capability | GeForce NOW | Xbox Cloud Gaming |
|---|---|---|
| Maximum requested resolution | Up to 4K, account/service dependent | `Best` up to 1440p; service may adapt lower |
| Video controls | Resolution, FPS, H.264/H.265/AV1, color mode | Resolution only; service currently selects H.264 |
| Color/HDR | Automatic, HDR, SDR10/SDR8 fallback with decoded-format proof | Automatic only; validated delivery is SDR8 |
| Game audio | Automatic, Stereo, 5.1 Surround | Automatic; current service route is Opus stereo/mono |
| Client bitrate control | Configurable maximum bitrate | None; automatic/uncapped client policy |
| Server selection | Automatic, region, or dedicated game server | Service-selected region |
| Input | Up to four controllers, keyboard/mouse, Siri Remote, text entry | Controller and keyboard/mouse; live controller-slot count unconfirmed; no native text-entry claim |
| Stream truth | Negotiated settings plus decoded delivery | Requested ceiling and delivered media shown separately |

## Requirements

- Apple TV 4K (2nd generation or later) running tvOS 26.2+
- A supported cloud gaming account for the selected provider
- Account, current plan, title, region, and service eligibility for the requested
  stream; Xbox ad-supported preview access is controlled by Microsoft
- **Build from source only:** Xcode 26.2+ on a Mac, Apple Developer account (free tier works)

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
swiftformat --lint --config .swiftformat CloudNow CloudNowTests CloudNowUITests
swiftlint --strict --config .swiftlint.yml CloudNow CloudNowTests CloudNowUITests
```

These commands require the exact tool versions pinned by CI: SwiftFormat 0.62.1 and SwiftLint 0.65.0. See [Linting](#linting) for installation and version details.

### 5. Build & Run

Select your Apple TV as the run destination (USB-C or network) and hit **⌘R**.

Use the shared `CloudNow` scheme for development and final archives. Xbox `Best`
requests the account's Max Stream Quality through the validated Microsoft-web
profile: `1440` when that ceiling is available (and while optional access
metadata is unknown), otherwise `1080`. The service can adapt lower, so the
in-stream HUD distinguishes requested from delivered resolution.

On first launch, choose **GeForce NOW** or **Xbox Cloud Gaming**. CloudNow then shows that provider's QR code and PIN; scan it or visit the displayed URL on another device to complete sign-in, then return to the TV. The two accounts are stored independently, so you can sign into both and use the top-left provider dropdown to move between their separate modes without signing in again.

CloudNow automatically localizes the entire UI to the active tvOS language. No app-side language picker is required for the interface. If a supported locale is unavailable, the app falls back to English.

The game language setting is separate from the app UI language. In Settings,
choose `Automatic` to use the tvOS language for the selected provider, or choose
a specific game language when that provider exposes the control.

In either provider mode, LB/RB on a connected controller moves through the
top-level navigation, including the provider dropdown and that mode's tabs. GFN
uses Home, Library, Store, and Settings; Xbox uses Home, Library, and Settings.
Once a stream is open, those shoulder buttons stay with the active streaming
controller path instead of the app menu.

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
swiftformat --lint --config .swiftformat CloudNow CloudNowTests CloudNowUITests
# Lint check
swiftlint --strict --config .swiftlint.yml CloudNow CloudNowTests CloudNowUITests
# Auto-fix everything fixable
swiftformat --config .swiftformat CloudNow CloudNowTests CloudNowUITests && \
  swiftlint --fix --config .swiftlint.yml CloudNow CloudNowTests CloudNowUITests
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

The app and both test bundles use complete Swift concurrency checking (`SWIFT_STRICT_CONCURRENCY = complete`) while remaining in Swift 5 language mode. Concurrency-sensitive streaming changes should be built in both Debug and Release configurations before merging.

---

## Testing

The automated suite runs without provider credentials, external application
services, or physical Apple TV hardware. It requires Xcode with a compatible
tvOS simulator runtime and `python3` for deterministic simulator discovery.

Run the complete shared test plan from any directory:

```bash
/path/to/CloudNow/Scripts/test.sh
```

From the repository root, focused runs are:

```bash
# Unit and integration tests only
Scripts/test.sh --unit

# UI automation only
Scripts/test.sh --ui

# Explicit full-suite form; equivalent to no argument
Scripts/test.sh --full
```

The runner selects the newest installed tvOS runtime, prefers the newest available Apple TV device generation and native resolution, then breaks ties deterministically by device name and identifier. It boots the selected device when necessary, resolves Swift package dependencies, disables code signing, runs the shared `CloudNow` test plan with coverage enabled, and prints the exact `xcodebuild` commands.

Before launching the simulator, the runner performs a host-side duplicate-key scan of every localization source table. Runtime completeness, placeholder, alias, and fallback behavior remains covered by Swift Testing inside `CloudNowTests`.

Each run writes a timestamped result bundle and compact coverage summaries under:

```text
TestArtifacts/<timestamp>-<mode>/CloudNow-<mode>.xcresult
TestArtifacts/<timestamp>-<mode>/Coverage/targets.txt
TestArtifacts/<timestamp>-<mode>/Coverage/targets.json
TestArtifacts/<timestamp>-<mode>/Coverage/required-sources.txt
TestArtifacts/<timestamp>-<mode>/Coverage/required-sources.json
```

Successful full and unit runs require 100% xccov executable-line coverage for
the shared deterministic capability model, its GFN adapter, and its Xbox
adapter. UI-only runs skip this scoped gate. With the CI toolchain (Xcode 26.6,
Apple Swift 6.3.3), LLVM reports a zero branch denominator for these Swift
sources. The gate therefore measures executable lines only and does not claim
an unavailable branch-coverage percentage; deterministic tests enumerate the
behavioral paths separately.

`TestArtifacts/` is gitignored. Unit and integration tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, and `#require`). XCTest is reserved for `XCUIApplication` UI automation.

Add anonymized JSON, SDP, and binary samples under `CloudNowTests/Fixtures/`,
group them by subsystem, and include them in the `CloudNowTests` target.
Fixtures must not contain credentials, tokens, personal data, or production
endpoint dependencies. Tests must use injected transports and deterministic
fakes; live provider authentication, catalog, signaling, image, media, and
community-service calls are prohibited.

Some behavior remains hardware- or Apple-framework-bound. The nearest automated protection is:

| Excluded behavior | Automated seam |
|---|---|
| Real Apple TV GFN HDR output switching | Synthetic pixel-buffer color inspection and video diagnostics tests |
| Physical controller, keyboard/mouse, focus, and controller-motor output | Provider input encoders, navigation state, responder bridge, and haptics decoder tests |
| AirPods and Continuity Microphone route transitions | Audio-route policy, SDP/session request, and runtime lifecycle coverage; framework route transitions remain manual |
| Actual VideoToolbox hardware decoding | SDP codec/profile tests and synthetic pixel-buffer format inspection |
| Live WebRTC media transport | Session state-machine, signaling codec, endpoint-race, and cancellation tests using fakes |
| Live Xbox Cloud Gaming consumer services | Device-code, Xbox Live/XSTS, offering, catalog, session, REST signaling, WebRTC, input, and teardown tests use injected transports; an entitled Microsoft account on Apple TV remains a manual smoke test |
| Apple TLS and certificate-stack behavior | Transport-independent signaling parsing and endpoint-selection tests |
| Live connected-store → cloud-library synchronization | Injected library-sync contract, retry, timeout, orchestration, persistence, and UI tests; authenticated Apple TV verification remains manual |

---

## Architecture

CloudNow is one app target, not a `CloudGamingCore` framework. Its boundaries are
enforced through narrow provider-neutral contracts, lazy provider graphs, tests,
and a CI manifest that freezes the established GFN production sources. Shared
real-time state has explicit actor, lock, or serial-queue ownership; callbacks
from stale peer, signaling, and data-channel generations are rejected.

### Ownership boundaries

| Layer | Shared/provider-neutral | GeForce NOW-owned | Xbox-owned |
|---|---|---|---|
| App shell | Provider selection, tabs, focus, dialogs, lifecycle | GFN Home/Library/Store/Settings and launch presentation | Xbox Home/Library/Settings and launch presentation |
| Account and storage | Provider registry, Keychain abstraction, scoped reset/cache rules | OAuth state, cloud-library caches, GFN settings | Microsoft OAuth/Xbox Live/XSTS state, Xbox catalog and settings |
| Catalog | Card primitives, artwork pipeline, Favorites presentation | Browse, Store, connected-library refresh, feature filters | Offering/access discovery, route-aware Library, input/access filters |
| Session safety | One-server-session and one-local-peer coordinator | CloudMatch lease and `SessionOrchestrator` | Xbox allocation lease, Leave/Continue/End lifecycle |
| RTC/media primitives | One process-level `CloudRTCRuntime` factory, audio device, passive renderer, decoded-format inspection | Server-offer answer, GFN SDP policy, H.265 decoder policy, NVST media behavior | Client offer/answer, service overrides, Xbox channel/readiness policy |
| Input | Device observation, responder surface, and controller haptics | GFN v2/v3 mapping, input, and text protocol | Xbox mapping, legacy/modern input, channel handshake, feedback, rumble |
| Diagnostics | Neutral HUD snapshots, bounded histories, redaction rules | GFN negotiated/requested media state | Xbox requested ceiling and delivered RTC statistics |

The shared RTC factory is intentionally an implementation primitive, not a
shared protocol layer. GFN remains the WebRTC answerer and keeps its existing
SDP munger, decoder advertisement, audio negotiation, input, and reconnect
behavior. Xbox is the WebRTC offerer and exclusively owns its allocation
identity, REST signaling, data-channel versions, quality bootstrap, input
encoding, reconnect, and resume behavior. Neither provider imports or translates
the other's wire protocol.

### Source layout

```text
CloudNow/
├── CloudNowApp.swift                 Composition root; restores and activates only the selected
│                                     provider while retaining independent account managers
├── PersistenceStore.swift            Actor-backed preferences, activity, credentials,
│                                     provider resets, and scoped file-cache policy
├── AppDataManager.swift               Provider-scoped and app-wide cache maintenance
├── MemoryLifecycleCoordinator.swift  Memory-pressure dispatch and bounded cache cleanup
├── FeatureFlags.swift                 GFN account-scope hashing and compile-time library-sync gate
├── Networking/
│   └── HTTPTransport.swift            Injectable URLSession transport and redacted HTTP errors
├── Services/
│   ├── CloudGamingProvider.swift      Provider identity, persisted selection, switch/reset
│   │                                  coordination, and GFN background-refresh ownership
│   ├── CloudGamingCapabilities.swift  Neutral account/catalog/stream/input/diagnostic contracts;
│   │                                  global server-session and local-peer lease coordinator
│   └── CloudInputDeviceMonitor.swift  Controller and keyboard/mouse availability for presentation
├── Auth/                              Established GFN account path and shared secure storage
│   ├── AuthManager.swift              GFN observable sign-in, refresh, reset, and lifecycle fences
│   ├── NVIDIAAuthAPI.swift            GFN OAuth 2.0 PKCE, token refresh, and user information
│   └── KeychainCredentialStore.swift  Provider-namespaced Keychain persistence and access policy
├── GFN/
│   └── GFNCapabilityAdapter.swift     Maps established GFN behavior into neutral capabilities
├── Session/                           GFN catalog, cloud library, account capability, and session path
│   ├── SessionState.swift             Games, variants, stream settings, color, server, and session models
│   ├── GamesClient.swift              GraphQL catalog and incremental metadata enrichment
│   ├── GameMetadataCache.swift        Locale/VPC-scoped descriptive metadata persistence
│   ├── LibrarySyncClient.swift        Connected-library discovery, sync requests, and progress states
│   ├── MESClient.swift                Account-entitled resolution/FPS and capability discovery
│   ├── ServerInfoClient.swift         GFN-confirmed regions, automatic route, and VPC metadata
│   ├── ZoneClient.swift               Region/server list, queue metadata, and bounded ping cache
│   ├── CloudMatchClient.swift         GFN session create/poll/resume/stop and request fields
│   ├── SessionOrchestrator.swift      Single-flight ownership, Leave/End, cleanup, and retry fencing
│   ├── SessionAttemptState.swift      Generation-safe launch attempt state
│   └── SessionReadinessTracker.swift  Queue/provisioning readiness and setup timeout policy
├── Streaming/                         Frozen GFN wire path plus reusable native media primitives
│   ├── CloudRTCRuntime.swift          One process-level LiveKit WebRTC factory and SSL lifetime
│   ├── GFNStreamController.swift      GFN peer lifecycle, reconnect, input, microphone, and audio state
│   ├── SignalingClient.swift          GFN WebSocket signaling and bounded endpoint racing
│   ├── SignalingEndpointRace.swift    Staggered signaling endpoint selection and cancellation
│   ├── SignalingMessageCodec.swift    Bounded GFN signaling message parsing/encoding
│   ├── SDPMunger.swift                GFN codec filtering, profile ordering, and bandwidth hints
│   ├── InputSender.swift              GFN controller/keyboard/mouse/Siri Remote and text protocol
│   ├── GFNAudioDevice.swift           Shared low-latency playout/capture with stereo/5.1 support
│   ├── CloudAudioSessionCoordinator.swift
│   │                                  Shared permission, route, and microphone-track coordination
│   ├── CloudMicrophoneRoutePolicy.swift
│   │                                  AirPods/Continuity input acquisition and recovery policy
│   ├── BoundedSampleHistory.swift     Fixed-capacity latency/statistics history storage
│   ├── GFNVideoDecoderFactory.swift   GFN decoder advertisement, including H.265 Main10
│   ├── GFNVideoDecoderH265.swift      VideoToolbox H.265 decoder preserving depth/color metadata
│   ├── ControllerHaptics.swift        Shared GameController/CoreHaptics rumble output
│   └── GFNHapticsDecoder.swift        GFN rumble packet decoding
├── Xbox/                              Xbox-owned clean-room account, catalog, and streaming stack
│   ├── MicrosoftDeviceCodeOAuthClient.swift
│   │                                  Microsoft consumer device authorization and refresh
│   ├── XboxAuthManager.swift          Observable Xbox sign-in, reset fences, and credential lifecycle
│   ├── XboxLiveTokenClient.swift      Xbox Live user-token exchange
│   ├── XboxLiveAccountAuthorizationClient.swift
│   │                                  XSTS and account authorization composition
│   ├── XboxLiveAuthorizationModels.swift
│   │                                  Bounded Xbox Live/XSTS request and response models
│   ├── XboxLocalCredentialLifecycleGroup.swift
│   │                                  Clears independent memory-only Xbox credentials as one boundary
│   ├── XboxCloudOfferingService.swift Immutable endpoint/protocol/identity compatibility profile;
│   │                                  offering discovery, validation, and service login
│   ├── XboxContentAccessClient.swift  Optional account access, Max Stream Quality, and product evidence
│   ├── XboxContentAccessStore.swift   Bounded account-access cache and request coalescing
│   ├── XboxFresnoCatalogDiscoveryClient.swift
│   │                                  Credential-free ad-supported catalog discovery
│   ├── XboxCloudCatalogClient.swift   Route-aware Library hydration and playability evidence
│   ├── XboxCloudCatalogDetailLoader.swift
│   │                                  Lazy localized description/artwork/detail enrichment
│   ├── XboxCatalogCache.swift         Bounded process-local account/locale/market catalog snapshots
│   ├── XboxServiceContracts.swift     Catalog, access, route, playability, and UI-facing models
│   ├── XboxCloudSessionAPI.swift      Web-compatible v5 allocation, queue/configuration/keepalive/delete
│   ├── XboxCloudSignalingAPI.swift    Bounded REST local-offer upload and server-answer/ICE polling
│   ├── XboxCloudWebRTCContracts.swift Peer/signaling/channel abstractions and testable transport seams
│   ├── XboxCloudWebRTCTransport.swift Xbox offerer, transceivers, service codec overrides, channels,
│   │                                  media readiness, microphone attachment, and teardown
│   ├── XboxCloudInputDriver.swift     Serial control/message/input bootstrap, controller/keyboard/mouse,
│   │                                  feedback, rumble, dimensions, and reconnect-safe state
│   ├── XboxLegacyInputCodec.swift     Legacy Xbox input/feedback wire encoding
│   ├── XboxModernInputCodec.swift     Modern reliable/unreliable input wire encoding
│   ├── XboxCloudRTCStatsSampler.swift Delivered resolution/FPS/bitrate/codec/audio RTC statistics
│   ├── XboxCloudStreamController.swift
│   │                                  Allocation, launch, media state, reconnect, Leave/Continue/End
│   ├── XboxCloudStreamLifecycle.swift Runtime/session interfaces and production native runtime
│   ├── XboxProductionRuntimeContext.swift
│   │                                  Lazy Xbox dependency graph and app lifecycle integration
│   ├── XboxCloudStreamSettings.swift  Xbox-only resolution, language, controller, accessibility,
│   │                                  microphone, HUD, and diagnostic preferences
│   ├── XboxCapabilityAdapter.swift    Honest Xbox capability and presentation mapping
│   ├── XboxCloudRTCEventLog.swift     Bounded, allowlisted, redacted local RTC lifecycle log
│   └── XboxCloudInstallationIdentityStore.swift
│                                      Resettable non-secret SDK installation identity
├── Video/
│   ├── VideoSurfaceView.swift         Passive AVSampleBufferDisplayLayer renderer and remote-touch input
│   ├── VideoColorFormat.swift         Display capability and decoded pixel-buffer format inspection
│   ├── VideoPipelineDiagnostics.swift Render/decode path diagnostics
│   └── I420FrameConverter.swift       Software I420 conversion fallback
├── UI/
│   ├── CloudServiceSelectionView.swift Equal provider choice on fresh install/reset
│   ├── CloudNowTabShell.swift         Provider menu, focus restoration, and safe switch workflow
│   ├── CloudCatalogViews.swift        Reusable card/grid/filter presentation primitives
│   ├── CloudNowDeviceCodeView.swift   Shared QR/PIN sign-in presentation
│   ├── CloudStreamChrome.swift        Shared launch states and pause-menu presentation
│   ├── CloudNetworkTestView.swift     Shared ping/jitter/loss presentation
│   ├── CloudAppLifecycleModifier.swift
│   │                                  Shared app lifecycle and memory-pressure policy
│   ├── StatsHUDView.swift             Neutral requested/delivered media and history presentation
│   ├── HeroArtPrefetcher.swift        Shared coalescing/downsampling artwork pipeline
│   ├── GameCarouselView.swift         Shared carousel engine with provider-supplied cards
│   ├── UIControllerNavigationCoordinator.swift
│   │                                  Exclusive controller ownership for app navigation
│   ├── MainTabView.swift              Established GFN Home/Library/Store/Settings root
│   ├── GamesViewModel.swift           GFN games, sessions, Favorites, settings, and cloud-library import
│   ├── HomeView.swift                 GFN hero, Continue Playing, and Favorites
│   ├── LibraryView.swift              GFN cloud-library grid and favorite actions
│   ├── StoreView.swift                GFN public catalog and cloud-library badges
│   ├── GameFilters.swift              GFN sorting and collection/genre/store/feature filters
│   ├── SettingsView.swift             GFN account, stream, input, server, diagnostic, and reset controls
│   ├── StreamView.swift               GFN session orchestration, player, pause, Leave, and End
│   ├── XboxCloudViews.swift           Xbox Home/Library/Settings, catalog model, filters, and launch flow
│   ├── XboxCatalogDetailView.swift    Xbox detail/access/input presentation
│   ├── XboxCloudPlayerView.swift      Xbox full-screen player, HUD, pause, lifecycle, and session lease
│   └── XboxVideoSurfaceView.swift     Xbox surface adapter and Simulator keyboard/pointer bridge
└── Localization/
    ├── AppLocalization.swift          tvOS locale/lookup, shared labels, and GFN language mapping
    ├── L10nEN.swift                   English source/fallback table
    └── L10nXX.swift                   Complete provider-neutral values for every supported locale
```

Xbox's catalog, session, and transport service graph is constructed lazily when
Xbox is selected. Its lightweight account manager, capability adapter, and
production context can remain resident without activating Xbox catalog/session
network work during a GFN-only run. Switching providers preserves independent
credentials and settings while the global coordinator prevents two cloud
sessions or peers from becoming active.
The detailed Xbox boundary and wire path are documented in
[Xbox Cloud Gaming integration](Documentation/XboxCloudGaming.md).

### GFN cloud-library metadata cache

Library browse results remain the source of truth for dynamic fields such as ownership, variants, and supported features. Only enriched descriptive fields are persisted, then overlaid without replacing newer browse data. A second unchanged Library refresh therefore makes no metadata-enrichment request; missing or expired app IDs are fetched in bounded batches.

Library ownership is keyed by a SHA-256 account identifier. The descriptive
catalog remains ownership-neutral and shared by locale and VPC, with only the
current account's authoritative cloud library overlaid in memory. A full refresh
atomically replaces that account's library and updates the independent catalog
cache only when fresh catalog data is available, preserving the last-known-good
Store cache after transient failures. Legacy unscoped ownership caches are
treated as misses so signing into another account cannot expose the previous
account's library.

| Rule | Behavior |
|------|----------|
| Scope | Separate cache for each NVIDIA locale and VPC |
| Enriched metadata freshness | 24 hours |
| Missing-record tombstone | 1 hour, preventing immediate repeat requests |
| Failed refresh fallback | Retain stale metadata for up to 30 days without advancing its timestamp |
| Storage bound | Keep the newest 2,000 records per locale/VPC scope |
| Manual invalidation | Settings → Clear Cache removes catalog and metadata cache files |

### Provider protocol ownership

Both native transports use
[livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework), but
their account, session, signaling, SDP, input, and lifecycle protocols remain
independent.

| Layer | GeForce NOW | Xbox Cloud Gaming |
|---|---|---|
| Account | OAuth 2.0 PKCE and refresh-token lifecycle | Microsoft device authorization, Xbox Live, and XSTS |
| Catalog/access | GFN GraphQL catalog, cloud library, connected-store sync, account capabilities | Xbox offering and access discovery, authenticated/ad-supported routes, public product metadata |
| Session | CloudMatch create, poll, resume, and stop | Xbox v5 allocation, queue/provisioning, configuration, keepalive, and delete |
| Signaling | WebSocket endpoint race; receives server offer and returns SDP answer/ICE | REST signaling; creates local offer and applies service answer/ICE |
| Quality | GFN session request plus provider-owned SDP answer policy | Microsoft resolution alias, display-dimensions message, and validated service overrides |
| Input | GFN v2/v3 XInput, keyboard/mouse, text, and haptics data channels | Xbox legacy/modern input, controller/keyboard/mouse reports, feedback, and rumble |
| Resume/reconnect | GFN controller and `SessionOrchestrator` | Xbox controller retaining one unexpired allocation |

---

## GFN Color and HDR Notes

CloudNow does **not** treat a stream as HDR merely because:

- the stream is 10-bit
- the connected display supports HDR
- tvOS is currently outputting HDR or Dolby Vision
- the user selected an HDR-related setting

The GFN path uses three separate pieces of information:

1. **What to request** — based on user preference and local capabilities
2. **What the server negotiated** — based on session and signaling state
3. **What is actually being rendered** — based on decoded video metadata from the real pixel buffer

This means a GFN HDR request can legitimately fall back to SDR10 or SDR8, and
the app reports that instead of falsely claiming HDR is active. Xbox currently
has no HDR/Main10 control: its HUD reports the color format detected from the
delivered stream, and the validated 1440p route delivered SDR8.

---

## Known Limitations

- **Unofficial provider integrations.** CloudNow is not an official client for
  either service. Provider APIs and consumer-service behavior can change without
  notice. TestFlight and sideloaded builds do not make Apple TV a supported Xbox
  Cloud Gaming platform.
- **Xbox 1440p remains adaptive.** A controlled tvOS Simulator A/B proved the
  Microsoft-web profile can sustain 2560×1440, but account, current plan, title,
  region, display, network, and service policy still decide delivery. Physical
  Apple TV validation remains required for each release.
- **Xbox media controls are intentionally narrow.** The validated route delivered
  H.264, SDR8, and Opus stereo. CloudNow does not expose Xbox HEVC, HDR/Main10,
  5.1, manual bitrate, L4S, or manual-region controls without service and
  delivered-media proof.
- **Xbox title metadata has no authoritative cloud A/V capabilities.** Store
  badges are not treated as proof of 1440p, HDR, or surround delivery. The app
  shows observed session values rather than inventing Library filters.
- **Simulator pointer input is limited.** The Xbox development bridge converts a
  Siri Remote-style indirect click-drag gesture into relative mouse movement and
  a left-button report. tvOS Simulator does not provide normal captured hover or
  wheel input; physical keyboard/mouse validation uses GameController devices.
- **Provider library refresh uses undocumented services.** The live GFN web
  contract may change. CloudNow fails closed to the neutral **Reload Library**
  path when discovery or schema validation fails, reports categorical progress,
  and synchronizes only accounts already linked through the provider.
- **Queue ad playback.** During high demand the GFN service can require ads while
  in queue. CloudNow plays them with AVPlayer and reports lifecycle events back
  to CloudMatch.
- **Server location.** Region names and addresses come from NVIDIA's serverInfo endpoint. The manual Servers browser gets queue-depth and location metadata from the PrintedWaste community API, which may lag behind actual queue conditions; ping values are measured locally after opening a city. Dedicated servers pinned by older builds remain selected after upgrading.
- **HDR depends on the full pipeline.** A selected HDR-capable mode does not guarantee the server will deliver HDR, and a 10-bit stream is not automatically HDR.
- **AV1 currently uses the software I420 path.** On the current implementation this falls back to SDR 8-bit BT.709 rather than preserving SDR10 or HDR metadata.
- **Color diagnostics are only as good as decoded metadata.** If the decoder or software conversion path strips metadata, CloudNow will conservatively report fallback or unknown modes instead of guessing.
- **Diagnostic export is unavailable on tvOS.** Supported local share, activity,
  and document-export APIs are unavailable, so bounded local logs can be cleared
  but are not advertised as exportable.

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
