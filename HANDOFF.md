# HANDOFF.md — where development stopped

Point-in-time status for whoever picks Armadale up next. Update this file
whenever work pauses. The durable rules for working in this repository are
in `AGENTS.md`; the design contract is `docs/DESIGN.md`; build and run
instructions are in `README.md`.

## Status (October 19, 2026)

Steps 1–9 of the build order (`docs/DESIGN.md` §12) are implemented,
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
| 8 Menu bar | bf40d94 | quit question, General preference, accessory mode with status item, End Sessions and Quit |
| 9 Ship | (next commit) | Developer ID signing, `scripts/release.sh`, notarized stapled DMG |

The app icon ("Panes": a graphite tile with three panes, the top-right
one lit coral) was added after step 7: `scripts/render-app-icon.swift`
generates the Icon Composer document, the asset catalog rasters and
`docs/icon/AppIcon.svg` from one geometric description. Concept and
refinement pages used to choose it are not in the repository.

ac7094b removed GitHub Actions: there is no CI. Every commit was made after
the full local build and test command passed (452 tests at dac547f, zero
warnings; 467 at step 8). The working tree was clean and nothing was
running when work paused.

Step 8 (October 19, 2026) came out of the macOS 27 investigation below:
Armadale asks before quitting with running sessions and can stay in the
menu bar instead (`docs/DESIGN.md` section 8, "Quitting with running
sessions"). Owner decisions: a plain quit that leaves sessions running
exists only in the status item's menu (from accessory mode, where the
Dock shows nothing), never in the ⌘Q alert; the choice is rememberable
through a General preference (Ask / Keep running in the menu bar / End
sessions, default Ask); the status item shows the Panes glyph as a
template image. Built with the implementer → reviewer loop (467 tests,
zero warnings, `check-quit.sh` passing).

Step 9 (October 19, 2026): Developer ID signing under team
**YJ8LXVCB3T** (an individual enrolment under the owner's name; "Tiny
Little Apps" is only the bundle id prefix), `scripts/release.sh`
(archive, verify, notarize and staple the app, build, sign, notarize and
staple the DMG, Gatekeeper checks), a README "Releasing" section. **No
updater** in v1 (the repository is private, so a Sparkle feed has no
public home; revisit if the repository or a website becomes public) and
**no crash reporting**. Spec: `docs/DESIGN.md` section 11, "Release
pipeline (step 9)". The keychain profile `armadale-notary` exists on this
Mac and the first notarized `Armadale-0.1.0.dmg` was produced and
accepted during the step's verification (not kept: `build/` is
git-ignored and wiped by the script). Built with the implementer →
reviewer loop. The app is arm64 only (macOS 27 has no Intel support);
the bundled persistence helper stays universal for Intel Mac hosts.

## Next

The build order is complete. Candidates, each needing an owner decision:
the Ghostty second renderer (below), the open items below, a public home
for an update feed, and the untested macOS 27 prompt cases listed under
"Menu bar mode (step 8)".

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

Menu bar mode (step 8), from its review
- The Dock badge could not be seen for Armadale on this Mac in any mode,
  before or after step 8 (the Dock's `AXStatusLabel` stays empty with
  attention pending). Probably the app's badge setting in System
  Settings › Notifications; the code path (`NSApp.dockTile.badgeLabel`)
  is unchanged. Check on a Mac where badges show.
- A workspace window in full screen saves its full-screen frame to the
  state file, so the next launch opens a screen-sized normal window.
  Predates step 8.
- Not exercised live: a real logout, restart or shutdown (the quit
  event's reason is unit-tested with synthetic events only); a
  notification click reopening from menu bar mode (code path only);
  End Sessions and Quit against a slow or unreachable remote host; the
  persistence fallback mode; window order with several windows on
  return; macOS hiding the status item; the light menu bar.
- Whether a quit from menu bar mode (accessory policy) triggers macOS
  27's first-quit "allow this app to run in the background" prompt is
  unknown: the owner's stored Allow masks it on this Mac. Whether
  launchd lists the session daemons under Background App Activity after
  such a quit is also unknown (needs root or the System Settings UI).
- What Don't Allow does on that prompt is still untested (toggle
  Armadale off under Allow in the Background, launch, quit with a
  session).

Shipping (step 9)
- The app icon's lit coral (`#F26B4A`) should become the in-app attention
  colour (Dock badge, status glyphs); today those use their own colours.
- No updater and no crash reporting (decided for v1, October 19, 2026).

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
after step 9 (Ship).

### macOS 27: "Running in Background" after quit — tested, decided (step 8)

Since macOS 27 the Dock keeps an app's icon with a light grey indicator
and the tooltip "Running in Background" when processes that originate
from the app are still alive after quit (Apple support article 125671).
Tested live on October 19, 2026 (isolated state directory, fresh session
each run, Dock driven through accessibility). Results:

- **The Dock's "Stop Running in Background" ends every session.** It
  sends SIGTERM to every process in the session tree at once (a trap in
  the session shell and one in a background job both recorded TERM
  before the daemon's own SIGHUP arrived). The daemon logs "SIGTERM
  received, shutting down gracefully", unlinks its socket and SIGHUPs the
  shell. No SIGKILL follows: a process that ignores SIGTERM survives,
  orphaned, but the session is gone. The icon leaves the Dock once the
  tree is dead; a quit with nothing left behind shows no indicator.
- **A first-quit prompt exists.** On quit with a live session the
  system asked the owner: "“Armadale” was closed. Allow this app to run
  in the background in the future?", with Don't Allow / Allow. Every
  user will see this on their first quit with a session running, and
  the wording ("updating or syncing data") makes Don't Allow sound
  harmless. What Don't Allow does is **untested**; by Apple's deployment
  guide the system then terminates the background tasks, presumably on
  every quit. Apple's deployment guide: "if background tasks are started
  by an app and remain active after a user quits the app, the user is
  prompted to allow or not allow the background tasks to remain active";
  an MDM Service Management profile can suppress the prompt by bundle id
  or team id.
- **Disclaiming responsibility does not help.** With
  `responsibility_spawnattrs_setdisclaim` on the `posix_spawn` in
  `spawnOnPTY` (symbol via `dlsym`), every process in the tree became its
  own responsible process (daemon, shell, client), yet the Dock still
  showed the indicator and its stop item still killed the daemon. The
  only effect was on privacy prompts: `ls ~/Desktop` from inside a
  session produced "“ctty-exec-0.1.0” would like to access files in your
  Desktop folder" (the installed helper copy's file name) instead of
  Armadale. The change was reverted.
- **A launchd job submitted from inside a session does not escape
  either.** `launchctl submit` from the pane gave the job its own
  coalition and responsibility, but after quit the Dock still showed
  Armadale, and the stop item killed the job and removed its launchd
  entry. The attribution is kept by launchd across fork, exec, disclaim
  and `launchctl submit`; nothing a child does after spawn changes it.
  Option 3 of the earlier plan (transient launchd agents started by the
  app) is therefore out as well.

What Apple says (developer forums, DTS replies on the macOS 26 version of
this feature, thread 799162): apps should quit when told; background work
that outlives the app must be visible, as a menu bar status item, a
window, or an entry in System Settings › Login Items & Extensions.
Keyboard Maestro's forum reports that its Engine avoids the Dock
indicator when it runs as a login item rather than being launched by the
editor. Against that, forum thread 835214 (macOS 27 beta, FB23203848)
reports an `SMAppService` agent still giving the parent app the grey dot
after quit, and thread 848726 reports turning an app off under Background
App Activity sends its `SMAppService` daemon SIGTERM. Thread 847300: a
background-only app (`LSUIElement`) now appears in the Dock with the
"Running in Background" subtitle. No API, entitlement or Info.plist key
opts out.

Options considered (3 was chosen and became step 8):
1. Keep the architecture, accept the indicator and the prompt, document
   both, and make the sessions survivable: a visible "sessions are still
   running" cue at quit (an alert, or a window that stays while sessions
   are alive) so the first-quit prompt is understood, and a note in the
   README. Does not stop a user clicking Don't Allow or Stop.
2. Move session ownership out of the app's process tree into a
   `SMAppService` login item or agent ("Armadale Sessions"): a small
   server that launchd starts and that owns the persistence daemons; the
   app attaches through it. It appears under Login Items & Extensions
   with the app's name, which is Apple's sanctioned form, but thread
   835214 suggests the Dock may still show the parent app, and a user
   turning it off there still SIGTERMs it. Needs a prototype before it
   becomes a step: register an agent, start a daemon from it, quit, and
   see what the Dock and the toggle do.
3. Do not quit: keep a status item while sessions are alive (the
   "visible presence" exemption). **Prototyped and tested on October 19,
   2026**, then built as step 8. The prototype: ⌘Q with live sessions shows an
   alert, "N sessions are still running", with *Keep Running in Menu
   Bar* (default), *End Sessions and Quit* (destructive) and *Cancel*.
   Keep hides every window, switches the activation policy to accessory
   and adds a status item whose menu shows the count, *Open Armadale*,
   *Quit, Keep Sessions Running* and *End Sessions and Quit*. Observed:
   - In menu bar mode Armadale is **not in the Dock at all**, still not
     after 90 s, and no system dialog appeared. The daemon and its client
     stay attached. *Open Armadale* brings the window and Dock icon back.
   - *Quit, Keep Sessions Running* from the status menu quits from
     accessory mode: the daemon survives and the Dock shows **no**
     "Running in Background" item, checked at 3 s and 20 s. A quit from
     the normal (regular) policy with the same daemon alive does show it.
     The Dock decorates an existing tile; an accessory app has none.
     Whether launchd still lists the daemon under Background App
     Activity is unknown (needs root or System Settings).
   - Relaunch reattaches the pane to the same session. *End Sessions and
     Quit* kills every session (controllers for shown panes, backends for
     the rest), the daemon logs the kill, the socket is removed, and the
     app exits with nothing left; no Dock item.
   - SIGTERM (logout) bypasses the alert and quits as before; the
     `check-quit.sh` paths are unchanged in principle but were not rerun.
   Open questions for making this a step: wording; whether a quit from
   menu bar mode should be the only "keep running" quit; whether the
   first-quit system prompt still appears for an accessory-mode quit
   (cannot be tested on this Mac while the Allow decision is stored);
   the Settings window and notifications while in menu bar mode; the
   `.terminateLater` note in DESIGN.md §8 (the prototype cancels the
   quit, ends sessions in a Task, then calls terminate again, so it does
   not depend on `.terminateLater`).

Still untested, in order of value: Don't Allow on the prompt (toggle
Armadale off under Allow in the Background, launch, quit with a
session); whether an accessory-mode quit triggers that prompt; an
`SMAppService` agent prototype (option 2). Record the outcome in
`docs/DESIGN.md` sections 7 and 13 once decided.

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

- Background App Activity: on October 19, 2026 the owner answered
  **Allow** to the first-quit prompt for `com.tinylittleapps.armadale`,
  so the prompt will not appear again on this Mac until Armadale is
  switched off under System Settings › General › Login Items &
  Extensions › Allow in the Background (`sudo sfltool dumpbtm` shows the
  record). A Desktop-folder privacy denial was recorded for the deleted
  path `/tmp/armadale-bgtest/bin/ctty-exec-0.1.0` during the disclaim
  test; harmless.
- Notification permission for `com.tinylittleapps.armadale` is granted in
  System Settings (done during step 7 testing); notification
  authorization is per bundle id, so it covers ad-hoc and Developer ID
  builds alike. Privacy (TCC) grants keyed by code requirement, and
  macOS 27's stored background decision, may differ between the two.
- The Developer ID certificate for team YJ8LXVCB3T expires on February 1,
  2027; the notarization keychain profile is `armadale-notary`.
- The Lima VM `default` is stopped and has no `~/.armadale` inside it.
- Claude Code 2.1.292 and Codex 0.163.0 are installed; `docs/DESIGN.md`
  §10 records what each offers and the source lines consulted. Re-check
  when either is upgraded.
