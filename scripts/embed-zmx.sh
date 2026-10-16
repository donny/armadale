#!/bin/bash
# Xcode run-script phase of the Armadale app target (project.yml): bundles
# the pinned zmx (docs/DESIGN.md section 4, "Bundling").
#
# - Verifies Vendor/zmx against scripts/zmx.lock, fetching it if it is
#   missing or does not verify.
# - lipo's the two macOS binaries into a universal $DERIVED_FILE_DIR/zmx and
#   copies it to Contents/Helpers/zmx, re-signed with the app's identity,
#   the hardened runtime and no entitlements (like ctty-exec).
# - Copies the Linux binaries to Contents/Resources/remote/ as data, for
#   deployment to SSH hosts.
set -euo pipefail

: "${SRCROOT:?run from Xcode}" "${DERIVED_FILE_DIR:?}" "${TARGET_BUILD_DIR:?}"
: "${CONTENTS_FOLDER_PATH:?}" "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"

VENDOR="$SRCROOT/Vendor/zmx"
# Every binary must match the tarball zmx.lock pins, not merely exist: a
# stale or modified Vendor/zmx is re-fetched, and the build fails if that
# cannot produce verified binaries (offline, or a hash mismatch).
if ! "$SRCROOT/scripts/fetch-zmx.sh" --check >/dev/null 2>&1; then
    echo "note: Vendor/zmx is missing or does not match scripts/zmx.lock; running scripts/fetch-zmx.sh"
    "$SRCROOT/scripts/fetch-zmx.sh"
    "$SRCROOT/scripts/fetch-zmx.sh" --check
fi

universal="$DERIVED_FILE_DIR/zmx"
mkdir -p "$DERIVED_FILE_DIR"
lipo -create "$VENDOR/macos-aarch64/zmx" "$VENDOR/macos-x86_64/zmx" -output "$universal"

helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
remote="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/remote"
mkdir -p "$helpers" "$remote"
install -m 0755 "$universal" "$helpers/zmx"
install -m 0644 "$VENDOR/linux-aarch64/zmx" "$remote/zmx-linux-aarch64"
install -m 0644 "$VENDOR/linux-x86_64/zmx" "$remote/zmx-linux-x86_64"

# Sign like Xcode's sign-on-copy of ctty-exec: the app's identity, a stable
# identifier, no entitlements at all (a restricted entitlement without a
# provisioning profile can stop a helper from launching under Developer ID),
# and the hardened runtime whenever the build has it. Xcode turns
# ENABLE_HARDENED_RUNTIME off for ad-hoc ("Sign to Run Locally") builds, for
# its own targets and in this phase's environment alike, so local builds of
# both helpers are plain ad-hoc and Developer ID builds are hardened.
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    flags=(--force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --identifier "com.tinylittleapps.armadale.zmx")
    if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ]; then
        flags+=(--options runtime)
    fi
    if [ "$EXPANDED_CODE_SIGN_IDENTITY" = "-" ]; then
        flags+=(--timestamp=none)
    else
        flags+=(--timestamp)
    fi
    /usr/bin/codesign "${flags[@]}" "$helpers/zmx"
fi
