#!/bin/bash
set -euo pipefail
umask 077

project_path="$(cd "$(dirname "$0")/.." && pwd -P)"
app_path="${DIST_DIR:-$project_path/dist}/Yeelight Station.app"
install_dir="${INSTALL_DIR:-/Applications}"
require_notarization=1
app_argument=0
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
bundle_inode() { stat -f '%d:%i' "$1" 2>/dev/null || printf 'missing\n'; }
checked_inode="missing"
usage() {
    cat <<'USAGE'
Usage: scripts/install-app.sh [APP_PATH] [--allow-unnotarized]
  Default: require Developer ID, a validated stapled ticket and Gatekeeper acceptance.
  --allow-unnotarized  Explicitly install a Developer ID build before notarization.
                       No notarization/Gatekeeper success is claimed in this mode.
  DEVELOPMENT_TEAM=... Expected team; default: FMS4W53T57.
  INSTALL_DIR=...      Destination directory; default: /Applications.
  INSTALL_RECEIPTS_DIR=... Receipt parent; default: <project>/.analysis/installations.
Quit Station gracefully before installing. No process is killed, no sudo is used,
no app is launched, and user settings outside the app bundle are never modified.
Ad hoc/Apple Development builds cannot replace the canonical installation.
USAGE
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help) usage; exit 0 ;;
        --allow-unnotarized) require_notarization=0; shift ;;
        --*) fail 'Unknown option; use --help.' ;;
        *) [ "$app_argument" = 0 ] || fail 'Only one app path is accepted.'; app_path="$1"; app_argument=1; shift ;;
    esac
done
[ "$(uname -s)" = Darwin ] || fail 'Installation requires macOS.'
for tool in codesign ditto plutil pgrep stat shasum; do
    command -v "$tool" >/dev/null || fail "Missing required tool: $tool."
done
[ -x /usr/bin/python3 ] || fail 'Atomic installation requires Python 3 from the Xcode command line tools.'
/usr/bin/python3 -c 'import ctypes; ctypes.CDLL(None).renameatx_np; ctypes.CDLL("/usr/lib/libproc.dylib").proc_pidpath' >/dev/null 2>&1 || fail 'Python 3 or the macOS atomic rename/process APIs are unavailable; select/install Xcode command line tools.'
if [ "$require_notarization" = 1 ]; then
    command -v spctl >/dev/null || fail 'spctl is unavailable.'
    xcrun --find stapler >/dev/null 2>&1 || fail 'stapler is unavailable; select a full Xcode installation.'
fi
team="${DEVELOPMENT_TEAM:-FMS4W53T57}"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || fail 'DEVELOPMENT_TEAM must be a ten-character Apple team ID.'
[ -d "$app_path" ] && [ ! -L "$app_path" ] || fail "Expected an app directory, not a symlink: $app_path"
app_path="$(cd "$app_path" && pwd -P)"
[ -d "$install_dir" ] && [ ! -L "$install_dir" ] || fail "Installation directory is missing or is a symlink: $install_dir"
install_dir="$(cd "$install_dir" && pwd -P)"
[ -w "$install_dir" ] && [ -x "$install_dir" ] || fail "No write permission in $install_dir. Install from an account with write access; this script never requests sudo/passwords."
final_path="$install_dir/Yeelight Station.app"
[ "$app_path" != "$final_path" ] || fail 'Source and installed app are the same bundle.'
requirement="=anchor apple generic and identifier \"dev.yeelightstation.mac\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$team\""
check_identity() {
    local plist="$1/Contents/Info.plist"
    [ "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" = dev.yeelightstation.mac ] || fail "Refusing unrelated bundle: $1"
    [ "$(plutil -extract CFBundleExecutable raw -o - "$plist")" = YeelightStation ] || fail "Unexpected executable in $1"
}
check_release() {
    check_identity "$1"
    codesign --verify --deep --strict --test-requirement "$requirement" "$1" || fail 'Installation requires a valid Developer ID Application build from the expected team. Ad hoc/Apple Development downgrades are refused.'
}
ensure_stopped() {
    local result=0
    pgrep -x YeelightStation >/dev/null 2>&1 || result=$?
    case "$result" in
        1) ;;
        0) fail 'Station is running. Quit it gracefully so captures/lighting can stop and state can be restored, then run installation again.' ;;
        *) fail 'Could not check for running Station processes; refusing installation.' ;;
    esac
    # Check kernel-reported executable paths too: a process may change its name.
    /usr/bin/python3 - "$app_path" "$final_path" <<'PY'
import ctypes
import os
import sys

libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
libproc.proc_listallpids.argtypes = (ctypes.c_void_p, ctypes.c_int)
libproc.proc_listallpids.restype = ctypes.c_int
libproc.proc_pidpath.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)
libproc.proc_pidpath.restype = ctypes.c_int
count = libproc.proc_listallpids(None, 0)
if count <= 0:
    raise SystemExit("error: Could not enumerate processes; refusing installation.")
pids = (ctypes.c_int * (count * 2 + 256))()
count = libproc.proc_listallpids(pids, ctypes.sizeof(pids))
if count <= 0 or count >= len(pids):
    raise SystemExit("error: Process enumeration was incomplete; retry installation.")
prefixes = tuple(os.fsencode(path.rstrip("/") + "/") for path in sys.argv[1:])
for pid in pids[:count]:
    path = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(pid, path, len(path)) > 0 and path.value.startswith(prefixes):
        raise SystemExit("error: A process is executing from a Station bundle. Quit it gracefully before installation.")
PY
}
check_existing() {
    # Bind validation to this exact directory, not whichever bundle appears later.
    checked_inode="$(bundle_inode "$final_path")"
    if [ -e "$final_path" ] || [ -L "$final_path" ]; then
        [ -d "$final_path" ] && [ ! -L "$final_path" ] || fail "Refusing to overwrite a non-bundle/symlink at $final_path."
        check_identity "$final_path"
        codesign --verify --deep --strict "$final_path" || fail 'The existing app has an invalid signature; inspect it before replacing it.'
        local signature
        signature="$(codesign -d --verbose=4 "$final_path" 2>&1)"
        # Permit migration from Station's valid ad hoc developer build. Once the
        # canonical app is Developer ID-signed, the source gate forbids regression.
        if ! printf '%s\n' "$signature" | grep -q '^Signature=adhoc$'; then
            codesign --verify --strict --test-requirement "$requirement" "$final_path" || fail 'The existing bundle belongs to a different signing identity; refusing to overwrite it.'
        fi
    fi
    [ "$(bundle_inode "$final_path")" = "$checked_inode" ] || fail 'The installed bundle changed during validation. It was left untouched; retry after other installers/Finder operations finish.'
}
check_release "$app_path"
ensure_stopped
check_existing
source_version="$(plutil -extract CFBundleShortVersionString raw -o - "$app_path/Contents/Info.plist")"
source_build="$(plutil -extract CFBundleVersion raw -o - "$app_path/Contents/Info.plist")"
source_hash="$(shasum -a 256 "$app_path/Contents/MacOS/YeelightStation" | cut -d ' ' -f 1)"
receipt_parent="${INSTALL_RECEIPTS_DIR:-$project_path/.analysis/installations}"
mkdir -p "$receipt_parent"
receipt="$(mktemp -d "$receipt_parent/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")"
receipt="$(cd "$receipt" && pwd -P)"
lock_path="$install_dir/.dev.yeelightstation.mac.install-lock"
mkdir "$lock_path" 2>/dev/null || fail "Another install may be active ($lock_path). Inspect a stale lock before removing it."
stage=""
mutation=""
committed=0
candidate_inode=""
previous_inode=""
atomic_rename() {
    # Use parent directory handles and refuse symlinks at the kernel boundary.
    # RENAME_SWAP exchanges nonempty bundles; RENAME_EXCL never clobbers on first install.
    /usr/bin/python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import ctypes
import os
import stat
import sys

rename = ctypes.CDLL(None, use_errno=True).renameatx_np
rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
rename.restype = ctypes.c_int
flags = {"swap": 0x00000002, "new": 0x00000004}[sys.argv[3]] | 0x00000010
handles = []
try:
    for path, expected in zip(sys.argv[1:3], sys.argv[4:6]):
        parent, name = os.path.split(path)
        handle = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        handles.append((handle, os.fsencode(name)))
        try:
            info = os.stat(name, dir_fd=handle, follow_symlinks=False)
        except FileNotFoundError:
            if expected != "missing":
                raise SystemExit("error: A bundle disappeared before atomic replacement.")
        else:
            actual = str(info.st_dev) + ":" + str(info.st_ino)
            if actual != expected or not stat.S_ISDIR(info.st_mode) or os.path.ismount(path):
                raise SystemExit("error: A bundle changed or is a mountpoint; refusing atomic replacement.")
    if rename(*handles[0], *handles[1], flags) != 0:
        raise SystemExit("error: atomic bundle rename failed: " + os.strerror(ctypes.get_errno()))
finally:
    for handle, _ in handles:
        os.close(handle)
PY
}
cleanup() {
    local result=$?
    trap - EXIT
    if [ "$committed" = 0 ] && [ -n "$mutation" ]; then
        if [ "$mutation" = swap ]; then
            if [ "$(bundle_inode "$final_path")" = "$candidate_inode" ] && [ "$(bundle_inode "$stage/Yeelight Station.app")" = "$previous_inode" ]; then
                if ! atomic_rename "$stage/Yeelight Station.app" "$final_path" swap "$previous_inode" "$candidate_inode"; then
                    printf 'error: Rollback failed. Preserve recovery bundle at %s\n' "$stage" >&2
                    stage=""
                fi
            elif [ "$(bundle_inode "$final_path")" != "$previous_inode" ] || [ "$(bundle_inode "$stage/Yeelight Station.app")" != "$candidate_inode" ]; then
                printf 'error: Rollback failed. Preserve recovery bundle at %s\n' "$stage" >&2
                stage=""
            fi
        else
            if [ "$(bundle_inode "$final_path")" = "$candidate_inode" ] && [ "$(bundle_inode "$stage/Yeelight Station.app")" = missing ]; then
                if ! atomic_rename "$final_path" "$stage/Yeelight Station.app" new "$candidate_inode" missing; then
                    printf 'error: Could not withdraw failed installation at %s. Recovery directory: %s\n' "$final_path" "$stage" >&2
                    stage=""
                fi
            elif [ "$(bundle_inode "$final_path")" != missing ] || [ "$(bundle_inode "$stage/Yeelight Station.app")" != "$candidate_inode" ]; then
                printf 'error: Ambiguous installation state. Preserve recovery directory at %s\n' "$stage" >&2
                stage=""
            fi
        fi
    fi
    if [ "$committed" = 1 ] && [ "$mutation" = swap ] && { [ "$(bundle_inode "$final_path")" != "$candidate_inode" ] || [ "$(bundle_inode "$stage/Yeelight Station.app")" != "$previous_inode" ]; }; then
        printf 'error: Bundle identities changed before cleanup. Preserve recovery directory at %s\n' "$stage" >&2
        stage=""
        result=1
    fi
    if [ -n "$stage" ]; then rm -rf "$stage"; fi
    rmdir "$lock_path" || true
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stage="$(mktemp -d "$install_dir/.Station-install.XXXXXXXX")"
ditto "$app_path" "$stage/Yeelight Station.app"
candidate_inode="$(bundle_inode "$stage/Yeelight Station.app")"
check_release "$stage/Yeelight Station.app"
[ "$source_hash" = "$(shasum -a 256 "$stage/Yeelight Station.app/Contents/MacOS/YeelightStation" | cut -d ' ' -f 1)" ] || fail 'The source app changed during copying.'
if [ "$require_notarization" = 1 ]; then
    xcrun stapler validate "$stage/Yeelight Station.app" > "$receipt/staple-validation.txt" 2>&1 || fail "No valid stapled ticket. Run notarize-app.sh first. Receipt: $receipt"
    spctl --assess --type execute --verbose=4 "$stage/Yeelight Station.app" > "$receipt/gatekeeper.txt" 2>&1 || fail "Gatekeeper rejected the staged app. See $receipt/gatekeeper.txt."
fi
ensure_stopped
check_existing
previous_inode="$checked_inode"
if [ "$previous_inode" != missing ]; then
    mutation=swap
    atomic_rename "$stage/Yeelight Station.app" "$final_path" swap "$candidate_inode" "$previous_inode"
else
    mutation=new
    atomic_rename "$stage/Yeelight Station.app" "$final_path" new "$candidate_inode" missing
fi
# Keep the previous bundle intact until the copy at its canonical path verifies.
[ "$(bundle_inode "$final_path")" = "$candidate_inode" ] || fail 'The installed bundle changed after atomic replacement; preserving recovery state.'
if [ "$mutation" = swap ]; then
    [ "$(bundle_inode "$stage/Yeelight Station.app")" = "$previous_inode" ] || fail 'The displaced bundle changed after atomic replacement; preserving it for inspection.'
fi
check_release "$final_path"
[ "$source_version" = "$(plutil -extract CFBundleShortVersionString raw -o - "$final_path/Contents/Info.plist")" ] || fail 'Installed version differs from source.'
[ "$source_build" = "$(plutil -extract CFBundleVersion raw -o - "$final_path/Contents/Info.plist")" ] || fail 'Installed build differs from source.'
[ "$source_hash" = "$(shasum -a 256 "$final_path/Contents/MacOS/YeelightStation" | cut -d ' ' -f 1)" ] || fail 'Installed executable differs from source.'
if [ "$require_notarization" = 1 ]; then
    xcrun stapler validate "$final_path" > "$receipt/installed-ticket.txt" 2>&1
    spctl --assess --type execute --verbose=4 "$final_path" > "$receipt/installed-gatekeeper.txt" 2>&1
fi
codesign -d --verbose=4 "$final_path" > "$receipt/installed-signature.txt" 2>&1
[ "$(bundle_inode "$final_path")" = "$candidate_inode" ] || fail 'The installed bundle changed during final verification; preserving recovery state.'
if [ "$mutation" = swap ]; then
    [ "$(bundle_inode "$stage/Yeelight Station.app")" = "$previous_inode" ] || fail 'The displaced bundle changed before cleanup; preserving it for inspection.'
fi
{
    printf 'Installed: %s\nVersion: %s (%s)\n' "$final_path" "$source_version" "$source_build"
    printf 'Executable SHA-256: %s\n' "$source_hash"
    if [ "$require_notarization" = 1 ]; then
        printf 'Policy: Developer ID, stapled ticket and Gatekeeper verified.\n'
    else
        printf 'Policy: Developer ID verified; explicit unnotarized installation. No notarization/Gatekeeper claim.\n'
    fi
    printf 'User data outside the bundle was preserved. App was not launched.\n'
} > "$receipt/completed.txt"
committed=1
cat "$receipt/completed.txt"
printf 'Receipt: %s\n' "$receipt"
