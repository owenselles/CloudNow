# Discord Content Sources

Direct Discord copy lives in [`content/`](content/):

- [`start-here.md`](content/start-here.md)
- [`rules-screening.md`](content/rules-screening.md)
- [`rules.md`](content/rules.md)
- [`faq.md`](content/faq.md)
- [`support-template.md`](content/support-template.md)
- [`known-issues.md`](content/known-issues.md)
- [`feature-discussion.md`](content/feature-discussion.md)
- [`contributing.md`](content/contributing.md)
- [`canned-responses.md`](content/canned-responses.md)

> [!WARNING]
> Publishing must fail if an unresolved brace-delimited configuration token
> remains. `{MODERATION_APPEAL_METHOD}` is a launch blocker. Runtime fields in
> canned responses, such as `{CHANNEL}` and `{GITHUB_ISSUE}`, must be replaced
> before each response is sent.

Local publication also extracts the final staff-only starter from
`canned-responses.md` into `#security-response`. Replacement mode keeps that
starter exact but preserves staff incident messages. It makes the six public
managed content channels exact and keeps the two bot-owned `#help` reference
posts exact and locked. `Support request template` is the forum's single pinned
thread; `Help forum guidelines` remains unpinned.
