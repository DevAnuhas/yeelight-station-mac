#!/bin/bash
set -euo pipefail
umask 077

# Credentials must already exist in a notarytool Keychain profile. This script
# accepts only its name: never Apple IDs, app-specific passwords, or API keys.
project_path="$(cd "$(dirname "$0")/.." && pwd -P)"
app_path="${DIST_DIR:-$project_path/dist}/Yeelight Station.app"
resume_path=""
app_argument=0
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: KEYCHAIN_PROFILE=<existing-profile-name> scripts/notarize-app.sh [APP_PATH]
       KEYCHAIN_PROFILE=<existing-profile-name> scripts/notarize-app.sh [APP_PATH] --resume RECEIPT_DIR
  NOTARY_TIMEOUT=30m       Bounded service wait per invocation (e.g. 30m, 1h).
  DEVELOPMENT_TEAM=...     Expected team; default: FMS4W53T57.
  NOTARY_RECEIPTS_DIR=...  Private receipt parent; default: <project>/.analysis/notarization.
  ZIP_PATH=...            Final stapled ZIP; default: beside APP_PATH/Yeelight-Station-macOS.zip.
A timeout leaves the submission running at Apple. Resume with the printed receipt
path; never resubmit an uncertain upload automatically. No app is installed/launched.
Only the app is submitted; this does not notarize the separate stationctl binary.
USAGE
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help) usage; exit 0 ;;
        --resume) [ "$#" -ge 2 ] || fail '--resume needs a receipt directory.'; resume_path="$2"; shift 2 ;;
        --*) fail 'Unknown option; use --help.' ;;
        *) [ "$app_argument" = 0 ] || fail 'Only one app path is accepted.'; app_path="$1"; app_argument=1; shift ;;
    esac
done
[ "$(uname -s)" = Darwin ] || fail 'Notarization requires macOS and Xcode command line tools.'
for tool in xcrun codesign ditto plutil shasum spctl zip; do
    command -v "$tool" >/dev/null || fail "Missing $tool. Install/select Xcode command line tools."
done
xcrun --find notarytool >/dev/null 2>&1 || fail 'notarytool is unavailable. Select Xcode 14 or newer with xcode-select.'
xcrun --find stapler >/dev/null 2>&1 || fail 'stapler is unavailable. Select a full Xcode installation with xcode-select.'
profile="${KEYCHAIN_PROFILE:-}"
[ -n "$profile" ] || fail 'KEYCHAIN_PROFILE must name an existing notarytool Keychain credential profile. Provision credentials securely before running this script.'
timeout="${NOTARY_TIMEOUT:-30m}"
[[ "$timeout" =~ ^[1-9][0-9]*[smh]?$ ]] || fail 'NOTARY_TIMEOUT must be a positive duration such as 1800s, 30m or 1h.'
team="${DEVELOPMENT_TEAM:-FMS4W53T57}"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || fail 'DEVELOPMENT_TEAM must be a ten-character Apple team ID.'
[ -d "$app_path" ] && [ ! -L "$app_path" ] || fail "Expected an app directory, not a symlink: $app_path"
app_path="$(cd "$app_path" && pwd -P)"
plist="$app_path/Contents/Info.plist"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" = dev.yeelightstation.mac ] || fail 'The app bundle identifier is not dev.yeelightstation.mac.'
[ "$(plutil -extract CFBundleExecutable raw -o - "$plist")" = YeelightStation ] || fail 'Unexpected app executable.'
executable="$app_path/Contents/MacOS/YeelightStation"
requirement="=anchor apple generic and identifier \"dev.yeelightstation.mac\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$team\""
codesign --verify --deep --strict --test-requirement "$requirement" "$app_path" || fail 'Notarization requires an intact Developer ID Application signature from the expected team.'
executable_hash() { shasum -a 256 "$executable" | cut -d ' ' -f 1; }
current_hash="$(executable_hash)"
if [ -n "$resume_path" ]; then
    [ -d "$resume_path" ] && [ ! -L "$resume_path" ] || fail 'Resume receipt directory does not exist or is a symlink.'
    receipt="$(cd "$resume_path" && pwd -P)"
    [ -f "$receipt/app-executable.sha256" ] && [ -f "$receipt/submission-id.txt" ] || fail 'Incomplete receipt: no recorded executable hash or submission ID. Inspect it before submitting again.'
    [ "$current_hash" = "$(cat "$receipt/app-executable.sha256")" ] || fail 'This app differs from the submitted app. Resume using the original signed build.'
    submission_id="$(cat "$receipt/submission-id.txt")"
else
    receipt_parent="${NOTARY_RECEIPTS_DIR:-$project_path/.analysis/notarization}"
    mkdir -p "$receipt_parent"
    receipt="$(mktemp -d "$receipt_parent/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")"
    receipt="$(cd "$receipt" && pwd -P)"
    printf '%s\n' "$current_hash" > "$receipt/app-executable.sha256"
    plutil -extract CFBundleShortVersionString raw -o "$receipt/app-version.txt" "$plist"
    plutil -extract CFBundleVersion raw -o "$receipt/app-build.txt" "$plist"
    codesign -d --verbose=4 "$app_path" > "$receipt/signature.txt" 2>&1
    grep -q 'flags=.*runtime' "$receipt/signature.txt" || fail "Hardened Runtime is missing. Receipt: $receipt"
    grep -q '^Timestamp=' "$receipt/signature.txt" || fail "Secure signing timestamp is missing. Receipt: $receipt"
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$receipt/submission.zip"
    shasum -a 256 "$receipt/submission.zip" > "$receipt/submission-archive.sha256"
    printf 'Uploading signed app. Private receipts: %s\n' "$receipt"
    # Upload exactly once. A failed/ambiguous network response must be investigated,
    # not retried as another submission by this script.
    submit_result=0
    xcrun notarytool submit "$receipt/submission.zip" --keychain-profile "$profile" --no-wait --output-format json --no-progress > "$receipt/submission.json" 2> "$receipt/submission.stderr" || submit_result=$?
    submission_id="$(plutil -extract id raw -o - "$receipt/submission.json" 2>/dev/null || true)"
    if [[ "$submission_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
        printf '%s\n' "$submission_id" > "$receipt/submission-id.txt"
    else
        fail "Upload returned no submission ID (exit $submit_result). Inspect $receipt and the account's submission history before retrying; no automatic resubmission was attempted."
    fi
    [ "$submit_result" = 0 ] || fail "Upload returned an error after recording a submission ID. Resume using --resume '$receipt'; do not resubmit."
fi
[[ "$submission_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || fail 'Invalid submission ID in receipt.'
printf 'Waiting up to %s for submission %s.\n' "$timeout" "$submission_id"
# wait's timeout does not cancel Apple's submission. Always fetch its authoritative
# status once afterwards, including when wait times out or loses its connection.
xcrun notarytool wait "$submission_id" --keychain-profile "$profile" --timeout "$timeout" --output-format json --no-progress > "$receipt/wait.json" 2> "$receipt/wait.stderr" || true
xcrun notarytool info "$submission_id" --keychain-profile "$profile" --output-format json > "$receipt/info.json" 2> "$receipt/info.stderr" || fail "Could not retrieve status. Resume using --resume '$receipt'; do not resubmit."
[ "$(plutil -extract id raw -o - "$receipt/info.json")" = "$submission_id" ] || fail "Submission status has an unexpected ID. Inspect $receipt/info.json."
status="$(plutil -extract status raw -o - "$receipt/info.json")"
case "$status" in
    Accepted|Invalid|Rejected)
        xcrun notarytool log "$submission_id" --keychain-profile "$profile" "$receipt/log.pending.json" > "$receipt/log.stdout" 2> "$receipt/log.stderr" || fail "Could not retrieve the notary log. Resume using --resume '$receipt'."
        [ "$(plutil -extract jobId raw -o - "$receipt/log.pending.json")" = "$submission_id" ] || fail "Notary log has an unexpected job ID. Inspect $receipt/log.pending.json."
        [ "$(plutil -extract status raw -o - "$receipt/log.pending.json")" = "$status" ] || fail "Notary log status differs from submission status. Inspect $receipt/log.pending.json."
        mv -f "$receipt/log.pending.json" "$receipt/log.json"
        ;;
    *) fail "Notarization is not complete (status: $status). Resume using --resume '$receipt'; no new upload is needed." ;;
esac
[ "$status" = Accepted ] || fail "Apple did not accept this app (status: $status). Inspect $receipt/log.json."
[ "$current_hash" = "$(executable_hash)" ] || fail 'The app changed while notarization was running; refusing to staple/package it.'
codesign --verify --deep --strict --test-requirement "$requirement" "$app_path"
xcrun stapler staple "$app_path" > "$receipt/staple.txt" 2>&1 || fail "Stapling failed. Resume using --resume '$receipt'."
xcrun stapler validate "$app_path" > "$receipt/staple-validation.txt" 2>&1 || fail "Stapled ticket validation failed. See $receipt/staple-validation.txt."
codesign --verify --deep --strict --verbose=2 "$app_path" > "$receipt/signature-validation.txt" 2>&1
spctl --assess --type execute --verbose=4 "$app_path" > "$receipt/gatekeeper.txt" 2>&1 || fail "Gatekeeper rejected the app. See $receipt/gatekeeper.txt."
zip_path="${ZIP_PATH:-$(dirname "$app_path")/Yeelight-Station-macOS.zip}"
[ "${zip_path##*.}" = zip ] || fail 'ZIP_PATH must end with .zip.'
mkdir -p "$(dirname "$zip_path")"
zip_directory="$(cd "$(dirname "$zip_path")" && pwd -P)"
zip_path="$zip_directory/$(basename "$zip_path")"
case "$zip_path" in "$app_path"/*) fail 'The distribution ZIP must be outside the signed app bundle.' ;; esac
[ ! -L "$zip_path" ] || fail 'Refusing to replace a symlink at ZIP_PATH.'
zip_stage="$(mktemp -d "$zip_directory/.Station-notarized.XXXXXXXX")"
trap 'rm -rf "$zip_stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# ZIP files cannot be stapled: recreate the archive from the stapled app.
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_stage/distribution.zip"
# The notice is an archive sibling, preserving the accepted app signature/ticket.
[ -f "$project_path/LICENSE" ] || fail 'The repository license is missing.'
zip -j -q "$zip_stage/distribution.zip" "$project_path/LICENSE"
mv -f "$zip_stage/distribution.zip" "$zip_path"
shasum -a 256 "$zip_path" > "$receipt/distribution-archive.sha256"
printf 'Accepted, stapled, signature-verified and Gatekeeper-assessed.\n' > "$receipt/completed.txt"
printf 'Notarization complete.\nApp: %s\nStapled ZIP: %s\nReceipts: %s\n' "$app_path" "$zip_path" "$receipt"
