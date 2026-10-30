import ArmadaleCore
import Testing
@testable import Armadale

/// Sidebar icon colours (DESIGN §1, October 29, 2026): accent only in an
/// active window and only on its shown path; gray everywhere else.
@Suite("Sidebar icon tint")
@MainActor
struct SidebarIconTintTests {
    @Test func onlyTheShownPathOfAnActiveWindowIsAccented() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace()
        let other = model.newWorkspace()
        let shownGroup = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let otherGroup = try #require(model.newTabGroup(in: workspace))
        model.select(tabGroup: shownGroup)
        let shownTab = try #require(model.tabGroup(shownGroup)?.selectedTabID)
        let secondTab = try #require(model.newTab(in: shownGroup))
        model.select(tab: shownTab)
        let otherGroupTab = try #require(model.tabGroup(otherGroup)?.selectedTabID)
        let otherWorkspaceGroup = try #require(model.workspace(other)?.selectedTabGroupID)

        func accented(_ item: SidebarItem, active: Bool = true) -> Bool {
            SidebarIconTint.isAccented(item, in: model, currentWorkspaceID: workspace, isWindowActive: active)
        }
        #expect(accented(.workspace(workspace)))
        #expect(accented(.tabGroup(shownGroup)))
        #expect(accented(.tab(shownTab)))
        #expect(!accented(.tab(secondTab)), "the shown group's other tabs are gray")
        #expect(!accented(.tabGroup(otherGroup)), "the workspace's other groups are gray")
        #expect(!accented(.tab(otherGroupTab)))
        #expect(!accented(.workspace(other)), "other workspaces are gray")
        #expect(!accented(.tabGroup(otherWorkspaceGroup)))

        for item: SidebarItem in [.workspace(workspace), .tabGroup(shownGroup), .tab(shownTab)] {
            #expect(!accented(item, active: false), "an inactive window shows every icon gray")
        }
        #expect(!SidebarIconTint.isAccented(
            .workspace(workspace), in: model, currentWorkspaceID: WorkspaceID(raw: "gone"), isWindowActive: true))
    }

    /// The highlight is the deepest visible row of the shown path.
    @Test func theHighlightFollowsTheDeepestVisibleRowOfTheShownPath() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace()
        _ = model.newWorkspace()
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let tab = try #require(model.tabGroup(group)?.selectedTabID)
        _ = try #require(model.newTab(in: group))
        model.select(tab: tab)

        func row(workspaceExpanded: Bool = true, groupExpanded: Bool = true) -> SidebarItem? {
            SidebarHighlight.row(
                in: model, currentWorkspaceID: workspace,
                isWorkspaceExpanded: workspaceExpanded, isGroupExpanded: { _ in groupExpanded })
        }
        #expect(row() == .tab(tab))
        #expect(row(groupExpanded: false) == .tabGroup(group))
        #expect(row(workspaceExpanded: false) == .workspace(workspace))
        #expect(row(workspaceExpanded: false, groupExpanded: false) == .workspace(workspace))
        #expect(SidebarHighlight.row(
            in: model, currentWorkspaceID: WorkspaceID(raw: "gone"),
            isWorkspaceExpanded: true, isGroupExpanded: { _ in true }) == nil)
    }
}
