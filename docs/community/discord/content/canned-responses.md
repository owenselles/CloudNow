# Staff Canned Responses

Replace every runtime field before sending. `{MODERATION_APPEAL_METHOD}` is not
a runtime field; it must be configured before launch.

## Wrong channel

Thanks for posting. This discussion belongs in `{CHANNEL}`, so we are
redirecting it there to keep the server organized.

## Missing support information

Please edit your post using the support template. We need the release tag,
TestFlight build number, or commit SHA; Apple TV model; tvOS version;
installation route; and reproduction steps.

Do not include credentials, tokens, login codes, QR codes, personal data, or
unredacted logs.

## Existing issue

This appears to match `{GITHUB_ISSUE}`. Add new reproduction details there
rather than opening a duplicate. This thread can remain open for
troubleshooting.

## NVIDIA account or billing issue

CloudNow and this community cannot access NVIDIA accounts, subscriptions,
billing, queues, or enforcement systems. Contact NVIDIA through its official
support channels. Do not send anyone here a password, PIN, QR code, or
authentication token.

## Unrecognized distribution

This build or listing is not one of the current repository-documented
installation routes. There is no CloudNow App Store release. Remove it and use
TestFlight, a release IPA, or source-build instructions linked from:

https://github.com/owenselles/CloudNow#installation

Community support may be limited for modified builds.

## Sensitive information exposed

Your message contained potentially sensitive information and was removed from
public view. Rotate or revoke the exposed credential or session immediately
when applicable. Contact staff privately if you need help identifying what was
exposed, but do not resend the secret.

## Suspected vulnerability posted in Discord

Your message may describe a security vulnerability, so its public copy was
removed. Do not repost the details or send them to staff by direct message.
Submit the report through:

https://github.com/owenselles/CloudNow/security/advisories/new

GitHub private vulnerability reporting is the canonical route.
`#security-response` is a private staff coordination channel, not a reporting
endpoint.

## Feature request expectations

Community interest helps maintainers understand demand, but discussions and
reactions are not commitments or release dates. Add a concrete use case,
expected behavior, and relevant platform constraints.

## Conversation becoming hostile

Pause personal remarks and return to the technical issue. Disagreement is
allowed; insults, accusations, dogpiling, and hostile speculation are not.
Further escalation may result in moderation action.

## Moderation appeal

Moderation discussion will not continue in public. Submit an appeal privately
through `{MODERATION_APPEAL_METHOD}`. Do not include account credentials or
unrelated personal data.

## Staff-only `#security-response` Starter

This channel coordinates staff response after a report exists in GitHub private
vulnerability reporting or after a secret is exposed in Discord. It is not a
member-facing vulnerability intake channel.

- Move vulnerability details to the GitHub advisory; GitHub private
  vulnerability reporting is the canonical route.
- Remove exposed secrets from public view; advise the member to rotate or revoke
  them.
- Do not ask members to post vulnerability details, credentials, tokens, PINs,
  or QR codes in Discord.
- Copy only the minimum context needed. Keep vulnerability material in the
  GitHub private advisory, remove it from Discord after handoff, and never
  retain exposed credentials.
