#!/bin/bash
# Builds the release artifact: a Developer ID signed, notarized and stapled
# DMG (docs/DESIGN.md section 11, "Release pipeline (step 9)").
#
#   scripts/release.sh [--skip-notarize] [--allow-dirty] [--allow-existing-tag]
#
#   --skip-notarize       stop after the signature checks and build an
#                         unnotarized DMG (Armadale-<version>-unnotarized.dmg),
#                         for checking the pipeline without notary
#                         credentials. That DMG is not for distribution.
#   --allow-dirty         build from a working tree with uncommitted or
#                         untracked changes.
#   --allow-existing-tag  build although the tag v<version> already exists
#                         (normally the version must be bumped first).
#
# Every run removes build/release first, including a DMG from an earlier
# run: move a finished DMG out before running again.
#
# Steps: xcodegen; `xcodebuild archive` (Release) into build/release/;
# verify the app and both helpers (Developer ID, hardened runtime, secure
# timestamp, entitlements, universal zmx); notarize and staple the app;
# build the DMG with dmgbuild (the designed Finder window: background,
# icon positions, volume icon; scripts/dmg/settings.py), sign, notarize and
# staple it; final Gatekeeper checks. Output:
# build/release/Armadale-<MARKETING_VERSION>.dmg (named so only once every
# check has passed). Nothing is tagged or uploaded; the suggested tag
# command is printed at the end.
#
# Prerequisites: the team's "Developer ID Application" certificate in the
# login keychain (if several valid ones exist, for example after a renewal,
# set ARMADALE_SIGNING_IDENTITY to the SHA-1 of the one to use); the pinned
# dmgbuild in Vendor/dmgbuild, installed once with scripts/fetch-dmgbuild.sh;
# and (unless --skip-notarize) the notary keychain profile, created once with
#   xcrun notarytool store-credentials armadale-notary \
#     --apple-id <apple id> --team-id YJ8LXVCB3T
set -euo pipefail

TEAM_ID="YJ8LXVCB3T"
NOTARY_PROFILE="armadale-notary"

skip_notarize=0
allow_dirty=0
allow_existing_tag=0
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) skip_notarize=1 ;;
        --allow-dirty) allow_dirty=1 ;;
        --allow-existing-tag) allow_existing_tag=1 ;;
        -h|--help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "release: unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
fail() { printf '\nrelease: FAILED: %s\n' "$*" >&2; exit 1; }

cd "$(dirname "$0")/.."
[ -f project.yml ] && [ -f scripts/release.sh ] || fail "not at the repository root"

# --- Preflight --------------------------------------------------------------
step "Preflight"
command -v xcodegen >/dev/null || fail "xcodegen is not installed (brew install xcodegen)"
# dmgbuild lays out the DMG (step 4); checked now rather than after the
# archive and notarization.
DMGBUILD_PYTHON="Vendor/dmgbuild/bin/python3"
scripts/fetch-dmgbuild.sh --check >/dev/null 2>&1 \
    || fail "Vendor/dmgbuild is missing or does not match scripts/dmgbuild-requirements.txt; run scripts/fetch-dmgbuild.sh"
info "dmgbuild $("$DMGBUILD_PYTHON" -I -c 'from importlib import metadata; print(metadata.version("dmgbuild"))')"
for file in scripts/dmg/settings.py scripts/dmg/background.tiff; do
    [ -f "$file" ] || fail "$file is missing"
done
# dmgbuild attaches its scratch image at /Volumes/Armadale and records that
# path in the window's background bookmark; a mounted volume of that name
# would push it to "/Volumes/Armadale 1".
[ ! -e /Volumes/Armadale ] || fail "a volume named Armadale is mounted; eject it first"

# --untracked-files=normal: a status.showUntrackedFiles setting must not
# hide untracked files (XcodeGen compiles whatever is in the source folders).
dirty_at_start=0
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
    dirty_at_start=1
    if [ "$allow_dirty" = 1 ]; then
        info "working tree has uncommitted changes (--allow-dirty): this build is not reproducible from a commit"
    else
        git status --short --untracked-files=normal >&2
        fail "the working tree has uncommitted or untracked changes; commit them, or pass --allow-dirty"
    fi
fi
commit="$(git rev-parse --short HEAD)"
info "commit $commit"

# The identity the DMG is signed with, by SHA-1 so that a renewed
# certificate next to the old one cannot make the choice ambiguous. Xcode
# picks the identity for the app itself; step 2 checks they agree.
identity_hashes="$( (security find-identity -v -p codesigning || true) \
    | grep "\"Developer ID Application: .* ($TEAM_ID)\"" | awk '{print $2}' | sort -u || true)"
identity_count="$(grep -c . <<<"$identity_hashes" || true)"
if [ -n "${ARMADALE_SIGNING_IDENTITY:-}" ]; then
    signing_hash="$(tr '[:lower:]' '[:upper:]' <<<"$ARMADALE_SIGNING_IDENTITY")"
    grep -qx "$signing_hash" <<<"$identity_hashes" \
        || fail "ARMADALE_SIGNING_IDENTITY=$ARMADALE_SIGNING_IDENTITY is not a valid \"Developer ID Application: … ($TEAM_ID)\" identity (security find-identity -v -p codesigning)"
    info "Developer ID Application identity $signing_hash (ARMADALE_SIGNING_IDENTITY)"
elif [ "$identity_count" = 0 ]; then
    fail "no valid \"Developer ID Application: … ($TEAM_ID)\" identity in the keychain (security find-identity -v -p codesigning)"
elif [ "$identity_count" -gt 1 ]; then
    security find-identity -v -p codesigning | grep "Developer ID Application: .* ($TEAM_ID)" >&2 || true
    fail "several valid Developer ID Application identities for $TEAM_ID (above); set ARMADALE_SIGNING_IDENTITY=<sha1> to the one to sign with"
else
    signing_hash="$identity_hashes"
    info "Developer ID Application identity $signing_hash"
fi

if [ "$skip_notarize" = 0 ]; then
    if ! history_out="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)"; then
        echo "$history_out" >&2
        if grep -q "No Keychain password item found" <<<"$history_out"; then
            fail "the notary keychain profile \"$NOTARY_PROFILE\" does not exist. Create it once with
    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple id> --team-id $TEAM_ID
(it asks for an app-specific password from account.apple.com), or pass --skip-notarize"
        fi
        fail "notarytool could not use the keychain profile \"$NOTARY_PROFILE\" (output above)"
    fi
    info "notary keychain profile \"$NOTARY_PROFILE\" works"
else
    info "--skip-notarize: no notarization, the DMG will not pass Gatekeeper"
fi

# --- 1. Archive ---------------------------------------------------------------
step "Archive (Release) into build/release"
rm -rf build/release
mkdir -p build/release
xcodegen generate
# A private DerivedData so a release never reuses intermediates from
# development builds. The full log is kept; xcodebuild's own output is
# filtered to warnings, errors and the result.
if ! xcodebuild archive \
        -project Armadale.xcodeproj -scheme Armadale -configuration Release \
        -destination 'generic/platform=macOS' \
        -archivePath build/release/Armadale.xcarchive \
        -derivedDataPath build/release/DerivedData \
        -skipPackagePluginValidation -onlyUsePackageVersionsFromResolvedFile \
        >build/release/archive.log 2>&1; then
    grep -E "error:|warning:" build/release/archive.log | sort -u | tail -40 >&2 || true
    fail "xcodebuild archive failed (full log: build/release/archive.log)"
fi
# (appintentsmetadataprocessor's "no AppIntents.framework dependency" note
# is not a warning about this project.)
grep -E "warning:" build/release/archive.log | grep -v appintentsmetadataprocessor | sort -u || true
grep -m1 'ARCHIVE SUCCEEDED' build/release/archive.log \
    || fail "xcodebuild archive did not report ARCHIVE SUCCEEDED (full log: build/release/archive.log)"

APP="build/release/Armadale.xcarchive/Products/Applications/Armadale.app"
[ -d "$APP" ] || fail "the archive has no Products/Applications/Armadale.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
info "Armadale $version ($build), $(lipo -archs "$APP/Contents/MacOS/Armadale")"
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
    if [ "$allow_existing_tag" = 1 ]; then
        info "tag v$version already exists (--allow-existing-tag)"
    else
        fail "tag v$version already exists; bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml (or pass --allow-existing-tag)"
    fi
fi

# --- 2. Verify ----------------------------------------------------------------
step "Verify signatures"
if ! out="$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)"; then
    echo "$out" >&2
    fail "codesign --verify --deep --strict rejects the app"
fi
echo "$out" | sed 's/^/    /'

mkdir -p build/release/verify
# check_signature PATH NAME: signed with the Developer ID identity of
# $TEAM_ID, the hardened runtime and a secure timestamp. Sets
# checked_authority. Every substitution tolerates failure so that an
# unsigned or ad hoc binary reaches the matching message.
check_signature() {
    local path="$1" name="$2" details authority flags team
    [ -e "$path" ] || fail "$name is missing"
    details="$(codesign -d -vv "$path" 2>&1 || true)"
    authority="$( (grep -m1 '^Authority=' <<<"$details" || true) | sed 's/^Authority=//')"
    flags="$( (grep -m1 '^CodeDirectory' <<<"$details" || true) | sed -n 's/.*flags=[^(]*(\([^)]*\)).*/\1/p')"
    team="$( (grep -m1 '^TeamIdentifier=' <<<"$details" || true) | sed 's/^TeamIdentifier=//')"
    case "$authority" in
        "Developer ID Application: "*"($TEAM_ID)") ;;
        *) echo "$details" >&2; fail "$name is not signed with the Developer ID identity of $TEAM_ID" ;;
    esac
    [ "$team" = "$TEAM_ID" ] || { echo "$details" >&2; fail "$name has TeamIdentifier '$team'"; }
    grep -qw runtime <<<"$flags" || { echo "$details" >&2; fail "$name is not signed with the hardened runtime"; }
    grep -q '^Timestamp=' <<<"$details" || { echo "$details" >&2; fail "$name has no secure timestamp"; }
    info "$name: $authority, flags ($flags), $(grep -m1 '^Timestamp=' <<<"$details")"
    checked_authority="$authority"
}
signer=""
for path in "$APP" "$APP/Contents/Helpers/zmx" "$APP/Contents/Helpers/ctty-exec"; do
    name="${path#"$APP"}"; name="Armadale.app${name}"
    check_signature "$path" "$name"
    if [ -z "$signer" ]; then signer="$checked_authority"; fi
    [ "$checked_authority" = "$signer" ] || fail "$name is signed by '$checked_authority', the app by '$signer'"
done

# The certificate Xcode signed the app with must be the identity the DMG
# will be signed with (its SHA-1 is the identity's hash). build/release is
# fresh, so app-cert0 is this run's.
codesign -d --extract-certificates=build/release/verify/app-cert "$APP" >/dev/null 2>&1 || true
app_cert_hash="$(shasum -a 1 build/release/verify/app-cert0 2>/dev/null | awk '{print toupper($1)}' || true)"
[ "$app_cert_hash" = "$signing_hash" ] \
    || fail "the app is signed with certificate ${app_cert_hash:-unknown}, but the DMG would be signed with $signing_hash; set ARMADALE_SIGNING_IDENTITY to the certificate Xcode uses"
info "the app's certificate is identity $signing_hash"

# Entitlements: none on the helpers (a restricted entitlement without a
# provisioning profile can stop a helper from launching), and only the
# sandbox-off entitlement on the app (no get-task-allow in a release).
entitlements_json() {
    codesign -d --entitlements - --xml "$1" >build/release/verify/entitlements.plist 2>/dev/null || true
    if [ -s build/release/verify/entitlements.plist ]; then
        plutil -convert json -o - build/release/verify/entitlements.plist || echo "unreadable"
    else
        echo "none"
    fi
}
for helper in zmx ctty-exec; do
    ents="$(entitlements_json "$APP/Contents/Helpers/$helper")"
    [ "$ents" = "none" ] || fail "Contents/Helpers/$helper carries entitlements: $ents"
    info "Armadale.app/Contents/Helpers/$helper: no entitlements"
done
ents="$(entitlements_json "$APP")"
[ "$ents" = '{"com.apple.security.app-sandbox":false}' ] \
    || fail "Armadale.app has unexpected entitlements: $ents"
info "Armadale.app: entitlements $ents"

zmx_archs="$(lipo -archs "$APP/Contents/Helpers/zmx" || true)"
for arch in arm64 x86_64; do
    grep -qw "$arch" <<<"$zmx_archs" \
        || fail "Contents/Helpers/zmx is not universal (architectures: $zmx_archs)"
done
info "Armadale.app/Contents/Helpers/zmx: universal ($zmx_archs)"

# Submits $1 to the notary service and waits; fails unless it is Accepted,
# printing the service's log.
notarize() {
    local file="$1" label="$2" result="build/release/verify/notary-$2.json" status id
    info "submitting $file (this usually takes a few minutes)"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait \
        --output-format json >"$result" || true
    status="$(plutil -extract status raw -o - "$result" 2>/dev/null || echo "unknown")"
    id="$(plutil -extract id raw -o - "$result" 2>/dev/null || echo "")"
    info "notarization of $label: $status (submission ${id:-unknown})"
    if [ "$status" != "Accepted" ]; then
        cat "$result" >&2 || true
        if [ -n "$id" ]; then
            xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" \
                "build/release/verify/notary-$label-log.json" >/dev/null 2>&1 || true
            cat "build/release/verify/notary-$label-log.json" >&2 || true
        fi
        fail "notarization of $label was not accepted"
    fi
    # An accepted submission can still carry warnings; show them.
    if xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" \
            "build/release/verify/notary-$label-log.json" >/dev/null 2>&1; then
        if grep -Eq '"issues" *: *null' "build/release/verify/notary-$label-log.json"; then
            info "notary log: no issues"
        else
            info "notary log reports issues (accepted anyway):"
            sed 's/^/      /' "build/release/verify/notary-$label-log.json"
        fi
    else
        info "could not fetch the notary log (not fatal)"
    fi
}

# staple FILE LABEL: staples the notarization ticket to FILE, failing with
# a message if that does not work.
staple() {
    if ! out="$(xcrun stapler staple "$1" 2>&1)"; then
        echo "$out" >&2
        fail "stapling the $2 failed"
    fi
    echo "$out" | sed 's/^/    /'
}

# --- 3. Notarize and staple the app ---------------------------------------------
if [ "$skip_notarize" = 0 ]; then
    step "Notarize the app"
    mkdir -p build/release/notarize
    ditto -c -k --keepParent "$APP" build/release/notarize/Armadale.zip
    notarize build/release/notarize/Armadale.zip app
    staple "$APP" app
fi

# --- 4. DMG ---------------------------------------------------------------------
# A notarized DMG is built as "-pending" and gets its final name only once
# every check below has passed, so a failed run never leaves a file that
# looks like a release.
if [ "$skip_notarize" = 0 ]; then
    DMG="build/release/Armadale-$version-pending.dmg"
    FINAL_DMG="build/release/Armadale-$version.dmg"
else
    DMG="build/release/Armadale-$version-unnotarized.dmg"
    FINAL_DMG="$DMG"
fi
step "Build $DMG"
# The volume icon is the plain app icon, made here from the asset catalog's
# AppIcon rasters (the app's own AppIcon.icns, compiled from the Icon
# Composer document, holds only the 16 and 128 pt sizes).
mkdir -p build/release/dmg/Armadale.iconset
appiconset="Armadale/Resources/Assets.xcassets/AppIcon.appiconset"
for points in 16 32 128 256 512; do
    for scale in 1 2; do
        source="$appiconset/icon_$((points * scale)).png"
        [ -f "$source" ] || fail "$source is missing (scripts/render-app-icon.swift writes it)"
        if [ "$scale" = 1 ]; then name="icon_${points}x${points}.png"; else name="icon_${points}x${points}@2x.png"; fi
        cp "$source" "build/release/dmg/Armadale.iconset/$name"
    done
done
iconutil -c icns -o build/release/dmg/Armadale.icns build/release/dmg/Armadale.iconset \
    || fail "iconutil could not make the volume icon"
# dmgbuild (scripts/dmg/settings.py) makes the image: a read-write HFS+
# volume "Armadale" holding the app (copied with ditto, so its signature and
# stapled ticket survive), an Applications symlink, the background and the
# volume icon, with the Finder window's layout in .DS_Store; then converts
# it to UDZO. -I keeps PYTHON* variables and the user's site-packages out.
# (On macOS 27 hdiutil warns on stderr that create, attach and convert are
# deprecated in favour of `diskutil image`; those lines are shown as they
# come.)
if ! "$DMGBUILD_PYTHON" -I -m dmgbuild -s scripts/dmg/settings.py \
        -D app="$APP" -D icon=build/release/dmg/Armadale.icns \
        Armadale "$DMG"; then
    fail "dmgbuild failed (output above)"
fi
[ -f "$DMG" ] || fail "dmgbuild did not write $DMG"
info "$DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"

# Check inside the image before signing it: dmgbuild ignores the exit
# status of the ditto that copies the app and of the SetFile that sets the
# volume icon flag. The image is mounted read-only without showing it in
# Finder, and detached again even when a check fails.
MOUNT="$PWD/build/release/dmg/mount"
mkdir -p "$MOUNT"
image_mounted=0
detach_image() {
    if [ "$image_mounted" = 1 ]; then
        hdiutil detach "$MOUNT" -quiet 2>/dev/null || hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true
        image_mounted=0
    fi
    rmdir "$MOUNT" 2>/dev/null || true
}
trap detach_image EXIT
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG" >/dev/null 2>&1 \
    || fail "could not mount $DMG to check it"
image_mounted=1
[ -d "$MOUNT/Armadale.app" ] || fail "the DMG has no Armadale.app"
if ! diff -r "$APP" "$MOUNT/Armadale.app" >build/release/verify/dmg-app.diff 2>&1; then
    head -20 build/release/verify/dmg-app.diff >&2
    fail "Armadale.app in the DMG differs from $APP (full list: build/release/verify/dmg-app.diff)"
fi
info "Armadale.app in the DMG is identical to the archived app"
if ! out="$(codesign --verify --deep --strict "$MOUNT/Armadale.app" 2>&1)"; then
    echo "$out" >&2
    fail "codesign --verify --deep --strict rejects Armadale.app inside the DMG"
fi
info "Armadale.app in the DMG: signature verifies (--deep --strict)"
if [ "$skip_notarize" = 0 ]; then
    if ! out="$(xcrun stapler validate "$MOUNT/Armadale.app" 2>&1)"; then
        echo "$out" >&2
        fail "Armadale.app inside the DMG has no valid stapled ticket"
    fi
    info "Armadale.app in the DMG: stapled ticket validates"
fi
[ "$(readlink "$MOUNT/Applications" || true)" = /Applications ] \
    || fail "the DMG's Applications item is not a symlink to /Applications"
for file in .background.tiff .VolumeIcon.icns .DS_Store; do
    [ -f "$MOUNT/$file" ] || fail "the DMG has no $file"
done
[ "$(GetFileInfo -aC "$MOUNT" 2>/dev/null || true)" = 1 ] \
    || fail "the DMG's volume does not have the custom icon flag set (SetFile -a C)"
info "Applications link, background, volume icon (custom icon flag set) and .DS_Store present"
hdiutil detach "$MOUNT" -quiet || fail "could not detach the DMG from $MOUNT"
image_mounted=0
trap - EXIT
rmdir "$MOUNT"

codesign --sign "$signing_hash" --timestamp "$DMG" || fail "signing the DMG failed"
if ! out="$(codesign --verify --strict --verbose=2 "$DMG" 2>&1)"; then
    echo "$out" >&2
    fail "codesign --verify --strict rejects the DMG"
fi
echo "$out" | sed 's/^/    /'
if ! out="$(hdiutil verify "$DMG" 2>&1)"; then
    echo "$out" >&2
    fail "hdiutil verify rejects the DMG"
fi
echo "$out" | tail -1 | sed 's/^/    /'

if [ "$skip_notarize" = 0 ]; then
    step "Notarize the DMG"
    notarize "$DMG" dmg
    staple "$DMG" DMG
fi

# --- 5. Final checks ----------------------------------------------------------
step "Gatekeeper"
app_assess="$(spctl --assess --type execute --verbose=2 "$APP" 2>&1 || true)"
dmg_assess="$(spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 || true)"
echo "$app_assess" | sed 's/^/    /'
echo "$dmg_assess" | sed 's/^/    /'

if [ "$skip_notarize" = 1 ]; then
    step "Done (unnotarized)"
    info "$DMG"
    info "signed with $signer but NOT notarized: Gatekeeper rejects it"
    info "(\"source=Unnotarized Developer ID\" above is expected). Not for distribution."
    exit 0
fi

grep -q ": accepted" <<<"$app_assess" && grep -q "source=Notarized Developer ID" <<<"$app_assess" \
    || fail "Gatekeeper does not accept the app as notarized"
grep -q ": accepted" <<<"$dmg_assess" && grep -q "source=Notarized Developer ID" <<<"$dmg_assess" \
    || fail "Gatekeeper does not accept the DMG as notarized"
for file in "$APP" "$DMG"; do
    if ! out="$(xcrun stapler validate "$file" 2>&1)"; then
        echo "$out" >&2
        fail "stapler validate rejects $file"
    fi
    echo "$out" | sed 's/^/    /'
done
mv "$DMG" "$FINAL_DMG"

step "Done"
info "$FINAL_DMG ($(du -h "$FINAL_DMG" | cut -f1 | tr -d ' '))"
info "Armadale $version ($build) from commit $commit, notarized and stapled"
if [ "$dirty_at_start" = 1 ]; then
    info "built from a working tree with uncommitted changes: commit them and run again"
    info "before tagging, so the tag names what was built"
else
    info "suggested tag:  git tag -a v$version -m \"Armadale $version\" $commit && git push origin v$version"
fi
