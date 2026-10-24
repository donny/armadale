import AppKit
import ArmadaleCore
import ArmadaleSessions
import Observation
import TerminalSurface

/// How the app reaches SSH hosts (docs/DESIGN.md section 6): one shared
/// transport, and what every host's ``RemoteZmxBackend`` is made with.
struct RemoteSessionSupport {
    var transport: any SSHTransport
    /// `ctty-exec` for ssh clients; `nil` asks ``HelperLocator``.
    var cttyExec: String?
    var appVersion: String
    /// How disconnected remote sessions are retried.
    var reconnectSchedule = ReconnectSchedule()
    /// The bundled zmx for a host's platform.
    var binary: @Sendable (RemotePlatform) throws -> URL = { try HelperLocator.remoteZmx(for: $0) }

    func makeBackend(for host: ArmadaleCore.Host) -> RemoteZmxBackend {
        var configuration = RemoteZmxBackend.Configuration(host: host, transport: transport)
        configuration.cttyExec = cttyExec
        configuration.appVersion = appVersion
        configuration.binary = binary
        return RemoteZmxBackend(configuration: configuration)
    }
}

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
///
/// Remote sessions (step 6) use one ``RemoteZmxBackend`` per host, made
/// when first needed and replaced when the host's settings change. Each
/// host referenced by a restored session is probed in the background; until
/// its answer arrives its sessions show as starting, and a host that does
/// not answer leaves them disconnected (retried by schedule), never ended.
/// A session whose host was removed is unavailable: left running, never
/// killed.
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
    /// Receives bells and notifications from every session (DESIGN §10);
    /// the status glyphs show its attention. `nil` in tests that do not
    /// need it.
    @ObservationIgnored var attention: AttentionCenter?
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
    /// Hosts of remote sessions as last observed: a session closed from
    /// the model is gone from it by the time it is ended here.
    @ObservationIgnored private var lastHosts: [SessionID: HostID] = [:]
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    @ObservationIgnored private var rendererTask: Task<Void, Never>?
    @ObservationIgnored private var hostsTask: Task<Void, Never>?
    /// SSH support; `nil` when remote sessions are off (tests).
    @ObservationIgnored let remote: RemoteSessionSupport?
    /// One backend per host, made on first use.
    @ObservationIgnored private var remoteBackends: [HostID: RemoteZmxBackend] = [:]
    /// Each host's live sessions, asked once per backend (in the background).
    @ObservationIgnored private var remoteProbes: [HostID: Task<Set<SessionID>?, Never>] = [:]
    /// The answers that have arrived (observed, like ``liveAtLaunch``); a
    /// host whose probe failed has none.
    private var remoteLive: [HostID: Set<SessionID>] = [:]

    static let persistenceWarningText = "Sessions won’t survive quitting"

    /// The backend new sessions use.
    var backend: any PersistenceBackend { runtime.backend }

    init(
        model: AppModel, runtime: SessionRuntimeSetup, restoredSessionIDs: Set<SessionID>, settings: AppSettings,
        remote: RemoteSessionSupport? = nil
    ) {
        self.model = model
        self.settings = settings
        self.runtime = runtime
        self.remote = remote
        self.policy = RestorePolicy(backendIsPersistent: runtime.isPersistent)
        self.restoredSessionIDs = restoredSessionIDs
        self.restoredPersistentIDs = Set(model.sessions.filter {
            restoredSessionIDs.contains($0.id) && RestorePolicy.isPersistent($0)
        }.map(\.id))
        self.persistenceWarning = runtime.isPersistent ? nil : Self.persistenceWarningText
        self.knownSessionIDs = Set(model.sessions.map(\.id))
        self.lastHosts = Dictionary(
            model.sessions.compactMap { session in session.remoteHostID.map { (session.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        liveProbe = Self.probe(runtime.backend)
        awaitProbe()
        observeRemovedSessions()
        observeRenderer()
        observeHosts()
        // Hosts of restored sessions are asked in the background; nothing
        // waits for them.
        let hosts = Set(model.sessions.filter { restoredSessionIDs.contains($0.id) }.compactMap(\.remoteHostID))
        for host in hosts.sorted() { _ = remoteProbe(for: host) }
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
        let remoteBackend = session.remoteHostID.flatMap { remoteBackend(for: $0) }
        var makeOutputFilter = runtime.makeOutputFilter
        if session.remoteHostID != nil { makeOutputFilter = { ZmxOutputFilter() } }
        let controller = SessionController(
            session: session,
            backend: remoteBackend ?? runtime.backend,
            makeSurface: {
                factory.makeSurface(appearance: settings.terminalAppearance(for: NSApp.effectiveAppearance))
            },
            makeOutputFilter: makeOutputFilter)
        controller.delegate = self
        if session.remoteHostID != nil {
            controller.reconnectSchedule = remote?.reconnectSchedule
            // Never reached through the local backend.
            if remoteBackend == nil { controller.markUnavailable(reason: unreachableHostReason(for: session)) }
        }
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
        if let host = controller.session.remoteHostID {
            startRemote(controller, host: host, restored: restored)
            return
        }
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
            case .markEnded: await markEnded(controller)
            case .markUnavailable: controller.markUnavailable(reason: "Persistent sessions are unavailable.")
            }
        }
    }

    /// ``startIfNeeded(_:)`` for a session on `host`: created if new;
    /// attached if restored and its host's probe did not find it gone. One
    /// that was never persistent (a plain ssh shell) cannot be reattached.
    private func startRemote(_ controller: SessionController, host: HostID, restored: Bool) {
        guard remoteBackend(for: host) != nil else {
            controller.markUnavailable(reason: unreachableHostReason(for: controller.session))
            return
        }
        guard restored else {
            Task { await controller.start(.create) }
            return
        }
        guard RestorePolicy.isPersistent(controller.session) else {
            controller.markEnded()
            return
        }
        let probe = remoteProbe(for: host)
        Task {
            let live = await probe.value
            guard controller.state == .detached else { return }
            // An unanswered probe (host down) attaches anyway: the attach
            // then fails as unreachable and is retried, never ended.
            if let live, !live.contains(controller.session.id) {
                await markEnded(controller)
            } else {
                await controller.start(.attach)
            }
        }
    }

    /// Shows a restored session that is gone as ended, with the exit status
    /// its backend recorded (a clean exit then closes its pane: see
    /// ``closePaneIfEndedCleanly(_:exitStatus:)``).
    private func markEnded(_ controller: SessionController) async {
        let id = controller.session.id
        let status = await controller.activeBackend.recordedExitStatuses(of: [id])[id]
        controller.markEnded(exitCode: status)
    }

    // MARK: Clean exits

    /// The rule for a session whose program ended (``EndedSessionRule``,
    /// docs/DESIGN.md section 4, "Ended"): after a clean exit (status 0, or
    /// any normal exit of the user's shell) its pane closes the way the
    /// placeholder's Close Pane closes it (no question: nothing runs), which
    /// closes the tab with its last pane and the tab group with its last
    /// tab, unless it is the only pane of the only tab of the only tab group
    /// of its workspace. Returns whether it closed.
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
            let session = model.session(sessionID)
            if let host = session?.remoteHostID ?? lastHosts[sessionID] {
                // A session on a removed host cannot be reached: left alone.
                guard let backend = remoteBackend(for: host) else { return }
                Task { [weak self] in
                    try? await backend.kill(sessionID)
                    self?.onSessionRetired?(sessionID)
                }
                return
            }
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

    /// End Sessions and Quit (docs/DESIGN.md section 8): ends every
    /// session that may be alive, all at once. Shown panes go through their
    /// controllers (``SessionController/close()``: the backend's kill, then
    /// the client); sessions never shown are killed in their backend
    /// (restored ones may be alive). Unreachable sessions are left: those of
    /// a removed host, and persistent sessions while the persistent runtime
    /// is unavailable. Each kill is bounded by its backend's command
    /// timeout, so this returns within the longest of them. Panes stay in
    /// place, ended; the model is not changed. `only` limits it to those
    /// sessions (a second pass); returns the sessions it went through.
    @discardableResult
    func endAllSessions(only: Set<SessionID>? = nil) async -> Set<SessionID> {
        let ids = only ?? Set(model.sessions.map(\.id)).union(panes.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                if let controller = panes[id]?.controller {
                    group.addTask { await controller.close() }
                } else if let session = model.session(id) {
                    if let host = session.remoteHostID {
                        guard let backend = remoteBackend(for: host) else { continue }
                        group.addTask { try? await backend.kill(id) }
                    } else if runtime.isPersistent {
                        let backend = runtime.backend
                        group.addTask { try? await backend.kill(id) }
                    }
                }
            }
        }
        return ids
    }

    /// Sessions that may be running although an End pass went through
    /// `ended`: ones it did not cover (a tab opened meanwhile), and covered
    /// ones whose pane runs again (a Respawn meanwhile). A covered session
    /// that was never shown is judged gone: its launch-probe status is
    /// stale after the kill.
    func sessionsRunning(after ended: Set<SessionID>) -> Set<SessionID> {
        Set(model.sessions.map(\.id).filter { id in
            guard ended.contains(id) else { return CloseRisk.mayBeRunning(riskItem(for: id)) }
            return panes[id] != nil && CloseRisk.mayBeRunning(riskItem(for: id))
        })
    }

    /// Whether local sessions outlive the app in this run (the persistent
    /// runtime is set up). In the fallback they end with any quit.
    var sessionsSurviveQuit: Bool { runtime.isPersistent }

    // MARK: Persistence availability

    /// Retry on an unavailable pane: sets the persistent runtime up again
    /// and, if that works, attaches every unavailable session through it.
    /// Sessions created as plain PTY sessions meanwhile stay as they are.
    func retryPersistence() {
        // Remote sessions only need their host back.
        for pane in panes.values where pane.controller.state.isUnavailable {
            guard let host = pane.controller.session.remoteHostID, let backend = remoteBackend(for: host) else { continue }
            pane.controller.useBackend(backend, makeOutputFilter: { ZmxOutputFilter() })
            startIfNeeded(pane.controller.session.id)
        }
        guard !runtime.isPersistent else { return }
        guard let setup = setUpPersistentRuntime?(), setup.isPersistent else {
            NSLog("Armadale: persistent sessions are still unavailable")
            return
        }
        runtime = setup
        policy = RestorePolicy(backendIsPersistent: true)
        persistenceWarning = nil
        liveProbe = Self.probe(setup.backend)
        awaitProbe()
        for pane in panes.values where pane.controller.state.isUnavailable && pane.controller.session.remoteHostID == nil {
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
        let restored = restoredSessionIDs.contains(sessionID)
        if let host = session.remoteHostID {
            guard restored, model.host(host) != nil else { return false }
            guard RestorePolicy.isPersistent(session) else { return true }
            return remoteLive[host].map { !$0.contains(sessionID) } ?? false
        }
        return policy.mayRespawnUnshown(session, restored: restored, live: liveAtLaunch)
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
                self.remoteLive[host] = live
                for sessionID in candidates where !live.contains(sessionID) && self.isEnded(sessionID) {
                    self.respawn(sessionID)
                }
            }
        }
    }

    private func respawn(_ sessionID: SessionID) {
        guard let controller = paneView(for: sessionID)?.controller else { return }
        controller.markEnded() // a pane never shown is still detached
        Task { await controller.respawn() }
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
        if let host = session.remoteHostID {
            guard model.host(host) != nil, remote != nil else { return .unavailable }
            guard restored else { return .pending }
            guard RestorePolicy.isPersistent(session) else { return .ended }
            // Not probed yet, or the host did not answer: starting.
            guard let live = remoteLive[host] else { return .pending }
            return live.contains(sessionID) ? .running : .ended
        }
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

    /// What a session's glyph shows: its status, or attention
    /// (``SessionStatus/withAttention(_:)``).
    func glyphStatus(of sessionID: SessionID) -> SessionStatus {
        status(of: sessionID).withAttention(attention?.needsAttention(sessionID) ?? false)
    }

    /// The glyph of several sessions (a tab's panes), by
    /// ``SessionStatus/precedence``.
    func glyphStatus(of sessionIDs: [SessionID]) -> SessionStatus {
        SessionStatus.summary(of: sessionIDs.map { glyphStatus(of: $0) })
    }

    /// Whether closing these sessions needs a confirmation (``CloseRisk``).
    func closeRisk(of sessionIDs: [SessionID]) -> CloseRisk {
        CloseRisk.assess(sessionIDs.map(riskItem(for:)))
    }

    /// How many of the model's sessions may still have a live process, by
    /// the close-confirmation rule (``CloseRisk/mayBeRunning(_:)``): what a
    /// quit asks about and the status item's menu shows.
    func runningSessionCount() -> Int {
        QuitDecision.runningCount(model.sessions.map { riskItem(for: $0.id) })
    }

    private func riskItem(for id: SessionID) -> CloseRisk.Item {
        CloseRisk.Item(
            status: status(of: id),
            mayExist: restoredSessionIDs.contains(id) || panes[id].map { $0.controller.state != .detached } ?? false,
            isRunning: panes[id]?.controller.isRunning ?? false)
    }

    // MARK: Remote hosts

    /// Why a remote session cannot be reached at all: its host was removed
    /// (or remote sessions are off in this run).
    static let hostRemovedReason = "The host this session runs on was removed from Settings › Hosts."

    private func unreachableHostReason(for session: Session) -> String {
        remote == nil ? "Remote sessions are not available in this run." : Self.hostRemovedReason
    }

    /// The backend for `host`, made on first use; `nil` if the host is gone
    /// (or remote sessions are off).
    func remoteBackend(for host: HostID) -> RemoteZmxBackend? {
        guard let remote, let settings = model.host(host) else { return nil }
        if let existing = remoteBackends[host], existing.host == settings { return existing }
        let backend = remote.makeBackend(for: settings)
        let versions = Dictionary(
            model.sessions.filter { $0.remoteHostID == host }.compactMap { session in session.runtimeVersion.map { (session.id, $0) } },
            uniquingKeysWith: { _, last in last })
        Task { await backend.noteRuntimeVersions(versions) }
        remoteBackends[host] = backend
        return backend
    }

    /// The host's live-session probe, started on first use.
    private func remoteProbe(for host: HostID) -> Task<Set<SessionID>?, Never> {
        if let probe = remoteProbes[host] { return probe }
        guard let backend = remoteBackend(for: host) else { return Task { nil } }
        let probe = Self.probe(backend)
        remoteProbes[host] = probe
        Task { [weak self] in
            guard let live = await probe.value, let self else { return }
            self.remoteLive[host] = live
            await self.closeRestoredSessionsThatEndedCleanly(on: host, backend: backend, live: live)
        }
        return probe
    }

    /// Restored sessions on `host` whose panes have not been shown and that
    /// the host's first listing found gone: those whose programs exited
    /// cleanly (their wrapper recorded 0) lose their panes, as at launch for
    /// local sessions. Shown panes get the same rule through their
    /// controllers (``markEnded(_:)``).
    func closeRestoredSessionsThatEndedCleanly(on host: HostID, backend: any PersistenceBackend, live: Set<SessionID>) async {
        let candidates = Set(model.sessions.filter { session in
            session.remoteHostID == host && restoredSessionIDs.contains(session.id) && RestorePolicy.isPersistent(session)
                && !live.contains(session.id) && (controller(for: session.id)?.state ?? .detached) == .detached
        }.map(\.id))
        guard !candidates.isEmpty else { return }
        let statuses = await backend.recordedExitStatuses(of: candidates)
        let unshown = statuses.filter { panes[$0.key] == nil }
        closePanesOfSessionsThatEndedCleanly(unshown)
    }

    /// The hosts of some sessions (a tab's panes), in order, without repeats.
    func hosts(of sessionIDs: [SessionID]) -> [ArmadaleCore.Host] {
        var seen: Set<HostID> = []
        return sessionIDs.compactMap { model.session($0)?.remoteHostID }.filter { seen.insert($0).inserted }.compactMap {
            model.host($0)
        }
    }

    /// Why one of these sessions will not survive quitting although it runs
    /// on a host (it could not take the persistence helper), if any.
    func persistenceNote(of sessionIDs: [SessionID]) -> String? {
        sessionIDs.lazy.compactMap { self.panes[$0]?.controller.persistenceNote }.first
    }

    /// Settings › Hosts › Test Connection: what the host is, and whether
    /// Armadale's helper is there. Throws when it cannot be reached.
    func testConnection(to host: ArmadaleCore.Host) async throws -> String {
        guard let remote else { throw BackendError.unreachable("Remote sessions are not available in this run.") }
        do {
            let probe = try await RemoteDeployer(host: host, transport: remote.transport).probe()
            let system = probe.platform?.displayName ?? probe.uname
            return probe.platform == nil
                ? "Connected. \(host.displayName) runs \(system), which Armadale can’t keep sessions on."
                : "Connected to \(system)." + (probe.isDeployed ? " The persistence helper is installed." : " The persistence helper will be installed when you first open a session there.")
        } catch let failure as SSHFailure {
            if case .needsInteraction = failure {
                throw BackendError.unreachable(failure.message
                    + " Armadale can’t answer prompts here: open a tab on this host to sign in, then test again.")
            }
            throw BackendError.unreachable(failure.message)
        }
    }

    /// Settings › Hosts › Deploy Now.
    func deployHelper(to host: ArmadaleCore.Host) async throws -> String {
        guard let remote else { throw BackendError.unreachable("Remote sessions are not available in this run.") }
        let deployer = RemoteDeployer(host: host, transport: remote.transport, binary: remote.binary)
        do {
            let deployment = try await deployer.deploy()
            return "Installed the persistence helper " + (deployment.platform.map { "for \($0.displayName) " } ?? "")
                + "in \(host.remoteDirectory) on \(host.displayName)."
        } catch let failure as SSHFailure {
            throw BackendError.unreachable(failure.message)
        }
    }

    /// Host edits apply from each session's next connection: the host gets a
    /// new backend and every controller of its sessions switches to it (a
    /// live client keeps running; its next reattach, reconnect or retry
    /// uses the new settings). A removed host's sessions are hung up and
    /// become unavailable, with a backend that refuses everything, so
    /// closing them later ends nothing on the host.
    private func observeHosts() {
        let model = model
        hostsTask = Task { [weak self] in
            for await hosts in Observations({ model.hosts }) {
                guard let self else { return }
                let current = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for (id, backend) in self.remoteBackends where current[id] != backend.host {
                    self.remoteBackends[id] = nil
                    self.remoteProbes[id] = nil
                    self.remoteLive[id] = nil
                    let replacement = self.remoteBackend(for: id)
                    for pane in self.panes.values where pane.controller.session.remoteHostID == id {
                        let controller = pane.controller
                        if let replacement {
                            controller.useBackend(replacement, makeOutputFilter: { ZmxOutputFilter() })
                        } else {
                            controller.detachAsUnavailable(
                                reason: Self.hostRemovedReason, backend: UnavailableBackend(reason: Self.hostRemovedReason))
                        }
                    }
                }
            }
        }
    }

    /// A workspace's window closed (or opened again): its remote sessions
    /// stop (or resume) retrying lost connections by themselves.
    func setWindowOpen(_ isOpen: Bool, for workspace: WorkspaceID) {
        for id in model.sessionIDs(in: workspace) {
            guard let controller = controller(for: id) else { continue }
            if isOpen { controller.resumeAutomaticReconnect() } else { controller.pauseAutomaticReconnect() }
        }
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
            for await sessions in Observations({ model.sessions.map { ($0.id, $0.remoteHostID) } }) {
                guard let self else { return }
                let ids = Set(sessions.map(\.0))
                let removed = self.knownSessionIDs.subtracting(ids)
                for (id, host) in sessions { if let host { self.lastHosts[id] = host } }
                self.knownSessionIDs = ids
                for id in removed {
                    self.close(id)
                    self.lastHosts[id] = nil
                }
            }
        }
    }
}

extension SessionRegistry: SessionControllerDelegate {
    func sessionController(_ controller: SessionController, didChangeState state: SessionState) {
        // A clean exit takes its pane with it (DESIGN §4, "Ended").
        if case .ended(let exit?) = state {
            closePaneIfEndedCleanly(controller.session.id, exit: exit)
        }
    }

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
