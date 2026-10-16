# Armadale

Armadale is a native macOS terminal for running and supervising a fleet of
persistent agent sessions (Claude Code, Codex, or plain shells). Sessions
survive app restarts, live locally or on SSH hosts, and are organised as
**Workspace → Tab Group → Tab → Pane**. The app uses AppKit for windows and
splits and SwiftUI for chrome. Terminal rendering sits behind a pluggable
`TerminalSurface` protocol, and SwiftTerm is the first renderer. Session
persistence comes from a private, bundled `zmx` daemon. Layout is stored as
versioned JSON in `~/Library/Application Support/Armadale/`.

Status: step 2 (one pane). The window shows the focused pane of the
selected tab: a real login shell on Armadale's own PTY layer, rendered by
SwiftTerm. When the session ends, the pane shows *Session Ended* with
Respawn / Close Pane. Sessions are not yet persistent: they end when the app
quits, and after a relaunch they show as ended (zmx arrives in step 3).

The design is in [docs/DESIGN.md](docs/DESIGN.md).

## Requirements

- macOS 27, Xcode 27 (Swift 6.4)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Generate, build, test

```sh
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
path. They take about 10 s.

Dependency versions are locked in
`Armadale.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
It is the only tracked file inside the generated project, and
`xcodegen generate` leaves it alone. CI passes
`-onlyUsePackageVersionsFromResolvedFile`, so builds use exactly those
versions. To change a pin, edit `Packages/SwiftTermSurface/Package.swift`,
run `swift package resolve` in that directory, and copy the resulting
`Package.resolved` over the locked one.

SwiftTerm includes a build-tool plugin. On the command line you need
`-skipPackagePluginValidation`. In Xcode, choose **Trust & Enable** the first
time you build.

Set `ARMADALE_STATE_DIR=/some/dir` to point the app at a different state
directory, for example when debugging.

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
`Contents/Helpers/`, then next to the running test bundle. Set
`ARMADALE_CTTY_EXEC=/path/to/ctty-exec` to override the location.

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
| `Packages/ArmadaleSessions` | `PTYProcess`, `EphemeralBackend`, `LaunchResolver`, `SessionController`, `HelperLocator`, and the `ctty-exec` helper source |
| `Packages/TerminalSurface` | Renderer protocol and appearance types |
| `Packages/SwiftTermSurface` | SwiftTerm adapter |
