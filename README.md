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

All nine steps of the build order in [docs/DESIGN.md](docs/DESIGN.md)
section 12 are implemented and committed on `main` (October 2026). Step 8
is menu bar mode, asking before quitting with running sessions; step 9 is
Developer ID signing and `scripts/release.sh`, which builds a notarized,
stapled DMG (see [Releasing](#releasing)). There is no updater and no
crash reporting in v1.
Where development stopped, what is next and the open items are in
[HANDOFF.md](HANDOFF.md); the rules for working in the repository are in
[AGENTS.md](AGENTS.md).

What works today:

- **Hierarchy.** Each workspace is a window with a sidebar listing every
  workspace, its tab groups and tabs (with status glyphs), a tab bar for the
  selected tab group, and the selected tab's split panes. Splits (⌘D /
  ⇧⌘D), focus (⌥⌘ arrows), resize (⌃⌘ arrows or divider drag), zoom (⇧⌘↩),
  equalize (⌃⌘=), tabs (⌘T, ⌘1…⌘9, ⌃Tab), tab groups (⇧⌘N, ⇧⌘1…⇧⌘9) and
  workspaces (⌘N) work from the menus and keyboard; tabs and groups can be
  renamed and reordered by dragging, and a tab dragged onto a sidebar tab
  group moves there. Closing a window keeps its workspace in the sidebar.
  The full shortcut table is in docs/DESIGN.md section 9 and in Settings.
- **Persistence.** Sessions outlive Armadale (see [Quitting and the menu
  bar](#quitting-and-the-menu-bar)); a relaunch
  restores windows, layouts and selections and reattaches every visible
  pane, replaying its screen and scrollback. A session whose program exited
  shows *Session Ended* with Respawn / Close Pane; **Workspace › Respawn All
  Ended** (⌥⌘R) respawns every ended pane of a workspace.
- **Settings** (⌘,): General (default profile and directory, close
  confirmation, quitting with running sessions, notifications), Appearance
  (font, size, light and dark themes, Ghostty theme import, cursor,
  renderer), Profiles, Hosts, and a read-only Shortcuts table generated
  from the menus. **File › New Tab with Profile** opens a tab with any
  profile.
- **Remote hosts.** **Settings › Hosts** adds SSH hosts (destination, port,
  identity file, SSH config file, remote folder) with Test Connection and
  Deploy Now. **File › New Tab on Host** opens a session that keeps running
  on the host: Armadale installs its private persistence helper under
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

The design is in [docs/DESIGN.md](docs/DESIGN.md).

## Requirements

- macOS 27, Xcode 27 (Swift 6.4)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Generate, build, test

```sh
scripts/fetch-zmx.sh  # downloads the pinned zmx into Vendor/zmx (git-ignored)
xcodegen generate     # creates Armadale.xcodeproj (git-ignored)

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
does it, in two cases, each with its own scratch state directory: it sends
SIGTERM (`pkill -x Armadale`) and checks that the app is gone within 2 s.
Normally, no session client may be left and the session daemon must still
be alive. With the fallback alert up (it makes `<state dir>/bin` a regular
file so the session runtime cannot be set up), the quit must not wait for
the alert and must still save the state.

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
was installed, and check that a truncated helper on the host is replaced. For example, against a Lima VM:

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
| `ARMADALE_STATE_DIR=/dir` | State directory: `state.json`, `bin/` (helper copies) and `run/` (sessions). Use a short path (such as `/tmp/armadale-dev`) so socket paths stay under the limit. |
| `ARMADALE_BACKEND=ephemeral` | Plain PTY sessions that end when the app quits (tests, debugging). |
| `ARMADALE_ZMX=/path/to/zmx` | zmx binary to bundle-install and test with, instead of the app's `Contents/Helpers/zmx` or `Vendor/zmx`. |
| `ARMADALE_CTTY_EXEC=/path/to/ctty-exec` | `ctty-exec` to use (see below). |
| `ARMADALE_DEFAULTS_SUITE=name` | Keep settings in the UserDefaults suite `name` instead of the app's domain (same as the `-ArmadaleDefaultsSuite name` argument). |

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
run inside a pane never sees Armadale's private sessions.

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
Details in docs/DESIGN.md section 8, "Quitting with running sessions".

## Settings and themes

Settings live in the app's user defaults (`com.tinylittleapps.armadale`,
i.e. `~/Library/Preferences/com.tinylittleapps.armadale.plist`), through the
typed `Preferences` store: default profile and directory, the three
notification settings (`notifyOnAttention`, `notifyOnlyForAgents`,
`notificationPlaysSound`), `confirmClosingRunningSession` (default `true`: closing a pane, tab or tab
group with a running process asks first), `quitWithRunningSessions` (`ask`, `keepInMenuBar` or
`endSessions`; default `ask`), font name and size (⌘= / ⌘- / ⌘0
change the stored size), theme choice, cursor, renderer, and the Settings
window's position and tab. Profiles are not preferences: they are saved
with the layout in `state.json`.

Imported themes are JSON files in `<state dir>/themes/<name>.json`
(`~/Library/Application Support/Armadale/themes/` by default). Import reads
a Ghostty theme file (`palette = N=#rrggbb`, `background`, `foreground`,
`cursor-color`, `selection-background`, `selection-foreground`); importing
a file with the same name replaces the earlier one. To remove an imported
theme, delete its JSON file (it falls back to the default theme).

To keep test or debugging runs away from your real settings, point the app
at another defaults suite:

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

To release:

1. Bump `MARKETING_VERSION` (the version users see, e.g. `0.2.0`) and
   `CURRENT_PROJECT_VERSION` (the build number, which must increase with
   every release) in the app target's settings in `project.yml`, and
   commit.
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
   helper), notarizes and staples the app, builds the DMG (volume
   "Armadale" with the app and an Applications link), signs, notarizes
   and staples it, and checks both with Gatekeeper (`spctl`) and `stapler
   validate`. Notarization usually takes a few minutes per submission; a
   rejected submission fails the script and prints the notary log.
3. The result is `build/release/Armadale-<version>.dmg`. Until every
   check has passed the DMG is called `Armadale-<version>-pending.dmg`, so
   a file with that name is not a release. The script prints the suggested
   `git tag` command; tagging and publishing are up to you.

To run the release build on this Mac, `scripts/install-release.sh` runs
`scripts/release.sh` (passing on any options, such as `--skip-notarize`),
mounts the DMG and installs the app from it into `~/Applications`,
replacing the copy there. It refuses while Armadale is running (quit it
first; persistent sessions keep running). `--from-dmg` installs the DMG
already in `build/release/` without building again.

`scripts/release.sh --skip-notarize` (no credentials needed) stops after
the signature checks and builds `build/release/Armadale-<version>-unnotarized.dmg`,
signed but not notarized: Gatekeeper rejects it ("source=Unnotarized
Developer ID"), so it is for checking the pipeline only. To check that a
Release build starts sessions, run `scripts/check-quit.sh
build/release/Armadale.xcarchive/Products/Applications/Armadale.app`.

A Developer ID build has a different code identity from a development
build. Notification permission is kept per bundle identifier and carries
over; privacy grants, which macOS ties to the code identity, and macOS
27's "Allow in the Background" decision may be asked for again.

## Layout

| Path | Contents |
|---|---|
| `project.yml` | XcodeGen spec (app target, scheme, signing) |
| `docs/` | `DESIGN.md` (the design contract), `icon/AppIcon.svg` (master vector of the app icon, generated) |
| `Armadale/` | AppKit app: lifecycle, menus (the source of the shortcut table), windows, SwiftUI sidebar and tab bar, split tree and panes, `SessionRegistry` (a backend per host), `AttentionCenter`, Settings (`Settings/`: window, `Preferences`, tabs), `ThemeCatalog`, `AppSettings` and `UserNotificationService` (`Support/`), `Resources/armadale-notify` |
| `Packages/ArmadaleCore` | Model, `PaneLayout` operations, `SplitTreeReconciler`, `AppModel`, `AttentionTracker`, `AgentIntegration`, `StateStore`, migrations (no AppKit) |
| `Packages/ArmadaleSessions` | `PTYProcess`, `CommandRunner`, `ZmxSessionDriver` with `LocalZmxBackend` and `RemoteZmxBackend` (+ `ZmxRuntime`, `ZmxOutputFilter`), `SSHTransport`, `RemoteDeployer`, `ReconnectSchedule`, `EphemeralBackend`, `LaunchResolver`, `SessionController`, `HelperLocator`, `HelperInstaller`, and the `ctty-exec` helper source |
| `Packages/TerminalSurface` | Renderer protocol, appearance types, `SurfaceRegistry`, Ghostty theme parser |
| `Packages/SwiftTermSurface` | SwiftTerm adapter |
| `scripts/` | `fetch-zmx.sh`, `zmx.lock`, `embed-zmx.sh` (build phase), `check-quit.sh` (quit check against a built app), `release.sh` (the release DMG, see [Releasing](#releasing)), `render-app-icon.swift` (regenerates the app icon: `Armadale/Resources/AppIcon.icon`, `Armadale/Resources/Assets.xcassets/AppIcon.appiconset`, the menu bar glyph `Armadale/Resources/Assets.xcassets/StatusItem.imageset` and `docs/icon/AppIcon.svg`; edit the script, not the generated files) |
| `Vendor/zmx/` | Fetched zmx binaries (git-ignored) |
