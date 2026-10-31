import ArmadaleCore
import SwiftUI
import Testing
@testable import Armadale

/// The sidebar's shown path (DESIGN §1, October 29 and 30, 2026): its rows
/// are semibold in every window; their icons are accent-coloured only in
/// an active window; everything else is regular and gray.
@Suite("Sidebar shown path")
@MainActor
struct SidebarShownPathTests {
    @Test func onlyTheShownPathIsEmphasised() throws {
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

        func shown(_ item: SidebarItem) -> Bool {
            SidebarShownPath.contains(item, in: model, currentWorkspaceID: workspace)
        }
        func accented(_ item: SidebarItem, active: Bool = true) -> Bool {
            SidebarShownPath.isAccented(item, in: model, currentWorkspaceID: workspace, isWindowActive: active)
        }
        for item: SidebarItem in [.workspace(workspace), .tabGroup(shownGroup), .tab(shownTab)] {
            #expect(shown(item))
            #expect(accented(item))
            #expect(!accented(item, active: false), "an inactive window shows every icon gray")
        }
        #expect(!shown(.tab(secondTab)), "the shown group's other tabs are not on the path")
        #expect(!accented(.tab(secondTab)))
        #expect(!shown(.tabGroup(otherGroup)), "the workspace's other groups are not on the path")
        #expect(!accented(.tabGroup(otherGroup)))
        #expect(!shown(.tab(otherGroupTab)))
        #expect(!accented(.tab(otherGroupTab)))
        #expect(!shown(.workspace(other)), "other workspaces are not on the path")
        #expect(!accented(.workspace(other)))
        #expect(!shown(.tabGroup(otherWorkspaceGroup)))
        #expect(!accented(.tabGroup(otherWorkspaceGroup)))

        let gone = WorkspaceID(raw: "gone")
        #expect(!SidebarShownPath.contains(.workspace(workspace), in: model, currentWorkspaceID: gone))
        #expect(!SidebarShownPath.isAccented(
            .workspace(workspace), in: model, currentWorkspaceID: gone, isWindowActive: true))
    }

    /// Tab group rows show ⇧⌘1…⇧⌘9 (owner's decision, October 30, 2026),
    /// nothing from the tenth group on.
    @Test func tabGroupRowsShowTheirShortcut() {
        #expect(SidebarShortcut.tabGroup(number: 1) == "⇧⌘1")
        #expect(SidebarShortcut.tabGroup(number: 9) == "⇧⌘9")
        #expect(SidebarShortcut.tabGroup(number: 10) == nil)
        #expect(SidebarShortcut.tabGroup(number: 0) == nil)
    }

    @Test func theShownPathIsSemiboldAndTheRestRegular() {
        #expect(SidebarShownPath.font(isShown: true) == Font.body.weight(.semibold))
        #expect(SidebarShownPath.font(isShown: false) == Font.body.weight(.regular))
        #expect(SidebarShownPath.color(isAccented: true) == Color.accentColor)
        #expect(SidebarShownPath.color(isAccented: false) == Color.secondary)
    }
}
