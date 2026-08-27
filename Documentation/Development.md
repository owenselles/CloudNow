# Development

This guide covers local setup, source builds, development tools, and automated
testing. Read [Architecture](Architecture.md) before changing provider
boundaries, session ownership, or real-time media code. Use
[Release validation](ReleaseValidation.md) for checks that require physical
Apple TV hardware or live provider accounts.

## Requirements

Source development requires:

- macOS with Xcode 26.2 or newer
- A tvOS 26.2 or newer SDK and a compatible tvOS simulator runtime
- An Apple Developer account for device builds; a free account is sufficient
- `python3` for the test runner and repository validation scripts
- Git

CloudNow uses the shared `CloudNow` scheme for development, tests, and release
archives.

## Set up the project

Clone the repository and enter its directory:

```bash
git clone https://github.com/owenselles/CloudNow.git
cd CloudNow
```

Open `CloudNow.xcodeproj` in Xcode. The project already declares
[`livekit/webrtc-xcframework`](https://github.com/livekit/webrtc-xcframework),
and its resolved revision is tracked at
`CloudNow.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Xcode resolves this dependency when needed. Do not add the package manually.

To resolve packages from the command line:

```bash
xcodebuild -resolvePackageDependencies \
  -project CloudNow.xcodeproj \
  -scheme CloudNow
```

### Configure local signing

For a physical-device build, open the `CloudNow` target in Xcode, choose
**Signing & Capabilities**, enable automatic signing, and select your own
development team for the configurations you use. Target-level signing settings
take precedence over base configuration files in the current project.

Selecting a different team may update local project state. Review the Git diff
and avoid committing personal signing identifiers. Keep signing identities,
provisioning profiles, certificates, API keys, and account credentials out of
the repository. Simulator tests disable code signing and do not require an
Apple Developer account.

Select an Apple TV run destination and run the `CloudNow` scheme. Package
resolution and signing happen through the shared project configuration and your
selected team.

## Linting and formatting

The [README linting section](../README.md#linting) is the source of truth for
the required SwiftFormat and SwiftLint versions and non-mutating checks. Verify
the installed versions before running those checks. Do not substitute newer
local releases, since their output can differ from CI.

Homebrew can install the local tools:

```bash
brew install swiftformat swiftlint pre-commit
```

Homebrew may provide a newer version than the repository pins. Check both
versions against the README before using them. If either version differs, use
the pinned pre-commit environment or the matching release artifact referenced
by `.github/workflows/lint.yml`.

After reviewing local changes, you can apply available fixes with:

```bash
swiftformat --config .swiftformat CloudNow CloudNowTests CloudNowUITests
swiftlint --fix --config .swiftlint.yml CloudNow CloudNowTests CloudNowUITests
```

The repository also provides optional pre-commit hooks:

```bash
pre-commit install
```

The hook uses the tool revisions pinned in `.pre-commit-config.yaml`. It runs
SwiftFormat before SwiftLint and may update files in the working tree. When a
hook changes a file, review the result, stage it again, and retry the commit.
Unfixable violations must be corrected manually.

When a SwiftLint rule cannot apply, use the narrowest single-line suppression
and include the reason:

```swift
// swiftlint:disable:next force_cast - reason: layerClass guarantees this type
```

Do not use an unexplained suppression or a file-wide disable for a local
exception.

## Testing

`Scripts/test.sh` runs the shared deterministic tvOS test plan. You can invoke
it from any directory by using its absolute path. From the repository root, use
one of these modes:

| Command | Scope | Coverage gate |
|---|---|---|
| `Scripts/test.sh` | Full unit, integration, and UI suite | Required |
| `Scripts/test.sh --full` | Same as the default invocation | Required |
| `Scripts/test.sh --unit` | `CloudNowTests` only | Required |
| `Scripts/test.sh --ui` | `CloudNowUITests` only | Skipped |

The runner:

1. Validates localization table parity and literal production keys.
2. Runs unit tests for the coverage validator.
3. Selects the newest installed tvOS runtime and the newest compatible Apple TV
   simulator generation.
4. Boots the selected simulator and resolves Swift package dependencies.
5. Runs the `Deterministic` configuration in `CloudNow.xctestplan` with code
   signing disabled and coverage enabled.
6. Produces compact text and JSON coverage reports.

The deterministic configuration uses English, the US region, UTC, and
`CLOUDNOW_DISABLE_LIVE_SERVICES=1`. Tests must not depend on developer account
state or live services.

### Test concurrency

The test script disables parallel Xcode destinations because Xcode 26 can leave
cloned tvOS test destinations running indefinitely. Swift Testing can still run
unit cases in parallel inside the test process. Do not enable parallel Xcode
destinations without proving that full and focused runs complete reliably on
the supported Xcode version.

### Test artifacts

Every run writes to a timestamped, mode-specific directory:

```text
TestArtifacts/<timestamp>-<mode>/CloudNow-<mode>.xcresult
TestArtifacts/<timestamp>-<mode>/Coverage/targets.txt
TestArtifacts/<timestamp>-<mode>/Coverage/targets.json
TestArtifacts/<timestamp>-<mode>/Coverage/required-sources.txt
TestArtifacts/<timestamp>-<mode>/Coverage/required-sources.json
```

`TestArtifacts/` is ignored by Git. CI uploads compact coverage reports for all
runs and retains the full result bundle when a test run fails.

The runner supports these environment overrides for local diagnosis:

| Variable | Purpose |
|---|---|
| `CLOUDNOW_TEST_SCHEME` | Xcode scheme name |
| `CLOUDNOW_TEST_PLAN` | Test plan name |
| `CLOUDNOW_TEST_CONFIGURATION` | Test plan configuration name |
| `CLOUDNOW_TEST_ARTIFACTS_DIR` | Artifact output directory |
| `CLOUDNOW_DERIVED_DATA_PATH` | Explicit Derived Data directory |

Leave the defaults in place for results intended to match CI.

### Coverage contract

Successful full and unit runs require 100 percent xccov executable-line
coverage for the deterministic capability model and both provider adapters:

- `CloudNow/Services/CloudGamingCapabilities.swift`
- `CloudNow/GFN/GFNCapabilityAdapter.swift`
- `CloudNow/Xbox/XboxCapabilityAdapter.swift`

This is a focused regression gate, not a claim of full-project coverage. The
current Swift toolchain reports no usable branch denominator for these sources,
so the gate evaluates executable lines. `Scripts/validate_coverage.py` owns the
required source list and report validation.

### Test code and fixtures

Use Swift Testing for unit and integration coverage in `CloudNowTests`. Reserve
XCTest for `XCUIApplication` automation in `CloudNowUITests`.

Tests must use injected transports, deterministic clocks or state where needed,
and local fakes. They must never contact live provider authentication, catalog,
signaling, artwork, media, or community services.

Place anonymized JSON, SDP, and binary samples under
`CloudNowTests/Fixtures/`, group them by subsystem, and include them in the
`CloudNowTests` target. Fixtures must not contain credentials, tokens, personal
data, or dependencies on production endpoints.

Simulator coverage cannot prove physical display switching, hardware decoding,
controller output, audio route changes, or live service compatibility. Follow
[Release validation](ReleaseValidation.md) when a change touches those areas.

## Localization checks

Production strings use the source tables in `CloudNow/Localization/`. Every
locale must contain the same keys as `L10nEN.swift`, with no duplicates. The
test runner enforces this before it opens the simulator. You can run the check
directly while editing translations:

```bash
python3 Scripts/validate_localizations.py
```

Runtime lookup, placeholder, alias, and fallback behavior belongs in
`CloudNowTests/Localization/`.

## Swift concurrency

The app, unit tests, and UI tests use complete Swift concurrency checking while
remaining in Swift 5 language mode. Keep observable UI state on the main actor.
Use an actor, lock, or serial queue for shared real-time state, and reject stale
callbacks with the owning connection or session generation.

Build concurrency-sensitive streaming changes in both Debug and Release before
submitting them. The automated suite runs the Debug configuration, while the
release workflow archives Release after tests pass on `main`.

## Before opening a pull request

Run the exact non-mutating checks from
[README: Linting](../README.md#linting), then run the smallest useful test mode
during development and the full suite before requesting review. Check
[CONTRIBUTING.md](../CONTRIBUTING.md) for the pull request checklist and
[Release validation](ReleaseValidation.md) for hardware-sensitive changes.
