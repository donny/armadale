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

## State of this Mac that matters

- Notification permission for `com.tinylittleapps.armadale` is granted in
  System Settings (done during step 7 testing); it applies to any build
  with that bundle id.
- The Lima VM `default` is stopped and has no `~/.armadale` inside it.
- Claude Code 2.1.292 and Codex 0.163.0 are installed; `docs/DESIGN.md`
  §10 records what each offers and the source lines consulted. Re-check
  when either is upgraded.
