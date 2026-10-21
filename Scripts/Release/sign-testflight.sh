#!/bin/bash
set +x
set -euo pipefail
umask 077

signing_dir="${RUNNER_TEMP:?}/testflight-signing"
keychain="$signing_dir/signing.keychain-db"
profiles_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

cleanup() {
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    if [[ -f "$signing_dir/profile.installed" ]]; then
        local profile_id
        profile_id=$(cat "$signing_dir/profile.uuid")
        if [[ "$profile_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
            rm -f "$profiles_dir/$profile_id.mobileprovision"
        fi
    fi
    rm -rf "$signing_dir"
}

if [[ "${1:-}" == "--cleanup" ]]; then
    cleanup
    exit 0
fi

mkdir -p "$signing_dir"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 --decode > "$signing_dir/certificate.p12"
printf '%s' "$APPLE_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$signing_dir/profile.mobileprovision"
security cms -D -i "$signing_dir/profile.mobileprovision" > "$signing_dir/profile.plist"

keychain_password=$(openssl rand -hex 32)
printf '::add-mask::%s\n' "$keychain_password"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$signing_dir/certificate.p12" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
unset APPLE_CERTIFICATE_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_PROVISIONING_PROFILE_BASE64
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain"
identity=$(security find-identity -v -p codesigning "$keychain" | awk '/"Apple Distribution:/ { print $2 }')
[[ "$identity" =~ ^[0-9A-Fa-f]{40}$ ]] || { echo "Expected one valid Apple Distribution identity" >&2; exit 1; }

CERTIFICATE_SHA1="$identity" python3 - <<'PY'
import os
import pathlib
import plistlib
import re

directory = pathlib.Path(os.environ["RUNNER_TEMP"]) / "testflight-signing"
profile = plistlib.loads((directory / "profile.plist").read_bytes())
team, bundle = os.environ["APPLE_TEAM_ID"], os.environ["APPLE_BUNDLE_ID"]
entitlements = profile.get("Entitlements", {})
if not (
    team in profile.get("TeamIdentifier", [])
    and "tvOS" in profile.get("Platform", [])
    and entitlements.get("application-identifier") == f"{team}.{bundle}"
    and entitlements.get("com.apple.developer.team-identifier") == team
    and entitlements.get("get-task-allow") is False
    and "ProvisionedDevices" not in profile
    and not profile.get("ProvisionsAllDevices", False)
):
    raise SystemExit("Expected a matching tvOS App Store distribution profile")
identifier = profile.get("UUID", "")
if not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", identifier):
    raise SystemExit("Invalid provisioning profile UUID")
(directory / "profile.uuid").write_text(identifier)
options = {
    "method": "app-store-connect",
    "destination": "export",
    "signingStyle": "manual",
    "signingCertificate": os.environ["CERTIFICATE_SHA1"],
    "provisioningProfiles": {bundle: identifier},
    "teamID": team,
    "manageAppVersionAndBuildNumber": False,
}
(directory / "ExportOptions.plist").write_bytes(plistlib.dumps(options))
PY

profile_id=$(cat "$signing_dir/profile.uuid")
mkdir -p "$profiles_dir"
test ! -e "$profiles_dir/$profile_id.mobileprovision"
touch "$signing_dir/profile.installed"
cp "$signing_dir/profile.mobileprovision" "$profiles_dir/$profile_id.mobileprovision"
xcodebuild -exportArchive \
    -archivePath "$RUNNER_TEMP/testflight/CloudNow.xcarchive" \
    -exportPath "$RUNNER_TEMP/testflight-export" \
    -exportOptionsPlist "$signing_dir/ExportOptions.plist"

ditto -x -k "$RUNNER_TEMP/testflight-export/CloudNow.ipa" "$signing_dir/exported"
app="$signing_dir/exported/Payload/CloudNow.app"
codesign --verify --deep --strict "$app"
codesign --display --entitlements - "$app" > "$signing_dir/signed-entitlements.plist"
python3 - <<'PY'
import os
import pathlib
import plistlib

path = pathlib.Path(os.environ["RUNNER_TEMP"]) / "testflight-signing/signed-entitlements.plist"
entitlements = plistlib.loads(path.read_bytes())
team, bundle = os.environ["APPLE_TEAM_ID"], os.environ["APPLE_BUNDLE_ID"]
if not (
    entitlements.get("application-identifier") == f"{team}.{bundle}"
    and entitlements.get("com.apple.developer.team-identifier") == team
    and entitlements.get("get-task-allow", False) is False
):
    raise SystemExit("Exported IPA has unexpected signing entitlements")
PY
