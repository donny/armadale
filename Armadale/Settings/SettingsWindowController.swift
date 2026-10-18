import AppKit
import ArmadaleCore
import SwiftUI

/// Armadale › Settings… (⌘,): one window, with the standard toolbar of
/// settings tabs (General, Appearance, Profiles, Hosts, Shortcuts), each a
/// SwiftUI view. The app keeps a single instance; the window remembers
/// where it was and which tab was shown (in ``Preferences``).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    enum Tab: String, CaseIterable {
        case general, appearance, profiles, hosts, shortcuts

        var title: String {
            switch self {
            case .general: "General"
            case .appearance: "Appearance"
            case .profiles: "Profiles"
            case .hosts: "Hosts"
            case .shortcuts: "Shortcuts"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintpalette"
            case .profiles: "terminal"
            case .hosts: "network"
            case .shortcuts: "keyboard"
            }
        }

        /// Each tab's content size; the window resizes to it, keeping its top edge.
        var contentSize: NSSize {
            switch self {
            case .general: NSSize(width: 620, height: 330)
            case .appearance: NSSize(width: 620, height: 640)
            case .profiles: NSSize(width: 780, height: 560)
            case .hosts: NSSize(width: 780, height: 600)
            case .shortcuts: NSSize(width: 620, height: 560)
            }
        }
    }

    private let settings: AppSettings
    private let tabs: SettingsTabViewController

    init(
        model: AppModel, settings: AppSettings, hostTools: HostTools = .unavailable,
        mainMenu: @escaping @MainActor () -> NSMenu
    ) {
        self.settings = settings
        // Read first: adding the tabs selects the first one, which is recorded.
        let saved = settings.preferences.settingsTab.flatMap(Tab.init(rawValue:)) ?? .general
        tabs = SettingsTabViewController(preferences: settings.preferences)
        tabs.tabStyle = .toolbar
        // The window is "Settings" whichever tab is shown (Window menu, accessibility).
        tabs.canPropagateSelectedChildViewControllerTitle = false
        for tab in Tab.allCases {
            let root: AnyView = switch tab {
            case .general: AnyView(GeneralSettingsView(model: model, preferences: settings.preferences))
            case .appearance: AnyView(AppearanceSettingsView(settings: settings))
            case .profiles: AnyView(ProfilesSettingsView(model: model))
            case .hosts: AnyView(HostsSettingsView(model: model, tools: hostTools))
            case .shortcuts: AnyView(ShortcutsSettingsView(rows: ShortcutTable.rows(from: mainMenu())))
            }
            let hosting = NSHostingController(rootView: root.frame(width: tab.contentSize.width, height: tab.contentSize.height))
            hosting.sizingOptions = []
            hosting.view.frame.size = tab.contentSize
            let item = NSTabViewItem(viewController: hosting)
            item.identifier = tab.rawValue
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Tab.general.contentSize),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        window.contentViewController = tabs
        window.title = "Settings"
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        super.init(window: window)
        window.delegate = self
        tabs.selectedTabViewItemIndex = Tab.allCases.firstIndex(of: saved) ?? 0
        tabs.resizeWindow(animated: false)
        placeWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The tab shown (for tests).
    var selectedTab: Tab? {
        tabs.tabViewItems.indices.contains(tabs.selectedTabViewItemIndex)
            ? (tabs.tabViewItems[tabs.selectedTabViewItemIndex].identifier as? String).flatMap(Tab.init(rawValue:))
            : nil
    }

    func show(_ tab: Tab? = nil) {
        if let tab, let index = Tab.allCases.firstIndex(of: tab) {
            tabs.selectedTabViewItemIndex = index
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Where the window was last time, if that is still on a screen; else centred.
    private func placeWindow() {
        guard let window else { return }
        if let topLeft = settings.preferences.settingsWindowTopLeft,
           NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(topLeft) }) {
            window.setFrameTopLeftPoint(topLeft)
        } else {
            window.center()
        }
    }

    /// ⌘W is bound to File › Close Pane, which only workspace windows
    /// handle; here it closes Settings.
    @objc func closePane(_ sender: Any?) {
        window?.performClose(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closePane(_:)) {
            menuItem.title = "Close Settings"
        }
        return true
    }

    func windowDidMove(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        settings.preferences.settingsWindowTopLeft = NSPoint(x: frame.minX, y: frame.maxY)
    }
}

/// Toolbar-style tabs that remember the selected tab and fit the window
/// to each one.
@MainActor
private final class SettingsTabViewController: NSTabViewController {
    private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String { preferences.settingsTab = id }
        resizeWindow(animated: view.window?.isVisible ?? false)
    }

    /// Sizes the window to the selected tab's content, keeping its top edge.
    func resizeWindow(animated: Bool) {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex),
              let id = tabViewItems[selectedTabViewItemIndex].identifier as? String,
              let tab = SettingsWindowController.Tab(rawValue: id),
              let window = view.window
        else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        var frame = window.frameRect(forContentRect: NSRect(origin: content.origin, size: tab.contentSize))
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: animated)
    }
}
