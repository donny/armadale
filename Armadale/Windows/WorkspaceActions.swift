import AppKit
import ArmadaleCore

/// The hierarchy operations of one workspace window, shared by its menu
/// commands, tab bar and sidebar: selecting, creating, renaming, closing
/// (with the same confirmation everywhere), and drag and drop. Model
/// changes go through ``AppModel`` intents; sessions closed here are ended
/// by the ``SessionRegistry``.
@MainActor
final class WorkspaceActions {
    let model: AppModel
    let registry: SessionRegistry
    let workspaceID: WorkspaceID
    /// Where sheets go.
    weak var window: NSWindow?
    /// Brings a workspace's window to front, opening it if it is closed.
    var showWorkspace: (WorkspaceID) -> Void = { _ in }
    /// The open window of a workspace, if any.
    var windowOfWorkspace: (WorkspaceID) -> NSWindow? = { _ in nil }

    init(model: AppModel, registry: SessionRegistry, workspaceID: WorkspaceID) {
        self.model = model
        self.registry = registry
        self.workspaceID = workspaceID
    }

    // MARK: Selection

    func select(tab id: TabID) {
        model.select(tab: id)
        showIfElsewhere(model.location(of: id)?.workspace)
    }

    func select(tabGroup id: TabGroupID) {
        model.select(tabGroup: id)
        showIfElsewhere(model.workspaceID(containing: id))
    }

    private func showIfElsewhere(_ workspace: WorkspaceID?) {
        if let workspace, workspace != workspaceID { showWorkspace(workspace) }
    }

    // MARK: Creating

    /// A new tab in `group`, or in this workspace's selected group, with
    /// `profile` (else the default profile).
    func newTab(in group: TabGroupID? = nil, profile: ProfileID? = nil) {
        if let group = group ?? model.workspace(workspaceID)?.selectedTabGroupID {
            model.newTab(in: group, profile: profile)
            showIfElsewhere(model.workspaceID(containing: group))
        } else {
            model.newTabGroup(in: workspaceID)
        }
    }

    func newTabGroup(in workspace: WorkspaceID? = nil) {
        let target = workspace ?? workspaceID
        model.newTabGroup(in: target)
        showIfElsewhere(target)
    }

    // MARK: Renaming

    /// Where a rename sheet for something in `workspace` goes: that
    /// workspace's window when it is open (a double click on another
    /// workspace's row has just brought it forward), else this one.
    private func sheetWindow(for workspace: WorkspaceID?) -> NSWindow? {
        guard let workspace, workspace != workspaceID,
              let other = windowOfWorkspace(workspace), other.isVisible
        else { return window }
        return other
    }

    func renameWorkspace(_ id: WorkspaceID) {
        guard let workspace = model.workspace(id) else { return }
        TextPrompt.ask(on: sheetWindow(for: id), title: "Rename Workspace", initialValue: workspace.name) { [model] name in
            guard !name.isEmpty else { return }
            model.renameWorkspace(id, to: name)
        }
    }

    func renameTabGroup(_ id: TabGroupID) {
        guard let group = model.tabGroup(id) else { return }
        TextPrompt.ask(
            on: sheetWindow(for: model.workspaceID(containing: id)), title: "Rename Tab Group", initialValue: group.name
        ) { [model] name in
            guard !name.isEmpty else { return }
            model.renameTabGroup(id, to: name)
        }
    }

    func renameTab(_ id: TabID) {
        guard let tab = model.tab(id) else { return }
        TextPrompt.ask(
            on: sheetWindow(for: model.location(of: id)?.workspace), title: "Rename Tab",
            message: "Leave the name empty to show the title of the program running in the tab.",
            initialValue: tab.customTitle ?? model.displayTitle(for: tab)
        ) { [model] name in
            model.renameTab(id, to: name.isEmpty ? nil : name)
        }
    }

    // MARK: Closing

    /// Closes a pane (⌘W), killing its session; asks first if it may be
    /// running (and confirmation is on) or cannot be reached.
    func closePane(_ paneID: PaneID, confirm: Bool) {
        guard let tab = model.tab(containing: paneID), let sessionID = tab.pane(paneID)?.sessionID else { return }
        let perform: @MainActor () -> Void = { [model, registry] in
            let result = model.closePane(paneID)
            registry.close(sessionID)
            if case .notFound = result {
                NSLog("Armadale: pane %@ was already gone", paneID.raw)
            }
        }
        guard confirm else { return perform() }
        confirmClose(sessions: [sessionID], subject: .pane, perform: perform)
    }

    /// Closes a tab and its sessions (tab bar close button, middle click,
    /// context menu); asks like ⌘W.
    func closeTab(_ id: TabID) {
        let sessions = model.sessionIDs(ofTab: id)
        confirmClose(sessions: sessions, subject: .tab) { [model, registry] in
            model.closeTab(id)
            sessions.forEach(registry.close)
        }
    }

    /// Closes every other tab of `id`'s group; one confirmation for all.
    func closeOtherTabs(than id: TabID) {
        guard let location = model.location(of: id), let group = model.tabGroup(location.tabGroup) else { return }
        let others = group.tabs.map(\.id).filter { $0 != id }
        guard !others.isEmpty else { return }
        let sessions = others.flatMap { model.sessionIDs(ofTab: $0) }
        confirmClose(sessions: sessions, subject: .otherTabs) { [model, registry] in
            model.closeOtherTabs(than: id)
            sessions.forEach(registry.close)
        }
    }

    /// Closes a tab group with all its tabs. Its last group closes the
    /// workspace's window; the workspace stays.
    func closeTabGroup(_ id: TabGroupID) {
        guard let group = model.tabGroup(id) else { return }
        let sessions = group.tabs.flatMap { model.sessionIDs(ofTab: $0.id) }
        confirmClose(sessions: sessions, subject: .tabGroup) { [model, registry] in
            model.closeTabGroup(id)
            sessions.forEach(registry.close)
        }
    }

    /// Deletes a workspace and ends all its sessions, always after asking.
    func deleteWorkspace(_ id: WorkspaceID) {
        guard let workspace = model.workspace(id) else { return }
        let sessions = model.sessionIDs(in: id)
        let alert = NSAlert()
        alert.messageText = "Delete the workspace “\(workspace.name)”?"
        alert.informativeText = sessions.isEmpty
            ? "Its tab groups and tabs will be removed."
            : "Its tab groups and tabs will be removed, and the \(sessions.count == 1 ? "session" : "\(sessions.count) sessions") in them will end. This can’t be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        present(alert) { [model, registry] response, _ in
            guard response == .alertFirstButtonReturn else { return }
            model.deleteWorkspace(id)
            sessions.forEach(registry.close)
        }
    }

    private enum Subject {
        case pane, tab, otherTabs, tabGroup
    }

    private func confirmClose(sessions: [SessionID], subject: Subject, perform: @escaping @MainActor () -> Void) {
        let risk = registry.closeRisk(of: sessions)
        let preferences = registry.settings.preferences
        let wantsConfirmation = preferences.confirmClosingRunningSession
        guard risk.unreachable || (risk.mayBeRunning && wantsConfirmation) else { return perform() }

        let alert = NSAlert()
        switch subject {
        case .pane: alert.messageText = "Close this pane?"
        case .tab: alert.messageText = "Close this tab?"
        case .otherTabs: alert.messageText = "Close the other tabs?"
        case .tabGroup: alert.messageText = "Close this tab group?"
        }
        if risk.unreachable {
            alert.informativeText = subject == .pane
                ? "This session may still be running and cannot be reached right now. Closing the pane leaves it "
                    + "running until Armadale next starts with sessions available, and then ends it."
                : "Some of these sessions may still be running and cannot be reached right now. Closing leaves "
                    + "them running until Armadale next starts with sessions available, and then ends them."
        } else {
            alert.informativeText = switch subject {
            case .pane: "A process is still running in this pane. Closing it will end the session."
            case .tab: "A process is still running in this tab. Closing it will end its sessions."
            case .otherTabs: "Processes are still running in the other tabs. Closing them will end their sessions."
            case .tabGroup: "Processes are still running in this tab group. Closing it will end its sessions."
            }
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don’t ask again"
        }
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        present(alert) { response, alert in
            if alert.suppressionButton?.state == .on {
                preferences.confirmClosingRunningSession = false
            }
            guard response == .alertFirstButtonReturn else { return }
            perform()
        }
    }

    private func present(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse, NSAlert) -> Void) {
        guard let window else {
            completion(alert.runModal(), alert)
            return
        }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { completion(response, alert) }
        }
    }

    // MARK: Drag and drop

    /// Items dropped on the tab at `index` of `group` (or after the last
    /// tab when `index` is `nil`): a tab takes that position, from this
    /// group or any other.
    @discardableResult
    func drop(_ items: [HierarchyDragItem], onTabAt index: Int?, in group: TabGroupID) -> Bool {
        var handled = false
        for case .tab(let id) in items {
            model.moveTab(id, to: group, index: index ?? Int.max)
            handled = true
        }
        return handled
    }

    /// Items dropped on a tab group's sidebar row: a tab moves into the
    /// group (at the end); a tab group of the same workspace takes the
    /// group's position.
    @discardableResult
    func drop(_ items: [HierarchyDragItem], onTabGroup target: TabGroupID) -> Bool {
        var handled = false
        for item in items {
            switch item {
            case .tab(let id):
                guard model.location(of: id)?.tabGroup != target else { continue }
                model.moveTab(id, to: target, index: Int.max)
                handled = true
            case .tabGroup(let id):
                guard id != target, let workspace = model.workspaceID(containing: target),
                      model.workspaceID(containing: id) == workspace,
                      let index = model.workspace(workspace)?.tabGroups.firstIndex(where: { $0.id == target })
                else { continue }
                model.moveTabGroup(id, to: index)
                handled = true
            }
        }
        return handled
    }
}
