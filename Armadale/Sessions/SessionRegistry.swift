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
    /// Sessions alive although a listing left them out: their socket exists
    /// in the runtime directory and they have no exit record
    /// (``ZmxRuntime/sessionsAliveWithoutListing()``), read after a listing:
    /// the helper's listing leaves out a daemon that does not answer and
    /// still succeeds, and removes the stale socket of a killed one. None
    /// without a runtime directory.
    var socketSessions: @MainActor () -> Set<SessionID> = { [] }
}

/// What a host's listing said (docs/DESIGN.md section 6), kept with why it
/// failed: a host that needs the user (a sign-in, an unknown or changed
/// host key, a refused key) gets no attach for a pane that is not on
/// screen, so no hidden pane ever sits at a password prompt.
enum HostListing: Sendable, Hashable {
    case live(Set<SessionID>)
    /// It could not be reached (or the listing failed otherwise): nothing
    /// is known, nothing is ended.
    case unreachable
    /// Connecting needs the user.
    case needsUser
}

/// Owns one ``SessionController`` per session in the model, from the
/// moment the session exists until it leaves the model (docs/DESIGN.md
/// section 8), and the ``PaneView`` of each session shown so far
/// (``PaneViewStore``), made when its pane is first shown around the
/// controller that already exists. Switching tabs or closing a window
/// never destroys a terminal. Also the controllers' delegate
/// (`SessionRegistry+Delegate.swift`): it records titles, directories,
/// runtime versions, grid sizes and respawns in the ``AppModel``.
///
/// The parts, by file:
/// - this file: the controllers, how a session is started when its pane is
///   shown (``startIfNeeded(_:)``), Retry on an unavailable pane;
/// - `SessionRegistry+Ending.swift`: clean exits, closing and ending
///   sessions, Respawn All Ended;
/// - `SessionRegistry+Status.swift`: status, glyphs, close risk, the
///   running count, the pane header's content;
/// - `PaneViewStore.swift`: the pane views;
/// - `SessionRegistry+LaunchAttach.swift`: attaching restored sessions whose
///   panes are not on screen once their location's first listing has
///   answered, a few at a time (``LaunchAttachQueue``);
/// - `SessionRegistry+Remote.swift`: one ``RemoteZmxBackend`` per host,
///   each host's listing, host edits and removals;
/// - `SessionRegistry+Delegate.swift`: the controllers' delegate;
/// - `GridSizeRecorder.swift`: each session's last grid size, recorded
///   when it has settled.
///
/// A restored session that is not attached (its location has not answered
/// yet, its host needs the user, it has no saved size) shows the launch
/// listing's answer as its status: alive → running, unanswered → starting.
@MainActor
@Observable
final class SessionRegistry {
    @ObservationIgnored let model: AppModel
    /// Preferences, themes and renderers for every pane.
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored var runtime: SessionRuntimeSetup
    @ObservationIgnored var policy: RestorePolicy
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
    /// The actions of a workspace's open window (set by the app delegate),
    /// through which a pane's header and menu split it (``split(pane:axis:)``).
    @ObservationIgnored var actionsOfWorkspace: (WorkspaceID) -> WorkspaceActions? = { _ in nil }
    /// Sessions recorded by an earlier run of the app. They are attached to,
    /// never created: a session that is gone must show as ended, not be
    /// silently replaced by a fresh shell.
    @ObservationIgnored var restoredSessionIDs: Set<SessionID>
    /// One controller per session in the model. Observed, so status glyphs
    /// follow a controller made after they were first drawn.
    var controllers: [SessionID: SessionController] = [:]
    /// The pane views of the sessions shown so far.
    @ObservationIgnored let paneViews = PaneViewStore()
    /// The local `liveSessions()` call made at launch (and again after a
    /// successful retry); `nil` result if it failed.
    @ObservationIgnored private(set) var liveProbe: Task<Set<SessionID>?, Never>
    /// The local listing's answer once it has arrived (`nil` while it has
    /// not, or when it failed), and the sessions whose socket existed then.
    /// Observed: the status of a session that is not attached comes from
    /// them.
    private(set) var localListed: Set<SessionID>?
    private(set) var localSockets: Set<SessionID> = []
    /// Sessions in the model as last observed, and sessions already ended
    /// for good here (closed or retired by a respawn).
    @ObservationIgnored var knownSessionIDs: Set<SessionID>
    @ObservationIgnored var finishedSessionIDs: Set<SessionID> = []
    @ObservationIgnored private var sessionsTask: Task<Void, Never>?
    @ObservationIgnored private var rendererTask: Task<Void, Never>?
    @ObservationIgnored var hostsTask: Task<Void, Never>?
    /// SSH support; `nil` when remote sessions are off (tests).
    @ObservationIgnored let remote: RemoteSessionSupport?
    /// One backend per host, made on first use.
    @ObservationIgnored var remoteBackends: [HostID: RemoteZmxBackend] = [:]
    /// Each host's listing, asked once per backend (in the background), or
    /// again after a sign-in or a host edit.
    @ObservationIgnored var hostListingTasks: [HostID: Task<HostListing, Never>] = [:]
    /// The answers that have arrived (observed, like ``localListed``).
    var hostListings: [HostID: HostListing] = [:]
    /// Hosts whose listing needed the user: listed again once one of their
    /// sessions connects (a shown pane signed in).
    @ObservationIgnored var hostsAwaitingUser: Set<HostID> = []
    /// The launch attaches still to make (``LaunchAttachQueue``).
    @ObservationIgnored var launchQueue = LaunchAttachQueue()
    /// Restored sessions whose start was asked for by their pane being
    /// shown (``startIfNeeded(_:)``): the launch pass leaves them alone.
    @ObservationIgnored var startRequested: Set<SessionID> = []
    /// Starts by ``startIfNeeded(_:)`` still waiting or connecting: one per
    /// session, however often its pane is shown meanwhile.
    @ObservationIgnored var startsInProgress: Set<SessionID> = []
    /// The launch pass runs only once the app has opened its windows
    /// (``startLaunchPass()``), so panes about to be shown start at their
    /// laid-out size; the listings may answer before that.
    @ObservationIgnored var isLaunchPassStarted = false
    /// The local listing has answered (``localListed`` is its answer, `nil`
    /// if it failed).
    @ObservationIgnored var hasLocalAnswer = false
    /// Hidden sessions on a host that needs the user, whose automatic
    /// retries stopped (``retryPreflight(for:)``): the relisting after a
    /// sign-in reconnects them.
    @ObservationIgnored var waitingForUser: Set<SessionID> = []
    /// Sessions of ``waitingForUser`` that reconnected once when their pane
    /// was shown (``startIfNeeded(_:)``); never twice by itself.
    @ObservationIgnored var reconnectedWhenShown: Set<SessionID> = []
    /// End Sessions and Quit is ending sessions: their ends say nothing
    /// about a host. While it runs this also suppresses the relist for an
    /// end the app did not cause (an attach finding its session gone at the
    /// same moment); harmless, since the app quits right after.
    @ObservationIgnored var isEndingAllSessions = false
    /// The renderer each controller's surface was made with, and the one a
    /// pending replacement will use, for sessions whose pane view has not
    /// been made yet (a pane view keeps its own).
    @ObservationIgnored var surfaceRenderers: [SessionID: (current: String, pending: String?)] = [:]
    /// Each session's last grid size, written to the model once settled.
    @ObservationIgnored let gridSizes: GridSizeRecorder

    static let persistenceWarningText = "Sessions won’t survive quitting"
    static let unavailableReason = "Persistent sessions are unavailable."

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
        self.persistenceWarning = runtime.isPersistent ? nil : Self.persistenceWarningText
        self.knownSessionIDs = Set(model.sessions.map(\.id))
        self.liveProbe = Self.probe(runtime.backend)
        self.gridSizes = GridSizeRecorder(
            current: { [model] in model.session($0)?.gridSize },
            write: { [model] in model.setGridSizes($0) })
        for session in model.sessions { ensureController(for: session.id) }
        awaitLocalProbe()
        observeSessions()
        observeRenderer()
        observeHosts()
        // Hosts of restored sessions are listed in the background; nothing
        // waits for them.
        let hosts = Set(model.sessions.filter { restoredSessionIDs.contains($0.id) }.compactMap(\.remoteHostID))
        for host in hosts.sorted() { _ = hostListing(for: host) }
    }

    static func probe(_ backend: any PersistenceBackend) -> Task<Set<SessionID>?, Never> {
        Task {
            do {
                return try await backend.liveSessions()
            } catch {
                NSLog("Armadale: could not list live sessions: %@", String(describing: error))
                return nil
            }
        }
    }

    /// When the local listing answers: its answer (with the sockets present
    /// then) becomes the status of restored sessions not attached yet, and
    /// the launch pass runs (``runLocalLaunchPass()``).
    func awaitLocalProbe() {
        let probe = liveProbe
        Task { [weak self] in
            let listed = await probe.value
            guard let self, self.liveProbe == probe else { return }
            self.localSockets = self.runtime.isPersistent ? self.runtime.socketSessions() : []
            self.localListed = listed
            self.hasLocalAnswer = true
            if self.isLaunchPassStarted { await self.runLocalLaunchPass() }
        }
    }

    /// The app has opened its windows (their panes on screen have asked to
    /// start): the launch pass runs now for every location whose listing
    /// has answered, and for the others when theirs does. Tests call it
    /// themselves.
    func startLaunchPass() {
        guard !isLaunchPassStarted else { return }
        isLaunchPassStarted = true
        Task { [weak self] in
            guard let self else { return }
            if self.hasLocalAnswer { await self.runLocalLaunchPass() }
            for host in self.hostListings.keys.sorted() { await self.runHostLaunchPass(host: host) }
        }
    }

    /// Splits `paneID` from its header or its menu (``PaneThemeBinding/split``):
    /// through its window's ``WorkspaceActions/split(pane:axis:)``, as ⌘D
    /// does for the focused pane, or the model alone when no window shows
    /// it (tests).
    func split(pane paneID: PaneID, axis: ArmadaleCore.Axis) {
        if let tab = model.tab(containing: paneID), let workspace = model.location(of: tab.id)?.workspace,
           let actions = actionsOfWorkspace(workspace) {
            actions.split(pane: paneID, axis: axis)
        } else {
            model.splitPane(paneID, axis: axis)
        }
    }

    // MARK: Controllers

    /// The session's controller, if it has one (every session in the model
    /// does, once the registry has seen it).
    func controller(for sessionID: SessionID) -> SessionController? {
        controllers[sessionID]
    }

    /// The controller of `sessionID`, made if the session is in the model
    /// and has none yet. A restored session whose runtime is not available
    /// (the persistent runtime, its host) is marked unavailable at once, a
    /// restored plain one (made by the fallback, or a plain ssh shell) as
    /// ended; automatic retries start paused while its workspace's window is
    /// closed (``setWindowOpen(_:for:)``).
    @discardableResult
    func ensureController(for sessionID: SessionID) -> SessionController? {
        if let existing = controllers[sessionID] { return existing }
        guard !finishedSessionIDs.contains(sessionID), let session = model.session(sessionID) else { return nil }
        let host = session.remoteHostID
        let remoteBackend = host.flatMap { remoteBackend(for: $0) }
        let backend: any PersistenceBackend = if host == nil {
            runtime.backend
        } else {
            remoteBackend ?? UnavailableBackend(reason: unreachableHostReason)
        }
        let model = model
        let settings = settings
        var makeOutputFilter = runtime.makeOutputFilter
        if host != nil { makeOutputFilter = { ZmxOutputFilter() } }
        let controller = SessionController(
            session: session,
            backend: backend,
            makeSurface: { [weak self] in
                // The pane's theme and the renderer as they are when the
                // surface is first needed.
                let factory = settings.surfaceFactory
                self?.surfaceRenderers[sessionID] = (factory.id, nil)
                return factory.makeSurface(appearance: settings.terminalAppearance(
                    for: NSApp.effectiveAppearance, paneThemeID: model.pane(showing: sessionID)?.themeID))
            },
            makeOutputFilter: makeOutputFilter)
        controller.delegate = self
        controllers[sessionID] = controller
        let restored = restoredSessionIDs.contains(sessionID)
        if host != nil {
            controller.reconnectSchedule = remote?.reconnectSchedule
            controller.retryPreflight = { [weak self, weak controller] in
                guard let self, let controller else { return .connect }
                return await self.retryPreflight(for: controller)
            }
            if remoteBackend == nil {
                controller.markUnavailable(reason: unreachableHostReason)
            } else if restored, !RestorePolicy.isPersistent(session) {
                // A plain ssh shell from an earlier run cannot be reattached.
                controller.markEnded()
            }
        } else if restored, policy.action(for: session, restored: true, live: nil) == .markUnavailable {
            controller.markUnavailable(reason: Self.unavailableReason)
        }
        if let place = model.place(of: sessionID), model.workspace(place.workspace)?.window?.isOpen == false {
            controller.pauseAutomaticReconnect()
        }
        return controller
    }

    /// Connects the session's controller if it has not been yet, as
    /// ``RestorePolicy`` says: its pane is on screen (``ContentViewController``
    /// calls this after layout, so it starts at the pane's real size). A
    /// restored session waiting in the launch queue jumps it.
    func startIfNeeded(_ sessionID: SessionID) {
        guard let controller = ensureController(for: sessionID) else { return }
        makeUnavailableIfHostRemoved(controller)
        // A hidden session whose retries stopped because its host needed the
        // user: its pane is on screen now, so it reconnects once by itself
        // (and may prompt there).
        if waitingForUser.contains(sessionID), controller.state.isDisconnected, !controller.isReconnecting,
           reconnectedWhenShown.insert(sessionID).inserted {
            Task { await controller.reconnect() }
            return
        }
        guard controller.state == .detached else { return }
        guard restoredSessionIDs.contains(sessionID) else {
            Task { await controller.start(.create) }
            return
        }
        // Shown again while its start waits for the listing: that start
        // stands (one counted start per session).
        guard startsInProgress.insert(sessionID).inserted else { return }
        startRequested.insert(sessionID)
        let lane = Self.lane(of: controller.session)
        launchQueue.started(sessionID, in: lane)
        if let host = controller.session.remoteHostID {
            let listing = hostListing(for: host)
            Task {
                let answer = await listing.value
                if controller.state == .detached {
                    // An unanswered listing (host down) or one that needs
                    // the user attaches anyway: the pane is on screen, so a
                    // sign-in can be answered there, and an unreachable
                    // host leaves it disconnected and retried, never ended.
                    if case .live(let live) = answer, !live.contains(sessionID) {
                        await markEnded([controller])
                    } else {
                        await controller.start(.attach)
                    }
                }
                startsInProgress.remove(sessionID)
                launchStartFinished(sessionID, lane: lane, controller: controller, kind: .attach)
            }
            return
        }
        let probe = liveProbe
        Task {
            let listed = await probe.value
            if controller.state == .detached {
                let alive = listed.map { $0.union(runtime.socketSessions()) }
                switch policy.action(for: controller.session, restored: true, live: alive) {
                case .create, .attach: await controller.start(.attach)
                case .markEnded: await markEnded([controller])
                case .markUnavailable: controller.markUnavailable(reason: Self.unavailableReason)
                }
            }
            startsInProgress.remove(sessionID)
            launchStartFinished(sessionID, lane: lane, controller: controller, kind: .attach)
        }
    }

    /// Shows restored sessions that are gone as ended, with the exit
    /// statuses their backend recorded (one call for all of them, a single
    /// command on a host); a clean exit then closes its pane
    /// (``closePaneIfEndedCleanly(_:exit:)``). Only controllers still
    /// detached are touched.
    func markEnded(_ controllers: [SessionController]) async {
        var byBackend: [ObjectIdentifier: (backend: any PersistenceBackend, controllers: [SessionController])] = [:]
        for controller in controllers {
            let backend = controller.activeBackend
            let key = ObjectIdentifier(backend as AnyObject)
            byBackend[key, default: (backend, [])].controllers.append(controller)
        }
        for group in byBackend.values {
            let statuses = await group.backend.recordedExitStatuses(of: Set(group.controllers.map(\.session.id)))
            for controller in group.controllers where controller.state == .detached {
                controller.markEnded(exitCode: statuses[controller.session.id])
            }
        }
    }

    // MARK: Persistence availability

    /// Retry on an unavailable pane: sets the persistent runtime up again
    /// and, if that works, brings every unavailable session up through it,
    /// as at launch: a session whose pane is on screen is attached at once;
    /// the others follow the launch pass once the new listing has answered
    /// (attached at their saved size, left until shown, or ended). Sessions
    /// created as plain PTY sessions meanwhile stay as they are.
    func retryPersistence() {
        // Remote sessions only need their host back.
        for controller in controllers.values where controller.state.isUnavailable {
            guard let host = controller.session.remoteHostID, let backend = remoteBackend(for: host) else { continue }
            controller.useBackend(backend, makeOutputFilter: { ZmxOutputFilter() })
            if paneViews.isShown(controller.session.id) {
                startIfNeeded(controller.session.id)
            } else if case .live? = hostListings[host] {
                Task { await runHostLaunchPass(host: host) }
            }
        }
        guard !runtime.isPersistent else { return }
        guard let setup = setUpPersistentRuntime?(), setup.isPersistent else {
            NSLog("Armadale: persistent sessions are still unavailable")
            return
        }
        runtime = setup
        policy = RestorePolicy(backendIsPersistent: true)
        persistenceWarning = nil
        localListed = nil
        localSockets = []
        liveProbe = Self.probe(setup.backend)
        let local = controllers.values.filter { $0.state.isUnavailable && $0.session.remoteHostID == nil }
        for controller in local {
            controller.useBackend(setup.backend, makeOutputFilter: setup.makeOutputFilter)
        }
        for controller in local where paneViews.isShown(controller.session.id) {
            startIfNeeded(controller.session.id)
        }
        // The rest when the new listing answers.
        awaitLocalProbe()
    }

    /// Whether `controller`'s session runs on a host that is no longer in
    /// the model (or remote sessions are off in this run).
    func isOnRemovedHost(_ controller: SessionController) -> Bool {
        guard let host = controller.session.remoteHostID else { return false }
        return remote == nil || model.host(host) == nil
    }

    /// A session on a removed host is never killed: before anything could
    /// reach its backend, the controller gets one that refuses everything
    /// (``observeHosts()`` does the same a turn later).
    func makeUnavailableIfHostRemoved(_ controller: SessionController) {
        guard isOnRemovedHost(controller), !(controller.activeBackend is UnavailableBackend) else { return }
        controller.detachAsUnavailable(reason: unreachableHostReason, backend: UnavailableBackend(reason: unreachableHostReason))
    }

    // MARK: Helpers

    /// The sessions whose program has reported its working directory (OSC
    /// 7) since this launch. Only their directory is shown in a pane header:
    /// `Session.workingDirectory` is otherwise the directory the session
    /// started in, which a shell sending no OSC 7 leaves behind at its first
    /// `cd` (DESIGN §8, "Pane cards"). Restored sessions count as unreported
    /// until they report again.
    var reportedDirectories: Set<SessionID> = []

    /// A renderer change applies to new surfaces at once and to existing
    /// ones at their next attach (DESIGN §5): live terminals are never
    /// rebuilt. A pane view is told (it tracks its renderer); a controller
    /// whose surface was made but is not shown gets the replacement
    /// directly; one whose surface was never made makes it with the new
    /// renderer anyway.
    private func observeRenderer() {
        let preferences = settings.preferences
        rendererTask = Task { [weak self] in
            var last: String?
            for await id in Observations({ preferences.rendererID }) {
                guard let self else { return }
                if last != nil, last != id {
                    let factory = self.settings.surfaces.factory(for: id)
                    for (sessionID, controller) in self.controllers {
                        if let pane = self.paneViews.view(for: sessionID) {
                            pane.useRenderer(factory)
                        } else if controller.hasSurface, let record = self.surfaceRenderers[sessionID] {
                            guard record.current != factory.id else {
                                // Back to the surface's own renderer: cancelled.
                                controller.replaceSurfaceOnNextAttach(nil)
                                self.surfaceRenderers[sessionID] = (record.current, nil)
                                continue
                            }
                            let settings = self.settings
                            let model = self.model
                            self.surfaceRenderers[sessionID] = (record.current, factory.id)
                            controller.replaceSurfaceOnNextAttach { [weak controller] in
                                factory.makeSurface(appearance: settings.terminalAppearance(
                                    for: NSApp.effectiveAppearance,
                                    paneThemeID: controller.flatMap { model.pane(showing: $0.session.id)?.themeID }))
                            }
                        }
                    }
                }
                last = id
            }
        }
    }

    /// Sessions can enter the model through any intent (a new session) and
    /// leave it through any intent (closing a tab, deleting a workspace):
    /// a new one gets its controller, a removed one is ended.
    private func observeSessions() {
        let model = model
        sessionsTask = Task { [weak self] in
            for await sessions in Observations({ model.sessions.map { ($0.id, $0.remoteHostID) } }) {
                guard let self else { return }
                let ids = Set(sessions.map(\.0))
                let removed = self.knownSessionIDs.subtracting(ids)
                self.knownSessionIDs = ids
                for id in removed { self.close(id) }
                for (id, _) in sessions { self.ensureController(for: id) }
            }
        }
    }
}
