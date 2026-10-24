#!/bin/bash
# Bumps the build number (CURRENT_PROJECT_VERSION) in project.yml, which is
# the only place the version numbers live: Info.plist takes them from the
# build settings. Run it before a release, then commit.
#
#   scripts/bump-build.sh                 next build number (current + 1)
#   scripts/bump-build.sh --set N         a specific build number (must be
#                                         greater than the current one)
#   scripts/bump-build.sh --version X.Y.Z also set MARKETING_VERSION
#   scripts/bump-build.sh --commit        commit the bump as
#                                         "Bump to <version> (<build>)"
#
# The build number is an integer that must increase with every release:
# CFBundleVersion is compared numerically by Launch Services and by
# updaters, so a git commit hash cannot serve as one. To know which commit
# a build came from, use the git tag the release prints, or the commit the
# "Bump" commit sits on.
set -euo pipefail

cd "$(dirname "$0")/.."
spec=project.yml

set_build=""
version=""
commit=no
while [ $# -gt 0 ]; do
    case "$1" in
        --set) set_build="${2:?--set needs a number}"; shift ;;
        --version) version="${2:?--version needs X.Y.Z}"; shift ;;
        --commit) commit=yes ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "bump-build: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

current=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$spec")
current_version=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*([0-9][0-9.]*)[[:space:]]*$/\1/p' "$spec")
if [ "$(printf '%s\n' "$current" | wc -l | tr -d ' ')" != 1 ] || [ -z "$current" ]; then
    echo "bump-build: expected exactly one CURRENT_PROJECT_VERSION line in $spec" >&2
    exit 1
fi
if [ "$(printf '%s\n' "$current_version" | wc -l | tr -d ' ')" != 1 ] || [ -z "$current_version" ]; then
    echo "bump-build: expected exactly one MARKETING_VERSION line in $spec" >&2
    exit 1
fi

if [ -n "$set_build" ]; then
    case "$set_build" in ''|*[!0-9]*) echo "bump-build: --set needs an integer" >&2; exit 2 ;; esac
    if [ "$set_build" -le "$current" ]; then
        echo "bump-build: build $set_build is not greater than the current $current" >&2
        exit 1
    fi
    next=$set_build
else
    next=$((current + 1))
fi
new_version=${version:-$current_version}
case "$new_version" in
    *[!0-9.]*|*..*|.*|*.) echo "bump-build: --version needs digits and dots, like 0.2.0" >&2; exit 2 ;;
esac

if [ "$commit" = yes ] && [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
    echo "bump-build: the working tree must be clean to --commit" >&2
    exit 1
fi

sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*)[0-9]+[[:space:]]*$/\1$next/" "$spec"
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*)[0-9][0-9.]*[[:space:]]*$/\1$new_version/" "$spec"
echo "bump-build: $current_version ($current) -> $new_version ($next) in $spec"

if [ "$commit" = yes ]; then
    git add "$spec"
    git commit -q -m "Bump to $new_version ($next)"
    echo "bump-build: committed $(git log --oneline -1)"
fi
