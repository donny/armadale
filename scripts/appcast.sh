#!/bin/bash
# Adds a release to the update feed, docs/appcast.xml (README, "Releasing",
# step 4; docs/DESIGN.md section 11, "Release pipeline"). Run it after the
# GitHub Release v<version> exists with the DMG, and after "Next release"
# on docs/changelog.html has become that version's section.
#
#   scripts/appcast.sh [--item FILE] [--dmg FILE] [--feed FILE]
#                      [--changelog FILE] [--public-key BASE64]
#
#   --item        the item scripts/release.sh wrote
#                 (default build/release/appcast-item.xml)
#   --dmg         check this local file instead of downloading the release
#                 asset (for checking this script; a real release is
#                 checked as downloaded)
#   --feed        the feed to change (default docs/appcast.xml)
#   --changelog   the changelog page (default docs/changelog.html)
#   --public-key  the public key to verify with (default: SUPublicEDKey in
#                 project.yml, the key every build carries)
#
# It downloads https://github.com/donny/armadale/releases/download/v<version>/Armadale-<version>.dmg,
# checks that it has the length the item records and that the item's
# EdDSA signature of it verifies against the public key, makes the
# embedded release notes from that version's section of the changelog
# page, and puts the item at the top of the feed's items. It commits and
# pushes nothing: the push of the feed to main is what publishes the
# update to every copy of Armadale that checks.
set -euo pipefail

cd "$(dirname "$0")/.."

item="build/release/appcast-item.xml"
dmg=""
feed="docs/appcast.xml"
changelog="docs/changelog.html"
public_key=""
while [ $# -gt 0 ]; do
    case "$1" in
        --item) item="$2"; shift 2 ;;
        --dmg) dmg="$2"; shift 2 ;;
        --feed) feed="$2"; shift 2 ;;
        --changelog) changelog="$2"; shift 2 ;;
        --public-key) public_key="$2"; shift 2 ;;
        -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "appcast: unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

fail() { printf 'appcast: FAILED: %s\n' "$*" >&2; exit 1; }
info() { printf '    %s\n' "$*"; }

for file in "$item" "$feed" "$changelog"; do
    [ -f "$file" ] || fail "$file is missing"
done
if [ -z "$public_key" ]; then
    public_key="$(sed -n 's/^[[:space:]]*SUPublicEDKey:[[:space:]]*\([A-Za-z0-9+/=]*\)[[:space:]]*$/\1/p' project.yml | head -1)"
    [ -n "$public_key" ] || fail "project.yml has no SUPublicEDKey"
fi

fields="$(/usr/bin/python3 -I scripts/appcast.py read "$item")" || fail "cannot read $item"
version="" build="" length="" signature="" minimum_system="" url=""
eval "$fields"
info "Armadale $version ($build), $length bytes, macOS $minimum_system or later"
expected_url="https://github.com/donny/armadale/releases/download/v$version/Armadale-$version.dmg"
[ "$url" = "$expected_url" ] || fail "the item's URL is $url, not $expected_url"

# A fixed, git-ignored scratch folder (build/ is), removed by its literal
# name.
scratch="build/appcast-check"
rm -rf build/appcast-check
mkdir -p build/appcast-check
cleanup() { rm -rf build/appcast-check; }
trap cleanup EXIT

if [ -z "$dmg" ]; then
    info "downloading $url"
    curl --fail --location --silent --show-error --output "$scratch/release.dmg" "$url" \
        || fail "the release asset does not download (does the GitHub Release v$version exist?)"
    dmg="$scratch/release.dmg"
else
    info "checking $dmg instead of the release asset (--dmg)"
fi
actual_length="$(stat -f %z "$dmg")"
[ "$actual_length" = "$length" ] || fail "the DMG has $actual_length bytes, the item signed $length"
/usr/bin/swift scripts/ed25519-verify.swift "$public_key" "$signature" "$dmg" >/dev/null \
    || fail "the item's signature does not verify against the public key"
info "length and EdDSA signature verify"

/usr/bin/python3 -I scripts/appcast.py notes --changelog "$changelog" --version "$version" >"$scratch/notes.html" \
    || fail "cannot make the release notes"
info "release notes: $(grep -c '<h3>' "$scratch/notes.html") item(s) from the changelog's section v$version"
/usr/bin/python3 -I scripts/appcast.py insert --feed "$feed" --item "$item" --notes "$scratch/notes.html" \
    || fail "cannot insert the item into $feed"
info "added to $feed; commit it with the changelog change and push to publish the update"
