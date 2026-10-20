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

Search, sorting, Favorites, collection, genre, store, and subscription filters use provider
catalog data. Feature filters appear only when the current data supports them.
Library and Store keep independent loading, error, search, sorting, and filter
state.

Focused game cards show their available stores beside a storefront icon,
including games outside the library and games without subscription metadata.
Duplicate store names appear only once; up to two fit on the row, with `+N` for
additional stores. A separate, secondary row beside a ticket icon shows the
first subscription name and `+N` for additional subscriptions when NVIDIA
supplies per-variant metadata. Install-to-Play games add a third, conditional
metadata row with a download icon. Full store and subscription lists remain in game
details and accessibility descriptions.
The footer hides when focus leaves; game titles and library status badges remain
visible. Details show subscriptions for the selected store, including games
outside the library.
These labels describe catalog inclusion, not the account's active subscriptions
or ownership. Library subscription filters consider owned variants. Combining a
store and subscription filter requires both to match the same variant.

Missing or unknown subscription metadata produces no label. An unsupported
subscription field is omitted on retry without disabling the catalog. Fresh
browse metadata replaces cached subscription labels, including an empty list.

A library refresh discovers linked stores, requests provider synchronization,
then reloads the authoritative cloud library. The live browse response remains the
source of truth for ownership, variants, artwork, and supported features. Cached
descriptive metadata can fill missing titles, descriptions, genres, and artwork,
but it cannot replace newer browse-owned fields.

The library synchronization route follows a provider web contract that may
change. CloudNow validates the response and falls back to Reload Library when
discovery or schema checks fail. Only connected accounts with provider-reported
sync support are synchronized.

### Adding games to the library

Game details offer **Mark as Owned** for an unowned store variant. The confirmation
asks the user to confirm ownership on the selected store; it does not purchase a
game license or bypass GeForce NOW membership and storage requirements. Actions
follow the selected variant, so owning a game on one store does not imply owning
it on another.

**View in Steam** or the equivalent store action displays a QR code for the
provider's game-store URL. Users buy or claim the game on their phone, then use
**Connected Stores** to link their account or resync their library. If a game is
still missing, including a free game or demo that store sync does not report,
they can return and mark it as owned. The action does not infer pricing from
catalog filters. A missing or invalid store URL is reported instead of generating
a link from the NVIDIA variant ID.

CloudNow submits ownership changes to NVIDIA and reloads authoritative library
state before updating the game, library membership, and cached ownership. It does
not treat a mutation acknowledgement alone as ownership confirmation. If the
result cannot be confirmed, **Refresh Library Status** checks the current state
before another attempt. Account changes invalidate pending results.

**Unmark as Owned** removes a manual ownership mark after confirmation; it does
not remove the game from the store account. Store-synced ownership continues to
use the existing synchronization flow. Once ownership is confirmed, the selected
variant offers its normal **Play**, **Install**, or **Open in Steam** action.
These controls use NVIDIA's direct GeForce NOW service and do not change Xbox
Cloud Gaming.

### Install-to-Play

NVIDIA's `gfn.playType` classifies games as Ready-to-Play or Install-to-Play.
Library and Store provide a **Play Type** filter when the catalog reports these
values. Unknown or missing values remain unclassified; public catalog optimization
flags are not used to guess installation requirements.

Game details show the selected store's minimum installation size and warn about
single-session installations and games without Steam Cloud saves. The action
reads **Install**, **Play**, or **Open in Steam**, according to fresh provider
installation metadata. Installation happens in streamed Steam on the GFN cloud
PC, using the existing controller, remote pointer and text input. Connecting Steam
and syncing the library does not replace signing into streamed Steam.

For direct NVIDIA accounts, **Settings > Library > Install-to-Play** refreshes
membership access and cloud-storage information. Capacity, usage and storage
location appear only when reported by the membership service. **Manage Cloud
Storage** displays a QR code for NVIDIA's official account page; purchases and
storage changes happen there. Refreshing the page reloads account status.

New Install-to-Play sessions check current game playability, storage entitlement
and known available capacity. Exhausted monthly playtime alone does not block
installation. Capacity checks use healthy storage metadata; storage-status errors
are left to the service to resolve. A resolved persistent-storage region takes
precedence over ordinary server preferences without changing the saved preference.
Single-session storage and unresolved regions retain ordinary routing, matching
NVIDIA's client. Existing sessions resume on their saved route. Unconfirmed
storage entitlement or insufficient capacity produces an actionable error.

Account eligibility and installed-game state are excluded from the shared catalog
cache. The integration uses NVIDIA's web contracts, including
`addons[type=STORAGE]` and its `PERMANENT_STORAGE` / `EPHEMERAL_STORAGE` subtype;
it does not infer access from membership names or store subscription labels.
Unsupported catalog fields are omitted on retry for older regional schemas.
Install-to-Play launching is limited to direct NVIDIA accounts.

### Connected stores

GeForce NOW Settings includes **Connected Stores** for connecting, reconnecting,
and disconnecting store accounts. Store availability, connection state, library
sync, and automatic sign-in capabilities come from the provider. These controls
do not change Xbox Cloud Gaming accounts or settings.

Connect and Reconnect display a provider-issued QR code and code for a temporary
linking session. The user completes store sign-in and authorization on their
phone; CloudNow does not collect store passwords. The app checks the connection
after authorization and reuses the existing library refresh for stores that
support synchronization. **Resync Library** uses the same synchronization path;
**Refresh Connections** checks account state again. Disconnect requires explicit
confirmation and a refreshed provider response before reporting success.

Closing the linking screen cancels local polling. An expired code requires a new
Connect attempt. Sign-out or account changes invalidate pending results so they
cannot update another account's connection state. The account-linking contract
is undocumented and may change. If linking a supported store fails in CloudNow,
users can connect it in the official GeForce NOW app and refresh connections in
CloudNow.

Linking and game-session sign-in remain separate capabilities. Steam linking
synchronizes the library but does not sign into streamed games; Steam's own QR
login can be used when its launcher displays one. Epic automatic sign-in applies
only to supported titles. EA sign-in remains inside the streamed game session
when provider account linking is unavailable. A connected store does not imply
ownership, an active subscription, or automatic sign-in for every game.

### Patching and maintenance

Opening a game's expanded details checks live availability for its store variants.
The selected **Launch Via** store determines the status shown and whether Play is
disabled for patching or maintenance. Other stores can remain playable.

When NVIDIA supplies a patch completion estimate, CloudNow displays a countdown.
An expired estimate does not mean patching has finished: the status remains until
**Check availability** confirms a change. Missing estimates are identified explicitly.
Maintenance details distinguish service compatibility work from work with the game
developer. Availability is not persisted in the catalog cache; a failed refresh
keeps the last known status as advisory, offers another check, and allows a launch
attempt. Only a successful detail check disables Play. Existing sessions are unaffected.

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
session. End closes playback immediately and confirms server termination in the
background using the session-control endpoint, independently of the media host.
A new launch shows cleanup progress and waits for that same operation before
resuming or creating a session. Failed cleanup retains ownership for retry;
confirmed cleanup clears only the ended session's resume metadata. Confirmation
uses a successful, uncached provider active-session list with the ended session
absent. Lingering individual session records do not delay a new launch or provider
switch; failed or incomplete list responses keep cleanup pending.

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
Microphone route returns. Manual 7.1 requests eight channels; playback follows
the server's negotiated layout, including 5.1 or stereo fallback. Automatic
continues to request at most 5.1. Discrete 7.1 requires an Ultimate membership,
a supporting game, and an audio route that carries eight-channel PCM.

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
- Connected-store linking and synchronization use undocumented web contracts.
  Linking can become unavailable, and synchronization may fall back to a normal
  Library reload.
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
