import AppKit
import ArmadaleCore
import ArmadaleSessions
import TerminalSurface

/// The registry is every controller's delegate: it records what the
/// controllers report in the model (titles, directories, runtime versions,
/// grid sizes, respawns), passes bells and notifications to the
/// ``AttentionCenter`` (whether or not the pane was ever shown), and keeps
/// the pane views in step.
extension SessionRegistry: SessionControllerDelegate {
    func sessionController(_ controller: SessionController, didChangeState state: SessionState) {
        let id = controller.session.id
        if state.isAttached {
            waitingForUser.remove(id)
            reconnectedWhenShown.remove(id)
        }
        // A session of a host whose listing needed the user reached the
        // host (its pane is shown and the user signed in): it attached, or
        // its attach found it gone. List the host again, so its other
        // sessions follow the launch rule. An end the app caused (closing
        // the pane, End Sessions and Quit) says nothing about the host.
        let reachedHost = state.isAttached
            || (state.isEnded && !finishedSessionIDs.contains(id) && !isEndingAllSessions)
        if reachedHost, let host = controller.session.remoteHostID, hostsAwaitingUser.remove(host) != nil {
            relist(host)
        }
        if case .ended(let exit?) = state {
            // A clean exit takes its pane with it (DESIGN §4, "Ended").
            closePaneIfEndedCleanly(controller.session.id, exit: exit)
        }
    }

    func sessionController(_ controller: SessionController, didSetTitle title: String) {
        model.setTitle(title, for: controller.session.id)
    }

    func sessionController(_ controller: SessionController, didChangeDirectory path: String) {
        reportedDirectories.insert(controller.session.id)
        model.setWorkingDirectory(path, for: controller.session.id)
    }

    func sessionController(_ controller: SessionController, didRecordRuntimeVersion version: String) {
        model.setRuntimeVersion(version, for: controller.session.id)
        // Without it a crash would leave the session looking non-persistent.
        onRuntimeVersionRecorded?()
    }

    func sessionController(_ controller: SessionController, didApplySize size: PTYSize) {
        gridSizes.record(SessionGridSize(columns: Int(size.columns), rows: Int(size.rows)), for: controller.session.id)
    }

    func sessionController(_ controller: SessionController, didReplace old: SessionID, with new: Session) {
        // Re-key before the model drops `old`; the old session is retired
        // (the controller already killed it), so pruning leaves it alone.
        if let existing = controllers.removeValue(forKey: old) {
            controllers[new.id] = existing
        }
        paneViews.rekey(old, to: new.id)
        if let record = surfaceRenderers.removeValue(forKey: old) { surfaceRenderers[new.id] = record }
        waitingForUser.remove(old)
        reconnectedWhenShown.remove(old)
        gridSizes.rekey(old, to: new.id)
        knownSessionIDs.insert(new.id)
        finishedSessionIDs.insert(old)
        restoredSessionIDs.remove(old)
        startRequested.remove(old)
        launchQueue.remove(old)
        reportedDirectories.remove(old)
        model.replaceSession(old, with: new)
        onSessionRetired?(old)
    }

    func sessionController(_ controller: SessionController, launchForRespawning session: Session) -> LaunchSpec? {
        model.launchForRespawn(of: session)
    }

    /// A pane view shows the new surface where the old one was, at its own
    /// layout. Without one, the new surface takes the old one's grid, so
    /// the reconnect or respawn that installs it does not resize the
    /// program, and the registry's record moves to the new renderer.
    func sessionController(_ controller: SessionController, didReplaceSurface old: any TerminalSurface) {
        let id = controller.session.id
        if let pane = paneViews.view(for: id) {
            pane.surfaceWasReplaced(old)
            return
        }
        let grid = old.gridSize
        controller.surface.setGridSize(columns: grid.columns, rows: grid.rows)
        if let record = surfaceRenderers[id] { surfaceRenderers[id] = (record.pending ?? record.current, nil) }
    }

    func sessionControllerDidRingBell(_ controller: SessionController) {
        attention?.signal(.bell, from: controller.session.id)
        if NSApp?.isActive == false {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func sessionController(_ controller: SessionController, didReceiveNotification title: String, body: String) {
        attention?.signal(.notification(title: title, body: body), from: controller.session.id)
    }

    func sessionController(_ controller: SessionController, didActivateLink link: String) {
        // Program output is untrusted: only open ordinary web, mail and file links.
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "file"].contains(scheme)
        else { return }
        NSWorkspace.shared.open(url)
    }

    func sessionController(_ controller: SessionController, didRequestClipboard op: ClipboardOp) {
        // OSC 52: writes are allowed (as in most terminals); reads are denied
        // by the surface.
        guard case .write(let text) = op else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
