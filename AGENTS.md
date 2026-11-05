# AGENTS.md — how to work in this repository

Durable rules for any agent (or person) working on Armadale. Where
development currently stands, what is next and the open items are in
`HANDOFF.md`, which is updated whenever work pauses. The design contract is
`docs/DESIGN.md`; build and run instructions are in `README.md`. Read
`HANDOFF.md` and `docs/DESIGN.md` before changing code.

## Build and test

```sh
scripts/fetch-zmx.sh     # once; pinned zmx into Vendor/zmx (git-ignored)
xcodegen generate && xcodebuild -project Armadale.xcodeproj -scheme Armadale \
  -destination 'platform=macOS' -skipPackagePluginValidation \
  -onlyUsePackageVersionsFromResolvedFile build test
```

That command must pass with **zero warnings** (Swift 6 strict concurrency,
warnings as errors on our targets) before anything is committed. There is
no CI; GitHub Actions is disabled for this repository, so the local run is
the gate. The built app is under
`~/Library/Developer/Xcode/DerivedData/Armadale-*/Build/Products/Debug/Armadale.app`.
Per-package: `cd Packages/<name> && swift test`. The SSH integration tests
need a host; see "Test hosts" below.

The editor's SourceKit index often reports "No such module 'ArmadaleCore'"
or similar in the app target. That is the indexer, not the build; trust
`xcodebuild`.

## The process

Each step of the build order (`docs/DESIGN.md` §12) goes through the same
loop, and it has worked well:

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
step; pause immediately if asked. When work pauses, update `HANDOFF.md`.

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

Probes that need no input and are safe at any time: the Dock's items
through System Events (`tell process "Dock" to return name of every UI
element of list 1`; an item left after the app exited whose
`AXIsApplicationRunning` is true is macOS 27's "Running in Background"),
a status item (`tell process "Armadale" to menu bar 2`), an alert's text
(`value of every static text of window 1`). System Events reports
`frontmost` as false for an accessory (menu bar only) app even when it
is active, so for clicks on Armadale's own status menu in that state the
check is: screen unlocked and at least 20 s of HID idle time (`ioreg -c
IOHIDSystem`, `HIDIdleTime`). `osascript -e 'quit app "Armadale"'`
behaves like ⌘Q and returns "User canceled" when the quit alert's answer
cancels the quit; that is expected.

**Isolation for test runs.** Launch with `ARMADALE_STATE_DIR=/tmp/armadale-<name>`
(a short path: Unix socket paths are limited to 104 bytes) and
`ARMADALE_DEFAULTS_SUITE=armadale-<name>` so the owner's real state and
settings are untouched; afterwards remove the directory, `defaults delete`
the suite and delete `~/Library/Preferences/armadale-<name>.plist`. AppKit
panels still write a few keys to the real `com.tinylittleapps.armadale`
domain; that is accepted.

**Two apps with one name.** The owner's installed
`~/Applications/Armadale.app` may be running while a test build runs,
and both processes are named Armadale. Never end a test build by name
(`pkill -x Armadale`, `osascript -e 'quit app "Armadale"'`,
`pkill -x zmx-0.8.1`) when that is possible: find the test build's pid
with `ps -o pid,command -p "$(pgrep -x Armadale | tr '\n' ',')"` (its
path is under DerivedData) and signal that pid; end only its sessions
with the helper copy in the test state directory
(`ZMX_DIR=/tmp/armadale-<name>/run /tmp/armadale-<name>/bin/zmx-0.8.1
kill <session>`); and probe its windows by pid (System Events'
`process "Armadale"` picks one of the two at random; CoreGraphics'
window list filtered by owner pid is reliable, and `screencapture -x -l
<window number>` captures that window alone). `scripts/check-quit.sh`
refuses to run while any Armadale is running, which is right.

**Cleanup.** Quit the test build (⌘Q in its window, or SIGTERM to its
pid), then end its session daemons as above, or with `pkill -x
zmx-0.8.1` only when the installed app is not running. Never `pkill -f`
with the helper's name: it matches the shell running the command,
including a remote one (this killed an agent's own cleanup once).
Confirm with `pgrep -lx Armadale; pgrep -lx zmx-0.8.1; pgrep -fl 'ssh
-tt'` (`pgrep -fl 'zmx|Armadale'` matches the agent's own shell). Never
put a shell variable inside an `rm` path (`rm -rf $DIR/*` was denied
once and is banned); literal paths only, including `$TMPDIR`.

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
- **Claude Code** at `/opt/homebrew/bin/claude` and **Codex** at
  `/opt/homebrew/bin/codex`. `docs/DESIGN.md` §10 records exactly what each
  offers for completion signals and the source lines consulted; re-check
  them when either is upgraded.
- `scripts/check-quit.sh /path/to/Armadale.app` checks the SIGTERM quit
  path in three scenarios (New Session chooser up, normal, fallback alert
  up); run it when touching `AppDelegate` quit code, sheets or the chooser.
- `scripts/release.sh` (Developer ID signed, notarized, stapled DMG) and
  `scripts/install-release.sh` (the same, then installed to
  `~/Applications`) need the Developer ID certificate in the login
  keychain and the notary profile `armadale-notary`; both exist on this
  Mac. They also need `scripts/fetch-dmgbuild.sh` run once: it installs
  dmgbuild, which lays out the DMG's Finder window, into `Vendor/dmgbuild`
  (git-ignored), pinned with hashes in `scripts/dmgbuild-requirements.txt`.
  Never store or print credentials; never create keychain profiles
  on the owner's behalf. A release run deletes `build/release/`, takes
  several minutes and submits to Apple, so do not run it casually; the
  Debug gate never touches the keychain. Running the Release app for a
  check (`check-quit.sh` against it) is live UI testing.
- Never run or replace the owner's installed `~/Applications/Armadale.app`
  during tests; test builds come from DerivedData with an isolated state
  directory.
