import AppKit
import Testing

/// Settings › Shortcuts is generated from the menu bar.
@Suite("Shortcut table")
@MainActor
struct ShortcutTableTests {
    private func rows() -> [ShortcutTable.Row] {
        _ = NSApplication.shared
        return ShortcutTable.rows(from: MainMenu.make(installsSpecialMenus: false))
    }

    private func shortcut(_ command: String) -> String? {
        rows().first { $0.command == command }?.shortcut
    }

    @Test func listsTheDesignShortcutsFromTheMenus() {
        #expect(shortcut("Settings…") == "⌘,")
        #expect(shortcut("New Workspace") == "⌘N")
        #expect(shortcut("New Tab Group") == "⇧⌘N")
        #expect(shortcut("New Tab") == "⌘T")
        #expect(shortcut("Split Right") == "⌘D")
        #expect(shortcut("Split Down") == "⇧⌘D")
        #expect(shortcut("Close Pane") == "⌘W")
        #expect(shortcut("Close Window") == "⇧⌘W")
        #expect(shortcut("Show Tab 1–8") == "⌘1…⌘8")
        #expect(shortcut("Show Last Tab") == "⌘9")
        #expect(shortcut("Show Tab Group 1–9") == "⇧⌘1…⇧⌘9")
        #expect(shortcut("Show Next Tab") == "⇧⌘], ⌃⇥")
        #expect(shortcut("Show Previous Tab") == "⇧⌘[, ⌃⇧⇥")
        #expect(shortcut("Focus Left Pane") == "⌥⌘←")
        #expect(shortcut("Move Divider Down") == "⌃⌘↓")
        #expect(shortcut("Zoom Pane") == "⇧⌘↩")
        #expect(shortcut("Equalize Panes") == "⌃⌘=")
        #expect(shortcut("Toggle Full Screen") == "⌘↩")
        #expect(shortcut("Clear Screen") == "⌘K")
        #expect(shortcut("Bigger") == "⌘=, ⌘+")
        #expect(shortcut("Smaller") == "⌘-")
        #expect(shortcut("Actual Size") == "⌘0")
        #expect(shortcut("Copy") == "⌘C")
        #expect(shortcut("Paste") == "⌘V")
        #expect(shortcut("Toggle Sidebar") == "⌃⌘S")
        #expect(shortcut("Respawn All Ended") == "⌥⌘R")
        #expect(shortcut("Redo") == "⇧⌘Z")
        #expect(shortcut("Next Pane Needing Attention") == "⌃⌘A")
    }

    @Test func everyRowIsInAMenuAndHiddenAlternatesAreNotRowsOfTheirOwn() {
        let table = rows()
        #expect(table.count == Set(table.map(\.id)).count)
        #expect(table.filter { $0.command == "Bigger" }.count == 1)
        #expect(table.filter { $0.command == "Show Next Tab" }.count == 1)
        #expect(!table.contains { $0.command.hasPrefix("Show Tab 3") })
        #expect(table.allSatisfy { !$0.menu.isEmpty && !$0.shortcut.isEmpty })
        #expect(table.first { $0.command == "New Tab" }?.menu == "File")
        #expect(!table.contains { $0.command.contains("New Tab with Profile") }, "removed in step 10")
    }

    /// AppKit fills the Services menu and adds window-tiling commands to the
    /// Window menu (Center is ⌃C with the Globe key); neither belongs in the
    /// table, and ⌃C must not look like an Armadale binding.
    @Test func systemItemsAreLeftOut() throws {
        _ = NSApplication.shared
        let menu = MainMenu.make(installsSpecialMenus: false)
        let appMenu = try #require(menu.items.first?.submenu)
        let services = try #require(appMenu.items.first { $0.title == "Services" }?.submenu)
        let previousServices = NSApp.servicesMenu
        NSApp.servicesMenu = services
        defer { NSApp.servicesMenu = previousServices }
        services.addItem(withTitle: "Make New Sticky Note", action: Selector(("makeStickyNote:")), keyEquivalent: "y")
            .keyEquivalentModifierMask = [.command, .shift]
        let window = try #require(menu.items.first { $0.title == "Window" }?.submenu)
        window.addItem(withTitle: "Center", action: Selector(("_zoomCenter:")), keyEquivalent: "c")
            .keyEquivalentModifierMask = [.function, .control]
        window.addItem(withTitle: "Fill", action: Selector(("_zoomFill:")), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.function, .control]

        let table = ShortcutTable.rows(from: menu)
        #expect(!table.contains { $0.command == "Make New Sticky Note" })
        #expect(!table.contains { $0.command == "Center" || $0.command == "Fill" })
        #expect(!table.contains { $0.shortcut.contains("⌃C") || $0.shortcut.contains("⌃F") })
        #expect(table.contains { $0.command == "Show Next Tab" }, "our Window menu items are still listed")
        #expect(MainMenu.isOwnItem(try #require(window.items.first)))
    }

    /// The table is Help › Keyboard Shortcuts since October 29, 2026 (it
    /// was a Settings tab): the Help item opens it, has no key equivalent
    /// of its own, and the window shows the same rows.
    @Test func helpOpensTheTableInItsOwnWindow() throws {
        _ = NSApplication.shared
        let menu = MainMenu.make(installsSpecialMenus: false)
        let help = try #require(menu.items.last?.submenu)
        #expect(help.title == "Help")
        let item = try #require(help.items.first { $0.title == "Keyboard Shortcuts" })
        #expect(item.action == #selector(AppDelegate.showKeyboardShortcuts(_:)))
        #expect(item.keyEquivalent.isEmpty)
        #expect(!rows().contains { $0.command == "Keyboard Shortcuts" })

        let controller = ShortcutsWindowController(rows: rows())
        #expect(controller.window?.title == "Keyboard Shortcuts")
        #expect(controller.window?.styleMask.contains(.resizable) == true)
        let close = NSMenuItem(title: "Close Pane", action: #selector(ShortcutsWindowController.closePane(_:)), keyEquivalent: "w")
        #expect(controller.validateMenuItem(close))
        #expect(close.title == "Close Keyboard Shortcuts")
        controller.window?.close()
    }

    @Test func theGlobeKeyIsShown() {
        #expect(ShortcutTable.display(key: "c", modifiers: [.function, .control]) == "🌐⌃C")
        #expect(ShortcutTable.display(key: "f", modifiers: [.function]) == "🌐F")
        #expect(ShortcutTable.display(key: "Z", modifiers: [.command]) == "⇧⌘Z")
    }
}
