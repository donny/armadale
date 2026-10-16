#!/bin/bash
# Checks that SIGTERM (`pkill -x Armadale`, as at logout) quits Armadale
# within 2 s, in two situations:
#
#   1. normal: the first pane is attached to a persistent session. No session
#      client may outlive the app, and the session daemon must keep running.
#   2. with an app-modal alert up: the persistent runtime cannot be set up
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

# --- 1. Normal quit -------------------------------------------------------
mkdir -p /tmp/armadale-quitcheck
open -n --env ARMADALE_STATE_DIR=/tmp/armadale-quitcheck "$APP"
session=""
for _ in $(seq 1 75); do
    session="$(zmx ls --short 2>/dev/null | head -1 || true)"
    if [ -n "$session" ] && pgrep -f "attach $session /usr/bin/true" >/dev/null; then break; fi
    session=""
    sleep 0.2
done
[ -n "$session" ] || { echo "check-quit: FAIL: no attached session appeared" >&2; exit 1; }

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

# --- 2. Quit while the fallback alert is up ------------------------------
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
