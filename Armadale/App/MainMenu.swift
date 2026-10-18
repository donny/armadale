import AppKit
import ArmadaleCore

/// Builds the main menu in code (there is no nib). Every shortcut of
/// DESIGN §9 is a menu key equivalent, so it shows in the menus and works
/// whatever has keyboard focus; keys that are not bound here reach the
/// terminal. Workspace commands are nil-targeted and land on the key
/// window's ``WorkspaceWindowController``; app-wide ones on ``AppDelegate``.
///
/// This is also the shortcut table: Settings › Shortcuts is generated from
/// the menu this builds (``ShortcutTable``), so the two cannot disagree.
@MainActor
enum MainMenu {
    /// Identifier of File › New Tab with Profile, whose items are filled in
    /// by `profileMenuDelegate` each time it opens.
    static let newTabWithProfileIdentifier = NSUserInterfaceItemIdentifier("newTabWithProfile")
    /// Identifier of File › New Tab on Host, filled in the same way.
    static let newTabOnHostIdentifier = NSUserInterfaceItemIdentifier("newTabOnHost")

    /// Prefix of the identifier given to every item this builds. AppKit adds
    /// items of its own later (the Services menu's contents, the Window
    /// menu's tiling commands); the shortcut table lists only ours.
    static let ownItemPrefix = "armadale.menu."

    /// Whether `item` was created by ``make(profileMenuDelegate:installsSpecialMenus:)``.
    static func isOwnItem(_ item: NSMenuItem) -> Bool {
        item.identifier?.rawValue.hasPrefix(ownItemPrefix) ?? false
    }

    /// The main menu. With `installsSpecialMenus`, the Services, Window
    /// and Help menus are registered with `NSApp` (pass `false` to only
    /// read the menu, e.g. in tests).
    static func make(profileMenuDelegate: (any NSMenuDelegate)? = nil, installsSpecialMenus: Bool = true) -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let main = NSMenu()

        // App
        let app = submenu(appName, in: main)
        app.addItem(withTitle: "About \(appName)",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        if installsSpecialMenus { NSApp.servicesMenu = services }
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others",
                    action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let file = submenu("File", in: main)
        file.addItem(withTitle: "New Workspace", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "New Tab Group", action: #selector(WorkspaceWindowController.newTabGroup(_:)),
                     keyEquivalent: "n").keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "New Tab", action: #selector(WorkspaceWindowController.newTab(_:)), keyEquivalent: "t")
        let profiles = NSMenu(title: "New Tab with Profile")
        profiles.identifier = newTabWithProfileIdentifier
        profiles.delegate = profileMenuDelegate
        file.addItem(withTitle: "New Tab with Profile", action: nil, keyEquivalent: "").submenu = profiles
        let hosts = NSMenu(title: "New Tab on Host")
        hosts.identifier = newTabOnHostIdentifier
        hosts.delegate = profileMenuDelegate
        file.addItem(withTitle: "New Tab on Host", action: nil, keyEquivalent: "").submenu = hosts
        file.addItem(.separator())
        file.addItem(withTitle: "Close Pane", action: #selector(WorkspaceWindowController.closePane(_:)),
                     keyEquivalent: "w")
        file.addItem(withTitle: "Close Tab", action: #selector(WorkspaceWindowController.closeTab(_:)),
                     keyEquivalent: "")
        file.addItem(withTitle: "Close Tab Group", action: #selector(WorkspaceWindowController.closeTabGroup(_:)),
                     keyEquivalent: "")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            .keyEquivalentModifierMask = [.command, .shift]

        // Edit
        let edit = submenu("Edit", in: main)
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        // Nil-targeted: Copy, Paste and Select All reach SwiftTerm's terminal
        // view through the responder chain when it is first responder.
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Clear Screen", action: #selector(WorkspaceWindowController.clearScreen(_:)),
                     keyEquivalent: "k")

        // View
        let view = submenu("View", in: main)
        view.addItem(withTitle: "Toggle Sidebar",
                     action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        view.addItem(.separator())
        view.addItem(withTitle: "Bigger", action: #selector(AppDelegate.increaseFontSize(_:)), keyEquivalent: "=")
        // ⌘+ (⇧⌘=) as well, hidden, as in most Mac apps.
        let plus = view.addItem(withTitle: "Bigger", action: #selector(AppDelegate.increaseFontSize(_:)),
                                keyEquivalent: "+")
        hideAlternate(plus)
        view.addItem(withTitle: "Smaller", action: #selector(AppDelegate.decreaseFontSize(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(AppDelegate.resetFontSize(_:)), keyEquivalent: "0")
        view.addItem(.separator())
        view.addItem(withTitle: "Toggle Full Screen",
                     action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "\r")

        // Pane
        let pane = submenu("Pane", in: main)
        pane.addItem(withTitle: "Split Right", action: #selector(WorkspaceWindowController.splitRight(_:)),
                     keyEquivalent: "d")
        pane.addItem(withTitle: "Split Down", action: #selector(WorkspaceWindowController.splitDown(_:)),
                     keyEquivalent: "d").keyEquivalentModifierMask = [.command, .shift]
        pane.addItem(.separator())
        for direction in Direction.allCases {
            let item = pane.addItem(
                withTitle: "Focus \(name(of: direction)) Pane",
                action: #selector(WorkspaceWindowController.focusPane(_:)), keyEquivalent: arrowKey(direction))
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = directionTag(direction)
        }
        pane.addItem(.separator())
        for direction in Direction.allCases {
            let item = pane.addItem(
                withTitle: "Move Divider \(name(of: direction))",
                action: #selector(WorkspaceWindowController.resizePane(_:)), keyEquivalent: arrowKey(direction))
            item.keyEquivalentModifierMask = [.command, .control]
            item.tag = directionTag(direction)
        }
        pane.addItem(withTitle: "Equalize Panes", action: #selector(WorkspaceWindowController.equalizePanes(_:)),
                     keyEquivalent: "=").keyEquivalentModifierMask = [.command, .control]
        pane.addItem(withTitle: "Zoom Pane", action: #selector(WorkspaceWindowController.togglePaneZoom(_:)),
                     keyEquivalent: "\r").keyEquivalentModifierMask = [.command, .shift]

        // Workspace
        let workspace = submenu("Workspace", in: main)
        workspace.addItem(withTitle: "Rename Workspace…",
                          action: #selector(WorkspaceWindowController.renameWorkspace(_:)), keyEquivalent: "")
        workspace.addItem(withTitle: "Rename Tab Group…",
                          action: #selector(WorkspaceWindowController.renameTabGroup(_:)), keyEquivalent: "")
        workspace.addItem(withTitle: "Rename Tab…",
                          action: #selector(WorkspaceWindowController.renameTab(_:)), keyEquivalent: "")
        workspace.addItem(.separator())
        workspace.addItem(withTitle: "Respawn All Ended",
                          action: #selector(WorkspaceWindowController.respawnAllEnded(_:)), keyEquivalent: "r")
            .keyEquivalentModifierMask = [.command, .option]
        workspace.addItem(.separator())
        workspace.addItem(withTitle: "Delete Workspace…",
                          action: #selector(WorkspaceWindowController.deleteWorkspace(_:)), keyEquivalent: "")

        // Window
        //
        // ⇧⌘] / ⇧⌘[ and ⇧⌘1…9 are written as the unshifted character plus a
        // Shift mask, not as "}" or "!". That is the form that displays as
        // ⇧⌘] / ⇧⌘1, and since macOS 12 AppKit matches menu key equivalents
        // by key, with automatic key-equivalent localization for the current
        // layout (`NSMenuItem.allowsAutomaticKeyEquivalentLocalization`,
        // on by default). Verified on macOS 27 in step 4: ⇧⌘1 / ⇧⌘2 select
        // tab groups (not tabs, which ⌘1 would), ⇧⌘] / ⇧⌘[ change tabs.
        let window = submenu("Window", in: main)
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        let next = window.addItem(withTitle: "Show Next Tab",
                                  action: #selector(WorkspaceWindowController.selectNextTab(_:)), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        let previous = window.addItem(withTitle: "Show Previous Tab",
                                      action: #selector(WorkspaceWindowController.selectPreviousTab(_:)),
                                      keyEquivalent: "[")
        previous.keyEquivalentModifierMask = [.command, .shift]
        let nextControl = window.addItem(withTitle: "Show Next Tab",
                                         action: #selector(WorkspaceWindowController.selectNextTab(_:)),
                                         keyEquivalent: "\t")
        nextControl.keyEquivalentModifierMask = [.control]
        hideAlternate(nextControl)
        let previousControl = window.addItem(withTitle: "Show Previous Tab",
                                             action: #selector(WorkspaceWindowController.selectPreviousTab(_:)),
                                             keyEquivalent: "\t")
        previousControl.keyEquivalentModifierMask = [.control, .shift]
        hideAlternate(previousControl)
        window.addItem(.separator())
        for number in 1...9 {
            let item = window.addItem(
                withTitle: number == 9 ? "Show Last Tab" : "Show Tab \(number)",
                action: #selector(WorkspaceWindowController.selectTabByNumber(_:)), keyEquivalent: "\(number)")
            item.tag = number
        }
        window.addItem(.separator())
        for number in 1...9 {
            let item = window.addItem(
                withTitle: "Show Tab Group \(number)",
                action: #selector(WorkspaceWindowController.selectTabGroupByNumber(_:)), keyEquivalent: "\(number)")
            item.keyEquivalentModifierMask = [.command, .shift]
            item.tag = number
        }
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front",
                       action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        if installsSpecialMenus { NSApp.windowsMenu = window }

        // Help
        let help = submenu("Help", in: main)
        help.addItem(withTitle: "\(appName) Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        if installsSpecialMenus { NSApp.helpMenu = help }

        markOwnItems(in: main, path: "")
        return main
    }

    /// Gives every item built so far an ``ownItemPrefix`` identifier.
    private static func markOwnItems(in menu: NSMenu, path: String) {
        for (index, item) in menu.items.enumerated() {
            let itemPath = path.isEmpty ? "\(index)" : "\(path).\(index)"
            // AppKit defaults an item's identifier to its action's name; ours
            // replaces it (nothing relies on that default).
            item.identifier = NSUserInterfaceItemIdentifier(ownItemPrefix + itemPath)
            if let submenu = item.submenu { markOwnItems(in: submenu, path: itemPath) }
        }
    }

    /// Fills File › New Tab with Profile with one item per profile.
    static func fillProfileMenu(_ menu: NSMenu, profiles: [Profile], defaultProfile: ProfileID) {
        menu.removeAllItems()
        for profile in profiles {
            let item = menu.addItem(
                withTitle: profile.name, action: #selector(WorkspaceWindowController.newTabWithProfile(_:)),
                keyEquivalent: "")
            item.representedObject = profile.id.raw
            item.image = NSImage(systemSymbolName: profile.icon, accessibilityDescription: nil)
            item.state = profile.id == defaultProfile ? .on : .off
        }
    }

    /// Fills File › New Tab on Host: one item per host (a tab there, in
    /// the home directory, with the default profile), then Add Host….
    static func fillHostMenu(_ menu: NSMenu, hosts: [ArmadaleCore.Host]) {
        menu.removeAllItems()
        if hosts.isEmpty {
            menu.addItem(withTitle: "No Hosts", action: nil, keyEquivalent: "").isEnabled = false
        }
        for host in hosts {
            let item = menu.addItem(
                withTitle: host.displayName, action: #selector(WorkspaceWindowController.newTabOnHost(_:)),
                keyEquivalent: "")
            item.representedObject = host.id.raw
            item.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
            if host.displayName != host.sshDestination { item.toolTip = host.sshDestination }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add Host…", action: #selector(AppDelegate.showHostsSettings(_:)), keyEquivalent: "")
    }

    // MARK: Directions

    /// Menu item tags for the four directions (⌥⌘ / ⌃⌘ arrows).
    static func directionTag(_ direction: Direction) -> Int {
        (Direction.allCases.firstIndex(of: direction) ?? 0) + 1
    }

    static func direction(forTag tag: Int) -> Direction? {
        let index = tag - 1
        return Direction.allCases.indices.contains(index) ? Direction.allCases[index] : nil
    }

    private static func name(of direction: Direction) -> String {
        switch direction {
        case .left: "Left"
        case .right: "Right"
        case .up: "Up"
        case .down: "Down"
        }
    }

    private static func arrowKey(_ direction: Direction) -> String {
        let key = switch direction {
        case .left: NSLeftArrowFunctionKey
        case .right: NSRightArrowFunctionKey
        case .up: NSUpArrowFunctionKey
        case .down: NSDownArrowFunctionKey
        }
        return String(Character(UnicodeScalar(UInt16(key)) ?? " "))
    }

    // MARK: Helpers

    /// A second shortcut for a command shown once: hidden, but its key
    /// equivalent still works.
    private static func hideAlternate(_ item: NSMenuItem) {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
    }

    private static func submenu(_ title: String, in main: NSMenu) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }
}
