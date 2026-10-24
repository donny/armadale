import Foundation
import Testing
@testable import ArmadaleCore

@Suite("PersistedState.repaired")
struct RepairTests {
    private let session = SessionID.generate()

    private func tab(layout: PaneLayout, panes: [PaneID], focus: PaneID, zoom: PaneID? = nil) -> Tab {
        Tab(layout: layout, panes: panes.map { Pane(id: $0, sessionID: session) }, focusedPaneID: focus, zoomedPaneID: zoom)
    }

    /// The session every pane of ``tab(layout:panes:focus:zoom:)`` shows.
    private var sessionRecord: Session {
        Session(id: session, profileID: Profile.shell.id, launch: LaunchSpec(), workingDirectory: "/")
    }

    private func state(with tabs: [Tab]) -> PersistedState {
        PersistedState(
            workspaces: [Workspace(name: "W", tabGroups: [TabGroup(name: "G", tabs: tabs)])],
            sessions: [sessionRecord])
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

    /// A group whose tabs were all dropped goes too, and a closed workspace
    /// left without groups after that; an open one is kept (opening it
    /// makes a fresh group).
    @Test func emptiedGroupsAndClosedWorkspacesAreDropped() throws {
        let (p, q) = (PaneID.generate(), PaneID.generate())
        let good = tab(layout: .pane(p), panes: [p], focus: p)
        let broken = tab(layout: .pane(q), panes: [], focus: q)
        let emptied = TabGroup(name: "Broken", tabs: [broken])
        let kept = TabGroup(name: "Good", tabs: [good])
        let alreadyEmpty = TabGroup(name: "Empty", tabs: [])
        let mixed = Workspace(name: "Mixed", tabGroups: [emptied, kept, alreadyEmpty], selectedTabGroupID: emptied.id)
        let closed = Workspace(
            name: "Closed", tabGroups: [TabGroup(name: "Empty too", tabs: [])], window: WindowState(isOpen: false))
        let open = Workspace(name: "Open", tabGroups: [TabGroup(name: "Empty three", tabs: [])],
                             window: WindowState(isOpen: true))
        let (repaired, issues) = PersistedState(workspaces: [mixed, closed, open], sessions: [sessionRecord]).repaired()
        #expect(repaired.workspaces.map(\.id) == [mixed.id, open.id])
        #expect(repaired.workspaces[0].tabGroups.map(\.id) == [kept.id])
        #expect(repaired.workspaces[0].selectedTabGroupID == kept.id)
        #expect(repaired.workspaces[1].tabGroups.isEmpty)
        #expect(repaired.workspaces[1].selectedTabGroupID == nil)
        #expect(issues.contains("Dropped closed workspace \(closed.id) with no tab groups"))
        #expect(issues.filter { $0.hasPrefix("Dropped tab group") }.count == 4)
    }

    /// A closed workspace whose only group is a duplicate of an earlier one
    /// is dropped once the duplicate is.
    @Test func aClosedWorkspaceEmptiedByDuplicateRemovalIsDropped() throws {
        let p = PaneID.generate()
        let group = TabGroup(name: "G", tabs: [tab(layout: .pane(p), panes: [p], focus: p)])
        let first = Workspace(name: "First", tabGroups: [group])
        let copy = Workspace(name: "Copy", tabGroups: [group], window: WindowState(isOpen: false))
        let (repaired, issues) = PersistedState(workspaces: [first, copy], sessions: [sessionRecord]).repaired()
        #expect(repaired.workspaces.map(\.id) == [first.id])
        #expect(issues.contains("Dropped duplicate tab group \(group.id)"))
        #expect(issues.contains("Dropped closed workspace \(copy.id) with no tab groups"))
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

    /// A pane whose session is not in the file becomes an empty pane (it
    /// shows the New Session chooser), logged; its tab, layout and focus
    /// stay as they were, and its neighbours keep their sessions.
    @Test func aPaneWhoseSessionIsMissingBecomesEmpty() throws {
        let (p, q) = (PaneID.generate(), PaneID.generate())
        let missing = SessionID.generate()
        let layout = PaneLayout.split(axis: .horizontal, ratio: 0.5, first: .pane(p), second: .pane(q))
        let original = Tab(
            layout: layout, panes: [Pane(id: p, sessionID: session), Pane(id: q, sessionID: missing)],
            focusedPaneID: q)
        let (repaired, issues) = state(with: [original]).repaired()
        let fixed = try #require(repaired.workspaces.first?.tabGroups.first?.tabs.first)
        #expect(fixed.layout == layout)
        #expect(fixed.focusedPaneID == q)
        #expect(fixed.pane(p)?.sessionID == session)
        #expect(fixed.pane(q)?.isEmpty == true)
        #expect(issues == ["Emptied pane \(q) whose session \(missing) is missing"])
        // Repairing again finds nothing more.
        #expect(repaired.repaired().issues.isEmpty)
    }

    /// An empty pane is kept as it is, with no issue.
    @Test func anEmptyPaneIsKept() {
        let p = PaneID.generate()
        let original = state(with: [Tab(layout: .pane(p), panes: [Pane(id: p)], focusedPaneID: p)])
        let (repaired, issues) = original.repaired()
        #expect(issues.isEmpty)
        #expect(repaired == original)
    }
}
