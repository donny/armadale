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
  Deleting a workspace (explicit, confirmed) kills its sessions. Since
  October 23, 2026 **a tab group is never kept without tabs, and a
  workspace is never kept without tab groups**: closing or moving away a
  group's last tab removes the group, and removing a workspace's last group
  deletes the workspace (section 8), even the only one, so the app may be
  left with no workspace at all. Loading applies the same rule to older
  files (section 3), so a closed workspace in the sidebar always has tab
  groups.
- **Tab Group** — a named folder of tabs. The tab bar always shows the tabs
  of the selected tab group.
- **Tab** — a layout of one or more panes. Its title defaults to the focused
  pane's session title and can be renamed.
- **Pane** — a rectangle in the tab's split tree. A pane has exactly one
  session, or none yet: since October 24, 2026 a new pane starts **empty**
  and shows the *New Session* chooser (section 8, "New sessions") until
  the user picks a favorite or fills in the New Session dialog, so the pane
  tree is the session layout plus the panes still being decided.
- **Session** — the persistent thing: a working directory, a launch profile
  (shell, command, Claude, Codex…), a location (local or an SSH host), and a
  runtime state. Sessions are only ever created by Armadale; it never adopts
  sessions created elsewhere. A **favorite** is a saved recipe for one
  (profile, location, directory, options, and a name); starting it creates
  a fresh session every time.

### Sidebar semantics

The sidebar is app-global and identical in every window. It lists every
workspace, with the current window's workspace expanded; the window's
shown path (its workspace, the tab group it shows, that group's selected
tab) is in semibold.
Clicking another workspace brings that window to front, or opens it if its
window is closed. Under a workspace: tab groups, and under each tab group its
tabs. Panes are not listed; a tab row shows a status summary of its panes.
A tab group row of the current window's workspace ends in its shortcut,
⇧⌘1…⇧⌘9 for the first nine groups (owner's decision, October 30, 2026,
in place of the group's tab count; other workspaces' groups show nothing
there, since ⇧⌘N acts on the key window's workspace).

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
attention also get a purple tint in the tab bar (the sidebar title is not
emphasised: semibold there means the shown path, below), and workspace and
tab group rows show how many of their panes need attention.

A closed workspace is dimmed with a "reopen" icon. **The sidebar has no selection
and no highlight** (owner's decision, October 29, 2026): the `List` has
no selection binding, so no row is ever drawn selected, gray or blue.
The step 4 highlight on the shown tab group's row, and then the
shown-path highlight of the same day, both kept leaving the List with
the keyboard or the wrong row highlighted. Where the window is shows in
the semibold titles and icon colours below. Rows are
acted on by tap gestures, as the tab bar's tabs are: a click anywhere
across a row acts on it, a double-click (a double-tap gesture) renames
it, and each row has its own context menu. A click on a row of the
window's shown path (its workspace, the tab group it shows, that group's
selected tab) writes nothing to the model (no select, no save). The List never takes
keyboard focus from a click: SwiftUI's `.focusable(false)` on it does
not stop the outline view behind it from becoming first responder, so
`WorkspaceWindow.makeFirstResponder(_:)` refuses any table or outline
view inside the sidebar (seen live: the outline view took the keyboard
on every row click without it; `SidebarFocusTests`). Since the list then
never takes focus away from an open rename field, a mouse down in the
sidebar outside a rename field commits the window's open rename
(`WorkspaceWindow.sendEvent(_:)`, as `TabBarHostingView.mouseDown` does
for the tab bar), hit-tested from the window's frame view so the title
bar's controls and a window drag above the sidebar do not count. With
no selection and the outline view refused, arrow keys and Full Keyboard
Access no longer reach sidebar rows (owner's decision); each row is an
accessibility button whose default action acts on it, with a Rename
action, for VoiceOver (not checked live). **Title weight and icon
colours** (owner's rules, October 29 and 30, 2026; `SidebarShownPath`,
unit-tested). A window's *shown path* is its own workspace, the tab group
it shows and that group's selected tab. Those three rows' titles are
semibold in every window, active or not, so an inactive window still says
what it shows; every other title, the window's other groups and tabs and
the other workspaces included, is regular. In a window that looks active
(SwiftUI's `appearsActive`: key, or main under a panel) the shown path's
icons are accent-coloured; every other icon is gray, and in an inactive
window every icon is gray, so blue alone says which window is active.
Until October 29 the sidebar List tinted every icon blue in the key window
and gray otherwise, and the current workspace's icon was blue in every
window; until October 30 only the current workspace's row was semibold
(in every window) and a tab needing attention was semibold wherever it
was (owner's decision: semibold means the shown path and nothing else;
attention keeps ◐ and the purple counts). The colours are `Color`
values: the hierarchical `.secondary` inside a sidebar label is a level
of the list's tint and still reads blue in an active window. Rows: a
click on another workspace shows or opens its window (on the current
workspace's row it does nothing); on a tab group or tab, selects it
(bringing its window to front if it belongs to another workspace). Double-click, or the row's
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
filing). Moving a group's last tab away removes the group, as closing that
tab would, and the workspace too when it was its last group (its window
closes). If the emptied group was the one the window showed and the target
is in the same workspace, the window shows the target group. (Since October
23, 2026; until then the emptied group was kept and showed an empty state
with New Tab. The repair after every load drops such a group, so that
state and ⌘W closing it without asking remain only as defensive code,
should one appear.) The first click of a double click on a row of another
workspace brings that workspace's window forward, so the edit happens in that
window's sidebar, where the keyboard now is; Rename chosen from a context
menu edits in the window it was chosen in. When the window brought forward
covers the spot clicked, the second click lands in that window instead and
no edit starts (seen live, October 29, 2026, with two overlapping windows;
the context menu's Rename works there). (Renaming used to be a sheet;
inline editing replaced it, and the Workspace menu's three Rename items
went with it.)

Closing asks first (unless turned off) when a session may be running:
running or disconnected, or *starting* when a process may exist: a session
restored from an earlier run before the launch probe has answered, or one
whose start is under way. A session created in this run whose pane was
never shown has no process and does not ask. Unreachable (unavailable)
sessions always ask (`CloseRisk`, unit-tested). When the close removes the
workspace's last tab group, and so the workspace (section 8), the question
ends with "The workspace “<name>” will be removed too."
(`WorkspaceActions.closeConfirmationText`, unit-tested, with
`AppModel.workspaceRemoved(byClosingPane:)`, `…Tab:`, `…TabGroup:`); this
never adds a question where none would be asked.

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
    var sessionID: SessionID?              // nil: empty pane showing the New Session chooser
    var themeID: String?                   // the pane's own theme; nil: Settings (October 30, 2026)
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
    var options: SessionOptions?           // the dialog's per-session choices; nil for older files
}

struct SessionOptions: Codable, Sendable {  // what the New Session dialog adds to a profile
    var skipPermissions: Bool              // Claude: --dangerously-skip-permissions; Codex: --dangerously-bypass-approvals-and-sandbox
    var continueConversation: Bool         // Claude: --continue (Codex has no flag; ignored)
    var model: String?                     // --model <m> for either; nil: the agent's default
    var sandbox: String?                   // Codex: --sandbox <mode>; nil: default
    var additionalArguments: [String]      // appended last, for any profile with a program
}

struct SessionRequest: Codable, Sendable { // the dialog's result; a favorite minus its name
    var location: Location
    var profileID: ProfileID
    var workingDirectory: String           // "" or "~": home; remote paths are the host's
    var options: SessionOptions
}

struct Favorite: Identifiable, Codable, Sendable {
    let id: FavoriteID
    var name: String
    var request: SessionRequest
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

*October 24, 2026:* a session's arguments are the profile's
`launchArguments` (its own plus the attention integration's), then the
`SessionOptions` the New Session dialog chose
(`AgentIntegration.arguments(for: options)`, a data table per agent that
is re-checked against the installed agents like the rest of section 10;
nothing for a shell or a `.command` profile except `additionalArguments`),
then `additionalArguments`. The options are recorded on the session
(`Session.options`), so **Respawn** composes the profile as it is then with
the session's own options (`launchForRespawn(of:)`), and an older file's
session without options respawns as before. `Favorite`s are saved with the
layout, in the order the user keeps them in Settings › Favorites; a
favorite whose host or profile is gone is kept and shown as broken
(`AppModel.favoriteProblem(_:)` says why) until edited or removed.

*Implementation (step 10a).* What the code names and decides beyond the
above:

- `Pane.sessionID` is optional (`Pane.isEmpty`); `Pane()` is an empty
  pane. `SessionOptions`, `SessionRequest`, `Favorite` and `FavoriteID` are
  as listed; every `SessionOptions` key and a request's `workingDirectory`
  and `options` may be absent when decoding. A blank `model` or `sandbox`
  adds no flag.
- The flag table is `OptionFlags` (`.claudeCode`, `.codex`, with Codex's
  `sandboxModes` for the dialog's picker) on `AgentIntegration.optionFlags`;
  `AgentIntegration.arguments(for:)` emits skip permissions, continue,
  sandbox, model, in that order, and nothing for an option the agent has no
  flag for. It was built in 10a with the model rather than in 10b.
  `Profile.launchSpec(options:)` composes `launchArguments` + those flags +
  `additionalArguments`; **a profile without a program (the login shell)
  ignores every option, the additional arguments included** (a login shell
  is started with no arguments), and `nil` options give `launchSpec`.
- `startSession(in:request:)` resolves the directory: blank or `~` is
  `defaultWorkingDirectory` locally and `~` on a host; locally a leading
  `~/` is expanded against `defaultWorkingDirectory`; anything else is kept
  as typed, with surrounding whitespace trimmed (locally and on a host). `requestProblem(_:)` is the check behind both `startSession`'s
  refusal and `favoriteProblem(_:)` (host first, then profile).
- Favorites: `addFavorite(_ favorite: Favorite) -> FavoriteID` (a taken ID
  gets a new one; the name is trimmed; a blank one becomes
  `proposedFavoriteName(for:)`, made unique with " 2", " 3"… among the
  others, while a name the user typed is kept even if another favorite has
  it); `updateFavorite` cleans the name the same way; `moveFavorite(_:to:)`
  counts the index after removal, like `moveTabGroup`. `proposedFavoriteName`
  shows the local home as `~` (`~/work`), never abbreviates a remote path,
  and says "Session" / "Host" for a missing profile or host.
- Lookups added: `pane(_:)`, `emptyPaneIDs(in:)` (a workspace's empty panes
  in tab and layout order). An empty focused pane titles its tab "New
  Session" (`displayTitle(for:)`). The repair also drops duplicate favorite
  IDs and keeps broken favorites.
- `ShellWords.split` splits like a shell, simplified: no variable
  expansion, globbing or command substitution, and inside double quotes
  only `\"` and `\\` are escapes (`"\$HOME"` stays `\$HOME`; a
  backslash-newline is not joined). It closes an unterminated quote at the end of the text
  (what was typed is kept rather than the line refused, since the field has
  no error state), keeps a trailing lone backslash, makes `''` an empty
  word, and expands nothing.

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
profile). *October 24, 2026:* the default profile and directory
preferences are gone with the chooser (below); `newWorkspace`, `newTabGroup`,
`newTab(in:)` and `splitPane` now create an **empty pane**
(`Pane.sessionID == nil`) and no session, `newTab(in:onHost:profile:)` is
removed, and `startSession(in: PaneID, request: SessionRequest) ->
SessionID?` creates the session (refused, returning `nil`, for a pane that
already has one, a request naming a missing profile or host, or a pane that
is gone) and binds the pane to it. `closePane` on an empty pane removes it
like any other, cascading tab, group and workspace as section 8 describes,
with no session to end. Favorites: `addFavorite(_:)` (a blank name becomes
one made from the request, as the dialog proposes), `updateFavorite(_:)`,
`removeFavorite(_:)`, `moveFavorite(_:to:)`, `favoriteProblem(_:)`
(`nil`, or "Host removed" / "Profile removed"). `defaultWorkingDirectory`
stays, as the home directory a blank request directory means. Every
mutation goes through `AppModel`, which is what makes the
sidebar and tab bar trivially consistent across windows and what triggers
persistence.

---

## 3. Persistence of layout: `StateStore`

- File: `~/Library/Application Support/Armadale/state.json`, with
  `schemaVersion` at the top and explicit migration steps per version.
- Written atomically (temp file + rename), debounced 500 ms after any model
  change, and synchronously on quit.
- Stores workspaces, selections, window frames, sessions, hosts, profiles
  and (October 24, 2026) favorites.
  A window's frame is always its normal (windowed) frame; `isFullScreen`
  says whether it was in full screen (section 8, "App lifecycle").
- October 24, 2026, additive and still schema 1: a pane may have no
  `sessionID` (an empty pane showing the New Session chooser; it is
  restored as one, and nothing is started for it), `favorites` is a
  top-level array (absent decodes as empty), and a session may carry
  `options` (absent: none). Older files decode unchanged. A build from
  before this change cannot read a file holding an empty pane; the owner
  decided not to care, as Armadale has not been released. The repair
  after every load (below) also turns a pane whose `sessionID` names a
  session missing from the file into an empty pane, logged, so it shows
  the chooser (step 10c; before, it was kept and showed a blank view).
- A field added after a schema version shipped decodes with a default
  when absent (`decodeIfPresent`), without a version bump, when the
  default is right for every file written before it (`Profile.attentionIntegration`,
  `WindowState.isFullScreen`); a change old files cannot be read as
  gets a migration step.
- Loading drops empty closed workspaces (no tab groups, window closed),
  the husks that closing a workspace's last tab group left before October
  23, 2026, even when that leaves none (the app then makes a fresh one).
  `StateStore.decode` applies `PersistedState.droppingEmptyClosedWorkspaces()`
  to every file it reads, the backup included, without a version bump:
  such a workspace holds no tab groups and so no sessions, and files are
  still readable by older builds; `StateStore.load` reports how many it
  dropped and the app logs it. The repair that follows every load
  (`PersistedState.repaired()`) drops tab groups left without tabs (moves
  kept them before October 23, 2026, and a repair can empty one) and then
  closed workspaces it left without groups (one whose only group was a
  duplicate, say), logging each. An empty workspace that is open or has
  no window state (only a hand-edited file has one) is kept, and opening
  it makes a fresh "Main" group. The next save writes the file without
  the husks.
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
  removed. A session's exit recorder (below) keeps running the copy it was
  started from; removing the file does not disturb it (the running
  process keeps its inode), and nothing starts it again.

### `PersistenceBackend` protocol

```swift
protocol PersistenceBackend: Sendable {
    func create(_ session: Session, size: PTYSize) async throws -> ProcessHandle  // attach, creating
    func attach(_ session: Session, size: PTYSize) async throws -> ProcessHandle  // attach only if exists
    func exists(_ id: SessionID) async throws -> Bool
    func liveSessions() async throws -> Set<SessionID>
    func kill(_ id: SessionID) async throws
    func history(_ id: SessionID) async throws -> Data               // live sessions only
    func resolveExit(of session: Session) async -> ExitResolution    // .ended(exitStatus:) | .detached
    func recordedExitStatuses(of ids: Set<SessionID>) async -> [SessionID: Int32]
}
```

`resolveExit` was added in step 3: a zmx client exits the same way whether
its session ended or only the client went away, so the backend decides from
the session itself (`exists(id)`; listing errors count as `.detached`).
Since October 23, 2026 `.ended` carries the program's exit status when
the session's recorder wrote one, and `recordedExitStatuses` reads the
records of sessions that are already gone (the launch path; section
"Session lifecycle", Ended).
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
  started as `-zsh`; the program is therefore `ctty-exec [--unset …]
  --exit-file <runtime>/a-<id>.exit <program> <argv0> <args…>` (the
  trampoline's `TIOCSCTTY` succeeds silently in the daemon's child, which
  already owns its PTY; `--exit-file` is the exit recorder, below).
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
  exit code is always 0, so it cannot distinguish detach from end, and zmx
  discards the program's exit status. So since October 23, 2026 a small
  **exit recorder** sits between the daemon and the program and records how
  it ended in a file next to the session: locally `ctty-exec --exit-file
  <runtime>/a-<id>.exit` (section 7), which writes `N` for a normal exit
  with status N and `signal N` for a death by signal N; remotely the
  session's `/bin/sh` script, which runs the shell without `exec` and writes
  `$?` to `<dir>/run/a-<id>.exit` (section 6). Both write through a
  temporary file and a rename and then exit with the status (128 + N after
  a signal, as shells report it), so the file exists before the daemon ends
  and the socket goes. A local recorder that has passed on SIGHUP or
  SIGTERM (zmx's kill when Armadale closes or respawns the session, or a
  hangup) writes nothing, like the remote script, which such a signal ends:
  the session is being ended from outside, and the app removes a closed
  session's file, which a late write would bring back. zmx 0.8.1's `ls`
  lists sockets only: `ls --short` ignores the file and neither `ls` nor
  `kill` removes it (verified). `resolveExit` reads the file once the
  session is gone (`.ended(exitStatus:)` with a `ProgramExit`: `.exited(N)`
  or `.signaled(N)`; remotely one more command over the shared connection,
  only then) and the controller's state becomes `ended(exitCode:)` with
  it; the ephemeral backend and the plain-ssh fallback keep the client's
  own status (the process is the session; a client killed by a signal
  gives none). `$?` on a host cannot tell a normal exit from a death by
  signal, so there a status of 128 or more is taken as a signal and below
  128 as a normal exit.
  **The rule** (`EndedSessionRule` in `ArmadaleCore`, pure and tested;
  applied by `SessionRegistry` when a controller reports the state): a
  normal exit with status 0 closes the pane, whatever the program; a
  normal exit with any status closes it when the session runs the user's
  shell (no program of its own, or a program named `sh`, `bash`, `zsh`,
  `fish`, `tcsh`, `csh`, `ksh`, `dash` or `nu`). A shell's `exit` without an
  argument and ^D report the last command's status: 130 after ^C at the
  prompt, 1 after a failed command (measured with zsh 5.9), and leaving the
  shell is what the user did. Closing works the way the placeholder's
  Close Pane does, without asking (nothing runs), wherever the pane is:
  like ⌘W it closes the tab with its last pane, the tab group with its last
  tab and the workspace with its last tab group (section 8), whose window
  then closes; with no workspace left the app keeps running with its Dock
  icon (or its status item in menu bar mode) and ⌘N, a Dock click or *Open
  Armadale* makes a fresh one. It never quits the app. (Since October 23,
  2026, owner's request; until then the only pane of the only tab of the
  only tab group of its workspace kept the placeholder, so a window never
  closed by itself.) A
  non-shell program's non-zero exit, a death by signal and an unknown end
  keep the *Session Ended* placeholder (icon, "The session “<title>” exited
  with status N." or "… was ended by signal N (status 128 + N).", else
  "… is no longer running.", **Respawn** / **Close Pane**) **over the
  surface's last contents**, which the surface retains; `history()` cannot
  be used because the session no longer exists. Closing removes the session
  from the model, which also clears its attention. On hosts a shell that
  exits right after an interrupted command (`$?` 130 after ^C at the
  prompt, then ^D) keeps its placeholder: its status reads as a death by
  SIGINT there, since `$?` carries no more than the number.
  The placeholder's primary button (Respawn, Reconnect, Retry) answers
  Return only in the focused pane, or the only one on screen
  (`PaneView.focusStyle`), so Return typed into another pane's terminal
  never respawns or reconnects it; a click on the pane around the
  placeholder's card focuses that pane, as a click on a terminal does.
  *No dimming* (owner's decision, October 31, 2026): the placeholder used
  to lay black at 18 % over the pane around its card, so an ended pane
  looked grey beside a white empty pane; now the area around the card is
  clear (it still takes the click that focuses the pane), so the pane
  shows its theme background, as an empty pane does (white on a light
  theme, the theme's own dark on a dark one), and the session's last
  output stays readable under the card. The dead terminal's cursor is
  hidden while any placeholder is up (ended, disconnected, reconnecting,
  unavailable, host removed), so no idle hollow box shows beside the
  card: `PaneView` feeds the surface DECTCEM, `ESC [ ? 25 l`
  (`TerminalSurface.setCursorVisible(false)`, the bytes in
  `TerminalCursorVisibility`), again after every appearance it applies
  while the placeholder is up (SwiftTerm soft-resets the terminal,
  cursor visibility included, whenever its font is set; seen live:
  choosing Dracula for an ended pane brought the box back, before the
  surface stopped setting an unchanged font, section 8 "Re-applying no
  longer soft-resets"; a size change, ⌘=, still sets it), and feeds `ESC [ ? 25 h` when the placeholder goes because the
  terminal is live again, before keyboard focus returns to it (a respawn
  also resets the terminal, which shows it). A program's own later
  output may change it again, as on any terminal. Tested by asking the
  terminal for mode 25 (DECRQM), since SwiftTerm keeps the state
  internal: in `SwiftTermSurfaceTests` after each sequence, and in
  `PlaceholderKeyboardTests` on a `PaneView` (hidden under a
  placeholder, still hidden after its appearance is applied again, shown
  once the terminal is live).
  While a placeholder is shown the pane itself (`PaneView`), not its
  terminal, holds keyboard focus: the dead terminal used to keep it and
  swallow Return, so the button's default-action shortcut was never
  consulted and Return did nothing (found in review, October 23, 2026).
  The pane takes focus when the placeholder appears over a focused
  terminal, and every way of focusing the pane (`focusTerminal()`: a
  click, the model's focus, the window appearing) targets it while the
  placeholder is up; Return or keypad Enter, without modifiers, presses
  the primary button unless another pane of the split is the focused one,
  and every other key is ignored. When the session runs again (attaching
  or attached) the terminal gets focus back if the pane held it.
  **At launch**, before any window shows, the app reads the exit files of
  the restored local persistent sessions (a file exists only once the
  program has ended, so no listing is needed;
  `SessionRegistry.closeLocalSessionsThatEndedCleanly`) and closes, by the
  same rule and in the model's order, the panes of those that ended cleanly
  while Armadale was not running. That may delete workspaces, all of them
  included; it runs before `AppModel.ensureWorkspacesToOpen()`, so a launch
  where every restored session ended cleanly opens one fresh "Workspace"
  and nothing else. A restored session found gone when its
  pane is first shown (or an attach that finds it gone) is marked ended
  with its record, and the same rule applies then. Remote restored
  sessions cannot hold up the launch: when a host's first listing
  arrives, its restored sessions that are gone and were never shown have
  their records read in one command, and those that ended cleanly lose
  their panes then; a workspace emptied that way is deleted and its
  window, if open, closes then (accepted: the listing comes within seconds
  of the launch).
- **Daemon killed from outside** (SIGKILL, reboot): `ls` reports the stale
  socket as an error entry, cleans it up, and `ls --short` omits it. The pane
  ends up in the same ended state, with no record (status unknown): the
  local recorder, the terminal's session leader, gets the hangup, passes it
  to the shell and writes nothing; a reboot or a SIGKILL of the recorder
  leaves nothing either.
- **Respawn**: kills the old session (always: a pane that looks ended may
  still be alive, and a not-found kill is harmless), creates a new session
  with the same directory and location and the profile's current launch
  (step 5; the old `launch` if the profile was deleted), and rebinds the pane to
  it. The old session ID is retired and its zmx log and exit file removed.
  Close Pane likewise always kills. The
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
--unset ZMX_SESSION_PREFIX --exit-file <runtime>/a-<id>.exit <program>
<argv0> …`, and the trampoline removes them before it starts the program
(verified: `env | grep ZMX` in a pane prints nothing).

### Housekeeping

zmx writes one log per daemon to `ZMX_DIR/logs/<name>.log` plus a shared
`zmx.log`, at debug level, each truncated at 2 MB but never deleted. At
launch Armadale removes log files whose session ID is neither live nor
referenced by the model, and during a run it removes a session's log as
soon as it kills or retires the session. Exit files (`<runtime>/a-<id>.exit`,
and a recorder's leftover `.exit.tmp`) are treated the same way: removed
when the session is closed or retired, and at launch when their session is
neither live nor referenced. On a host, killing a session (close, respawn)
removes its log and exit file there; nothing else is collected on hosts,
whose `~/.armadale` several Macs may share.

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
  without `-l` for csh and tcsh). *Exit recorder (October 23, 2026):* in a
  zmx session the script does not `exec` the shell; it runs `trap : INT
  QUIT TSTP`, then the shell (or `$SHELL -l -c 'exec <program> …'`) as its
  child, then `s=$?; f=<dir>/run/a-<id>.exit; { printf '%s\n' "$s" >
  "$f.tmp" && mv -f "$f.tmp" "$f"; } 2>/dev/null; exit "$s"`. Trapped,
  not ignored: a trapped signal is reset to its default action in the
  child, so ^C, ^\ and ^Z still reach the shell and its jobs, while the
  script, waiting for a foreground child, cannot be ended or stopped by
  them (a bare program stays in the script's process group, which is the
  terminal's foreground group). `$?` after a death by signal N is 128 + N
  in POSIX shells. SIGHUP keeps its default action: zmx's kill (SIGHUP to
  its child) ends the script, the terminal's hangup then ends the shell,
  and nothing is recorded, which only matters for sessions Armadale is
  ending anyway. Remotely a `sh` script rather than `ctty-exec` because the
  helper is a macOS binary; a script needs nothing deployed. The plain-ssh
  fallback still `exec`s (ssh's own exit status is the shell's). Verified
  with the loopback host (macOS `/bin/sh`, bash in POSIX mode) and on the
  Lima VM, whose `/bin/sh` is dash (October 23, 2026: `exit 3` records 3,
  `true; exit` 0, `false` then ^D 1, `kill -9 $$` 137, `cat` interrupted
  by ^C 130, `zmx kill` nothing; `SSHIntegrationTests` checks the first
  two). The app reads 128 and above as a death by signal (section 4,
  Ended). Output over
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
  without the session ends it; an unreachable host means `.detached`. An
  ended session's record is then read with one more command over the
  shared connection (`cd <dir>/run; for n in a-<id> …; do test -f "$n.exit"
  && print it; done`, which also serves several sessions at once after a
  host's first listing); a host that cannot be asked gives no status.
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
- **Exit recorder** (`ctty-exec --exit-file <path>`, October 23, 2026;
  section 4, Ended). Instead of `execv` it `posix_spawn`s the program with
  the same path, argv (argv[0] included) and environment, with the
  original signal mask (`SETSIGMASK`), and stays as its parent: it ignores
  SIGINT, SIGQUIT, SIGTSTP, SIGTTIN and SIGTTOU (it never touches the
  terminal), and the program gets back the default action of each of
  those that was not already ignored when the recorder started
  (`SETSIGDEF` for exactly those, read with `sigaction`), so dispositions
  are what an exec would have passed on. It blocks SIGHUP, SIGTERM and
  SIGCHLD and takes them with `sigwait` (no signal handlers run, no fork in
  Swift), passes SIGHUP and SIGTERM on once (to the program's process
  group when the program leads one of its own, else to the program),
  reaps it, writes the record to `<path>` (temporary file, rename; `N` for
  a normal exit, `signal N` for a death by signal N; a program that cannot
  be started as 127), unless it has passed a signal on, and exits with the
  status (128 + N after a signal).
  Chosen over a `sh` wrapper locally because it keeps argv[0] exactly as
  before without relying on `exec -a`, and starts no shell around a
  program. Job control is unaffected, verified on real PTYs
  (`ExitRecorderTests`, and through zmx in `LocalZmxBackendTests`): an
  interactive zsh under it leads its own process group, which is the
  terminal's foreground group; ^C interrupts `sleep 30` and the shell lives
  on (`$?` 130); ^Z stops a job; a bare program in the recorder's group
  dies of ^C and the recorder records 130; a resize reaches the program as
  SIGWINCH; SIGHUP to the recorder (what `zmx kill` sends, measured with a
  trapping script) reaches an interactive shell once and ends a bare
  program, and nothing is recorded; `exit 3` (3), `exit 137` (137),
  `kill -9 $$` (`signal 9`) and `exit` (0) are recorded; a signal ignored
  before the recorder started stays ignored in the program. On macOS a terminal's hangup signals only the
  session leader, now the recorder, which is why it passes SIGHUP on. Cost:
  one more small process per local session.
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
        └── PaneContainerView (NSView)                 8 pt gutter, or an empty-group state
            └── SplitTreeView (nested PaneSplitViews mirroring PaneLayout; 8 pt gaps)
                └── PaneView per leaf with a session   a card; paneMenu(): PaneMenu
                │   ├── surface.view                   terminal, below the header
                │   ├── NSHostingView<PlaceholderView> Session Ended / Disconnected
                │   ├── PaneHeaderHostingView          header: glyph, title, directory, "…"
                │   └── focus overlay                  hairline / focus border, no hit testing
                └── EmptyPaneView per empty leaf       a card; first responder when focused
                    ├── NSHostingView<NewSessionPaneView> the New Session chooser
                    ├── PaneHeaderHostingView          header: "New Session", "…"
                    └── focus overlay                  hairline / focus border, no hit testing
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
  terminal, a pane's chooser or a sidebar rename field has focus (the
  sidebar's list itself never takes focus, section 1); the tab bar, the sidebar and the menu
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
  accent border (only while more than one pane is on screen; since the
  pane cards, below, every other card has a hairline). Unfocused
  panes keep their terminal's own background: the dimming overlay of
  steps 2 to 9 was dropped on October 23, 2026 at the owner's request.
- The tab bar is custom SwiftUI (not `NSTabView`): it needs shortcut badges,
  status glyphs, drag reordering, and dragging a tab onto a sidebar tab group
  to move it. Tabs share the track's whole width equally (at least 110 pt;
  October 30, 2026) and scroll when they do not fit; each shows its status
  glyph, title (custom, else session title, else
  profile name), a split/zoom hint, and ⌘1…⌘8 badges (⌘9 on the last tab),
  which turn into a close button on hover. Click selects; dropping a tab on
  another takes its position (from any group or window); middle click
  (handled by the hosting view, SwiftUI has no gesture for it) and the close
  button close it with the ⌘W confirmation; double-click or the context
  menu's Rename Tab edits the title in place; the context menu also has
  Close Tab, Close Other Tabs.
- *Tab bar look (owner's decision, October 30, 2026).* The bar is drawn
  like the native macOS 27 window tab bar (Terminal's Window › Show Tab
  Bar), in light and dark, and takes its height: **36 pt** (a native
  window grows by 36 pt when it shows its tab bar; ours was 32). The
  content of a tab, its alignment and every behaviour above are as
  before; what changed is the look, the place of the "+" (now at the
  bar's right end, where native puts it, also when there are no tabs) and
  the width sharing below. Measured from
  screenshots of the native bar (Terminal in light; an AppKit window with
  native tabs forced to each appearance for dark and for the inactive
  look): one capsule **track** 28 pt high, centred in the bar with 8 pt
  at either end, a 0.5 pt border; the **selected tab** is a pill 24 pt
  high (fully rounded, inset 2 pt in the track) with a hairline border and
  a faint shadow, its title in the primary colour; the other titles are
  dimmer, and the ⌘N badges and the split/zoom hint are never brighter
  than an unselected title; plain tabs are separated by 1 × 16 pt
  **dividers**, none next to a pill (`TabBarStyle.showsDivider`, tested);
  the **"+"** is a 28 pt circle (fill and hairline ring) 4 pt to the right
  of the track, outside it. A hovered tab is a faint pill darker than the
  track in both appearances (so in dark it stays clearly below the lighter
  selected pill); a tab needing attention is the pill shape in purple
  (fill and border, as before); both hide the dividers beside them like
  the selected pill. In a window that is not key the selected pill goes
  flat (lighter than the track in light, darker in dark, as native) and
  every title, badge and the "+" glyph turn tertiary. The drop indicator
  is a 2 × 16 pt accent bar just inside the target tab's leading edge, so
  the track's rounded end does not clip it. **Tabs fill the track** (the
  owner's second round, same day), as native: the track's whole inside,
  less the 2 pt insets and the 2 pt gaps between tabs, is shared equally
  (one tab fills it, two take half each); the 220 pt maximum is gone. When
  the tabs would go below 110 pt the track scrolls, clipped to its
  capsule (`TabBarStyle.tabWidth`, tested).
  *Scrolling the track* (second and third rounds, October 30, 2026).
  The track's offset is driven through a `ScrollPosition` and read back
  with `onScrollGeometryChange`; every target is computed by
  `TrackScroll` (tested) from the tab count, the selected tab's index and
  the bar's width (all tabs share one width), never from measured frames.
  Two kinds of change are told apart. When the *selection* changes (a new
  tab, ⌘1…⌘9, a click in the sidebar, the attention reveal, a close that
  selects a neighbour) the track scrolls the least amount that shows the
  selected tab wholly with the 2 pt inset beside it, so the track's
  rounded end never clips the pill (for the first tab that is the start,
  for the last the end), and not at all when it already shows; animated,
  0.2 s. When only the bar's *width* or the *number of tabs* changes (a
  resize, a tab closed or added with the same selection) the user's offset
  is left alone and only clamped: the start when every tab fits, the new
  end when the content shrank under the offset (the scroll view does not
  always clamp by itself: before, a window narrowed and widened again kept
  about 30 pt past the start with no way back), otherwise unchanged; so
  closing a tab never jumps the track to the selected tab or to the
  start. A resize (the width changed, the number of tabs did not) also
  keeps the selected tab in view if it showed wholly before: when the
  clamped offset would cut it off, the least scroll shows it again; a
  selected tab already out of view stays out of view
  (`TrackScroll.resizedOffset`, tested; fourth round, same day). Quick
  selection changes (⌘9 then ⌘2, or ⌘5 ⌘9 ⌘1, within the animation) are
  safe. The offset a decision starts from is the target of a scroll still
  under way, and each scroll is asked for on the main actor's next turn,
  reading the tabs, the selection and the width when it runs, so the last
  state wins whatever order those turns run in (usually a tab added with the
  selection is laid out by then; nothing depends on it, since targets are
  computed rather than measured). The bookkeeping is `PendingScroll` (pure,
  tested event by event, kept in `TabFrameStore`): the target counts as
  reached only when the track comes to rest at it, or is reported at it
  while no animation runs; an offset reported at it during an animation is
  only passing through (the animation towards the end for ⌘9 passes the
  start and tab 2 on its way). The scroll view was seen to drop a target
  asked for just after an animated scroll began and come to rest at the
  earlier one; an animation coming to rest away from the pending target
  therefore asks for it once more, at most once per requested scroll. The
  user's own scrolling (tracking, interacting, decelerating) drops the
  target, so no retry ever follows it. Known and not fixed (older than this
  change): dragging a tab does not scroll the track, so only visible tabs
  can be drop targets. *Middle click* (second round): the hosting
  view's `TabFrameStore` also records the track's visible frame and only
  resolves a point inside it, so a tab scrolled out of view, whose stored
  frame lies under the "+" or the bar's ends, can no longer be closed by a
  middle click there (`TabFrameStore.tab(at:)`, tested).
  Colours (`TabBarStyle`) are black tints in light and white tints in
  dark, chosen per appearance through a dynamic `NSColor`, so the bar
  follows the window's appearance; their strengths were tuned until the
  pixels on screen matched the native screenshots (track, track border,
  divider and "+" within a few levels of 8-bit grey in both appearances),
  because the native bar's tints are not exposed as named system colours
  and SwiftUI renders the same alpha lighter than AppKit does in light
  mode. With Increase Contrast (SwiftUI's `colorSchemeContrast`) the
  track border, pill border, dividers and "+" ring are clearly stronger
  (`TabBarStyle.tint`, tested; not seen live). Not native, kept on
  purpose: our tab content (status glyph, host badge, title at 12 pt,
  left-aligned and truncated in the middle, split/zoom hint, ⌘N badge and
  hover close button) instead of the native centred title and left-hand
  close button; the bar sits under the title bar's title and subtitle
  rather than inside the title bar.
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
  pane's chooser); after a click elsewhere it stays where the click put
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
  the sidebar and the tab bar alike the double click is a
  `TapGesture(count: 2)` added as a `simultaneousGesture` beside the single
  click's tap, so the single click's action is not delayed waiting for a
  second click (the sidebar's `SidebarRowActions`, over the whole row
  width; the sidebar's List has no selection since October 29, 2026). In
  the sidebar both taps are off while the row's field is up, so a click in
  the field neither starts another edit nor takes its focus; a mouse down
  in the sidebar outside the field commits the edit (`WorkspaceWindow`).
- *Attention (step 7).* An app-level `AttentionCenter`
  (`Sessions/AttentionCenter.swift`, `@Observable`) owns the pure
  `AttentionTracker` (section 10). The registry forwards every bell and
  notification sequence to it; the tab bar, the sidebar and the Dock badge
  read it. The app delegate keeps its `isAppActive` (application
  did-become/resign-active) and `keyWorkspaceID` (window did-become/
  resign-key, mapped to the window's workspace; nil for Settings or no
  window) current. The tab bar tints a tab needing attention (a purple
  pill, fill and border) and shows ◐; the sidebar shows ◐ on the tab row
  (its title's weight is the shown path's, section 1, since October 30,
  2026) and a purple count capsule (`AttentionCount`) on the tab group and
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
- **Pane context menu** (owner's decisions, October 30, 2026). Each
  pane has a context menu, an AppKit `NSMenu` built by one pure builder,
  `PaneMenu.make(_:actions:)` (`Panes/PaneMenu.swift`, tested):
  `PaneMenu.Inputs` holds what the items show and `PaneMenu.Actions` what
  they do, so a later pane item adds a field to each and a few lines to
  the builder. It holds **Split Right** and **Split Down** (added October
  31, 2026, at the owner's request; they are the header's way to split,
  see "Pane cards" below), a separator,
  then **Theme**. The split items show the Pane menu's shortcuts (⌘D,
  ⇧⌘D, the same keys and modifiers; a test keeps the two equal; ⌘D with
  the menu open splits once, seen in review) and split *the pane the menu
  was opened for*
  (`AppModel.splitPane(_:axis:)`, Split Right horizontal, Split Down
  vertical), not whichever pane is focused; the rest is as ⌘D. Theme is a
  submenu: "Default"
  first, a separator, the built-in themes in catalog order, then, if any,
  a separator and the imported themes; the pane's current choice is
  checked ("Default" when it has none, or when its ID is unknown).
  Choosing an item calls `AppModel.setTheme(_:forPane:)`. `PaneView.paneMenu()`
  and `EmptyPaneView.paneMenu()` build it fresh from the pane's theme and
  the theme catalog; its items are `ActionMenuItem`s (their own target,
  running a closure).
  *Its entry point is the pane card's header* (October 31, 2026, "Pane
  cards" below): the header's "…" button and a right-click (or
  Control-click) on the header open it; nothing over the terminal does.
  *Until then no mouse event opened it.* The first version (ebec034) opened it on
  a right-click when the program had not asked for the mouse, on Shift +
  right-click always, and treated Control-click as a right-click, which
  meant a program that asked for the mouse never saw Control + left-click
  (Emacs's buffer menu) and could not see Shift with a right button. The
  owner decided the same evening that programs such as vim and Emacs
  must get every mouse event exactly as the renderer reports it, and
  that the menu's entry point is to be chosen later (a UI entry point,
  not a mouse rule; it became the pane header the next day). So the subclass that applied those rules
  (`HostTerminalView`) and the rules themselves (`ContextClick`) were
  removed in the following commit; `SwiftTermSurface` uses SwiftTerm's
  `TerminalView` unchanged (a right-click goes to a program that asked
  for the mouse, as before; otherwise SwiftTerm calls `super`, and NSView
  passes it up the responder chain where no view has a menu for it, so
  nothing happens), the pane views override neither `menu(for:)` nor any
  mouse method for it (`menu(for:)` would make AppKit show it on a
  right-click), and a Control-click is a left click with Control, as the
  program sees it. The builder, the per-pane theme (below) and their tests
  stay, so the Theme submenu is one entry point away. When one is added,
  the menu should focus the pane first, as a click would, and neither take
  keyboard focus nor change the focused pane (the first version did, seen
  live). The header does exactly that: it focuses the pane (its terminal,
  or the pane itself while a placeholder or the chooser shows), then opens
  the menu; after a choice, typing goes on in the pane (seen live).
  *The pane's theme* is `Pane.themeID` in the model (section 2): one
  explicit theme shown in light and dark system appearance alike, not a
  light/dark pair (owner's decision); `nil` ("Default") follows the
  Settings choice, which keeps following the system appearance. Because it
  lives on the pane record, it survives relaunch, a respawn (the session
  is replaced, the pane stays), a tab moved between groups or windows and
  a drag; a split's new pane starts on Default. It is saved only when set
  (no schema bump; older files load unchanged). `AppSettings.terminalAppearance(for:paneThemeID:)`
  uses the pane's theme when the catalog knows it, and the Settings
  choice for the appearance when it is `nil` or unknown (a theme removed
  outside the app, a typo in the state file); removing an imported theme
  in Settings › Appearance (`AppSettings.removeUserTheme(_:model:)`) also
  returns every pane naming it to Default (`AppModel.forgetTheme(_:)`).
  `PaneView` and `EmptyPaneView` read the pane's theme through a
  `PaneThemeBinding` (a `PaneView` by its controller's current session,
  an empty pane by its pane ID) and observe it together with the Settings
  inputs (`PaneAppearanceChange`), so a choice recolours the terminal, the
  padding and an empty pane's background at once, only in that pane. A
  pane with its own theme also sets its view `appearance` to dark or light
  aqua to suit the theme's background (luminance below 0.4 is dark), so
  the placeholder card and the New Session chooser stay legible (seen
  live: an empty pane on Armadale Light in dark mode showed a dark card
  with faded text before this); on Default the pane follows the window.
  A context menu popped up for the pane would be drawn in that appearance
  too, so a light-themed pane in dark mode shows a lighter menu than the
  rest of the app (accepted as cosmetic in the first version).
  The surface a pane's session is created with starts with the pane's
  theme, so nothing flashes in the Settings theme first.
- **Pane cards** (*design agreed with the owner on October 31, 2026;
  implemented the same day*, see *As built* at the end of this bullet).
  The owner noted that recent
  terminal and agent front ends (superlogical, Tern, herdr) draw each pane
  as a rounded card with a margin around it and a header on top, and
  asked for a design. Armadale adopts it because it makes splits legible
  without a divider line, makes two differently themed panes look chosen
  rather than broken, and gives the pane context menu (above) the entry
  point it lacks: a header no program can take.
  *Geometry.* The pane area keeps a **gutter of 8 pt** (the tab bar's
  margin, `TabBarStyle.margin`) on all four sides, and sibling panes in a
  split are **8 pt apart**: that gap is the split's divider
  (`dividerThickness` 8, drawn as nothing so the window background shows
  through; the whole gap is the drag target and shows the resize cursor).
  Each leaf is a card with **10 pt corner radius**, filled with the pane's
  theme background (the pane's own theme or the Settings one, as today),
  clipped to its corners. Inside the card: the **header, 28 pt** tall (the
  tab bar's track height), then 4 pt, then the terminal grid, with 10 pt
  of padding left, right and bottom as today; since the padding is at
  least the radius, no corner cell is clipped. The gutter and the gaps
  show the window background. A zoomed pane and a tab with one pane show
  one card with the same gutter and header (consistency with every other
  tab; owner's decision). The empty tab group state is unchanged.
  *Header.* Drawn in the pane's appearance over the theme background, in
  the theme's foreground colour at reduced opacity so it suits any theme:
  left, the session's status glyph (`StatusGlyph`, as in the tab bar),
  then the **title** (the session's title, else the profile name; a tab's
  custom title is the tab's, not the pane's) in the system font at 12 pt
  semibold at 70 % opacity, then the **working directory** (`~`-abbreviated,
  from the directory the registry records; nothing while unknown) at 55 %,
  both truncated in the middle; right, a **"…" button** (`ellipsis`
  symbol, shown at 55 %, full opacity on hover) that opens `paneMenu()` as
  a pull-down below itself. A **right-click anywhere on the header** opens
  the same menu at the pointer; a click on the header focuses the pane as
  a click on the padding does; a double-click does nothing for now (a
  pane has no title of its own to rename). No split, zoom or close
  buttons in the header: the owner asked on October 31, 2026 for Split
  Right and Split Down buttons beside "…" and dropped them the same
  morning because they made the header look busy, so the splits are
  reached from the pane menu (its first two items, ⌘D, ⇧⌘D) and the
  application's Pane menu; zoom and close are in the tab bar and on the
  keyboard. An empty pane's header shows
  no glyph and the title "New Session"; a pane showing the *Session Ended*
  or *Disconnected* placeholder keeps its glyph and title, and the
  placeholder's card sits in the content area as now.
  *Focus and attention.* Every card has a **0.5 pt hairline border** in the
  theme's foreground at 12 % (so a light card has an edge on a light
  window, and a dark one on a dark window); the **focused card** replaces
  it with the **1.5 pt accent border at 55 %** used today, now following
  the rounded edge, and only while more than one pane is on screen (as
  today; a lone card keeps the hairline). A pane needing attention shows
  ◐ in its header and tints the header's title with the attention colour
  (`StatusGlyph.attentionColor`, the tab bar's purple), cleared as the tab
  bar's is when the session is looked at.
  *Cost.* Against today's layout a 2 × 2 split loses about 60 pt of height
  (two headers and the top and bottom gutters against today's 4 + 10 pt
  pane padding and the 1 pt divider) and about 24 pt of width (three
  gutters), roughly four rows and three columns at the default font; a
  single pane loses about 40 pt of height and 16 pt of width. The owner
  accepts this for the first version; a "Show pane headers" preference
  (cards and gutters stay, the header row goes) is deferred (owner's
  decision), noted in section 13.
  *Menus and chooser.* The pane context menu's entry point is the header
  ("…" and right-click), which answers the open point above. The New
  Session chooser's compact widths (below, 340 and 180 pt) are measured
  against the pane's width as now; with 20 pt less content width the
  thresholds stay, since they describe the card's content.
  *Implementation.* `PaneContainerView` insets the split tree by the
  gutter. `PaneSplitView` gets `dividerThickness` 8 and draws no divider
  (`drawDivider(in:)` empty; `dividerColor` unused). `PaneView` and
  `EmptyPaneView` set `layer.cornerRadius` and `masksToBounds`, put the
  border on their existing focus overlay layer (same radius) and host a
  `PaneHeaderView` (SwiftUI in an `NSHostingView`, sharing `StatusGlyph`
  with the tab bar; its inputs are a small `PaneHeaderModel` struct —
  glyph status, title, directory, attention, pane appearance — that the
  pane view keeps current from the model the way the tab bar does). A
  pure `PaneCardStyle` (gutter, gap, radius, header height, insets,
  border width and colour for each focus state and appearance) is unit
  tested, as `TabBarStyle` is; the header's title precedence and the "…"
  button reaching `paneMenu()` are tested with the views in a window.
  Live checks (the Mac is needed): light and dark, two themes side by
  side, a 2 × 2 split, zoom, an empty pane, a *Session Ended* pane, a
  narrow pane at about 90, 165 and 185 pt, divider drags in the gap, and
  the header menu over vim with `mouse=a`.
  *Owner's decisions (October 31, 2026).* A lone pane gets the gutter
  and header too; the "Show pane headers" preference comes later; the
  numbers above (gutter 8, gap 8, radius 10, header 28) are judged live
  against the window's own corners and the native tab bar and adjusted
  in the same change; no split, zoom or close buttons in the header. (The
  owner asked for Split Right and Split Down buttons beside "…" later on
  October 31, 2026, with the same two items at the top of the pane menu,
  and dropped the buttons the same morning because they made the header
  look busy; the menu items stay.)
  *As built (October 31, 2026).* The numbers stayed as agreed after the
  live checks in light and dark (they sit well against the window's
  rounded bottom corners and the 36 pt tab bar): gutter 8, gap 8, corner
  radius 10 (continuous curve), header 28, 4 pt to the grid, padding 10;
  hairline 0.5 pt at 12 % of the theme foreground, focus border 1.5 pt
  accent at 55 %; title 12 pt semibold at 70 %, directory 12 pt regular at
  55 %, "…" at 55 % (100 % on hover). All of it is `PaneCardStyle`
  (`Panes/PaneCardStyle.swift`, pure, tested in `PaneCardTests`, which
  also checks the views in a window: title precedence, directory,
  attention set and cleared, the card's borders, the "…" button and a
  right-click reaching `paneMenu()` and focusing the pane first, that
  a header point hit-tests to the header and a grid point to the
  terminal, and that `PaneView` and `EmptyPaneView` are released with
  their headers). The header is `PaneHeaderView` (SwiftUI) in a
  `PaneHeaderHostingView` (`Panes/PaneHeaderView.swift`): `mouseDown`
  focuses the pane then lets SwiftUI handle the click (the "…" button),
  `rightMouseDown` and `menu(for:)` (AppKit's Control-click) focus the
  pane and return its menu, the button pops the menu up under itself
  (`PaneCardStyle.menuOrigin`): its leading edge at the button's leading
  edge, or, when the menu would run past the window's right edge (the
  rightmost pane, seen in review), its trailing edge at the button's
  trailing edge (tested). A pane view's header content comes from
  `SessionRegistry.headerModel(for:)` through an `Observations` loop
  (`PaneView.headerSource`, set by the registry), so it follows the
  model's title and directory (`AppModel.setTitle`, `setWorkingDirectory`;
  the directory is abbreviated with `AppModel.abbreviatedDirectory`, now
  public, so a host's path is shown as it is), the controller's state and
  `AttentionCenter`. *The directory is shown only once the session's
  program has reported it with OSC 7* since this launch
  (`SessionRegistry.reportedDirectories`; restored and respawned sessions
  count as unreported until they report again): `Session.workingDirectory`
  is otherwise the directory the session started in, and a shell that
  sends no OSC 7 (the owner's zsh, section 8, "New sessions") would show
  it after every `cd` (seen in review: "~" after `cd /private/tmp/…`). An
  unreported directory is "unknown", which the design shows as nothing.
  Once reported, a session stays reported, so a program that reports
  once and hands back to a shell that never does leaves the last
  reported path in the header (seen in review by sending OSC 7 by hand
  from the owner's zsh, then `cd`); a shell with OSC 7 integration
  reports at every prompt, so this is accepted. The header's theme
  foreground is added when the pane applies its appearance. The gutter is `PaneContainerView.splitTreeFrame`
  (applied in `resizeSubviews`, so a zero-sized pane area never gets a
  negative frame); the empty-group state still fills the whole area.
  `PaneSplitView.dividerThickness` is `PaneCardStyle.gap` and
  `drawDivider(in:)` draws nothing; the ratio layout already subtracted
  `dividerThickness`, so it needed no change (the split test now expects
  `(width - 8) × ratio`). *Deviations, found live:* (1) the directory is
  not shown when it equals the title (zsh and fish title themselves with
  the directory, which read "~ ~"; `PaneHeaderModel.shownDirectory`,
  tested); (2) the title and the directory share the header's text
  width by a rule (`PaneCardStyle.headerTextWidths`, laid out by
  `HeaderTextLayout`, tested): both whole when they fit; else the title
  whole and the directory truncated in the middle to what is left, when
  that leaves the directory at least 40 % of the width (or 40 pt, or all
  it needs if less); else the title truncated in the middle and the
  directory given 40 % of the width (at least 40 pt); and the directory
  dropped only when that would leave the title under 40 pt, so a narrow
  pane never shows a stray one-character fragment of it (seen live) and
  a long title never hides it in a normal pane (the first version's
  `ViewThatFits` did, seen in review in a 417 pt pane); (3) the *Session Ended* / *Disconnected* placeholder now
  covers the card below the header (`PaneCardStyle.contentFrame`) rather
  than the whole pane, so the header (glyph, title, "…") stays clear of
  it (it dimmed the pane until later that day, see "Session Ended": no
  dimming now); (4) Control-click on the header opens the menu too
  (`menu(for:)`, standard AppKit; the header is never the program's).
  *Checked live* (test build, isolated state, light and forced dark):
  a 2 × 2 split (gutters, gaps, corners, headers, hairlines, accent border
  on the focused card only), Default, Gruvbox Dark and Dracula panes side
  by side chosen from the "…" pull-down and from a header right-click,
  typing in the pane right after a choice, a lone pane and a zoomed pane,
  an empty pane at full width and at about 90, 165 and 185 pt (header
  "Ne…n" with the "…" still there; chooser tiny, small, compact; New…
  still opens the dialog), a *Session Ended* pane (glyph ○ and title
  kept), a drag in the 8 pt gap, vim with `mouse=a` (a right-click in
  the grid moved vim's cursor, `mousemodel=popup_setpos`; a right-click on
  the header opened Armadale's menu and vim's cursor did not move), a bell
  in an unfocused pane (◐ and the purple title in its header, with the
  tab and sidebar), Control-click on the header. Not checked live: the
  *Disconnected* placeholder (needs a host) and Increase Contrast. The
  three review fixes (OSC 7-only directory, the shared-width rule, the
  right-aligned menu on the rightmost pane) were checked live by the
  reviewer in light mode: no directory after `cd` in a plain zsh, the
  path after an OSC 7 report, an 80-character title truncated in the
  middle beside the directory in a 417 pt pane, a long directory
  truncated beside a short title, and the rightmost pane's menu ending at
  its button's trailing edge inside the window.
  *Split items, as built (October 31, 2026).* The header keeps its one
  24 × 20 pt "…" button, 4 pt from the trailing edge
  (`PaneCardStyle.menuButtonFrame`, `headerButtonSize`, drawn by
  `PaneHeaderButton`); the title and the directory share what the row
  leaves them (`PaneCardStyle.headerTextSpace`: the header less 68 pt
  with a glyph, 10 leading, 12 glyph and 6, 6 on each side of the
  flexible space, 24 for "…" and 4 trailing; less 50 pt without a glyph)
  by the rule above. (Split buttons were built and checked live that
  morning: three 24 pt buttons, the text space the header less 116 pt,
  and "…" alone under 156 pt; the owner then dropped them, and that
  geometry with them.) The pane's split travels with its theme in
  `PaneThemeBinding.split` (a `PaneView` by its session's current pane,
  an `EmptyPaneView` by its pane ID; detached: nothing), which ends in
  `WorkspaceActions.split(pane:axis:)` of the pane's window (the
  registry's `actionsOfWorkspace`, set by the app delegate, or the content
  controller's actions for an empty pane): it notes the split pane's
  session for the New Session dialog's directory, as ⌘D notes the
  focused one, then calls `AppModel.splitPane(_:axis:)`, which focuses the
  new empty pane; the content controller then gives it keyboard focus and
  it shows the chooser, as after ⌘D. Tested in `PaneMenuTests` (outline
  Split Right, Split Down, separator, Theme; the shortcuts equal the main
  menu's; the menu of an unfocused pane splits that pane and focuses the
  new one) and `PaneCardTests` (the "…" frame, the text space, the "…"
  menu's split items splitting their own pane after focusing it, through
  the window's actions, and an empty pane's). *Checked live* (test build,
  light mode): Split Down and Split Right from a header right-click on
  unfocused panes, with ⌘D and ⇧⌘D shown, each splitting that pane with
  the new pane focused showing the chooser; typing in the terminal after
  clicking back into it; the rightmost pane's "…" menu ending inside the
  window.
- Settings is an `NSWindowController` hosting SwiftUI tabs:
  **General** (notifications (step 7), confirm‑on‑close, menu bar mode;
  the default profile and directory were removed on October 24, 2026 with
  the New Session chooser, below),
  **Appearance** (font, size, theme, cursor, renderer), **Profiles**,
  **Hosts**, **Favorites** (October 24, 2026). The read‑only Shortcuts
  tab of steps 5 to 10 moved to **Help › Keyboard Shortcuts** on October
  29, 2026 (below): Settings is for what can be changed, and a shortcut
  cannot be changed in Armadale yet.
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
    `-ArmadaleDefaultsSuite <name>`. It holds `confirmClosingRunningSession`
    (same key as step 4), font name and size (6–48, stored; ⌘= / ⌘- / ⌘0
    write through it), the theme choice (one theme, or a light and a dark
    one that follow the system appearance), cursor shape and blink, the
    renderer, and the Settings window's position and tab. Profiles stay in
    the model (`state.json`).
  - `AppSettings` bundles `Preferences`, `ThemeCatalog` and the
    `SurfaceRegistry` and turns them into a `TerminalAppearance` for a
    light or dark view. Each `PaneView` observes it, so every appearance
    change, including a re-imported user theme, applies to all panes at
    once, shown or not. A pane can override the theme from its context
    menu (above, "Pane context menu"); the Settings theme then applies
    only to panes on Default, while font, size and cursor still apply to
    every pane.
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
    (`notificationPlaysSound`, default off). (File › New Tab with Profile
    and the tab bar's "+" context menu, which opened a tab with any
    profile, were removed on October 24, 2026: every new pane asks.)
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
  - **New sessions on hosts**: the New Session dialog's SSH choice (below;
    until October 24, 2026 File › New Tab on Host and an "On Host" section
    in the tab bar "+" context menu created a remote tab with the default
    profile in the host's home directory, and splitting a remote pane
    stayed on its host; both are gone with the chooser).
    Remote tabs carry a small host badge (a network glyph; with the host's
    name in the sidebar; orange when not persistent). The window subtitle
    is unchanged by remote tabs, except that it shows the existing
    "Sessions won’t survive quitting" warning while one of the workspace's
    sessions is a non-persistent fallback (section 6). Remote sessions
    restore on relaunch like local ones.
  - **Help › Keyboard Shortcuts** (`Help/ShortcutsWindowController.swift`,
    one window, kept by the app delegate like Settings; until October 29,
    2026 a Settings tab) shows the table generated from the menu bar
    `MainMenu` builds (`Help/ShortcutTable.swift`): every item with a key
    equivalent, hidden alternates folded into their visible item, numbered
    runs collapsed (⌘1…⌘8), so it cannot drift from the real bindings.
    Only items `MainMenu` created are listed (it gives each an
    `armadale.menu.*` identifier); what AppKit adds later, the Services
    menu's contents and the Window menu's tiling commands (🌐⌃C Center,
    …), is not Armadale's and is left out. The Globe modifier is shown as
    🌐. The Help item itself has no key equivalent, so it is not a row. The
    window is resizable, centred, titled "Keyboard Shortcuts"; ⌘W closes
    it as it does Settings; in menu bar mode it is ordered out with
    Settings and closing it hides the app the same way. A `settingsTab`
    preference still reading `shortcuts` opens General.
  - **Help › Acknowledgements** (`Help/AcknowledgementsWindowController.swift`,
    November 4, 2026) shows the third-party notices bundled as
    `Contents/Resources/Acknowledgements.txt` (source
    `Armadale/Resources/`): SwiftTerm's and the persistence helper's
    copyright lines and MIT license texts, verbatim from
    `THIRD_PARTY_LICENSES.md`, and the colour-scheme credits. The MIT
    license requires the notices in every copy, and the DMG is one. The
    helper is named "the persistence helper" there, never by its
    runtime's name (`AcknowledgementsTests` checks that, and that every
    copyright line, license text and credit of `THIRD_PARTY_LICENSES.md`
    is in the bundled file, so the file cannot gain a notice the bundle
    lacks; the texts are compared with upstream by hand on a SwiftTerm or
    helper bump). One window, kept by
    the app delegate like Keyboard Shortcuts: a read-only, selectable,
    plain-text `NSTextView` in the small monospaced system font, 560 × 520
    points, resizable, centred, titled "Acknowledgements", no document;
    choosing the item again brings the same window forward, ⌘W closes it,
    and in menu bar mode it is ordered out and its closing hides the app
    as for Settings. The item has no key equivalent, so it is not a row
    of the shortcut table.
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
  - *Re-applying no longer soft-resets the program* (October 31, 2026,
    found in review). SwiftTerm 1.99.0's `font` setter calls `resetFont()`,
    which calls `resize(cols:rows:)` (`AppleTerminalView.swift`, about
    line 4470), which ends in `terminal.softReset()` (`cmdSoftReset`,
    `Terminal.swift`, about line 5739): application cursor keys and keypad
    mode off, the cursor shown, scroll region, origin mode, wraparound,
    charset and attributes reset, and `resetAllColors()` (mouse reporting,
    the alternate screen and bracketed paste survive). `SwiftTermSurface.apply` set the font on
    every call, and a pane applies its appearance whenever it enters a
    window, so a split, a tab switch or a zoom soft-reset the program in
    that pane (seen: `?1h` and `?25l` reported reset by DECRQM after ⌘D;
    a window resize, which resizes without the reset, kept them). Now the
    surface sets the font only when its name or size changed
    (`appliedFont`, as `appliedCursor`); the colours and the cursor style
    soft-reset nothing and still apply every time, though installing the
    theme's palette replaces one the program set with OSC 4
    (`installPalette`, `Terminal.swift` about line 1174), accepted for a
    theme change. `PaneView` also skips the
    surface entirely when the appearance it computes is the one it last
    applied to the same surface (it still updates its own card and
    header), so re-entering a window does not even reinstall the palette.
    A font or size change (⌘= / ⌘- / ⌘0, Settings) still soft-resets the
    program's modes: a SwiftTerm property, accepted; under a placeholder
    the pane hides the cursor again after the font is applied ("Session
    Ended"). Tested with DECRQM in `SwiftTermSurfaceTests` (same
    appearance, theme and cursor-style changes keep mode 1; a size change
    resets it) and `PlaceholderKeyboardTests` (a pane re-entering a window
    applies nothing and keeps modes 1 and 25; ⌘= on an ended pane keeps
    the cursor hidden).
  - Ghostty import also accepts the basic X11 colour names (black … white,
    bright/light variants, grey), meaning the default palette's entries;
    the default palette is the light one when the background is light
    (luminance > 0.5). A rejected file reports its bad lines. User theme
    IDs are lower-case and matched case-insensitively; Appearance ›
    Remove deletes an imported theme, and choices using it fall back to
    the defaults (and panes using it to Default, since October 30, 2026).
    A font picked in the font panel that is not fixed-pitch
    is refused with a message.

### New sessions: the chooser, the dialog and favorites (October 24, 2026)

Owner's request: a new pane never starts a local shell by itself. It asks.

- **Every new pane is empty** (`Pane.sessionID == nil`) and shows the
  **New Session chooser** in place of a terminal: File › New Workspace
  (⌘N), New Tab Group (⇧⌘N), New Tab (⌘T), Split Right / Down (⌘D / ⇧⌘D),
  the tab bar's "+", the sidebar's New Tab / New Tab Group, and the fresh
  workspace a launch with nothing to restore makes
  (`ensureWorkspacesToOpen`). A split no longer copies the pane's profile
  and directory; it asks like the rest. Respawn is untouched: it belongs to
  a pane that has a session.
- **The chooser** (`NewSessionPaneView`, SwiftUI hosted in the pane's
  place, one per empty pane, owned by the content controller rather than
  the `SessionRegistry`, which only knows sessions) shows the heading
  "New Session", the list of favorites (profile icon and name, host badge
  for a remote one, directory in secondary text; a broken favorite is
  dimmed with its reason and does nothing; broken means its host or
  profile was removed, or its host has no usable destination, which
  `AppModel.favoriteProblem` reports as "Host has no usable destination",
  as the dialog refuses Start for it), and two buttons: **Cancel** and
  **New Session…**. A single click on a favorite starts it in this pane.
  Keyboard: the empty pane is first responder when focused (as a pane with
  a placeholder is); ↑/↓ move a selection through the favorites, Return
  starts the selected favorite or, with none selected, opens the dialog,
  and Escape cancels. A right-click on a favorite offers **Edit…** (the
  dialog in edit mode) and **Remove** (no question). With no favorites the
  card says "No favorites yet. New Session… starts one and can save it as
  a favorite." Cancel closes the pane through the
  normal close path with no confirmation (nothing is running), so when it
  was the tab's only pane the tab, group and workspace cascade as a clean
  exit does (section 4): New Workspace then Cancel closes the new window
  again. An empty pane's tab is titled "New Session" and has no status
  glyph; it needs no attention, counts as no session for the quit question
  and menu bar mode, and does not block anything.
- **The New Session dialog** (`NewSessionSheet`, a SwiftUI form in a sheet
  on the workspace window; `WorkspaceActions.newSession(in: PaneID)`) has:
  - **Location**: Local or SSH (segmented). SSH shows a picker of the saved
    hosts (`Host.displayName`) and an **Add Host…** button that opens
    Settings › Hosts; the sheet stays and its picker follows the model, so
    the host added there can be picked without starting over. With no host
    saved the picker reads "No Hosts" and Start is disabled while SSH is
    selected. Host details (port, identity file, config file, remote
    directory) stay in Settings › Hosts; the dialog never duplicates them.
  - **Working directory**: a text field, prefilled with the directory of
    the window's focused pane that has a session (the registry's last
    known directory, else the session's), else the home directory; empty
    or `~` means home. Local shows **Choose…** (an open panel for a folder;
    `~` abbreviation as the old General setting did). Remote directories
    are the host's and are passed through untouched.
  - **Profile**: a picker of every profile (icon and name), built-ins and
    the user's own, in Settings order; the shell is preselected.
  - **Options**, shown for a profile whose flavor Armadale knows (section
    10) and otherwise only the arguments field: for **Claude Code** "Skip
    permission checks (--dangerously-skip-permissions)", "Continue the most
    recent conversation (--continue)", and a **Model** text field (empty:
    Claude's default; the flag is `--model`); for **Codex** "Skip approvals
    and sandbox (--dangerously-bypass-approvals-and-sandbox)", a
    **Sandbox** picker (Default, read-only, workspace-write,
    danger-full-access; `--sandbox`) and **Model** (`--model`). A free
    **Additional arguments** field (one line, split like a shell: spaces
    separate, single and double quotes group, `ShellWords.split` in
    `ArmadaleCore`, pure and tested) for any profile with a program. The
    flag names come from `claude 2.1.304 --help` and `codex-cli 0.163.0
    --help` on this Mac (Codex has no `--full-auto` any more and no resume
    flag; `resume` is a subcommand), and live in `AgentIntegration` with
    the other researched facts, so an upgrade re-check covers them. The
    text next to each option says the flag, as the Profiles editor does
    for the attention setting.
  - **Add to Favorites**: a checkbox that reveals a **Name** field
    prefilled from the choices ("Claude Code in ~/work", "Shell on
    lima-default in ~"), editable. The favorite is saved when Start is
    pressed, in addition to starting the session.
  - Buttons **Cancel** and **Start** (Return; disabled while the form is
    invalid: SSH with no host, a directory containing NUL). Escape cancels.
    Start calls `startSession(in:request:)`; the pane's view becomes the
    session's `PaneView` and takes keyboard focus. The dialog's Cancel
    closes the sheet only: the pane keeps its chooser (only the chooser's
    own Cancel closes the pane). In **edit mode** (from
    a favorite's Edit… or Settings › Favorites) the title is "Edit
    Favorite", the name field is always shown, the buttons are Cancel and
    **Save**, and nothing is started.
- **Settings › Favorites** (`Settings/FavoritesSettingsView.swift`): the
  list (drag to reorder, which is the chooser's order) with add / remove
  and the same form as an editor on the right, like Profiles and Hosts;
  edits save when a field's editing ends. A broken favorite shows its
  reason and lets the user pick another host or profile. Removing a host
  or deleting a profile leaves the favorites that used it, broken; the
  host removal alert mentions how many.
- **Removed**: File › New Tab with Profile, File › New Tab on Host (and the
  Add Host… item under it), the tab bar "+" context menu (its help text is
  now just "New Tab"), Settings › General's default profile and directory
  (the preference keys are left unread), `Preferences.defaultProfileID` /
  `defaultWorkingDirectory`, `AppModel.defaultProfileID`,
  `newTab(in:onHost:profile:)`. The Shortcuts table is unchanged: nothing
  here has a key equivalent.
- **Persistence**: an empty pane is saved as a pane without a session and
  comes back as an empty pane showing the chooser (section 3).
  The repair step keeps it, and turns a pane whose `sessionID` names a
  session missing from the file into such an empty pane (logged like the
  other repairs: "Emptied pane … whose session … is missing"), so it shows
  the chooser instead of a blank view.

*Implementation (step 10c).* What the code decides beyond the above:

- **Views.** `NewSessionPaneView` (`Panes/NewSessionPaneView.swift`,
  SwiftUI) is the card; `EmptyPaneView` (`Panes/EmptyPaneView.swift`, an
  `NSView` hosting it) is what `ContentViewController` puts in the split
  tree for a pane without a session, one per empty pane on screen, made
  when the pane is first shown and dropped once it has a session or is no
  longer shown (switching tabs makes a fresh one, so a selection does not
  survive a tab switch). The decisions are `NewSessionChooser`
  (`Panes/NewSessionChooser.swift`, `@Observable`, no view code;
  `NewSessionChooserTests`). `PaneContainerView.blankView(for:)` is left
  only for a pane whose session has no pane view, which the repair makes
  impossible. The card is the placeholder's (material, 14 pt corners,
  shadow, at most 440 pt wide) over the terminal theme's background,
  as the placeholder's is (neither dims the pane); the focus border is the same as a
  terminal pane's. A split counts all its leaves for the border, so a
  terminal next to an empty pane shows focus as in any split. In a pane
  narrower than 340 pt the card is compact (`PaneCard`, shared with the
  *Session Ended* placeholder: 12/8 pt padding instead of 32/24, no big
  icon, a one-line heading that scales down, rows of icon and one-line
  truncated name and reason without the host or directory line, buttons
  labelled "New…" or stacked when the full labels do not fit, and small
  below 180 pt), checked live at about 90, 165 and 185 pt.
- **Rows.** Profile icon (a warning triangle for a broken favorite), name,
  and below it, for a remote favorite, the tab bar's `HostBadge` with the
  host's name, then the directory (local ones `~`-abbreviated, remote ones
  as typed, `~` when blank); a broken one shows its reason in orange at
  55 % opacity and ignores clicks, but keeps its context menu so Edit…
  can repair it. The rows are a plain stack when they fit the pane and a
  scroll view (following the selection) when they do not (`ViewThatFits`).
  The pointer highlights a startable row; the selection is an accent tint.
- **Keys.** They reach the chooser only through `EmptyPaneView.keyDown`
  while the pane is first responder; neither button has a SwiftUI
  keyboard shortcut (a deviation from the placeholder, which keeps its
  default-action shortcut for the look), so Return or Escape typed
  anywhere else (the sidebar, another pane) can never press them. New
  Session… is drawn prominent (`.borderedProminent`) while Return would
  press it: the pane takes keys and no favorite is selected. ↑/↓ move
  through the favorites that can start, skipping broken ones, and
  **clamp**: ↓ from no selection picks the first, ↑ from the first goes
  back to no selection (where Return opens the dialog), neither end wraps.
  A selection whose favorite is removed or breaks counts as none. Return
  and keypad Enter (not repeats) and Escape act only when the pane is not
  an unfocused pane of a split (`isKeyTarget`, from the focus style, as
  `isDefaultActionEnabled` for the placeholder); other keys are ignored.
- **Focus.** Every path that focuses a pane focuses an empty one too:
  the model's focus changing (a new tab, split or window focuses its
  empty pane), the window appearing, the rename fallback
  (`ContentViewController.focusFocusedPane()`), a click on the pane
  around the card (the chooser's clear background has the tap gesture
  that focuses the pane and so the model; the hosting view covers the
  whole pane, so `EmptyPaneView` itself takes no mouse down, and a click
  on the card's own padding does nothing, as on the placeholder), and the window's
  first responder being lost when a view is replaced. When the pane gets
  its session the chooser view leaves the window and the terminal takes
  focus (`focusPaneWhenShown` as well). ⌘K and other terminal commands
  stay disabled (`focusedPaneView` is `nil` there).
- **Actions.** `WorkspaceActions.startFavorite(_:in:)` resolves the
  favorite, refuses a missing or broken one (`favoriteProblem`) or a pane
  that is gone or has a session, starts it with `startSession(in:request:)`,
  focuses the pane and its terminal. `editFavorite(_:)` presents the form
  in `.editFavorite` mode as a sheet on the window (Save saves and closes;
  Cancel closes). `removeFavorite(_:)` removes without a question.
  `newSession(in:)` and `editFavorite(_:)` share one sheet slot: one sheet
  at a time per window, none while another sheet (a close question) is up,
  and none while the window is closing or entering or leaving full screen
  (`WorkspaceWindowController.canPresentSheet`, as 10b's presenter did):
  New Session… and Return then do nothing, and work again once the
  transition has ended. A sheet is taken down by itself when its pane is
  closed, given a session elsewhere, or leaves the window's workspace (its
  tab dragged into another workspace from another window's sidebar; that
  window shows its chooser), or its favorite is removed (in Settings), and
  when its window closes. The Edit Favorite sheet's Save follows the
  looser rule of Settings › Favorites (`NewSessionForm.canConfirm`:
  `canSave` in the favorite modes, `isValid` for Start), so a broken
  favorite can be renamed from the chooser while it stays broken.
- **Nothing opens a sheet by itself.** The 10b interim
  (`NewSessionPresenter`, which put the dialog on every empty pane) is
  gone; the dialog opens only from New Session… or Return. At launch,
  restored empty panes and the fresh workspace show the chooser.
- **Quit.** The chooser is a view, so it never holds up a quit, and an
  empty pane has no session, so the quit question and menu bar mode count
  nothing for it. `ArmadaleApplication` still ends a New Session or Edit
  Favorite sheet before AppKit's `terminate(_:)` (which refuses while a
  sheet is attached; `AppDelegate.endSheetsForQuit`, tested with a sheet
  of each kind in two windows; the hook from `terminate` to it is not
  unit-tested); a cancelled quit no longer brings the sheet back
  (deviation from 10b: the pane's chooser is still there, so there is
  nothing to resume). `scripts/check-quit.sh`'s first scenario is now
  "chooser up" (a fresh launch shows the window alone, no sheet; SIGTERM
  quits within 2 s and saves the pane empty).
- **Tabs.** An empty pane's tab is titled "New Session" (`displayTitle`)
  and its status glyph's place is left empty in the tab bar and the
  sidebar (`StatusGlyph` takes `nil` for a tab with no session; until 10c
  such a tab showed the hollow "ended" circle).

*Implementation (step 10b).* What the code decides beyond the above:

- The form's rules are `NewSessionForm` (`Panes/NewSessionForm.swift`, an
  `@Observable` class in the app target with no view code; unit-tested in
  `NewSessionFormTests`); `NewSessionSheet` and `NewSessionFormFields`
  (`Panes/NewSessionSheet.swift`) are its views. Modes: new session
  (Start), new favorite (Settings' "+", Save via `addFavorite`), edit
  favorite (Save via `updateFavorite`).
- **Directory prefill.** The source is the window's focused session, or,
  when the focused pane is the new empty one, the session focused before
  it was made: `WorkspaceActions.lastFocusedSessionID`, noted by every
  intent there that makes a pane (and by the target window's actions when
  the pane is made in another workspace from the sidebar). A window made
  by ⌘N takes it from the window it was made from (a deviation from "the
  window's focused pane": the new window has none; 10a did the same). The
  directory is that session's `Session.workingDirectory`, which only OSC 7
  updates (there is no separate registry record): with a shell that does
  not send OSC 7 (seen live: the owner's zsh sets the title but sends no
  OSC 7) it is the directory the session started in. A remote session
  gives `~` and the form starts Local.
- **Hosts.** The picker preselects the only saved host; with several it
  reads "Choose a Host" and Start waits for a choice. A host added while
  the dialog is open and SSH is selected becomes the selected host (it was
  added for this session); otherwise an explicit choice is kept, and the
  only host, chosen implicitly, becomes an explicit choice when a second
  appears (`NewSessionForm.hostsDidChange`). It follows
  `model.hosts`, so a host added through **Add Host…**
  (`AppDelegate.showSettings(tab:)`, now internal, reached through
  `WorkspaceActions.showSettings`) can be picked; a host whose destination
  is blank or unusable (`Host.destinationProblem`, e.g. one just added
  with "+") disables Start with a note to set it in Settings › Hosts. A
  favorite's removed host shows as "Host removed" in the picker (and a
  removed profile as "Profile removed").
- **Options.** Rows come from the flag table (`OptionFlags`): a row is
  shown when the profile runs a program and its agent has that flag, its
  footnote and help name the flag. Titles: Claude Code "Skip permission
  checks", Codex "Skip approvals and sandbox". A hidden field adds
  nothing to the request; switching between agent flavors clears
  everything agent-specific (skip, continue, sandbox, model; the
  additional arguments stay), so neither a dangerous flag nor a model name
  the other agent does not know carries over unseen; a favorite whose
  profile is gone keeps its options until another profile is picked. In
  edit mode the additional arguments are shown re-quoted
  (`NewSessionForm.joinedShellWords`, which `ShellWords.split` turns back
  into the same words).
- **Name.** It follows `proposedFavoriteName` until the user types one; a
  saved favorite whose name equals the proposal for its request keeps
  following when edited.
- **Validity.** `problem` is, in order: SSH without a host, a NUL in the
  directory, `requestProblem` (host or profile removed), a host without a
  usable destination. The problem is shown beside the buttons.
  Settings' editor saves a broken favorite's other edits (`canSave`: only
  SSH without any host and a NUL refuse), so it stays broken until a host
  or profile is picked.
- **Keys.** Return presses Start / Save, Escape cancels. A focused text
  field takes Return before the default button sees it (found live), so
  the fields' `onSubmit` confirms the sheet too; confirming twice is
  harmless (the pane already has its session; Settings' New Favorite
  sheet saves once).
- **Layout.** The sheet is a `.columns` form (it sizes to its content);
  Settings › Favorites uses `.grouped` like Profiles and Hosts. Its New
  Favorite sheet is presented like the workspace dialog
  (`NewFavoriteSheet`: an `NSHostingController` with
  `sizingOptions = [.preferredContentSize]` and `presentAsSheet` on the
  Settings window), so it grows and shrinks with its rows (measured live:
  540×241 Local, 540×273 SSH, 241 again; step 10c). The SwiftUI `.sheet`
  with `.presentationSizing(.fitted)` used in 10b never grew: SSH's Host
  row squeezed the title's top margin. Choose… opens its folder panel as a sheet on the
  window the form is in, so the panel cannot outlive the dialog.
- **Respawn** keeps the session's options on the fresh session too
  (`SessionController.respawn`), so every respawn composes them, not only
  the first.
- **Settings › Favorites.** "+" opens the form as a sheet titled "New
  Favorite" (rather than adding a blank row, which would save a favorite
  nobody asked for); the new favorite is selected. Pickers, toggles and
  the location save at once, text fields when focus leaves them or on
  Return, and the editor when it goes away. Rows show the profile's icon,
  the name, and "This Mac · ~/dir" or "host · dir", or the problem in
  orange with a warning icon. Drag reorders (`moveFavorite`).
- **Host removal.** The existing question (asked only when sessions run
  on the host) adds how many favorites will be broken
  (`HostsSettingsView.removalMessage(sessions:favorites:)`); a host with
  no sessions is still removed without a question.

### App lifecycle

- `NSApplicationDelegate` loads `StateStore`, builds `AppModel`, probes each
  backend's live sessions once, then opens every workspace whose window was
  open at last quit (else the first workspace; with none at all, a fresh
  one: `AppModel.ensureWorkspacesToOpen()`) and attaches its visible
  panes first, the rest lazily when their tab is first shown.
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
  fallback alert up, the state saved on the way out. *Step 10b:* AppKit's
  `terminate(_:)` does nothing at all, without asking the delegate, while
  any window has a sheet attached (measured on macOS 27), so the app's
  `NSApplication` subclass (`ArmadaleApplication`, the principal class)
  lets the delegate end every window's New Session (or Edit Favorite)
  sheet first, and any sheet in Settings; the panes stay empty, are saved
  so and show the chooser again at the next launch. No sheet comes back
  when the quit is cancelled (since step 10c; the pane's chooser is still
  there). Every quit path goes through it (⌘Q, the quit Apple Event,
  SIGTERM, the status menu's Quit and End Sessions and Quit).
  `check-quit.sh` has a third case, the fresh launch's chooser up (step
  10c; in 10b it was the sheet the interim put on every new pane), whose
  window must show no sheet; its "normal" case attaches to a session the
  helper creates beforehand, since a fresh launch starts none. A close
  confirmation sheet still holds a quit up, as before. Closing a pane kills its session after a confirmation if it is
  still running or disconnected (configurable), and also kills a session
  that was never shown (restored but not yet attached). Closing a window
  keeps the workspace.
- Closing the last tab in a tab group removes the tab group. Closing the
  last tab group in a workspace (⌘W on its last pane, Close Tab, Close Tab
  Group, the placeholder's Close Pane), or dragging its last tab into
  another workspace, **deletes the workspace** (October 23, 2026, owner's
  request; until then it stayed in the model and the sidebar as a dimmed,
  empty "closed" row, and reopening it made a fresh "Main" group). It has
  no sessions left, so nothing is ended (a dragged tab's sessions go with
  the tab); its window closes and its row leaves every sidebar. A
  confirmation that is asked anyway names it (section 1). This holds for
  the only workspace too: the model may then hold none, the app keeps
  running with its Dock icon
  (`applicationShouldTerminateAfterLastWindowClosed` is false), and a Dock
  click (`applicationShouldHandleReopen` with no visible window), ⌘N,
  *Open Armadale* from menu bar mode or the next launch makes a fresh
  workspace (named "Workspace" again, the name being free). The model
  returns `CloseResult.deletedWorkspace` (the old `.closedWindow` is
  gone). The window closes the way Delete Workspace closes it: its
  controller sees the workspace leave the model, closes once, reports its
  close (which the app delegate does not record, the workspace being gone)
  and is released; `ArmadaleAppTests` checks this, for ⌘W and for a clean
  exit. A clean exit in a workspace's last pane gets here too (section 4,
  "Ended", since October 23, 2026), through the same `closePane` followed
  by the registry's close, which retires the session and removes its log
  and exit file; in menu bar mode the hidden window closes the same way
  and *Open Armadale* with no workspace left makes a fresh one. A
  workspace closed *with* tab groups (the window's close button, ⇧⌘W) is
  unchanged: it stays, dimmed, its sessions running, and can be reopened.
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
  transition ends (two toggles in the same turn leave the second window
  normal); each becomes its own Space. Since October 23, 2026 every
  full-screen toggle Armadale makes goes through one app-wide serializer
  (`FullScreenSerializer`, owned by the app delegate): launch entries,
  entries on return from menu bar mode, exits for menu bar mode and exits
  before a close. A step starts only when the previous one has finished
  (its transition's completion has run and, for a close, the window has
  closed) and no window is in a transition, a toggle by hand included
  (every window reports its transitions), and always from the default
  run-loop mode on a later turn. A close goes ahead of queued entries; an
  entry whose turn comes in menu bar mode, or for a workspace deleted
  meanwhile, is skipped; a refused toggle still ends its step. Every path
  ends its step, a window closing ends whatever step waited on it, and a
  transition AppKit never ends would hold the queue (no timeout exists).
  A window closed in full screen from outside Armadale's own path
  (⇧⌘W in a full-screen window) still gets AppKit's exit after
  `windowWillClose`, which the serializer does not see (benign in
  review). When Armadale itself closes a window in full screen it notes
  the end of that exit, so the next step still waits the settle time.
  Entries are never retried: a refused or failed restore entry leaves the
  window normal, and it is then saved as not in full screen. Worst-case
  timings measured in review: entries end about 0.6 + 0.9 × (N − 1) s
  after launch for N windows (three windows: 0.63, 1.51 and 2.39 s); a
  close of a full-screen window can take about 4–5 s in the worst case
  (its turn, failed exits retried, the closing exit); a return from menu
  bar mode can wait up to 2 s more per window for its Space. From being queued until its entry starts a
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
  reports from a controller that is no longer the workspace's. A window
  whose workspace leaves the model (or is marked closed) **while it is in
  full screen or in a transition** is never closed as it is (October 23,
  2026, review of the clean-exit change; measured on macOS 27). Closed
  mid-transition, its controller was released and AppKit finished the
  transition on its own, putting the window back on screen at its normal
  frame, titled and empty, and the launch queue, waiting for that
  transition, stalled, so the next window never entered full screen and
  was saved as not in full screen. Closed in full screen while another
  window's transition ran (the launch queue's next entry), it came back
  the same way: the close brings an exit, and the two overlapped. So such
  a window takes its turn in the serializer (no transition anywhere),
  leaves full screen, and closes when that has ended, as a normal window.
  Measured on macOS 27: the exit of a full-screen window that is not on
  the active Space fails (`windowDidFailToExitFullScreen`, with the style
  mask already reading normal, and AppKit then puts the window back into
  full screen), so such a window is closed in full screen instead, as its
  own step, which stays open until the exit AppKit runs after the close
  has ended (about 0.1 s; at most 1.5 s). A failed exit on the active
  Space is tried again after 0.3 s, up to four times, then the window is
  closed in full screen. The serializer also waits 0.3 s after the last
  transition before starting a step: an exit 9 ms after another window's
  entry failed. It enters full
  screen no more meanwhile, and leaving menu bar mode does not show it
  again. The app delegate keeps the controller until `windowWillClose`,
  and the step holds it too. A normal window closes at once.
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
  program running in them (for one session it says "the session" and
  "it", `MenuBarText.alertInformative(running:)`). Buttons: **Keep Running in Menu Bar**
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
  of full screen first. The saved frame and flag were sane either way.
  Each such exit is a step of the full-screen serializer ("Full
  screen"). A full-screen window on another Space cannot be taken out of
  full screen (measured on macOS 27, October 23, 2026: its exit fails and
  AppKit puts it back), so it is ordered out as it is, and on return it
  is brought forward (its Space becomes the active one), leaves full
  screen and re-enters it, which restores its title bar and toolbar
  (checked live with two full-screen windows). This is the usual case,
  not a rare one: switching to the accessory activation policy moves the
  frontmost full-screen window off the active Space too, so after ⌘Q →
  Keep Running every full-screen window gets this treatment on *Open
  Armadale*, one after another, each with a visible Space switch (about
  2.5 s for two windows, measured in review), plus up to 2 s per window
  waiting for its Space to become active. The status item shows the
  app icon's three-pane glyph as a template image, generated by
  `scripts/render-app-icon.swift` into the asset catalog as a
  `StatusItem` image set (18 pt, 1x and 2x), with the attention count as
  text next to it when it is non-zero. Its menu: "N sessions running"
  (disabled), then **Open Armadale**, **Settings…**, a separator,
  **Quit, Keep Sessions Running**, **End Sessions and Quit**. Its tooltip
  names attention when there is some, else "Armadale: sessions running",
  or just "Armadale" when none is running. Menu bar mode stays when the
  last session ends (a clean exit may even delete every workspace
  meanwhile): the status item remains, reading "0 sessions running", and
  the app never leaves menu bar mode or quits on its own (owner's
  decision, October 23, 2026). Attention
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
(`MenuBarText`), the status item (`MenuBarStatusItem`) and bringing the
app forward (`AppActivation`, "Activation" below);
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
- **Activation.** The quit alert (a quit sent from the Dock or a script
  comes while another app is active), *Settings…* and *Open Armadale*
  from the status menu, and Help › Keyboard Shortcuts and
  Help › Acknowledgements, bring the app forward with
  `AppActivation.bringForward()`: when another app is frontmost it calls
  `NSRunningApplication.current.activate(from:options:)` with that app
  (as if it had yielded; *Open Armadale* adds `.activateAllWindows`),
  else `NSApp.activate()`. Found November 9, 2026 on macOS 27 with a real
  click on the status item and the item chosen from its menu: plain
  `NSApp.activate()` is refused (cooperative activation, macOS 14 and
  later), so Settings opened behind the active app's front window, drawn
  inactive, and *Open Armadale* left the regular app inactive with its
  windows behind; switching to the regular policy before `activate()`
  was refused the same way; the quit alert, which still called
  `NSApp.activate()`, opened behind the active app's front window
  (November 12, 2026, a scripted quit with Terminal active).
  `activate(from:)` was let through every time
  (the app active, the window key and in front). `activate(ignoringOtherApps:)`
  also worked but is marked to be deprecated and is not used.
  Settings and the Help windows shown from menu bar mode keep the
  accessory policy (no Dock icon), so the menu bar stays the previous
  app's while they are in front; their key equivalents still work (⌘W,
  ⌘Q, editing). Testing artefact: System Events' `frontmost` reports
  false for an accessory app even while it is active (use
  `NSWorkspace.frontmostApplication`).
- **Closing Settings in menu bar mode** (⌘W, the close button) would
  leave an active accessory app with no window, so keystrokes would go
  nowhere: once the close is done the app hides (`NSApp.hide`), which
  gives the previously active app its menu bar and keyboard back.
  `NSApp.deactivate()` was tried first and does not: the accessory app
  stayed the frontmost application. The status item stays while hidden,
  and every way back (`leaveMenuBarMode()`, *Settings…*) unhides.
  Testing artefact: `NSRunningApplication.isHidden` stays false for an
  accessory app after a successful `hide` (`NSApp.isHidden` is true;
  checked November 12, 2026 with a windowless accessory app), so the
  check is that the previously active app is frontmost again.
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

Rebinding is out of scope for v1; the table is shown read‑only under
Help › Keyboard Shortcuts (in Settings until October 29, 2026). Every
binding is a menu item key equivalent, so System Settings › Keyboard ›
Keyboard Shortcuts › App Shortcuts can rebind any of them by menu title
without Armadale's help.

*Step 4 notes.* Every row is an `NSMenuItem` key equivalent (built in
`App/MainMenu.swift`, which is the shortcut table's source),
so the shortcuts appear in the menus and work whatever has focus, and keys
not bound there reach the terminal (since step 5 the table shown in the
app, Help › Keyboard Shortcuts, is generated from these menu items). ⌃Tab / ⌃⇧Tab and ⌘+ are hidden
alternates (`allowsKeyEquivalentWhenHidden`) of ⇧⌘] / ⇧⌘[ and ⌘=. ⌘9 goes
to the last tab, ⇧⌘9 to the ninth tab group. Show Tab 1…8, Show Last
Tab and Show Tab Group 1…9 are hidden commands of the Window menu
(owner's decision, October 30, 2026: eighteen rows crowded it; the tab
bar shows ⌘N and the sidebar ⇧⌘N instead); their key equivalents work
and the table lists them, but as they are not visible menu titles,
rebinding them in System Settings › App Shortcuts was not checked. ⌃⌘ arrows move the nearest
divider by 5 % of its split (`moveDivider`). ⌘= / ⌘- / ⌘0 change the font
size of every pane; since step 5 the size is the stored Appearance
setting, so it persists across launches. ⌘, opens Settings (step 5).
Commands also in the menus
without a default key: Close Tab, Close Tab Group, Delete Workspace, and
(step 7) Window › Clear All Attention. (Renaming is inline, in the sidebar
and the tab bar, and has no menu command.)

*October 24, 2026:* in an empty pane (section 8, "New sessions") Return
opens the New Session dialog or starts the selected favorite, ↑/↓ select a
favorite and Escape cancels; the dialog's Return is Start. No menu item was
added or rebound.

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

A pane runs whatever the New Session dialog chose (until October 24, 2026
it was "just a shell" by default). The agent profiles only add:

- a launch program (`claude`, `codex`) and arguments; the resolved
  `LaunchSpec` is stored on the session, and a respawn takes the profile
  as it is then plus the session's own `SessionOptions` (falling back to
  the stored launch if the profile is gone);
- (October 24, 2026) the per-session options the dialog offers for the
  agents Armadale knows, as a flag table in `AgentIntegration`
  (section 8, "New sessions"); checked against `claude 2.1.304` and
  `codex-cli 0.163.0`, to be re-checked with the rest of this section when
  either is upgraded;
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
│   ├── Panes/                       PaneContainerView, SplitTreeView, PaneView, SessionPlaceholderView,
│   │                                EmptyPaneView + NewSessionPaneView + NewSessionChooser (the
│   │                                chooser), NewSessionSheet + NewSessionForm (the dialog),
│   │                                PaneMenu (the pane context menu builder, PaneThemeBinding,
│   │                                ActionMenuItem), PaneCardStyle + PaneHeaderView (pane cards:
│   │                                geometry and borders, the header and its hosting view)
│   ├── Sessions/                    SessionRegistry (controllers per session, a backend per host,
│   │                                RemoteSessionSupport), SessionStatus / CloseRisk,
│   │                                AttentionCenter (+ NotificationService, NotificationPolicy)
│   ├── Settings/                    SettingsWindowController, Preferences, SwiftUI tabs
│   │                                (General, Appearance, Profiles, Hosts, Favorites)
│   ├── Help/                        ShortcutTable, ShortcutsWindowController (Help › Keyboard Shortcuts),
│   │                                AcknowledgementsWindowController (Help › Acknowledgements)
│   ├── Resources/                   AppIcon.icon (Icon Composer document), Assets.xcassets
│   │                                (AppIcon rasters, StatusItem template glyph), Info.plist,
│   │                                Armadale.entitlements,
│   │                                armadale-notify (helper for agent hooks → Contents/Resources),
│   │                                Acknowledgements.txt (third-party notices → Contents/Resources)
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
├── Vendor/dmgbuild/                 dmgbuild virtual environment for releases (git‑ignored)
├── scripts/                         fetch-zmx.sh, zmx.lock, embed-zmx.sh, check-quit.sh,
│                                    render-app-icon.swift, release.sh, install-release.sh,
│                                    fetch-dmgbuild.sh, dmgbuild-requirements.txt,
│                                    render-dmg-background.swift, dmg/ (settings.py and the
│                                    generated window background)
├── docs/                            DESIGN.md, icon/AppIcon.svg (generated master vector)
├── LICENSE, CONTRIBUTING.md         MIT license; contribution terms
├── THIRD_PARTY_LICENSES.md          bundled components' licenses, colour-scheme credits
│                                    (mirrored in Armadale/Resources/Acknowledgements.txt)
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
  needs signing.
- **Third-party notices.** SwiftTerm (linked) and `zmx` (bundled) are
  MIT-licensed, which requires their copyright and license notices in
  every copy; the DMG is one. They ship in the bundle as
  `Contents/Resources/Acknowledgements.txt`, shown by Help ›
  Acknowledgements (section 8), with the colour-scheme credits; it is a
  plain resource and needs no signing of its own. When a bundled
  component or its notice changes, update `THIRD_PARTY_LICENSES.md` and
  the resource together (`AcknowledgementsTests` fails when the file
  gains a notice the resource lacks; nothing compares either with the
  upstream text, so re-read the upstream LICENSE on a bump). A Release
  build must launch and run sessions: the
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
     (Since November 2026 the DMG is built with dmgbuild and has a
     designed Finder window; see "The DMG window" below.)
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
  dmgbuild also runs `hdiutil create`, `attach` and `convert`, and each
  prints the same kind of warning on stderr.

**The DMG window (November 2026).** A deviation from the plain DMG of
step 4: opening the DMG shows a laid-out Finder window instead of two
icons on white. It is built with
[dmgbuild](https://github.com/dmgbuild/dmgbuild) (MIT), which writes the
window's `.DS_Store` directly, so nothing drives Finder or AppleScript and
the build needs no logged-in UI.

- *Layout.* Icon view, 600 × 400 points (`window_rect` `((200, 250),
  (600, 400))`; dmgbuild documents y as running bottom to top, and Finder
  moves a window that would be off screen back onto it), no sidebar,
  toolbar, status bar or path bar, icon previews off, 128 pt icons with
  13 pt labels below. Positions are Finder's: each icon's centre, in
  points from the top-left of the content area. `Armadale.app` is at
  (150, 200) and the `Applications` symlink at (450, 200); the hidden
  `.background.tiff`, `.VolumeIcon.icns` and `.DS_Store` are placed at
  (900, 900), outside the window, so Finder's "show all files" does not
  put them over the design (dmgbuild writes an `Iloc` for every name in
  `icon_locations`, whether or not it added the file). The
  background is the website's light ground `#F5F5F7`; a 3 pt arrow in
  the website's muted `#6E6E73`, with round caps and an open head, runs
  from x 230 to 370 at y 200, between the two icons (the app icon's right
  edge is at 214, the folder's left edge at 386); the caption "Drag
  Armadale to Applications", system font 13 pt in `#6E6E73`, is centred
  at (300, 320). The brief said about y 300; the icons' labels occupy
  about 268–286, so 320 keeps a clear gap under them. Nothing else: no
  logo (the app icon itself is the first item), no other text.
- *Background.* `scripts/render-dmg-background.swift` draws it with
  CoreGraphics and Core Text (offscreen, no UI) in the same top-left
  coordinates and writes `scripts/dmg/background.png` (600 × 400 px,
  72 dpi), `background@2x.png` (1200 × 800 px, 144 dpi) and
  `background.tiff`, both combined with `tiffutil -cathidpicheck`. The
  three are committed, so a release renders nothing; rerun the script
  after changing it (`swift scripts/render-dmg-background.swift`), never
  edit the images. The settings point dmgbuild at the TIFF; dmgbuild
  copies it into the volume as `.background.tiff` (at the root, not in a
  `.background/` folder) and records it in `.DS_Store` as an alias and a
  bookmark. (dmgbuild can also take a PNG and combine an `@2x` file next
  to it with `tiffutil` itself; the committed TIFF makes that step
  unnecessary, and the TIFF's name has no `@2x` sibling, so dmgbuild uses
  it as it is.)
- *Volume icon.* The plain app icon. `release.sh` builds
  `build/release/dmg/Armadale.icns` with `iconutil` from the 16–1024 px
  rasters of `Assets.xcassets/AppIcon.appiconset`, rather than reusing
  the app's own `Contents/Resources/AppIcon.icns` (compiled by actool
  from the Icon Composer document), which holds only the 16 and 128 pt
  sizes. dmgbuild copies it to `.VolumeIcon.icns` and sets the volume's
  custom-icon flag with `SetFile -a C`.
- *Image.* `scripts/dmg/settings.py` is the dmgbuild settings file (it is
  Python): volume "Armadale", UDZO, HFS+ as before, the app (passed as
  `-D app=…`, copied with `ditto`, so its signature and stapled ticket
  are kept), the `Applications` → `/Applications` symlink, the volume
  icon (`-D icon=…`) and the window above. dmgbuild creates a read-write
  image, attaches it with `-nobrowse` (Finder shows nothing), fills it,
  shrinks it and converts it to UDZO. dmgbuild attaches the scratch image
  at `/Volumes/Armadale` and the background bookmark records that path,
  so the preflight fails with "a volume named Armadale is mounted; eject
  it first" if one is.
- *Checks inside the image.* dmgbuild ignores the exit status of the
  `ditto` that copies the app and of `SetFile`, so before signing the
  DMG `release.sh` mounts it read-only (`hdiutil attach -nobrowse
  -noautoopen -readonly` at `build/release/dmg/mount`) and requires:
  `diff -r` of the archived app and the copy finds nothing; `codesign
  --verify --deep --strict` passes on the copy; on the notarized path
  (the DMG is built from the app stapled in step 3) `xcrun stapler
  validate` passes on the copy; `Applications` is a symlink to
  `/Applications`; `.background.tiff`, `.VolumeIcon.icns` and `.DS_Store`
  exist; `GetFileInfo -aC` on the volume prints 1. It detaches the image
  afterwards, and an `EXIT` trap detaches it when a check fails.
  Everything after that is unchanged: `codesign` of the DMG, `codesign
  --verify --strict`, `hdiutil verify`, notarization, stapling and the
  Gatekeeper checks.
- *Pinned environment.* `scripts/fetch-dmgbuild.sh` mirrors
  `fetch-zmx.sh`: it makes `Vendor/dmgbuild/` (git-ignored) a virtual
  environment of `/usr/bin/python3` (Python 3.9.6 on this Mac, from
  Xcode) with `python3 -m venv` (its pip comes from Python's bundled
  ensurepip, so only the packages are downloaded) and installs
  `scripts/dmgbuild-requirements.txt` with `pip install --isolated
  --require-hashes --only-binary :all:` and `PIP_CONFIG_FILE=/dev/null`
  (`--isolated` alone still reads the global and site `pip.conf` and a
  `PIP_CONFIG_FILE`; `/dev/null` makes pip skip every configuration
  file): dmgbuild 1.6.5, ds_store 1.3.1
  and mac_alias 2.2.2, each pinned to the SHA-256 of its PyPI wheel. These
  are the newest releases that support Python 3.9 (dmgbuild 1.6.6,
  ds_store 1.3.2 and mac_alias 2.2.3 and later need 3.10; a newer
  `/usr/bin/python3` works with the same pins, and the script does not
  check the version). The install stores the SHA-256 of the requirements
  file in `Vendor/dmgbuild/requirements.sha256`; a run does nothing when
  that matches the current file, the installed versions are the pinned
  ones and dmgbuild imports, and otherwise (a changed pin or hash, a
  broken environment) rebuilds it from an empty directory. A failed
  install leaves no environment behind. `--check` only verifies, the same
  way. pip checks the wheel hashes at install time; later runs do not
  re-hash the installed files. `release.sh` runs `fetch-dmgbuild.sh --check`
  in its preflight, before the archive, and stops with "run
  scripts/fetch-dmgbuild.sh" if it fails; it runs dmgbuild as
  `Vendor/dmgbuild/bin/python3 -I -m dmgbuild` (isolated mode: no
  `PYTHON*` variables or user site-packages, and no dependence on the
  `bin/dmgbuild` launcher's absolute interpreter path). Nothing from
  dmgbuild ships in the DMG.
- *Not checked without a Finder window.* The `.DS_Store` contents
  (window bounds, view options, icon positions, background reference) are
  checked by parsing the file with the environment's `ds_store` module;
  how Finder actually draws the window has to be looked at by opening the
  DMG. Whether Finder treats `WindowBounds` as the content size or the
  whole window including its title bar is not documented; if the latter,
  the bottom ~28 points of the background are hidden, which is plain
  ground colour.

---

## 12. Build order

Each step was built by an implementer agent, reviewed by a separate
reviewer agent (code reading plus live keystroke checks of the running
app), fixed, verified with the full build and test command, and committed
on `main`. Steps 1–7 are done: d0c4587, 93019d8, f6cedbb, 76a4e4e,
4d3ab86, 7302a12, dac547f (October 16–18, 2026); steps 8 and 9 on October 19;
step 10 (added later at the owner's request) on October 24.
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
10. **New Session** (owner's request, October 24, 2026; section 8, "New
    sessions"), in three sub-steps, each through the loop: **10a** the
    model (empty panes, `SessionOptions`, `Favorite`, `startSession`, the
    favorite intents, `ShellWords`, and, moved forward from 10b, the option
    flag table) and the removals (the two
    File items, the "+" context menu, General's defaults), with the app
    still starting a shell in every new pane through `startSession` so it
    stays usable; **10b** the New Session dialog and Settings › Favorites; **10c** the chooser in every new pane,
    Cancel's cascade, restore of empty panes, and the README; the repair
    then also turns a pane whose `sessionID` names a missing session into an
    empty pane showing the chooser (until then it was kept and showed the
    blank view). *Done* (October 24, 2026).

---

## 13. Risks and open points

- **Pane headers preference** (October 31, 2026). Pane cards (section 8)
  always show their header row in the first version; a "Show pane headers"
  preference that keeps the cards and gutters but drops the row is
  deferred by the owner's decision. When it comes, the pane context menu
  needs another entry point while headers are hidden.
- **New Session (step 10).** A state file holding an empty pane is not
  readable by builds before it (accepted: unreleased). The Codex and Claude
  flag names are version facts and will rot; the chooser adds one more
  "pane without a terminal" state whose focus
  and first-responder behaviour must match the placeholder's (the Return
  bug fixed on October 23, 2026 came from exactly that gap). Step 10c
  makes the empty pane first responder on every focusing path and tests
  it (`NewSessionChooserTests`); the live check is the reviewer's.
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
- **Lost exit codes** (resolved October 23, 2026). zmx discards the
  program's exit status; a recorder around the program now writes it next
  to the session (section 4, Ended), a clean exit closes its pane, and the
  placeholder shows the status otherwise. Still unknown: sessions created
  before this version (no recorder), a session ended from outside (zmx
  kill, the daemon killed, a hangup, a reboot, a SIGKILL of the recorder)
  and the plain-ssh fallback when ssh itself fails; the placeholder then
  says only that the session is no longer running. On hosts a normal exit
  with status 128 or more cannot be told from a death by signal and is
  read as one.
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
