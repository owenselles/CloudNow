# Manual TestFlight releases

`Release to TestFlight` is a separate, manual workflow. `Build and Release IPA`
continues automatically after successful tests on `main`, with its existing
sideload identity. No existing IPA is reused: TestFlight builds independently as
the app identified by the configured bundle and team secrets.

## Required GitHub setup

The repository owner must configure these settings before adding credentials:

1. Protect `main`: require pull requests, successful Tests/Lint checks, and code
   owner approval. Dismiss stale approvals, require approval of the latest push,
   and prevent direct pushes, force pushes, and bypasses.
2. In **Settings > Environments**, create `testflight`.
3. Set deployment branches to **Selected branches and tags**, with exactly one
   **branch** rule: `main`. Add no tag rules or wildcards.
4. Set required reviewers to exactly `owenselles` and `aarikmudgal`. Leave
   **Prevent self-review** off so either person can approve their own release.
   Disable **Allow administrators to bypass configured protection rules**.
5. Add the following credentials as **environment secrets inside `testflight`**.
   Do not duplicate them as repository or organization secrets.

| Secret | Value |
|---|---|
| `APPLE_CERTIFICATE_BASE64` | Base64 of the Apple Distribution `.p12`, including its private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting that `.p12` |
| `APPLE_PROVISIONING_PROFILE_BASE64` | Base64 of the tvOS App Store distribution `.mobileprovision` for the configured bundle ID, matching the certificate |
| `ASC_KEY_ID` | Key ID of the Individual App Store Connect API key |
| `ASC_PRIVATE_KEY` | Entire `.p8` file contents, including the BEGIN/END lines |

6. Under **Settings > Secrets and variables > Actions**, add these two
   **repository secrets**. They contain app identifiers, not credentials:

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | Confirmed Apple Developer Team ID |
| `APPLE_BUNDLE_ID` | Exact Bundle ID of the existing App Store Connect app |

These identifiers are needed by the unsigned build and signing jobs. Keep them
only at repository scope; do not duplicate them in the environment. This keeps
their values out of the workflow source without giving the build job access to
the environment containing signing and upload credentials.

No GitHub variables, numeric Apple ID, Issuer ID, Apple account password, or
personal GitHub token are required.
The Individual key must retain App Manager access to CloudNow. Its permissions
follow its Apple account; it cannot manage provisioning profiles.

For binary secrets, these local commands copy base64 to the macOS clipboard:

```bash
base64 -i /path/to/distribution.p12 | pbcopy
base64 -i /path/to/profile.mobileprovision | pbcopy
```

Paste each result into its corresponding environment secret. Paste the `.p8`
as text. Never commit or upload private signing files as workflow artifacts.

## Release

1. After merging this workflow, wait for Tests and Lint on the intended `main`
   commit to pass. Complete applicable [release validation](ReleaseValidation.md).
2. Open **Actions > Release to TestFlight > Run workflow** and select `main`.
3. Enter the intended version and a new, unused build number after checking
   App Store Connect. No app-specific version or build defaults are stored.
4. Once the unsigned build succeeds, approve its `testflight` environment job.
   Either `owenselles` or `aarikmudgal` can dispatch and self-approve.
5. Check App Store Connect for processing, export-compliance questions, and
   TestFlight group availability. External testing can require Apple's beta
   review. The workflow uploads a build; it does not submit an App Store release
   or change tester groups.

Re-runs are deliberately rejected, including re-running only the upload job.
Start a new manual run. If Apple already accepted the previous upload, use a new
build number. Releases are serialized; avoid queuing several versions at once.

## Security and maintenance

The first step checks the triggering username, then the immutable GitHub account
ID. Only `owenselles` and `aarikmudgal` qualify. GitHub still lets other repository
writers press Run; their runs fail before checkout. Forks and non-main runs fail.
Environment branch restrictions and required reviewers protect secrets even if a
writer changes the YAML on another branch. These settings are essential; YAML
alone cannot enforce them. Administrators can still reconfigure protections.

Compilation receives only the two app identifiers on a separate hosted runner,
without signing or upload credentials. Signing downloads only the same run's
artifact by ID, checks its SHA-256, and safely extracts it. Only release scripts
from the workflow commit run beside credentials;
no package resolution or app build runs there. The upload key is available only
to the upload step, and its short-lived Individual JWT is masked. Signing files
and the temporary keychain are removed; hosted runners are discarded afterward.

Secrets keep configured values out of the workflow source and enable log
masking; they do not make app identifiers confidential. The existing Xcode
project already contains a Team ID. Built archives and apps contain identifiers
and versions, and repository readers can download workflow artifacts. Workflow
inputs and the triggering account also remain visible in GitHub run metadata.
Repository writers can use repository secrets from other workflows; only the
two non-credential identifiers belong there. The public GitHub usernames,
account IDs, repository identity, and reviewed tool pins remain in source so
authorization and dependency changes require code review.

Actions use full commit pins. Apple Transporter is downloaded from Apple's
official endpoint and checked against a reviewed installer SHA-256 before any
signing or upload credentials are used. If Apple replaces the installer, the checksum check
stops the release until the new package is verified and its pin updated.

The first credentialed run must confirm archive export and Apple's acceptance
with the supplied certificate, profile, and API key. Local checks cannot prove
those without the credentials. Export/signature failures stop before upload.

References: [GitHub environment protections](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments),
[Apple Individual API tokens](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests),
[Apple Transporter](https://help.apple.com/itc/transporteruserguide/en.lproj/static.html).
