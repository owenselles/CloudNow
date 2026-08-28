# Release validation

Automated tests cannot prove live provider entitlement, regional service state,
physical display routing, controller firmware behavior, or tvOS microphone route
changes. Run this checklist on a physical Apple TV before a release that changes
provider, catalog, session, media, input, lifecycle, or cache behavior.

Run the automated checks in [Development](Development.md#testing) first. Use the
current provider expectations in [GeForce NOW integration](GeForceNOW.md) and
[Xbox Cloud Gaming integration](XboxCloudGaming.md) when interpreting results.
Review the shared ownership and performance rules in
[Architecture](Architecture.md) before changing a cross-provider expectation.

## Required setup

- A physical supported Apple TV running the release's minimum or newer tvOS
  version.
- A supported controller, physical keyboard and mouse, and the microphone routes
  required by the change under test.
- Accounts with current access to each provider and the titles used in the test.
- The shared `CloudNow` scheme built or archived in Release configuration.
- The current production provider profiles. Do not substitute a development
  identity when validating production behavior.
- A stable display and network path whose details can be recorded.

The Simulator can help reproduce deterministic UI and protocol behavior, but it
does not count as a physical release pass.

## Evidence record

Create one record for every physical run. Include:

| Field | What to record |
|---|---|
| Build | Date, CloudNow commit, release tag if assigned, and build configuration |
| Device | Apple TV model, tvOS version, display, output mode, and audio route |
| Provider | Provider, production profile, account access, current plan, and region |
| Content | Title and the route or access path used to launch it |
| Input | Controller model, controller firmware when available, keyboard and mouse route, and microphone route |
| Request | Requested resolution and other relevant stream settings |
| Delivery | HUD resolution, transitions, FPS, bitrate, codec, color format, audio channels, and microphone state |
| Duration | Total stream duration and any timed acceptance interval |
| Result | Pass, Fail, or Inconclusive, with a short reason |

Record the displayed CloudNow error and redacted diagnostics when a live request
fails. Never capture or share provider access tokens, refresh tokens, device codes,
QR codes, session identifiers, SDP, ICE candidates, transfer tokens, or raw
channel payloads.

## Xbox 1440p comparison

Validate the production profile before the general cross-provider checklist:

1. Choose an account whose Max Stream Quality includes 1440p. Use the same
   account, region, display, and network for the reference and CloudNow runs.
   Start a fresh Cyberpunk 2077 session for each run.
2. Establish the reference on [xbox.com/play](https://www.xbox.com/play). If the
   reference does not reach 1440p under the matched conditions, mark the
   comparison Inconclusive. Do not treat the CloudNow run as failed.
3. On the physical Apple TV, start a fresh CloudNow session with the current
   production profile and run it for at least 90 seconds.
4. Record requested and delivered resolution, resolution transitions, FPS,
   bitrate, codec, color format, and audio channels. Startup at 1080p is allowed.
   A pass requires delivered 2560x1440 for at least 30 consecutive seconds.
   Codec, color, or stereo delivery does not invalidate an otherwise successful
   1440p result, but every observed value must be recorded.
5. Repeat the comparison three times under the same conditions. Use Halo Infinite
   as the secondary title after Cyberpunk 2077 proves the primary path.

If xbox.com reaches 1440p and CloudNow does not under matched conditions, inspect
identity, launch envelope, bootstrap order, display dimensions, and delivered
media evidence. Change one Xbox-owned variable at a time.

## Cross-provider smoke test

1. Reset provider selection. Confirm that a fresh launch shows equal GeForce NOW
   and Xbox Cloud Gaming choices.
2. Select Xbox. Confirm that its QR code and device code remain visible until the
   Microsoft flow succeeds or the user selects Cancel. The app must not return to
   the provider chooser on its own.
3. Complete sign-in. Confirm that Xbox opens Home, Library, Browse, and Settings,
   with the provider menu available. Home and Library must contain only playable
   routes and exclude titles known to be touch-only. Browse must retain the full
   catalog and show route-specific unavailable reasons.
4. Combine account access and playability filters. Confirm that a card opens the
   same route that satisfied those filters. An unconfirmed or unavailable
   ad-supported route may remain in Browse, but it must not appear as playable in
   Library.
5. Launch an Xbox title. Verify queue and provisioning states, requested and
   delivered resolution, delivered media statistics, cancellation, Leave,
   Continue without a second allocation, reconnect after a temporary network
   interruption, and explicit End.
6. Start Refresh Library from Xbox Settings. Verify both progress steps, totals,
   additions and removals, and completion time. Close and reopen the progress
   screen while the refresh runs. Then test failure and Retry, confirming that the
   last-good Library remains available.
7. Test an Xbox controller, a PlayStation controller, physical keyboard and mouse,
   Menu, View, Share, independent rumble, and Escape to pause. Record additional
   controller behavior as an observation, not as a confirmed service slot count.
8. Enable the Xbox microphone setting, grant permission, and test AirPods and
   Continuity Microphone connection, loss, and automatic restoration.
9. Switch to GeForce NOW. Confirm that its account, Library, Store, and settings
   remain unchanged. Switch back to Xbox and verify that neither account requires
   another login.
10. Background and foreground CloudNow once in each mode. Confirm that the inactive
    provider performs no refresh. Verify Leave, Continue, and End according to the
    active provider's session rules.
11. Run the established GeForce NOW login, catalog, Library, Store, game detail,
    Settings, and launch smoke tests. Confirm tier-neutral copy, filters, focus,
    saved settings, and the expected launch flow.
12. On a GeForce NOW title, account, server, display, and audio route that expose
    them, verify H.265 Main10, 5.1 output, microphone permission and route changes,
    controller input and rumble, and pause HUD behavior. Confirm that unavailable
    modes follow the established GFN fallback instead of being treated as an Xbox
    result.
13. In GeForce NOW Settings, capture and cancel a text-input button combination,
    then save one and adjust its hold delay. Start a stream, open Apple TV text
    entry with the saved combination, send supported text, cancel without sending,
    and verify unsupported layout, unsupported character, and length failures do
    not send partial input. Confirm Menu, overlay, reconnect, and stream teardown
    release input cleanly.
14. Interrupt and restore the GeForce NOW network path. Exercise Retry,
    background and foreground, Exit, End Session, and a new launch. Confirm that
    reconnect and session ownership remain stable and that no Xbox allocation or
    authorization work occurs during the GFN-only run.
15. Repeat provider switches and stream entry and exit. Confirm that old peers,
    renderers, controllers, observers, input workers, and provider service graphs
    release after teardown. The inactive provider must not retain an active peer
    or begin network work.

## Ad-supported Xbox account

For an account enrolled in the ad-supported preview without normal cloud gaming
access:

1. Confirm that Library offers the Ads filter only when a confirmed playable
   ad-supported route exists.
2. Confirm that the selected route reaches the normal queue and provisioning flow.
3. Confirm that unverified routes remain disabled in Browse with a neutral reason.
4. Record advertising behavior and session limits as service observations.
   CloudNow must not simulate, suppress, or claim completion of provider-managed
   advertising.

## Archive checks

- Confirm that the archive contains one RTC framework and no second provider media
  runtime.
- Confirm that `App Store Media/` screenshots are absent from the app bundle.
- Compare archive and IPA size with the established release baseline. Investigate
  unexplained growth before publishing.
- Confirm that both Debug and Release use the same provider separation and that
  production release settings do not expose debug diagnostics.

## Pass criteria

A release pass requires a recorded result for every applicable Xbox and GeForce
NOW item. An unavailable account, title, service route, display mode, input device,
or microphone route is Inconclusive, not an inferred pass. A failure needs a
linked issue or an explicit release decision before publication.

When a provider changes its live behavior, update the provider document and this
checklist from recorded evidence. Do not turn one unexpected result into a new
capability claim or user setting.
