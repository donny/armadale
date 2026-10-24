import AppKit
import ArmadaleCore
import ArmadaleSessions
import Testing

/// Step 10b interim (replaced by the New Session chooser in 10c): every
/// path that makes panes leaves them empty, and each window asks its empty
/// panes for their session with the New Session dialog, one at a time
/// (``NewSessionPresenter``). Cancel closes the pane like a clean exit.
/// The sheet itself is not shown here (no window); its decisions are.
@Suite("Step 10b interim: the New Session dialog for new panes")
@MainActor
struct NewSessionInterimTests {
    private func fixture() -> (AppModel, WorkspaceActions, AppSettings, WorkspaceID) {
        _ = NSApplication.shared
        let model = AppModel(defaultWorkingDirectory: "/Users/me")
        let workspace = model.newWorkspace(name: "W")
        model.fillEmptyPanes(workingDirectory: "/repo")
        let settings = AppSettings.forTesting()
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: [],
            settings: settings)
        return (model, WorkspaceActions(model: model, registry: registry, workspaceID: workspace), settings, workspace)
    }

    private func focusedSession(_ model: AppModel, _ workspace: WorkspaceID) throws -> Session {
        try #require(model.focusedSessionID(in: workspace).flatMap { model.session($0) })
    }

    /// New tabs, tab groups and splits start nothing: their pane is empty,
    /// focused, and is the one the dialog is for.
    @Test func newPanesStayEmptyAndAreAskedAbout() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let first = try focusedSession(model, workspace)

        actions.splitFocusedPane(axis: .horizontal)
        let split = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        #expect(model.pane(split)?.isEmpty == true)
        #expect(model.sessionIDs(in: workspace) == [first.id])
        #expect(NewSessionPresenter.nextPane(in: model, workspace: workspace) == split)

        actions.newTab()
        let tabPane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        #expect(model.pane(tabPane)?.isEmpty == true)
        #expect(NewSessionPresenter.nextPane(in: model, workspace: workspace) == tabPane, "the one on screen first")

        actions.newTabGroup()
        #expect(model.emptyPaneIDs(in: workspace).count == 3)
        #expect(model.sessionIDs(in: workspace) == [first.id])
    }

    /// The pane asked about: the focused one if empty, else an empty pane
    /// on screen, else the first empty pane in the workspace (revealed).
    @Test func theNextPaneIsTheVisibleOneFirst() throws {
        let (model, _, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        #expect(NewSessionPresenter.nextPane(in: model, workspace: workspace) == nil)
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let firstTab = try #require(model.selectedTab(in: workspace)?.id)
        let original = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let background = try #require(model.newTab(in: group))
        let backgroundPane = try #require(model.tab(background)?.focusedPaneID)
        model.select(tab: firstTab)
        let split = try #require(model.splitPane(original, axis: .vertical))
        model.focus(pane: original)
        #expect(NewSessionPresenter.nextPane(in: model, workspace: workspace) == split, "an empty pane on screen")
        model.focus(pane: split)
        #expect(NewSessionPresenter.nextPane(in: model, workspace: workspace) == split)
        model.closePane(split)
        #expect(NewSessionPresenter.nextPane(in: model, workspace: workspace) == backgroundPane)
        NewSessionPresenter.reveal(backgroundPane, in: model, workspace: workspace)
        #expect(model.selectedTab(in: workspace)?.id == background)
        #expect(model.selectedTab(in: workspace)?.focusedPaneID == backgroundPane)
    }

    /// A zoomed tab is unzoomed to show the empty pane.
    @Test func revealingUnzooms() throws {
        let (model, _, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let original = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let split = try #require(model.splitPane(original, axis: .horizontal))
        model.focus(pane: original)
        model.toggleZoom(in: workspace)
        #expect(model.selectedTab(in: workspace)?.zoomedPaneID == original)
        #expect(NewSessionPresenter.nextPane(in: model, workspace: workspace) == split, "not on screen, but first")
        NewSessionPresenter.reveal(split, in: model, workspace: workspace)
        #expect(model.selectedTab(in: workspace)?.zoomedPaneID == nil)
        #expect(model.selectedTab(in: workspace)?.focusedPaneID == split)
    }

    /// A window for the real sheet (never ordered on screen).
    private func windowFixture() -> (AppModel, WorkspaceWindowController, AppSettings, WorkspaceID) {
        let (model, actions, settings, workspace) = fixture()
        let controller = WorkspaceWindowController(model: model, workspaceID: workspace, registry: actions.registry)
        return (model, controller, settings, workspace)
    }

    /// The dialog's directory: the focused session's before the pane was
    /// made (noted by every intent that makes one), else home; through the
    /// real `newSession(in:)`.
    @Test func theDirectoryComesFromThePaneFocusedBefore() throws {
        let (model, controller, settings, workspace) = windowFixture()
        defer {
            controller.close()
            settings.removeTestDefaults()
        }
        let actions = controller.actions
        let first = try focusedSession(model, workspace)
        model.setWorkingDirectory("/Users/me/src/app", for: first.id) // as OSC 7 reports it
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        #expect(model.focusedSessionID(in: workspace) == nil)
        actions.newSession(in: pane)
        #expect(actions.newSessionPane == pane)
        #expect(controller.window?.attachedSheet != nil)
        #expect(actions.newSessionForm?.workingDirectory == "~/src/app")
        actions.cancelNewSession(in: pane)
        #expect(actions.newSessionPane == nil)
        #expect(NewSessionForm.prefilledDirectory(in: model, from: nil) == "~")
    }

    /// Before a quit (``AppDelegate/prepareForQuit()``) the sheet goes, so
    /// AppKit's terminate is not refused; the pane stays empty (saved, it
    /// asks again at the next launch), and nothing is presented until the
    /// quit is cancelled.
    @Test func aQuitEndsTheSheetAndKeepsThePane() throws {
        let (model, controller, settings, workspace) = windowFixture()
        defer {
            controller.close()
            settings.removeTestDefaults()
        }
        let actions = controller.actions
        actions.splitFocusedPane(axis: .horizontal)
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        actions.newSession(in: pane)
        #expect(controller.window?.attachedSheet != nil)

        controller.suspendNewSessionsForQuit()
        #expect(controller.window?.attachedSheet == nil, "terminate is no longer refused")
        #expect(actions.newSessionPane == nil)
        #expect(model.pane(pane)?.isEmpty == true, "kept, and saved empty")
        actions.newSession(in: pane) // what a look would do; the presenter does not
        actions.endNewSessionSheet()
        controller.resumeNewSessions()
        #expect(model.pane(pane)?.isEmpty == true)
    }

    /// A sheet whose pane moved to another workspace (its tab dragged
    /// there), was closed or was started goes; that workspace's window asks.
    @Test func aSheetForAPaneThatLeftTheWorkspaceIsStale() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        actions.newTab()
        let tab = try #require(model.selectedTab(in: workspace)?.id)
        let pane = try #require(model.tab(tab)?.focusedPaneID)
        #expect(!NewSessionPresenter.sheetIsStale(for: pane, in: model, workspace: workspace))
        let other = model.newWorkspace(name: "Other")
        let otherGroup = try #require(model.workspace(other)?.selectedTabGroupID)
        model.moveTab(tab, to: otherGroup, index: 0)
        #expect(NewSessionPresenter.sheetIsStale(for: pane, in: model, workspace: workspace))
        #expect(!NewSessionPresenter.sheetIsStale(for: pane, in: model, workspace: other))
        model.startSession(in: pane, request: SessionRequest())
        #expect(NewSessionPresenter.sheetIsStale(for: pane, in: model, workspace: other))
    }

    /// Cancel closes the empty pane at once, with no question and nothing
    /// to end; a split's pane leaves the tab as it was.
    @Test func cancelClosesTheEmptyPane() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let tab = try #require(model.selectedTab(in: workspace))
        actions.splitFocusedPane(axis: .horizontal)
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        var removed: Set<SessionID> = []
        model.onSessionsRemoved = { removed.formUnion($0) }
        actions.cancelNewSession(in: pane)
        #expect(model.pane(pane) == nil)
        #expect(model.tab(tab.id)?.layout == tab.layout)
        #expect(removed.isEmpty)
        #expect(model.emptyPaneIDs(in: workspace).isEmpty)
    }

    /// ⌘N then Cancel: the cascade removes the tab, the group and the new
    /// workspace (its window then closes itself), as a clean exit does.
    @Test func cancellingANewWorkspaceRemovesIt() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let fresh = model.newWorkspace()
        let pane = try #require(model.emptyPaneIDs(in: fresh).first)
        let registry = actions.registry
        let freshActions = WorkspaceActions(model: model, registry: registry, workspaceID: fresh)
        freshActions.cancelNewSession(in: pane)
        #expect(model.workspace(fresh) == nil)
        #expect(model.workspace(workspace) != nil)
    }

    /// Cancel for a pane that was meanwhile given a session (or is gone)
    /// closes nothing.
    @Test func cancelLeavesAStartedPaneAlone() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        actions.cancelNewSession(in: pane)
        #expect(model.pane(pane)?.isEmpty == false)
    }

    /// Start through the actions: the session runs in the pane, which is
    /// focused; without a window no sheet was ever up.
    @Test func startStartsInThePane() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        actions.newSession(in: pane) // no window: nothing is presented
        #expect(actions.newSessionPane == nil)
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        var focused: PaneID?
        actions.focusPaneWhenShown = { focused = $0 }
        actions.startNewSession(form)
        #expect(model.pane(pane)?.isEmpty == false)
        #expect(focused == pane)
    }

    /// An empty pane closes without a question and ends nothing.
    @Test func closingAnEmptyPaneDoesNotAsk() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let tab = try #require(model.newTab(in: group))
        let pane = try #require(model.tab(tab)?.focusedPaneID)
        var removed: Set<SessionID> = []
        model.onSessionsRemoved = { removed.formUnion($0) }
        actions.closePane(pane, confirm: true)
        #expect(model.tab(tab) == nil, "closed at once, no alert")
        #expect(removed.isEmpty)
        #expect(model.sessionIDs(in: workspace).count == 1)
    }

    /// The host removal question counts the favorites it breaks.
    @Test func hostRemovalMentionsBrokenFavorites() {
        #expect(!HostsSettingsView.removalMessage(sessions: 1, favorites: 0).contains("favorite"))
        #expect(HostsSettingsView.removalMessage(sessions: 2, favorites: 1).hasSuffix(
            "A favorite uses this host and won’t start until you edit it."))
        #expect(HostsSettingsView.removalMessage(sessions: 1, favorites: 3).hasSuffix(
            "3 favorites use this host and won’t start until you edit them."))
    }
}
