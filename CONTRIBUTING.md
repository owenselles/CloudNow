# Contributing

Contributions to CloudNow are welcome. Keep each pull request focused on one
problem so its behavior, provider impact, and validation are easy to review.

## Before you start

Search [existing issues](https://github.com/owenselles/CloudNow/issues) and pull
requests before opening a new one. Use an issue to discuss a broad feature,
protocol change, or behavior whose intended result is still unclear.

Report security problems through
[GitHub private vulnerability reporting](https://github.com/owenselles/CloudNow/security/advisories/new).
Do not include credentials, access tokens, private account data, or production
service captures in a public issue or pull request.

Read the documentation that owns the area you plan to change:

- [Development](Documentation/Development.md) covers source setup, tools, tests,
  fixtures, coverage, and concurrency.
- [Architecture](Documentation/Architecture.md) defines shared and
  provider-owned boundaries.
- [Release validation](Documentation/ReleaseValidation.md) covers physical
  Apple TV and live provider checks.
- [README: Linting](README.md#linting) contains the canonical tool versions and
  required non-mutating checks.

## Prepare the change

Create a branch from the latest `main`. Preserve the independent GFN and Xbox
account, catalog, session, signaling, quality, input, and lifecycle paths.
Shared code should remain provider-neutral and should not translate one
provider's protocol into the other.

Add or update tests for behavior that can run deterministically. Use anonymized
fixtures and injected dependencies instead of live service calls. Update
localization tables when UI text changes, and update the canonical document when
a user-facing setting, limitation, development contract, or architecture rule
changes.

Write code, comments, commit messages, and pull request text in US English.

## Verify the change

Before requesting review:

1. Run the exact SwiftFormat and SwiftLint checks from
   [README: Linting](README.md#linting).
2. Run the relevant focused test mode while developing, then run the complete
   `Scripts/test.sh` suite. See [Development](Documentation/Development.md#testing).
3. Complete the applicable checks in
   [Release validation](Documentation/ReleaseValidation.md) when behavior
   depends on physical hardware, provider accounts, or live services.
4. Review the final diff for secrets, unrelated generated files, and accidental
   changes to provider-owned behavior.

If a required check cannot run locally, state which check was skipped, why it
was unavailable, and what evidence was used instead.

## Open the pull request

Include:

- A concise description of the problem and the resulting behavior
- Links to related issues or earlier pull requests
- The test commands and manual checks you ran
- Screenshots or a short recording for visible tvOS changes
- Any known compatibility, migration, or follow-up work

Describe provider-specific effects explicitly. A change that affects only GFN
or only Xbox should say so, and a shared change should explain how both paths
were protected.
