import AppKit
import ArmadaleCore
import SwiftUI

/// The window of a workspace. Reports every first-responder change, which
/// is how a click into a pane focuses that pane in the model.
@MainActor
final class WorkspaceWindow: NSWindow {
    var onFirstResponderChange: ((NSResponder?) -> Void)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted { onFirstResponderChange?(firstResponder) }
        return accepted
    }
}

/// One window per open workspace: a sidebar (SwiftUI) and the content area,
/// in an `NSSplitViewController`. Title and subtitle track the workspace and
/// its selected tab group, and the window closes itself when the model marks
/// the workspace closed (its last tab group was closed) or deletes it.
///
/// It is also where the workspace's menu commands land (DESIGN §9): the
/// window controller is always in the responder chain, whether a terminal
/// or the sidebar has keyboard focus, and keys that are not bound to a menu
/// item still reach the terminal.
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let workspaceID: WorkspaceID
    /// Called with the window's state when it moves, resizes, or closes
    /// (`isOpen == false`).
    var onWindowStateChange: ((WorkspaceWindowController, WindowState) -> Void)?

    let actions: WorkspaceActions
    private let model: AppModel
    /// Its persistence warning is appended to the subtitle while sessions
    /// do not outlive the app.
    private let registry: SessionRegistry
    private let splitViewController = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem
    private let content: ContentViewController
    private var titleTask: Task<Void, Never>?
    /// Debounced report of geometry changes that end without a live resize
    /// (sidebar drags and collapses, zoom); see ``observeGeometry()``.
    private var stateTask: Task<Void, Never>?
    private var splitObserver: (any NSObjectProtocol)?

    private static let defaultSize = NSSize(width: 1100, height: 700)
    private static let defaultSidebarWidth: CGFloat = 240
    /// ⌃⌘ arrow moves a divider by this share of its split.
    private static let resizeStep = 0.05

    init(model: AppModel, workspaceID: WorkspaceID, registry: SessionRegistry) {
        self.model = model
        self.workspaceID = workspaceID
        self.registry = registry
        let actions = WorkspaceActions(model: model, registry: registry, workspaceID: workspaceID)
        self.actions = actions

        let sidebar = NSHostingController(rootView: SidebarView(
            model: model, registry: registry, currentWorkspaceID: workspaceID, actions: actions))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        content = ContentViewController(model: model, workspaceID: workspaceID, registry: registry, actions: actions)
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 320
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)

        let window = WorkspaceWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed // Armadale has its own tabs.
        window.minSize = NSSize(width: 520, height: 320)
        window.contentViewController = splitViewController

        super.init(window: window)

        actions.window = window
        window.onFirstResponderChange = { [weak content] responder in
            content?.firstResponderDidChange(responder)
        }
        let toolbar = NSToolbar(identifier: "WorkspaceToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.delegate = self

        restoreWindowState()
        observeTitles()
        observeGeometry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        titleTask?.cancel()
        stateTask?.cancel()
        if let splitObserver { NotificationCenter.default.removeObserver(splitObserver) }
        #if DEBUG
        NSLog("Armadale: WorkspaceWindowController deinit (%@)", workspaceID.raw)
        #endif
    }

    /// The window's current geometry.
    func captureWindowState(isOpen: Bool) -> WindowState {
        let frame = window?.frame ?? .zero
        let collapsed = sidebarItem.isCollapsed
        let width = collapsed ? nil : Double(sidebarItem.viewController.view.frame.width)
        return WindowState(
            frame: WindowFrame(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height),
            sidebarWidth: width ?? model.workspace(workspaceID)?.window?.sidebarWidth,
            sidebarCollapsed: collapsed,
            isOpen: isOpen)
    }

    /// Whether the workspace had a saved frame when the window was made.
    private(set) var hadSavedFrame = false

    private func restoreWindowState() {
        guard let window else { return }
        let state = model.workspace(workspaceID)?.window
        if let frame = state?.frame {
            hadSavedFrame = true
            window.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
        } else {
            // Assigning contentViewController sized the window to its
            // content's fitting size; apply the default size explicitly.
            window.setContentSize(Self.defaultSize)
            window.center()
        }
        let width = CGFloat(state?.sidebarWidth ?? Double(Self.defaultSidebarWidth))
        splitViewController.splitView.setPosition(width, ofDividerAt: 0)
        sidebarItem.isCollapsed = state?.sidebarCollapsed ?? false
    }

    /// What the window shows of its workspace.
    private struct Presentation: Equatable, Sendable {
        var title: String
        var subtitle: String
        /// False once the workspace is deleted or its window marked closed.
        var isOpen: Bool
    }

    private func observeTitles() {
        let model = model
        let workspaceID = workspaceID
        let registry = registry
        titleTask = Task { [weak self] in
            let presentations = Observations {
                let workspace = model.workspace(workspaceID)
                let group = workspace?.selectedTabGroup?.name ?? ""
                let warning = registry.persistenceWarning
                return Presentation(
                    title: workspace?.name ?? "Armadale",
                    subtitle: [group, warning ?? ""].filter { !$0.isEmpty }.joined(separator: " — "),
                    isOpen: workspace?.window?.isOpen ?? false)
            }
            for await presentation in presentations {
                guard let self else { return }
                guard presentation.isOpen else {
                    self.close()
                    return
                }
                self.window?.title = presentation.title
                self.window?.subtitle = presentation.subtitle
            }
        }
    }

    // MARK: Menu commands (DESIGN §9)

    /// ⇧⌘N
    @objc func newTabGroup(_ sender: Any?) {
        actions.newTabGroup()
    }

    /// ⌘T
    @objc func newTab(_ sender: Any?) {
        actions.newTab()
    }

    /// ⌘D: a new shell right of the focused pane, in its directory.
    @objc func splitRight(_ sender: Any?) {
        model.splitFocusedPane(axis: .horizontal, in: workspaceID)
    }

    /// ⇧⌘D: a new shell below the focused pane, in its directory.
    @objc func splitDown(_ sender: Any?) {
        model.splitFocusedPane(axis: .vertical, in: workspaceID)
    }

    /// ⌘W: the last pane closes the tab, the last tab the group, the last
    /// group the window. In a tab group left empty (its tabs were moved
    /// away) it closes the group; nothing runs there, so it does not ask.
    @objc func closePane(_ sender: Any?) {
        guard let group = model.workspace(workspaceID)?.selectedTabGroup else { return }
        guard let pane = group.selectedTab?.focusedPaneID else {
            if group.tabs.isEmpty { model.closeTabGroup(group.id) }
            return
        }
        actions.closePane(pane, confirm: true)
    }

    @objc func closeTab(_ sender: Any?) {
        guard let tab = model.selectedTab(in: workspaceID)?.id else { return }
        actions.closeTab(tab)
    }

    @objc func closeTabGroup(_ sender: Any?) {
        guard let group = model.workspace(workspaceID)?.selectedTabGroupID else { return }
        actions.closeTabGroup(group)
    }

    /// ⌘1…⌘8, ⌘9 (last): the menu item's tag is the number.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let number = (sender as? NSMenuItem)?.tag else { return }
        model.selectTab(number: number, in: workspaceID)
    }

    /// ⇧⌘1…⇧⌘9: the menu item's tag is the number.
    @objc func selectTabGroupByNumber(_ sender: Any?) {
        guard let number = (sender as? NSMenuItem)?.tag else { return }
        model.selectTabGroup(number: number, in: workspaceID)
    }

    /// ⌃Tab, ⇧⌘]
    @objc func selectNextTab(_ sender: Any?) {
        model.selectAdjacentTab(offset: 1, in: workspaceID)
    }

    /// ⌃⇧Tab, ⇧⌘[
    @objc func selectPreviousTab(_ sender: Any?) {
        model.selectAdjacentTab(offset: -1, in: workspaceID)
    }

    /// ⌥⌘ arrows: the menu item's tag is a ``MainMenu/directionTag(_:)``.
    @objc func focusPane(_ sender: Any?) {
        guard let direction = (sender as? NSMenuItem).flatMap({ MainMenu.direction(forTag: $0.tag) }) else { return }
        model.moveFocus(direction, in: workspaceID)
    }

    /// ⌃⌘ arrows: the menu item's tag is a ``MainMenu/directionTag(_:)``.
    @objc func resizePane(_ sender: Any?) {
        guard let direction = (sender as? NSMenuItem).flatMap({ MainMenu.direction(forTag: $0.tag) }) else { return }
        content.commitRatios()
        model.resizeFocusedPane(toward: direction, by: Self.resizeStep, in: workspaceID)
    }

    /// ⌃⌘=
    @objc func equalizePanes(_ sender: Any?) {
        content.commitRatios()
        model.equalizePanes(in: workspaceID)
    }

    /// ⇧⌘↩
    @objc func togglePaneZoom(_ sender: Any?) {
        content.commitRatios()
        model.toggleZoom(in: workspaceID)
    }

    /// ⌘K
    @objc func clearScreen(_ sender: Any?) {
        content.focusedPaneView?.controller.clearScreen()
    }

    /// Workspace › Respawn All Ended (⌥⌘R): every ended pane in this
    /// window's workspace, shown or not.
    @objc func respawnAllEnded(_ sender: Any?) {
        registry.respawnAllEnded(in: workspaceID)
    }

    @objc func renameWorkspace(_ sender: Any?) {
        actions.renameWorkspace(workspaceID)
    }

    @objc func renameTabGroup(_ sender: Any?) {
        guard let group = model.workspace(workspaceID)?.selectedTabGroupID else { return }
        actions.renameTabGroup(group)
    }

    @objc func renameTab(_ sender: Any?) {
        guard let tab = model.selectedTab(in: workspaceID)?.id else { return }
        actions.renameTab(tab)
    }

    @objc func deleteWorkspace(_ sender: Any?) {
        actions.deleteWorkspace(workspaceID)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let workspace = model.workspace(workspaceID)
        let group = workspace?.selectedTabGroup
        let tab = group?.selectedTab
        switch menuItem.action {
        case #selector(newTab(_:)), #selector(newTabGroup(_:)), #selector(renameWorkspace(_:)),
             #selector(deleteWorkspace(_:)):
            return workspace != nil
        case #selector(closePane(_:)):
            let closesEmptyGroup = tab == nil && group?.tabs.isEmpty == true
            menuItem.title = closesEmptyGroup ? "Close Tab Group" : "Close Pane"
            return tab != nil || closesEmptyGroup
        case #selector(splitRight(_:)), #selector(splitDown(_:)), #selector(closeTab(_:)), #selector(renameTab(_:)):
            return tab != nil
        case #selector(clearScreen(_:)):
            return content.focusedPaneView != nil
        case #selector(closeTabGroup(_:)), #selector(renameTabGroup(_:)):
            return group != nil
        case #selector(selectTabByNumber(_:)):
            let count = group?.tabs.count ?? 0
            return menuItem.tag >= 9 ? count > 0 : menuItem.tag <= count
        case #selector(selectTabGroupByNumber(_:)):
            return menuItem.tag <= (workspace?.tabGroups.count ?? 0)
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return (group?.tabs.count ?? 0) > 1
        case #selector(focusPane(_:)):
            guard let tab, let direction = MainMenu.direction(forTag: menuItem.tag) else { return false }
            return tab.layout.neighbor(of: tab.focusedPaneID, direction: direction) != nil
        case #selector(resizePane(_:)):
            guard let tab, tab.zoomedPaneID == nil, let direction = MainMenu.direction(forTag: menuItem.tag) else {
                return false
            }
            return tab.layout.moveDivider(of: tab.focusedPaneID, toward: direction, by: 0.01) != tab.layout
                || tab.layout.moveDivider(of: tab.focusedPaneID, toward: direction, by: -0.01) != tab.layout
        case #selector(equalizePanes(_:)):
            return tab?.layout.isSplit ?? false
        case #selector(togglePaneZoom(_:)):
            menuItem.state = tab?.zoomedPaneID != nil ? .on : .off
            return tab?.layout.isSplit ?? false
        case #selector(respawnAllEnded(_:)):
            return registry.hasEndedSessions(in: workspaceID)
        default:
            return true
        }
    }

    // MARK: Geometry

    /// Sidebar drags and collapses (and the window zooming, below) end
    /// without a live resize, so they are saved from here, debounced, rather
    /// than only at the next move, close or quit.
    private func observeGeometry() {
        splitObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: splitViewController.splitView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleStateReport() }
        }
    }

    private func scheduleStateReport() {
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.window?.isVisible == true else { return }
            self.onWindowStateChange?(self, self.captureWindowState(isOpen: true))
        }
    }

    // MARK: NSWindowDelegate

    func windowDidEndLiveResize(_ notification: Notification) {
        onWindowStateChange?(self, captureWindowState(isOpen: true))
    }

    /// Zoom and other resizes that are not live (a live one is saved when
    /// it ends).
    func windowDidResize(_ notification: Notification) {
        guard window?.inLiveResize == false else { return }
        scheduleStateReport()
    }

    func windowDidMove(_ notification: Notification) {
        onWindowStateChange?(self, captureWindowState(isOpen: true))
    }

    func windowWillClose(_ notification: Notification) {
        content.stop()
        titleTask?.cancel()
        titleTask = nil
        stateTask?.cancel()
        stateTask = nil
        onWindowStateChange?(self, captureWindowState(isOpen: false))
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        nil // Only system items, which AppKit creates itself.
    }
}
