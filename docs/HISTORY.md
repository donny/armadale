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

## November 14, 2026: the documents split

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
the contract keeps every behaviour and only its history left. Whether
an agent may read only the sections it changes is the owner's rule to
relax (`HANDOFF.md`, open items, "The documents"). On the Mac used
that day there was no installed Armadale, no Lima and no Codex
(`HANDOFF.md`, "State of this Mac that matters").

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

- **November 14, 2026. Stopped daemons are not listed.** A stopped daemon
  (`kill -STOP`) is left out of a listing that still succeeds (checked
  November 14, 2026: `ls --short` exited 0 in about 1 s and printed nothing
  for it). This is why `OrphanReclaimer.Plan` also spares sessions whose
  socket exists (`ZmxRuntime.sessionsWithSockets()`), and why
  `ZmxRuntime.aliveForHousekeeping` counts them as alive.
- **Spared sessions not shown yet.** Spared sessions are not shown
  anywhere yet; they keep running until their programs exit.


## 5. Terminal rendering: `TerminalSurface`

**Implementation (step 5). Renderer registry and selection.** Step 5
built `SurfaceRegistry` (in `TerminalSurface`), with `SurfaceFactory`s
keyed by a persisted identifier (`swiftterm` the only one and the
default), `SurfaceRegistry.standard` in the app, new surfaces made
through the factory named by the `rendererID` preference, and
`SessionController.replaceSurfaceOnNextAttach(_:)` for existing panes.
In the same step `TerminalTheme` gained an optional
`selectionForeground` (from Ghostty themes), which SwiftTerm cannot use.

## 6. Remote hosts

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

## 7. Process plumbing (`ArmadaleSessions`)

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

**The pane's appearance for its theme.** A pane with its own theme sets
its view `appearance` to suit the theme's background so the placeholder
card and the New Session chooser stay legible (seen live: an empty pane
on Armadale Light in dark mode showed a dark card with faded text before
this). The lighter context menu of a light-themed pane in dark mode was
accepted as cosmetic in the first version.

### Pane cards

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
the setting was on.)

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
