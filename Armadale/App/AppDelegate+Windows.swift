import AppKit
import ArmadaleCore
import ArmadaleSessions
import Observation
import os
import UserNotifications

/// Workspace windows: showing, opening and recording them, and the
/// full-screen hand-offs (docs/DESIGN.md section 8).
extension AppDelegate {
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
    func openWindow(
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
        // The dialog's New Host… offers the aliases of the user's ssh
        // configuration, read off the main actor when it is chosen.
        controller.actions.sshAliasLoader = { SSHConfigAliases.aliases(home: NSHomeDirectory()) }
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

    /// Queues a workspace's window to enter full screen (opened at launch,
    /// or shown again after menu bar mode); its reported flag stays true
    /// until it does. The windows that were in full screen go back one
    /// after another (each becomes its own Space; a second toggle while one
    /// animates can be refused). Each window was shown at its normal frame
    /// first, and its visible sessions started at that size; full screen
    /// then resizes them once. An entry whose turn comes in menu bar mode,
    /// or for a workspace deleted meanwhile (its last pane's session exited
    /// cleanly, say), is skipped.
    func queueFullScreen(_ id: WorkspaceID) {
        windowControllers[id]?.markFullScreenEntryPending()
        fullScreenSteps.enqueue { [weak self] done in
            guard let self, self.menuBarItem == nil, self.model.workspace(id) != nil,
                  let controller = self.windowControllers[id], !controller.isClosePending
            else { return done() }
            controller.enterFullScreen(then: done)
        }
    }
}
