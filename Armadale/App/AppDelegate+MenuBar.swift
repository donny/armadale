import AppKit
import ArmadaleCore
import ArmadaleSessions
import Observation
import os
import UserNotifications

/// Menu bar mode (docs/DESIGN.md section 8, "Quitting with running
/// sessions: menu bar mode"): entering and leaving it, and the status
/// menu's items.
extension AppDelegate {
    // MARK: Menu bar mode

    /// Hides every window (ordered out, not closed: the workspaces stay
    /// open for the next launch and their panes stay attached), leaves the
    /// Dock (accessory activation policy) and shows the status item.
    func enterMenuBarMode() {
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
    func leaveMenuBarMode() {
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
    /// way back unhides (``leaveMenuBarMode()``, ``showSettings(_:)``,
    /// ``showKeyboardShortcuts(_:)``, ``showAcknowledgements(_:)``).
    func auxiliaryWindowDidClose() {
        guard menuBarItem != nil else { return }
        Task { @MainActor [weak self] in
            self?.hideIfWindowlessInMenuBar()
        }
    }

    /// Whether an app in menu bar mode hides: it is active with nothing to
    /// type into once none of Settings, Keyboard Shortcuts or
    /// Acknowledgements is on screen. Pure, for the tests.
    nonisolated static func hidesInMenuBarMode(isInMenuBar: Bool, auxiliaryWindowVisible: Bool) -> Bool {
        isInMenuBar && !auxiliaryWindowVisible
    }

    /// Hides the app by ``hidesInMenuBarMode(isInMenuBar:auxiliaryWindowVisible:)``:
    /// after an auxiliary window closed, and after a quit from menu bar mode
    /// that did not go through (docs/DESIGN.md section 8).
    func hideIfWindowlessInMenuBar() {
        let visible = settingsWindowController?.window?.isVisible == true
            || shortcutsWindowController?.window?.isVisible == true
            || acknowledgementsWindowController?.window?.isVisible == true
        if Self.hidesInMenuBarMode(isInMenuBar: menuBarItem != nil, auxiliaryWindowVisible: visible) {
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
}
