import AppKit
import ArmadaleCore
import ArmadaleSessions
import Observation
import os
import UserNotifications

/// App-wide menu actions: new workspaces, Settings and the Help windows,
/// font size, attention, and their validation.
extension AppDelegate {
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
}
