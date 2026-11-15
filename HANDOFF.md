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
quit alert activate the app again, and on November 14, 2026 the
findings of an architecture review were built: one Armadale process per
state directory, a safer orphan reclaim and save schedule, state file
schema 2, and restored sessions attached at launch. That last change
was checked live the same day on a test build, except on a host (there
was none) and for what the accessibility tree does not show ("From
finished changes" below). The last gate run: 834 tests, zero warnings.
**Armadale 0.1.2 (28) is built, notarized and stapled from 76562b7
(November 14, 2026) and installed on the owner's Mac, but not
released: no tag, no GitHub Release, no fixture ("Next" below).**
What each change was, how it was checked and what was found on the way
is in `docs/HISTORY.md`.

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

Since the last release. The earlier changes, back to the build order,
are the headings of Part 1 of `docs/HISTORY.md`, with their dates and,
in the heading or the text under it, their commits:
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
- November 14, 2026: restored sessions are attached at launch; the
  session registry owns the controllers (7353b3a).
- November 14, 2026: `AppDelegate` and `SessionRegistry` split into
  files, code moved only (8d6bb99).
- November 14, 2026: the live checks of attaching at launch;
  `scripts/check-quit.sh` uses defaults suites of its own (cdfc8b0).
- November 14, 2026: the Dock badge and notifications checked live,
  also for a session in a tab not shown; no code changed (6d07126).
- November 14, 2026: the Mac used that day set up for releases and
  host tests; a signing dry run and the SSH integration tests passed
  there; no code changed.
- November 14, 2026: bump to 0.1.2 (28) (76562b7); that commit built,
  notarized, stapled and installed in `~/Applications` on that Mac.
  Not tagged or published.
- November 14, 2026: housekeeping: the state of a Mac moved out of
  this file into `HANDOFF.local.md` (git-ignored); this file trimmed
  (e926467).
- November 14, 2026: hosts checked live: the limit of six at launch,
  more than ten sessions on one host, an unreachable host coming
  back; no code changed.

## Next

Nothing is in progress. Everything the owner gave the go-ahead for on
November 14, 2026 is built, and checked live where the Mac was free
(`docs/HISTORY.md`, the entries of that day). What comes next waits
for the owner.

Waiting for owner decisions:
- **Publishing 0.1.2.** The notarized DMG of 76562b7 exists only on
  the Mac it was built on (`HANDOFF.local.md` there; `docs/HISTORY.md`,
  "Armadale 0.1.2 (28), built and notarized, not published"), in
  `build/release/`, which the next run of `scripts/release.sh`
  deletes. The owner does not plan to publish for now (November 14,
  2026). To publish that very build: tag 76562b7 as `v0.1.2`, create
  the GitHub Release with the DMG under both names, and add the tag's
  state fixture (README, "Releasing", steps 4 and 5). If anything is
  committed to the app before then, bump the build number and build
  again instead. The release notes should say that 0.1.2 writes state
  file schema 2, which 0.1.0 and 0.1.1 refuse.
- **Three decisions the coordinator made** when restored sessions
  were attached at launch (November 14, 2026), each the owner's to
  overrule: the launch holds at most six of a host's sessions (open
  items, Remote; made without a test host, it held live on one later
  that day); a session never shown in the run does not start a
  sign-in by itself; and the cost of heavy output in sessions not on
  screen is accepted as it is (open items, Session layer).
- **A live check on a host that needs a sign-in.** What the app does
  with a host at launch was checked live with key authentication
  (`docs/HISTORY.md`, "hosts, checked live"). A host that asks for a
  password was not: it needs a test host set up for that.
- **Showing or re-adopting spared sessions** (open items, Session
  layer).
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
  failed in two of three full-gate runs on October 23, 2026, each time
  with three bytes more than the flood's 7,888,896, and was not
  reproduced in 11 further runs (the failures had coincided with a
  release build, notarization and install on the same Mac). The test
  keeps the byte count strict, prints the first mismatching bytes
  when the count is off (`describeMismatch`) and records a low share
  of full batches as a known issue. Open: wait for the diagnostic to
  catch the next occurrence; if it shows a focus report (`ESC [ I` or
  `ESC [ O`, the only three-byte sequence in this code base), look for
  a surface answering a replayed `?1004h` into a live PTY in the
  concurrent session-controller tests. The investigation is in
  `docs/HISTORY.md` ("housekeeping").
- One unexplained rendering glitch: a Claude Code prompt once showed a
  colour code as literal text (`185;249m`) after a replay. Not reproduced.
- Spared sessions (November 14, 2026) are invisible and never end by
  themselves: sessions that were running when a launch could not read
  its state file as written stay in `sparedSessionIDs`, no pane shows
  them, and End Sessions and Quit leaves them alone. The `state` log
  line of each launch gives their number and how many still run. By
  hand: `ZMX_DIR=<state directory>/run <state directory>/bin/zmx-0.8.1
  ls`, and `kill a-<id>` to end one. Their helper version is not
  recorded, so after the bundled helper changes the old copy is
  removed and listing or ending them with the new one may time out
  (DESIGN section 13). In a run on the plain PTY fallback the flag
  stays set, so the reclaim is held back until a run with the
  persistent runtime (intended).
  What to do with them is an owner decision. The reclaim is the only
  code that ends sessions the user did not ask to end, and it does so
  by set difference against one file. It could ask before ending ("N
  sessions are running that no pane shows"), or write a small record
  per local session beside its socket at create (the `Session` value)
  so that unreferenced live sessions can be offered back as panes
  after a lost state file. A daemon left running costs a few
  megabytes; an agent ended by mistake can cost hours of its work.
  DESIGN section 1's "never adopts sessions created elsewhere" would
  still hold (these are Armadale's own). Hosts are a separate
  question, since several Macs may share a host's `~/.armadale`.
- The helper's listing leaves out a daemon that does not answer within
  about a second and still succeeds (November 14, 2026, `kill -STOP`).
  Locally nothing depends on the listing alone any more (the same
  day, `docs/DESIGN.md` section 4): a session is alive when it is
  listed, or when its socket is still there after the listing and it
  has no exit record. On hosts the listing is still all there is: a
  remote daemon it leaves out is marked ended, at launch now for panes
  not shown too, and Respawn All Ended there starts a new session
  while the old daemon keeps running unreferenced (from the code; no
  test host).
- A local session whose daemon does not answer (stopped, deadlocked)
  is never ended: at launch it is attached and shows nothing until the
  daemon answers, and a client that goes away is attached again. When
  its pane is closed the kill fails or times out, one line in the log
  (category `sessions`) names the session, and the daemon keeps
  running with no pane until it runs again; then it takes the queued
  kill and ends. Nothing kills it by pid, so one that never runs again
  stays (November 14, 2026; seen live with `kill -STOP` and
  `kill -CONT`). Not seen live: the Disconnected placeholder for it
  (two lost clients within the reattach allowance).
- A restored session without a saved size is not attached until its
  pane is shown once (the owner's decision, November 14, 2026: no
  program is resized on a guess). That is every session saved by 0.1.1
  or earlier, once each. Until then it is as before the change: no
  attention from it, and its glyph and its place in the quit
  question's count are the launch listing's answer, never refreshed.
  The same holds for a host's sessions beyond the limit of six (Remote)
  and for a host that needs a sign-in.
- Heavy output in sessions that are not on screen costs the main
  thread, as it always did for a tab visited once and left; since
  November 14, 2026 sessions in tabs never visited are attached and
  pay it too. Measured that day with five such sessions each printing
  50 MB: an optimized build stays at about 90 % CPU while the output
  lasts and is idle 2 s after it ends, with accessibility round trips
  of about 0.2 s; a Debug build cannot keep up (round trips of about
  9 s, and 2 to 4 minutes of parsing after the output has ended, during
  which a quit can take seconds). Accepted as it is (the coordinator's
  decision); `docs/HISTORY.md` Part 2, section 8, has the numbers and
  four options that were not built. Twenty attached idle sessions: a
  footprint of 55 MB and no CPU (Debug build). Not measured: a real
  release build, and real agents at work.
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
- One SIGWINCH reaches a full-screen program at every attach, a
  relaunch included, whatever the size: the persistence helper sends
  it to a program on the alternate screen, and it cannot be removed on
  Armadale's side. A program at a prompt gets none at a relaunch at an
  unchanged size (November 14, 2026: through the real helper, and live
  in 12 and then 5 relaunches, one of the sessions made by Armadale
  itself), which was the old item "one extra SIGWINCH after relaunch".
  The exception found on the way: a session that the helper's own
  `send` or `run` command has touched can get one at every later
  attach. Armadale never uses them, but a test that stages sessions
  with them will see it (`docs/HISTORY.md` Part 2, section 4).
- A font or size change while a session is attached and its pane has
  not been shown in this run can give two resizes when the pane is
  first shown (the font applied on entering the window, then the
  layout). Accepted (November 14, 2026).
- The pixel size a program is told can stay stale for a session
  attached while its pane was not shown and first shown on a screen of
  another scale, until its grid next changes: sending the pixels alone
  would cost the program a SIGWINCH. Accepted (November 14, 2026); it
  matters only to programs that draw by pixel.
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
- More than ten sessions on one host that asks for a password. Every
  client of a host shares one connection and sshd allows 10 sessions
  on one by default. Checked live with key authentication (November
  14, 2026; `docs/HISTORY.md`, "hosts, checked live"): past ten, ssh
  opens a connection of its own for each further client and for a
  close's kill, so twelve panes attached and a closed pane's session
  ended on the host. Not checked: a host that asks for a password,
  where each of those connections would need its own sign-in; a kill
  sent without one would fail, its failure is swallowed, and the
  closed pane's session would keep running there. The launch holds at
  most six of a host's sessions (the coordinator's decision; the owner
  may overrule it); that held live, at launch and when an unreachable
  host came back.
- A pane on a host that was shown once and is now in another tab may
  still start a sign-in by itself when an automatic retry finds the
  host back and asking for a password; only sessions never shown in
  the run are held back from that (November 14, 2026).

Agents
- Claude Code's own idle signal arrives 60 s after it finishes; immediate
  signalling needs the user's `Stop` hook (the Configure… sheet shows it).
- The `armadale-notify` helper cannot reach the pane from inside tmux or
  screen, and only exists on the Mac that runs Armadale (hooks in
  remote sessions cannot use it; the profile arguments work
  everywhere).
- A session whose profile was deleted is never notified under "Only for
  agent profiles".

Menu bar mode (step 8), from its review
- Not exercised live: a real logout, restart or shutdown (the quit
  event's reason is unit-tested with synthetic events only); a
  notification click reopening from menu bar mode (code path only);
  End Sessions and Quit against a slow or unreachable remote host; the
  persistence fallback mode; window order with several windows on
  return; macOS hiding the status item; the light menu bar.
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
- Known limit of the instance lock (November 14, 2026): builds before
  it, 0.1.1 included, take no lock, so an installed 0.1.1 or earlier
  and a newer build are not kept apart; AGENTS.md's isolation rule
  still stands.
- 0.1.1, the last published release, has neither activation fix
  (dcdeb50, 704a941); 0.1.2 has both and is not published.

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
- Restored sessions attached at launch (November 14, 2026). Checked
  live the same day on the Debug build with its own state directory,
  staged with the helper and driven by accessibility actions, without
  a synthetic keystroke or click (`docs/HISTORY.md`, "the live checks
  of attaching at launch"). **Not checked:**
  - On a host, what needs a sign-in: a host that needs a password at
    launch starts no client in a pane not shown until one tab signs
    in, then the rest attach; a host unreachable at launch and back
    asking for a password leaves those panes Disconnected with ssh's
    message, and showing one reconnects it. The rest was checked live
    that evening with key authentication (`docs/HISTORY.md`, "hosts,
    checked live"): the limit of six, more than sshd's ten, and an
    unreachable host coming back.
  - What the eye would see. The sidebar's and the tab bar's glyphs and
    the purple counts are not in the accessibility tree, and Screen
    Recording was not granted. Attention was read from the Window
    menu's items and from Next Pane Needing Attention, the ended state
    from the quit question's count and from Respawn All Ended becoming
    enabled, and whether a terminal fills its card from the pty sizes
    alone.
  - A click on a notification for a session in a tab not shown since
    the launch: it should select the tab and focus the pane. The Dock
    badge and the banner themselves were seen later that day
    (`docs/HISTORY.md`, "the Dock badge and notifications, checked
    live").
  - The Disconnected placeholder of a session whose daemon does not
    answer; how many attaches are in flight at once (the order was
    read from process ids: the selected tab's client first, then three
    more, the rest within about 60 ms); a renderer change (there is
    one renderer); the size check after a launch through Finder or
    `open` (every launch was by the binary's path).

  **Found and not fixed:** heavy output in sessions not on screen
  (Session layer, above; accepted as it is).

Architecture review (November 12 and 14, 2026): what is left

Most of its findings were built on November 14, 2026 (`docs/HISTORY.md`,
from "one Armadale process per state directory" to "`AppDelegate` and
`SessionRegistry` split into files"), and the owner kept the rule that
every agent reads all of `docs/DESIGN.md` and this file. What it says
about spared sessions is under Session layer above. The findings came
from reading the documents and the code; none of what is left is
reproduced live.
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
  the risk instead of guarding against it. Looked into on November 14,
  2026 and not made: Lima 2.3.0 has a `macos-27` template (Apple's
  27.2 restore image, a 25.6 GB download, about 48 GB of disk at the
  peak of the install); the owner would still have to log in and grant
  Accessibility inside the guest; `limactl screenshot` would give
  pictures of the guest without Screen Recording. The cost is high,
  and live checks work on the owner's screen when it is free.
- **Titles and working directories schedule saves.** Besides a longest
  wait, the title and the working directory (`AppModel.setTitle`,
  `setWorkingDirectory`) could stay out of what schedules a save and
  be written with the next structural change and at quit: the
  persistence helper replays both on attach, so the saved copies
  matter only for sessions that are not attached. `AppModel` is one
  `@Observable` object and `displayTitle(for:)` reads `sessions`, so
  every title change also re-evaluates the sidebar and tab bar views
  that show titles, in every window; not measured. Not built: the
  longest wait (`docs/HISTORY.md`) bounds the delay, and titles still
  schedule saves.
- Smaller: some 17 `NSLog` calls remain in the app beside the
  `Logger`s, although NSLog is `<private>` in `log show` on macOS 27
  (10c, `docs/HISTORY.md`); the load-sensitive flood tests run beside
  four other test bundles in the gate. Seen in review on November 14,
  2026: a clean `xcodebuild … build-for-testing` into a fresh
  DerivedData fails with "Unable to resolve module dependency:
  'Armadale'" at `ArmadaleAppTests/SidebarShownPathTests.swift:4`
  (`@testable import Armadale`), while the gate's `build test` passes
  from a fresh DerivedData; older, not looked into.

## Decisions pending

Looked into after step 7 (October 19, 2026). Each needs an owner
decision before it becomes a step. Details that belong to the design
contract are in `docs/DESIGN.md` where noted; the full accounts of the
two macOS 27 investigations are in `docs/HISTORY.md`.

### A second renderer: Ghostty behind `TerminalSurface`

SwiftTerm 1.99.0 (pinned) is a preview of 2.0, whose API break means
`SwiftTermSurface` needs attention at 2.0 either way. Three Swift
packages for Ghostty-based rendering were compared on October 19, 2026
(`docs/HISTORY.md`, "housekeeping", has the table and the reasoning).
Only `Lakr233/libghostty-spm` fits, because `TerminalSurface` is
byte-fed and the session layer owns the PTY. Its costs: a
weekly-moving upstream pin held together by one maintainer's patch
stack, a 20 to 30 MB macOS slice in the bundle, one Metal layer per
pane. Unverified: how its host-managed backend behaves with the
persistence helper's replay on attach.

Proposed step: a `GhosttySurface` package implementing `TerminalSurface`
over libghostty-spm's in-memory session, registered in `SurfaceRegistry`
as a second renderer with SwiftTerm staying the default, then compared on
real sessions. Decision needed: whether and when to spend a step on
this.

### macOS 27: "Running in Background" after quit — tested, decided (step 8)

Decided: Armadale does not quit while sessions are alive but keeps a
status item (step 8). The test of October 19, 2026 and the options
considered are in `docs/HISTORY.md` ("macOS 27, 'Running in
Background' after quit").

Still untested, in order of value: an `SMAppService` agent prototype
(option 2 there: session ownership moved into a login item or agent),
now also as a possible way out of the kill described in the next
section; the prompt's Don't Allow button itself (needs a Mac with no
stored decision; the switch records the same state); whether a quit
leaves the ssh connection masters (`ControlPersist`, up to 10 minutes)
as subordinate processes that show the Dock indicator or are killed
(seen November 14, 2026: a master outlives a quit by SIGTERM, its
parent being launchd; the Dock was not looked at then);
whether Background App Activity lists the daemons after a quit (needs
root or the System Settings UI).

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

## State of this Mac that matters

What is installed and granted on a particular Mac is not in this file:
the installed app, the test host, the agents, the signing identities
and the notary profile, the notification and background settings, and
the privacy grants agents need. It is in `HANDOFF.local.md` at the
repository root, which is git-ignored, one per Mac. `AGENTS.md` ("Test
hosts and tools") says what that file holds and what to do on a Mac
that has none.

The section this replaces described two Macs as last recorded on
November 14, 2026: the one used until November 12, 2026 and the one
used on November 14. It is in git: `git show f4d8bd8:HANDOFF.md`. On
the first Mac, the entries there that are not dated November 14 say
what to look at; none was re-verified after November 12, 2026, so
each is to be checked again, not copied.
