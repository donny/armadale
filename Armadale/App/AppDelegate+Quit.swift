import AppKit
import ArmadaleCore
import ArmadaleSessions
import Observation
import os
import ServiceManagement
import UserNotifications

/// The quit paths (docs/DESIGN.md section 8, "Quitting with running
/// sessions"): the quit question, End Sessions and Quit, the SIGTERM
/// handler and ending sheets before a quit.
extension AppDelegate {
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
        let isSystemQuit = Self.isSystemQuit(NSAppleEventManager.shared().currentAppleEvent)
        let localSessions = registry.localSessionsThatMayOutliveQuit()
        let decision = QuitDecision.decide(
            running: registry.runningSessionCount(),
            preference: settings.preferences.quitWithRunningSessions,
            context: QuitDecision.Context(
                isForced: isForcedQuit || isSystemQuit,
                isInMenuBar: menuBarItem != nil,
                isEndingSessions: isEndingSessions, sessionsEnded: sessionsEnded,
                lossSeen: lossSeenAt != nil, localAtRisk: localSessions.count))
        switch decision {
        case .quitNow:
            break
        case .confirmLeavingSessions(let atRisk):
            let answer = askBeforeLeavingSessions(atRisk)
            if answer == .alertSecondButtonReturn { break }  // Quit Anyway
            // Open System Settings or Cancel: the quit is cancelled and the
            // app stays in the menu bar.
            if answer == .alertFirstButtonReturn {
                // System Settings takes activation by itself; hiding would
                // hand it to the previously active app, which may land after
                // System Settings and put it behind.
                SMAppService.openSystemSettingsLoginItems()
            } else {
                // The alert brought the app forward; with no window of its
                // own left on screen it hides again, so keystrokes go back to
                // the app that had them (as when Settings closes). On the
                // next turn, once this quit has been answered.
                Task { @MainActor [weak self] in self?.hideIfWindowlessInMenuBar() }
            }
            return .terminateCancel
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
        // Before the clients hang up: which local sessions this quit leaves
        // running, for the check at the next launch (DESIGN §8, "Background
        // App Activity"); written with the state in `applicationWillTerminate`.
        quitToRecord = LastQuitRecord.Quit(
            time: Date(),
            kind: Self.kindOfQuit(isSignal: isForcedQuit, isSystem: isSystemQuit, sessionsEnded: sessionsEnded),
            bootTime: LoginSession.bootTime(),
            auditSessionID: LoginSession.auditSessionID(),
            sessions: localSessions)
        // Quitting never ends sessions: hang up every client now (SIGHUP and
        // closing its terminal are synchronous; the session daemons keep
        // running) and quit at once. Never `.terminateLater`: a quit that
        // waits on async work deadlocks when it starts inside a main-queue
        // block, as SIGTERM's handler does (AppKit then runs a nested run
        // loop the main actor cannot run in), which would block logout.
        registry.detachAllNow()
        return .terminateNow
    }

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

    /// The kind of a quit that goes through, for ``LastQuitRecord``: SIGTERM
    /// (`isForcedQuit`; a fatal launch writes no record) before a quit
    /// Apple event with a reason, then End Sessions and Quit's own quit;
    /// anything else is the user's.
    nonisolated static func kindOfQuit(isSignal: Bool, isSystem: Bool, sessionsEnded: Bool) -> LastQuitRecord.Kind {
        if isSignal { return .signal }
        if isSystem { return .system }
        if sessionsEnded { return .endedSessions }
        return .user
    }

    /// The question before a quit from menu bar mode while a loss has been
    /// seen (docs/DESIGN.md section 8, "Background App Activity"). Returns
    /// the button: first Open System Settings, second Quit Anyway.
    private func askBeforeLeavingSessions(_ atRisk: Int) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = BackgroundActivityText.quitMessage(atRisk: atRisk)
        alert.informativeText = BackgroundActivityText.quitInformative(atRisk: atRisk)
        alert.addButton(withTitle: BackgroundActivityText.openSettingsButton)
        // The answer that may lose sessions, marked as End Sessions and Quit is.
        alert.addButton(withTitle: BackgroundActivityText.quitAnywayButton).hasDestructiveAction = true
        alert.addButton(withTitle: BackgroundActivityText.cancelButton)
        // An accessory app answering its status menu: in front, as the quit
        // question is.
        AppActivation.bringForward()
        return alert.runModal()
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
            await registry.endAllSessions()
            let appeared = registry.sessionsStillRunning()
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

    /// Turns SIGTERM (`kill`, `pkill`, launchd at logout) into a normal quit
    /// so state is saved synchronously, as on ⌘Q.
    func handleTerminationSignal() {
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
}
