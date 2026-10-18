# Armadale — Design

Armadale is a native macOS terminal for running and supervising a fleet of
persistent agent sessions. Sessions survive app restarts, live locally or on
SSH hosts, and are organised as **Workspace → Tab Group → Tab → Pane**.

| Decision | Choice |
|---|---|
| UI stack | AppKit app lifecycle and windows; SwiftUI for chrome (sidebar, tab bar, settings, placeholders); AppKit for split containers and terminal views |
| Language / toolchain | Swift 6.4, strict concurrency, Xcode 27, deployment target macOS 27 |
| Terminal renderer | Pluggable `TerminalSurface` protocol; SwiftTerm is the first implementation |
| Session persistence | Bundled `zmx` daemon per session, never exposed to the user |
| Remote sessions | SSH transport; Armadale deploys its own private `zmx` to the host |
| Project generation | XcodeGen (`project.yml`) plus local Swift packages |
| Distribution | Developer ID, notarized, hardened runtime, **no** App Sandbox |
| State storage | Versioned JSON in `~/Library/Application Support/Armadale/` |

---

## 1. Concepts and hierarchy

```
App
└── Workspace            (one NSWindow; listed in every window's sidebar)
    └── Tab Group        (sidebar folder; ⇧⌘1…9)
        └── Tab          (tab bar entry; ⌘1…9)
            └── Pane tree (binary splits)
                └── Pane  ──1:1──▶ Session
```

- **Workspace** — a window. Owns an ordered list of tab groups and remembers
  its frame, sidebar width and selection. Closing the window does not delete
  the workspace; it stays in the sidebar of other windows and can be reopened.
  Deleting a workspace (explicit, confirmed) kills its sessions.
- **Tab Group** — a named folder of tabs. The tab bar always shows the tabs
  of the selected tab group.
- **Tab** — a layout of one or more panes. Its title defaults to the focused
  pane's session title and can be renamed.
- **Pane** — a rectangle in the tab's split tree. A pane always has exactly
  one session, so the pane tree is also the session layout.
- **Session** — the persistent thing: a working directory, a launch profile
  (shell, command, Claude, Codex…), a location (local or an SSH host), and a
  runtime state. Sessions are only ever created by Armadale; it never adopts
  sessions created elsewhere.

### Sidebar semantics

The sidebar is app-global and identical in every window. It lists every
workspace, with the current window's workspace expanded and highlighted.
Clicking another workspace brings that window to front, or opens it if its
window is closed. Under a workspace: tab groups, and under each tab group its
tabs. Panes are not listed; a tab row shows a status summary of its panes.

Each tab row carries a status glyph:

| State | Meaning |
|---|---|
| ● running | at least one pane's process is alive |
| ◐ attention | a pane rang the bell or emitted a notification while unfocused |
| ○ ended | all panes have exited |
| ⚠ disconnected | remote host unreachable; sessions may still be alive there |

*Step 4:* the glyph is shared by the sidebar's tab rows and the tab bar
(`StatusGlyph`), computed by `SessionRegistry.status(of:)`. Two states were
added: *starting* (dotted circle: not attached yet, or a pane never shown
whose session the launch probe did not find alive) and *unavailable* (the
persistent runtime could not be set up). A pane not shown yet whose session
the probe found alive counts as running. A tab shows the most important
state of its panes: disconnected, unavailable, running, starting, and ended
only when all have ended. *Attention* arrives with step 7.

The current workspace's row is emphasised (accent icon, semibold), the
window's selected tab group is the selected row, and a closed workspace is
dimmed with a "reopen" icon. Rows: a click on another workspace shows or
opens its window; on a tab group or tab, selects it (bringing its window to
front if it belongs to another workspace). Double-click renames (a sheet,
not inline editing). Context menus: workspace — New Tab Group, Rename,
Show/Open Window, Delete Workspace… (always confirmed); tab group — New Tab,
New Tab Group, Rename, Close Tab Group (confirmed like ⌘W); tab — Rename,
Close Tab, Close Other Tabs. Drag and drop uses a private UTType
(`com.tinylittleapps.armadale.hierarchy-item`, declared in Info.plist), so a
tab dropped on a terminal never types anything: a tab group dropped on
another of the same workspace takes its place; a tab (from the tab bar or the
sidebar) dropped on a tab group moves to its end and becomes that group's
selected tab, while the window keeps showing its current group (Finder-like
filing; a group left empty by a move is kept and shows an empty state with
New Tab; ⌘W there closes the group, without asking since nothing runs in
it). A rename sheet opens on the window of the workspace that owns the
item, so double-clicking another workspace's row (which brings its window
forward) puts the sheet there.

Closing asks first (unless turned off) when a session may be running:
running or disconnected, or *starting* when a process may exist: a session
restored from an earlier run before the launch probe has answered, or one
whose start is under way. A session created in this run whose pane was
never shown has no process and does not ask. Unreachable (unavailable)
sessions always ask (`CloseRisk`, unit-tested).

---

## 2. Data model (`ArmadaleCore`)

Pure value types, `Codable` and `Sendable`, no AppKit imports. This is what is
persisted and what every UI layer reads.

```swift
struct WorkspaceID: Hashable, Codable, Sendable { let raw: String }   // short random id
struct TabGroupID, TabID, PaneID, SessionID, HostID … // same shape

struct Workspace: Identifiable, Codable, Sendable {
    let id: WorkspaceID
    var name: String
    var tabGroups: [TabGroup]
    var selectedTabGroupID: TabGroupID?
    var window: WindowState?               // frame, sidebarWidth, isOpen
}

struct TabGroup: Identifiable, Codable, Sendable {
    let id: TabGroupID
    var name: String
    var tabs: [Tab]
    var selectedTabID: TabID?
}

struct Tab: Identifiable, Codable, Sendable {
    let id: TabID
    var customTitle: String?               // nil → derived from focused pane
    var layout: PaneLayout
    var focusedPaneID: PaneID
    var zoomedPaneID: PaneID?
}

indirect enum PaneLayout: Codable, Sendable {
    case pane(PaneID)
    case split(axis: Axis, ratio: Double, first: PaneLayout, second: PaneLayout)
}

struct Pane: Identifiable, Codable, Sendable {
    let id: PaneID
    var sessionID: SessionID
}

struct Session: Identifiable, Codable, Sendable {
    let id: SessionID
    var location: Location                 // .local | .remote(HostID)
    var profileID: ProfileID               // for icon, status rules, respawn
    var launch: LaunchSpec                 // resolved at creation: program, args, env
    var workingDirectory: String
    var title: String                      // last OSC 0/2 title, for display
    var createdAt: Date
    var runtimeVersion: String?            // zmx version that created the daemon; nil for ephemeral
}

struct Host: Identifiable, Codable, Sendable {   // SSH target
    let id: HostID
    var name: String                       // display
    var sshDestination: String             // user@host or ssh_config alias
    var port: Int?
    var identityFile: String?
    var remoteDirectory: String            // default "~/.armadale"
}

struct Profile: Identifiable, Codable, Sendable {
    let id: ProfileID
    var name: String
    var kind: Kind                         // .shell, .command, .agent(AgentFlavor)
    var program: String?                   // nil → login shell
    var arguments: [String]
    var environment: [String: String]
    var icon: String                       // SF Symbol name
}
```

Built-in profiles ship for **Shell**, **Claude Code** (`claude`), and
**Codex** (`codex`). Users can add their own in Settings. An SSH session is
not a profile: it is any profile with a `.remote(host)` location.

*Step 5:* a session still records the `LaunchSpec` it was created with, so
a running session is unaffected by later profile edits, but **Respawn uses
the profile as it is at respawn time** (`AppModel.launchForRespawn(of:)`,
asked by `SessionController` through its delegate), falling back to the
recorded launch when the profile has been deleted. Built-in profiles
(`Profile.isBuiltIn`) cannot be deleted, and only their name and icon can
be changed; duplicating one gives a fully editable copy.

Layout operations live in `PaneLayout` as pure functions with unit tests:
`split(pane, axis, newPane)`, `remove(pane)` (collapses the parent),
`neighbor(of:direction:)`, `resize(pane, delta)`, `swap`, `equalize` (weighted
by how many panes sit side by side on each axis, so nested columns come out
equal, as in Ghostty), and
(step 4) `moveDivider(of:toward:by:)` (⌃⌘ arrow: moves the pane's nearest
divider on that axis in the arrow's direction, as Ghostty's
`resize_split` does, whichever side of it the pane is on),
`hasSameShape(as:)` and `clampingRatios()`.

`SplitTreeReconciler` (also in `ArmadaleCore`, pure and tested) turns
successive layouts of one view into `SplitTree`s: the same tree with an
identity on every split container. A new split keeps an old container's
identity when that container held exactly the same panes on the same axis
(a subtree that moved, e.g. when closing a pane collapses its parent), or
else when the old tree had an unclaimed container with the same axis at the
same position (e.g. the parent of a pane that was split). The app keeps one
`NSSplitView` per identity, so a pane is only reparented when its parent
container really changed.

### `AppModel`

A single `@MainActor @Observable final class AppModel` owns `[Workspace]`,
`[Session]`, `[Host]`, `[Profile]` and exposes intent methods
(`newTab(in:)`, `splitFocusedPane(axis:)`, `closePane(_:)`,
`moveTab(_:to:)`, …). Step 4 added `moveTabGroup`, `closeTabGroup`,
`closeOtherTabs(than:)`, `selectTab(number:)` (9 means last),
`selectTabGroup(number:)`, `selectAdjacentTab(offset:)` (wraps),
`moveFocus(_:)` (unzooms), `resizeFocusedPane(toward:by:)` (ignored while
zoomed), `equalizePanes`, `toggleZoom` (only with more than one pane) and
`setSplitRatios(_:for:)` (divider drags; ignored unless the layout still has
that shape). Step 5 added the profile intents `newProfile`,
`duplicateProfile`, `updateProfile` (cleans up blank names, icons and
programs; for built-ins takes only name and icon) and `deleteProfile`
(refused for built-ins), plus `launchForRespawn(of:)`. The default
profile and directory are not model state: they are preferences
(section 8) that the app copies into `defaultProfileID` /
`defaultWorkingDirectory`. Every mutation goes through it, which is what makes the
sidebar and tab bar trivially consistent across windows and what triggers
persistence.

---

## 3. Persistence of layout: `StateStore`

- File: `~/Library/Application Support/Armadale/state.json`, with
  `schemaVersion` at the top and explicit migration steps per version.
- Written atomically (temp file + rename), debounced 500 ms after any model
  change, and synchronously on quit.
- Stores workspaces, selections, window frames, sessions, hosts, profiles.
- Does **not** store scrollback or terminal state; the session daemon holds
  that.
- A backup of the previous file is kept as `state.json.bak`; a parse failure
  on launch falls back to it and reports the problem rather than starting
  empty.

SwiftData was considered and rejected: the state is a small tree that is
easier to inspect, diff and migrate as JSON.

---

## 4. Session persistence: the zmx backend

zmx (MIT, Zig, zmx.sh) runs one daemon per session, each with its own Unix
socket, and replays the terminal snapshot and scrollback on reattach using
libghostty-vt. It deliberately has no windows, tabs or splits, which is
exactly the division of labour Armadale wants. It is an implementation
detail: nothing in the UI, menus or settings says "zmx".

### Isolation

- Armadale sets `ZMX_DIR` to its own directory,
  `~/Library/Application Support/Armadale/run`, so Armadale's sessions never
  appear in a user's own `zmx ls`, and theirs never appear in Armadale. zmx
  allows 103 bytes for `ZMX_DIR + "/" + name`; the default path is 72 bytes
  for a five-letter user name, so the fallback to `/tmp/armadale-<uid>` only
  triggers when `$HOME` is longer than 64 bytes. Spaces in the path are fine
  (verified).
- Session names are `a-<SessionID>`. IDs are 16 lowercase base32 characters.
- `ZMX_NO_DETACH_KEY=1` is set so Ctrl+\ reaches the application in the pane
  (verified). Armadale manages attaching and detaching itself.
- `ZMX_SESSION` and `ZMX_SESSION_PREFIX` are **scrubbed** from the environment
  of every zmx invocation. If Armadale is itself launched from inside a zmx
  session, an inherited `ZMX_SESSION` turns `zmx attach X` into a "switch"
  that, in 0.8.1, kills the inherited session and never creates `X`.
- zmx's stdout is always a pipe, never a regular file: it writes positionally
  at offset 0 and would overwrite the file's start.

### Bundling

- `scripts/fetch-zmx.sh` downloads a pinned release
  (`https://zmx.sh/a/zmx-<ver>-<os>-<arch>.tar.gz`) for
  `macos-aarch64`, `macos-x86_64`, `linux-aarch64`, `linux-x86_64`, verifies
  SHA‑256 sums committed in `scripts/zmx.lock`, and places them under
  `Vendor/zmx/` (git‑ignored). Pinned version: **0.8.1** (latest as of
  2026‑10‑15; macos-aarch64 SHA‑256
  `1d86b1c9fba47fa707a6f0e976b20510b07c1c26d0ed010b9414b2a2c5e6beef`).
- An XcodeGen build phase (`scripts/embed-zmx.sh`) `lipo`s the two macOS
  binaries into a universal `Contents/Helpers/zmx`, which is code‑signed
  with the app's identity, no entitlements, and the hardened runtime for
  notarization. The Linux binaries ship as data in
  `Contents/Resources/remote/` for deployment to SSH hosts. *Implementation
  notes:* the phase runs with user-script sandboxing off for the app target
  (`codesign` writes a temporary file next to the helper, and the phase runs
  `fetch-zmx.sh` when `Vendor/zmx` does not verify against `zmx.lock`; a
  modified or stale copy is re-fetched, and the build fails if no verified
  copy can be had); its inputs and outputs
  are still declared. Xcode itself turns `ENABLE_HARDENED_RUNTIME` off for
  ad-hoc ("Sign to Run Locally") builds, so local builds of both helpers are
  plain ad-hoc and Developer ID builds are hardened (zmx was verified to run
  hardened: the integration tests pass against a hardened copy).
- A second helper, `Contents/Helpers/ctty-exec`, is a ten-line trampoline
  built from source in this repo (see section 7). It is bundled and copied
  the same way as zmx.
- At launch Armadale (`HelperInstaller`) copies both helpers to
  `~/Library/Application Support/Armadale/bin/` as `zmx-<zmx version>` and
  `ctty-exec-<app version>` if missing or different (SHA-256), through a
  temporary file and an atomic rename, and always runs **those** copies.
  Daemons therefore never hold open a binary inside an app bundle that may
  be replaced by an update. The daemon's argv[0] is that path, so `pgrep -f`
  can identify Armadale's daemons. Older `zmx-<ver>` copies are kept while a
  session records that version (section 13); older `ctty-exec` copies are
  removed, since nothing keeps running them.

### `PersistenceBackend` protocol

```swift
protocol PersistenceBackend: Sendable {
    func create(_ session: Session, size: PTYSize) async throws -> ProcessHandle  // attach, creating
    func attach(_ session: Session, size: PTYSize) async throws -> ProcessHandle  // attach only if exists
    func exists(_ id: SessionID) async throws -> Bool
    func liveSessions() async throws -> Set<SessionID>
    func kill(_ id: SessionID) async throws
    func history(_ id: SessionID) async throws -> Data               // live sessions only
    func resolveExit(of session: Session) async -> ExitResolution    // .ended | .detached
}
```

`resolveExit` was added in step 3: a zmx client exits the same way whether
its session ended or only the client went away, so the backend decides from
the session itself (`exists(id)`; listing errors count as `.detached`).
`ProcessHandle.runtimeVersion` reports the zmx version a create used, which
the app stores on the `Session`.

`size` is the PTY's initial window size. It has to be set when the PTY is
opened, otherwise the program's first output (a shell prompt, an agent's
first screen) is laid out for the wrong width. Failures common to all
backends are `BackendError` values (`notPersistent`, `noSuchSession`,
`historyUnavailable`, and `runtimeFailure` for control commands that fail or
time out and clients that cannot start).

Implementations:

- `LocalZmxBackend` — spawns `zmx attach a-<id> <program> <args…>` in a
  PTY, with `chdir` to the working directory before exec so the daemon
  inherits it. Everything after the name is the argv, passed verbatim to
  `execvpe`. There is **no `--` separator**: zmx would try to execute `--`.
  Because zmx uses the program path as argv[0], a login shell could not be
  started as `-zsh`; the program is therefore `ctty-exec <program> <argv0>
  <args…>` (the trampoline's `TIOCSCTTY` succeeds silently in the daemon's
  child, which already owns its PTY).
- `RemoteZmxBackend` — same commands wrapped in `ssh` (section 6).
- `EphemeralBackend` — a plain PTY with no daemon. Used as a fallback when
  the remote host cannot take a zmx deployment, and in UI tests. Its
  `attach` always throws `BackendError.notPersistent`, so sessions it
  created show as ended after a relaunch.

The distinction between **create** and **attach** matters: `zmx attach`
creates a session if none exists, which would silently respawn a dead agent
with a fresh shell on relaunch. zmx 0.8.1 has no attach‑only flag, so the
backend builds the two operations itself (all verified empirically):

- **`attach`** runs `zmx attach a-<id> /usr/bin/true`. An existing session
  ignores the command and attaches normally. A missing one is created, runs
  `true`, dies at once, and the client exits 1, leaving nothing behind. This
  closes the window between an `ls` check and the attach. Restore still
  consults `liveSessions()` first (one `zmx ls --short` per backend at
  launch) so missing sessions are marked ended without any spawn.
- **`create`** runs `zmx attach a-<id> <program> …`, waits for the client to
  connect (it prints `session "a-<id>" created`), drops that client, and
  then attaches again. This is needed because the daemon only replays its
  screen to the second and later clients; output produced before the first
  client finished connecting, such as the shell's initial prompt, is lost to
  it. The double attach makes creation deterministic and also keeps the
  `created` line out of the pane.
- **Telling the cases apart** (step 3): the backend looks at a client's
  first output without consuming it. `ESC[2J` first means attached to an
  existing session, so `attach` returns at once rather than waiting to see
  whether the client exits. `session "a-<id>" created` first means the
  sentinel created the session, i.e. it did not exist: `attach` waits for
  that client to die, kills the name defensively and throws `noSuchSession`.
  Anything else, or nothing within 2 s, is
  `runtimeFailure("Could not establish the session.")` and the pane shows
  Disconnected with Reconnect, rather than a client that never shows
  anything.
  `create` drops its first client only after `created` **and** `ESC[2J`
  plus 150 ms: the client prints `ESC[2J` *before* it sends its Init
  message, and only Init marks the daemon as having had a client (read in
  `main.zig`/`loop.zig`); a client dropped earlier would leave the next one
  without a replay. A program that exits before the second attach surfaces
  as `runtimeFailure("The session ended as soon as it started.")` with
  whatever it printed.

### Client stream filtering

The zmx client writes fixed sequences of its own that must not reach the
surface:

- `ESC[2J ESC[H` on every attach (a clear, acceptable, but the surface is
  cleared explicitly before attach so the replay starts clean).
- On detach or session end: `ESC c` (RIS) followed by `OSC 110 / 111 / 112`
  resets. RIS would wipe the pane just as the *Session Ended* placeholder
  appears, so the exact byte sequence
  `\x1bc\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\` is filtered at the end of
  the stream.

Replay format on attach: scrollback lines as plain text with SGR, then a
clear, then the visible screen with modes and scrolling region, then cursor
position, `ESC[0m`, OSC 7 (cwd) and OSC 2 (title). Alternate‑screen programs
are replayed inside `?1049h`. Scrollback is capped at 10,000 lines by zmx and
is not configurable.

A session that is on the alternate screen when Armadale reattaches (vim,
less, an agent's full-screen UI) is replayed as that screen only: zmx sends
neither the primary screen nor its scrollback while the alternate screen is
active. When the program then exits, the pane is back on a primary screen
that holds nothing from before the reattach (the session itself still has
it, and a later reattach shows it again). This is a limit of zmx 0.8.1's
replay and is accepted.

### Session lifecycle

```
          create/attach
 detached ───────────────▶ attaching ──▶ attached ──┬──▶ ended(exit)      client exited and
    ▲                                        │       │                    session not in ls
    │          app quit / window closed       │       └──▶ disconnected    transport died but
    └────────────────────────────────────────┘                            session may be alive
```

- **Attached**: the pane's PTY runs the zmx client. Output bytes go to the
  surface; input goes to the PTY; resizes go to the PTY via `TIOCSWINSZ`,
  which zmx forwards to the daemon.
- **Client gone, session alive** (`resolveExit` → `.detached`): the
  controller reattaches once by itself (surface reset first; the replay
  restores it). If that fails, or the new client goes away again at once,
  the pane shows **Disconnected** ("Armadale lost its connection to this
  session. It may still be running.", **Reconnect** / **Close Pane**),
  never *Session Ended*: the session is alive, and an ended pane's Respawn
  would retire it. An attach that lasted 5 s restores the allowance. An
  attach **or create** that fails for any reason other than the session
  being gone (including a client that shows nothing recognisable within
  2 s, such as a client/daemon mismatch, or a create whose second attach
  times out on a loaded machine) also ends in Disconnected: after a failure
  the controller asks `exists(id)`, and only a session confirmed gone is
  shown as ended.
- **Unavailable**: when the persistent runtime cannot be set up at launch,
  Armadale falls back to plain PTY sessions for new panes only. Restored
  sessions that the runtime created (`runtimeVersion` set) show
  "Persistent sessions are unavailable" with **Retry**, which runs the
  installer again and attaches them if it now works. They are never shown
  as ended, never respawned by Respawn All, and never killed (they cannot be
  reached). ⌘W on such a pane always asks first ("This session may still be
  running and cannot be reached right now."), and closing it leaves the
  session running until the next launch with a working runtime reclaims it
  (Housekeeping).
- **Ended**: the client exited and `exists(id)` is false. When the session's
  process exits, the zmx daemon exits too, unlinks its socket and the session
  vanishes from `ls`; there is no "exited but listed" state. The client's own
  exit code is always 0, so it cannot distinguish detach from end, and the
  program's exit status is discarded by zmx. The pane shows the *Session
  Ended* placeholder (icon, "The session “<title>” is no longer running.",
  **Respawn** / **Close Pane**) **over the surface's last contents**, which
  the surface retains; `history()` cannot be used because the session no
  longer exists. Exit codes are not shown in v1. If they turn out to matter,
  the program can be wrapped by a small recorder; this is deliberately left
  out for now.
- **Daemon killed from outside** (SIGKILL, reboot): `ls` reports the stale
  socket as an error entry, cleans it up, and `ls --short` omits it. The pane
  ends up in the same ended state.
- **Respawn**: kills the old session (always: a pane that looks ended may
  still be alive, and a not-found kill is harmless), creates a new session
  with the same directory and location and the profile's current launch
  (step 5; the old `launch` if the profile was deleted), and rebinds the pane to
  it. The old session ID is retired and its zmx log removed. Close Pane
  likewise always kills. The
  surface is fully reset first (RIS, scrollback cleared), so modes a dead
  program left on, such as the alternate screen or mouse reporting, do not
  carry over.
- **Disconnected**, remote (step 6): the ssh transport died. Same
  placeholder; Armadale also retries in the background with exponential
  backoff (1 s → 30 s) until the host answers, then re-attaches
  automatically.
- **Workspace › Respawn All Ended** exists for the morning‑after‑reboot case
  where every session is gone.

### Environment handed to new sessions

`TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Armadale`,
`TERM_PROGRAM_VERSION`, `ARMADALE_SESSION_ID`, `LANG` (from the user's
locale), the user's login shell environment, plus profile environment
(merged last, so it wins). A session without a program runs the login shell
from the user database as a login shell (`argv[0]` `-zsh`, plus `-l`). A
session with a program runs it as `$SHELL -l -c 'exec <program> <args…>'`,
so it is found on, and runs with, the login `PATH` rather than the app's
minimal launchd environment.

The base is the app's own environment, minus variables that describe
whatever Armadale itself was started from: `ZMX_SESSION*`, `TMUX`, `STY`,
`TERM_SESSION_ID`, `ITERM_*`, `KITTY_*`, `GHOSTTY_*`, `WEZTERM_*`,
`ALACRITTY_*`, `LC_TERMINAL*`, `VTE_VERSION`, `WINDOWID`, `SHLVL`,
`OLDPWD`, `TERMINFO`, `COLORFGBG`, `XPC_SERVICE_NAME`, `DYLD_*` and other
Xcode launch variables, and Armadale's own
`ARMADALE_*` (for example `ARMADALE_STATE_DIR`). `PWD` is set to the
working directory, and a working directory that no longer exists falls back
to the home directory. This is done by `LaunchResolver`. Because the
daemon inherits the cwd and environment of the **creating** client only
(verified), later attaches cannot change them; zmx's tracked‑variable
mechanism keeps `SSH_AUTH_SOCK` current. zmx itself sets `ZMX_SESSION` inside
the child. The daemon also passes on the creating client's `ZMX_DIR` and
`ZMX_NO_DETACH_KEY=1`. None of them may reach the program: with them, a
user's own `zmx ls` or `zmx attach x` inside a pane would list Armadale's
private sessions or switch this one away. The program is therefore started
as `ctty-exec --unset ZMX_DIR --unset ZMX_NO_DETACH_KEY --unset ZMX_SESSION
--unset ZMX_SESSION_PREFIX <program> <argv0> …`, and the trampoline removes
them before its `execv` (verified: `env | grep ZMX` in a pane prints
nothing).

### Housekeeping

zmx writes one log per daemon to `ZMX_DIR/logs/<name>.log` plus a shared
`zmx.log`, at debug level, each truncated at 2 MB but never deleted. At
launch Armadale removes log files whose session ID is neither live nor
referenced by the model, and during a run it removes a session's log as
soon as it kills or retires the session.

At launch, once the live probe has answered, Armadale also ends live
sessions in its runtime directory that no saved session refers to (for
example one whose pane was closed while the runtime was unavailable).
Armadale only ever manages sessions it created, and this keeps to that:
the runtime directory is private to the app, and only `a-<id>` names are
listed. It is done only when an existing state file loaded cleanly; with
no state file at all (a first launch, or a file the user removed), or after
a damaged, recovered or newer-format one, the references are unknown and
nothing is killed (`OrphanReclaimer`).

---

## 5. Terminal rendering: `TerminalSurface`

Rendering is behind a small `@MainActor` protocol so the engine can be swapped
without touching sessions or layout.

```swift
@MainActor protocol TerminalSurface: AnyObject {
    var view: NSView { get }
    var delegate: TerminalSurfaceDelegate? { get set }
    var gridSize: GridSize { get }                     // cols, rows, cell px
    func feed(_ bytes: ArraySlice<UInt8>)              // process → screen
    func apply(_ appearance: TerminalAppearance)       // font, theme, cursor
    func clearScrollback()
    func scrollToBottom()
    func find(_ query: String, direction: FindDirection)
    var selectedText: String? { get }
}

@MainActor protocol TerminalSurfaceDelegate: AnyObject {
    func surface(_ s: TerminalSurface, didInput bytes: [UInt8])
    func surface(_ s: TerminalSurface, didResize size: GridSize)
    func surface(_ s: TerminalSurface, didSetTitle title: String)
    func surface(_ s: TerminalSurface, didChangeDirectory url: URL)   // OSC 7
    func surfaceDidRingBell(_ s: TerminalSurface)
    func surface(_ s: TerminalSurface, didRequestClipboard op: ClipboardOp)
    func surface(_ s: TerminalSurface, didReceiveNotification title: String, body: String) // OSC 9/777
}
```

- `SwiftTermSurface` wraps SwiftTerm's `TerminalView` (not
  `LocalProcessTerminalView`): Armadale owns the PTY so the same process
  plumbing serves every renderer. SwiftTerm is imported with
  `@preconcurrency` and confined to the main actor by the adapter.
- A second implementation (libghostty, or a Metal grid renderer) only needs to
  satisfy the protocol. The renderer is chosen in Settings and applied to new
  surfaces; existing surfaces are rebuilt on the next attach.
  *Implementation (step 5):* `SurfaceRegistry` (in `TerminalSurface`) holds
  `SurfaceFactory`s keyed by a persisted identifier (`swiftterm` is the
  only one and the default; an unknown identifier resolves to the default).
  The app's `SurfaceRegistry.standard` registers them, and
  `SessionRegistry` makes every new surface through the factory named by
  the `rendererID` preference. When that preference changes, each existing
  pane calls `SessionController.replaceSurfaceOnNextAttach(_:)`; the
  controller swaps the surface at the start of its next connect (Respawn,
  Reconnect, an automatic reattach; a relaunch makes new surfaces anyway),
  before anything is fed to it or its size is taken, and tells its
  delegate, which puts the new view in the pane. A live terminal is never
  torn down, and an ended pane keeps showing its last screen until then.
  Choosing the pane's current renderer again cancels the replacement.
  `TerminalTheme` gained an optional `selectionForeground` (from Ghostty
  themes); SwiftTerm cannot recolour selected text and ignores it.
- Surface views are owned by the session controller, not by the layout. Tab
  switches and pane moves reparent the view; they never recreate it, so no
  terminal state is lost and no replay is needed.

---

## 6. Remote hosts

A session with `.remote(host)` location uses the same zmx model on the host.

- **Deployment**: on first use Armadale runs `ssh host 'uname -sm'`, picks the
  matching bundled binary, and streams it to
  `~/.armadale/bin/zmx-<ver>` on the host (`ssh host 'mkdir -p … && cat >
  … && chmod +x …'`). Remote `ZMX_DIR` is `~/.armadale/run`. Version is
  checked on each connection; a mismatch triggers a redeploy. If the host
  cannot run it (unsupported OS, read‑only home), the session falls back to
  `EphemeralBackend` over ssh and the pane shows a "not persistent" badge.
- **Interactive attach**: `ssh -tt <dest> -- env ZMX_DIR=~/.armadale/run
  ZMX_NO_DETACH_KEY=1 ~/.armadale/bin/zmx-<ver> attach a-<id> <program>`
  runs inside the pane's PTY, spawned through the same `ctty-exec`
  trampoline as local sessions because `ssh -t` also relies on SIGWINCH to
  forward resizes. Host‑key and passphrase prompts therefore appear in the
  pane itself, which is the simplest and most honest UX. The attach‑only and
  double‑attach‑on‑create rules from section 4 apply unchanged.
- **Control commands** (`ls`, `kill`, `exists`, deploy) run through the same
  destination with OpenSSH multiplexing:
  `-o ControlMaster=auto -o ControlPersist=600 -o ControlPath=<App
  Support>/ssh/%C`, so a workspace with twenty remote panes keeps one TCP
  connection per host.
- **Working directory** for remote sessions is a path on the host, validated
  with `ssh host test -d` before creation.
- Hosts are managed in Settings › Hosts and in the new‑session sheet. SSH
  config aliases are honoured, so most users only type a name.

---

## 7. Process plumbing (`ArmadaleSessions`)

- `PTYProcess`: `openpty()`, then `posix_spawn` of the **`ctty-exec`
  trampoline** with `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT |
  POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF`, a file‑action `open` of
  the slave device onto fd 0, `dup2` to 1 and 2, and `addchdir` (the `_np`
  variant is deprecated since macOS 26) for the working directory. The
  trampoline calls `ioctl(0, TIOCSCTTY)` and `execv`s the real program.
  This is required: on macOS 27, `posix_spawn` with `SETSID` and an open of
  the slave does **not** give the child a controlling terminal (verified
  with `ps` TPGID and by `^C` not interrupting `sleep`; bash hides the bug
  by acquiring the tty itself, zsh and bare programs do not). Without a
  controlling terminal the zmx client never receives SIGWINCH and resizes
  are silently lost. `forkpty` works too and remains the fallback, but
  `posix_spawn` keeps fd hygiene and signal reset in the kernel and runs no
  Swift after a fork in a multithreaded app.
- The parent keeps the slave fd open until `posix_spawn` returns; closing it
  earlier resets the tty and the child reads a 0×0 window size.
- The PTY pair is opened with `O_CLOEXEC | O_NOCTTY` on the `open` calls
  themselves (`/dev/ptmx`, `grantpt`, `unlockpt`, `ptsname_r`), not
  `openpty()` followed by `fcntl`. A `Process` launched concurrently
  elsewhere in the app therefore cannot inherit the master, and the app
  never acquires the terminal itself.
- `ctty-exec` is signed with no entitlements at all
  (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`, `ENTITLEMENTS_REQUIRED = NO`).
  Xcode would otherwise add `com.apple.application-identifier`, a restricted
  entitlement that, without a provisioning profile, can stop the helper
  from launching under Developer ID. Release builds keep the
  hardened-runtime flag.
- `HelperLocator` finds `ctty-exec` via `$ARMADALE_CTTY_EXEC`, then
  `Contents/Helpers/` of the main bundle, then next to the running `.xctest`
  bundle (SwiftPM and Xcode build the executable there for package tests).
- Only fds 0–2 reach the child (`CLOEXEC_DEFAULT`). This matters because the
  zmx daemon only closes inherited fds 3–63.
- Output is read with a `DispatchSource` on the non-blocking master fd into
  a 64 KB buffer and delivered as an `AsyncStream<[UInt8]>` of batches of at
  most 64 KB. Delivery is throttled rather than debounced: the first bytes
  after a quiet period go out at once, so echo is never delayed, and within
  16 ms of the previous batch more output waits until the 16 ms are up or
  64 KB have accumulated. The stream is pull-based. Above 256 KB of
  undelivered output the read source is suspended, so the kernel's PTY
  buffer fills and the child blocks, as it would on any slow terminal. A
  full 64 KB batch is handed over at once, whatever the interval. Under a
  flood (`yes`, a million-line `seq`) the main actor is therefore busy
  (about 2,200 batches a second were measured with a free consumer); the
  consumer yields after every batch (while output keeps coming, the stream
  hands over the next batch without ever suspending, so without the yield
  it would hold the main actor for the whole flood). For an **ephemeral**
  session, memory stays bounded by the backpressure: the child blocks.
  A hard limit of one batch per 16 ms was rejected: it would cap output at
  about 4 MB/s.
- **zmx floods.** Backpressure cannot reach a program inside a persistent
  session: zmx 0.8.1's client copies everything the daemon sends into an
  unbounded stdout buffer (`loop.zig`), so a pane that falls behind only
  grows that client. When the session client's buffered backlog grows past
  ~16 MB, Armadale drops that client and reattaches to a bounded snapshot
  (10,000 scrollback lines plus the screen), so output produced in that
  window is skipped. This only happens when the renderer is genuinely far
  behind, not on fast output that is being rendered.
  The backlog is measured directly as the client process's memory
  footprint (`proc_pid_rusage`, `ri_phys_footprint`), sampled off the main
  actor every 500 ms while attached, after a 1 s grace period following
  each attach; two consecutive samples over the limit trigger the
  reattach. There is no rate or "consumer behind" heuristic: an earlier
  version that reattached on sustained output above 320 KB/s misfired on a
  30 fps full-screen redraw (~390 KB/s, rendered fine), resetting the pane
  every ~3 s. Measured with zmx 0.8.1: an idle client, and one carrying
  ~410 KB/s for 5 s that the pane keeps up with, stays at about 1.4 MB
  (0 reattaches); one second of `yes` against a pane limited to ~6 MB/s
  takes the client to about 35 MB. The suggested 32 MB limit was therefore
  too close to that peak to trigger reliably; 16 MB is about eleven times
  an idle client. Without the mitigation the prompt appeared 78 s after
  ^C; with it, 0.75 s, after one reattach (in the app the reviewer saw
  100% CPU for 260 s and a 115 MB client before). The ephemeral backend
  is unchanged: there the child blocks, as on any slow terminal.
- The stream finishes at EOF/EIO. If a leftover background job keeps the
  terminal open after the process exits, it finishes 100 ms after the exit
  instead, and the master is closed.
- Input and resizes go through a serial queue in call order.
  `ProcessHandle.write` and `resize` are synchronous enqueue calls rather
  than `async`, because separate tasks calling async methods could reorder
  keystrokes. Partial writes and `EAGAIN` are retried without blocking reads.
  Process exit is observed with `DispatchSource.makeProcessSource(.exit)`
  and `waitpid`. For zmx clients the exit status is meaningless (always 0);
  the session state is decided by `exists(id)` afterwards.
- `terminate()` sends SIGHUP to the child, its process group and the
  terminal's foreground job, sends SIGKILL to the same set if anything is
  still running 2 s later, then closes the master. Signals are only sent
  before the child is reaped, on the same queue that reaps it, so a reused
  pid is never signalled.
- Dropping a `PTYProcess` closes the master and also sends SIGHUP itself.
  The kernel's hangup on master close only reaches a child that has already
  acquired the terminal, and one dropped right after spawn may not have done
  so yet (observed: a `sleep` outlived its closed PTY). The child is still
  reaped when it exits, so neither fds nor zombies leak.
- `PTYProcess` is a port of the spike harness (`PTYSpawn.swift`,
  `ctty-exec.swift`). It is Sendable with all mutable state in
  `Synchronization.Mutex`, and uses no `nonisolated(unsafe)` or
  `@unchecked Sendable`. `forkpty` stays selectable as a fallback.
- One‑shot commands (`zmx ls`, `kill`, ssh control) go through an
  `actor CommandRunner` built on `Process` with async `run() -> (status,
  stdout, stderr)` and a timeout.
- `SessionController` (`@MainActor`) is the per‑session glue: owns the
  surface, the `ProcessHandle`, the state machine, the attention flag, and
  forwards title / cwd / bell to `AppModel` through a delegate. An optional
  `OutputFilter`, made fresh for each attach, rewrites output before it
  reaches the surface. It is the identity for ephemeral sessions; zmx uses
  it to strip the RIS sequence at end of stream. The filter's `finish()`
  runs exactly once per attach, however the session ends. The session ends
  when the process has exited and its output has drained, or 500 ms after
  the exit if the stream stays open.
- `respawn()` is not re-entrant: a second call while one is in progress
  does nothing, so a double click cannot retire one session twice. A
  connect that `close()` or `respawn()` overtakes is killed in the backend
  when it completes, not just disconnected, so no daemon is left
  unreferenced.
- ⌘K clears the surface's scrollback and sends ^L to the program, the
  conventional redraw key. A shell clears and redraws its own prompt, so
  its idea of the cursor stays correct. An ended pane is cleared locally.

### Concurrency rules

- All model and UI state is `@MainActor`. Backends and the command runner
  are actors; data crossing the boundary is `Sendable` value types or
  `[UInt8]`.
- No `DispatchQueue.main.async` from library code; everything surfaces as
  `async` functions or `AsyncStream`s consumed on the main actor.

---

## 8. Windows and views

AppKit owns lifecycle and windows; SwiftUI is hosted where it is the better
tool.

```
WorkspaceWindowController (NSWindowController, one per open workspace;
│                          menu commands land here)
├── WorkspaceWindow (NSWindow; reports first-responder changes)
├── WorkspaceActions                                    select / create / rename /
│                                                       close (confirmed) / drops
└── NSSplitViewController
    ├── Sidebar: NSHostingController<SidebarView>       SwiftUI List, drag & drop
    └── Content: ContentViewController
        ├── TabBarHostingView<TabBarView>              SwiftUI, ⌘N badges, "+"
        └── PaneContainerView (NSView)                 or an empty-group state
            └── SplitTreeView (nested PaneSplitViews mirroring PaneLayout)
                └── PaneView per leaf
                    ├── surface.view                   terminal
                    ├── NSHostingView<PlaceholderView> Session Ended / Disconnected
                    └── focus overlay                  border / dim, no hit testing
```

- Window uses `titlebarAppearsTransparent`, `toolbarStyle = .unified`, and
  `title` / `subtitle` set to "Workspace name" / "Tab group name", which
  produces the header in the mockup. The toolbar holds the sidebar toggle.
- `SplitTreeView` diffs the new `PaneLayout` against the current view tree
  and reparents existing `PaneView`s rather than rebuilding, preserving
  terminal views and first responder. *Implementation (step 4):* the diff is
  `SplitTreeReconciler` (section 2); containers whose identity survives keep
  their `NSSplitView`, and only changed children are moved. Frames are
  assigned top-down before anything is laid out inside a view: a new
  container gets its final frame, and a pane its final size, before the
  pane is moved into it, and a split with no size lays nothing out. (A new
  container starting at zero size would otherwise squeeze the pane moved
  into it to 0×0 first, sending its program an extra resize through a tiny
  grid; `ArmadaleAppTests` checks that a split resizes each affected
  terminal exactly once.) Panes left in a dropped container are detached
  from it. Each
  `PaneSplitView` lays its two panes out from the model's ratio in one pass
  (its own frames, then `setPosition` at the same place so NSSplitView's
  divider drawing follows; letting `super` resize proportionally first gave
  nested panes two sizes per layout pass, and their programs two SIGWINCHes).
  Its delegate is a separate object: an `NSSplitView` that is its own
  delegate recurses forever in `respondsToSelector:`. Ratios stay within
  0.1–0.9 while dragging. A drag updates the view at once and is written to
  the model 400 ms after the last move (`setSplitRatios`), or at once when
  the tab changes, a keyboard resize comes, or the window closes.
- The selected tab shows its layout, or only its zoomed pane. After every
  change the visible sessions are started (after layout, so they start at
  their real size), and keyboard focus moves to the focused pane when the
  tab or the focused pane changed, or when reparenting left no responder; it
  is never taken from the sidebar or a sheet otherwise. In the other
  direction `WorkspaceWindow.makeFirstResponder` reports every change, so a
  click into a pane (or its padding) focuses it in the model.
- Closing a window stops its content controller: pending divider positions
  are written, it stops following the model, and its pane views are taken
  out of the closed window (the registry keeps them). The app delegate then
  drops the window controller, and both controllers deinit (logged in debug
  builds; `ArmadaleAppTests` checks it).
- Hierarchy commands are nil-targeted menu items handled by
  `WorkspaceWindowController`, which is in the responder chain whether a
  terminal or the sidebar has focus; the tab bar, the sidebar and the menu
  all go through one `WorkspaceActions` per window, so closing asks the same
  question everywhere (running or disconnected sessions, honouring the
  "don't ask again" default; unreachable ones always). App-wide commands
  (new workspace, font size) are on the app delegate.
- An app-level `SessionRegistry` owns one `SessionController` and its
  `PaneView` per session shown so far. It creates them lazily when a pane
  first becomes visible and keeps them until the session leaves the model,
  so tab switches and window closes never destroy a terminal. It is the
  controllers' delegate, and it records titles, directories and respawns in
  `AppModel`.
- The pane area is pinned to the content view's safe area. On macOS 27 the
  content view extends under both the transparent title bar and the
  floating sidebar.
- Keyboard focus follows `focusedPaneID`; the focused pane has a subtle
  accent border, the unfocused ones dim slightly (only while more than one
  pane is on screen).
- The tab bar is custom SwiftUI (not `NSTabView`): it needs shortcut badges,
  status glyphs, drag reordering, and dragging a tab onto a sidebar tab group
  to move it. Tabs share the width (110–220 pt) and scroll when they do not
  fit; each shows its status glyph, title (custom, else session title, else
  profile name), a split/zoom hint, and ⌘1…⌘8 badges (⌘9 on the last tab),
  which turn into a close button on hover. Click selects; dropping a tab on
  another takes its position (from any group or window); middle click
  (handled by the hosting view, SwiftUI has no gesture for it) and the close
  button close it with the ⌘W confirmation; the context menu has Rename,
  Close, Close Other Tabs.
- Settings is an `NSWindowController` hosting SwiftUI tabs:
  **General** (default profile, default directory, confirm‑on‑close),
  **Appearance** (font, size, theme, cursor, renderer), **Profiles**,
  **Hosts**, **Shortcuts** (read‑only table in v1).
  *Implementation (step 5):* `SettingsWindowController` (one instance,
  owned by the app delegate, opened by ⌘,) hosts an `NSTabViewController`
  with `tabStyle = .toolbar` whose items are `NSHostingController`s of the
  SwiftUI tab views, rather than a SwiftUI `TabView`: outside a SwiftUI
  `Settings` scene a `TabView` does not produce the standard toolbar of
  settings tabs, and `NSTabViewController` does. The window
  (`toolbarStyle = .preference`) resizes to each tab, keeping its top
  edge, and remembers its position and last tab in preferences (not with
  `setFrameAutosaveName`, which would write to the standard defaults even
  when a test suite is in use).
  - **Preferences** (`Settings/Preferences.swift`) is a typed,
    `@Observable` store over an injected `UserDefaults`; the app's is the
    standard domain, or the suite named by `ARMADALE_DEFAULTS_SUITE` /
    `-ArmadaleDefaultsSuite <name>`. It holds the default profile and
    directory (empty = home, `~` expanded), `confirmClosingRunningSession`
    (same key as step 4), font name and size (6–48, stored; ⌘= / ⌘- / ⌘0
    write through it), the theme choice (one theme, or a light and a dark
    one that follow the system appearance), cursor shape and blink, the
    renderer, and the Settings window's position and tab. Profiles stay in
    the model (`state.json`).
  - `AppSettings` bundles `Preferences`, `ThemeCatalog` and the
    `SurfaceRegistry` and turns them into a `TerminalAppearance` for a
    light or dark view. Each `PaneView` observes it, so every appearance
    change, including a re-imported user theme, applies to all panes at
    once, shown or not.
  - `ThemeCatalog` (`Support/ThemeCatalog.swift`) holds the built-in
    themes as data (Armadale Light/Dark, Solarized Light/Dark, Dracula,
    Nord, One Dark, Gruvbox Dark; IDs `builtin.*`) and user themes stored
    as JSON in `<state dir>/themes/<name>.json` (IDs `user.<name>`). Import
    reads a Ghostty theme file with `GhosttyTheme.parse` (a pure function
    in `TerminalSurface`, next to `TerminalTheme`; it uses only
    Foundation): `palette = N=#hex`, `background`, `foreground`,
    `cursor-color`, `selection-background`, `selection-foreground`;
    comments, quotes and missing `#` are accepted, bad lines are reported,
    other keys ignored. Importing the same name again replaces it. An
    unknown theme ID falls back to Armadale Light or Dark.
  - Appearance offers a popup of installed fixed-pitch families (regular
    face, SF Mono first) plus the system font panel, a size stepper, the
    theme pickers with a preview, Import Ghostty Theme…, cursor shape and
    blink, and the renderer picker.
  - Profiles: list with add / duplicate / delete (built-ins cannot be
    deleted) and an editor (name, SF Symbol icon with preview, kind,
    program, arguments one per line, environment table); edits go through
    the `AppModel` intents. File › New Tab with Profile and the tab bar's
    "+" context menu open a tab with any profile.
  - Hosts is a placeholder until step 6.
  - Shortcuts is generated from the menu bar `MainMenu` builds
    (`ShortcutTable`): every item with a key equivalent, hidden alternates
    folded into their visible item, numbered runs collapsed
    (⌘1…⌘8), so it cannot drift from the real bindings. Only items
    `MainMenu` created are listed (it gives each an `armadale.menu.*`
    identifier); what AppKit adds later, the Services menu's contents and
    the Window menu's tiling commands (🌐⌃C Center, …), is not Armadale's
    and is left out. The Globe modifier is shown as 🌐.
  - The window is titled "Settings" whatever the tab, and ⌘W (File ›
    Close Pane, which only workspace windows otherwise handle) closes it.
  - A profile's environment variables must have a non-empty name without
    `=`, spaces or NUL, and may not start with `ARMADALE_` or `ZMX_`
    (`Profile.environmentNameProblem`); the editor shows why a row will not
    be saved and `updateProfile` drops it. `LaunchResolver` applies the
    same rule and removes every `ZMX_*` variable after merging, so nothing
    from a profile reaches the session runtime.
  - Re-applying the appearance (every tab switch, every theme change)
    does not reset the cursor: the surface only pushes the cursor style
    when the preference changed, so a program's own DECSCUSR choice
    (vim's insert-mode bar) stays.
  - A deleted default profile resets the preference to the shell.
    Ghostty import also accepts the basic X11 colour names (black … white,
    bright/light variants, grey), meaning the default palette's entries;
    the default palette is the light one when the background is light
    (luminance > 0.5). A rejected file reports its bad lines. User theme
    IDs are lower-case and matched case-insensitively; Appearance ›
    Remove deletes an imported theme, and choices using it fall back to
    the defaults. A font picked in the font panel that is not fixed-pitch
    is refused with a message.

### App lifecycle

- `NSApplicationDelegate` loads `StateStore`, builds `AppModel`, probes each
  backend's live sessions once, then opens every workspace whose window was
  open at last quit and attaches its visible panes first, the rest lazily
  when their tab is first shown.
- Quit never kills sessions. `applicationShouldTerminate` hangs every
  pane's client up synchronously (SIGHUP and closing its terminal; no
  waiting) and returns `.terminateNow`, then the state is saved
  synchronously. `.terminateLater` was tried and rejected: SIGTERM's handler
  ran inside a main-queue block, where AppKit's nested run loop starves the
  main actor, so the reply never came and logout would hang. SIGTERM now
  quits from the run loop, performed in the common **and modal-panel**
  modes, so an app-modal alert (a launch or save-failure warning shown with
  `runModal()`) does not hold the quit until someone clicks OK; the
  terminate path (`applicationShouldTerminate` → `.terminateNow`, then the
  synchronous save) runs from inside the modal session.
  `scripts/check-quit.sh` checks both cases: exit within 2 s (measured:
  119 ms each), with no client left and the daemons alive, and with the
  fallback alert up, the state saved on the way out. Closing a pane kills its session after a confirmation if it is
  still running or disconnected (configurable), and also kills a session
  that was never shown (restored but not yet attached). Closing a window
  keeps the workspace.
- Closing the last tab in a tab group removes the tab group. Closing the
  last tab group in a workspace closes the workspace's window; the workspace
  stays in the model and in the sidebar, and reopening it creates a fresh
  "Main" group with one Shell tab.
- A new workspace's window (⌘N), or a reopened one without a saved frame,
  cascades from the key window. Open windows, their frames, sidebar width,
  and every workspace's selected group, tab and focused pane are in the
  state file, so a relaunch restores them. Window geometry is recorded when
  a move or live resize ends, and, debounced by 500 ms, after a sidebar
  drag or collapse and after a resize that is not live (zoom), so a crash
  loses at most that half second.
- Reboot or daemon loss simply yields panes in the ended state on next
  launch, with "Respawn All Ended" one click away.

---

## 9. Keyboard shortcuts

Ghostty's macOS defaults, plus Armadale's hierarchy keys. Armadale-specific
bindings are marked ✱.

| Shortcut | Action |
|---|---|
| ⌘N | New workspace (window) |
| ⇧⌘N ✱ | New tab group |
| ⌘T | New tab in current tab group |
| ⌘D / ⇧⌘D | Split pane right / down |
| ⌘W | Close pane (last pane closes tab) |
| ⇧⌘W | Close window |
| ⌘1…⌘8, ⌘9 | Go to tab N, last tab |
| ⇧⌘1…⇧⌘9 ✱ | Go to tab group N |
| ⌃Tab / ⌃⇧Tab, ⇧⌘] / ⇧⌘[ | Next / previous tab |
| ⌥⌘← ↑ → ↓ | Focus pane in direction |
| ⌃⌘← ↑ → ↓ | Resize pane |
| ⇧⌘↩ | Toggle pane zoom |
| ⌃⌘= | Equalize panes |
| ⌘↩ | Toggle full screen |
| ⌘K | Clear screen |
| ⌘= / ⌘- / ⌘0 | Font size up / down / reset |
| ⌘C / ⌘V | Copy / paste |
| ⌃⌘S ✱ | Toggle sidebar |
| ⌘, | Settings |

Rebinding is out of scope for v1; the table is exposed read‑only in Settings.

*Step 4 notes.* Every row is an `NSMenuItem` key equivalent (built in
`App/MainMenu.swift`, which is the shortcut table until Settings shows it),
so the shortcuts appear in the menus and work whatever has focus, and keys
not bound there reach the terminal (since step 5, Settings › Shortcuts
is generated from these menu items). ⌃Tab / ⌃⇧Tab and ⌘+ are hidden
alternates (`allowsKeyEquivalentWhenHidden`) of ⇧⌘] / ⇧⌘[ and ⌘=. ⌘9 goes
to the last tab, ⇧⌘9 to the ninth tab group. ⌃⌘ arrows move the nearest
divider by 5 % of its split (`moveDivider`). ⌘= / ⌘- / ⌘0 change the font
size of every pane; since step 5 the size is the stored Appearance
setting, so it persists across launches. ⌘, opens Settings (step 5).
Commands also in the menus
without a default key: Close Tab, Close Tab Group, Rename Workspace / Tab
Group / Tab, Delete Workspace.

---

## 10. Agent sessions

A pane is "just a shell" by default. The agent profiles only add:

- a launch program (`claude`, `codex`) and arguments; the resolved
  `LaunchSpec` is stored on the session, and a respawn takes the profile
  as it is then (falling back to the stored launch if the profile is gone);
- an **attention** rule: a bell (BEL) or an OSC 9 / OSC 777 notification in
  an unfocused pane sets the tab's attention state, shows a badge on the Dock
  icon count, and optionally posts a `UNUserNotification`. Claude Code and
  Codex both ring the bell on completion when configured to.
- The sidebar's "running / ended / attention" glyphs make a dozen agents
  scannable at a glance.

Richer status (idle vs. working vs. waiting for approval) would need
agent‑specific hooks and is explicitly left out of v1; the profile model has
room for it.

---

## 11. Repository layout

```
armadale/
├── project.yml                      XcodeGen spec
├── Armadale/                        app target (AppKit)
│   ├── App/                         main.swift, AppDelegate, menus
│   ├── Windows/                     WorkspaceWindowController, WorkspaceActions, ContentViewController
│   ├── Sidebar/                     SidebarView (SwiftUI)
│   ├── Tabs/                        TabBarView, StatusGlyph (SwiftUI)
│   ├── Panes/                       PaneContainerView, SplitTreeView, PaneView, SessionPlaceholderView
│   ├── Sessions/                    SessionRegistry (controllers per session), SessionStatus / CloseRisk
│   ├── Settings/                    SettingsWindowController, Preferences, ShortcutTable, SwiftUI tabs
│   │                                (General, Appearance, Profiles, Hosts, Shortcuts)
│   ├── Resources/                   Assets.xcassets, Info.plist, Armadale.entitlements
│   └── Support/                     ThemeCatalog (built-in + user themes), AppSettings
│                                    (+ SurfaceRegistry.standard), HierarchyDragItem, TextPrompt;
│                                    the shortcut table's source is App/MainMenu
├── ArmadaleAppTests/                tests of the app target's code (unhosted)
├── Packages/
│   ├── ArmadaleCore/                model, PaneLayout ops, StateStore, migrations   (no AppKit)
│   ├── ArmadaleSessions/            PTYProcess, CommandRunner, backends, SSHTransport, SessionController,
│   │                                LaunchResolver, HelperLocator; Sources/ctty-exec (helper source)
│   ├── TerminalSurface/             protocol, appearance types, SurfaceRegistry, GhosttyTheme parser
│   └── SwiftTermSurface/            SwiftTerm adapter (depends on SwiftTerm)
├── Vendor/zmx/                      fetched binaries (git‑ignored)
├── scripts/                         fetch-zmx.sh, zmx.lock, notarize.sh
└── docs/DESIGN.md
```

- `ArmadaleCore` and the layout operations are fully unit‑tested with Swift
  Testing and run in a few seconds without a UI.
- `ArmadaleAppTests` (step 4) tests the app target's own code: the split
  tree view with real SwiftTerm surfaces, the close-confirmation rule, and
  window controller lifetime; since step 5 also `Preferences` (each test
  in its own defaults suite, removed afterwards), `ThemeCatalog`, the
  shortcut table, settings reaching existing panes, the renderer switch
  and the Settings window. It is unhosted: it compiles the app's sources
  (all but `main.swift`) into the test bundle, so the app never launches, no
  window is shown, no state file is touched, and an inert backend starts no
  process.
- `ArmadaleSessions` has integration tests that spawn a real local zmx
  session, kill it, and assert the state machine.
- No hosted CI: GitHub Actions is disabled for this repository. The full
  build and test command is run locally before every commit (see README).
- Signing: hardened runtime, no sandbox entitlement, `zmx` helper signed as
  part of the bundle, notarization via `notarytool` in `scripts/notarize.sh`.

---

## 12. Build order

1. **Skeleton** — XcodeGen project, packages, `ArmadaleCore` model,
   `PaneLayout` operations with tests, `StateStore` with migrations.
2. **One pane** — `PTYProcess` with the `ctty-exec` helper target,
   `EphemeralBackend`, `SwiftTermSurface`, a single window with one shell
   pane. Proves the surface protocol and the IO path, including that `^C`
   and resizes reach a zsh child.
3. **Persistence** — zmx bundling and the versioned helper copy,
   `LocalZmxBackend`, restore on relaunch, *Session Ended* placeholder,
   Respawn, Respawn All.
4. **Hierarchy** — sidebar, tab groups, tab bar, splits, focus and resize,
   window title/subtitle, shortcut table, drag and drop, multiple windows.
5. **Settings** — window, appearance, profiles, themes, renderer switch.
6. **Remote** — `SSHTransport`, host deployment, `RemoteZmxBackend`,
   disconnected state and auto‑reconnect, Hosts settings.
7. **Agents** — Claude / Codex profiles, attention badges, notifications.
8. **Ship** — notarization pipeline, crash reporting decision, update
   mechanism decision (Sparkle is the obvious candidate).

---

## 13. Risks and open points

- **zmx maturity.** It is pre‑1.0 (0.8.x) and built with a pre‑release Zig.
  Pinning a release and running a private copy limits exposure. There is
  **no version handshake** between client and daemon: the wire format is
  frozen by tests (8‑byte header, 552‑byte info struct, non‑exhaustive tag
  enum), and upstream's README states that an IPC change "will kill all
  your sessions". Armadale therefore keeps the previous `zmx-<ver>` copy in
  its bin directory across an update, attaches daemons with the version that
  created them (recorded on the `Session`), and only retires an old copy
  when no session references it. Newer‑client‑against‑older‑daemon calls
  time out rather than fail fast, so control commands carry a timeout.
- **Replay fidelity.** Reattach replays a libghostty‑vt snapshot (verified
  for scrollback, colours and the alternate screen). SwiftTerm renders it as
  ordinary VT output. Anything odd shows up in step 3 and is the earliest
  signal that a different renderer is worth building. The first attach to a
  fresh session gets no replay, which is why creation attaches twice.
- **Lost exit codes.** zmx discards the program's exit status, so the
  *Session Ended* placeholder cannot show it in v1.
- **Unbounded client buffering** in zmx 0.8.1 (see section 7, "zmx
  floods"): backpressure cannot reach a program inside a persistent
  session. When the session client's buffered backlog grows past ~16 MB,
  Armadale drops that client and reattaches to a bounded snapshot, so
  output produced in that window is skipped; this only happens when the
  renderer is genuinely far behind, not on fast output that is being
  rendered. A zmx release with a bounded client buffer, or one that stops
  reading the daemon while stdout is blocked, would make this unnecessary.
- **Alternate-screen replay** drops the primary screen and scrollback from
  the pane (section 4).
- **SwiftTerm under Swift 6.** It is not annotated for strict concurrency.
  The adapter confines it to the main actor with `@preconcurrency import`,
  and the swappable surface means a cleaner renderer can replace it later.
- **Socket path length** on macOS (104 bytes) constrains where the runtime
  directory lives; handled with the fallback above. zmx does not resolve
  symlinks, so a symlinked short directory is an alternative if ever needed.
- **Remote deployment trust.** Armadale writes a binary into the user's home
  on remote hosts. This is explicit in the Hosts UI, versioned, and confined
  to `~/.armadale`.
- **Team ID** is not yet set; `project.yml` carries an empty placeholder.
  The bundle identifier is `com.tinylittleapps.armadale`.
