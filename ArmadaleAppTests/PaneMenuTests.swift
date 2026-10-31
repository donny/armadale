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

    private func menu(themeID: String?, userThemes: [ThemeEntry] = [], chosen: ((String?) -> Void)? = nil) -> NSMenu {
        PaneMenu.make(
            PaneMenu.Inputs(themeID: themeID, builtInThemes: ThemeCatalog.builtIns, userThemes: userThemes),
            actions: PaneMenu.Actions(chooseTheme: { chosen?($0) }))
    }

    private func themeSubmenu(_ menu: NSMenu) throws -> NSMenu {
        let item = try #require(menu.items.first { $0.identifier == PaneMenu.themeItemIdentifier })
        #expect(item.title == "Theme")
        return try #require(item.submenu)
    }

    private func rightClick() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Titles, with "—" for a separator and "✓" before the checked item.
    private func outline(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : ($0.state == .on ? "✓ " : "") + $0.title }
    }

    // MARK: Builder

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
        let submenu = try themeSubmenu(menu(themeID: "builtin.nord", userThemes: [Self.mine]) { chosen.append($0) })
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
        let submenu = try themeSubmenu(try #require(firstView.menu(for: try rightClick())))
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
        let again = try themeSubmenu(try #require(firstView.menu(for: try rightClick())))
        #expect(outline(again).filter { $0.hasPrefix("✓") } == ["✓ Dracula"])
        try #require(again.items.first as? ActionMenuItem).handler()
        #expect(model.pane(first)?.themeID == nil)
        #expect(await eventually { firstSurface.appearance.theme.name == "Gruvbox Dark" })
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

        let submenu = try themeSubmenu(try #require(view.menu(for: try rightClick())))
        #expect(submenu.items.last?.title == "Mine")
        try #require(submenu.items.last as? ActionMenuItem).handler()
        #expect(model.pane(pane)?.themeID == imported.entry.id)
        #expect(await eventually { surface.appearance.theme.background == TerminalColor(hex: 0x123456) })

        try settings.removeUserTheme(imported.entry.id, model: model)
        #expect(model.pane(pane)?.themeID == nil)
        #expect(await eventually { surface.appearance.theme.name == "Nord" })
    }

    /// A Control-click (without Command) on an empty pane is taken by the
    /// pane for its menu, not by the chooser; any other click still reaches
    /// the chooser. (The hit test reads `NSApp.currentEvent`, which a unit
    /// test cannot set, so only the rule and the ordinary path are tested.)
    @Test func anEmptyPaneTakesOnlyControlClicksForItsMenu() throws {
        func click(_ modifiers: NSEvent.ModifierFlags, _ type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 20, y: 20), modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        #expect(EmptyPaneView.takesContextClick(try click([.control])))
        #expect(EmptyPaneView.takesContextClick(try click([.control, .option])))
        #expect(!EmptyPaneView.takesContextClick(try click([.control, .command])), "⌘ keeps a click")
        #expect(!EmptyPaneView.takesContextClick(try click([])))
        #expect(!EmptyPaneView.takesContextClick(try click([.control], .leftMouseUp)))
        #expect(!EmptyPaneView.takesContextClick(nil))

        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let (model, registry, workspace) = makeRegistry(settings: settings)
        let actions = WorkspaceActions(model: model, registry: registry, workspaceID: workspace)
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let view = EmptyPaneView(
            chooser: NewSessionChooser(model: model, paneID: pane, actions: actions), settings: settings,
            theme: .pane(pane, in: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        // The card's centre: a button or the card itself, inside the chooser.
        let hit = try #require(view.hitTest(NSPoint(x: 320, y: 200)))
        #expect(hit !== view, "without a Control-click the chooser gets the click: \(hit)")
        #expect(hit.isDescendant(of: view))
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

        let submenu = try themeSubmenu(try #require(view.menu(for: try rightClick())))
        try #require(submenu.items.first { $0.title == "Dracula" } as? ActionMenuItem).handler()
        #expect(await eventually { background(of: view) == ThemeCatalog.dracula.background })
        #expect(view.appearance?.name == .darkAqua, "the chooser is drawn to suit a dark theme")

        let second = try themeSubmenu(try #require(view.menu(for: try rightClick())))
        try #require(second.items.first { $0.title == "Armadale Light" } as? ActionMenuItem).handler()
        #expect(await eventually { background(of: view) == ThemeCatalog.armadaleLight.background })
        #expect(view.appearance?.name == .aqua, "and a light one")

        let third = try themeSubmenu(try #require(view.menu(for: try rightClick())))
        try #require(third.items.first as? ActionMenuItem).handler()
        #expect(await eventually { background(of: view) == ThemeCatalog.nord.background })
        #expect(view.appearance == nil, "Default follows the window again")
    }
}
