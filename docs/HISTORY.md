# Armadale — History

Why and when. `docs/DESIGN.md` says what is true now; this file keeps
what led there, in two parts. Part 1 is the change log: what was built
when, how it was checked and what was found on the way, in order (it
was the status section of `HANDOFF.md` until November 14, 2026). Part 2
is the history of each design section, under the same section numbers
as `docs/DESIGN.md`: the steps and dates, the alternatives that were
rejected, the measurements and the live checks (it was interleaved with
the contract in `docs/DESIGN.md` until the same day).

Nothing here is a rule. Where this file and `docs/DESIGN.md` disagree,
DESIGN and the code are right: this file records what was true when
each entry was written. New entries go at the end of Part 1, one per
change, and in Part 2 under the section they concern.

---

# Part 1: changes, in order

What was built when, how it was checked, and what was found on the
way, oldest first; moved from `HANDOFF.md` on November 14, 2026. "Open
items" in these accounts means the open items of `HANDOFF.md`.

## October 16, 2026: no CI (ac7094b)

ac7094b removed GitHub Actions: there is no CI. Every commit was made after
the full local build and test command passed (452 tests at dac547f, zero
warnings; 467 from step 8 on; 523 at the clean-exit change; 545 at the
empty-workspace change; 551 at the last-pane change). The working tree was clean and nothing was
running when work paused (October 19, 2026, evening).

## October 18, 2026: the app icon, "Panes" (bbf81a4)

The app icon ("Panes": a graphite tile with three panes, the top-right
one lit coral) was added after step 7: `scripts/render-app-icon.swift`
generates the Icon Composer document, the asset catalog rasters and
`docs/icon/AppIcon.svg` from one geometric description. Concept and
refinement pages used to choose it are not in the repository.

## October 19, 2026: investigations after step 7 (first recorded in 7b15acf)

Three things looked into after step 7. None is started; each needs an
owner decision before it becomes a step. Details that belong to the
design contract are in `docs/DESIGN.md` where noted.

(As recorded on October 19, 2026. The first, a second renderer built on
Ghostty, is still pending and stays in `HANDOFF.md`, "Decisions
pending"; the macOS 27 investigations and the `ctty-exec` orientation
follow here.)

## October 19, 2026: macOS 27, "Running in Background" after quit (tested; decided in step 8)

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
  harmless. What the disallowed state does was **tested on October 19,
  2026 (evening)**: macOS ends every session process 1 to 5 s after any
  quit, from the menu bar too (the "Allow in the Background" entry
below). The prompt's own Don't
  Allow button was not pressed (the stored Allow cannot be cleared on
  this Mac without `sudo sfltool resetbtm`, which resets every app);
  it records the same "off" state as the switch. Apple's deployment
  guide: "if background tasks are started by an app and remain active
  after a user quits the app, the user is prompted to allow or not allow
  the background tasks to remain active"; an MDM Service Management
  profile can suppress the prompt by bundle id or team id.
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
   (answered below: no prompt was seen, and `loginwindow` treats the
   exited accessory app as never user-visible);
   the Settings window and notifications while in menu bar mode; the
   `.terminateLater` note in DESIGN.md §8 (the prototype cancels the
   quit, ends sessions in a Task, then calls terminate again, so it does
   not depend on `.terminateLater`).

Still untested, in order of value: an `SMAppService` agent prototype
(option 2), now also as a possible way out of the kill described in the
next section; the prompt's Don't Allow button itself (needs a Mac with
no stored decision; the switch records the same state); whether a quit
leaves the ssh connection masters (`ControlPersist`, up to 10 minutes)
as subordinate processes that show the Dock indicator or are killed;
whether Background App Activity lists the daemons.

## October 19, 2026: the `ctty-exec` helper, for orientation (first recorded in 7b15acf)

Documented in README ("The `ctty-exec` helper") and `docs/DESIGN.md`
section 7; summarised here because the two macOS 27 investigations of
October 19, 2026 both touch it.
It is Armadale's own small trampoline
(`Packages/ArmadaleSessions/Sources/ctty-exec/main.swift`), shipped at
`Contents/Helpers/ctty-exec`. Spawned on a fresh PTY, it claims the PTY as
controlling terminal (`ioctl(TIOCSCTTY)`) and `execv`s the real program;
with `--exit-file <path>` (October 23, 2026) it instead `posix_spawn`s it,
stays as its parent out of the way of job control, and records how it
ended in that file (DESIGN section 7, "Exit recorder").
It exists because on macOS 27 `posix_spawn` with `SETSID` plus the slave on
fds 0 to 2 no longer acquires a controlling terminal, so without it ^C
(SIGINT) and resizes (SIGWINCH) never reach the program; `forkpty` would
fix that but forks the multithreaded app, so it is only the fallback. The
persistence helper also runs it inside each session to set the program's
`argv[0]` (`-zsh` for a login shell) and to strip the helper's private
environment (`--unset`). Being the first process in every session's tree,
whatever responsibility it is spawned with flows down to daemon, shell and
agent, which is why the macOS 27 disclaim would be set on its spawn.

## October 19, 2026: Step 8, menu bar mode (bf40d94)

Step 8 (October 19, 2026) came out of the macOS 27 investigation above:
Armadale asks before quitting with running sessions and can stay in the
menu bar instead (`docs/DESIGN.md` section 8, "Quitting with running
sessions"). Owner decisions: a plain quit that leaves sessions running
exists only in the status item's menu (from accessory mode, where the
Dock shows nothing), never in the ⌘Q alert; the choice is rememberable
through a General preference (Ask / Keep running in the menu bar / End
sessions, default Ask); the status item shows the Panes glyph as a
template image. Built with the implementer → reviewer loop (467 tests,
zero warnings, `check-quit.sh` passing).

## October 19, 2026: Step 9, Ship (cb63ef7)

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

## October 19, 2026: `scripts/install-release.sh` (cf9305c)

After step 9, cf9305c added `scripts/install-release.sh`, which runs the
release pipeline and installs the app from the DMG into `~/Applications`.

## October 19 and 23, 2026: Armadale 0.1.0, builds 1 and 2

**Releases.** Armadale 0.1.0 (build 1) was built, notarized and stapled
on October 19, 2026 from 72cf014 and installed to `~/Applications`
(untagged). Armadale 0.1.0 (build 2) was built, notarized and stapled by
`scripts/install-release.sh` on October 23, 2026 from 524c9da (both
notary submissions accepted) and installed to `~/Applications`, replacing
build 1; it is tagged **`v0.1.0`** (annotated, pushed). The build number
is raised with `scripts/bump-build.sh` before each release. The DMG is
not kept in the repository (`build/` is ignored and wiped by the script).

## October 19, 2026, evening: macOS 27, "Allow in the Background" switched off (a5eb37c; deferred in a6c7c25)

The two prompt cases left open by the "Running in Background"
investigation above were tested with the Debug build of
0892714 (ad hoc, real bundle id, launched through Launch Services with
`open -n --env`, state in `/tmp/armadale-bgtest`), the owner switching
Armadale off under System Settings › General › Login Items & Extensions
› Allow in the Background for tests 1 to 3 and on again for test 4.
Each run: one local shell session, quit, then the daemon watched for
60 s and the unified log read (`log show`, subsystems
`com.apple.launchservices:quitsupport` and
`com.apple.backgroundtaskmanagement`).

| Test | Switch | Quit | App gone | Daemon | Dock tile | Prompt |
|---|---|---|---|---|---|---|
| 1 | off | ⌘Q › Keep Running in Menu Bar › status menu › Quit, Keep Sessions Running | at once | SIGTERM 5 s after the quit | none | none |
| 2 | off | SIGTERM (`pkill -x Armadale`, regular policy) | 0.6 s | SIGTERM 1 s after the quit, gone at 2.3 s | none seen | none |
| 3 | off | as 2, with a TERM trap in the pane's shell | 0.6 s | gone at 1.7 s; the shell's trap started (its output file was created) and was cut off | none seen | none |
| 4 | on | as 1 | at once | alive after 60 s | none | none |

What the log shows. When the app process exits, `loginwindow` notes the
"non-application coalition pids" (daemon, shells) and asks Background
Task Management whether the app may run background tasks
(`checkTasksAllowedInBackgroundForAppURL`). Switched off, the answer is
"BTM said this application is not allowed to run background processes"
and `loginwindow` calls `_LSForceQuitApplication` on the app's
coalition, which SIGTERMs every remaining process; the daemon logs
"SIGTERM received, shutting down gracefully" and the shell gets the
signal directly as well (test 3). After a regular-policy quit the app
"was foreground, and still has subordinate processes", and the kill is
scheduled 1 s later. After a quit from menu bar mode the exited app "is
non-foreground and never tracked", is dropped from the application
list, and the check and kill come 5 s later with the words "is not
allowed to run non-foreground and has never been user-visible, so
killing the process and its subordinate processes". Switched on, the
same quit logs only the "never tracked" line and nothing is touched.

What it means. Menu bar mode avoids the Dock's "Running in Background"
tile and its stop item, as step 8 intended, but not the allow decision:
the sessions survive a quit only while Armadale is allowed in the
background, whatever the quit. A user who answers Don't Allow on the
first-quit prompt (or switches Armadale off later) loses every session
a few seconds after each quit, with *Quit, Keep Sessions Running* in
the status menu promising otherwise. While Armadale is running, in the
menu bar or not, nothing is killed. There is no API for the app to read
the decision (`SMAppService` covers login items, not this record), and
no prompt appears for an accessory-mode quit, so the user is never told
again. Remote sessions are not affected (no local process), except that
their ssh masters are subordinate processes too (untested).

Options for the owner: say so in the quit alert and the README
(cheapest; the alert already explains menu bar mode), add it to the
status menu's wording, or prototype the `SMAppService` agent (option 2
above) to see whether a login item's processes escape the check.
**Decision deferred by the owner (October 19, 2026): open item, nothing
started.** What was recorded: `docs/DESIGN.md` section 8 ("Quit, Keep Sessions
Running") and section 13; the README's "Quitting and the menu bar"
gained one sentence.

## October 19–20, 2026: small changes and inline renaming (f3855aa, a2c236b, 628c99e, 26c6699, ba9ecf5)

Small changes after the build order (October 19–20, 2026), each through
the full gate: the About panel's copyright holder (f3855aa); the sidebar
toggle moved to the divider end of the sidebar section (a2c236b); tab
group rows always show the plain folder icon (628c99e); AGENTS.md's
rule to end test builds by pid while the installed app may be running
(26c6699); and **inline renaming** of workspaces, tab groups and tabs
in the sidebar and the tab bar (double-click or the context menu; Return
commits, Escape cancels, focus loss commits; blank names are ignored and
a blank tab title restores the derived one; the three Workspace menu
items and the rename sheet are gone; `docs/DESIGN.md` sections 1 and 8).
Built with the implementer → reviewer loop and a live keystroke pass
(October 20, 2026).

## October 20, 2026: the full-screen frame (f67d804)

The **full-screen frame** fix (October 20, 2026): the
frame is never recorded while a window is in full screen, `WindowState`
gained `isFullScreen` (decoding to false for older files, no schema
bump), a full-screen workspace comes back full screen at launch and
after menu bar mode, and a saved frame is clamped to a screen that still
exists (`docs/DESIGN.md` section 8, "Full screen" and "Saved frames and
screens"). Built with the implementer → reviewer loop and two live
passes.

## October 23, 2026: About panel and pane dimming (9e47bee)

October 23, 2026: the About panel puts "All rights reserved." on its own
line and unfocused panes are no longer dimmed, only the focused pane's
accent border remains (9e47bee, owner's request).

## October 23, 2026: a clean exit closes the pane (f218600)

October 23, 2026: **a clean exit closes the pane** (implementer →
reviewer loop, two live passes, Lima VM for the host side): an exit recorder sits between the
persistence daemon and the program, locally `ctty-exec --exit-file`
(`posix_spawn` instead of `execv`; `N` for a normal exit, `signal N` for
a death by signal) and on hosts the session's `sh` script (`$?`, so 128
and above reads as a signal), writing `<run dir>/a-<id>.exit` through a
temporary file and a rename. `ExitResolution.ended` carries a
`ProgramExit`; `EndedSessionRule` (ArmadaleCore, pure) closes the pane
through the Close Pane path when the program exited normally with 0, or
with any status when the session runs the user's shell (^D after ^C is
130; `exit` after a failed command is 1), and keeps the *Session Ended*
placeholder, now with "exited with status N" or "was ended by signal N",
for a signal death, an unknown end, or a non-shell program's non-zero
exit; the only pane of a workspace always keeps the placeholder. At
launch, restored local sessions that ended cleanly while the app was
closed lose their panes before any window shows; remote ones when their
host first answers. The placeholder's Respawn button answers Return only
in the focused pane, and a click around the placeholder's card focuses
the pane. `docs/DESIGN.md` sections 4, 6, 7 and 13; README. The owner's
request to remove the "Ask Siri" field from the sidebar's context menus
was **withdrawn** the same day. The investigation, as it stood in the
open items:

- macOS 27 puts an "Ask Siri" field at the top of the sidebar's context
  menus (workspace, tab group and tab rows). Investigated October 23,
  2026: it is AppKit's "assistant field", not a context menu plug-in
  (`allowsContextMenuPlugIns = false` leaves it; SwiftUI's
  `contextMenuIntelligentAssistantBehavior` is not public). It appears
  only in context menus inside a SwiftUI `List`, not for `.contextMenu`
  outside a List (the tab bar) nor for AppKit `popUpContextMenu`,
  `popUp(positioning:)` or `NSTableView.menu`. The only working removal
  was a private AppKit setter on each menu as it is built; the owner
  ruled out private API and **withdrew the request**. If it comes back,
  the public route is AppKit-built pop-up menus for the sidebar rows,
  which means mapping the click to its row.

## October 23, 2026: an empty workspace is deleted automatically (a651532)

Later on October 23, 2026 (implementer → reviewer loop, two live passes):
**an empty workspace is deleted automatically.** A tab group is never
kept without tabs and a workspace never without tab groups: closing or
moving away the last tab removes the group, and removing the last group
deletes the workspace and closes its window, the only workspace
included, so the model may hold zero workspaces (the app stays running
with its Dock icon; ⌘N or a Dock click makes a fresh "Workspace";
`CloseResult.deletedWorkspace`, `AppModel.ensureWorkspacesToOpen()`).
A workspace closed with tabs in it (red button, ⇧⌘W) is unchanged: it
stays dimmed in the sidebar with its sessions running. A close that
asks anyway adds "The workspace “X” will be removed too." (after
committing an open inline rename). Loading the state file drops closed
workspaces with no tab groups and, in the repair pass, groups with no
tabs, logged and with no schema bump; the owner's own "Workspace 2" husk
goes at the next launch of a build with this change. After a move
empties the group the window showed, the target group is shown when it
is in the same workspace. `docs/DESIGN.md` sections 1, 3 and 8; README.

## October 23, 2026, evening: a clean exit closes a workspace's only pane too (2462fe6)

October 23, 2026, evening (implementer → reviewer loop, three
live passes): **a clean exit closes a workspace's only pane too**: the
last-pane exception of `EndedSessionRule` is gone, so the close
cascades through tab, tab group and workspace, the window closes, and
with no workspace left the app keeps running with its Dock icon (or
stays in menu bar mode with "0 sessions running" and the tooltip
"Armadale": owner's decision, the app never leaves menu bar mode or
quits on its own). At launch, restored sessions that all exited
cleanly give one fresh "Workspace". Two bugs fixed on the way. First,
a window closing itself while any window was entering or leaving full
screen came back as an empty orphan and the next queued window never
entered full screen: the launch queue in `AppDelegate` is replaced by
`Windows/FullScreenSerializer.swift`, which runs every full-screen
toggle one at a time (launch entries, menu bar exits and re-entries,
exits before a close), starting only when no window is in a transition
and 0.3 s after the last one ended; a full-screen window that has to
close leaves full screen first (an exit AppKit reports as failed is
retried up to four times; a window on an inactive Space cannot leave
and is closed in full screen as its own step); closes go ahead of
entries; entries for deleted workspaces are skipped; still no timeout
if AppKit never ends a transition. Menu bar mode with several
full-screen windows also changed: switching to accessory mode moves
full-screen windows off the active Space, so on return each one is
brought forward, leaves and re-enters full screen instead of coming
back without its title bar (a visible Space switch, about 2.5 s for
two windows; the usual case after ⌘Q → Keep Running). Known gap: ⇧⌘W on a
full-screen window, whose exit after the close the serializer does not
see (`docs/DESIGN.md` section 8, "Full screen", "Closing in full
screen", "Menu bar mode"; `FullScreenSerializerTests`). Second, Return
never pressed the placeholder's Respawn / Reconnect / Retry button,
since step 2, because the ended terminal view kept keyboard focus; the
pane itself is first responder while a placeholder is shown
(`PlaceholderKeyboardTests`). `docs/DESIGN.md` sections 4 and 8; README.

## October 24, 2026: Step 10, New Session: the design (269adec)

**Step 10, New Session (owner's request, October 24, 2026): done in
three sub-steps (10a 507a52a, 10b 9168f0b, 10c 18faf87).** `docs/DESIGN.md` §8 "New sessions: the chooser, the dialog
and favorites", §2 (`Pane.sessionID` optional, `SessionOptions`,
`SessionRequest`, `Favorite`, the new intents), §3, §10 and
§12 (step 10, three sub-steps) hold the agreed design. In short: a new
pane never starts a shell by itself; it shows a chooser with the saved
favorites, Cancel and New Session…; the New Session dialog (a sheet)
takes Local or SSH (a picker of saved hosts plus Add Host…), a working
directory, a profile, per-agent options (Claude Code: skip permissions,
continue, model; Codex: bypass approvals and sandbox, sandbox mode,
model; both: additional arguments) and an Add to Favorites checkbox with
a prefilled name; Cancel and Start. Favorites are saved with the layout
and get a Settings › Favorites page. Removed: File › New Tab with
Profile, File › New Tab on Host, the tab bar "+" context menu, General's
default profile and directory. Splits ask too; Respawn is unchanged; a
chooser pane survives a quit as a chooser pane. Decisions the owner made
on the way: keep the word Profile and the Profiles and Hosts pages as
they are; the word for the thing is "session"; the button is Start; a
favorite whose host or profile is gone is shown broken until edited or
removed. The flag names were read from `claude 2.1.304 --help` and
`codex-cli 0.163.0 --help` on October 24, 2026 (Codex has no
`--full-auto` any more). The owner said not to care about files written
by older builds (unreleased), so the state file stays schema 1 with
additive decoding (0.1.0 had in fact been tagged the day before and
cannot read an empty pane; schema 2 since November 14, 2026,
below). Order: 10a model and removals, 10b dialog and
Settings › Favorites, 10c the chooser; each through the implementer →
reviewer loop. The owner gave the go-ahead for all of step 10 on October
24, 2026 and asked only to be told when the Mac is needed for live UI
work (10c; 10a and 10b were done code-only, no app launch).

## October 24, 2026: Step 10a, model and removals (507a52a)

**10a (model and removals) is committed:** empty panes, `SessionOptions`,
`SessionRequest`, `Favorite`, `startSession(in:request:)`, the favorite
intents, the agent flag table (pulled forward from 10b) in
`AgentIntegration`, `ShellWords.split`, respawn with the session's
options; the two File items, the "+" context menu and General's defaults
removed; an **interim** (`WorkspaceActions.withInterimShells`, marked
`Step 10a interim`) gives every new pane a local shell in the focused
pane's directory until 10c, so between 10a and 10b there is no way to
start a remote or non-shell session except Respawn. Reviewer findings,
all low, were fixed (directory trimming, repair wording, `ShellWords`
wording) except two notes for later: a pane whose `sessionID` names a
missing session is kept and shows blank (as at HEAD before 10a); 10c's
repair should turn it into an empty pane that shows the chooser. **10b
live check to do:** nobody has run a real Codex session with `--model`,
`--sandbox` or `--dangerously-bypass-approvals-and-sandbox` to see
whether they, like the `-c` overrides §10 records, make Codex run
"without the shared background server"; they parse together fine
(`codex … completion zsh` exits 0). "Add Host…" needs its own way to open
Settings › Hosts in 10b, since `showHostsSettings` went with the menu.
Tests: 578 at 10a (129 app + 223 core + 206 sessions + 13 + 7).

## October 24, 2026: Step 10b, the dialog and Settings › Favorites (9168f0b)

**10b (the dialog and Settings › Favorites) is committed:** the New
Session sheet (`NewSessionSheet` over the view-free `NewSessionForm`,
tested), Settings › Favorites, `AppDelegate.showSettings(tab:)` for Add
Host…, and the interim changed: every empty pane now gets the sheet from a
per-window `NewSessionPresenter` (marked `Step 10b interim`), Cancel
closes the pane and cascades, so between 10b and 10c the app already
asks for every new pane, only without the favorites list in the pane.
The reviewer's blocker: **AppKit's `terminate:` returns without calling
`applicationShouldTerminate` while any window has a sheet attached**
(confirmed with a standalone program; `presentAsSheet` and `beginSheet`
alike), so ⌘Q, the Quit item and SIGTERM did nothing with a New Session
sheet up. Fixed by `ArmadaleApplication` (an `NSApplication` subclass,
the principal class) that takes every New Session sheet down before the
terminate runs; panes stay empty and saved; a cancelled quit brings the
sheets back. `scripts/check-quit.sh` now has three scenarios (sheet up,
normal, fallback alert), all passing (SIGTERM with the sheet up quit in
351 ms). Also fixed from the review: respawn dropped `Session.options`
after the first respawn (10a bug in `SessionController`); a sheet
outliving its pane's move to another workspace; a host added while the
sheet is open becomes the selected host; Choose… is a sheet on the sheet;
switching Claude Code ↔ Codex clears skip, continue, sandbox and model;
the New Favorite sheet sizing (`.presentationSizing(.fitted)`, **not
checked live**). Known from the live passes: the directory prefill comes
from `Session.workingDirectory`, which only OSC 7 updates, and the
owner's zsh sends none, so the prefill is `~` until shell integration
exists (owner decision, not started). Not checked live in 10b: full
screen and menu bar mode with a sheet up, a host deleted while the sheet
is open, broken favorites in Settings, the host-removal count sentence,
Codex options, a real SSH start. Tests: 604 at 10b (155 app + 223 core
+ 206 sessions + 13 + 7).

## October 24, 2026: Step 10c, the chooser (18faf87)

**10c (the chooser) is committed:** every empty pane shows the New
Session chooser (`EmptyPaneView` hosting `NewSessionPaneView`, decisions
in the view-free `NewSessionChooser`): favorites (icon, name, host badge,
directory; a broken one dimmed with its reason, inert, still editable),
a hint when there are none, Cancel and New Session…; ↑/↓ select (broken
ones skipped, ↑ from the first returns to none), Return starts the
selection or opens the dialog, Escape closes the pane and cascades, only
in the focused pane; right-click Edit… / Remove. The 10b interim
presenter is gone; the dialog's Cancel returns to the chooser; a
cancelled quit brings no sheet back; no sheet opens during a full-screen
transition or while the window closes; a sheet ends when its pane leaves
the window's workspace. Repair turns a pane whose session is missing into
an empty pane. `scripts/check-quit.sh` scenarios: chooser up, normal
(attaches to a session the helper creates first), fallback alert. A tab
of only empty panes shows no status glyph (`StatusGlyph` takes nil).
Both cards (`PaneCard`) go compact below 340 pt. Repair and drop logs go
through `os.Logger` (subsystem `com.tinylittleapps.armadale`, category
`state`, public) because NSLog is `<private>` in `log show` on macOS 27.
Reviewed with two live passes (all scripted checks passed: quit script,
every chooser path, Return/Escape routing in splits, favorites
edit/remove/broken, SIGTERM with the dialog and the Edit Favorite sheet
up, a tab with the dialog up dragged to another window, full screen,
⌘Q counting). Not checked live: menu bar mode with a chooser pane,
keypad Enter, hover, a scrolling favorites list, dark mode, ⇧⌘N / tab bar
"+" / sidebar New Tab in 10c (they share the path), Add Host… from the
Edit Favorite sheet, zoom with a chooser, the compact Disconnected and
Unavailable cards. Known: compact chooser rows show only icon and name,
so a remote favorite in a narrow pane does not show its host. Tests: 621 at 10c (169 app +
226 core + 206 sessions + 13 + 7).

## October 29, 2026: the Shortcuts tab moves to Help (c4e45e0)

October 29, 2026 (owner's decision, done by the coordinating session
through the gate, no agents): **the Shortcuts tab moved from Settings to
Help › Keyboard Shortcuts** (`Armadale/Help/ShortcutsWindowController.swift`
and `ShortcutTable.swift`, the Help menu item without a key equivalent,
`AppDelegate.showKeyboardShortcuts`; the window is ordered out in menu
bar mode with Settings and closing it there hides the app the same way;
a saved `settingsTab` of `shortcuts` opens General; `docs/DESIGN.md`
sections 8, 9 and 11; README). Reason: Settings is for what can be
changed, and every binding is a menu item key equivalent that System
Settings › Keyboard › App Shortcuts can already rebind by title. **Not
checked live** (the Mac was not free): the window itself (Help ›
Keyboard Shortcuts, its size, ⌘W closing it, menu bar mode). Tests: 623
(171 app + 226 core + 206 sessions + 13 + 7), zero warnings.

## October 29, 2026: sidebar icon colours and the highlight (5b005b6, 204627f, 5249216)

Later on October 29, 2026 (owner's rule, coordinating session, through
the gate, no agents, code-only): **sidebar icon colours**. Icons are
accent-coloured only in a window that looks active and only on its shown
path (its workspace, the tab group it shows, that group's selected tab);
every other icon is gray, and all of them are in an inactive window
(then `SidebarIconTint` in `Sidebar/SidebarView.swift`, now `SidebarShownPath`, `SidebarShownPathTests`,
`docs/DESIGN.md` section 1). Removing the selection highlight was
discussed and **deferred by the owner** ("I'll test it later"): there is
no supported way to hide a List's selection highlight on macOS, so it
would mean dropping the selection binding that the double-click rename
and the context menus are built on. The owner ran the build and the
icon colours looked right. Then (same evening, owner's rule) **the
highlight moved** from the shown tab group's row to the deepest visible
row of the shown path (`SidebarHighlight`: the selected tab, the group
while collapsed, the workspace while collapsed), and a click on a row of
the window that changes nothing now moves the highlight back and gives
the pane the keyboard (seen live by the owner: clicking the current
workspace row left it bright blue, the List holding keyboard focus).
The owner's live check of that commit (204627f): renaming the tab and
the workspace by double-click looked right (highlight on the tab, bright
blue while the rename field holds focus inside the list), but
double-clicking the shown group's row left **no row highlighted**: the
click still wrote `select(tabGroup:)` to the model, which changed no
value but re-rendered the sidebar inside the click. Fixed the same
evening: a click on a row that is already shown writes nothing
(`SidebarHighlight.isShown`, tested). Also seen in that screenshot and
unexplained: "Main" and the second tab under it drawn semibold while the
tab rename field was up; not reproduced from code, watch for it.
**Not checked live:** the group double-click after this fix, that the
keyboard returns to the pane after a single click on the current
workspace, the selected group and the selected tab, the collapsed-group
and collapsed-workspace highlight, and that `appearsActive` flips the
icons on every activation path. Tests: 626, zero warnings.

## October 29, 2026: the sidebar has no selection and no highlight (831b9af)

Then (October 29, 2026, owner's decision after trying those commits,
implementer agent, not committed by it): **the sidebar has no selection
and no highlight at all.** The owner still saw highlight and focus
problems, so the `List` lost its selection binding, and with it
`SidebarHighlight` (and its two tests), the selection nudge, the shown-row
guard and `WorkspaceActions.focusFocusedPane`. Rows act through tap
gestures over the whole row width, as the tab bar's tabs do
(`SidebarRowActions`: a click acts, a simultaneous double tap renames, both
off while the row's rename field is up), and each row has its own
`.contextMenu`. Without a selection the outline view behind the List still
took keyboard focus on every click (seen live; `.focusable(false)` on the
List did not stop it), so `WorkspaceWindow.makeFirstResponder(_:)` refuses
any table or outline view in the sidebar; and since the list then never
takes focus from an open rename field, `WorkspaceWindow.sendEvent(_:)`
commits the window's open rename on a mouse down in the sidebar outside
the field (a first try that committed on the refused focus request also
ended a fresh double-click edit at once, since the outline view asks again
after the double tap). Icon colours and the semibold current workspace are
unchanged. `docs/DESIGN.md` sections 1 and 8. **Checked live** (test build,
isolated state, screenshots of the window only): single clicks on the
current workspace row, the shown group row, the selected tab row, another
tab, another group and another workspace's row (its window came forward)
each acted and left typed `echo` commands reaching the focused terminal;
no row was ever drawn selected (only AppKit's blue context-menu target
outline while a menu is open); double-click renames of a tab, a group and
the workspace opened the field with the text selected, Return committed,
Escape cancelled, a click in the field kept the edit, a click on another
row or on the current workspace row committed it; the three context menus
(and the other workspace's, with Show Window); a tab dragged onto another
group moved there; a group's chevron collapsed and expanded without
selecting it. **Found and not fixed:** a double-click on another
workspace's row whose window, once brought forward, covers the clicked
spot starts no rename (the second click lands in that window); the
context menu's Rename works. **Not checked live:** the keyboard reaching
an empty pane's chooser after a sidebar click, and a tab bar rename being
committed by a click in the sidebar (both were then seen by the
reviewer's live pass). After review (code only, no live run): a click on a
row of the shown path writes nothing to the model; the sidebar mouse down
is hit-tested from the window's frame view, so title-bar clicks above the
sidebar do not commit a rename; `SidebarFocusTests` covers the refusal;
each row is an accessibility button with a default action and a Rename
action. Arrow keys and Full Keyboard Access no longer reach sidebar rows
(owner's decision); **VoiceOver was not checked live.** Tests: 625, zero
warnings. Committed as 831b9af.

## October 30, 2026: sidebar title weight follows the shown path (9162c7e)

October 30, 2026 (owner's rule, coordinating session, through the gate,
no agents, code-only): **sidebar title weight follows the shown path.**
The three rows of a window's shown path (its workspace, the tab group it
shows, that group's selected tab) are semibold in every window, active or
not; every other row is regular, including a tab needing attention, which
was semibold before (it keeps ◐ and the purple counts). So bold says what
a window shows and blue alone says which window is active. The tint
helper became `SidebarShownPath` (`contains`, `isAccented`, `font`,
`color`; `SidebarShownPathTests` replaces `SidebarIconTintTests`), and
the shown-path click guard uses it. `docs/DESIGN.md` sections 1 and 8.
This also accounts for the earlier "unexplained" semibold "Main": it was
that window's workspace, and a semibold tab under it would have been one
needing attention. **Not checked live** (the owner will see it on the next
install): a screenshot of an inactive window with its path semibold and
all icons gray. Tests: 626, zero warnings. Committed as 9162c7e; the
owner installed it (build 14) and accepted the look.

## October 30, 2026: the tab bar drawn like the native macOS 27 tab bar (60e107d)

October 30, 2026 (owner's request, implementer → reviewer loop): **the
tab bar is drawn like the native macOS 27 window tab bar**, at the
native 36 pt height: a capsule track holding the tabs, the selected tab
a raised pill (flat in a window that is not key), hairline dividers
between plain tabs and none beside a pill, a hovered tab and a tab
needing attention (purple) as pills too, and "+" as a circle at the
bar's right end outside the track. Style only: tab content, alignment,
widths, scrolling, drag, rename, context menu, middle click and "+" are
as before (`TabBarStyle` in `Tabs/TabBarView.swift`, `TabBarStyleTests`;
`docs/DESIGN.md` section 8, "Tab bar look", with the measurements, the
per-appearance tints and what deliberately differs from native).
Increase Contrast strengthens the hairlines (tested, not seen live).
**Checked live** by both agents in light (against a Terminal window with
its tab bar) and in dark (the test build forced dark with a test-only
injected library, since deleted, against a scratch native-tab window):
1, 3 and 9+ tabs, hover, inactive window, rename with Return and Escape,
middle click, drag reorder and the drop indicator, attention, a narrow
window, scrolling. **Older bugs found by the reviewer and not fixed**
(reproduced on the unchanged build; recorded in DESIGN section 8): the
track can stay scrolled about 30 pt past its start after the window is
narrowed and widened again, until relaunch; a new tab beyond the visible
ones is selected but not scrolled into view; and, from code reading, a
hidden overflow tab's stored frame could catch a middle click near "+".
Tests: 632, zero warnings. Committed as 60e107d; the owner installed it
(build 15).

## October 30, 2026: tabs fill the track; three tab bar bugs fixed (49fd474)

October 30, 2026, later (owner's request, implementer → reviewer loop,
three review rounds): **tabs fill the track and the three tab bar bugs
above are fixed.** The 220 pt maximum is gone: tabs share the track's
whole inside equally (one tab fills it, two are halves, as native), down
to 110 pt, below which the track scrolls. Scrolling is decided by the
pure `TrackScroll` from the tab count, the selected index, the bar width
and the current or pending offset, never from measured frames: a
selection change reveals the selected tab with the least scroll (start
for the first, end for the last); a tab-count change only clamps the
user's offset (start when everything fits, new end when past it); a
width change clamps and keeps a selected tab that was wholly visible
visible. A programmatic scroll the scroll view drops (seen live with
quick ⌘9 ⌘2 bursts) is retried once by the pure `PendingScroll` state
machine in `TabFrameStore`: a target counts as reached only when the
track rests on it, a user scroll phase clears it. Middle click resolves
only inside the track's visible frame. `docs/DESIGN.md` section 8 ("Tab
bar look", "Scrolling the track"). **Checked live** (light; dark for the
widths and the first scroll round): 1, 2, 5 and 11 tabs; "+", ⌘1/⌘9 and
sidebar clicks revealing hidden tabs; two- and three-key ⌘ bursts (74/74
after the last fix); closing tabs with the track scrolled (offset only
clamps); narrow to 520 pt and widen to 1100 pt; a trackpad scroll during
a reveal animation wins with no later jump; middle click on "+", the
margins and a partly hidden tab; drag reorder with overflow. **Known and
not fixed:** dragging a tab does not auto-scroll the track, so only
visible tabs are drop targets. **Not checked live:** the attention
reveal's scroll (same selection-change path), a sidebar toggle at the
same moment as a selection change, a tab closed during a live resize,
and the last fix in dark mode. Tests: 644, zero warnings. Committed as
49fd474.

## October 30, 2026, evening: Show Tab items hidden; ⇧⌘N in the sidebar (2b64971)

October 30, 2026, evening (owner's request, coordinating session, through
the gate, code-only): **the eighteen Show Tab / Show Tab Group items are
out of the Window menu**, kept as hidden commands
(`allowsKeyEquivalentWhenHidden`, `MainMenu.hideCommand`) so ⌘1…⌘9 and
⇧⌘1…⇧⌘9 still work; `ShortcutTable` folds a hidden item into the one
before it only when the title matches too, so these keep their rows
under Help › Keyboard Shortcuts (tested). And **a tab group row of the
current workspace ends in its ⇧⌘N shortcut** (`SidebarShortcut`, first
nine groups, nothing for other workspaces' groups) instead of the tab
count. `docs/DESIGN.md` sections 1 and 9. **Not checked live** (the Mac
was not free): the Window menu's look without the items and the sidebar
badge; the owner will see both on the next install. Tests: 646, zero
warnings. Committed as 2b64971.

## October 30, 2026, evening: a pane context menu with a Theme submenu (ebec034)

October 30, 2026, evening (owner's decision, implementer → reviewer
loop): **a right-click context menu per pane, with a Theme submenu that
sets that pane's theme.** `Pane.themeID` (saved only when set, missing
key decodes nil, no schema bump; older builds read the file and drop the
themes on their next save), `AppModel.setTheme(_:forPane:)` and
`forgetTheme(_:)` (a removed user theme clears panes using it, wired
into Settings › Appearance › Remove through `AppSettings.removeUserTheme`).
One explicit theme per pane for both appearances; Default follows
Settings. `PaneMenu.make` (`Panes/PaneMenu.swift`) is the pure builder
future pane items go into; `PaneThemeBinding` ties a pane to the model.
Click rules are `ContextClick` in `TerminalSurface`, used by
`HostTerminalView` (SwiftTermSurface subclass; the SwiftTerm checkout is
untouched): a right-click goes to a program that asked for the mouse,
otherwise to the pane; Shift + right-click always opens the pane menu;
Control-click (without Command) is a right-click and reaches such a
program as a right button; ⌘-click is left to SwiftTerm. A themed pane
draws its chooser and placeholder (and, cosmetically, its menu) in the
appearance suiting the theme. `docs/DESIGN.md` sections 2, 8 ("Pane
context menu") and 11. **Owner decision pending** (DESIGN names the
one-line alternative): Control-click reaching a mouse-aware program as a
right button means it never sees Control+left-click (Emacs's buffer
menu). **Checked live** by the implementer (test build, isolated state,
dark Mac): menu on terminal, padding, placeholder and empty pane;
Dracula on one of two panes; Default; Settings theme changes only
Default panes; import and remove of a Ghostty theme; survival across
respawn, a sidebar tab move and quit/relaunch; forced light appearance;
vim with mouse=a (plain right-click and Control-click to vim, Shift +
right-click to the menu). The reviewer reproduced the menu, the themes,
vim, the mouse bytes in SGR and X10 modes and SIGTERM persistence, then
**stopped its live pass at about 20:15: a mis-aimed Control-drag landed
on the desktop** (Finder frontmost on the guard check) and Finder made
`~/Desktop/Pasted 2026-10-30 at 8.14.53 PM.textClipping` from stale drag
data; the reviewer moved it to the Trash. **Not re-verified by the
reviewer:** ⌘Q through the quit alert then relaunch, respawn, theme
import/remove, forced light, the Session Ended placeholder, Control-click
and Control-drag in a plain shell, Control-click on an empty pane
(`NSApp.currentEvent` path, not unit-testable), attention colours on a
themed pane. Tests: 674, zero warnings. Committed as ebec034.

## October 30, 2026, late evening: no mouse event opens the pane menu (a9f13c8)

October 30, 2026, late evening (owner's decision; a deletion done by the
coordinating session, through the gate): **no mouse event opens the pane
menu any more.** Asked to choose between Control-click reaching a
mouse-aware program as a right button and Control-click always opening
Armadale's menu, the owner chose neither: vim and Emacs must get every
mouse event untouched, and a better UI entry point for the pane menu will
be chosen later. `HostTerminalView` and `ContextClick` (and its tests) are
gone; `SwiftTermSurface` uses SwiftTerm's `TerminalView` as before the
menu; `PaneView` and `EmptyPaneView` no longer override `menu(for:)`,
`rightMouseDown`, `mouseDown` (for Control) or `hitTest`, and instead
offer `paneMenu()`, which nothing calls yet besides the tests. The
builder (`PaneMenu.make`), `Pane.themeID`, `PaneThemeBinding`, the themed
pane appearance and all their tests stay, so the Theme submenu is one
entry point away (it is unreachable in the app until then). Mouse
behaviour is exactly that of 2b64971. `docs/DESIGN.md` section 8 ("Pane
context menu", rewritten) and 11. Nothing was run live: the change only
removes code paths, and the remaining paths are the ones live-tested
before the menu existed. Committed as a9f13c8.

## October 31, 2026: pane cards, the design (20b315b)

October 31, 2026, morning (owner's decision): **pane cards** are the next
step. Each pane becomes a rounded card with a gutter and gaps of 8 pt, a
28 pt header (status glyph, session title, working directory, a "…"
button and right-click opening the pane menu, which is the menu's entry
point), hairline and focus borders on the card, attention in the header.
The agreed design is `docs/DESIGN.md` section 8, "Pane cards" (owner's
four decisions recorded there; the "Show pane headers" preference is
deferred, section 13). This commit is the design only; the
implementation follows through the implementer → reviewer loop and
needs the Mac for live checks. Committed as 20b315b.

## October 31, 2026: pane cards implemented (8f601d1)

October 31, 2026, morning (implementer → reviewer loop): **pane cards
implemented.** `Panes/PaneCardStyle.swift` (pure geometry and borders:
gutter 8, gap 8, radius 10, header 28, 4 pt to the grid, padding 10,
hairline 0.5 pt at 12 %, focus 1.5 pt accent at 55 %, the header text
width rule, the menu origin), `Panes/PaneHeaderView.swift`
(`PaneHeaderModel`, the SwiftUI header, `PaneHeaderHostingView`: a click
focuses the pane; "…", right-click and Control-click open `paneMenu()`),
`PaneView` and `EmptyPaneView` as clipped rounded cards hosting the
header, `SplitTreeView` with an 8 pt invisible divider,
`ContentViewController` insetting the split tree, `SessionRegistry`
feeding the headers (title, `~`-abbreviated directory only after an OSC 7
report, status glyph, attention). Deviations recorded in DESIGN §8 "As
built": directory hidden when equal to the title and shown only after
OSC 7; title and directory share the header (directory at least 40 pt
or 40 % of the text width, dropped only when the title would go under
40 pt); the placeholder covers only the area below the header; the "…"
menu right-aligns on the rightmost pane; a once-reported directory can
go stale (accepted). **Checked live** (implementer, light and dark via a
test-only injected dylib; reviewer, light): 2 × 2 split, two themes side
by side from "…" and from a header right-click, lone and zoomed panes,
empty pane at 90/165/185 pt, Session Ended pane, divider drag in the gap,
vim with mouse=a keeping its right-clicks while the header opens the
menu, mouse bytes reaching `cat -v` for right, Control and left clicks,
`stty size` after split/zoom/resize/drag, a bell's ◐ and purple title,
typing after every header action, the three review fixes. **Not checked
live:** the *Disconnected* placeholder, Increase Contrast, dark mode for
the review fixes, release on the respawn path (the close path is
tested). Tests: 675, zero warnings. Committed as 8f601d1.

## October 31, 2026: Split Right and Split Down in the pane menu and header (2695c1b)

October 31, 2026, mid-morning (owner's request, implementer → reviewer
loop): **Split Right and Split Down in the pane menu and as header
buttons.** The pane menu is Split Right ⌘D, Split Down ⇧⌘D, separator,
Theme; the items split the pane the menu was opened for
(`PaneThemeBinding.split(axis)`, `WorkspaceActions.split(pane:axis:)`,
which records the pane's session as last focused so the New Session
dialog takes its directory as after ⌘D; the registry finds the pane's
window from the model, wired by the app delegate, and falls back to the
model without one). The header shows Split Right, Split Down and "…" as
three 24 × 20 pt buttons at its trailing end (text width = header width
− 116 pt with a glyph); the split buttons hide below a 156 pt header,
where the menu still offers both splits. The owner reversed the earlier
"no split buttons" decision; zoom and close stay out of the header.
DESIGN §8 (both bullets). **Checked live** (implementer and reviewer,
light): buttons and tooltips on terminal and empty panes, Split Down
from an unfocused pane's button splitting that pane with the chooser
focused in the new pane, both items from the right-click menu with the
shortcuts shown, ⌘D with the menu open splitting once, typing after,
truncation beside three buttons in a 417 pt pane, headers of about
105 pt hiding the split buttons cleanly, the rightmost "…" menu inside
the window. **Not checked live:** dark mode, the dialog's directory after
a split (unit-tested), a pane moved to another window. Review's three
low findings fixed by the coordinator: DESIGN wording on the shortcuts,
`StatusGlyph.width` shared with `PaneCardStyle.glyphWidth`, the release
test now exercises the split closures. Tests: 682, zero warnings.
Committed as 2695c1b.

## October 31, 2026: header split buttons dropped; Session Ended not dimmed (6e0e0ca)

October 31, 2026, later morning (owner's decisions, implementer →
reviewer loop): **header split buttons dropped; Session Ended no longer
dimmed.** The owner found three header buttons busy, so the header is
back to glyph, title, directory and "…" (text space = header − 68 pt
with a glyph, − 50 without; no hide threshold); Split Right ⌘D and Split
Down ⇧⌘D stay in the pane menu. The placeholder's 18 % black layer is
gone (an ended pane looked grey beside a white empty pane): the pane's
theme background shows and the last output stays readable under the
card; the dead terminal's cursor is hidden under any placeholder kind
(DECTCEM through `TerminalSurface.setCursorVisible`, re-hidden after
each appearance change while the placeholder is up because SwiftTerm's
font setter soft-resets the terminal) and shown again when the terminal
is live. DESIGN §8 (pane cards, Session Ended). **Checked live** (light):
"…" only; the menu's split items and a split from them; an ended pane
white beside an empty pane with no cursor box and its last output
readable; a click beside the card focusing the pane; Dracula on the
ended pane keeping the cursor hidden; Return respawning with the cursor
back and typing working. **Not checked live:** dark system appearance;
the disconnected, reconnecting, unavailable and host-removed
placeholders; the reconnect ordering of the show sequence. Tests: 683,
zero warnings.

**Found in review, older than this step, not fixed (owner's decision
pending):** `SwiftTermSurface.apply` sets `terminalView.font` on every
call without comparing, and SwiftTerm 1.99.0's font setter ends in
`terminal.softReset()` (application cursor keys and keypad mode off,
cursor shown, scroll region, origin mode, wraparound, charset,
attributes and colours reset; mouse reporting, the alternate screen and
bracketed paste survive). `PaneView.viewDidMoveToWindow` applies the
appearance whenever the pane enters a window, so a split, a tab switch
or a zoom resets those modes for the program in the pane (seen live
with DECRQM: `?1` and `?25` reset after ⌘D; a window resize alone left
them). Proposed fix: set the font only when its name or size changed,
and skip the re-apply when nothing changed. Committed as 6e0e0ca.

## October 31, 2026: a split, tab switch or zoom no longer soft-resets the program (c2c3aa2)

October 31, 2026, late morning (owner's go, implementer → reviewer
loop): **a split, a tab switch or a zoom no longer soft-resets the
program in a pane.** `SwiftTermSurface.apply` sets the font only when
its name or size changed (`appliedFont`); `PaneView` skips the surface
when the appearance it computes equals the one last applied to the same
surface (record cleared when the surface is replaced), still updating
its card and header; the placeholder's cursor re-hide runs after the
font apply. A font or size change (⌘= / ⌘- / ⌘0, Settings) still
soft-resets the program's modes, and a theme change still replaces an
OSC 4 palette: SwiftTerm properties, accepted and recorded in DESIGN §8
with the lines consulted. Tests: same appearance, a theme change and a
cursor-style change keep modes 1 and 25, a size change resets them; a
pane re-entering a window applies nothing; ⌘= on an ended pane keeps the
cursor hidden. **Checked live** (implementer and reviewer, light): `?1h`
and `?25l` surviving ⌘D, ⌘2/⌘1 and zoom (DECRQM `?1;1`, `?25;2`, where
before the fix they read `?1;2`, `?25;1`); vim with mouse=a keeping the
mouse and arrows after a theme change and a tab switch; ⌘= enlarging
text with the accepted reset; an ended pane keeping the cursor hidden
through ⌘= and a theme change, Return respawning with the cursor back.
**Incident:** the implementer's keystroke helper sent ⌘ and ⇧ as flags
without pressing and releasing the modifier keys, leaving both held
system-wide for a few minutes (the test build went full screen and
zoomed from its typing); it released them, rewrote the helper, and the
reviewer and the coordinator confirmed no modifier held afterwards
(`CGEventSource.flagsState`). Tests: 686, zero warnings.

Committed as c2c3aa2.

## November 4, 2026: MIT License (7047a64)

November 4, 2026, evening (owner's decision, coordinator): **MIT
License.** The owner plans to make the repository public and to put a
simple site at armadale.dev (bought at Namecheap; a logo and a DMG link;
GitHub Pages, free once the repository is public). Options weighed:
plain MIT, MIT with the Commons Clause, the marketplace-only variant of
it (as joseph/mud uses), BSL/FSL and AGPL; the owner first chose
"anyone can read and fork, only I ship it through stores", then plain
MIT for simplicity, as SwiftTerm, Ghostty and the persistence helper
are. Added: `LICENSE` (MIT, the owner's name), `CONTRIBUTING.md`
(contributions under the same license), `THIRD_PARTY_LICENSES.md`
(SwiftTerm's and the persistence helper's MIT notices in full, credits
for the six built-in palettes) and a README "License" section. Still to
do before the switch to public, each for its own go-ahead: a scan of the
history and scripts for anything that should not be public; the notices
shipped inside the app bundle with a Help › Acknowledgements item (the
MIT condition is that the notice accompanies every copy, and the DMG is
a copy; in-app text must say "persistence helper", never the helper's
name); the site under `docs/` (GitHub Pages serves a branch root or
`docs/`, and Actions are off) with the DMG as a GitHub Release here (`releases/latest/download/Armadale.dmg` as a stable
link); Namecheap DNS (A records to GitHub Pages, `www` CNAME, domain
verification TXT) and Enforce HTTPS, which a `.dev` domain requires; a
notarized DMG from a full `scripts/release.sh` run, since the installed
build is made with `--skip-notarize`. The repository visibility change
is the owner's to flip.

Committed as 7047a64.

## November 4, 2026: ready to go public: scan, Help › Acknowledgements, the site (7fc2e32)

November 4, 2026, later evening (owner: "go with all three"; coordinator
scan and site, implementer → reviewer loop for the code, no live UI as
the Mac was not declared free): **ready to go public.** (1) **Scan:** all
80 commits and 663 unique blobs grepped for key material (private keys,
GitHub/AWS/Slack/Anthropic token shapes, JWTs): none. The tree holds
the team ID, the bundle id, the notary profile name, the Lima VM name
and `/Users/donny` in test fixtures, none of them secret; HANDOFF and
AGENTS describe this Mac in detail, which is the owner's call. Ever-
tracked paths: only `.github/workflows/ci.yml` and superseded sources
were deleted; no plist, key or env file was ever committed. (2) **Help ›
Acknowledgements:** `Armadale/Resources/Acknowledgements.txt` (SwiftTerm's
and the persistence helper's MIT notices verbatim, the palette credits,
never the helper's name), `Armadale/Help/AcknowledgementsWindowController.swift`
(one window kept by the app delegate like Keyboard Shortcuts, read-only
selectable monospaced text, hidden in menu bar mode), the Help menu item
without a shortcut, `AcknowledgementsTests` (the file cannot gain a
notice the bundle lacks; no "zmx" in the resource). Review: no blocker;
low findings fixed by the coordinator (DESIGN no longer claims the two
files "cannot drift"; the inert find-bar lines dropped; the text view
is the window's initial first responder; the About panel's "All rights
reserved" now reads "MIT License"). Accepted: no test checks the app
bundle itself for the resource (the reviewer confirmed it by hand);
`showAcknowledgements` is covered by reading, not a test. **Not checked
live:** the window's look in light and dark, ⌘W, bring-to-front on a
second request, menu bar mode hiding; `scripts/check-quit.sh` not re-run
(the quit code is untouched). (3) **Site:** `docs/index.html`, `docs/CNAME`
(armadale.dev), `docs/.nojekyll`; icon, name, tagline, a Download button
to `releases/latest/download/Armadale.dmg`, an All releases link and a
Source link, dark mode, phone width; the reviewer's contrast finding
fixed (dark text on the accent, 5.6:1). README "Releasing" gained step 4
(tag, `gh release create` with the DMG uploaded under its versioned
name and as `Armadale.dmg`) and "The website" (Pages from `main`
`/docs`, DNS records, Enforce HTTPS). Every GitHub link on the page is
dead until the repository is public, Pages is on and a release carries
`Armadale.dmg`. Tests: 692, zero warnings.

Committed as 7fc2e32. The owner then enabled Pages (main, `/docs`), set
the Namecheap records, verified the domain and ticked Enforce HTTPS once
GitHub's DNS check (stale for ~30 minutes after the records changed) and
the Let's Encrypt certificate came through; https://armadale.dev is live
(November 4, 2026, late evening).

## November 5, 2026: the release DMG's Finder window, and 0.1.1 (a39f3ab, 7560281, ade6f27)

November 5, 2026, after midnight (owner: 0.1.1, dmgbuild, go; implementer
→ reviewer loop, no Finder on screen): **the release DMG opens to a
designed Finder window.** `scripts/fetch-dmgbuild.sh` installs dmgbuild
1.6.5 (with ds_store 1.3.1 and mac_alias 2.2.2, the newest for Xcode's
Python 3.9.6) into the git-ignored `Vendor/dmgbuild` venv from
`scripts/dmgbuild-requirements.txt` (sha256-pinned, `--require-hashes
--only-binary`, `PIP_CONFIG_FILE=/dev/null`), stamping the requirements
file's hash so `--check` catches a changed pin or hash.
`scripts/render-dmg-background.swift` draws `scripts/dmg/background.png`,
`x.png` and the two-representation `background.tiff` (600 × 400 pt,
#F5F5F7 ground, a #6E6E73 arrow between the icon spots, caption "Drag
Armadale to Applications" at y 320) deterministically; `scripts/dmg/settings.py`
places Armadale.app at (150, 200) and Applications at (450, 200), 128 pt
icons, 13 pt labels, window {{200, 250}, {600, 400}}, sidebar/toolbar/
status/path bars off, the hidden files parked at (900, 900), the volume
icon made at release time with iconutil from the appiconset. `release.sh`
checks dmgbuild in Preflight (and that no volume named Armadale is
mounted), builds the DMG with it, then mounts the image unbrowsed and
checks inside before signing: the app identical to the archive (`diff
-r`), `codesign --verify --deep --strict`, `stapler validate` on the
notarized path, the Applications link, the background, the volume icon
flag and `.DS_Store`; an EXIT trap detaches on failure. `DMGLayoutTests`
checks the committed images' pixel sizes and DPI and the settings values.
Review: no blocker; the medium (nothing checked inside the image) and
the lows fixed as above; accepted: no Python version guard (documented).
**Not checked:** how Finder draws the window (whether `WindowBounds` is
the content size or the frame, the 2x background on Retina, the volume
icon on the desktop); the owner opens the notarized DMG. Verified
without UI: a `--skip-notarize` run passes every in-image check; a
broken app copy fails it and the image is detached. Tests: 695, zero
warnings.

Committed as a39f3ab (rebased over two GitHub-made CNAME commits from the
Pages settings). Then `scripts/bump-build.sh --version 0.1.1 --commit`
(7560281, build 27), a full `scripts/release.sh` run (app and DMG
notarizations Accepted, stapled ticket validated inside the image,
Gatekeeper "Notarized Developer ID" for both), tag `v0.1.1` at 7560281,
and GitHub release v0.1.1 with `Armadale-0.1.1.dmg` and the same file as
`Armadale.dmg` (the site's stable link; checked: the download redirects
to it, the bytes match, `spctl` accepts, `stapler validate` passes). The
first public release (November 5, 2026, afternoon). The owner has not yet
opened the DMG to judge the Finder window, nor installed 0.1.1
(`~/Applications/Armadale.app` is still the earlier 0.1.0 build).

Committed as ade6f27. The owner judged the DMG window "great" and
installed 0.1.1 (November 5, 2026).

## November 5 and 9, 2026: Help › Acknowledgements checked live (8ef4178)

November 5 and 9, 2026 (owner: Mac free; live-check agents only, no code
changes): **Help › Acknowledgements checked live**, light and dark
(dark forced on the test build by a tiny injected dylib setting
`NSApp.appearance`; `DYLD_INSERT_LIBRARIES` is dropped when the launch
goes through `env` or `nohup`, so export it and exec the binary directly):
the window, wrapping, overlay scrollbar, credits at the bottom, ⌘W with
"Close Acknowledgements" in File, the same window returning to the front,
⌘A/⌘C, hiding and returning in menu bar mode, and a real ⌘Q with the
quit alert ("1 session is still running"; Keep Running in Menu Bar / End
Sessions and Quit / Cancel) ending the session and exiting: all pass.
Minor: a reopened window keeps its scroll position; the alert says "keep
them running" for one session. **Found, not fixed (owner's go needed):
menu bar mode does not activate the app.** With Armadale accessory and
Terminal active, Settings… from the status item (pressed through
accessibility) opens the Settings window under Terminal's front window,
drawn inactive, the menu bar still Terminal's; Help › Acknowledgements
then lands behind Settings. `showSettings` and `showAcknowledgements`
call `NSApp.activate()` (cooperative since macOS 14), which the system
refuses when the active app does not yield; whether a real mouse click
on the status item counts as the user event that would let it through
is untested (the click lies in the top-right region agents avoid).
Candidate fix: `activate(ignoringOtherApps: true)` or a temporary
`.regular` policy while an auxiliary window is shown, then a live check
with a real status-item click. Incidents: on November 5 an agent's click
hit a Calendar notification banner and opened Calendar (rule added to
AGENTS.md with the modifier-key and clipboard rules); the same agent
cleared the owner's clipboard after a copy test. The local `build/` and
`Packages/*/.build` folders were deleted on the owner's request
(November 9).

Committed as 8ef4178.

## November 9, 2026: menu bar mode activates the app again (dcdeb50)

November 9, 2026, evening (owner's go, Mac free; implementer → reviewer
loop with real status-item clicks under the new window-layer rule):
**menu bar mode activates the app again.** Reproduced with a real click:
Settings… and Open Armadale from the status item left the other app
active (cooperative `NSApp.activate()` refused; a switch to `.regular`
first refused too). Fix: `AppActivation.bringForward(allWindows:)` in
`Armadale/App/MenuBarMode.swift` activates with
`NSRunningApplication.current.activate(from: frontmostApp)` when another
app is frontmost (not deprecated; let through on macOS 27 though the
header documents it for a yielding app; the result is checked and a
refusal falls back to `NSApp.activate()`), used by Settings, Keyboard
Shortcuts, Acknowledgements and Open Armadale (the last with
`.activateAllWindows`). Decision (coordinator, owner may overrule):
Settings and the Help windows shown from menu bar mode keep the
accessory policy, so no Dock icon appears and the menu bar stays the
previous app's; key equivalents work. Also: the quit alert agrees in
number for one session ("keep the session running … end the session
later. Ending the session stops every program running in it."). DESIGN
§8 rewritten (its old claim that real status-menu clicks activated the
app was false). **Checked live** by both agents: Settings… from the
status item makes Armadale active with the window in front and drawn
active; Open Armadale brings the workspace forward, regular, with
Armadale's menu bar and Dock item; ⌘W returns to the previous app; the
one-session alert text. Review: no blocker; lows: result ignored (fixed
by the coordinator), the Help items are not reachable from the status
menu so their change is for consistency only. **Open, found by the
reviewer, unverified:** the quit alert for a Dock or script quit still
uses plain `NSApp.activate()` and DESIGN says it "brings it forward";
after ⌘W on Settings in menu bar mode the app reported `hidden false`
where DESIGN says it hides. Not tested: Open Armadale while already
frontmost; ⌘Q from Settings in accessory mode. Tests: 696, zero
warnings.

Committed as dcdeb50.

## November 12, 2026: the quit alert comes forward again (704a941)

November 12, 2026 (owner's go, Mac free; a short live check by the
coordinator, then the fix through the gate): **the quit alert comes
forward again.** The reviewer's first open item was real: with
Terminal active and a shell session running, a scripted quit opened the
alert behind Terminal's front window with Armadale inactive (the plain
`NSApp.activate()` refused, as for Settings). Fix: the alert uses
`AppActivation.bringForward()` too (`askAboutRunningSessions`,
`Armadale/App/AppDelegate.swift`); checked live the same way: Armadale
active, its own menu bar, the alert in front. The second item was a
probe artefact: after ⌘W on Settings in menu bar mode Terminal was
frontmost again, as designed; `NSRunningApplication.isHidden` stays
false for an accessory app after a successful `hide` (`NSApp.isHidden`
is true; confirmed with a windowless accessory app). DESIGN §8 records
both. Also seen: Settings… from a real status-item click came up in
front and active (dcdeb50 holds). Still not tested: Open Armadale while
already frontmost; ⌘Q from Settings in accessory mode. The installed
0.1.1 has neither activation fix; a new release would ship them. Tests:
696, zero warnings.

## November 12, 2026: an architecture review (298e881)

An architecture review was recorded at the end of `HANDOFF.md`'s open
items. The three findings below were built on November 14, 2026 and
moved here; the rest stay open there.

Findings from reading the documents and the code. Nothing was built or
run, so none is reproduced live, and none is started. Suggested order:
the orphan reclaim and the save scheduling first (small, in
`ArmadaleCore` and `AppDelegate`, testable without launching the app),
the schema rule before the next change to the state file's shape, then
the documents; attaching restored sessions at launch needs an owner
decision on pane sizes and is a step of its own.

- **Orphan reclaim is held back for one launch only.** After an
  unreadable state file (`.unparseable`, with or without a usable
  backup) `stateLoadedCleanly` is false and nothing is killed, but
  that run saves a clean file (`ensureWorkspacesToOpen` makes a
  workspace, the quit flushes). The next launch loads it cleanly and
  `OrphanReclaimer` ends every live session it does not name: all of
  them after a fresh start, those newer than the backup after a
  recovery. The quarantined `state.json.corrupt-<time>` is kept, but
  the sessions it names are gone by then. Possible: save with the
  state that its references are incomplete, and reclaim only sessions
  created after that. **Built November 14, 2026** (below): the
  flag is `sessionListIncomplete`, and the sessions found are spared
  for good instead of being told apart by age.
- **No rule for an older build reading a newer file.** The schema is
  still 1 with additive decoding (`Migrations.steps` is empty), which
  DESIGN section 3 justifies for a new build reading old files. Since
  v0.1.0 an older build is a real reader: a change it cannot decode,
  made without a version bump, is `.unparseable` there (quarantine,
  fresh start, then the reclaim above) instead of the safe
  `.newerVersion` alert, and a key it does not know is dropped by its
  next save. Rule to adopt: bump `schemaVersion` whenever a released
  build could not decode the file. No test reads a state file written
  by a released version; a fixture per release would hold the rule.
  **Built November 14, 2026** (below): the rule, schema 2, a
  fixture per release, and `scripts/check-state-compat.sh`.
- **Save scheduling.** Every title change (`AppModel.setTitle`, OSC
  0/2) increments `changeCount`, and `StateSaver.schedule` restarts
  its 500 ms timer on every change with no longest wait, so programs
  that keep changing their titles (several agents at work) can put
  layout saves off until the model is quiet or the app quits; a crash
  meanwhile loses them. New sessions are safe
  (`onRuntimeVersionRecorded` saves at once). `state.json.bak` is
  replaced by every save (`StateStore.rotateBackup`), so two saves of
  a bad state leave no good copy; a backup kept once per launch would.
  **Built November 14, 2026** (below): a longest wait of 2 s,
  and `state.json.launch.bak` beside the per-save backup.

## November 14, 2026: the architecture review's second pass (75a22c8)

A second pass of the review, recorded after the first in `HANDOFF.md`.
The instance lock below was built the same day, and the orphan reclaim
addition in part; the other findings of the pass stay open there.

The findings above were read against the code again and stand. Three
are new and three add to ones above. Again from reading only: nothing
was built or run, none is reproduced live, and none is started.
Suggested order now: the instance lock first (small, and it closes one
way into the orphan reclaim), then the orphan reclaim and the save
scheduling, the schema rule and the documents as above; attaching
restored sessions at launch stays a step of its own.

- **New: nothing stops two Armadale processes sharing one state
  directory.** There is no lock (no `flock`, no
  `LSMultipleInstancesProhibited`), `StateLocation.directory` falls
  back to the real `~/Library/Application Support/Armadale` whenever
  `ARMADALE_STATE_DIR` is unset, and the scheme's Run action in
  `project.yml` sets no environment, so isolation rests on AGENTS.md's
  rule alone. A test build started without the variable while the
  installed app runs loads the same `state.json` and attaches to the
  same sessions; each process then saves its own model over the
  other's (`StateStore.save`, last writer wins), a pane closed in one
  ends a session the other shows, and a session created in the process
  whose save loses is unreferenced at the next clean launch, where
  `OrphanReclaimer` ends it. Possible: an exclusive `flock` on a file
  in the state directory, taken in `AppDelegate.init` before
  `StateStore.load` and held for the life of the process (a second
  process explains and quits, or activates the first), and an
  `ARMADALE_STATE_DIR` in the scheme's Run environment. Test builds
  with their own state directory are unaffected. **Built November 14,
  2026** (below).

- **Adds to "Orphan reclaim".** It is the only code that ends sessions
  the user did not ask to end, and it does so by set difference
  against one file. Instead of only widening the hold-back, the rule
  could change: ask before ending ("N sessions are running that no
  pane shows"), or write a small record per local session beside its
  socket at create (the `Session` value) so that unreferenced live
  sessions can be offered back as panes after a lost state file. A
  daemon left running costs a few megabytes; an agent ended by mistake
  can cost hours of its work. DESIGN section 1's "never adopts
  sessions created elsewhere" would still hold (these are Armadale's
  own). Owner decision; hosts are a separate question, since several
  Macs may share a host's `~/.armadale`. **Partly built November 14,
  2026** (below): the reclaim now spares what it cannot account
  for, but nothing shows the spared sessions or offers them back; that
  part is still the owner's decision (open items, Session layer).

An architecture review on November 12, 2026 added candidates of its
own, with a suggested order: "Architecture review" at the end of the
open items in `HANDOFF.md`. A second pass on November 14, 2026 added three
findings and put a new one first, a lock against two processes
sharing one state directory: "Architecture review, second pass",
after it. The lock, the orphan reclaim and save scheduling changes,
and the schema rule are done (November 14, 2026, below). The
owner gave the go-ahead the same day for the rest in the suggested
order, which leaves the documents. Attaching restored sessions at
launch, showing or re-adopting spared sessions, and a fork of the
persistence helper still wait for owner decisions.

## November 14, 2026: one Armadale process per state directory (ab27dfe)

November 14, 2026 (implementer → reviewer loop on Opus 5.5, two review
rounds, three live passes): **one Armadale process per state
directory**, the first item of the architecture review's second pass.
`StateLock` (ArmadaleCore) takes an exclusive `flock` on
`armadale.lock` in the state directory, close-on-exec, held for the
life of the process; `AppDelegate.init` takes it before
`StateStore.load`. A second process on the same directory loads and
saves nothing, starts no helper, shows "Armadale is already running",
writes the holder's pid and the lock file to standard error and the
log, and quits through the fatal launch path; after the alert it
brings the other copy forward when that is a regular app. A lock that
cannot be taken at all (no `flock` on the volume) is logged and the
app runs without one. A fatal launch (this one, a newer or an
unreadable state file) now brings itself forward with
`AppActivation.bringForward()` and ignores a reopen while its alert is
up. The scheme's Run action sets `ARMADALE_STATE_DIR=/tmp/armadale-dev`
and `ARMADALE_DEFAULTS_SUITE=armadale-dev` (Profile inherits them; the
test action does not, through a disabled placeholder variable that
XcodeGen needs). `docs/DESIGN.md` sections 3, 8 and 11; README. Checked
live, all on test builds in `/tmp/armadale-lock`: the refused copy's
alert text read on screen, matching `InstanceLock.refusal` word for
word; the state directory's listing identical before, during and after
it; Return dismissing it, the copy quitting by itself and the first
copy coming forward; SIGTERM with the alert up ending it in about
60 ms; a session started from the chooser whose daemon, trampoline,
shell and client held no descriptor on the lock; a relaunch taking the
lock while that daemon ran; a refused copy while the first was in menu
bar mode (alert shown, the first not activated, its windows still
hidden); `scripts/check-quit.sh`, three scenarios. Known limit: builds
before this one, 0.1.1 included, take no lock, so the installed app
and a new build are not kept apart until the installed app is
replaced; AGENTS.md's isolation rule still stands. Seen on the way: a
normal launch started from a shell does not come forward (open items,
Hierarchy and UI). Tests: 711 at this change (236 app + 247 core + 206
sessions + 13 + 9).

## November 14, 2026: reclaim and save safety (64221bb)

November 14, 2026, after the instance lock (same loop, three fix
rounds, five live passes, all without input): **reclaim and save safety**, the review's orphan
reclaim and save scheduling findings. The state file gained two
fields, in schema 1 at that commit: `sparedSessionIDs`, sessions the
orphan reclaim must never end, and `sessionListIncomplete`, set
whenever a launch did not read `state.json` as written (a first
launch, a missing
or unreadable file, a recovery from a backup) and cleared once that
launch has recorded what was running. A launch that may not reclaim
ends nothing and spares every live session no saved session names,
and every session whose socket exists in the runtime directory: the
helper's listing leaves out a daemon that does not answer within about
a second and still succeeds (measured with `kill -STOP`: exit 0 after
1.06 s, nothing printed). The list never shrinks by itself. A launch
that read a complete file ends only what is listed, unnamed and not
spared, as before. Spared sessions are invisible: no pane shows them
and End Sessions and Quit leaves them alone (open items, Session
layer). The launch housekeeping keeps the logs and exit files of
sessions that are listed or have a socket. `StateSaver` keeps its
500 ms debounce and has a longest wait of 2 s from the first unwritten
change; a retry pending after a failed write keeps its own time.
`state.json.launch.bak` is the file a launch read successfully, copied
before that launch's first save and tried after `state.json` and
`state.json.bak`; the recovery alert names the backup it used, and a
fresh start now means removing all three files. `docs/DESIGN.md`
sections 3, 4, 8 and 13; README. Checked live on test builds in
`/tmp/armadale-reclaim`: unreadable `state.json` and `.bak` with a
running session (spared, alive after the next clean launch, still
listed as spared after it was ended by hand); a hand-written file
carrying the flag with nothing spared; a file without the new fields
(the stray session ended, as before); SIGKILL at eight moments of an
unclean launch; a stopped daemon the listing left out (spared by its
socket, its log kept, counted as running); a first launch and a
recovery leaving a good launch backup untouched, three unreadable
files, a newer-version launch backup (fatal, nothing moved); the alert
texts read on screen; `scripts/check-quit.sh`. Not staged live: a
failing disk under a stream of changes (the retry timing has unit
tests only; one attempt with a read-only state directory produced no
save attempt at all, not looked into). Known limit: 0.1.1 ignores both
fields and drops them at its next save, after which its own reclaim
would end spared sessions. Tests: 748 at this change (244 app + 265
core + 217 sessions + 13 + 9).

## November 14, 2026: a rule for the state file's version, schema 2 (d34d3af)

November 14, 2026, after the reclaim change (same loop, two review
rounds; one live check with the owner's leave, the rest code and
scripts): **a rule for the state
file's version, held by fixtures.** The rule (`docs/DESIGN.md` section
3): `schemaVersion` is bumped whenever a released build could not
decode the file, or would decode it and lose something whose loss is
unsafe; a released build answers a newer file by reading it without
loss or by refusing it by version, never by treating it as damaged.
Applied at once: **the state file is schema 2**, with a first
migration step from 1 that changes only the version. Two reasons,
both read from the tags: 0.1.0 has a non-optional `Pane.sessionID`
and so cannot decode the empty panes 0.1.1 and later save, and 0.1.1
would drop `sparedSessionIDs` at its next save. So a state directory
saved by a build from this change on is refused by 0.1.0 and 0.1.1
("This version of Armadale is too old for your saved layout"); they
leave state files and sessions alone, but before that alert they
install their own helper copies in `bin/` and remove other versions'
copies there (open items, Shipping). Fixtures: one saved state per
release, written by that release's own code in a temporary worktree
of its tag (`Packages/ArmadaleCore/Tests/ArmadaleCoreTests/Fixtures/`;
generators, and how to add the next one, in `scripts/state-fixtures/`),
with tests that the working tree reads them. From the other side,
`scripts/check-state-compat.sh` gives every release tag a file written
by the working tree and fails when one treats it as damaged, or reads
it and would save it back with something lost that
`scripts/state-fixtures/accepted-drops` does not list; with today's
file set back to schema 1 it reports 0.1.0 as unparseable and 0.1.1
as losing the spared list and its flag. It is not part of the gate
(about 18 s, it builds the old versions): run it before a release and
whenever the state file's shape changes (README, "Releasing"). On the
way: every fatal launch (another copy holds the lock, a newer file, an
unreadable file) now installs no helper, prepares no runtime and
removes no stale temporary file, checked live once at schema 99 with
decoy helper copies in a test directory (only the lock file changed;
the control launch at schema 2 removed the decoys); and a JSON
boolean is no longer taken for a version. `docs/DESIGN.md` sections 3,
8, 11 and 13; README. Tests: 761 at this change (248 app + 274 core +
217 sessions + 13 + 9).

## November 14, 2026: the documents split (fe20ea1)

The architecture review's finding, as recorded on November 12, 2026
("this file" is `HANDOFF.md`): **The documents.** `docs/DESIGN.md` is
235 KB (3,644 lines, section 8 alone 1,440) and this file 84 KB, and
AGENTS.md has every agent read both before changing code. DESIGN.md
mixes the contract with its history: 69 lines carry an October 2026
date or "until then". Separating what is true now from a decision log,
and cutting this file's Status to the current state, would make the
contract findable.

The second pass's finding, November 14, 2026: **New:
`docs/DESIGN.md`'s status paragraph is out of date.** Line 7 still
says "Status (October 19, 2026). All nine steps", before step 10 and
both releases (v0.1.0, v0.1.1). Small by itself; an example for "The
documents" above.

Done the same day. `docs/DESIGN.md` (3,900 lines by then) keeps what
is true now, in the present tense, under the same 13 sections and the
names the code refers to; its history moved to Part 2 of this file
under the same numbers, and its status paragraph went with it (Part
2, "Document header"). `HANDOFF.md` (1,671 lines by then) was cut to
where things stand; its status accounts became Part 1 of this file.
Four `###` headings of DESIGN changed: "New sessions: the chooser, the
dialog and favorites", "Quitting with running sessions: menu bar
mode" and "Release pipeline" lost a date or a step in parentheses,
and "Step 7: what was built" became "Attention and notifications";
`scripts/release.sh` line 3 follows. AGENTS.md says where each kind
of text goes from now on.

How it was done and checked: seven agents (Opus 5.5) rewrote the two
documents in parallel, six on ranges of DESIGN and one on HANDOFF,
each into files of its own, under the rule that nothing is lost and
history is moved in its own words; where the document and the code
disagreed they followed the code. The parts were assembled and
checked mechanically (every backticked term of both old documents is
in one of the three new files; every named reference into DESIGN from
code, scripts and documents resolves inside its section), then by
three reviewers. One measured how much of each of the 2,048 old
sentences survives in the new files and read every sentence that
scored low; the only losses were the two findings quoted above. Two
checked sections 1 to 7 and 8 to 13 against the code: the listings,
the tables, every number, and a sample of behavioural statements in
each section. None found a blocker. Their findings were applied;
almost all were places where the old document had already drifted
from the code, among them the `$HOME` length at which the runtime
directory falls back to `/tmp/armadale-<uid>` (43 bytes, not 64), the
list of environment variables removed for new sessions, the compact
chooser card's geometry, a missing ⌥⌘R row in the shortcut table, and
two references to a label "Session Ended" that did not exist (it is
section 4, "Ended"). Stale comments in the code that the reviews
turned up were corrected with them, comments only.

What it did not achieve: DESIGN is still about 3,700 lines, because
the contract keeps every behaviour and only its history left (section
8 alone is about 1,350). Whether an agent may read sections 1 and 2
and only the sections it changes was the owner's rule to relax. Asked
the same day, after the commit, the owner kept it: every agent reads
all of DESIGN and `HANDOFF.md` before changing code. That closed the
open item "The documents" in `HANDOFF.md`, which was removed there. On
the Mac used that day there was no installed Armadale, no Lima and no
Codex (`HANDOFF.md`, "State of this Mac that matters").

## November 14, 2026: restored sessions are attached at launch (7353b3a)

November 14, 2026, after the documents split (implementer → reviewer
loop on Opus 5.5: four implementer rounds and three review rounds, the
first two with full builds and mutations in a copy, the third by
reading; **no live pass**, because the owner had not said the Mac was
free): **restored sessions are attached at launch**, the step the
architecture review had left for an owner decision. The three findings
it answers, as they stood in `HANDOFF.md` until this change:

- First pass. **Restored sessions in tabs not shown yet are not
  attached.** `SessionRegistry.startIfNeeded` is called only for the
  panes of a window's selected tab (`ContentViewController.show`) and
  by `retryPersistence`, as DESIGN section 8 "App lifecycle" says
  ("the rest lazily when their tab is first shown"). Until then a
  restored session has no client, so its bell or OSC 9 / 777 never
  reaches `AttentionCenter`: no ◐, no badge, no notification, for an
  agent that finished in a tab not visited since the relaunch.
  Attaching every live restored session after launch needs a size
  before the pane is laid out (an attach at another size resizes the
  program); saving each pane's last grid size would give one.
- Second pass. **New: the status of a session never shown is the
  launch probe's answer, and is never refreshed.** For a restored
  session without a controller, `SessionRegistry.status(of:)` answers
  from `liveAtLaunch` (local) or `remoteLive` (hosts), which are set
  when the launch probe answers, after a successful
  `retryPersistence`, and for a host by Respawn All Ended's listing. A
  session that ends in a tab not visited since the launch therefore
  stays `.running`: in its tab's and the sidebar's glyph, and, through
  `CloseRisk.mayBeRunning`, in `runningSessionCount()`, which is what
  the quit question and the status item's menu show. It is corrected
  when the tab is first shown. Same cause as "Restored sessions in
  tabs not shown yet are not attached", and attaching them at launch
  removes it.
- Second pass. **Adds to "Restored sessions in tabs not shown yet are
  not attached".** A controller exists only inside a pane view
  (`SessionRegistry.panes` is `[SessionID: PaneView]`, and
  `controller(for:)` reads it from there), which is why nothing can be
  attached before it is shown, and why `status(of:)`, `isEnded`,
  `riskItem`, `close`, `endAllSessions`, `sessionsRunning(after:)`,
  `respawn` and `closeRestoredSessionsThatEndedCleanly` each have a
  second path for a session never shown. A registry that holds the
  controllers itself, with the pane view made when a pane is first
  shown, makes the attach at launch possible and lets those paths go.
  `SessionRegistry` (868 lines) and `AppDelegate` (955) are best split
  in that step, not before.

The owner's decisions. The design was put to the owner with four
questions, and the answer the same day was "Go ahead with the
recommended answers for all four". So: a session with no saved size is
left unattached until its pane is first shown, as before (over
attaching it at 80×24, which resizes every such program twice, and
over reading its size from the helper's log, which does record it but
only locally and in a debug line); sessions on hosts are attached too,
once the host's first listing has answered; a few at a time, the panes
on screen first; and the memory of a surface and a client per session
is accepted, with a fleet of about 20 to be measured.

What was built. `SessionRegistry` owns one `SessionController` per
session in the model; a controller makes its surface when it first
connects or is shown, and a `PaneView` is made around it when its pane
is first shown. Each session's last grid size (`Session.gridSize`: the
columns and rows last applied to its program) is saved, recorded
500 ms after it settles and flushed before the save at quit; the
state file stays schema 2 (`scripts/check-state-compat.sh` answers
`newerVersion` for v0.1.0 and v0.1.1, so no bump and no accepted
drop). Once `AppDelegate` has opened its windows and the listing has
answered, every restored session that is alive and has a saved size is
attached at that size, four at a time locally and two per host; the
panes on screen are started when shown, at their laid-out size, and go
first; a session that is gone is ended through its controller with its
exit record. The second paths for sessions never shown are gone, and
one "not attached" case is left, where the launch listing still gives
the status. `SessionRegistry.swift` is split into `PaneViewStore`,
`SessionRegistry+LaunchAttach`, `SessionRegistry+Remote`,
`SessionRegistry+Delegate` and `GridSizeRecorder`, with the choice of
what to attach next in `ArmadaleSessions` (`LaunchAttachPlan`,
`LaunchAttachQueue`), pure and tested. `AppDelegate` is not split in
this change. `docs/DESIGN.md` sections 1 to 8, 10, 11 and 13; README.

Decisions the coordinator made on the way, each the owner's to
overrule. The launch holds at most six of a host's sessions: every
client of a host shares one connection, sshd allows 10 sessions on one
by default, and by the reviewer's reading the kill, the listing and
new panes are refused past that; nothing of it could be checked
without a host. A local session is alive when it is listed, or when
its socket is still there after the listing and it has no exit record,
and every local decision that ends or shows a session uses that one
rule, inside the helper driver's attach and create too; a daemon that
does not answer is therefore attached and shows nothing until it does,
where the design as put to the owner said it would show as
disconnected. A session whose pane has not been shown in the run never
starts a sign-in by itself on an automatic retry; it reconnects, once,
when its pane is first shown. Two costs were accepted and written
down: a font or size change while such a session is attached can give
two resizes when its pane is first shown, and the pixel size a program
is told can stay stale on a screen of another scale.

Measured, in test harnesses through the real helper and not in the
app. The helper sends one SIGWINCH per attach to a program on the
alternate screen, whatever the size, and none to a program on the
primary screen attached at its own size, pixels included; an attach
with the same grid and other pixels sends one, which is why the size
is no longer sent again after connecting unless columns or rows
changed. That explains the open item "One extra SIGWINCH reaches each
pane after relaunch" for full-screen programs. 24 sessions were
attached in about 1 s at four in flight and in about 0.4 s all at
once, with no attach missing its 2 s even with every core busy, so the
pacing was kept for the reason given and not because a miss was seen.
20 attached sessions cost about 1.3 MB each in the test process and a
2.4 MB client each. A stopped daemon is left out of a listing that
succeeds after about a second, and an attach to it returns at once and
shows nothing until it runs again. Of 400 sessions that ended normally
(a clean exit, a non-zero exit, a death by signal, a command that does
not exist; idle and under load) none had its socket outlive its
listing entry and all resolved as ended.

What the reviews found, all fixed before the commit: setting the saved
size on a terminal that already sat in a pane view left it out of step
with its card (after Respawn All Ended in tabs visited earlier, and
after Retry); a pane shown before the listing answered was counted
twice in the queue, which could exceed the limit and lose its one
retry; the launch pass could start before any window existed; the
helper driver's own "is it gone" still went by the listing alone and
would have killed a stopped daemon's session after a failed attach; a
host's answer reconnected the stopped sessions of every host, so a
pane nobody saw could have sat at another host's password prompt; and
four tests did not test what their names said. Each fix has a test
that fails when the fix alone is reverted (the implementer's check for
every fix, repeated by the reviewer with its own mutations for the
first two rounds). The three build-system `warning:` lines in a clean
gate log (the App Intents metadata step, and the test bundle's
dependency on the app) are in the log at the commit before this one
too.

Resolved, and removed from `HANDOFF.md`: the three findings above (the
registry's half of the split; `AppDelegate`'s follows), and the local
half of "The helper's listing leaves out a daemon that does not
answer". What it leaves open is there: sessions without a saved size
until each has been shown once, where the old staleness remains; the
host half of the listing's gap; a daemon that never answers, which is
never ended; the limit of six and what lies past sshd's ten; and the
two accepted costs.

**Not checked live: all of it.** No app was launched and no host was
available (no Lima on the Mac used). The checks to make are listed in
`HANDOFF.md` under "From finished changes". Tests: 834 at this change
(291 app + 281 core + 237 sessions + 13 + 12).

## November 14, 2026: `AppDelegate` and `SessionRegistry` split into files (8d6bb99)

November 14, 2026, straight after the change above and as its second
commit (same implementer and reviewer, one round each; no live pass):
the split the architecture review's second pass had asked for in that
step, kept apart so that the review of the behaviour was not buried in
moved lines. `AppDelegate.swift` (1,157 lines) keeps its stored state,
`init` and the application delegate's entry points (277 lines), with
`AppDelegate+Launch`, `+Quit`, `+MenuBar`, `+Windows`, `+Actions`,
`+Attention` and `+Saving` beside it; `SessionRegistry.swift` (811
lines after the fixes of the change above) keeps its state,
controllers and starting (537), with `SessionRegistry+Ending` and
`SessionRegistry+Status` added to the three files of the change above.
**Code moved only**: no statement changed and nothing was reordered,
checked against 7353b3a by three comparisons, two of which keep order
(Part 2, section 11). 36 members of `AppDelegate` lost `private`
because they are now used from another file; none in the registry.
`docs/DESIGN.md` sections 8 and 11. The gate: 834 tests, as before,
zero warnings. **Not run:** `scripts/check-quit.sh`, which launches
the app; it is the check for the quit paths that moved, and it is on
the list of live checks in `HANDOFF.md`. This closes the review's
finding on the size of the two files, removed from `HANDOFF.md`.

## November 14, 2026: the live checks of attaching at launch

November 14, 2026, late afternoon, once the owner had said the Mac was
free: the live checks of the two changes above, on the Debug build of
8d6bb99 with its own state directory and defaults suite. The reviewer
made three passes and the implementer one; no code changed. Nobody
sent a synthetic keystroke or click: sessions were made with the
helper and tabs written into `state.json`, the app was driven by
accessibility actions on its own elements by pid (sidebar rows, the
window's size, menu items, alert buttons), and everything was read
from files, process lists, the log, the helper's listing and the
accessibility tree. Screen Recording was not granted, so nothing was
seen as a picture.

What was checked, and held. A bell and an OSC 777 notification from
tabs not shown since the relaunch raised attention (the Window menu's
attention items became enabled, and Next Pane Needing Attention went
to the right tab), and the replay alone raised none. The quit question
went from 8 running sessions to 7 when a program died in a tab not
shown, Respawn All Ended became enabled, and a clean exit there closed
its tab. A program at a prompt got no SIGWINCH at a relaunch at its
saved size and none when its tab was then shown with the window
unchanged; a real window resize gave exactly one, and a full-screen
program one per attach, the helper's. With thirteen tabs and the last
selected, the selected tab's client started first, then three more,
then the rest. With every saved size removed from the state file, only
the tab on screen had a client until another was shown, and a quit
saved sizes for those two. A stopped daemon's session was attached,
counted as running and never ended, also when its client was killed
twice; its pane closed left one line in the log. Respawn All Ended
after the tabs had been visited and the window resized created each
session at its pane's size. The new size was saved after a resize
followed within 0.2 s by SIGTERM, by Keep Running in Menu Bar and then
Quit, Keep Sessions Running, and by End Sessions and Quit; five resize
steps wrote `state.json` once. `scripts/check-quit.sh` passed (about
60 ms each). Twenty attached idle sessions: a footprint of 55 MB and
no CPU. A font size change while sessions were attached in tabs never
shown gave one resize when one was shown.

What was found. First, one SIGWINCH per relaunch at an unchanged size
in the reviewer's first pass, none in the implementer's twelve
relaunches; the reviewer's third pass traced it to its own staging: a
session the helper's `send` or `run` has touched gets one at every
later attach, and sessions only Armadale ever attached to, one of them
made by Armadale itself, got none (Part 2, section 4). Second, five
sessions in tabs never shown, each printing 50 MB, kept the Debug
build at 100 % CPU for minutes after the output had ended, with
accessibility round trips of seconds; measured, this is the cost of
any attached session that is not on screen (a tab visited once and
left costs the same), the flood handling does trigger, and an
optimized build of the same tree is idle 2 s after the output ends
(Part 2, section 8). The coordinator accepted it as it is; four
options are recorded there, none built. Third, `scripts/check-quit.sh`
launched without a defaults suite and so used the real defaults domain
(it had left nothing behind); each of its launches has a suite of its
own now, removed at the end with literal paths, and it passed again.
Fourth, a kill that a stopped daemon could not answer is not lost:
when the daemon ran again it took the kill and ended, which
`docs/DESIGN.md` section 4 now says.

Not checked, and listed in `HANDOFF.md`: anything on a host; what only
the eye would see (the glyphs and the purple counts are not in the
accessibility tree); the Dock badge and notifications. On the last:
macOS asked for the notification permission after the first bell,
nobody answered, and it may now be recorded as a denial on that Mac
(`HANDOFF.md`, "State of this Mac that matters"). `docs/DESIGN.md`
sections 4, 8 and 13. No code changed: the implementer's gate run on
this tree passed with the same 834 tests, and the coordinator's own
last run is the one on 8d6bb99.

## November 14, 2026: the Dock badge and notifications, checked live

November 14, 2026, about 17:35, once the owner had allowed
notifications for Armadale on the Mac used that day and said it was
free: the two things the live checks above could not see. The Debug
build of cdfc8b0 (HEAD was 193d3fd, documents only; the gate had
passed on cdfc8b0 with 834 tests ten minutes earlier), with its own
state directory and defaults suite, staged the way
`scripts/check-quit.sh` stages its second scenario: a first launch
for the helper and a state file, a session made with the helper
whose program rings the bell every 10 s, and that session written
into `state.json`. The suite had "Only for agent profiles" off
(`notifyOnlyForAgents`), because the session is a shell and with the
default nothing is posted for one. Nobody sent a synthetic keystroke
or click: the Dock item's `AXStatusLabel` and the static texts of
Notification Center's banner window were read through System Events
about once a second, and Window › Clear All Attention was pressed as
an accessibility action on the build's own menu, by pid.

Two runs, and both held.
- **The session in the selected tab, Armadale in the background.**
  The build was launched with `open -g` and was never the active app.
  At the first bell after the attach, three seconds after the launch,
  the badge read "1" and a banner was up with "Shell", "Workspace /
  Main" and "Finished": the profile's name, the workspace and tab
  group, and the body of a bell (section 10). Each later bell brought
  a new banner, up for about 5 s, and the badge stayed "1". Clear All
  Attention, pressed while a banner was up, emptied the badge and
  took the banner off the screen within a second; the next bell
  raised both again.
- **The session in a tab not shown, Armadale in front.** The session
  was in a second tab, not selected, with a saved size; the selected
  tab was an empty pane; the build was launched in front and stayed
  the active app. The session's client was running within a second
  of the launch, and the first bell after that gave the same badge
  and banner. This is the path the change of that day added: a
  session attached at launch whose pane has never been shown.

In both runs, once the session had been ended with the test
directory's helper and attention cleared, the badge was empty and no
banner came in the 12 s or more that were watched. Afterwards no
process, directory, defaults file, Dock item or banner was left.

What it adds. In the live checks above, with the permission prompt
unanswered, the same `AXStatusLabel` stayed empty with attention
pending; with notifications allowed it shows, which agrees with
section 10 (a registered app's badge follows its notification
settings). The setting cannot be read from
`~/Library/Preferences/com.apple.ncprefs.plist` on macOS 27: with
notifications allowed that file had no entry for Armadale.

Not checked: what the banner looks like (Screen Recording is not
granted), the sound, Notification Center's list, a click on a
notification, menu bar mode, and anything on a host. In `HANDOFF.md`
this replaces the item on the Dock badge and notifications under
"Restored sessions attached at launch" with the click on a
notification, and the step 8 item on the badge now says what is left
on the first Mac. No code changed.

## November 14, 2026: the release pipeline and the SSH tests on a second Mac

November 14, 2026, evening. The owner wanted to sign, notarize and
release from the Mac used that day. That morning it had no signing
identity, no dmgbuild and no test host, so `scripts/release.sh`
stopped at its preflight and the SSH integration tests had been
skipped in every gate run. Nothing in the repository changed apart
from these documents.

What was set up. The owner imported the team's certificates with
their keys. The Developer ID Application identity was valid at once;
the Apple Development and Apple Distribution certificates were shown
in red as "not trusted" because the keychain held only the Worldwide
Developer Relations intermediate that expired in February 2023, and
both were issued by its successor, G3. The owner added Apple's G3
intermediate and all three identities became valid. No trust setting
had been changed by hand, which matters: an "Always Trust" set on a
certificate makes `codesign` fail later. The agent read the keychain
(`security find-identity`, `find-certificate`, `dump-trust-settings`)
and changed nothing in it. `scripts/fetch-dmgbuild.sh` installed the
pinned dmgbuild. No Homebrew software was missing for a release
(`xcodegen` and `gh` were there). The owner installed Lima and made
the VM `default`.

What was run, and held.
- `scripts/release.sh --skip-notarize --allow-existing-tag` on
  6d07126: 78 s. The app, the persistence helper and `ctty-exec`
  signed by the Developer ID identity with the hardened runtime and
  secure timestamps, the helper universal, the helpers without
  entitlements; the DMG built by dmgbuild, signed and verified;
  Gatekeeper answered "Unnotarized Developer ID" for both, as it
  should without notarization. Nothing was submitted to Apple. The
  app's signature was verified once more by hand (`codesign --verify
  --deep --strict`; chain Developer ID Application, Developer ID
  Certification Authority, Apple Root CA).
- The six tests of `SSHIntegrationTests` against the Lima VM (Ubuntu
  26.10, aarch64): deploy, create, attach and kill; the shell's exit
  status recorded on the host; a killed upload installs nothing; a
  truncated helper is replaced; a missing session is not created by
  an attach; the connection is shared. 3.7 s. Afterwards `~/.armadale`
  was removed in the VM, its home was still mode 750, the shared
  connection was closed and the VM stopped.
- `scripts/check-quit.sh` against the Release app of that dry run,
  once the owner had said the Mac was free: the app exited 57 ms
  after SIGTERM with the chooser up, 65 ms with a session attached
  (no client left, the session still alive) and 56 ms with the
  fallback alert up, saving its state each time. So a Developer ID
  build with the hardened runtime launches and runs a session on that
  Mac (section 11's concern about a restricted entitlement on a
  helper). No system prompt was left on screen afterwards.

What it found. The Developer ID Application certificate expires on
February 1, 2027 because its issuer, "Developer ID Certification
Authority", expires that day; a release after it needs a certificate
issued under Apple's newer Developer ID authority.

The notary profile, later that evening. The owner created
`armadale-notary` on that Mac from an App Store Connect API key
instead of an Apple ID and an app-specific password; the release
script names the profile only, so either kind works. The first
attempt failed at "Validating your credentials" with HTTP 403, "A
required agreement is missing or has expired", until the owner had
accepted an updated agreement in the developer account; a failed
attempt stores nothing. `xcrun notarytool history --keychain-profile
armadale-notary`, the script's own check, then listed the account's
earlier submissions. One wrong turn on the way: the agent looked for
the profile with `security find-generic-password` under the service
`com.apple.gke.notary.tool`, found nothing, and said so, although
the profile existed; on macOS 27 the profile is not an item that
command or `security dump-keychain` can see. `notarytool history`
answering "No Keychain password item found for profile" is the test.

Not done: a notarized build (nothing was submitted to Apple from that
Mac), and anything the app does with a host at launch: the SSH
integration tests drive the session layer, so the host items under
"Restored sessions attached at launch" in `HANDOFF.md` stay.

## November 14, 2026: Armadale 0.1.2 (28), built and notarized, not published (76562b7)

November 14, 2026, about 19:20, on the owner's go-ahead: a notarized
build of everything since 0.1.1, installed on the Mac used that day so
that the owner can use it before deciding to publish. The owner chose
the version 0.1.2.

- `scripts/bump-build.sh --version 0.1.2`: 0.1.1 (27) to 0.1.2 (28),
  `project.yml` only, committed as 76562b7 after the gate (834 tests,
  no warnings) had passed on it.
- `scripts/check-state-compat.sh`: the working tree writes schema 2,
  and v0.1.0 and v0.1.1 both answer `newerVersion`, the refusal the
  version rule allows (section 3).
- `scripts/install-release.sh` on the clean tree at 76562b7: archive,
  signature checks, the app notarized ("Accepted", notary log without
  issues) and stapled, the DMG built, signed, notarized ("Accepted",
  no issues) and stapled, Gatekeeper "Notarized Developer ID" for
  both, then the app installed from the DMG into `~/Applications`.
  The two submissions were the first from that Mac and its notary
  profile. The whole run took 2 min 18 s.
- Checked again by hand: the installed app is 0.1.2 (28), identical
  to the archived app, its signature verifies, `spctl` accepts it as
  "Notarized Developer ID" and its stapled ticket validates. The DMG
  is `build/release/Armadale-0.1.2.dmg`, 16,212,103 bytes, SHA-256
  `da7b29c37efab2c7919200d332f0715329bf49685d33ed5007677cde3c735596`.

Not done, on purpose: no tag, no GitHub Release, no state fixture for
the tag, no change to the website, and the installed app was not run
by an agent. What 0.1.2 has that was never checked live is in
`HANDOFF.md`, mainly what the app does with a host at launch. How to
publish this very build is under "Next" there.

## November 14, 2026: housekeeping: the state of a Mac leaves the repository, HANDOFF trimmed

November 14, 2026, late evening, on the owner's go-ahead for the
housekeeping left over from that day's review. Documents and
`.gitignore` only; no code changed.

**The state of a Mac.** `HANDOFF.md` had a section "State of this Mac
that matters": the installed app, the test host, the signing
identities, the privacy grants. That morning it had described a Mac
other than the one the work was done on (which had no installed
Armadale, no Lima and no Codex), by the evening it described two, and
the repository is public. That state is now in `HANDOFF.local.md` at
the repository root, git-ignored, one per Mac. `AGENTS.md` says what
the file holds, in a section now called "Test hosts and tools" (it was
"… on this Mac"), which no longer says that the certificate and the
notary profile "both exist on this Mac" or that Codex is installed.
`HANDOFF.md` keeps the section's name with a pointer. The section as
it stood, with both Macs, is `git show f4d8bd8:HANDOFF.md`. Nothing
was removed from the repository's history, so what it said stays
public there; the change is to what is published from now on.

**HANDOFF trimmed**, from 849 lines to about 610; it had been about
690 after the documents split that morning. What went, and where:
- The status list before the last release (0.1.1). Its lines were the
  headings of Part 1 above, with the same dates and commits. One
  commit was only in that list: fd96512, the bump for 0.1.0 build 2.
  The list now starts at the last release, and AGENTS.md says so.
- The narrative of what the owner approved that day, in "Next" and at
  the head of the two architecture review lists: the entries above are
  the account. The two review lists are now one, "what is left". What
  the second pass said about the orphan reclaim is merged, lightly
  reworded, into the open item on spared sessions.
- An item under menu bar mode that repeated "Allow in the Background
  switched off" under "Decisions pending"; a note that the release
  checklist had grown (the checklist is in the README); the tested and
  decided part of "Running in Background after quit" (the entry of
  October 19, 2026 above); a section that only pointed to where the
  `ctty-exec` helper is described; and, in the review's "Smaller"
  item, the sentence on `AppDelegate` (about 1,150 lines in one file
  before it was split that day; its quit paths are now in
  `AppDelegate+Quit.swift` and still need `scripts/check-quit.sh`,
  which AGENTS.md says).
- The open item on the Dock badge that could not be seen on the Mac
  used for step 8. The badge shows where notifications are allowed
  ("the Dock badge and notifications, checked live", above), so what
  was left was one Mac's own setting, System Settings › Notifications
  › Armadale › "Badge application icon", and that is not an open item
  of the project.
- Two accounts that existed nowhere else. They are below, word for
  word: the investigation of three extra bytes in a flood test, and
  the comparison of Ghostty packages.

What the old section said that holds on any Mac went to AGENTS.md
("Live UI testing"): which bundle macOS holds responsible for an
agent's commands and what it needs, `lsappinfo` for the frontmost app
without any permission, comparing the pid when several test builds
run, and that synthetic keystrokes reset `HIDIdleTime`. The first
review of this change found them missing from the committed
documents. It also found that the local file said the installed app
had not been run, when the owner had run it at 19:29 (the real state
directory was there), and that a new sentence in AGENTS.md was wrong
about when the SSH integration tests are skipped: they run only when
`ARMADALE_TEST_SSH_HOST` is set, whatever is installed.

AGENTS.md gained the rule behind this: HANDOFF says what is open and
points to the account, the account belongs here, and nothing about a
particular Mac goes into HANDOFF.

**A guest VM for live UI tests**, the review's other housekeeping
item, was looked into and not made. Lima 2.3.0 has a `macos-27`
template: Apple's 27.2 restore image, a 25.6 GB download, about 48 GB
of disk at the peak of the install. The owner would still have to log
in and grant Accessibility inside the guest; `limactl screenshot`
would give pictures of the guest without Screen Recording. The owner
asked whether it was needed, since live checks work on the Mac itself
when it is free. It was not made; the open item stays in HANDOFF with
what was found.

**Moved from HANDOFF: three extra bytes in a flood test (October 23,
2026).** The open item as it stood:

- `floodArrivesCompleteInBoundedBatches` (PTYProcess, `ArmadaleSessions`)
  failed in two of three full-gate runs on October 23, 2026 (the five
  packages' tests run concurrently under `xcodebuild test`), each time
  with the same delta: 7,888,899 bytes arrived for a `seq 1 1000000`
  flood instead of 7,888,896, three extra bytes, and the share of bytes
  in full 64 KB batches was 42 % and then 79.75 % against the 80 % the
  test wants. It passed three times in a row under `swift test` on its
  own, and in the gate run between the two failures. The identical
  three-byte excess means something in the gate's environment adds to
  the PTY stream, not random loss; not investigated. In two further
  runs the count was right but no batch was full at all (0 %, 165
  batches of about 50 KB) on a loaded machine: `seq` was not outrunning
  the reader, so batches closed on the 16 ms interval. The test now
  records that share as a known issue with the numbers, as the zmx flood
  test does, keeps the byte count strict, and prints the first
  mismatching bytes when the count is off (`describeMismatch`), so the
  next three-byte failure says what the bytes are, which batch they
  fell in, and the PTY's device path. Investigated the same evening
  without a reproduction: 6 runs of the sessions bundle alone and 5
  full-gate runs with the diagnostic armed all passed (the three
  failures had coincided with the release build, notarization and DMG
  install running on the same Mac). Excluded by reading the code: a
  master descriptor reused while its read source is live (the master is
  closed only in the source's cancel handler, after the last event
  handler; reads, the exit source, the exit poll and the drain all run
  on one serial queue; writes are refused once the descriptor is set to
  −1 before the close; both PTY ends are close-on-exec), duplication in
  `OutputBuffer` (batches are taken from one pending array under a lock
  and never re-delivered), and the app tests' detached notify helper
  writing to a reallocated device by path (its `sh` waits for it, and
  its payload is one BEL or a long OSC 777, never three bytes). What is
  three bytes long in this code base is a focus report, `ESC [ I` or
  `ESC [ O`, which only a terminal view emits when DECSET 1004 is on;
  no test writes one to a PTY. Open: wait for the diagnostic to catch
  the next occurrence; if it shows a focus report, look for a surface
  answering a replayed `?1004h` into a live PTY in the concurrent
  session-controller tests.

**Moved from HANDOFF: a second renderer, the comparison of October
19, 2026.** The section as it stood, without its heading and its
proposed step, which stay in HANDOFF ("Decisions pending"):

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

## November 14, 2026: hosts, checked live

November 14, 2026, 20:12 to 20:20, with the owner's word that the Mac
was free: what the app does with a host at launch, which the live
checks of attaching at launch had left out for want of a test host.
The Debug build of 76562b7 (the gate had passed on it), with its own
state directory and defaults suite, against the Lima VM: Ubuntu
26.10, OpenSSH with `MaxSessions 10` in its sshd configuration, key
authentication. Twelve sessions were made on the VM with the helper
copied there, each running `sleep`, and twelve tabs were written into
`state.json`, each session with a saved size, the first tab selected.
Nobody sent a synthetic keystroke or click: the build's own menu
items (Window › Show Next Tab, File › Close Pane) and the close
confirmation's button were pressed as accessibility actions by pid,
and everything was read from process lists, `lsof`, the helper's
listing on the VM and the window's accessibility tree. No code
changed.

What held.
- **The limit of six at launch.** Within 3 s of the launch six
  sessions had a client: the selected tab's and the first five in tab
  order that were not shown. The other six had none, 16 s later
  either. The six count the session on screen.
- **Showing a tab.** Showing each of the five attached at launch
  started nothing. Showing each of the other six started its client,
  one per tab, up to twelve.
- **Past sshd's ten.** The eleventh and twelfth clients attached like
  the others. The first ten had no TCP connection of their own, and
  one sshd session on the VM held ten ptys; the eleventh and twelfth
  each had one. The shared connection had refused another session and
  ssh had opened a connection of its own. So what the open item
  feared, that past ten the kill, the listing and new panes would be
  refused, does not happen where a new connection needs nobody to
  sign in.
- **Closing a pane with the shared connection full.** Close Pane
  asked ("Close this pane?", "A process is still running in this
  pane. Closing it will end the session."), and after Close the
  session was gone from the VM within 3 s. Twice in a row, with ten
  sessions on the shared connection both times.
- **A quit.** SIGTERM with ten clients, and later with six: the
  clients went and the ten sessions stayed on the VM.
- **Unreachable at launch, then back.** With the host's port closed
  (a copy of its ssh configuration with another port), no client was
  started, and the pane on screen said "Reconnecting…", "Armadale lost
  its connection to this session and keeps trying to reconnect. The
  session may still be running." and ssh's own line, "ssh: connect to
  host 127.0.0.1 port 9: Connection refused". The port was put back
  while the build ran. Within 19 s six sessions had a client, the one
  on screen and the first five in tab order, with nobody touching the
  build; the other four stayed without one.

What was found on the way.
- The menu items of a build that is not the active app are disabled:
  Show Next Tab did nothing eleven times until the build was brought
  to the front, once. A build in the background can be read, and its
  Clear All Attention pressed, but its tab commands cannot.
- The first staging used session identifiers with the digits 0 and 1.
  The build refused the file as it should (identifiers are 16
  lowercase base32 characters), kept it as
  `state.json.corrupt-<seconds>`, used `state.json.bak`, and said so
  in its alert, with the path of the first bad identifier. The twelve
  sessions on the VM were left alone.
- After a quit the shared connection's master is still running
  (`ControlPersist=600`), a child of launchd. Whether the Dock shows
  "Running in Background" for it was not looked at.

Not checked: a host that asks for a password (at launch, after being
unreachable, and for the separate connections past ten, where a
close's kill would be lost); the Disconnected placeholder once the
retries give up; two hosts at once; what only the eye would see.
`docs/DESIGN.md` sections 4 and 13 now say what happens past ten.
`HANDOFF.md` keeps the password cases ("Next"; Remote; "Restored
sessions attached at launch").

## November 14, 2026: sessions macOS ends after a quit are detected and told (14ec35c)

The decision deferred on October 19, 2026 ("Allow in the Background"
switched off, above) was made on November 14, 2026, and built the same
evening. With Armadale switched off under System Settings › General ›
Login Items & Extensions › Background App Activity, macOS ends every
local session 1 to 5 s after any quit, and until now Armadale said
nothing: the next launch just showed ended panes.

What was checked before the options went to the owner (the evidence is
in Part 2, sections 4 and 8).
- **No API reads the setting.** Apple's ServiceManagement
  documentation and the header in the macOS 27.2 SDK have nothing that
  tells an app whether it may run in the background;
  `SMAppService.status` describes an item the app registered.
- **The section's name.** On macOS 27.2.1 the Login Items pane's own
  strings call it "Background App Activity", as Apple's support
  article 125671 does. "Allow in the Background", which the repository
  used, was its name on macOS 13 to 26.
- **What a session ended by the system leaves behind.** Sessions were
  staged with the persistence helper alone and ended in different
  ways: a daemon that gets SIGTERM writes a dated "SIGTERM received"
  line to its log; the helper's own kill and a program that ends do
  not. The exit recorder writes nothing in that case, and the state
  file held no quit time and no list of the sessions alive at a quit.

The options, and the owner's choice. Detect the loss after the fact and
tell; only say it, in the quit alert, the status menu and the README; or
a registered background item (`SMAppService`), prototyped first in a
throwaway app, either only to read the switch through its `status` or
to own the sessions. The owner chose the first ("Detect and tell").
The second would have told everyone at every quit, in an alert whose
answers the switch does not affect. The third keeps no session alive
with the switch off either (an agent that is switched off does not
run); it could at best let the app know before a loss, and is not
tested.

What was built (`docs/DESIGN.md` section 3, "The last quit", and
section 8, "Background App Activity").
- **A record at quit**, `last-quit.json` beside the state file: the
  time, the kind of quit, the boot and the login session, and the local
  sessions it left running. It is not part of the state file, so the
  schema is untouched.
- **A check at the next launch**, from files only, no earlier than 12 s
  after the quit: *ended* when a recorded session's log has the SIGTERM
  line within 10 s of the quit, *survived* when none has and one is
  alive, otherwise nothing is said (the system's own quit, a restart or
  a logout since, nothing recorded).
- **An alert after a loss**, "macOS ended N sessions after Armadale
  quit", with Open System Settings and Not Now. It says what happened
  and what makes macOS do it, never that the switch is off.
- **A question before the next quit that would leave local sessions**
  from menu bar mode, while a loss has been seen: Open System Settings,
  Quit Anyway, Cancel. It stops when a later quit's sessions are found
  alive. The ⌘Q question is unchanged.
- The README and DESIGN name the switch as macOS 27.2 shows it.

How it was checked. An implementer and a separate reviewer (both Opus
5.5), three implementer rounds and two review rounds. The reviewer ran
the gate itself in both rounds, staged a session with the helper to
check the log line, read NSAlert's key equivalents from a script that
shows no window, and tried six mutations: the two of the first round
survived and their gaps were closed, the four of the second were all
caught. The coordinating session's gate on the final tree: 861 tests
(315 app, 281 core, 240 sessions, 13 and 12), no compiler warning, no
process left. The SSH integration tests did not run (no host was set).
The app was never launched.

What the reviews found, all fixed (Part 2, section 8, has each).
- Cancel on the new question left an active menu bar app with no
  window, so keystrokes went nowhere: the app hides again, as it does
  when Settings is closed in menu bar mode.
- The alert of a check that had to wait can appear up to 12 s after
  launch, while the user types: no button answers Return there, and
  Not Now answers Escape in both alerts.
- A damaged record (a boot time of `Int64.min`) would have crashed
  every launch.
- The question said "the last quit", which the record does not always
  show.
- A check that had to wait must not clear the warning: whether macOS
  still ends the old run's sessions when the app is running again
  within 5 s is not known.

Not checked live: both alerts and their buttons, the hide after
Cancel, a SIGTERM quit under the new alerts, the record at each kind
of quit, and the whole loop with the switch off and on again. It needs
the owner at the switch, and a test build started through Launch
Services, as on October 19, 2026. The known limits (a crash of
Armadale, a restart or logout before the next launch, a `kill` by hand
within 10 s of a quit) are in DESIGN section 8.

In `HANDOFF.md`, "macOS 27: 'Allow in the Background' switched off" is
removed from "Decisions pending" and from "Next". What stays there: the
live check, and the `SMAppService` prototype as an untested option.

## November 14, 2026: the background detection, checked live

November 14, 2026, 22:00 to 22:17, with the owner's word that the Mac
was free and the owner at the switch (System Settings › General › Login
Items & Extensions › Background App Activity). The Debug build of
14ec35c, with its own state directory, started through Launch Services.
Nobody sent a synthetic keystroke or click: buttons, the alerts and the
status menu's items were pressed as accessibility actions by pid, quits
were SIGTERM to the pid or `NSRunningApplication.terminate()` (a quit
Apple event without a reason), and everything was read from the
accessibility tree, the record file, the helper's log and the unified
log. No code changed.

**What went wrong first: a test build ran on the real state
directory, twice.** After a quit from the regular policy that leaves a
session, the Dock keeps Armadale's tile ("Running in Background"). A
click on it starts the app through Launch Services *without* the
environment `open -n --env …` had given it, so the Debug build opened
on `~/Library/Application Support/Armadale`: at 22:00:55 (ended by
SIGKILL to its pid at 22:02:28) and at 22:05:07 (quit a second later).
The unified log shows the Dock asking for both launches; the owner did
not remember clicking. No session was running there and none was lost;
what the two runs left in that directory is in that Mac's
`HANDOFF.local.md`. From then on the test used a copy of the build with the test
environment in its own `Info.plist` (`LSEnvironment`, signed ad hoc
again), which every Launch Services launch honours, a Dock click
included (the copy's process carried a marker variable that only the
`Info.plist` set). `AGENTS.md` has the rule now.

What held (the wording of every alert as in DESIGN section 8).
- **Survived, macOS allowing.** A SIGTERM quit with one session;
  relaunched 66 s later: no alert, "last quit check: survived after a
  signal quit, 1 session(s) recorded, 0 ended by SIGTERM",
  `last-quit.json` gone, the pane attached again.
- **Ended, switched off.** The same quit: the daemon logged "SIGTERM
  received" 1 s later and was gone. Relaunched 27 s later: the alert
  "macOS ended 1 session after Armadale quit", "last quit check: ended
  (1) after a signal quit, 1 session(s) recorded, 1 ended by SIGTERM",
  the file holding only `lossSeenAt`, the pane showing Session Ended.
  Open System Settings brought System Settings forward at Login Items;
  on a second loss Not Now closed the alert, whose default button was
  Open System Settings.
- **The question before a quit from the menu bar.** With the loss seen
  and a session running in menu bar mode, a quit Apple event and the
  status menu's Quit, Keep Sessions Running each raised "macOS may end
  1 session when Armadale quits", in front of the app that was active.
  Cancel left Armadale in the menu bar and that app was in front again;
  Open System Settings brought System Settings forward over Finder;
  Quit Anyway quit.
- **A quick relaunch, switched off.** After Quit Anyway and a relaunch
  1 s later the session stayed alive (15 s watched): "last quit check
  (late): survived after a user quit", and `lossSeenAt` was kept.
- **The late alert.** A SIGTERM quit, relaunched 3 s later: the alert
  came 12 s after the quit, "last quit check (late): ended (1)", with
  no default button and Not Now as its cancel button.
- **SIGTERM under the alert** quit at once (within the 10 ms the probe
  resolves) and wrote the record: a signal quit, no sessions,
  `lossSeenAt` carried over. The next launch said "undetermined (no
  sessions recorded)" and kept it.
- **Switched on again.** Quit, Keep Sessions Running asked (the loss
  was still remembered); Quit Anyway; the session was alive 14 s later;
  relaunched: "survived after a user quit", no alert, the file gone.
  The next Quit, Keep Sessions Running quit without a question, and the
  Dock showed no tile.

What was found on the way.
- With no decision stored macOS ends nothing; it registers the app and
  posts a notification about 30 s after the first such quit (Part 2,
  section 8). So on a new Mac the first loss can only come after the
  user has answered that notification or used the switch.
- A quick relaunch after a quit from the menu bar keeps the sessions
  even with the switch off (Part 2, section 8).
- The status menu's items are in the accessibility tree without the
  menu being opened (`AXExtrasMenuBar`), and pressing one there runs
  its action: no click on the status item is needed.

Not checked: what the notification's Don't Allow does to sessions
running at that moment; the Developer ID build (whether the installed
app shares the entry); the question with ⌘Q typed in Settings; the
late check in menu bar mode; a real keystroke into the late alert; a
restart or logout between a loss and the next launch. Afterwards: no
process, no test directory, modifier flags 0, the owner's switch on
again.

## November 16, 2026: favorites are managed in the chooser, a host is added in the New Session dialog, Settings loses its Favorites tab (3a5183c)

The owner asked on November 14, 2026 whether Profiles, Hosts and
Favorites, which hold things the user creates rather than preferences,
had a better home than Settings. The documentation of about 34
terminal, SSH and agent apps was read that day (Part 2, section 8, "New
sessions", has what it found and the sources), and on November 16, 2026
the owner approved this step with six decisions: remove the Favorites
tab; reorder by drag plus Move Up and Move Down; an inline Destination
field rather than a host sheet; suggest `~/.ssh/config` aliases; a
favorite saved from a pane uses the pane's current directory; recents
are not part of this step.

What was built (`docs/DESIGN.md` section 8, "New sessions", "Pane
context menu" and the Settings bullet; section 2; section 6, one line).
- **The chooser manages favorites.** A favorite row can be dragged onto
  another, whose place it takes (as a tab in the tab bar), with a 2 pt
  accent bar on the edge where it will land; its context menu is Edit…,
  Move Up, Move Down, Remove, with matching accessibility actions. A
  favorite drags as a type of Armadale's own
  (`com.tinylittleapps.armadale.favorite`, declared in Info.plist), so
  a terminal, the sidebar and the tab bar take nothing from it. The
  decisions (`dropIndex`, `dropEdge`, `move(_:by:)`, `canMove`) are in
  `NewSessionChooser`.
- **Save as Favorite…** in the pane menu of a pane with a session (after
  the splits, between separators) opens the dialog as "New Favorite" on
  the workspace window, through the same sheet slot, filled in from the
  session with its current working directory
  (`AppModel.favoriteRequest(fromSession:)`).
- **New Host…** is the host picker's last item and replaces Add Host…
  (which opened Settings › Hosts): a Destination field in the same sheet,
  with the aliases of the user's ssh configuration offered while typing.
  Start or Save adds the host, named after its destination, or uses a
  plain host already saved for it (`AppModel.ensureHost(forDestination:)`);
  Cancel adds nothing. With no host saved, SSH goes to New Host… at once.
- **`SSHConfigAliases`** (`ArmadaleCore`): a small reader of `Host` and
  `Include` lines that only reads, given a home folder; the dialog reads
  it off the main actor when New Host… is chosen, through a loader the
  app injects (tests get one that finds nothing).
- **Settings loses its Favorites tab** (General, Appearance, Profiles,
  Hosts remain); a saved `favorites` tab opens General.
  `FavoritesSettingsView.swift` (the list, its editor and its New Favorite
  sheet), the form fields' per-field commit plumbing, the dialog's Add
  Host… plumbing (`WorkspaceActions.showSettings`,
  `AppDelegate.showSettings(tab:)`) and the quit notification only that
  sheet listened to (`armadaleWillQuit`) are gone.

How it was checked. Unit tests: the alias reader with strings and
temporary folders (includes in place, globs, a cycle, the depth limit,
a FIFO, the size and file limits, unreadable files and folders, nothing
written), the matching rule, the host lookup and intent, the request
from a session, the form's New Host… rules and its injected loader
(called once, off the main thread), the name shown being the name
saved, the New Favorite form from a session, the chooser's moves and
drops, the drag types and their declarations, the pane menu's outline
and its Save as Favorite… reaching the window's sheet, the quit path
ending a sheet of each kind, and the saved `favorites` tab. The gate,
run by the coordinator on the final tree: 914 tests (336 app, 313 core,
240 sessions, 13 and 12), zero warnings; the SSH integration tests did
not run (no host was set). No state file shape changed, so
`scripts/check-state-compat.sh` was not needed. **The app was not
launched: nothing of this step is checked live** (`HANDOFF.md` lists
what to look at), and `scripts/check-quit.sh`, due because the step
touches sheets and the chooser, was not run; both wait for the owner's
word that the Mac is free.

The review. An implementer and a separate adversarial reviewer (both
Opus 5.5), as `AGENTS.md` describes. The reviewer found no blocker and
confirmed by hand the drop and move index arithmetic for every pair,
that no path leaves a host behind when nothing is started or saved,
that the drop's result does not depend on the remembered drag, and
that no test can read the real `~/.ssh/config`. What it and the
coordinator's own reading found was fixed in the same change (Part 2,
section 8, "New sessions", "after the review", has the list): the
favorite's name shown could differ from the name saved; the alias
reader read an included file of any size whole (25 s and 3.2 GB for a
sparse 1 GB file); aliases no destination can use were offered; the
word splitting was brought in line with OpenSSH's `argv_split`, first
from a description and then, corrected, from its source; and a line in
`HANDOFF.md` described one Mac. Left as they were, with reasons there:
four smaller points.

In `HANDOFF.md` the Step 10 items "broken favorites in Settings" (10b)
and "Add Host… from the Edit Favorite sheet" (10c) are removed: the
first is moot (the tab is gone; a broken favorite is repaired through
the chooser's Edit…, which was already there), the second names a
button that no longer exists.

## November 16, 2026: favorites in the chooser and New Host…, checked live

November 16, 2026, about 10:20 to 10:31, with the owner's word that
the Mac was free. The Debug build of the final tree (the code of
3a5183c), as a copy under `/tmp` that carried its own state directory
and defaults suite in its `Info.plist` and was started through Launch
Services; the lock in the test directory was confirmed at every launch.
The installed app was not running and was not touched. Five favorites
(one broken) and a profile whose program reports a directory with
OSC 7 were staged in the test state file. Everything was read from the
accessibility tree, the on-screen window list and the state file
(Screen Recording is not granted here, so nothing was seen as a
picture). Buttons, menu items and the rows' accessibility actions were
pressed by pid; the drags, the clicks on rows, the typing into the
Destination field and five keys (Escape, Return three times, ↓) were
synthetic events, each sent only with the screen unlocked, the test
build frontmost by pid and its own window under the pointer. No code
changed.

What was seen.
- **Move Up and Move Down.** The first row offers no Move Up and the
  last no Move Down, as accessibility actions and, disabled, in the
  context menu (Edit…, separator, Move Up, Move Down, separator,
  Remove); pressed as an accessibility action and chosen from the menu,
  each moved its row by one, the broken favorite included, and the
  order reached the state file.
- **Drag against click.** A row dragged down onto another landed below
  it, one dragged up landed above it, a broken row dragged like the
  rest, a press and release on the same row moved nothing and started
  nothing; in a 205 pt (compact) chooser, and from a 99 pt (tiny)
  chooser onto a row of another pane's chooser, the same. A plain click
  then started a favorite (in the full-size and in a tiny chooser), and
  a click on the broken row did nothing. No drag started a session, and
  the app took every drag without a crash, so SwiftUI builds the drag's
  payload where the code expects it. A favorite dropped on the sidebar,
  on the tab bar and on a terminal changed nothing (the shell's screen,
  read with the helper's `history`, held only its prompt), and a tab
  dropped on a favorite row changed nothing.
- **Save as Favorite….** The pane menu of a running pane reads Split
  Right, Split Down, separator, Save as Favorite…, separator, Theme; an
  empty pane's has no such item. It opened "New Favorite" on the
  window with the name "Reporter in /private/tmp", Local, the directory
  `/private/tmp` (what the program had reported; the session had
  started in `~`), the session's profile and Cancel and Save. Saved
  after the switch to SSH described next, it added the favorite and
  started nothing. A row's Edit…, pressed as an accessibility action,
  opened "Edit Favorite" the same way.
- **New Host….** With no host saved, SSH showed the picker on New
  Host…, the Destination field with keyboard focus, the message asking
  for a destination and Save disabled, and the sheet grew by the row
  (309 to 412 pt). With hosts saved the picker lists them, a separator
  and New Host…; with several it reads "Choose a Host". Typing made
  the name follow ("Reporter on gamma.invalid in /private/tmp"), Return
  in the field saved: one plain host named after the destination, a
  favorite on it, no session, no ssh process. Cancel after typing
  another destination added nothing. New Host… with a destination
  already saved added no second host. In the New Session dialog, Start
  with a destination that resolves nowhere (`epsilon.invalid`) added
  the host, started the session on it, and the pane showed
  "Reconnecting…" with ssh's "Could not resolve hostname"; Close Pane
  ended it. Nothing connected anywhere. Settings › Hosts listed the
  added host with only its destination set.
- **Aliases.** This Mac has no `~/.ssh/config`, so nothing was offered
  (and nothing went wrong). To see the suggestions, the copy was given a
  home folder of its own (`CFFIXED_USER_HOME` in `LSEnvironment`, which
  `NSHomeDirectory()` follows) holding a config of fake names: two on
  one `Host` line, a wildcard and a negated pattern, an `Include`, a
  quoted pattern with a space and one starting with `-`. The list
  appeared under the field as soon as it had focus, in the sheet, with
  the four usable names in the file's order, the included one in its
  place; `g` narrowed it to three and `ga` to two. **Return with the
  list open and nothing highlighted confirmed the dialog with the text
  as typed** (a host named `ga` was saved); **↓ highlighted an alias and
  Return then took it and confirmed in the same keystroke.**
- **Settings.** Four tabs: General, Appearance, Profiles, Hosts. With
  `settingsTab` saved as `favorites` it opened General and saved
  `general`.
- **Quit.** SIGTERM with a New Session sheet up: gone in 0.4 s, the
  state saved with the pane still empty. `scripts/check-quit.sh`
  against the Debug build passed its three cases (128, 67 and 133 ms).

Found. The two Return behaviours above, which follow from "Return in a
field confirms" and are now in DESIGN; whether Return should take a
suggestion first was put to the owner, who decided the same day to
leave it as it is (the item is removed from `HANDOFF.md`'s pending
decisions). A favorite row's
help text is repeated in its accessibility help, once per text or image
in the row, and two favorites can carry the same proposed name; both
are older than the step and are in `HANDOFF.md`, not fixed.

On the way. The Dock owns a click-through window over the whole
display at layer 20, so "the frontmost window under the point" was the
Dock's everywhere and the first drag was refused by the helper's own
guard; the guard now skips that one window. A SwiftUI context menu
opened with the row's `AXShowMenu` and its items answered `AXPress`,
but `AXCancel` on it returned success and left it open (Escape closed
it, sent only after the window list showed the menu). Both are in
`AGENTS.md` now. The helper's source is in the sessions' shared notes
folder, not in the repository.

Afterwards: the test sessions ended with the test directory's own
helper before each quit, the build ended by pid, the test directories,
the copy and the defaults suite removed, no Armadale or helper process,
no Dock item, modifier flags 0x20000000, the real state directory last
written on November 14. In `HANDOFF.md` the step's not-checked-live
list is replaced by what is left.

## November 16, 2026: Armadale 0.1.2 (29), built and notarized, not published (77a02cf)

November 16, 2026, about 10:40, on the owner's word: a new notarized
build for the owner's own use, because the installed 0.1.2 (28) of
November 14 had neither the detection of sessions macOS ends after a
quit nor favorites in the chooser and New Host…. The version stays
0.1.2; only the build number rises.

- `scripts/bump-build.sh`: 0.1.2 (28) to 0.1.2 (29), `project.yml`
  only, committed as 77a02cf after the gate had passed on it (914
  tests, no warnings; the SSH integration tests did not run, as in
  every gate run).
- `scripts/check-state-compat.sh`: the working tree writes schema 2,
  and v0.1.0 and v0.1.1 both answer `newerVersion`.
- `scripts/install-release.sh` on the clean tree at 77a02cf: the app
  and the DMG both notarized ("Accepted", notary logs without issues)
  and stapled, Gatekeeper "Notarized Developer ID" for both, and the
  app installed over build 28 in `~/Applications`. The run took 2 min
  35 s. It deleted the DMG of build 28 with `build/release/`.
- Checked again by hand: the installed app is 0.1.2 (29), identical
  to the archived app, its signature verifies, `spctl` accepts it as
  "Notarized Developer ID" and its stapled ticket validates.

Not done, on purpose: no tag, no GitHub Release, no state fixture, no
change to the website, and no agent ran the installed app. The DMG's
size and hash are in the local file of the Mac it was built on. How
to publish this very build is under "Next" in `HANDOFF.md`.

## November 16, 2026: a changelog page on the site

November 16, 2026, evening (owner's request: a static changelog page
with dates for the website, written for the commits so far, "not too
micro", and kept up by agents from now on; done by the coordinating
session through the gate, no agents): **the site has a changelog
page**, `docs/changelog.html`, linked under the Download button of
`docs/index.html`.

- **The page.** Self-contained like the home page (inline styles, no
  script, the same colours, light and dark, phone width): a section
  per release, newest first, and in each section one entry per day,
  the date beside that day's items; an item is a title and at most
  one short paragraph. The sections now: "Next release" (not yet
  released: what 0.1.2 would ship), 0.1.1 with the "Latest release"
  pill and its links, and 0.1.0.
- **The past.** The 118 commits up to 03e4f34 became 26 items on 15
  days: 6 under "Next release" (November 12 to 16, 2026), 10 under
  0.1.1 (October 23 to November 5, 2026) and 10 under 0.1.0 (October
  15 to 20, 2026), written from the commit subjects, Part 1 of this
  file and the README. Left out as nothing a user sees: documents,
  rules for agents, live checks, build bumps, scripts, the
  architecture review as such, the file splits. Left out as too
  small: the app icon, the About panel's lines, the sidebar toggle's
  place, the folder icon and the ⇧⌘N badge of tab group rows, the
  Window menu's hidden Show Tab items, unfocused panes and ended
  sessions no longer dimmed, the full-screen serializer. Folded
  together: the two activation fixes of November 9 and 12, 2026 (one
  item, on the later day); the instance lock, the reclaim and save
  safety and schema 2 (one item, "A safer saved layout", which also
  says that 0.1.1 and earlier refuse the new file); the pane menu's
  path (a context menu, its removal, then the header's "…") inside
  "Panes are cards".
- **Keeping it.** AGENTS.md has a new section, "The changelog page":
  a change a user of the app would notice gets its item in the commit
  that makes it; what goes in and what stays out; how much (one item
  per change as a user would name it, one to three for a day of
  work); where (the day's entry under "Next release"); and what
  happens at a release. Step 4 of the process has the coordinating
  session check it. README "Releasing", step 4, has the release notes
  written from that section and the section turned into the version's
  once the GitHub Release exists; "The website" describes the page. A
  comment at the top of the page's `<main>` holds the markup for a
  day and for a new "Next release" section.
- **`ChangelogPageTests`** (4 tests, `ArmadaleAppTests`) reads the two
  pages from `docs/`: sections newest first with "Next release" only
  on top, ids `v<version>`, the latest pill on the newest release and
  no other; every `<time>` a real date whose text is that date written
  out; one entry per day and the days newest first in a section;
  nothing in a section older than the release below it; the runtime's
  name on neither page; the two pages linking to each other.

Decisions the coordinator made, each the owner's to overrule. (1) The
page shows work that is on `main` and not released, under "Next
release": the owner asked for the page to follow the commits, and
0.1.2 is not published; the section says it is not in the download
yet. (2) 0.1.0 has a section although it was never published (the
repository was private then), described as "The first build, made
before Armadale was public. It was not published." (3) An item is
dated by the day its work was finished, and a day has one entry in a
section. (4) No generator and no second source: the page is the only
copy and is written as HTML by hand, because the site has no build
step (Pages serves `docs/` as it is, Actions are off) and a
`CHANGELOG.md` beside it would be a second copy to keep in step.

Checked: both pages served from `docs/` by `python3 -m http.server`,
in the Claude app's browser pane, 1100 px wide in light and in dark
and 375 px wide: no horizontal scroll at 375 px, no console message,
the home page's link opens the page. Not checked: Safari, and the
page as GitHub Pages serves it (nothing is pushed). Gate: 918
tests, zero warnings (the SSH integration tests did not run, as in
every gate run). No app code changed, so 0.1.2 (29) of 77a02cf is
still the app as it is on `main`.

## November 16, 2026: an updater, with Sparkle

November 16, 2026, night (the step the owner approved that day, "Build as
recommended", on a design written by the coordinating session; built by
an implementer agent and reviewed by a second, adversarial one):
**Armadale updates itself with
Sparkle 2.10.1**, offered from a feed on the site, the DMG on GitHub
Releases. Nothing is published: the feed has no item, and no build
starts the updater until the owner has made the signing key and its
public half is in `project.yml`.

The owner's eight decisions (November 16, 2026; the design and its
evidence are in Part 2, sections 8, "Updates", and 11): (1) the feed is
`docs/appcast.xml` at `https://armadale.dev/appcast.xml`, each item
pointing at the versioned DMG of a GitHub Release; (2) one EdDSA key
under the keychain account `armadale`, made and kept by the owner, never
by an agent or a script; (3) the update is the existing notarized DMG,
its signature checked before it is mounted
(`SUVerifyUpdateBeforeExtraction`); (4) Armadale › Check for Updates…,
automatic checks asked once by Sparkle's prompt and then daily, a
checkbox in Settings › General, no background download and no silent
install, Update Available… in the status menu; (5) the update's quit is
decided before Sparkle sends it and keeps sessions; (6) nothing in the
app about state file versions, the release notes say it; (7) no system
profile and no added parameters, notes embedded in the feed; (8) it ships
as 0.1.2 with build 30.

- **What was built.** The package (exact 2.10.1, pinned in
  `Package.resolved` at revision ab7d712, the tag's; the XCFramework's
  SHA-256 is the checksum of the tag's `Package.swift`, 4c2e48a3…023a).
  `App/Updates.swift`: `AppUpdater` (the protocol), `UpdaterPolicy` (when
  the updater starts), `UpdateQuitGate`, `UpdateCoordinator` (every
  decision around Sparkle's callbacks), `UpdateSettings` and
  `UpdateText`. `App/SparkleUpdater.swift`, the only file that imports
  Sparkle, out of `ArmadaleAppTests`. `UpdateQuitDecision` next to
  `QuitDecision`, which gained `isUpdateQuit`.
  `SessionRegistry.sessionsThatEndAtQuit()`. `App/AppDelegate+Updates.swift`
  (starting after the launch alerts, the alerts, Check for Updates…,
  Update Available…). The menu item, the status menu item, Settings ›
  General › Updates (the tab grew to 620 × 640 pt). Info.plist keys.
  The build phase `scripts/embed-sparkle.sh`. `scripts/release.sh`
  (preflight of the feed and the key, Sparkle's code in the signature
  checks, the DMG signed for the updater, `appcast-item.xml`, the schema
  reminder), `scripts/sparkle-tool.sh`, `scripts/appcast.sh` with
  `scripts/appcast.py`, `scripts/ed25519-verify.swift`. `docs/appcast.xml`
  (no item). Sparkle's `LICENSE`, verbatim with its external licenses,
  in `THIRD_PARTY_LICENSES.md` and `Acknowledgements.txt`. README
  ("Updates", "Releasing", the environment table), DESIGN sections 8, 11
  and 13, and an item on the changelog page.
- **Tests.** `UpdatesTests` (the policy table, the decision table, the
  update quit in `QuitDecision`, the gate's lifetime, the coordinator
  driven as Sparkle drives it: nothing to tell, a question answered yes,
  Cancel and a later ordinary quit, the loss warning and Open System
  Settings, a refusal while End Sessions and Quit runs, a quit started
  under the alert, the gate after an abort, after a cycle that ends
  without a quit and after its lifetime, no gate without a yes; the menu
  bar reminder; the Settings model; the sessions that end at a quit; the
  menu items; the wording, with neither "zmx" nor "Sparkle"),
  `AppcastTests` (the feed's form, and the rule on good and bad items),
  and `AcknowledgementsTests` for the third component.
- **Checked without the app.** The gate (below). The built Debug bundle:
  `Contents/Frameworks/Sparkle.framework` with `Versions/B/Autoupdate`,
  `Updater.app`, `Sparkle`, `Resources`, no `XPCServices`, `Headers`,
  `PrivateHeaders` or `Modules`; `codesign --verify --deep --strict`
  accepts the app; the framework and both helpers ad hoc, with Sparkle's
  identifiers. A build into a fresh DerivedData. The scripts against
  scratch files with a throwaway key in a file (never the keychain): the
  artifact's `sign_update --ed-key-file` signature verifies with
  `ed25519-verify.swift` and with `sign_update --verify`, a changed file
  does not; `appcast.py item`, then `appcast.sh --dmg --feed --changelog
  --public-key` inserts an item whose notes come from a copy of the
  changelog with "Next release" renamed `v0.1.2`; it refuses the same
  build twice, a file of another length, another public key, a missing
  section and a `project.yml` without a key. `release.sh`'s parsing of
  `project.yml`, of `sign_update`'s output and of the schema versions
  (2 now, 1 at `v0.1.1`, so the reminder prints) on scratch inputs.
  `release.sh` itself was not run.
- **Found on the way.** (a) Xcode's own embed of a package framework is
  not a build phase: a script phase after it ran at the same time as its
  copy (Autoupdate missing) and, in another build, as its sign-on-copy
  (`codesign` failed on a framework being changed under it); declaring
  the copied paths as the script's inputs did not order them, and an
  explicit Embed Frameworks phase for the package product fails ("The
  file 'Sparkle-product' couldn't be opened"). So the dependency is
  `link: false` (`import Sparkle` links the framework Xcode extracts
  into `BUILT_PRODUCTS_DIR`) and the last phase embeds and signs it. (b)
  SwiftPM's download of the XCFramework never started in this
  environment (no socket open, sandboxed or not, for over ten minutes;
  `curl` fetched it in a second): the zip was fetched with `curl`, its
  SHA-256 matched the checksum in Sparkle's `Package.swift`, and it was
  put in SwiftPM's cache
  (`~/Library/Caches/org.swift.swiftpm/artifacts/`), from which the
  builds resolved. (c) `Preferences.suiteName(environment:arguments:)`
  and its two names became `nonisolated` (pure; the policy needs them
  outside the main actor). (d) An empty feed answers "You’re up to date!"
  (Sparkle's `SPUBasicUpdateDriver.m`: no item counts as the latest
  version).
- **Cancel, from Sparkle's source** (Part 2, section 8, "Updates", has
  the citations): the design said "Cancel leaves the update downloaded;
  Sparkle installs it when Armadale next quits". That is what happens,
  with one addition the design did not say: that quit does not relaunch
  Armadale (the installer relaunches only when asked to by the install
  Armadale cancelled). DESIGN section 8 and the alert say so.
- **Not checked live**, because the app was not launched (the Mac was
  not free): everything in HANDOFF's list for this change.
- **The review** (an adversarial reviewer, the same night) found no
  blocker; it confirmed the bundle, the signing order, the quit path
  against Sparkle's source, the scripts on scratch files and the
  licenses, and sent 13 items, fixed with the coordinator's decisions:
  (1) the updater could start in a Debug build launched without the
  isolation variables (from the Dock, Finder or `open`), writing
  Sparkle's settings into the real defaults domain: it is now off in a
  Debug build too (`Reason.debugBuild`, `DEBUG` read in one place), and
  the test switch, renamed `ARMADALE_UPDATER_FOR_TEST`, lifts that and
  the isolated run only; (2) the privacy guards checked the key that
  only shows the prompt's checkbox, not `SUSendProfileInfo`, which sends
  the profile: `release.sh` and the Info.plist test refuse
  `SUSendProfileInfo`, `SUEnableSystemProfiling` and
  `SUEnableJavaScript`, `release.sh` checks the built plist's
  `SUAllowsAutomaticUpdates` and `SUVerifyUpdateBeforeExtraction` too,
  and `allowedSystemProfileKeys(for:)` returns an empty list, which
  leaves nothing to send; (3) a no could stick and abort a later install
  unasked if its cycle's end was not reported: it is one-shot; (4) the
  Settings line now says the request names the version of Armadale and
  of its updater; (5) the key preflight showed `sign_update`'s errors
  nowhere (they go to standard output): both streams are shown on
  failure; (6) `release.sh` named a phase and script that no longer
  existed ("Sign Sparkle"); (7) the gate let any quit through for up to
  60 s: it is one-shot, closed by the first quit that consults it; (8)
  the alert's promise after Cancel became "normally", with the
  exceptions in DESIGN; (9) the changelog item no longer promises that
  every session survives; (10) a test runs `scripts/appcast.py` through
  `AppcastTests`' rule; (11) the release notes are an allowlist of the
  changelog's tags and the feed is replaced atomically; (12) an
  unreadable schema version stops the release (the source's) or warns
  (the tag's); (13) the served feed's comment names no internals. The
  gate after the fixes is below.

Gate, run by the coordinating session after the fixes: 945 tests (918
before; 27 new in `ArmadaleAppTests`), no warning from Armadale's code.
That run built incrementally and its log has no warning line at all; a
clean build's log (the implementer's, and the reviewer's clean Debug
build and ad hoc Release archive) has the same two kinds of warning
lines the gate at e5f5e25 has (checked the same night on a copy of that
commit):
`appintentsmetadataprocessor`'s "no AppIntents.framework dependency"
and Xcode's "'ArmadaleAppTests' is missing a dependency on 'Armadale'"
(the dependency-scan issue HANDOFF records under the architecture
review). The SSH integration tests did not run (no
`ARMADALE_TEST_SSH_HOST`).

## November 16, 2026: the updater, checked live

November 16, 2026, 22:17 to 22:48 (the owner said the Mac was free and
was at the Background App Activity switch for the last part; run by the
coordinating session; no code changed): **a real update was installed
five times on test builds, with sessions running, and each time the
sessions lived through it.** The installed app was not running and was
never touched.

- **The setup**, as designed that day: copies of the Debug build of
  13f12c2 under `/tmp/armadale-upd` with a bundle identifier of their
  own (`com.tinylittleapps.armadale.updatetest`, so Sparkle's launchd
  jobs, cache and settings were theirs), builds 9001 to 9006 (versions
  0.1.2 to 0.1.7), `LSEnvironment` with the test state directory, the
  defaults suite and `ARMADALE_UPDATER_FOR_TEST=1`; a feed on
  `127.0.0.1:8765` served by a small script that logged every request
  with its headers; DMGs made with `hdiutil` and signed with
  `sign_update --ed-key-file` and a throwaway key in a file (never the
  keychain); `NSAllowsArbitraryLoads` in the copies for the http feed.
  Everything was driven by accessibility presses by pid; no synthetic
  keystroke or click was posted. The builds were ad hoc signed, so the
  Developer ID path (`scripts/release.sh`, an update between notarized
  builds) is still unchecked.
- **A check and what it sends.** Check for Updates… showed "A new
  version of Armadale is available! Armadale 0.1.3 is now available—you
  have 0.1.2." with the embedded notes rendered. Two requests per
  update and nothing else: `GET /appcast.xml` with no query (Host,
  Accept, `Accept-Language: en-US,en;q=0.9`, Connection,
  Accept-Encoding, `User-Agent: Armadale/0.1.2 Sparkle/2.10.1`) and the
  DMG with the same headers. The language header is part of "what
  every web request carries" in the Settings line.
- **An update with two sessions running** (9001 to 9002): Install and
  Relaunch raised no question; within a second the old process was
  gone, the bundle was the new build and the new process was up at the
  same path, holding the lock, both tabs Running; the two session
  daemons kept their pids through all of the first four updates. `bin/`
  got `ctty-exec-0.1.3` in place of `ctty-exec-0.1.2`, the persistence
  helper's copy was untouched; Sparkle's two launchd jobs were gone
  afterwards.
- **Sparkle's question** came at the new build's launch (the second
  launch), after the window was up: "Check for updates automatically?"
  with Don’t Check and Check Automatically and no checkbox. The answer
  wrote `SUEnableAutomaticChecks` and `SUSendProfileInfo = 0` into the
  test identifier's domain; Settings › General › Updates showed the
  switch on, and switching it wrote the setting both ways. The real
  `com.tinylittleapps.armadale` domain got no `SU` key.
- **The loss warning and Cancel** (9002 to 9003, with a staged
  `lossSeenAt`): "macOS may end 2 sessions when Armadale quits", the
  Background App Activity text and "If you cancel, the update stays
  ready and is normally installed the next time Armadale quits.", with
  Open System Settings, Install Anyway and Cancel. After Cancel the
  alert and Sparkle's window closed, the build kept running, Sparkle's
  jobs stayed. A quit event without a reason (what Sparkle sends) then
  raised the ordinary question ("2 sessions are still running"): the
  gate was shut. Keep Running in Menu Bar, then Quit, Keep Sessions
  Running and Quit Anyway: within a second of that quit the bundle was
  build 9003, no Armadale was running, the daemons were alive, and the
  last-quit record was of kind `user`.
- **Menu bar mode** (9003 to 9004): with `SULastCheckTime` moved so the
  scheduled check was due, the check came on time while the build was
  in menu bar mode; no window opened, the app in front stayed in front,
  and the status menu had Update Available…. Pressing it brought
  Sparkle's window forward and removed the item; Remind Me Later closed
  the window and gave the front back. Installing from there (Check for
  Updates… is reachable in menu bar mode) raised no question, and the
  new build came up as a regular app with its window and both sessions.
- **Background App Activity switched off** (9005 to 9006). The first
  attempt (9004 to 9005) proved nothing: the entry the owner had
  switched off was not the test builds' (a plain quit left three
  sessions alive for 40 s); the test identifier had an entry of its
  own. With every Armadale entry off, the three sessions the closed
  build had left were ended at once; a plain quit then ended a fresh
  session within two seconds; and the next launch said "macOS ended 1
  session after Armadale quit" (Check for Updates… stayed disabled
  until that alert was answered: the updater starts after the launch
  alerts). Then the update, with two fresh sessions: the loss warning,
  Install Anyway at 22:47:27, and within a second the bundle was 9006
  and the new build was up; **macOS did not stop Sparkle's installer,
  and both sessions were still running half a minute later**, attached
  to the new build. `lossSeenAt` stayed set, as it should with the
  entry off. One run; DESIGN section 13 says what it does not settle.
- **Found on the way.** (a) A menu item pressed by a substring of its
  title ("Settings…") was the Apple menu's System Settings…, which
  opened System Settings; it was closed by its pid. Menu items are
  matched exactly. (b) The three sessions ended by switching the entry
  off while the build was closed came back as Ended with no word about
  macOS: their end was minutes after the quit, outside the window the
  launch check looks at (HANDOFF). (c) After Remind Me Later in menu
  bar mode `NSRunningApplication.isHidden` read false, though no window
  was on screen and the app was not active. (d) A search of `~/Library`
  with `find` hung for two minutes and was stopped; the test builds'
  leftovers are at known paths (`Caches`, `HTTPStorages`, `WebKit`,
  `Preferences`, each under the bundle identifier). (a) and (d) are
  rules in AGENTS.md since the same night ("Rules learned the hard
  way").
- **Not checked**: HANDOFF's list for the updater, now shorter.
- **Cleanup**: the builds, the state directory and the feed removed,
  the server stopped, both defaults domains and the three folders under
  `~/Library` deleted, the throwaway key deleted, no Armadale, helper
  or Sparkle process and no Sparkle launchd job left. The test builds'
  entry stays in the Background App Activity list.

## November 17, 2026: the update key exists

November 17, 2026 (the owner made the key and put its public half into
`project.yml`; the coordinating session checked and committed it; no
app code changed): **the update signing key exists and its public half
is `SUPublicEDKey` in `project.yml`, so a Release build starts the
updater.** A Debug build still never does, and no Release build has
been made with the key.

- **The key**: the owner ran `scripts/sparkle-tool.sh generate_keys
  --account armadale` that morning and uncommented the `SUPublicEDKey`
  line in `project.yml` with the key it printed. `xcodegen generate`
  carries it into `Armadale/Resources/Info.plist`.
- **Checked**: the login keychain has the item (service
  `https://sparkle-project.org`, account `armadale`), read by its
  attributes only, never the key. The item's comment, which
  `generate_keys` wrote, names the same public key as `project.yml`,
  and that key decodes to 32 bytes. Gate: 945 tests, no warning from
  Armadale's code.
- **Not checked**: no signature was made with the key
  (`scripts/release.sh` signs a scratch file with it and verifies the
  signature against `project.yml` before it builds); no Release build
  was made, so the updater was not seen starting in one.
- **Documents**: README, "Releasing", now says that the key exists and
  that `generate_keys` must not be run on a Mac that lacks it (it would
  make a different key; such a Mac imports the key). DESIGN section 8,
  "Updates", says the key is set. HANDOFF: making the key is no longer
  open; what is left of item (1) of "The updater: what is left" is the
  first signature and the first Release build.

## November 17, 2026: Armadale 0.1.2 (30), built and notarized, not published (dc03cc5)

November 17, 2026, 08:52 to 08:55, on the owner's word: **the first
release run with the updater in it and the first signatures with the
update key; 0.1.2 (30) is notarized, stapled and installed on the
owner's Mac.** The version stays 0.1.2; only the build number rises.
The installed 0.1.2 (29) had no updater.

- `scripts/bump-build.sh`: 0.1.2 (29) to 0.1.2 (30), `project.yml`
  only, committed as dc03cc5 after the gate had passed on it (945
  tests, no warnings; the SSH integration tests did not run, as in
  every gate run).
- `scripts/check-state-compat.sh`: the working tree writes schema 2,
  and v0.1.0 and v0.1.1 both answer `newerVersion`.
- `scripts/install-release.sh` on the clean tree at dc03cc5, 3 min 6 s
  in all:
  - **Preflight.** `sign_update --account armadale` signed a scratch
    file, the first signature with the key. The keychain asked whether
    `sign_update` may use the key and the run waited about half a
    minute until the owner had answered; then "the keychain's update
    key matches SUPublicEDKey". The keychain did not ask again at the
    second signature, of the DMG (made at 08:55:20, three seconds
    before the run ended).
  - **Archive**, with the release's own DerivedData: the packages
    resolved (Sparkle "cached") without the hang SwiftPM's download
    had shown on that Mac.
  - **Signatures**: the app, both helpers and Sparkle's code (the
    framework, `Autoupdate`, `Updater.app` and its executable) carry
    the Developer ID of YJ8LXVCB3T, the hardened runtime and a secure
    timestamp; no entitlements on the helpers or on Sparkle's code.
    The built Info.plist has the feed, the public key of
    `project.yml`, no automatic installs, verification before
    extraction, no system profile and no JavaScript.
  - **Notarization**: the app with the framework in it and the DMG,
    both "Accepted" with notary logs without issues, both stapled;
    Gatekeeper "Notarized Developer ID" for both.
  - **The DMG signed for the updater**: the EdDSA signature of its
    17,162,822 bytes verifies against the built app's
    `SUPublicEDKey`, and `build/release/appcast-item.xml` holds the
    item (version 30, 0.1.2, minimum system 27.0, the notes link, the
    URL of the GitHub Release asset that does not exist yet).
  - The app installed over build 29 in `~/Applications`. The run
    deleted the DMG of build 29 with `build/release/`.
- Checked again by hand: the installed app is 0.1.2 (30); every file,
  link and directory in it is identical to the archived app (60 files
  and 5 links, compared by hashes and link targets) and both have the
  same CDHash; its signature verifies (`--deep --strict`); `spctl`
  accepts it as "Notarized Developer ID" and its stapled ticket
  validates; its `SUPublicEDKey` is `project.yml`'s. The DMG's
  signature in `appcast-item.xml` verifies against the key in
  `project.yml` with `scripts/ed25519-verify.swift`, which needs no
  private key.
- **Found**: `diff -r` on an app with Sparkle's framework in it writes
  "Directory loop detected" for the directories it had already reached
  through the framework's links and exits 0. `release.sh`'s comparison
  of the DMG's app with the archived one therefore passed with six
  such lines in `build/release/verify/dmg-app.diff`: every file was
  compared once, but not that the links are links; the signature check
  that follows covers those. Not changed (HANDOFF, open items,
  Shipping).

Not done, on purpose: no tag, no GitHub Release, no item in the feed
(`scripts/appcast.sh` needs the release asset), no state fixture, no
change to the website, and no agent ran the installed app. So the
updater was still not seen starting in a Release build, and an update
between two Developer ID signed builds was not seen either (HANDOFF,
"From finished changes"). HANDOFF's list for the updater lost the
release run: the Developer ID signing of Sparkle's code, the preflight
against the keychain, notarization with the framework, `sign_update`
and `appcast-item.xml` are checked by this run. The DMG's size and
hash are in the local file of the Mac it was built on. How to publish
this very build is under "Next" in `HANDOFF.md`.

## November 17, 2026: Armadale 0.1.2, released

November 17, 2026, afternoon, on the owner's word ("Please cut a
release 0.1.2"): **Armadale 0.1.2 is released: build 30 from dc03cc5,
the build of that morning, tagged `v0.1.2`, on GitHub with the
notarized DMG, on the changelog page as the latest release and in the
update feed.** It is the first release with an updater and the first
that writes state file schema 2. Nothing was built again: the DMG in
`build/release/` still had the hash recorded in the morning, and only
documents had changed since dc03cc5.

- **A launch first.** No one had launched build 30: the owner's
  settings held no key of the updater and the state directory was last
  written on November 14. Asked whether to publish like that, the
  owner opened the installed build and chose Check for Updates…; it
  answered that Armadale was up to date (the feed was empty then).
  Afterwards the settings held `SUHasLaunchedBefore` and
  `SULastCheckTime`. Before that, on disk only: the Release binary
  links `@rpath/Sparkle.framework/Versions/B/Sparkle` with the rpath
  `@executable_path/../Frameworks`, which is where the framework is.
- **The tag and the GitHub Release**: `v0.1.2`, annotated, at dc03cc5,
  pushed; the release "Armadale 0.1.2" with `Armadale-0.1.2.dmg` and
  `Armadale.dmg` (17,162,822 bytes each), published at 23:01 UTC and
  now the latest, so the site's Download button gives 0.1.2. The notes
  are written from the changelog page and say first what a user has to
  know: 0.1.1 and earlier cannot update themselves and get 0.1.2 by
  downloading it once, and 0.1.1 and earlier refuse a layout this
  version saves.
- **The changelog page**: "Next release" became the 0.1.2 section
  (`v0.1.2`, November 17, 2026, the "Latest release" pill, a note with
  the links); 0.1.1 gave up the pill and its link to the latest
  download, which is 0.1.2 from now on. There is no "Next release"
  section until there is new work.
- **The feed**: `scripts/appcast.sh` downloaded the release asset,
  checked its length and the item's signature against the key in
  `project.yml`, made the notes from the 0.1.2 section (7 items) and
  put the item into `docs/appcast.xml`. Committed with the changelog
  as f1e0fca and pushed; a few minutes later
  `https://armadale.dev/appcast.xml` served the same file and the
  changelog page showed the 0.1.2 section.
- **Found: a test that depended on the real feed.** `AppcastTests`'
  script test inserted a sample 0.1.2 (30) into a copy of
  `docs/appcast.xml`; with the real item in the feed the script
  refused the second build 30, and the gate failed on that one test.
  The test now starts from the real feed as it was before its first
  item (f1e0fca). The script and the feed were right.
- **The state fixture**: `scripts/state-fixtures/v0.1.2.swift`, a copy
  of `current.swift`, run against the tag, wrote `state-0.1.2.json`
  (schema 2, with the orphan reclaim's record and a session's grid
  size); `StateFixtureTests` has its line and `contentOf012`.
  `scripts/check-state-compat.sh` now also runs v0.1.2, which loads
  the working tree's file and loses nothing. One more test had counted
  on the list of fixtures: `GridSizeTests.olderFilesHaveNone` ran for
  every released version and failed for 0.1.2, whose fixture has a
  grid size; it now names 0.1.0 and 0.1.1, the versions it is about.
- **Gate**: 945 tests before the fixture and 946 with it, no warning
  from Armadale's code. The runs that recompiled the test target have
  the two tool warnings described under "an updater, with Sparkle".
  The SSH integration tests did not run.

Resolved in HANDOFF by this change: "Publishing 0.1.2" under "Waiting
for owner decisions", and from the updater's list the updater seen
running in a Release build, `scripts/appcast.sh` against a real
release asset and the real feed with an item. Its status list starts
again from this release. Still open there: a check against the feed
with its item, Sparkle's question at the second launch in a Release
build, and an update between two Developer ID signed builds, which
only the next release can show.

## November 24, 2026: recording a pane (f127458)

The owner asked for a way to record a pane from its context menu, with
a pulsing red light while it records and a stop button; he took SwiftTerm
to record through termcast. It does not in a way Armadale can use
(Part 2, section 7: termcast is a separate tool that starts its own
shell), so Armadale writes the same file format, asciicast v2, itself.
The owner decided the save sheet each time, the header's dot and stop
button, and the tab's dot; the coordinator decided the rest (Part 2,
section 8). Built by the implementer, reviewed the same day, fixed after
the review; not committed when this was written.

- **What was built.** `TerminalSurface.screenSnapshot()` (section 5), in
  `SwiftTermSurface` through a `TerminalView` subclass that reads the
  terminal while it answers four DECRQM queries; in `ArmadaleSessions`
  the format (`Asciicast`, `UTF8StreamDecoder`), the writer
  (`RecordingFileWriter`: decoding, escaping and writing on its own
  queue, a 32 MB backlog cap, whole lines only, a bounded wait), the
  recording (`PaneRecording`, which can be pending), the tracker of where
  the output stream stands (`TerminalStreamTracker`, a copy of SwiftTerm's
  parser framing) and the controller's API (`startRecording(to:title:)`,
  `stopRecording()`, `stopRecordingNow(until:)`, `recording`,
  `isRecordingPending`, `canStartRecording`, `recordingWriter`,
  `recordingDidFail`), with the four `surface.feed` sites made one
  (`feedSurface`); in the app the pane menu's Record Pane… / Stop
  Recording, the save sheet and the problem alert behind a presentation
  seam (`WorkspaceActions+Recording.swift`), the header's Core Animation
  dot, stop button and give-way rule, the tab's dot in the tab bar and the
  sidebar, the registry's part (`SessionRegistry+Recording.swift`: a file
  in use refused, problems told one at a time, the quit's one-second wait
  for every writer of the run), and the save sheet ended in
  `endSheetsForQuit` and when its window closes.
- **The review** (the coordinator's fix list: one blocker, seven medium,
  the rest low; Part 2, sections 5, 7 and 8). The blocker: Record
  confirmed while the output had stopped inside a sequence cut that
  sequence short in the pane and began the file with its tail, about
  every second Record on a streaming agent. Now the recording waits for
  the first point between sequences. The others: a quit's unbounded wait
  on a writer, a quit leaving a file unfinished after an asynchronous
  end, a host's removal not ending the recording, the `TimelineView`
  pulse's cost, decoding on the main actor, U+2028 and U+2029 written
  raw, half a line after a failed write, failures dropped, the pending
  wrap and reverse video and the saved cursor missing from the snapshot,
  a test that could not catch a late answer, overlaps in a very narrow
  header, test-only API, the save-panel tests putting windows on screen,
  two recordings into one file, a name over 255 bytes; each fixed and
  tested.
- **How it was checked.** The gate before the change: 946 tests, no
  warning from Armadale's code. After the first build: 985; after the
  review's fixes: 1005, no warning from Armadale's code (not even the
  tool's "missing a dependency" line in that run). New since the first
  build: `TerminalStreamTrackerTests` (6), more `AsciicastTests` (the
  writer's raw bytes, U+2028, a write cut short, the cap, the bounded
  wait), pending recordings and a host's removal in
  `SessionRecordingTests`, the pending wrap, reverse video and the saved
  cursor in `ScreenSnapshotTests`, and in `PaneRecordingTests` the
  give-way rule, the header drawn at five widths, the dot's animation
  through a title change, problems one at a time, a file in use, an emoji
  name, and the reviewer's five splits end to end (the pane equal to an
  undisturbed terminal, playback equal to the pane). The tracker costs
  about 2.2 µs per kilobyte of colourful output optimized, 31 µs in
  Debug. The SSH integration tests did not run.
- **Live check: stopped at the first screenshot.** The owner had granted
  Accessibility, event posting, Screen Recording and Automation that day
  (all four read true). After waiting for the idle gate (the owner had
  been away for 35 minutes), a test build copy with its own environment
  was launched and one screenshot of its window was taken with
  `screencapture -l`. macOS then put up an alert from
  UserNotificationCenter for the Claude app ("requesting to bypass the
  system private window picker", Allow / Open System Settings), which
  took the front; the next frontmost check refused the first click, so
  no input was sent, and the live part stopped there. The alert was left
  unanswered for the owner (`HANDOFF.local.md`). The test build was ended
  by SIGTERM to its pid, its state directory, defaults suite, app copy and
  screenshot removed. `scripts/check-quit.sh` passed on the final build
  (158, 71 and 138 ms). HANDOFF lists what was not seen.
- **Found.** SwiftTerm's DECRQSS answer for the pen is wrong for basic
  colours (a trailing separator that reads back as a reset) and leaves
  out dim, italic, crossed out and the underline style, so the pen is
  read from `Terminal.currentAttribute` (Part 2, section 5). In SwiftTerm
  CAN does not end a CSI or an escape, and a UTF-8 continuation byte below
  0xA0 at the start of a read ends an OSC string (Part 2, section 7). The
  accessibility tree of a SwiftUI header in an unhosted test is empty, so
  the header tests read the drawn picture. A test that reads the screen
  through a query (`screenState()`) disturbs a sequence the program left
  unfinished, so the split tests wait on the view's public text instead.
  The first screenshot an agent takes can raise a system alert that
  takes the front (above).
- **Second review** (the same day; no live part, the alert still up).
  The reviewer confirmed the 17 fixes and the gate, and found four low
  things, fixed with a fifth item: the differential test against SwiftTerm
  is in the tree; SwiftTerm's RIS quirk (Part 2, section 7) is written
  down, not copied; a file whose earlier recording is still being written
  is refused; a problem alert taken down unanswered is told again; the
  licence files say SwiftTerm's parser table is adapted. Gate: 1009 tests,
  no warning from Armadale's code.
- **Live pass, in part** (the same day, after the commit and after the
  owner had answered the alert with Allow; the reviewer, on a copy of
  the Debug build under /tmp with a state directory of its own, driven
  by accessibility presses by pid, with one window screenshot first: no
  alert came back). It stopped early: before the first press of the stop
  button the frontmost check found the Claude app in front, with 9.6 s
  of idle time, so someone was at the Mac, and by the rule all live
  testing ended there. Seen before that: an empty pane's menu is Split
  Right, Split Down, Theme, with no recording item; a pane with a
  session has Record Pane…, enabled, after Save as Favorite…; the save
  sheet's field held "-tmp-armrec-w 2026-11-24 at 17.02.57.cast" for a
  zsh titled /tmp/armrec/w, and its buttons were Cancel and Record;
  while recording, the tab row read "Running, /tmp/armrec/w, Recording,
  ⌘1" and the header had "Recording", a "Stop Recording" button and
  "Pane Menu"; the file was sound (a version 2 header, 117×39, the
  prompt with its colours as the first frame, output events only, times
  increasing, read by termcast's own types). Three things came out of
  it. The suggested name started with a dash: fixed (Part 2, section 8).
  A "/" the reviewer posted to the test build, to reach /tmp in the save
  panel, ended the panel as confirmed, so a recording landed in the
  owner's home folder (removed afterwards) and the "/" reached the shell:
  now a rule for live checks in AGENTS.md; whether a "/" typed by hand
  does the same is not known. And the recording was found ended before
  the reviewer's stop press, with nothing to say why; the full pass
  below looked for it first.
- **Live pass, in full** (the same evening, on f717917, with the owner
  away from the Mac; the reviewer, on a copy of the Debug build with a
  bundle identifier of its own, so that the save panel's folder could be
  set in the copy's own defaults, `NSNavLastRootDirectory`, to a scratch
  folder; the folder was read through accessibility before every
  Record, and nothing was typed while a panel was up). The recording
  that had ended by itself did not come back: one left alone for 90
  seconds still read Recording at each of nine reads, and its file grew
  when the shell printed. Nothing in the code ties a recording to the
  app losing the front, so the first pass's stop was most likely someone
  at the Mac. Seen:
  - the menu: no item in an empty pane; Record Pane… enabled for an
    attached shell, disabled in an ended session's pane;
  - the save sheet: "tmp-armrec-w 2026-11-24 at 17.12.37.cast" as the
    suggested name; "q1" became `q1.cast` and "named.txt" became
    `named.txt.cast`; an existing file brought the panel's own question
    about replacing it; a folder of mode 555 gave "The recording could
    not start." / "The file “ro.cast” could not be created. Permission
    denied.", and nothing was created;
  - quitting with the sheet up: SIGTERM quit the build, no file was
    made and the session lived; the Quit item took the sheet down and
    Armadale's own question about the running session came;
  - the header: the dot pulsing in window screenshots 0.8 s apart (208
    strongly red pixels at the dot, then none), and still pulsing after
    an OSC 0 title change, a switch to another tab and back, minimize
    and restore, and hide and back once the app was active again; the
    stop button and the menu's Stop Recording each ended a recording;
  - the app's CPU (the median of ten `ps` samples a second apart, the
    terminal idle): 0 % with a recording pane visible, minimized and
    hidden, as without a recording;
  - the tab's dot in the tab bar and in the sidebar, also with the tab
    in the background and with a second pane of the tab not recording
    (the rows read "Running, /tmp/armrec/w, Recording");
  - a recording during a flood of 256-colour, bold, underlined and
    italic lines with CJK text: no escape fragment in the pane
    afterwards; the file (76.5 MB, 879 output events over 33 seconds, no
    input event) was read by termcast's own types and, replayed on a
    SwiftTerm surface, ended where the pane had;
  - a recording started inside `top`: the first frame held top's screen
    on the alternate screen, and after top quit the file ended with the
    prompt; one at a prompt with three commands replayed to the pane's
    last screen;
  - narrow panes: at about 99 pt the stop button and "…", at about 46 pt
    "…" alone; nothing overlapped, and the tab's dot still showed the
    recording;
  - quits: after Keep Running in Menu Bar the recording went on with the
    window closed, and after Quit, Keep Sessions Running from the status
    menu the file was whole (556 lines, a newline at the end, read by
    termcast's types); the same after End Sessions and Quit;
  - a full 4 MB volume: one alert, "The recording stopped." / "“full.cast”
    could not be written. No space left on device. What was recorded
    until then is in the file.", the dot gone, the file's last line
    whole;
  - the file of a recording chosen again in a second pane: refused with
    "Another pane is being recorded into “same.cast”. Choose another
    file.", the first file untouched.

  `scripts/check-quit.sh` passed on that build. Found: Record Pane…
  failed during the flood (the next item); the dot seemed dim right
  after an unhide until the app was active, which turned out to be a
  measuring mistake (the item after that); and a tab bar item answers an
  accessibility press without selecting its tab, which was so before
  this change (HANDOFF, open items).
- **Third round of fixes** (after the live pass). A recording can be
  started while a session attached in this run is being attached again,
  as a pending one that starts at the reset: during the flood the pane
  reattached again and again, Record Pane… was disabled in about one of
  three opens of the menu, and a confirm that landed in between was
  refused as "the session is not running in this pane", which was not
  true; the refusals that remain each say what is (Part 2, section 7).
  The dot's layer rests at full red, and the pulse is started again
  whenever its window can be seen again (Part 2, section 8). Short gaps
  in a snapshot are written as spaces (Part 2, section 5).
- **The fixes, checked live** (the same evening, the reviewer, on a test
  copy of the fixed build, the Mac still untouched). During the flood
  the pane menu was opened ten times a few seconds apart and Record
  Pane… was enabled every time, twice while the tab read Starting; five
  recordings were started during the flood and none was refused, two of
  them during a reattach; each file was whole (21 to 45 MB, a version 2
  header, every event read by termcast's own types), and one, replayed
  on a SwiftTerm surface, ended where the pane had. The dot: after an
  unhide without activation, in a window visible but not key, it pulsed
  from the first screenshot. The reviewer corrected its earlier
  observation there: it had measured the wrong pixels (Part 2, section
  8). Reading the new rule, it found two edges, both closed by the
  coordinator: no recording starts while a respawn is under way (its
  state can still read attached while the old session is killed, and the
  recording would have run on into the fresh session), and a
  disconnected pane becoming unavailable ends a recording that was
  waiting there. Gate: 1019 tests, no warning from Armadale's code.

## November 24, 2026: the tab bar's tabs answer an accessibility press (72e38d8)

Found in the live pass of recording a pane, and so before that change: a
tab in the tab bar answered an accessibility press with success and did
not select its tab, while a sidebar row did. The owner had it fixed the
same evening, by the coordinator, without the implementer and reviewer
loop (three lines in `TabItemView`).

- **Built.** A tab is one accessibility button whose default action
  selects it, as a click does, with Rename as its other action, and its
  children stay separate while its rename field is up, as a sidebar row
  does (Part 2, section 8). On the changelog page.
- **Checked.** Gate: 1019 tests, no warning from Armadale's code. No
  unit test reaches a SwiftUI accessibility action in an unhosted test,
  so none was added. Live, on a copy of the Debug build with a bundle
  identifier, state directory and defaults suite of its own, opened in
  the background (`open -g`) and driven by accessibility presses on its
  pid alone, with no synthetic event (the Claude app stayed in front
  throughout): with two tabs, a press on the tab reading "New Session,
  ⌘1" made it the selected one (its `AXSelected`, and `selectedTabID` in
  the copy's state file), and a press on "⌘2" selected that one again;
  the tab's actions were `AXShowMenu`, `AXPress` and Rename; Rename
  brought a text field named "Name" into the accessibility tree, and a
  quit by SIGTERM left both titles as they were. The copy, its state
  directory and its defaults were removed.
- **Found on the way.** A main menu item pressed through accessibility
  (File › New Tab) answers success and does nothing while the app is in
  the background with no key window: its action goes up a responder
  chain that starts nowhere. The tab bar's New Tab button, a SwiftUI
  button, works there. Not seen: VoiceOver itself.

---

# Part 2: the history of each design section

## Document header

**October 19, 2026. Status of the build order.** All nine steps of the
build order (section 12) are implemented, reviewed and committed on
`main`: step 8 is menu bar mode (the quit question, accessory mode with a
status item), step 9 is Developer ID signing and the release pipeline
(section 11). This document is the contract the code was built against
and was kept in step with it: paragraphs marked *Step N* or
*Implementation (step N)* recorded what that step built and where it
deviated from the original plan.

## 1. Concepts and hierarchy

**November 14, 2026. Status from controllers.** Since every session has a
controller from the start and every live restored session is attached
after launch (section 4, "Restore at launch"), a session's status comes
from its controller whether or not its pane was shown. Until then a
restored session that was never shown kept the launch probe's answer
(`liveAtLaunch`, `remoteLive`) for its whole life, so one that ended in a
tab not visited since the launch stayed ● running in its tab's and the
sidebar's glyph and in the quit question's count (the architecture
review's second pass). What is left of that is one case, a restored
session that is not attached (no saved size yet, its host needs the
user, its listing not answered), which still shows the listing's answer
and is not refreshed until it is attached; the owner accepted that with
the decision to leave sessions without a saved size unattached.

**October 23, 2026. Empty tab groups and workspaces removed.** Since
October 23, 2026 a tab group is never kept without tabs, and a workspace
is never kept without tab groups: closing or moving away a group's last
tab removes the group, and removing a workspace's last group deletes the
workspace. Until then the emptied group was kept and showed an empty
state with New Tab; moving a group's last tab away now removes the group.
The repair after every load drops such a group, so that state and ⌘W
closing it without asking remain only as defensive code.

**October 24, 2026. New panes start empty.** Since October 24, 2026 a new
pane starts **empty** and shows the *New Session* chooser (section 8,
"New sessions") until the user picks a favorite or fills in the New
Session dialog.

**October 30, 2026. Tab group shortcut in the sidebar.** A tab group row
of the current window's workspace ends in its shortcut, ⇧⌘1…⇧⌘9 for the
first nine groups (owner's decision, October 30, 2026, in place of the
group's tab count).

**Step 4. Shared status glyph, starting and unavailable.** The glyph is
shared by the sidebar's tab rows and the tab bar (`StatusGlyph`), computed
by `SessionRegistry.status(of:)`. Two states were added: *starting*
(dotted circle: not attached yet, or a pane never shown whose session the
launch probe did not find alive) and *unavailable* (the persistent runtime
could not be set up). A tab shows the most important state of its panes:
disconnected, unavailable, running, starting, and ended only when all have
ended.

**Step 7. Attention state and final precedence.** ◐ attention (SF Symbol
`circle.lefthalf.filled`, purple) was added in step 7, shown by a pane
whose program rang the bell or sent a desktop notification sequence while
nobody was looking at it (section 10), and the final precedence was set
(`SessionStatus.precedence`, unit-tested): disconnected, unavailable,
attention, running, starting, ended.

**October 29, 2026. No selection and no highlight in the sidebar.**
**The sidebar has no selection and no highlight** (owner's decision,
October 29, 2026): the `List` has no selection binding. The step 4
highlight on the shown tab group's row, and then the shown-path highlight
of the same day, both kept leaving the List with the keyboard or the wrong
row highlighted.

**October 29, 2026. The sidebar list never takes keyboard focus.** That
SwiftUI's `.focusable(false)` does not stop the outline view behind the
List from becoming first responder was seen live: the outline view took
the keyboard on every row click without
`WorkspaceWindow.makeFirstResponder(_:)` refusing it
(`SidebarFocusTests`). With no selection and the outline view refused,
arrow keys and Full Keyboard Access no longer reach sidebar rows (owner's
decision); the accessibility button and its Rename action for VoiceOver
were not checked live.

**October 29 and 30, 2026. Title weight and icon colours.** The rules are
the owner's, of October 29 and 30, 2026 (`SidebarShownPath`, unit-tested).
Until October 29 the sidebar List tinted every icon blue in the key window
and gray otherwise, and the current workspace's icon was blue in every
window; until October 30 only the current workspace's row was semibold
(in every window) and a tab needing attention was semibold wherever it
was (owner's decision: semibold means the shown path and nothing else;
attention keeps ◐ and the purple counts).

**Live check. Return after a row click.** That clicking a sidebar row does
not give the list keyboard focus, so Return keeps going to the terminal,
was verified live.

**October 29, 2026. Double click across overlapping windows.** When the
window brought forward by the first click of a double click covers the
spot clicked, the second click lands in that window instead and no edit
starts (seen live, October 29, 2026, with two overlapping windows; the
context menu's Rename works there).

**Inline rename replaced the rename sheet.** Renaming used to be a sheet;
inline editing replaced it, and the Workspace menu's three Rename items
went with it.

## 2. Data model (`ArmadaleCore`)

**November 14, 2026. `Session.gridSize`.** Each session's last grid size
(columns and rows of the size last applied to its program's PTY while
attached) was added so a session whose pane is not on screen can be
attached at launch without resizing its program. It is the session's own
size, not one computed from the layout (owner's decision, November 14,
2026: a tab not on screen keeps the size it had when last shown). Rejected: deriving a size
from the layout and the window frame (a guess that is wrong for every
split and every font change since); reading the size from the
persistence helper, whose listing gives `name pid clients created cwd`
and no size, while its per-session log does record `resize rows=R cols=C`
at debug level (rejected by the owner: a log is not an interface, and the
helper version may change it); 80 × 24 for sessions without one (rejected
by the owner: no program is resized on a guess). `setGridSizes` takes
several at once so a live window resize is one model change.
`replaceSession` gives a respawn's fresh session the old one's size.

**October 30, 2026. Per-pane theme.** `Pane.themeID`, the pane's own
theme (nil: Settings), dates from October 30, 2026.

**Step 6. Host SSH config file.** `Host.sshConfigFile` (`ssh -F` instead
of ~/.ssh/config) was added in step 6.

**October 24, 2026. Session options and favorites.** A session's
arguments became the profile's `launchArguments`, then the
`SessionOptions` the New Session dialog chose, then `additionalArguments`.
The options are recorded on the session (`Session.options`), so
**Respawn** composes the profile as it is then with the session's own
options (`launchForRespawn(of:)`), and an older file's session without
options respawns as before. `Favorite`s are saved with the layout.

**Implementation (step 10a). What the code names and decides.** Step 10a
recorded the details of panes, options, favorites, directory resolution
and `ShellWords` (now in section 2 of DESIGN). The flag table
(`OptionFlags` on `AgentIntegration.optionFlags`, with
`AgentIntegration.arguments(for:)`) was built in 10a with the model rather
than in 10b. The lookups `pane(_:)` and `emptyPaneIDs(in:)` were added
then.

**Step 5. Respawn uses the current profile; built-in profiles.** A session
still records the `LaunchSpec` it was created with, so a running session
is unaffected by later profile edits, but from step 5 **Respawn uses the
profile as it is at respawn time** (`AppModel.launchForRespawn(of:)`,
asked by `SessionController` through its delegate), falling back to the
recorded launch when the profile has been deleted. Built-in profiles
(`Profile.isBuiltIn`) cannot be deleted, and only their name and icon can
be changed; duplicating one gives a fully editable copy.

**Step 7. Attention integration on profiles.** Step 7 added
`Profile.attentionIntegration` (Bool, on by default; state saved without
it decodes as on), `Profile.launchArguments`, `Profile.refreshingBuiltIn`
(applied by `AppModel.init`), `AppModel.onSessionsRemoved` and
`Profile.isAgent`. `AppModel` gained the lookups `place(of:)`,
`focusedSessionID(in:)`, `sessionOrder` and `sessionIDs(ofTabGroup:)`.

**Step 4. Divider moves and layout shape.** `moveDivider(of:toward:by:)`,
`hasSameShape(as:)` and `clampingRatios()` were added to `PaneLayout` in
step 4.

**Step 4. AppModel hierarchy intents.** Step 4 added `moveTabGroup`,
`closeTabGroup`, `closeOtherTabs(than:)`, `selectTab(number:)`,
`selectTabGroup(number:)`, `selectAdjacentTab(offset:)`, `moveFocus(_:)`,
`resizeFocusedPane(toward:by:)`, `equalizePanes`, `toggleZoom` and
`setSplitRatios(_:for:)`.

**Step 5. AppModel profile intents.** Step 5 added the profile intents
`newProfile`, `duplicateProfile`, `updateProfile` and `deleteProfile`,
plus `launchForRespawn(of:)`.

**Step 6. AppModel host intents.** Step 6 added the host intents
`addHost`, `updateHost`, `removeHost`, `sessionIDs(onHost:)` and
`newTab(in:onHost:profile:)` (home directory on the host, default
profile).

**October 24, 2026. Empty panes and the chooser replace defaults.** The
default profile and directory preferences are gone with the chooser;
`newWorkspace`, `newTabGroup`, `newTab(in:)` and `splitPane` now create an
**empty pane** (`Pane.sessionID == nil`) and no session,
`newTab(in:onHost:profile:)` is removed, and `startSession(in: PaneID,
request: SessionRequest) -> SessionID?` creates the session. The favorite
intents were added. `defaultWorkingDirectory` stays, as the home directory
a blank request directory means.

## 3. Persistence of layout: `StateStore`

**November 14, 2026. `last-quit.json`, beside the state file.** The record
of what a quit left running (section 8, "Background App Activity") was
kept out of `state.json` on purpose: it changes at every quit and every
launch check, nothing in the layout depends on it, and keeping it apart
leaves the state file's schema, the fixtures and
`scripts/check-state-compat.sh` untouched. It carries a version of its
own; a file of another version counts as absent, like a damaged one. A
fatal or locked-out launch never touches it (`LaunchStateTests` stage one
in each fatal case and compare the directory before and after).

**November 14, 2026. `Session.gridSize` at schema 2, no bump.** Applying
the version rule: 0.1.0 and 0.1.1 refuse every schema-2 file by version,
so the field needs no bump and no entry in `accepted-drops`.
`scripts/check-state-compat.sh`, with `current.swift` now recording a
size: "working tree writes schema 2 / v0.1.0: newerVersion / v0.1.1:
newerVersion", exit 0. With `--as-schema 1` it shows what the check
would catch without schema 2: v0.1.0 `unparseable` (the empty pane), and
v0.1.1 `loaded, would lose: sessionListIncomplete, sessions[*].gridSize,
sparedSessionIDs`. The repair drops sizes outside 1…4,000 columns and
1…2,000 rows (larger than any screen shows at 6 pt).

**November 14, 2026. Schema 2.** `schemaVersion` has been 2 since
November 14, 2026.

**October 24, 2026. Favorites stored.** The state file has stored
favorites since October 24, 2026.

**November 14, 2026. The version rule.** The version rule dates from
November 14, 2026. Released builds then out: 0.1.0 of October 23 and
0.1.1 of November 5, 2026.

**November 14, 2026. What a refusing build does.** From November 14, 2026
a build that refuses the file (newer or unreadable), like one locked out
of the directory, uses nothing in the state directory beyond opening the
lock file and reading the state files.

**November 14, 2026. Schema 2 and how schema 1 grew.** Schema 2 (November
14, 2026) is a version-only step. Schema 1 grew additively, each field
decoding with a default when absent: `Profile.attentionIntegration` (true)
and `WindowState.isFullScreen` (false) before 0.1.0; for 0.1.1 an
optional `Pane.sessionID`, top-level `favorites`, `Session.options`
(October 24) and `Pane.themeID` (October 30); then `sparedSessionIDs` and
`sessionListIncomplete`.

**Step 10c. Dangling pane sessions.** The repair turning a pane whose
`sessionID` names a session missing from the file into an empty pane came
in step 10c; before, such a pane was kept and showed a blank view.

**Measurement. `scripts/check-state-compat.sh` run time and results.** It
builds every released version (about 20 s in all with two). With the file
set back to schema 1 it answers `unparseable` for v0.1.0 and, for v0.1.1,
`loaded` losing `sessionListIncomplete` and `sparedSessionIDs`; at schema
2, `newerVersion` for both.

**October 23, 2026. Empty closed workspaces on load.** Loading drops empty
closed workspaces, the husks that closing a workspace's last tab group
left before October 23, 2026. The repair drops tab groups left without
tabs, which moves kept before October 23, 2026.

**Launch backup.** Since the launch backup (`state.json.launch.bak`),
removing `state.json` and `state.json.bak` alone no longer gives a fresh
start.

**November 14, 2026. Orphan reclaim fields.** The two top-level fields for
the orphan reclaim, `sparedSessionIDs` and `sessionListIncomplete`, were
added on November 14, 2026, in schema 1 (absent: none, false).

**One process per state directory. The `O_CLOEXEC` test.** A test spawns
a child while the lock is held, releases it and takes it again; its
control shows that a descriptor opened without the flag is inherited and
keeps the lock. Builds before this lock (0.1.1 included) take none.

**SwiftData considered.** SwiftData was considered and rejected: the state
is a small tree that is easier to inspect, diff and migrate as JSON.

**November 17, 2026. 0.1.2 is a released reader.** With its release,
0.1.2 joined the versions the rule is about: it writes schema 2, its
fixture is `state-0.1.2.json`, and `scripts/check-state-compat.sh`
answers `loaded` for it (Part 1, "Armadale 0.1.2, released").


## 4. Session persistence: the zmx backend

### Isolation

- **Verified: spaces in the runtime path.** Spaces in the `ZMX_DIR` path
  (`~/Library/Application Support/Armadale/run`) were verified to be fine.
- **Verified: the detach key.** `ZMX_NO_DETACH_KEY=1` was verified to let
  Ctrl+\ reach the application in the pane.

### Bundling

- **October 15, 2026. Pinned zmx version.** Pinned version: **0.8.1**
  (latest as of 2026‑10‑15; macos-aarch64 SHA‑256
  `1d86b1c9fba47fa707a6f0e976b20510b07c1c26d0ed010b9414b2a2c5e6beef`).
- **Implementation notes: the embed phase.** The notes on the
  `scripts/embed-zmx.sh` phase (user-script sandboxing off, `fetch-zmx.sh`
  run when `Vendor/zmx` does not verify against `zmx.lock`, ad-hoc versus
  Developer ID hardening) were recorded as *Implementation notes*; zmx was
  verified to run hardened: the integration tests pass against a hardened
  copy.
- **The first `ctty-exec`.** `Contents/Helpers/ctty-exec` was first
  described as a ten-line trampoline built from source in this repo.

### `PersistenceBackend` protocol

- **Step 3. `resolveExit`.** `resolveExit` was added in step 3: a zmx
  client exits the same way whether its session ended or only the client
  went away, so the backend decides from the session itself (`exists(id)`;
  listing errors count as `.detached`).
- **October 23, 2026. Exit statuses.** Since October 23, 2026 `.ended`
  carries the program's exit status when the session's recorder wrote one,
  and `recordedExitStatuses` reads the records of sessions that are already
  gone (the launch path; section "Session lifecycle", Ended).
- **Step 6. `BackendError` for hosts.** Step 6 gave `notPersistent` a
  `reason` (why a host cannot keep sessions) and added `unreachable` (ssh
  could not connect or lost the connection: nothing is known about the
  session).
- **Verified: create and attach.** zmx 0.8.1 has no attach‑only flag, so
  the backend builds the two operations itself (all verified empirically).
- **Step 3. Telling the cases apart.** Looking at a client's first output
  without consuming it (`ESC[2J` first: attached; `session "a-<id>"
  created` first: did not exist; anything else, or nothing within 2 s:
  `runtimeFailure("Could not establish the session.")`) was built in
  step 3. The 150 ms wait after `created` and `ESC[2J` in `create` comes
  from reading zmx's `main.zig`/`loop.zig`: the client prints `ESC[2J`
  before it sends its Init message, and only Init marks the daemon as
  having had a client.

### Session lifecycle
- **November 14, 2026, live checks. One SIGWINCH per relaunch at an
  unchanged size: an effect of the test's staging.** In the reviewer's
  first live run every pane's program on the primary screen (a shell
  trapping WINCH, in a tab not shown and in the shown one) logged one
  SIGWINCH at each relaunch, with rows, columns and pixels unchanged
  (`TIOCGWINSZ` before and after); a plain attach of the helper at that
  size caused none. The implementer then relaunched the same build
  (8d6bb99) twelve times and saw none: a tab not shown and the shown
  one, a plain `sh` loop, an interactive `zsh -f` and a login `zsh`,
  quits by SIGTERM and through the quit alert and the status menu, the
  app frontmost or not, the helper's per-session log showing the same
  `init resize` and `resize` at every attach. A change of the client's
  environment (the helper's tracked variables) was excluded on the way.
  The reviewer's second run found the difference by changing one thing
  at a time, on six sessions with the helper's log and `TIOCGWINSZ`
  read immediately before and after each launch. Sessions that only
  attaches had ever touched logged nothing in five relaunches: two made
  as Armadale's create makes them (one shown, one never shown), and one
  made by Armadale itself through Respawn All Ended, in a tab not shown
  at its saved size, in two. Every session the helper's `send` or `run`
  had touched logged one SIGWINCH at every relaunch. The decisive one
  logged nothing at its attach in the first run, got a single `send` of
  a space while the app was not running, and logged one at every
  relaunch after that; the helper's log and the pty's size were the
  same in both groups, so what the helper keeps is not visible (a pixel
  size of zero from the `send` client is a guess). All three loggers of
  the first run had been started with `send` or made with `run`. One
  thing does not fit and was not followed up: the implementer's two
  `zsh` sessions had their loops typed in with `send` and logged
  nothing; whether those loggers worked was not checked with a real
  resize. Armadale never runs `send`, `run`, `print` or `write`, so
  DESIGN section 4 states the rule with this as its exception.

- **November 14, 2026. Restore at launch.** Until November 14, 2026 a
  restored session was attached only when its pane was first shown ("the
  rest lazily when their tab is first shown"). Now every live restored
  session is attached once its location's first listing has answered,
  with the owner's decisions of November 14, 2026: a session without a
  saved size (saved by an older build) is left unattached until shown,
  rather than attached at 80 × 24 or at a size read from the helper's
  log; hosts follow after their first listing; a few at a time, panes on
  screen first (4 local, 2 per host); the memory accepted and measured
  (section 8 has the measurements). Locally a session counts as alive when
  listed or when its socket exists (Housekeeping, below), which closes the
  open item that restore at launch showed a stopped daemon's session as
  Session Ended; `exists()` after a client goes away and Respawn All Ended
  on hosts still use the listing alone. The helper's forced SIGWINCH on
  every attach to a program on the alternate screen was measured then.

- **October 23, 2026. Exit recorder.** Since October 23, 2026 a small
  **exit recorder** sits between the daemon and the program and records how
  it ended in a file next to the session, because the client's exit code is
  always 0 and zmx discards the program's exit status. That zmx 0.8.1's
  `ls` lists sockets only (`ls --short` ignores the file and neither `ls`
  nor `kill` removes it) was verified.
- **Measured: a shell's exit status.** A shell's `exit` without an argument
  and ^D report the last command's status: 130 after ^C at the prompt, 1
  after a failed command (measured with zsh 5.9).
- **October 23, 2026, owner's request. A clean exit closes the last pane.**
  Closing a pane after a clean exit works wherever the pane is, including
  the only pane of a workspace, whose window then closes. (Since October
  23, 2026, owner's request; until then the only pane of the only tab of
  the only tab group of its workspace kept the placeholder, so a window
  never closed by itself.)
- **October 31, 2026, owner's decision. No dimming.** The placeholder used
  to lay black at 18 % over the pane around its card, so an ended pane
  looked grey beside a white empty pane; now the area around the card is
  clear (it still takes the click that focuses the pane), so the pane shows
  its theme background, as an empty pane does, and the session's last
  output stays readable under the card.
- **Seen live: the cursor came back after a theme change.** SwiftTerm
  soft-resets the terminal, cursor visibility included, whenever its font
  is set; seen live: choosing Dracula for an ended pane brought the hollow
  cursor box back, before the surface stopped setting an unchanged font
  (section 8 "Re-applying no longer soft-resets"); a size change, ⌘=, still
  sets it. Hence `PaneView` feeds `ESC [ ? 25 l` again after every
  appearance it applies while the placeholder is up.
- **October 23, 2026, found in review. Keyboard focus under a
  placeholder.** While a placeholder is shown the pane itself
  (`PaneView`), not its terminal, holds keyboard focus: the dead terminal
  used to keep it and swallow Return, so the button's default-action
  shortcut was never consulted and Return did nothing (found in review,
  October 23, 2026).
- **Accepted: remote clean exits close late.** For remote restored
  sessions, a workspace emptied when a host's first listing arrives is
  deleted and its window, if open, closes then (accepted: the listing comes
  within seconds of the launch).
- **Step 5. Respawn uses the profile's current launch.** Respawn creates
  the new session with the profile's current launch since step 5 (the old
  `launch` if the profile was deleted).
- **Step 6. Remote disconnects.** The remote **Disconnected** state
  (Reconnecting…, background retries with exponential backoff, automatic
  re-attach) came with step 6.

### Environment handed to new sessions

- **Step 7, seen live. Claude Code markers.** The markers of a Claude Code
  session Armadale was started from (`CLAUDECODE`, `CLAUDE_PID`,
  `CLAUDE_CODE_CHILD_SESSION`, …, `AI_AGENT`, `TRACEPARENT`) were added to
  the scrubbed variables in step 7: they are the variables Claude Code
  2.1.292 sets for its own children, seen live when Armadale was opened
  from a Claude Code shell: a `claude` in a pane then took itself for that
  session's child, stopped saving its transcript, and got its messaging
  token.
- **Verified: the creating client's environment.** That the daemon
  inherits the cwd and environment of the **creating** client only was
  verified, and so was the trampoline's removal of zmx's variables: `env |
  grep ZMX` in a pane prints nothing.

### Housekeeping
- **November 14, 2026. The SIGTERM line in a session's log.** Five
  sessions staged with the vendored helper (0.8.1) alone, in a scratch
  runtime directory, were ended in different ways and their logs read
  (no app). SIGTERM to the daemon, what `loginwindow`'s force quit sends
  (as do the Dock's "Stop Running in Background", a shutdown and a `kill`
  by hand), logs `[1794717111] [info] (default): SIGTERM received,
  shutting down gracefully session=a-term`, then `kill received`, then
  `shutting down daemon`, also when daemon and shell get it together;
  the helper's own kill logs `kill received` and `shutting down daemon`
  with no SIGTERM line; a program that ends (its shell killed with
  SIGKILL) logs only `shutting down daemon`. (The first account of the
  probe said the SIGTERM line was followed by `shutting down daemon`
  only; the reviewer's staging and a second probe the same day showed
  the `kill received` between them.) The helper's
  listing writes `client connected` / `client disconnected` into every
  live daemon's log, so a log's modification time is not the time of
  death while the daemon lives; a dead one is never written again. The
  recorder writes no exit record once it has passed SIGHUP or SIGTERM
  on, so a session the system ended has none. The line is read with
  only the log's tail (the helper truncates at 2 MB), and
  `LocalZmxBackendTests` sends SIGTERM to a real daemon (the parent of
  the pid the helper's `ls` prints) to pin the wording.
- **November 14, 2026, live checks. A queued kill.** After the pane of a
  stopped daemon was closed (one `sessions` log line), `kill -CONT` made
  the daemon take the kill it had queued and end; the helper then
  answered that the session was not found. So the daemon keeps running
  only while it does not answer.
- **November 14, 2026, third review. Housekeeping keeps counting every
  socket.** When the exit record joined the rule for "gone", the orphan
  reclaim and the log and exit-file collection were left counting every
  socket as alive: erring towards alive costs one more launch of a
  leftover socket and its files, while ending or collecting too early
  could lose a session. The unanswered-kill log line was reworded to say
  what is known whatever the error (the kill failed or was not answered,
  and the socket is still there), with the error's kind but not its text.
- **November 14, 2026, second review. One local rule for "gone", with
  the exit record.** The driver's own checks inside create and attach
  still decided "gone" from the listing alone, so an attach whose client
  gave up could kill a stopped daemon's session and report it missing;
  they now use the same rule as `exists`. The reviewer also inferred that a
  daemon tearing down after its program exited might keep its socket past
  its listing entry, turning a real end into Disconnected. Measured with
  the real helper, 50 rounds each (a shell's `exit 0`, `exit 3`, a program
  killing itself with signal 9, a create of a command that does not
  exist), once on the Mac as it was and once with 12 busy `yes`
  processes (load about 9): all 400 resolved as ended with their record,
  none detached, and in none was the socket left after the listing that
  did not list it, so the race was not seen. The rule was narrowed anyway
  so it cannot depend on it: a session with an exit record has ended
  (the recorder writes it before the daemon ends); no further narrowing
  was needed. A kill a stopped daemon never answers now leaves one log
  line instead of nothing.
- **November 14, 2026, review. `exists` counts a socket.** The review of
  restore at launch found that a stopped daemon's session, attached at
  launch (its client returns at once and shows nothing), was still
  resolved as ended when that client went away (`exists` false,
  `resolveExit` `.ended(nil)`, both measured), so Respawn could start a new
  session beside the old daemon. Since then `LocalZmxBackend.exists` counts
  a session whose socket is left after a listing as alive, which closes
  the local half of the listing gap for `exists()`; hosts have no
  fallback. Tested against the real helper: stopped and client dropped →
  detached; continued → attaches and replays; killed → its socket is left
  until the listing removes it, then gone. Being attached and showing
  nothing until the daemon runs again was accepted (coordinator, November
  14, 2026): it cannot be told apart sooner, and needs no click.
- **November 14, 2026. A stopped daemon, measured again.** With the
  daemon itself stopped (`kill -STOP` of the `zmx attach` daemon, not of
  the program, whose pid is what `zmx ls` prints as `pid=`), `ls --short`
  exited 0 after 1.08 s without it, and plain `ls` printed
  `err=Timeout status=unreachable` for it after 1.01 s; its socket stayed.
  An attach to it returned at once (the client writes `ESC[2J` before its
  Init is answered) and showed nothing; `exists` said false and
  `resolveExit` `.ended(nil)`. After `SIGKILL` of a daemon its socket stayed
  until the next `ls --short`, which removed it. Hence the launch reads
  the runtime directory's sockets after the listing and counts them as
  alive (section 4, "Restore at launch").

- **November 14, 2026. Stopped daemons are not listed.** A stopped daemon
  (`kill -STOP`) is left out of a listing that still succeeds (checked
  November 14, 2026: `ls --short` exited 0 in about 1 s and printed nothing
  for it). This is why `OrphanReclaimer.Plan` also spares sessions whose
  socket exists (`ZmxRuntime.sessionsWithSockets()`), and why
  `ZmxRuntime.aliveForHousekeeping` counts them as alive.
- **Spared sessions not shown yet.** Spared sessions are not shown
  anywhere yet; they keep running until their programs exit.


## 5. Terminal rendering: `TerminalSurface`

**November 24, 2026, live pass. Blank cells.** A first frame of `top`
was 2931 characters: runs of blank cells were already stepped over with
one cursor move each, but `top`'s columns are mostly one blank apart, so
every such gap cost `ESC [ 1 C` (four bytes for one). A gap of at most
three cells in the default pen is written as spaces now. Spaces with a
background or reverse video (status and selection bars) were never
stepped over: `ScreenReading.isPlain` excludes any colour and style, so
they were written as cells with their attributes; no defect there, and a
round-trip test now holds it.

**November 24, 2026, review. The snapshot completed.** The reviewer
found that a cursor waiting to wrap (past the last column after a
character written there, as agent interfaces leave it after a row drawn
to the full width) was put on the last column, so the program's next
character landed there in a player instead of on the next row. The
remedy, through public API: when the cursor's x equals the column count,
the last column's character is written again with wraparound on.
DECSCNM (mode 5) was added to the queries, and the saved cursor (DECSC:
`buffer.savedX`, `savedY`, `savedAttr`, public) to what is captured; the
active character set is private (`Terminal.charset`) and stays out, as do
the origin mode, wraparound and character set DECSC saved. The text-only
fallback for a terminal that does not answer was removed: it could not be
reached (without SwiftTerm's render session the queries are dropped too).

**November 24, 2026. `screenSnapshot()`.** Added for recording a pane
(section 7): a recording started in the middle of a session must not
start from a blank screen, because programs that redraw by moving the
cursor relative to what is on screen (Claude Code, Codex, any full-screen
program) would play back garbled. The coordinator's floor was text, cursor
position and the alternate screen, with colours, attributes and the modes
wanted where SwiftTerm 1.99.0's public API exposes them. Found in the
pinned checkout: `TerminalView` keeps its `Terminal` internal
(`MacTerminalView.swift`, `var terminal: Terminal!`), and its public
state snapshot (`terminalStateSnapshot()`, `TerminalViewStateSnapshot`)
has the rows' text, cell widths, cursor and cursor style but no
attributes. `Terminal` itself has a public reading API (`getLine`,
`CharData.attribute` with `fg`, `bg`, `style`, `underlineStyle`,
`underlineColor`, `buffer.scrollTop`/`scrollBottom`,
`isCurrentBufferAlternate`, `currentAttribute`), but keeps
`cursorHidden`, `originMode` and `wraparound` internal (`Terminal.swift`,
about lines 655–665) and `curAttr` private. Tracking cursor visibility
through the view's `open` `showCursor(source:)`/`hideCursor(source:)` was
rejected: a soft reset and `setup` set `cursorHidden` without calling them
(about lines 1352 and 5746). The terminal hands itself to its view's
`open` `send(source:data:)` whenever it answers a query, and DECRQM
(`CSI ? n $ p`) answers for modes 25, 6 and 7 (about line 5520); so the
surface's view is a `TerminalView` subclass that, for one call, feeds
those three queries, keeps the answers from the program and reads the
screen with the terminal it is handed. Output is parsed synchronously on
the feeding thread (`feedSender.configure`, `AppleTerminalView.swift`
about line 1417), so the answers arrive inside the call. The first tests
checked that no answer reached the program right after the call, which
could not have caught a late one; in review (the same day) they were made
to wait for a later turn of the main queue, and the reviewer confirmed
from the code that the terminal answers synchronously and that the one
asynchronous hop is in the base `send` the override skips. DECRQSS for the pen was rejected: its `m` answer is
`Attribute.toSgr()`, which leaves out dim, italic, crossed out and the
underline style, and writes a basic colour as `3n;` with a trailing
separator, which reads back as a reset (`CharData.swift` about line 135);
`currentAttribute` is public and exact. Getting at the live screen when
the user has scrolled back: `getLine` reads from `yDisp` and `yBase` is
internal, so the view is scrolled to the bottom first. The round trips
(`ScreenSnapshotTests`) passed at the first run, colours, attributes,
underline styles and colours, wide characters, emoji with a variation
selector, a flag and a combining mark included.

**November 14, 2026. `setGridSize(columns:rows:)` and the lazy surface.**
Added so a session can be attached at its saved size before its pane
view exists: the surface's grid is set while its view is in no window.
SwiftTerm 1.99.0's view-level `resize(cols:rows:)` was rejected (it ends
in a soft reset and leaves the frame alone, so the next layout would size
the grid back); `processSizeChange` (`AppleTerminalView.swift`, about line
1835) reports `sizeChanged` only when columns or rows differ, so a frame
holding exactly the grid keeps it. The cell is measured when the font is
set (`computeFontDimensions`, snapped to the backing scale of the window
or else the main screen) and is not recomputed when the view moves into
a window, so the grid survives entering one. SwiftTerm keeps at least 2
columns. The controller's surface became lazy at the same time: an ended
session in a tab nobody opens no longer costs a terminal.

**Implementation (step 5). Renderer registry and selection.** Step 5
built `SurfaceRegistry` (in `TerminalSurface`), with `SurfaceFactory`s
keyed by a persisted identifier (`swiftterm` the only one and the
default), `SurfaceRegistry.standard` in the app, new surfaces made
through the factory named by the `rendererID` preference, and
`SessionController.replaceSurfaceOnNextAttach(_:)` for existing panes.
In the same step `TerminalTheme` gained an optional
`selectionForeground` (from Ghostty themes), which SwiftTerm cannot use.

## 6. Remote hosts

**November 14, 2026, second review. Hidden sign-ins, three corrections.**
A pane shown while its hidden session's retry was asking the host lost
its retries to the "needs the user" answer; the answer is now judged when
it arrives. A session stopped that way stayed Disconnected when its pane
was shown, although the text said showing it may prompt; it now
reconnects once by itself when first shown. The host pass cleared the
mark before a retry that the cap could drop; the mark now lasts until the
session connects, is closed or is respawned. Relisting no longer follows
ends the app causes (closing a pane, End Sessions and Quit).

**November 14, 2026, review. A cap per host; no hidden sign-in.** Every
client of a host shares one ssh connection and sshd allows 10 sessions per
connection by default (`MaxSessions`); by reading, past it control
commands on that connection are refused too, and a refused kill is
swallowed, so a closed pane's session would keep running. The launch pass
could reach that by itself, so it keeps at most 6 of a host's sessions
attached for panes nobody showed (coordinator's decision, November 14,
2026; the owner may change it once it is checked on a host, which this
Mac cannot do). Also from the review: a never-shown session's automatic
retry could meet a host that came back needing a password and start an
interactive sign-in in a pane nobody sees, one per such session; its
retries now ask the host in batch mode first and stop when it needs the
user. A pane shown in this run retries as before (step 6). A host whose
listing needed the user is listed again when a signed-in session ends
because it is gone, not only when one attaches. A host edit relists the
host whenever it had been listed (the comment that said "when restored
sessions are still waiting" was made to match the code).

**November 14, 2026. Listings keep why they failed; hosts after their
first listing.** Owner's decision: hidden sessions on a host are attached
once its first listing has answered. The listing now keeps why it failed
(`HostListing`): unreachable gets the attach attempt (Disconnected,
retried, never ended); one that needs the user starts nothing for panes
not on screen, so no hidden pane sits at a password prompt, and is listed
again once one of its sessions connects. sshd's default of 10 sessions
per connection (`MaxSessions`) is reached at launch by a host with ten or
more restored sessions with saved sizes; this could not be checked on
this Mac (no Lima, no test host). Editing a host's settings now lists it
again; before, a host edit dropped the listing and nothing asked again
until a pane was shown.

**Implementation (step 6). Remote backend.** Step 6 built
`SSHTransport`, `RemoteDeployer` and `RemoteZmxBackend` in
`ArmadaleSessions`, and moved the zmx session protocol of section 4 into
one `ZmxSessionDriver`, parameterised by a `ZmxEndpoint`, which
`LocalZmxBackend` and `RemoteZmxBackend` both use.

**Deviation. ControlPath.** The original design had
`<App Support>/ssh/%C`, which overflows `sun_path`; the socket is
therefore named by a 16-hex-character token in the runtime directory
instead.

**Multiplexing measured.** Measured against a Lima VM: 190 ms for
the first control command, 6 ms after, once the first one has left a
master behind.

**Deployment: why the upload is checked before the rename.** Before the
temporary file was checked (size, and SHA-256 where the host has a hash
tool), a dropped link or the 180 s upload limit gave the remote `cat` an
early EOF and it succeeded: a 3 MB prefix could be installed, pass
`test -x` and even print its version.

**October 23, 2026. Exit recorder for remote sessions.** The remote
session script stopped `exec`ing the shell in a zmx session and began
recording its exit status in `<dir>/run/a-<id>.exit`. Verified with the
loopback host (macOS `/bin/sh`, bash in POSIX mode) and on the Lima VM,
whose `/bin/sh` is dash (October 23, 2026: `exit 3` records 3,
`true; exit` 0, `false` then ^D 1, `kill -9 $$` 137, `cat` interrupted
by ^C 130, `zmx kill` nothing; `SSHIntegrationTests` checks the first
two).

**Attach detection verified.** It was verified that zmx writes
exactly `ESC[2J ESC[H` at the start of an attach, after
`session "…" created\r\n` for a new session, which is what the remote
classification looks for at the start of the stream or of a line.

**More than ten sessions on one connection, seen live (November 14,
2026).** Against OpenSSH on Ubuntu 26.10 with `MaxSessions 10`: ten
clients went through the shared connection, and the eleventh and
twelfth each got a TCP connection of their own, because ssh opens a
new connection when the master refuses a session. A close's kill
reached the host with the shared connection full. Key authentication
only (Part 1, "hosts, checked live"). Before this, section 4 said
from reading that control commands past ten would be refused.

## 7. Process plumbing (`ArmadaleSessions`)

**November 24, 2026, live pass. Recording during a reattach.** Seen in
the reviewer's live pass on f717917: while a loop flooded a pane with
coloured lines the session reattached again and again (the flood
reattach), `canStartRecording` wanted the attached state, so Record
Pane… was disabled in about one of three opens, and a confirm that
landed during a reattach said "There is nothing to record: the session
is not running in this pane" of a running session. Decided by the
coordinator: a recording may start while a session attached in this run
is being attached again; it waits and starts at the reset that attach
feeds (the order the reviewer had seen in round 2 for a recording
already pending when a reattach came: the snapshot, then the replay).
The menu item follows the same rule; the refusals left say what is
true (the session has ended; it is not connected right now; it is still
starting). Tested with a fake backend and through the real persistence
helper (a client killed, Record asked for while the controller was seen
attaching again: the file holds the replay and not the reset).

**November 24, 2026, second review. A differential test and a
SwiftTerm quirk.** The reviewer ran a differential test against SwiftTerm
(54 kinds of token, alone and in seeded mixes, random batches of 1 to 17
bytes, a recording asked for at every byte offset and handled as the
controller does, the screen and the titles compared with a control fed
the same batches with no snapshot): of 3388 offsets 3381 were equal. The
other 7 are SwiftTerm's: after a RIS inside one parse call it does not
save its parser state at the end of that call (`EscapeSequenceParser.swift`,
`reset` about lines 824–830 and the early return about lines 1434–1439),
so a sequence left open at the end of the same batch is dropped
(`"ok\ec\e"` then `"[31mC"` prints `[31mC`). With a recording pending
across a RIS split over two reads, the cut feeds the RIS on its own and
the following sequence survives: the pane with a recording differs from
the pane without one, in the right direction. The tracker was left as it
is (copying a bug would make the recording's pane wrong too); the test is
in the tree (`RecordingDifferentialTests`), names the case and expects
it, and is the guard for the next SwiftTerm bump. Fixed the same round:
a new recording could reopen, emptying it, a file whose earlier writer was
still finishing, so any writer not yet closed now holds its file; a
problem alert taken down by its window closing was lost, so it goes back
to the head of the queue; the licence files say the parser's table is
adapted, not only linked.

**November 24, 2026, review. Starting inside a sequence; the writer's
bounds.** The reviewer found that Record confirmed while the program's
output had stopped inside a sequence (a read ending in `ESC [ 3 8 ; 5 ; 1
9`, the next starting `6 m R E D`) made the snapshot's DECRQM queries cut
that sequence short in the live pane and made the recording begin with
its tail: an SGR split showed `6mRED` as text, an OSC title split set the
title to "my ti" and printed `tle`, a CUP split printed `0;5Hx`, and a
4-byte character split was lost in the pane and played back as two
U+FFFD. Measured by the reviewer on a pty (reads of at most 1024 bytes):
28 % to 57 % of the batch boundaries of colourful output fall inside a
sequence or a character, so this is about every second Record on a
streaming agent. Decided by the coordinator: a pure tracker of where the
stream stands, fed every byte the surface is fed, and a recording that
waits for the first point between sequences. To agree with SwiftTerm on
where a sequence ends, `TerminalStreamTracker` copies SwiftTerm 1.99.0's
`EscapeSequenceParser.swift`: the transition table
(`buildVt500TransitionTable`, about lines 326–457, built by the same
additions in the same order, so CAN does not end a CSI or an escape
there: their C0 executables were added after the "anywhere" rules), the
0xA0 column for bytes above it and the `.error` action's handling of
them (about lines 1222–1240: the CSI-ignore, DCS-ignore and
DCS-passthrough states keep their state), the ground state's fast path
that prints every byte from 0x20 on (about line 1175), the OSC and APC
runs (`oscPut`, about lines 1352–1383, `consumeOscRun`, about lines
1022–1062: inside a run a 0x9C ends an OSC unless
`oscExpectsUTF8Continuation`, about lines 891–904, says it continues a
character; the first byte of a run, at a batch's start too, goes through
the table), the ESC that ends a string or a DCS passthrough starting an
escape (`oscEnd`, about lines 1384–1418; `dcsUnhook`), and OSC 7501's
`programStatusEscape` (`isProgramStatusOsc`, about line 521;
`finishProgramStatusSt`, about line 1066). Not copied: the 1 MB OSC and
65 MB APC limits. Measured: about 2.2 µs per kilobyte of colourful output
in an optimized build after a fast path for runs of text, string payload
and CSI parameters (3.4 µs without the CSI one), 31 µs in a Debug build;
the reviewer had measured about 1 µs for a tracker of the same kind. The
reviewer's five splits are end-to-end tests now.
The other findings of that review, each fixed the same day: a quit could
wait without bound on a writer (1 MB to a pipe nobody reads never
returned), so the quit now waits at most one second in all and the
writer ends a recording that falls 32 MB behind; a quit could leave a
file unfinished after a stop, a closed pane, an ended session or End
Sessions and Quit, because those finish asynchronously, so the registry
keeps the writers until they are closed and every quit waits for them
within the same second; a host's removal now ends the recording; the
`TimelineView` pulse used 3.57 s of CPU in 3 s in the reviewer's test
window, so it is a Core Animation animation now; decoding and escaping
cost the main actor 0.88 ms per 64 KB of plain output and 3.4 ms of
colourful output, so they moved to the writer's queue; U+2028 and U+2029
were written raw and termcast's player (`TermcastPlayer.swift` line 9,
`CharacterSet.newlines`) stopped on them, so they are escaped; a failed
write left half a line (a 1337-byte partial line on a full 4 MB volume),
so a failed or short write is truncated back to the last whole line.

**November 24, 2026. Recording a pane; termcast not used.** The owner
asked for a way to record a pane from its context menu, believing that
SwiftTerm supports recording through termcast. In SwiftTerm 1.99.0 (the
pinned version; the checkout under
`~/Library/Developer/Xcode/DerivedData/Armadale-*/SourcePackages/checkouts/SwiftTerm`)
termcast is only an executable target, `Sources/Termcast`
(`AsciicastFormat.swift`, `TermcastRecorder.swift`, `TermcastPlayer.swift`,
`main.swift`), shipped as the `termcast` executable product
(`Package.swift`, `.executable(name: "termcast", targets: ["Termcast"])`).
Its types (`AsciicastHeader`, `AsciicastEvent`, `TermcastRecorder`) are
internal to that tool and are not in the `SwiftTerm` library product
Armadale links. The recorder starts its own shell with `LocalProcess` and
forwards the tool's own stdin to it (`TermcastRecorder.swift`, about lines
92 and 281–340), so it cannot record a terminal that already exists, and
Armadale owns the PTY anyway (section 5). It also records keystrokes as
`"i"` events (`TermcastInputHandler.forward`, about lines 30–46), times
its events with the wall clock (`Date().timeIntervalSince1970`), and
drops a whole chunk of output when a multi-byte UTF-8 character is split
across two reads (`String(bytes: slice, encoding: .utf8) ?? ""`, about
line 394). So
Armadale writes the same file format itself, asciicast v2, the `.cast`
format that `termcast playback` and `asciinema play` read: no new
dependency, and nothing from termcast is copied. Decided with the
coordinator: output only, never an `"i"` event (a typed password does not
echo and must not land in a file); UTF-8 decoded across batches with
U+FFFD for invalid bytes; exactly what the surface is fed, through the
controller's four `surface.feed` sites made one (`feedSurface`), so a
reset and a reattach's replay are in the recording as the pane showed
them; the first event a snapshot of the screen (section 5); writes off the
main actor, in order, with no backlog bound (the pump only hands over what
the surface has already rendered); and the quit flushing and closing the
file synchronously, beside the clients' synchronous hang-up, because a
quit never waits (section 8, "App lifecycle"). An end-to-end test plays
the file of a scripted session recorded from its middle on a fresh
SwiftTerm surface and compares the screen with the pane's, cell by cell.

**November 14, 2026. No pixel-only resizes.** Measured with the real
helper (a shell that traps WINCH and logs `stty size`, attached through
`LocalZmxBackend`): an attach at exactly the window size the program has,
pixels included, sends it no SIGWINCH; an attach or a resize that changes
only the pixel size sends one; a resize to the identical size sends none.
So the controller sends a size only when the grid changes, and reports
every size it gives (`didApplySize`) for the session's last grid size.
Until then the controller re-sent the surface's size after every connect,
which a backing scale that changed while connecting turned into a
pixel-only SIGWINCH.

**Controlling terminal bug verified.** That `posix_spawn` with `SETSID`
and an open of the slave does not give the child a controlling terminal
on macOS 27 was verified with `ps` TPGID and by `^C` not interrupting
`sleep`; hence the `ctty-exec` trampoline.

**October 23, 2026. Exit recorder (`ctty-exec --exit-file <path>`).**
Added for local sessions (section 4, Ended). Job control under it was
verified on real PTYs (`ExitRecorderTests`, and through zmx in
`LocalZmxBackendTests`); that SIGHUP is what `zmx kill` sends was
measured with a trapping script.

**Output throughput measured.** About 2,200 batches a second were
measured under a flood (`yes`, a million-line `seq`) with a free
consumer. A hard limit of one batch per 16 ms was rejected: it would cap
output at about 4 MB/s.

**zmx floods: the rate heuristic and the 16 MB limit.** An earlier
version reattached on sustained output above 320 KB/s; it misfired on a
30 fps full-screen redraw (~390 KB/s, rendered fine), resetting the pane
every ~3 s, and was replaced by the footprint measurement. Measured with
zmx 0.8.1: an idle client, and one carrying ~410 KB/s for 5 s that the
pane keeps up with, stays at about 1.4 MB (0 reattaches); one second of
`yes` against a pane limited to ~6 MB/s takes the client to about 35 MB.
The suggested 32 MB limit was therefore too close to that peak to
trigger reliably; 16 MB is about eleven times an idle client. Without the
mitigation the prompt appeared 78 s after ^C; with it, 0.75 s, after one
reattach (in the app the reviewer saw 100% CPU for 260 s and a 115 MB
client before). The ephemeral backend was left unchanged.

**Dropped `PTYProcess` hangup observed.** Before a dropped `PTYProcess`
sent SIGHUP itself, a `sleep` was observed to outlive its closed PTY: the
kernel's hangup on master close had not reached it, because it had not
yet acquired the terminal.

**Origin of `PTYProcess`.** `PTYProcess` is a port of the spike harness
(`PTYSpawn.swift`, `ctty-exec.swift`).

**Step 6. `CommandRunner` stdin.** Since step 6 `CommandRunner` can feed
stdin from a pipe (uploads), with `F_SETNOSIGPIPE`.

**Step 7. Attention.** Since step 7 the session registry passes bells and
notifications from `SessionController` to the app's `AttentionCenter`.


## 8. Windows and views

**November 24, 2026, live pass. The dot at rest.** Seen in the
reviewer's live pass: the pulse ran after a title change, a tab switch
and back, minimize and restore, but right after the app was unhidden
without being activated three window screenshots 0.4 s apart showed no
strong red at the dot, and it pulsed again once the app was activated:
the animation was gone after the unhide and the layer showed the dim
end. Decided by the coordinator: the layer's own opacity is full, the
animation runs from full down and back, and it is added afresh when the
dot can be seen again (back in a window, its window's occlusion
changing, the app unhidden). Unit-tested by removing the animation and
posting each notification by hand; with Reduce Motion (a replaceable
check in the test) the dot stays steady and full. *Corrected the same
evening:* the observation was wrong. The reviewer had measured a fixed
box of pixels, and a screenshot of an inactive window has a smaller
shadow (2292×1492 against 2424×1624), so the dot was elsewhere in the
image; measured at the right place, a dot in a window that is visible
but not key pulsed in every series of shots, before any activation. The
change stays: a dot that rests at full red is the safer failure, and it
costs nothing.

**November 24, 2026, review. Recording a pane, the window's part.** Fixed
after the review: a write failure is always told, one at a time and in
order, on the pane's window or, with that closed, on the next workspace
window that opens or becomes key (before, it was only logged then, and a
second one while the alert was up was dropped), and the reason reads as
a sentence of its own; the header gives way in a fixed order as it
narrows (directory, title, dot, glyph; the stop button stays with "…"
until only "…" fits), because at 80 pt the stop button overlapped "…" and
at 60 pt only red was drawn; the save panel and the alert go up through a
seam the tests replace, because the save-panel tests had put two windows
on screen for about a second each (the reviewer found existing tests
showing about 25 windows the same way; that is an open item in
HANDOFF); two recordings into one file are refused; the suggested name is
cut by bytes, since 100 characters of emoji could pass the 255-byte
limit; the pulse is a Core Animation animation (above, section 7).

**November 24, 2026. A tab's accessibility action.** `TabItemView` was
an accessibility element with its children combined and the button
trait, and no action of its own, so a press on it (what VoiceOver's
activation sends) reported success and selected nothing; the reviewer
of recording a pane met it when its accessibility presses on tab bar
tabs did nothing while the same press on a sidebar row selected. The
sidebar's rows had both actions since the List lost its selection
(`SidebarRowActions`); the tab bar now does the same: a default action
that selects, a Rename action, and separate children while the rename
field is up, without which the field that Rename brings up could not be
reached. Close Tab stays with the context menu and the close button.
Checked live by accessibility presses on a test build (Part 1).

**November 24, 2026, live pass. The suggested name.** For a zsh titled
with its directory, /tmp/armrec/w, the save sheet offered "-tmp-armrec-w
2026-11-24 at 17.02.57.cast": every `/` had become `-`, the first one
too, and a title under the home directory would have started `~-`. A
name that starts with a dash is taken for an option on a command line,
and a shell expands `~-`. Leading dashes and tildes are now dropped with
the leading dots, and trailing dashes with the trailing spaces
(`RecordingFileName.cleaned`); a title that is only `~` gives "Pane".

**November 24, 2026. Recording a pane (owner's and coordinator's
decisions).** The owner asked for "a CTA to record the pane in the
context menu", "a pulsing red to indicate that recording is in progress",
and "a stop button". Decided by the owner the same day: the pane menu's
item opens a save sheet each time and the recording starts when it is
confirmed (no default folder, no preference); the recording pane's header
shows a pulsing red dot and a stop button; a tab shows a small red dot, in
the tab bar and in the sidebar's tab row, while any of its panes records
(a pane keeps recording while its tab is in the background). Decided by
the coordinator: the words Record Pane…, Stop Recording and Recording; the
item beside Save as Favorite…, without a shortcut and not in the
application's Pane menu; the save sheet taken down before a quit like the
other sheets (AppKit's `terminate:` does nothing while a sheet is
attached, section 8, "App lifecycle") and when its pane leaves the
window; the header's controls in the system red with Reduce Motion
honoured; the tab's dot not a status. The rule for the item's state,
written down then: Record Pane… is enabled only while the session is
attached, a client feeding the surface; there is no live terminal to
record in any other state, so it is shown disabled there. The pulse was
first drawn from the time alone (`TimelineView`) rather than a repeating
animation started on appear, because the header's root view is replaced
on every title or directory change, which can restart or stop an
animation held in view state; the review replaced it with a Core
Animation animation on an AppKit view the header keeps (its cost, above). No type is declared in Info.plist for
`.cast`: a dynamic type made from the extension is what the save panel is
given (the live check of the panel keeping the extension was not made;
see Part 1). `scripts/check-quit.sh` was not given a save-sheet scenario:
its scenarios need no input, and opening the sheet does (the pane menu).
The quit with the sheet up is unit-tested through
`AppDelegate.endSheetsForQuit`, first with a real `NSSavePanel`, since the
review through the presentation seam.

**November 14, 2026, live checks. Floods in sessions not on screen.** The
reviewer saw a Debug build at about 100 % CPU for minutes with 20 attached
sessions, five in tabs never shown each running `yes | head -c 50000000`,
accessibility round trips of 3 to 4 s and a SIGTERM quit of about 5 s.
Measured the same day (isolated state, Debug build from DerivedData and
the same configuration built with `SWIFT_OPTIMIZATION_LEVEL=-O` and whole
module optimization into its own DerivedData; CPU from `ps` time deltas
every 2 s; accessibility round trip: one `get name of window 1`):

| Build, tabs | CPU while producing | Output ended | Idle after the end | Round trip under load | Flood reattaches | Quit under load |
|---|---|---|---|---|---|---|
| Debug, never shown | about 100 % | about 120 s | about 137 s | about 9 s | 20 (clients reach the limit about every 25 s) | 94 ms |
| Debug, visited once | about 100 % | about 130 s | about 252 s | about 9 s | 20 | 641 ms |
| Optimized, never shown | about 90 % | about 118 s | 2 s | about 0.2 s | none | 52 ms |
| Optimized, visited once | about 90 % | about 120 s | 2 s | about 0.2 s | none | 65 ms |

So it is not new: a tab visited once and left (what a hidden attached
session was before restore at launch) costs the same; the step widened who
pays it to sessions never shown. The minutes after the output in the Debug
build are the backlog the clients hold below the flood limit (16 MB each,
by footprint): the flood handling does trigger (each client was dropped
about every 25 s while the output lasted), and what is under the limit
when the output ends is parsed in full, at the Debug build's speed. The
optimized build keeps up, so its clients never reach the limit. No defect
was found in the flood watch or the output pump; the quit was not seen
waiting on the feed (0.05 to 0.65 s). The reviewer's 5 s quit was not
reproduced, and it was taken at another moment: about four minutes
after the floods had ended, with the Debug build still parsing its
backlog (one feed call held the main thread for seconds at a time in a
`sample`), timed by polling once a second. A quit waits for the feed in
progress to return, so that figure is an upper bound for the Debug
build under that backlog. Accepted as it is (the coordinator's
decision, the owner's to overrule): a release build is optimized.
Options not built, should a release build ever show it: a lower flood
limit for sessions not on screen (more of their output skipped into the
replay); feeding them at a capped rate (attention arrives late, and it
ends in more reattaches); a light scanner for BEL, OSC 9 / 777 and the
title in place of a full terminal for sessions not on screen, the
surface rebuilt by a replay when shown; parsing off the main actor
(SwiftTerm is not thread-safe).

**November 14, 2026, live checks. `check-quit.sh` with suites.** Each of
the script's launches now uses a defaults suite of its own, removed at the
end. Run against the Debug build: chooser 67 ms, normal 64 ms, alert 136 ms;
and again after its cleanup was changed to literal paths in `rm`
(AGENTS.md): 57, 62 and 54 ms, nothing left behind, no real defaults
domain created.

**November 14, 2026, review of restore at launch.** Fixed after an
adversarial review (no blocker found): `setGridSize` reached terminals
that sat in a pane view not on screen (Respawn All Ended after tabs were
visited; Retry for panes shown earlier), and AppKit lays a pane's
subviews out only when its size changes, so the terminal stayed at the
wrong size in its card. Now a terminal in a pane view gets its grid only
from that pane's layout, and the pane puts it back when it is laid out or
enters a window. A pane shown several times while its start waited for
the listing counted several starts, so the in-flight limit and the one
retry could be lost; one start per session now. The launch pass waits for
the app to open its windows (`startLaunchPass()`), since the listing can
answer first. A pane view made after a renderer change now knows the
renderer of the surface it shows and of the pending one, and a
replacement surface for a session without a pane view takes the old
grid (it started at 640 × 400, which would resize the program).
`sessionsRunning(after:)` became `sessionsStillRunning()`: its parameter
no longer did anything. Each fix has a test that failed with the fix
reverted (checked by reverting each in turn).

**November 14, 2026. The registry owns the controllers; restore at
launch.** Built at the owner's go-ahead of November 14, 2026, from the
architecture review's two passes: `SessionRegistry` kept each controller
inside a pane view, so nothing could be attached before it was shown, and
`status(of:)`, `isEnded`, `riskItem`, `close`, `endAllSessions`,
`sessionsRunning(after:)`, `respawn` and the remote clean-exit pass each
had a second path for sessions never shown. Now one controller per
session exists from the start and those paths go through it; the safety
rules they held are kept (an unavailable session is never killed, a
removed host's sessions are left alone, a restored session that may be
alive is killed when its pane is closed, End Sessions and Quit leaves the
unreachable ones). The registry (868 lines) was split along its seams in
the same change; `AppDelegate` was left for a later, purely mechanical
change.

**Measurements behind restore at launch (November 14, 2026), in a test
harness, not in the app** (real persistence helper, real SwiftTerm
surfaces, sessions attached through the registry, no window on screen):
- *Pacing.* 24 sessions with 2,000 lines of output each, on this Mac as
  it was (load about 1.7): 4 in flight settled all 24 in 0.94–1.00 s, all
  at once in 0.39 s, with no attach missing the 2 s window either way
  (two runs each). With every one of the 10 cores busy (`yes`): 1.53 s
  against 0.53 s, still no miss. The owner chose a few at a time; the
  numbers gave no reason to change 4 and 2, and none to go higher either,
  since the risk the pacing guards against (misses on a busy Mac) did not
  show here at all.
- *Memory* (owner's decision: accept it and measure a fleet of about 20):
  20 sessions with 5,000 lines of output each, attached: the test process
  grew by 25.7 MB, about 1.3 MB per session (controller and SwiftTerm
  surface, whose scrollback is SwiftTerm's default of 500 lines; zmx keeps
  up to 10,000), and each client process was 2.4 MB (48 MB for 20). The
  daemons, about 8.7 MB each (175 MB for 20), ran before anyway. To be
  measured in the app when the Mac is free.
- *The extra SIGWINCH after relaunch* (HANDOFF's open item). Through a
  controller and a real SwiftTerm surface, a program that traps WINCH got
  one SIGWINCH at every attach at an unchanged size, and the sizes the
  controller gave were identical each time (no resize at all). Through
  the backend alone the same attach gave none, unless the program had
  switched to the alternate screen: zmx 0.8.1 sends a program on the
  alternate screen one SIGWINCH at every attach (including create's
  second attach), a forced redraw. So "full-screen programs redraw once"
  is the helper's, not Armadale's, and no change here can remove it. At a
  prompt the program gets none from an attach at its own size; the one
  path in Armadale found to send it one there was the controller's
  re-send of the size after a connect when only the pixel size differed,
  now gone. A headless relaunch of a visible pane (a window controller,
  not ordered on screen) attached once at the laid-out grid and sent no
  resize afterwards, with or without a saved size. Not reproduced live.

**Implementation (step 4): the split tree diff.** The diff of `PaneLayout`
against the view tree, `SplitTreeReconciler` (section 2), was built in
step 4. Each `PaneSplitView` lays its two panes out from the model's ratio
in one pass; letting `super` resize proportionally first gave nested panes
two sizes per layout pass, and their programs two SIGWINCHes.

**October 23, 2026: dimming of unfocused panes dropped.** Unfocused panes
keep their terminal's own background: the dimming overlay of steps 2 to 9
was dropped on October 23, 2026 at the owner's request. The hairline on
every other card came with the pane cards (below).

**October 30, 2026: tab width.** Tabs share the track's whole width
equally (at least 110 pt) from October 30, 2026.

**Tab bar look (owner's decision, October 30, 2026).** The bar is drawn
like the native macOS 27 window tab bar and takes its height: 36 pt (a
native window grows by 36 pt when it shows its tab bar; ours was 32). The
content of a tab, its alignment and every behaviour of the tab bar were
as before; what changed is the look, the place of the "+" (now at the
bar's right end, where native puts it, also when there are no tabs) and
the width sharing. Measured from screenshots of the native bar (Terminal
in light; an AppKit window with native tabs forced to each appearance for
dark and for the inactive look). A tab needing attention kept the purple
pill (fill and border, as before). Colour strengths were tuned until the
pixels on screen matched the native screenshots (track, track border,
divider and "+" within a few levels of 8-bit grey in both appearances).
The Increase Contrast strengths (`TabBarStyle.tint`, tested) were not
seen live.

**Tabs fill the track (the owner's second round, October 30, 2026).** As
native, the track's inside is shared equally; the 220 pt maximum is gone.

**Scrolling the track (second and third rounds, October 30, 2026).** The
offset clamp was added because the scroll view does not always clamp by
itself: before, a window narrowed and widened again kept about 30 pt past
the start with no way back. Keeping the selected tab in view on a resize
(`TrackScroll.resizedOffset`, tested) came in the fourth round, the same
day. The scroll view was seen to drop a target asked for just after an
animated scroll began and come to rest at the earlier one, which is why
an animation coming to rest away from the pending target asks for it once
more. Known and not fixed (older than this change): dragging a tab does
not scroll the track.

**Middle click (second round, October 30, 2026).** A tab scrolled out of
view, whose stored frame lay under the "+" or the bar's ends, could be
closed by a middle click there until `TabFrameStore` also recorded the
track's visible frame and resolved only points inside it.

**October 29, 2026: the sidebar's List.** The sidebar's List has had no
selection since October 29, 2026 (relevant to the double click being a
simultaneous gesture on `SidebarRowActions`).

**Attention (step 7).** `AttentionCenter`, the tab bar tint and ◐, the
sidebar count capsules and the Dock badge were built in step 7. The tab
row's title weight in the sidebar has been the shown path's (section 1)
since October 30, 2026.

### Pane context menu

**November 24, 2026: Record Pane… / Stop Recording.** Added beside Save as
Favorite…, for a pane that has a session; one separator now follows the
two. See "Recording a pane" at the top of this section.

**Pane context menu (owner's decisions, October 30, 2026).** The context
menu, its pure builder `PaneMenu.make(_:actions:)` and the per-pane theme
were decided and built on October 30, 2026. A pane's theme is one
explicit theme shown in light and dark alike, not a light/dark pair, by
the owner's decision. `Pane.themeID` is saved only when set; it was added
in schema 1 without a bump, and older files load unchanged.

**October 31, 2026: Split Right and Split Down.** Split Right and Split
Down were added to the menu on October 31, 2026, at the owner's request;
they are the header's way to split (see "Pane cards"). That ⌘D with the
menu open splits once was seen in review.

**The menu's entry point, until the pane header.** Until the pane card's
header (October 31, 2026) no mouse event opened the menu. The first
version (ebec034) opened it on a right-click when the program had not
asked for the mouse, on Shift + right-click always, and treated
Control-click as a right-click, which meant a program that asked for the
mouse never saw Control + left-click (Emacs's buffer menu) and could not
see Shift with a right button. The owner decided the same evening that
programs such as vim and Emacs must get every mouse event exactly as the
renderer reports it, and that the menu's entry point was to be chosen
later (a UI entry point, not a mouse rule; it became the pane header the
next day). So the subclass that applied those rules (`HostTerminalView`)
and the rules themselves (`ContextClick`) were removed in the following
commit; `SwiftTermSurface` uses SwiftTerm's `TerminalView` unchanged (a
right-click goes to a program that asked for the mouse, as before). The
builder, the per-pane theme and their tests stayed, so the Theme submenu
was one entry point away. The rule then written down: when an entry
point is added, the menu should focus the pane first, as a click would,
and neither take keyboard focus nor change the focused pane (the first
version did, seen live). The header does exactly that; after a choice,
typing goes on in the pane (seen live).

**November 16, 2026: Save as Favorite….** Added to the menu of a pane
that has a session, after Split Right and Split Down between separators
(the coordinator's placement), by the owner's decision that favorites
are made where sessions are; it opens the dialog as New Favorite filled
in from the session (section 8, "New sessions").

**The pane's appearance for its theme.** A pane with its own theme sets
its view `appearance` to suit the theme's background so the placeholder
card and the New Session chooser stay legible (seen live: an empty pane
on Armadale Light in dark mode showed a dark card with faded text before
this). The lighter context menu of a light-themed pane in dark mode was
accepted as cosmetic in the first version.

### Pane cards

**November 24, 2026: the recording controls.** A recording pane's header
shows a pulsing red dot and a stop button between the text and "…"; the
text space rule counts their 34 pt and the spacing after them, so the
title and directory truncate first. A test draws a 160 pt header (since
the review at 140, 100, 80, 60 and 40 pt, with the give-way rule) and
checks that red is drawn only where the controls are and no text there
(the accessibility tree of a SwiftUI header is empty in an unhosted test,
so the picture is read instead).

**Pane cards (design agreed with the owner on October 31, 2026;
implemented the same day).** The owner noted that recent terminal and
agent front ends (superlogical, Tern, herdr) draw each pane as a rounded
card with a margin around it and a header on top, and asked for a design.
Armadale adopted it because it makes splits legible without a divider
line, makes two differently themed panes look chosen rather than broken,
and gives the pane context menu the entry point it lacked. A zoomed pane
and a tab with one pane show one card with the same gutter and header
(consistency with every other tab; owner's decision). The empty tab group
state was unchanged by the cards. The focused card's 1.5 pt accent border
at 55 % is the one used before the cards, now following the rounded edge.
The header's answer to the context menu's open point: its entry point is
the header ("…" and right-click). The New Session chooser's compact
widths are measured against the pane's width as before the cards.

**October 31, 2026: header buttons.** The owner asked on October 31, 2026
for Split Right and Split Down buttons beside "…" and dropped them the
same morning because they made the header look busy, so the splits are
reached from the pane menu (its first two items, ⌘D, ⇧⌘D) and the
application's Pane menu.

**Cost (October 31, 2026).** Against the layout before the cards a 2 × 2
split loses about 60 pt of height (two headers and the top and bottom
gutters against the old 4 + 10 pt pane padding and the 1 pt divider) and
about 24 pt of width (three gutters), roughly four rows and three columns
at the default font; a single pane loses about 40 pt of height and 16 pt
of width. The owner accepted this for the first version; a "Show pane
headers" preference (cards and gutters stay, the header row goes) was
deferred (owner's decision), noted in section 13.

**Planned implementation and live checks (October 31, 2026).** The plan:
`PaneContainerView` insets the split tree by the gutter; `PaneSplitView`
gets `dividerThickness` 8 and draws no divider (`drawDivider(in:)` empty;
`dividerColor` unused); `PaneView` and `EmptyPaneView` set
`layer.cornerRadius` and `masksToBounds`, put the border on their existing
focus overlay layer and host a `PaneHeaderView` with a small
`PaneHeaderModel`; a pure `PaneCardStyle` unit tested as `TabBarStyle` is;
the header's title precedence and the "…" button reaching `paneMenu()`
tested with the views in a window. Live checks planned (the Mac is
needed): light and dark, two themes side by side, a 2 × 2 split, zoom, an
empty pane, a *Session Ended* pane, a narrow pane at about 90, 165 and
185 pt, divider drags in the gap, and the header menu over vim with
`mouse=a`.

**Owner's decisions (October 31, 2026).** A lone pane gets the gutter and
header too; the "Show pane headers" preference comes later; the numbers
(gutter 8, gap 8, radius 10, header 28) were to be judged live against
the window's own corners and the native tab bar and adjusted in the same
change; no split, zoom or close buttons in the header. (The owner asked
for Split Right and Split Down buttons beside "…" later on October 31,
2026, with the same two items at the top of the pane menu, and dropped
the buttons the same morning because they made the header look busy; the
menu items stay.)

**As built (October 31, 2026).** The numbers stayed as agreed after the
live checks in light and dark (they sit well against the window's rounded
bottom corners and the 36 pt tab bar). The ratio layout already
subtracted `dividerThickness`, so it needed no change (the split test now
expects `(width - 8) × ratio`). `AppModel.abbreviatedDirectory` was made
public for the header. *Deviations, found live:* (1) the directory is not
shown when it equals the title (zsh and fish title themselves with the
directory, which read "~ ~"); (2) the title and the directory share the
header's text width by a rule, so a narrow pane never shows a stray
one-character fragment of the directory (seen live) and a long title
never hides it in a normal pane (the first version's `ViewThatFits` did,
seen in review in a 417 pt pane); (3) the *Session Ended* /
*Disconnected* placeholder covers the card below the header rather than
the whole pane (it dimmed the pane until later that day, see "Session
Ended"); (4) Control-click on the header opens the menu too. The rule
that the directory shows only after an OSC 7 report came from review
(seen in review: "~" after `cd /private/tmp/…`, from the owner's zsh,
which sends no OSC 7); that a session once reported stays reported was
seen in review by sending OSC 7 by hand from the owner's zsh, then `cd`.
The menu's right alignment on the rightmost pane was also seen in review.

**Checked live (October 31, 2026, pane cards).** Test build, isolated
state, light and forced dark: a 2 × 2 split (gutters, gaps, corners,
headers, hairlines, accent border on the focused card only), Default,
Gruvbox Dark and Dracula panes side by side chosen from the "…" pull-down
and from a header right-click, typing in the pane right after a choice, a
lone pane and a zoomed pane, an empty pane at full width and at about 90,
165 and 185 pt (header "Ne…n" with the "…" still there; chooser tiny,
small, compact; New… still opens the dialog), a *Session Ended* pane
(glyph ○ and title kept), a drag in the 8 pt gap, vim with `mouse=a` (a
right-click in the grid moved vim's cursor, `mousemodel=popup_setpos`; a
right-click on the header opened Armadale's menu and vim's cursor did not
move), a bell in an unfocused pane (◐ and the purple title in its header,
with the tab and sidebar), Control-click on the header. Not checked live:
the *Disconnected* placeholder (needs a host) and Increase Contrast. The
three review fixes (OSC 7-only directory, the shared-width rule, the
right-aligned menu on the rightmost pane) were checked live by the
reviewer in light mode: no directory after `cd` in a plain zsh, the path
after an OSC 7 report, an 80-character title truncated in the middle
beside the directory in a 417 pt pane, a long directory truncated beside
a short title, and the rightmost pane's menu ending at its button's
trailing edge inside the window.

**Split items, as built (October 31, 2026).** The header kept its one
24 × 20 pt "…" button. Split buttons were built and checked live that
morning: three 24 pt buttons, the text space the header less 116 pt, and
"…" alone under 156 pt; the owner then dropped them, and that geometry
with them. *Checked live* (test build, light mode): Split Down and Split
Right from a header right-click on unfocused panes, with ⌘D and ⇧⌘D
shown, each splitting that pane with the new pane focused showing the
chooser; typing in the terminal after clicking back into it; the
rightmost pane's "…" menu ending inside the window.

### Settings

**October 24, 2026: General.** The default profile and directory were
removed from General on October 24, 2026 with the New Session chooser.
The Favorites tab dates from October 24, 2026.

**October 29, 2026: the Shortcuts tab.** The read‑only Shortcuts tab of
steps 5 to 10 moved to Help › Keyboard Shortcuts on October 29, 2026:
Settings is for what can be changed, and a shortcut cannot be changed in
Armadale yet. Until October 29, 2026 Keyboard Shortcuts was a Settings
tab.

**Implementation (step 5): the Settings window.** `SettingsWindowController`
with an `NSTabViewController` and the typed `Preferences` store were
built in step 5. `confirmClosingRunningSession` kept the same key as
step 4.

**Step 7: profile Attention and General › Notifications.** The Claude
Code and Codex **Attention** section in the profile editor and General ›
Notifications came with step 7.

**October 24, 2026: new tabs with a profile.** File › New Tab with
Profile and the tab bar's "+" context menu, which opened a tab with any
profile, were removed on October 24, 2026: every new pane asks.

**Step 6: Hosts.** Settings › Hosts (`Settings/HostsSettingsView.swift`)
was built in step 6.

**October 24, 2026: new sessions on hosts.** Until October 24, 2026 File ›
New Tab on Host and an "On Host" section in the tab bar "+" context menu
created a remote tab with the default profile in the host's home
directory, and splitting a remote pane stayed on its host; both are gone
with the chooser.

**November 4, 2026: Help › Acknowledgements.** Help › Acknowledgements
(`Help/AcknowledgementsWindowController.swift`) was added on November 4,
2026.

**Re-applying no longer soft-resets the program (October 31, 2026, found
in review).** `SwiftTermSurface.apply` set the font on every call, and a
pane applies its appearance whenever it enters a window, so a split, a
tab switch or a zoom soft-reset the program in that pane (seen: `?1h` and
`?25l` reported reset by DECRQM after ⌘D; a window resize, which resizes
without the reset, kept them). Since then the surface sets the font only
when its name or size changed.

**October 30, 2026: removing an imported theme.** Removing an imported
theme has returned panes using it to Default since October 30, 2026.

**November 16, 2026: the Favorites tab removed.** Settings › Favorites
(October 24, 2026 to November 16, 2026) is gone: favorites are managed
in the New Session chooser, made in the dialog and from a pane's menu
(section 8, "New sessions"). A `settingsTab` saved as `favorites` opens
General, as `shortcuts` does. The dialog's Add Host… button, which opened
Settings › Hosts, went with it (New Host… in the dialog); Settings ›
Hosts itself is unchanged.

### New sessions: the chooser, the dialog and favorites

**October 24, 2026. New sessions designed (owner's request).** The design
of the chooser, the dialog and favorites is dated October 24, 2026, and
was the owner's request: a new pane never starts a local shell by itself.
It asks. It was built in step 10, in three sub-steps (10a, 10b, 10c).

**Step 10. Splits stopped copying.** A split no longer copies the pane's
profile and directory; it asks like the rest.

**Step 10. The old General setting.** The dialog's Choose… abbreviates
the home folder as `~` as the old General setting (the default directory
in Settings › General) did.

**Step 10. Removed.** File › New Tab with Profile, File › New Tab on Host
(and the Add Host… item under it), the tab bar "+" context menu (its help
text is now just "New Tab"), Settings › General's default profile and
directory (the preference keys are left unread),
`Preferences.defaultProfileID` / `defaultWorkingDirectory`,
`AppModel.defaultProfileID`, `newTab(in:onHost:profile:)`. The Shortcuts
table is unchanged: nothing here has a key equivalent.

**Step 10. Flag names checked.** The flag names come from
`claude 2.1.304 --help` and `codex-cli 0.163.0 --help` on this Mac (Codex
has no `--full-auto` any more and no resume flag; `resume` is a
subcommand).

**Step 10c. Implementation of the chooser.** The bullets that the
document listed as "*Implementation (step 10c).* What the code decides
beyond the above" (Views, Rows, Keys, Focus, Actions, Nothing opens a
sheet by itself, Quit, Tabs) were written for step 10c; their current
content is in DESIGN.

**Step 10c. Compact card checked live.** The compact card (a pane
narrower than 340 pt) was checked live at about 90, 165 and 185 pt.

**Step 10c. The chooser's buttons and the placeholder.** Neither of the
chooser's buttons has a SwiftUI keyboard shortcut, a deviation from the
placeholder, which keeps its default-action shortcut for the look.

**Step 10c. Sheet slot rule taken from 10b.** No sheet while the window is
closing or entering or leaving full screen
(`WorkspaceWindowController.canPresentSheet`), as 10b's presenter did.

**Step 10c. The 10b interim removed.** The 10b interim
(`NewSessionPresenter`, which put the dialog on every empty pane) is
gone; the dialog opens only from New Session… or Return.

**Step 10c. Quit with a sheet.** `ArmadaleApplication` still ends a New
Session or Edit Favorite sheet before AppKit's `terminate(_:)`; a
cancelled quit no longer brings the sheet back (deviation from 10b: the
pane's chooser is still there, so there is nothing to resume).
`scripts/check-quit.sh`'s first scenario is now "chooser up".

**Step 10c. Empty tab's status glyph.** `StatusGlyph` takes `nil` for a
tab with no session; until 10c such a tab showed the hollow "ended"
circle.

**Step 10b. Implementation of the dialog.** The bullets that the document
listed as "*Implementation (step 10b).* What the code decides beyond the
above" (the form's rules, Directory prefill, Hosts, Options, Name,
Validity, Keys, Layout, Respawn, Settings › Favorites, Host removal) were
written for step 10b; their current content is in DESIGN.

**Step 10b. Directory prefill and the original wording.** The October 24
design said the directory came from "the registry's last known
directory, else the session's". As built, the directory is the session's
`Session.workingDirectory`, which only OSC 7 updates (there is no
separate registry record). With a shell that does not send OSC 7 (seen
live: the owner's zsh sets the title but sends no OSC 7) it is the
directory the session started in. A window made by ⌘N takes the session
from the window it was made from (a deviation from "the window's focused
pane": the new window has none; 10a did the same).

**Step 10b. `showSettings(tab:)`.** `AppDelegate.showSettings(tab:)` was
made internal in step 10b for the dialog's Add Host….

**Step 10b. Return in a text field.** A focused text field takes Return
before the default button sees it (found live), so the fields'
`onSubmit` confirms the sheet too.

**Step 10b, step 10c. Sheet sizing.** Settings' New Favorite sheet is
presented like the workspace dialog (`NewFavoriteSheet`), so it grows and
shrinks with its rows (measured live: 540×241 Local, 540×273 SSH, 241
again; step 10c). The SwiftUI `.sheet` with
`.presentationSizing(.fitted)` used in 10b never grew: SSH's Host row
squeezed the title's top margin.

**Step 10b. Host removal question.** The existing question (asked only
when sessions run on the host) gained how many favorites will be broken;
a host with no sessions is still removed without a question.

**November 14, 2026: where Profiles, Hosts and Favorites belong (the
research).** The owner's question: General and Appearance hold
preferences, while Profiles, Hosts and Favorites hold things the user
creates; do those three have a better home than Settings? About 34
terminal, SSH and agent apps were read from their official documentation
that day (documentation only; none was run). What it found:
- Launching has its own surface outside Settings in almost every
  terminal: iTerm2's Profiles window, Warp's "+" menu with Tab Configs,
  Windows Terminal's dropdown, Tabby's selector, Wave's launcher in a new
  block. None gives profile editing a window of its own; those with a
  graphical editor keep profiles in Settings.
- Agent apps create hosts and environments where they are used: the last
  item of the "where it runs" picker opens the add dialog (Claude
  desktop, Codex), and Settings is at most a second door (Codex
  Connections, Emdash Machines, Paradev Hosts).
- An existing ssh configuration is offered rather than retyped (Codex,
  Emdash, Zed, Tabby as a read-only group, VS Code, which uses the file
  as its store).
- SSH-first apps put hosts in the main window (Termius, Prompt 3,
  SecureCRT, MobaXterm). Armadale is not host-first, so no Hosts window.
- Nobody has literal favorites; the equivalents are recents, pins and
  recipes saved from a live session (Warp's "Save as new config",
  Transmit's connect first and save afterwards).
Sources: https://docs.warp.dev/terminal/windows/tab-configs ,
https://docs.waveterm.dev/connections ,
https://iterm2.com/documentation-menu-items.html ,
https://learn.microsoft.com/en-us/windows/terminal/customize-settings/startup ,
https://code.claude.com/docs/en/desktop ,
https://learn.chatgpt.com/docs/remote-connections ,
https://zed.dev/docs/remote-development ,
https://emdash.com/docs/remote-development/ssh-connections ,
https://help.panic.com/prompt/prompt-mac-sidebar/ ,
https://docs.termius.com/getting-started/import-existing-hosts.md ,
https://help.nova.app/remote-files/servers/ ,
https://code.visualstudio.com/docs/remote/ssh .

**November 16, 2026: the owner's six decisions.** Approved that day: (1)
Settings loses its Favorites tab; (2) favorites are reordered in the
chooser by drag, plus Move Up and Move Down; (3) a host is added in the
New Session dialog through an inline Destination field (no sheet on a
sheet, which the window's one sheet slot and the quit path would not
allow); (4) the aliases of `~/.ssh/config` are suggested while the
destination is typed; (5) a favorite saved from a pane uses the pane's
current directory; (6) recents are not part of this step. Not in this
step either: a Hosts window, a default favorite that a new tab starts by
itself (a new pane always asks), sign-in in an embedded terminal,
resolving aliases with `ssh -G`, any change to Profiles, a main-menu item
or shortcut for any of this. The coordinator's details: Save as
Favorite… sits after Split Right and Split Down between separators and
is not in an empty pane's menu; a host added by New Host… is named after
its destination, made unique like "New Host"; with no host saved, SSH
goes to New Host… at once (the "No Hosts" state and its message went);
a saved host without a usable destination still points at Settings ›
Hosts, which stays as it was.

**November 16, 2026: as built.** Decisions made in the implementation,
beyond the brief:
- A dropped favorite takes the target row's index, counted after removal
  as `moveFavorite` counts (the tab bar's rule), so it lands below a row
  it came from above and above one it came from below. The drop
  indicator is drawn on that edge. A drop destination sees the payload
  only on the drop, so the edge comes from the favorite whose drag
  SwiftUI started last (`FavoriteDragItem.lastDragged`, set when the
  payload is built); the tab bar's indicator, always at the leading
  edge, was the alternative and was not taken because it shows the wrong
  edge for a move down.
- Move Up and Move Down are accessibility actions only where the move
  is possible (`accessibilityActions` with conditions), matching the
  disabled menu items, rather than actions that do nothing at the ends.
- New Host…'s host is looked up as a "plain" host (`Host.isPlain`: no
  port, identity file or config file, the default remote folder) with
  the destination compared exactly as typed after trimming, not
  case-insensitively: an exact comparison errs towards one more saved
  host, never towards a session on a host the user did not name. What
  ssh does, read from the source, not run (openssh-portable master:
  readconf.c v1.424, match.c v1.46, ssh.c v1.647): the `oHost` case
  calls `match_pattern(host, arg)`, which compares byte for byte, against
  the host name as typed (ssh.c passes `options.host_arg` to the first
  configuration pass and lowercases `host` only afterwards), so `Host`
  patterns are case-sensitive in that pass; `Match host` is not
  (`match_hostname` lowercases). The reason above holds either way.
- The request shown while New Host… is chosen names the plain host
  already saved for the destination, if any, so the proposed name names
  that host; otherwise the proposal names the destination
  (`proposedFavoriteName(for:hostName:)`).
- New Favorite (Save as Favorite…) saves only a valid form, so a session
  whose host or profile is gone waits for a choice; Edit Favorite keeps
  its looser rule.
- The alias matching is: all while nothing is typed, then prefix matches,
  then other substring matches, ignoring case, at most 20, an exact match
  left out. The reader follows each file once (a cycle ends there) and
  stops at ssh's depth of 16; it also accepts `'` quotes and backslash
  escapes and treats an unquoted word starting with `#` as a comment,
  as OpenSSH's own argument splitting does.
- The form takes its loader at init, and `WorkspaceActions` holds the
  one it passes (`sshAliasLoader`), whose default also finds nothing:
  the app delegate sets the real one when it makes a window, so even a
  test that drives a window's dialog cannot read the real file.
- The notification `armadaleWillQuit`, posted at a quit for Settings ›
  Favorites' New Favorite sheet only, was removed with it; a quit still
  ends any sheet on the Settings window (Profiles' Configure…).
- A drag does not scroll the scrolling variant of the list (not built;
  the tab bar has the same limit), recorded in DESIGN as a known limit.

**November 16, 2026: after the review.** An adversarial review of the
step and the coordinator's own reading found no blocker. Changed:
- *The favorite's name shown was not the name saved.* With a configured
  host "vm" (port 2200) saved, New Host… "vm" with Add to Favorites
  showed "Shell on vm in ~", added the host as "vm 2" and saved the
  favorite as "Shell on vm 2 in ~". The proposal now names a host to be
  added as it will be named (`AppModel.newHostName(forDestination:)`,
  which `ensureHost(forDestination:)` uses too), so the name shown is the
  name saved and still equals the proposal for the saved request.
- *The ssh configuration reader read whatever it was pointed at, whole.*
  The reviewer measured an `Include` of a sparse 1 GB file: 25 s of CPU
  and 3.2 GB resident, on a thread that cannot be cancelled. (A FIFO,
  `/dev/zero` and `/dev/stdin` returned at once in the reviewer's
  probes: `FileManager.contents(atPath:)` gives nothing for them. The
  reader no longer relies on that.) It now reads regular files only,
  checked with `stat` before opening, skips a file over 1 MB and opens
  at most 256 files in one read.
- *Aliases that can never be used were offered* (`Host "a b"`, a pattern
  starting with `-`): an alias must also pass `Host.destinationProblem`.
- *The word splitting now follows OpenSSH's `argv_split`* (misc.c
  v1.223, read from the source, not run): a line with an unterminated
  quote is dropped (it gave an alias; ssh rejects it as invalid quotes);
  a backslash escapes a following `'`, `"` or `\` in every quote state
  and a following space only outside quotes, and stays a backslash
  before anything else; an `Include` of `~user/x` names nothing (it read
  `~/.ssh/~user/x`). The backslash rule was first written from a
  description (inside quotes only the quote and `\`) and then corrected
  against `argv_split` itself.
- *`FavoriteDragItem.lastDragged` was never cleared*: a handled drop
  clears it now (a cancelled drag still leaves it until the next drag
  starts, which only affects the indicator).
- Smaller: `AppModel.host(forDestination:)` renamed
  `ensureHost(forDestination:)`, since it adds; the picker's divider only
  under an item; a session binding without a saver has no Save as
  Favorite…; the form's "Profile removed" for a host to be added comes
  from `requestProblem`; a test of the drag types' declarations in the
  source tree's Info.plist (an unhosted test cannot see them otherwise);
  a vacuous test block removed; wording.
Left as it was, by the coordinator's decision:
`SettingsWindowController.show(_ tab:)` keeps its parameter (a test uses
it, and it is a reasonable entry point); Save as Favorite… does nothing
while the window's sheet slot is taken (a sheet blocks the window's
headers, so the menu cannot be opened then; the remaining case is a
full-screen transition, where New Session… does nothing either);
aliases are deduplicated case-sensitively and destinations compared
exactly; `Include ${VAR}` and `%` tokens are not expanded.

**November 16, 2026: checked live; Return while aliases are offered.**
The step was checked live the same day (Part 1, "favorites in the
chooser and New Host…, checked live"). One thing no test could show:
with SwiftUI's suggestions open under the Destination field, Return
with none highlighted submits the field, so the dialog confirms with
the text as typed, and Return on a highlighted suggestion completes
and submits in one keystroke. Both come from the field's `onSubmit`
confirming the sheet (step 10b, "Return in a text field"). Left as it
is and written into DESIGN. Asked the same day whether Return should
take a suggestion first and leave the dialog open, the owner decided
to leave it as it is.

### App lifecycle

**November 14, 2026. The state directory's lock.** The lock on the state
directory (section 3, "One process per state directory") was added; a
lock that is unavailable is logged and the app runs as before the lock
existed.

**November 14, 2026. A fatal launch: activation checked in review.** In
review (November 14, 2026) a locked-out copy started by its binary path
from a shell put its alert on screen (layer 0) while the other app stayed
frontmost. With `bringForward()` (same check, same day, Terminal
frontmost) the locked-out copy was the frontmost app at 1, 3, 6 and 10 s,
its alert on the modal-panel layer (8), and SIGTERM with the alert up
ended it in 0.06 s.

**November 14, 2026. A fatal launch: one launch plan.** Every fatal launch
is built the way the locked-out one is (`AppDelegate.LaunchPlan`, keyed
on `LoadReport.isFatal`) since November 14, 2026; before that only the
lock refusal was. Live (same day, Debug build, isolated directory): with
`state.json` at schema 99 and decoy `zmx-0.0.1` and `ctty-exec-0.0.0`
copies in `bin/`, the alert said format 99 against format 2, no helper
process started, and after SIGTERM every file had the same inode, size
and modification time except the lock file; the same launch at schema 2
removed both decoys.

**November 14, 2026. The normal launch's activation.** The normal
launch's plain `NSApp.activate()` was refused the same way (the first
copy, started from the shell, stayed behind Terminal); it is unchanged
for now.

**`.terminateLater` rejected.** `.terminateLater` was tried and rejected:
SIGTERM's handler ran inside a main-queue block, where AppKit's nested
run loop starves the main actor, so the reply never came and logout would
hang. SIGTERM now quits from the run loop, performed in the common and
modal-panel modes.

**Quit timing measured.** `scripts/check-quit.sh` checks exit within 2 s
(measured: 119 ms each).

**Step 10b. Sheets and `terminate(_:)`.** AppKit's `terminate(_:)` does
nothing at all, without asking the delegate, while any window has a sheet
attached (measured on macOS 27), so in step 10b the app's
`NSApplication` subclass (`ArmadaleApplication`, the principal class)
was made to let the delegate end every window's New Session (or Edit
Favorite) sheet first, and any sheet in Settings. No sheet comes back
when the quit is cancelled since step 10c (the pane's chooser is still
there).

**Step 10c. `check-quit.sh`'s third case.** `check-quit.sh` has a third
case, the fresh launch's chooser up (step 10c; in 10b it was the sheet
the interim put on every new pane). A close confirmation sheet still
holds a quit up, as before.

**October 23, 2026. Closing the last tab group deletes the workspace
(owner's request).** Closing the last tab group in a workspace, or
dragging its last tab into another workspace, deletes the workspace since
October 23, 2026, at the owner's request; until then it stayed in the
model and the sidebar as a dimmed, empty "closed" row, and reopening it
made a fresh "Main" group. The model returns `CloseResult.deletedWorkspace`
(the old `.closedWindow` is gone). A clean exit in a workspace's last pane
gets here too (section 4, "Ended", since October 23, 2026). A workspace
closed *with* tab groups (the window's close button, ⇧⌘W) is unchanged.

**October 23, 2026. Full-screen serializer.** Since October 23, 2026
every full-screen toggle Armadale makes goes through one app-wide
serializer (`FullScreenSerializer`, owned by the app delegate). A window
closed in full screen from outside Armadale's own path (⇧⌘W in a
full-screen window) still gets AppKit's exit after `windowWillClose`,
which the serializer does not see; this was judged benign in review.

**Full-screen timings measured in review.** Worst-case timings measured in
review: entries end about 0.6 + 0.9 × (N − 1) s after launch for N
windows (three windows: 0.63, 1.51 and 2.39 s); a close of a full-screen
window can take about 4–5 s in the worst case (its turn, failed exits
retried, the closing exit); a return from menu bar mode can wait up to
2 s more per window for its Space.

**October 20, 2026. Full-screen relaunch measured.** Measured October 20,
2026 on a 3200×1800-point display: relaunched in full screen with the
pane attached and `stty size` reporting 121×420, the full-screen grid.

**October 23, 2026. Closing in full screen (review of the clean-exit
change).** A window whose workspace leaves the model (or is marked closed)
while it is in full screen or in a transition is never closed as it is
(October 23, 2026, review of the clean-exit change; measured on macOS
27). Closed mid-transition, its controller was released and AppKit
finished the transition on its own, putting the window back on screen at
its normal frame, titled and empty, and the launch queue, waiting for
that transition, stalled, so the next window never entered full screen
and was saved as not in full screen. Closed in full screen while another
window's transition ran (the launch queue's next entry), it came back the
same way: the close brings an exit, and the two overlapped. Measured on
macOS 27: the exit of a full-screen window that is not on the active
Space fails (`windowDidFailToExitFullScreen`). A failed exit on the
active Space was described as tried again after 0.3 s, "up to four
times"; the code makes four attempts in all. The serializer's 0.3 s
settle time came from a measurement: an exit 9 ms after another window's
entry failed.

**Saved frames and screens: AppKit's constraint measured.** With the
default separate Spaces per display, a frame spanning the built-in
display and an external one came back entirely on the built-in one (x
−600 became −1100), and one half off an external display's right edge
was moved fully onto it (x 2650 became 2100). Armadale's own constraint
(`constrainFrameRect(_:to:)`) brought a title bar on screen (y 1500
became 1070) and fitted an oversized frame (4000×2500) to the visible
area. An old state file holding a screen-sized frame was saved in full
screen before this rule.

### Quitting with running sessions: menu bar mode

**Step 8. Menu bar mode built.** Quitting with running sessions and menu
bar mode were built in step 8 ("Quitting with running sessions: menu bar
mode (step 8)"); the implementation notes were headed
"*Implementation (step 8):*" and listed "where it differs from or adds
to the above".

**October 19, 2026. Status item escapes the Dock (prototype).** That an
app that stays running with a status item is not in the Dock at all, and
that a quit from that state leaves no Dock item either, was verified
October 19, 2026 with the prototype that preceded this step.

**Step 8. Plain quit unchanged.** With no running sessions, quit proceeds
as before (detach every client, `.terminateNow`, save); SIGTERM quits as
before, sessions kept. Window close is unchanged: closing the last window
keeps the app running with its Dock icon; only quit enters menu bar mode.

**October 20, 2026. Full screen and menu bar mode.** Found October 20,
2026: a full-screen window ordered out and shown again does come back in
full screen, but its title bar and toolbar do not (AppKit's full-screen
toolbar window comes back zero-sized), so it is taken out of full screen
first. The saved frame and flag were sane either way.

**October 23, 2026. Full-screen windows on another Space.** A full-screen
window on another Space cannot be taken out of full screen (measured on
macOS 27, October 23, 2026: its exit fails and AppKit puts it back). The
return path (brought forward, leaves full screen, re-enters it) was
checked live with two full-screen windows. After ⌘Q → Keep Running, the
treatment on *Open Armadale* took about 2.5 s for two windows (measured
in review).

**October 23, 2026. Menu bar mode stays (owner's decision).** Menu bar
mode stays when the last session ends, and the app never leaves menu bar
mode or quits on its own (owner's decision, October 23, 2026).

**October 19, 2026. Background permission tested.** Tested October 19,
2026: with Armadale switched off in Allow in the Background,
`loginwindow` asks Background Task Management when the app exits, is told
no, and force-quits the app's coalition, which SIGTERMs every daemon and
shell: 5 s after a quit from menu bar mode, 1 s after a regular quit such
as SIGTERM. No prompt appeared for an accessory-mode quit, switched on or
off (a Mac with no stored decision was not tested).

**`.terminateLater` still not used.** In End Sessions and Quit,
`.terminateLater` is still not used (the SIGTERM deadlock, "App
lifecycle").

**November 9 and 12, 2026. Activation.** Found November 9, 2026 on macOS
27 with a real click on the status item and the item chosen from its
menu: plain `NSApp.activate()` is refused (cooperative activation, macOS
14 and later), so Settings opened behind the active app's front window,
drawn inactive, and *Open Armadale* left the regular app inactive with
its windows behind; switching to the regular policy before `activate()`
was refused the same way; the quit alert, which still called
`NSApp.activate()`, opened behind the active app's front window
(November 12, 2026, a scripted quit with Terminal active).
`activate(from:)` was let through every time (the app active, the window
key and in front). `activate(ignoringOtherApps:)` also worked but is
marked to be deprecated and is not used.

**November 12, 2026. Closing Settings in menu bar mode.**
`NSApp.deactivate()` was tried first and does not work: the accessory
app stayed the frontmost application, so the app hides instead.
`NSRunningApplication.isHidden` staying false for an accessory app after
a successful `hide` was checked November 12, 2026 with a windowless
accessory app.

**Step 8. Settings › General height.** Settings › General is 520 pt tall
(was 330, which already scrolled the last section out of view).

**November 14, 2026. "Allow in the Background" is now "Background App
Activity".** The repository named the switch by its macOS 13 to 26 name.
On macOS 27.2.1 (build 26B131) the Login Items pane's own strings
(`LoginItems.appex`, `Localizable.loctable`, English) have "Open at
Login", "Background App Activity", "Extensions", "Legacy Background
Tasks" and "Managed Background Apps", and no "Allow in the Background";
Apple's support article 125671 (September 14, 2026, "Starting in macOS
27") says "Under Background App Activity" (the Mac User Guide says "App
Background Activity"). DESIGN and the README now use the on-screen name.

### Background App Activity

**November 14, 2026. Detect and tell (owner's choice).** The switch's
effect (section 8, "Quit, Keep Sessions Running"; Part 1, October 19,
2026, evening) was an open decision since October 19, 2026. On November
14, 2026 Apple's ServiceManagement documentation (the framework page,
`SMAppService`, `SMAppService.Status`, `openSystemSettingsLoginItems()`,
`agent(plistName:)`, `statusForLegacyPlist(at:)`) and the macOS 27.2
SDK's `SMAppService.h` were checked: every symbol is macOS 13.0 (the
newest, `SMAppServiceErrorDomain`, macOS 15.0), nothing for macOS 26 or
27, and `status` describes a service the app registered, so no API reads
the app's own background allowance. Three options went to the owner:
detect the loss after the fact and tell (chosen); only say it in the quit
alert and the status menu; or a registered background item
(`SMAppService`), prototyped first in a throwaway app, which even at
best would only let the app know before the loss, since an agent that
is switched off does not run either. The coordinating session decided
the details: the record at quit, the rule and its windows (1 s before
the quit, for the log's whole seconds, to 10 s after it, against the
measured 1 s and 5 s; the check no earlier than 12 s after the quit),
the wording, and which quits ask (only a quit from menu bar mode that
leaves local sessions; the ⌘Q question already never leaves sessions to
the system).

False alarms and misses looked at then: the system's own quit carries a
reason, and a restart or logout changes the boot time or the audit
session id (undetermined, not a loss); sessions the user ended go
through the helper's kill (no SIGTERM line) or are not in the record; a
program that finished by itself has an exit record and no SIGTERM line.
The Dock's stop item or a `kill` by hand within 10 s of a quit is
reported as a loss (rare; the Dock item exists only after a quit from
the regular policy). A crash or force quit of Armadale leaves no record.
A relaunch within 5 s of a quit from the menu bar would find the
sessions still alive, which is why the check waits until 12 s after the
quit. Whether the force quit also ends sessions started by an earlier
run of the app (their daemons are in that run's coalition) is not
known: every test on October 19, 2026 used a fresh session, so *ended*
needs one recorded session ended that way, not all of them.

Two details came from the implementation. `kern.boottime` moves when the
clock is set, so two boot times within 60 s count as the same boot; a
restart moves it by the Mac's whole uptime. A quit within 12 s of the
previous one, before that one's check has run, replaces its record, so
that check never runs (accepted: the window is the 12 s itself).

The review of the same day changed six things (coordinator's
decisions). A quit question answered with Cancel or Open System
Settings left an active accessory app with no window, so after Cancel
the app now hides again by the rule closing Settings uses. After Open
System Settings it does not (the second review): System Settings takes
activation by itself, and `NSApp.hide` hands activation to the
previously active app, which may land after System Settings and put it
behind; reasoned from how hiding works, not checked live. The late loss
alert can come up to 12 s after launch, while the user types into a
pane: Return there does nothing, and in menu bar mode no alert is shown
at all (an inactive accessory app's alert may sit behind other
windows), decided once, when the alert would show (the second review
found that deciding at the check as well missed a user who had left
menu bar mode meanwhile); Not Now answers Escape in both alerts. A hand-edited boot time of `Int64.min`
trapped in the subtraction at every launch, since the quit is removed
only after the verdict; the comparison is overflow-safe now, and the
file's other numbers were checked: the decoder refuses non-finite
seconds and out-of-range integers, dates are only compared or offset in
floating point, and the wait is capped and never NaN. The quit
question's text said "After the last quit that left sessions running",
which the record does not show (`lossSeenAt` outlives undetermined
checks); it now says "After an earlier quit". Quit Anyway is marked
destructive. And a check that ran late never clears `lossSeenAt`:
**not known** is whether macOS still ends the old run's sessions when
the app is running again within 5 s of the quit (every test on October
19, 2026 relaunched later); if it does not, a quick relaunch would find
them alive and clear the flag while the switch is still off.

**November 14, 2026, 22:00 to 22:17. Checked live** (Part 1, "the
background detection, checked live", has the run). What it settled for
this section:
- *Ended*, *survived* and *undetermined* each came out as designed,
  with the alert, the log line and the record file to match. Switched
  off, the daemon logged its SIGTERM line 1 s after a SIGTERM quit.
- **A quick relaunch saves the sessions.** Switched off, after Quit
  Anyway from menu bar mode and a relaunch 1 s later, the session was
  still alive 15 s after the quit and Background Task Management logged
  no check for that exit: `loginwindow`'s check, 5 s after an
  accessory-mode quit, does not come when the app is running again. So
  the late check said *survived* with the switch off, and `lossSeenAt`
  stayed only because a late check never clears it; the second review's
  rule was needed.
- After Open System Settings on the quit question, System Settings came
  to the front over Finder with the app left in the menu bar; after
  Cancel the app that was active before was in front again.
- The late alert has no default button (`AXDefaultButton` absent) and
  Not Now as its cancel button; the launch-time alert has Open System
  Settings as its default.
- **With no decision stored nothing is ended.** Armadale was not in the
  Background App Activity list on that Mac. At the first quit that left
  a session, Background Task Management answered "record not found
  (-95)" and nothing was touched; 32 s after the exit it registered the
  app and posted a notification, and Armadale was in the list from then
  on, switched on. A later quit of a copy at another path posted none,
  and the one entry governed both copies (both ad hoc, same bundle
  identifier). What the notification's own choice does was not seen
  (the owner used the switch).


### Updates

**November 16, 2026. Sparkle, decided by the owner; built.** The design
(written that day by the coordinating session from Sparkle's
documentation, its release notes and its source at tag 2.10.1) put eight
decisions to the owner, who answered "Build as recommended" (Part 1, "an
updater, with Sparkle", lists them). What the source says, which the
implementation relies on (paths in the Sparkle repository at 2.10.1):

- *The install path.* Install and Relaunch in the standard user driver
  calls the stored handler once and forgets it
  (`Sparkle/SPUStandardUserDriver.m` 521–527; the "Ready to Install"
  window is made with `closable:NO`, 510–519); the UI driver passes the
  choice to the core driver (`SPUUIBasedUpdateDriver.m` 417–426), which
  calls `installWithToolAndRelaunch:YES`
  (`SPUCoreBasedUpdateDriver.m` 307–320). There
  (`SPUInstallerDriver.m` 509–561): `updaterShouldRelaunchApplication`
  first (`mayUpdateAndRestart`, 503–507), and a no aborts the install
  with no error (515–519); then, only while `_postponedOnce` (65) is
  unset, `shouldPostponeRelaunchForUpdate:untilInvokingBlock:` (522–535),
  whose block calls `installWithToolAndRelaunch` again; then
  `installerWillFinishInstallationAndRelaunch:` once (551–554), which
  calls `updaterWillRelaunchApplication:` in the app's process
  (`SPUCoreBasedUpdateDriver.m` 322–339); then the message that resumes
  the installer to stage 2 (560), whose stage 2 asks the progress agent
  to quit the app (`Autoupdate/AppInstaller.m` 749–763) by
  `NSRunningApplication.terminate`, "an Apple quit event, which gives
  the application or user a chance to delay or cancel the request"
  (`Sparkle/InstallerProgress/InstallerProgressAppController.m` 375–385).
- *If the app does not quit.* The UI driver's "installing" step with
  the app not terminated closes the status window and keeps a retry
  handler (`SPUStandardUserDriver.m` 862–880; `SPUUIBasedUpdateDriver.m`
  377–390), so nothing stays on screen.
- *Cancel.* A no from `updaterShouldRelaunchApplication` reaches
  `installerIsRequestingAbortInstallWithError:nil`, then the UI
  driver's abort, which calls `dismissUpdateInstallation` (closing the
  checking, status and alert windows and telling the delegate
  `standardUserDriverWillFinishUpdateSession`,
  `SPUStandardUserDriver.m` 927–960; `SPUUIBasedUpdateDriver.m`
  452–494) and the core driver's abort, which only invalidates the
  installer connection (`SPUInstallerDriver.m` 575–582;
  `SPUCoreBasedUpdateDriver.m` 383–400). The installer process stays: it
  exits on a lost connection only before installation has started
  (`AppInstaller.m` 204–210, `_willCompleteInstallation`, set at 690–692
  once validation passed), and it has registered for the app's
  termination (399–417). When the app terminates, it installs (765–831)
  and relaunches only if a stage-2 request asked it to (821–824, with
  `_shouldRelaunch` from that request, 654–664). So after Cancel the
  update is installed at the next quit, by whatever path, and the app
  is not relaunched. A later check finds the install in progress and
  offers it again; Install Update there goes through the postpone hook
  of a new installer driver, Skip This Version sends
  `SPUCancelInstallation` and the installer exits without installing
  (`SPUUIBasedUpdateDriver.m` 270–313; `AppInstaller.m` 681–684). The
  updater delegate hears the end of the cycle
  (`updater:didAbortWithError:` unless the error is "authorize later",
  `updater:didFinishUpdateCycleForUpdateCheck:error:` unless the next
  update is shown at once; `Sparkle/SPUUpdater.m` 803–811), which is why
  the gate also has a lifetime.
- *The relaunch* is `NSWorkspace openURL` of the bundle path
  (`InstallerProgressAppController.m` 387–421): an ordinary launch.
- *The installer's jobs* are submitted with `SMJobSubmit` under
  `<bundle id>-sparkle-progress` and `<bundle id>-sparkle-updater`
  (`InstallerLauncher/SUInstallerLauncher.m` 60, 259, 278).

Options considered for the decision before the quit. (a) Run the alert
inside the postpone callback: the callback runs in a main-queue block
(the user driver dispatches the choice, `SPUUIBasedUpdateDriver.m` 421),
so a modal alert there would hold up the main queue and with it every
main-actor task, session output included, for as long as it is up. (b)
Ask in `updaterShouldRelaunchApplication` and answer no there: the same
block, and the hook Sparkle documents for postponing is the other one.
(c) Postpone always, decide on the next turn of the run loop in its
default mode (as the late loss alert does), then call the block: chosen.
A no is carried to the `updaterShouldRelaunchApplication` that the block
leads to. The quit itself is recognised by a gate opened in
`updaterWillRelaunchApplication` (just before the quit is sent) rather
than by looking at the quit event's sender, which would tie Armadale to
Sparkle's process layout; the gate closes with the cycle and after 60 s
in any case, so it cannot let a later ⌘Q through.

"Sessions that cannot survive a quit": the registry had
`localSessionsThatMayOutliveQuit()` (the persistent ones a quit leaves
to macOS) but nothing for the opposite. A session made by the persistent
runtime records its version (`RestorePolicy.isPersistent`), but one being
created has none yet, so the rule asks the controller instead: a local
session whose backend is `EphemeralBackend`, or a remote one whose client
carries a persistence note (the plain-ssh fallback), that may be running
(`CloseRisk.mayBeRunning`) and records no runtime version.

What a check sends was read in the source: the user agent
`<name>/<version> Sparkle/2.10.1` (`Sparkle/SPUUserAgent+Private.m`
18–38), `Accept: application/rss+xml,*/*;q=0.1`
(`Sparkle/SUAppcastDriver.m` 74), no query parameters without system
profiling. The system's URL loading adds its usual headers (it was not
measured which), hence the Settings line's "Besides what every web
request carries".

Not known and left for the live test (HANDOFF): what Background App
Activity switched off does to the installer's jobs (section 13).

**November 16, 2026, night. After the review.** The system profile: the
profile is sent when `SUSendProfileInfo` is true (`SPUUpdaterSettings.m`
349–352, read from Info.plist or the user defaults by `SUHost`'s
`boolForKey:`), at most weekly (`SPUUpdater.m` 1249–1263), as the entries
of `systemProfileArray` filtered by the delegate's allowed keys (1299–1315);
with an empty list the parameters are empty and the feed URL is returned
unchanged (1270–1278). `SUEnableSystemProfiling` only decides whether the
permission prompt offers the checkbox. A no left standing: Sparkle asks
`updaterShouldRelaunchApplication` before the postpone hook on every
attempt (`SPUInstallerDriver.m` 515–519) and does not report the end of a
cycle whose next update is shown at once (`SPUUpdater.m` 810), so the no
is cleared as soon as it has been answered. The gate: one-shot, consulted
once per `applicationShouldTerminate` (Armadale's `terminate` override ends
sheets and calls AppKit's `terminate` once; SIGTERM calls `terminate` once;
End Sessions and Quit cancels its first quit and makes a second). The two
limits that remain (End Sessions and Quit between the yes and the quit;
Sparkle's retry, which is not reported again because of
`_notifiedDelegateInstallationWillFinish`, `SPUInstallerDriver.m`
551–554) are in DESIGN sections 8 and 13.

**November 17, 2026. The key.** The owner made the update key
(`generate_keys --account armadale`) and its public half went into
`project.yml` as `SUPublicEDKey`. Until then that line was a comment
and no build started the updater, by the rule that still holds for a
build without the key (Part 1, "the update key exists").


## 9. Keyboard shortcuts

**Step 7: the ⌃⌘A row.** The table's row "⌃⌘A ✱ | Next pane needing
attention" was marked "(step 7)": Window › Next Pane Needing Attention was
added in step 7.

**October 29, 2026: the table moved to Help.** The read‑only shortcut
table is shown under Help › Keyboard Shortcuts; it was in Settings until
October 29, 2026.

**Step 4 notes: menu key equivalents.** Every row is an `NSMenuItem` key
equivalent (built in `App/MainMenu.swift`), so the shortcuts appear in the
menus and work whatever has focus, and keys not bound there reach the
terminal. Since step 5 the table shown in the app, Help › Keyboard
Shortcuts, is generated from these menu items. Since step 5 the font size
that ⌘= / ⌘- / ⌘0 change is the stored Appearance setting, so it persists
across launches. ⌘, opens Settings (step 5). Window › Clear All Attention
is a step 7 command.

**October 30, 2026: Show Tab commands hidden.** Show Tab 1…8, Show Last
Tab and Show Tab Group 1…9 are hidden commands of the Window menu by the
owner's decision of October 30, 2026: eighteen rows crowded it; the tab
bar shows ⌘N and the sidebar ⇧⌘N instead. Their key equivalents work and
the table lists them, but as they are not visible menu titles, rebinding
them in System Settings › App Shortcuts was not checked.

**October 24, 2026: keys in an empty pane.** In an empty pane (section 8,
"New sessions") Return opens the New Session dialog or starts the
selected favorite, ↑/↓ select a favorite and Escape cancels; the dialog's
Return is Start. No menu item was added or rebound.

**Step 7: ⌃⌘A checked free.** Window › Next Pane Needing Attention is
⌃⌘A. It is free in this table, in Ghostty's macOS defaults (checked
against `src/config/Config.zig`: Ghostty binds ⌃⌘ only with arrows, `=`,
`f`, `[`, `]` and ⇧⌃⌘J) and in macOS's own shortcuts.

---

## 10. Agent sessions

**November 14, 2026. Attention from tabs not visited since a relaunch.**
Until every live restored session was attached after launch, a restored
session had no client until its tab was first shown, so its bell or OSC
9 / 777 never reached `AttentionCenter`. Tested now with a real SwiftTerm
surface in no window: both reach it.

**October 24, 2026: no default "just a shell".** A pane runs whatever the
New Session dialog chose; until October 24, 2026 it was "just a shell" by
default.

**October 24, 2026: per-session options.** The per-session options the
dialog offers for the agents Armadale knows, as a flag table in
`AgentIntegration` (section 8, "New sessions"), were added on October 24,
2026; checked against `claude 2.1.304` and `codex-cli 0.163.0`.

**Step 7: what was built.** The subsection "Attention and notifications"
was headed "Step 7: what was built": the attention rule
(`AttentionTracker`), the attention center, notifications
(`NotificationService`, `UserNotificationService`, `NotificationPolicy`)
and the notify helper were built in step 7.

**Step 7: Dock badge permission, verified live.** On macOS 27 an app
registered with UserNotifications only shows its Dock badge while its
"Badge application icon" setting is on. (Verified live: a plain process's
`NSDockTile` badge shows without any permission; Armadale's did not until
the setting was on.) Seen again on November 14, 2026 on another Mac: no
badge with attention pending while the permission prompt was unanswered,
and the badge once the owner had allowed notifications (Part 1, "the
Dock badge and notifications, checked live").

**Claude Code hooks without a terminal, verified live.** Hooks
(`hooks.Stop`, `hooks.Notification`, … in settings) run commands. Verified
live: Claude Code runs hook commands in a session of their own **without
a controlling terminal** (`/dev/tty`: "Device not configured"), while
`claude` itself is on the pane's terminal.

**zmx replays focus reporting, checked.** zmx replays `ESC[?1004h` to a
reattaching client (checked with zmx 0.8.1: a session that had enabled
it, attached again, received it in the replay), so this survives a
relaunch.

**Codex BEL derived, not run.** So Codex rings BEL on turn completion and
approval requests exactly when its pane is not looked at, which is when
Armadale sets attention. (Not run against a real Codex turn, which would
use the user's account; derived from the source above.)

**Codex command-line overrides tried and dropped.** Command-line overrides
(`-c tui.notification_method=…`) were tried and dropped: Codex 0.163.0
then runs "without the shared background server" (a warning on every
launch, and no `codex agents` or remote control).
`tui.notification_method = "osc9"` is offered as an optional user setting
in the Configure… sheet instead.

**Codex `notify` not set on the command line.** `notify` is a single
command, so setting it on the command line would replace the user's own
`notify` (this Mac's user has one for another tool): it is offered only as
an optional hook.

**The notify helper, tested.** `armadale-notify` was tested on a real
pseudo-terminal (`script`), also with the helper detached into a session
of its own (`setsid`), and live from a Claude Code `SessionStart` hook
passed with `--settings`.

---

## 11. Repository layout

**November 14, 2026. `AppDelegate` and the rest of `SessionRegistry`
split.** As the architecture review's second pass asked, `AppDelegate`
(1,157 lines) was split into its main file and `AppDelegate+Launch`,
`+Quit`, `+MenuBar`, `+Windows`, `+Actions`, `+Attention` and `+Saving`, and
`SessionRegistry` (811 lines) gained `SessionRegistry+Ending` and
`SessionRegistry+Status`. Mechanical: code moved between files in
extensions, with `private` dropped only where a move across files needed
it; no behaviour changed. Checked three times against 7353b3a, by the
implementer as multisets of lines, and by the coordinator and the
reviewer each with a comparison that keeps order (every line of every
new file is in the old file in the same order; every member of the old
files appears whole and contiguous in the new ones): the only
differences are the extension wrappers, imports, the new files' header
comments, the registry's comment listing its files, and 36 dropped
`private`s, all in `AppDelegate` (22 stored properties, 13 methods and
the file's logger).

**November 14, 2026. The registry split.** `Sessions/` gained
`PaneViewStore`, `SessionRegistry+LaunchAttach`, `SessionRegistry+Remote`,
`SessionRegistry+Delegate` and `GridSizeRecorder`; `ArmadaleSessions`
gained `LaunchAttachPlan` (with `LaunchAttachQueue`), beside
`RestorePolicy`, whose `mayRespawnUnshown` went with the second paths.

**Steps 4–8: `ArmadaleAppTests` grew step by step.** `ArmadaleAppTests`
(step 4) tests the app target's own code: the split tree view with real
SwiftTerm surfaces, the close-confirmation rule, and window controller
lifetime; since step 5 also `Preferences` (each test in its own defaults
suite, removed afterwards), `ThemeCatalog`, the shortcut table, settings
reaching existing panes, the renderer switch and the Settings window;
since step 7 the attention center (with a fake notification service),
status precedence, notification policy, bells and OSC 9/777 fed to real
surfaces reaching it, and the notify helper on a pseudo-terminal; since
step 8 the quit decision, the running-session count, End Sessions against
a recording backend, system quit events, the menu bar wording and the
status menu's items.

**Step 6: remote backend tests.** Since step 6 the remote backend is
tested three ways: with a scripted `FakeTransport`, with a
`LoopbackTransport`, and against a real host when `ARMADALE_TEST_SSH_HOST`
is set.

**October 2026: the app icon chosen.** App icon: "Panes", chosen from six
concepts and ten shape variants in October 2026. No cursor, sparkle or
network glyph, by decision. The lit coral is meant to become the in-app
attention colour as well; today the badge and status glyphs use their own
colours (open item).

**Step 9: Release signing.** Release builds are signed with Developer ID
by the release pipeline built in step 9.

### Release pipeline

**October 19, 2026: decisions.** Decisions (October 19, 2026): team
**YJ8LXVCB3T** (an individual Developer Program enrolment; Gatekeeper
names "Donny Kurniawan"); **no updater** and **no crash reporting** in v1
(the repository is private, so a Sparkle feed has nowhere public to live;
macOS keeps crash reports under `~/Library/Logs/DiagnosticReports`); the
artifact is a **notarized, stapled DMG**.

**Step 9 plan: signing settings.** The plan: Debug keeps "Sign to Run
Locally" (`CODE_SIGN_IDENTITY = -`); Release signs with `Developer ID
Application` (manual style), hardened runtime, secure timestamp;
`embed-zmx.sh` already follows the build's identity and hardened flag.

**Step 9 plan: the DMG with `hdiutil`.** Step 4 of `scripts/release.sh`
as planned: build the DMG from the stapled app with `hdiutil` (volume
"Armadale", the app and an `Applications` symlink, UDZO), sign the DMG
with the same identity, notarize it the same way, staple it. (Since
November 2026 the DMG is built with dmgbuild and has a designed Finder
window; see "The DMG window" below.) Step 5 as planned: final checks,
output `build/release/Armadale-<MARKETING_VERSION>.dmg`; print the
suggested `git tag v<version>` command rather than tagging. The script
now suggests an annotated tag.

**October 23, 2026: `scripts/bump-build.sh`.** `scripts/bump-build.sh`
(October 23, 2026) raises the build number by one, or sets it and the
marketing version, and can commit the bump from a clean tree.

**Build number: commit hash rejected.** The build number stays an
integer: a git commit hash was considered and rejected, since
`CFBundleVersion` is compared numerically by Launch Services and by
updaters.

**November 14, 2026: state file check.** Before a release,
`scripts/check-state-compat.sh` must pass (added November 14, 2026).

**Implementation (step 9): where the build differs from the plan.** Where
the build differs from the plan above, or adds to it:

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
  `--timestamp`. On this Mac the first Developer ID signing raised no
  keychain prompt.
- *Architectures.* The app and `ctty-exec` are arm64 only (macOS 27 has no
  Intel support); `Contents/Helpers/zmx` stays universal.
- *Profile action.* The scheme's Profile action builds Release, which now
  needs the Developer ID certificate and carries no `get-task-allow`.
- *`release.sh` additions.* A preflight, before anything is built; the
  identity resolution and `ARMADALE_SIGNING_IDENTITY`; the tag check and
  `--allow-existing-tag`; the archive's own DerivedData under
  `build/release/` and `build/release/archive.log`; a secure timestamp on
  each of the three signatures and one signer for all three; the DMG
  checked with `codesign --verify --strict` and `hdiutil verify`; the DMG's
  file system HFS+; the `-pending` name and the rename after the final
  checks; every check failing with a message rather than ending the script
  silently under `set -e`. These were additions to the plan in step 9.
- *`--skip-notarize`* still signs the DMG and runs the Gatekeeper checks,
  names it `Armadale-<version>-unnotarized.dmg`; the suggested tag is an
  annotated `git tag -a v<version>`; the notary log is fetched for
  accepted submissions too. Additions in step 9.
- *`hdiutil` on macOS 27* prints a deprecation warning for `create`;
  `hdiutil` still works and was kept in step 9. dmgbuild, added later,
  also runs `hdiutil create`, `attach` and `convert`, and each prints the
  same kind of warning on stderr.

**November 2026: the DMG window.** A deviation from the plain DMG of
step 4: opening the DMG shows a laid-out Finder window instead of two
icons on white, built with dmgbuild. The brief put the caption at about
y 300; the icons' labels occupy about 268–286, so 320 keeps a clear gap
under them. The DMG keeps HFS+ as before.

**November 2026: the DMG window, checked without a Finder window.** The
`.DS_Store` contents (window bounds, view options, icon positions,
background reference) are checked by parsing the file with the
environment's `ds_store` module; how Finder actually draws the window has
to be looked at by opening the DMG.


**November 16, 2026. The updater in the pipeline.** Sparkle's helpers
ship ad hoc signed with the hardened runtime; notarization needs them
signed with the Developer ID, the runtime flag and a timestamp, which
Xcode's sign-on-copy does not do for code inside a framework and which
`release.sh` (no `-exportArchive`) would not get either. Sparkle's
documentation shows a run-script phase "after copying the Sparkle
framework" that removes the XPC services and re-signs, for install builds
only; Armadale's phase runs in every configuration so the Debug bundle
has the same shape. It embeds the framework itself (Part 1, "an updater,
with Sparkle", found (a)). The preflight signs a scratch file with the
keychain's key and verifies it against `project.yml`'s public key, so
that a missing or mismatched key fails before the archive and before
anything goes to Apple; the final signature is verified against the
public key read from the built app, the one installed copies hold.
`scripts/ed25519-verify.swift` uses CryptoKit, so no tool reads the
private key for verification. No option reads the private key from a
file (Sparkle's `--ed-key-file` exists; the release uses the keychain
only). The feed's items are generated, never hand-written, and their
release notes come from the changelog page, so the text exists once.

**November 17, 2026. The first release through it.** 0.1.2 was the
first release with a feed item. The script test of `AppcastTests` had
inserted its sample into a copy of the real feed, which holds a real
0.1.2 (30) since then; it now starts from the feed as it was before
its first item (Part 1, "Armadale 0.1.2, released").

---

## 12. Build order

**October 16–24, 2026: how the steps were built.** Each step was built by
an implementer agent, reviewed by a separate reviewer agent (code reading
plus live keystroke checks of the running app), fixed, verified with the
full build and test command, and committed on `main`. Steps 1–7 are done:
d0c4587, 93019d8, f6cedbb, 76a4e4e, 4d3ab86, 7302a12, dac547f (October
16–18, 2026); steps 8 and 9 on October 19; step 10 (added later at the
owner's request) on October 24. The build order is complete.

**The plan, step by step.**

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
10. **New Session** (owner's request, October 24, 2026; section 8, "New
    sessions"), in three sub-steps, each through the loop: **10a** the
    model (empty panes, `SessionOptions`, `Favorite`, `startSession`, the
    favorite intents, `ShellWords`, and, moved forward from 10b, the option
    flag table) and the removals (the two
    File items, the "+" context menu, General's defaults), with the app
    still starting a shell in every new pane through `startSession` so it
    stays usable; **10b** the New Session dialog and Settings › Favorites;
    **10c** the chooser in every new pane, Cancel's cascade, restore of
    empty panes, and the README; the repair then also turns a pane whose
    `sessionID` names a missing session into an empty pane showing the
    chooser (until then it was kept and showed the blank view). *Done*
    (October 24, 2026).

---

## 13. Risks and open points

**November 14, 2026: the background switch, detected.** The open point
of October 19, 2026 (what to do about Armadale switched off under what
is now called Background App Activity) was decided for "detect and
tell" (section 8, "Background App Activity"): the loss is found at the
next launch and the user told, not prevented. The `SMAppService`
prototype stays untested; it could at best tell the app before a loss.

**November 14, 2026. Attaching every restored session at launch.** The
risk was recorded with the change: the cost of hidden attached sessions
(harness figures), sshd's `MaxSessions`, and a stopped daemon's client
that exits being resolved as ended.

**October 31, 2026: pane headers preference deferred.** Pane cards
(section 8) always show their header row in the first version; a "Show
pane headers" preference that keeps the cards and gutters but drops the
row is deferred by the owner's decision.

**Step 10: the empty pane's focus.** The chooser adds one more "pane
without a terminal" state whose focus and first-responder behaviour must
match the placeholder's (the Return bug fixed on October 23, 2026 came
from exactly that gap). Step 10c makes the empty pane first responder on
every focusing path and tests it (`NewSessionChooserTests`); the live
check is the reviewer's.

**November 14, 2026: old builds and a future helper version.** The risk
"Old builds and a future helper version" was recorded on November 14,
2026, not solved.

**Step 3: replay fidelity.** Anything odd in the replay shows up in step 3
and is the earliest signal that a different renderer is worth building.

**October 23, 2026: lost exit codes resolved.** Lost exit codes (resolved
October 23, 2026). zmx discards the program's exit status; a recorder
around the program now writes it next to the session (section 4, Ended).
Still unknown: sessions created before this version (no recorder).

**October 19, 2026: a Ghostty-based renderer evaluated.** A Ghostty-based
second renderer over `Lakr233/libghostty-spm` (the one wrapper with
host-fed I/O) was evaluated on October 19, 2026 and is recorded as a
pending decision in `HANDOFF.md`.

**October 19, 2026: macOS 27 background attribution.** The Dock's "Stop
Running in Background" item sends SIGTERM to every session process at once
(verified live on October 19, 2026: one click ends every session).
Disclaiming responsibility at spawn
(`responsibility_spawnattrs_setdisclaim` in `spawnOnPTY`) and starting the
work through `launchctl submit` were both tested and change nothing.
Decision (October 19, 2026): Armadale asks before quitting with running
sessions and otherwise stays in the menu bar (step 8, section 8); the
findings are in `HANDOFF.md`. Tested the same evening: menu bar mode
avoids the Dock indicator and its stop item, and no prompt appeared for a
quit from it (with a decision stored), but the stored allow decision
governs the sessions all the same.

**Step 9: Team ID and bundle identifier.** The Team ID YJ8LXVCB3T was set
in step 9; the bundle identifier `com.tinylittleapps.armadale` is a prefix
the owner chose, not a registered organisation name.

**November 16, 2026. The updater's risks** (section 13): what macOS 27
does to Sparkle's installer jobs with Armadale switched off under
Background App Activity is not known (no report in Sparkle's issue
tracker, design of that day); the feed URL compiled into every build;
the loss of the update key, with Sparkle's key rotation as the way out
(its documentation, "Rotating signing keys": a Developer ID signed DMG
is required for a key change with `SUVerifyUpdateBeforeExtraction`);
and a helper version bump reaching every install within a day.

**November 16, 2026 (night). The updater and Background App Activity,
seen** (section 13): in the live test an update installed with every
Armadale entry switched off (the plain quit in the same state ended a
session within two seconds): the bundle was replaced and the new build
was up within a second of the quit, and the two sessions were alive
half a minute later (Part 1, "the updater, checked live"). One run, on
ad hoc signed builds of 59 MB; a waiting installer
after Cancel was not tried in that state.
