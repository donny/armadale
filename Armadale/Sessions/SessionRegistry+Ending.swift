import AppKit
import ArmadaleCore
import ArmadaleSessions
import Observation
import TerminalSurface

/// Ending sessions (docs/DESIGN.md sections 4 and 8): clean exits,
/// closing a pane's session, End Sessions and Quit, detaching at quit, and
/// Respawn All Ended.
extension SessionRegistry {
    // MARK: Clean exits

    /// The rule for a session whose program ended (``EndedSessionRule``,
    /// docs/DESIGN.md section 4, "Ended"): after a clean exit (status 0, or
    /// any normal exit of the user's shell) its pane closes the way the
    /// placeholder's Close Pane closes it (no question: nothing runs), which
    /// closes the tab with its last pane, the tab group with its last tab
    /// and the workspace with its last tab group (its window then closes
    /// itself). Returns whether it closed.
    @discardableResult
    func closePaneIfEndedCleanly(_ sessionID: SessionID, exit: ProgramExit?) -> Bool {
        guard !finishedSessionIDs.contains(sessionID),
              model.closePaneIfSessionEndedCleanly(sessionID, exit: exit) != nil
        else { return false }
        close(sessionID)
        return true
    }

    /// At launch, before any window shows: closes the panes of restored
    /// sessions whose programs exited cleanly while Armadale was not
    /// running (`statuses`: what their recorders wrote), by the same rule,
    /// in the model's order. Returns the sessions closed.
    @discardableResult
    func closePanesOfSessionsThatEndedCleanly(_ statuses: [SessionID: ProgramExit]) -> [SessionID] {
        var closed: [SessionID] = []
        for id in model.sessionOrder where restoredSessionIDs.contains(id) {
            if let exit = statuses[id], closePaneIfEndedCleanly(id, exit: exit) { closed.append(id) }
        }
        return closed
    }

    /// ``closePanesOfSessionsThatEndedCleanly(_:)`` for the restored local
    /// persistent sessions, from the exit files in `runtime`. A file is only
    /// written once the program has ended, so this needs no listing and
    /// does not wait for the live probe.
    @discardableResult
    func closeLocalSessionsThatEndedCleanly(recordedIn runtime: ZmxRuntime) -> [SessionID] {
        var statuses: [SessionID: ProgramExit] = [:]
        for session in model.sessions where session.remoteHostID == nil && RestorePolicy.isPersistent(session) {
            statuses[session.id] = runtime.recordedExitStatus(for: session.id)
        }
        return closePanesOfSessionsThatEndedCleanly(statuses)
    }

    // MARK: Closing and ending

    /// Ends a session whose pane was closed and forgets it, through its
    /// controller (``SessionController/close()``), which kills it in its
    /// backend whatever its state: a restored session that was never
    /// attached may still be alive. Unavailable sessions (no persistent
    /// runtime, a removed host) cannot be reached and are left running.
    func close(_ sessionID: SessionID) {
        guard finishedSessionIDs.insert(sessionID).inserted else { return }
        reportedDirectories.remove(sessionID)
        restoredSessionIDs.remove(sessionID)
        startRequested.remove(sessionID)
        waitingForUser.remove(sessionID)
        reconnectedWhenShown.remove(sessionID)
        surfaceRenderers[sessionID] = nil
        launchQueue.remove(sessionID)
        gridSizes.forget(sessionID)
        paneViews.remove(sessionID)?.removeFromSuperview()
        guard let controller = controllers.removeValue(forKey: sessionID) else { return }
        makeUnavailableIfHostRemoved(controller)
        let retires = !controller.state.isUnavailable
        Task { [weak self] in
            await controller.close()
            if retires { self?.onSessionRetired?(sessionID) }
        }
    }

    /// Disconnects every client at once without ending any session; used
    /// when the app quits (synchronous, so quitting never waits). The grid
    /// sizes not yet recorded are written to the model first, so the save
    /// at quit has them, and every recording is ended and its file, like
    /// those of recordings already ending, written and closed within one
    /// second in all (``finishRecordingsForQuit()``).
    func detachAllNow() {
        gridSizes.flush()
        finishRecordingsForQuit()
        for controller in controllers.values where controller.state.isAttached {
            controller.detachNow()
        }
    }

    /// Writes the grid sizes not yet recorded to the model now (before the
    /// synchronous save at quit).
    func flushGridSizes() {
        gridSizes.flush()
    }

    /// End Sessions and Quit (docs/DESIGN.md section 8): ends every session
    /// that may be alive, all at once, through its controller
    /// (``SessionController/close()``: the backend's kill, then the client),
    /// attached or not. Unreachable sessions are left: those of a removed
    /// host, and persistent sessions while the persistent runtime is
    /// unavailable (their controllers are unavailable and kill nothing).
    /// Each kill is bounded by its backend's command timeout, so this
    /// returns within the longest of them. Panes stay in place, ended; the
    /// model is not changed. `only` limits it to those sessions (a second
    /// pass); returns the sessions it went through.
    @discardableResult
    func endAllSessions(only: Set<SessionID>? = nil) async -> Set<SessionID> {
        let ids = only ?? Set(model.sessions.map(\.id)).union(controllers.keys)
        isEndingAllSessions = true
        defer { isEndingAllSessions = false }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                guard let controller = controllers[id] ?? ensureController(for: id) else { continue }
                makeUnavailableIfHostRemoved(controller)
                group.addTask { await controller.close() }
            }
        }
        return ids
    }

    /// Sessions that may still be running (``CloseRisk/mayBeRunning(_:)``),
    /// asked after an End pass: ones it did not cover (a tab opened
    /// meanwhile) and covered ones whose pane runs again (a Respawn
    /// meanwhile) are among them; a covered session shows its controller's
    /// state like any other, so one it ended is not.
    func sessionsStillRunning() -> Set<SessionID> {
        Set(model.sessions.map(\.id).filter { CloseRisk.mayBeRunning(riskItem(for: $0)) })
    }

    /// Whether local sessions outlive the app in this run (the persistent
    /// runtime is set up). In the fallback they end with any quit.
    var sessionsSurviveQuit: Bool { runtime.isPersistent }

    // MARK: Ended sessions

    /// Whether `sessionID` is known to have ended (its controller says so;
    /// never an unavailable or disconnected one).
    func isEnded(_ sessionID: SessionID) -> Bool {
        controllers[sessionID]?.state.isEnded == true
    }

    /// Whether any pane of the workspace shows an ended session.
    func hasEndedSessions(in workspaceID: WorkspaceID) -> Bool {
        model.sessionIDs(in: workspaceID).contains { isEnded($0) }
    }

    /// Workspace › Respawn All Ended: respawns every ended session in the
    /// workspace's panes, including ones whose tab was not shown yet (the
    /// morning after a reboot). Disconnected and unavailable sessions are
    /// not ended and are left alone.
    ///
    /// Sessions on a host are only respawned once the host has answered a
    /// fresh listing: one that cannot be reached right now is left alone
    /// (its sessions may well be alive, and a respawn could not start
    /// anyway).
    func respawnAllEnded(in workspaceID: WorkspaceID) {
        var remoteCandidates: [HostID: [SessionID]] = [:]
        for sessionID in model.sessionIDs(in: workspaceID) where isEnded(sessionID) {
            if let host = model.session(sessionID)?.remoteHostID {
                remoteCandidates[host, default: []].append(sessionID)
                continue
            }
            respawn(sessionID)
        }
        for (host, candidates) in remoteCandidates {
            guard let backend = remoteBackend(for: host) else { continue }
            Task { [weak self] in
                guard let live = try? await backend.liveSessions() else {
                    NSLog("Armadale: not respawning sessions on an unreachable host")
                    return
                }
                guard let self else { return }
                self.hostListings[host] = .live(live)
                for sessionID in candidates where !live.contains(sessionID) && self.isEnded(sessionID) {
                    self.respawn(sessionID)
                }
            }
        }
    }

    /// Respawns an ended session. A session whose pane view was never made
    /// creates the fresh session at its saved size (its pane would be shown
    /// at it), not at a renderer's default size; one with a pane view
    /// creates at its terminal's grid, which only that pane's layout sets.
    private func respawn(_ sessionID: SessionID) {
        guard let controller = controllers[sessionID], controller.state.isEnded else { return }
        if paneViews.view(for: sessionID) == nil, let size = model.session(sessionID)?.gridSize {
            controller.surface.setGridSize(columns: size.columns, rows: size.rows)
        }
        Task { await controller.respawn() }
    }
}
