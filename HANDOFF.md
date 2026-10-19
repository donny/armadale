# HANDOFF.md — where development stopped

Point-in-time status for whoever picks Armadale up next. Update this file
whenever work pauses. The durable rules for working in this repository are
in `AGENTS.md`; the design contract is `docs/DESIGN.md`; build and run
instructions are in `README.md`.

## Status (October 18, 2026)

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

The app icon ("Panes": a graphite tile with three panes, the top-right
one lit coral) was added after step 7: `scripts/render-app-icon.swift`
generates the Icon Composer document, the asset catalog rasters and
`docs/icon/AppIcon.svg` from one geometric description. Concept and
refinement pages used to choose it are not in the repository.

ac7094b removed GitHub Actions: there is no CI. Every commit was made after
the full local build and test command passed (452 tests at dac547f, zero
warnings). The working tree was clean and nothing was running when work
paused.

## Next: step 8 (Ship), not started

Decisions needed from the owner before work begins:

1. The Developer ID **team identifier**. `DEVELOPMENT_TEAM` is `""` in
   `project.yml` (app and `ctty-exec` targets); the bundle id is
   `com.tinylittleapps.armadale`.
2. Whether to add **crash reporting**, and which service or mechanism.
3. The **update mechanism**. Sparkle is the obvious candidate.

Then the work is: Developer ID signing of the app and both helpers (keep
the helpers signed with no entitlements; see the `project.yml` comments),
`scripts/notarize.sh` with `notarytool`, a release build script, the
chosen updater and crash reporter, and a README section. Use the same
implementer → reviewer → fix → verify → commit loop described in
`AGENTS.md`, and ask the owner before starting.

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
  signalling needs the user's `Stop` hook (the Configure… sheet shows it).
- The `armadale-notify` helper cannot reach the pane from inside tmux or
  screen, and only exists on this Mac (hooks in remote sessions cannot use
  it; the profile arguments work everywhere).
- A session whose profile was deleted is never notified under "Only for
  agent profiles".

Shipping (step 8)
- The app icon's lit coral (`#F26B4A`) should become the in-app attention
  colour (Dock badge, status glyphs); today those use their own colours.
- `DEVELOPMENT_TEAM` empty; signing is "sign to run locally".
- No `scripts/notarize.sh`, no crash reporting, no updater.

## Investigations (October 19, 2026), decisions pending

Three things looked into after step 7. None is started; each needs an
owner decision before it becomes a step. Details that belong to the
design contract are in `docs/DESIGN.md` where noted.

### A second renderer: Ghostty behind `TerminalSurface`

SwiftTerm 1.99.0 (pinned) is a preview of 2.0: a new I/O architecture and
SIMD work, but also an API break ("you can no longer hold on to the
underlying terminal"), so `SwiftTermSurface` needs attention at 2.0 either
way. Ghostty-based rendering (Metal, Ghostty's parser and VT coverage) was
compared across three Swift packages. The deciding constraint is that
`TerminalSurface` is byte-fed: the session layer owns the PTY (persistence
helper via `ctty-exec`, `ssh -tt`, the output filter, flood handling), the
renderer gets `feed(bytes)` and reports `didInput`. A stock libghostty
surface spawns its own command and owns its PTY, so only a wrapper with a
host-managed I/O patch can slot in.

| Package | Host-fed I/O | Events for our delegate | Pin / activity (19 Oct 2026) |
|---|---|---|---|
| `Lakr233/libghostty-spm` | Yes: `InMemoryTerminalSession` (`receive(Data)`, write and resize callbacks, output backpressure hooks) | Title, pwd, bell, desktop notification, open URL, hover link, clipboard with confirmation, progress, colour change, command finished, search, scrollbar, cell size | Ghostty main, re-pinned weekly, 21 documented patches; 114 stars; Swift 6.2; ~72 MB zip for all Apple slices |
| `hudsonkit/Termini` | Yes: `processRemoteOutput`, `onTransportWrite`, `onSizeChange` (one ~400-line patch) | Only input, size, diagnostics, open URL, OSC 52. No title, bell, pwd, notification | One June 2026 Ghostty commit; 18 stars; Swift 5.9; 131 MB zip |
| `briannadoubt/GhosttyKit` | No: stock libghostty spawns the shell | Title, pwd, bell, notification, URL, search, progress, child exited | May 2026 commit; arm64 only; 6 stars; last push June 2026 |

Conclusion: `libghostty-spm` is the only candidate that fits the
architecture, and it maps onto `TerminalSurfaceDelegate` almost one to one
(`find`, `selectedText`, `clearScrollback`, `scrollToBottom` map to its
search delegate, public selection API and binding actions). Costs: a
weekly-moving upstream pin held together by one maintainer's patch stack, a
20 to 30 MB macOS slice in the bundle, one Metal layer per pane. Unverified
from outside: how its host-managed backend behaves with the persistence
helper's replay on attach (replayed query sequences must not be answered to
the live PTY; `ZmxOutputFilter` handles this for SwiftTerm today and would
sit in the same place). Termini is a useful reference for how small the
patch is; briannadoubt's wrapper is unusable here without moving PTY
ownership into the renderer.

Proposed step: a `GhosttySurface` package implementing `TerminalSurface`
over libghostty-spm's in-memory session, registered in `SurfaceRegistry`
as a second renderer with SwiftTerm staying the default, then compared on
real sessions. Decision needed: whether to spend a step on this before or
after step 8.

### macOS 27: "Running in Background" after quit

Since macOS 27 the Dock keeps an app's icon with a light grey indicator
and the tooltip "Running in Background" when any process the app is
*responsible for* is still alive after quit (Apple support article
125671). Responsibility is set at spawn and inherited down the whole
process tree, double forks included. Armadale spawns `ctty-exec` with
`posix_spawn`, it execs the persistence client, the client forks the
session daemon, the daemon runs the shell and any agent: all of it is
attributed to Armadale, so after quitting with live sessions the Dock is
reporting the truth. Verified on this Mac with a spawn experiment: a plain
child and its grandchild report the parent's responsible process; a child
spawned with `responsibility_spawnattrs_setdisclaim` (present on macOS 27,
used by LLDB and Chromium, not in public headers, looked up with `dlsym`)
is responsible for itself, and so is its grandchild.

The risk is the icon's context menu item "Stop Running in Background",
which press coverage says kills the background processes. For Armadale
that would be every session daemon, so every persistent session and the
agents in them, from one Dock click. The per-app toggle in System
Settings › General › Login Items & Extensions › Background App Activity
is undocumented for already-running processes. Apple has published no
developer guidance or API. Neither action has been tested here: it needs
the Mac free for live UI work.

Options:
1. Keep attribution, accept the indicator. Sessions keep inheriting
   Armadale's privacy grants (a Full Disk Access grant covers every shell;
   folder prompts say "Armadale"). Nothing in our code can intercept the
   Dock's kill if it is SIGKILL.
2. Disclaim at spawn: one attribute on the `posix_spawn` call in
   `PTYSpawn.swift` (`spawnOnPTY`). The daemon tree becomes its own
   responsible process; the indicator should disappear and the Dock has
   nothing to kill. Cost: privacy prompts from shells and agents would
   carry the helper binary's name rather than Armadale's, and Armadale's
   grants would no longer cover sessions. The installed helper copy would
   have to be renamed so the runtime's name never reaches a prompt
   (product rule). The `forkpty` fallback cannot disclaim; acceptable.
3. Transient launchd agents for daemons: same privacy consequence as 2,
   more moving parts, needs a server-only start mode. No advantage over 2.

Test plan before deciding (owner present, isolated state dir): start a
throwaway session, quit, confirm the grey dot, choose "Stop Running in
Background", check whether the daemon dies and how (socket removed means
SIGTERM, socket left means SIGKILL); then a build with the disclaim
attribute: dot gone, sessions survive quit, and what name a protected-folder
prompt carries from inside a session. Recommendation: if the kill is real,
ship the disclaim with a presentable helper name, because "one click ends
every session" is the worse failure for a persistence terminal; if the
Dock action is gentler than described, keep attribution and document the
dot. Record the outcome in `docs/DESIGN.md` section 7 and 13.

### The `ctty-exec` helper, for orientation

Documented in README ("The `ctty-exec` helper") and `docs/DESIGN.md`
section 7; summarised here because the two items above both touch it.
It is Armadale's own ~30-line trampoline
(`Packages/ArmadaleSessions/Sources/ctty-exec/main.swift`), shipped at
`Contents/Helpers/ctty-exec`. Spawned on a fresh PTY, it claims the PTY as
controlling terminal (`ioctl(TIOCSCTTY)`) and `execv`s the real program.
It exists because on macOS 27 `posix_spawn` with `SETSID` plus the slave on
fds 0 to 2 no longer acquires a controlling terminal, so without it ^C
(SIGINT) and resizes (SIGWINCH) never reach the program; `forkpty` would
fix that but forks the multithreaded app, so it is only the fallback. The
persistence helper also runs it inside each session to set the program's
`argv[0]` (`-zsh` for a login shell) and to strip the helper's private
environment (`--unset`). Being the first process in every session's tree,
whatever responsibility it is spawned with flows down to daemon, shell and
agent, which is why the macOS 27 disclaim would be set on its spawn.

## State of this Mac that matters

- Notification permission for `com.tinylittleapps.armadale` is granted in
  System Settings (done during step 7 testing); it applies to any build
  with that bundle id.
- The Lima VM `default` is stopped and has no `~/.armadale` inside it.
- Claude Code 2.1.292 and Codex 0.163.0 are installed; `docs/DESIGN.md`
  §10 records what each offers and the source lines consulted. Re-check
  when either is upgraded.
