import AppKit
import ArmadaleCore
import SwiftUI

/// The hierarchy operations of one workspace window, shared by its menu
/// commands, tab bar and sidebar: selecting, creating, renaming in place
/// (``rename``, the window's one inline edit), closing (with the same
/// confirmation everywhere), and drag and drop. Model
/// changes go through ``AppModel`` intents; sessions closed here are ended
/// by the ``SessionRegistry``.
@MainActor
final class WorkspaceActions {
    let model: AppModel
    let registry: SessionRegistry
    let workspaceID: WorkspaceID
    /// The window's inline rename, observed by its sidebar and tab bar.
    let rename: InlineRename
    /// Where sheets go.
    weak var window: NSWindow?
    /// Brings a workspace's window to front, opening it if it is closed.
    var showWorkspace: (WorkspaceID) -> Void = { _ in }
    /// The actions of a workspace's open window, if any.
    var actionsOfWorkspace: (WorkspaceID) -> WorkspaceActions? = { _ in nil }

    init(model: AppModel, registry: SessionRegistry, workspaceID: WorkspaceID) {
        self.model = model
        self.registry = registry
        self.workspaceID = workspaceID
        rename = InlineRename(model: model)
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

    /// A new tab in `group`, or in this workspace's selected group. Its
    /// pane starts empty and shows the New Session chooser (DESIGN §8, "New
    /// sessions").
    func newTab(in group: TabGroupID? = nil) {
        noteFocusedSession(beforeCreatingIn: group.flatMap { model.workspaceID(containing: $0) })
        if let group = group ?? model.workspace(workspaceID)?.selectedTabGroupID {
            model.newTab(in: group)
        } else {
            model.newTabGroup(in: workspaceID)
        }
        if let group { showIfElsewhere(model.workspaceID(containing: group)) }
    }

    func newTabGroup(in workspace: WorkspaceID? = nil) {
        let target = workspace ?? workspaceID
        noteFocusedSession(beforeCreatingIn: target)
        _ = model.newTabGroup(in: target)
        showIfElsewhere(target)
    }

    /// ⌘D / ⇧⌘D: splits the focused pane. The new pane starts empty (a
    /// split no longer copies the pane's profile and directory) and asks
    /// like any new pane.
    func splitFocusedPane(axis: ArmadaleCore.Axis) {
        noteFocusedSession(beforeCreatingIn: workspaceID)
        _ = model.splitFocusedPane(axis: axis, in: workspaceID)
    }

    // MARK: New Session

    /// The session of the last focused pane of this window that had one:
    /// the New Session dialog's directory comes from it when the focused
    /// pane is the new, empty one. Noted before every intent here that
    /// makes a pane; a new window (⌘N) is given the focused session of the
    /// window it was made from.
    var lastFocusedSessionID: SessionID?

    /// Records this workspace's focused session, if it has one, as
    /// ``lastFocusedSessionID``, and that of `other` in its own window's
    /// actions when a pane is about to be made there.
    private func noteFocusedSession(beforeCreatingIn other: WorkspaceID? = nil) {
        if let id = model.focusedSessionID(in: workspaceID) { lastFocusedSessionID = id }
        if let other, other != workspaceID, let actions = actionsOfWorkspace(other) {
            actions.noteFocusedSession()
        }
    }

    /// Opens Settings on a tab (the dialog's Add Host…).
    var showSettings: (SettingsWindowController.Tab) -> Void = { _ in }
    /// Gives keyboard focus to a pane's terminal once it is on screen.
    var focusPaneWhenShown: (PaneID) -> Void = { _ in }
    /// Gives the window's focused pane keyboard focus (its terminal, the
    /// pane under a placeholder, or an empty pane's chooser). The sidebar
    /// calls it after a click on one of its rows, so the list never keeps
    /// the keyboard (October 29, 2026).
    var focusFocusedPane: () -> Void = {}
    /// Whether the window can take a sheet now, besides having none: the
    /// window controller refuses while the window is closing or entering
    /// or leaving full screen (``WorkspaceWindowController/canPresentSheet(isClosed:isClosePending:fullScreenTarget:)``).
    /// The chooser's New Session… and Return then do nothing.
    var canPresentSheet: () -> Bool = { true }

    /// The sheet that is up (New Session, or Edit Favorite from the
    /// chooser), with its form.
    private var sheet: NSViewController?
    /// The form of the sheet that is up, if one is.
    private(set) var newSessionForm: NewSessionForm?
    /// Ends the sheet when what it is about goes away.
    private var sheetWatch: Task<Void, Never>?

    /// The pane whose New Session sheet is up, if one is.
    var newSessionPane: PaneID? {
        if case .newSession(let pane)? = newSessionForm?.mode { pane } else { nil }
    }

    /// The New Session dialog for the empty pane `paneID`, as a sheet on
    /// this window (DESIGN §8), opened by the pane's chooser (its New
    /// Session… button, or Return with no favorite selected). Start starts
    /// the session there (saving a favorite first when asked) and focuses
    /// the pane; Cancel closes the sheet only, and the pane keeps its
    /// chooser. Does nothing while a sheet is up, without a window, or for
    /// a pane that is gone or has a session.
    func newSession(in paneID: PaneID) {
        guard model.pane(paneID)?.isEmpty == true else { return }
        let directorySession = model.focusedSessionID(in: workspaceID) ?? lastFocusedSessionID
        let form = NewSessionForm(model: model, mode: .newSession(paneID), directorySession: directorySession)
        presentSheet(form: form) { [weak self] in self?.startNewSession(form) }
    }

    /// The favorite's Edit… in the chooser: the dialog in edit mode, as a
    /// sheet on this window. Save updates the favorite; nothing is started.
    func editFavorite(_ id: FavoriteID) {
        guard model.favorite(id) != nil else { return }
        let form = NewSessionForm(model: model, mode: .editFavorite(id))
        presentSheet(form: form) { [weak self, weak form] in
            guard let self, let form, self.newSessionForm === form else { return }
            form.save()
            self.endNewSessionSheet()
        }
    }

    private func presentSheet(form: NewSessionForm, onConfirm: @escaping @MainActor () -> Void) {
        guard newSessionForm == nil, canPresentSheet(), let window, window.attachedSheet == nil,
              let presenter = window.contentViewController
        else { return }
        rename.commit()
        let controller = NSHostingController(rootView: NewSessionSheet(
            form: form,
            showHosts: { [weak self] in self?.showSettings(.hosts) },
            onCancel: { [weak self] in self?.endNewSessionSheet() },
            onConfirm: onConfirm))
        controller.sizingOptions = [.preferredContentSize]
        sheet = controller
        newSessionForm = form
        watchSheet(form)
        presenter.presentAsSheet(controller)
    }

    /// Takes the sheet down once its pane is closed, given a session
    /// elsewhere, or moved to another workspace (its tab dragged there from
    /// another window's sidebar; that workspace's window shows its
    /// chooser), or its favorite is removed (in Settings).
    private func watchSheet(_ form: NewSessionForm) {
        sheetWatch?.cancel()
        let model = model
        let mode = form.mode
        let workspaceID = workspaceID
        sheetWatch = Task { [weak self] in
            let stillWanted = Observations { () -> Bool in
                switch mode {
                case .newSession(let pane): WorkspaceActions.sheetIsWanted(for: pane, in: model, workspace: workspaceID)
                case .editFavorite(let id): model.favorite(id) != nil
                case .newFavorite: true
                }
            }
            for await wanted in stillWanted where !wanted {
                guard let self, self.newSessionForm === form else { return }
                self.endNewSessionSheet()
                return
            }
        }
    }

    /// Whether a New Session sheet for `pane` on `workspace`'s window still
    /// has a purpose: the pane is still an empty pane of that workspace.
    static func sheetIsWanted(for pane: PaneID, in model: AppModel, workspace: WorkspaceID) -> Bool {
        model.emptyPaneIDs(in: workspace).contains(pane)
    }

    /// Start: the session begins in the pane, the sheet goes, and the
    /// pane's terminal takes keyboard focus once it is shown.
    func startNewSession(_ form: NewSessionForm) {
        guard case .newSession(let paneID) = form.mode, form.isValid else { return }
        let started = form.start() != nil
        if newSessionForm === form { endNewSessionSheet() }
        guard started else { return }
        model.focus(pane: paneID)
        focusPaneWhenShown(paneID)
    }

    /// A favorite clicked (or chosen with Return) in the chooser of the
    /// empty pane `paneID`: starts a session from its request there, focuses
    /// the pane and gives its terminal keyboard focus once shown. Refused
    /// (returns `nil`, nothing changes) when the favorite is gone or broken
    /// (``AppModel/favoriteProblem(_:)``), or the pane is gone or already
    /// has a session.
    @discardableResult
    func startFavorite(_ id: FavoriteID, in paneID: PaneID) -> SessionID? {
        guard let favorite = model.favorite(id), model.favoriteProblem(favorite) == nil,
              model.pane(paneID)?.isEmpty == true
        else { return nil }
        rename.commit()
        guard let session = model.startSession(in: paneID, request: favorite.request) else { return nil }
        model.focus(pane: paneID)
        focusPaneWhenShown(paneID)
        return session
    }

    /// The favorite's Remove in the chooser: no question (a favorite is
    /// only a recipe; sessions started from it are unaffected).
    func removeFavorite(_ id: FavoriteID) {
        model.removeFavorite(id)
    }

    /// The chooser's Cancel (and Escape): the empty pane closes through the
    /// normal close path with no question (nothing runs there), cascading
    /// to its tab, tab group and workspace as a clean exit does, so a new
    /// window whose chooser is cancelled closes again. A New Session sheet
    /// up for it goes too.
    func cancelNewSession(in paneID: PaneID) {
        if newSessionPane == paneID { endNewSessionSheet() }
        if model.pane(paneID)?.isEmpty == true { closePane(paneID, confirm: false) }
    }

    /// Takes the sheet (New Session or Edit Favorite) down, if one is up,
    /// without starting, saving or closing anything: Cancel, a quit
    /// (``AppDelegate/prepareForQuit()``), the window closing, or what it
    /// was about having gone.
    func endNewSessionSheet() {
        sheetWatch?.cancel()
        sheetWatch = nil
        guard newSessionForm != nil else { return }
        let sheet = sheet
        self.sheet = nil
        newSessionForm = nil
        if let sheet, sheet.presentingViewController != nil {
            sheet.presentingViewController?.dismiss(sheet)
        }
    }

    // MARK: Renaming

    /// Starts renaming `item` in place on `surface` of this window (the
    /// sidebar row's or the tab's title becomes a text field; see
    /// ``InlineRename``). From the sidebar, an item of another workspace
    /// whose window is now the key window is edited in that window's
    /// sidebar instead: the first click of a double click on its row has
    /// just brought that window forward, and the field must be where the
    /// keyboard is.
    func beginRename(_ item: SidebarItem, on surface: RenameSurface) {
        if surface == .sidebar, let owner = workspace(of: item), owner != workspaceID,
           let other = actionsOfWorkspace(owner), other.window?.isKeyWindow == true {
            rename.commit()
            other.rename.begin(item, on: .sidebar)
            return
        }
        rename.begin(item, on: surface)
    }

    private func workspace(of item: SidebarItem) -> WorkspaceID? {
        switch item {
        case .workspace(let id): id
        case .tabGroup(let id): model.workspaceID(containing: id)
        case .tab(let id): model.location(of: id)?.workspace
        }
    }

    // MARK: Closing

    /// Closes a pane (⌘W), killing its session; asks first if it may be
    /// running (and confirmation is on) or cannot be reached. An empty pane
    /// (no session yet) has nothing to end and closes without asking.
    func closePane(_ paneID: PaneID, confirm: Bool) {
        rename.commit() // a name being typed counts, in the question too
        guard let pane = model.tab(containing: paneID)?.pane(paneID) else { return }
        let sessionID = pane.sessionID
        let perform: @MainActor () -> Void = { [model, registry] in
            let result = model.closePane(paneID)
            if let sessionID { registry.close(sessionID) }
            if case .notFound = result {
                NSLog("Armadale: pane %@ was already gone", paneID.raw)
            }
        }
        guard confirm, let sessionID else { return perform() }
        confirmClose(
            sessions: [sessionID], subject: .pane, removing: model.workspaceRemoved(byClosingPane: paneID),
            perform: perform)
    }

    /// Closes a tab and its sessions (tab bar close button, middle click,
    /// context menu); asks like ⌘W.
    func closeTab(_ id: TabID) {
        rename.commit()
        let sessions = model.sessionIDs(ofTab: id)
        let removing = model.workspaceRemoved(byClosingTab: id)
        confirmClose(sessions: sessions, subject: .tab, removing: removing) { [model, registry] in
            model.closeTab(id)
            sessions.forEach(registry.close)
        }
    }

    /// Closes every other tab of `id`'s group; one confirmation for all.
    func closeOtherTabs(than id: TabID) {
        rename.commit()
        guard let location = model.location(of: id), let group = model.tabGroup(location.tabGroup) else { return }
        let others = group.tabs.map(\.id).filter { $0 != id }
        guard !others.isEmpty else { return }
        let sessions = others.flatMap { model.sessionIDs(ofTab: $0) }
        confirmClose(sessions: sessions, subject: .otherTabs, removing: nil) { [model, registry] in
            model.closeOtherTabs(than: id)
            sessions.forEach(registry.close)
        }
    }

    /// Closes a tab group with all its tabs. Closing the workspace's last
    /// group deletes the workspace (``CloseResult/deletedWorkspace(_:)``);
    /// its window closes itself when the workspace leaves the model.
    func closeTabGroup(_ id: TabGroupID) {
        rename.commit()
        guard let group = model.tabGroup(id) else { return }
        let sessions = group.tabs.flatMap { model.sessionIDs(ofTab: $0.id) }
        let removing = model.workspaceRemoved(byClosingTabGroup: id)
        confirmClose(sessions: sessions, subject: .tabGroup, removing: removing) { [model, registry] in
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

    /// What a close confirmation is about.
    enum CloseSubject {
        case pane, tab, otherTabs, tabGroup
    }

    /// `removing`: the workspace the close deletes (its last tab group goes),
    /// named in the question; nothing more is asked because of it.
    private func confirmClose(
        sessions: [SessionID], subject: CloseSubject, removing workspace: WorkspaceID?,
        perform: @escaping @MainActor () -> Void
    ) {
        let risk = registry.closeRisk(of: sessions)
        let preferences = registry.settings.preferences
        let wantsConfirmation = preferences.confirmClosingRunningSession
        guard risk.unreachable || (risk.mayBeRunning && wantsConfirmation) else { return perform() }

        let alert = NSAlert()
        let text = Self.closeConfirmationText(
            subject: subject, unreachable: risk.unreachable,
            removingWorkspace: workspace.flatMap { model.workspace($0)?.name })
        alert.messageText = text.message
        alert.informativeText = text.informative
        if !risk.unreachable {
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

    /// The close confirmation's question and explanation. When the close
    /// removes the workspace's last tab group, and so the workspace
    /// (DESIGN §8), the explanation ends by saying so.
    nonisolated static func closeConfirmationText(
        subject: CloseSubject, unreachable: Bool, removingWorkspace workspaceName: String?
    ) -> (message: String, informative: String) {
        let message = switch subject {
        case .pane: "Close this pane?"
        case .tab: "Close this tab?"
        case .otherTabs: "Close the other tabs?"
        case .tabGroup: "Close this tab group?"
        }
        var informative: String
        if unreachable {
            informative = subject == .pane
                ? "This session may still be running and cannot be reached right now. Closing the pane leaves it "
                    + "running until Armadale next starts with sessions available, and then ends it."
                : "Some of these sessions may still be running and cannot be reached right now. Closing leaves "
                    + "them running until Armadale next starts with sessions available, and then ends them."
        } else {
            informative = switch subject {
            case .pane: "A process is still running in this pane. Closing it will end the session."
            case .tab: "A process is still running in this tab. Closing it will end its sessions."
            case .otherTabs: "Processes are still running in the other tabs. Closing them will end their sessions."
            case .tabGroup: "Processes are still running in this tab group. Closing it will end its sessions."
            }
        }
        if let workspaceName {
            informative += " The workspace “\(workspaceName)” will be removed too."
        }
        return (message, informative)
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
