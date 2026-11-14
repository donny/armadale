import AppKit
import ArmadaleCore
import ArmadaleSessions
import Observation
import os
import UserNotifications

/// Saving the state (docs/DESIGN.md section 3): the model observation,
/// immediate saves and save failures.
extension AppDelegate {
    /// Writes the state at once instead of after the debounce.
    func saveNow() {
        guard canSave else { return }
        saver.schedule(model.persistedState)
        saver.flush()
    }

    /// Tells the user once per launch that saving is failing; the saver
    /// keeps retrying in the background.
    func reportSaveFailure(_ error: any Error) {
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

    /// Schedules a debounced save whenever the model changes.
    func observeModelForPersistence() {
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
