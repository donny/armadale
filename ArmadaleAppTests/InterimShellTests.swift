import AppKit
import ArmadaleCore
import ArmadaleSessions
import Testing

/// Step 10a interim (replaced by the New Session chooser in 10c): every
/// path that makes panes gives each empty pane a local shell at once, in
/// the directory of the window's focused session pane, else home.
@Suite("Step 10a interim shells")
@MainActor
struct InterimShellTests {
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

    @Test func newTabsGroupsAndSplitsGetAShellInTheFocusedDirectory() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let first = try focusedSession(model, workspace)
        model.setWorkingDirectory("/repo/sub", for: first.id) // as OSC 7 reports it

        actions.splitFocusedPane(axis: .horizontal)
        let split = try focusedSession(model, workspace)
        #expect(split.id != first.id)
        #expect(split.workingDirectory == "/repo/sub")
        #expect(split.profileID == Profile.shell.id)
        #expect(split.location == .local)
        #expect(split.options == SessionOptions())

        actions.newTab()
        #expect(try focusedSession(model, workspace).workingDirectory == "/repo/sub")
        actions.newTabGroup()
        #expect(try focusedSession(model, workspace).workingDirectory == "/repo/sub")
        #expect(model.emptyPaneIDs(in: workspace).isEmpty)
        #expect(model.sessionIDs(in: workspace).count == 4)
    }

    /// A remote focused session's directory is the host's: the interim's
    /// local shell starts at home instead.
    @Test func aRemoteFocusedSessionGivesHome() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let host = model.addHost(name: "VM", sshDestination: "vm")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        _ = try #require(model.newTab(in: group, starting: Profile.shell.id, at: .remote(host: host), workingDirectory: "/srv"))
        actions.splitFocusedPane(axis: .vertical)
        let split = try focusedSession(model, workspace)
        #expect(split.location == .local)
        #expect(split.workingDirectory == "/Users/me")
    }

    /// Without a workspace to take a directory from (⌘N with no window,
    /// the fresh workspace at launch), home; every empty pane in the model
    /// is filled, a restored one included.
    @Test func withoutAWorkspaceEveryEmptyPaneGetsHome() throws {
        let model = AppModel(defaultWorkingDirectory: "/Users/me")
        let restored = model.newWorkspace(name: "Restored") // as if read from a file with an empty pane
        let fresh = WorkspaceActions.withInterimShells(model: model, near: nil) { model.newWorkspace() }
        for workspace in [restored, fresh] {
            #expect(model.emptyPaneIDs(in: workspace).isEmpty)
            #expect(try focusedSession(model, workspace).workingDirectory == "/Users/me")
        }
    }

    /// An empty pane closes without a question and ends nothing.
    @Test func closingAnEmptyPaneDoesNotAsk() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let tab = try #require(model.newTab(in: group)) // straight through the model: stays empty
        let pane = try #require(model.tab(tab)?.focusedPaneID)
        var removed: Set<SessionID> = []
        model.onSessionsRemoved = { removed.formUnion($0) }
        actions.closePane(pane, confirm: true)
        #expect(model.tab(tab) == nil, "closed at once, no alert")
        #expect(removed.isEmpty)
        #expect(model.sessionIDs(in: workspace).count == 1)
    }
}
