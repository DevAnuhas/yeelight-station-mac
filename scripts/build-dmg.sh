#!/bin/bash
set -euo pipefail

project_path="$(cd "$(dirname "$0")/.." && pwd -P)"
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
if [ "${1:-}" = --help ]; then
    cat <<'USAGE'
Usage: CODE_SIGN_IDENTITY=<Developer-ID-fingerprint> scripts/build-dmg.sh [APP_PATH]
  APP_PATH               Default: <DIST_DIR>/Yeelight Station.app; must be signed/stapled.
  DIST_DIR=...           Output directory; default: <project>/dist.
  DEVELOPMENT_TEAM=...   Expected team; default: FMS4W53T57.
Run scripts/setup-dmg.sh once first. Produces Yeelight-Station-<app-version>-universal.dmg.
The container is signed with a secure timestamp; run notarize-dmg.sh before release.
USAGE
    exit 0
fi
[ "$#" -le 1 ] || fail 'Only one app path is accepted; use --help.'
[ "$(uname -s)" = Darwin ] || fail 'DMG packaging requires macOS.'
for tool in codesign xcrun spctl lipo plutil hdiutil ditto cmp; do
    command -v "$tool" >/dev/null || fail "Missing $tool. Install/select Xcode command line tools."
done
python="$project_path/.tools/dmgbuild/bin/python3"
dmgbuild="$project_path/.tools/dmgbuild/bin/dmgbuild"
[ -x "$python" ] && [ -x "$dmgbuild" ] || fail 'Run scripts/setup-dmg.sh first.'
"$python" -c 'from importlib.metadata import version; assert version("dmgbuild") == "1.6.7", "Run scripts/setup-dmg.sh"'
identity="${CODE_SIGN_IDENTITY:-}"
[ -n "$identity" ] && [ "$identity" != - ] || fail 'CODE_SIGN_IDENTITY must identify a Developer ID Application certificate.'
team="${DEVELOPMENT_TEAM:-FMS4W53T57}"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || fail 'DEVELOPMENT_TEAM must be a ten-character Apple team ID.'
mkdir -p "${DIST_DIR:-$project_path/dist}"
dist_path="$(cd "${DIST_DIR:-$project_path/dist}" && pwd -P)"
source_app="${1:-$dist_path/Yeelight Station.app}"
[ -d "$source_app" ] && [ ! -L "$source_app" ] || fail 'Expected a built app directory, not a symlink.'
source_app="$(cd "$source_app" && pwd -P)"
case "$dist_path/" in "$source_app/"*) fail 'DIST_DIR must be outside the signed app.' ;; esac
plist="$source_app/Contents/Info.plist"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$plist")"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || fail 'App version must contain only dot-separated numbers.'
output="$dist_path/Yeelight-Station-$version-universal.dmg"
[ ! -L "$output" ] && { [ ! -e "$output" ] || [ -f "$output" ]; } || fail "Refusing a symlink/non-file at $output."
lock="$output.lock"
mkdir "$lock" 2>/dev/null || fail "Another build/notary operation may be using $output (lock: $lock)."
stage=""
cleanup_mounts() {
    # Only detach disks whose backing image is inside this invocation's private stage.
    hdiutil info -plist > "$stage/mounts.plist" 2>> "$stage/cleanup.log" || return 1
    "$python" - "$stage" <<'PY' > "$stage/devices.txt" || return 1
import os, plistlib, re, sys
stage = os.path.realpath(sys.argv[1]) + os.sep
with open(stage + "mounts.plist", "rb") as stream:
    images = plistlib.load(stream).get("images", [])
for image in images:
    if os.path.realpath(image.get("image-path", "")).startswith(stage):
        devices = [e.get("dev-entry", "") for e in image.get("system-entities", [])]
        disk = next((d for d in devices if re.fullmatch(r"/dev/disk[0-9]+", d)), None)
        if not disk:
            raise SystemExit("Cannot identify owned image device; preserve the stage for inspection")
        print(disk)
PY
    local device
    while IFS= read -r device; do
        hdiutil detach "$device" >> "$stage/cleanup.log" 2>&1 || return 1
    done < "$stage/devices.txt"
}
cleanup() {
    local result=$?
    trap - EXIT
    if [ -n "$stage" ]; then
        if ! cleanup_mounts; then
            printf 'error: could not detach a packaging disk; inspect %s\n' "$stage" >&2
            result=1
        fi
        if [ "$result" = 0 ]; then rm -rf "$stage";
        else printf 'DMG build diagnostics preserved: %s\n' "$stage" >&2; fi
    fi
    rmdir "$lock" || true
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stage="$(mktemp -d "$dist_path/.Station-dmg.XXXXXXXX")"
app="$stage/Yeelight Station.app"
ditto "$source_app" "$app"
ditto "$project_path/LICENSE" "$stage/LICENSE"
requirement="=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$team\""
validate_app() {
    local candidate="$1" arch
    [ "$(plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist")" = dev.yeelightstation.mac ] || fail 'Unexpected app bundle identifier.'
    [ "$(plutil -extract CFBundleExecutable raw -o - "$candidate/Contents/Info.plist")" = YeelightStation ] || fail 'Unexpected app executable.'
    [ "$(plutil -extract CFBundleShortVersionString raw -o - "$candidate/Contents/Info.plist")" = "$version" ] || fail 'App version changed while staging.'
    [ -f "$candidate/Contents/Resources/Station.icns" ] || fail 'The colorful Station icon is missing.'
    for arch in arm64 x86_64; do lipo "$candidate/Contents/MacOS/YeelightStation" -verify_arch "$arch" || return 1; done
    codesign --verify --deep --strict --test-requirement "$requirement and identifier \"dev.yeelightstation.mac\"" "$candidate" || return 1
    xcrun stapler validate "$candidate" || return 1
    spctl --assess --type execute --verbose=4 "$candidate" || return 1
}
validate_app "$app" > "$stage/app-validation.log" 2>&1 || fail "App validation failed; see $stage/app-validation.log."
"$dmgbuild" -s "$project_path/packaging/dmg/settings.py" \
    -D "app=$app" -D "resources=$project_path/packaging/dmg" -D "license=$stage/LICENSE" \
    "Yeelight Station $version" "$stage/distribution.dmg" > "$stage/dmgbuild.log" 2>&1 || fail "dmgbuild failed; see $stage/dmgbuild.log."
hdiutil verify "$stage/distribution.dmg" > "$stage/image-validation.log" 2>&1
mkdir "$stage/verify"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$stage/verify" -plist "$stage/distribution.dmg" > "$stage/attach.plist" 2> "$stage/attach.stderr"
[ "$(readlink "$stage/verify/Applications")" = /Applications ] || fail 'The Applications link is missing or incorrect.'
cmp "$stage/LICENSE" "$stage/verify/License.txt" || fail 'The packaged MIT license differs.'
validate_app "$stage/verify/Yeelight Station.app" > "$stage/packaged-app-validation.log" 2>&1 || fail "Packaged app validation failed; see $stage/packaged-app-validation.log."
cleanup_mounts || fail 'Cannot detach the verification image; refusing to publish.'
codesign --force --sign "$identity" --timestamp --identifier dev.yeelightstation.dmg "$stage/distribution.dmg" > "$stage/signing.log" 2>&1
codesign --verify --strict --test-requirement "$requirement and identifier \"dev.yeelightstation.dmg\"" "$stage/distribution.dmg" >> "$stage/signing.log" 2>&1
codesign -d --verbose=4 "$stage/distribution.dmg" >> "$stage/signing.log" 2>&1
grep -q '^Timestamp=' "$stage/signing.log" || fail 'The DMG has no secure signing timestamp.'
mv -f "$stage/distribution.dmg" "$output"
printf 'Built signed DMG: %s\nContainer notarization has NOT been performed. Run scripts/notarize-dmg.sh next.\n' "$output"
