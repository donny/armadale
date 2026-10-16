#!/bin/bash
# Downloads the pinned zmx release for every platform Armadale ships and
# places the binaries under Vendor/zmx/<os>-<arch>/zmx (docs/DESIGN.md
# section 4, "Bundling").
#
#   scripts/fetch-zmx.sh           fetch whatever is missing or does not verify
#   scripts/fetch-zmx.sh --check   verify only; exit 1 if anything is missing or wrong
#
# The version and the SHA-256 of each release tarball come from
# scripts/zmx.lock. Each platform directory keeps its verified tarball next
# to the binary, so a later run (or --check) can prove the binary is exactly
# what the pinned tarball contains. Already verified platforms are skipped,
# so the script is cheap to run on every build.
#
# Downloads are untrusted until their hash matches: each one goes into its own
# fresh temporary directory, and only the single expected member (`zmx`, a
# regular file) is extracted, again into a fresh directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/scripts/zmx.lock"
VENDOR="$ROOT/Vendor/zmx"
BASE_URL="https://zmx.sh/a"
PLATFORMS="macos-aarch64 macos-x86_64 linux-aarch64 linux-x86_64"

CHECK_ONLY=0
case "${1:-}" in
    "") ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

die() { echo "fetch-zmx: error: $*" >&2; exit 1; }
say() { echo "fetch-zmx: $*"; }

[ -f "$LOCK" ] || die "missing $LOCK"
VERSION="$(awk '$1 == "version" { print $2; exit }' "$LOCK")"
[ -n "$VERSION" ] || die "no 'version' line in $LOCK"

# SHA-256 that zmx.lock pins for a tarball name.
pinned_sha() {
    awk -v name="$1" '$2 == name && $1 ~ /^[0-9a-f]+$/ && length($1) == 64 { print $1; exit }' "$LOCK"
}

sha_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }

# One scratch directory for the whole run, removed on exit. The removal is
# guarded so it can only ever delete a directory this script created.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/armadale-fetch-zmx.XXXXXX")"
cleanup() {
    case "$WORK" in
        */armadale-fetch-zmx.??????) rm -rf -- "$WORK" ;;
    esac
}
trap cleanup EXIT

# Extracts the single `zmx` member of tarball $1 into a fresh directory and
# prints the extracted file's path. Refuses archives with any other content.
extract_zmx() {
    local tarball="$1" listing fresh
    listing="$(tar -tzf "$tarball")" || die "cannot list $tarball"
    [ "$listing" = "zmx" ] || die "unexpected contents in $(basename "$tarball"): $(echo "$listing" | tr '\n' ' ')"
    fresh="$(mktemp -d "$WORK/extract.XXXXXX")"
    tar -xzf "$tarball" -C "$fresh" zmx || die "cannot extract $tarball"
    [ -f "$fresh/zmx" ] && [ ! -L "$fresh/zmx" ] || die "$(basename "$tarball") did not contain a regular file named zmx"
    echo "$fresh/zmx"
}

# Whether Vendor/zmx/<platform> holds the verified binary for tarball $2.
is_verified() {
    local dir="$VENDOR/$1" name="$2" sha="$3" extracted
    [ -f "$dir/$name" ] && [ -f "$dir/zmx" ] && [ -x "$dir/zmx" ] || return 1
    [ "$(sha_of "$dir/$name")" = "$sha" ] || return 1
    extracted="$(extract_zmx "$dir/$name")" || return 1
    cmp -s "$extracted" "$dir/zmx"
}

failures=0
for platform in $PLATFORMS; do
    name="zmx-$VERSION-$platform.tar.gz"
    sha="$(pinned_sha "$name")"
    [ -n "$sha" ] || die "$LOCK has no SHA-256 for $name"
    dir="$VENDOR/$platform"

    if is_verified "$platform" "$name" "$sha"; then
        say "$platform: ok ($VERSION)"
        continue
    fi
    if [ "$CHECK_ONLY" = 1 ]; then
        echo "fetch-zmx: $platform: missing or does not match $name in zmx.lock" >&2
        failures=$((failures + 1))
        continue
    fi

    download="$(mktemp -d "$WORK/download.XXXXXX")"
    say "$platform: downloading $BASE_URL/$name"
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 20 \
        -o "$download/$name" "$BASE_URL/$name" || die "download of $name failed"
    actual="$(sha_of "$download/$name")"
    [ "$actual" = "$sha" ] || die "$name: SHA-256 mismatch (expected $sha, got $actual)"
    binary="$(extract_zmx "$download/$name")"

    # Install: tarball first, then the binary via a temporary name and an
    # atomic rename, so an interrupted run never leaves a half-written zmx.
    mkdir -p "$dir"
    # Old versions' tarballs in this directory are superseded.
    find "$dir" -maxdepth 1 -name 'zmx-*.tar.gz' ! -name "$name" -delete
    cp "$download/$name" "$dir/$name"
    install -m 0755 "$binary" "$dir/zmx.partial"
    mv -f "$dir/zmx.partial" "$dir/zmx"
    is_verified "$platform" "$name" "$sha" || die "$platform: verification after install failed"
    say "$platform: installed $VERSION"
done

[ "$failures" = 0 ] || die "$failures platform(s) need scripts/fetch-zmx.sh"
exit 0
