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
4. After sign-in, each provider presents a distinct CloudNow mode with its own
   Home, Browse, Settings, catalog state, launch flow, and player.
5. Xbox Home includes a separate `Stream free with ads` rail populated from
   Microsoft's current public preview catalog. Browse offers an All / Free with
   ads filter, and each selection retains its exact authenticated Xbox launch
   route. Microsoft session creation is the final authority for ad-backed access;
   CloudNow does not incorrectly gate that route on standard subscription
   entitlement fields, which remain false for valid ad-backed launches.
   Settings reports the authoritative Game Pass membership when optional Content
   Access metadata is available; metadata failure never blocks catalog discovery
   or standard streaming.
6. A top-left provider dropdown switches between the two modes. There is no
   merged home screen, catalog, settings form, or provider-branded borrowed UI.
7. Before a switch completes, the outgoing mode stops its active stream,
   controller sampler, WebRTC peer, polling, and catalog work. Small persisted
   account records remain so switching back does not require another QR login.
8. Xbox Play allocates one session, shows CloudNow queue/provisioning/connection
   states, then presents video in CloudNow's full-screen player. Cancel and End
   Session both perform best-effort server deletion and local teardown.

## Architecture

The root `CloudGamingProviderCoordinator` persists only the selected provider and
exposes the matching provider configuration. GeForce NOW remains concrete and
unchanged. Xbox dependencies are composed once, remain lazy, and are reachable
only while Xbox is selected.

CloudNow deliberately reuses:

- App-owned login chrome, QR/PIN presentation, navigation, focus, and dialogs.
- Actor-backed Keychain/UserDefaults persistence and reset behavior.
- Bounded lazy catalog grids, artwork validation, request coalescing,
  downsampling, and decoded-image cache.
- Exactly one `CloudRTCRuntime.peerConnectionFactory`, the existing audio device,
  native video surface, and controller haptics implementation.
- Common cancellation, memory-pressure, app-lifecycle, and error-redaction
  primitives.

CloudNow deliberately keeps separate:

- OAuth scopes, Xbox Live/XSTS credentials, relying parties, and transfer token.
- Entitlement/offering discovery and Game Streaming region/session state.
- Catalog and session requests, REST SDP/ICE signaling, and data-channel formats.
- Xbox legacy-input encoding, channel handshake, feedback, and rumble decoding.
- Xbox stream preferences, accessibility flags, UI state, and player lifecycle.

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
5. The Xbox catalog client keeps Microsoft's authenticated title response as the
   authority for standard launch routes. Separately, a credential-free request
   discovers product identifiers from Microsoft's current `Stream with ads`
   catalog rail. Its subscription context follows Microsoft's bounded cloud-pass
   allowlist and uses the required `none` sentinel when no supported cloud pass
   is active; unrelated Content Access passes are never forwarded. CloudNow then
   resolves their localized names and posters through Microsoft's public Game
   Pass metadata endpoint, and maps them to exact launch identifiers through the
   authenticated title service. The public metadata request sends no Microsoft
   credential. It tries Microsoft's 400-product limit first and retries only
   size/client rejections in 200-product batches. A title returned by the
   authenticated mapping is offered for launch; standard `hasEntitlement`,
   `userPrograms`, and remaining-time hints are diagnostic only because they do
   not represent ad-backed authorization. Session creation remains the final
   server authority. Standard and free routes for one product are merged without
   losing distinct title identifiers, and a playable duplicate always wins.
6. Play creates one v5 cloud session, polls bounded provisioning states, obtains
   the console-transfer URI, submits the short-lived Microsoft transfer token,
   and retrieves configuration/signaling context.
7. The native transport creates one peer from CloudNow's shared factory,
   exchanges SDP and ICE over the session REST endpoints, and opens Microsoft's
   chat, control, message, input, reliable-input, and unreliable-input channels.
8. A dedicated serial sampler sends bounded legacy gamepad frames only while a
   stream is active. Controller notifications maintain stable slots; feedback is
   decoded into CloudNow's existing haptics component.
9. Each service heartbeat also forces one unchanged slot-zero controller report
   through the existing input sampler, keeping idle sessions active without a
   second timer or synthetic stick movement. Keepalive and media monitoring are
   generation-fenced. Stream exit, provider switch, sign-out, reset,
   cancellation, and deinitialization all converge on idempotent local teardown
   plus best-effort session deletion.

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
- Catalog snapshots retain at most 512 validated unique items. Artwork is HTTPS,
  credential-free, downsampled, and handled by the shared bounded pipeline.
- Session allocation, polling, keepalive, candidate lists, response bodies,
  controller slots, queued input, retries, and caches all have explicit bounds.
- High-frequency controller/media work stays outside SwiftUI observation and the
  main actor; sampling stops synchronously with the stream.
- Provider settings use separate small Codable values. Xbox's non-secret SDK
  installation identifier is stable and removed by Reset All Data.
- Release validation checks exactly one RTC factory/framework, no new runtime
  package, GeForce NOW regression coverage, resource return after repeated
  switches, and archive/IPA size against the Issue 66 baseline.

## Entitled-account smoke test

Use a physical Apple TV, a supported controller, and a Microsoft account with a
current Xbox Cloud Gaming entitlement:

1. Reset CloudNow's provider selection and confirm the fresh-launch screen shows
   equal GeForce NOW and Xbox Cloud Gaming choices.
2. Select Xbox and confirm its QR code and device code remain visible until the
   Microsoft flow succeeds or Cancel is selected; the screen must not return to
   the provider chooser on its own.
3. Complete sign-in and confirm Xbox opens its own Home, Browse, and Settings
   tabs with the top-left provider dropdown visible.
4. Launch a catalog title and verify queue/provisioning states, video, audio,
   controller input, rumble, pause, cancellation, and End Session.
5. Switch to GeForce NOW with the dropdown, confirm its existing Library and
   Store remain unchanged, then switch back and verify neither account requires
   another login.
6. Background and foreground CloudNow once in each mode. Confirm the inactive
   provider performs no refresh, an active Xbox session tears down cleanly, and
   a later launch can create a fresh session.

Record the displayed CloudNow error and redacted diagnostics if a live request
fails. Do not capture or share Microsoft, Xbox Live, XSTS, Game Streaming, or
transfer tokens.

For an account enrolled in Microsoft's free-with-ads preview but without
standard cloud access, also confirm Home shows the free-with-ads rail, Browse can
filter to it, Settings reports the independent Game Pass membership, and the
selected free route reaches Microsoft's normal queue/provisioning flow. CloudNow
does not simulate, suppress, or claim completion of Microsoft's advertising;
Microsoft controls preview eligibility, ad presentation, and session limits.

## First-party references

- [Microsoft device authorization grant](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
- [Xbox website authentication](https://learn.microsoft.com/en-us/gaming/gdk/docs/services/fundamentals/s2s-auth-calls/service-authentication/live-website-authentication)
- [Xbox Live authentication](https://learn.microsoft.com/en-us/gaming/gdk/docs/services/fundamentals/s2s-auth-calls/service-authentication/live-xbox-live-authentication)
- [XGameStreaming reference](https://learn.microsoft.com/en-us/gaming/gdk/docs/reference/system/xgamestreaming/xgamestreaming_members)
- [Xbox Wire: Stream Games With Ads Preview](https://news.xbox.com/en-us/2026/07/23/game-streaming-ad-supported-xbox-insiders/)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
