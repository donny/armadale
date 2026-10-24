import AppKit
import ArmadaleCore
import ArmadaleSessions
import Testing

/// Renaming in place (DESIGN §1, §8): the rules of ``InlineRename``, which
/// the sidebar's and the tab bar's text fields only feed. The fields
/// themselves are not driven here.
@Suite("Inline rename")
@MainActor
struct InlineRenameTests {
    private struct Fixture {
        let model: AppModel
        let rename: InlineRename
        let workspace: WorkspaceID
        let group: TabGroupID
        let tab: TabID
    }

    private func makeFixture() throws -> Fixture {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "Work")
        model.fillEmptyPanes()
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let tab = try #require(model.tabGroup(group)?.tabs.first?.id)
        return Fixture(model: model, rename: InlineRename(model: model), workspace: workspace, group: group, tab: tab)
    }

    @Test func aWorkspaceNameIsTrimmedAndABlankOneIgnored() throws {
        let f = try makeFixture()
        #expect(f.rename.begin(.workspace(f.workspace), on: .sidebar))
        #expect(f.rename.text == "Work", "the field starts with the name")
        f.rename.text = "  Project X \n"
        f.rename.commit()
        #expect(f.model.workspace(f.workspace)?.name == "Project X")
        #expect(f.rename.edit == nil)

        for blank in ["", "   ", "\t\n"] {
            f.rename.begin(.workspace(f.workspace), on: .sidebar)
            f.rename.text = blank
            f.rename.commit()
            #expect(f.model.workspace(f.workspace)?.name == "Project X", "blank \(blank.debugDescription) is ignored")
        }
    }

    @Test func aTabGroupNameIsTrimmedAndABlankOneIgnored() throws {
        let f = try makeFixture()
        f.rename.begin(.tabGroup(f.group), on: .sidebar)
        #expect(f.rename.text == "Main")
        f.rename.text = " Agents "
        f.rename.commit()
        #expect(f.model.tabGroup(f.group)?.name == "Agents")

        f.rename.begin(.tabGroup(f.group), on: .sidebar)
        f.rename.text = "  "
        f.rename.commit()
        #expect(f.model.tabGroup(f.group)?.name == "Agents")
    }

    @Test func aTabTitleIsTrimmedAndABlankOneRestoresTheDerivedTitle() throws {
        let f = try makeFixture()
        let derived = try #require(f.model.tab(f.tab).map(f.model.displayTitle(for:)))

        f.rename.begin(.tab(f.tab), on: .tabBar)
        #expect(f.rename.text == derived, "no custom title yet: the field starts with the derived one")
        f.rename.text = "  build  "
        f.rename.commit()
        #expect(f.model.tab(f.tab)?.customTitle == "build")

        f.rename.begin(.tab(f.tab), on: .sidebar)
        #expect(f.rename.text == "build", "the field starts with the custom title")
        f.rename.text = "   "
        f.rename.commit()
        #expect(f.model.tab(f.tab)?.customTitle == nil, "blank clears the custom title")
        #expect(f.model.tab(f.tab).map(f.model.displayTitle(for:)) == derived)
    }

    @Test func committingTheUnchangedDerivedTitleDoesNotPinIt() throws {
        let f = try makeFixture()
        f.rename.begin(.tab(f.tab), on: .tabBar)
        f.rename.commit()
        #expect(f.model.tab(f.tab)?.customTitle == nil)

        let before = f.model.changeCount
        f.rename.begin(.workspace(f.workspace), on: .sidebar)
        f.rename.text = " Work "
        f.rename.commit()
        #expect(f.model.changeCount == before, "an unchanged name changes nothing")
    }

    @Test func startingAnotherEditCommitsTheCurrentOne() throws {
        let f = try makeFixture()
        f.rename.begin(.tabGroup(f.group), on: .sidebar)
        let first = try #require(f.rename.edit)
        f.rename.text = "Servers"
        #expect(f.rename.begin(.tab(f.tab), on: .tabBar))
        #expect(f.model.tabGroup(f.group)?.name == "Servers")
        let second = try #require(f.rename.edit)
        #expect(second.item == .tab(f.tab) && second.surface == .tabBar && second.id != first.id)
        #expect(f.rename.edit(of: .tabGroup(f.group), on: .sidebar) == nil)
        #expect(f.rename.edit(of: .tab(f.tab), on: .sidebar) == nil, "only on the surface it started on")
        #expect(f.rename.edit(of: .tab(f.tab), on: .tabBar) == second)

        // The first field going away afterwards ends nothing.
        f.rename.end(first.id, commit: false)
        #expect(f.rename.edit == second)
    }

    @Test func renamingAnItemAgainOnTheSameSurfaceKeepsTheEdit() throws {
        let f = try makeFixture()
        f.rename.begin(.workspace(f.workspace), on: .sidebar)
        let edit = try #require(f.rename.edit)
        f.rename.text = "Half typ"
        #expect(f.rename.begin(.workspace(f.workspace), on: .sidebar))
        #expect(f.rename.edit == edit)
        #expect(f.rename.text == "Half typ")
        #expect(f.model.workspace(f.workspace)?.name == "Work")
    }

    @Test func cancellingRestoresTheOldName() throws {
        let f = try makeFixture()
        f.rename.begin(.workspace(f.workspace), on: .sidebar)
        let edit = try #require(f.rename.edit)
        f.rename.text = "Something else"
        f.rename.end(edit.id, commit: false)
        #expect(f.rename.edit == nil)
        #expect(f.model.workspace(f.workspace)?.name == "Work")

        f.rename.begin(.tab(f.tab), on: .tabBar)
        f.rename.text = "x"
        f.rename.cancel()
        #expect(f.model.tab(f.tab)?.customTitle == nil)
    }

    @Test func endingCommitsOnlyTheEditUnderWay() throws {
        let f = try makeFixture()
        f.rename.begin(.tabGroup(f.group), on: .sidebar)
        let edit = try #require(f.rename.edit)
        f.rename.text = "Logs"
        f.rename.end(edit.id + 1, commit: true)
        #expect(f.rename.edit == edit, "another field's id ends nothing")
        f.rename.end(edit.id, commit: true)
        #expect(f.rename.edit == nil)
        #expect(f.model.tabGroup(f.group)?.name == "Logs")
        f.rename.end(edit.id, commit: true)
        #expect(f.model.tabGroup(f.group)?.name == "Logs", "ending twice is harmless")
    }

    @Test func aMissingItemStartsNoEdit() throws {
        let f = try makeFixture()
        f.rename.begin(.workspace(f.workspace), on: .sidebar)
        let edit = try #require(f.rename.edit)
        #expect(!f.rename.begin(.tab(TabID.generate()), on: .tabBar))
        #expect(f.rename.edit == edit, "the edit under way goes on")

        // An item that goes away while being edited: committing is harmless.
        f.rename.begin(.tab(f.tab), on: .tabBar)
        f.rename.text = "gone"
        f.model.closeTab(f.tab)
        f.rename.commit()
        #expect(f.rename.edit == nil)
    }

    @Test func whitespaceRunsBecomeOneSpace() throws {
        #expect(InlineRename.normalized(" a\n\tb  c \r\n") == "a b c")
        #expect(InlineRename.committedName("x\ny", original: "z", allowsEmpty: false) == "x y")
        #expect(InlineRename.committedName("\n\t ", original: "z", allowsEmpty: false) == nil)
        #expect(InlineRename.committedName("a  b", original: "a b", allowsEmpty: false) == nil, "unchanged once normalised")

        let f = try makeFixture()
        f.rename.begin(.tabGroup(f.group), on: .sidebar)
        f.rename.text = "Build\n\tlogs\u{2028}today"
        f.rename.commit()
        #expect(f.model.tabGroup(f.group)?.name == "Build logs today")
    }

    /// Chained edits (Rename chosen from another item's context menu while
    /// a field is open) keep the place focus returns to from the first one;
    /// a rename field or a window is never that place.
    @Test func theReturnPlaceSurvivesChainedEdits() throws {
        _ = NSApplication.shared
        let f = try makeFixture()
        let terminal = NSView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(terminal)
        var fallbacks = 0
        f.rename.focusFallback = { fallbacks += 1 }

        f.rename.begin(.tabGroup(f.group), on: .sidebar)
        f.rename.offerReturnFocus(window)
        #expect(f.rename.returnFocus == nil, "a window is not a return place")
        f.rename.offerReturnFocus(terminal)
        #expect(f.rename.returnFocus === terminal)

        // The second field sees the first one's field: neither replaces it.
        f.rename.begin(.tab(f.tab), on: .tabBar)
        let oldField = RenameTextField(string: "")
        f.rename.offerReturnFocus(oldField)
        #expect(f.rename.returnFocus === terminal)
        f.rename.commit()
        #expect(f.rename.returnFocus === terminal, "kept for the field's teardown")

        // A fresh edit forgets it; a rename field is never recorded.
        f.rename.begin(.workspace(f.workspace), on: .sidebar)
        #expect(f.rename.returnFocus == nil)
        f.rename.offerReturnFocus(oldField)
        #expect(f.rename.returnFocus == nil)

        // Nothing to return to: the terminal fallback.
        f.rename.restoreFocus(in: window)
        #expect(fallbacks == 1)
        // A return place in another window: the fallback too.
        let elsewhere = NSView()
        f.rename.offerReturnFocus(elsewhere)
        #expect(f.rename.returnFocus === elsewhere)
        f.rename.restoreFocus(in: window)
        #expect(fallbacks == 2)
        f.rename.cancel()
    }

    /// SwiftUI can recreate a field mid-edit; the old one's teardown must
    /// then not end the edit. A field gone with no replacement commits.
    @Test func teardownEndsTheEditOnlyWithoutAReplacementField() throws {
        let f = try makeFixture()
        f.rename.begin(.tabGroup(f.group), on: .sidebar)
        let edit = try #require(f.rename.edit)
        let fields = (NSObject(), NSObject())
        let old = ObjectIdentifier(fields.0)
        let replacement = ObjectIdentifier(fields.1)
        f.rename.registerField(old, for: edit.id)
        f.rename.text = "Typed"

        f.rename.registerField(replacement, for: edit.id)
        f.rename.unregisterField(old, for: edit.id)
        f.rename.endIfNoField(edit.id)
        #expect(f.rename.edit == edit, "the replacement field goes on editing")

        f.rename.unregisterField(replacement, for: edit.id)
        f.rename.endIfNoField(edit.id)
        #expect(f.rename.edit == nil)
        #expect(f.model.tabGroup(f.group)?.name == "Typed")

        // A later edit is not ended by an earlier edit's teardown.
        f.rename.begin(.workspace(f.workspace), on: .sidebar)
        f.rename.endIfNoField(edit.id)
        #expect(f.rename.edit?.item == .workspace(f.workspace))
        withExtendedLifetime(fields) {}
    }

    /// Names are taken literally: the field edits with its own field
    /// editor, every automatic substitution off.
    @Test func theFieldEditsWithoutSubstitutions() throws {
        _ = NSApplication.shared
        let field = RenameTextField(string: "x")
        let cell = try #require(field.cell as? RenameTextFieldCell)
        #expect(cell.isEditable)
        let editor = try #require(cell.fieldEditor(for: field))
        #expect(editor is RenameFieldEditor && editor.isFieldEditor)
        #expect(cell.fieldEditor(for: field) === editor, "one per field")
        #expect(!editor.isAutomaticTextReplacementEnabled && !editor.isAutomaticSpellingCorrectionEnabled)
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled && !editor.isAutomaticDashSubstitutionEnabled)
        #expect(!editor.isAutomaticTextCompletionEnabled && !editor.isAutomaticDataDetectionEnabled)
        #expect(!editor.isAutomaticLinkDetectionEnabled && editor.enabledTextCheckingTypes == 0)

        // A borrowed (shared) editor gets its settings back.
        let shared = NSTextView()
        shared.isAutomaticQuoteSubstitutionEnabled = true
        shared.isAutomaticTextReplacementEnabled = true
        let saved = TextSubstitutions(of: shared)
        TextSubstitutions.none.apply(to: shared)
        #expect(!shared.isAutomaticQuoteSubstitutionEnabled)
        saved.apply(to: shared)
        #expect(shared.isAutomaticQuoteSubstitutionEnabled && shared.isAutomaticTextReplacementEnabled)
    }

    @Test func thePeriodOnDoubleSpaceIsUndone() {
        #expect(RenameFieldEditor.substitutionOverride(inserted: ". ", replacedText: " ") == "  ")
        #expect(RenameFieldEditor.substitutionOverride(inserted: ". x", replacedText: " ") == "  x")
        #expect(RenameFieldEditor.substitutionOverride(inserted: ".", replacedText: "") == nil)
        #expect(RenameFieldEditor.substitutionOverride(inserted: ". ", replacedText: "a") == nil)
        #expect(RenameFieldEditor.substitutionOverride(inserted: "a", replacedText: " ") == nil)
    }

    @Test func theWindowHandsARenameFieldItsOwnEditor() throws {
        _ = NSApplication.shared
        let field = RenameTextField(string: "x")
        let editor = try #require(field.privateFieldEditor)
        #expect(editor is RenameFieldEditor)
        #expect(field.privateFieldEditor === editor)
    }

    @Test func theCommitRules() {
        #expect(InlineRename.committedName(" a ", original: "b", allowsEmpty: false) == "a")
        #expect(InlineRename.committedName("  ", original: "b", allowsEmpty: false) == nil)
        #expect(InlineRename.committedName("  ", original: "b", allowsEmpty: true) == "")
        #expect(InlineRename.committedName(" b", original: "b", allowsEmpty: true) == nil)
        #expect(InlineRename.committedName("", original: "", allowsEmpty: true) == nil)
    }

    /// The tab bar and a sidebar with no other workspace's window in front
    /// edit in their own window.
    @Test func aWindowEditsInItsOwnSurfaces() throws {
        _ = NSApplication.shared
        let f = try makeFixture()
        let other = f.model.newWorkspace(name: "Other")
        f.model.fillEmptyPanes()
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let registry = SessionRegistry(
            model: f.model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: [],
            settings: settings)
        let actions = WorkspaceActions(model: f.model, registry: registry, workspaceID: f.workspace)
        let otherActions = WorkspaceActions(model: f.model, registry: registry, workspaceID: other)
        actions.actionsOfWorkspace = { $0 == other ? otherActions : nil }

        actions.beginRename(.tab(f.tab), on: .tabBar)
        #expect(actions.rename.edit(of: .tab(f.tab), on: .tabBar) != nil)
        // Another workspace's row while its window is not key (here it has
        // none): edited where it was asked for, committing the tab's edit.
        actions.rename.text = "renamed"
        actions.beginRename(.workspace(other), on: .sidebar)
        #expect(f.model.tab(f.tab)?.customTitle == "renamed")
        #expect(actions.rename.edit(of: .workspace(other), on: .sidebar) != nil)
        #expect(otherActions.rename.edit == nil)
    }
}

/// Renaming is inline only: the Workspace menu has no rename items, and
/// the shortcut table (which never listed them: they had no key) is as it was.
@Suite("Workspace menu")
@MainActor
struct WorkspaceMenuTests {
    @Test func hasNoRenameItems() throws {
        _ = NSApplication.shared
        let menu = MainMenu.make(installsSpecialMenus: false)
        let workspace = try #require(menu.items.first { $0.title == "Workspace" }?.submenu)
        #expect(workspace.items.map { $0.isSeparatorItem ? "-" : $0.title }
            == ["Respawn All Ended", "-", "Delete Workspace…"])

        func titles(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) }
        }
        #expect(!titles(menu).contains { $0.localizedCaseInsensitiveContains("rename") })

        let rows = ShortcutTable.rows(from: menu)
        #expect(rows.filter { $0.menu == "Workspace" }.map(\.command) == ["Respawn All Ended"])
        #expect(!rows.contains { $0.command.localizedCaseInsensitiveContains("rename") })
    }
}
