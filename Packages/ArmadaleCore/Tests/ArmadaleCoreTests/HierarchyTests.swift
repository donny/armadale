import Foundation
import Testing
@testable import ArmadaleCore

/// Step 4 intents: tab groups, tab navigation, close-others, moves, and
/// pane focus / resize / zoom through ``PaneLayout``.
@Suite("AppModel hierarchy")
@MainActor
struct HierarchyTests {
    private func makeModel() -> (AppModel, WorkspaceID, TabGroupID) {
        let model = AppModel(defaultWorkingDirectory: "/work")
        let ws = model.newWorkspace(name: "W")
        model.fillEmptyPanes()
        let group = model.workspace(ws)?.tabGroups.first?.id ?? TabGroupID(raw: "none")
        return (model, ws, group)
    }

    private func tabs(_ model: AppModel, _ group: TabGroupID) -> [TabID] {
        model.tabGroup(group)?.tabs.map(\.id) ?? []
    }

    // MARK: Tab groups

    @Test func moveTabGroupReordersWithinWorkspace() throws {
        let (model, ws, g1) = makeModel()
        let g2 = try #require(model.newTabGroup(in: ws, name: "B"))
        let g3 = try #require(model.newTabGroup(in: ws, name: "C"))
        model.moveTabGroup(g3, to: 0)
        #expect(model.workspace(ws)?.tabGroups.map(\.id) == [g3, g1, g2])
        model.moveTabGroup(g3, to: 99)
        #expect(model.workspace(ws)?.tabGroups.map(\.id) == [g1, g2, g3])
        model.moveTabGroup(g1, to: 1)
        #expect(model.workspace(ws)?.tabGroups.map(\.id) == [g2, g1, g3])
        // Selection is untouched (the last created group).
        #expect(model.workspace(ws)?.selectedTabGroupID == g3)
        let before = model.changeCount
        model.moveTabGroup(TabGroupID.generate(), to: 0)
        #expect(model.changeCount == before)
    }

    @Test func closeTabGroupRemovesItsSessionsAndSelectsNeighbour() throws {
        let (model, ws, g1) = makeModel()
        let g2 = try #require(model.newTabGroup(in: ws, name: "B"))
        _ = try #require(model.newTab(in: g2))
        model.fillEmptyPanes()
        #expect(model.sessions.count == 3)
        #expect(model.closeTabGroup(g2) == .closedTabGroup(g2, in: ws))
        #expect(model.workspace(ws)?.tabGroups.map(\.id) == [g1])
        #expect(model.workspace(ws)?.selectedTabGroupID == g1)
        #expect(model.sessions.count == 1)
        #expect(model.closeTabGroup(TabGroupID.generate()) == .notFound)
    }

    /// Closing a workspace's last tab group deletes the workspace when
    /// others exist; they are untouched (DESIGN §8, October 23, 2026).
    @Test func closingLastTabGroupDeletesTheWorkspace() throws {
        let (model, ws, g1) = makeModel()
        let other = model.newWorkspace(name: "Other")
        model.fillEmptyPanes()
        let otherBefore = try #require(model.workspace(other))
        let sessionsBefore = model.sessions.count
        let changes = model.changeCount
        #expect(model.closeTabGroup(g1) == .deletedWorkspace(ws))
        #expect(model.workspace(ws) == nil)
        #expect(model.workspaces.map(\.id) == [other])
        #expect(model.workspace(other) == otherBefore, "the other workspace is unchanged")
        #expect(model.sessions.count == sessionsBefore - 1)
        #expect(model.changeCount > changes)
        #expect(model.closeTabGroup(g1) == .notFound)
    }

    /// The only workspace is deleted too: the model is left with none, and
    /// the next new workspace takes the free name "Workspace" again.
    @Test func closingTheOnlyWorkspacesLastTabGroupLeavesNoWorkspace() throws {
        let model = AppModel(defaultWorkingDirectory: "/work")
        let ws = model.newWorkspace()
        #expect(model.workspace(ws)?.name == "Workspace")
        let group = try #require(model.workspace(ws)?.selectedTabGroupID)
        #expect(model.closeTabGroup(group) == .deletedWorkspace(ws))
        #expect(model.workspaces.isEmpty)
        #expect(model.sessions.isEmpty)
        #expect(model.persistedState.workspaces.isEmpty)
        let fresh = model.newWorkspace()
        #expect(fresh != ws)
        #expect(model.workspace(fresh)?.name == "Workspace")
        #expect(model.workspace(fresh)?.tabGroups.map(\.name) == ["Main"])
    }

    /// A workspace with groups left keeps them, its window and itself.
    @Test func closingOneOfSeveralTabGroupsKeepsTheWorkspace() throws {
        let (model, ws, g1) = makeModel()
        let g2 = try #require(model.newTabGroup(in: ws, name: "B"))
        let tab = try #require(model.tabGroup(g2)?.tabs.first?.id)
        #expect(model.closeTab(tab) == .closedTabGroup(g2, in: ws))
        #expect(model.workspace(ws)?.tabGroups.map(\.id) == [g1])
        #expect(model.workspace(ws)?.window?.isOpen == true)
        #expect(model.workspaces.count == 1)
    }

    @Test func selectTabGroupByNumber() throws {
        let (model, ws, g1) = makeModel()
        let g2 = try #require(model.newTabGroup(in: ws))
        #expect(model.selectTabGroup(number: 1, in: ws))
        #expect(model.workspace(ws)?.selectedTabGroupID == g1)
        #expect(model.selectTabGroup(number: 2, in: ws))
        #expect(model.workspace(ws)?.selectedTabGroupID == g2)
        let before = model.changeCount
        #expect(!model.selectTabGroup(number: 3, in: ws))
        #expect(!model.selectTabGroup(number: 0, in: ws))
        #expect(model.workspace(ws)?.selectedTabGroupID == g2)
        #expect(model.changeCount == before)
    }

    @Test func renameEverything() throws {
        let (model, ws, group) = makeModel()
        let tab = tabs(model, group)[0]
        model.renameWorkspace(ws, to: "Agents")
        model.renameTabGroup(group, to: "Backend")
        model.renameTab(tab, to: "server")
        #expect(model.workspace(ws)?.name == "Agents")
        #expect(model.tabGroup(group)?.name == "Backend")
        #expect(model.displayTitle(for: try #require(model.selectedTab(in: ws))) == "server")
        model.renameTab(tab, to: nil)
        #expect(model.displayTitle(for: try #require(model.selectedTab(in: ws))) == "Shell")
    }

    // MARK: Tabs

    @Test func moveTabToAnotherGroupKeepsSessionAndSelectsItThere() throws {
        let (model, ws, g1) = makeModel()
        let t2 = try #require(model.newTab(in: g1))
        let g2 = try #require(model.newTabGroup(in: ws, name: "B"))
        model.fillEmptyPanes()
        model.select(tabGroup: g1)
        let sessions = model.sessionIDs(ofTab: t2)
        let existing = tabs(model, g2)[0]
        model.moveTab(t2, to: g2, index: 0)
        #expect(tabs(model, g2) == [t2, existing])
        #expect(model.tabGroup(g2)?.selectedTabID == t2)
        #expect(model.sessionIDs(ofTab: t2) == sessions)
        #expect(model.sessions.count == 3)
        // The source keeps its other tab selected; the workspace keeps its group.
        #expect(model.tabGroup(g1)?.selectedTabID == tabs(model, g1)[0])
        #expect(model.workspace(ws)?.selectedTabGroupID == g1)
    }

    @Test func moveTabAcrossWorkspaces() throws {
        let (model, _, g1) = makeModel()
        let t2 = try #require(model.newTab(in: g1))
        let other = model.newWorkspace(name: "Other")
        model.fillEmptyPanes()
        let otherGroup = try #require(model.workspace(other)?.tabGroups[0].id)
        model.moveTab(t2, to: otherGroup, index: 5)
        #expect(model.location(of: t2)?.workspace == other)
        #expect(tabs(model, otherGroup).last == t2)
        #expect(model.sessionIDs(in: other).count == 2)
    }

    @Test func reorderTabsWithinGroup() throws {
        let (model, _, group) = makeModel()
        let t0 = tabs(model, group)[0]
        let t1 = try #require(model.newTab(in: group))
        let t2 = try #require(model.newTab(in: group))
        // Dropping t2 onto t0 puts it where t0 was.
        model.moveTab(t2, to: group, index: 0)
        #expect(tabs(model, group) == [t2, t0, t1])
        // Dropping t2 onto t1 (index 2 before removal) puts it where t1 was.
        model.moveTab(t2, to: group, index: 2)
        #expect(tabs(model, group) == [t0, t1, t2])
    }

    @Test func closeOtherTabsKeepsOnlyThatTab() throws {
        let (model, _, group) = makeModel()
        let t0 = tabs(model, group)[0]
        let t1 = try #require(model.newTab(in: group))
        let t2 = try #require(model.newTab(in: group))
        model.fillEmptyPanes()
        let kept = model.sessionIDs(ofTab: t1)
        #expect(Set(model.closeOtherTabs(than: t1)) == [t0, t2])
        #expect(tabs(model, group) == [t1])
        #expect(model.tabGroup(group)?.selectedTabID == t1)
        #expect(model.sessions.map(\.id) == kept)
        let before = model.changeCount
        #expect(model.closeOtherTabs(than: t1).isEmpty)
        #expect(model.closeOtherTabs(than: TabID.generate()).isEmpty)
        #expect(model.changeCount == before)
    }

    @Test func selectTabByNumberWithNineMeaningLast() throws {
        let (model, ws, group) = makeModel()
        let t0 = tabs(model, group)[0]
        let t1 = try #require(model.newTab(in: group))
        let t2 = try #require(model.newTab(in: group))
        #expect(model.selectTab(number: 1, in: ws))
        #expect(model.selectedTab(in: ws)?.id == t0)
        #expect(model.selectTab(number: 2, in: ws))
        #expect(model.selectedTab(in: ws)?.id == t1)
        #expect(model.selectTab(number: 9, in: ws))
        #expect(model.selectedTab(in: ws)?.id == t2)
        #expect(!model.selectTab(number: 4, in: ws))
        #expect(!model.selectTab(number: 0, in: ws))
        #expect(model.selectedTab(in: ws)?.id == t2)
    }

    @Test func nextAndPreviousTabWrap() throws {
        let (model, ws, group) = makeModel()
        let t0 = tabs(model, group)[0]
        let t1 = try #require(model.newTab(in: group))
        let t2 = try #require(model.newTab(in: group))
        #expect(model.selectedTab(in: ws)?.id == t2)
        model.selectAdjacentTab(offset: 1, in: ws)
        #expect(model.selectedTab(in: ws)?.id == t0)
        model.selectAdjacentTab(offset: -1, in: ws)
        #expect(model.selectedTab(in: ws)?.id == t2)
        model.selectAdjacentTab(offset: -1, in: ws)
        #expect(model.selectedTab(in: ws)?.id == t1)
        model.selectAdjacentTab(offset: 4, in: ws)
        #expect(model.selectedTab(in: ws)?.id == t2)
    }

    /// A group without tabs is no longer kept by any intent; one from a
    /// hand-edited file must still not break navigation.
    @Test func adjacentTabInEmptyGroupDoesNothing() throws {
        let empty = TabGroup(name: "Empty", tabs: [])
        let g1 = empty.id
        let workspace = Workspace(name: "W", tabGroups: [empty], window: WindowState(isOpen: true))
        let ws = workspace.id
        let model = AppModel(state: PersistedState(workspaces: [workspace]), defaultWorkingDirectory: "/work")
        model.select(tabGroup: g1)
        #expect(!model.selectAdjacentTab(offset: 1, in: ws))
        #expect(!model.selectTab(number: 1, in: ws))
        #expect(model.selectedTab(in: ws) == nil)
    }

    // MARK: Panes

    /// p1 | (p2 / p3), focused p3.
    private func threePanes() throws -> (AppModel, WorkspaceID, PaneID, PaneID, PaneID) {
        let (model, ws, _) = makeModel()
        let p1 = try #require(model.selectedTab(in: ws)?.focusedPaneID)
        let p2 = try #require(model.splitFocusedPane(axis: .horizontal, in: ws))
        let p3 = try #require(model.splitFocusedPane(axis: .vertical, in: ws))
        return (model, ws, p1, p2, p3)
    }

    /// A split no longer copies the pane's profile and directory: the new
    /// pane is empty and asks (DESIGN §8 "New sessions").
    @Test func splitFocusedPaneMakesAnEmptyPane() throws {
        let (model, ws, _) = makeModel()
        let first = try #require(model.selectedTab(in: ws)?.panes.first?.sessionID)
        model.setWorkingDirectory("/repo", for: first)
        let new = try #require(model.splitFocusedPane(axis: .horizontal, in: ws))
        let tab = try #require(model.selectedTab(in: ws))
        #expect(tab.focusedPaneID == new)
        #expect(tab.pane(new)?.isEmpty == true)
        #expect(model.sessions.map(\.id) == [first])
        #expect(model.focusedSessionID(in: ws) == nil)
    }

    @Test func moveFocusByDirection() throws {
        let (model, ws, p1, p2, p3) = try threePanes()
        #expect(model.moveFocus(.up, in: ws) == p2)
        #expect(model.moveFocus(.left, in: ws) == p1)
        #expect(model.selectedTab(in: ws)?.focusedPaneID == p1)
        let before = model.changeCount
        #expect(model.moveFocus(.left, in: ws) == nil)
        #expect(model.changeCount == before)
        #expect(model.moveFocus(.right, in: ws) != nil)
        #expect(model.moveFocus(.down, in: ws) == p3)
    }

    @Test func moveFocusUnzooms() throws {
        let (model, ws, _, p2, p3) = try threePanes()
        model.toggleZoom(in: ws)
        #expect(model.selectedTab(in: ws)?.zoomedPaneID == p3)
        #expect(model.moveFocus(.up, in: ws) == p2)
        #expect(model.selectedTab(in: ws)?.zoomedPaneID == nil)
    }

    @Test func resizeFocusedPaneMovesNearestDivider() throws {
        let (model, ws, p1, _, _) = try threePanes()
        // Focused p3 is in the vertical split's second child: ⌃⌘↑ moves that
        // divider up (ratio down), ⌃⌘→ the root divider right.
        model.resizeFocusedPane(toward: .up, by: 0.1, in: ws)
        guard case .split(.horizontal, let root, _, .split(.vertical, let inner, _, _))? = model.selectedTab(in: ws)?.layout
        else { Issue.record("unexpected layout"); return }
        #expect(abs(inner - 0.4) < 1e-9)
        #expect(root == 0.5)
        model.resizeFocusedPane(toward: .right, by: 0.1, in: ws)
        guard case .split(.horizontal, let root2, _, _)? = model.selectedTab(in: ws)?.layout else { return }
        #expect(abs(root2 - 0.6) < 1e-9)
        // From p1 (first child) ⌃⌘← moves the same root divider left.
        model.focus(pane: p1)
        model.resizeFocusedPane(toward: .left, by: 0.3, in: ws)
        guard case .split(.horizontal, let root3, _, _)? = model.selectedTab(in: ws)?.layout else { return }
        #expect(abs(root3 - 0.3) < 1e-9)
        // No vertical split above p1: nothing changes.
        let before = model.changeCount
        model.resizeFocusedPane(toward: .down, in: ws)
        #expect(model.changeCount == before)
    }

    @Test func resizeClampsAndIsIgnoredWhileZoomed() throws {
        let (model, ws, _, _, _) = try threePanes()
        model.resizeFocusedPane(toward: .right, by: 5, in: ws)
        guard case .split(.horizontal, let root, _, _)? = model.selectedTab(in: ws)?.layout else { return }
        #expect(root == PaneLayout.ratioRange.upperBound)
        model.toggleZoom(in: ws)
        let layout = model.selectedTab(in: ws)?.layout
        model.resizeFocusedPane(toward: .left, by: 0.2, in: ws)
        #expect(model.selectedTab(in: ws)?.layout == layout)
    }

    @Test func equalizeResetsRatios() throws {
        let (model, ws, _, _, _) = try threePanes()
        model.resizeFocusedPane(toward: .up, by: 0.2, in: ws)
        model.resizeFocusedPane(toward: .left, by: 0.2, in: ws)
        model.equalizePanes(in: ws)
        let layout = try #require(model.selectedTab(in: ws)?.layout)
        #expect(layout == layout.equalized())
        let before = model.changeCount
        model.equalizePanes(in: ws)
        #expect(model.changeCount == before)
    }

    @Test func toggleZoomNeedsASplit() throws {
        let (model, ws, _) = makeModel()
        model.toggleZoom(in: ws)
        #expect(model.selectedTab(in: ws)?.zoomedPaneID == nil)
        let new = try #require(model.splitFocusedPane(axis: .vertical, in: ws))
        model.toggleZoom(in: ws)
        #expect(model.selectedTab(in: ws)?.zoomedPaneID == new)
        model.toggleZoom(in: ws)
        #expect(model.selectedTab(in: ws)?.zoomedPaneID == nil)
        // Splitting unzooms.
        model.toggleZoom(in: ws)
        _ = model.splitFocusedPane(axis: .horizontal, in: ws)
        #expect(model.selectedTab(in: ws)?.zoomedPaneID == nil)
    }

    @Test func setSplitRatiosAcceptsOnlyTheCurrentShape() throws {
        let (model, ws, p1, p2, p3) = try threePanes()
        let tab = try #require(model.selectedTab(in: ws))
        let dragged = PaneLayout.split(
            axis: .horizontal, ratio: 0.3, first: .pane(p1),
            second: .split(axis: .vertical, ratio: 0.95, first: .pane(p2), second: .pane(p3)))
        model.setSplitRatios(dragged, for: tab.id)
        guard case .split(_, let root, _, .split(_, let inner, _, _))? = model.selectedTab(in: ws)?.layout else {
            Issue.record("unexpected layout"); return
        }
        #expect(root == 0.3)
        #expect(inner == PaneLayout.ratioRange.upperBound)

        let before = model.changeCount
        // A stale shape (pane closed meanwhile, axes differ) is ignored.
        model.setSplitRatios(.split(axis: .vertical, ratio: 0.2, first: .pane(p1), second: .pane(p2)), for: tab.id)
        model.setSplitRatios(.pane(p1), for: tab.id)
        model.setSplitRatios(dragged, for: TabID.generate())
        #expect(model.changeCount == before)
    }

    @Test func newIntentsBumpChangeCount() throws {
        let (model, ws, g1) = makeModel()
        var last = model.changeCount
        func bumped() -> Bool { defer { last = model.changeCount }; return model.changeCount > last }
        let g2 = try #require(model.newTabGroup(in: ws)); #expect(bumped())
        model.moveTabGroup(g2, to: 0); #expect(bumped())
        model.selectTabGroup(number: 2, in: ws); #expect(bumped())
        _ = try #require(model.newTab(in: g1)); #expect(bumped())
        model.selectTab(number: 1, in: ws); #expect(bumped())
        model.selectAdjacentTab(offset: 1, in: ws); #expect(bumped())
        _ = model.splitFocusedPane(axis: .horizontal, in: ws); #expect(bumped())
        model.moveFocus(.left, in: ws); #expect(bumped())
        model.resizeFocusedPane(toward: .right, in: ws); #expect(bumped())
        model.equalizePanes(in: ws); #expect(bumped())
        model.toggleZoom(in: ws); #expect(bumped())
        let tab = try #require(model.selectedTab(in: ws)?.id)
        model.closeOtherTabs(than: tab); #expect(bumped())
        model.closeTabGroup(g2); #expect(bumped())
    }
}
