import AppKit
import ArmadaleCore

/// Loads state, owns the ``AppModel``, opens one window per open workspace,
/// and persists every model change (debounced) and on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
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
        self.canSave = result.allowsSaving
        self.loadReport = report
        self.model = AppModel(state: state)
        self.saver = StateSaver(url: url)
        super.init()
    }

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
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
        NSApp.activate()

        if let report = loadReport {
            loadReport = nil
            showAlert(message: report.message, details: report.details, style: .warning)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Windows closing because the app quits must stay "open" for next launch.
        isTerminating = true
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

    /// File › New Window: a new workspace in its own window.
    @objc func newWindow(_ sender: Any?) {
        let id = model.newWorkspace()
        openWindow(for: id)
    }

    // MARK: Windows

    /// Shows the workspace's window, creating it (and, if the workspace has
    /// no tab groups left, a fresh "Main" group) as needed.
    private func openWindow(for id: WorkspaceID) {
        if let existing = windowControllers[id] {
            existing.showWindow(nil)
            return
        }
        if let workspace = model.workspace(id), workspace.window?.isOpen != true || workspace.tabGroups.isEmpty {
            model.reopenWorkspace(id)
        }
        let controller = WorkspaceWindowController(model: model, workspaceID: id)
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
            MainActor.assumeIsolated {
                NSApp.terminate(nil)
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
