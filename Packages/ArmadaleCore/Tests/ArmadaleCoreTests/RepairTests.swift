import Foundation
import Testing
@testable import ArmadaleCore

@Suite("PersistedState.repaired")
struct RepairTests {
    private let session = SessionID.generate()

    private func tab(layout: PaneLayout, panes: [PaneID], focus: PaneID, zoom: PaneID? = nil) -> Tab {
        Tab(layout: layout, panes: panes.map { Pane(id: $0, sessionID: session) }, focusedPaneID: focus, zoomedPaneID: zoom)
    }

    private func state(with tabs: [Tab]) -> PersistedState {
        PersistedState(workspaces: [Workspace(name: "W", tabGroups: [TabGroup(name: "G", tabs: tabs)])])
    }

    @Test func validStateIsUnchanged() {
        let p = PaneID.generate()
        let original = state(with: [tab(layout: .pane(p), panes: [p], focus: p)])
        let (repaired, issues) = original.repaired()
        #expect(issues.isEmpty)
        #expect(repaired == original)
    }

    @Test func orphanPaneRecordsAreDropped() throws {
        let (p, orphan) = (PaneID.generate(), PaneID.generate())
        let (repaired, issues) = state(with: [tab(layout: .pane(p), panes: [p, orphan], focus: p)]).repaired()
        let fixed = try #require(repaired.workspaces.first?.tabGroups.first?.tabs.first)
        #expect(fixed.panes.map(\.id) == [p])
        #expect(issues.count == 1)
    }

    @Test func leavesWithoutRecordsAreRemovedFromLayout() throws {
        let (p, q) = (PaneID.generate(), PaneID.generate())
        let layout = PaneLayout.split(axis: .horizontal, ratio: 0.5, first: .pane(p), second: .pane(q))
        let (repaired, _) = state(with: [tab(layout: layout, panes: [p], focus: q, zoom: q)]).repaired()
        let fixed = try #require(repaired.workspaces.first?.tabGroups.first?.tabs.first)
        #expect(fixed.layout == .pane(p))
        #expect(fixed.focusedPaneID == p, "focus falls back to the first leaf")
        #expect(fixed.zoomedPaneID == nil)
    }

    @Test func focusOutsideLayoutPicksFirstLeaf() throws {
        let (p, q) = (PaneID.generate(), PaneID.generate())
        let layout = PaneLayout.split(axis: .vertical, ratio: 0.5, first: .pane(p), second: .pane(q))
        let (repaired, issues) = state(with: [tab(layout: layout, panes: [p, q], focus: PaneID.generate())]).repaired()
        #expect(repaired.workspaces.first?.tabGroups.first?.tabs.first?.focusedPaneID == p)
        #expect(issues == ["Reset focused pane of tab \(repaired.workspaces[0].tabGroups[0].tabs[0].id)"])
    }

    @Test func tabWithNoValidPanesIsDroppedAndSelectionFixed() throws {
        let (p, q) = (PaneID.generate(), PaneID.generate())
        let good = tab(layout: .pane(p), panes: [p], focus: p)
        let broken = tab(layout: .pane(q), panes: [], focus: q)
        var original = state(with: [broken, good])
        original.workspaces[0].tabGroups[0].selectedTabID = broken.id
        let (repaired, _) = original.repaired()
        let group = try #require(repaired.workspaces.first?.tabGroups.first)
        #expect(group.tabs.map(\.id) == [good.id])
        #expect(group.selectedTabID == good.id)
    }

    @Test func duplicateIDsAreDropped() throws {
        let p = PaneID.generate()
        let t = tab(layout: .pane(p), panes: [p], focus: p)
        let workspace = Workspace(name: "W", tabGroups: [TabGroup(name: "G", tabs: [t, t])])
        let s = Session(id: session, profileID: Profile.shell.id, launch: LaunchSpec(), workingDirectory: "/")
        let original = PersistedState(workspaces: [workspace, workspace], sessions: [s, s])
        let (repaired, issues) = original.repaired()
        #expect(repaired.workspaces.count == 1)
        #expect(repaired.workspaces[0].tabGroups[0].tabs.count == 1)
        #expect(repaired.sessions.count == 1)
        #expect(issues.count == 3)
    }

    @Test func paneIDsAreUniqueAcrossTabs() throws {
        let p = PaneID.generate()
        let (repaired, _) = state(with: [
            tab(layout: .pane(p), panes: [p], focus: p),
            tab(layout: .pane(p), panes: [p], focus: p),
        ]).repaired()
        #expect(repaired.workspaces[0].tabGroups[0].tabs.count == 1)
    }

    @Test func dropsRepeatedLeaves() throws {
        let (p, q) = (PaneID.generate(), PaneID.generate())
        let layout = PaneLayout.split(
            axis: .horizontal, ratio: 0.5, first: .pane(p),
            second: .split(axis: .vertical, ratio: 0.5, first: .pane(q), second: .pane(p)))
        let (repaired, _) = state(with: [tab(layout: layout, panes: [p, q], focus: p)]).repaired()
        let fixed = try #require(repaired.workspaces.first?.tabGroups.first?.tabs.first)
        #expect(fixed.layout.leaves() == [p, q])
    }
}
