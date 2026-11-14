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
| `ASC_KEY_ID` | Key ID of the Team App Store Connect API key |
| `ASC_ISSUER_ID` | Issuer ID shown with the Team keys in App Store Connect |
| `ASC_PRIVATE_KEY` | Entire `.p8` file contents, including the BEGIN/END lines |

6. Under **Settings > Secrets and variables > Actions**, add these two
   **repository secrets**. They contain app identifiers, not credentials:

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | Confirmed Apple Developer Team ID |
| `APPLE_BUNDLE_ID` | Exact Bundle ID of the existing App Store Connect app |

Enable **User Management** for the TestFlight App ID, then generate a new tvOS
App Store distribution profile and replace `APPLE_PROVISIONING_PROFILE_BASE64`.
The signing step checks that the profile authorizes
`runs-as-current-user-with-user-independent-keychain` and that the exported app
carries that entitlement. Free-account sideload builds use single-user storage.

These identifiers are needed by the unsigned build and signing jobs. Keep them
only at repository scope; do not duplicate them in the environment. This keeps
their values out of the workflow source without giving the build job access to
the environment containing signing and upload credentials.

No GitHub variables, numeric Apple ID, Apple account password, or
personal GitHub token are required.
The Team key must be active with the App Manager role.

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
   App Store Connect. **Include external testers** is checked by default. Clear
   it to skip external distribution for this run. You can still add the build
   to an external group later in App Store Connect. Enter optional **What to
   Test** notes when distributing externally. The notes are visible to testers
   and in the workflow run metadata. No app-specific version or build defaults
   are stored.
4. Once the unsigned build succeeds, approve its `testflight` environment job.
   Either `owenselles` or `aarikmudgal` can dispatch and self-approve.
5. After upload, App Store Connect makes the processed build available to
   internal groups with automatic distribution enabled. With **Include external
   testers** checked, the workflow also waits for processing, assigns the build
   to the external **Testers** group, submits it for TestFlight beta review, and
   waits for Apple's decision. Once Apple approves it, the workflow
   sends the available-build notification to eligible testers in that group.
   Apple controls processing and review, so this can take several hours. The
   workflow waits up to five hours after upload; if review is still pending,
   the build remains uploaded, assigned, and submitted, but you must notify
   testers in App Store Connect after approval. If Apple rejects it, inspect the
   review details in App Store Connect.

   The app-level **Beta App Description** and beta-review contact details must
   already be configured in App Store Connect. The workflow only sets the
   optional per-build **What to Test** notes when supplied.

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
no package resolution or app build runs there. The App Store Connect key is
available only to the upload and distribution steps. Each step writes it to a
private temporary file and removes it on exit. Signing files and the temporary
keychain are removed before the workflow waits for Apple's review; hosted runners
are discarded afterward.

Secrets keep configured values out of the workflow source and enable log
masking; they do not make app identifiers confidential. The existing Xcode
project already contains a Team ID. Built archives and apps contain identifiers
and versions, and repository readers can download workflow artifacts. Workflow
inputs and the triggering account also remain visible in GitHub run metadata.
Repository writers can use repository secrets from other workflows; only the
two non-credential identifiers belong there. The public GitHub usernames,
account IDs, repository identity, and reviewed tool pins remain in source so
authorization and dependency changes require code review.

Actions use full commit pins. Uploads use `altool` from the selected Xcode version;
its required options are checked before signing or upload credentials are loaded.
`altool` signs a Team-key JWT using `ASC_ISSUER_ID` as its issuer (`iss`).
No Individual-key user subject (`sub: user`) is sent.

The first credentialed run must confirm archive export and Apple's acceptance
with the supplied certificate, profile, and API key. Local checks cannot prove
those without the credentials. Export/signature failures stop before upload.

References: [GitHub environment protections](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments),
[Apple API tokens](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests),
[Apple build uploads](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).
