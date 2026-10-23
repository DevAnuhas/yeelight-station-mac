#!/bin/bash
set -euo pipefail
umask 077

project_path="$(cd "$(dirname "$0")/.." && pwd -P)"
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: KEYCHAIN_PROFILE=Station-Notary scripts/notarize-dmg.sh [DMG_PATH] [--resume RECEIPT_DIR]
  DMG_PATH                Default: <DIST_DIR>/Yeelight-Station-<app-version>-universal.dmg.
  DIST_DIR=...            Default: <project>/dist.
  NOTARY_TIMEOUT=30m      Bounded wait per invocation, e.g. 30m or 1h.
  DEVELOPMENT_TEAM=...    Expected team; default: FMS4W53T57.
  NOTARY_RECEIPTS_DIR=... Default: <project>/.analysis/notarization/dmg.
Only the existing Keychain profile name is accepted; never pass credentials.
Uploads once. An uncertain upload or timeout must be inspected/resumed, not resubmitted.
The original DMG is replaced atomically only after stapling and Gatekeeper acceptance.
No app is installed or launched. App/ZIP notarization remains a separate workflow.
USAGE
}
dmg_path=""
resume_path=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help) usage; exit 0 ;;
        --resume) [ "$#" -ge 2 ] && [ -z "$resume_path" ] || fail '--resume needs one receipt directory.'; resume_path="$2"; shift 2 ;;
        --*) fail 'Unknown option; use --help.' ;;
        *) [ -z "$dmg_path" ] || fail 'Only one DMG path is accepted.'; dmg_path="$1"; shift ;;
    esac
done
[ "$(uname -s)" = Darwin ] || fail 'Notarization requires macOS.'
for tool in xcrun codesign plutil shasum hdiutil spctl ditto; do
    command -v "$tool" >/dev/null || fail "Missing $tool. Install/select Xcode command line tools."
done
[ -n "${KEYCHAIN_PROFILE:-}" ] || fail 'KEYCHAIN_PROFILE must name an existing notarytool Keychain credential profile. Pass its name only.'
profile="$KEYCHAIN_PROFILE"
xcrun --find notarytool >/dev/null 2>&1 || fail 'notarytool is unavailable. Select Xcode 14 or newer.'
xcrun --find stapler >/dev/null 2>&1 || fail 'stapler is unavailable. Select a full Xcode installation.'
timeout="${NOTARY_TIMEOUT:-30m}"
[[ "$timeout" =~ ^[1-9][0-9]*[smh]?$ ]] || fail 'NOTARY_TIMEOUT must be a positive duration such as 1800s, 30m or 1h.'
team="${DEVELOPMENT_TEAM:-FMS4W53T57}"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || fail 'DEVELOPMENT_TEAM must be a ten-character Apple team ID.'
if [ -z "$dmg_path" ]; then
    dist_path="${DIST_DIR:-$project_path/dist}"
    version="$(plutil -extract CFBundleShortVersionString raw -o - "$dist_path/Yeelight Station.app/Contents/Info.plist")"
    [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || fail 'Unexpected app version; supply DMG_PATH explicitly.'
    dmg_path="$dist_path/Yeelight-Station-$version-universal.dmg"
fi
[ -f "$dmg_path" ] && [ ! -L "$dmg_path" ] && [[ "$dmg_path" = *.dmg ]] || fail 'Expected a regular .dmg file, not a symlink.'
dmg_path="$(cd "$(dirname "$dmg_path")" && pwd -P)/$(basename "$dmg_path")"
lock="$dmg_path.lock"
mkdir "$lock" 2>/dev/null || fail "Another build/notary operation may be using this DMG (lock: $lock)."
stage=""
cleanup() {
    local result=$?
    trap - EXIT
    if [ -n "$stage" ]; then
        if [ "$result" = 0 ]; then rm -rf "$stage";
        else printf 'Unpublished DMG work preserved: %s\n' "$stage" >&2; fi
    fi
    rmdir "$lock" || true
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
requirement="=anchor apple generic and identifier \"dev.yeelightstation.dmg\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$team\""
codesign --verify --strict --test-requirement "$requirement" "$dmg_path" || fail 'The DMG must have an intact Developer ID Application signature from the expected team.'
signature="$(codesign -d --verbose=4 "$dmg_path" 2>&1)"
printf '%s\n' "$signature" | grep -q '^Timestamp=' || fail 'The DMG has no secure signing timestamp.'
cdhash="$(printf '%s\n' "$signature" | sed -n 's/^CDHash=//p')"
[[ "$cdhash" =~ ^[[:xdigit:]]{40}$ ]] || fail 'Missing or ambiguous DMG code-directory hash.'
file_hash() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
current_hash="$(file_hash "$dmg_path")"
[[ "$current_hash" =~ ^[[:xdigit:]]{64}$ ]] || fail 'Cannot calculate the DMG SHA-256.'
if [ -n "$resume_path" ]; then
    [ -d "$resume_path" ] && [ ! -L "$resume_path" ] || fail 'Resume receipt directory is missing or a symlink.'
    receipt="$(cd "$resume_path" && pwd -P)"
else
    receipt_parent="${NOTARY_RECEIPTS_DIR:-$project_path/.analysis/notarization/dmg}"
    mkdir -p "$receipt_parent"
    receipt_parent="$(cd "$receipt_parent" && pwd -P)"
    receipt="$receipt_parent/$current_hash"
    mkdir "$receipt" 2>/dev/null || fail "A receipt already exists for this DMG. Inspect it and resume with --resume '$receipt'; do not resubmit."
    printf '%s\n' "$current_hash" > "$receipt/submitted.sha256"
    printf '%s\n' "$cdhash" > "$receipt/cdhash.txt"
    printf '%s\n' "$signature" > "$receipt/signature.txt"
    printf '%s\n' "$dmg_path" > "$receipt/source-path.txt"
    ditto "$dmg_path" "$receipt/submission.dmg"
    [ "$(file_hash "$receipt/submission.dmg")" = "$current_hash" ] || fail "DMG changed during the snapshot. Inspect $receipt."
    hdiutil verify "$receipt/submission.dmg" > "$receipt/image-validation.txt" 2>&1
    printf 'Uploading signed DMG once. Private receipts: %s\n' "$receipt"
    submit_result=0
    xcrun notarytool submit "$receipt/submission.dmg" --keychain-profile "$profile" --no-wait --output-format json --no-progress > "$receipt/submission.json" 2> "$receipt/submission.stderr" || submit_result=$?
    submission_id="$(plutil -extract id raw -o - "$receipt/submission.json" 2>/dev/null || true)"
    if [[ "$submission_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
        printf '%s\n' "$submission_id" > "$receipt/submission-id.pending"
        mv "$receipt/submission-id.pending" "$receipt/submission-id.txt"
    else
        fail "Upload returned no submission ID (exit $submit_result). Inspect $receipt and Apple's submission history before retrying. No automatic resubmission was attempted."
    fi
    [ "$submit_result" = 0 ] || fail "Upload returned an error after recording its ID. Resume using --resume '$receipt'; do not resubmit."
fi
[ -f "$receipt/submitted.sha256" ] && [ -f "$receipt/cdhash.txt" ] && [ -f "$receipt/submission-id.txt" ] || fail "Incomplete receipt. Inspect $receipt and submission history; do not resubmit blindly."
[ "$cdhash" = "$(cat "$receipt/cdhash.txt")" ] || fail 'This DMG has a different code-directory hash from the submitted image.'
submitted_hash="$(cat "$receipt/submitted.sha256")"
[[ "$submitted_hash" =~ ^[[:xdigit:]]{64}$ ]] || fail 'Invalid submission SHA-256 in receipt.'
if [ "$current_hash" != "$submitted_hash" ]; then
    [ -f "$receipt/stapled.sha256" ] && [ "$current_hash" = "$(cat "$receipt/stapled.sha256")" ] || fail 'This DMG differs from both the submitted and recorded stapled image.'
fi
[ -f "$receipt/submission.dmg" ] && [ "$(file_hash "$receipt/submission.dmg")" = "$submitted_hash" ] || fail 'The preserved submission image differs from its receipt.'
submission_id="$(cat "$receipt/submission-id.txt")"
[[ "$submission_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || fail 'Invalid submission ID in receipt.'
attempt="$(mktemp -d "$receipt/check-XXXXXXXX")"
printf 'Waiting up to %s for submission %s. Receipts: %s\n' "$timeout" "$submission_id" "$receipt"
xcrun notarytool wait "$submission_id" --keychain-profile "$profile" --timeout "$timeout" --output-format json --no-progress > "$attempt/wait.json" 2> "$attempt/wait.stderr" || true
xcrun notarytool info "$submission_id" --keychain-profile "$profile" --output-format json > "$attempt/info.json" 2> "$attempt/info.stderr" || fail "Cannot retrieve status. Resume using --resume '$receipt'; do not resubmit."
[ "$(plutil -extract id raw -o - "$attempt/info.json")" = "$submission_id" ] || fail "Unexpected status ID; inspect $attempt/info.json."
status="$(plutil -extract status raw -o - "$attempt/info.json")"
case "$status" in
    Accepted|Invalid|Rejected)
        xcrun notarytool log "$submission_id" --keychain-profile "$profile" "$attempt/log.json" > "$attempt/log.stdout" 2> "$attempt/log.stderr" || fail "Cannot retrieve log. Resume using --resume '$receipt'."
        [ "$(plutil -extract jobId raw -o - "$attempt/log.json")" = "$submission_id" ] || fail "Unexpected notary log ID; inspect $attempt/log.json."
        [ "$(plutil -extract status raw -o - "$attempt/log.json")" = "$status" ] || fail "Notary log/status mismatch; inspect $attempt/log.json."
        ;;
    *) fail "Notarization is not complete (status: $status). Resume using --resume '$receipt'; no new upload is needed." ;;
esac
[ "$status" = Accepted ] || fail "Apple did not accept the DMG (status: $status). Inspect $attempt/log.json."
[ "$(file_hash "$dmg_path")" = "$current_hash" ] || fail 'The distribution DMG changed during notarization; refusing to replace it.'
# Staple a private copy: timeouts/failures never modify the public artifact.
stage="$(mktemp -d "$(dirname "$dmg_path")/.Station-notarized-dmg.XXXXXXXX")"
ditto "$receipt/submission.dmg" "$stage/distribution.dmg"
codesign --verify --strict --test-requirement "$requirement" "$stage/distribution.dmg" > "$attempt/signature-before.txt" 2>&1
xcrun stapler staple "$stage/distribution.dmg" > "$attempt/staple.txt" 2>&1 || fail "Stapling failed. Resume using --resume '$receipt'."
xcrun stapler validate "$stage/distribution.dmg" > "$attempt/staple-validation.txt" 2>&1 || fail "Ticket validation failed; inspect $attempt/staple-validation.txt."
codesign --verify --strict --test-requirement "$requirement" "$stage/distribution.dmg" > "$attempt/signature-validation.txt" 2>&1
codesign -d --verbose=4 "$stage/distribution.dmg" > "$attempt/stapled-signature.txt" 2>&1
[ "$(sed -n 's/^CDHash=//p' "$attempt/stapled-signature.txt")" = "$cdhash" ] || fail 'The code-directory hash changed during stapling.'
hdiutil verify "$stage/distribution.dmg" > "$attempt/stapled-image-validation.txt" 2>&1
spctl --assess --type open --context context:primary-signature --verbose=4 "$stage/distribution.dmg" > "$attempt/gatekeeper.txt" 2>&1 || fail "Gatekeeper rejected the DMG; inspect $attempt/gatekeeper.txt."
stapled_hash="$(file_hash "$stage/distribution.dmg")"
printf '%s\n' "$stapled_hash" > "$receipt/stapled.sha256.pending"
mv -f "$receipt/stapled.sha256.pending" "$receipt/stapled.sha256"
[ ! -L "$dmg_path" ] && [ "$(file_hash "$dmg_path")" = "$current_hash" ] || fail 'The destination changed; refusing to replace it.'
mv -f "$stage/distribution.dmg" "$dmg_path"
printf 'Accepted, stapled, signature-verified and Gatekeeper-assessed.\n' > "$receipt/completed.txt"
printf 'Notarization complete.\nStapled DMG: %s\nSHA-256: %s\nReceipts: %s\n' "$dmg_path" "$stapled_hash" "$receipt"
