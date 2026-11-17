#!/bin/bash
# Runs one of Sparkle's command-line tools from the pinned Sparkle package
# (docs/DESIGN.md section 11, "Release pipeline"):
#
#   scripts/sparkle-tool.sh generate_keys|sign_update|generate_appcast [args…]
#
# The tools come in the Swift package's artifact, the same 2.10.1 the app
# embeds, under SourcePackages/artifacts/sparkle/Sparkle/bin/ of either the
# release build's DerivedData (build/release/DerivedData) or the project's
# default DerivedData. Arguments are passed on unchanged; this script never
# runs a tool by itself. Note that `generate_keys` with no key in the
# keychain creates one: that is the owner's to run (README, "Releasing").
set -euo pipefail

# The repository root, without changing directory: the tool's arguments
# are paths relative to where it was run from.
root="$(cd "$(dirname "$0")/.." && pwd)"

tool="${1:-}"
case "$tool" in
    generate_keys|sign_update|generate_appcast) shift ;;
    -h|--help|"") sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sparkle-tool: unknown tool: $tool (generate_keys, sign_update or generate_appcast)" >&2; exit 2 ;;
esac

candidates=("$root/build/release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin")
for dir in "$HOME"/Library/Developer/Xcode/DerivedData/Armadale-*/SourcePackages/artifacts/sparkle/Sparkle/bin; do
    candidates+=("$dir")
done
for dir in "${candidates[@]}"; do
    if [ -x "$dir/$tool" ]; then
        exec "$dir/$tool" "$@"
    fi
done

cat >&2 <<MESSAGE
sparkle-tool: Sparkle's $tool was not found: the Sparkle package has not been
fetched on this Mac yet. Fetch it with the build (README, "Generate, build,
test"):

  xcodegen generate && xcodebuild -project Armadale.xcodeproj -scheme Armadale \\
    -destination 'platform=macOS' -skipPackagePluginValidation \\
    -onlyUsePackageVersionsFromResolvedFile build

and run this again.
MESSAGE
exit 1
