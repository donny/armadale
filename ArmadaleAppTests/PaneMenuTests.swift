import AppKit
import ArmadaleCore
import ArmadaleSessions
import SwiftTermSurface
import TerminalSurface
import Testing

/// The pane context menu and a pane's own theme (DESIGN §8, "Pane context
/// menu"): the menu builder, the appearance a pane theme gives, and panes
/// re-applying it when it changes.
@Suite("Pane menu and pane themes")
@MainActor
struct PaneMenuTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<60 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private static let mine = ThemeEntry(
        id: "user.mine", theme: TerminalTheme(
            name: "Mine", ansi: TerminalTheme.defaultANSI, foreground: TerminalColor(hex: 0xfedcba),
            background: TerminalColor(hex: 0x123456), cursor: TerminalColor(hex: 0xfedcba),
            selection: TerminalColor(hex: 0x445566)),
        isBuiltIn: false)

    private func menu(
        themeID: String?, userThemes: [ThemeEntry] = [], split: ((ArmadaleCore.Axis) -> Void)? = nil,
        chosen: ((String?) -> Void)? = nil
    ) -> NSMenu {
        PaneMenu.make(
            PaneMenu.Inputs(themeID: themeID, builtInThemes: ThemeCatalog.builtIns, userThemes: userThemes),
            actions: PaneMenu.Actions(
                splitRight: { split?(.horizontal) }, splitDown: { split?(.vertical) }, chooseTheme: { chosen?($0) }))
    }

    private func themeSubmenu(_ menu: NSMenu) throws -> NSMenu {
        let item = try #require(menu.items.first { $0.identifier == PaneMenu.themeItemIdentifier })
        #expect(item.title == "Theme")
        return try #require(item.submenu)
    }

    /// Titles, with "—" for a separator and "✓" before the checked item.
    private func outline(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : ($0.state == .on ? "✓ " : "") + $0.title }
    }

    // MARK: Builder

    @Test func theMenuIsSplitRightSplitDownThenTheTheme() throws {
        var split: [ArmadaleCore.Axis] = []
        let menu = menu(themeID: nil, split: { split.append($0) })
        #expect(outline(menu) == ["Split Right", "Split Down", "—", "Theme"])
        let right = try #require(menu.items.first { $0.identifier == PaneMenu.splitRightItemIdentifier } as? ActionMenuItem)
        let down = try #require(menu.items.first { $0.identifier == PaneMenu.splitDownItemIdentifier } as? ActionMenuItem)
        #expect(menu.items.first === right && menu.items[1] === down)
        for item in [right, down] {
            #expect(item.isEnabled)
            #expect(item.target === item)
        }
        right.handler()
        down.handler()
        #expect(split == [.horizontal, .vertical], "Split Right is a horizontal split, Split Down a vertical one")
    }

    /// The split items show the application Pane menu's shortcuts (⌘D, ⇧⌘D).
    @Test func theSplitItemsShowThePaneMenusShortcuts() throws {
        let main = MainMenu.make(installsSpecialMenus: false)
        let paneMenu = try #require(main.items.first { $0.title == "Pane" }?.submenu)
        let menu = menu(themeID: nil)
        for title in [PaneMenu.splitRightTitle, PaneMenu.splitDownTitle] {
            let mine = try #require(menu.items.first { $0.title == title })
            let app = try #require(paneMenu.items.first { $0.title == title })
            #expect(mine.keyEquivalent == app.keyEquivalent, "\(title)")
            #expect(mine.keyEquivalentModifierMask == app.keyEquivalentModifierMask, "\(title)")
        }
        #expect(menu.items[0].keyEquivalent == "d" && menu.items[0].keyEquivalentModifierMask == [.command])
        #expect(menu.items[1].keyEquivalent == "d" && menu.items[1].keyEquivalentModifierMask == [.command, .shift])
    }

    @Test func theThemeSubmenuListsDefaultThenBuiltInsThenImported() throws {
        let builtInNames = ThemeCatalog.builtIns.map(\.name)
        let plain = try themeSubmenu(menu(themeID: nil))
        #expect(outline(plain) == ["✓ Default", "—"] + builtInNames, "no imported themes: no second separator")

        let withImported = try themeSubmenu(menu(themeID: nil, userThemes: [Self.mine]))
        #expect(outline(withImported) == ["✓ Default", "—"] + builtInNames + ["—", "Mine"])
    }

    @Test func theCurrentChoiceIsChecked() throws {
        let dracula = try themeSubmenu(menu(themeID: "builtin.dracula", userThemes: [Self.mine]))
        #expect(outline(dracula).filter { $0.hasPrefix("✓") } == ["✓ Dracula"])

        let mine = try themeSubmenu(menu(themeID: "User.Mine", userThemes: [Self.mine]))
        #expect(outline(mine).filter { $0.hasPrefix("✓") } == ["✓ Mine"], "IDs match case-insensitively")

        // An ID the catalog does not know (removed outside the app) shows as Default.
        let unknown = try themeSubmenu(menu(themeID: "user.gone", userThemes: [Self.mine]))
        #expect(outline(unknown).filter { $0.hasPrefix("✓") } == ["✓ Default"])
    }

    @Test func choosingAnItemReportsItsThemeOrDefault() throws {
        var chosen: [String?] = []
        let submenu = try themeSubmenu(menu(themeID: "builtin.nord", userThemes: [Self.mine], chosen: { chosen.append($0) }))
        for title in ["Dracula", "Mine", "Default"] {
            let item = try #require(submenu.items.first { $0.title == title } as? ActionMenuItem)
            #expect(item.isEnabled)
            #expect(item.target === item)
            item.handler()
        }
        #expect(chosen == ["builtin.dracula", "user.mine", nil])
    }

    // MARK: Appearance

    @Test func aPaneThemeIsUsedInBothAppearancesAndAnUnknownOneFallsBack() {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        settings.preferences.followsSystemAppearance = true
        settings.preferences.lightThemeID = "builtin.solarized-light"
        settings.preferences.darkThemeID = "builtin.nord"
        #expect(settings.terminalAppearance(isDark: false, paneThemeID: "builtin.dracula").theme.name == "Dracula")
        #expect(settings.terminalAppearance(isDark: true, paneThemeID: "builtin.dracula").theme.name == "Dracula")
        #expect(settings.terminalAppearance(isDark: false, paneThemeID: nil).theme.name == "Solarized Light")
        #expect(settings.terminalAppearance(isDark: true, paneThemeID: nil).theme.name == "Nord")
        #expect(settings.terminalAppearance(isDark: false, paneThemeID: "user.gone").theme.name == "Solarized Light")
        #expect(settings.terminalAppearance(isDark: true, paneThemeID: "user.gone").theme.name == "Nord")
        #expect(settings.terminalAppearance(for: NSAppearance(named: .aqua)!, paneThemeID: "builtin.one-dark")
            .theme.name == "One Dark")
    }

    // MARK: Panes

    private func makeRegistry(settings: AppSettings) -> (AppModel, SessionRegistry, WorkspaceID) {
        _ = NSApplication.shared
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        model.fillEmptyPanes()
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: [],
            settings: settings)
        return (model, registry, workspace)
    }

    private func background(of view: NSView) -> TerminalColor? {
        guard let color = view.layer?.backgroundColor?.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
            let c = color.components, c.count >= 3
        else { return nil }
        return TerminalColor(red: UInt8((c[0] * 255).rounded()), green: UInt8((c[1] * 255).rounded()), blue: UInt8((c[2] * 255).rounded()))
    }

    @Test func aPaneReappliesWhenItsThemeChangesAndOnlyThatPane() async throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        settings.preferences.followsSystemAppearance = false
        settings.preferences.themeID = "builtin.nord"
        let (model, registry, workspace) = makeRegistry(settings: settings)
        let first = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let second = try #require(model.splitPane(first, axis: .vertical))
        model.fillEmptyPanes()
        let firstView = try #require(model.pane(first)?.sessionID.flatMap { registry.paneView(for: $0) })
        let secondView = try #require(model.pane(second)?.sessionID.flatMap { registry.paneView(for: $0) })
        let firstSurface = try #require(firstView.controller.surface as? SwiftTermSurface)
        let secondSurface = try #require(secondView.controller.surface as? SwiftTermSurface)
        #expect(firstSurface.appearance.theme.name == "Nord")
        try await Task.sleep(for: .milliseconds(50))

        // Chosen from the pane's own menu.
        let submenu = try themeSubmenu(firstView.paneMenu())
        #expect(submenu.items.first?.state == .on, "Default is checked")
        try #require(submenu.items.first { $0.title == "Dracula" } as? ActionMenuItem).handler()
        #expect(model.pane(first)?.themeID == "builtin.dracula")
        #expect(await eventually { firstSurface.appearance.theme.name == "Dracula" })
        #expect(await eventually { background(of: firstView) == ThemeCatalog.dracula.background }, "the padding too")
        #expect(secondSurface.appearance.theme.name == "Nord", "the other pane keeps the Settings theme")

        // The Settings theme changes only panes on Default.
        settings.preferences.themeID = "builtin.gruvbox-dark"
        #expect(await eventually { secondSurface.appearance.theme.name == "Gruvbox Dark" })
        #expect(firstSurface.appearance.theme.name == "Dracula")

        // Default returns to the Settings choice.
        let again = try themeSubmenu(firstView.paneMenu())
        #expect(outline(again).filter { $0.hasPrefix("✓") } == ["✓ Dracula"])
        try #require(again.items.first as? ActionMenuItem).handler()
        #expect(model.pane(first)?.themeID == nil)
        #expect(await eventually { firstSurface.appearance.theme.name == "Gruvbox Dark" })
    }

    /// The menu splits the pane it was opened for, not the focused one; the
    /// new pane is focused (as after ⌘D) and empty (it shows the chooser).
    @Test func theMenuSplitsItsOwnPaneNotTheFocusedOne() throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let (model, registry, workspace) = makeRegistry(settings: settings)
        let first = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let second = try #require(model.splitPane(first, axis: .horizontal))
        model.fillEmptyPanes()
        #expect(model.selectedTab(in: workspace)?.focusedPaneID == second)
        let firstView = try #require(model.pane(first)?.sessionID.flatMap { registry.paneView(for: $0) })

        let menu = firstView.paneMenu()
        try #require(menu.items.first { $0.identifier == PaneMenu.splitDownItemIdentifier } as? ActionMenuItem).handler()
        var tab = try #require(model.selectedTab(in: workspace))
        #expect(tab.layout.leaves().count == 3)
        let below = try #require(tab.layout.neighbor(of: first, direction: .down), "a new pane below the first")
        #expect(below != second)
        #expect(tab.focusedPaneID == below, "the new pane is focused")
        #expect(model.pane(below)?.isEmpty == true)
        #expect(tab.layout.neighbor(of: second, direction: .down) == nil, "the focused pane was not split")

        // Split Right from the empty pane's binding: right of that pane.
        let empty = EmptyPaneView(
            chooser: NewSessionChooser(
                model: model, paneID: below,
                actions: WorkspaceActions(model: model, registry: registry, workspaceID: workspace)),
            settings: settings, theme: .pane(below, in: model))
        model.focus(pane: first)
        try #require(empty.paneMenu().items.first { $0.identifier == PaneMenu.splitRightItemIdentifier } as? ActionMenuItem)
            .handler()
        tab = try #require(model.selectedTab(in: workspace))
        let right = try #require(tab.layout.neighbor(of: below, direction: .right))
        #expect(right != second && right != first)
        #expect(tab.focusedPaneID == right)

        // A detached binding (outside any model) splits nothing.
        PaneThemeBinding.detached.split(.horizontal)
        #expect(model.selectedTab(in: workspace)?.layout.leaves().count == 4)
    }

    @Test func aPaneViewMadeLaterStartsWithItsPanesTheme() throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let (model, registry, workspace) = makeRegistry(settings: settings)
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        model.setTheme("builtin.one-dark", forPane: pane)
        let view = try #require(model.pane(pane)?.sessionID.flatMap { registry.paneView(for: $0) })
        #expect((view.controller.surface as? SwiftTermSurface)?.appearance.theme.name == "One Dark")
    }

    @Test func removingAnImportedThemeReturnsItsPanesToDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("armadale-panemenu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = AppSettings.forTesting()
        defer { base.removeTestDefaults() }
        let settings = AppSettings(
            preferences: base.preferences, themes: ThemeCatalog(directory: root.appendingPathComponent("themes")),
            surfaces: base.surfaces)
        settings.preferences.followsSystemAppearance = false
        settings.preferences.themeID = "builtin.nord"
        let file = root.appendingPathComponent("Mine")
        try "background = #123456\nforeground = #fedcba\n".write(to: file, atomically: true, encoding: .utf8)
        let imported = try settings.themes.importGhosttyTheme(at: file)
        settings.preferences.themeID = "builtin.nord"

        let (model, registry, workspace) = makeRegistry(settings: settings)
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let view = try #require(model.pane(pane)?.sessionID.flatMap { registry.paneView(for: $0) })
        let surface = try #require(view.controller.surface as? SwiftTermSurface)
        try await Task.sleep(for: .milliseconds(50))

        let submenu = try themeSubmenu(view.paneMenu())
        #expect(submenu.items.last?.title == "Mine")
        try #require(submenu.items.last as? ActionMenuItem).handler()
        #expect(model.pane(pane)?.themeID == imported.entry.id)
        #expect(await eventually { surface.appearance.theme.background == TerminalColor(hex: 0x123456) })

        try settings.removeUserTheme(imported.entry.id, model: model)
        #expect(model.pane(pane)?.themeID == nil)
        #expect(await eventually { surface.appearance.theme.name == "Nord" })
    }

    @Test func anEmptyPaneShowsItsThemesBackground() async throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        settings.preferences.followsSystemAppearance = false
        settings.preferences.themeID = "builtin.nord"
        let (model, registry, workspace) = makeRegistry(settings: settings)
        let actions = WorkspaceActions(model: model, registry: registry, workspaceID: workspace)
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        #expect(model.pane(pane)?.isEmpty == true)
        let view = EmptyPaneView(
            chooser: NewSessionChooser(model: model, paneID: pane, actions: actions), settings: settings,
            theme: .pane(pane, in: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        #expect(background(of: view) == ThemeCatalog.nord.background)
        try await Task.sleep(for: .milliseconds(50))

        let submenu = try themeSubmenu(view.paneMenu())
        try #require(submenu.items.first { $0.title == "Dracula" } as? ActionMenuItem).handler()
        #expect(await eventually { background(of: view) == ThemeCatalog.dracula.background })
        #expect(view.appearance?.name == .darkAqua, "the chooser is drawn to suit a dark theme")

        let second = try themeSubmenu(view.paneMenu())
        try #require(second.items.first { $0.title == "Armadale Light" } as? ActionMenuItem).handler()
        #expect(await eventually { background(of: view) == ThemeCatalog.armadaleLight.background })
        #expect(view.appearance?.name == .aqua, "and a light one")

        let third = try themeSubmenu(view.paneMenu())
        try #require(third.items.first as? ActionMenuItem).handler()
        #expect(await eventually { background(of: view) == ThemeCatalog.nord.background })
        #expect(view.appearance == nil, "Default follows the window again")
    }
}
