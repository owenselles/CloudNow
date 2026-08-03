# Discord Access Model

`server.json` is the source of truth for Discord roles, channel permissions,
native Community Onboarding, and the explicit obsolete-resource cleanup list.
The local provisioning bot configures this model; it does not need to remain
online afterward.

## New-member access

Before choosing interests, a member can see these onboarding defaults:

- Read-only: `#start-here`, `#rules`, `#announcements`
- Writable: `#general`, `#introductions`, `#showcase`,
  `#feature-discussion`, `#off-topic`

Discord requires at least seven default channels, including five where
`@everyone` can send messages, while Community Onboarding is enabled. Every
other managed channel denies `VIEW_CHANNEL` to `@everyone` and requires an
explicit role mapping.

## Self-selected access

Discord's native Onboarding assigns these unprivileged roles:

| Selection | Assigned role | Additional access |
| --- | --- | --- |
| Help and troubleshooting | Support Interest | `#help`, `#support-resources`, `#known-issues`, `#faq` |
| Releases | Releases | `#releases` |
| Development | Developer Interest | `#development`, `#contributing`, `#pull-requests`, `#community-projects` |
| Localization | Localization Interest | `#localization` |
| Beta updates | Beta Updates | `#testing` |
| Voice | Voice Access | `Lounge`, `Pair Debugging` |

These roles have no guild-level permissions. They only re-enable
`VIEW_CHANNEL` through manifest-controlled overwrites, so members cannot use
Onboarding to obtain staff or moderation capabilities.

## Assigned roles

- `Beta Tester` also unlocks `#testing`.
- `Translator` also unlocks `#localization`.
- `Contributor` and `Project Maintainer` can access development channels.
- `Support Team` can access support and its intended staff channels.
- `Moderator` and `Server Admin` receive explicit staff access. Voice
  moderation is limited to those two roles.

## Authoritative reconciliation

With `"authoritative": true`, the provisioner removes undeclared permission
overwrites, forum tags, and Onboarding entries from managed resources. Whole
roles, channels, and categories are deleted only when their exact Discord ID,
name, and type are listed under `cleanup` and the operator supplies the
destructive-cleanup flag.

Unknown resources are reported but retained. This prevents accidental deletion
of future Discord integrations or third-party bot roles.
