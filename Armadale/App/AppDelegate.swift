import AppKit
import ArmadaleCore
import ArmadaleSessions
import Observation

/// Loads state, owns the ``AppModel``, opens one window per open workspace,
/// and persists every model change (debounced) and on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    let model: AppModel
    /// Preferences, themes and renderers.
    let settings: AppSettings
    private var settingsWindowController: SettingsWindowController?
    private var preferencesTask: Task<Void, Never>?
    private var profilesTask: Task<Void, Never>?
    /// Session controllers for every pane shown so far.
    private let registry: SessionRegistry
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
    /// The state file loaded as written (or there was none yet). Only then
    /// are the saved sessions a complete list of what Armadale created.
    private let stateLoadedCleanly: Bool

    /// What to tell the user about the state file at launch.
    private struct LoadReport {
        var message: String
        var details: String
        /// The app cannot run safely and quits after the alert.
        var isFatal: Bool
    }

    override init() {
        let url = StateLocation.stateFile()
        let result = StateStore.load(from: url)
        var state = result.state ?? .empty
        var report: LoadReport?

        switch result {
        case .loaded:
            break
        case .unparseable(let problem, let recovered, let quarantined):
            let kept = quarantined.isEmpty
                ? ""
                : " The unreadable file was kept at: \(quarantined.map(\.path).joined(separator: ", "))."
            report = recovered == nil
                ? LoadReport(
                    message: "Armadale could not read its saved layout",
                    details: "\(problem). Armadale started with a new workspace.\(kept)",
                    isFatal: false)
                : LoadReport(
                    message: "Armadale restored its layout from a backup",
                    details: "The saved layout could not be read (\(problem)), so the previous backup was used.\(kept)",
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
                details: "\(file.path) could not be read: \(message). The file has not been changed. "
                    + "Check its permissions and open Armadale again.",
                isFatal: true)
        }

        let (repaired, issues) = state.repaired()
        if !issues.isEmpty {
            NSLog("Armadale: repaired saved layout: %@", issues.joined(separator: "; "))
            state = repaired
        }

        self.stateURL = url
        // Orphan reclaim needs a state file that existed and loaded: with no
        // file at all (first launch, or a file the user removed) the references
        // are unknown, and running sessions must not be killed.
        if case .loaded(_, isFirstLaunch: false) = result { self.stateLoadedCleanly = true } else { self.stateLoadedCleanly = false }
        self.canSave = result.allowsSaving
        self.loadReport = report
        self.settings = AppSettings.shared
        self.model = AppModel(state: state, defaultWorkingDirectory: settings.preferences.resolvedWorkingDirectory())
        model.defaultProfileID = settings.preferences.defaultProfileID
        let sessions = Self.makeSessionBackend(for: state.sessions)
        self.zmxRuntime = sessions.runtime
        self.sessionSetupFailure = sessions.failure
        self.registry = SessionRegistry(
            model: model,
            runtime: sessions.setup,
            restoredSessionIDs: Set(state.sessions.map(\.id)),
            settings: settings)
        self.saver = StateSaver(url: url)
        super.init()
        wireRegistry()
        followGeneralPreferences()
    }

    /// The default profile and directory live in preferences; the model
    /// uses them for every new tab, tab group and workspace. A deleted
    /// default profile resets the preference to the shell.
    private func followGeneralPreferences() {
        let preferences = settings.preferences
        let model = model
        profilesTask = Task {
            for await ids in Observations({ model.profiles.map(\.id) }) {
                preferences.reconcileDefaultProfile(with: ids)
            }
        }
        preferencesTask = Task {
            for await (profile, _) in Observations({ (preferences.defaultProfileID, preferences.defaultWorkingDirectory) }) {
                model.defaultProfileID = profile
                model.defaultWorkingDirectory = preferences.resolvedWorkingDirectory()
            }
        }
    }

    private func wireRegistry() {
        registry.setUpPersistentRuntime = { [weak self] in
            guard let self, ProcessInfo.processInfo.environment["ARMADALE_BACKEND"] != "ephemeral" else { return nil }
            let sessions = Self.makeSessionBackend(for: self.model.sessions)
            guard sessions.setup.isPersistent else { return nil }
            self.zmxRuntime = sessions.runtime
            return sessions.setup
        }
        // Logs of sessions retired during this run go at once, not only at
        // the next launch.
        registry.onSessionRetired = { [weak self] id in
            self?.zmxRuntime?.removeLog(for: id)
        }
        registry.onRuntimeVersionRecorded = { [weak self] in
            self?.saveNow()
        }
    }

    /// Writes the state at once instead of after the debounce.
    private func saveNow() {
        guard canSave else { return }
        saver.schedule(model.persistedState)
        saver.flush()
    }

    // MARK: Sessions

    /// What runs the app's (local) sessions, and how it was set up.
    private struct SessionBackend {
        var setup: SessionRuntimeSetup
        var runtime: ZmxRuntime?
        var failure: String?
    }

    /// The persistent zmx backend, with the helpers installed into the
    /// state directory's `bin/`. If that cannot be set up the app still
    /// works, with sessions that end when it quits. `ARMADALE_BACKEND=ephemeral`
    /// selects those deliberately (tests, debugging).
    private static func makeSessionBackend(for sessions: [Session]) -> SessionBackend {
        let environment = ProcessInfo.processInfo.environment
        let ephemeral = { (failure: String?) in
            SessionBackend(
                setup: SessionRuntimeSetup(
                    backend: EphemeralBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
                runtime: nil, failure: failure)
        }
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
                runtime: runtime, failure: nil)
        } catch {
            NSLog("Armadale: persistent sessions unavailable: %@", String(describing: error))
            return ephemeral(String(describing: error))
        }
    }

    /// Launch housekeeping once the live probe has answered: ends live
    /// sessions no saved session refers to (only when the state loaded
    /// cleanly; see ``OrphanReclaimer``), then removes the runtime's log files
    /// of sessions that are neither alive nor in the model.
    private func collectGarbageAfterProbe() {
        guard let runtime = zmxRuntime else { return }
        let model = model
        let probe = registry.liveProbe
        let backend = registry.backend
        let stateLoadedCleanly = stateLoadedCleanly
        Task {
            guard let live = await probe.value else { return }
            let referenced = Set(model.sessions.map(\.id))
            let killed = await OrphanReclaimer.reclaim(
                live: live, referenced: referenced, stateLoadedCleanly: stateLoadedCleanly, backend: backend)
            if !killed.isEmpty {
                NSLog("Armadale: ended %d session(s) that no pane refers to any more", killed.count)
            }
            let removed = runtime.collectGarbageLogs(live: live.subtracting(killed), referenced: referenced)
            if !removed.isEmpty {
                NSLog("Armadale: removed %d log file(s) of ended sessions", removed.count)
            }
        }
    }

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(profileMenuDelegate: self)
        handleTerminationSignal()

        if let report = loadReport, report.isFatal {
            // Do not open windows or save anything: the file on disk wins.
            NSApp.activate()
            showAlert(message: report.message, details: report.details, style: .critical)
            NSApp.terminate(nil)
            return
        }

        if model.workspaces.isEmpty {
            model.newWorkspace()
        }
        let open = model.workspaces.filter { $0.window?.isOpen ?? true }
        for workspace in open.isEmpty ? Array(model.workspaces.prefix(1)) : open {
            openWindow(for: workspace.id)
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
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
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(model: model, settings: settings) {
                NSApp.mainMenu ?? MainMenu.make(installsSpecialMenus: false)
            }
        }
        settingsWindowController?.show()
        NSApp.activate()
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let preferences = settings.preferences
        switch menuItem.action {
        case #selector(increaseFontSize(_:)): return preferences.canIncreaseFontSize
        case #selector(decreaseFontSize(_:)): return preferences.canDecreaseFontSize
        case #selector(resetFontSize(_:)): return preferences.fontSize != Preferences.defaultFontSize
        default: return true
        }
    }

    /// File › New Tab with Profile is filled in each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier == MainMenu.newTabWithProfileIdentifier else { return }
        MainMenu.fillProfileMenu(menu, profiles: model.profiles, defaultProfile: model.defaultProfileID)
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
    private func openWindow(for id: WorkspaceID, cascadingFrom reference: NSWindow? = nil) {
        if let existing = windowControllers[id] {
            existing.showWindow(nil)
            return
        }
        if let workspace = model.workspace(id), workspace.window?.isOpen != true || workspace.tabGroups.isEmpty {
            model.reopenWorkspace(id)
        }
        let controller = WorkspaceWindowController(model: model, workspaceID: id, registry: registry)
        controller.actions.showWorkspace = { [weak self] id in self?.showWorkspace(id) }
        controller.actions.windowOfWorkspace = { [weak self] id in self?.windowControllers[id]?.window }
        // Cascade from the current window instead of opening exactly on top.
        if !controller.hadSavedFrame, let reference, let window = controller.window, window !== reference {
            window.cascadeTopLeft(from: reference.cascadeTopLeft(from: .zero))
        }
        controller.onWindowStateChange = { [weak self] controller, state in
            guard let self, !self.isTerminating else { return }
            if !state.isOpen {
                self.windowControllers[controller.workspaceID] = nil
            }
            // A deleted workspace has nothing left to record.
            if self.model.workspace(controller.workspaceID) != nil {
                self.model.updateWindowState(state, for: controller.workspaceID)
            }
        }
        windowControllers[id] = controller
        controller.showWindow(nil)
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

    // MARK: Persistence

    /// Turns SIGTERM (`kill`, `pkill`, launchd at logout) into a normal quit
    /// so state is saved synchronously, as on ⌘Q.
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // From the run loop rather than inside this dispatch block, so
            // the quit runs like ⌘Q's; in the common and modal-panel modes,
            // so an app-modal alert (a launch warning, a save failure) does
            // not hold it up until someone clicks OK. Logout must not wait.
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated {
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
