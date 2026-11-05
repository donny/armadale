#!/bin/bash
# Installs the pinned dmgbuild, which lays out the release DMG's Finder
# window (docs/DESIGN.md section 11, "Release pipeline"), into a virtual
# environment at Vendor/dmgbuild (git-ignored).
#
#   scripts/fetch-dmgbuild.sh           install unless the pinned versions are already there
#   scripts/fetch-dmgbuild.sh --check   verify only; exit 1 if anything is missing or wrong
#
# The versions and the SHA-256 of each wheel come from
# scripts/dmgbuild-requirements.txt. The environment is made with
# `/usr/bin/python3 -m venv` (the venv's own pip, from Python's bundled
# ensurepip, so nothing is fetched to bootstrap it), and pip installs with
# --require-hashes --only-binary :all:, so only wheels with the pinned
# hashes are accepted and no package's build code runs. --isolated makes
# pip ignore PIP_* option variables and the user's pip.conf, and
# PIP_CONFIG_FILE=/dev/null makes it skip every configuration file (global
# and site ones too). Nothing is installed outside Vendor/dmgbuild.
#
# The install records the SHA-256 of the requirements file it used in
# Vendor/dmgbuild/requirements.sha256. The environment counts as installed
# when that matches the current file, the installed versions are the
# pinned ones and dmgbuild imports; a normal run then does nothing, and
# anything else (missing, a changed pin or hash, a broken environment, for
# example after Xcode replaced the Python it was made from) rebuilds it from
# an empty directory. Hashes are checked by pip at install time; later runs
# do not re-hash the installed files. Only the install needs the network.
#
# The pins were chosen for Xcode's /usr/bin/python3, Python 3.9.6 on
# macOS 27 (dmgbuild 1.6.5 needs 3.9 or later); a newer /usr/bin/python3
# works too. The script does not check the version.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQUIREMENTS="$ROOT/scripts/dmgbuild-requirements.txt"
VENV="$ROOT/Vendor/dmgbuild"
PY="$VENV/bin/python3"
STAMP="$VENV/requirements.sha256"
BASE_PYTHON="/usr/bin/python3"

CHECK_ONLY=0
case "${1:-}" in
    "") ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

die() { echo "fetch-dmgbuild: error: $*" >&2; exit 1; }
say() { echo "fetch-dmgbuild: $*"; }

[ -f "$REQUIREMENTS" ] || die "missing $REQUIREMENTS"

# Whether the environment was installed from this exact requirements file,
# runs, holds the pinned versions, and dmgbuild imports. -I: ignore PYTHON*
# variables and the user's site-packages.
sha_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }

is_installed() {
    [ -x "$PY" ] && [ -f "$STAMP" ] || return 1
    [ "$(cat "$STAMP")" = "$(sha_of "$REQUIREMENTS")" ] || return 1
    "$PY" -I - "$REQUIREMENTS" <<'PYTHON' >/dev/null 2>&1
import re, sys
from importlib import metadata

pins = {}
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r"^([A-Za-z0-9_.-]+)==([^\s\\]+)", line)
        if m:
            pins[m.group(1)] = m.group(2)
if not pins:
    sys.exit(1)
for name, version in pins.items():
    if metadata.version(name) != version:
        sys.exit(1)
import dmgbuild.core  # noqa: F401  (imports ds_store and mac_alias too)
PYTHON
}

# The pinned versions, one "name version" per line, for messages.
pinned() {
    sed -n 's/^\([A-Za-z0-9_.-]*\)==\([^ \\]*\).*/\1 \2/p' "$REQUIREMENTS" | paste -sd ',' - | sed 's/,/, /g'
}

if is_installed; then
    say "ok ($(pinned))"
    exit 0
fi
if [ "$CHECK_ONLY" = 1 ]; then
    echo "fetch-dmgbuild: Vendor/dmgbuild is missing, broken, or was not installed from the current scripts/dmgbuild-requirements.txt; run scripts/fetch-dmgbuild.sh" >&2
    exit 1
fi

[ -x "$BASE_PYTHON" ] || die "$BASE_PYTHON not found (it comes with Xcode or the Command Line Tools)"
say "using $("$BASE_PYTHON" --version 2>&1) ($BASE_PYTHON)"

# Start from an empty directory. The removal is guarded so it can only ever
# delete this script's environment.
remove_venv() {
    case "$VENV" in
        */Vendor/dmgbuild) rm -rf -- "$VENV" ;;
        *) die "refusing to remove $VENV" ;;
    esac
}
remove_venv
mkdir -p "$ROOT/Vendor"
# A failed install leaves nothing behind that could look installed.
trap 'status=$?; if [ "$status" != 0 ]; then remove_venv; fi' EXIT

"$BASE_PYTHON" -I -m venv "$VENV" || die "could not create a virtual environment with $BASE_PYTHON -m venv"
say "installing $(pinned)"
PIP_CONFIG_FILE=/dev/null "$PY" -I -m pip install --isolated --disable-pip-version-check \
    --no-input --no-cache-dir --require-hashes --only-binary :all: -r "$REQUIREMENTS" \
    || die "pip install failed (see above)"
sha_of "$REQUIREMENTS" >"$STAMP"

is_installed || die "verification after install failed"
trap - EXIT
say "installed $(pinned) in Vendor/dmgbuild"
