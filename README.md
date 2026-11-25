# Armadale

Armadale is a native macOS terminal for running and supervising a fleet of
persistent agent sessions (Claude Code, Codex, or plain shells). Sessions
survive app restarts, live locally or on SSH hosts, and are organised as
**Workspace → Tab Group → Tab → Pane**. The app uses AppKit for windows and
splits and SwiftUI for chrome. Terminal rendering sits behind a pluggable
`TerminalSurface` protocol, and SwiftTerm is the first renderer. Session
persistence comes from a private, bundled `zmx` daemon. Layout is stored as
versioned JSON in `~/Library/Application Support/Armadale/`.

## Status

All ten steps of the build order in [docs/DESIGN.md](docs/DESIGN.md)
section 12 are implemented and committed on `main`, and 0.1.2 is the
current release. Step 8 is menu bar mode, asking before quitting with
running sessions; step 9 is Developer ID signing and
`scripts/release.sh`, which builds a notarized, stapled DMG (see
[Releasing](#releasing)); step 10 is the New Session chooser. Since
0.1.2 Armadale updates itself ([Updates](#updates)); there is no crash
reporting in v1.
Where development stands, what is next and the open items are in
[HANDOFF.md](HANDOFF.md); what is true of the design now is in
[docs/DESIGN.md](docs/DESIGN.md), and why and when in
[docs/HISTORY.md](docs/HISTORY.md); the rules for working in the
repository are in [AGENTS.md](AGENTS.md).

What works today:

- **Hierarchy.** Each workspace is a window with a sidebar listing every
  workspace, its tab groups and tabs (with status glyphs), a tab bar for the
  selected tab group, and the selected tab's split panes. Splits (⌘D /
  ⇧⌘D), focus (⌥⌘ arrows), resize (⌃⌘ arrows or divider drag), zoom (⇧⌘↩),
  equalize (⌃⌘=), tabs (⌘T, ⌘1…⌘9, ⌃Tab), tab groups (⇧⌘N, ⇧⌘1…⇧⌘9) and
  workspaces (⌘N) work from the menus and keyboard; workspaces, tab
  groups and tabs are renamed in place (double-click the row or the tab),
  tabs and groups are reordered by dragging, and a tab dragged onto a
  sidebar tab group moves there. Closing a window keeps its workspace in
  the sidebar, with its sessions running; closing a workspace's last tab
  (or tab group) deletes the workspace, since nothing is left in it. The
  full shortcut table is in docs/DESIGN.md section 9 and under **Help ›
  Keyboard Shortcuts**.
- **Persistence.** Sessions outlive Armadale (see [Quitting and the menu
  bar](#quitting-and-the-menu-bar)); a relaunch
  restores windows, layouts and selections and reattaches every visible
  pane, replaying its screen and scrollback; sessions in tabs not on
  screen are reattached in the background at the size they had, a few at
  a time, so an agent finishing there still raises attention (a session
  saved by an older version waits until its tab is shown once). A session that ends cleanly
  (any program exiting with status 0, or the shell leaving by `exit` or
  ^D, whatever status it reports) closes its pane, as Close Pane would,
  even the only pane left in its workspace, which then goes with its
  window (the app keeps running); a program that fails,
  anything killed by a signal, or an end nobody saw shows *Session Ended*
  over its last screen, with the status or signal when it is known, and
  Respawn / Close Pane. **Workspace › Respawn All Ended** (⌥⌘R) respawns every ended
  pane of a workspace.
- **New sessions are chosen per pane.** A new tab, tab group, window or
  split never starts a shell by itself: its pane shows the **New Session
  chooser**, a card listing your **favorites** (profile icon, name, host
  and directory) with **Cancel** and **New Session…**. A click on a
  favorite starts it in that pane; ↑/↓ select one and Return starts it
  (with none selected, Return opens the dialog); Escape or Cancel closes
  the pane, cascading like a clean exit (so ⌘N then Cancel closes the new
  window). Favorites are managed right there: drag one onto another to
  reorder them, and a right-click offers Edit…, Move Up, Move Down and
  Remove; a favorite whose host or profile was removed is dimmed with the
  reason until it is edited or removed. **New Session…** opens the **New
  Session** dialog: Local or SSH (a saved host, or **New Host…**, which
  takes a destination, offers the host aliases of your `~/.ssh/config`
  while you type, and saves the host when you start or save), a directory
  (prefilled from the window's focused session), a profile, the agent
  options for Claude Code (skip permission checks, continue, model) and
  Codex (skip approvals and sandbox, sandbox mode, model), additional
  arguments, and Add to Favorites. Start starts it; its Cancel returns to
  the chooser. A running pane's menu (the "…" in its header) has **Save
  as Favorite…**, which saves that session's location, profile, options
  and current directory under a name. A pane still choosing is saved
  as such and shows the chooser again after a relaunch; it needs no
  attention and never holds up a quit. File › New Tab with Profile, File ›
  New Tab on Host, the "+" button's menu and General's default profile and
  directory are gone.
- **Settings** (⌘,): General (close confirmation, quitting with running
  sessions, notifications), Appearance (font, size, light and dark themes,
  Ghostty theme import, cursor, renderer), Profiles and Hosts.
  **Help › Keyboard Shortcuts** shows the read-only shortcut table,
  generated from the menus.
- **Remote hosts.** **Settings › Hosts** adds SSH hosts (destination, port,
  identity file, SSH config file, remote folder) with Test Connection and
  Deploy Now; a session is started on a host from the New Session
  dialog's SSH choice, where New Host… adds a host by its destination
  alone. A session
  on a host keeps running there: Armadale installs its private persistence helper under
  `~/.armadale` there on first use, quitting leaves the session running, a
  relaunch reattaches it, and a lost connection shows *Reconnecting…* and
  retries by itself for up to five minutes. See docs/DESIGN.md section 6.
- **Agents and attention.** A pane whose program rings the bell or sends a
  notification sequence (OSC 9 / OSC 777) while you aren't looking at it
  shows ◐ on its tab, is counted in the sidebar and on the Dock icon, and
  can post a macOS notification that brings the pane forward when clicked.
  **Window › Next Pane Needing Attention** (⌃⌘A) cycles through them. The
  Claude Code and Codex profiles are set up so both agents signal their
  pane; see [Notifications and agents](#notifications-and-agents).
- **Recording a pane.** A running pane's menu has **Record Pane…**: pick
  where to save, and from then on everything the pane shows (its output
  only, never what you type) goes into an asciicast `.cast` file, the
  format `asciinema play` reads, starting from what is on screen. While it
  records, the pane's header and its tab's row in the sidebar show a red
  dot pulsing in step (with the sidebar hidden, the tab in the tab bar shows
  a steady one); **Stop Recording** is in the same menu. The recording
  also ends with the session, when the pane closes, and when Armadale quits;
  the file holds whole lines only, and a quit waits up to a second for it to
  be written (a disk that stalls longer keeps what was written by then). See
  docs/DESIGN.md sections 7 and 8.

The design is in [docs/DESIGN.md](docs/DESIGN.md).

## Requirements

- macOS 27, Xcode 27 (Swift 6.4)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- For releases only: `/usr/bin/python3` (it comes with Xcode), into which
  `scripts/fetch-dmgbuild.sh` installs the pinned dmgbuild (see
  [Releasing](#releasing))

## Generate, build, test

```sh
scripts/fetch-zmx.sh  # downloads the pinned zmx into Vendor/zmx (git-ignored)
xcodegen generate     # creates Armadale.xcodeproj (git-ignored)
# (before a release, once: scripts/fetch-dmgbuild.sh; see Releasing)

# Build the app
xcodebuild -project Armadale.xcodeproj -scheme Armadale \
  -destination 'platform=macOS' -skipPackagePluginValidation \
  -onlyUsePackageVersionsFromResolvedFile build

# Run every package's tests through the app scheme
xcodebuild -project Armadale.xcodeproj -scheme Armadale \
  -destination 'platform=macOS' -skipPackagePluginValidation test

# Or test a single package
(cd Packages/ArmadaleCore && swift test)
```

`ArmadaleAppTests` tests the app target's own code (split tree view with
real SwiftTerm surfaces, close-confirmation rule, window controller
lifetime, preferences, themes, the shortcut table, settings applied to
open panes, the renderer switch, the Settings window, attention and
notifications with a fake notification service, and the `armadale-notify`
helper on a pseudo-terminal). It is unhosted: the app's sources are compiled into the bundle,
so the app never launches, no window appears and no process is started.

`ArmadaleSessions` tests spawn real processes on PTYs (zsh and bare
binaries) through the `ctty-exec` helper, so they need no mocks for the I/O
path. Its zmx integration tests run the real, pinned zmx from
`Vendor/zmx/macos-<arch>/zmx`: each test uses a private runtime directory
`/tmp/armadale-test-<pid>-<random>` (short enough for socket paths), kills
the sessions it creates and removes the directory, and the suite's teardown
kills anything left behind. If the binary is missing, the tests run
`scripts/fetch-zmx.sh` once and otherwise fail with a message saying to run
it. The whole package takes about 15 s.

Dependency versions are locked in
`Armadale.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
It is the only tracked file inside the generated project, and
`xcodegen generate` leaves it alone. The build command above passes
`-onlyUsePackageVersionsFromResolvedFile`, so builds use exactly those
versions. To change a pin, edit `Packages/SwiftTermSurface/Package.swift`,
run `swift package resolve` in that directory, and copy the resulting
`Package.resolved` over the locked one.

SwiftTerm includes a build-tool plugin. On the command line you need
`-skipPackagePluginValidation`. In Xcode, choose **Trust & Enable** the first
time you build.

### zmx

Session persistence comes from [zmx](https://zmx.sh) (MIT), pinned in
`scripts/zmx.lock` (version plus the SHA-256 of each release tarball).
`scripts/fetch-zmx.sh` downloads the macOS (arm64, x86_64) and Linux
(aarch64, x86_64) builds into `Vendor/zmx/<os>-<arch>/zmx`, verifying each
tarball against the lock file; it skips what is already verified, and
`--check` only verifies. The app target's *Embed zmx* build phase
(`scripts/embed-zmx.sh`) verifies `Vendor/zmx` against the lock file (and
fetches it if it is missing or does not verify, failing the build if that
does not work),
`lipo`s a universal `Contents/Helpers/zmx` signed like `ctty-exec` (the
app's identity, no entitlements), and copies the Linux builds to
`Contents/Resources/remote/`. `ZmxVersion.current` in `ArmadaleSessions` must
equal the lock file's version; a test checks it. To update zmx, change the
lock file (version and all four hashes), `ZmxVersion.swift`, and run the
fetch script.

At launch Armadale copies both helpers to `<state dir>/bin/zmx-<version>`
and `ctty-exec-<app version>` and runs those copies. Sessions live in
`<state dir>/run` (or `/tmp/armadale-<uid>` when that path is too long for
a Unix socket). To look at them by hand, use the installed copy with the
same directory, and pipe its output (zmx overwrites the start of a regular
file it writes to):

```sh
ZMX_DIR=~/Library/Application\ Support/Armadale/run \
  ~/Library/Application\ Support/Armadale/bin/zmx-0.8.1 ls | cat
```

`scripts/check-quit.sh /path/to/Armadale.app` checks quitting as logout
does it, in three cases: it sends SIGTERM (`pkill -x Armadale`) and checks
that the app is gone within 2 s. With the New Session chooser up (a fresh
launch, whose pane shows the chooser and no sheet), the quit must not be
held up, and the state must be saved with the pane still empty. Normally (that pane given a session the
helper creates beforehand, which the app attaches to), no session client
may be left and the session daemon must still be alive. With the fallback
alert up (it makes `<state dir>/bin` a regular file so the session runtime
cannot be set up, in a second scratch state directory), the quit must not
wait for the alert and must still save the state. It refuses to run while
any Armadale is running.

`aFloodIsCutShortByReattaching` floods a session until the client has
passed the 16 MB limit and been reattached (up to 15 s), then expects the
prompt within 5 s of ^C. On a heavily loaded machine either step can be out
of reach (the flood never fills the client, or the test renderer drains the
bounded backlog at a few hundred KB/s); those cases are recorded as known
issues with the measured numbers, not failures, but the reattach must still
happen and the prompt must still arrive within 60 s.

The integration test `floodBaselineWithoutReattach` measures a zmx flood
without the reattach mitigation (docs/DESIGN.md section 7); it only runs
when `ARMADALE_FLOOD_BASELINE` is set (to the number of seconds to wait for
the prompt, 300 by default) and can take minutes.

### Remote hosts and the SSH integration tests

Remote sessions use the system's `/usr/bin/ssh` with your own
configuration, keys and agent. Connections to a host are shared
(`ControlMaster`); their sockets are in `<state dir>/run/ssh/` (or
`/tmp/armadale-<uid>/ssh/`), named by a short hash of the host's settings.
To close one by hand: `ssh -O exit -o ControlPath=<that socket> <host>`.
On the host, everything is in the remote folder (default `~/.armadale`):
`bin/zmx-<version>` and `run/` (its sessions). Removing that folder is a
complete uninstall from the host.

The package tests exercise the remote backend without a network: a
scripted transport for command lines and parsing, and a loopback transport
that runs "remote" commands on this Mac with a private `HOME` against the
real zmx (deploy, create, reattach, reconnect after a lost connection,
fallback, interactive sign-in). The tests in `SSHIntegrationTests` run
against a real host only when `ARMADALE_TEST_SSH_HOST` names an ssh
destination (they are skipped otherwise); `ARMADALE_TEST_SSH_CONFIG`
optionally names an ssh config file for it (`ssh -F`). They deploy the
helper to `~/.armadale` on the host (and leave it there), create, detach,
reattach and kill a session, check that the shared connection is reused
(`ssh -O check`), kill an upload's ssh mid-transfer and check that nothing
was installed, check that a truncated helper on the host is replaced, and
check that a session's shell exit status is recorded on the host. For example, against a Lima VM:

```sh
limactl start default
limactl show-ssh --format=config default > /tmp/lima-ssh.conf
cd Packages/ArmadaleSessions
ARMADALE_TEST_SSH_HOST=lima-default ARMADALE_TEST_SSH_CONFIG=/tmp/lima-ssh.conf \
  swift test --filter SSHIntegrationTests
```

Through `xcodebuild test`, prefix the variables with `TEST_RUNNER_`
(`TEST_RUNNER_ARMADALE_TEST_SSH_HOST=…`); xcodebuild passes those on to
the test process without the prefix.

### Environment overrides

| Variable | Effect |
|---|---|
| `ARMADALE_STATE_DIR=/dir` | State directory: `state.json` with its backups `state.json.bak` (before the latest save) and `state.json.launch.bak` (as the latest clean launch read it; to start fresh, remove all three; one that cannot be read at all, or was written by a newer Armadale, stops the launch wherever it is in that order), `armadale.lock`, `last-quit.json` (what the last quit left running; see "Quitting and the menu bar"), `bin/` (helper copies) and `run/` (sessions). Use a short path (such as `/tmp/armadale-dev`) so socket paths stay under the limit. Only one Armadale process can use a state directory at a time (see below). |
| `ARMADALE_BACKEND=ephemeral` | Plain PTY sessions that end when the app quits (tests, debugging). |
| `ARMADALE_ZMX=/path/to/zmx` | zmx binary to bundle-install and test with, instead of the app's `Contents/Helpers/zmx` or `Vendor/zmx`. |
| `ARMADALE_CTTY_EXEC=/path/to/ctty-exec` | `ctty-exec` to use (see below). |
| `ARMADALE_DEFAULTS_SUITE=name` | Keep settings in the UserDefaults suite `name` instead of the app's domain (same as the `-ArmadaleDefaultsSuite name` argument). |
| `ARMADALE_UPDATER_FOR_TEST=1` | Start the updater in a Debug build and in a run with `ARMADALE_STATE_DIR` or a defaults suite set (it starts in neither otherwise), for the live test of a real update. It never lifts a missing `SUPublicEDKey` or `SUFeedURL`, or a launch that cannot go on. Sparkle's own settings stay in the app's standard defaults domain, so a test copy needs a bundle identifier of its own. |

Each running Armadale holds a lock (`flock`) on `armadale.lock` in its
state directory; the file holds its pid. A second process started on the
same directory shows "Armadale is already running" and quits without
reading or writing anything there, printing the holder's pid and the lock
file on standard error; give it its own `ARMADALE_STATE_DIR` to run both. A
leftover lock file from a process that is gone blocks nothing. If no lock
can be taken at all (a volume without `flock`), that is logged and the app
runs without one. Builds from before the lock (0.1.1 included) take none,
so they are not detected.

An `ARMADALE_ZMX` or `ARMADALE_CTTY_EXEC` that does not name an executable
file is an error (logged and thrown), never a reason to fall back to the
bundled copy. None of the variables reach the sessions themselves:
`ARMADALE_*` is removed from every session's environment.

### The `ctty-exec` helper

Sessions are spawned through a tiny trampoline, `ctty-exec`, which makes the
PTY the child's controlling terminal and then execs the real program. Without
it, `^C` and window resizes never reach the program; see docs/DESIGN.md
section 7. Its source is `Packages/ArmadaleSessions/Sources/ctty-exec/main.swift`,
and it is built in two places:

- `project.yml` has a `ctty-exec` command-line tool target. The app depends
  on it, and a Copy Files phase puts it in `Armadale.app/Contents/Helpers/`,
  re-signed with the app's identity.
- `Packages/ArmadaleSessions` declares it as an executable target, so
  `swift build` / `swift test` build it next to the test bundle.

`HelperLocator` looks for it in `$ARMADALE_CTTY_EXEC`, then in the app's
`Contents/Helpers/`, then next to the running test bundle (and for zmx in
`$ARMADALE_ZMX`, `Contents/Helpers/`, then `Vendor/zmx`). The app runs the
installed copy in `<state dir>/bin/`. zmx clients run on the pane's PTY
through `ctty-exec`, and `ctty-exec` also starts the session program inside
the zmx daemon: it sets its argv[0] (`-zsh` for a login shell), which zmx's
own command line cannot express, and removes zmx's variables from its
environment (`ctty-exec --unset VAR … <path> <argv0> [args…]`), so `zmx`
run inside a pane never sees Armadale's private sessions. There it also
records how the program ended (`--exit-file <run dir>/a-<id>.exit`:
`N` for a normal exit, `signal N` for a death by signal): instead of
exec'ing the program it starts it as its child, ignores ^C, ^\ and ^Z
itself (the program gets them as usual), passes SIGHUP and SIGTERM on (and
then writes nothing: the session is being ended from outside), and writes
the record when the program ends by itself (DESIGN §4 and §7).

When you check PTY behaviour by hand, use zsh or a bare program, never
`/bin/sh`. macOS's `/bin/sh` is bash, which acquires the controlling
terminal itself and so hides a broken spawn.

## Notifications and agents

Notifications (Settings › General): "Notify when an unfocused pane needs
attention" (on), "Only for agent profiles" (on: only Claude Code, Codex and
other agent-kind profiles), "Play sound" (off). macOS asks for permission
the first time a pane needs attention (or a notification is posted), never
at launch. The Dock badge also depends on that permission: on macOS 27 it
shows only while System Settings › Notifications › Armadale › "Badge
application icon" is on. If the permission prompt is dismissed (or
Armadale quits while it is on screen), turn notifications on there. A
banner is skipped if you are already looking at that pane, and a pane's
notification is removed from Notification Center once you look at it.

Making agents signal their pane (details, sources and line numbers in
docs/DESIGN.md section 10):

- **Claude Code**: by itself it sends nothing in terminals it doesn't
  recognise. A Claude Code profile with **"Signal attention when Claude
  Code needs input"** on (Settings › Profiles; on by default, also for the
  built-in) runs `claude --settings '{"preferredNotifChannel":"ghostty"}'`,
  so Claude Code sends OSC 777 when it has waited a minute for input or
  asks for permission. **This overrides your own `preferredNotifChannel`,
  including `notifications_disabled`, for every session started from that
  profile**; your settings files are not changed. To keep your own channel,
  turn the toggle off for that profile (new sessions and respawns then
  start without the argument). For a signal the moment Claude stops, add a
  `Stop` hook to `~/.claude/settings.json` (Settings › Profiles › Claude
  Code › Configure… shows it with the right path and a Copy button):

  ```json
  { "hooks": { "Stop": [ { "hooks": [ { "type": "command",
    "command": "'/Applications/Armadale.app/Contents/Resources/armadale-notify' 'Claude Code' 'Finished'" } ] } ] } }
  ```

- **Codex** needs nothing: in a terminal it doesn't recognise its defaults
  ring the bell when a turn completes or it asks for approval, and only
  while its terminal reports itself unfocused. Armadale reports focus
  (focus reporting, DECSET 1004), so Codex rings exactly when you aren't
  looking at its pane. (Passing `-c tui.…` overrides on the command line
  makes Codex run without its shared background server, so the profile
  doesn't.) Optional, in `~/.codex/config.toml`: the message text instead
  of a plain bell, and the helper after every turn (`notify` goes at the
  top, before any `[table]`, and replaces any `notify` you already have):

  ```toml
  notify = ["/Applications/Armadale.app/Contents/Resources/armadale-notify", "Codex", "Turn complete"]

  [tui]
  notification_method = "osc9"
  ```

- **Anything else**: ring the bell (`printf '\a'`), or run
  `armadale-notify [--bell] [TITLE [BODY]]` from inside a pane, e.g.
  `make; …/armadale-notify Build Done` posts a notification titled "Build"
  saying "Done". The helper writes to the pane's terminal even when its
  output is piped or it has no controlling terminal (as in Claude Code
  hooks), and does nothing outside Armadale. It cannot reach the pane from
  inside tmux or screen, which swallow the sequence.

## Quitting and the menu bar

Quitting (⌘Q) while sessions are running asks first: **Keep Running in
Menu Bar** (the default button), **End Sessions and Quit**, or Cancel.
Keeping them hides Armadale's windows and Dock icon and leaves a status
item in the menu bar (the three-pane glyph, with the number of panes
needing attention next to it); its menu shows how many sessions are
running and has **Open Armadale**, **Settings…**, **Quit, Keep Sessions
Running** (not offered when persistent sessions are unavailable in this
run, since a quit would end them) and **End Sessions and Quit**. Clicking a notification,
`open -a Armadale` or opening the app from Finder brings the windows back
too. If the status item is not visible (macOS can hide it: the per-app
menu bar setting in System Settings, or a crowded menu bar on a display
with a notch), opening Armadale from the Dock, Finder, Spotlight or with
`open -a Armadale` brings the windows back. Settings › General › "When
quitting with running sessions" (Ask, Keep running in the menu bar, End
sessions) skips the question. Logout,
restart, shutdown and SIGTERM never ask: they quit at once, as before,
without ending the sessions.

Why: since macOS 27, a quit that leaves processes started by the app
running makes the Dock show the app as "Running in Background" (with a
one-time prompt to allow it), and the Dock's "Stop Running in Background"
ends every session at once. A quit from menu bar mode leaves no Dock item.
Sessions survive a quit only while Armadale is allowed to run in the
background: if you answered Don't Allow to that prompt, or switched
Armadale off under System Settings › General › Login Items & Extensions
› Background App Activity, macOS ends every local session a few seconds
after Armadale quits, from the menu bar too. Keep it allowed, or keep
Armadale running. Armadale cannot read that setting, so it watches for
the result instead: each quit records which local sessions it left
running, and when the next launch finds that macOS ended them a few
seconds after the quit, Armadale says so, with a button that opens
System Settings at Login Items & Extensions. From then on, any quit
while Armadale is in the menu bar that would leave local sessions
running (such as Quit, Keep Sessions Running) asks first (**Open System
Settings**, **Quit Anyway** or Cancel), until a later quit's sessions
are found still running.
A loss is reported at the next launch, not prevented. What it cannot
catch: a crash or force quit of Armadale (nothing is recorded), and a
restart or logout before the next launch. Details in docs/DESIGN.md
section 8, "Quitting with running sessions" and "Background App
Activity".

## Settings and themes

Settings live in the app's user defaults (`com.tinylittleapps.armadale`,
i.e. `~/Library/Preferences/com.tinylittleapps.armadale.plist`), through the
typed `Preferences` store: the three
notification settings (`notifyOnAttention`, `notifyOnlyForAgents`,
`notificationPlaysSound`), `confirmClosingRunningSession` (default `true`: closing a pane, tab or tab
group with a running process asks first), `quitWithRunningSessions` (`ask`, `keepInMenuBar` or
`endSessions`; default `ask`), font name and size (⌘= / ⌘- / ⌘0
change the stored size), theme choice, cursor, renderer, and the Settings
window's position and tab. (The `defaultProfileID` and
`defaultWorkingDirectory` keys of older builds are left unread.) Profiles
are not preferences: they are saved with the layout in `state.json`, as
are favorites.

Imported themes are JSON files in `<state dir>/themes/<name>.json`
(`~/Library/Application Support/Armadale/themes/` by default). Import reads
a Ghostty theme file (`palette = N=#rrggbb`, `background`, `foreground`,
`cursor-color`, `selection-background`, `selection-foreground`); importing
a file with the same name replaces the earlier one. To remove an imported
theme, delete its JSON file (it falls back to the default theme).

To keep test or debugging runs away from your real settings, point the app
at another defaults suite and state directory. Run in Xcode does this
already: the scheme's Run action sets `ARMADALE_STATE_DIR=/tmp/armadale-dev`
and `ARMADALE_DEFAULTS_SUITE=armadale-dev` (the test action does not get
them; Profile, which reuses Run's environment, does, so Instruments runs
against them too). From the command line:

```sh
ARMADALE_DEFAULTS_SUITE=armadale-dev ARMADALE_STATE_DIR=/tmp/armadale-dev \
  ~/Library/Developer/Xcode/DerivedData/Armadale-*/Build/Products/Debug/Armadale.app/Contents/MacOS/Armadale
# or: … Armadale -ArmadaleDefaultsSuite armadale-dev
defaults delete armadale-dev   # afterwards
```

AppKit itself (open panels, the font panel) still writes a few window and
panel keys to the standard domain of the app's bundle identifier; a fully
isolated run needs a copy of the app with another bundle identifier.
`ArmadaleAppTests` never use the app's domain: each test that writes makes
its own suite, named by an absolute path inside a fresh temporary folder
(CFPreferences then keeps the plist there, not in `~/Library/Preferences`),
and removes the folder at the end.

## Updates

Armadale › Check for Updates… asks https://armadale.dev/appcast.xml for
newer versions (Sparkle; docs/DESIGN.md section 8, "Updates"). At the
second launch Armadale asks once whether to check automatically (then
once a day); Settings › General › Updates changes that. Besides what
every web request carries, a check sends only the version of Armadale
and of its updater, in the request's user agent. Nothing is
downloaded or installed until you choose to install. Installing quits
Armadale and keeps your sessions, as Quit, Keep Sessions Running does,
then relaunches the new version, which reattaches them; Armadale asks
first only when some sessions would end (the plain PTY fallback, a host
without the persistence helper) or after macOS was seen ending sessions
at a quit (Background App Activity, above). Cancel there, and the update
stays ready and is normally installed the next time Armadale quits,
without reopening it (not after a logout or restart, which ends the
waiting installer, nor after Skip This Version at a later check). In
menu bar mode a scheduled check that finds an update opens no window;
the menu bar item's menu shows Update Available…. The updater never runs
in a Debug build, in a run with `ARMADALE_STATE_DIR` or a defaults suite
(Run in Xcode, test builds), nor in a build without an `SUPublicEDKey`
(the update key's public half, "Releasing");
`ARMADALE_UPDATER_FOR_TEST=1` lifts the first two for a live test.
Sparkle
keeps its settings (`SUEnableAutomaticChecks`, `SULastCheckTime`, …) in
the app's standard defaults domain.

## Releasing

A release is a Developer ID signed, notarized and stapled DMG built by
`scripts/release.sh` (docs/DESIGN.md section 11, "Release pipeline").
Debug builds, including the build and test command above, are signed ad
hoc ("Sign to Run Locally") and never need the keychain; only the Release
configuration, which `xcodebuild archive` uses, signs with Developer ID.

Prerequisites, once per Mac:

- The team's **Developer ID Application** certificate (team `YJ8LXVCB3T`)
  with its private key in the login keychain. `security find-identity -v
  -p codesigning` must list `Developer ID Application: … (YJ8LXVCB3T)`.
  The first signing may ask to let `codesign` use the key; choose Always
  Allow. If several valid ones are listed (for example a renewed
  certificate next to the old one), the script stops and asks you to
  choose one with `ARMADALE_SIGNING_IDENTITY=<its SHA-1>`; the app must
  then be signed with that same certificate (remove the old one from the
  keychain if Xcode picks it).
- A notary keychain profile named `armadale-notary`, created
  interactively with an app-specific password (account.apple.com › Sign-In
  and Security › App-Specific Passwords):

  ```sh
  xcrun notarytool store-credentials armadale-notary \
    --apple-id <apple id> --team-id YJ8LXVCB3T
  ```

  No credentials live in the repository.
- The pinned [dmgbuild](https://github.com/dmgbuild/dmgbuild), which lays
  out the DMG's Finder window: run `scripts/fetch-dmgbuild.sh` once. It
  makes `Vendor/dmgbuild/` (git-ignored) a virtual environment of
  `/usr/bin/python3` and installs dmgbuild and its two dependencies from
  `scripts/dmgbuild-requirements.txt`, whose versions and wheel hashes
  are pinned (`pip install --require-hashes`); nothing is installed
  outside `Vendor/dmgbuild`. Running it again does nothing while the
  environment was installed from the current requirements file (it keeps
  that file's SHA-256) with the pinned versions, and `--check` only
  verifies. `release.sh`
  checks it before building and says to run the script if it is missing.
- **The update signing key** (docs/DESIGN.md section 8, "Updates"): one
  EdDSA key under the login keychain's account `armadale`, made by the
  owner on November 17, 2026 and kept by the owner. Its public half is
  `SUPublicEDKey` in `project.yml`; without that line the updater never
  starts and `release.sh` refuses to build. `scripts/sparkle-tool.sh`
  runs Sparkle's tools from the pinned package (build once first, so
  the package is fetched). The key was made with

  ```sh
  scripts/sparkle-tool.sh generate_keys --account armadale
  ```

  which stores the private key in the login keychain and prints the
  public key. Do not run that on a Mac that lacks the key: it would
  make a different one, and installed copies accept only updates signed
  with the first. A Mac that releases gets the key by import. For the
  backup and the other Mac, export it:

  ```sh
  scripts/sparkle-tool.sh generate_keys --account armadale -x ~/armadale-update-key.txt
  ```

  move that file by AirDrop or as an attachment in a password manager
  (which is then also the backup), import it on the other Mac, and delete
  the file on both:

  ```sh
  scripts/sparkle-tool.sh generate_keys --account armadale -f ~/armadale-update-key.txt
  rm ~/armadale-update-key.txt
  ```

  Never by mail, chat, a cloud folder or the repository. `generate_keys`
  run with no key under that account creates a new one, so run it only
  for these two purposes.

To release:

1. Bump `MARKETING_VERSION` (the version users see, e.g. `0.2.0`) and
   `CURRENT_PROJECT_VERSION` (the build number, which must increase with
   every release) in the app target's settings in `project.yml`, and
   commit. `scripts/bump-build.sh` does it: with no options it raises the
   build number by one; `--set N` picks a number (it must be higher),
   `--version X.Y.Z` also sets the marketing version, and `--commit`
   commits the change as "Bump to X.Y.Z (N)" from a clean tree. The
   build number is an integer compared numerically by Launch Services
   and by updaters, so a git commit hash cannot stand in for it; the
   commit a build came from is the one the release's suggested tag
   points at.
   Run `scripts/check-state-compat.sh` too: every released version must
   refuse the new `state.json` as newer, or read it and lose nothing at
   its next save; never treat it as damaged (docs/DESIGN.md section 3 has
   the rule).
2. From a clean working tree, run `scripts/release.sh`. It refuses a tree
   with uncommitted or untracked changes unless given `--allow-dirty`,
   and a version whose tag `v<version>` already exists unless given
   `--allow-existing-tag`. **Every run first deletes `build/release/`,
   including a DMG from an earlier run, so move a finished DMG out of it
   before running the script again.** It archives the Release
   configuration into `build/release/` (git-ignored, with its own
   DerivedData, so a release starts from scratch and takes several
   minutes), checks the
   signatures of the app and both helpers (Developer ID of `YJ8LXVCB3T`,
   hardened runtime, secure timestamp, no entitlements on the helpers, only
   the sandbox-off entitlement on the app, a universal persistence
   helper), notarizes and staples the app, builds the DMG with dmgbuild
   (volume "Armadale" with the app and an Applications link, laid out in a
   600 × 400 Finder window with a background showing an arrow and "Drag
   Armadale to Applications", and the app icon as the volume icon),
   checks inside it that the app is an exact, validly signed copy, signs,
   notarizes and staples it, and checks both with Gatekeeper (`spctl`) and
   `stapler validate`. Notarization usually takes a few minutes per submission; a
   rejected submission fails the script and prints the notary log.
   For the updater, before anything is built it checks that `project.yml`
   has the feed URL, `SUAllowsAutomaticUpdates: false`, an
   `SUPublicEDKey` and none of `SUSendProfileInfo`,
   `SUEnableSystemProfiling` and `SUEnableJavaScript`, and that the key in the
   keychain (account `armadale`) signs a scratch file so that the
   signature verifies against that public key (the keychain may ask to
   let `sign_update` use it; when it cannot sign, `sign_update`'s own
   message is shown); it checks Sparkle's code in the app like the
   helpers (Developer ID, runtime, timestamp, no entitlements, no XPC
   services) and the built Info.plist's updater keys (the feed, the
   public key, `SUAllowsAutomaticUpdates` false,
   `SUVerifyUpdateBeforeExtraction` true, none of the three above); and at the end it signs the stapled DMG with
   `sign_update --account armadale`, verifies that signature against the
   public key in the built app, and writes
   `build/release/appcast-item.xml`. It reminds you when the state
   file's schema version is higher than at the last release tag: the
   release notes must then say that older versions refuse a layout this
   one saves. It stops if it cannot read the current schema version
   from the source, and warns if it cannot read the tag's.
3. The result is `build/release/Armadale-<version>.dmg`. Until every
   check has passed the DMG is called `Armadale-<version>-pending.dmg`, so
   a file with that name is not a release. The script prints the suggested
   `git tag` command; tagging and publishing are up to you.

4. Publish it as a GitHub Release so the website can link to it. The
   site's Download button points at the latest release's asset named
   exactly `Armadale.dmg`, a URL GitHub keeps stable across releases, so
   upload the DMG twice: under its versioned name for people browsing the
   releases page, and as `Armadale.dmg` for the button.

   ```sh
   git tag v<version> && git push origin v<version>
   cp build/release/Armadale-<version>.dmg build/release/Armadale.dmg
   gh release create v<version> --title "Armadale <version>" --notes "…" \
     build/release/Armadale-<version>.dmg build/release/Armadale.dmg
   ```

   The DMG must be the notarized one: Gatekeeper refuses a `--skip-notarize`
   build downloaded from the web. Write the notes from the "Next
   release" section of `docs/changelog.html`, and once the release
   exists turn that section into the version's (AGENTS.md, "The
   changelog page"). Then add the release to the update feed:

   ```sh
   scripts/appcast.sh
   ```

   It downloads the release asset `Armadale-<version>.dmg`, checks that
   it has the length and EdDSA signature recorded in
   `build/release/appcast-item.xml` (against `SUPublicEDKey` in
   `project.yml`), makes the item's release notes from the version's
   section of the changelog page, and puts the item at the top of
   `docs/appcast.xml`. It commits nothing. Commit the feed with the
   changelog change and push: **that push publishes the update** to
   every copy of Armadale that checks, and the site's changelog then
   names the version the Download button gives. Never edit an item of `docs/appcast.xml`
   by hand: its signature and length belong to the DMG on GitHub, and
   `AppcastTests` (in the gate) holds the file's form.
5. Once the tag exists, add its state fixture, written by the tagged
   version's own code, as `scripts/state-fixtures/README.md` describes.

To run the release build on this Mac, `scripts/install-release.sh` runs
`scripts/release.sh` (passing on any options, such as `--skip-notarize`),
mounts the DMG and installs the app from it into `~/Applications`,
replacing the copy there. It refuses while Armadale is running (quit it
first; persistent sessions keep running). `--from-dmg` installs the DMG
already in `build/release/` without building again. On a Mac that does
not hold the update signing key, `scripts/install-release.sh
--skip-update-signature` does the same without it: the app is signed,
notarized and stapled as in a release, and only the DMG's signature for
the updater and the feed's item are left out
(`build/release/Armadale-<version>-local.dmg`, for that Mac, never for
publishing).

### The website

[armadale.dev](https://armadale.dev) is two static pages in `docs/`
(`index.html` and `changelog.html`, with the icon, `CNAME` and
`.nojekyll`), served by GitHub Pages
from the `docs` folder of `main`: Settings › Pages › "Deploy from a
branch", `main`, `/docs`, custom domain `armadale.dev`, Enforce HTTPS
(a `.dev` domain is HTTPS-only). GitHub Pages is free for a public
repository only. DNS at the registrar: `A` records for the apex to
GitHub Pages (185.199.108.153, 185.199.109.153, 185.199.110.153,
185.199.111.153), `CNAME www` to `donny.github.io`, and the
`_github-pages-challenge-donny` TXT record from GitHub's domain
verification. `docs/DESIGN.md` and `docs/HISTORY.md` are served too,
as raw files; that is fine, the repository is public. A change to a page is a normal commit
on `main`; Pages redeploys within a minute or two.

`changelog.html` ([armadale.dev/changelog.html](https://armadale.dev/changelog.html),
linked under the Download button) says what changed for the people
who use the app, newest first: a section per release, with "Next
release" on top for what is on `main` and not yet in a release, and in
each section one entry per day. It is written by hand, in the commit
that makes a change a user would notice; what goes on it, how short
it stays and what happens to it at a release are in AGENTS.md, "The
changelog page". Both pages are self-contained (inline styles, no
scripts); to look at them as served, run
`python3 -m http.server --directory docs` and open
`http://localhost:8000/`.

`scripts/release.sh --skip-notarize` (no credentials needed) stops after
the signature checks and builds `build/release/Armadale-<version>-unnotarized.dmg`,
signed but not notarized: Gatekeeper rejects it ("source=Unnotarized
Developer ID"), so it is for checking the pipeline only. To check that a
Release build starts sessions, run `scripts/check-quit.sh
build/release/Armadale.xcarchive/Products/Applications/Armadale.app`.

A Developer ID build has a different code identity from a development
build. Notification permission is kept per bundle identifier and carries
over; privacy grants, which macOS ties to the code identity, and macOS
27's Background App Activity decision may be asked for again.

## Layout

| Path | Contents |
|---|---|
| `project.yml` | XcodeGen spec (app target, scheme, signing) |
| `docs/` | `DESIGN.md` (the design contract: what is true now), `HISTORY.md` (why and when: the change log and each design section's history), `index.html`, `changelog.html`, `appcast.xml` (the update feed, served at armadale.dev/appcast.xml), `CNAME` (the website; the changelog page is kept as AGENTS.md says), `icon/AppIcon.svg` (master vector of the app icon, generated) |
| `Armadale/` | AppKit app: lifecycle, menus (the source of the shortcut table), windows, SwiftUI sidebar and tab bar, split tree and panes, `SessionRegistry` (a backend per host), `AttentionCenter`, Settings (`Settings/`: window, `Preferences`, tabs), `ThemeCatalog`, `AppSettings` and `UserNotificationService` (`Support/`), `Resources/armadale-notify`, `Resources/Acknowledgements.txt` (the third-party notices shown by Help › Acknowledgements) |
| `Packages/ArmadaleCore` | Model, `PaneLayout` operations, `SplitTreeReconciler`, `AppModel`, `AttentionTracker`, `AgentIntegration`, `StateStore`, migrations (no AppKit) |
| `Packages/ArmadaleSessions` | `PTYProcess`, `CommandRunner`, `ZmxSessionDriver` with `LocalZmxBackend` and `RemoteZmxBackend` (+ `ZmxRuntime`, `ZmxOutputFilter`), `SSHTransport`, `RemoteDeployer`, `ReconnectSchedule`, `EphemeralBackend`, `LaunchResolver`, `SessionController`, `HelperLocator`, `HelperInstaller`, and the `ctty-exec` helper source |
| `Packages/TerminalSurface` | Renderer protocol, appearance types, `SurfaceRegistry`, Ghostty theme parser |
| `Packages/SwiftTermSurface` | SwiftTerm adapter |
| `scripts/` | `fetch-zmx.sh`, `zmx.lock`, `embed-zmx.sh` (build phase), `check-quit.sh` (quit check against a built app), `check-state-compat.sh` (every release tag refuses a state file the working tree wrote, or reads it without loss) and `state-fixtures/` (writes a state fixture with a release tag's own code; see its README), `bump-build.sh` (raises the build number, optionally the version, in `project.yml`), `embed-sparkle.sh` (build phase: embeds and signs the updater framework), `sparkle-tool.sh` (Sparkle's `generate_keys`, `sign_update`, `generate_appcast` from the pinned package), `appcast.sh` and `appcast.py` (the update feed's items), `ed25519-verify.swift` (checks an update signature against a public key), `release.sh` (the release DMG) and `install-release.sh` (builds it and installs the app to `~/Applications`; see [Releasing](#releasing)), `fetch-dmgbuild.sh` and `dmgbuild-requirements.txt` (the pinned dmgbuild for the DMG), `dmg/settings.py` (the DMG's dmgbuild settings: contents, window, icon positions), `render-dmg-background.swift` (regenerates the DMG window's background, `dmg/background.png`, `dmg/background@2x.png` and `dmg/background.tiff`), `render-app-icon.swift` (regenerates the app icon: `Armadale/Resources/AppIcon.icon`, `Armadale/Resources/Assets.xcassets/AppIcon.appiconset`, the menu bar glyph `Armadale/Resources/Assets.xcassets/StatusItem.imageset` and `docs/icon/AppIcon.svg`); edit the scripts, not the generated files |
| `Vendor/zmx/` | Fetched zmx binaries (git-ignored) |
| `Vendor/dmgbuild/` | dmgbuild virtual environment for releases (`scripts/fetch-dmgbuild.sh`, git-ignored) |

## License

Armadale is open source under the [MIT License](LICENSE). Contributions
are accepted under the same terms ([CONTRIBUTING.md](CONTRIBUTING.md)).
The licenses of the components it bundles, SwiftTerm, the persistence
helper and Sparkle (the updater), and the credits for the built-in colour schemes are in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md); the app carries the
same notices under Help › Acknowledgements.
