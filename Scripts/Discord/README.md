# CloudNow local Discord automation

`provision.py` reconciles the Discord server structure in
`docs/community/discord/server.json` using Discord REST API v10 and Python's
standard library. It is dry-run by default, never deletes Discord objects, and
does not create GitHub integrations or webhooks.

`publish_content.py` separately reconciles the reviewed Discord messages in
`docs/community/discord/content/`. Both scripts run from a local checkout; no
GitHub workflow, GitHub token, webhook, or repository secret is involved.

## Prerequisites

1. In the Discord Developer Portal, enable **Guild Install** for the application
   and keep the `bot` install scope. This automation uses only Discord's HTTP API;
   no privileged Gateway intents or public interaction endpoint are needed.
2. Copy the non-secret **Application ID** and generate the exact install URL:

   ```bash
   python3 Scripts/Discord/provision.py \
     --invite-url 'YOUR_APPLICATION_ID'
   ```

   Open the printed URL, choose the target server, and authorize the bot. The URL
   requests the manifest's computed least-privilege union. It never requests
   Administrator. The same integer and readable permission list can be inspected
   with `--print-required-permissions`.
3. In **Server Settings → Roles**, place the bot role above every role this
   manifest will manage. Do not grant Administrator; the provisioner rejects it.
4. Enable **Community** in Discord. During its interactive setup, use or create
   channels named exactly `rules` and `discord-updates`; the provisioner will
   adopt those unique names. Community enablement, Rules Screening, and Server
   Guide remain UI actions because the bot intentionally lacks Administrator and
   Discord no longer documents a Rules Screening edit API.
5. Use a staff account protected by multifactor authentication.

The bot needs the moderation permissions because Discord will not let it create
a role containing a permission that the bot itself lacks, or write channel
overwrites for permissions it lacks. Before any mutation, the provisioner checks
the bot's effective permissions and role position. It also keeps a member
overwrite that lets the bot see managed staff-only channels.

## Inspect, plan, then apply

Set credentials in the process environment. They cannot be passed as CLI
arguments or stored in the manifest. Treat the bot token like a password; never
paste it into chat or commit it.

```bash
export DISCORD_GUILD_ID='1525109547910565958'
export DISCORD_BOT_TOKEN='replace-with-bot-token'
python3 Scripts/Discord/provision.py --inspect
```

`--inspect` performs GET requests only and prints today's guild settings, roles,
channel/category structure, onboarding summary, and AutoMod rules. Then generate
the reconciliation plan:

```bash
python3 Scripts/Discord/provision.py
```

Review every `PLAN:` line. Apply the same manifest explicitly:

```bash
python3 Scripts/Discord/provision.py --apply
```

Useful options:

```text
--manifest PATH       Use another validated manifest.
--state PATH          Use another local managed-ID state file.
--rollback-dir PATH   Store pre-apply snapshots elsewhere.
--reason TEXT         Set the Discord audit-log reason prefix.
--inspect             Print the current server structure; GET requests only.
--invite-url ID       Print the exact bot server-install URL.
--print-required-permissions
                      Print the exact bot permission integer and names.
```

The default state file is `Scripts/Discord/.discord-state.json`. It records only
guild resource IDs and names, never the bot token. Once a resource is adopted by
unique name, its persisted ID lets the script reconcile a later manifest rename
without creating a duplicate. Do not share state between Discord servers.

Every apply writes an owner-readable pre-change snapshot under
`Scripts/Discord/.discord-rollbacks/` before making the first mutation. Snapshots
contain managed role/channel settings, full onboarding data, and managed AutoMod
rules, with secret-like fields redacted. They are evidence for a manual rollback,
not executable rollback scripts. Both local artifact paths are gitignored.

## Publish the reviewed content

Run `provision.py --apply` first. The content publisher resolves channel IDs
only from the provisioner's local `.discord-state.json`; it does not search by
channel or message name.

Set the private moderation appeal wording that should replace the required
token in `rules.md`, then review a dry run:

```bash
export DISCORD_MODERATION_APPEAL_METHOD='the Modmail bot'
python3 Scripts/Discord/publish_content.py
```

`DISCORD_GUILD_ID` and `DISCORD_BOT_TOKEN` must remain set. Publication fails if
the appeal method is empty or another brace-delimited configuration token is
unresolved. Apply the reviewed plan explicitly:

```bash
python3 Scripts/Discord/publish_content.py --apply
```

Useful content-publisher options:

```text
--content-dir PATH    Use another reviewed content source directory.
--core-state PATH     Read channel IDs from another provisioner state file.
--state PATH          Use another local managed-content ID state file.
--rollback-dir PATH   Store redacted pre-apply snapshots elsewhere.
--reason TEXT         Set the Discord audit-log reason prefix.
```

The publisher posts `start-here.md`, `rules.md`, `faq.md`, and
`contributing.md` to their matching channels. It creates a pinned
**Support request template** forum post in `#help` from the pinned-template
section of `support-template.md`. Copy is split at Markdown whitespace
boundaries when needed so every Discord message is at most 2,000 characters.
Every message write disables allowed mentions, and the first managed message in
each standard channel is pinned through Discord's current message-pin route.

The default `Scripts/Discord/.discord-content-state.json` stores only IDs and
content hashes. On the first apply, the publisher always creates its own
messages; it never guesses that an existing user message is managed. Later
runs edit only IDs from that state, validate them against the core channel
state, and never delete messages or posts. Do not remove or share either state
file while continuing to manage the same server.

Every content apply first writes an owner-readable snapshot under the existing
`Scripts/Discord/.discord-rollbacks/` directory. Message bodies are redacted
and represented by their length and SHA-256 digest.

## Reconciliation boundaries

The provisioner:

- creates or updates managed roles, role order, categories, channels, forum tags,
  merged permission overwrites, guild safety settings, Community Onboarding, and
  AutoMod rules;
- adopts an existing object only when its stable name is unique, and fails closed
  on duplicate or ambiguous names;
- retains unmanaged roles, channels, permission overwrites, forum tags,
  onboarding prompts/options/defaults, and AutoMod rules;
- sends an audit-log reason on every supported mutation and respects Discord
  rate-limit responses;
- never prunes or deletes server data.

`rules-screening.md` and `canned-responses.md` intentionally remain manual.
Discord Rules Screening, Server Guide resource pages/to-dos, raid protection,
MFA enforcement, server icon/banner, invite policy, and the new-member
desktop/mobile preview also remain interactive Discord checks.

Run the focused unit suite with:

```bash
python3 -m unittest \
  Scripts/Discord/test_provision.py \
  Scripts/Discord/test_publish_content.py
```
