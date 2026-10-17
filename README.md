# Armadale

Armadale is a native macOS terminal for running and supervising a fleet of
persistent agent sessions (Claude Code, Codex, or plain shells). Sessions
survive app restarts, live locally or on SSH hosts, and are organised as
**Workspace → Tab Group → Tab → Pane**. The app uses AppKit for windows and
splits and SwiftUI for chrome. Terminal rendering sits behind a pluggable
`TerminalSurface` protocol, and SwiftTerm is the first renderer. Session
persistence comes from a private, bundled `zmx` daemon. Layout is stored as
versioned JSON in `~/Library/Application Support/Armadale/`.

Status: step 3 (persistence). The window shows the focused pane of the
selected tab: a real login shell, rendered by SwiftTerm, running in a
private zmx session. Quitting Armadale disconnects the panes but leaves the
sessions running; on relaunch every pane reattaches to the same shell and
its screen and scrollback are replayed. A session whose program exited (or
that is gone after a reboot) shows *Session Ended* with Respawn / Close
Pane, and **Workspace › Respawn All Ended** (⌥⌘R) respawns every ended pane
of the window's workspace.

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

The integration test `floodBaselineWithoutReattach` measures a zmx flood
without the reattach mitigation (docs/DESIGN.md section 7); it only runs
when `ARMADALE_FLOOD_BASELINE` is set (to the number of seconds to wait for
the prompt, 300 by default) and can take minutes.

### Environment overrides

| Variable | Effect |
|---|---|
| `ARMADALE_STATE_DIR=/dir` | State directory: `state.json`, `bin/` (helper copies) and `run/` (sessions). Use a short path (such as `/tmp/armadale-dev`) so socket paths stay under the limit. |
| `ARMADALE_BACKEND=ephemeral` | Plain PTY sessions that end when the app quits (tests, debugging). |
| `ARMADALE_ZMX=/path/to/zmx` | zmx binary to bundle-install and test with, instead of the app's `Contents/Helpers/zmx` or `Vendor/zmx`. |
| `ARMADALE_CTTY_EXEC=/path/to/ctty-exec` | `ctty-exec` to use (see below). |

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

The `confirmClosingRunningSession` user default (default `true`) controls
whether ⌘W asks before closing a pane whose process is still running.

## Layout

| Path | Contents |
|---|---|
| `project.yml` | XcodeGen spec (app target, scheme, signing) |
| `Armadale/` | AppKit app: lifecycle, menus, windows, SwiftUI sidebar, panes, `SessionRegistry` |
| `Packages/ArmadaleCore` | Model, `PaneLayout` operations, `AppModel`, `StateStore`, migrations (no AppKit) |
| `Packages/ArmadaleSessions` | `PTYProcess`, `CommandRunner`, `LocalZmxBackend` (+ `ZmxRuntime`, `ZmxOutputFilter`), `EphemeralBackend`, `LaunchResolver`, `SessionController`, `HelperLocator`, `HelperInstaller`, and the `ctty-exec` helper source |
| `Packages/TerminalSurface` | Renderer protocol and appearance types |
| `Packages/SwiftTermSurface` | SwiftTerm adapter |
| `scripts/` | `fetch-zmx.sh`, `zmx.lock`, `embed-zmx.sh` (build phase) |
| `Vendor/zmx/` | Fetched zmx binaries (git-ignored) |
