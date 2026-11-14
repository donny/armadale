import AppKit
import ArmadaleCore
import ArmadaleSessions
import Observation
import os
import UserNotifications

/// Launch repairs and housekeeping counts, readable in `log show` (NSLog's
/// arguments are redacted as `<private>` there on macOS 27): subsystem
/// `com.tinylittleapps.armadale`, category `state`.
private let stateLog = Logger(subsystem: "com.tinylittleapps.armadale", category: "state")

/// Loads state, owns the ``AppModel``, opens one window per open workspace,
/// and persists every model change (debounced) and on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, QuitPreparing {
    let model: AppModel
    /// Preferences, themes and renderers.
    let settings: AppSettings
    private var settingsWindowController: SettingsWindowController?
    private var shortcutsWindowController: ShortcutsWindowController?
    private var acknowledgementsWindowController: AcknowledgementsWindowController?
    /// Session controllers for every pane shown so far.
    private let registry: SessionRegistry
    /// Which sessions need attention; the Dock badge and notifications.
    private let attention: AttentionCenter
    private let notifications: UserNotificationService
    private var focusObservers: [any NSObjectProtocol] = []
    private let stateURL: URL
    private let saver: StateSaver
    /// False when the state on disk must not be overwritten (written by a
    /// newer Armadale, or unreadable). The app then explains and quits.
    private let canSave: Bool
    /// A problem found while loading state, reported once the app is running.
    private var loadReport: LoadReport?
    private var windowControllers: [WorkspaceID: WorkspaceWindowController] = [:]
    private var persistenceTask: Task<Void, Never>?
    private var terminationSignalSource: (any DispatchSourceSignal)?
    private var isTerminating = false
    private var hasReportedSaveFailure = false
    /// Why sessions do not persist in this run, if the session runtime
    /// could not be set up; reported once the app is running.
    private var sessionSetupFailure: String?
    /// The persistent runtime, for log housekeeping.
    private var zmxRuntime: ZmxRuntime?
    /// `state.json` itself was read and does not say its sessions are
    /// incomplete: only then are the saved sessions a complete list of what
    /// Armadale created, and only then may the launch's orphan reclaim end
    /// sessions (``OrphanReclaimer``). Loading drops closed workspaces with
    /// no tab groups (``StateStore``); they hold no sessions, so the list
    /// stays complete.
    private let mayReclaimOrphans: Bool
    /// This process's lock on the state directory, held for its whole life
    /// (``StateLock``); `nil` when it could not be taken.
    private let stateLock: StateLock?
    /// What this launch sets up (``LaunchPlan``). A fatal launch (another
    /// process holds the state directory's lock, the state file is newer or
    /// unreadable) runs no helper, prepares no runtime and only explains and
    /// quits.
    private let plan: LaunchPlan

    /// Menu bar mode (docs/DESIGN.md section 8, "Quitting with running
    /// sessions"): the status item while the app stays running with its
    /// windows hidden and no Dock icon; `nil` otherwise.
    private var menuBarItem: MenuBarStatusItem?
    /// The quit came from SIGTERM (logout) or a launch that cannot go on:
    /// never ask, never stay.
    private var isForcedQuit = false
    /// End Sessions and Quit is running.
    private var isEndingSessions = false
    /// End Sessions and Quit has finished; its quit goes straight through.
    private var sessionsEnded = false

    /// What to tell the user about the state file at launch.
    struct LoadReport {
        var message: String
        var details: String
        /// The app cannot run safely and quits after the alert.
        var isFatal: Bool
        /// After a fatal alert: the process to bring forward (the copy that
        /// holds the state directory's lock), best effort.
        var bringForward: pid_t? = nil
    }

    override init() {
        // The lock first: loading deletes stale temporary files and may
        // quarantine an unreadable file, so it must never run against a
        // state directory another process owns (docs/DESIGN.md section 8).
        let directory = StateLocation.directory()
        let url = directory.appendingPathComponent(StateStore.fileName)
        let lockOutcome = StateLock.acquire(directory: directory)
        if case .acquired(let lock) = lockOutcome { self.stateLock = lock } else { self.stateLock = nil }
        if let line = InstanceLock.unavailableLogLine(for: lockOutcome) {
            stateLog.error("\(line, privacy: .public)")
        }
        let refusal = InstanceLock.refusal(for: lockOutcome, stateDirectory: directory)
        if let refusal {
            stateLog.error("\(refusal.logLine, privacy: .public)")
            FileHandle.standardError.write(Data((refusal.logLine + "\n").utf8))
        }

        let loaded = Self.launchState(refusal: refusal, stateURL: url)
        let state = loaded.state
        let plan = LaunchPlan(loaded)
        self.plan = plan
        self.stateURL = url
        self.mayReclaimOrphans = loaded.mayReclaimOrphans
        self.canSave = loaded.canSave
        self.loadReport = loaded.report
        let services = Self.launchServices(plan: plan, restoring: state.sessions)
        let sessions = services.sessions
        self.settings = services.settings
        self.model = AppModel(state: state, defaultWorkingDirectory: NSHomeDirectory())
        self.zmxRuntime = sessions.runtime
        self.sessionSetupFailure = sessions.failure
        self.registry = SessionRegistry(
            model: model,
            runtime: sessions.setup,
            restoredSessionIDs: Set(state.sessions.map(\.id)),
            settings: settings,
            remote: services.remote)
        let notifications = UserNotificationService()
        self.notifications = notifications
        self.attention = AttentionCenter(
            model: model, preferences: settings.preferences, notifications: notifications)
        self.saver = StateSaver(url: url)
        super.init()
        wireRegistry()
        wireAttention()
    }

    /// The state as loaded (and repaired), and what to make of it.
    struct LoadedState {
        var state: PersistedState
        var report: LoadReport?
        var canSave: Bool
        /// See ``AppDelegate/mayReclaimOrphans``.
        var mayReclaimOrphans: Bool
    }

    /// How much a launch sets up besides its windows (docs/DESIGN.md
    /// section 8, "A fatal launch"). A fatal launch, whatever made it fatal
    /// (``LoadReport/isFatal``: the lock is held by another process, the
    /// state file is newer or cannot be read), uses nothing in the state
    /// directory: no helper copies installed in `bin/` or other versions'
    /// copies removed, no persistent runtime prepared (so no session listed
    /// or probed, no log or exit file removed), no SSH support, no user
    /// themes read.
    struct LaunchPlan: Equatable {
        var usesStateDirectory: Bool

        init(_ loaded: LoadedState) {
            usesStateDirectory = loaded.report?.isFatal != true
        }
    }

    /// What a launch runs on: its settings, its local session backend and
    /// its SSH support.
    struct LaunchServices {
        var settings: AppSettings
        var sessions: SessionBackend
        var remote: RemoteSessionSupport?
    }

    /// The services `plan` allows. A fatal plan gets settings with no themes
    /// folder, the plain PTY backend and no SSH support, so nothing in the
    /// state directory is touched beyond the lock file's open (and, when the
    /// lock was taken, reading the state file): no helper installed or
    /// removed, no runtime prepared. A normal plan gets
    /// `sharedSettings()`, the persistent backend (``makeSessionBackend(for:environment:)``,
    /// falling back to plain PTY sessions) and SSH support. Internal, with
    /// `environment` and `sharedSettings` as parameters, for the tests.
    static func launchServices(
        plan: LaunchPlan,
        restoring sessions: [Session],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sharedSettings: () -> AppSettings = { AppSettings.shared }
    ) -> LaunchServices {
        guard plan.usesStateDirectory else {
            return LaunchServices(
                settings: AppSettings(preferences: .shared, themes: ThemeCatalog(directory: nil), surfaces: .standard),
                sessions: ephemeralBackend(failure: nil),
                remote: nil)
        }
        let backend = makeSessionBackend(for: sessions, environment: environment)
        return LaunchServices(
            settings: sharedSettings(),
            sessions: backend,
            remote: makeRemoteSupport(cttyExec: backend.cttyExec, environment: environment))
    }

    /// The persistent runtime the session registry asks for when it has none
    /// (a later attempt after the launch's failed): `nil` for a fatal plan
    /// (`makeBackend` is not called), with `ARMADALE_BACKEND=ephemeral`, or
    /// when the attempt gives no persistent backend. Internal, with
    /// `makeBackend` as a parameter, for the tests.
    static func persistentRuntimeForRegistry(
        plan: LaunchPlan,
        sessions: [Session],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        makeBackend: ([Session], [String: String]) -> SessionBackend = { AppDelegate.makeSessionBackend(for: $0, environment: $1) }
    ) -> SessionBackend? {
        guard plan.usesStateDirectory, environment["ARMADALE_BACKEND"] != "ephemeral" else { return nil }
        let backend = makeBackend(sessions, environment)
        return backend.setup.isPersistent ? backend : nil
    }

    /// The state this launch starts from: nothing when another process
    /// holds the lock (`refusal`), else `stateURL` loaded. Internal for the
    /// tests.
    static func launchState(refusal: InstanceLock.Refusal?, stateURL: URL) -> LoadedState {
        refusal.map(Self.lockedOut) ?? Self.loadState(from: stateURL)
    }

    /// Another process owns the state directory: nothing is loaded, nothing
    /// will be saved, and the alert explains before the app quits.
    private static func lockedOut(_ refusal: InstanceLock.Refusal) -> LoadedState {
        LoadedState(
            state: .empty,
            report: LoadReport(
                message: refusal.message, details: refusal.details, isFatal: true, bringForward: refusal.otherPID),
            canSave: false,
            mayReclaimOrphans: false)
    }

    /// Loads `url` with ``StateStore``, repairs it, keeps it as the launch
    /// backup when `state.json` itself was read, and marks the saved
    /// sessions incomplete when it was not (docs/DESIGN.md sections 3 and
    /// 4). Internal so the tests can run it against a temporary directory.
    static func loadState(from url: URL) -> LoadedState {
        var droppedWorkspaces = 0
        let result = StateStore.load(from: url) { droppedWorkspaces = $0 }
        var state = result.state ?? .empty
        var report: LoadReport?

        switch result {
        case .loaded:
            break
        case .unparseable(let fullProblem, let recovered, let backup, let quarantined):
            // The problem is a sentence of its own ("…correct format."): one
            // period less, so it can sit inside another.
            let problem = Self.withoutFinalPeriod(fullProblem)
            let kept = quarantined.isEmpty
                ? ""
                : quarantined.count == 1
                    ? " The unreadable file was kept at: \(quarantined[0].path)."
                    : " The unreadable files were kept at: \(quarantined.map(\.path).joined(separator: ", "))."
            let which = switch backup {
            case .launch: "the backup kept at an earlier launch (\(StateStore.launchBackupURL(for: url).lastPathComponent))"
            case .previousSave, nil: "the previous backup (\(StateStore.backupURL(for: url).lastPathComponent))"
            }
            report = recovered == nil
                ? LoadReport(
                    message: "Armadale could not read its saved layout",
                    details: "\(problem). Armadale started with a new workspace.\(kept)",
                    isFatal: false)
                : LoadReport(
                    message: "Armadale restored its layout from a backup",
                    details: "The saved layout could not be read (\(problem)), so \(which) was used.\(kept)",
                    isFatal: false)
        case .newerVersion(let version, let file):
            report = LoadReport(
                message: "This version of Armadale is too old for your saved layout",
                details: "\(file.path) uses layout format \(version), but this version of Armadale only "
                    + "understands format \(PersistedState.currentSchemaVersion). Your layout has not been changed. "
                    + "Please open a newer version of Armadale.",
                isFatal: true)
        case .ioError(let message, let file):
            report = LoadReport(
                message: "Armadale could not read its saved layout",
                details: "\(file.path) could not be read: \(Self.withoutFinalPeriod(message)). The file has not been changed. "
                    + "Check its permissions and open Armadale again.",
                isFatal: true)
        }

        if droppedWorkspaces > 0 {
            stateLog.notice(
                "Armadale: dropped \(droppedWorkspaces, privacy: .public) closed workspace(s) with no tab groups from the saved layout")
        }
        let (repaired, issues) = state.repaired()
        if !issues.isEmpty {
            stateLog.notice("Armadale: repaired saved layout: \(issues.joined(separator: "; "), privacy: .public)")
            state = repaired
        }
        // Orphan reclaim needs `state.json` itself, read as written and not
        // marked incomplete: with no file at all (first launch, or a file the
        // user removed), a damaged one or a backup, the references are
        // unknown, and running sessions must not be ended. Such a launch
        // marks its state incomplete, so a file saved before the live probe
        // answers holds the reclaim back at the next launch too.
        let readStateFile = result.readStateFile
        let mayReclaim = readStateFile && !state.sessionListIncomplete
        if readStateFile {
            // Before the first save: a copy this build could read, kept
            // however many saves follow (docs/DESIGN.md section 3).
            do {
                try StateStore.keepLaunchBackup(of: url)
            } catch {
                stateLog.error("Armadale: could not keep the launch backup: \(String(describing: error), privacy: .public)")
            }
        } else if result.allowsSaving, !state.sessionListIncomplete {
            state.sessionListIncomplete = true
            stateLog.notice("Armadale: the saved layout was not read as written; no running session will be ended until the running ones are recorded")
        }
        return LoadedState(
            state: state, report: report, canSave: result.allowsSaving, mayReclaimOrphans: mayReclaim)
    }

    /// `text` without one trailing period, for a sentence built around it.
    static func withoutFinalPeriod(_ text: String) -> String {
        text.hasSuffix(".") ? String(text.dropLast()) : text
    }

    private func wireRegistry() {
        registry.setUpPersistentRuntime = { [weak self] in
            guard let self,
                  let sessions = Self.persistentRuntimeForRegistry(plan: self.plan, sessions: self.model.sessions)
            else { return nil }
            self.zmxRuntime = sessions.runtime
            return sessions.setup
        }
        // Logs and exit files of sessions retired during this run go at
        // once, not only at the next launch.
        registry.onSessionRetired = { [weak self] id in
            self?.zmxRuntime?.removeLog(for: id)
            self?.zmxRuntime?.removeExitStatus(for: id)
        }
        registry.onRuntimeVersionRecorded = { [weak self] in
            self?.saveNow()
        }
        registry.actionsOfWorkspace = { [weak self] id in self?.windowControllers[id]?.actions }
    }

    /// The Dock badge follows the attention total; a revealed session's
    /// window comes forward.
    private func wireAttention() {
        registry.attention = attention
        attention.onBadgeChange = { label in
            NSApp.dockTile.badgeLabel = label
        }
        attention.showWorkspace = { [weak self] id in
            self?.showWorkspace(id)
        }
        // A badge set before macOS allowed one is not shown: set it again.
        notifications.onAuthorized = { [weak self] in
            guard let self else { return }
            NSApp.dockTile.badgeLabel = AttentionBadge.label(total: self.attention.total)
        }
    }

    /// Keeps ``AttentionCenter/isAppActive`` and
    /// ``AttentionCenter/keyWorkspaceID`` current, so a bell in the pane
    /// being looked at never sets attention, and looking at a pane clears it.
    private func observeFocus() {
        let center = NotificationCenter.default
        let update: @MainActor (Notification.Name, NSWindow?) -> Void = { [weak self] name, window in
            guard let self else { return }
            self.attention.isAppActive = NSApp.isActive
            if name == NSWindow.didResignKeyNotification {
                // Key moves to another window next (did-become-key follows);
                // nil until then. NSApp.keyWindow still covers a sheet of
                // the same window taking over.
                if let window, self.workspaceID(of: window) == self.attention.keyWorkspaceID {
                    self.attention.keyWorkspaceID = NSApp.keyWindow.flatMap { $0 === window ? nil : self.workspaceID(of: $0) }
                }
            } else {
                self.attention.keyWorkspaceID = NSApp.keyWindow.flatMap { self.workspaceID(of: $0) }
            }
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            focusObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                let name = notification.name
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated {
                    update(name, window)
                }
            })
        }
        attention.isAppActive = NSApp.isActive
        attention.keyWorkspaceID = NSApp.keyWindow.flatMap { workspaceID(of: $0) }
    }

    /// The workspace of `window`, or of the window it is a sheet of (a
    /// sheet, such as a close confirmation, takes key status from its
    /// window, whose focused pane is still the one being looked at).
    private func workspaceID(of window: NSWindow) -> WorkspaceID? {
        let owner = Self.sheetOwner(of: window)
        return windowControllers.first { $0.value.window === owner }?.key
    }

    /// The window a sheet (or a sheet of a sheet) is attached to; `window`
    /// itself if it is not a sheet.
    static func sheetOwner(of window: NSWindow) -> NSWindow {
        var owner = window
        while let parent = owner.sheetParent { owner = parent }
        return owner
    }

    /// Writes the state at once instead of after the debounce.
    private func saveNow() {
        guard canSave else { return }
        saver.schedule(model.persistedState)
        saver.flush()
    }

    // MARK: Sessions

    /// What runs the app's (local) sessions, and how it was set up.
    struct SessionBackend {
        var setup: SessionRuntimeSetup
        var runtime: ZmxRuntime?
        var failure: String?
        /// The installed `ctty-exec`, when the installer ran.
        var cttyExec: String?
    }

    /// SSH hosts (docs/DESIGN.md section 6): the system's OpenSSH, with its
    /// shared connections' sockets in the runtime directory (or the `/tmp`
    /// fallback when that is too long for them).
    private static func makeRemoteSupport(cttyExec: String?, environment: [String: String]) -> RemoteSessionSupport {
        let runtimeDirectory = ZmxRuntime.directory(forStateDirectory: StateLocation.directory(environment: environment))
        let transport = OpenSSHTransport(
            controlDirectory: OpenSSHTransport.controlDirectory(forRuntimeDirectory: runtimeDirectory),
            environment: OpenSSHTransport.clientEnvironment(environment))
        return RemoteSessionSupport(
            transport: transport,
            cttyExec: cttyExec,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    }

    /// Plain PTY sessions that end when the app quits; nothing on disk.
    private static func ephemeralBackend(failure: String?) -> SessionBackend {
        SessionBackend(
            setup: SessionRuntimeSetup(
                backend: EphemeralBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            runtime: nil, failure: failure)
    }

    /// The persistent zmx backend, with the helpers installed into the
    /// state directory's `bin/`. If that cannot be set up the app still
    /// works, with sessions that end when it quits. `ARMADALE_BACKEND=ephemeral`
    /// selects those deliberately (tests, debugging).
    static func makeSessionBackend(for sessions: [Session], environment: [String: String]) -> SessionBackend {
        let ephemeral = ephemeralBackend(failure:)
        if environment["ARMADALE_BACKEND"] == "ephemeral" {
            return ephemeral(nil)
        }
        do {
            let installer = try HelperInstaller.forApp(environment: environment)
            let installed = try installer.install(
                referencedZmxVersions: Set(sessions.compactMap(\.runtimeVersion)))
            let runtime = ZmxRuntime(stateDirectory: StateLocation.directory(environment: environment))
            try runtime.prepare()
            let backend = LocalZmxBackend(configuration: LocalZmxBackend.Configuration(
                runtime: runtime,
                executables: installed.zmxExecutables,
                cttyExec: installed.cttyExec.path,
                resolver: LaunchResolver()))
            let versions = Dictionary(
                sessions.compactMap { session in session.runtimeVersion.map { (session.id, $0) } },
                uniquingKeysWith: { _, last in last })
            Task { await backend.noteRuntimeVersions(versions) }
            return SessionBackend(
                setup: SessionRuntimeSetup(backend: backend, makeOutputFilter: { ZmxOutputFilter() }, isPersistent: true),
                runtime: runtime, failure: nil, cttyExec: installed.cttyExec.path)
        } catch {
            NSLog("Armadale: persistent sessions unavailable: %@", String(describing: error))
            return ephemeral(String(describing: error))
        }
    }

    /// Before any window shows: restored local sessions whose programs
    /// exited cleanly while Armadale was not running lose their panes
    /// (DESIGN §4, "Ended"), which may delete workspaces, every one
    /// included: it runs before ``AppModel/ensureWorkspacesToOpen()``, which
    /// then makes a fresh one. Their recorders' files say so; a file is
    /// only written once the program has ended, so this needs no listing
    /// and does not wait for the live probe.
    private func closePanesOfSessionsThatEndedCleanly() {
        guard let runtime = zmxRuntime else { return }
        let closed = registry.closeLocalSessionsThatEndedCleanly(recordedIn: runtime)
        if !closed.isEmpty {
            stateLog.notice(
                "Armadale: closed \(closed.count, privacy: .public) pane(s) whose sessions exited cleanly while Armadale was not running")
        }
    }

    /// Launch housekeeping once the live probe has answered: ends live
    /// sessions no saved session refers to, unless they are spared, or
    /// spares them all when the saved sessions are not known to be complete
    /// (``OrphanReclaimer``), records the spared ones and, when that
    /// changed the model, saves at once;
    /// then removes the runtime's log and exit files of sessions that are
    /// neither alive (listed and not just ended, or with a socket:
    /// ``ZmxRuntime/aliveForHousekeeping(listed:ended:sockets:)``) nor in
    /// the model. Without the runtime or the probe's answer nothing is
    /// recorded, and the state stays marked incomplete.
    private func collectGarbageAfterProbe() {
        guard let runtime = zmxRuntime else { return }
        let model = model
        let probe = registry.liveProbe
        let backend = registry.backend
        let mayReclaim = mayReclaimOrphans
        Task { [weak self] in
            guard let live = await probe.value else { return }
            // Sessions whose socket exists, listed or not (a stopped daemon
            // is not listed). Held back, they are spared too; on every
            // launch they count as running and keep their files.
            let sockets = runtime.sessionsWithSockets()
            let outcome = await OrphanReclaimer.reclaim(
                live: live, present: sockets, model: model, mayReclaim: mayReclaim, backend: backend)
            if outcome.changedModel { self?.saveNow() }
            let killed = outcome.ended
            let referenced = Set(model.sessions.map(\.id))
            stateLog.notice(
                "Armadale: launch reclaim \(mayReclaim ? "allowed" : "held back", privacy: .public): \(live.count, privacy: .public) live session(s), ended \(killed.count, privacy: .public) that no saved session refers to, \(outcome.spared.count, privacy: .public) recorded as spared (\(outcome.sparedRunning, privacy: .public) running)")
            let alive = ZmxRuntime.aliveForHousekeeping(listed: live, ended: Set(killed), sockets: sockets)
            let removed = runtime.collectGarbageLogs(live: alive, referenced: referenced)
            if !removed.isEmpty {
                stateLog.notice("Armadale: removed \(removed.count, privacy: .public) log file(s) of ended sessions")
            }
            let exitFiles = runtime.collectGarbageExitStatuses(live: alive, referenced: referenced)
            if !exitFiles.isEmpty {
                stateLog.notice("Armadale: removed \(exitFiles.count, privacy: .public) exit file(s) of ended sessions")
            }
        }
    }

    // MARK: NSApplicationDelegate

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launching finishes, so a click on a notification that
        // launched the app is delivered. Setting the delegate asks for no
        // permission; that happens when the first notification is posted.
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        handleTerminationSignal()
        observeFocus()

        if let report = loadReport, report.isFatal {
            // Do not open windows or save anything: the file on disk wins.
            // A copy started from a shell or a script comes up behind the
            // active app, where the cooperative `NSApp.activate()` is
            // refused; activating from the frontmost app is let through, as
            // for the quit alert (docs/DESIGN.md section 8, "Activation").
            AppActivation.bringForward()
            showAlert(message: report.message, details: report.details, style: .critical)
            InstanceLock.bringForward(pid: report.bringForward)
            isForcedQuit = true
            NSApp.terminate(nil)
            return
        }

        // Before any workspace is made: a fresh one has no restored sessions,
        // and one is made if these closes leave none.
        closePanesOfSessionsThatEndedCleanly()
        for id in model.ensureWorkspacesToOpen() {
            openWindow(for: id, restoringFullScreen: true)
        }

        saver.onWriteFailure = { [weak self] error, _ in
            self?.reportSaveFailure(error)
        }
        observeModelForPersistence()
        collectGarbageAfterProbe()
        NSApp.activate()

        if let report = loadReport {
            loadReport = nil
            showAlert(message: report.message, details: report.details, style: .warning)
        }
        if sessionSetupFailure != nil {
            // The details (logged at setup) name internals; the alert does not.
            sessionSetupFailure = nil
            showAlert(
                message: "Sessions won’t survive quitting Armadale",
                details: "Armadale could not set up the service that keeps sessions running. Your shells work, "
                    + "but they will end when Armadale quits, and sessions from earlier runs can’t be reattached. "
                    + "Reinstalling Armadale may fix this.",
                style: .warning)
        }
    }

    /// Before AppKit's `terminate(_:)` (``ArmadaleApplication``), which does
    /// nothing while a sheet is attached: every window's New Session or Edit
    /// Favorite sheet is taken down without closing its pane (it keeps the
    /// chooser, saved empty, and shows it again at the next launch); a sheet
    /// in Settings (New Favorite, Configure…) is ended too. A cancelled quit
    /// does not bring a sheet back: the pane's chooser is still there. The
    /// chooser itself is a view in the pane, never a sheet, and holds
    /// nothing up.
    func prepareForQuit() {
        Self.endSheetsForQuit(
            workspaceWindows: Array(windowControllers.values), settingsWindow: settingsWindowController?.window)
    }

    /// ``prepareForQuit()``'s work, separate so it can be tested: ends the
    /// New Session or Edit Favorite sheet of every workspace window, and
    /// any sheet on the Settings window (posting ``Notification/Name/armadaleWillQuit``
    /// first, so its SwiftUI state lets go of it).
    static func endSheetsForQuit(workspaceWindows: [WorkspaceWindowController], settingsWindow: NSWindow?) {
        for controller in workspaceWindows { controller.actions.endNewSessionSheet() }
        if let window = settingsWindow, let sheet = window.attachedSheet {
            NotificationCenter.default.post(name: .armadaleWillQuit, object: nil)
            if window.attachedSheet === sheet { window.endSheet(sheet) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A name typed into an inline rename field counts (on every quit,
        // SIGTERM's included: its handler calls `terminate`), before the
        // state is saved in `applicationWillTerminate`.
        for controller in windowControllers.values { controller.actions.rename.commit() }
        // Running sessions (docs/DESIGN.md section 8): ask, stay in the menu
        // bar, or end them first. Neither waits here: staying cancels the
        // quit, and ending them cancels it and quits again when done.
        let decision = QuitDecision.decide(
            running: registry.runningSessionCount(),
            preference: settings.preferences.quitWithRunningSessions,
            context: QuitDecision.Context(
                isForced: isForcedQuit || Self.isSystemQuit(NSAppleEventManager.shared().currentAppleEvent),
                isInMenuBar: menuBarItem != nil,
                isEndingSessions: isEndingSessions, sessionsEnded: sessionsEnded))
        switch decision {
        case .quitNow:
            break
        case .ask(let running):
            switch askAboutRunningSessions(running) {
            case .alertFirstButtonReturn: enterMenuBarMode()
            case .alertSecondButtonReturn: endSessionsAndQuit(nil)
            default: break
            }
            return .terminateCancel
        case .keepInMenuBar:
            enterMenuBarMode()
            return .terminateCancel
        case .endSessions:
            endSessionsAndQuit(nil)
            return .terminateCancel
        case .cancel:
            return .terminateCancel
        }
        // Windows closing because the app quits must stay "open" for next launch.
        isTerminating = true
        // Quitting never ends sessions: hang up every client now (SIGHUP and
        // closing its terminal are synchronous; the session daemons keep
        // running) and quit at once. Never `.terminateLater`: a quit that
        // waits on async work deadlocks when it starts inside a main-queue
        // block, as SIGTERM's handler does (AppKit then runs a nested run
        // loop the main actor cannot run in), which would block logout.
        registry.detachAllNow()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistenceTask?.cancel()
        guard canSave else { return }
        for controller in windowControllers.values {
            model.updateWindowState(controller.captureWindowState(isOpen: true), for: controller.workspaceID)
        }
        saver.schedule(model.persistedState)
        saver.flush()
        if let error = saver.lastError {
            NSLog("Armadale: failed to save state to %@: %@", stateURL.path, String(describing: error))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A reopen (Dock click, `open -a`) does nothing while a fatal launch
    /// report is pending: the app shows its alert and quits, and must not
    /// open a window on the state it refused to load.
    static func ignoresReopen(pendingReport: LoadReport?) -> Bool {
        pendingReport?.isFatal == true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A fatal launch (another copy owns the state directory, a newer
        // or unreadable state file) is quitting under its alert: open nothing.
        if Self.ignoresReopen(pendingReport: loadReport) { return false }
        // `open -a`, Finder, or a second launch while in menu bar mode.
        if menuBarItem != nil {
            openFromMenuBar(nil)
            return true
        }
        if !flag {
            if let first = model.workspaces.first {
                openWindow(for: first.id)
            } else {
                newWindow(nil)
            }
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Actions

    /// File › New Workspace (⌘N): a new workspace in its own window,
    /// cascaded from the current one.
    @objc func newWindow(_ sender: Any?) {
        let reference = NSApp.keyWindow ?? NSApp.mainWindow
        let id = model.newWorkspace()
        openWindow(for: id, cascadingFrom: reference)
    }

    /// Armadale › Settings… (⌘,): the one Settings window.
    @objc func showSettings(_ sender: Any?) {
        showSettings(tab: nil)
    }

    /// Settings, on `tab` (the New Session dialog's Add Host… opens Hosts),
    /// else on the tab shown last.
    func showSettings(tab: SettingsWindowController.Tab?) {
        if settingsWindowController == nil {
            let registry = registry
            settingsWindowController = SettingsWindowController(
                model: model, settings: settings,
                hostTools: HostTools(
                    testConnection: { try await registry.testConnection(to: $0) },
                    deploy: { try await registry.deployHelper(to: $0) }))
            settingsWindowController?.onClose = { [weak self] in
                self?.auxiliaryWindowDidClose()
            }
        }
        NSApp.unhide(nil) // hidden after Settings closed in menu bar mode
        settingsWindowController?.show(tab)
        AppActivation.bringForward()
    }

    /// Help › Keyboard Shortcuts: the one window with the shortcut table,
    /// generated from the main menu (``ShortcutTable``).
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        if shortcutsWindowController == nil {
            let menu = NSApp.mainMenu ?? MainMenu.make(installsSpecialMenus: false)
            shortcutsWindowController = ShortcutsWindowController(rows: ShortcutTable.rows(from: menu))
            shortcutsWindowController?.onClose = { [weak self] in
                self?.auxiliaryWindowDidClose()
            }
        }
        NSApp.unhide(nil) // hidden after a window closed in menu bar mode
        shortcutsWindowController?.show()
        AppActivation.bringForward()
    }

    /// Help › Acknowledgements: the one window with the third-party
    /// notices bundled as `Acknowledgements.txt`.
    @objc func showAcknowledgements(_ sender: Any?) {
        let controller = AcknowledgementsWindowController.reusing(acknowledgementsWindowController)
        controller.onClose = { [weak self] in
            self?.auxiliaryWindowDidClose()
        }
        acknowledgementsWindowController = controller
        NSApp.unhide(nil) // hidden after a window closed in menu bar mode
        controller.show()
        AppActivation.bringForward()
    }

    /// View › Bigger (⌘=): every pane; stored like the Settings font size.
    @objc func increaseFontSize(_ sender: Any?) {
        settings.preferences.increaseFontSize()
    }

    /// View › Smaller (⌘-).
    @objc func decreaseFontSize(_ sender: Any?) {
        settings.preferences.decreaseFontSize()
    }

    /// View › Actual Size (⌘0).
    @objc func resetFontSize(_ sender: Any?) {
        settings.preferences.resetFontSize()
    }

    /// Window › Next Pane Needing Attention (⌃⌘A): the next session
    /// needing attention after the key window's focused pane, in sidebar
    /// order across every window; its window comes forward, its tab group
    /// and tab are selected and its pane focused, which clears it.
    @objc func showNextPaneNeedingAttention(_ sender: Any?) {
        attention.revealNext()
    }

    /// Window › Clear All Attention.
    @objc func clearAllAttention(_ sender: Any?) {
        attention.clearAll()
    }

    /// A click on a notification: the session's pane, if it still exists;
    /// otherwise just the app. Either leaves menu bar mode (revealing a
    /// pane opens its window, which does).
    fileprivate func openNotification(for session: SessionID?) {
        if let session, attention.reveal(session) { return }
        if menuBarItem != nil {
            openFromMenuBar(nil)
        } else {
            NSApp.activate()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let preferences = settings.preferences
        switch menuItem.action {
        case #selector(showNextPaneNeedingAttention(_:)): return attention.nextSession != nil
        case #selector(clearAllAttention(_:)): return attention.total > 0
        case #selector(increaseFontSize(_:)): return preferences.canIncreaseFontSize
        case #selector(decreaseFontSize(_:)): return preferences.canDecreaseFontSize
        case #selector(resetFontSize(_:)): return preferences.fontSize != Preferences.defaultFontSize
        default: return true
        }
    }

    // MARK: Windows

    /// Brings a workspace's window to front, opening it if it is closed
    /// (the sidebar's workspace rows).
    func showWorkspace(_ id: WorkspaceID) {
        guard model.workspace(id) != nil else { return }
        openWindow(for: id, cascadingFrom: NSApp.keyWindow)
        windowControllers[id]?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Shows the workspace's window, creating it (and, if the workspace has
    /// no tab groups left, a fresh "Main" group) as needed. A new window
    /// without a saved frame is cascaded from `reference`.
    private func openWindow(
        for id: WorkspaceID, cascadingFrom reference: NSWindow? = nil, restoringFullScreen: Bool = false
    ) {
        // Showing a workspace window always leaves menu bar mode (a
        // notification click, ⌘N or ⌃⌘A from the Settings window there).
        leaveMenuBarMode()
        if let existing = windowControllers[id] {
            existing.showWindow(nil)
            return
        }
        if let workspace = model.workspace(id), workspace.window?.isOpen != true || workspace.tabGroups.isEmpty {
            model.reopenWorkspace(id)
        }
        // A new workspace's empty pane (⌘N, the fresh one at launch), a
        // reopened one's fresh group and an empty pane restored from the
        // state file show the New Session chooser. The dialog's directory
        // comes from the window this one was made from.
        let near = windowControllers.first { $0.value.window === reference }?.value
        let controller = WorkspaceWindowController(model: model, workspaceID: id, registry: registry)
        controller.actions.lastFocusedSessionID = near.flatMap {
            model.focusedSessionID(in: $0.workspaceID) ?? $0.actions.lastFocusedSessionID
        }
        controller.actions.showWorkspace = { [weak self] id in self?.showWorkspace(id) }
        controller.actions.actionsOfWorkspace = { [weak self] id in self?.windowControllers[id]?.actions }
        controller.actions.showSettings = { [weak self] tab in self?.showSettings(tab: tab) }
        controller.fullScreenSteps = fullScreenSteps
        // Cascade from the current window instead of opening exactly on top.
        if !controller.hadSavedFrame, let reference, let window = controller.window, window !== reference {
            window.cascadeTopLeft(from: reference.cascadeTopLeft(from: .zero))
        }
        controller.onWindowStateChange = { [weak self] controller, state in
            guard let self, !self.isTerminating else { return }
            // A controller whose window has closed (or was replaced) has
            // nothing more to say about the workspace.
            guard self.windowControllers[controller.workspaceID] === controller else { return }
            if !state.isOpen {
                self.windowControllers[controller.workspaceID] = nil
                // Nobody sees its panes: no retrying lost connections.
                self.registry.setWindowOpen(false, for: controller.workspaceID)
            }
            // A deleted workspace has nothing left to record.
            if self.model.workspace(controller.workspaceID) != nil {
                self.model.updateWindowState(state, for: controller.workspaceID)
            }
        }
        windowControllers[id] = controller
        // Decided before showing: ordering the window in reports a move,
        // which must not record the flag as false meanwhile.
        let wasFullScreen = controller.savedAsFullScreen
        if wasFullScreen, restoringFullScreen { queueFullScreen(id) }
        controller.showWindow(nil)
        registry.setWindowOpen(true, for: id)
        if wasFullScreen, !restoringFullScreen {
            // Reopened later (the sidebar): a normal window, recorded so.
            model.updateWindowState(controller.captureWindowState(isOpen: true), for: id)
        }
    }

    /// Every full-screen toggle, one at a time (``FullScreenSerializer``):
    /// windows entering full screen at launch or after menu bar mode,
    /// leaving it for menu bar mode, and leaving it before closing.
    private let fullScreenSteps = FullScreenSerializer()

    /// Queues a workspace's window to enter full screen (opened at launch,
    /// or shown again after menu bar mode); its reported flag stays true
    /// until it does. The windows that were in full screen go back one
    /// after another (each becomes its own Space; a second toggle while one
    /// animates can be refused). Each window was shown at its normal frame
    /// first, and its visible sessions started at that size; full screen
    /// then resizes them once. An entry whose turn comes in menu bar mode,
    /// or for a workspace deleted meanwhile (its last pane's session exited
    /// cleanly, say), is skipped.
    private func queueFullScreen(_ id: WorkspaceID) {
        windowControllers[id]?.markFullScreenEntryPending()
        fullScreenSteps.enqueue { [weak self] done in
            guard let self, self.menuBarItem == nil, self.model.workspace(id) != nil,
                  let controller = self.windowControllers[id], !controller.isClosePending
            else { return done() }
            controller.enterFullScreen(then: done)
        }
    }

    // MARK: Alerts

    private func showAlert(message: String, details: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = details
        alert.runModal()
    }

    /// Tells the user once per launch that saving is failing; the saver
    /// keeps retrying in the background.
    private func reportSaveFailure(_ error: any Error) {
        NSLog("Armadale: failed to save state to %@: %@", stateURL.path, String(describing: error))
        guard !hasReportedSaveFailure else { return }
        hasReportedSaveFailure = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Armadale can't save your layout"
        alert.informativeText = "Writing \(stateURL.path) failed: \(error.localizedDescription). "
            + "Armadale will keep retrying. Your sessions are not affected."
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: Menu bar mode

    /// A quit Apple event that carries a reason (`kAEQuitReason`: log out,
    /// restart, shut down, quit all) comes from the system, not from the
    /// user: like SIGTERM it must not ask (that would hold up logout) or
    /// stay. ⌘Q has no Apple event; the Dock's Quit and AppleScript's
    /// `quit` send one without a reason.
    static func isSystemQuit(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication)
        else { return false }
        let keyword = AEKeyword(kAEQuitReason)
        return event.attributeDescriptor(forKeyword: keyword) != nil || event.paramDescriptor(forKeyword: keyword) != nil
    }

    /// The quit question (docs/DESIGN.md section 8). Returns the button:
    /// first Keep Running in Menu Bar, second End Sessions and Quit.
    private func askAboutRunningSessions(_ running: Int) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = MenuBarText.alertMessage(running: running)
        alert.informativeText = MenuBarText.alertInformative(running: running)
        alert.addButton(withTitle: MenuBarText.keepButton)
        let end = alert.addButton(withTitle: MenuBarText.endButton)
        end.hasDestructiveAction = true
        alert.addButton(withTitle: MenuBarText.cancelButton)
        // A quit from the Dock's menu, or from another app, comes while
        // Armadale is in the background: the alert needs it in front, and
        // on macOS 27 the plain `NSApp.activate()` is refused there (the
        // alert opened behind the active app's window, checked live).
        AppActivation.bringForward()
        return alert.runModal()
    }

    /// Hides every window (ordered out, not closed: the workspaces stay
    /// open for the next launch and their panes stay attached), leaves the
    /// Dock (accessory activation policy) and shows the status item.
    private func enterMenuBarMode() {
        guard menuBarItem == nil else { return }
        // Entries still queued are skipped in their turn (menu bar mode).
        for controller in windowControllers.values {
            controller.hideForMenuBarMode()
        }
        settingsWindowController?.window?.orderOut(nil)
        shortcutsWindowController?.window?.orderOut(nil)
        acknowledgementsWindowController?.window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        let registry = registry
        menuBarItem = MenuBarStatusItem(
            target: self,
            actions: MenuBarStatusItem.Actions(
                open: #selector(openFromMenuBar(_:)),
                settings: #selector(showSettings(_:)),
                quitKeepingSessions: #selector(quitKeepingSessions(_:)),
                endSessionsAndQuit: #selector(endSessionsAndQuit(_:))),
            attention: attention,
            runningCount: { registry.runningSessionCount() },
            sessionsSurviveQuit: { registry.sessionsSurviveQuit })
    }

    /// Back to a regular app: Dock icon (with the attention badge, which
    /// kept counting meanwhile) and every hidden workspace window. Does
    /// nothing outside menu bar mode.
    private func leaveMenuBarMode() {
        guard let item = menuBarItem else { return }
        item.remove()
        menuBarItem = nil
        NSApp.unhide(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.dockTile.badgeLabel = AttentionBadge.label(total: attention.total)
        // A window whose workspace is gone is closing, not shown again.
        for (id, controller) in windowControllers where model.workspace(id) != nil && !controller.isClosePending {
            controller.showWindow(nil)
            if controller.didShowAfterMenuBarMode() { queueFullScreen(id) }
        }
    }

    /// Closing Settings, Keyboard Shortcuts or Acknowledgements (⌘W) in
    /// menu bar mode would leave an active accessory app with no window,
    /// taking keystrokes nowhere: once the close is done, and no such
    /// window is left on screen, the app hides, which activates the app
    /// that was active before (`NSApp.deactivate()` does not, for an accessory app: it
    /// stayed the frontmost application). The status item stays; every
    /// way back unhides (``leaveMenuBarMode()``, ``showSettings(tab:)``,
    /// ``showKeyboardShortcuts(_:)``, ``showAcknowledgements(_:)``).
    private func auxiliaryWindowDidClose() {
        guard menuBarItem != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.menuBarItem != nil,
                  self.settingsWindowController?.window?.isVisible != true,
                  self.shortcutsWindowController?.window?.isVisible != true,
                  self.acknowledgementsWindowController?.window?.isVisible != true
            else { return }
            NSApp.hide(nil)
        }
    }

    /// Status menu › Open Armadale (and every reopen in menu bar mode).
    @objc func openFromMenuBar(_ sender: Any?) {
        leaveMenuBarMode()
        if windowControllers.isEmpty {
            if let first = model.workspaces.first {
                openWindow(for: first.id)
            } else {
                newWindow(nil)
            }
        }
        AppActivation.bringForward(allWindows: true)
    }

    /// Status menu › Quit, Keep Sessions Running: a plain quit from
    /// accessory mode (``QuitDecision/Context/isInMenuBar``). Clients hang
    /// up, sessions keep running, and with no Dock tile the Dock shows
    /// nothing afterwards.
    @objc func quitKeepingSessions(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    /// End Sessions and Quit (the alert, the status menu, or the "End
    /// them" preference): ends every session, then quits. The quit that
    /// led here was cancelled; this one goes straight through. Never
    /// `.terminateLater` (see ``applicationShouldTerminate(_:)``).
    /// Sessions that started while the first pass ran (a tab opened, a
    /// pane respawned) get one more pass; then it quits regardless. In
    /// menu bar mode the status menu shows "Ending sessions…" meanwhile.
    @objc func endSessionsAndQuit(_ sender: Any?) {
        guard !isEndingSessions else { return }
        isEndingSessions = true
        menuBarItem?.showEnding()
        Task { [weak self, registry] in
            let ended = await registry.endAllSessions()
            let appeared = registry.sessionsRunning(after: ended)
            if !appeared.isEmpty {
                NSLog("Armadale: %d session(s) started while ending sessions; ending them too", appeared.count)
                await registry.endAllSessions(only: appeared)
            }
            guard let self else { return }
            self.isEndingSessions = false
            self.sessionsEnded = true
            NSApp.terminate(nil)
        }
    }

    // MARK: Persistence

    /// Turns SIGTERM (`kill`, `pkill`, launchd at logout) into a normal quit
    /// so state is saved synchronously, as on ⌘Q.
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            // From the run loop rather than inside this dispatch block, so
            // the quit runs like ⌘Q's; in the common and modal-panel modes,
            // so an app-modal alert (a launch warning, a save failure) does
            // not hold it up until someone clicks OK. Logout must not wait.
            RunLoop.main.perform(inModes: [.common, .modalPanel]) { [weak self] in
                MainActor.assumeIsolated {
                    self?.isForcedQuit = true
                    NSApp.terminate(nil)
                }
            }
        }
        source.resume()
        terminationSignalSource = source
    }

    /// Schedules a debounced save whenever the model changes.
    private func observeModelForPersistence() {
        guard canSave else { return }
        let model = model
        let saver = saver
        persistenceTask = Task {
            for await _ in Observations({ model.changeCount }) {
                saver.schedule(model.persistedState)
            }
        }
    }
}

// MARK: - Notifications

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Clicking a notification brings its session forward (routed by the
    /// session ID in `userInfo`; a session that no longer exists only
    /// activates the app).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let session = AttentionNotification.sessionID(fromUserInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            self.openNotification(for: session)
        }
        completionHandler()
    }

    /// Shown while Armadale is active too (the pane is elsewhere, another
    /// tab or window, which is why it was posted), unless the user is
    /// looking at that session by the time it would appear.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let session = AttentionNotification.sessionID(fromUserInfo: notification.request.content.userInfo)
        let present = await MainActor.run { self.attention.shouldPresent(session) }
        return present ? [.banner, .list, .sound] : []
    }
}
