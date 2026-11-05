# HANDOFF.md — where development stopped

Point-in-time status for whoever picks Armadale up next. Update this file
whenever work pauses. The durable rules for working in this repository are
in `AGENTS.md`; the design contract is `docs/DESIGN.md`; build and run
instructions are in `README.md`.

## Status (October 30, 2026)

Steps 1–10 of the build order (`docs/DESIGN.md` §12) are implemented,
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
| 9 Ship | cb63ef7 | Developer ID signing, `scripts/release.sh`, notarized stapled DMG |
| 10 New Session | 507a52a, 9168f0b, 18faf87 | empty panes, the New Session dialog, favorites, the chooser in every new pane (October 24, 2026) |

The app icon ("Panes": a graphite tile with three panes, the top-right
one lit coral) was added after step 7: `scripts/render-app-icon.swift`
generates the Icon Composer document, the asset catalog rasters and
`docs/icon/AppIcon.svg` from one geometric description. Concept and
refinement pages used to choose it are not in the repository.

After step 9, cf9305c added `scripts/install-release.sh`, which runs the
release pipeline and installs the app from the DMG into `~/Applications`.

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
(October 20, 2026). Then the **full-screen frame** fix (same day): the
frame is never recorded while a window is in full screen, `WindowState`
gained `isFullScreen` (decoding to false for older files, no schema
bump), a full-screen workspace comes back full screen at launch and
after menu bar mode, and a saved frame is clamped to a screen that still
exists (`docs/DESIGN.md` section 8, "Full screen" and "Saved frames and
screens"). Built with the implementer → reviewer loop and two live
passes.

October 23, 2026: the About panel puts "All rights reserved." on its own
line and unfocused panes are no longer dimmed, only the focused pane's
accent border remains (9e47bee, owner's request). Then **a clean exit
closes the pane** (same day, implementer → reviewer loop, two live
passes, Lima VM for the host side): an exit recorder sits between the
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
was **withdrawn** the same day (open items, Hierarchy and UI).

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

Then (October 23, 2026, evening, implementer → reviewer loop, three
live passes) **a clean exit closes a workspace's only pane too**: the
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
name); the site under `site/` served by GitHub Pages with the DMG as a
GitHub Release here (`releases/latest/download/Armadale.dmg` as a stable
link); Namecheap DNS (A records to GitHub Pages, `www` CNAME, domain
verification TXT) and Enforce HTTPS, which a `.dev` domain requires; a
notarized DMG from a full `scripts/release.sh` run, since the installed
build is made with `--skip-notarize`. The repository visibility change
is the owner's to flip.

ac7094b removed GitHub Actions: there is no CI. Every commit was made after
the full local build and test command passed (452 tests at dac547f, zero
warnings; 467 from step 8 on; 523 at the clean-exit change; 545 at the
empty-workspace change; 551 at the last-pane change). The working tree was clean and nothing was
running when work paused (October 19, 2026, evening).

**Releases.** Armadale 0.1.0 (build 1) was built, notarized and stapled
on October 19, 2026 from 72cf014 and installed to `~/Applications`
(untagged). Armadale 0.1.0 (build 2) was built, notarized and stapled by
`scripts/install-release.sh` on October 23, 2026 from 524c9da (both
notary submissions accepted) and installed to `~/Applications`, replacing
build 1; it is tagged **`v0.1.0`** (annotated, pushed). The build number
is raised with `scripts/bump-build.sh` before each release. The DMG is
not kept in the repository (`build/` is ignored and wiped by the script).

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
additive decoding. Order: 10a model and removals, 10b dialog and
Settings › Favorites, 10c the chooser; each through the implementer →
reviewer loop. The owner gave the go-ahead for all of step 10 on October
24, 2026 and asked only to be told when the Mac is needed for live UI
work (10c; 10a and 10b were done code-only, no app launch).

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

Other candidates, each needing an owner decision:
the Ghostty second renderer (below), the open items below, a public home
for an update feed, and what step 8 should say or do about macOS 27's
"Allow in the Background" switch, which ends every session a few seconds
after any quit when it is off, from the menu bar too (tested October 19,
2026, evening; "macOS 27: Allow in the Background switched off" below).
The owner deferred that last decision on October 19, 2026; it is an
open item, not started.

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
- One unexplained rendering glitch: a Claude Code prompt once showed a
  colour code as literal text (`185;249m`) after a replay. Not reproduced.

Hierarchy and UI
- One extra SIGWINCH reaches each pane after relaunch (harmless at a
  prompt; full-screen programs redraw once).
- Full screen (October 20 and 23, 2026): every toggle goes through
  `FullScreenSerializer`, one at a time. The stall trigger is narrower
  than before (closes, refused toggles and reported failures all end
  their step; only a transition AppKit never ends, for which no live
  trigger was found, would stall it) but the effect is wider: every
  later toggle Armadale makes would wait, including menu bar mode's
  exits, so a full-screen window would never be ordered out. No
  timeout exists. Entries never retry: a refused or failed restore
  entry leaves the window normal, saved as not full screen. ⇧⌘W on a
  full-screen window bypasses the serializer (known gap, benign when
  tried: closed, nothing stuck; DESIGN section 8). A hand toggle during
  a serialized step can still overlap it.
- Inline rename (October 20, 2026): in one of seven runs of a chained
  rename (a group from the sidebar's context menu, then a tab from the
  tab bar's), the first keystroke typed 0.4 s after Return was lost;
  six further runs lost nothing. Not reproduced; watch for it. Return
  on a selected sidebar row does not start a rename (the List never
  has keyboard focus); only double-click and the context menu do.
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
- Empty workspaces (October 23, 2026), predating the change: a Dock
  click does nothing while the Settings window is the only window and
  no workspace exists (`hasVisibleWindows` is true; ⌘N works); a
  session record in a hand-edited state file that no pane refers to
  survives a launch and keeps its daemon alive (orphan reclaim counts
  `model.sessions`; real empty workspaces never hold sessions). Not
  tested live: menu bar mode with zero workspaces (it needs running
  sessions, which a deleted workspace cannot have; the code falls back
  to `newWindow`).
- Clean exit (October 23, 2026): on hosts a shell that exits
  right after an interrupted command (`$?` 130) keeps its placeholder,
  because `$?` cannot tell that from a death by SIGINT (documented,
  DESIGN section 4). A recorder killed by SIGKILL or ended by a reboot
  leaves no record, so that pane shows "is no longer running." and
  stays.
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
- Not exercised live: a real logout, restart or shutdown (the quit
  event's reason is unit-tested with synthetic events only); a
  notification click reopening from menu bar mode (code path only);
  End Sessions and Quit against a slow or unreachable remote host; the
  persistence fallback mode; window order with several windows on
  return; macOS hiding the status item; the light menu bar.
- Tested October 19, 2026, evening ("macOS 27: Allow in the Background
  switched off", below): a quit from menu bar mode shows no first-quit
  prompt and leaves no Dock item, but with Armadale switched off under
  Allow in the Background macOS ends every session 5 s after that quit
  (1 s after a regular quit such as SIGTERM). Under Allow nothing is
  touched. The app cannot read that setting; what the quit alert, the
  status menu and the README should say about it is an owner decision,
  deferred on October 19, 2026 (open item).
  Whether launchd lists the session daemons under Background App
  Activity after a quit is still unknown (needs root or the System
  Settings UI).

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
  harmless. What the disallowed state does was **tested on October 19,
  2026 (evening)**: macOS ends every session process 1 to 5 s after any
  quit, from the menu bar too (section below). The prompt's own Don't
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

### macOS 27: "Allow in the Background" switched off — tested, October 19, 2026 (evening)

The two prompt cases left open above were tested with the Debug build of
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

### The `ctty-exec` helper, for orientation

Documented in README ("The `ctty-exec` helper") and `docs/DESIGN.md`
section 7; summarised here because the two items above both touch it.
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

## State of this Mac that matters

- Background App Activity: on October 19, 2026 the owner answered
  **Allow** to the first-quit prompt for `com.tinylittleapps.armadale`,
  so the prompt will not appear again on this Mac (`sudo sfltool dumpbtm`
  shows the record). The switch under System Settings › General › Login
  Items & Extensions › Allow in the Background was turned off for the
  evening's tests and **is on again**; off means every session is ended
  a few seconds after any quit (above). A Desktop-folder privacy denial
  was recorded for the deleted path
  `/tmp/armadale-bgtest/bin/ctty-exec-0.1.0` during the disclaim test;
  harmless.
- Notification permission for `com.tinylittleapps.armadale` is granted in
  System Settings (done during step 7 testing); notification
  authorization is per bundle id, so it covers ad-hoc and Developer ID
  builds alike. Privacy (TCC) grants keyed by code requirement, and
  macOS 27's stored background decision, may differ between the two.
- The Developer ID certificate for team YJ8LXVCB3T expires on February 1,
  2027; the notarization keychain profile is `armadale-notary` (created
  by the owner on October 19, 2026; the notary history under that account
  lists the accepted submissions). Debug builds never need either.
- `~/Applications/Armadale.app` is whatever the owner last installed with
  `scripts/install-release.sh` (0.1.0 build 4 was bumped on October 23,
  2026, after the clean-exit change and before the empty-workspace one;
  `--skip-notarize --allow-existing-tag` builds a local, signed but
  unnotarized copy of a version whose tag exists). It has a different
  code identity from Debug builds, so privacy prompts from inside its
  sessions may appear once more; it uses the real state directory
  (`~/Library/Application Support/Armadale`), never a test one. Do not
  replace it or run it during tests without the owner's say-so.
- The Lima VM `default` is stopped and has no `~/.armadale` inside it.
- Claude Code 2.1.292 and Codex 0.163.0 are installed; `docs/DESIGN.md`
  §10 records what each offers and the source lines consulted. Re-check
  when either is upgraded.
