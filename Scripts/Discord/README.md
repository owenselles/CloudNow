# CloudNow local Discord automation

`provision.py` reconciles the Discord server structure in
`docs/community/discord/server.json` using Discord REST API v10 and Python's
standard library. It is dry-run by default. The manifest is authoritative for
managed permission overwrites, forum tags, and Community Onboarding. Exact
legacy IDs declared under `cleanup` can be removed only with the explicit
`--cleanup-obsolete` flag.

`publish_content.py` separately reconciles the reviewed Discord messages in
`docs/community/discord/content/`. Both scripts run from a local checkout; no
GitHub workflow, GitHub token, webhook, or repository secret is involved.

## Prerequisites

1. In the Discord Developer Portal, enable **Guild Install** for the application
   and keep the `bot` install scope. No public interaction endpoint is needed.
   For the one-time legacy-role migration, also enable **Server Members Intent**.
   Enable **Message Content Intent** before every
   `--replace-existing-content` plan or apply. The publisher verifies the
   application flag through Discord and refuses replacement when it is absent;
   Discord otherwise hides message bodies and attachments from HTTP responses.
   These intents may be disabled between local runs, but must be re-enabled for
   each future exact-content convergence check. Native Onboarding and AutoMod
   continue to work without a locally running bot.
2. Copy the non-secret **Application ID** and generate the exact install URL:

   ```bash
   python3 Scripts/Discord/provision.py \
     --invite-url 'YOUR_APPLICATION_ID'
   ```

   Open the printed URL, choose the target server, and authorize the bot. The URL
   requests the manifest's computed least-privilege union. It never requests
   Administrator. The same integer and readable permission list can be inspected
   with `--print-required-permissions`.
3. For the default least-privilege path, place the bot role above every role this
   manifest will manage. Do not grant Administrator. If the bot already has
   temporary Administrator, use the explicit bootstrap flow below instead.
4. For the default path, enable **Community** in Discord and use or create
   channels named exactly `rules` and `discord-updates`; the provisioner adopts
   those unique names. Administrator bootstrap creates both channels and enables
   Community automatically. Rules Screening and Server Guide remain UI actions
   because Discord does not document APIs for their full configuration.
5. Use a staff account protected by multifactor authentication.

The bot needs the moderation permissions because Discord will not let it create
a role containing a permission that the bot itself lacks, or write channel
overwrites for permissions it lacks. Before any mutation, the provisioner checks
the bot's effective permissions and role position. It also keeps a member
overwrite that lets the bot see managed staff-only channels.

### Temporary Administrator bootstrap

If the bot already has Administrator for the first setup, keep that permission
temporarily and opt in explicitly:

```bash
python3 Scripts/Discord/provision.py --bootstrap-from-administrator
python3 Scripts/Discord/provision.py \
  --bootstrap-from-administrator \
  --apply
```

The apply creates or updates a non-managed `CloudNow Provisioner` role with the
exact computed permission set, positions it below the bot's highest role,
assigns it to the bot, creates the required Community channels, and enables
Community when needed. It does not remove Administrator. After structure and
content publication succeed, remove Administrator in Discord; subsequent runs
work through `CloudNow Provisioner` without the bootstrap flag. If a future
manifest needs permissions absent from that role, temporarily restore
Administrator and rerun the bootstrap. Discord does not allow a bot to manage
roles at or above its highest role, even with Administrator.

The legacy `Admin` role is intentionally not in automated cleanup because it is
currently the bot's highest role. After a zero-drift run, assign `Server Admin`
to the human owner, remove `Admin`/Administrator from the bot, then delete that
legacy role in Discord if no person still needs it. Discord's role hierarchy
prevents the bot from safely deleting its own highest role.

## Inspect, plan, then apply

Copy the tracked environment template, fill its private copy, and load it into
the current shell. `.env.discord.local` is ignored by Git. Treat the bot token
like a password; never paste it into chat or commit it.

```bash
cp Scripts/Discord/.env.example Scripts/Discord/.env.discord.local
chmod 600 Scripts/Discord/.env.discord.local
# Edit Scripts/Discord/.env.discord.local and add the bot token.
set -a
source Scripts/Discord/.env.discord.local
set +a
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

For the audited one-time CloudNow migration, include the exact obsolete
resources declared by ID in `server.json`:

```bash
python3 Scripts/Discord/provision.py \
  --bootstrap-from-administrator \
  --cleanup-obsolete

python3 Scripts/Discord/provision.py \
  --bootstrap-from-administrator \
  --cleanup-obsolete \
  --apply
```

`--cleanup-obsolete --apply` deletes the declared legacy channels, categories,
and roles. Channel deletion is irreversible and the structural rollback
snapshot does not contain channel messages, forum threads, or attachments.
Review the dry run and preserve anything wanted from those exact legacy
channels before applying.

Useful options:

```text
--apply               Perform mutations; omitted means dry-run.
--bootstrap-from-administrator
                      Allow temporary Administrator; create and assign the
                      least-privilege CloudNow Provisioner role.
--cleanup-obsolete    Include only exact ID/name/type cleanup targets declared
                      in the manifest; deletion still requires --apply.
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
Apply mode holds an exclusive lock from state loading through completion.

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
token in `rules.md` through `.env.discord.local`, then review a dry run:

```bash
python3 Scripts/Discord/publish_content.py \
  --replace-existing-content
```

`DISCORD_GUILD_ID` and `DISCORD_BOT_TOKEN` must remain set. Publication fails if
the appeal method is empty or another brace-delimited configuration token is
unresolved. Apply the reviewed plan explicitly:

```bash
python3 Scripts/Discord/publish_content.py \
  --replace-existing-content \
  --apply
```

`--replace-existing-content` makes six public managed content channels
authoritative. Before the first message deletion, apply mode writes an
owner-only recovery bundle containing full API payloads and downloaded bytes
for every attachment. It then re-fetches every deletion candidate and aborts
all deletion if content changed after backup. It never scans or deletes
unrelated `#help` posts or replies. The private `#security-response` starter is
managed and pinned, but staff incident history in that channel is retained.
Replacement also fails closed on non-deletable Discord system messages, source
messages with child threads, or rich attachment media lacking durable size
metadata; preserve or remove those exceptional items manually before rerunning.

Useful content-publisher options:

```text
--replace-existing-content
                      Replace non-managed content only in authoritative
                      channels and obsolete managed chunks elsewhere; requires
                      --apply to delete and writes a recovery bundle first.
--content-dir PATH    Use another reviewed content source directory.
--core-state PATH     Read channel IDs from another provisioner state file.
--state PATH          Use another local managed-content ID state file.
--rollback-dir PATH   Store redacted snapshots and sensitive recovery bundles
                      elsewhere.
--reason TEXT         Set the Discord audit-log reason prefix.
```

The publisher posts `start-here.md`, `rules.md`, `faq.md`, `contributing.md`,
the support-resources section of `support-template.md`, and `known-issues.md`
to their matching channels. It pins but does not make member history
authoritative in writable `#feature-discussion`, using
`feature-discussion.md`, and private `#security-response`, using the final
starter from `canned-responses.md`. It creates two locked reference posts in
`#help`: **Support request template** is the forum's single pinned thread, while
**Help forum guidelines** remains unpinned because Discord rejects a second
forum pin. It resolves the live `Other` tag required by the forum and removes
unrelated tags from both posts. Copy is split at Markdown whitespace boundaries
when needed so every Discord message is at most 2,000 characters. Every message
write disables allowed mentions, and the first managed message in each standard
channel is pinned through Discord's current message-pin route.

The default `Scripts/Discord/.discord-content-state.json` stores only IDs and
content hashes. On the first apply, the publisher always creates its own
messages; it never guesses that an existing user message is managed. Later
runs edit only IDs from that state. Before any mutation, they must resolve to
the expected live channel in this guild, and every tracked message/help thread
must be owned by the provisioning bot. If a tracked message or managed help
post was manually deleted, the publisher safely removes the stale binding and
recreates it; a recreated core channel also resets its old content binding.
Deletion occurs only with `--replace-existing-content`. Do not remove or share
either state file while continuing to manage the same server.

Apply mode holds an exclusive owner-only lock for the complete state load and
reconciliation. Before each message or forum-post create, it durably records a
pending-create journal. A rerun adopts the exact bot-authored object after an
interruption instead of creating a duplicate; ambiguous matches fail closed.

Every content apply first writes an owner-readable snapshot under the existing
`Scripts/Discord/.discord-rollbacks/` directory. Message bodies are redacted
and represented by their length and SHA-256 digest. Content replacement writes
an additional clearly labelled sensitive JSON snapshot plus a sibling
`.attachments/` directory containing verified binary attachment copies. Files
are owner-only and flushed before the first deletion. This is a manual repost
aid, not an exact Discord rollback: Discord cannot recreate original message
IDs, authors, timestamps, reactions, or poll votes.

## Reconciliation boundaries

The provisioner:

- creates or updates managed roles, role order, categories, channels, forum tags,
  merged permission overwrites, guild safety settings, Community Onboarding, and
  AutoMod rules;
- adopts an existing object only when its stable name is unique, and fails closed
  on duplicate or ambiguous names; singleton AutoMod trigger types are also
  adopted by their immutable trigger type because Discord permits only one;
- exactly reconciles permission overwrites, forum tags, and Onboarding when the
  manifest enables authoritative mode;
- deletes only obsolete whole roles, channels, and categories whose exact ID,
  name, and type are declared in the cleanup allowlist and whose destructive
  flag was supplied;
- retains unknown whole roles, channels, categories, and AutoMod rules so a
  future integration is never deleted merely because it is unknown;
- migrates members from declared legacy roles before deleting those roles;
- sends an audit-log reason on every supported mutation and respects Discord
  rate-limit responses.

Authoritative overwrites remove manual role/member/integration overwrites from
managed categories and channels unless the target is declared by the manifest
or is the provisioning bot's guarded access overwrite. Add future integration
access to `server.json` before applying.

See [`docs/community/discord/ACCESS.md`](../../docs/community/discord/ACCESS.md)
for new-member defaults and role-to-channel mapping.

Reusable canned responses intentionally remain manual; only their
`#security-response` starter section is published. `rules-screening.md`,
Discord Rules Screening, Server Guide resource pages/to-dos, raid protection,
MFA enforcement, server icon/banner, invite policy, and the new-member
desktop/mobile preview remain interactive Discord checks.

Run the focused unit suite with:

```bash
python3 -m unittest \
  Scripts/Discord/test_provision.py \
  Scripts/Discord/test_publish_content.py
```
