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

Layout operations live in `PaneLayout` as pure functions with unit tests:
`split(pane, axis, newPane)`, `remove(pane)` (collapses the parent),
`neighbor(of:direction:)`, `resize(pane, delta)`, `swap`, `equalize`.

### `AppModel`

A single `@MainActor @Observable final class AppModel` owns `[Workspace]`,
`[Session]`, `[Host]`, `[Profile]` and exposes intent methods
(`newTab(in:)`, `splitFocusedPane(axis:)`, `closePane(_:)`,
`moveTab(_:to:)`, …). Every mutation goes through it, which is what makes the
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
- An XcodeGen build phase `lipo`s the two macOS binaries into a universal
  `Contents/Helpers/zmx`, which is code‑signed with the app's identity and
  hardened runtime for notarization. The Linux binaries ship as data in
  `Contents/Resources/remote/` for deployment to SSH hosts.
- A second helper, `Contents/Helpers/ctty-exec`, is a ten-line trampoline
  built from source in this repo (see section 7). It is bundled and copied
  the same way as zmx.
- At launch Armadale copies both helpers to
  `~/Library/Application Support/Armadale/bin/<name>-<ver>` if missing and
  always runs **those** copies. Daemons therefore never hold open a binary
  inside an app bundle that may be replaced by an update. The daemon's
  argv[0] is that path, so `pgrep -f` can identify Armadale's daemons.

### `PersistenceBackend` protocol

```swift
protocol PersistenceBackend: Sendable {
    func create(_ session: Session) async throws -> ProcessHandle   // attach, creating
    func attach(_ session: Session) async throws -> ProcessHandle   // attach only if exists
    func exists(_ id: SessionID) async throws -> Bool
    func liveSessions() async throws -> Set<SessionID>
    func kill(_ id: SessionID) async throws
    func history(_ id: SessionID) async throws -> Data               // live sessions only
}
```

Implementations:

- `LocalZmxBackend` — spawns `zmx attach a-<id> <program> <args…>` in a
  PTY, with `chdir` to the working directory before exec so the daemon
  inherits it. Everything after the name is the argv, passed verbatim to
  `execvpe`. There is **no `--` separator**: zmx would try to execute `--`.
- `RemoteZmxBackend` — same commands wrapped in `ssh` (section 6).
- `EphemeralBackend` — a plain PTY with no daemon. Used as a fallback when
  the remote host cannot take a zmx deployment, and in UI tests.

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
- **Respawn**: creates a new session with the same `launch`, directory and
  location, and rebinds the pane to it. The old session ID is retired.
- **Disconnected** (remote only): the ssh transport died. The placeholder
  shows **Reconnect** / **Close Pane**, and Armadale retries in the
  background with exponential backoff (1 s → 30 s) until the host answers,
  then re-attaches automatically.
- **Workspace › Respawn All Ended** exists for the morning‑after‑reboot case
  where every session is gone.

### Environment handed to new sessions

`TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Armadale`,
`TERM_PROGRAM_VERSION`, `ARMADALE_SESSION_ID`, `LANG` (from the user's
locale), the user's login shell environment (the program is launched through
`$SHELL -l -c` for shell profiles), plus profile environment. Because the
daemon inherits the cwd and environment of the **creating** client only
(verified), later attaches cannot change them; zmx's tracked‑variable
mechanism keeps `SSH_AUTH_SOCK` current. zmx itself sets `ZMX_SESSION` inside
the child; Armadale leaves that alone.

### Housekeeping

zmx writes one log per daemon to `ZMX_DIR/logs/<name>.log` plus a shared
`zmx.log`, at debug level, each truncated at 2 MB but never deleted. At
launch Armadale removes log files whose session ID is neither live nor
referenced by the model.

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
- Only fds 0–2 reach the child (`CLOEXEC_DEFAULT`). This matters because the
  zmx daemon only closes inherited fds 3–63.
- Output is read with a `DispatchSource` on the master fd into a 64 KB
  buffer and delivered to the main actor in coalesced batches (≤ 16 ms or
  when the buffer fills), which keeps a chatty agent from starving the UI.
- Input and resizes are written on a serial queue. Process exit is observed
  with `DispatchSource.makeProcessSource(.exit)` and `waitpid`. For zmx
  clients the exit status is meaningless (always 0); the session state is
  decided by `exists(id)` afterwards.
- The spike harness in the scratchpad (`PTYSpawn.swift`, `ctty-exec.swift`)
  is the reference implementation for step 2 and compiles under Swift 6
  strict concurrency with no `nonisolated(unsafe)` or `@unchecked Sendable`.
- One‑shot commands (`zmx ls`, `kill`, ssh control) go through an
  `actor CommandRunner` built on `Process` with async `run() -> (status,
  stdout, stderr)` and a timeout.
- `SessionController` (`@MainActor`) is the per‑session glue: owns the
  surface, the `ProcessHandle`, the state machine, the attention flag, and
  forwards title / cwd / bell to `AppModel`.

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
WorkspaceWindowController (NSWindowController, one per open workspace)
└── NSSplitViewController
    ├── Sidebar: NSHostingController<SidebarView>       SwiftUI List, drag & drop
    └── Content: ContentViewController
        ├── NSHostingView<TabBarView>                  SwiftUI, ⌘N badges, "+"
        └── PaneContainerView (NSView)
            └── SplitTreeView (nested NSSplitViews mirroring PaneLayout)
                └── PaneView per leaf
                    ├── surface.view                   terminal
                    └── NSHostingView<PlaceholderView> Session Ended / Disconnected
```

- Window uses `titlebarAppearsTransparent`, `toolbarStyle = .unified`, and
  `title` / `subtitle` set to "Workspace name" / "Tab group name", which
  produces the header in the mockup. The toolbar holds the sidebar toggle.
- `SplitTreeView` diffs the new `PaneLayout` against the current view tree
  and reparents existing `PaneView`s rather than rebuilding, preserving
  terminal views and first responder.
- Keyboard focus follows `focusedPaneID`; the focused pane has a subtle
  accent border, the unfocused ones dim slightly.
- The tab bar is custom SwiftUI (not `NSTabView`): it needs shortcut badges,
  status glyphs, drag reordering, and dragging a tab onto a sidebar tab group
  to move it.
- Settings is an `NSWindowController` hosting a SwiftUI `TabView`:
  **General** (default profile, default directory, confirm‑on‑close),
  **Appearance** (font, size, theme, cursor, renderer), **Profiles**,
  **Hosts**, **Shortcuts** (read‑only table in v1).

### App lifecycle

- `NSApplicationDelegate` loads `StateStore`, builds `AppModel`, probes each
  backend's live sessions once, then opens every workspace whose window was
  open at last quit and attaches its visible panes first, the rest lazily
  when their tab is first shown.
- Quit never kills sessions. Closing a pane kills its session after a
  confirmation if it is still running (configurable). Closing a window keeps
  the workspace.
- Closing the last tab in a tab group removes the tab group. Closing the
  last tab group in a workspace closes the workspace's window; the workspace
  stays in the model and in the sidebar, and reopening it creates a fresh
  "Main" group with one Shell tab.
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

---

## 10. Agent sessions

A pane is "just a shell" by default. The agent profiles only add:

- a launch program (`claude`, `codex`) and arguments, respawn‑safe because the
  resolved `LaunchSpec` is stored on the session;
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
│   ├── Windows/                     WorkspaceWindowController, ContentViewController
│   ├── Sidebar/                     SidebarView (SwiftUI)
│   ├── Tabs/                        TabBarView (SwiftUI)
│   ├── Panes/                       PaneContainerView, SplitTreeView, PaneView, PlaceholderView
│   ├── Settings/                    SettingsWindowController + SwiftUI tabs
│   ├── Resources/                   Assets.xcassets, Info.plist, Armadale.entitlements
│   └── Support/                     Keybindings, ThemeCatalog
├── Packages/
│   ├── ArmadaleCore/                model, PaneLayout ops, StateStore, migrations   (no AppKit)
│   ├── ArmadaleSessions/            PTYProcess, CommandRunner, backends, SSHTransport, SessionController
│   ├── TerminalSurface/             protocol + appearance types
│   └── SwiftTermSurface/            SwiftTerm adapter (depends on SwiftTerm)
├── Vendor/zmx/                      fetched binaries (git‑ignored)
├── scripts/                         fetch-zmx.sh, zmx.lock, notarize.sh
└── docs/DESIGN.md
```

- `ArmadaleCore` and the layout operations are fully unit‑tested with Swift
  Testing and run in a few seconds without a UI.
- `ArmadaleSessions` has integration tests that spawn a real local zmx
  session, kill it, and assert the state machine.
- CI: `xcodegen generate && xcodebuild test` on a macOS 27 runner.
- Signing: hardened runtime, no sandbox entitlement, `zmx` helper signed as
  part of the bundle, notarization via `notarytool` in `scripts/notarize.sh`.

---

## 12. Build order

1. **Skeleton** — XcodeGen project, packages, CI, `ArmadaleCore` model,
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
