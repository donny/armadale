# Armadale — Design

Armadale is a native macOS terminal for running and supervising a fleet of
persistent agent sessions. Sessions survive app restarts, live locally or on
SSH hosts, and are organised as **Workspace → Tab Group → Tab → Pane**.

**Status (October 19, 2026).** All nine steps of the build order (section
12) are implemented, reviewed and committed on `main`: step 8 is menu bar
mode (the quit question, accessory mode with a status item), step 9 is
Developer ID signing and the release pipeline (section 11). This document
is the contract the code was built against and was kept in step with it: paragraphs marked *Step N* or *Implementation (step N)*
record what that step built and where it deviated from the original plan.
Current status, next steps and open items are in `HANDOFF.md` at the
repository root; the rules for working in the repository are in `AGENTS.md`.

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
| ◐ attention | a pane rang the bell or emitted a notification while unfocused (step 7; precedence below) |
| ○ ended | all panes have exited |
| ⚠ disconnected | remote host unreachable; sessions may still be alive there |

*Step 4:* the glyph is shared by the sidebar's tab rows and the tab bar
(`StatusGlyph`), computed by `SessionRegistry.status(of:)`. Two states were
added: *starting* (dotted circle: not attached yet, or a pane never shown
whose session the launch probe did not find alive) and *unavailable* (the
persistent runtime could not be set up). A pane not shown yet whose session
the probe found alive counts as running. A tab shows the most important
state of its panes: disconnected, unavailable, running, starting, and ended
only when all have ended.

*Step 7:* ◐ attention (SF Symbol `circle.lefthalf.filled`, purple) is shown
by a pane whose program rang the bell or sent a desktop notification
sequence while nobody was looking at it (section 10). The final precedence,
most important first (`SessionStatus.precedence`, unit-tested), is:

1. ⚠ disconnected
2. ⚠ unavailable
3. ◐ attention
4. ● running
5. starting
6. ○ ended (only when every pane has ended)

A session needing attention shows ◐ whatever its state, except disconnected
or unavailable, which matter more (it may be gone); an ended one still
shows ◐ (it rang before it exited). The glyph is for display only: close
confirmation (`CloseRisk`) looks at the underlying state. Tabs needing
attention also get a purple tint in the tab bar and a semibold title in the
sidebar, and workspace and tab group rows show how many of their panes need
attention.

The current workspace's row is emphasised (accent icon, semibold), the
window's selected tab group is the selected row, and a closed workspace is
dimmed with a "reopen" icon. Rows: a click on another workspace shows or
opens its window; on a tab group or tab, selects it (bringing its window to
front if it belongs to another workspace). Double-click, or the row's
Rename item in its context menu, edits the title in place, Finder-style
(the tab bar does the same for its tabs; section 8 has the mechanics).
These are the only ways to start one: clicking a sidebar row does not give
the list keyboard focus, so Return keeps going to the terminal (verified
live). In the field, Return commits, Escape cancels
and leaves the old name, and the field losing keyboard focus (a click
elsewhere, another window or app becoming active) commits, as does
quitting. Committing makes every run of whitespace (newlines and tabs
included, as from a paste) one space and trims; a blank name is ignored for a
workspace or tab group (the old name stays) and clears a tab's custom
title, back to its derived title; text unchanged from what the field
started with changes nothing (so a tab's derived title is not pinned by an
edit that was opened and left). A window edits one item at a time:
starting another edit commits the current one. Context menus: workspace —
New Tab Group, Rename Workspace, Show/Open Window, Delete Workspace…
(always confirmed); tab group — New Tab, New Tab Group, Rename Tab Group,
Close Tab Group (confirmed like ⌘W); tab — Rename Tab, Close Tab, Close
Other Tabs. There is no rename command in the menu bar. Drag and drop
uses a private UTType (`com.tinylittleapps.armadale.hierarchy-item`,
declared in Info.plist), so a tab dropped on a terminal never types
anything: a tab group dropped on another of the same workspace takes its
place; a tab (from the tab bar or the sidebar) dropped on a tab group
moves to its end and becomes that group's
selected tab, while the window keeps showing its current group (Finder-like
filing; a group left empty by a move is kept and shows an empty state with
New Tab; ⌘W there closes the group, without asking since nothing runs in
it). The first click of a double click on a row of another workspace
brings that workspace's window forward, so the edit happens in that
window's sidebar, where the keyboard now is; Rename chosen from a context
menu edits in the window it was chosen in. (Renaming used to be a sheet;
inline editing replaced it, and the Workspace menu's three Rename items
went with it.)

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
    var sshConfigFile: String?             // step 6: `ssh -F` instead of ~/.ssh/config
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

*Step 7:* `Profile.attentionIntegration` (Bool, on by default; state saved
without it decodes as on) adds the agent's `AgentIntegration.launchArguments`
in front of the profile's own arguments at launch (`Profile.launchArguments`,
used by `launchSpec`): for Claude Code `--settings
{"preferredNotifChannel":"ghostty"}`, for Codex nothing (section 10). The
built-ins' own arguments are empty and fixed; the toggle is the user's, also
on a built-in (`updateProfile` takes it with the name and icon, a duplicate
copies it). A saved built-in takes what it runs (kind, program, arguments,
environment) from the running version of Armadale and keeps its saved name,
icon and toggle (`Profile.refreshingBuiltIn`, applied by `AppModel.init`),
so a newer Armadale's launch reaches profiles saved by an older one.
`AppModel.onSessionsRemoved` is called synchronously, inside the intent,
with the sessions that left the model (closed, or retired by a respawn);
the attention center uses it.
`Profile.isAgent` is the "Only for agent profiles" filter. `AppModel` gained
the lookups `place(of:)` (workspace, tab group, tab and pane showing a
session), `focusedSessionID(in:)`, `sessionOrder` (every pane's session in
sidebar order) and `sessionIDs(ofTabGroup:)`.

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
(refused for built-ins), plus `launchForRespawn(of:)`. Step 6 added the
host intents `addHost` (a blank name becomes a unique "New Host"),
`updateHost` (trims everything; a port outside 1…65535 becomes the ssh
default; a blank or relative remote directory becomes `~/.armadale`),
`removeHost` (its sessions stay, see section 6), `sessionIDs(onHost:)` and
`newTab(in:onHost:profile:)` (home directory on the host, default
profile). The default
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
  A window's frame is always its normal (windowed) frame; `isFullScreen`
  says whether it was in full screen (section 8, "App lifecycle").
- A field added after a schema version shipped decodes with a default
  when absent (`decodeIfPresent`), without a version bump, when the
  default is right for every file written before it (`Profile.attentionIntegration`,
  `WindowState.isFullScreen`); a change old files cannot be read as
  gets a migration step.
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
time out and clients that cannot start). Step 6 gave `notPersistent` a
`reason` (why a host cannot keep sessions) and added `unreachable` (ssh
could not connect or lost the connection: nothing is known about the
session). `ProcessHandle.persistenceNote` says why a session will not
survive although its backend is persistent (the plain-ssh fallback).

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
  placeholder, titled Reconnecting…; Armadale also retries in the
  background with exponential backoff (1 s → 30 s, for up to 5 minutes)
  until the host answers, then re-attaches automatically (section 6).
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
Xcode launch variables, the markers of a Claude Code session Armadale was
started from (step 7: `CLAUDECODE`, `CLAUDE_PID`,
`CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_ENTRYPOINT`,
`CLAUDE_CODE_EXECPATH`, `CLAUDE_CODE_MESSAGING_SOCKET`,
`CLAUDE_CODE_MESSAGING_TOKEN`, `CLAUDE_CODE_SESSION_ATTENDED`,
`CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_INVOKED_SKILLS`, `CLAUDE_EFFORT`,
`AI_AGENT`, `TRACEPARENT`, the variables Claude Code 2.1.292 sets for its
own children, seen live when Armadale was opened from a Claude Code shell:
a `claude` in a pane then took itself for that session's child, stopped
saving its transcript, and got its messaging token. The rule is narrow:
only names that identify the launching session, listed exactly; a user's
own configuration such as `ANTHROPIC_API_KEY`, `CLAUDE_CONFIG_DIR` or
`CLAUDE_CODE_USE_BEDROCK` is passed on), and Armadale's own
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
*Implementation (step 6):* `SSHTransport`, `RemoteDeployer` and
`RemoteZmxBackend` in `ArmadaleSessions`; the zmx session protocol of
section 4 (create's double attach, attach-only through the sentinel,
`ls --short`, `kill`) lives in one `ZmxSessionDriver`, parameterised by a
`ZmxEndpoint` ("how to spawn a client", "how to run a control command"),
which `LocalZmxBackend` and `RemoteZmxBackend` both use.

- **Transport** (`SSHTransport` protocol; `OpenSSHTransport` runs the
  system's `/usr/bin/ssh`, tests use scripted and loopback fakes). Every
  invocation for a host gets `-o ControlMaster=auto -o ControlPersist=600
  -o ControlPath="<dir>/<token>" -o ConnectTimeout=10
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o LogLevel=ERROR`,
  plus `-F <config>`, `-p <port>`, `-i <identity>` when the host sets them,
  then `--` and the destination (so a destination can never be read as an
  option; one starting with `-` is refused anyway). A destination may be an
  `ssh_config` alias; the user's own config, keys and agent apply
  (`SSH_AUTH_SOCK` is kept, `ZMX_*` and the variables scrubbed for
  sessions are removed from ssh's environment, `TERM=xterm-256color`).
  `Host.sshConfigFile` replaces the user's config (`ssh -F`), e.g. the file
  `limactl show-ssh --format=config` writes for a Lima VM.
  `LogLevel=ERROR` matters for interactive clients: without it ssh prints
  "Shared connection to … closed." on the pane's terminal after zmx's
  final reset sequence, which the output filter would then no longer find.
- **ControlPath** lives in the runtime directory: `<state dir>/run/ssh/`,
  or `/tmp/armadale-<uid>/ssh/` when that is too long. ssh binds a new
  master's socket at the ControlPath plus `.` and 16 random characters
  before renaming it, so the path must stay ≤ 86 bytes. ssh's own `%C`
  (40 hex characters) does not fit under the default state directory
  (`~/Library/Application Support/Armadale/run/ssh` is 57 bytes for a
  five-letter user name), so the socket is named by a 16-hex-character
  token: SHA-256 of destination, port, identity and config file. Editing
  any of them therefore never reuses another connection. (*Deviation:* the
  original design had `<App Support>/ssh/%C`, which overflows `sun_path`.)
  With the default state directory the ControlPath is 74 bytes.
- **Control commands** (`test -x`, `uname`, `ls`, `kill`, uploads) run
  `ssh -T -o BatchMode=yes …` through `CommandRunner` (stdin `/dev/null`, or
  a pipe for uploads with SIGPIPE off; stdout and stderr captured; 30 s
  limit, 180 s for uploads; a timeout counts as unreachable). The first one
  leaves a master behind, so later commands and the interactive clients
  multiplex over one connection per host (measured against a Lima VM:
  190 ms for the first command, 6 ms after). Every remote command is a
  single-line `/bin/sh` script (`exec /bin/sh -c '<script>'`, statements
  joined with `;`), so it means the same whatever the user's login shell
  is: sshd hands the command line to that shell, and csh-family shells
  reject a newline inside quotes (a test parses every command line with
  `/bin/tcsh`, `/bin/sh` and `/bin/zsh`, and the loopback suite runs a whole
  session with tcsh as the login shell). `~/…` becomes `"$HOME"/…`. ssh's
  own failures are exit status 255: `SSHFailure` tells *unreachable*
  (refused, timed out, lost) from *needs interaction* (an unknown host key,
  a rejected or locked key) and *refused* (a changed host key, too many
  authentication failures).
- **Deployment** (`RemoteDeployer`, one per host). Before every create or
  attach, one round trip over the shared connection: `uname -sm` and the
  size (`wc -c`) of `<dir>/bin/zmx-<ver>` if it is an executable file. If it
  is missing or not exactly the size of the bundled binary for that
  platform (a truncated or foreign copy), it is deployed again. Deploying:
  `uname -sm` and `$HOME`; the platform is
  mapped to `linux-aarch64`, `linux-x86_64`, `macos-aarch64` or
  `macos-x86_64` (`Linux arm64` and `amd64` spellings accepted); the bundled
  binary is `Contents/Resources/remote/zmx-<platform>` for Linux and the
  universal `Contents/Helpers/zmx` for macOS (`HelperLocator.remoteZmx`,
  falling back to `Vendor/zmx/<platform>/zmx` in the source tree); it is
  uploaded into a temporary file next to its final path (a rename puts it
  in place: Linux refuses to write over a running binary), and the
  **temporary file is checked before the rename**: its size must equal the
  bundled binary's (`[ $(wc -c < tmp) -eq N ]`), and where the host has
  `sha256sum` or `shasum -a 256` its SHA-256 must equal the bundled
  binary's. Otherwise it is removed and the upload fails (exit 5 or 6;
  "damaged on its way", retried at the next connection). This matters
  because a dropped link (or the 180 s upload limit killing ssh) gives the
  remote `cat` an early EOF and it succeeds: before this check a 3 MB
  prefix could be installed, pass `test -x` and even print its version.
  "Integrity" here means *matches the bundled binary*, which the build
  verified against `scripts/zmx.lock`. A host with neither hash tool gets a
  size check only; the upload prints a marker, `RemoteDeployment.hashVerified`
  is false and the app logs it. After the rename the helper must run
  (`zmx version` prints `zmx\t\t0.8.1` and its socket and log
  directories); one that does not is removed (the helper's own output goes
  to the log, not to the user). Directories are created with `umask 077`
  (so Armadale's own folders are 0700); no existing directory's
  permissions are ever changed. Concurrent checks share one deploy. The
  default directory is `~/.armadale` (`Host.remoteDirectory`): it must be a
  folder of Armadale's own, `~/…` or absolute and at least two levels deep,
  without `.` or `..` (`~`, `/` and `/opt` are refused, by the model and
  again by the deployer). Old versions on the host are not removed in v1.
- **Not persistent**: another system or architecture, a directory that
  cannot be written, a helper that cannot run there, a home so long that
  `<dir>/run/a-<id>` would not fit a socket path, or a bundle without that
  platform's binary throw `BackendError.notPersistent(reason:)`. A *create*
  then falls back to a plain `ssh -tt <host> -- <session script>` in the
  pane (not `EphemeralBackend`, which is local): the handle carries a
  `persistenceNote`, the tab's host badge turns orange with that note, and
  the window subtitle shows the existing "Sessions won’t survive quitting"
  warning. Such a session records no runtime version, so after a relaunch it
  is shown as ended at once.
- **Interactive attach**: `ssh -tt … -- <dest> "exec /bin/sh -c 'unset
  ZMX_SESSION ZMX_SESSION_PREFIX; exec env ZMX_DIR=<dir>/run
  ZMX_NO_DETACH_KEY=1 <dir>/bin/zmx-<ver> attach a-<id> <program…>'"`,
  spawned on the pane's PTY through `ctty-exec` with argv[0] `ssh`, exactly
  like a local client, so resizes reach it and prompts appear in the pane.
  The attach-only sentinel is `true` (from the host's `PATH`). The program a
  create starts is `/bin/sh -c <script>`: unset `ZMX_*`, `cd` to the
  working directory (checked with `test -d` before the create; home if it
  is missing), export `TERM`, `COLORTERM`, `TERM_PROGRAM(_VERSION)`,
  `ARMADALE_SESSION_ID`, `LANG=C.UTF-8` if unset and the profile's
  variables, then `exec "$SHELL" -l`, or `exec "$SHELL" -l -c 'exec
  <program> <args…>'` for a profile with a program, as locally (`-c`
  without `-l` for csh and tcsh). Output over
  ssh may start with text that is not zmx's (an ssh warning, a noisy remote
  rc file), so the remote classification skips whole lines: zmx's output is
  only looked for at the start of the stream or of a line, and an attach is
  only zmx's full `ESC[2J ESC[H` there (verified: zmx writes exactly that,
  after `session "…" created\r\n` for a new session), never an `ESC[2J` in
  the middle of other text. User-visible failures never quote the helper's
  own output (which names its paths); it goes to the log. The flood mitigation of section 7 does not apply:
  the local process is ssh, which does not grow; the backlog builds up in
  the zmx client on the host, out of reach.
- **Prompts**: when a BatchMode control command fails for a reason a
  prompt might fix (an unknown host key; "Permission denied", which is also
  what a key locked by a passphrase gives), the backend starts an
  interactive `ssh -tt … -- <dest> exit 0` on the pane's PTY and watches
  its output for up to 10 s. Only a real question (`password:`,
  `passphrase`, "Are you sure you want to continue connecting", `(yes/no`,
  a verification code) starts a sign-in: the backend returns a
  `SignInClient`, the user answers in the pane, the sign-in becomes the
  master and stays up (`ControlPersist`), and the session is deployed,
  created or attached over it, with the same handle carrying on as that
  client (output relayed on demand, so backpressure still holds). The user
  has 120 s; then the sign-in is ended. A sign-in that fails (a wrong
  password), times out or is abandoned ends the handle with a
  `connectionFailure`: the controller shows ssh's last line as
  Disconnected, does not ask whether the session exists and does **not**
  retry by itself. An interactive ssh that asks nothing (a rejected key)
  and a refusal (a changed host key: no interactive ssh is even started)
  are `BackendError.authenticationFailed`: Disconnected with ssh's message,
  Reconnect Now, no automatic retries. Test Connection in Settings cannot
  answer prompts and says to open a tab.
- **Exit resolution** is the local rule: when a client goes away the
  backend asks `exists` (an `ls` over ssh). Only a host that answers
  without the session ends it; an unreachable host means `.detached`.
- **Disconnected and reconnect.** A create or attach that cannot reach the
  host throws `BackendError.unreachable(message)`; the controller shows
  Disconnected with ssh's message and does not ask `exists` (it would
  only time out again). Remote controllers have a `ReconnectSchedule`
  (pure, tested): retries after 1 s, 2 s, 4 s, 8 s, 16 s and then every
  30 s, no attempt starting more than 5 minutes after the loss (13
  attempts). Retries are quiet: the pane keeps the placeholder, titled
  **Reconnecting…** with a spinner, ssh's message, **Close Pane** and
  **Reconnect Now**; the glyph stays ⚠ disconnected. Reconnect Now stops
  the loop and tries at once, after waiting for an attempt that is still
  under way (never two connects at once); if it fails as unreachable the
  schedule starts over. Close and Respawn stop it, and so does closing the
  pane's window (retries resume when it is opened again). Authentication
  failures are never retried by themselves (above). An ssh client that exits
  255 before zmx showed anything is unreachable, not a runtime failure.
  When the budget runs out the pane is plain
  Disconnected with Reconnect. A create that never reached the host is
  retried as a create (nothing was created); everything else as an attach.
  A dropped ssh client with the host still reachable (e.g. `pkill -f 'ssh
  -tt'`) is resolved as detached and reattached at once, to the same shell.
- **Sessions on hosts in the app** (`SessionRegistry`): one
  `RemoteZmxBackend` per host, made on first use and replaced when the
  host's settings change. Every controller of that host switches to the new
  one at once; an attached client keeps its working connection, and its
  next reattach, Reconnect or retry uses the new settings. At launch each host referenced by a restored session is probed
  (`ls --short`) in the background; until it answers its sessions show as
  starting, never ended, and attaching them waits for that answer only. A
  host that does not answer leaves them attaching → disconnected →
  retried. Respawn All Ended lists each host again first and leaves every
  session on a host that does not answer alone. Remote orphans are not
  reclaimed (several Macs may share a host's `~/.armadale`). Closing a pane
  on an unreachable host kills nothing on the host; the session stays
  there until its program exits.
- **Removed hosts**: a removed host's sessions stay in their panes and are
  unavailable, with a "Host removed" placeholder (Close Pane only; closing
  asks first and leaves the session running on the host), never killed.
  An attached pane is hung up at once (the session keeps running on the
  host) and its controller gets an `UnavailableBackend`, which refuses to
  create or attach and whose kill does nothing, so a later close ends
  nothing on the host.

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
  stdout, stderr)` and a timeout. Since step 6 it can feed stdin from a
  pipe (uploads), with `F_SETNOSIGPIPE` so a command that exits early
  cannot kill the app.
- `SessionController` (`@MainActor`) is the per‑session glue: owns the
  surface, the `ProcessHandle`, the state machine, and forwards title / cwd
  / bell / notifications through a delegate (the registry, which records
  them in `AppModel` and, since step 7, passes bells and notifications to
  the app's `AttentionCenter`; attention is kept there, per session, not in
  the controller, so it outlives views and needs the app's focus). An optional
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
├── WorkspaceActions                                    select / create / close
│   └── InlineRename (@Observable)                      (confirmed) / drops; the
│                                                       window's one inline rename
└── NSSplitViewController
    ├── Sidebar: NSHostingController<SidebarView>       SwiftUI List, drag & drop
    └── Content: ContentViewController
        ├── TabBarHostingView<TabBarView>              SwiftUI, ⌘N badges, "+"
        └── PaneContainerView (NSView)                 or an empty-group state
            └── SplitTreeView (nested PaneSplitViews mirroring PaneLayout)
                └── PaneView per leaf
                    ├── surface.view                   terminal
                    ├── NSHostingView<PlaceholderView> Session Ended / Disconnected
                    └── focus overlay                  focus border, no hit testing
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
  accent border (only while more than one pane is on screen). Unfocused
  panes keep their terminal's own background: the dimming overlay of
  steps 2 to 9 was dropped on October 23, 2026 at the owner's request.
- The tab bar is custom SwiftUI (not `NSTabView`): it needs shortcut badges,
  status glyphs, drag reordering, and dragging a tab onto a sidebar tab group
  to move it. Tabs share the width (110–220 pt) and scroll when they do not
  fit; each shows its status glyph, title (custom, else session title, else
  profile name), a split/zoom hint, and ⌘1…⌘8 badges (⌘9 on the last tab),
  which turn into a close button on hover. Click selects; dropping a tab on
  another takes its position (from any group or window); middle click
  (handled by the hosting view, SwiftUI has no gesture for it) and the close
  button close it with the ⌘W confirmation; double-click or the context
  menu's Rename Tab edits the title in place; the context menu also has
  Close Tab, Close Other Tabs.
- *Inline rename.* The editing state is `InlineRename`
  (`Windows/InlineRename.swift`, `@Observable`), one per window, owned by
  its `WorkspaceActions` (`actions.rename`): that is already the one object
  per window that the sidebar, the tab bar and the window controller share,
  and committing applies `AppModel` intents (`renameWorkspace`,
  `renameTabGroup`, `renameTab`) like its other operations. Its `edit`
  names the item and the surface it is edited on (sidebar or tab bar), so a
  tab being renamed in the tab bar is not also a field in the sidebar; both
  views read `edit(of:on:)` and show a field instead of the title for the
  matching row or tab. `text` is written by the field as the user types and
  is not observed (no redraw per keystroke). Each edit has an id, and a
  field can only end the edit it was created for, so a field going away
  late never ends a newer edit; asking again for the edit under way keeps
  it (a double click inside the field). The commit rules are section 1's
  and are unit-tested. `WorkspaceActions.beginRename(_:on:)` starts an
  edit; from the sidebar, an item of another workspace whose window is now
  key is handed to that window's `InlineRename` (the first click of the
  double click brought it forward; this hand-off is not unit-tested, as
  it needs a key window), and the sidebar expands the workspace and tab
  group containing the row being edited. Keyboard focus after an edit
  goes to `returnFocus`: what had it when the first field of a chain of
  edits appeared (an edit started while another is open keeps it; a fresh
  edit forgets it; a rename field, its field editor or the window is never
  recorded), else, when that is gone or in another window, to the
  window's focused terminal (`focusFallback`, set by the window
  controller). `AppDelegate.applicationShouldTerminate` commits every
  window's open edit before the state is saved, on every quit path.
  The field is `InlineRenameField` (`Support/InlineRenameField.swift`), an
  `NSViewRepresentable` over a borderless `NSTextField`, chosen over a
  SwiftUI `TextField` so that each way an edit ends is explicit on macOS:
  Return (`insertNewline:`) and Escape (`cancelOperation:`) are taken in
  the delegate's `control(_:textView:doCommandBy:)` before the field editor
  acts on them; `controlTextDidEndEditing` (a click elsewhere, Tab) commits;
  the window's did-resign-key notification commits too, since the field
  keeps first responder in a window that is no longer key; a mouse down
  anywhere in the tab bar outside the field commits too
  (`TabBarHostingView.mouseDown`: the bar never takes keyboard focus, so
  the field would not notice that click). Whenever SwiftUI tears a field
  down (its row deleted, or whenever `List` discards it), the teardown only
  does bookkeeping; on the next turn of the main actor the edit is
  committed unless another field has registered for it by then (SwiftUI
  can recreate a field mid-edit, which must not end the edit), and focus
  left on the window itself is put back as below. So no model change
  happens inside SwiftUI's view update; for the same reason the commit
  from `controlTextDidEndEditing` runs on the next turn, and only if the
  field is still in its window. After Return, Escape or resign-key,
  keyboard focus goes back (see `returnFocus` above; the terminal, or the
  sidebar's list); after a click elsewhere it stays where the click put
  it. Names are taken literally: the field has its own field editor
  (`RenameTextFieldCell.fieldEditor(for:)`) with text replacement,
  spelling correction, completion, quote and dash substitution and all
  text checking (data detection, the double-space period) turned off, so
  the window's shared field editor is never changed; should AppKit hand
  the field the shared one anyway, the same settings are turned off for
  the edit and put back when it ends. The window's delegate
  (`windowWillReturnFieldEditor`) hands out the private editor for a
  rename field too, and `controlTextDidBeginEditing` logs (debug level,
  subsystem `com.tinylittleapps.armadale`, category `rename`) which editor
  an edit uses. The system's period-on-double-space substitution is
  intercepted in the private editor (`RenameFieldEditor.insertText`, which
  puts back the space it would replace), because the text view's flags do
  not stop it. The field takes keyboard focus
  with its text selected on the turn after it enters the window (SwiftUI
  has laid it out by then). Its font is the title's SwiftUI font resolved
  in its environment (`Font.resolve(in:)`, `ctFont`): body, semibold where
  the title is, and 12 pt in the tab bar. While a row or tab is being
  edited it is not `draggable` (dragging in the field selects text). In
  the sidebar the double click is the `List`'s `primaryAction`, so a single
  click selects exactly as before; in the tab bar it is a
  `TapGesture(count: 2)` added as a `simultaneousGesture`, so the single
  click's select is not delayed waiting for a second click.
- *Attention (step 7).* An app-level `AttentionCenter`
  (`Sessions/AttentionCenter.swift`, `@Observable`) owns the pure
  `AttentionTracker` (section 10). The registry forwards every bell and
  notification sequence to it; the tab bar, the sidebar and the Dock badge
  read it. The app delegate keeps its `isAppActive` (application
  did-become/resign-active) and `keyWorkspaceID` (window did-become/
  resign-key, mapped to the window's workspace; nil for Settings or no
  window) current. The tab bar tints a tab needing attention (purple fill
  and border) and shows ◐; the sidebar shows ◐ and a semibold title on the
  tab row and a purple count capsule (`AttentionCount`) on the tab group and
  workspace rows. The Dock badge (`NSApp.dockTile.badgeLabel`) is the total,
  nil when zero (`AttentionBadge.label`). Window titles are unchanged.
  Notifications go through `NotificationService` (`UserNotificationService`
  in the app, a fake in tests); the app delegate is the
  `UNUserNotificationCenterDelegate`, set in
  `applicationWillFinishLaunching` (no permission is asked then): a click
  reveals the session from `userInfo["armadale.sessionID"]`
  (`AttentionCenter.reveal`: select its group and tab, focus its pane, bring
  its window forward, opening it if closed), or only activates the app if
  the session is gone; banners also show while Armadale is active (the pane
  is elsewhere), unless the session is looked at by the time the banner
  would appear (`willPresent` asks `AttentionCenter.shouldPresent`). When a
  session's attention clears (looked at, Clear All, closed), its delivered
  notification is removed. A sheet (a close or delete confirmation) takes
  key status from its window; the key workspace is resolved through `sheetParent`
  (`AppDelegate.sheetOwner(of:)`), so the focused pane under a sheet is
  still looked at.
- Settings is an `NSWindowController` hosting SwiftUI tabs:
  **General** (default profile, default directory, notifications (step
  7), confirm‑on‑close),
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
    the `AppModel` intents. *Step 7:* a Claude Code or Codex profile has an
    **Attention** section. For Claude Code it is the toggle "Signal
    attention when Claude Code needs input (sets the notification channel
    for this session)" (`attentionIntegration`, editable on the built-in
    too) with text saying plainly that it overrides the user's own
    `preferredNotifChannel`, `notifications_disabled` included, for
    sessions started from that profile, and that turning it off keeps their
    own. For Codex it says no arguments are needed and why. **Configure…**
    opens a sheet with the exact optional settings to add to the agent's own
    file (the Claude `Stop` hook; Codex's `notify` and
    `tui.notification_method = "osc9"`), pointing at the bundled helper,
    with Copy. Armadale never edits those files.
  - General › Notifications (step 7): "Notify when an unfocused pane needs
    attention" (`notifyOnAttention`, default on), "Only for agent profiles"
    (`notifyOnlyForAgents`, default on), "Play sound"
    (`notificationPlaysSound`, default off). File › New Tab with Profile and the tab bar's
    "+" context menu open a tab with any profile.
  - **Hosts** (step 6, `Settings/HostsSettingsView.swift`): a list with
    add / remove and an editor like Profiles: name, destination (`user@host`
    or an alias; a blank or `-`-prefixed one is flagged), port, identity
    file and SSH config file (each with Choose…, an open panel showing
    hidden files from `~/.ssh`), remote folder. **Test Connection** runs
    `uname -sm` through the transport and reports the platform and whether
    the persistence helper is installed (or ssh's error); **Deploy Now**
    uploads and verifies it even if it is there. Edits are saved when a
    field's editing ends (focus leaves it, Return, Choose…), before Test
    Connection or Deploy Now, and when the tab closes, never per keystroke,
    so a half-typed destination never reaches the sessions. Removing a host that
    sessions run on asks first; those sessions become unavailable, never
    killed. Nothing user-visible names the runtime: it is "the persistence
    helper". Hosts are saved with the layout (`state.json`).
  - **New sessions on hosts**: File › New Tab on Host (filled when it
    opens: one item per host, "No Hosts", Add Host… which opens Settings ›
    Hosts) and a "On Host" section in the tab bar "+" context menu create a
    remote tab in the selected tab group with the default profile in the
    host's home directory (`~`). Splitting a remote pane stays on its host.
    Remote tabs carry a small host badge (a network glyph; with the host's
    name in the sidebar; orange when not persistent). The window subtitle
    is unchanged by remote tabs, except that it shows the existing
    "Sessions won’t survive quitting" warning while one of the workspace's
    sessions is a non-persistent fallback (section 6). Remote sessions
    restore on relaunch like local ones.
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
- A plain quit never kills sessions (with sessions running, the quit asks
  first; see "Quitting with running sessions" below; only *End Sessions
  and Quit* ends them). `applicationShouldTerminate` hangs every
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
- **Full screen.** A full-screen frame is never recorded: while the window
  is in full screen, or entering or leaving it, the recorded frame stays
  the normal one (the frame from just before full screen, else the last
  saved one; `WindowGeometry.recordedFrame`), and `WindowState.isFullScreen`
  (default false; state saved before it decodes as false) records the
  state the window is in or going to. Entering and leaving full screen
  each save once the transition ends, so leaving it records the normal
  frame again. At launch a window that was in full screen opens at its
  normal frame and is shown, its visible sessions start at that size
  (after layout, as always), and then, from the default run-loop mode (so
  after any launch alert is dismissed), it enters full screen. Several
  such windows enter one after another, each when the previous one's
  transition ends (one queue, also used on return from menu bar mode;
  two toggles in the same turn leave the second window normal); each
  becomes its own Space. From being queued until its entry starts a
  window reports `isFullScreen` true, so a quit before then (under a
  launch alert, say) keeps the flag although showing the window at its
  normal frame reports a move. Entering full screen
  resizes the panes once (one SIGWINCH; a resize while a client is
  still connecting is applied when it attaches). Measured October 20,
  2026 on a 3200×1800-point display: relaunched in full screen with the
  pane attached and `stty size` reporting 121×420, the full-screen grid.
  A window reopened later (from the sidebar) after being closed in full
  screen opens as a normal window, and is recorded so.
- **Closing in full screen.** AppKit sends `windowWillClose` while the
  window is still in full screen and only then `windowWillExitFullScreen`,
  a resize and `windowDidExitFullScreen` (the window no longer visible).
  So a controller reports nothing after `windowWillClose` (its
  `isOpen: false` report is the last), and the app delegate ignores
  reports from a controller that is no longer the workspace's.
- **Saved frames and screens.** A saved frame whose title bar (the top
  40 pt of the frame) overlaps any screen's visible frame is applied as
  saved: Armadale does not constrain it. AppKit still does, when the
  window is shown: with the default separate Spaces per display, a
  frame spanning the built-in display and an external one came back
  entirely on the built-in one (x −600 became −1100), and one half off
  an external display's right edge was moved fully onto it (x 2650
  became 2100); a window cannot be made to span displays by restoring
  its frame. One whose title bar is on no screen but which still
  overlaps one is constrained by Armadale (`constrainFrameRect(_:to:)`)
  to the screen it overlaps most, which brings the title bar on screen
  (y 1500 became 1070) and fits an oversized frame (4000×2500) to the
  visible area. One that overlaps no screen that still exists (a
  disconnected display) opens like a window without a saved frame: the
  default size, centred (and cascaded when reopened from another
  window). `WindowGeometry.placement` makes the decision; it is
  unit-tested. An old state file holding a screen-sized frame (saved in
  full screen before this rule) still opens as a screen-sized normal
  window fitted to the visible area; it is not healed. A miniaturized
  window needs nothing: AppKit keeps its normal frame, and minimizing
  reports no move or resize.
- Reboot or daemon loss simply yields panes in the ended state on next
  launch, with "Respawn All Ended" one click away.

### Quitting with running sessions: menu bar mode (step 8)

Background (section 13, "macOS 27 background attribution"): any process
that originates from Armadale and outlives it makes the Dock show
Armadale as "Running in Background", prompts the user once to allow or
disallow it, and offers a Dock menu item that SIGTERMs every such
process at once. Nothing a child does after spawn escapes this. What
does escape it is a visible presence: an app that stays running with a
status item is not in the Dock at all, and a quit from that state leaves
no Dock item either (verified October 19, 2026 with the prototype that
preceded this step). So Armadale does not quit silently with sessions
running; it asks, and the "keep running" answer keeps the app alive in
the menu bar.

- **The question.** `applicationShouldTerminate` counts sessions that
  may still have a process (status running, pending, disconnected or
  attention; ended and unavailable do not count). With none, quit
  proceeds as before (detach every client, `.terminateNow`, save). With
  some, and the preference set to *Ask*, an app-modal alert: "N sessions
  are still running" (singular for one), informative text explaining
  that Armadale can keep them running from the menu bar, where it can be
  reopened or the sessions ended later, and that ending them stops every
  program running in them. Buttons: **Keep Running in Menu Bar**
  (default), **End Sessions and Quit** (destructive), **Cancel**. The
  alert never offers a plain quit that leaves sessions behind: that is
  the path where the Dock's "Stop Running in Background" ends them all.
- **Preference.** Settings › General, "When quitting with running
  sessions": *Ask* (default), *Keep running in the menu bar*, *End
  sessions*. The alert has no "don't ask again" checkbox; the setting is the
  only way to skip it. Stored in `Preferences` with the other settings.
- **SIGTERM** (logout, `pkill -x Armadale`) never asks and never stays:
  it quits as before, sessions kept, within the two seconds
  `scripts/check-quit.sh` checks. The handler sets a flag before calling
  `terminate`.
- **Menu bar mode.** Every workspace window is ordered out (not closed:
  the workspaces stay "open" for the next launch and their controllers
  stay alive), the Settings window too; the activation policy becomes
  `.accessory`, so the Dock icon and the main menu go away; a status item
  appears. Panes stay attached (output keeps flowing into their
  surfaces, attention keeps being tracked). Each window's recorded state
  is frozen when it is hidden and reported unchanged until it is shown
  again, so a quit from menu bar mode saves what was on screen. A
  full-screen window first leaves full screen and is ordered out when
  that ends; shown again, it is queued to re-enter full screen, one
  window after another as at launch. Found October 20,
  2026: a full-screen window ordered out and shown again does come back
  in full screen, but its title bar and toolbar do not (AppKit's
  full-screen toolbar window comes back zero-sized), so it is taken out
  of full screen first. The saved frame and flag were sane either way. The status item shows the
  app icon's three-pane glyph as a template image, generated by
  `scripts/render-app-icon.swift` into the asset catalog as a
  `StatusItem` image set (18 pt, 1x and 2x), with the attention count as
  text next to it when it is non-zero. Its menu: "N sessions running"
  (disabled), then **Open Armadale**, **Settings…**, a separator,
  **Quit, Keep Sessions Running**, **End Sessions and Quit**. Attention
  notifications still post, and clicking one reopens the app on that
  session. Reopening (the status item, a notification, `open -a`,
  Finder, `applicationShouldHandleReopen`) restores the regular policy,
  removes the status item and shows the windows again, activating the
  app. Attention counts while in menu bar mode are not lost: the Dock
  badge resumes on return.
- **Quit, Keep Sessions Running** is a plain quit from accessory mode:
  clients detached, sessions alive, state saved. The Dock shows nothing
  afterwards (no tile to decorate). Whether launchd lists the daemons
  under Background App Activity in System Settings is not known.
  **The sessions survive only while Armadale is allowed to run in the
  background** (System Settings › General › Login Items & Extensions ›
  Allow in the Background, the decision the first-quit prompt records).
  Tested October 19, 2026: with Armadale switched off there,
  `loginwindow` asks Background Task Management when the app exits,
  is told no, and force-quits the app's coalition, which SIGTERMs
  every daemon and shell: 5 s after a quit from menu bar mode (the
  exited accessory app counts as "never user-visible"), 1 s after a
  regular quit such as SIGTERM. No prompt appeared for an accessory-mode
  quit, switched on or off (a Mac with no stored decision was not
  tested). Switched on, nothing is touched. The app has no
  way to read that setting, so the status menu's promise holds only
  under Allow; what to say about it is an open point (section 13,
  `HANDOFF.md`).
- **End Sessions and Quit** ends every session that may be alive, then
  quits: shown panes through their controllers (`close()`), the rest
  through their backends (`kill`); unavailable sessions cannot be
  reached and are left. The quit is cancelled while this runs
  (`.terminateCancel`), then `terminate` is called again with a flag
  that skips the question; `.terminateLater` is still not used (the
  SIGTERM deadlock above). The kills run concurrently, so the wait is
  the longest single kill: about 10 s at most for a local session (the
  helper's command timeout), about 10 s for an unreachable host (ssh's
  `ConnectTimeout`; the kill fails and nothing else is tried), and up to
  about 60 s for a host that connects but stalls (30 s for the kill, 30 s
  for removing its log). The alert's text does not promise more.
- **Window close** is unchanged: closing the last window keeps the app
  running with its Dock icon (`applicationShouldTerminateAfterLastWindowClosed`
  is false); only quit enters menu bar mode.

*Implementation (step 8):* `App/MenuBarMode.swift` holds the pure rule,
`QuitDecision.decide(running:preference:context:)` → *quit now*, *ask*,
*keep in menu bar*, *end sessions* or *cancel*, the wording
(`MenuBarText`) and the status item (`MenuBarStatusItem`);
`AppDelegate.applicationShouldTerminate` acts on the decision.
`Preferences.quitWithRunningSessions` (key `quitWithRunningSessions`,
values `ask` / `keepInMenuBar` / `endSessions`, anything else reads as
`ask`) backs the General picker. Where it differs from or adds to the
above:

- **What counts as running** is the close-confirmation rule
  (`CloseRisk.mayBeRunning`, `SessionRegistry.runningSessionCount()`), not
  the bare status list: a *pending* session counts only if it may exist
  (restored from the last run, or a start was attempted). A tab created in
  this run and never shown has no process and is not counted. Remote
  sessions count as well, although after a quit they leave no local
  process (the Dock never shows them): the question is about sessions,
  not about the Dock.
- **Forced quits** skip the question: SIGTERM, a launch that cannot go on
  (the fatal state-file alert), and a quit Apple event that carries a
  reason (`kAEQuitReason`: log out, restart, shut down; logout sends this
  event before any signal, and an alert there would hold logout up).
  ⌘Q has no Apple event; the Dock's Quit and AppleScript's `quit` send one
  without a reason, so they ask (`AppDelegate.isSystemQuit`).
- **A quit while in menu bar mode** is a plain quit that keeps the
  sessions, whatever the preference: the status menu's *Quit, Keep
  Sessions Running*, and ⌘Q with the Settings window in front (an
  accessory app still handles key equivalents).
- **While End Sessions and Quit runs**, every other quit is cancelled
  (*cancel*) except a forced one. The kills run in one task group
  (controllers' `close()` and backend kills), so the wait is the bound
  given above (about 10 s local or unreachable, about 60 s for a stalled
  host). In menu bar mode the status menu's count line reads "Ending
  sessions…" and every item is disabled meanwhile; on the alert path the
  windows stay up, their panes showing *Session Ended* as each finishes.
  Before the final quit the running sessions are counted again
  (`SessionRegistry.sessionsRunning(after:)`): a session the pass did not
  cover (a tab opened meanwhile) or one whose pane runs again (a Respawn)
  gets one more pass, then the app quits regardless. A relaunch
  afterwards shows the ended panes, as after a reboot.
- **Showing a workspace window leaves menu bar mode** (`openWindow` calls
  `leaveMenuBarMode()`), so every path back is covered: *Open Armadale*,
  `applicationShouldHandleReopen` (`open -a`, Finder), a notification click
  (revealing its pane opens the window; with no pane left it reopens the
  app), and ⌘N or ⌃⌘A pressed in the Settings window. Leaving restores the
  regular policy, removes the status item, shows every hidden window, and
  sets the Dock badge again from `AttentionCenter.total`.
- **Activation.** The alert calls `NSApp.activate()` so a quit sent from
  the Dock or a script brings it forward, and *Settings…* and *Open
  Armadale* activate the app. With a real click on the status menu both
  do (verified in review: `NSWorkspace.frontmostApplication` became
  Armadale). Two testing artefacts look otherwise and are not app
  behaviour: System Events' `frontmost` reports false for an accessory
  app even while it is active, and items pressed through accessibility
  (AX) carry no user click, so macOS may decline the activation they ask
  for (cooperative activation, macOS 14 and later).
- **Closing Settings in menu bar mode** (⌘W, the close button) would
  leave an active accessory app with no window, so keystrokes would go
  nowhere: once the close is done the app hides (`NSApp.hide`), which
  gives the previously active app its menu bar and keyboard back.
  `NSApp.deactivate()` was tried first and does not: the accessory app
  stayed the frontmost application. The status item stays while hidden,
  and every way back (`leaveMenuBarMode()`, *Settings…*) unhides.
- **Status item glyph**: the lit pane solid, the two idle panes as 1 pt
  outlines, so the lit one stands out in one colour; the panes' bounding
  box is 16 pt inside the 18 pt image, edges snapped to each scale's pixel
  grid (`StatusItem.imageset`, `status_item.png` and `status_item@2x.png`).
  The menu has no separator under the count line, as listed above. The
  button's tooltip names the attention count when there is one.
- **Persistence unavailable** (the fallback runtime): the question is
  still asked, and *Keep Running in Menu Bar* does keep local sessions
  alive (the app keeps running), but any quit ends them then. The status
  menu therefore omits *Quit, Keep Sessions Running* while the runtime is
  not persistent (checked each time the menu opens); *End Sessions and
  Quit* stays.
- Settings › General is 520 pt tall (was 330, which already scrolled the
  last section out of view).

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
| ⌃⌘A ✱ | Next pane needing attention (step 7) |
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
without a default key: Close Tab, Close Tab Group, Delete Workspace, and
(step 7) Window › Clear All Attention. (Renaming is inline, in the sidebar
and the tab bar, and has no menu command.)

*Step 7:* Window › Next Pane Needing Attention is ⌃⌘A. It is free in this
table, in Ghostty's macOS defaults (checked against `src/config/Config.zig`:
Ghostty binds ⌃⌘ only with arrows, `=`, `f`, `[`, `]` and ⇧⌃⌘J) and in
macOS's own shortcuts. It goes to the next session needing attention after
the key window's focused pane, in sidebar order across every workspace,
wrapping around: its window comes forward (opened if closed), its tab group
and tab are selected and its pane focused, which clears it. Disabled when
nothing needs attention.

---

## 10. Agent sessions

A pane is "just a shell" by default. The agent profiles only add:

- a launch program (`claude`, `codex`) and arguments; the resolved
  `LaunchSpec` is stored on the session, and a respawn takes the profile
  as it is then (falling back to the stored launch if the profile is gone);
- an **attention** rule: a bell (BEL) or an OSC 9 / OSC 777 notification in
  an unfocused pane sets the tab's attention state, shows a badge on the Dock
  icon count, and optionally posts a `UNUserNotification`.
- The sidebar's "running / ended / attention" glyphs make a dozen agents
  scannable at a glance.

Richer status (idle vs. working vs. waiting for approval) would need
agent‑specific hooks and is explicitly left out of v1; the profile model has
room for it.

### Step 7: what was built

**Attention rule** (`AttentionTracker` in `ArmadaleCore/Attention.swift`,
pure, unit-tested). A session is *looked at* exactly when Armadale is the
active app **and** the session is in the focused pane of the selected tab
of the key window's workspace (`AttentionFocus`). A signal from a session
that is looked at does nothing; from any other session (another pane of the
same tab, another tab, another window, any window while the app is in the
background, any pane while Settings is key) it sets attention. Signals are
BEL and the desktop notification sequences OSC 9 (`9;body`, except `9;4;…`
progress) and OSC 777 (`777;notify;title;body`), as parsed by the surface;
title changes (OSC 0/2) are not signals. Being looked at clears it (the app
coming back with that pane focused, a tab switch to it, a click into the
pane, a notification click, Next Pane Needing Attention). Attention lives
in memory for the app's lifetime: it survives tab switches and closing and
reopening windows, is not saved, and is forgotten synchronously when its
session leaves the model (closed, or retired by a respawn;
`AppModel.onSessionsRemoved`), so no count or badge can stick; a signal from
a session no longer in the model (a bell still in flight from a closed
pane) is ignored. Window › Clear All Attention clears everything. Counts are sessions (panes), per tab group, per
workspace and in total (the Dock badge).

SwiftTerm delivers bells and titles to the main thread through its event
queue and lets at most one bell through per 100 ms per view; OSC 9/777 are
observed passively and hop to the main actor. None of this depends on the
pane being on screen.

**Notifications** (`NotificationService`, `UserNotificationService`,
`NotificationPolicy`). A signal that sets attention may post a notification:
only when "Notify when an unfocused pane needs attention" is on, only for
sessions whose profile is `.agent` while "Only for agent profiles" is on,
and at most one per session per 2 s (later signals in that window are
dropped; each session's notification also replaces its previous one in
Notification Center). Title: the OSC 777 title when the program gave one,
else the session's title, else its profile's name. Subtitle: "Workspace /
Tab group". Body: the OSC body, else "Finished" (a bell, or no text).
"Play sound" adds the default sound. Permission (alert, sound, badge) is
requested the first time in a run that a session needs attention (once per
run, whatever the notification settings, because the Dock badge needs it),
or when a notification would be posted; never at launch. A denied
permission drops notifications (logged once). A banner is not presented if
the session is looked at by the time it would appear, and a session's
delivered notification is removed when its attention clears. On macOS 27 an app registered with UserNotifications only
shows its Dock badge while its "Badge application icon" setting is on, so
the badge needs that permission too; it is set again when permission
arrives. (Verified live: a plain process's `NSDockTile` badge shows without
any permission; Armadale's did not until the setting was on.) A
notification prompt that is still on screen when the app quits is withdrawn
by macOS and counts as a denial; turning notifications on later is done in
System Settings › Notifications › Armadale.

### What the agents offer (researched, not assumed)

**Claude Code 2.1.292** (sources: `claude --help`; the shipped bundle's
JavaScript read with `strings` from
`/opt/homebrew/Caskroom/claude-code/2.1.292/claude`; the docs at
code.claude.com/docs/en/terminal-config ("Get a terminal bell or
notification"), /settings (precedence: managed, then command line
`--settings`, then local, project, user) and /settings-reference
(`preferredNotifChannel`)):

- Terminal notifications go through the setting `preferredNotifChannel`:
  `auto` (default), `iterm2` (OSC 9 with "title: message"),
  `iterm2_with_bell`, `kitty` (OSC 99), `ghostty` (OSC 777
  `notify;<title>;<message>`, title "Claude Code"), `terminal_bell` (BEL),
  `notifications_disabled`. `auto` picks a method only when `TERM_PROGRAM`
  is Apple_Terminal (bell, if that profile's bell is off), iTerm.app, kitty
  or ghostty; in any other terminal, Armadale included, it sends nothing.
- It notifies when it has waited for input for `messageIdleNotifThresholdMs`
  (60 000 ms by default; a key of the global config `~/.claude.json`, with
  no command-line form), on permission prompts (after a short delay), and on
  sign-in and usage-limit events. There is no terminal signal the moment a
  turn ends.
- `--settings <file-or-json>` loads settings for one session, above the
  user's own files (below managed settings), and `preferredNotifChannel` is
  read from it. **A Claude Code profile with "Signal attention when Claude
  Code needs input" on (the default, also for the built-in;
  `Profile.attentionIntegration`) is started with
  `--settings {"preferredNotifChannel":"ghostty"}`** in front of its own
  arguments; no user file is touched. This overrides the user's own channel
  for sessions started from that profile, `notifications_disabled`
  included; turning the toggle off (Settings › Profiles) keeps theirs.
- Hooks (`hooks.Stop`, `hooks.Notification`, … in settings) run commands;
  `Stop` fires when Claude finishes responding. Verified live: Claude Code
  runs hook commands in a session of their own **without a controlling
  terminal** (`/dev/tty`: "Device not configured"), while `claude` itself
  is on the pane's terminal. The helper below handles that.

**Codex 0.163.0** (sources: `codex --help` (`-c key=value` overrides
`config.toml` with TOML values); the binary's strings; the source at tag
`rust-v0.163.0`: `codex-rs/config/src/types.rs` (`Notifications` defaults
to enabled, `NotificationMethod` `auto|osc9|bel` defaults to `auto`,
`NotificationCondition` `unfocused|always` defaults to `unfocused`),
`codex-rs/tui/src/notifications/{mod,osc9,bel}.rs`, `codex-rs/tui/src/tui.rs`;
the docs at learn.chatgpt.com/docs/config-file/config-advanced and
config-reference):

- The TUI notifies on turn completion (`agent-turn-complete`; the message
  is a preview of the response or "Agent turn complete") and on approval
  requests, plan-mode prompts and questions, while `tui.notifications` is
  on (the default: `codex-rs/config/src/types.rs` 715–719).
- **The built-in profile passes nothing, and needs nothing.** What the
  defaults do in Armadale, from the source at `rust-v0.163.0`:
  - Method: `TERM_PROGRAM=Armadale` is not a terminal Codex knows, so it is
    `TerminalName::Unknown` (`codex-rs/terminal-detection/src/lib.rs`
    257–261, 377 ff.); `auto` (`types.rs` 721–728) uses OSC 9 only for
    Ghostty, iTerm2, Kitty, Warp and WezTerm and otherwise **BEL**
    (`codex-rs/tui/src/notifications/mod.rs` 22–26, 53–61; `bel.rs` writes
    `\x07`).
  - Condition: `unfocused` by default (`types.rs` 742–746);
    `should_emit_notification` emits only when the terminal is not focused
    (`codex-rs/tui/src/tui.rs` 117–121, used by `Tui::notify` 1018–1020).
    The TUI starts out assuming focused (`tui.rs` 752), turns on focus
    reporting, DECSET 1004 (`EnableFocusChange`, `tui.rs` 262), and
    tracks `FocusGained` / `FocusLost` (`codex-rs/tui/src/tui/event_stream.rs`
    305–313).
  - Armadale **does** answer focus reporting: SwiftTerm (v1.99.0) reports
    the current state as soon as 1004 is set (`Terminal.swift`, case 1004
    of DECSET, ~6638: "Report the current state right away"), and again
    whenever its view becomes or stops being first responder, its window
    becomes or stops being key, or it moves to or out of a window
    (`Mac/MacTerminalView.swift` 973, 1016–1060, 1766–1780). Focused there
    means first responder in the key window, which is Armadale's "looked at"
    rule (a background app has no key window; a pane of another tab is out
    of the window). zmx replays `ESC[?1004h` to a reattaching client
    (checked with zmx 0.8.1: a session that had enabled it, attached again,
    received it in the replay), so this survives a relaunch.
  - So Codex rings BEL on turn completion and approval requests exactly
    when its pane is not looked at, which is when Armadale sets attention.
    (Not run against a real Codex turn, which would use the user's
    account; derived from the source above.)
- Command-line overrides (`-c tui.notification_method=…`) were tried and
  dropped: Codex 0.163.0 then runs "without the shared background server"
  (a warning on every launch, and no `codex agents` or remote control).
  `tui.notification_method = "osc9"` (the message text instead of a plain
  bell) is offered as an optional user setting in the Configure… sheet.
- `notify = ["program", …]` in `~/.codex/config.toml` runs a command with a
  JSON payload (`type`, `thread-id`, `turn-id`, `cwd`, `input-messages`,
  `last-assistant-message`) appended as the last argument, on
  `agent-turn-complete` only. It is a single command, so setting it on the
  command line would replace the user's own `notify` (this Mac's user has
  one for another tool): it is offered only as an optional hook.

### The notify helper and how to enable the hooks

`Contents/Resources/armadale-notify` (source `Armadale/Resources/`, POSIX
`sh`): `armadale-notify [--bell] [TITLE [BODY]]` writes
`ESC ] 777 ; notify ; TITLE ; BODY BEL` (or a BEL) to the pane's terminal:
`/dev/tty` if it has a controlling terminal, else the terminal device of its
nearest ancestor that has one (`ps -o tty=`; this is what makes it work
from Claude Code hooks). TITLE becomes the notification's title and BODY
its text. Inside tmux or screen running in a pane it writes to the
multiplexer's terminal, which swallows the sequence (tmux would need
passthrough and DCS wrapping), so it cannot reach the Armadale pane from
there; a bell rung inside tmux reaches it only if tmux passes bells on. Arguments starting with `{` (Codex's JSON payload)
are ignored; control characters are removed, and `;` in the title becomes
`,`; the body defaults to "Finished". It does nothing outside an Armadale
session (`TERM_PROGRAM` is not `Armadale` and `ARMADALE_SESSION_ID` is
unset), so a hook in global agent settings stays quiet in other terminals,
and it always exits 0. Tested on a real pseudo-terminal (`script`), also
with the helper detached into a session of its own (`setsid`), and live
from a Claude Code `SessionStart` hook passed with `--settings`.

The Profiles editor's **Configure…** shows the exact text with the
helper's real path. For an app in `/Applications`:

```json
// ~/.claude/settings.json: attention the moment Claude stops
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command",
  "command": "'/Applications/Armadale.app/Contents/Resources/armadale-notify' 'Claude Code' 'Finished'" } ] } ] } }
```

```toml
# ~/.codex/config.toml, optional. notify goes at the top, before any
# [table], and replaces any notify you already have.
notify = ["/Applications/Armadale.app/Contents/Resources/armadale-notify", "Codex", "Turn complete"]

# The message text instead of a plain bell (in your [tui] table).
[tui]
notification_method = "osc9"
```

Remote sessions get the same profile arguments (they work on any host);
the helper exists only on this Mac.

**Not supported:** tmux or screen inside a pane hide the helper's sequence
(above).

**Next Pane Needing Attention** (⌃⌘A) and **Clear All Attention** are in the
Window menu (section 9).

**Not built:** per-agent status beyond attention; changing the agents'
idle threshold; posting while the pane is looked at; a notification for a
session whose profile was deleted under "Only for agent profiles" (it is
not known to be an agent).

---

## 11. Repository layout

```
armadale/
├── project.yml                      XcodeGen spec
├── Armadale/                        app target (AppKit)
│   ├── App/                         main.swift, AppDelegate, menus, MenuBarMode (QuitDecision,
│   │                                MenuBarText, MenuBarStatusItem: quitting and menu bar mode)
│   ├── Windows/                     WorkspaceWindowController, WorkspaceActions (+ InlineRename),
│   │                                ContentViewController
│   ├── Sidebar/                     SidebarView (SwiftUI)
│   ├── Tabs/                        TabBarView, StatusGlyph, HostBadge (SwiftUI)
│   ├── Panes/                       PaneContainerView, SplitTreeView, PaneView, SessionPlaceholderView
│   ├── Sessions/                    SessionRegistry (controllers per session, a backend per host,
│   │                                RemoteSessionSupport), SessionStatus / CloseRisk,
│   │                                AttentionCenter (+ NotificationService, NotificationPolicy)
│   ├── Settings/                    SettingsWindowController, Preferences, ShortcutTable, SwiftUI tabs
│   │                                (General, Appearance, Profiles, Hosts, Shortcuts)
│   ├── Resources/                   AppIcon.icon (Icon Composer document), Assets.xcassets
│   │                                (AppIcon rasters, StatusItem template glyph), Info.plist,
│   │                                Armadale.entitlements,
│   │                                armadale-notify (helper for agent hooks → Contents/Resources)
│   └── Support/                     ThemeCatalog (built-in + user themes), AppSettings
│                                    (+ SurfaceRegistry.standard), HierarchyDragItem,
│                                    InlineRenameField, UserNotificationService;
│                                    the shortcut table's source is App/MainMenu
├── ArmadaleAppTests/                tests of the app target's code (unhosted)
├── Packages/
│   ├── ArmadaleCore/                model, PaneLayout ops, StateStore, migrations,
│   │                                AttentionTracker, AgentIntegration              (no AppKit)
│   ├── ArmadaleSessions/            PTYProcess, CommandRunner, ZmxSessionDriver (+ Local/RemoteZmxBackend),
│   │                                EphemeralBackend, SSHTransport, RemoteDeployer, ReconnectSchedule,
│   │                                SessionController, LaunchResolver, HelperLocator; Sources/ctty-exec
│   ├── TerminalSurface/             protocol, appearance types, SurfaceRegistry, GhosttyTheme parser
│   └── SwiftTermSurface/            SwiftTerm adapter (depends on SwiftTerm)
├── Vendor/zmx/                      fetched binaries (git‑ignored)
├── scripts/                         fetch-zmx.sh, zmx.lock, embed-zmx.sh, check-quit.sh,
│                                    render-app-icon.swift, release.sh, install-release.sh
├── docs/                            DESIGN.md, icon/AppIcon.svg (generated master vector)
├── AGENTS.md                        how to work in this repository (process, rules, test hosts)
└── HANDOFF.md                       where development stopped (status, next step, open items)
```

- `ArmadaleCore` and the layout operations are fully unit‑tested with Swift
  Testing and run in a few seconds without a UI.
- `ArmadaleAppTests` (step 4) tests the app target's own code: the split
  tree view with real SwiftTerm surfaces, the close-confirmation rule, and
  window controller lifetime; since step 5 also `Preferences` (each test
  in its own defaults suite, removed afterwards), `ThemeCatalog`, the
  shortcut table, settings reaching existing panes, the renderer switch
  and the Settings window; since step 7 the attention center (with a fake
  notification service), status precedence, notification policy, bells
  and OSC 9/777 fed to real surfaces reaching it, and the notify helper on
  a pseudo-terminal; since step 8 the quit decision, the running-session
  count, End Sessions against a recording backend, system quit events,
  the menu bar wording and the status menu's items. It is unhosted: it compiles the app's sources
  (all but `main.swift`) into the test bundle, so the app never launches, no
  window is shown, no state file is touched, and an inert backend starts no
  process.
- `ArmadaleSessions` has integration tests that spawn a real local zmx
  session, kill it, and assert the state machine. Since step 6 the remote
  backend is tested three ways: with a scripted `FakeTransport` (command
  lines, parsing, 255 → unreachable, exit resolution, deployment), with a
  `LoopbackTransport` that runs "remote" commands on this Mac with a
  private `HOME`, so deployment, create/attach, reconnecting to the same
  shell, the plain-ssh fallback and the interactive sign-in run against the
  real zmx without a network, and against a real host when
  `ARMADALE_TEST_SSH_HOST` is set (README).
- No hosted CI: GitHub Actions is disabled for this repository. The full
  build and test command is run locally before every commit (see README).
- App icon: "Panes", chosen from six concepts and ten shape variants in
  October 2026. A graphite tile (`#1E2228`) holding three panes, one tall
  on the left and two square on the right in `#4E5666`, with the top-right
  pane lit in the attention coral `#F26B4A`; pane corners are concentric
  with the tile's (radius 64 at inset 168 on the 1024 grid, tile radius
  232). No cursor, sparkle or network glyph, by decision. The icon is
  generated, never drawn by hand: `scripts/render-app-icon.swift` holds
  the geometry and palette and writes `Resources/AppIcon.icon` (two
  layers, idle panes and the lit pane, over an automatic gradient of the
  ground colour; macOS 26 and later render it with the system shape,
  depth and dark/tinted variants), the `AppIcon` set in `Assets.xcassets`
  (16–1024 px rasters on the classic 824-in-1024 grid with a baked
  shadow, for everything else), the `StatusItem` template image set (the
  menu bar mode glyph, section 8) and `docs/icon/AppIcon.svg`. Change the
  script and rerun it; do not edit the generated files.
  `ASSETCATALOG_COMPILER_APPICON_NAME` is `AppIcon` in `project.yml`. The
  lit coral is meant to become the in-app attention colour as well; today
  the badge and status glyphs use their own colours (open item).
- Signing: hardened runtime, no sandbox entitlement, `zmx` and `ctty-exec`
  helpers signed as part of the bundle. Debug builds are ad hoc; Release
  builds are signed with Developer ID by the release pipeline (step 9,
  next subsection).

### Release pipeline (step 9)

Decisions (October 19, 2026): team **YJ8LXVCB3T** (an individual
Developer Program enrolment; Gatekeeper names "Donny Kurniawan"); **no
updater** and **no crash reporting** in v1 (the repository is private, so
a Sparkle feed has nowhere public to live; macOS keeps crash reports
under `~/Library/Logs/DiagnosticReports`); the artifact is a **notarized,
stapled DMG**.

- **Signing settings** (`project.yml`). `DEVELOPMENT_TEAM` is
  `YJ8LXVCB3T` on the app, `ctty-exec` and the test target. Debug keeps
  "Sign to Run Locally" (`CODE_SIGN_IDENTITY = -`) so the build and test
  gate never depends on the keychain; Release signs with `Developer ID
  Application` (manual style), hardened runtime, secure timestamp. Both
  helpers stay without entitlements (the `project.yml` comments explain
  why); `embed-zmx.sh` already follows the build's identity and hardened
  flag. `armadale-notify` is a shell script in Resources and is not
  Mach-O; the Linux `zmx` binaries are data. Nothing else in the bundle
  needs signing. A Release build must launch and run sessions: the
  AMFI concern (a restricted entitlement on a helper) is what
  `scripts/check-quit.sh` against the Release app proves absent.
- **`scripts/release.sh`** builds the artifact from a clean working
  tree (refuses a dirty one unless `--allow-dirty`), in this order:
  1. `xcodegen generate`; `xcodebuild archive` (Release) into
     `build/release/` (git-ignored); the app is taken from the archive's
     `Products/Applications` (no provisioning profile is involved, so
     `-exportArchive` adds nothing).
  2. Verification before anything leaves the machine: `codesign
     --verify --deep --strict --verbose=2` on the app; the app, `zmx` and
     `ctty-exec` are signed by the Developer ID identity with the
     hardened runtime (`codesign -d -vv` shows `runtime`); the helpers
     carry no entitlements and the app carries only the sandbox-off
     entitlement; `Contents/Helpers/zmx` is universal.
  3. Notarize the app first: zip it (`ditto -c -k --keepParent`),
     `xcrun notarytool submit --keychain-profile armadale-notary --wait`,
     fail on anything but `Accepted` (print the log on failure), then
     `xcrun stapler staple` the app.
  4. Build the DMG from the stapled app with `hdiutil` (volume
     "Armadale", the app and an `Applications` symlink, UDZO), sign the
     DMG with the same identity, notarize it the same way, staple it.
  5. Final checks: `spctl --assess --type execute` on the app and
     `spctl --assess --type open --context context:primary-signature` on
     the DMG; `stapler validate` on both. Output
     `build/release/Armadale-<MARKETING_VERSION>.dmg`; print the
     suggested `git tag v<version>` command rather than tagging.
  `--skip-notarize` stops after step 2 plus an unnotarized DMG, for
  checking the pipeline without credentials.
- **Credentials.** The keychain profile `armadale-notary` is created
  once, interactively, by the owner:
  `xcrun notarytool store-credentials armadale-notary --apple-id <id>
  --team-id YJ8LXVCB3T` with an app-specific password. The script
  explains this when the profile is missing. Nothing in the repository
  holds credentials.
- **Versions.** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in
  `project.yml` and are bumped before a release (the build number must
  increase every release); `scripts/bump-build.sh` (October 23, 2026)
  raises the build number by one, or sets it and the marketing version,
  and can commit the bump from a clean tree. The build number stays an
  integer: a git commit hash was considered and rejected, since
  `CFBundleVersion` is compared numerically by Launch Services and by
  updaters; the commit a build came from is the one the release's
  suggested tag points at. A release is a commit; the tag is the
  owner's.
- **Identity change.** A Developer ID build has a different code
  identity (designated requirement) from the ad-hoc development build.
  Notification permission is kept per bundle identifier, so it carries
  over. Privacy (TCC) grants, which are keyed by the code requirement, may
  need granting again, and macOS 27's stored "Allow in the Background"
  decision may be asked again. Not a defect; noted for testing.

**Implementation (step 9).** Where the build differs from the plan above,
or adds to it:

- *Signing style.* All three targets use `CODE_SIGN_STYLE = Manual`, Debug
  included (with `CODE_SIGN_IDENTITY = -`, still "Sign to Run Locally"), so
  Xcode never consults an Apple account or looks for a provisioning
  profile. Release sets `CODE_SIGN_IDENTITY = Developer ID Application`
  and `OTHER_CODE_SIGN_FLAGS = --timestamp` on the app and `ctty-exec`
  (the archive log shows `codesign --force --sign <Developer ID SHA-1>
  --timestamp -o runtime` and no `--timestamp=none`). The test target is
  ad hoc in every configuration; it never ships. `embed-zmx.sh` needed no
  change: under Release it receives the Developer ID SHA-1 as
  `EXPANDED_CODE_SIGN_IDENTITY` and `ENABLE_HARDENED_RUNTIME = YES`, so
  `zmx` is signed with the same identity, `--options runtime` and
  `--timestamp`. The sign-on-copy of `ctty-exec` keeps its runtime flag
  and its empty entitlements. On this Mac the first Developer ID signing
  raised no keychain prompt.
- *Architectures.* The app and `ctty-exec` are arm64 only: macOS 27 has
  no Intel support, and with a macOS 27 deployment target Xcode 27's
  `ARCHS_STANDARD` is `arm64`. `Contents/Helpers/zmx` stays universal, and
  the script checks that, because it is also the binary deployed to
  macOS SSH hosts (`HelperLocator.remoteZmx`, section 6); its x86_64 slice
  is what an Intel Mac host (macOS 26 or earlier) receives.
- *Profile action.* The scheme's Profile action builds Release, which now
  needs the Developer ID certificate and carries no `get-task-allow`, so
  Instruments cannot attach to it; profile a Debug build instead, or
  change the action's configuration locally.
- *`release.sh` additions.* A preflight, before anything is built,
  checks for `xcodegen`, checks the working tree with `git status
  --porcelain --untracked-files=normal` (so a `status.showUntrackedFiles`
  setting cannot hide untracked files), resolves the signing identity and
  (unless `--skip-notarize`) checks that `xcrun notarytool history
  --keychain-profile armadale-notary` works; a missing profile prints the
  `store-credentials` command. The identity is the SHA-1 of the single
  valid `Developer ID Application: … (YJ8LXVCB3T)` identity; with none the
  script fails, and with several (a renewed certificate next to the old
  one) it fails asking for `ARMADALE_SIGNING_IDENTITY=<sha1>`, which is
  honoured when set and must name one of them. Xcode still picks the
  app's identity by name; the script then requires the app's leaf
  certificate (`codesign --extract-certificates`) to be that identity, and
  signs the DMG with its SHA-1. After reading the version, the script
  fails if the tag `v<version>` already exists (bump the versions first)
  unless `--allow-existing-tag` is given. The archive uses its own
  DerivedData under `build/release/` (the whole directory is removed at
  the start of every run), so a release never reuses development
  intermediates; its log is kept as `build/release/archive.log`. The
  version and build number are read from the archived app's
  `Info.plist`. Verification also requires a secure timestamp on each of
  the three signatures and that all three name the same signer; the DMG
  is signed with the resolved identity, checked with `codesign --verify
  --strict` and `hdiutil verify`. The DMG's file system is HFS+. A
  notarized DMG is built as `Armadale-<version>-pending.dmg` and renamed
  to `Armadale-<version>.dmg` only after the final `spctl` and `stapler
  validate` checks pass (the stapled ticket is inside the file, so the
  rename does not affect it); a failed run never leaves a file with the
  release name. Every check (signatures, stapling, `hdiutil`) fails with
  a message rather than ending the script silently under `set -e`.
- *`--skip-notarize`* still signs the DMG and runs the Gatekeeper checks
  (which reject it with "source=Unnotarized Developer ID"), and names it
  `Armadale-<version>-unnotarized.dmg`, so it cannot be mistaken for a
  release. The suggested tag is an annotated `git tag -a v<version>` on
  the commit that was built; after an `--allow-dirty` build the script
  says to commit and rebuild instead of suggesting a tag (based on the
  tree's state at the start of the run). The notary log
  is fetched for accepted submissions too, and any issues (warnings) in
  it are printed.
- *`hdiutil` on macOS 27* prints a deprecation warning for `create`,
  pointing at `diskutil image create from` (whose folder images are
  APFS). `hdiutil` still works and is kept; the switch is a later chore.

---

## 12. Build order

Each step was built by an implementer agent, reviewed by a separate
reviewer agent (code reading plus live keystroke checks of the running
app), fixed, verified with the full build and test command, and committed
on `main`. Steps 1–7 are done: d0c4587, 93019d8, f6cedbb, 76a4e4e,
4d3ab86, 7302a12, dac547f (October 16–18, 2026); steps 8 and 9 on October 19.
The build order is complete.

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
8. **Menu bar mode** — the quit question, the General preference,
   accessory mode with a status item, End Sessions and Quit (section 8,
   "Quitting with running sessions"). *Done.*
9. **Ship** — Developer ID signing, `scripts/release.sh` (archive,
   verify, notarize, staple, DMG), README release section (section 11,
   "Release pipeline"). No updater and no crash reporting in v1. *Done.*

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
  SwiftTerm 1.99.0 is a preview of 2.0 with an API break; a Ghostty-based
  second renderer over `Lakr233/libghostty-spm` (the one wrapper with
  host-fed I/O) was evaluated on October 19, 2026 and is recorded as a
  pending decision in `HANDOFF.md`.
- **macOS 27 background attribution.** Every session process originates
  from Armadale, so after quitting with live sessions the Dock shows
  Armadale as "Running in Background", the first such quit prompts the
  user to allow or disallow it, and the Dock's "Stop Running in
  Background" item sends SIGTERM to every session process at once
  (verified live on October 19, 2026: one click ends every session).
  Disclaiming responsibility at spawn
  (`responsibility_spawnattrs_setdisclaim` in `spawnOnPTY`) and starting
  the work through `launchctl submit` were both tested and change
  nothing: launchd keeps the attribution across fork, exec, disclaim and
  job submission. Decision (October 19, 2026): Armadale asks before
  quitting with running sessions and otherwise stays in the menu bar
  (step 8, section 8); the findings are in `HANDOFF.md`. Tested the
  same evening: menu bar mode avoids the Dock indicator and its stop
  item, and no prompt appeared for a quit from it (with a decision
  stored), but the stored allow decision governs the sessions all the
  same. With Armadale switched
  off under Allow in the Background (what Don't Allow on the first-quit
  prompt records), `loginwindow` force-quits the app's whole coalition
  5 s after a menu bar mode quit and 1 s after a regular quit ("BTM said
  this application is not allowed to run background processes"), so
  every local session dies; under Allow nothing is touched. No API
  reports the decision. Open: whether the quit alert, the status menu
  or an `SMAppService` login item should answer this (`HANDOFF.md`).
- **Socket path length** on macOS (104 bytes) constrains where the runtime
  directory lives; handled with the fallback above. zmx does not resolve
  symlinks, so a symlinked short directory is an alternative if ever needed.
- **Remote deployment trust.** Armadale writes a binary into the user's home
  on remote hosts. This is explicit in the Hosts UI, versioned, verified by
  SHA-256 where the host can, and confined to `~/.armadale` (0700).
- **Host keys and prompts.** Control commands never prompt (BatchMode). An
  unknown host key, a passphrase or a password is answered in the pane by an
  interactive sign-in that leaves the shared connection up (section 6); a
  *changed* host key makes ssh refuse, and its warning is what the pane
  shows. A master that dies (network change, sleep) takes every pane on
  that host with it; they reconnect on the schedule.
- **Agent forwarding** is not supported in v1 (no `-A`); a user's own
  `ForwardAgent` in `ssh_config` applies to the connection that becomes the
  master, which is usually a control command.
- **Login shells**: remote command lines are single-line POSIX `sh`
  scripts and are verified to parse under tcsh, sh and zsh; fish is not
  tested. Inside a session, csh and tcsh as the user's `$SHELL` get
  `$SHELL -c '<program>'` instead of `-l -c` (they refuse `-l` with other
  flags); a loopback test starts a program that way.
- **Windows hosts are unsupported**, as are other systems and
  architectures than Linux and macOS on ARM64 and x86-64: sessions there
  are plain ssh shells that end when Armadale quits. A host whose shell
  start-up files print text when run non-interactively still works (the
  classification skips it), but a remote `.bashrc` that asks for input
  would hang the attach until its timeout.
- **Remote floods**: the zmx client's unbounded buffer (section 7) is on
  the host; Armadale cannot see or bound it.
- **Agent integrations drift.** What section 10 relies on was read from
  Claude Code 2.1.292 (the `--settings` argument and its
  `preferredNotifChannel` values) and Codex 0.163.0 (its defaults: BEL in an
  unknown terminal, only while unfocused). A later version may rename
  channel values, change the defaults, or start hooks differently; section
  10 records the sources and lines to check again. The notify helper only
  relies on a terminal device somewhere up the process tree.
- **Environment scrubbing** (section 4) removes an exact list of
  variables that identify the session Armadale was started from (other
  terminals, Claude Code 2.1.292's own child markers). It never removes
  configuration a user may rely on (API keys, config directories, provider
  switches); a new agent version adding markers would need adding to the
  list.
- **Team ID** is YJ8LXVCB3T (step 9); the bundle identifier is
  `com.tinylittleapps.armadale`, a prefix the owner chose, not a
  registered organisation name.
