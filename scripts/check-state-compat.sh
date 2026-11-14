#!/bin/bash
# Checks the state file's version rule (docs/DESIGN.md section 3) from the
# side of the released builds: every release tag must answer a state file
# written by the working tree in one of two ways only. Either it refuses the
# file by version (`newerVersion`), or it reads it (`loaded`) and its next
# save would keep everything in it. Never `unparseable` (treated as damaged),
# and never `loaded` with something lost.
#
#   scripts/check-state-compat.sh                  the working tree's file as written
#   scripts/check-state-compat.sh --as-schema N    the same file with schemaVersion set to N
#
# Run it before a release, and whenever the state file's shape changes. It is
# not part of the build-and-test gate: it builds every released version's
# ArmadaleCore (a few seconds each) and needs no network. `--as-schema` is
# for showing what the check catches, for example the file as it would be
# without a version bump.
#
# The working tree's code writes a representative state
# (scripts/state-fixtures/current.swift); then, for every tag `v*` in
# version order, that tag's own StateStore.load reads a fresh copy of it
# (scripts/state-fixtures/load.swift, built in a temporary worktree of the
# tag by scripts/state-fixtures/run.sh). When the tag loads it, the state is
# repaired and encoded again by the tag's own code and compared with the
# file it was given (scripts/state-fixtures/compare.py): every key path the
# tag would drop or change is printed. Key order, whitespace, the version
# number and keys the tag adds are not loss. A path whose loss is safe can be
# listed, with its reason, in scripts/state-fixtures/accepted-drops.
#
# What is modelled is the release's load and its repair
# (`PersistedState.repaired()`, which every released app applies before its
# first save); anything its AppModel changes at launch or later is not.
#
# One line per tag: `loaded`, `newerVersion`, `loaded, would lose:` (then the
# paths), or `unparseable` (with the problem). Exit status: 0 when every tag
# passes; 1 if any tag answers `unparseable`; 3 if none does but a tag would
# lose something not accepted; 2 if a step fails or answers anything else
# (a tag that fails to build, an `ioError`, an error in compare.py), which
# stops the run before the later tags are checked; 130 when interrupted
# (SIGINT or SIGTERM), after the running build has been stopped and cleaned
# up. Scratch files live in a temporary directory removed on exit; the
# repository's working tree and `git worktree list` are left as they were.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$ROOT/scripts/state-fixtures"
RUN="$FIXTURES/run.sh"

die() { echo "check-state-compat: error: $*" >&2; exit 2; }

AS_SCHEMA=""
case "${1:-}" in
    "") ;;
    --as-schema)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--as-schema needs a number"
        AS_SCHEMA="$2" ;;
    -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--as-schema N]" >&2; exit 2 ;;
esac

# The removal is guarded so it can only ever delete a directory this script
# created.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/armadale-state-compat.XXXXXX")"
cleanup() {
    case "$WORK" in
        */armadale-state-compat.??????) /bin/rm -rf -- "$WORK" ;;
    esac
}
trap cleanup EXIT

# Each step runs in the background so a signal is handled at once: the
# step (run.sh, which stops its own build and removes its worktree) is
# asked to stop and waited for.
CHILD=""
interrupted() {
    if [ -n "$CHILD" ]; then
        kill -TERM "$CHILD" 2>/dev/null || true
        wait "$CHILD" 2>/dev/null || true
    fi
    echo "check-state-compat: interrupted" >&2
    exit 130
}
trap interrupted INT TERM

# Runs a command in the background with stdout to $1, and waits for it.
step() {
    local out="$1"
    shift
    "$@" >"$out" &
    CHILD=$!
    local status=0
    wait "$CHILD" || status=$?
    CHILD=""
    # run.sh exits 130 when interrupted (Ctrl-C reaches its build directly).
    [ "$status" != 130 ] || interrupted
    return "$status"
}

step "$WORK/written.out" "$RUN" --working-tree "$FIXTURES/current.swift" "$WORK/state.json" \
    || die "the working tree could not write its state file"
if [ -n "$AS_SCHEMA" ]; then
    /usr/bin/python3 -I -c '
import json, sys
path, version = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as f: state = json.load(f)
state["schemaVersion"] = version
with open(path, "w", encoding="utf-8") as f: json.dump(state, f, indent=2, sort_keys=True)
' "$WORK/state.json" "$AS_SCHEMA" || die "could not set schemaVersion to $AS_SCHEMA"
    echo "working tree's file, with schemaVersion set to $AS_SCHEMA"
else
    version="$(sed -n 's/^  "schemaVersion" : \([0-9]*\),$/\1/p' "$WORK/state.json")"
    echo "working tree writes schema ${version:-?}"
fi

tags="$(git -C "$ROOT" tag -l 'v*' --sort=version:refname)"
[ -n "$tags" ] || die "no release tags (v*)"

unparseable=0
lossy=0
for tag in $tags; do
    mkdir "$WORK/$tag"
    cp "$WORK/state.json" "$WORK/$tag/state.json"
    step "$WORK/$tag/answer" "$RUN" "$tag" "$FIXTURES/load.swift" "$WORK/$tag/state.json" "$WORK/$tag/resaved.json" \
        || die "$tag: could not run its StateStore.load"
    line="$(head -n 1 "$WORK/$tag/answer")"
    answer="${line%%$'\t'*}"
    case "$answer" in
        newerVersion)
            echo "$tag: newerVersion" ;;
        loaded)
            if /usr/bin/python3 -I "$FIXTURES/compare.py" "$WORK/state.json" "$WORK/$tag/resaved.json" \
                "$FIXTURES/accepted-drops" >"$WORK/$tag/lost"; then
                if [ -s "$WORK/$tag/lost" ]; then
                    echo "$tag: loaded, losing only accepted paths:"
                    sed 's/^/    /' "$WORK/$tag/lost"
                else
                    echo "$tag: loaded"
                fi
            else
                status=$?
                [ "$status" = 1 ] || die "$tag: comparing its saved state failed"
                echo "$tag: loaded, would lose:"
                sed 's/^/    /' "$WORK/$tag/lost"
                lossy=$((lossy + 1))
            fi ;;
        unparseable)
            echo "$tag: unparseable (${line#*$'\t'})"
            unparseable=$((unparseable + 1)) ;;
        *)
            die "$tag: unexpected answer: $line" ;;
    esac
done

if [ "$unparseable" != 0 ]; then
    echo "check-state-compat: $unparseable release(s) would treat the file as damaged; bump schemaVersion (docs/DESIGN.md section 3)" >&2
fi
if [ "$lossy" != 0 ]; then
    cat >&2 <<EOF
check-state-compat: $lossy release(s) would read the file and lose what is listed above at their next save.
The rule (docs/DESIGN.md section 3): a released build reads a newer file without loss, or refuses it by version.
Either bump schemaVersion (with a migration step), or, if losing a path is safe (it ends no session and loses
no layout), list it with the reason in scripts/state-fixtures/accepted-drops.
EOF
fi
[ "$unparseable" = 0 ] || exit 1
[ "$lossy" = 0 ] || exit 3
exit 0
