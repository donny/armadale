# HANDOFF.md — where development stands

Point-in-time status for whoever picks Armadale up next: where things
stand, what is next, what waits for the owner, the open items. Update
this file whenever work pauses. The durable rules for working in this
repository are in `AGENTS.md`; the design contract, what is true now,
is `docs/DESIGN.md`; why and when (the change log, and the history of
each design section) is `docs/HISTORY.md`; build and run instructions
are in `README.md`.

## Status (November 24, 2026)

Steps 1–10 of the build order (`docs/DESIGN.md` §12) are implemented,
reviewed and committed on `main`. Armadale 0.1.0 (tag `v0.1.0`, October
23, 2026), 0.1.1 (tag `v0.1.1`, the first public release, November
5, 2026) and 0.1.2 (tag `v0.1.2`, November 17, 2026, the first with an
updater) are released, notarized and stapled; the code is under the MIT
License and https://armadale.dev is live. Since the build order the
sidebar, the tab bar and the panes (now cards with a header and a pane
menu) were reworked, a clean exit closes its pane, menu bar mode and the
quit alert activate the app again, and on November 14, 2026 the
findings of an architecture review were built: one Armadale process per
state directory, a safer orphan reclaim and save schedule, state file
schema 2, and restored sessions attached at launch. That last change
was checked live the same day on a test build, except on a host (there
was none) and for what the accessibility tree does not show ("From
finished changes" below). The same evening Armadale learned to detect
that macOS ended the sessions a quit left running (Armadale switched
off under Background App Activity) and to say so; that change was
checked live the same night, with the owner at the switch ("From
finished changes" below has what is left). On November 16, 2026
favorites moved into the New Session
chooser (drag, Move Up, Move Down, Save as Favorite… in the pane
menu), the New Session dialog learned to add a host (New Host…, with
the aliases of the ssh configuration offered), and Settings lost its
Favorites tab; that change was checked live the same day on a test
build ("From finished changes" below has what is left and what was
found). The same day the site gained a changelog page
(`docs/changelog.html`), written for everything so far and kept by a
rule in AGENTS.md from now on. The same night an updater was built,
reviewed and committed (Sparkle 2.10.1), and a real update was checked
live on test builds with a bundle identifier of their own: sessions
lived through every update, also with Armadale switched off under
Background App Activity ("From finished changes" below has what is
left). On November 17, 2026 the owner made the update signing key and
its public half went into `project.yml`.
**The same day Armadale 0.1.2 was released, with everything above in
it: build 30 from dc03cc5, tagged `v0.1.2`, on GitHub with the
notarized DMG, on the changelog page as the latest release and in the
update feed. It is the build installed on the owner's Mac.**
On November 24, 2026 recording a pane was built at the owner's request
(the status list and "From finished changes" below): committed, not
released, and not checked live yet.
The last gate run: 1009 tests, no warning from Armadale's code.
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

Since the last release (0.1.2, November 17, 2026). The earlier
changes, back to the build order, are the headings of Part 1 of
`docs/HISTORY.md`, with their dates and, in the heading or the text
under it, their commits:
- November 17, 2026: 0.1.2 build 30 (dc03cc5), tagged `v0.1.2` and
  released on GitHub, on the changelog page and in the update feed
  (f1e0fca); its state fixture (`docs/HISTORY.md`, "Armadale 0.1.2,
  released"). No app code changed since the build.
- November 24, 2026: recording a pane, f127458 (Record Pane… / Stop Recording in
  the pane menu, an asciicast v2 `.cast` file of the pane's output, a
  pulsing red dot and a stop button in the header, a red dot on the tab;
  `docs/HISTORY.md`, "recording a pane"). Built, reviewed twice and
  fixed; the gate passed with 1009 tests; not checked live ("From
  finished changes" below).

## Next

Recording a pane (the owner's request of November 24, 2026) is built,
reviewed, fixed and committed, and waits for its live check (the first
one stopped at a macOS screen-capture alert for the Claude app, left
for the owner; the reviewer's own was not started while that alert was
up). 0.1.2 is released with everything the owner
gave the go-ahead for up to November 17, 2026 (`docs/HISTORY.md`,
"Armadale 0.1.2, released"); "From finished changes" below has what
was not checked live. From now on a change a user would notice adds
its item to the changelog page in the same commit, under a new "Next
release" section (AGENTS.md, "The changelog page"). What comes next
waits for the owner.

Waiting for owner decisions:
- **Three decisions the coordinator made on the changelog page**
  (November 16, 2026), each the owner's to overrule: the page shows
  what is on `main` and not yet released, under "Next release"; 0.1.0
  has a section, described as a build that was not published; and the
  page went up with 26 items for the 118 commits so far
  (`docs/HISTORY.md`, "a changelog page on the site").
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
- **The updater: what is left** (released with 0.1.2;
  `docs/DESIGN.md` section 8, "Updates"). (1) An update between
  Developer ID signed builds can only be seen with the next release:
  check the first update after 0.1.2 on a copy of 0.1.2 (the owner's
  installed one is such a copy) before telling anyone. (2) The update
  key's backup and its import on a second Mac are the owner's (README,
  "Releasing").
- **An `SMAppService` prototype**, optional ("Decisions pending"
  below): whether a registered background item's `status` follows the
  same switch, which would let Armadale know before a loss instead of
  after.
- Any of the open items below.

## Open items carried forward

Known, accepted for now, and worth a round of their own. None is a
regression; each came out of a review and was deferred as low.

Session layer
- A SwiftTerm quirk worth reporting upstream (the owner decides whether
  to): after a RIS inside one parse call SwiftTerm 1.99.0 does not save
  its parser state at the end of that call (`EscapeSequenceParser.swift`,
  about lines 824–830 and 1434–1439), so a sequence left open at the end
  of the same batch is dropped: `"ok\ec\e"` then `"[31mC"` prints `[31mC`
  in any pane. A pending recording's cut makes the pane right in that
  case (`docs/DESIGN.md` section 13; `RecordingDifferentialTests`
  expects it).
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
- Some unit tests put windows on screen. `ArmadaleAppTests` is unhosted,
  but tests that present a sheet or an alert on a test window (found in
  review on November 24, 2026: `NewSessionChooserTests`,
  `NotifyHelperTests`, about 25 windows in a gate run, each for about a
  second) show it, so README's "no window appears" is not true. The
  recording tests use a presentation seam
  (`WorkspaceActions.recordPanelPresenter`) and show nothing; the others
  could do the same.
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
- No crash reporting (decided for v1, October 19, 2026). The updater
  is built (November 16, 2026) and has its key (November 17, 2026);
  0.1.2 is the first release that runs it. 0.1.1 and earlier cannot
  update themselves, so 0.1.2 is downloaded once by hand (its release
  notes and the changelog page say so).
- `scripts/release.sh` compares the DMG's app with the archived one by
  `diff -r`, which follows the links in Sparkle's framework: it writes
  "Directory loop detected" into `build/release/verify/dmg-app.diff`
  and still exits 0, having compared every file once but not that the
  links are links (the signature check that follows covers those).
  Seen November 17, 2026; a comparison that does not follow links
  would be exact.
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
  (dcdeb50, 704a941); 0.1.2 has both.

From finished changes: not checked live, and found and not fixed
- Recording a pane (November 24, 2026; `docs/DESIGN.md` sections 5, 7
  and 8, "Recording a pane"). **Checked live only in part**
  (`docs/HISTORY.md`, "recording a pane"). The first live check stopped
  at a macOS screen-capture alert for the Claude app, which the owner
  has since answered with Allow (`HANDOFF.local.md`); the reviewer's
  own, by accessibility presses on a test build, stopped early when the
  Claude app came to the front. Seen live before that: no recording
  item in an empty pane's menu; Record Pane…, enabled, in the menu of a
  pane with a session; the save sheet with its suggested name and its
  Cancel and Record buttons; the tab row's and the header's
  accessibility labels while recording; a sound file from a real pane.
  `scripts/check-quit.sh` passed on the build before the suggested
  name's fix. Two things that pass left open, to look at first next
  time: the recording was found ended before the reviewer pressed stop,
  and nothing says why (someone at the Mac, or a defect); and whether a
  "/" typed by hand into the save sheet confirms it, as a posted one
  did. Not seen: Record Pane… disabled before attach; `.cast` kept with
  no extension typed and with `.txt`, replacing a file, a read-only
  folder; ⌘Q, the Quit item and SIGTERM with the sheet
  up (unit-tested through `endSheetsForQuit` and a presentation seam; the
  hook from `terminate` is not); the dot pulsing (Core Animation), still
  pulsing after a title change, a tab switch, minimize and ⌘H, steady
  with Reduce Motion; the app's CPU
  with a recording pane visible, minimized, hidden; the stop button and
  the menu's Stop Recording; the tab's dot in the tab bar and the
  sidebar, in the background; a recording of
  streaming coloured output, one inside a full-screen program and one
  at a shell prompt with commands, parsed and played
  back (no `asciinema` or `termcast` here); a narrow pane's header; a
  quit and End Sessions and
  Quit with a recording running; a host's removal; a full small volume;
  the same file chosen in two panes;
  the problem alert on a real window; VoiceOver. Covered by tests
  instead: recording through the real persistence helper across a
  reattach, five recordings started inside a sequence with the pane
  undisturbed and playback equal to it, the quit's bounded wait.
- The updater (November 16, 2026; `docs/DESIGN.md` section 8,
  "Updates"). Checked live the same night on ad hoc signed test builds
  with their own bundle identifier, a throwaway key and a feed on
  127.0.0.1 (`docs/HISTORY.md`, "the updater, checked live"): a check
  and its two requests, Sparkle's question at the second launch,
  Settings, an update with sessions running, the loss warning, Cancel
  and the install at the next quit, menu bar mode's Update Available…,
  and an update with Armadale switched off under Background App
  Activity. Not checked live:
  - In a Release build: the owner opened the released 0.1.2 (30) on
    November 17, 2026 and Check for Updates… answered that it was up
    to date, with the feed still empty (`docs/HISTORY.md`, "Armadale
    0.1.2, released"). Not seen in a Release build: a check against
    the feed with its item (0.1.2 should again be up to date),
    Sparkle's question at the second launch, and an update between
    Developer ID signed builds.
  - The "N sessions will end" alert (the plain PTY fallback, a host
    without the persistence helper); the answers Open System Settings
    and Skip This Version; the daily check by its own timer (the test
    moved `SULastCheckTime`); Version History (no such control was in
    the accessibility tree); and what only a picture shows (no Screen
    Recording): how the windows look, the General tab at 620 × 640 pt.
  - With Armadale switched off under Background App Activity: one run
    only (DESIGN section 13); a slower install and an installer left
    waiting after Cancel were not tried.
  - Whether Sparkle's quit event reaches `applicationShouldTerminate`
    while an app-modal alert of Armadale's is up (the late loss alert;
    that the updater does not start before the launch alerts are
    answered was seen).
  - Sparkle's retry after a quit that did not happen (its quit then
    gets the ordinary question: DESIGN section 8, "Updates").
  - Entering menu bar mode while Sparkle's update window is showing:
    that window then has no Update Available… route back.
  - The log line of a run where the updater is off (none was found
    with `log show`; the test builds carried the switch).
  Found and not fixed:
  - Switching Armadale off under Background App Activity while it is
    closed ended the sessions it had left running, at once; the next
    launch showed them as Ended and said nothing about macOS, because
    they ended minutes after the quit, outside the window the launch
    check looks at.
  - After Remind Me Later in menu bar mode no window was on screen and
    the app was not active, but `NSRunningApplication.isHidden` read
    false; whether the app hid as it does when Settings closes there
    was not told apart.
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
    with a sheet up, a host deleted while the sheet is open, the
    host-removal count sentence, Codex options, a real SSH start.
  - Not checked live in 10c: menu bar mode with a chooser pane, keypad
    Enter, hover, a scrolling favorites list, dark mode, ⇧⌘N / tab bar
    "+" / sidebar New Tab in 10c (they share the path), zoom with a
    chooser, the compact
    Disconnected and Unavailable cards. Known: compact chooser rows
    show only icon and name, so a remote favorite in a narrow pane does
    not show its host.
- Favorites in the chooser, Save as Favorite…, New Host…, Settings
  without Favorites (November 16, 2026, 3a5183c; `docs/DESIGN.md` section 8,
  "New sessions"). Checked live the same day on a test build with its
  own state directory (`docs/HISTORY.md`, "favorites in the chooser and
  New Host…, checked live"). **Not checked:**
  - What the eye would see: the drop indicator and its edge, the
    dragged row's preview, the compact and tiny cards' look (Screen
    Recording is not granted where it was checked; everything was read
    from the accessibility tree and the state file).
  - A drag in the scrolling variant of the list (seven favorites did
    not scroll); the arrow-key selection after a move; VoiceOver.
  - Save as Favorite… from a right-click on the header (the "…" button
    was used), on a remote pane, on a pane whose host or profile was
    removed, and in a window that is not the key one.
  - A real start on a host added through New Host… that connects (the
    start was made on a name that resolves nowhere: the host was added,
    the session started and the pane showed ssh's message). New Host…
    alone cannot reach the Lima VM, which needs its config file.
  - The suggestions with a real `~/.ssh/config` (they were seen with a
    staged home folder, `CFFIXED_USER_HOME`); a click on a suggestion.
  - ⌘Q with a sheet up (SIGTERM with a New Session sheet up was seen:
    quit in 0.4 s, the pane saved empty), and Profiles' Configure… in
    Settings at a quit (the unit test ends a plain sheet on the
    Settings window, not that SwiftUI one).

  Decided (the owner, November 16, 2026): Return while aliases are
  offered keeps confirming the dialog, with the text as typed or with
  the alias ↓ highlighted (`docs/DESIGN.md` section 8, "New Host…").

  **Found and not fixed** (neither from this step's code):
  - A favorite row's help text is repeated in its accessibility help,
    once per text or image in the row ("Start “Alpha”, Start “Alpha”,
    Start “Alpha”"; twice in a compact row), so VoiceOver would read it
    two or three times: `.help` on the row reaches each leaf and the
    row combines its children. Older than this step (the row has had
    both modifiers since step 10c).
  - Two favorites can carry the same name: Save as Favorite… twice
    from one pane gives two "Reporter on gamma.invalid in /private/tmp".
    The form passes its proposed name as a name, and `addFavorite`
    makes only a blank name unique (as Add to Favorites has since step
    10b).
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
- Sessions macOS ends after a quit, detected and told (November 14,
  2026; `docs/DESIGN.md` section 8, "Background App Activity").
  Checked live the same night with the owner at the switch
  (`docs/HISTORY.md`, "the background detection, checked live"): the
  three verdicts with their alerts, log lines and record file, the
  question before a quit from the menu bar and its three answers, the
  late check and its alert, a SIGTERM quit under the alert, switched
  off and on again. **Not checked:**
  - What the choice on macOS's own notification does to sessions
    running at that moment. With no decision stored macOS ends
    nothing; about 30 s after the first quit that leaves sessions it
    lists Armadale, switched on, and posts the notification. The owner
    used the switch instead.
  - The Developer ID build: whether the installed app shares the one
    entry that governed two ad hoc copies.
  - The question with ⌘Q typed in Settings, Keyboard Shortcuts or
    Acknowledgements (nothing should hide after Cancel); the late
    check while the app is in menu bar mode (no alert, one more log
    line); a real Return typed while the late alert is up (its default
    button is absent in the accessibility tree); a restart or logout
    between a loss and the next launch.
  Known limits, accepted (DESIGN section 8): a crash or force quit of
  Armadale leaves no record; a restart or logout before the next
  launch says nothing; a `kill` by hand or the Dock's "Stop Running in
  Background" within 10 s of a quit is reported as macOS's doing; a
  quit within 12 s of the previous one drops that one's check; the
  first loss is reported, not prevented. Found live: a relaunch within
  5 s of a quit from the menu bar keeps the sessions even with the
  switch off, so a user who relaunches quickly never sees a loss.

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

Still untested, in order of value: an `SMAppService` prototype (the
next section); the choice on the first-quit notification itself (on a
Mac with no stored decision it came about 30 s after the quit and
nothing was ended until then, November 14, 2026; what its choice does
to running sessions was not seen); whether a quit
leaves the ssh connection masters (`ControlPersist`, up to 10 minutes)
as subordinate processes that show the Dock indicator or are killed
(seen November 14, 2026: a master outlives a quit by SIGTERM, its
parent being launchd; the Dock was not looked at then);
whether Background App Activity lists the daemons after a quit (needs
root or the System Settings UI).

### macOS 27: a registered background item (`SMAppService`) — untested

With Armadale switched off under Background App Activity, macOS ends
every local session a few seconds after any quit (tested October 19,
2026). What Armadale does about it was decided and built on November
14, 2026: it detects the loss at the next launch and says so
(`docs/DESIGN.md` section 8, "Background App Activity";
`docs/HISTORY.md`, "sessions macOS ends after a quit are detected and
told"). That reports a loss; it cannot prevent the first one, because
no API reads the setting.

What is left to decide is whether to prototype a registered background
item, in a throwaway app with its own bundle identifier so that
Armadale's stored decision is not touched. Two sizes:
- **Only to read the switch.** A do-nothing item registered through
  `SMAppService`; its `status` is `requiresApproval` when the user has
  switched the item off. If macOS 27 keeps one switch per app for a
  registered item and for processes left after a quit (not known), the
  app could know before a loss and say so at the quit. The prototype
  is small and needs the owner at the switch a few times.
- **Session ownership moved into an agent** (option 2 of October 19,
  2026). The largest change considered: a new bundled executable,
  signing and the release pipeline, existing sessions to migrate. A
  developer forum thread (835214, macOS 27 beta) reports such an agent
  still giving the app the Dock's grey dot after a quit.
Neither keeps a session alive with the switch off: an agent that is
switched off does not run.

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
