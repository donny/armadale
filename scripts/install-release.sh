#!/bin/bash
# Builds a release with scripts/release.sh (Developer ID signed, notarized,
# stapled DMG) and installs the app from that DMG into ~/Applications, so
# what runs locally is exactly what a user would download.
#
#   scripts/install-release.sh [--from-dmg] [release.sh options...]
#
# --from-dmg installs the DMG already in build/release/ (from an earlier
# run) without building again. Every other option is passed to release.sh
# (--skip-notarize, --allow-dirty, --allow-existing-tag).
#
# Refuses while Armadale is running: quit it first (persistent sessions
# keep running). Replaces ~/Applications/Armadale.app.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "install-release: $*" >&2; exit 1; }

from_dmg=no
args=()
for arg in "$@"; do
    case "$arg" in
        --from-dmg) from_dmg=yes ;;
        *) args+=("$arg") ;;
    esac
done

if pgrep -x Armadale >/dev/null; then
    fail "Armadale is running; quit it first (persistent sessions keep running), then run this again"
fi

if [ "$from_dmg" = no ]; then
    scripts/release.sh ${args[@]+"${args[@]}"}
fi

dmgs=(build/release/Armadale-*.dmg)
if [ "${#dmgs[@]}" -ne 1 ] || [ ! -f "${dmgs[0]}" ]; then
    fail "expected exactly one DMG in build/release/, found: ${dmgs[*]}"
fi
dmg="${dmgs[0]}"
case "$dmg" in
    *-pending.dmg) fail "$dmg did not pass every release check" ;;
esac

echo "==> Install $dmg"
mount="$(mktemp -d /tmp/armadale-install.XXXXXX)"
trap 'hdiutil detach "$mount" -quiet 2>/dev/null || true; rmdir "$mount" 2>/dev/null || true' EXIT
hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" >/dev/null || fail "could not mount $dmg"
[ -d "$mount/Armadale.app" ] || fail "no Armadale.app in $dmg"

mkdir -p ~/Applications
# Copy to a staging name next to the destination, then swap, so a failed
# copy never leaves a half-written app at the real path.
rm -rf ~/Applications/.Armadale.app.installing
ditto "$mount/Armadale.app" ~/Applications/.Armadale.app.installing
rm -rf ~/Applications/Armadale.app
mv ~/Applications/.Armadale.app.installing ~/Applications/Armadale.app

echo "==> Verify ~/Applications/Armadale.app"
codesign --verify --deep --strict ~/Applications/Armadale.app || fail "the installed app's signature does not verify"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' ~/Applications/Armadale.app/Contents/Info.plist)"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' ~/Applications/Armadale.app/Contents/Info.plist)"
# Informational: an unnotarized build is rejected here but still launches,
# since a locally built app carries no quarantine attribute.
spctl --assess --type execute --verbose=2 ~/Applications/Armadale.app 2>&1 | sed 's/^/    /' || true
if xattr -p com.apple.quarantine ~/Applications/Armadale.app >/dev/null 2>&1; then
    echo "    note: the app carries a quarantine attribute"
fi
echo "==> Done"
echo "    Armadale $version ($build) installed at ~/Applications/Armadale.app"
echo "    open ~/Applications/Armadale.app"
