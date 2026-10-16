import AppKit
import ArmadaleCore
import ArmadaleSessions
import SwiftTermSurface
import TerminalSurface

/// Owns one ``SessionController`` (and its ``PaneView``) per session that
/// has been shown, keyed by session ID. Controllers are created lazily when
/// a pane first becomes visible and live until their session leaves the
/// model, so switching tabs or closing a window never destroys a terminal.
/// Also the controllers' delegate: it records titles, directories and
/// respawns in the ``AppModel``.
@MainActor
final class SessionRegistry {
    private let model: AppModel
    private let backend: any PersistenceBackend
    /// Sessions recorded by an earlier run of the app. They are attached to,
    /// never created: a session that is gone must show as ended, not be
    /// silently replaced by a fresh shell.
    private var restoredSessionIDs: Set<SessionID>
    private var panes: [SessionID: PaneView] = [:]
    private var pruneTask: Task<Void, Never>?

    init(model: AppModel, backend: any PersistenceBackend, restoredSessionIDs: Set<SessionID>) {
        self.model = model
        self.backend = backend
        self.restoredSessionIDs = restoredSessionIDs
        observeRemovedSessions()
    }

    /// The pane view for `sessionID`, created (with its controller) on first use.
    func paneView(for sessionID: SessionID) -> PaneView? {
        if let pane = panes[sessionID] { return pane }
        guard let session = model.session(sessionID) else { return nil }
        let controller = SessionController(
            session: session,
            backend: backend,
            makeSurface: { SwiftTermSurface(appearance: DefaultTheme.appearance(for: NSApp.effectiveAppearance)) })
        controller.delegate = self
        let pane = PaneView(controller: controller)
        pane.titleProvider = { [weak self, weak controller] in
            guard let self, let controller else { return "Shell" }
            return self.displayName(of: controller.session)
        }
        panes[sessionID] = pane
        return pane
    }

    func controller(for sessionID: SessionID) -> SessionController? {
        panes[sessionID]?.controller
    }

    /// Connects the session's controller if it has not been yet: restored
    /// sessions are attached, new ones created.
    func startIfNeeded(_ sessionID: SessionID) {
        guard let controller = controller(for: sessionID), controller.state == .detached else { return }
        let mode: SessionController.StartMode = restoredSessionIDs.contains(sessionID) ? .attach : .create
        Task { await controller.start(mode) }
    }

    /// Ends a session whose pane was closed and forgets it.
    func close(_ sessionID: SessionID) {
        guard let pane = panes.removeValue(forKey: sessionID) else { return }
        restoredSessionIDs.remove(sessionID)
        pane.removeFromSuperview()
        Task { await pane.controller.close() }
    }

    private func displayName(of session: Session) -> String {
        if !session.title.isEmpty { return session.title }
        return model.profile(session.profileID)?.name ?? "Shell"
    }

    /// Sessions can leave the model through any intent (closing a tab,
    /// deleting a workspace); end their processes too.
    private func observeRemovedSessions() {
        let model = model
        pruneTask = Task { [weak self] in
            for await ids in Observations({ Set(model.sessions.map(\.id)) }) {
                guard let self else { return }
                for id in self.panes.keys where !ids.contains(id) {
                    self.close(id)
                }
            }
        }
    }
}

extension SessionRegistry: SessionControllerDelegate {
    func sessionController(_ controller: SessionController, didSetTitle title: String) {
        model.setTitle(title, for: controller.session.id)
    }

    func sessionController(_ controller: SessionController, didChangeDirectory path: String) {
        model.setWorkingDirectory(path, for: controller.session.id)
    }

    func sessionController(_ controller: SessionController, didReplace old: SessionID, with new: Session) {
        // Re-key before the model drops `old`, so pruning doesn't close it.
        if let pane = panes.removeValue(forKey: old) {
            panes[new.id] = pane
        }
        restoredSessionIDs.remove(old)
        model.replaceSession(old, with: new)
    }

    func sessionControllerDidRingBell(_ controller: SessionController) {
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
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
