#!/bin/bash
set -euo pipefail
project_path="$(cd "$(dirname "$0")/.." && pwd -P)"
if [ "${1:-}" = --help ]; then
    printf 'Usage: scripts/setup-dmg.sh\nInstalls hash-pinned dmgbuild in ignored .tools/dmgbuild using Python 3.10+.\n'
    exit 0
fi
[ "$#" -eq 0 ] || { printf 'error: unexpected argument; use --help.\n' >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || { printf 'error: dmgbuild requires macOS.\n' >&2; exit 1; }
python3 -c 'import sys; assert sys.version_info >= (3, 10), "Python 3.10+ is required"'
venv="$project_path/.tools/dmgbuild"
[ ! -L "$venv" ] || { printf 'error: refusing a symlink at %s\n' "$venv" >&2; exit 1; }
if [ ! -e "$venv" ]; then python3 -m venv "$venv"; fi
[ -x "$venv/bin/python3" ] || { printf 'error: incomplete venv: %s\n' "$venv" >&2; exit 1; }
"$venv/bin/python3" -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: -r "$project_path/packaging/dmg/requirements.txt"
"$venv/bin/python3" -m pip check
printf 'DMG tooling ready: %s/bin/dmgbuild\n' "$venv"
