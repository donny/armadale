#!/bin/bash
# Builds one Swift program against the ArmadaleCore of a release tag (or of
# the working tree) and runs it. Used to write the state fixtures with each
# released version's own code, and by scripts/check-state-compat.sh to ask
# each released version to load a file the working tree wrote.
#
#   scripts/state-fixtures/run.sh <tag> <program.swift> [arguments...]
#   scripts/state-fixtures/run.sh --working-tree <program.swift> [arguments...]
#
# The program is one Swift file with an `@main` type; it is compiled as the
# only file of an executable that depends on ArmadaleCore, then run in the
# caller's directory with the arguments. A tag's ArmadaleCore comes from a
# temporary `git worktree` of that tag; the working tree's is a copy of
# Packages/ArmadaleCore. Everything (worktree, package, build) lives in one
# temporary directory under $TMPDIR, removed on exit together with the
# worktree (only this run's own worktree: no repository-wide prune), so the
# repository's working tree and `git worktree list` are left as they were.
# Needs no network: ArmadaleCore has no dependencies. Build output goes to
# the temporary directory's log and is shown only when the build fails.
# SIGINT or SIGTERM (to this script, or a signal that stops the build)
# stops the build, cleans up, prints one line and exits 130.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

die() { echo "state-fixtures/run: error: $*" >&2; exit 1; }

[ $# -ge 2 ] || { sed -n '2,21p' "$0" >&2; exit 2; }
REF="$1"
PROGRAM="$2"
shift 2
[ -f "$PROGRAM" ] || die "no such program: $PROGRAM"

# One scratch directory for the whole run. The removal is guarded so it can
# only ever delete a directory this script created; its worktree is
# unregistered first.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/armadale-state-tool.XXXXXX")"
cleanup() {
    if [ -d "$WORK/tree" ]; then
        git -C "$ROOT" worktree remove --force "$WORK/tree" >/dev/null 2>&1 || true
    fi
    case "$WORK" in
        */armadale-state-tool.??????) /bin/rm -rf -- "$WORK" ;;
    esac
}
trap cleanup EXIT

# The build runs in the background so a signal is handled at once: the
# build is stopped and waited for, then the EXIT trap cleans up.
CHILD=""
interrupted() {
    if [ -n "$CHILD" ]; then
        kill -TERM "$CHILD" 2>/dev/null || true
        wait "$CHILD" 2>/dev/null || true
    fi
    echo "state-fixtures/run: interrupted" >&2
    exit 130
}
trap interrupted INT TERM

if [ "$REF" = "--working-tree" ]; then
    mkdir -p "$WORK/core"
    rsync -a --exclude .build --exclude .swiftpm "$ROOT/Packages/ArmadaleCore/" "$WORK/core/ArmadaleCore/"
    CORE="$WORK/core/ArmadaleCore"
else
    git -C "$ROOT" rev-parse -q --verify "refs/tags/$REF" >/dev/null || die "no such tag: $REF"
    git -C "$ROOT" worktree add --quiet --detach "$WORK/tree" "refs/tags/$REF" >/dev/null 2>&1 \
        || die "cannot check out $REF into a temporary worktree"
    CORE="$WORK/tree/Packages/ArmadaleCore"
fi
[ -f "$CORE/Package.swift" ] || die "$REF has no Packages/ArmadaleCore"

mkdir -p "$WORK/tool/Sources"
cp "$PROGRAM" "$WORK/tool/Sources/Tool.swift"
cat > "$WORK/tool/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StateTool",
    platforms: [.macOS("27.0")],
    dependencies: [.package(path: "$CORE")],
    targets: [
        .executableTarget(
            name: "StateTool",
            dependencies: [.product(name: "ArmadaleCore", package: "ArmadaleCore")],
            path: "Sources"),
    ],
    swiftLanguageModes: [.v6]
)
EOF

# SwiftPM leaves lock files in $TMPDIR; keep them inside the scratch directory.
mkdir -p "$WORK/tmp"
TMPDIR="$WORK/tmp" swift build --package-path "$WORK/tool" --disable-sandbox >"$WORK/build.log" 2>&1 &
CHILD=$!
status=0
wait "$CHILD" || status=$?
CHILD=""
if [ "$status" -gt 128 ]; then
    # The build was stopped by a signal (Ctrl-C reaches it directly): an
    # interruption, not a failure, so no build log.
    interrupted
elif [ "$status" != 0 ]; then
    cat "$WORK/build.log" >&2
    die "building $(basename "$PROGRAM") against ArmadaleCore of $REF failed"
fi
BIN="$(TMPDIR="$WORK/tmp" swift build --package-path "$WORK/tool" --show-bin-path)/StateTool"
"$BIN" "$@"
