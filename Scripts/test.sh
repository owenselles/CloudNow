#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Scripts/test.sh [--full | --unit | --ui]

  --full  Run the complete CloudNow test plan (default).
  --unit  Run only the CloudNowTests target.
  --ui    Run only the CloudNowUITests target.
EOF
}

print_command() {
    printf 'Command:'
    printf ' %q' "$@"
    printf '\n'
}

mode="full"
if [[ $# -gt 1 ]]; then
    usage >&2
    exit 64
fi

if [[ $# -eq 1 ]]; then
    case "$1" in
        --full)
            mode="full"
            ;;
        --unit)
            mode="unit"
            ;;
        --ui)
            mode="ui"
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
fi

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_directory/.." && pwd)"
project_path="$repository_root/CloudNow.xcodeproj"
scheme_name="${CLOUDNOW_TEST_SCHEME:-CloudNow}"
test_plan_name="${CLOUDNOW_TEST_PLAN:-CloudNow}"
test_configuration_name="${CLOUDNOW_TEST_CONFIGURATION:-Deterministic}"
artifact_root="${CLOUDNOW_TEST_ARTIFACTS_DIR:-$repository_root/TestArtifacts}"
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
run_directory="$artifact_root/$timestamp-$mode"
result_bundle="$run_directory/CloudNow-$mode.xcresult"
coverage_directory="$run_directory/Coverage"

cd "$repository_root"
mkdir -p "$coverage_directory"

localization_check_command=(
    python3
    "$repository_root/Scripts/validate_localizations.py"
)
print_command "${localization_check_command[@]}"
"${localization_check_command[@]}"

if ! simulator_record="$(
    xcrun simctl list devices available --json |
        python3 -c '
import json
import re
import sys

payload = json.load(sys.stdin)
candidates = []

def hardware_rank(device):
    identifier = device.get("deviceTypeIdentifier", "")
    generation_match = re.search(
        r"-(\d+)(?:st|nd|rd|th)-generation(?:-|$)",
        identifier,
    )
    generation = int(generation_match.group(1)) if generation_match else 0
    supports_4k = int("-4K" in identifier)
    native_resolution = int(not identifier.endswith("-1080p"))
    return (generation, supports_4k, native_resolution)

for runtime, devices in payload.get("devices", {}).items():
    match = re.search(r"\.tvOS-(\d+(?:-\d+)*)$", runtime)
    if match is None:
        continue

    version = tuple(int(component) for component in match.group(1).split("-"))
    for device in devices:
        if not device.get("isAvailable", False):
            continue
        candidates.append(
            (
                version,
                hardware_rank(device),
                device.get("name", ""),
                device.get("udid", ""),
                device.get("state", ""),
                runtime,
            )
        )

if not candidates:
    sys.exit(1)

newest_runtime = max(candidate[0] for candidate in candidates)
newest_candidates = [
    candidate for candidate in candidates if candidate[0] == newest_runtime
]
newest_hardware = max(candidate[1] for candidate in newest_candidates)
newest_candidates = [
    candidate for candidate in newest_candidates
    if candidate[1] == newest_hardware
]
selected = min(
    newest_candidates,
    key=lambda candidate: (candidate[2].casefold(), candidate[3]),
)
print("\t".join((selected[3], selected[2], selected[5], selected[4])))
'
)"; then
    echo "error: no available tvOS simulator was found." >&2
    exit 1
fi

IFS=$'\t' read -r simulator_udid simulator_name simulator_runtime simulator_state \
    <<<"$simulator_record"

if [[ -z "$simulator_udid" ]]; then
    echo "error: simulator selection returned an empty device identifier." >&2
    exit 1
fi

echo "Selected simulator: $simulator_name ($simulator_udid)"
echo "Runtime: $simulator_runtime"

if [[ "$simulator_state" != "Booted" ]]; then
    if ! xcrun simctl boot "$simulator_udid"; then
        echo "Simulator boot request did not complete; checking current boot status."
    fi
fi
xcrun simctl bootstatus "$simulator_udid" -b

resolve_command=(
    xcodebuild
    -resolvePackageDependencies
    -project "$project_path"
    -scheme "$scheme_name"
)
print_command "${resolve_command[@]}"
"${resolve_command[@]}"

destination="platform=tvOS Simulator,id=$simulator_udid"
# Xcode 26 can strand tvOS test runners while creating cloned simulator
# destinations, including unit-only runs. Swift Testing still executes cases
# in parallel within the unit-test process, so serialize Xcode destinations.
parallel_testing="NO"
test_command=(
    xcodebuild
    -project "$project_path"
    -scheme "$scheme_name"
    -testPlan "$test_plan_name"
    -only-test-configuration "$test_configuration_name"
    -configuration Debug
    -destination "$destination"
    -resultBundlePath "$result_bundle"
    -enableCodeCoverage YES
    -parallel-testing-enabled "$parallel_testing"
    -collect-test-diagnostics never
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
)

case "$mode" in
    unit)
        test_command+=("-only-testing:CloudNowTests")
        ;;
    ui)
        test_command+=("-only-testing:CloudNowUITests")
        ;;
esac
test_command+=(test)

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export TZ="UTC"
export CLOUDNOW_DISABLE_LIVE_SERVICES="1"

print_command "${test_command[@]}"
set +e
"${test_command[@]}"
test_status=$?
set -e

coverage_status=0
if [[ -d "$result_bundle" ]]; then
    coverage_text_command=(
        xcrun xccov view --report --only-targets "$result_bundle"
    )
    print_command "${coverage_text_command[@]}"
    if "${coverage_text_command[@]}" >"$coverage_directory/targets.txt"; then
        :
    else
        coverage_status=$?
    fi

    coverage_json_command=(
        xcrun xccov view --report --only-targets --json "$result_bundle"
    )
    print_command "${coverage_json_command[@]}"
    if "${coverage_json_command[@]}" >"$coverage_directory/targets.json"; then
        :
    else
        coverage_status=$?
    fi
elif [[ $test_status -eq 0 ]]; then
    echo "error: xcodebuild succeeded without creating a result bundle." >&2
    coverage_status=1
fi

echo "Result bundle: $result_bundle"
echo "Coverage summary: $coverage_directory"

if [[ $test_status -ne 0 ]]; then
    exit "$test_status"
fi

if [[ $coverage_status -ne 0 ]]; then
    exit "$coverage_status"
fi
