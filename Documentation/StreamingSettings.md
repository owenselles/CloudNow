# Streaming settings

CloudNow keeps GeForce NOW and Xbox Cloud Gaming settings separate. A control
shown for one provider is not assumed to exist for the other. This guide records
the defaults, option sources, eligibility rules, and current provider limits in
the app.

For first launch, provider switching, navigation, languages, and data actions,
see [Using CloudNow](UsingCloudNow.md). Provider implementation and compatibility
details are documented in [GeForce NOW integration](GeForceNOW.md) and
[Xbox Cloud Gaming integration](XboxCloudGaming.md).

## Available, requested, and delivered

Three different values can be involved in a streaming session:

- **Available** is what CloudNow offers in Settings. An option can depend on
  account entitlements, membership data, selected resolution, the active
  provider, and Apple TV display capabilities.
- **Requested** is the preference or ceiling CloudNow sends when starting a
  session. It is not a guarantee.
- **Delivered** is what the provider actually sends. The title, provider
  service, server, region, display path, and live network conditions can lower
  or otherwise change the result.

The in-stream pause menu cycles the statistics display through **Off**,
**Compact**, and **Standard**. Standard is the best place to compare requested
and delivered media. The statistics display defaults to Off for both providers.

Most stream, controller, audio, microphone, language, and accessibility changes
apply to the next session. Changing the statistics display from the pause menu
applies immediately.

Selection controls open as full Settings pages. The saved option receives
initial focus and keeps its checkmark. When CloudNow knows an option but the
account, display, or permission does not currently allow it, the option remains
focusable with an **Unavailable** label. Selecting it explains the exact reason
and, when CloudNow can recover in place, offers the relevant action.

## Defaults and saved preferences

Defaults apply when a provider has no saved settings, including after **Reset
All Data** for that provider. Updating CloudNow preserves existing saved
preferences, so a newly changed default does not overwrite a previous choice.

| Area | GeForce NOW default | Xbox Cloud Gaming default |
|---|---|---|
| Resolution | 1920x1080 | Automatic |
| Frame rate | 60 fps | Service controlled |
| Codec | H265 | Service controlled |
| Color | Automatic | Service controlled |
| Audio | Automatic | Service controlled |
| Maximum bitrate | 100 Mbps | No client cap |
| L4S | On | Not exposed |
| Game language | Automatic | Automatic |
| Microphone | Off | Off |
| Controller rumble | On | On |
| Rumble intensity | 1.00x | 100% |
| Controller deadzone | 15% | 15% |
| Statistics display | Off | Off |

## Capability summary

| Setting | GeForce NOW | Xbox Cloud Gaming |
|---|---|---|
| Resolution | Common choices remain visible; account entitlement decides availability | Automatic and all manual choices remain visible; membership decides availability |
| Frame rate | Known choices remain visible; account, resolution, and display decide availability | No manual control |
| Codec | H264, H265, AV1 | No manual control |
| Color and HDR | Automatic, Prefer HDR, Prefer 10-bit SDR, Compatibility SDR | No manual control |
| Audio layout | Automatic, Stereo, 5.1 Surround | No manual control |
| Maximum bitrate | 15 to 100 Mbps | No client bitrate cap |
| L4S | Toggle | Not exposed |
| Server location | NVIDIA automatic, region, or dedicated server | Service selected |
| Keyboard layout | Selectable | Not exposed |
| Game language | Selectable | Selectable |
| Game launch mode | Default or Big Picture | Not exposed |
| Microphone | Supported when the route and permission allow it | Supported when the Xbox capability is available |
| Controller tuning | Rumble, intensity, deadzone, overlay, input mode | Rumble, intensity, deadzone |
| Save in-game settings | Plan dependent | Not exposed |
| Xbox accessibility preferences | Not exposed | Text to speech, magnifier, high contrast |

## GeForce NOW settings

### Stream quality

| Setting | Default | Options and eligibility | Effect |
|---|---|---|---|
| Resolution | 1920x1080 | After entitlement data loads, the common HD, Full HD, 2K, 4K, and 5K choices remain visible. Choices not included in the current membership are unavailable and explain that an account upgrade or different resolution is required. Account-specific resolutions outside that common list are also shown when entitled. Before entitlement data is available, CloudNow offers 1280x720 and 1920x1080. | Sets the requested stream size. The service can deliver a different size. |
| Frame Rate | 60 fps | The page shows the 30 and 60 fps baselines plus frame rates reported anywhere in the account entitlements. Each choice is evaluated for the selected resolution and current Apple TV output refresh rate. See [Frame-rate eligibility](#frame-rate-eligibility). | Sets the requested frame rate. Delivered FPS can be lower. |
| Codec | H265 | H264, H265, and AV1 are always selectable. The picker does not hide codecs based on account or device checks. | Sets the requested GFN codec path. H265 is required for the current 10-bit and HDR path. |
| Color Mode | Automatic | Automatic, Prefer HDR, Prefer 10-bit SDR, and Compatibility SDR are always selectable. Actual requests are capability checked. | Controls the preferred color request and safe fallback. See [Codec, color, and HDR](#codec-color-and-hdr). |
| Audio Format | Automatic | Automatic, Stereo, and 5.1 Surround are always selectable. | Automatic requests 5.1 when the system maximum output-channel count is at least six. This is a heuristic rather than a reliable sink-capability check, and tvOS can still downmix. |
| Keyboard Layout | tvOS-derived locale | CloudNow's supported locale list. | Sends the selected keyboard layout to GFN. This is separate from game language. |
| Game Language | Automatic | Automatic plus the fixed language list documented in [Using CloudNow](UsingCloudNow.md#game-language). | Automatic maps the tvOS language to an NVIDIA locale. Title support still decides the language delivered in game. |
| Game Launch Mode | Big Picture | Default or Big Picture | Big Picture requests the TV-oriented launcher mode. Default requests the desktop-style launcher mode. |
| Max Bitrate | 100 Mbps | 15 to 100 Mbps in 5 Mbps steps | Sends a maximum bitrate preference. Network and service adaptation can remain below it. |
| Low Latency Mode | On | Always shown | Requests L4S behavior. It is useful only with a compatible router and ISP. |

#### Frame-rate eligibility

GFN entitlement data records combinations of width, height, and frame rate.
CloudNow calculates frame-rate availability as follows:

1. Read the maximum frame rate of the active Apple TV screen. If no screen is
   available yet, use 60 as the fallback cap.
2. Find entitlement records matching the selected resolution.
3. If there is no exact resolution match, use frame rates from all available
   entitlement records.
4. Build the visible choices from 30 and 60 fps plus every frame rate reported
   elsewhere in the account entitlements, remove duplicates, and sort them.
5. Keep choices above the display cap or outside the applicable entitlement
   records visible but unavailable. Selecting one explains the display limit,
   membership limit, or both. Display-limited messages include the Apple TV
   **Settings > Video and Audio > Format** recovery path.
6. If entitlement data is not available, start with 30 and 60 fps and apply the
   display cap without guessing a membership restriction.

The enabled choices remain the same values CloudNow used before this presentation
change. Unavailable values are explanatory only and are never sent to a stream.
Title support, server load, and network conditions can affect delivered FPS, but
they do not change Settings eligibility.

When account data loads, CloudNow replaces a saved resolution that is no longer
available with the highest available resolution. If at least one frame-rate
option remains, it also replaces an invalid saved frame rate with the highest
remaining option. After manually changing resolution, select a frame rate that
appears for the new resolution.

#### Codec, color, and HDR

Selecting a color preference does not prove that the stream is using that
format. CloudNow resolves the request from the codec and local video pipeline:

- The current 10-bit SDR and HDR paths require H265 and local 10-bit hardware
  decode support.
- The current pre-session HDR request uses the codec, local decoder, render and
  display capabilities, and account entitlement. Title and server support are
  not positively known at that point and can still produce an SDR fallback.
- **Automatic** requires confirmed account entitlement and a qualifying local
  pipeline. Otherwise it falls back to 10-bit SDR or 8-bit SDR.
- **Prefer HDR** requires a qualifying local pipeline and an account not known
  to be ineligible, then falls back safely.
- **Prefer 10-bit SDR** falls back to 8-bit SDR when 10-bit decode is not
  available.
- **Compatibility SDR** forces the 8-bit SDR request.
- AV1 currently uses the software I420 path and falls back to 8-bit SDR BT.709.

CloudNow reports color from negotiated state and decoded video metadata. A
10-bit stream, HDR-capable display, or HDR preference alone is not reported as
delivered HDR.

### Server and network

| Setting | Default | Availability | Effect |
|---|---|---|---|
| Server Location | Automatic | NVIDIA-direct accounts can choose Automatic, an official region, or a dedicated server. Partner-provider accounts see that server selection is managed by the named partner for that account. | Automatic delegates routing to NVIDIA. Region pins an official service region. Server selection pins a dedicated zone. |
| Test Network | Action, no saved value | Always shown in the GFN Settings server section. | Measures the currently selected routing target where possible. A good test does not guarantee a title session will use the same live conditions. |

Automatic routing is the safest default. A manually selected region or server
can become unavailable, add latency, or have different queue conditions.

### Microphone and controller

| Setting | Default | Options and eligibility | Effect |
|---|---|---|---|
| Use Microphone | Off | Always shown. The first explicit enable attempt requests tvOS microphone permission when its state is undetermined. If access was denied, Settings explains the Apple TV privacy path and offers **Open Settings**. | Requests voice chat for the next session and follows supported route changes. Runtime route and track handling are unchanged. |
| Controller Rumble | On | Always shown for supported controllers. | Enables GFN haptic output for the next session. |
| Rumble Intensity | 1.00x | Shown only while rumble is on. Range 0.00x to 2.00x in 0.05x steps. | Scales haptic power. Values above 1.00x increase motor load. |
| Deadzone | 15% | Always shown. Range 0% to 30% in 1% steps. | Increases the radial analog-stick deadzone to reduce drift. |
| Overlay Button | Start | Start or Options/Back | Long-pressing the selected button opens the CloudNow stream overlay. |
| Steam Overlay Gesture | On | Always shown | Long-pressing the other menu button sends Shift+Tab to the session. |
| Default Input Mode | Controller | Controller, Controller + Touchpad, or Controller + Mouse (Siri Remote) | Chooses the input mode used when a stream starts. Touchpad mode supports DualShock 4 and DualSense trackpads. |

GFN exposes the controller protocol as XInput over GFN v2/v3. Device support
and game support still determine which controls and haptics are delivered.

### Game, library, and diagnostics

| Setting or action | Default | Availability and effect |
|---|---|---|
| Save In-Game Settings | On | Premium tiers, including Ultimate and Performance or legacy Priority, can change the toggle. A known Free account keeps the disabled toggle visible with the current membership and required plans. An unknown tier can change the preference, but the service remains authoritative. |
| Refresh Library | Action, no saved value | Shown only in builds with provider library synchronization enabled. It refreshes linked-library and catalog data. |
| Statistics | Off | Changed from the in-stream pause menu. Compact and Standard are available. |
| Diagnostics | Off | Developer builds only. Enables additional local diagnostics. |
| RTC Event Log | Off | Developer builds only and disabled unless Diagnostics is on. The bounded log applies to the next stream. tvOS does not expose a supported local export path. |

## Xbox Cloud Gaming settings

Xbox settings remain intentionally smaller because CloudNow only exposes
controls supported by its validated Xbox route.

### Resolution eligibility

The resolution setting remains visible whenever the Xbox provider capability
supports manual quality controls. Its full page always lists Automatic, 1440p,
1080p HQ, 1080p, 720p HQ, and 720p. Automatic remains available while the
manual choices reflect account state:

| Account state | Enabled options | Unavailable-option explanation | Automatic request |
|---|---|---|---|
| Membership data loading | Automatic | CloudNow is checking the membership before enabling manual choices. | 1440p ceiling |
| Membership service unavailable | Automatic | Membership could not be confirmed; **Try Again** refreshes account access. | 1440p ceiling |
| Known Game Pass Ultimate | Automatic, 1440p, 1080p HQ, 1080p, 720p HQ, 720p | None | 1440p ceiling |
| Other known membership | Automatic, 1080p, 720p | 1440p and HQ choices name Game Pass Ultimate as required and show the current membership. | 1080p ceiling |
| Loaded account with no recognized tier | Automatic, 1080p, 720p | 1440p and HQ choices explain that an eligible Game Pass Ultimate membership could not be confirmed. | 1080p ceiling |

A saved manual choice that is no longer eligible is displayed as Automatic.
The session request also falls back to the account-aware Automatic ceiling.
Resolution aliases are preferences, not requirements, and the Xbox service can
adapt below them.

### Available Xbox settings

| Setting or action | Default | Options and eligibility | Effect |
|---|---|---|---|
| Resolution | Automatic | Account-aware options described above. | Sends the selected resolution alias or Automatic ceiling. |
| Game Language | Automatic | Automatic plus the fixed language list documented in [Using CloudNow](UsingCloudNow.md#game-language). | Automatic uses the active CloudNow locale. The title and service remain authoritative. |
| Controller Rumble | On | Always shown while Xbox Settings is available. | Enables Xbox haptic output for the next session. |
| Rumble Intensity | 100% | Shown only while rumble is on. Range 0% to 100% in 5% steps. | Scales Xbox haptic output. |
| Deadzone | 15% | Range 0% to 30% in 1% steps. | Adjusts the controller deadzone for the next session. |
| Use Microphone | Off | Shown when the Xbox capability reports voice-chat support. The first explicit enable attempt requests undetermined tvOS permission; denied access shows the Apple TV privacy path and **Open Settings**. | Requests microphone attachment for the next session. Runtime route and track handling are unchanged. |
| Test Network | Action, no saved value | Shown when the Xbox capability provides a network-test target. The current production capability does. | Tests the provider-owned target; Xbox still selects the session region. |
| Text to Speech | Off | Always shown in the current Xbox Settings screen. | Sends the Xbox accessibility preference at session creation. |
| Magnifier | Off | Always shown in the current Xbox Settings screen. | Sends the Xbox accessibility preference at session creation. |
| High Contrast | Off | Always shown in the current Xbox Settings screen. | Sends the Xbox accessibility preference at session creation. |
| Refresh Library | Action, no saved value | Available when no conflicting account, data, or refresh operation is running. | Refreshes catalog and account-access data and reports progress. |
| Statistics | Off | Changed from the in-stream pause menu. Compact and Standard are available. | Standard separates requested resolution from delivered media. |
| Diagnostics | Off | Developer builds only. | Enables additional local diagnostics. |
| RTC Event Log | Off | Developer builds only and disabled unless Diagnostics is on. | Captures a bounded local RTC lifecycle log for the next stream. |

Controller settings are disabled while a conflicting Xbox operation is in
progress and take effect on the next Xbox Cloud session.

### Settings Xbox does not expose

| Setting | Current Xbox behavior |
|---|---|
| Frame rate | No manual control. Delivered FPS is observed from WebRTC statistics. |
| Codec | No manual control. The service negotiates the codec; the validated route currently uses H264. |
| Color or HDR | No manual control. The validated route currently delivers SDR8, and CloudNow does not claim HDR or 10-bit support without delivered-media proof. |
| Audio layout | No manual control. The current route uses Opus stereo or mono. |
| Maximum bitrate | CloudNow sends no Xbox client bitrate cap or periodic bitrate-control message. |
| L4S | Not exposed. |
| Server location | Xbox selects the region. CloudNow offers only the supported network test. |
| Keyboard layout | Not exposed. Physical keyboard and mouse input can still be supported by a title route. |
| Game launch mode | Not exposed. |
| Overlay button, Steam gesture, and default input mode | Not exposed. Xbox owns its controller and pause behavior. |
| Save In-Game Settings | Not exposed. |

## Troubleshooting quality and eligibility

### 60 fps is unavailable in GFN

1. Check the selected resolution. GFN frame-rate entitlement is evaluated for
   that resolution.
2. Check the account's **Max Stream Quality** in the GFN Account section.
3. On Apple TV, open **Settings > Video and Audio > Format** and select a 60 Hz
   format if the television, receiver, and cable support it. CloudNow marks
   frame rates above the current output format as unavailable.
4. Return to the frame-rate page after account data has loaded. Select the
   unavailable option to see whether the remaining cause is the display,
   membership at the selected resolution, or both.

### 1440p or HQ options are unavailable in Xbox

Select the unavailable option for the current membership result. During a
membership-service failure, use **Try Again** directly from its explanation.
The current implementation enables 1440p and HQ aliases only for a recognized
Game Pass Ultimate account; standard 1080p and 720p remain available after
membership data loads.

### Delivered quality is lower than selected

Selections are requests or ceilings. Verify the Standard statistics display,
network test, account tier, title route, and current service status. The
provider can adapt resolution, FPS, bitrate, codec, color, or audio according
to live conditions.

### HDR or 10-bit color is not delivered in GFN

Use H265, confirm the Apple TV display path supports HDR, and check that the
account and title support HDR. Automatic and Prefer HDR can safely fall back.
The Standard statistics display reports negotiated and decoded results instead
of treating the preference as proof.

### 5.1 audio is not delivered in GFN

Confirm that Apple TV is connected through a surround-capable receiver or
soundbar. Automatic uses the system maximum output-channel count as a heuristic,
which is not a reliable report of the physical sink. tvOS can downmix a 5.1
request. Selecting 5.1 does not force the provider or output route to deliver
six discrete channels.

### L4S causes connection problems

L4S requires compatible network equipment and ISP support. Disable **Low
Latency Mode** and retry the next GFN session if the route behaves poorly with
it enabled.

### A new default did not replace an old preference

This is expected. Provider settings are persisted and decoded with fallback
values for newly added fields. Use the picker or toggle to change a saved value.
Use **Reset All Data** only if you intend to remove the active provider's
account, preferences, favorites, history, and cache.
