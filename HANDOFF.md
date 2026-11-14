# HANDOFF.md — where development stands

Point-in-time status for whoever picks Armadale up next: where things
stand, what is next, what waits for the owner, the open items. Update
this file whenever work pauses. The durable rules for working in this
repository are in `AGENTS.md`; the design contract, what is true now,
is `docs/DESIGN.md`; why and when (the change log, and the history of
each design section) is `docs/HISTORY.md`; build and run instructions
are in `README.md`.

## Status (November 14, 2026)

Steps 1–10 of the build order (`docs/DESIGN.md` §12) are implemented,
reviewed and committed on `main`. Armadale 0.1.0 (tag `v0.1.0`, October
23, 2026) and 0.1.1 (tag `v0.1.1`, the first public release, November
5, 2026) are released, notarized and stapled; the code is under the MIT
License and https://armadale.dev is live. Since the build order the
sidebar, the tab bar and the panes (now cards with a header and a pane
menu) were reworked, a clean exit closes its pane, menu bar mode and the
quit alert activate the app again, and on November 14, 2026 the first
findings of an architecture review were built: one Armadale process per
state directory, a safer orphan reclaim and save schedule, and state
file schema 2. The last gate run: 761 tests, zero warnings. What each
change was, how it was checked and what was found on the way is in
`docs/HISTORY.md`.

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

Since the build order (changes to the app and its scripts; the
investigations, the step 10 design and other documents-only commits
are in `docs/HISTORY.md`):
- October 18, 2026: the app icon, "Panes" (bbf81a4).
- October 19, 2026: `scripts/install-release.sh` (cf9305c).
- October 19, 2026: Armadale 0.1.0 build 1, from 72cf014 (untagged).
- October 19, 2026: About panel copyright holder (f3855aa); sidebar
  toggle moved (a2c236b); plain folder icon for tab groups (628c99e);
  AGENTS.md: end test builds by pid (26c6699).
- October 20, 2026: inline renaming in the sidebar and tab bar
  (ba9ecf5).
- October 20, 2026: the full-screen frame fix (f67d804).
- October 23, 2026: Armadale 0.1.0 build 2, tagged `v0.1.0` (bump
  fd96512; built from 524c9da).
- October 23, 2026: About panel on two lines; no dimming of unfocused
  panes (9e47bee).
- October 23, 2026: a clean exit closes the pane (f218600).
- October 23, 2026: an empty workspace is deleted automatically
  (a651532).
- October 23, 2026: a clean exit closes a workspace's only pane too;
  `FullScreenSerializer`; Return presses the placeholder's button
  (2462fe6).
- October 24, 2026: step 10 (table above).
- October 29, 2026: Shortcuts moves from Settings to Help › Keyboard
  Shortcuts (c4e45e0).
- October 29, 2026: sidebar icon colours (5b005b6), highlight on the
  shown path (204627f), a click on a shown row writes nothing
  (5249216).
- October 29, 2026: the sidebar has no selection and no highlight
  (831b9af).
- October 30, 2026: sidebar title weight follows the shown path
  (9162c7e).
- October 30, 2026: the tab bar drawn like the native macOS 27 one
  (60e107d).
- October 30, 2026: tabs fill the track; three tab bar bugs fixed
  (49fd474).
- October 30, 2026: Show Tab items hidden from the Window menu; ⇧⌘N on
  sidebar tab group rows (2b64971).
- October 30, 2026: a pane context menu with a Theme submenu (ebec034).
- October 30, 2026: no mouse event opens the pane menu (a9f13c8).
- October 31, 2026: pane cards, designed (20b315b) and built (8f601d1).
- October 31, 2026: Split Right and Split Down in the pane menu and as
  header buttons (2695c1b).
- October 31, 2026: header split buttons dropped; Session Ended no
  longer dimmed (6e0e0ca).
- October 31, 2026: a split, tab switch or zoom no longer soft-resets
  the program (c2c3aa2).
- November 4, 2026: MIT License (7047a64).
- November 4, 2026: the pre-publication scan, Help › Acknowledgements
  and the armadale.dev page (7fc2e32); the site went live that night.
- November 5, 2026: the release DMG opens to a designed Finder window
  (a39f3ab); 0.1.1 build 27 (7560281), tagged `v0.1.1` and released
  on GitHub (ade6f27).
- November 5 and 9, 2026: Help › Acknowledgements checked live; new
  live-testing rules in AGENTS.md (8ef4178).
- November 9, 2026: menu bar mode activates the app again (dcdeb50).
- November 12, 2026: the quit alert comes forward again (704a941).
- November 12, 2026: an architecture review, recorded (298e881); its
  second pass, November 14, 2026 (75a22c8).
- November 14, 2026: one Armadale process per state directory
  (ab27dfe).
- November 14, 2026: reclaim and save safety (64221bb).
- November 14, 2026: a rule for the state file's version; schema 2
  (d34d3af).
- November 14, 2026: the documents split: `docs/DESIGN.md` holds the
  contract, `docs/HISTORY.md` the change log and each section's
  history, and this file where things stand (fe20ea1).

## Next

Nothing is in progress. The owner gave the go-ahead on November 14,
2026 for the architecture review's items in the suggested order
("Architecture review" and its second pass, at the end of the open
items), and they are done: the lock, the orphan reclaim and save
scheduling changes, the schema rule, and the documents (this file cut
to where things stand, its change log and the history of each
`docs/DESIGN.md` section moved to `docs/HISTORY.md`). What comes next
waits for the owner.

Waiting for owner decisions:
- **Attaching restored sessions at launch**, a step of its own: it
  needs an owner decision on pane sizes ("Restored sessions in tabs not
  shown yet are not attached" and what the second pass adds to it).
- **Showing or re-adopting spared sessions** (open items, Session
  layer, and "Adds to Orphan reclaim").
- **A fork of the persistence helper** ("The persistence helper's
  workarounds").
- **The Ghostty second renderer** ("Decisions pending" below).
- **An updater.** There is no updater in v1 (step 9: the repository
  was private then, so a Sparkle feed had no public home). The
  repository is public now and https://armadale.dev is live, so a feed
  has a home (GitHub Releases or the site); whether a later version
  gets an updater is the owner's call.
- **macOS 27's "Allow in the Background" switch:** what step 8 should
  say or do about it, since it ends every session a few seconds after
  any quit when it is off, from the menu bar too (tested October 19,
  2026, evening; "Decisions pending" below). The owner deferred that
  decision on October 19, 2026; it is an open item, not started.
- Any of the open items below.

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
- Spared sessions (November 14, 2026) are invisible and never end by
  themselves: sessions that were running when a launch could not read
  its state file as written stay in `sparedSessionIDs`, no pane shows
  them, and End Sessions and Quit leaves them alone. The `state` log
  line of each launch gives their number and how many still run. By
  hand: `ZMX_DIR=<state directory>/run <state directory>/bin/zmx-0.8.1
  ls`, and `kill a-<id>` to end one. Showing them, or offering them
  back as panes (which needs a record of what each one runs), is an
  owner decision. Their helper version is not recorded, so after the
  bundled helper changes the old copy is removed and listing or ending
  them with the new one may time out (DESIGN section 13). In a run on
  the plain PTY fallback the flag stays set, so the reclaim is held
  back until a run with the persistent runtime (intended).
- The helper's listing leaves out a daemon that does not answer within
  about a second and still succeeds (November 14, 2026, `kill -STOP`).
  The reclaim no longer depends on it for what it spares, but the rest
  of the app does (from the code, not staged in the app): restore at
  launch shows such a session as Session Ended with no status, a
  Respawn there starts a new session while the old daemon keeps
  running unreferenced, and `exists()` after a client goes away and
  Respawn All Ended on hosts use the same listing.
- A clean launch of an unchanged state file still writes `state.json`
  once or twice in its first seconds, with the same content (seen
  November 14, 2026; not the reclaim, which saves only when it changed
  something; window-state recording after the window opens is
  suspected, not looked into).
- Quarantine names resolve to the second
  (`state.json.corrupt-<seconds>`): a second failure in the same
  second cannot be moved aside and stays in place (older, not
  triggered).
- The `/tmp/armadale-<uid>` fallback for the runtime directory is
  shared by every state directory whose socket paths would be too
  long, so an allowed reclaim in one would end the other's sessions
  (inferred from the code, not reproduced; it needs two long paths,
  and test directories under `/tmp` are short).
- Not staged live (November 14, 2026, reclaim and save safety): a
  failing disk under a stream of changes (the retry timing has unit
  tests only; one attempt with a read-only state directory produced no
  save attempt at all, not looked into).

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
- A copy started from a shell or a script by its binary path does not
  come forward on a normal launch: the plain `NSApp.activate()` at the
  end of `applicationDidFinishLaunching` is refused while another app
  is active, as the quit alert's was (seen November 14, 2026 with
  Terminal frontmost; a launch through Finder, the Dock or `open` is
  not affected). A fatal launch uses `AppActivation.bringForward()`
  and does come forward. Left alone: it only shows with test builds,
  where staying behind may even be wanted.
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
- Decision (coordinator, November 9, 2026; owner may overrule):
  Settings and the Help windows shown from menu bar mode keep the
  accessory policy, so no Dock icon appears and the menu bar stays the
  previous app's; key equivalents work.
- Still not tested (November 9 and 12, 2026): Open Armadale while
  already frontmost; ⌘Q from Settings in accessory mode.

Shipping (step 9)
- The app icon's lit coral (`#F26B4A`) should become the in-app attention
  colour (Dock badge, status glyphs); today those use their own colours.
- No updater and no crash reporting (decided for v1, October 19, 2026).
- Older builds on a newer state directory (November 14, 2026). Once a
  build with schema 2 has saved a state directory, 0.1.0 and 0.1.1
  refuse it by version, so going back to them means moving the state
  files away first. Before their alert they install their own helper
  copies in `bin/` and remove every other `zmx-*` and `ctty-exec-*`
  copy there (read from both tags, not run). That is harmless while
  every build bundles helper 0.8.1, since the later build puts its
  copies back at its next launch; with a later helper version it would
  remove copies that live sessions still need, and with both running
  at once (0.1.x takes no lock) the later build cannot start sessions
  until it is relaunched. A constraint for the next helper version
  bump (DESIGN section 13).
- The release checklist grew (README, "Releasing"): run
  `scripts/check-state-compat.sh` before a release, and add the new
  tag's fixture after it (`scripts/state-fixtures/README.md`). The
  comparison step needs `/usr/bin/python3`, which Xcode provides.
- Known limit of the instance lock (November 14, 2026): builds before
  it, 0.1.1 included, take no lock, so the installed app and a new
  build are not kept apart until the installed app is replaced;
  AGENTS.md's isolation rule still stands.
- The installed 0.1.1 has neither activation fix (dcdeb50, 704a941);
  a new release would ship them.

From finished changes: not checked live, and found and not fixed
- Step 10, New Session (October 24, 2026).
  - 10b live check to do: nobody has run a real Codex session with
    `--model`, `--sandbox` or
    `--dangerously-bypass-approvals-and-sandbox` to see whether they,
    like the `-c` overrides §10 records, make Codex run "without the
    shared background server"; they parse together fine (`codex …
    completion zsh` exits 0).
  - The directory prefill comes from `Session.workingDirectory`, which
    only OSC 7 updates, and the owner's zsh sends none, so the prefill
    is `~` until shell integration exists (owner decision, not
    started).
  - Not checked live in 10b: full screen and menu bar mode
    with a sheet up, a host deleted while the sheet is open, broken
    favorites in Settings, the host-removal count sentence, Codex
    options, a real SSH start.
  - Not checked live in 10c: menu bar mode with a chooser pane, keypad
    Enter, hover, a scrolling favorites list, dark mode, ⇧⌘N / tab bar
    "+" / sidebar New Tab in 10c (they share the path), Add Host… from
    the Edit Favorite sheet, zoom with a chooser, the compact
    Disconnected and Unavailable cards. Known: compact chooser rows
    show only icon and name, so a remote favorite in a narrow pane does
    not show its host.
- Help › Keyboard Shortcuts (October 29, 2026, c4e45e0). **Not checked
  live** (the Mac was not free): the window itself (Help › Keyboard
  Shortcuts, its size, ⌘W closing it, menu bar mode).
- Sidebar (October 29, 2026). Not checked live: that `appearsActive`
  flips the icons on every activation path (5b005b6). From 831b9af:
  **found and not fixed:** a double-click on another workspace's row
  whose window, once brought forward, covers the clicked spot starts no
  rename (the second click lands in that window); the context menu's
  Rename works. **VoiceOver was not checked live.**
- Tab bar (October 30, 2026). Increase Contrast strengthens the
  hairlines (tested, not seen live; 60e107d). From 49fd474: **known and
  not fixed:** dragging a tab does not auto-scroll the track, so only
  visible tabs are drop targets. **Not checked live:** the attention
  reveal's scroll (same selection-change path), a sidebar toggle at the
  same moment as a selection change, a tab closed during a live resize,
  and the last fix in dark mode.
- Window menu and sidebar badge (October 30, 2026, 2b64971). **Not
  checked live** (the Mac was not free): the Window menu's look without
  the items and the sidebar badge; the owner will see both on the next
  install.
- Per-pane themes (October 30, 2026, ebec034). **Not re-verified by
  the reviewer:** ⌘Q through the quit alert then relaunch, respawn,
  theme import/remove, forced light, the Session Ended placeholder,
  attention colours on a themed pane. (Its Control-click items went
  with the mouse paths in a9f13c8.)
- Pane cards (October 31, 2026, 8f601d1). **Not checked live:** the
  *Disconnected* placeholder, Increase Contrast, dark mode for the
  review fixes, release on the respawn path (the close path is
  tested). The "Show pane headers" preference is deferred
  (`docs/DESIGN.md` section 13).
- Split Right and Split Down in the pane menu (October 31, 2026,
  2695c1b). **Not checked live:** dark mode, the dialog's directory
  after a split (unit-tested), a pane moved to another window.
- Session Ended no longer dimmed (October 31, 2026, 6e0e0ca). **Not
  checked live:** dark system appearance; the disconnected,
  reconnecting, unavailable and host-removed placeholders; the
  reconnect ordering of the show sequence.
- Help › Acknowledgements (November 5 and 9, 2026). Minor: a reopened
  window keeps its scroll position.

Architecture review (November 12, 2026)

Findings from reading the documents and the code. Nothing was built or
run, so none is reproduced live. Of its suggested order, the orphan
reclaim, the save scheduling and the schema rule were built on November
14, 2026, and the documents were split the same day
(`docs/HISTORY.md`). The owner then kept the rule that every agent
reads all of `docs/DESIGN.md` and this file before changing code, which
closes the finding on the documents. Attaching restored sessions at
launch needs an owner decision on pane sizes and is a step of its own.
- **Restored sessions in tabs not shown yet are not attached.**
  `SessionRegistry.startIfNeeded` is called only for the panes of a
  window's selected tab (`ContentViewController.show`) and by
  `retryPersistence`, as DESIGN section 8 "App lifecycle" says ("the
  rest lazily when their tab is first shown"). Until then a restored
  session has no client, so its bell or OSC 9 / 777 never reaches
  `AttentionCenter`: no ◐, no badge, no notification, for an agent
  that finished in a tab not visited since the relaunch. Attaching
  every live restored session after launch needs a size before the
  pane is laid out (an attach at another size resizes the program);
  saving each pane's last grid size would give one.
- **The persistence helper's workarounds.** Create's double attach,
  attach-only through `/usr/bin/true`, telling the cases apart by a
  client's first bytes within 2 s, the RIS filter, the flood reattach
  by sampled footprint (local only) and the exit recorder all make up
  for what zmx 0.8.1 lacks. An attach-only flag, the program's exit
  status and a bounded client buffer, upstream or in a fork, would
  remove most of them.
- **Live UI testing shares the owner's screen.** Most of AGENTS.md's
  "Rules learned the hard way" guards against synthetic input landing
  in the wrong place. A macOS guest VM for those passes would remove
  the risk instead of guarding against it.
- Smaller: `AppDelegate` (955 lines on November 12, 2026; about 1,150
  two days later) holds launch, the quit paths, menu bar mode and
  window management, and the quit paths already need
  `scripts/check-quit.sh`; some 17 `NSLog` calls remain in the app
  beside the `Logger`s, although NSLog is `<private>` in `log show` on
  macOS 27 (10c, `docs/HISTORY.md`); the load-sensitive flood tests
  run beside four other test bundles in the gate. Seen in review on
  November 14, 2026: a clean `xcodebuild … build-for-testing` into a
  fresh DerivedData fails with "Unable to resolve module dependency:
  'Armadale'" at
  `ArmadaleAppTests/SidebarShownPathTests.swift:4` (`@testable import
  Armadale`), while the gate's `build test` passes from a fresh
  DerivedData; older, not looked into.

Architecture review, second pass (November 14, 2026)

The findings above were read against the code again and stand. Three
are new and three add to ones above. Again from reading only: none is
reproduced live. The first new one, the instance lock, was built on
November 14, 2026 (`docs/HISTORY.md`); attaching restored sessions at
launch stays a step of its own.
- **New: the status of a session never shown is the launch probe's
  answer, and is never refreshed.** For a restored session without a
  controller, `SessionRegistry.status(of:)` answers from `liveAtLaunch`
  (local) or `remoteLive` (hosts), which are set when the launch probe
  answers, after a successful `retryPersistence`, and for a host by
  Respawn All Ended's listing. A session that ends in a tab not
  visited since the launch therefore stays `.running`: in its tab's
  and the sidebar's glyph, and, through `CloseRisk.mayBeRunning`, in
  `runningSessionCount()`, which is what the quit question and the
  status item's menu show. It is corrected when the tab is first
  shown. Same cause as "Restored sessions in tabs not shown yet are
  not attached", and attaching them at launch removes it.
- **Adds to "Restored sessions in tabs not shown yet are not
  attached".** A controller exists only inside a pane view
  (`SessionRegistry.panes` is `[SessionID: PaneView]`, and
  `controller(for:)` reads it from there), which is why nothing can
  be attached before it is shown, and why `status(of:)`, `isEnded`,
  `riskItem`, `close`, `endAllSessions`, `sessionsRunning(after:)`,
  `respawn` and `closeRestoredSessionsThatEndedCleanly` each have a
  second path for a session never shown. A registry that holds the
  controllers itself, with the pane view made when a pane is first
  shown, makes the attach at launch possible and lets those paths go.
  `SessionRegistry` (868 lines) and `AppDelegate` (955) are best split
  in that step, not before.
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
  2026** (`docs/HISTORY.md`): the reclaim now spares what it cannot account
  for, but nothing shows the spared sessions or offers them back; that
  part is still the owner's decision (open items, Session layer).
- **Adds to "Save scheduling".** Besides a longest wait, the title and
  the working directory (`AppModel.setTitle`, `setWorkingDirectory`)
  could stay out of what schedules a save and be written with the next
  structural change and at quit: the persistence helper replays both
  on attach, so the saved copies matter only for sessions that are not
  attached. `AppModel` is one `@Observable` object and
  `displayTitle(for:)` reads `sessions`, so every title change also
  re-evaluates the sidebar and tab bar views that show titles, in
  every window; not measured. Not built: the longest wait
  (`docs/HISTORY.md`) bounds the delay, and titles still schedule saves.

## Decisions pending

Looked into after step 7 (October 19, 2026). Each needs an owner
decision before it becomes a step. Details that belong to the design
contract are in `docs/DESIGN.md` where noted; the full accounts of the
two macOS 27 investigations are in `docs/HISTORY.md`.

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
real sessions. Decision needed: whether and when to spend a step on
this.

### macOS 27: "Running in Background" after quit — tested, decided (step 8)

Since macOS 27 the Dock keeps an app's icon with a light grey indicator
and the tooltip "Running in Background" when processes that originate
from the app are still alive after quit (Apple support article 125671).
Tested live on October 19, 2026: the Dock's "Stop Running in
Background" ends every session; a first-quit system prompt asks whether
to allow the app in the background; neither disclaiming responsibility
on the spawn nor a launchd job submitted from inside a session escapes
the attribution, and no API, entitlement or Info.plist key opts out.
Of the options considered, the third (do not quit: keep a status item
while sessions are alive) was chosen and became step 8; the second,
moving session ownership into an `SMAppService` login item or agent,
needs a prototype and was not tried.

Still untested, in order of value: an `SMAppService` agent prototype
(option 2), now also as a possible way out of the kill described in the
next section; the prompt's Don't Allow button itself (needs a Mac with
no stored decision; the switch records the same state); whether a quit
leaves the ssh connection masters (`ControlPersist`, up to 10 minutes)
as subordinate processes that show the Dock indicator or are killed;
whether Background App Activity lists the daemons.

### macOS 27: "Allow in the Background" switched off — tested, decision deferred

Tested October 19, 2026 (evening), the owner switching Armadale off and
on again under System Settings › General › Login Items & Extensions ›
Allow in the Background. Switched off, macOS ends every session 5 s
after a quit from menu bar mode and 1 s after a regular quit such as
SIGTERM; switched on, nothing is touched. Menu bar mode avoids the
Dock's "Running in Background" tile and its stop item, as step 8
intended, but not the allow decision: the sessions survive a quit only
while Armadale is allowed in the background, whatever the quit. There
is no API for the app to read the decision, and no prompt appears for
an accessory-mode quit, so the user is never told again. Remote
sessions are not affected (no local process), except that their ssh
masters are subordinate processes too (untested).

Options for the owner: say so in the quit alert and the README
(cheapest; the alert already explains menu bar mode), add it to the
status menu's wording, or prototype the `SMAppService` agent (option 2
above) to see whether a login item's processes escape the check.
**Decision deferred by the owner (October 19, 2026): open item, nothing
started.** What was recorded: `docs/DESIGN.md` section 8 ("Quit, Keep Sessions
Running") and section 13; the README's "Quitting and the menu bar"
gained one sentence.

### The `ctty-exec` helper

The orientation note is in `docs/HISTORY.md`; what the helper is and
why it exists are in `docs/DESIGN.md` section 7 and the README ("The
`ctty-exec` helper").

## State of this Mac that matters

- **Looked at on November 14, 2026**, on the Mac that day's work was
  done on, which may not be the Mac the entries below describe (the
  checkout, the Claude Code cask and the build products were all new
  that morning). There was no `~/Applications/Armadale.app` and no
  Armadale in `/Applications`. Lima was not installed (`limactl` not on
  PATH, no `~/.lima`), so there was no test host and the SSH
  integration tests were skipped in every gate run that day. Codex was
  not installed (nothing at `/opt/homebrew/bin/codex` or on PATH), so
  nothing was checked against it. `/opt/homebrew/bin/claude` was
  2.1.311, while `docs/DESIGN.md` §10 was checked against 2.1.292
  (hooks) and 2.1.304 (flags) and is due a re-check. xcodegen was
  installed from Homebrew, and `Vendor/zmx` had to be fetched. The
  Developer ID certificate and the notary profile were not looked for.
  The entries below were not re-verified that day, apart from the
  privacy grants, which were made then.
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
  `scripts/install-release.sh` (by `docs/HISTORY.md`, 0.1.1 build 27,
  the notarized release of November 5, 2026;
  `--skip-notarize --allow-existing-tag` builds a local, signed but
  unnotarized copy of a version whose tag exists). It has a different
  code identity from Debug builds, so privacy prompts from inside its
  sessions may appear once more; it uses the real state directory
  (`~/Library/Application Support/Armadale`), never a test one. Do not
  replace it or run it during tests without the owner's say-so.
- Privacy grants for agent sessions run from the Claude desktop app
  (November 14, 2026). Commands there run under the bundle "Claude
  Code" (`com.anthropic.claude-code`, inside
  `~/Library/Application Support/Claude/claude-code/<version>/`), which
  macOS holds responsible, not the Claude app itself. The owner allowed
  it to control System Events (the dialog that AGENTS.md's frontmost
  check raises on first use, and which blocks that check until it is
  answered) and switched on Accessibility for it, which the System
  Events window probes and synthetic keystrokes need: without it they
  fail with -1719 or -1728 and no dialog appears. Screen Recording is
  not granted, so `screencapture -l` fails there. The owner may switch
  Accessibility off again; `AXIsProcessTrusted()` says whether it is
  on, and `lsappinfo info -only name -only pid "$(lsappinfo front)"`
  gives the frontmost app and its pid with no permission at all. With
  several test builds running, the frontmost check by name is not
  enough (all are "Armadale"); compare the pid too. Synthetic
  keystrokes reset `HIDIdleTime`, so the idle gate only means
  something before the first one.
- The Lima VM `default` is stopped and has no `~/.armadale` inside it.
- Claude Code 2.1.292 and Codex 0.163.0 were the versions installed
  when `docs/DESIGN.md` §10 recorded what each offers and the source
  lines consulted (its flag table was read from Claude Code 2.1.304).
  Re-check when either is upgraded; see the first entry of this
  section for what was installed on November 14, 2026.
