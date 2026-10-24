#!/bin/bash
# Checks that SIGTERM (`pkill -x Armadale`, as at logout) quits Armadale
# within 2 s, in three situations:
#
#   1. sheet up: a fresh launch, whose new workspace shows the New Session
#      sheet (DESIGN section 8). AppKit refuses to terminate while a sheet
#      is attached, so the app must take it down first; the pane is saved
#      empty (state.json written after the signal, with a pane that has no
#      session).
#   2. normal: the pane saved by 1 is given a persistent session created
#      beforehand with the helper, and the app attaches to it. No session
#      client may outlive the app, and the session daemon must keep running.
#   3. with an app-modal alert up: the persistent runtime cannot be set up
#      (`<state dir>/bin` is a regular file), so the app shows its fallback
#      warning with `runModal()`. The quit must not wait for someone to
#      click OK, and must still go through the normal terminate path (the
#      state file is written by applicationWillTerminate after the signal).
#
#   scripts/check-quit.sh /path/to/Armadale.app
#
# Uses the scratch state directories /tmp/armadale-quitcheck and
# /tmp/armadale-quitcheck2, which must not exist yet, and removes them at the
# end. Armadale must not be running.
set -euo pipefail

APP="${1:?usage: scripts/check-quit.sh /path/to/Armadale.app}"
for dir in /tmp/armadale-quitcheck /tmp/armadale-quitcheck2; do
    if [ -e "$dir" ]; then
        echo "check-quit: $dir exists; remove it first" >&2
        exit 2
    fi
done
if pgrep -x Armadale >/dev/null; then
    echo "check-quit: Armadale is running; quit it first" >&2
    exit 2
fi

now_ms() { python3 -I -c 'import time; print(int(time.time() * 1000))'; }
zmx() { ZMX_DIR=/tmp/armadale-quitcheck/run /tmp/armadale-quitcheck/bin/zmx-* "$@" | cat; }

cleanup() {
    pkill -x Armadale 2>/dev/null || true
    sleep 1
    pkill -9 -x Armadale 2>/dev/null || true  # a failed check may leave it ignoring SIGTERM
    if [ -d /tmp/armadale-quitcheck/run ]; then
        for name in $(zmx ls --short); do zmx kill "$name" >/dev/null || true; done
    fi
    sleep 1
    rm -rf /tmp/armadale-quitcheck /tmp/armadale-quitcheck2
}
trap cleanup EXIT

# Sends SIGTERM and prints the milliseconds until Armadale is gone (or fails
# after 10 s).
terminate_and_time() {
    local start
    start=$(now_ms)
    pkill -x Armadale
    while pgrep -x Armadale >/dev/null; do
        if [ $(( $(now_ms) - start )) -gt 10000 ]; then
            echo "check-quit: FAIL: Armadale still running 10 s after SIGTERM" >&2
            exit 1
        fi
        sleep 0.02
    done
    echo $(( $(now_ms) - start ))
}

# Whether Armadale (pid $1) shows a window at the modal-panel level (an
# NSAlert running modally).
modal_alert_up() {
    /usr/bin/swift -e "
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let up = windows.contains { (\$0[kCGWindowOwnerPID as String] as? Int32) == $1
    && (\$0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.modalPanelWindow)) }
print(up ? \"yes\" : \"no\")" 2>/dev/null | tail -1
}

status=0

# Whether Armadale (pid $1) shows a sheet: a second normal-level window
# besides the workspace window.
sheet_up() {
    /usr/bin/swift -e "
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let count = windows.filter { (\$0[kCGWindowOwnerPID as String] as? Int32) == $1
    && (\$0[kCGWindowLayer as String] as? Int) == 0 }.count
print(count >= 2 ? \"yes\" : \"no\")" 2>/dev/null | tail -1
}

# --- 1. Quit with the New Session sheet up ----------------------------------
mkdir -p /tmp/armadale-quitcheck
open -n --env ARMADALE_STATE_DIR=/tmp/armadale-quitcheck "$APP"
pid=""
sheet="no"
for _ in $(seq 1 30); do
    pid="$(pgrep -x Armadale || true)"
    if [ -n "$pid" ]; then
        sheet="$(sheet_up "$pid")"
        [ "$sheet" = "yes" ] && break
    fi
    sleep 0.5
done
if [ "$sheet" != "yes" ]; then
    echo "check-quit [sheet]: FAIL: the New Session sheet did not appear" >&2
    exit 1
fi
echo "check-quit [sheet]: New Session sheet is up (pid $pid)"
sleep 1  # let the sheet settle
signalled=$(( $(now_ms) / 1000 ))
elapsed=$(terminate_and_time)
echo "check-quit [sheet]: Armadale exited ${elapsed} ms after SIGTERM with the sheet up"
if [ "$elapsed" -gt 2000 ]; then
    echo "check-quit [sheet]: FAIL: slower than 2 s" >&2
    status=1
fi
saved=$(stat -f %m /tmp/armadale-quitcheck/state.json 2>/dev/null || echo 0)
if [ "$saved" -ge "$signalled" ] && python3 -I - /tmp/armadale-quitcheck/state.json <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
panes = [p for w in state["workspaces"] for g in w["tabGroups"] for t in g["tabs"] for p in t["panes"]]
sys.exit(0 if len(panes) == 1 and not panes[0].get("sessionID") else 1)
PY
then
    echo "check-quit [sheet]: state saved on the way out, with the pane still empty"
else
    echo "check-quit [sheet]: FAIL: state.json not written after SIGTERM, or the pane is not empty" >&2
    status=1
fi

# --- 2. Normal quit ---------------------------------------------------------
# The pane saved empty by 1 gets a session the helper (installed by 1)
# creates now; the app attaches to it at launch.
session=a-quitchecksession
zmx run "$session" -d /bin/sleep 3600 >/dev/null
for _ in $(seq 1 25); do
    zmx ls --short 2>/dev/null | grep -qx "$session" && break
    sleep 0.2
done
helper_version="$(basename /tmp/armadale-quitcheck/bin/zmx-* | sed 's/^zmx-//')"
python3 -I - /tmp/armadale-quitcheck/state.json "${session#a-}" "$helper_version" <<'PY'
import json, sys
path, sid, version = sys.argv[1:4]
state = json.load(open(path))
pane = [p for w in state["workspaces"] for g in w["tabGroups"] for t in g["tabs"] for p in t["panes"]][0]
pane["sessionID"] = sid
state["sessions"] = [{
    "id": sid, "location": {"local": {}}, "profileID": "builtin.shell",
    "launch": {"arguments": [], "environment": {}}, "workingDirectory": "/tmp",
    "title": "", "createdAt": "2026-01-01T00:00:00Z", "runtimeVersion": version,
}]
json.dump(state, open(path, "w"))
PY
open -n --env ARMADALE_STATE_DIR=/tmp/armadale-quitcheck "$APP"
attached=""
for _ in $(seq 1 75); do
    if pgrep -f "attach $session /usr/bin/true" >/dev/null; then attached=yes; break; fi
    sleep 0.2
done
[ -n "$attached" ] || { echo "check-quit: FAIL: the app did not attach to $session" >&2; exit 1; }

elapsed=$(terminate_and_time)
sleep 0.5
echo "check-quit [normal]: Armadale exited ${elapsed} ms after SIGTERM"
if [ "$elapsed" -gt 2000 ]; then
    echo "check-quit [normal]: FAIL: slower than 2 s" >&2
    status=1
fi
if pgrep -f "attach $session /usr/bin/true" >/dev/null; then
    echo "check-quit [normal]: FAIL: a session client outlived the app" >&2
    status=1
else
    echo "check-quit [normal]: no client left"
fi
if zmx ls --short | grep -qx "$session"; then
    echo "check-quit [normal]: session $session is still alive"
else
    echo "check-quit [normal]: FAIL: session $session did not survive" >&2
    status=1
fi

# --- 3. Quit while the fallback alert is up ------------------------------
mkdir -p /tmp/armadale-quitcheck2
touch /tmp/armadale-quitcheck2/bin   # a file where the helper directory should be
open -n --env ARMADALE_STATE_DIR=/tmp/armadale-quitcheck2 "$APP"
pid=""
alert="no"
for _ in $(seq 1 20); do
    pid="$(pgrep -x Armadale || true)"
    if [ -n "$pid" ]; then
        alert="$(modal_alert_up "$pid")"
        [ "$alert" = "yes" ] && break
    fi
    sleep 0.5
done
if [ "$alert" != "yes" ]; then
    echo "check-quit [alert]: FAIL: the fallback alert did not appear" >&2
    exit 1
fi
echo "check-quit [alert]: fallback alert is up (modal panel window of pid $pid)"
signalled=$(( $(now_ms) / 1000 ))
elapsed=$(terminate_and_time)
echo "check-quit [alert]: Armadale exited ${elapsed} ms after SIGTERM with the alert up"
if [ "$elapsed" -gt 2000 ]; then
    echo "check-quit [alert]: FAIL: slower than 2 s" >&2
    status=1
fi
saved=$(stat -f %m /tmp/armadale-quitcheck2/state.json 2>/dev/null || echo 0)
if [ "$saved" -ge "$signalled" ]; then
    echo "check-quit [alert]: state saved on the way out (normal terminate path)"
else
    echo "check-quit [alert]: FAIL: state.json was not written after SIGTERM" >&2
    status=1
fi

exit $status
