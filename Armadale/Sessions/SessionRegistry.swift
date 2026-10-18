import AppKit
import ArmadaleCore
import ArmadaleSessions
import Observation
import TerminalSurface

/// What runs the app's (local) sessions.
struct SessionRuntimeSetup {
    var backend: any PersistenceBackend
    var makeOutputFilter: @MainActor () -> any OutputFilter
    /// Sessions outlive the app (the zmx backend). `false` for the plain PTY
    /// fallback.
    var isPersistent: Bool
}

/// Owns one ``SessionController`` (and its ``PaneView``) per session that
/// has been shown, keyed by session ID. Controllers are created lazily when
/// a pane first becomes visible and live until their session leaves the
/// model, so switching tabs or closing a window never destroys a terminal.
/// Also the controllers' delegate: it records titles, directories, runtime
/// versions and respawns in the ``AppModel``.
///
/// At launch it asks the backend once which sessions are alive
/// (``liveProbe``); ``RestorePolicy`` then decides per pane, when it is
/// first shown: create (new this run), attach (restored, maybe alive),
/// ended (restored, gone) or unavailable (restored persistent session while
/// the persistent runtime could not be set up; left alone until
/// ``retryPersistence()`` succeeds).
@MainActor
@Observable
final class SessionRegistry {
    @ObservationIgnored private let model: AppModel
    /// Preferences, themes and renderers for every pane.
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored private var runtime: SessionRuntimeSetup
    @ObservationIgnored private var policy: RestorePolicy
    /// Shown in window subtitles while sessions do not outlive the app.
    private(set) var persistenceWarning: String?
    /// Sets the persistent runtime up again (Retry on an unavailable pane);
    /// `nil` result if it still fails.
    @ObservationIgnored var setUpPersistentRuntime: (() -> SessionRuntimeSetup?)?
    /// A session was ended for good here (closed, or retired by a respawn)
    /// and killed in the backend.
    @ObservationIgnored var onSessionRetired: ((SessionID) -> Void)?
    /// A create recorded the runtime version on a session: worth saving now.
    @ObservationIgnored var onRuntimeVersionRecorded: (() -> Void)?
    /// Sessions recorded by an earlier run of the app. They are attached to,
    /// never created: a session that is gone must show as ended, not be
    /// silently replaced by a fresh shell.
    @ObservationIgnored private var restoredSessionIDs: Set<SessionID>
    /// Restored sessions made by the persistent runtime (captured at launch:
    /// a session being closed has already left the model).
    @ObservationIgnored private let restoredPersistentIDs: Set<SessionID>
    /// The `liveSessions()` call made at launch (and again after a
    /// successful retry); `nil` result if it failed.
    @ObservationIgnored private(set) var liveProbe: Task<Set<SessionID>?, Never>
    /// The probe's answer once it has arrived. Observed, like `panes`, so
    /// status glyphs update when it arrives and when a pane is first shown.
    private var liveAtLaunch: Set<SessionID>?
    private var panes: [SessionID: PaneView] = [:]
    /// Sessions in the model as last observed, and sessions already ended
    /// for good here (closed or retired by a respawn).
    @ObservationIgnored private var knownSessionIDs: Set<SessionID>
    @ObservationIgnored private var finishedSessionIDs: Set<SessionID> = []
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    @ObservationIgnored private var rendererTask: Task<Void, Never>?

    static let persistenceWarningText = "Sessions won’t survive quitting"

    /// The backend new sessions use.
    var backend: any PersistenceBackend { runtime.backend }

    init(model: AppModel, runtime: SessionRuntimeSetup, restoredSessionIDs: Set<SessionID>, settings: AppSettings) {
        self.model = model
        self.settings = settings
        self.runtime = runtime
        self.policy = RestorePolicy(backendIsPersistent: runtime.isPersistent)
        self.restoredSessionIDs = restoredSessionIDs
        self.restoredPersistentIDs = Set(model.sessions.filter {
            restoredSessionIDs.contains($0.id) && RestorePolicy.isPersistent($0)
        }.map(\.id))
        self.persistenceWarning = runtime.isPersistent ? nil : Self.persistenceWarningText
        self.knownSessionIDs = Set(model.sessions.map(\.id))
        liveProbe = Self.probe(runtime.backend)
        awaitProbe()
        observeRemovedSessions()
        observeRenderer()
    }

    private static func probe(_ backend: any PersistenceBackend) -> Task<Set<SessionID>?, Never> {
        Task {
            do {
                return try await backend.liveSessions()
            } catch {
                NSLog("Armadale: could not list live sessions: %@", String(describing: error))
                return nil
            }
        }
    }

    private func awaitProbe() {
        let probe = liveProbe
        Task { [weak self] in
            let live = await probe.value
            self?.liveAtLaunch = live
        }
    }

    /// The pane view for `sessionID`, created (with its controller) on first use.
    func paneView(for sessionID: SessionID) -> PaneView? {
        if let pane = panes[sessionID] { return pane }
        guard let session = model.session(sessionID) else { return nil }
        let settings = settings
        let factory = settings.surfaceFactory
        let controller = SessionController(
            session: session,
            backend: runtime.backend,
            makeSurface: {
                factory.makeSurface(appearance: settings.terminalAppearance(for: NSApp.effectiveAppearance))
            },
            makeOutputFilter: runtime.makeOutputFilter)
        controller.delegate = self
        let pane = PaneView(controller: controller, settings: settings, rendererID: factory.id)
        pane.titleProvider = { [weak self, weak controller] in
            guard let self, let controller else { return "Shell" }
            return self.displayName(of: controller.session)
        }
        pane.onRetryPersistence = { [weak self] in self?.retryPersistence() }
        panes[sessionID] = pane
        return pane
    }

    func controller(for sessionID: SessionID) -> SessionController? {
        panes[sessionID]?.controller
    }

    /// Connects the session's controller if it has not been yet, as
    /// ``RestorePolicy`` says.
    func startIfNeeded(_ sessionID: SessionID) {
        guard let controller = controller(for: sessionID), controller.state == .detached else { return }
        let restored = restoredSessionIDs.contains(sessionID)
        guard restored else {
            Task { await controller.start(.create) }
            return
        }
        let probe = liveProbe
        Task {
            let live = await probe.value
            guard controller.state == .detached else { return }
            switch policy.action(for: controller.session, restored: true, live: live) {
            case .create, .attach: await controller.start(.attach)
            case .markEnded: controller.markEnded()
            case .markUnavailable: controller.markUnavailable(reason: "Persistent sessions are unavailable.")
            }
        }
    }

    /// Ends a session whose pane was closed and forgets it. A session that
    /// was never shown has no controller, but may still be alive in the
    /// backend (restored, not yet attached), so it is killed there too.
    /// Unavailable sessions cannot be reached, so they are left running.
    func close(_ sessionID: SessionID) {
        guard finishedSessionIDs.insert(sessionID).inserted else { return }
        let wasRestored = restoredSessionIDs.remove(sessionID) != nil
        if let pane = panes.removeValue(forKey: sessionID) {
            pane.removeFromSuperview()
            let controller = pane.controller
            let retires = !controller.state.isUnavailable
            Task { [weak self] in
                await controller.close()
                if retires { self?.onSessionRetired?(sessionID) }
            }
        } else {
            if wasRestored, !runtime.isPersistent, restoredPersistentIDs.contains(sessionID) {
                return // unavailable: cannot be reached, never killed blindly
            }
            let backend = runtime.backend
            Task { [weak self] in
                try? await backend.kill(sessionID)
                self?.onSessionRetired?(sessionID)
            }
        }
    }

    /// Disconnects every client at once without ending any session; used
    /// when the app quits (synchronous, so quitting never waits).
    func detachAllNow() {
        for pane in panes.values where pane.controller.state.isAttached {
            pane.controller.detachNow()
        }
    }

    // MARK: Persistence availability

    /// Retry on an unavailable pane: sets the persistent runtime up again
    /// and, if that works, attaches every unavailable session through it.
    /// Sessions created as plain PTY sessions meanwhile stay as they are.
    func retryPersistence() {
        guard !runtime.isPersistent, let setup = setUpPersistentRuntime?(), setup.isPersistent else {
            NSLog("Armadale: persistent sessions are still unavailable")
            return
        }
        runtime = setup
        policy = RestorePolicy(backendIsPersistent: true)
        persistenceWarning = nil
        liveProbe = Self.probe(setup.backend)
        awaitProbe()
        for pane in panes.values where pane.controller.state.isUnavailable {
            pane.controller.useBackend(setup.backend, makeOutputFilter: setup.makeOutputFilter)
            startIfNeeded(pane.controller.session.id)
        }
    }

    // MARK: Ended sessions

    /// Whether `sessionID` is known to have ended: its controller says so,
    /// or it was restored, not shown yet, and the policy calls it gone
    /// (never an unavailable one).
    private func isEnded(_ sessionID: SessionID) -> Bool {
        if let controller = controller(for: sessionID) {
            if controller.state.isEnded { return true }
            guard controller.state == .detached else { return false }
        }
        guard let session = model.session(sessionID) else { return false }
        return policy.mayRespawnUnshown(session, restored: restoredSessionIDs.contains(sessionID), live: liveAtLaunch)
    }

    /// Whether any pane of the workspace shows an ended session.
    func hasEndedSessions(in workspaceID: WorkspaceID) -> Bool {
        model.sessionIDs(in: workspaceID).contains { isEnded($0) }
    }

    /// Workspace › Respawn All Ended: respawns every ended session in the
    /// workspace's panes, including ones whose tab was not shown yet (the
    /// morning after a reboot). Disconnected and unavailable sessions are
    /// not ended and are left alone.
    func respawnAllEnded(in workspaceID: WorkspaceID) {
        for sessionID in model.sessionIDs(in: workspaceID) where isEnded(sessionID) {
            guard let controller = paneView(for: sessionID)?.controller else { continue }
            controller.markEnded() // a pane never shown is still detached
            Task { await controller.respawn() }
        }
    }

    // MARK: Status

    /// The status of one session, from its controller if it has been shown,
    /// else from the launch probe.
    func status(of sessionID: SessionID) -> SessionStatus {
        if let controller = panes[sessionID]?.controller {
            switch controller.state {
            case .attached: return .running
            case .ended: return .ended
            case .disconnected: return .disconnected
            case .unavailable: return .unavailable
            case .attaching: return .pending
            case .detached: break
            }
        }
        guard let session = model.session(sessionID) else { return .ended }
        let restored = restoredSessionIDs.contains(sessionID)
        guard restored else { return .pending }
        switch policy.action(for: session, restored: true, live: liveAtLaunch) {
        case .markEnded: return .ended
        case .markUnavailable: return .unavailable
        case .create, .attach: return liveAtLaunch?.contains(sessionID) == true ? .running : .pending
        }
    }

    /// The summary of several sessions (a tab's panes).
    func status(of sessionIDs: [SessionID]) -> SessionStatus {
        SessionStatus.summary(of: sessionIDs.map { status(of: $0) })
    }

    /// Whether closing these sessions needs a confirmation (``CloseRisk``).
    func closeRisk(of sessionIDs: [SessionID]) -> CloseRisk {
        CloseRisk.assess(sessionIDs.map { id in
            CloseRisk.Item(
                status: status(of: id),
                mayExist: restoredSessionIDs.contains(id) || panes[id].map { $0.controller.state != .detached } ?? false,
                isRunning: panes[id]?.controller.isRunning ?? false)
        })
    }

    // MARK: Helpers

    private func displayName(of session: Session) -> String {
        if !session.title.isEmpty { return session.title }
        return model.profile(session.profileID)?.name ?? "Shell"
    }

    /// A renderer change applies to new panes at once and to existing ones
    /// at their next attach (DESIGN §5): live terminals are never rebuilt.
    private func observeRenderer() {
        let preferences = settings.preferences
        rendererTask = Task { [weak self] in
            var last: String?
            for await id in Observations({ preferences.rendererID }) {
                guard let self else { return }
                if last != nil, last != id {
                    let factory = self.settings.surfaces.factory(for: id)
                    for pane in self.panes.values { pane.useRenderer(factory) }
                }
                last = id
            }
        }
    }

    /// Sessions can leave the model through any intent (closing a tab,
    /// deleting a workspace); end them too.
    private func observeRemovedSessions() {
        let model = model
        pruneTask = Task { [weak self] in
            for await ids in Observations({ Set(model.sessions.map(\.id)) }) {
                guard let self else { return }
                let removed = self.knownSessionIDs.subtracting(ids)
                self.knownSessionIDs = ids
                for id in removed {
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

    func sessionController(_ controller: SessionController, didRecordRuntimeVersion version: String) {
        model.setRuntimeVersion(version, for: controller.session.id)
        // Without it a crash would leave the session looking non-persistent.
        onRuntimeVersionRecorded?()
    }

    func sessionController(_ controller: SessionController, didReplace old: SessionID, with new: Session) {
        // Re-key before the model drops `old`; the old session is retired
        // (the controller already killed it), so pruning leaves it alone.
        if let pane = panes.removeValue(forKey: old) {
            panes[new.id] = pane
        }
        finishedSessionIDs.insert(old)
        restoredSessionIDs.remove(old)
        model.replaceSession(old, with: new)
        onSessionRetired?(old)
    }

    func sessionController(_ controller: SessionController, launchForRespawning session: Session) -> LaunchSpec? {
        model.launchForRespawn(of: session)
    }

    func sessionController(_ controller: SessionController, didReplaceSurface old: any TerminalSurface) {
        panes.values.first { $0.controller === controller }?.surfaceWasReplaced(old)
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
