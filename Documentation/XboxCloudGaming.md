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

Related documentation:

- [Using CloudNow](UsingCloudNow.md)
- [Streaming settings](StreamingSettings.md#xbox-cloud-gaming-settings)
- [Architecture](Architecture.md)
- [Release validation](ReleaseValidation.md)

## Xbox 1440p streaming

Xbox sessions use the validated `xbox-web-www-29.19.17-sdk-10.6.57`
compatibility profile. It supplies the pinned Microsoft web app/SDK versions, a
coherent browser/web/desktop identity, the minimal web launch envelope, and a
lowercase 22-character client session identifier. In the controlled tvOS
Simulator A/B on 2026-08-16, the same account, region, title, simulated display,
resolution alias, dimensions messages, and automatic bandwidth policy produced
720p at roughly 5 Mbps with the earlier native-tvOS identity and sustained
1440p at roughly 25 to 29 Mbps with the Microsoft-web profile. CloudNow therefore
ships only the Microsoft-web profile and has no profile selector. Physical
Apple TV validation remains a release requirement; the Simulator result is not
presented as hardware proof.

CloudNow sends the resolution alias before authorization as soon as the Xbox
control path is initialized. The request does not wait for decoded video,
controller registration, or the first controller report; gameplay input remains
gated on media readiness. After the negotiated message-channel handshake,
CloudNow sends the active output dimensions and updates them when display
geometry changes.

`Automatic` requests the account's Max Stream Quality: `1440` when high-resolution
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

Xbox uses the shared contracts and infrastructure described in
[Architecture](Architecture.md). Its dependency graph remains lazy and owns
Microsoft authentication and access, catalog routes, allocation, REST
signaling, channel negotiation, input, reconnect, settings, and resume behavior.
It reuses the shared RTC factory, audio and video infrastructure, and haptics
support without sharing or translating provider protocols.

Xbox catalog data and diagnostics remain provider-owned. Shared decoded artwork
and the system `URLCache` remain app-wide resources, as described in the
architecture guide.

### Diagnostics and tvOS export limitation

Debug builds expose the same Diagnostics and RTC Event Log controls used by the
shared settings and stream HUD. Xbox RTC logging is opt-in, local-only, bounded
to two 1 MiB files, and redacted by construction: it records only allowlisted
connection lifecycle events and never writes SDP, ICE candidates, endpoints,
tokens, account/session identifiers, or channel payloads. Release builds force
both diagnostics controls off even if a Debug build previously persisted them.

The tvOS APIs used by the current design do not provide a supported local share
or document-export path. CloudNow therefore does not advertise diagnostic export
for either provider and does not invent a network upload path. Logs remain in the
app cache and can be removed through cache maintenance. A future export feature
requires a supported tvOS API or a separately reviewed transfer design.

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
10. Xbox stream quality is a preference ceiling, not a launch requirement. The
    transport sends the selected resolution alias before authorization, without
    waiting for decoded video or controller readiness. After the negotiated
    `messageV1` handshake, CloudNow reports the active display dimensions and
    later geometry changes through Microsoft's dimensions message. Automatic
    selection and user-visible options are defined in
    [Streaming settings](StreamingSettings.md#xbox-cloud-gaming-settings).
11. The service negotiates codec, color, and audio. CloudNow applies only
    allowlisted service codec overrides and reports observed delivery in the HUD.
    It does not convert an observed format into an unsupported user control.

## Backend decision

The current Xbox path uses a public OAuth client and short-lived user-bound
tokens, so adding a backend would increase latency, operational cost, privacy
surface, and failure modes without protecting a secret. CloudNow should add a
minimal backend only if Microsoft later requires a confidential-client secret,
certificate, partner-only exchange, or server-side policy that cannot safely
ship in tvOS.

## Performance and resource ownership

Xbox follows the shared [performance invariants](Architecture.md#performance-invariants).
Its production graph remains lazy, inactive providers perform no network work,
and each process uses one native RTC runtime. Catalog snapshots retain at most
4,096 validated unique items. Session polling, response bodies, candidate lists,
controller queues, retries, and caches all have explicit bounds.

Explicit refresh keeps the last-good catalog while revalidation runs. Switching
providers cancels in-flight work and drops transient Xbox rows. High-frequency
controller and media work stays outside SwiftUI observation and stops with the
stream.

## Release validation

Physical display routes, live account access, service delivery, controllers, and
microphone transitions require recorded Apple TV checks. The canonical Xbox
1440p comparison and cross-provider release checklist are in
[Release validation](ReleaseValidation.md).

## First-party references

- [Microsoft device authorization grant](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
- [Xbox website authentication](https://learn.microsoft.com/en-us/gaming/gdk/docs/services/fundamentals/s2s-auth-calls/service-authentication/live-website-authentication)
- [Xbox Live authentication](https://learn.microsoft.com/en-us/gaming/gdk/docs/services/fundamentals/s2s-auth-calls/service-authentication/live-xbox-live-authentication)
- [XGameStreaming reference](https://learn.microsoft.com/en-us/gaming/gdk/docs/reference/system/xgamestreaming/xgamestreaming_members)
- [Xbox Wire: Stream Games With Ads Preview](https://news.xbox.com/en-us/2026/07/23/game-streaming-ad-supported-xbox-insiders/)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
