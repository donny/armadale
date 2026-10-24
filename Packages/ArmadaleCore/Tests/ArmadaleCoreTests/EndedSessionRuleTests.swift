import Foundation
import Testing
@testable import ArmadaleCore

/// A clean exit closes the pane, wherever it is; a workspace's only pane
/// included, which deletes the workspace (docs/DESIGN.md section 4, "Ended").
@Suite("Ended session rule")
@MainActor
struct EndedSessionRuleTests {
    @Test func whatClosesAndWhatKeepsThePlaceholder() {
        func action(_ exit: ProgramExit?, shell: Bool) -> EndedPaneAction {
            EndedSessionRule.action(exit: exit, runsShell: shell)
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
        model.fillEmptyPanes()
        let group = try #require(model.workspace(ws)?.tabGroups.first)
        return (model, ws, group.id, try #require(group.tabs.first))
    }

    /// A new tab in `group` running Claude Code.
    private func agentTab(in group: TabGroupID, of model: AppModel) throws -> TabID {
        let tab = try #require(model.newTab(in: group))
        let pane = try #require(model.tab(tab)?.focusedPaneID)
        try #require(model.startSession(in: pane, request: SessionRequest(profileID: Profile.claudeCode.id)) != nil)
        return tab
    }

    private func session(of pane: PaneID, in model: AppModel) throws -> SessionID {
        try #require(model.tab(containing: pane)?.pane(pane)?.sessionID)
    }

    /// The only pane of the only tab of the only group: a clean exit closes
    /// it, and the emptied workspace is deleted, the only one included.
    @Test func theOnlyPaneOfAWorkspaceClosesAndTheWorkspaceGoes() throws {
        let (model, ws, _, tab) = try makeModel()
        let pane = tab.focusedPaneID
        let session = try session(of: pane, in: model)
        #expect(model.closePaneIfSessionEndedCleanly(session, exit: .signaled(15)) == nil, "a signal keeps it")
        #expect(model.closePaneIfSessionEndedCleanly(session, exit: nil) == nil, "so does an unknown end")
        #expect(model.closePaneIfSessionEndedCleanly(session, exit: 3) == pane, "the shell's exit, whatever its status")
        #expect(model.workspace(ws) == nil, "the emptied workspace is deleted")
        #expect(model.workspaces.isEmpty)
        #expect(model.sessions.isEmpty)
        #expect(model.closePaneIfSessionEndedCleanly(session, exit: 0) == nil, "not in the model any more")
    }

    /// A program's failure in a workspace's only pane keeps the placeholder.
    @Test func aProgramsFailureInTheOnlyPaneKeepsIt() throws {
        let model = AppModel(defaultWorkingDirectory: "/work")
        let ws = model.newWorkspace(name: "W")
        model.fillEmptyPanes()
        let group = try #require(model.workspace(ws)?.selectedTabGroupID)
        let agentTab = try agentTab(in: group, of: model)
        let shellTab = try #require(model.workspace(ws)?.tabGroups.first?.tabs.first?.id)
        model.closeTab(shellTab)
        let agent = try session(of: try #require(model.tab(agentTab)?.focusedPaneID), in: model)
        #expect(model.closePaneIfSessionEndedCleanly(agent, exit: 1) == nil)
        #expect(model.closePaneIfSessionEndedCleanly(agent, exit: .signaled(2)) == nil)
        #expect(model.workspace(ws) != nil)
        #expect(model.closePaneIfSessionEndedCleanly(agent, exit: 0) != nil)
        #expect(model.workspace(ws) == nil)
    }

    /// A split pane closes alone; its sibling stays.
    @Test func aCleanExitClosesOneOfTwoPanes() throws {
        let (model, _, _, tab) = try makeModel()
        let first = tab.focusedPaneID
        let second = try #require(model.splitPane(first, axis: .vertical))
        model.fillEmptyPanes()
        let ended = try session(of: second, in: model)
        #expect(model.closePaneIfSessionEndedCleanly(ended, exit: .signaled(15)) == nil, "a signal keeps its pane")
        #expect(model.closePaneIfSessionEndedCleanly(ended, exit: nil) == nil, "so does an unknown status")
        #expect(model.closePaneIfSessionEndedCleanly(ended, exit: 0) == second)
        #expect(model.tab(containing: second) == nil)
        #expect(model.session(ended) == nil)
        #expect(model.tab(tab.id)?.panes.map(\.id) == [first])
    }

    /// A failing program keeps its pane; the shell's failing exit does not.
    @Test func aShellsNonZeroExitClosesAProgramsDoesNot() throws {
        let (model, ws, group, tab) = try makeModel()
        let agentTab = try agentTab(in: group, of: model)
        let agent = try session(of: try #require(model.tab(agentTab)?.focusedPaneID), in: model)
        #expect(model.closePaneIfSessionEndedCleanly(agent, exit: 1) == nil)
        #expect(model.closePaneIfSessionEndedCleanly(agent, exit: .signaled(15)) == nil)
        let shell = try session(of: tab.focusedPaneID, in: model)
        #expect(model.closePaneIfSessionEndedCleanly(shell, exit: .signaled(1)) == nil)
        #expect(model.closePaneIfSessionEndedCleanly(shell, exit: 130) == tab.focusedPaneID)
        #expect(model.closePaneIfSessionEndedCleanly(agent, exit: 0) != nil, "the workspace's last pane closes too")
        #expect(model.workspace(ws) == nil)
    }

    /// The last pane of a tab closes the tab (another tab remains), and the
    /// last tab of a group removes the group (another group remains).
    @Test func aCleanExitClosesTheTabAndTheGroupWhenOthersRemain() throws {
        let (model, ws, group, tab) = try makeModel()
        let secondTab = try #require(model.newTab(in: group))
        model.fillEmptyPanes()
        #expect(model.closePaneIfSessionEndedCleanly(try session(of: tab.focusedPaneID, in: model), exit: 0) != nil)
        #expect(model.tab(tab.id) == nil)
        #expect(model.tabGroup(group)?.tabs.map(\.id) == [secondTab])

        let otherGroup = try #require(model.newTabGroup(in: ws))
        model.fillEmptyPanes()
        let pane = try #require(model.tab(secondTab)?.focusedPaneID)
        #expect(model.closePaneIfSessionEndedCleanly(try session(of: pane, in: model), exit: 0) == pane)
        #expect(model.tabGroup(group) == nil, "the emptied group is removed")
        #expect(model.workspace(ws)?.tabGroups.map(\.id) == [otherGroup])
        #expect(model.workspace(ws)?.window?.isOpen == true, "the window stays")
    }

    /// The ending pane is the only pane of one of two tab groups: only its
    /// group goes and the workspace stays; the remaining group's last pane
    /// then takes the workspace with it, and another workspace is untouched.
    @Test func aCleanExitInOneOfTwoGroupsKeepsTheWorkspace() throws {
        let (model, ws, group, tab) = try makeModel()
        let other = model.newWorkspace(name: "Other")
        let second = try #require(model.newTabGroup(in: ws, name: "Second"))
        model.fillEmptyPanes()
        let pane = tab.focusedPaneID
        #expect(model.closePaneIfSessionEndedCleanly(try session(of: pane, in: model), exit: 0) == pane)
        #expect(model.tabGroup(group) == nil)
        #expect(model.workspace(ws)?.tabGroups.map(\.id) == [second])
        #expect(model.workspace(ws)?.selectedTabGroupID == second)
        #expect(model.workspaces.map(\.id) == [ws, other])
        let last = try #require(model.tabGroup(second)?.tabs.first?.focusedPaneID)
        #expect(model.closePaneIfSessionEndedCleanly(try session(of: last, in: model), exit: 0) == last)
        #expect(model.workspace(ws) == nil)
        #expect(model.workspaces.map(\.id) == [other])
        #expect(model.sessionIDs(in: other).count == 1)
    }
}
