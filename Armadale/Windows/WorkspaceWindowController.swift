import AppKit
import ArmadaleCore
import SwiftUI

/// One window per open workspace: a sidebar (SwiftUI) and the content area,
/// in an `NSSplitViewController`. Title and subtitle track the workspace and
/// its selected tab group, and the window closes itself when the model marks
/// the workspace closed (its last tab group was closed) or deletes it.
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let workspaceID: WorkspaceID
    /// Called with the window's state when it moves, resizes, or closes
    /// (`isOpen == false`).
    var onWindowStateChange: ((WorkspaceWindowController, WindowState) -> Void)?

    private let model: AppModel
    /// Its persistence warning is appended to the subtitle while sessions
    /// do not outlive the app.
    private let registry: SessionRegistry
    private let splitViewController = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem
    private var titleTask: Task<Void, Never>?

    private static let defaultSize = NSSize(width: 1100, height: 700)
    private static let defaultSidebarWidth: CGFloat = 240

    init(model: AppModel, workspaceID: WorkspaceID, registry: SessionRegistry) {
        self.model = model
        self.workspaceID = workspaceID
        self.registry = registry

        let sidebar = NSHostingController(rootView: SidebarView(model: model, currentWorkspaceID: workspaceID))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        let content = NSSplitViewItem(
            viewController: ContentViewController(model: model, workspaceID: workspaceID, registry: registry))
        content.minimumThickness = 320
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(content)

        let window = NSWindow(
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

        let toolbar = NSToolbar(identifier: "WorkspaceToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.delegate = self

        restoreWindowState()
        observeTitles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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

    private func restoreWindowState() {
        guard let window else { return }
        let state = model.workspace(workspaceID)?.window
        if let frame = state?.frame {
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

    // MARK: NSWindowDelegate

    func windowDidEndLiveResize(_ notification: Notification) {
        onWindowStateChange?(self, captureWindowState(isOpen: true))
    }

    func windowDidMove(_ notification: Notification) {
        onWindowStateChange?(self, captureWindowState(isOpen: true))
    }

    func windowWillClose(_ notification: Notification) {
        titleTask?.cancel()
        titleTask = nil
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
