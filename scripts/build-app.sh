#!/bin/bash
set -euo pipefail

# Developer build (ad hoc): scripts/build-app.sh
# Distribution build: RELEASE=1 CODE_SIGN_IDENTITY=<Developer-ID-fingerprint> scripts/build-app.sh
# A distribution build is signed, but is not notarized until notarize-app.sh succeeds.
if [ "${1:-}" = --help ]; then
    cat <<'USAGE'
Usage: scripts/build-app.sh
  RELEASE=1              Require a Developer ID Application signature (never fall back).
  CODE_SIGN_IDENTITY=...  Certificate name or SHA-1 fingerprint; default: - (ad hoc).
  DEVELOPMENT_TEAM=...    Expected release team; default: FMS4W53T57.
  UNIVERSAL=0 ARCH=...    Build one architecture; default: arm64 + x86_64.
  CONFIGURATION=...      Swift build configuration; default: release.
  DIST_DIR=...           Output directory; default: <project>/dist.
USAGE
    exit 0
fi
[ "$#" -eq 0 ] || { printf 'error: unexpected build argument; use --help.\n' >&2; exit 1; }
cd "$(dirname "$0")/.."
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
for tool in swift lipo codesign ditto file plutil; do
    command -v "$tool" >/dev/null || fail "Missing $tool. Install/select Xcode command line tools."
done
release="${RELEASE:-0}"
identity="${CODE_SIGN_IDENTITY:--}"
team="${DEVELOPMENT_TEAM:-FMS4W53T57}"
case "$release" in 0|1) ;; *) fail 'RELEASE must be 0 or 1.' ;; esac
case "${UNIVERSAL:-1}" in 0|1) ;; *) fail 'UNIVERSAL must be 0 or 1.' ;; esac
if [ "$release" = 1 ]; then
    [ "$identity" != - ] && [ -n "$identity" ] || fail 'RELEASE=1 requires CODE_SIGN_IDENTITY for a Developer ID Application certificate and its private key.'
    [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || fail 'DEVELOPMENT_TEAM must be a ten-character Apple team ID.'
fi
configuration="${CONFIGURATION:-release}"
mkdir -p "${DIST_DIR:-$PWD/dist}"
dist_path="$(cd "${DIST_DIR:-$PWD/dist}" && pwd -P)"
stage="$(mktemp -d "$dist_path/.Station-build.XXXXXXXX")"
app_path="$stage/Yeelight Station.app"
cli_path="$stage/stationctl"
zip_path="$stage/Yeelight-Station-macOS.zip"
final_path="$dist_path/Yeelight Station.app"
previous_path="$stage/previous.app"
cleanup() {
    local result=$?
    if [ -d "$previous_path" ] && [ ! -e "$final_path" ]; then mv "$previous_path" "$final_path"; fi
    rm -rf "$stage"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
build_arguments=(--configuration "$configuration" --build-system native)
app_binaries=()
cli_binaries=()
resource_path=""
if [ "${UNIVERSAL:-1}" = 1 ]; then
    architectures=(arm64 x86_64)
else
    architectures=("${ARCH:-$(uname -m)}")
fi
for architecture in "${architectures[@]}"; do
    case "$architecture" in arm64|x86_64) ;; *) fail "Unsupported architecture: $architecture" ;; esac
    swift build "${build_arguments[@]}" --arch "$architecture"
    bin_path="$(swift build "${build_arguments[@]}" --arch "$architecture" --show-bin-path)"
    app_binaries+=("$bin_path/YeelightStation")
    cli_binaries+=("$bin_path/stationctl")
    resource_path="$bin_path"
done
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
if [ "${#app_binaries[@]}" -gt 1 ]; then
    lipo -create "${app_binaries[@]}" -output "$app_path/Contents/MacOS/YeelightStation"
    lipo -create "${cli_binaries[@]}" -output "$cli_path"
else
    ditto "${app_binaries[0]}" "$app_path/Contents/MacOS/YeelightStation"
    ditto "${cli_binaries[0]}" "$cli_path"
fi
# Some installed cctools versions reject a multi-architecture -verify_arch list.
# Verify each required slice separately using the real tool's unambiguous form.
for architecture in "${architectures[@]}"; do
    lipo "$app_path/Contents/MacOS/YeelightStation" -verify_arch "$architecture"
    lipo "$cli_path" -verify_arch "$architecture"
done
# SwiftPM's current bundles contain architecture-independent preset data only.
for resource_bundle in "$resource_path"/*.bundle; do
    [ -d "$resource_bundle" ] || continue
    ditto "$resource_bundle" "$app_path/Contents/Resources/$(basename "$resource_bundle")"
done
ditto packaging/Info.plist "$app_path/Contents/Info.plist"
if [ -f assets/Station.icns ]; then ditto assets/Station.icns "$app_path/Contents/Resources/Station.icns"; fi
plutil -lint "$app_path/Contents/Info.plist" packaging/Station.entitlements >/dev/null

sign_arguments=(--force --sign "$identity")
if [ "$identity" != - ]; then
    # Apply Hardened Runtime and a secure timestamp to every real-certificate target.
    sign_arguments+=(--options runtime --timestamp)
fi
codesign "${sign_arguments[@]}" --identifier dev.yeelightstation.stationctl "$cli_path"
# Sign known code explicitly, inside out. Never propagate app entitlements to helpers.
# Current SwiftPM resources contain no code; refuse new executable resource bundles
# until they have a deliberate layout and entitlement policy.
while IFS= read -r -d '' candidate; do
    if [[ "$(file -b "$candidate")" == *Mach-O* ]]; then
        [ "$candidate" = "$app_path/Contents/MacOS/YeelightStation" ] || fail "Unexpected nested code: $candidate. Add an explicit inside-out signing step before packaging it."
    fi
done < <(find "$app_path" -type f -print0)
codesign "${sign_arguments[@]}" --entitlements packaging/Station.entitlements "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
codesign --verify --strict --verbose=2 "$cli_path"
if [ "$release" = 1 ]; then
    requirement="=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$team\""
    codesign --verify --strict --test-requirement "$requirement and identifier \"dev.yeelightstation.mac\"" "$app_path" || fail 'The app is not signed with the expected Developer ID Application identity.'
    codesign --verify --strict --test-requirement "$requirement and identifier \"dev.yeelightstation.stationctl\"" "$cli_path" || fail 'The CLI is not signed with the expected Developer ID Application identity.'
fi
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
# Publish only after all build, signature, architecture and archive checks pass.
if [ -e "$final_path" ] || [ -L "$final_path" ]; then
    [ -d "$final_path" ] && [ ! -L "$final_path" ] || fail "Refusing to replace a non-bundle/symlink at $final_path."
    mv "$final_path" "$previous_path"
fi
mv "$app_path" "$final_path"
mv -f "$cli_path" "$dist_path/stationctl"
mv -f "$zip_path" "$dist_path/Yeelight-Station-macOS.zip"
printf 'Built %s\nCLI: %s\nZIP: %s\n' "$final_path" "$dist_path/stationctl" "$dist_path/Yeelight-Station-macOS.zip"
if [ "$identity" = - ]; then
    printf 'Ad hoc developer build; not suitable for notarization or public distribution.\n'
else
    printf 'Signed build; notarization has NOT been performed. Run scripts/notarize-app.sh next.\n'
fi
