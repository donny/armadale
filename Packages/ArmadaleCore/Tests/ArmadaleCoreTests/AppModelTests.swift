import Foundation
import Testing
@testable import ArmadaleCore

@Suite("AppModel")
@MainActor
struct AppModelTests {
    private func makeModel() -> (AppModel, WorkspaceID, TabGroupID) {
        let model = AppModel(defaultWorkingDirectory: "/work")
        let ws = model.newWorkspace(name: "W")
        let group = model.workspace(ws)?.tabGroups.first?.id ?? TabGroupID(raw: "none")
        return (model, ws, group)
    }

    @Test func newWorkspaceHasOneGroupOneTabOneSession() throws {
        let (model, ws, _) = makeModel()
        let workspace = try #require(model.workspace(ws))
        #expect(workspace.tabGroups.count == 1)
        #expect(workspace.tabGroups[0].tabs.count == 1)
        #expect(workspace.selectedTabGroupID == workspace.tabGroups[0].id)
        #expect(workspace.window?.isOpen == true)
        #expect(model.sessions.count == 1)
        #expect(model.sessions[0].workingDirectory == "/work")
        #expect(model.sessions[0].profileID == Profile.shell.id)
        #expect(model.changeCount == 1)
    }

    @Test func newTabResolvesLaunchFromProfile() throws {
        let (model, _, group) = makeModel()
        let tabID = try #require(model.newTab(in: group, profile: Profile.codex.id, workingDirectory: "/repo"))
        let tab = try #require(model.location(of: tabID))
        #expect(tab.tabGroup == group)
        let session = try #require(model.sessions.last)
        #expect(session.launch == LaunchSpec(program: "codex"))
        #expect(session.workingDirectory == "/repo")
        #expect(model.displayTitle(for: try #require(model.tab(containing: model.workspaces[0].tabGroups[0].tabs[1].focusedPaneID))) == "Codex")
        #expect(model.workspaces[0].tabGroups[0].selectedTabID == tabID)
    }

    @Test func splitAndClosePane() throws {
        let (model, _, _) = makeModel()
        let original = model.workspaces[0].tabGroups[0].tabs[0].focusedPaneID
        let new = try #require(model.splitPane(original, axis: .horizontal))
        var tab = model.workspaces[0].tabGroups[0].tabs[0]
        #expect(tab.layout.leaves() == [original, new])
        #expect(tab.focusedPaneID == new)
        #expect(model.sessions.count == 2)

        model.closePane(new)
        tab = model.workspaces[0].tabGroups[0].tabs[0]
        #expect(tab.layout == .pane(original))
        #expect(tab.focusedPaneID == original)
        #expect(tab.panes.map(\.id) == [original])
        #expect(model.sessions.count == 1)
    }

    @Test func closingLastPaneClosesTab() throws {
        let (model, _, group) = makeModel()
        let second = try #require(model.newTab(in: group))
        let pane = model.workspaces[0].tabGroups[0].tabs[1].focusedPaneID
        #expect(model.closePane(pane) == .closedTab(second, in: group))
        #expect(model.location(of: second) == nil)
        #expect(model.workspaces[0].tabGroups[0].tabs.count == 1)
        #expect(model.workspaces[0].tabGroups[0].selectedTabID == model.workspaces[0].tabGroups[0].tabs[0].id)
        #expect(model.sessions.count == 1)
    }

    /// Moving a group's last tab away removes the group, as closing its
    /// last tab does; the workspace keeps its other group, now selected.
    @Test func moveTabAcrossGroupsRemovesTheEmptiedGroup() throws {
        let (model, ws, group) = makeModel()
        let other = try #require(model.newTabGroup(in: ws, name: "Other"))
        model.select(tabGroup: group)
        let tab = model.workspaces[0].tabGroups[0].tabs[0].id
        let sessions = model.sessionIDs(ofTab: tab)
        model.moveTab(tab, to: other, index: 0)
        #expect(model.tabGroup(group) == nil)
        #expect(model.workspace(ws)?.tabGroups.map(\.id) == [other])
        #expect(model.workspace(ws)?.selectedTabGroupID == other)
        #expect(model.tabGroup(other)?.tabs.map(\.id).first == tab)
        #expect(model.location(of: tab)?.tabGroup == other)
        #expect(model.sessionIDs(ofTab: tab) == sessions, "the moved tab keeps its sessions")
        #expect(model.workspace(ws)?.window?.isOpen == true)
    }

    /// Groups A, B, C with C shown: moving C's only tab onto A removes C and
    /// shows A, the target, not B, C's neighbour. A move out of a group the
    /// window does not show leaves the shown group alone.
    @Test func emptyingTheShownGroupByAMoveShowsTheTarget() throws {
        let (model, ws, a) = makeModel()
        let b = try #require(model.newTabGroup(in: ws, name: "B"))
        let c = try #require(model.newTabGroup(in: ws, name: "C"))
        #expect(model.workspace(ws)?.selectedTabGroupID == c)
        let tab = try #require(model.tabGroup(c)?.tabs.first?.id)
        model.moveTab(tab, to: a, index: Int.max)
        #expect(model.workspace(ws)?.tabGroups.map(\.id) == [a, b])
        #expect(model.workspace(ws)?.selectedTabGroupID == a)
        #expect(model.tabGroup(a)?.selectedTabID == tab)

        // B is not shown: emptying it keeps A shown.
        let bTab = try #require(model.tabGroup(b)?.tabs.first?.id)
        let other = model.newWorkspace(name: "Other")
        let otherGroup = try #require(model.workspace(other)?.tabGroups.first?.id)
        model.moveTab(bTab, to: otherGroup, index: 0)
        #expect(model.workspace(ws)?.tabGroups.map(\.id) == [a])
        #expect(model.workspace(ws)?.selectedTabGroupID == a)

        // Into another workspace: the source shows its remaining neighbour.
        let a2 = try #require(model.newTabGroup(in: ws, name: "A2"))
        let a2Tab = try #require(model.tabGroup(a2)?.tabs.first?.id)
        model.moveTab(a2Tab, to: otherGroup, index: 0)
        #expect(model.workspace(ws)?.selectedTabGroupID == a)
        #expect(model.workspace(other)?.selectedTabGroupID == otherGroup)
    }

    /// Moving a workspace's last tab into another workspace removes its
    /// group and the workspace with it; its sessions move, none ends.
    @Test func moveTheLastTabToAnotherWorkspaceRemovesTheWorkspace() throws {
        let (model, ws, _) = makeModel()
        let other = model.newWorkspace(name: "Other")
        let target = try #require(model.workspace(other)?.tabGroups.first?.id)
        let tab = model.workspaces[0].tabGroups[0].tabs[0].id
        var removed: Set<SessionID> = []
        model.onSessionsRemoved = { removed.formUnion($0) }
        model.moveTab(tab, to: target, index: Int.max)
        #expect(model.workspace(ws) == nil)
        #expect(model.workspaces.map(\.id) == [other])
        #expect(model.location(of: tab)?.workspace == other)
        #expect(model.tabGroup(target)?.tabs.last?.id == tab)
        #expect(model.tabGroup(target)?.selectedTabID == tab)
        #expect(model.sessions.count == 2)
        #expect(removed.isEmpty, "no session ends")
    }

    /// What a close would delete, for the confirmation's wording.
    @Test func whichCloseRemovesTheWorkspace() throws {
        let (model, ws, group) = makeModel()
        let tab = try #require(model.tabGroup(group)?.tabs.first)
        #expect(model.workspaceRemoved(byClosingPane: tab.focusedPaneID) == ws)
        #expect(model.workspaceRemoved(byClosingTab: tab.id) == ws)
        #expect(model.workspaceRemoved(byClosingTabGroup: group) == ws)
        let split = try #require(model.splitPane(tab.focusedPaneID, axis: .vertical))
        #expect(model.workspaceRemoved(byClosingPane: split) == nil, "another pane stays")
        #expect(model.workspaceRemoved(byClosingTab: tab.id) == ws)
        let second = try #require(model.newTab(in: group))
        #expect(model.workspaceRemoved(byClosingTab: second) == nil, "another tab stays")
        #expect(model.workspaceRemoved(byClosingTabGroup: group) == ws)
        let otherGroup = try #require(model.newTabGroup(in: ws))
        #expect(model.workspaceRemoved(byClosingTabGroup: group) == nil, "another group stays")
        #expect(model.workspaceRemoved(byClosingTabGroup: otherGroup) == nil)
        #expect(model.workspaceRemoved(byClosingTabGroup: TabGroupID.generate()) == nil)
        #expect(model.workspaceRemoved(byClosingTab: TabID.generate()) == nil)
        #expect(model.workspaceRemoved(byClosingPane: PaneID.generate()) == nil)
    }

    @Test func selectionAndFocus() throws {
        let (model, ws, group) = makeModel()
        let second = try #require(model.newTabGroup(in: ws))
        #expect(model.workspace(ws)?.selectedTabGroupID == second)
        model.select(tabGroup: group)
        #expect(model.workspace(ws)?.selectedTabGroupID == group)
        let pane = model.workspaces[0].tabGroups[1].tabs[0].focusedPaneID
        model.focus(pane: pane)
        #expect(model.workspace(ws)?.selectedTabGroupID == second)
    }

    @Test func renamesAndTitles() throws {
        let (model, ws, group) = makeModel()
        model.renameWorkspace(ws, to: "Renamed")
        model.renameTabGroup(group, to: "G")
        let tab = model.workspaces[0].tabGroups[0].tabs[0]
        #expect(model.displayTitle(for: tab) == "Shell")
        let session = try #require(tab.pane(tab.focusedPaneID)?.sessionID)
        model.setTitle("vim", for: session)
        #expect(model.displayTitle(for: model.workspaces[0].tabGroups[0].tabs[0]) == "vim")
        model.renameTab(tab.id, to: "Custom")
        #expect(model.displayTitle(for: model.workspaces[0].tabGroups[0].tabs[0]) == "Custom")
        model.renameTab(tab.id, to: "")
        #expect(model.workspaces[0].tabGroups[0].tabs[0].customTitle == nil)
        #expect(model.workspace(ws)?.name == "Renamed")
        #expect(model.workspaces[0].tabGroups[0].name == "G")
    }

    @Test func deleteWorkspaceRemovesSessions() {
        let (model, ws, _) = makeModel()
        let other = model.newWorkspace()
        #expect(model.sessions.count == 2)
        model.deleteWorkspace(ws)
        #expect(model.workspaces.map(\.id) == [other])
        #expect(model.sessions.count == 1)
    }

    @Test func everyIntentBumpsChangeCount() throws {
        let (model, ws, group) = makeModel()
        var last = model.changeCount
        func bumped() -> Bool { defer { last = model.changeCount }; return model.changeCount > last }
        model.renameWorkspace(ws, to: "x"); #expect(bumped())
        let tab = try #require(model.newTab(in: group)); #expect(bumped())
        model.select(tabGroup: group); #expect(bumped())
        model.select(tab: tab); #expect(bumped())
        model.renameTab(tab, to: "t"); #expect(bumped())
        model.renameTabGroup(group, to: "g"); #expect(bumped())
        model.updateWindowState(WindowState(isOpen: false), for: ws); #expect(bumped())
        let pane = model.workspaces[0].tabGroups[0].tabs[1].focusedPaneID
        let split = try #require(model.splitPane(pane, axis: .vertical)); #expect(bumped())
        model.focus(pane: pane); #expect(bumped())
        model.closePane(split); #expect(bumped())
        let other = try #require(model.newTabGroup(in: ws)); #expect(bumped())
        model.moveTab(tab, to: other, index: 0); #expect(bumped())
        model.closeTab(tab); #expect(bumped())
        model.reopenWorkspace(ws); #expect(bumped())
        let session = model.sessions[0].id
        model.setTitle("title", for: session); #expect(bumped())
        model.deleteWorkspace(ws); #expect(bumped())

        // No-ops do not signal.
        model.renameWorkspace(WorkspaceID.generate(), to: "x"); #expect(!bumped())
        model.closePane(PaneID.generate()); #expect(!bumped())
        model.closeTab(TabID.generate()); #expect(!bumped())
        model.focus(pane: PaneID.generate()); #expect(!bumped())
        model.deleteWorkspace(WorkspaceID.generate()); #expect(!bumped())
    }

    @Test func closePaneFocusesNearestPaneOfSiblingBranch() throws {
        // p1 | (p2 / p3); close p3 → p2, not the geometric left neighbour p1.
        let (model, _, _) = makeModel()
        let p1 = model.workspaces[0].tabGroups[0].tabs[0].focusedPaneID
        let p2 = try #require(model.splitPane(p1, axis: .horizontal))
        let p3 = try #require(model.splitPane(p2, axis: .vertical))
        #expect(model.workspaces[0].tabGroups[0].tabs[0].focusedPaneID == p3)
        let tabID = model.workspaces[0].tabGroups[0].tabs[0].id
        #expect(model.closePane(p3) == .closedPane(p3, in: tabID))
        #expect(model.workspaces[0].tabGroups[0].tabs[0].focusedPaneID == p2)
    }

    @Test func closePaneKeepsFocusWhenUnfocusedPaneCloses() throws {
        let (model, _, _) = makeModel()
        let p1 = model.workspaces[0].tabGroups[0].tabs[0].focusedPaneID
        let p2 = try #require(model.splitPane(p1, axis: .horizontal))
        model.focus(pane: p1)
        model.closePane(p2)
        #expect(model.workspaces[0].tabGroups[0].tabs[0].focusedPaneID == p1)
    }

    @Test func closingLastTabRemovesItsGroup() throws {
        let (model, ws, first) = makeModel()
        let second = try #require(model.newTabGroup(in: ws, name: "Second"))
        #expect(model.workspace(ws)?.selectedTabGroupID == second)
        let tab = try #require(model.workspace(ws)?.tabGroups[1].tabs[0].id)
        #expect(model.closeTab(tab) == .closedTabGroup(second, in: ws))
        #expect(model.workspace(ws)?.tabGroups.map(\.id) == [first])
        #expect(model.workspace(ws)?.selectedTabGroupID == first)
        #expect(model.workspace(ws)?.window?.isOpen == true)
    }

    /// ⌘W on a workspace's last pane closes its tab, its group and deletes
    /// the workspace, whether others exist or not.
    @Test(arguments: [true, false])
    func closingTheLastPaneDeletesTheWorkspace(otherWorkspace: Bool) throws {
        let (model, ws, _) = makeModel()
        let other = otherWorkspace ? model.newWorkspace(name: "Other") : nil
        let pane = model.workspaces[0].tabGroups[0].tabs[0].focusedPaneID
        let session = try #require(model.tab(containing: pane)?.pane(pane)?.sessionID)
        var removed: Set<SessionID> = []
        model.onSessionsRemoved = { removed.formUnion($0) }
        #expect(model.closePane(pane) == .deletedWorkspace(ws))
        #expect(model.workspace(ws) == nil)
        #expect(model.workspaces.map(\.id) == (other.map { [$0] } ?? []))
        #expect(model.session(session) == nil)
        #expect(removed == [session])
    }

    /// Launch: with no workspace (the last one was deleted) a fresh one is
    /// made and opened; otherwise the open ones, else the first.
    @Test func launchOpensAFreshWorkspaceWhenThereIsNone() throws {
        let model = AppModel(state: PersistedState(), defaultWorkingDirectory: "/work")
        let opened = model.ensureWorkspacesToOpen()
        #expect(opened.count == 1)
        #expect(model.workspaces.map(\.id) == opened)
        #expect(model.workspaces[0].name == "Workspace")
        #expect(model.workspaces[0].tabGroups.map(\.name) == ["Main"])
        #expect(model.sessions.count == 1)

        let closedA = Workspace(name: "A", window: WindowState(isOpen: false))
        let closedB = Workspace(name: "B", window: WindowState(isOpen: false))
        let neverShown = Workspace(name: "C")
        let allClosed = AppModel(state: PersistedState(workspaces: [closedA, closedB]))
        #expect(allClosed.ensureWorkspacesToOpen() == [closedA.id])
        let some = AppModel(state: PersistedState(workspaces: [closedA, neverShown]))
        #expect(some.ensureWorkspacesToOpen() == [neverShown.id])
        #expect(some.workspaces.count == 2)
    }

    /// Closing a workspace's last tab (Close Tab) deletes it the same way.
    @Test func closingTheLastTabDeletesTheWorkspace() throws {
        let (model, ws, group) = makeModel()
        let other = model.newWorkspace(name: "Other")
        let tab = try #require(model.tabGroup(group)?.tabs.first?.id)
        #expect(model.closeTab(tab) == .deletedWorkspace(ws))
        #expect(model.workspaces.map(\.id) == [other])
    }

    /// A workspace with no tab groups, open (only a hand-edited file holds
    /// one now), gets a fresh "Main" group when reopened.
    @Test func reopeningAnEmptyWorkspaceMakesMain() throws {
        let empty = Workspace(name: "Empty", window: WindowState(isOpen: true))
        let model = AppModel(state: PersistedState(workspaces: [empty]), defaultWorkingDirectory: "/work")
        model.reopenWorkspace(empty.id)
        let reopened = try #require(model.workspace(empty.id))
        #expect(reopened.window?.isOpen == true)
        #expect(reopened.tabGroups.map(\.name) == ["Main"])
        #expect(reopened.tabGroups[0].tabs.count == 1)
        #expect(reopened.selectedTabGroupID == reopened.tabGroups[0].id)
        #expect(model.sessions.map(\.profileID) == [Profile.shell.id])
    }

    @Test func reopenWorkspaceKeepsExistingGroups() throws {
        let (model, ws, group) = makeModel()
        model.updateWindowState(WindowState(isOpen: false), for: ws)
        model.reopenWorkspace(ws)
        #expect(model.workspace(ws)?.tabGroups.map(\.id) == [group])
        #expect(model.workspace(ws)?.window?.isOpen == true)
    }

    @Test func moveTabIndexCountsAfterRemoval() throws {
        let (model, _, group) = makeModel()
        let t0 = model.workspaces[0].tabGroups[0].tabs[0].id
        let t1 = try #require(model.newTab(in: group))
        let t2 = try #require(model.newTab(in: group))
        // Moving t0 to index 1 within its own group: [t1, t2] → [t1, t0, t2].
        model.moveTab(t0, to: group, index: 1)
        #expect(model.workspaces[0].tabGroups[0].tabs.map(\.id) == [t1, t0, t2])
        model.moveTab(t1, to: group, index: 99)
        #expect(model.workspaces[0].tabGroups[0].tabs.map(\.id) == [t0, t2, t1])
    }

    @Test func modelRestoresBuiltInProfilesMissingFromState() {
        let model = AppModel(state: PersistedState(profiles: []))
        #expect(model.profiles.map(\.id) == Profile.builtIns.map(\.id))
    }

    @Test func defaultWorkspaceNamesAreUnique() {
        let model = AppModel()
        model.newWorkspace()
        model.newWorkspace()
        #expect(model.workspaces.map(\.name) == ["Workspace", "Workspace 2"])
    }

    @Test func replaceSessionRebindsPaneAndRetiresOld() throws {
        let (model, _, _) = makeModel()
        let tab = model.workspaces[0].tabGroups[0].tabs[0]
        let old = try #require(model.session(tab.panes[0].sessionID))
        model.setTitle("vim", for: old.id)
        let fresh = Session(
            location: old.location, profileID: old.profileID, launch: old.launch, workingDirectory: old.workingDirectory)
        let before = model.changeCount
        model.replaceSession(old.id, with: fresh)
        #expect(model.session(old.id) == nil)
        #expect(model.session(fresh.id) == fresh)
        #expect(model.workspaces[0].tabGroups[0].tabs[0].panes[0].sessionID == fresh.id)
        #expect(model.sessions.count == 1)
        #expect(model.changeCount == before + 1)
        // Unknown old IDs and duplicate new IDs are ignored.
        model.replaceSession(old.id, with: Session(profileID: old.profileID, launch: old.launch, workingDirectory: "/"))
        model.replaceSession(fresh.id, with: fresh)
        #expect(model.sessions == [fresh])
    }

    @Test func setWorkingDirectoryRecordsOSC7() throws {
        let (model, _, _) = makeModel()
        let id = model.sessions[0].id
        let before = model.changeCount
        model.setWorkingDirectory("/tmp/x", for: id)
        model.setWorkingDirectory("/tmp/x", for: id)
        #expect(model.session(id)?.workingDirectory == "/tmp/x")
        #expect(model.changeCount == before + 1)
    }

    @Test func setRuntimeVersionIsRecordedAndPersisted() throws {
        let (model, _, _) = makeModel()
        let id = model.sessions[0].id
        #expect(model.session(id)?.runtimeVersion == nil)
        let before = model.changeCount
        model.setRuntimeVersion("0.8.1", for: id)
        model.setRuntimeVersion("0.8.1", for: id)
        model.setRuntimeVersion("1.0", for: SessionID.generate())
        #expect(model.session(id)?.runtimeVersion == "0.8.1")
        #expect(model.changeCount == before + 1)
        #expect(model.persistedState.sessions.first?.runtimeVersion == "0.8.1")
    }

    @Test func sessionIDsInAWorkspace() throws {
        let (model, ws, group) = makeModel()
        let tab = try #require(model.newTab(in: group, profile: nil, workingDirectory: nil))
        let pane = try #require(model.workspace(ws)?.tabGroups[0].tabs.first { $0.id == tab }?.focusedPaneID)
        _ = model.splitPane(pane, axis: .horizontal)
        let other = model.newWorkspace(name: "Other")
        #expect(model.sessionIDs(in: ws).count == 3)
        #expect(Set(model.sessionIDs(in: ws)).isDisjoint(with: model.sessionIDs(in: other)))
        #expect(model.sessionIDs(in: other).count == 1)
        #expect(model.sessionIDs(in: WorkspaceID.generate()).isEmpty)
    }
}
