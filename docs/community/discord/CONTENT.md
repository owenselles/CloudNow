# Discord Content Sources

Direct Discord copy lives in [`content/`](content/):

- [`start-here.md`](content/start-here.md)
- [`rules-screening.md`](content/rules-screening.md)
- [`rules.md`](content/rules.md)
- [`faq.md`](content/faq.md)
- [`support-template.md`](content/support-template.md)
- [`contributing.md`](content/contributing.md)
- [`canned-responses.md`](content/canned-responses.md)

> [!WARNING]
> Publishing must fail if an unresolved brace-delimited configuration token
> remains. `{MODERATION_APPEAL_METHOD}` is a launch blocker. Runtime fields in
> canned responses, such as `{CHANNEL}` and `{GITHUB_ISSUE}`, must be replaced
> before each response is sent.
