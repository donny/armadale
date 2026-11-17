#!/bin/bash
# Xcode run-script phase of the Armadale app target ("Embed Sparkle" in
# project.yml), the last of its phases, before Xcode signs the app: embeds
# Sparkle.framework and signs the code in it (docs/DESIGN.md section 11,
# "Release pipeline").
#
# - Copies $BUILT_PRODUCTS_DIR/Sparkle.framework (the macOS slice Xcode
#   extracts from the Sparkle package's XCFramework, which the app links)
#   into Contents/Frameworks, keeping its symbolic links, without Headers,
#   PrivateHeaders, Modules and XPCServices: the XPC services
#   (Installer.xpc, Downloader.xpc) are for sandboxed apps only, and
#   Armadale is not sandboxed.
# - Re-signs the two helpers Sparkle runs, Versions/B/Autoupdate and
#   Versions/B/Updater.app, and then the framework, with the build's
#   identity: ad hoc in Debug, Developer ID in Release with the hardened
#   runtime and a secure timestamp; never --deep, never with entitlements.
#   Sparkle ships them ad hoc signed, and nothing else would re-sign the
#   code inside the framework (scripts/release.sh takes the app from the
#   archive without exporting it). The identifiers Sparkle gave them are
#   kept.
#
# Xcode's own embed of the package framework is not used (project.yml has
# `link: false`): it is not a build phase, so no script phase can be
# ordered after it. Every configuration gets the same bundle shape.
set -euo pipefail

: "${BUILT_PRODUCTS_DIR:?run from Xcode}" "${TARGET_BUILD_DIR:?}" "${FRAMEWORKS_FOLDER_PATH:?}"

source="$BUILT_PRODUCTS_DIR/Sparkle.framework"
destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
framework="$destination/Sparkle.framework"
if [ ! -d "$source/Versions/B" ]; then
    echo "error: $source/Versions/B is missing: the Sparkle package was not built before this phase" >&2
    exit 1
fi

mkdir -p "$framework"
# --delete keeps the copy exact across builds (and drops what an earlier
# build embedded that this one excludes).
/usr/bin/rsync -a --delete \
    --exclude Headers --exclude PrivateHeaders --exclude Modules --exclude XPCServices \
    "$source/" "$framework/"

for helper in "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app"; do
    [ -e "$helper" ] || { echo "error: $helper is missing from Sparkle.framework" >&2; exit 1; }
done
if [ -e "$framework/XPCServices" ] || [ -L "$framework/XPCServices" ] || [ -e "$framework/Versions/B/XPCServices" ]; then
    echo "error: Sparkle's XPC services are still in $framework" >&2
    exit 1
fi

if [ "${CODE_SIGNING_ALLOWED:-YES}" != "YES" ] || [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    echo "note: code signing is off for this build; Sparkle's code is left as shipped"
    exit 0
fi

flags=(--force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier)
# As for the bundled persistence helper (scripts/embed-zmx.sh): the hardened
# runtime whenever the build has it. Xcode turns ENABLE_HARDENED_RUNTIME off
# for ad hoc ("Sign to Run Locally") builds, so Debug builds are plain ad hoc
# and never touch the keychain.
if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ]; then
    flags+=(--options runtime)
fi
if [ "$EXPANDED_CODE_SIGN_IDENTITY" = "-" ]; then
    flags+=(--timestamp=none)
else
    flags+=(--timestamp)
fi

# Inside out: the helpers, then the framework that seals them.
/usr/bin/codesign "${flags[@]}" "$framework/Versions/B/Autoupdate"
/usr/bin/codesign "${flags[@]}" "$framework/Versions/B/Updater.app"
/usr/bin/codesign "${flags[@]}" "$framework"
