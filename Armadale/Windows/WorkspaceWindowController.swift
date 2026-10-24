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
/// the workspace closed or deletes it (Delete Workspace, or its last tab
/// group was closed).
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
    /// The normal frame from just before full screen, while the window is
    /// in full screen or on its way in or out.
    private var frameBeforeFullScreen: NSRect?
    /// From `windowWill{Enter,Exit}FullScreen` until the transition ends:
    /// whether the window is going into full screen (true) or out (false).
    private var fullScreenTarget: Bool?
    /// Called once when the current full-screen transition ends or fails.
    private var afterFullScreenTransition: (@MainActor () -> Void)?
    /// The state recorded when the window was ordered out for menu bar
    /// mode, reported unchanged until it is shown again.
    private var stateWhileHidden: WindowState?
    /// Set in `windowWillClose`: nothing is reported after the close.
    private var isClosed = false
    /// Queued to enter full screen (``markFullScreenEntryPending()``): the
    /// reported flag stays true until the entry starts.
    private var isFullScreenEntryPending = false

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
        // Where focus goes after a rename when what had it before is gone.
        actions.rename.focusFallback = { [weak content = self.content] in content?.focusedPaneView?.focusTerminal() }
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

    /// Whether the window is in full screen or entering or leaving it: its
    /// frame is then not a normal one.
    var isInFullScreen: Bool {
        fullScreenTarget != nil || window?.styleMask.contains(.fullScreen) == true
    }

    /// The window's current geometry. A full-screen frame is never
    /// recorded: in full screen the last normal frame is kept, and
    /// `isFullScreen` says so (the state the window is going to, during a
    /// transition).
    func captureWindowState(isOpen: Bool) -> WindowState {
        if var hidden = stateWhileHidden {
            hidden.isOpen = isOpen
            return hidden
        }
        let saved = model.workspace(workspaceID)?.window
        let frame = WindowGeometry.recordedFrame(
            isFullScreen: isInFullScreen,
            current: window.map { WindowFrame($0.frame) },
            lastNormal: frameBeforeFullScreen.map(WindowFrame.init) ?? saved?.frame)
        let collapsed = sidebarItem.isCollapsed
        let width = collapsed ? nil : Double(sidebarItem.viewController.view.frame.width)
        return WindowState(
            frame: frame,
            sidebarWidth: width ?? saved?.sidebarWidth,
            sidebarCollapsed: collapsed,
            isOpen: isOpen,
            isFullScreen: fullScreenTarget
                ?? (isFullScreenEntryPending || window?.styleMask.contains(.fullScreen) == true))
    }

    /// Whether the workspace had a saved frame when the window was made
    /// (on a screen that still exists).
    private(set) var hadSavedFrame = false

    /// Whether the saved state says the window was in full screen.
    var savedAsFullScreen: Bool { model.workspace(workspaceID)?.window?.isFullScreen == true }

    private func restoreWindowState() {
        guard let window else { return }
        let state = model.workspace(workspaceID)?.window
        let placement = state?.frame.map { frame in
            WindowGeometry.placement(of: frame.rect, visibleFrames: NSScreen.screens.map(\.visibleFrame))
        } ?? .centredDefault
        if let frame = state?.frame?.rect, placement != .centredDefault {
            hadSavedFrame = true
            var target = frame
            if case .constrained(let index) = placement {
                target = window.constrainFrameRect(frame, to: NSScreen.screens[index])
            }
            window.setFrame(target, display: false)
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
                // Local sessions that won't persist, or remote ones on a
                // host that could not take the persistence helper.
                let warning = registry.persistenceWarning
                    ?? registry.persistenceNote(of: model.sessionIDs(in: workspaceID)).map { _ in
                        SessionRegistry.persistenceWarningText
                    }
                return Presentation(
                    title: workspace?.name ?? "Armadale",
                    subtitle: [group, warning ?? ""].filter { !$0.isEmpty }.joined(separator: " — "),
                    isOpen: workspace?.window?.isOpen ?? false)
            }
            for await presentation in presentations {
                guard let self else { return }
                guard presentation.isOpen else {
                    self.closeOutsideFullScreenTransition()
                    return
                }
                self.window?.title = presentation.title
                self.window?.subtitle = presentation.subtitle
            }
        }
    }

    /// Set when the workspace left the model or was marked closed while
    /// the window was in full screen or in a transition: it closes once it
    /// has left full screen (its turn in ``fullScreenSteps``), and enters
    /// full screen no more.
    private(set) var isClosePending = false

    /// Every full-screen toggle goes through it, one at a time, app-wide
    /// (``FullScreenSerializer``); set by the app delegate. Without one (in
    /// tests) a step runs at once.
    var fullScreenSteps: FullScreenSerializer?

    private func serialized(ahead: Bool = false, _ step: @escaping FullScreenSerializer.Step) {
        if let fullScreenSteps {
            fullScreenSteps.enqueue(ahead: ahead, step)
        } else {
            step {}
        }
    }

    /// Closes the window (its workspace left the model or was marked
    /// closed). A normal window closes at once. A window in full screen,
    /// or in a transition, is never closed as it is (DESIGN §8, "Closing
    /// in full screen"; measured on macOS 27): closed mid-transition, or
    /// closed in full screen while another window's transition runs, it
    /// comes back on screen at its normal frame, empty, and the other
    /// window is left out of full screen. So it waits for its turn in
    /// ``fullScreenSteps`` (no transition anywhere), leaves full screen,
    /// and closes when that has ended. The app delegate holds the
    /// controller until `windowWillClose`, and the step holds it too.
    private func closeOutsideFullScreenTransition() {
        guard !isClosed, !isClosePending else { return }
        guard isInFullScreen else { return close() }
        isClosePending = true
        serialized(ahead: true) { [self] done in
            self.leaveFullScreenAndClose(then: done)
        }
    }

    /// Out of full screen first if the window is in it, then closes, then
    /// calls `done`. A window AppKit will not take out of full screen (on
    /// another Space, or refusing every time) is closed in full screen.
    private func leaveFullScreenAndClose(then done: @escaping @MainActor () -> Void) {
        leaveFullScreen { [weak self] left in
            guard let self, !self.isClosed else { return done() }
            if left {
                self.close()
                done()
            } else {
                self.closeInFullScreen(then: done)
            }
        }
    }

    /// Set while a window closed in full screen waits for the exit AppKit
    /// runs after `windowWillClose`.
    private var isClosingInFullScreen = false

    /// Closes the window as it is, in full screen, and calls `done` when
    /// the exit AppKit then runs has ended (or after a while: the
    /// controller may be gone by then, and the step must end). Only from a
    /// serialized step, so no other transition overlaps that exit.
    private func closeInFullScreen(then done: @escaping @MainActor () -> Void) {
        guard let window, !isClosed else { return done() }
        guard window.styleMask.contains(.fullScreen) else {
            close()
            return done()
        }
        isClosingInFullScreen = true
        // That exit is not counted as a transition (the window is closed),
        // so its end is noted for the serializer's settle time.
        var isFinished = false
        let finish: @MainActor () -> Void = { [weak steps = fullScreenSteps] in
            guard !isFinished else { return }
            isFinished = true
            steps?.noteTransitionEnded()
            done()
        }
        afterFullScreenTransition = finish
        close()
        afterDelay(Self.closeExitAllowance, finish)
    }

    /// Exits that failed are tried again this many times in all.
    private static let exitAttempts = 4
    private static let exitRetryDelay: TimeInterval = 0.3
    /// How long a step waits for the exit AppKit runs after closing a
    /// full-screen window (measured: about 0.1 s).
    private static let closeExitAllowance: TimeInterval = 1.5

    /// Whether the last transition failed (`windowDidFail…FullScreen`;
    /// after a failed exit the style mask may already read normal, and
    /// AppKit puts the window back into full screen).
    private var lastTransitionFailed = false

    /// Leaves full screen; `completion(true)` once the window is out of
    /// it, `false` if it closed meanwhile, is in full screen on another
    /// Space (measured on macOS 27: its exit fails, and AppKit puts it back
    /// into full screen) or AppKit kept refusing. A failed exit is tried
    /// again after a short wait, once any transition of the window ended.
    ///
    /// `bringingForward`: a window on another Space is brought forward
    /// first (its Space becomes the active one) instead of giving up.
    private func leaveFullScreen(
        attempt: Int = 0, bringingForward: Bool = false, then completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let window, !isClosed else { return completion(false) }
        guard window.styleMask.contains(.fullScreen) else { return completion(true) }
        guard attempt < Self.exitAttempts else { return completion(false) }
        guard window.isOnActiveSpace else {
            guard bringingForward else { return completion(false) }
            window.makeKeyAndOrderFront(nil)
            return whenOnActiveSpace(waitingUpTo: 20) { [weak self] isActive in
                guard let self, isActive else { return completion(false) }
                self.leaveFullScreen(attempt: attempt, then: completion)
            }
        }
        afterFullScreenTransition = { [weak self] in
            guard let self, let window = self.window, !self.isClosed else { return completion(false) }
            guard self.lastTransitionFailed || window.styleMask.contains(.fullScreen) else { return completion(true) }
            self.afterDelay(Self.exitRetryDelay) { [weak self] in
                guard let self else { return completion(false) }
                guard self.fullScreenTarget != nil else {
                    return self.leaveFullScreen(attempt: attempt + 1, then: completion)
                }
                self.afterCurrentTransition { [weak self] in
                    guard let self else { return completion(false) }
                    self.leaveFullScreen(attempt: attempt + 1, then: completion)
                }
            }
        }
        lastTransitionFailed = false
        window.toggleFullScreen(nil)
        // AppKit refused without starting a transition (no delegate call).
        if fullScreenTarget == nil { finishFullScreenTransition() }
    }

    /// Calls `completion(true)` once the window is on the active Space
    /// (checked every 0.1 s), `false` after `checks` tries or if it closed.
    private func whenOnActiveSpace(waitingUpTo checks: Int, _ completion: @escaping @MainActor (Bool) -> Void) {
        guard let window, !isClosed else { return completion(false) }
        guard !window.isOnActiveSpace else { return completion(true) }
        guard checks > 0 else { return completion(false) }
        afterDelay(0.1) { [weak self] in
            guard let self else { return completion(false) }
            self.whenOnActiveSpace(waitingUpTo: checks - 1, completion)
        }
    }

    /// Runs `action` after `delay`, in the default run-loop mode.
    private func afterDelay(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .default)
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

    /// File › New Tab with Profile: the item's represented object is the
    /// profile's ID.
    @objc func newTabWithProfile(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String else { return }
        actions.newTab(profile: ProfileID(raw: raw))
    }

    /// File › New Tab on Host: the item's represented object is the host's ID.
    @objc func newTabOnHost(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String else { return }
        actions.newTab(onHost: HostID(raw: raw))
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
    /// group the workspace (and so its window). A tab group without tabs is
    /// never kept (moving its last tab away removes it, and the repair after
    /// every load drops one); this branch is defensive: should one appear,
    /// ⌘W closes it, without asking since nothing runs there.
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

    @objc func deleteWorkspace(_ sender: Any?) {
        actions.deleteWorkspace(workspaceID)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let workspace = model.workspace(workspaceID)
        let group = workspace?.selectedTabGroup
        let tab = group?.selectedTab
        switch menuItem.action {
        case #selector(newTab(_:)), #selector(newTabWithProfile(_:)), #selector(newTabOnHost(_:)), #selector(newTabGroup(_:)),
             #selector(deleteWorkspace(_:)):
            return workspace != nil
        case #selector(closePane(_:)):
            let closesEmptyGroup = tab == nil && group?.tabs.isEmpty == true
            menuItem.title = closesEmptyGroup ? "Close Tab Group" : "Close Pane"
            return tab != nil || closesEmptyGroup
        case #selector(splitRight(_:)), #selector(splitDown(_:)), #selector(closeTab(_:)):
            return tab != nil
        case #selector(clearScreen(_:)):
            return content.focusedPaneView != nil
        case #selector(closeTabGroup(_:)):
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

    /// Reports the window's state as open, unless it has closed.
    private func reportOpenState() {
        guard !isClosed else { return }
        onWindowStateChange?(self, captureWindowState(isOpen: true))
    }

    private func scheduleStateReport() {
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, !self.isClosed, self.window?.isVisible == true else { return }
            self.reportOpenState()
        }
    }

    // MARK: Full screen and menu bar mode

    /// The window is queued to enter full screen: until the entry starts,
    /// the state it reports says full screen (a quit before then keeps
    /// the flag).
    func markFullScreenEntryPending() {
        isFullScreenEntryPending = true
    }

    /// Enters full screen (the window must be on screen), then calls
    /// `completion` when the transition has ended or failed, or at once if
    /// the window is already in full screen or cannot enter it now. A
    /// window still leaving full screen enters once that has ended.
    func enterFullScreen(then completion: @escaping @MainActor () -> Void) {
        if fullScreenTarget != nil {
            afterCurrentTransition { [weak self] in
                guard let self else { return completion() }
                self.enterFullScreen(then: completion)
            }
            return
        }
        isFullScreenEntryPending = false
        guard let window, !isClosed, !isClosePending, window.isVisible, !isInFullScreen else {
            completion()
            return
        }
        afterFullScreenTransition = completion
        window.toggleFullScreen(nil)
        // AppKit refused without starting a transition (no delegate call).
        if fullScreenTarget == nil, !window.styleMask.contains(.fullScreen) {
            finishFullScreenTransition()
        }
    }

    /// Runs `action` when the current transition ends, after whatever was
    /// already waiting for it.
    private func afterCurrentTransition(_ action: @escaping @MainActor () -> Void) {
        let earlier = afterFullScreenTransition
        afterFullScreenTransition = {
            earlier?()
            action()
        }
    }

    private func finishFullScreenTransition() {
        fullScreenTarget = nil
        let completion = afterFullScreenTransition
        afterFullScreenTransition = nil
        completion?()
    }

    /// Menu bar mode: orders the window out. What it records stays as it
    /// is now until ``didShowAfterMenuBarMode()``. A window in full screen
    /// (or in a transition) leaves it first, in its turn in
    /// ``fullScreenSteps``, and is ordered out once it has: a full-screen
    /// window ordered out and back in keeps full screen but loses its
    /// title bar and toolbar (they come back as a zero-sized window).
    func hideForMenuBarMode() {
        stateWhileHidden = captureWindowState(isOpen: true)
        guard isInFullScreen else {
            window?.orderOut(nil)
            return
        }
        serialized { [weak self] done in
            guard let self else { return done() }
            self.leaveFullScreenAndOrderOut(then: done)
        }
    }

    /// Unless menu bar mode ended meanwhile (or the window closed): out of
    /// full screen, then ordered out; ordered out as it is if AppKit keeps
    /// refusing to leave. Then calls `done`.
    private func leaveFullScreenAndOrderOut(then done: @escaping @MainActor () -> Void) {
        guard !isClosed, stateWhileHidden != nil else { return done() }
        leaveFullScreen { [weak self] left in
            if let self, !self.isClosed, self.stateWhileHidden != nil {
                self.window?.orderOut(nil)
                if !left, self.window?.styleMask.contains(.fullScreen) == true { self.isOrderedOutInFullScreen = true }
            }
            done()
        }
    }

    /// Ordered out for menu bar mode while still in full screen (it was on
    /// another Space, where its exit fails): shown again it would lack its
    /// title bar and toolbar, so ``didShowAfterMenuBarMode()`` takes it out
    /// of full screen first, and the caller's queued entry puts it back.
    private var isOrderedOutInFullScreen = false

    /// The window is on screen again after menu bar mode. Returns whether
    /// it was in full screen: the caller queues it to re-enter, one window
    /// after another as at launch. One ordered out while in full screen
    /// leaves it first, in its turn.
    func didShowAfterMenuBarMode() -> Bool {
        guard let hidden = stateWhileHidden else { return false }
        stateWhileHidden = nil
        if isOrderedOutInFullScreen {
            isOrderedOutInFullScreen = false
            serialized { [weak self] done in
                guard let self else { return done() }
                self.leaveFullScreen(bringingForward: true) { _ in done() }
            }
        }
        return hidden.isFullScreen
    }

    // MARK: NSWindowDelegate

    func windowWillEnterFullScreen(_ notification: Notification) {
        if !isInFullScreen, let window { frameBeforeFullScreen = window.frame }
        fullScreenTarget = true
        if !isClosed { fullScreenSteps?.transitionBegan(self) }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        finishFullScreenTransition()
        reportOpenState()
        fullScreenSteps?.transitionEnded(self)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        lastTransitionFailed = true
        frameBeforeFullScreen = nil
        finishFullScreenTransition()
        fullScreenSteps?.transitionEnded(self)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        fullScreenTarget = false
        if !isClosed { fullScreenSteps?.transitionBegan(self) }
    }

    /// The frame is the normal one again: record it.
    func windowDidExitFullScreen(_ notification: Notification) {
        frameBeforeFullScreen = nil
        finishFullScreenTransition()
        reportOpenState()
        fullScreenSteps?.transitionEnded(self)
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        lastTransitionFailed = true
        finishFullScreenTransition()
        fullScreenSteps?.transitionEnded(self)
    }

    /// An inline rename field edits with its own field editor, never the
    /// window's shared one (names are taken literally, DESIGN §8).
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? RenameTextField)?.privateFieldEditor
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        reportOpenState()
    }

    /// Zoom and other resizes that are not live (a live one is saved when
    /// it ends).
    func windowDidResize(_ notification: Notification) {
        guard window?.inLiveResize == false else { return }
        scheduleStateReport()
    }

    func windowDidMove(_ notification: Notification) {
        reportOpenState()
    }

    func windowWillClose(_ notification: Notification) {
        // AppKit sends the full-screen exit callbacks (and a resize) after
        // this when a full-screen window closes; none may report it open.
        isClosed = true
        content.stop()
        titleTask?.cancel()
        titleTask = nil
        stateTask?.cancel()
        stateTask = nil
        onWindowStateChange?(self, captureWindowState(isOpen: false))
        // A closed window holds no full-screen step up: what waited for a
        // transition of it runs now (unless it waits for the exit AppKit
        // runs after closing a full-screen window), and the serializer
        // forgets it (the callbacks AppKit may still send are not counted).
        if !isClosingInFullScreen { finishFullScreenTransition() }
        fullScreenSteps?.transitionEnded(self)
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The toggle sits at the trailing end of the sidebar's section, next
        // to the divider, not beside the window's traffic lights.
        [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
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
