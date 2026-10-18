# AGENTS.md — hand-off for the next session

This file is for an agent (or a person) picking Armadale up cold. It says
what exists, how it was built, the rules that were learned the hard way,
and what is left. The design contract is `docs/DESIGN.md`; build and run
instructions are in `README.md`. Read those two before changing code.

## Where things stand (October 18, 2026)

Steps 1–7 of the build order (`docs/DESIGN.md` §12) are implemented,
reviewed and committed on `main`:

| Step | Commit | What it added |
|---|---|---|
| 1 Skeleton | d0c4587 | XcodeGen project, packages, model, `PaneLayout`, `StateStore` |
| 2 One pane | 93019d8 | `PTYProcess`, `ctty-exec` helper, ephemeral backend, SwiftTerm pane |
| 3 Persistence | f6cedbb | bundled zmx, `LocalZmxBackend`, restore on relaunch, Session Ended, Respawn |
| 4 Hierarchy | 76a4e4e | sidebar, tab bar, splits, shortcut table, drag and drop, windows |
| 5 Settings | 4d3ab86 | Settings window, preferences, themes, profiles, renderer registry |
| 6 Remote | 7302a12 | `SSHTransport`, deployment, `RemoteZmxBackend`, reconnect, Hosts tab |
| 7 Agents | dac547f | attention, Dock badge, notifications, Claude Code / Codex integration |

ac7094b removed GitHub Actions: **there is no CI**. Every commit was made
after the full local build and test command passed (452 tests at dac547f).

**Step 8 (Ship) is not started.** It needs decisions from the owner before
work begins:

- the Developer ID **team identifier** (`DEVELOPMENT_TEAM` is `""` in
  `project.yml`; the bundle id is `com.tinylittleapps.armadale`);
- whether to add **crash reporting**, and which;
- the **update mechanism** (Sparkle is the obvious candidate).

Then: Developer ID signing of the app and both helpers, `scripts/notarize.sh`
with `notarytool`, a release build script, and an entry in README. Keep
the helpers signed with no entitlements (see `project.yml` comments).

## How to build and test

```sh
scripts/fetch-zmx.sh     # once; pinned zmx into Vendor/zmx (git-ignored)
xcodegen generate && xcodebuild -project Armadale.xcodeproj -scheme Armadale \
  -destination 'platform=macOS' -skipPackagePluginValidation \
  -onlyUsePackageVersionsFromResolvedFile build test
```

That command must pass with **zero warnings** (Swift 6 strict concurrency,
warnings as errors on our targets) before anything is committed. The built
app is under `~/Library/Developer/Xcode/DerivedData/Armadale-*/Build/Products/Debug/Armadale.app`.
Per-package: `cd Packages/<name> && swift test`. The SSH integration tests
need a host; see "Test hosts" below.

The editor's SourceKit index often reports "No such module 'ArmadaleCore'"
or similar in the app target. That is the indexer, not the build; trust
`xcodebuild`.

## The process that was used

Each step went through the same loop, and it worked well:

1. An **implementer** agent (Opus) builds the step from `docs/DESIGN.md`,
   writes tests, updates DESIGN.md where it deviates, does a first live
   check, and reports. It never commits.
2. A separate **reviewer** agent (Opus) reads the diff, is told to be
   adversarial, verifies the implementer's claims with evidence, and does
   its own live keystroke checks. It never commits or fixes.
3. Findings go back to the implementer as a numbered fix list with
   decisions already made (blocker / medium / low); it fixes and re-verifies.
4. The coordinating session runs the full build and test command itself,
   checks for stray processes, commits `Step N: …` on `main` with a
   `Co-Authored-By: Claude <noreply@anthropic.com>` line, pushes, and
   notifies the owner.

The owner wants to give the go-ahead before each step starts, and
sometimes runs other UI-driving agents on this Mac. Ask before starting a
step; pause immediately if asked.

## Rules learned the hard way

**Live UI testing (keystrokes, clicks, screenshots).** Other agents and the
owner share this Mac's screen. Before *every* synthetic keystroke or mouse
event run both checks and proceed only if the screen is unlocked and the
expected app is frontmost:

```sh
/usr/bin/swift -e 'import Quartz; if let d = CGSessionCopyCurrentDictionary() as? [String: Any] { print("locked:", d["CGSSessionScreenIsLocked"] ?? 0) }'
osascript -e 'tell application "System Events" to get name of first process whose frontmost is true'
```

If either fails, stop all live testing, quit the app, clean up, and report
how far you got. Never activate the app in a loop. Do not launch the app
at all unless the owner has said the Mac is free (an idle-time gate of
three minutes via `ioreg -c IOHIDSystem` HIDIdleTime was used as a backup).
Screenshot only the app's window, never the full screen, and delete
screenshots afterwards. In an earlier round an agent typed into the lock
screen; these rules exist because of that.

**Isolation for test runs.** Launch with `ARMADALE_STATE_DIR=/tmp/armadale-<name>`
(a short path: Unix socket paths are limited to 104 bytes) and
`ARMADALE_DEFAULTS_SUITE=armadale-<name>` so the owner's real state and
settings are untouched; afterwards remove the directory, `defaults delete`
the suite and delete `~/Library/Preferences/armadale-<name>.plist`. AppKit
panels still write a few keys to the real `com.tinylittleapps.armadale`
domain; that is accepted.

**Cleanup.** Quit the app (⌘Q or `pkill -x Armadale`), then
`pkill -x zmx-0.8.1` for session daemons. Never `pkill -f` with the helper's
name: it matches the shell running the command, including a remote one
(this killed an agent's own cleanup once). Confirm with
`pgrep -fl 'zmx|Armadale|ssh -tt'`. Never put a shell variable inside an
`rm` path (`rm -rf $DIR/*` was denied once and is banned); literal paths
only, including `$TMPDIR`.

**Other people's processes.** The owner runs Claude Code in other sessions
on this Mac. Never kill a `claude` or `codex` process you did not start.
Never log in, accept a trust prompt, or type prompts into an agent on the
owner's behalf; confirm it launched and quit it.

**Hosts.** Never use hosts from `~/.ssh/config` (they are GitHub
entries). The test host is the owner's Lima VM (below).

**Product rules.** The persistence runtime is an implementation detail: the
string `zmx` must never appear in user-visible text (say "persistence
helper"). Profiles only add a program and arguments; never modify a user's
agent configuration files. Design deviations are written into
`docs/DESIGN.md` in the same change.

## Test hosts and tools on this Mac

- **Lima VM `default`** (Linux aarch64, stopped when idle): `limactl start default`,
  then `ssh -F ~/.lima/default/ssh.config lima-default`. Run the SSH
  integration tests with `ARMADALE_TEST_SSH_HOST=lima-default
  ARMADALE_TEST_SSH_CONFIG=~/.lima/default/ssh.config` (README has the full
  command). Afterwards remove `~/.armadale` inside the VM (`pkill -x
  zmx-0.8.1; rm -rf ~/.armadale` over ssh), check home stays mode 750, close
  the shared connection (`ssh -O exit`), and `limactl stop default`.
- **Claude Code 2.1.292** at `/opt/homebrew/bin/claude` and **Codex 0.163.0**
  at `/opt/homebrew/bin/codex`. Section 10 of DESIGN.md records exactly
  what each offers for completion signals and the source lines consulted;
  re-check them when either is upgraded.
- **Notification permission** for the bundle id is already granted in
  System Settings (done during step 7 testing); it applies to any build
  with that id.
- `scripts/check-quit.sh /path/to/Armadale.app` checks the SIGTERM quit
  path in two scenarios; run it when touching `AppDelegate` quit code.

## Open items carried forward

Known, accepted for now, and worth a round of their own. None is a
regression; each came out of a review and was deferred as low.

Session layer
- Keystrokes typed during a flood-triggered reattach are dropped
  (`SessionController`, around the reattach path), so a ^C pressed at that
  moment is lost.
- A program that resets its cursor (`ESC[0 q`, vim on exit) returns to
  SwiftTerm's blinking block rather than the configured cursor preference.
- The flood test `aFloodIsCutShortByReattaching` is load-sensitive; it
  records a known issue under heavy CPU load rather than failing.
- One unexplained rendering glitch: a Claude Code prompt once showed a
  colour code as literal text (`185;249m`) after a replay. Not reproduced.

Hierarchy and UI
- One extra SIGWINCH reaches each pane after relaunch (harmless at a
  prompt; full-screen programs redraw once).
- A system "Ask Siri" item appears in the workspace row's context menu.
- A tab whose shell exited keeps its last terminal title.
- The font panel lists proportional fonts; Armadale refuses them only after
  selection.

Remote
- Remote orphans are never reclaimed (several Macs may share a host's
  `~/.armadale`); old helper versions on hosts are not removed.
- The flood mitigation does not apply remotely: the client's backlog is on
  the host where Armadale cannot measure it.
- Closing a pane while its host is unreachable leaves that session running
  on the host (documented; a later reclaim would need a design decision).
- fish as a remote login shell is untested and likely mis-parses the nested
  quoting; sh, bash, zsh and tcsh are tested.
- Agent forwarding (`-A`) is not supported; Windows hosts get plain shells.

Agents
- Claude Code's own idle signal arrives 60 s after it finishes; immediate
  signalling needs the user's `Stop` hook (Configure… sheet shows it).
- The `armadale-notify` helper cannot reach the pane from inside tmux or
  screen, and only exists on this Mac (hooks in remote sessions cannot use
  it; the profile arguments work everywhere).
- A session whose profile was deleted is never notified under "Only for
  agent profiles".

Shipping (step 8)
- `DEVELOPMENT_TEAM` empty; signing is "sign to run locally".
- No `scripts/notarize.sh`, no crash reporting, no updater.
