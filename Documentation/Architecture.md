# Architecture

CloudNow is one tvOS app target with separate GeForce NOW and Xbox Cloud Gaming
provider modes. Provider-neutral contracts let the app shell present either mode
without merging their accounts, catalogs, settings, sessions, or wire protocols.

Related documentation:

- [GeForce NOW integration](GeForceNOW.md)
- [Xbox Cloud Gaming integration](XboxCloudGaming.md)
- [Development](Development.md)
- [Release validation](ReleaseValidation.md)

## Solution overview

```text
CloudNow tvOS app
├── Shared app shell
│   ├── Provider selection, navigation, focus, and lifecycle
│   ├── Provider-scoped persistence, credentials, data, and reset rules
│   ├── Global server-session and local-peer ownership
│   ├── Artwork, localization, diagnostics, and statistics HUD
│   └── Native RTC, audio, microphone routing, video surface, and haptics
├── GeForce NOW provider
│   ├── OAuth account and partner routing
│   ├── Public catalog, connected cloud library, and metadata cache
│   ├── CloudMatch session allocation, queue, resume, and stop
│   └── Server-offer signaling, GFN media policy, input, and reconnect
├── Xbox Cloud Gaming provider
│   ├── Microsoft OAuth, Xbox Live, XSTS, offering, and account access
│   ├── Route-aware catalog, playable Library, and full Browse catalog
│   ├── Xbox session allocation, queue, resume, keepalive, and delete
│   └── REST signaling, local offer, Xbox data channels, input, and reconnect
└── Verification and maintenance
    ├── Deterministic unit and integration tests with injected transports
    ├── Network-free tvOS UI automation
    ├── Physical Apple TV and live-provider release validation
    └── Lint, localization, coverage, release, and community scripts
```

Shared components provide infrastructure and presentation contracts. Provider
branches own service behavior from account authorization through stream teardown.
The global session coordinator is the only bridge that arbitrates active server
and peer ownership between them.

## Ownership boundaries

The app shares infrastructure only where the behavior is genuinely independent of
a provider. Each provider keeps control of its authentication, service requests,
stream negotiation, input protocol, and session lifecycle.

| Layer | Shared ownership | GeForce NOW ownership | Xbox ownership |
|---|---|---|---|
| App shell | Provider selection, tabs, focus, dialogs, app lifecycle, and safe switching | Home, Library, Store, Settings, and GFN launch presentation | Home, Library, Browse, Settings, and Xbox launch presentation |
| Account and storage | Provider registry, Keychain abstraction, scoped reset rules, and app-wide cache maintenance | OAuth state, account-scoped cloud library, catalog metadata, and GFN settings | Microsoft OAuth, Xbox Live and XSTS state, Xbox catalog, and Xbox settings |
| Catalog | Card, artwork, Favorites, and filter presentation primitives | Public catalog, connected cloud library, metadata enrichment, and GFN filters | Offering and access discovery, playable Library projection, full Browse projection, and route-correlated filters |
| Session safety | One server-session lease and one local-peer lease for the process | CloudMatch allocation and `SessionOrchestrator` | Xbox allocation and Leave, Continue, and End behavior |
| RTC and media | One process-level RTC factory, audio device, passive video surface, decoded-format inspection, and microphone route coordination | Server offer, SDP answer policy, GFN codecs, and NVST behavior | Local offer, REST signaling, service codec overrides, and Xbox channel readiness |
| Input | Device observation, responder surfaces, and controller haptics output | GFN controller, keyboard, mouse, remote pointer, and text protocols | Xbox controller, keyboard, mouse, feedback, and rumble protocols |
| Diagnostics | Requested and delivered media snapshots, bounded histories, redaction, network test UI, and HUD presentation | GFN negotiation and server statistics | Xbox resolution ceiling and delivered RTC statistics |

Provider adapters map provider-owned state into narrow shared capability values.
They do not import one another or translate one provider's protocol into the
other's protocol.

## Source layout

The directory map describes ownership without trying to list every source file.
The repository is the source of truth for the exact file inventory.

| Path | Responsibility |
|---|---|
| `CloudNow/` | Composition root, persistence, data reset, cache maintenance, and memory lifecycle coordination |
| `CloudNow/Services/` | Provider identity, capability contracts, provider switching, global session leases, and input-device observation |
| `CloudNow/Auth/` | GeForce NOW account flow and provider-namespaced secure credential storage |
| `CloudNow/GFN/` | Adapter from established GeForce NOW behavior to shared capabilities |
| `CloudNow/Session/` | GeForce NOW catalog, cloud library, server discovery, CloudMatch, and session ownership |
| `CloudNow/Streaming/` | GeForce NOW signaling, media, audio, input, haptics, and shared native RTC primitives |
| `CloudNow/Xbox/` | Xbox account, catalog, access, session, signaling, input, settings, diagnostics, and lazy production graph |
| `CloudNow/UI/` | Shared app surfaces plus provider-owned navigation, catalog, settings, launch, and player views |
| `CloudNow/Video/` | Passive renderer, latest-frame mailbox, decoded color inspection, and render diagnostics |
| `CloudNow/Networking/` | Injectable HTTP transport and redacted transport errors |
| `CloudNow/Localization/` | Locale selection, English fallback, and per-locale strings |
| `CloudNowTests/` | Deterministic unit and integration coverage using injected transports and fakes |
| `CloudNowUITests/` | Network-free tvOS UI journeys |
| `Scripts/` | Test runner, release support, and local community automation |

## Provider activation and session ownership

The composition root restores the selected provider and activates only that mode.
Lightweight account managers and capability adapters may stay resident. Heavy
catalog, session, and transport work must remain lazy, and an inactive provider
must not start network work.

`CloudSessionCoordinator` owns the process-wide server-session and local-peer
leases. At most one provider may hold each lease. A switch from an active session
must resolve that session through Leave or End before the other provider starts.
If a provider cannot confirm server deletion, its lease remains quarantined. The
app must not assume that a second server session is safe.

Provider switches, account resets, launch attempts, reconnects, and cache clears
use cancellation and generation checks. Work from an older generation cannot
publish state after a switch, retry, sign-out, teardown, or reset. Peer,
signaling, renderer, data-channel, input, and statistics callbacks also verify
that they still belong to the active connection.

## Concurrency and state publication

CloudNow uses complete Swift concurrency checking while remaining in Swift 5
language mode. Ownership follows the workload:

- SwiftUI state and presentation changes run on the main actor.
- Preferences, UserDefaults, and Keychain work owned by `AppPersistenceStore` is
  serialized away from the UI actor.
- Provider-owned disk caches and logs use their own actors or serial owners.
- Catalog caches and decoded-artwork caches use actors.
- High-frequency input, media, haptics, and statistics state uses a dedicated
  serial queue or an explicit lock.
- Observed diagnostics are published as coherent snapshots instead of a series of
  field updates.
- Cancellation handlers release waiters and resources without running callbacks
  while a lock is held.

New shared state needs one documented owner. Adding an unchecked isolation escape
or moving high-frequency work onto the main actor requires a measured reason and
targeted regression coverage.

## Cache and reset boundaries

Persistent provider data is scoped before it is accepted:

- GeForce NOW library ownership is account-scoped. Catalog and enriched metadata
  are scoped by the provider routing context and locale.
- Xbox catalog snapshots are scoped by account, locale, and market.
- Credentials, settings, activity, and reset generations remain provider-owned.
- Shared decoded artwork and `URLCache` entries do not carry provider ownership.

A provider-specific Clear Cache removes only data that can be attributed to that
provider. App-wide cache maintenance may also evict shared artwork and URL data.
Reset and cache-clear generations prevent older in-flight work from recreating
data after it has been removed.

Catalog snapshots may provide a bounded last-known view while a refresh runs.
Failed refreshes retain a usable last-good snapshot and mark it stale. They do not
replace it with an empty result or advance freshness timestamps. See the provider
documents for provider-specific cache rules.

## Performance invariants

The implementation work recorded in [performance issue #66](https://github.com/owenselles/CloudNow/issues/66)
is part of the architecture. Changes to shared UI, persistence, media, networking,
or lifecycle code must preserve these properties:

- `App Store Media/` stays outside app target membership and the release bundle.
- Cached catalog and account state can appear before background refresh finishes.
  Independent startup requests run concurrently, while duplicate work such as VPC
  resolution and active-session lookup is coalesced.
- Catalog search, filtering, sorting, and option derivation are cached or computed
  away from SwiftUI body evaluation. Large rows remain lazy or paged.
- Artwork requests share one pipeline. Identical requests are coalesced, images
  are downsampled before decode, and decoded caches have fixed cost and count
  limits. Streaming, backgrounding, and memory warnings cancel prefetch work and
  reduce cache ownership.
- Persistence and catalog decoding stay off the main actor. Only the selected
  localization table and the English fallback are materialized during normal use.
- Input-latency histories and similar diagnostics use bounded storage and remain
  disabled when no visible HUD or diagnostic consumer needs them.
- Video presentation uses latest-frame backpressure, cached format inspection,
  and bounded teardown. The H.265 path avoids the former per-NAL copy chain while
  preserving parameter sets and color metadata.
- Launch and reconnect work is single-flight, cancellable, and generation-bound.
  Signaling races and zone probes have fixed concurrency limits, and losing work
  is cancelled.
- Each process has one native RTC runtime and no second provider-specific media
  framework. Inactive providers do not retain an active peer or transport graph.

Performance changes need before-and-after measurements on the same device and
configuration. A lower local cost is not sufficient if it weakens cancellation,
cache scoping, decoded-media truth, or provider isolation.

## Adding shared behavior

Add behavior to the shared layer only when both provider modes need the same
semantics. A shared protocol should describe the smallest value or operation the
app shell consumes. Provider credentials, endpoints, request bodies, protocol
versions, and fallback rules stay behind the provider boundary.

Changes that touch both modes should include deterministic coverage for provider
selection, account isolation, session leases, stale callback rejection, and the
inactive-provider no-network rule. Physical checks belong in
[Release validation](ReleaseValidation.md).
