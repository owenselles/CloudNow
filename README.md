# CloudNow

CloudNow is a native cloud gaming app for Apple TV. GeForce NOW and Xbox Cloud
Gaming run as separate provider modes behind one tvOS interface. Each provider
keeps its own account, catalog, settings, session, signaling, quality, and input
behavior.

![CloudNow Home screen on Apple TV](App%20Store%20Media/Screenshot%201.png)

> **Independent, unofficial client.** This project is not affiliated with,
> endorsed by, or sponsored by NVIDIA or Microsoft. NVIDIA and GeForce NOW are
> trademarks of NVIDIA Corporation. Microsoft, Xbox, and Xbox Cloud Gaming are
> trademarks of the Microsoft group of companies. CloudNow is distributed
> through TestFlight, release IPA files, and source builds. It is not available
> from the App Store.

> **Xbox Cloud Gaming status.** CloudNow includes native Microsoft QR/PIN sign-in,
> catalog access, session handling, WebRTC media, controller input, and rumble.
> Microsoft does not list Apple TV as an officially supported Xbox Cloud Gaming
> platform, so service changes may affect compatibility. See the
> [Xbox Cloud Gaming integration](Documentation/XboxCloudGaming.md).

## Community

Join the [CloudNow Community on Discord](https://discord.gg/5d9wDJdtBa) for
installation help, troubleshooting, release updates, feature discussion, and
contributor chat.

<a href="https://discord.gg/5d9wDJdtBa">
  <img src="https://img.shields.io/badge/Discord-Join%20Us-7289da?style=for-the-badge&logo=discord&logoColor=white" alt="Discord">
</a>

Use [GitHub Issues](https://github.com/owenselles/CloudNow/issues) for tracked
bugs and project decisions. Report security vulnerabilities through
[GitHub private vulnerability reporting](https://github.com/owenselles/CloudNow/security/advisories/new),
not Discord.

## Installation

### Option A: TestFlight

Join the public beta without sideloading or Xcode:

**[Join TestFlight Beta](https://testflight.apple.com/join/hfm795kG)**

### Option B: Pre-built IPA

Download the latest `CloudNow.ipa` from
[Releases](https://github.com/owenselles/CloudNow/releases), then sideload it
with [Sideloadly](https://sideloadly.io) or AltServer. Sideloadly can sign the IPA
with a free Apple ID.

### Option C: Build from source

Follow the [development guide](Documentation/Development.md) for project setup,
signing, dependency resolution, and local checks.

## Features

### Shared CloudNow experience

- Choose a provider on first launch and switch from the top-left menu. Accounts,
  catalogs, preferences, provider-owned caches, launch state, and player state
  stay scoped to their provider.
- Navigate a native tvOS interface with focus-engine support, controller tab
  cycling, localized text, Favorites, Continue Playing, pause controls, and
  Compact or Standard statistics HUD modes.
- Load cached catalog rows immediately while bounded artwork and metadata caches
  refresh in the background.
- Keep credentials in provider-separated Keychain records. Cache clearing,
  sign-out, and Reset All Data preserve provider boundaries.
- Run at most one cloud server session and one local WebRTC peer. Leave,
  Continue, End, switching, reconnect, and failed cleanup paths keep explicit
  session ownership.

### GeForce NOW

- Browse the public catalog and cloud library, refresh linked stores, search,
  sort, filter, favorite games, and resume recent sessions.
- Configure account-aware resolution and frame rate, H.264/H.265/AV1, color mode,
  audio, language, maximum bitrate, Low Latency Mode (L4S), and server location.
- Use controller, keyboard, mouse, Siri Remote, native text input, rumble, and an
  optional permission-gated microphone.
- Connect through NVIDIA or supported regional partners. Provider routing,
  queues, reconnect, and session lifecycle remain owned by the GFN integration.

See the [GeForce NOW integration](Documentation/GeForceNOW.md) and
[streaming settings guide](Documentation/StreamingSettings.md) for detailed
behavior and limitations.

### Xbox Cloud Gaming

- Sign in through Microsoft's device authorization flow, then use native catalog,
  session, WebRTC, input, and rumble implementations without a browser or
  JavaScript runtime.
- Use Home and Library for service-confirmed playable routes. Browse retains the
  validated catalog and explains unavailable account, region, input, time-limit,
  and service routes.
- Let Automatic request the account's Max Stream Quality. Eligible accounts can
  request up to 1440p, while the service may adapt delivery lower.
- Compare requested and delivered resolution in the Standard HUD alongside
  delivered bitrate, FPS, codec, color format, and audio channels.

See the [Xbox Cloud Gaming integration](Documentation/XboxCloudGaming.md) for
compatibility and protocol details.

### Provider capability summary

| Capability | GeForce NOW | Xbox Cloud Gaming |
|---|---|---|
| Maximum requested resolution | Up to 5K, subject to account and service eligibility | Automatic up to 1440p; service may adapt lower |
| Video controls | Resolution, FPS, H.264/H.265/AV1, color mode | Resolution only; service selects the codec |
| Color and HDR | Automatic, HDR, SDR10, and SDR8 fallback | Automatic only; current validated delivery is SDR8 |
| Game audio | Automatic, Stereo, and 5.1 Surround | Automatic; current service route is Opus stereo or mono |
| Client bitrate control | Configurable maximum bitrate | None; service-managed bandwidth |
| Server selection | Automatic, region, or dedicated game server | Service-selected region |
| Input | Up to four controllers, keyboard/mouse, Siri Remote, and text entry | Controller and keyboard/mouse; native text entry is not claimed |
| Stream reporting | Requested or negotiated settings plus decoded delivery | Requested ceiling and delivered media shown separately |

## Requirements

- Apple TV 4K (2nd generation or later) running tvOS 26.2 or newer.
- A supported cloud gaming account for the selected provider.
- Account, plan, title, region, and service eligibility for the requested stream.
- Xcode 26.2 or newer for source builds.
- An Apple Developer account for physical-device builds.

## Getting started

On first launch, choose GeForce NOW or Xbox Cloud Gaming. CloudNow displays the
selected provider's QR code and PIN. Scan the code or open the displayed URL on
another device, finish sign-in, then return to Apple TV.

Provider accounts are stored independently. You can sign in to both and switch
between their separate modes without signing in again. GFN has Home, Library,
Store, and Settings. Xbox has Home, Library, Browse, and Settings.

CloudNow follows the active tvOS language and falls back to English when a locale
is unavailable. Game language is a separate streaming preference. See
[Using CloudNow](Documentation/UsingCloudNow.md) for navigation, language
support, provider switching, and help paths.

## Documentation

The README is the index for public project documentation. Each guide owns the
facts in its stated area so provider behavior and contributor instructions are
not copied between files.

### Use CloudNow

- [Using CloudNow](Documentation/UsingCloudNow.md): sign-in, provider switching,
  navigation, languages, cache controls, and support.
- [Streaming settings](Documentation/StreamingSettings.md): defaults, eligibility,
  provider differences, requested versus delivered quality, and troubleshooting.

### Provider references

- [GeForce NOW integration](Documentation/GeForceNOW.md): account, catalog,
  library, session, routing, media, cache, and compatibility behavior.
- [Xbox Cloud Gaming integration](Documentation/XboxCloudGaming.md): clean-room
  boundaries, product flow, compatibility profile, request path, and current
  service behavior.

### Build and contribute

- [Contributing](CONTRIBUTING.md): issue, pull request, and review expectations.
- [Development](Documentation/Development.md): source setup, signing, tools,
  testing, fixtures, coverage, and concurrency checks.
- [Architecture](Documentation/Architecture.md): shared ownership, provider
  boundaries, lifecycle, caching, and performance invariants.

### Maintain releases

- [Release validation](Documentation/ReleaseValidation.md): automated gates,
  physical Apple TV checks, provider smoke tests, and evidence recording.

## Linting

CloudNow uses SwiftLint and SwiftFormat. CI gates pull requests on failures.
Run both non-mutating checks before building or opening a pull request:

```bash
swiftformat --lint --config .swiftformat CloudNow CloudNowTests CloudNowUITests
swiftlint --strict --config .swiftlint.yml CloudNow CloudNowTests CloudNowUITests
```

CI and pre-commit hooks use these exact versions:

- SwiftFormat 0.62.1
- SwiftLint 0.65.0

Verify local tools before running the checks:

```bash
swiftformat --version  # expected: 0.62.1
swiftlint version      # expected: 0.65.0
```

If Homebrew provides a different version, use the pinned pre-commit environment
or the release artifacts referenced by `.github/workflows/lint.yml`. Installation,
auto-fix, and hook instructions are in the
[development guide](Documentation/Development.md#linting-and-formatting).

## Testing

Run the complete shared test plan from the repository root:

```bash
Scripts/test.sh --full
```

Focused runs use `--unit` or `--ui`. The runner selects a compatible tvOS
simulator, disables code signing, enables coverage, and stores results under
`TestArtifacts/`. See [Development](Documentation/Development.md#testing) for
test modes, coverage gates, fixtures, and hardware-bound exclusions.

## Architecture

CloudNow uses one app target with narrow provider-neutral contracts. Shared code
owns app navigation, storage boundaries, session arbitration, reusable media
primitives, artwork, and diagnostics. Each provider owns its account, catalog,
stream settings, session, signaling, input protocol, reconnect, and resume logic.
The providers do not import or translate one another's wire protocols.

See [Architecture](Documentation/Architecture.md) for the stable subsystem map
and [Release validation](Documentation/ReleaseValidation.md) for regression proof.

## Known limitations

- CloudNow uses unofficial provider integrations. Provider APIs and consumer
  services can change without notice.
- Microsoft does not list Apple TV as a supported Xbox Cloud Gaming platform.
  Xbox quality remains adaptive, even when CloudNow requests 1440p.
- GFN HDR, resolution, frame rate, and audio depend on the complete account,
  service, decoder, display, and network path. Selecting a preference does not
  guarantee that delivered mode.
- Some input, microphone, HDR, decoder, and live-service behavior requires
  physical Apple TV validation and cannot be proven by simulator tests alone.
- tvOS does not provide the local share and document-export surfaces used by the
  current diagnostics design, so diagnostic logs can be cleared but not exported.

Provider-specific limitations and fallback behavior are documented in
[Streaming settings](Documentation/StreamingSettings.md),
[GeForce NOW](Documentation/GeForceNOW.md), and
[Xbox Cloud Gaming](Documentation/XboxCloudGaming.md).

## Contributing

Pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before starting
work, and run the canonical lint and test commands above before requesting review.

## Sponsoring

If CloudNow is useful to you, consider sponsoring its maintenance.

[![GitHub Sponsors](https://img.shields.io/badge/Sponsor%20on%20GitHub-%E2%9D%A4-pink?style=flat-square&logo=github)](https://github.com/sponsors/owenselles)

## License

MIT. See [LICENSE](LICENSE).

## Acknowledgements

- [PrintedWaste](https://printedwaste.com) provides community GFN zone queue
  depths and region mapping.
- [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework)
  provides WebRTC for Apple platforms.
