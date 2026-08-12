# Xbox Cloud Gaming integration

## Status

CloudNow contains an experimental, native Xbox Cloud Gaming mode alongside its
existing GeForce NOW mode. Xbox is no longer a placeholder or a browser wrapper:
the app performs Microsoft device-code sign-in, Xbox Live/XSTS authorization,
catalog discovery, session allocation, REST signaling, WebRTC media, controller
input, and rumble using independently authored Swift.

Technical interoperability is not the same as official platform support.
Microsoft does not currently document Apple TV as a supported Xbox Cloud Gaming
client platform, and its consumer web-service contracts can change. CloudNow
therefore validates every response, bounds every poll and payload, redacts
credentials, fails closed, and keeps provider-specific failures contained inside
Xbox mode. No Microsoft client secret is embedded and no CloudNow backend is
required by the current public-client flow.

## Clean-room rule

The Xbox implementation is independently authored. No Stratix source code, UI,
assets, tests, fixtures, identifiers, credentials, constants, endpoint lists,
protocol captures, binaries, dependencies, or patches are used. No third-party
Xbox client implementation is a source dependency or implementation reference.

Permitted inputs are:

- Existing CloudNow components, performance work, and visual conventions.
- Microsoft first-party public documentation and publicly delivered Xbox web
  application behavior.
- Apple platform documentation and the WebRTC runtime already used by CloudNow.

The two providers share CloudNow infrastructure where it is genuinely generic;
they do not share or translate wire protocols.

Xbox production wire values are owned by one immutable, versioned compatibility
profile. It validates Microsoft endpoint hosts and paths, offering order,
Content Access offerings and plan-product mappings, SDP version ranges, and
data-channel descriptors before the Xbox runtime is exposed. If validation
fails, the app keeps GeForce NOW available and disables Xbox streaming with a
localized compatibility explanation.

## Product flow

1. A fresh install shows two equal CloudNow choices: GeForce NOW and Xbox Cloud
   Gaming.
2. Selecting Xbox opens CloudNow's native QR/PIN Microsoft device-code screen.
   The QR code prefers Microsoft's complete verification URL and otherwise
   pre-fills the code only for the exact secure Microsoft consumer link; the
   visible PIN remains the fallback. Completing Microsoft OAuth is followed by
   Xbox Live and XSTS authorization.
3. GeForce NOW and Xbox keep independent credential records. Signing into or
   switching away from one does not sign the other account out.
4. After sign-in, Xbox presents Home, Library, and Settings while GeForce NOW
   retains its existing Home, Library, Store, Settings, launch flow, and player.
5. Xbox Home contains only Continue Playing, Recently Played, and Favorites when
   those sections have content. Library contains the unified catalog and shows
   only data-backed filters. Unavailable titles remain visible with a localized
   account, access, region, input, time-limit, or service reason. Confirmed
   ad-supported routes remain ordinary playable items with an Ads badge;
   Microsoft owns any advertising experience.
6. A top-left provider dropdown switches between the two modes. There is no
   merged home screen, catalog, settings form, or provider-branded borrowed UI.
7. A global coordinator permits one cloud-server session and one local WebRTC
   peer. Switching with an active session offers Leave or End; a parked session
   must be ended before the other provider can start. A failed server deletion
   keeps the lease quarantined instead of silently allowing a second session.
8. Xbox Play allocates one session, shows shared queue/provisioning/connection
   states, then presents video in CloudNow's full-screen player. Leave retains a
   resumable allocation only until its service expiry. Continue reuses that
   allocation; explicit End deletes it and performs local teardown.

## Architecture

The root `CloudGamingProviderCoordinator` persists only the selected provider and
exposes the matching provider configuration. `CloudGamingCore`-style contracts in
the app target describe narrow account, catalog, stream-option, input,
microphone, resume, reconnect, and diagnostics capabilities. Provider adapters
consume those contracts without importing one another. GeForce NOW behavior is
preserved behind an adapter; Xbox dependencies remain lazy and are reachable
only while Xbox is selected.

CloudNow deliberately reuses:

- App-owned login chrome, QR/PIN presentation, navigation, focus, and dialogs.
- Actor-backed Keychain/UserDefaults persistence, provider-scoped reset fences,
  and provider-scoped cache clearing.
- Bounded lazy catalog grids, artwork validation, request coalescing,
  downsampling, and decoded-image cache.
- Exactly one `CloudRTCRuntime.peerConnectionFactory`, the existing audio device,
  native video surface, and controller haptics implementation.
- Shared settings rows, launch presentation, pause menu, HUD, network-test UI,
  cancellation, memory-pressure, lifecycle, accessibility, and error-redaction
  primitives.

CloudNow deliberately keeps separate:

- OAuth scopes, Xbox Live/XSTS credentials, relying parties, and transfer token.
- Entitlement/offering discovery and Game Streaming region/session state.
- Catalog and session requests, REST SDP/ICE signaling, and data-channel formats.
- Xbox legacy-input encoding, channel handshake, feedback, and rumble decoding.
- Xbox stream preferences, accessibility flags, UI state, and player lifecycle.

Provider-scoped Clear Cache removes only attributable catalog, routing, and
diagnostic-cache artifacts for the selected provider. The decoded-artwork cache
and shared `URLCache` are deliberately preserved because their entries do not
carry provider ownership; app-wide cache maintenance may evict both.

### Diagnostics and tvOS export limitation

Debug builds expose the same Diagnostics and RTC Event Log controls used by the
shared settings and stream HUD. Xbox RTC logging is opt-in, local-only, bounded
to two 1 MiB files, and redacted by construction: it records only allowlisted
connection lifecycle events and never writes SDP, ICE candidates, endpoints,
tokens, account/session identifiers, or channel payloads. Release builds force
both diagnostics controls off even if a Debug build previously persisted them.

tvOS 26.5 marks `ShareLink`, `UIActivityViewController`, the document picker,
and SwiftUI service/file export surfaces unavailable. CloudNow therefore does
not advertise local diagnostic export for either provider on tvOS and does not
invent a network-upload path. Logs remain in the app cache and are removable
through cache maintenance; a future export surface requires a supported tvOS
API or a separately reviewed, explicit transfer design.

### Xbox request path

1. Microsoft OAuth uses the `consumers` device-code public-client flow.
2. Xbox Live User Token and XSTS credentials are derived in memory. Only the
   generic Microsoft refresh token is persisted in the Keychain.
3. CloudNow first authenticates the current public Xbox web offering. Bounded
   offering discovery is a compatibility fallback only if that login fails.
4. An optional, separately scoped XSTS credential reads Microsoft's Content
   Access response into a normalized membership tier, active subscription
   context, and bounded product-access metadata. Its protobuf adapter never
   exposes a PUID, token, or raw response, and any failure is isolated from the
   cloud runtime. A shared, two-entry, five-minute actor cache coalesces the
   catalog and Settings requests without extending credential lifetime.
5. The Xbox catalog client retains service eligibility, ownership, streaming
   program, and remaining-time evidence for every route. Content Access uses the
   exact offering selected by the coalesced Game Streaming login. A
   credential-free request discovers the current ad-supported catalog; localized
   metadata is resolved without sending a Microsoft credential. Standard and ad
   routes for one product are merged without losing distinct title identifiers,
   and only service-confirmed ad routes are marked playable.
6. Play creates one v5 cloud session, polls queue and provisioning states within
   an ETA-aware allocation deadline capped at 15 minutes, obtains the
   console-transfer URI, submits the short-lived Microsoft transfer token, and
   retrieves configuration/signaling context. Session and signaling bodies are
   incrementally bounded before buffering.
7. The native transport creates one peer from CloudNow's shared factory,
   exchanges SDP and ICE over the session REST endpoints, and negotiates
   Microsoft's chat, control, message, input, reliable-input, and
   unreliable-input channels. Every returned channel version is validated;
   unsupported optional channels are disabled while video and a supported input
   path remain required.
8. A dedicated serial sampler sends bounded legacy or modern input frames only
   while a stream is active. Its internal controller capacity is bounded by the
   compatibility profile, but CloudNow does not advertise a live-service slot
   count until Microsoft confirms one. Xbox and PlayStation controllers,
   Menu/View/Share, physical keyboard and mouse, and Escape-to-pause share the
   negotiated input path. On the tvOS Simulator only, UIKit keyboard presses
   bridge into that same Xbox input path when `GCKeyboard` is unavailable;
   physical Apple TV input remains exclusively GameController-backed. The
   current service contract has no confirmed Unicode or composition channel, so
   CloudNow does not advertise native text entry.
9. Heartbeats retransmit unchanged input state without synthetic stick movement.
   Video and audio readiness are monitored. Media loss reconnects the existing
   allocation up to three times with exponential backoff inside one absolute
   30-second window. Microphone capture is opt-in and permission-gated; the
   shared audio device retains intent across AirPods or Continuity Microphone
   loss and restores capture when the input route returns.
10. Xbox stream quality is a preference ceiling, not a launch requirement.
    `Best` sends Microsoft's `1440` request for confirmed Ultimate accounts and
    safely falls back through the service's title, region, device, and network
    policy. Known lower tiers request `1080`; manual aliases remain available for
    troubleshooting. After the negotiated `messageV1` handshake, CloudNow reports
    the active display's preferred pixel dimensions and custom-resolution support
    using Microsoft's `/streaming/characteristics/dimensionschanged` message. The
    versioned compatibility profile identifies this native implementation as a
    web-protocol smart-TV client consistently across allocation and launch while
    retaining CloudNow as the app identity and tvOS as the real operating system.
11. The current public Xbox web-streaming contract negotiates H.264 SDR video and
    stereo Opus game audio. CloudNow does not invent unconfirmed 5.1, HEVC, or HDR
    capabilities. Delivered resolution, codec, color format, and audio channels
    remain visible in the diagnostics HUD; H.264 SDR8 does not by itself mean a
    requested 1440p stream was downgraded.

## Backend decision

The current Xbox path uses a public OAuth client and short-lived user-bound
tokens, so adding a backend would increase latency, operational cost, privacy
surface, and failure modes without protecting a secret. CloudNow should add a
minimal backend only if Microsoft later requires a confidential-client secret,
certificate, partner-only exchange, or server-side policy that cannot safely
ship in tvOS.

## Performance contract

Xbox must preserve the Issue 66 optimizations:

- No browser or JavaScript runtime, second WebRTC package, or duplicate media
  framework.
- One active provider runtime, at most one active peer connection, and no network
  activation for the inactive mode.
- Xbox catalog clients and the stream controller are factory-created only when
  needed; switching drops their in-flight work and transient rows.
- Catalog snapshots retain at most 1,024 validated unique items. Artwork is HTTPS,
  credential-free, downsampled, and handled by the shared bounded pipeline.
- Session allocation, polling, keepalive, candidate lists, response bodies,
  controller slots, queued input, retries, and caches all have explicit bounds.
- High-frequency controller/media work stays outside SwiftUI observation and the
  main actor; sampling stops synchronously with the stream.
- Provider settings use separate small Codable values. Xbox's non-secret SDK
  installation identifier is stable, survives a GeForce NOW reset, and is
  removed by Xbox-scoped or global Reset All Data.
- Release validation checks exactly one RTC factory/framework, no new runtime
  package, GeForce NOW regression coverage, resource return after repeated
  switches, and archive/IPA size against the Issue 66 baseline.

## Physical Apple TV release validation

The deterministic suites cannot prove Microsoft entitlement, regional service,
display-route, controller-firmware, or tvOS microphone behavior. Run this list
together on a physical Apple TV before release and record the result; do not
infer a pass from simulator coverage.

Use a physical Apple TV, a supported controller, and a Microsoft account with a
current Xbox Cloud Gaming entitlement:

1. Reset CloudNow's provider selection and confirm the fresh-launch screen shows
   equal GeForce NOW and Xbox Cloud Gaming choices.
2. Select Xbox and confirm its QR code and device code remain visible until the
   Microsoft flow succeeds or Cancel is selected; the screen must not return to
   the provider chooser on its own.
3. Complete sign-in and confirm Xbox opens its own Home, Library, and Settings
   tabs with the top-left provider dropdown visible.
4. Validate paid subscription and free/owned access routes. Launch a title and
   verify queue/provisioning states, requested-versus-delivered resolution,
   H.264 SDR video, stereo audio, observed HDR where the service supplies it,
   cancellation, Leave, Continue without a second allocation, reconnect after a
   temporary network interruption, and explicit End.
5. Test an Xbox controller, a PlayStation controller, keyboard and mouse,
   Menu/View/Share, independent rumble, and Escape-to-pause. Record additional
   controller behavior as a compatibility observation rather than a confirmed
   service slot count.
6. Enable the provider-specific microphone setting, grant permission, and verify
   AirPods and Continuity Microphone hot-plug, loss, and automatic restoration.
7. Switch to GeForce NOW with the dropdown, confirm its existing Library and
   Store remain unchanged, then switch back and verify neither account requires
   another login.
8. Background and foreground CloudNow once in each mode. Confirm the inactive
   provider performs no refresh, Xbox leaves and can continue the same unexpired
   session, and End Session permits a later launch to create a fresh session.

Record the displayed CloudNow error and redacted diagnostics if a live request
fails. Do not capture or share Microsoft, Xbox Live, XSTS, Game Streaming, or
transfer tokens.

For an account enrolled in the ad-supported preview but without standard cloud
access, confirm Library offers the Ads filter only when it is non-empty, the
selected confirmed route reaches the normal queue/provisioning flow, and
unconfirmed routes stay disabled with a neutral reason. CloudNow does not
simulate, suppress, or claim completion of advertising; Microsoft controls
preview eligibility, ad presentation, and session limits.

## First-party references

- [Microsoft device authorization grant](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
- [Xbox website authentication](https://learn.microsoft.com/en-us/gaming/gdk/docs/services/fundamentals/s2s-auth-calls/service-authentication/live-website-authentication)
- [Xbox Live authentication](https://learn.microsoft.com/en-us/gaming/gdk/docs/services/fundamentals/s2s-auth-calls/service-authentication/live-xbox-live-authentication)
- [XGameStreaming reference](https://learn.microsoft.com/en-us/gaming/gdk/docs/reference/system/xgamestreaming/xgamestreaming_members)
- [Xbox Wire: Stream Games With Ads Preview](https://news.xbox.com/en-us/2026/07/23/game-streaming-ad-supported-xbox-insiders/)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
