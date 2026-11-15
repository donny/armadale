import AppKit
import ArmadaleCore
import ArmadaleSessions
import Observation
import os
import UserNotifications

/// Launch repairs and housekeeping counts, readable in `log show` (NSLog's
/// arguments are redacted as `<private>` there on macOS 27): subsystem
/// `com.tinylittleapps.armadale`, category `state`.
let stateLog = Logger(subsystem: "com.tinylittleapps.armadale", category: "state")

/// Loads state, owns the ``AppModel``, opens one window per open workspace,
/// and persists every model change (debounced) and on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, QuitPreparing {
    let model: AppModel
    /// Preferences, themes and renderers.
    let settings: AppSettings
    var settingsWindowController: SettingsWindowController?
    var shortcutsWindowController: ShortcutsWindowController?
    var acknowledgementsWindowController: AcknowledgementsWindowController?
    /// A session controller for every session in the model, and the pane
    /// views of those shown so far.
    let registry: SessionRegistry
    /// Which sessions need attention; the Dock badge and notifications.
    let attention: AttentionCenter
    let notifications: UserNotificationService
    var focusObservers: [any NSObjectProtocol] = []
    let stateURL: URL
    let saver: StateSaver
    /// False when the state on disk must not be overwritten (written by a
    /// newer Armadale, or unreadable). The app then explains and quits.
    let canSave: Bool
    /// A problem found while loading state, reported once the app is running.
    private var loadReport: LoadReport?
    var windowControllers: [WorkspaceID: WorkspaceWindowController] = [:]
    var persistenceTask: Task<Void, Never>?
    var terminationSignalSource: (any DispatchSourceSignal)?
    var isTerminating = false
    var hasReportedSaveFailure = false
    /// Why sessions do not persist in this run, if the session runtime
    /// could not be set up; reported once the app is running.
    private var sessionSetupFailure: String?
    /// The persistent runtime, for log housekeeping.
    var zmxRuntime: ZmxRuntime?
    /// `state.json` itself was read and does not say its sessions are
    /// incomplete: only then are the saved sessions a complete list of what
    /// Armadale created, and only then may the launch's orphan reclaim end
    /// sessions (``OrphanReclaimer``). Loading drops closed workspaces with
    /// no tab groups (``StateStore``); they hold no sessions, so the list
    /// stays complete.
    let mayReclaimOrphans: Bool
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
    var menuBarItem: MenuBarStatusItem?
    /// The quit came from SIGTERM (logout) or a launch that cannot go on:
    /// never ask, never stay.
    var isForcedQuit = false
    /// End Sessions and Quit is running.
    var isEndingSessions = false
    /// End Sessions and Quit has finished; its quit goes straight through.
    var sessionsEnded = false

    /// `last-quit.json` (docs/DESIGN.md section 8, "Background App
    /// Activity"); `nil` for a launch that does not use its state directory.
    let lastQuitStore: LastQuitStore?
    /// When macOS was last found to have ended sessions after a quit, as
    /// the record says and the launch check updates it: while set, a quit
    /// from menu bar mode that leaves local sessions asks first.
    var lossSeenAt: Date?
    /// The quit under way, taken when ``applicationShouldTerminate(_:)``
    /// lets it go through and written by ``applicationWillTerminate(_:)``.
    var quitToRecord: LastQuitRecord.Quit?

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
        self.lastQuitStore = Self.lastQuitStore(plan: plan, canSave: loaded.canSave, stateDirectory: directory)
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

        // Whether macOS ended the sessions the last quit left running
        // (DESIGN §8, "Background App Activity"): files only, read before
        // any pane closes and retires a session's log. Told after the other
        // launch alerts; a check not due yet runs later by itself.
        let endedAfterLastQuit = startLastQuitCheck()
        // Before any workspace is made: a fresh one has no restored sessions,
        // and one is made if these closes leave none.
        closePanesOfSessionsThatEndedCleanly()
        for id in model.ensureWorkspacesToOpen() {
            openWindow(for: id, restoringFullScreen: true)
        }
        // After the windows: their panes on screen start at their laid-out
        // size; every other restored session follows (DESIGN §4).
        registry.startLaunchPass()

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
        if let ended = endedAfterLastQuit {
            showSessionsEndedAfterQuit(ended, late: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistenceTask?.cancel()
        guard canSave else { return }
        // Sizes applied in the last half second, not yet in the model.
        registry.flushGridSizes()
        for controller in windowControllers.values {
            model.updateWindowState(controller.captureWindowState(isOpen: true), for: controller.workspaceID)
        }
        saver.schedule(model.persistedState)
        saver.flush()
        if let error = saver.lastError {
            NSLog("Armadale: failed to save state to %@: %@", stateURL.path, String(describing: error))
        }
        writeLastQuitRecord()
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

    /// Every full-screen toggle, one at a time (``FullScreenSerializer``):
    /// windows entering full screen at launch or after menu bar mode,
    /// leaving it for menu bar mode, and leaving it before closing.
    let fullScreenSteps = FullScreenSerializer()

    // MARK: Alerts

    private func showAlert(message: String, details: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = details
        alert.runModal()
    }
}
