# GeForce NOW integration

CloudNow's GeForce NOW mode is a native provider integration. It owns its account,
catalog, cloud library, CloudMatch session, signaling, input, and streaming
behavior. Shared CloudNow infrastructure supplies the app shell, secure-storage
abstraction, native RTC runtime, video surface, audio route coordination, artwork
pipeline, and diagnostics presentation.

See [Streaming settings](StreamingSettings.md#geforce-now-settings) for current
controls and eligibility rules. See [Architecture](Architecture.md) for shared
ownership and cross-provider invariants.

## Account and provider routing

The default GeForce NOW account flow uses OAuth 2.0 PKCE and persists the refresh
credential in the provider's Keychain namespace. Sign-out and Reset All Data use
generation fences so an older refresh cannot restore credentials after deletion.

CloudNow also discovers GeForce NOW partners such as Jio and bro.game. Login ranks
NVIDIA's default service and likely regional providers first while keeping other
partners available for travel or incorrect region detection. A partner session
uses that provider's routing infrastructure. NVIDIA zone overrides, manual server
selection, and NVIDIA endpoint fallback do not apply to partner-owned sessions.

GeForce NOW and Xbox credentials remain separate. Switching providers does not
sign either account out.

## Catalog and cloud library

GeForce NOW presents three catalog surfaces:

- Home contains live resumable sessions, Continue Playing, and Favorites when
  those rows have content.
- Library contains the current account's connected cloud library.
- Store contains the public provider catalog and marks titles already present in
  the cloud library.

Search, sorting, Favorites, collection, genre, and store filters use provider
catalog data. Feature filters appear only when the current data supports them.
Library and Store keep independent loading, error, search, sorting, and filter
state.

A library refresh discovers linked stores, requests provider synchronization,
then reloads the authoritative cloud library. The live browse response remains the
source of truth for ownership, variants, artwork, and supported features. Cached
descriptive metadata can fill missing titles, descriptions, genres, and artwork,
but it cannot replace newer browse-owned fields.

The library synchronization route follows a provider web contract that may
change. CloudNow validates the response and falls back to Reload Library when
discovery or schema checks fail. It synchronizes only accounts already linked by
the provider.

## Cache behavior

Catalog and library caches are scoped before they are displayed. Public catalog
snapshots use the current NVIDIA locale and VPC. Library ownership uses a SHA-256
identifier for the current account. Legacy unscoped ownership data is treated as
a cache miss.

Metadata enrichment is incremental. Only missing or expired app IDs are requested,
and a second unchanged Library refresh makes no metadata-enrichment request.

| Rule | Behavior |
|---|---|
| Descriptive metadata scope | NVIDIA locale, VPC, and app ID |
| Fresh metadata | 24 hours |
| Missing-record tombstone | 1 hour |
| Failed refresh fallback | Retain stale metadata for up to 30 days without advancing its timestamp |
| Storage bound | Keep the newest 2,000 records in each locale and VPC scope |
| Ownership | Keep a separate authoritative library for each account |
| Manual invalidation | Clear Cache in Settings removes GFN catalog, library, and metadata files |

Writes are atomically merged through the persistence actor. Newer records win when
requests complete out of order. A cache-clear generation prevents older browse or
enrichment work from recreating removed files.

## Session lifecycle

CloudMatch creates, polls, resumes, and stops the provider's server session. The
launch flow owns one generation-bound attempt at a time. Retry cancels and
supersedes the previous attempt, and late work cannot publish after dismissal,
Leave, End, or teardown. If a create request succeeds after its attempt becomes
stale, CloudNow stops the resulting server session instead of leaving it orphaned.

Queue and provisioning states remain visible while the provider prepares a
session. When the provider requires queue advertising, CloudNow plays the supplied
media and reports its lifecycle to CloudMatch. Leave can retain a resumable server
session. End explicitly stops the server session and clears local ownership.

Reconnect work is cancellable and bound to the active connection generation.
Callbacks from an older peer, signaling socket, renderer, input path, or
statistics sampler cannot take over a replacement connection.

## Streaming and delivered-media truth

GeForce NOW supplies the server offer and CloudNow returns the SDP answer and ICE
candidates. The GFN transport owns codec ordering, SDP policy, media behavior,
input channels, and reconnect behavior. It does not share these protocols with
Xbox.

The settings that CloudNow may request are documented in
[Streaming settings](StreamingSettings.md#geforce-now-settings). A request is not
proof of delivery. CloudNow keeps three facts separate:

1. The settings requested from the provider.
2. The settings negotiated for the session.
3. The format and statistics observed from decoded media.

The GFN media path supports H.264, H.265, and AV1 negotiation. Its VideoToolbox
H.265 decoder advertises Main10 and preserves decoded bit depth and color metadata.
HDR is reported only when the decoded pixel buffer proves it. A 10-bit stream, an
HDR-capable display, or an HDR request is not enough on its own.

The current AV1 implementation uses the software I420 conversion path. That path
produces SDR 8-bit BT.709 output and does not preserve SDR10 or HDR metadata. If a
decoder or conversion path omits color attachments, diagnostics report fallback
or unknown instead of guessing.

Game audio, microphone behavior, and their user controls are also covered by
[Streaming settings](StreamingSettings.md#geforce-now-settings). The shared audio
device preserves the selected session audio mode through resume and restores
permission-gated microphone capture after a compatible AirPods or Continuity
Microphone route returns.

## Input

GFN input supports up to four controllers, keyboard and mouse, Siri Remote
pointer input, controller-triggered Apple TV text entry, and independent rumble.
Controller and media work stays outside SwiftUI observation; the HUD receives
bounded snapshots.

Controller text entry captures a complete local string before converting it to
ordered Windows virtual-key, scan-code, and modifier events. Planning finishes
before replay starts, and a successful submission appends Enter. The verified
remote layouts are:

- English (United States), `en-US`
- English (United Kingdom), `en-GB`
- German (Germany), `de-DE`
- French (France), `fr-FR`

Other selected layouts or characters without a verified key mapping are rejected
before any event is sent. Submissions over 1,024 UTF-8 bytes or requiring more
than 256 key events are also rejected. Replay is ordered, bounded, cancellable,
generation-safe, and releases accepted key-down events on failure or teardown.

The current client has no direct Unicode, clipboard, committed-text, or
composition fallback. This limitation affects controller-triggered text entry;
the existing physical keyboard path is unchanged. Xbox input remains a separate
provider-owned protocol and does not claim native text entry.

## Servers and network behavior

NVIDIA-direct sessions can use automatic routing, a provider-confirmed region, or
a dedicated game server. Account and service support still determine which route
is usable. Server information comes from NVIDIA's `serverInfo` response.

The dedicated-server browser augments that data with queue and location metadata
from the [PrintedWaste community service](https://printedwaste.com). Community
metadata may lag behind the provider. Ping values are measured locally after a
city is opened. Cached values appear immediately, and a bounded scheduler probes
only stale zones.

Partner providers manage their own routes. CloudNow does not apply NVIDIA region
or dedicated-server overrides to those sessions.

## Known limitations

- CloudNow is an independent client. Provider APIs and service behavior can change
  without notice.
- Connected-store synchronization uses an undocumented web contract and may fall
  back to a normal Library reload.
- Queue ad playback is controlled by the provider and can be required during high
  demand.
- PrintedWaste queue and location metadata can be older than the provider's live
  state.
- A selected HDR-capable mode does not guarantee HDR delivery. The full request,
  negotiation, decode, and display path must support it.
- AV1 currently uses the SDR 8-bit software conversion path described above.
- Local diagnostic export is unavailable on tvOS. Bounded diagnostics can be
  cleared but are not advertised as exportable.

## Contributor boundaries

The established GFN account, catalog, CloudMatch, SDP, input, reconnect, audio,
microphone, and settings behavior is the regression baseline for shared changes.
Xbox work must not import, translate, or replace it.

Tests use injected transports and anonymized fixtures. They must not depend on a
live provider account, service endpoint, token, SDP capture, or production media
session. Run the manual cross-provider checks in
[Release validation](ReleaseValidation.md) before a release that changes shared
account, catalog, media, input, lifecycle, or cache code.
