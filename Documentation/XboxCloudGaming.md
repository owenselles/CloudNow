# Xbox Cloud Gaming integration

## Status

CloudNow contains a production, native Xbox Cloud Gaming provider mode alongside
its established GeForce NOW mode. Xbox is not a placeholder or a browser wrapper:
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

This document keeps provider and protocol names where technical precision
requires them. Generic account, access, quality, library, server, and session
concepts follow CloudNow's neutral vocabulary: cloud gaming account, cloud
library, current plan, Max Stream Quality, game server, and streaming session.
Internal service identifiers and compatibility profiles remain technical
implementation details.

## Xbox 1440p streaming

Xbox sessions use the validated `xbox-web-www-29.19.17-sdk-10.6.57`
compatibility profile. It supplies the pinned Microsoft web app/SDK versions, a
coherent browser/web/desktop identity, the minimal web launch envelope, and a
lowercase 22-character client session identifier. In the controlled tvOS
Simulator A/B on 2026-08-16, the same account, region, title, simulated display,
resolution alias, dimensions messages, and automatic bandwidth policy produced
720p at roughly 5 Mbps with the earlier native-tvOS identity and sustained
1440p at roughly 25–29 Mbps with the Microsoft-web profile. CloudNow therefore
ships only the Microsoft-web profile and has no profile selector. Physical
Apple TV validation remains a release requirement; the Simulator result is not
presented as hardware proof.

CloudNow sends the resolution alias before authorization as soon as the Xbox
control path is initialized. The request does not wait for decoded video,
controller registration, or the first controller report; gameplay input remains
gated on media readiness. After the negotiated message-channel handshake,
CloudNow sends the active output dimensions and updates them when display
geometry changes.

`Best` requests the account's Max Stream Quality: `1440` when high-resolution
eligibility is confirmed, `1080` when known account metadata reports a lower
ceiling, and a safe `1440` preference while optional access metadata is
unavailable. The last case does not bypass access policy; the service can adapt
the request downward.
[Microsoft documents](https://news.xbox.com/en-us/2026/02/25/february-xbox-update-1440p-streaming-rog-xbox-ally-updates-and-more/)
supported-browser streaming up to 1440p with a higher bitrate, while its
[Cloud Gaming page](https://www.xbox.com/en-US/cloud-gaming) notes that delivered
resolution and audio outputs may remain limited. The service can therefore adapt
downward for title, region, device, display, or network conditions. CloudNow
sends no client bitrate ceiling or bitrate-control message. The standard HUD
shows requested and delivered resolution separately and continues to show
delivered bitrate.

The current official route prefers H.264 and exposes stereo or mono audio modes.
The successful 1440p validation delivered H.264, SDR8, and Opus stereo. These
are the validated current results, not assumptions that every future service
answer must be identical. CloudNow applies only allowlisted service codec
overrides and detects the actual decoded color format, but it exposes no Xbox
codec, HDR/Main10, or 5.1 user controls without future service and
delivered-media proof.

## Clean-room rule

The Xbox implementation is independently authored. No third-party client source,
UI, assets, tests, fixtures, identifiers, credentials, constants, endpoint
lists, protocol captures, binaries, dependencies, or patches are included or
copied. No third-party Xbox client is a source dependency.

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
4. After sign-in, Xbox presents Home, Library, Browse, and Settings while
   GeForce NOW retains its existing Home, Library, Store, Settings, launch flow,
   and player.
5. Xbox Home and Library contain only games with at least one
   Microsoft-confirmed playable route, excluding titles known to be touch-only
   on tvOS. Continue Playing, Recently Played, and Favorites appear on Home only
   when those playable sections have content. Browse contains the full
   validated service catalog, including touch-only titles that cannot launch on
   tvOS. It keeps
   unavailable routes visible with localized account, access, region, input,
   time-limit, or service reasons; it is not presented as a store and does not
   promise a purchase, plan change, or other acquisition path that the service
   has not supplied.
6. Library and Browse keep independent search, sort, filter, and focus state.
   Access, playability, and unavailable-reason filters are correlated to one
   route, and that same route is opened from the resulting card. An
   ad-supported route appears as playable in Library or Home only when Microsoft
   confirms that route; otherwise it remains an unavailable Browse result.
7. Refresh Library in Xbox Settings, Home, Library, and Browse uses one
   Xbox-owned operation. Its full-screen status shows catalog and account-access
   steps, playable and total catalog counts, additions and removals, completion
   time, Retry, and retained-cache warnings. Closing that screen does not cancel
   an active refresh, and opening it again resumes the same status.
8. A top-left provider dropdown switches between the two modes. There is no
   merged home screen, catalog, settings form, or provider-branded borrowed UI.
9. A global coordinator permits one cloud-server session and one local WebRTC
   peer. Switching with an active session offers Leave or End; a parked session
   must be ended before the other provider can start. A failed server deletion
   keeps the lease quarantined instead of silently allowing a second session.
10. Xbox Play allocates one session, shows shared queue/provisioning/connection
   states, then presents video in CloudNow's full-screen player. Leave retains a
   resumable allocation only until its service expiry. Continue reuses that
   allocation; explicit End deletes it and performs local teardown.

## Architecture

The root `CloudGamingProviderCoordinator` persists only the selected provider and
exposes the matching provider configuration. Provider-neutral contracts in the
single app target—there is no separate `CloudGamingCore` framework—describe
narrow account, catalog, stream-option, input,
microphone, resume, reconnect, and diagnostics capabilities. Provider adapters
consume those contracts without importing one another. GeForce NOW behavior is
preserved behind an adapter. Both lightweight account managers and capability
adapters can remain resident, while the Xbox catalog/session/transport service
graph stays lazy and performs network work only when Xbox is selected.

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

The Xbox transport retains the existing shared RTC factory, audio device, and
passive renderer. Xbox continues to own allocation identity, signaling,
data-channel protocol, quality feedback, input, reconnect, and resume behavior.

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
   Access response into normalized account-access, Max Stream Quality, and
   bounded product-access metadata. Its protobuf adapter never
   exposes a PUID, token, or raw response, and any failure is isolated from the
   cloud runtime. A shared, two-entry, five-minute actor cache coalesces the
   catalog and Settings requests without extending credential lifetime.
5. The Xbox catalog client retains service eligibility, ownership, streaming
   program, and remaining-time evidence for every route. Content Access uses the
   exact offering selected by the coalesced Game Streaming login. A
   credential-free request discovers the current ad-supported catalog; localized
   metadata is resolved without sending a Microsoft credential. Cloud gaming
   access and ad-supported routes for one product are merged without losing
   distinct title identifiers. The UI derives a confirmed-playable Library and
   Home from those routes and a full-catalog Browse. Filters and card selection
   use the same route, and only a service-confirmed ad-supported route is marked
   playable.
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
   negotiated input path. Physical Apple TV keyboard/mouse input remains
   GameController-backed through `GCKeyboard` and `GCMouse`. On tvOS Simulator,
   UIKit gameplay keys bridge into the same Xbox worker and are deduplicated
   against GameController state; Escape is debounced and remains the pause
   action. A Siri Remote-style indirect click-drag gesture produces relative
   movement plus a retained left-button report, with neutral reports sent when
   the overlay opens or the view is dismantled. The Simulator exposes no normal
   captured hover or wheel source, so this is a development bridge rather than
   full physical-mouse emulation. The current service contract has no confirmed
   Unicode or composition channel, so CloudNow does not advertise native text
   entry.
9. Heartbeats retransmit unchanged input state without synthetic stick movement.
   Video and audio readiness are monitored. Media loss reconnects the existing
   allocation up to three times with exponential backoff inside one absolute
   30-second window. Microphone capture is opt-in and permission-gated; the
   shared audio device retains intent across AirPods or Continuity Microphone
   loss and restores capture when the input route returns.
10. Xbox stream quality is a preference ceiling, not a launch requirement.
    `Best` sends Microsoft's `1440` request when the account's Max Stream Quality
    includes it and while optional access metadata is unavailable; known lower
    ceilings request `1080`. Manual resolution aliases remain available for
    troubleshooting, but there is no manual Xbox bandwidth control. The service
    may adapt through title, region, device, display, and network policy. The
    resolution request is sent before authorization during
    control bootstrap, independently of decoded-video and controller readiness.
    After the negotiated `messageV1` handshake, CloudNow reports the active
    display's preferred pixel dimensions and custom-resolution support using
    Microsoft's `/streaming/characteristics/dimensionschanged` message, and
    reports later geometry changes through the same path. Production sessions
    use the pinned Microsoft-web compatibility profile documented above.
11. The current public Xbox web-streaming route prefers H.264 and exposes stereo
    or mono Opus game-audio modes. The validated route delivered H.264 SDR8 and
    stereo; an allowlisted future service override or decoded format is reported
    as observed rather than converted into an unproven user control. CloudNow
    does not invent 5.1, HEVC, HDR, or Main10 capability claims. Delivered
    resolution, codec, color format, and audio channels remain visible in the
    diagnostics HUD; H.264 SDR8 does not by itself mean a requested 1440p stream
    was downgraded.

## Backend decision

The current Xbox path uses a public OAuth client and short-lived user-bound
tokens, so adding a backend would increase latency, operational cost, privacy
surface, and failure modes without protecting a secret. CloudNow should add a
minimal backend only if Microsoft later requires a confidential-client secret,
certificate, partner-only exchange, or server-side policy that cannot safely
ship in tvOS.

## Performance contract

Xbox must preserve CloudNow's established performance invariants:

- No browser or JavaScript runtime, second WebRTC package, or duplicate media
  framework.
- One active provider runtime, at most one active peer connection, and no network
  activation for the inactive mode.
- Xbox catalog clients and the stream controller are factory-created only when
  needed; switching drops their in-flight work and transient rows.
- Catalog snapshots retain at most 4,096 validated unique items. The
  account/locale/market-scoped disk cache may display its bounded last-known
  snapshot while an expired entry is revalidated; refresh failure leaves that
  snapshot visibly stale rather than treating it as fresh. Artwork is HTTPS,
  credential-free, downsampled, and handled by the shared bounded pipeline.
- Explicit refresh never evicts the last-good snapshot first. Its generation-
  fenced task coordinates catalog and account-access requests, rejects late
  completion after provider teardown, coalesces duplicate starts, and reports
  failure without inventing a successful account-access result.
- Session allocation, polling, keepalive, candidate lists, response bodies,
  controller slots, queued input, retries, and caches all have explicit bounds.
- High-frequency controller/media work stays outside SwiftUI observation and the
  main actor; sampling stops synchronously with the stream.
- Provider settings use separate small Codable values. Xbox's non-secret SDK
  installation identifier is stable, survives a GeForce NOW reset, and is
  removed by Xbox-scoped or global Reset All Data.
- Release validation checks exactly one RTC factory/framework, no new runtime
  package, GeForce NOW regression coverage, resource return after repeated
  switches, and archive/IPA size against the established pre-Xbox baseline.

## Physical Apple TV release validation

The deterministic suites cannot prove Microsoft entitlement, regional service,
display-route, controller-firmware, or tvOS microphone behavior. Run this list
together on a physical Apple TV before release and record the result; do not
infer a pass from simulator coverage.

Use a physical Apple TV, a supported controller, and a Microsoft account with a
current Xbox Cloud Gaming entitlement:

### Xbox 1440p validation

Validate the production profile before interpreting the general release
checklist:

1. Use the same account whose Max Stream Quality includes 1440p, region, display,
   and network for the reference and CloudNow runs. Start a fresh Cyberpunk 2077
   session for each run.
2. Establish the reference on [xbox.com/play](https://www.xbox.com/play) under
   those matched conditions. If the reference itself does not reach 1440p, mark
   the comparison inconclusive; do not treat the CloudNow run as failed.
3. On a physical Apple TV, build or archive the shared `CloudNow` scheme. Run a
   fresh CloudNow session for at least 90 seconds using the production
   `xbox-web-www-29.19.17-sdk-10.6.57` profile.
4. Record requested and delivered resolution, resolution transitions, FPS,
   bitrate, codec, color mode, and audio channels. Startup at 1080p is allowed;
   success requires delivered 2560×1440 for at least 30 consecutive seconds.
   H.264, SDR8, or stereo does not invalidate an otherwise successful 1440p run.
5. Repeat the result three times under the same conditions. Use Halo
   Infinite as the secondary title after Cyberpunk 2077 proves the primary path.

If CloudNow does not prove 1440p while xbox.com does under matched conditions,
investigate identity, launch-envelope, bootstrap-order, display-dimensions, and
delivered-media evidence before changing one Xbox-owned variable at a time.

### General provider validation

1. Reset CloudNow's provider selection and confirm the fresh-launch screen shows
   equal GeForce NOW and Xbox Cloud Gaming choices.
2. Select Xbox and confirm its QR code and device code remain visible until the
   Microsoft flow succeeds or Cancel is selected; the screen must not return to
   the provider chooser on its own.
3. Complete sign-in and confirm Xbox opens its own Home, Library, Browse, and
   Settings tabs with the top-left provider dropdown visible. Confirm Home and
   Library contain only games with a playable route and exclude titles known to
   be touch-only. Confirm Browse retains the full catalog, including those titles
   marked with a compatible-input requirement and route-specific unavailable
   reasons.
4. Validate the account's cloud gaming access, ad-supported, and owned evidence.
   Combine access and playability filters and confirm the opened card uses the
   route that satisfied both filters. Confirm an unconfirmed or unavailable
   ad-supported route remains in Browse but not Library. Launch a title and
   verify queue/provisioning states, requested-versus-delivered resolution,
   delivered H.264 SDR8 video and Opus stereo audio, cancellation, Leave,
   Continue without a second allocation, reconnect after a temporary network
   interruption, and explicit End.
5. In Xbox Settings, start Refresh Library and verify both progress steps,
   completion totals, additions/removals, and timestamp. Close it while running,
   reopen the same operation, then test failure and Retry while confirming the
   last-good Library remains available.
6. Test an Xbox controller, a PlayStation controller, keyboard and mouse,
   Menu/View/Share, independent rumble, and Escape-to-pause. Record additional
   controller behavior as a compatibility observation rather than a confirmed
   service slot count.
7. Enable the provider-specific microphone setting, grant permission, and verify
   AirPods and Continuity Microphone hot-plug, loss, and automatic restoration.
8. Switch to GeForce NOW with the dropdown, confirm its existing Library and
   Store remain unchanged, then switch back and verify neither account requires
   another login.
9. Background and foreground CloudNow once in each mode. Confirm the inactive
   provider performs no refresh, Xbox leaves and can continue the same unexpired
   session, and End Session permits a later launch to create a fresh session.
10. Run the established GeForce NOW login, catalog, Library, Store, game-detail,
   and Settings smoke tests. Confirm the same account, tier-neutral copy,
   filters, focus behavior, saved settings, and launch flow as the frozen
   pre-quality baseline.
11. On a GeForce NOW title/account/server combination that exposes them, verify
    the existing H.265 Main10, 5.1 output, microphone permission, AirPods or
    Continuity Microphone hot-swap, controller input/rumble, and pause HUD paths.
    Confirm unavailable media modes continue to use the established GFN
    fallback instead of being treated as an Xbox result.
11. Interrupt and restore the GeForce NOW network path, then exercise Retry,
    background/foreground, Exit, End Session, and a new launch. Confirm its
    existing reconnect and session-lifecycle behavior remains unchanged and no
    Xbox allocation or authorization work occurs in the GFN-only run.

For every physical run, record the date, CloudNow commit, build configuration,
Apple TV/tvOS and display/output route, provider/profile, account entitlement,
region, title, controller/input route, requested settings, delivered HUD values,
duration, and Pass/Fail/Inconclusive result. A release pass requires a recorded
result for every Xbox and GFN item above; an unavailable prerequisite is
Inconclusive, not an inferred pass.

Record the displayed CloudNow error and redacted diagnostics if a live request
fails. Do not capture or share Microsoft, Xbox Live, XSTS, Game Streaming, or
transfer tokens.

For an account enrolled in the ad-supported preview but without cloud gaming
access, confirm Library offers the Ads filter only when a confirmed playable
ad-supported route exists, the selected route reaches the normal
queue/provisioning flow, and unconfirmed routes remain disabled in Browse with a
neutral reason. CloudNow does not simulate, suppress, or claim completion of
advertising; Microsoft controls preview eligibility, ad presentation, and
session limits.

## First-party references

- [Microsoft device authorization grant](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
- [Xbox website authentication](https://learn.microsoft.com/en-us/gaming/gdk/docs/services/fundamentals/s2s-auth-calls/service-authentication/live-website-authentication)
- [Xbox Live authentication](https://learn.microsoft.com/en-us/gaming/gdk/docs/services/fundamentals/s2s-auth-calls/service-authentication/live-xbox-live-authentication)
- [XGameStreaming reference](https://learn.microsoft.com/en-us/gaming/gdk/docs/reference/system/xgamestreaming/xgamestreaming_members)
- [Xbox Wire: Stream Games With Ads Preview](https://news.xbox.com/en-us/2026/07/23/game-streaming-ad-supported-xbox-insiders/)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
