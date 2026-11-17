import AppKit
import ArmadaleCore
import os
import ServiceManagement

/// Updates (docs/DESIGN.md section 8, "Updates"): starting the updater,
/// Check for Updates…, the status menu's Update Available…, and what the
/// app tells the user before the quit Sparkle sends to install an update.
extension AppDelegate: UpdateHost {
    /// At the end of launching, after the launch alerts: starts the updater
    /// when ``UpdaterPolicy`` allows it in this run, and logs why not.
    func startUpdaterIfAllowed() {
        guard case .start = updaterVerdict else {
            if case .off(let reason) = updaterVerdict {
                stateLog.notice("Armadale: updates are off in this run (\(reason.rawValue, privacy: .public))")
            }
            return
        }
        guard let makeUpdater else { return }
        let updater = makeUpdater(updates)
        do {
            try updater.start()
        } catch {
            stateLog.error("Armadale: the updater did not start: \(String(describing: error), privacy: .public)")
            return
        }
        self.updater = updater
        updateSettings.attach(updater)
    }

    /// Armadale › Check for Updates…: enabled while the updater runs and
    /// can check (``validateMenuItem(_:)``).
    @objc func checkForUpdates(_ sender: Any?) {
        updater?.checkForUpdates()
    }

    /// Status menu › Update Available…: Sparkle's window for the update a
    /// scheduled check found while in menu bar mode, brought forward. The
    /// app keeps the accessory policy, as for Settings….
    @objc func showUpdateFromMenuBar(_ sender: Any?) {
        NSApp.unhide(nil) // hidden after a window closed in menu bar mode
        AppActivation.bringForward()
        updater?.checkForUpdates()
    }

    // MARK: UpdateHost

    func updateQuitContext() -> UpdateQuitDecision.Context {
        UpdateQuitDecision.Context(
            isEndingSessions: isEndingSessions,
            isQuitting: isTerminating || sessionsEnded,
            endingAtQuit: registry.sessionsThatEndAtQuit().count,
            lossSeen: lossSeenAt != nil,
            localAtRisk: registry.localSessionsThatMayOutliveQuit().count)
    }

    /// The question before the update's quit, brought forward like the quit
    /// question: for sessions that would end, Install and Relaunch (marked
    /// destructive) or Cancel; after a loss was seen, macOS's warning with
    /// Open System Settings, Install Anyway or Cancel.
    func askBeforeUpdateQuit(_ decision: UpdateQuitDecision) -> UpdateQuitAnswer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch decision {
        case .confirmEnding(let sessions):
            alert.messageText = UpdateText.endingMessage(sessions)
            alert.informativeText = UpdateText.endingInformative(sessions)
            alert.addButton(withTitle: UpdateText.installAndRelaunchButton).hasDestructiveAction = true
            alert.addButton(withTitle: UpdateText.cancelButton)
            AppActivation.bringForward()
            return alert.runModal() == .alertFirstButtonReturn ? .install : .cancel
        case .confirmLeavingSessions(let atRisk, let ending):
            alert.messageText = BackgroundActivityText.quitMessage(atRisk: atRisk)
            alert.informativeText = UpdateText.leavingInformative(atRisk: atRisk, ending: ending)
            alert.addButton(withTitle: BackgroundActivityText.openSettingsButton)
            alert.addButton(withTitle: UpdateText.installAnywayButton).hasDestructiveAction = true
            alert.addButton(withTitle: UpdateText.cancelButton)
            AppActivation.bringForward()
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                SMAppService.openSystemSettingsLoginItems()
                return .openSystemSettings
            case .alertSecondButtonReturn:
                return .install
            default:
                return .cancel
            }
        case .install:
            return .install
        case .refuse:
            return .cancel
        }
    }

    var isInMenuBarMode: Bool { menuBarItem != nil }

    /// In menu bar mode, an update session that ended (Remind Me Later,
    /// Skip, Cancel, an error) leaves the app hidden again when none of its
    /// own windows is on screen, as closing Settings does there; not after
    /// Open System Settings, which takes activation by itself (as after the
    /// quit question's Open System Settings).
    func updateSessionEnded(mayHide: Bool) {
        guard mayHide, NSApp.isActive else { return }
        Task { @MainActor [weak self] in self?.hideIfWindowlessInMenuBar() }
    }

    func updateSettingsChanged() {
        updateSettings.refresh()
    }
}
