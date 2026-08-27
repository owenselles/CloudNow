# Using CloudNow

This guide covers the shared Apple TV experience: first launch, provider
selection, navigation, languages, accounts, and local data. Stream quality and
provider-specific settings are documented in [Streaming settings](StreamingSettings.md).

CloudNow is an independent, unofficial client. A provider can change account,
catalog, or streaming behavior without notice. Check the current requirements
and installation options in the [main README](../README.md).

## First launch and sign-in

1. Open CloudNow and choose **GeForce NOW** or **Xbox Cloud Gaming**.
2. Follow the QR code and PIN instructions shown for that provider. Complete
   authorization on another device.
3. Return to Apple TV. CloudNow opens the selected provider when authorization
   finishes.

The selected provider is remembered. GeForce NOW and Xbox credentials,
preferences, catalogs, favorites, and history are stored separately. Signing
in to one provider does not sign in to the other, and switching providers does
not normally require signing in again.

If a provider cannot start because its bundled service configuration is not
available, its choice is disabled and CloudNow shows the reason. Select the
other provider or install a build with a valid configuration.

## Navigate the app

The provider menu appears at the top left. Each provider then presents its own
tabs:

| Provider | Tabs | Purpose |
|---|---|---|
| GeForce NOW | Home, Library, Store, Settings | Open recent and favorite games, browse the linked cloud library, find catalog titles, or change GFN preferences. |
| Xbox Cloud Gaming | Home, Library, Browse, Settings | Open recent and favorite games, view confirmed playable routes, browse the validated catalog, or change Xbox preferences. |

With a controller, LB and RB move through the provider menu and top-level tabs.
When a stream is active, those buttons are passed to the game instead of moving
through CloudNow navigation.

The Xbox **Library** is intentionally narrower than **Browse**. Library contains
titles with a confirmed playable route for the account. Browse can also show
titles that are unavailable or touch-only on tvOS, together with the reason
when the service provides one.

## Switch providers

Use the top-left provider menu or the **Cloud Service** section in Settings.
CloudNow deactivates the current provider's transient catalog and player state,
then activates the other provider. Saved accounts and preferences remain
separate and are not translated between services.

Only one cloud server session can be owned at a time. If a game is active,
CloudNow asks you to leave or end it before switching:

- **Leave Game** disconnects the local player while preserving a resumable
  provider session when that session supports resume.
- **End Session** closes the provider session.
- A session that was already left and parked must be ended before another
  provider can start a session.

Do not turn off Apple TV while an end operation is still in progress.

## App and game language

### CloudNow interface

CloudNow selects its interface language from the active tvOS language. There is
no separate interface-language setting in the app. Unsupported locales fall
back to English.

### Game language

Game language is a separate provider preference under Settings. **Automatic**
maps the active tvOS language to a locale accepted by the selected provider.
You can also choose a fixed language from the picker. The provider and title
still decide whether localized game content is available.

The manual picker currently includes:

| Language | Provider locale |
|---|---|
| Arabic | `ar_SA` |
| Chinese, Simplified | `zh_CN` |
| Chinese, Traditional | `zh_TW` |
| Croatian | `hr_HR` |
| Czech | `cs_CZ` |
| Danish | `da_DK` |
| Dutch | `nl_NL` |
| English, United States | `en_US` |
| English, United Kingdom | `en_GB` |
| Finnish | `fi_FI` |
| French | `fr_FR` |
| German | `de_DE` |
| Greek | `el_GR` |
| Hebrew | `he_IL` |
| Hindi | `hi_IN` |
| Hungarian | `hu_HU` |
| Indonesian | `id_ID` |
| Italian | `it_IT` |
| Japanese | `ja_JP` |
| Korean | `ko_KR` |
| Malay | `ms_MY` |
| Polish | `pl_PL` |
| Portuguese, Brazil | `pt_BR` |
| Romanian | `ro_RO` |
| Russian | `ru_RU` |
| Slovak | `sk_SK` |
| Spanish, Spain | `es_ES` |
| Swedish | `sv_SE` |
| Turkish | `tr_TR` |
| Ukrainian | `uk_UA` |
| Vietnamese | `vi_VN` |

GFN also has a separate **Keyboard Layout** setting. Its default is derived
from the tvOS locale. Xbox does not expose a keyboard-layout setting.

## Supported tvOS interface locales

CloudNow supports the interface locale identifiers below. Rows group related
identifiers for readability; some regional variants use distinct translations.

| Language | Locale identifiers |
|---|---|
| Arabic | `ar` |
| Catalan | `ca` |
| Chinese, Simplified | `zh-Hans` |
| Chinese, Traditional | `zh-Hant-HK`, `zh-Hant-MO`, `zh-Hant-TW` |
| Croatian | `hr` |
| Czech | `cs` |
| Danish | `da` |
| Dutch | `nl-BE`, `nl-NL` |
| English | `en-AU`, `en-CA`, `en-IN`, `en-IE`, `en-NZ`, `en-SG`, `en-ZA`, `en-GB`, `en-US` |
| Finnish | `fi` |
| French | `fr-BE`, `fr-CA`, `fr-FR`, `fr-CH` |
| German | `de-AT`, `de-DE`, `de-CH` |
| Greek | `el` |
| Hebrew | `he` |
| Hindi | `hi` |
| Hungarian | `hu` |
| Indonesian | `id` |
| Italian | `it-IT`, `it-CH` |
| Japanese | `ja` |
| Korean | `ko` |
| Malay | `ms` |
| Norwegian Bokmål | `nb` |
| Polish | `pl` |
| Portuguese | `pt-BR`, `pt-PT` |
| Romanian | `ro` |
| Russian | `ru` |
| Slovak | `sk` |
| Spanish | `es-AR`, `es-BO`, `es-CL`, `es-CO`, `es-CR`, `es-DO`, `es-EC`, `es-SV`, `es-GT`, `es-HN`, `es-419`, `es-MX`, `es-NI`, `es-PA`, `es-PY`, `es-PE`, `es-PR`, `es-ES`, `es-US`, `es-UY`, `es-VE` |
| Swedish | `sv` |
| Thai | `th` |
| Turkish | `tr` |
| Ukrainian | `uk` |
| Vietnamese | `vi` |

## Accounts, cache, and local data

The following actions always apply to the active provider. Data belonging to
the other provider is kept.

| Settings action | Effect |
|---|---|
| Refresh Library | Reloads the active provider's catalog and account-access data. Xbox always exposes this workflow. GFN exposes it only in builds with provider library synchronization enabled. |
| Clear Cache | Removes cache data owned by the active provider, including its catalog, routing measurements where applicable, and diagnostic logs. The active account and saved settings are preserved. Shared decoded artwork and URL responses are also preserved because they cannot be attributed safely to one provider. |
| Sign Out | Ends an active provider session when possible and disconnects the active provider account. It does not reset the other provider. |
| Reset All Data | Ends the active provider session, signs out, and removes that provider's settings, favorites, history, and provider-owned cached content from this Apple TV. Shared decoded artwork and URL responses are preserved. This cannot be undone. |

Resetting a provider restores that provider's current defaults on the next
setup. Installing an update does not replace preferences that were already
saved.

## Troubleshooting and support

Before opening an issue:

1. Confirm that the intended provider is active and the account has access to
   the selected title.
2. Open Settings and run **Test Network**.
3. Use **Refresh Library** if a title or account entitlement is stale.
4. Use **Clear Cache** if provider-owned catalog, routing, or diagnostic cache
   data is inconsistent. This keeps the account, preferences, shared decoded
   artwork, and shared URL responses.
5. Review [Streaming settings](StreamingSettings.md) if a quality option is
   missing or the delivered stream differs from the selected preference.

Use [GitHub Issues](https://github.com/owenselles/CloudNow/issues) for tracked
bugs and final project decisions. The
[CloudNow Discord community](https://discord.gg/5d9wDJdtBa) is available for
installation help and discussion. Report security vulnerabilities through
[GitHub private vulnerability reporting](https://github.com/owenselles/CloudNow/security/advisories/new),
not through a public issue or Discord.

When reporting a problem, include the active provider, Apple TV model, tvOS
version, title, selected quality settings, and the exact visible error. Do not
post QR codes, PINs, tokens, account identifiers, or other credentials.
