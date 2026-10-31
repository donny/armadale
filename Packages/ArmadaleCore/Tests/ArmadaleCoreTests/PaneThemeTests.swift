import Foundation
import Testing
@testable import ArmadaleCore

/// A pane's own theme (DESIGN §8, "Pane context menu"): `Pane.themeID`,
/// `setTheme(_:forPane:)`, `forgetTheme(_:)`, and how it is saved.
@Suite("Pane themes")
@MainActor
struct PaneThemeTests {
    /// A workspace with one pane running the shell.
    private func onePane() throws -> (AppModel, WorkspaceID, PaneID) {
        let model = AppModel(defaultWorkingDirectory: "/Users/me")
        let ws = model.newWorkspace(name: "W")
        let pane = try #require(model.emptyPaneIDs(in: ws).first)
        _ = try #require(model.startSession(in: pane, request: SessionRequest()))
        return (model, ws, pane)
    }

    @Test func aNewPaneFollowsTheSettings() throws {
        let (model, _, pane) = try onePane()
        #expect(model.pane(pane)?.themeID == nil)
    }

    @Test func settingAThemeSavesOnceAndIsANoOpWhenUnchanged() throws {
        let (model, _, pane) = try onePane()
        var count = model.changeCount
        model.setTheme("builtin.dracula", forPane: pane)
        #expect(model.pane(pane)?.themeID == "builtin.dracula")
        #expect(model.changeCount == count + 1)

        count = model.changeCount
        model.setTheme("builtin.dracula", forPane: pane)
        #expect(model.changeCount == count, "same theme: nothing saved")

        model.setTheme(nil, forPane: pane)
        #expect(model.pane(pane)?.themeID == nil)
        #expect(model.changeCount == count + 1)

        count = model.changeCount
        model.setTheme(nil, forPane: pane)
        model.setTheme("  ", forPane: pane)
        #expect(model.pane(pane)?.themeID == nil, "a blank ID means the Settings choice")
        #expect(model.changeCount == count)

        model.setTheme("builtin.nord", forPane: PaneID.generate())
        #expect(model.changeCount == count, "unknown pane")
    }

    @Test func anIDIsTrimmed() throws {
        let (model, _, pane) = try onePane()
        model.setTheme("  builtin.dracula\n", forPane: pane)
        #expect(model.pane(pane)?.themeID == "builtin.dracula")
        let count = model.changeCount
        model.setTheme("builtin.dracula ", forPane: pane)
        #expect(model.changeCount == count, "the same theme once trimmed: nothing saved")
        model.setTheme(" \t\n", forPane: pane)
        #expect(model.pane(pane)?.themeID == nil, "blank once trimmed means the Settings choice")
        #expect(model.changeCount == count + 1)
    }

    @Test func onlyThatPaneChanges() throws {
        let (model, ws, pane) = try onePane()
        let other = try #require(model.splitPane(pane, axis: .vertical))
        model.setTheme("builtin.dracula", forPane: other)
        #expect(model.pane(pane)?.themeID == nil)
        #expect(model.pane(other)?.themeID == "builtin.dracula")
        #expect(model.emptyPaneIDs(in: ws) == [other], "an empty pane can have a theme too")
    }

    /// A split's new pane starts on the Settings choice, whatever the
    /// split pane uses.
    @Test func aSplitDoesNotCopyTheTheme() throws {
        let (model, _, pane) = try onePane()
        model.setTheme("builtin.dracula", forPane: pane)
        let other = try #require(model.splitPane(pane, axis: .horizontal))
        #expect(model.pane(other)?.themeID == nil)
    }

    @Test func theThemeSurvivesARespawnAndATabMove() throws {
        let (model, ws, pane) = try onePane()
        model.setTheme("builtin.nord", forPane: pane)
        let old = try #require(model.pane(pane)?.sessionID.flatMap { model.session($0) })
        let fresh = Session(
            location: old.location, profileID: old.profileID, launch: old.launch, workingDirectory: old.workingDirectory)
        model.replaceSession(old.id, with: fresh)
        #expect(model.pane(pane)?.sessionID == fresh.id)
        #expect(model.pane(pane)?.themeID == "builtin.nord")
        #expect(model.pane(showing: fresh.id)?.themeID == "builtin.nord")

        let target = model.newWorkspace(name: "Target")
        let targetGroup = try #require(model.workspace(target)?.selectedTabGroupID)
        let tab = try #require(model.tab(containing: pane)?.id)
        model.moveTab(tab, to: targetGroup, index: Int.max)
        #expect(model.workspace(ws) == nil)
        #expect(model.tab(containing: pane)?.id == tab)
        #expect(model.pane(pane)?.themeID == "builtin.nord")
    }

    @Test func forgettingAThemeClearsEveryPaneNamingIt() throws {
        let (model, ws, pane) = try onePane()
        let second = try #require(model.splitPane(pane, axis: .vertical))
        let third = try #require(model.splitPane(second, axis: .horizontal))
        let group = try #require(model.workspace(ws)?.selectedTabGroupID)
        let elsewhere = try #require(model.newTab(in: group))
        let elsewherePane = try #require(model.tab(elsewhere)?.focusedPaneID)
        model.setTheme("user.mine", forPane: pane)
        model.setTheme("User.Mine", forPane: second)
        model.setTheme("builtin.dracula", forPane: third)
        model.setTheme("user.mine", forPane: elsewherePane)

        let count = model.changeCount
        model.forgetTheme("user.MINE")
        #expect(model.pane(pane)?.themeID == nil)
        #expect(model.pane(second)?.themeID == nil, "matched case-insensitively")
        #expect(model.pane(third)?.themeID == "builtin.dracula")
        #expect(model.pane(elsewherePane)?.themeID == nil, "in every tab")
        #expect(model.changeCount == count + 1, "saved once")

        model.forgetTheme("user.mine")
        model.forgetTheme("user.other")
        #expect(model.changeCount == count + 1, "nothing named it: nothing saved")
    }

    // MARK: State format

    /// The theme is saved with the pane and comes back; a pane without one
    /// has no `themeID` key, so files from before it are unchanged.
    @Test func theThemeRoundTripsAndIsOmittedWhenUnset() throws {
        let (model, ws, pane) = try onePane()
        let plain = try #require(model.splitPane(pane, axis: .vertical))
        model.setTheme("builtin.gruvbox-dark", forPane: pane)

        let data = try StateStore.encode(model.persistedState)
        let decoded = try StateStore.decode(data)
        let (repaired, issues) = decoded.repaired()
        #expect(issues.isEmpty)
        let restored = AppModel(state: repaired)
        #expect(restored.pane(pane)?.themeID == "builtin.gruvbox-dark")
        #expect(restored.pane(plain)?.themeID == nil)
        #expect(restored.emptyPaneIDs(in: ws) == [plain])

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let workspaces = try #require(object["workspaces"] as? [[String: Any]])
        let groups = try #require(workspaces.first?["tabGroups"] as? [[String: Any]])
        let tabs = try #require(groups.first?["tabs"] as? [[String: Any]])
        let panes = try #require(tabs.first?["panes"] as? [[String: Any]])
        #expect(panes.first { $0["id"] as? String == pane.raw }?["themeID"] as? String == "builtin.gruvbox-dark")
        let plainRecord = try #require(panes.first { $0["id"] as? String == plain.raw })
        #expect(plainRecord["themeID"] == nil)
    }

    @Test func aPaneRecordWithoutTheKeyDecodes() throws {
        let pane = try JSONDecoder().decode(
            Pane.self, from: Data(#"{"id":"ffffffffffffffff","sessionID":"aaaaaaaaaaaaaaaa"}"#.utf8))
        #expect(pane.themeID == nil)
        #expect(pane.sessionID == SessionID(raw: "aaaaaaaaaaaaaaaa"))
        let themed = try JSONDecoder().decode(
            Pane.self, from: Data(#"{"id":"ffffffffffffffff","themeID":"builtin.nord"}"#.utf8))
        #expect(themed.themeID == "builtin.nord")
        #expect(themed.isEmpty)
    }

    /// The repair that empties a pane whose session is missing keeps the
    /// pane's theme.
    @Test func repairKeepsTheThemeOfAnEmptiedPane() throws {
        let (model, _, pane) = try onePane()
        model.setTheme("builtin.nord", forPane: pane)
        var state = model.persistedState
        state.sessions = []
        let (repaired, issues) = state.repaired()
        #expect(!issues.isEmpty)
        let record = try #require(repaired.workspaces.first?.tabGroups.first?.tabs.first?.pane(pane))
        #expect(record.isEmpty)
        #expect(record.themeID == "builtin.nord")
    }
}
