import Foundation
import Testing
@testable import ArmadaleCore

/// A clean exit closes the pane, except the last pane of a workspace
/// (docs/DESIGN.md section 4, "Ended").
@Suite("Ended session rule")
@MainActor
struct EndedSessionRuleTests {
    @Test func whatClosesAndWhatKeepsThePlaceholder() {
        func action(_ exit: ProgramExit?, shell: Bool, last: Bool = false) -> EndedPaneAction {
            EndedSessionRule.action(exit: exit, runsShell: shell, isLastPaneInWorkspace: last)
        }
        // Status 0 closes any program's pane.
        #expect(action(.exited(0), shell: false) == .closePane)
        #expect(action(.exited(0), shell: true) == .closePane)
        // The shell's own exit closes whatever status it reports (130 after
        // ^C at the prompt, then ^D; 1 after a failed command).
        for status: Int32 in [1, 3, 127, 130, 255] {
            #expect(action(.exited(status), shell: true) == .closePane)
            #expect(action(.exited(status), shell: false) == .keepPlaceholder, "a program's failure stays readable")
        }
        // A death by signal and an unknown end keep it, shell or not.
        for exit: ProgramExit? in [.signaled(9), .signaled(2), .signaled(1), nil] {
            #expect(action(exit, shell: true) == .keepPlaceholder)
            #expect(action(exit, shell: false) == .keepPlaceholder)
        }
        // The workspace's last pane always stays.
        #expect(action(.exited(0), shell: true, last: true) == .keepPlaceholder)
        #expect(action(.exited(130), shell: true, last: true) == .keepPlaceholder)
    }

    @Test func whatCountsAsTheUsersShell() {
        #expect(EndedSessionRule.runsShell(LaunchSpec()))
        #expect(EndedSessionRule.runsShell(LaunchSpec(program: "")))
        for program in ["zsh", "/bin/zsh", "bash", "/opt/homebrew/bin/fish", "sh", "tcsh", "ksh", "dash", "nu", "-zsh"] {
            #expect(EndedSessionRule.runsShell(LaunchSpec(program: program)), "\(program)")
        }
        for program in ["claude", "/opt/homebrew/bin/codex", "vim", "zshx", "python3"] {
            #expect(!EndedSessionRule.runsShell(LaunchSpec(program: program)), "\(program)")
        }
    }

    @Test func programExitReadsAsAShellStatus() {
        let literal: ProgramExit = 3
        #expect(literal == .exited(3))
        #expect(ProgramExit.signaled(9).status == 137)
        #expect(ProgramExit.exited(130).status == 130)
    }

    private func makeModel() throws -> (AppModel, WorkspaceID, TabGroupID, Tab) {
        let model = AppModel(defaultWorkingDirectory: "/work")
        let ws = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(ws)?.tabGroups.first)
        return (model, ws, group.id, try #require(group.tabs.first))
    }

    private func session(of pane: PaneID, in model: AppModel) throws -> SessionID {
        try #require(model.tab(containing: pane)?.pane(pane)?.sessionID)
    }

    @Test func theLastPaneOfAWorkspaceStays() throws {
        let (model, _, _, tab) = try makeModel()
        let pane = tab.focusedPaneID
        #expect(model.isLastPaneInWorkspace(pane))
        #expect(model.closePaneIfSessionEndedCleanly(try session(of: pane, in: model), exit: 0) == nil)
        #expect(model.tab(containing: pane) != nil)
        #expect(!model.isLastPaneInWorkspace(PaneID.generate()), "not in the model")
    }

    /// A split pane closes alone; its sibling stays.
    @Test func aCleanExitClosesOneOfTwoPanes() throws {
        let (model, _, _, tab) = try makeModel()
        let first = tab.focusedPaneID
        let second = try #require(model.splitPane(first, axis: .vertical))
        #expect(!model.isLastPaneInWorkspace(first) && !model.isLastPaneInWorkspace(second))
        let ended = try session(of: second, in: model)
        #expect(model.closePaneIfSessionEndedCleanly(ended, exit: .signaled(15)) == nil, "a signal keeps its pane")
        #expect(model.closePaneIfSessionEndedCleanly(ended, exit: nil) == nil, "so does an unknown status")
        #expect(model.closePaneIfSessionEndedCleanly(ended, exit: 0) == second)
        #expect(model.tab(containing: second) == nil)
        #expect(model.session(ended) == nil)
        #expect(model.tab(tab.id)?.panes.map(\.id) == [first])
        // Now the survivor is the workspace's last pane.
        #expect(model.isLastPaneInWorkspace(first))
    }

    /// A failing program keeps its pane; the shell's failing exit does not.
    @Test func aShellsNonZeroExitClosesAProgramsDoesNot() throws {
        let (model, _, group, tab) = try makeModel()
        let agentTab = try #require(model.newTab(in: group, profile: Profile.claudeCode.id))
        let agent = try session(of: try #require(model.tab(agentTab)?.focusedPaneID), in: model)
        #expect(model.closePaneIfSessionEndedCleanly(agent, exit: 1) == nil)
        #expect(model.closePaneIfSessionEndedCleanly(agent, exit: .signaled(15)) == nil)
        let shell = try session(of: tab.focusedPaneID, in: model)
        #expect(model.closePaneIfSessionEndedCleanly(shell, exit: .signaled(1)) == nil)
        #expect(model.closePaneIfSessionEndedCleanly(shell, exit: 130) == tab.focusedPaneID)
        #expect(model.closePaneIfSessionEndedCleanly(agent, exit: 0) == nil, "now the workspace's last pane")
    }

    /// The last pane of a tab closes the tab (another tab remains), and the
    /// last tab of a group removes the group (another group remains).
    @Test func aCleanExitClosesTheTabAndTheGroupWhenOthersRemain() throws {
        let (model, ws, group, tab) = try makeModel()
        let secondTab = try #require(model.newTab(in: group))
        #expect(!model.isLastPaneInWorkspace(tab.focusedPaneID))
        #expect(model.closePaneIfSessionEndedCleanly(try session(of: tab.focusedPaneID, in: model), exit: 0) != nil)
        #expect(model.tab(tab.id) == nil)
        #expect(model.tabGroup(group)?.tabs.map(\.id) == [secondTab])

        let otherGroup = try #require(model.newTabGroup(in: ws))
        let pane = try #require(model.tab(secondTab)?.focusedPaneID)
        #expect(!model.isLastPaneInWorkspace(pane))
        #expect(model.closePaneIfSessionEndedCleanly(try session(of: pane, in: model), exit: 0) == pane)
        #expect(model.tabGroup(group) == nil, "the emptied group is removed")
        #expect(model.workspace(ws)?.tabGroups.map(\.id) == [otherGroup])
        #expect(model.workspace(ws)?.window?.isOpen == true, "the window stays")
    }

    /// The ending pane is the only pane of one of two tab groups: its group
    /// closes and the workspace stays (it never reaches the deletion of an
    /// emptied workspace: the last-pane rule keeps the workspace's last pane).
    @Test func aCleanExitInOneOfTwoGroupsKeepsTheWorkspace() throws {
        let (model, ws, group, tab) = try makeModel()
        let other = model.newWorkspace(name: "Other")
        let second = try #require(model.newTabGroup(in: ws, name: "Second"))
        let pane = tab.focusedPaneID
        #expect(model.closePaneIfSessionEndedCleanly(try session(of: pane, in: model), exit: 0) == pane)
        #expect(model.tabGroup(group) == nil)
        #expect(model.workspace(ws)?.tabGroups.map(\.id) == [second])
        #expect(model.workspace(ws)?.selectedTabGroupID == second)
        #expect(model.workspaces.map(\.id) == [ws, other])
        // Its last pane now stays, so the workspace cannot be emptied this way.
        let last = try #require(model.tabGroup(second)?.tabs.first?.focusedPaneID)
        #expect(model.closePaneIfSessionEndedCleanly(try session(of: last, in: model), exit: 0) == nil)
        #expect(model.workspace(ws) != nil)
    }

    /// Another workspace's panes do not count: each workspace keeps its
    /// last pane.
    @Test func eachWorkspaceKeepsItsLastPane() throws {
        let (model, _, _, tab) = try makeModel()
        let other = model.newWorkspace(name: "Other")
        let otherPane = try #require(model.workspace(other)?.tabGroups.first?.tabs.first?.focusedPaneID)
        #expect(model.isLastPaneInWorkspace(tab.focusedPaneID))
        #expect(model.isLastPaneInWorkspace(otherPane))
    }
}
