import AppKit
import ArmadaleCore
import ArmadaleSessions
import SwiftUI

/// The content side of a workspace window (DESIGN §8): the tab bar of the
/// selected tab group and, below it, the selected tab's split tree.
///
/// It follows the model: whenever the selected tab, its layout, zoom or
/// focus change, the ``SplitTreeView`` is updated (reparenting the
/// registry's pane views, never recreating them), the visible sessions are
/// started, and keyboard focus is put on the focused pane. In the other
/// direction, clicking into a pane focuses it in the model, and divider
/// drags are written back to the model after a short pause.
@MainActor
final class ContentViewController: NSViewController {
    private let model: AppModel
    private let workspaceID: WorkspaceID
    private let registry: SessionRegistry
    private let actions: WorkspaceActions
    private let paneContainer = PaneContainerView()
    private var tabBar: TabBarHostingView?
    private var shown: Display?
    /// The pane views on screen, by pane.
    private var visiblePanes: [PaneID: PaneView] = [:]
    private var displayTask: Task<Void, Never>?
    /// Divider drags not yet written to the model.
    private var pendingRatios: (tab: TabID, layout: PaneLayout)?
    private var ratioTask: Task<Void, Never>?

    /// How long divider drags wait before they are written to the model.
    private static let ratioDebounce: Duration = .milliseconds(400)

    /// What the pane area shows.
    private struct Display: Equatable {
        var tabID: TabID
        /// The layout on screen: the tab's, or only the zoomed pane.
        var layout: PaneLayout
        var focusedPaneID: PaneID
        var sessions: [PaneID: SessionID]
    }

    init(model: AppModel, workspaceID: WorkspaceID, registry: SessionRegistry, actions: WorkspaceActions) {
        self.model = model
        self.workspaceID = workspaceID
        self.registry = registry
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Set once the window has closed: nothing is shown or observed any more.
    private var isStopped = false

    isolated deinit {
        displayTask?.cancel()
        ratioTask?.cancel()
        #if DEBUG
        NSLog("Armadale: ContentViewController deinit (%@)", workspaceID.raw)
        #endif
    }

    /// The window is closing: writes pending divider positions, stops
    /// following the model, and lets go of the pane views (the registry
    /// keeps them for when the workspace is shown again). A controller that
    /// outlives its window can therefore never move panes back into it.
    func stop() {
        guard !isStopped else { return }
        commitRatios()
        isStopped = true
        displayTask?.cancel()
        displayTask = nil
        shown = nil
        visiblePanes = [:]
        paneContainer.splitTree.update(layout: nil) { _ in NSView() }
    }

    override func loadView() {
        let container = NSView()
        let frames = TabFrameStore()
        let tabBar = TabBarHostingView(rootView: TabBarView(
            model: model, registry: registry, workspaceID: workspaceID, actions: actions, frames: frames))
        tabBar.frames = frames
        tabBar.onMiddleClick = { [weak self] tab in self?.actions.closeTab(tab) }
        tabBar.onMouseDown = { [weak self] in self?.actions.rename.commit() }
        tabBar.sizingOptions = []
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        self.tabBar = tabBar

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.onNewTab = { [weak self] in self?.actions.newTab() }
        paneContainer.splitTree.onRatiosChanged = { [weak self] layout in self?.dividersMoved(layout) }

        container.addSubview(tabBar)
        container.addSubview(separator)
        container.addSubview(paneContainer)
        // The content view extends under the transparent title bar and the
        // floating sidebar; keep the tab bar and terminals inside the safe area.
        let safeArea = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: safeArea.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            separator.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            paneContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            paneContainer.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            paneContainer.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            paneContainer.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = model
        let workspaceID = workspaceID
        displayTask = Task { [weak self] in
            let displays = Observations { () -> Display? in
                guard let tab = model.selectedTab(in: workspaceID) else { return nil }
                let layout = tab.zoomedPaneID.map(PaneLayout.pane) ?? tab.layout
                return Display(
                    tabID: tab.id,
                    layout: layout,
                    focusedPaneID: tab.focusedPaneID,
                    sessions: Dictionary(
                        tab.panes.compactMap { pane in pane.sessionID.map { (pane.id, $0) } },
                        uniquingKeysWith: { first, _ in first }))
            }
            for await display in displays {
                guard let self else { return }
                self.show(display)
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusedPaneView?.focusTerminal()
    }

    /// The pane view of the focused pane, if it is on screen. `nil` for an
    /// empty pane (no session yet), which shows a plain view and is never
    /// given keyboard focus.
    var focusedPaneView: PaneView? {
        shown.flatMap { visiblePanes[$0.focusedPaneID] }
    }

    /// Called after a new display has been laid out (the New Session
    /// sheet waits for its pane to be on screen).
    var onDisplayed: (() -> Void)?

    /// Whether `pane` is on screen in a window, laid out.
    func isShowing(_ pane: PaneID) -> Bool {
        !isStopped && view.window != nil && shown?.layout.contains(pane) == true
    }

    /// A pane whose terminal takes keyboard focus once it is shown (a
    /// session just started from the New Session dialog).
    private var pendingFocus: PaneID?

    /// Gives `pane`'s terminal keyboard focus now if it is shown, else as
    /// soon as it is.
    func focusWhenShown(_ pane: PaneID) {
        if let view = visiblePanes[pane] {
            pendingFocus = nil
            view.focusTerminal()
        } else {
            pendingFocus = pane
        }
    }

    // MARK: Showing the model

    private func show(_ display: Display?) {
        guard !isStopped, display != shown else { return }
        // Divider drags still waiting go to the model first. If that changed
        // the model, this display is already stale: the next one follows.
        if pendingRatios != nil {
            let before = model.changeCount
            commitRatios()
            if model.changeCount != before { return }
        }
        let previous = shown
        shown = display
        guard let display else {
            paneContainer.splitTree.update(layout: nil) { _ in NSView() }
            paneContainer.showsEmptyState = model.workspace(workspaceID)?.selectedTabGroup != nil
            visiblePanes = [:]
            return
        }
        paneContainer.showsEmptyState = false

        var panes: [PaneID: PaneView] = [:]
        paneContainer.splitTree.update(layout: display.layout) { paneID in
            guard let sessionID = display.sessions[paneID], let pane = registry.paneView(for: sessionID) else {
                return paneContainer.blankView(for: paneID)
            }
            panes[paneID] = pane
            return pane
        }
        visiblePanes = panes

        let isSplit = panes.count > 1
        for (paneID, pane) in panes {
            pane.onClosePane = { [weak self] in self?.actions.closePane(paneID, confirm: false) }
            pane.focusStyle = !isSplit ? .alone : (paneID == display.focusedPaneID ? .focused : .unfocused)
        }

        // Lay out first so new sessions start at their pane's real size.
        view.layoutSubtreeIfNeeded()
        for paneID in display.layout.leaves() {
            if let sessionID = display.sessions[paneID] { registry.startIfNeeded(sessionID) }
        }

        // Keyboard focus follows the model. Only take it when the focus or
        // the tab changed, or when reparenting left the window with no
        // responder in a pane (never from the sidebar or a sheet otherwise).
        let focusChanged = previous?.tabID != display.tabID || previous?.focusedPaneID != display.focusedPaneID
        let responderLost = view.window.map { $0.firstResponder === $0 || $0.firstResponder == nil } ?? false
        if focusChanged || responderLost {
            focusedPaneView?.focusTerminal()
        }
        if let pending = pendingFocus, let pane = panes[pending] {
            pendingFocus = nil
            pane.focusTerminal()
        }
        onDisplayed?()
    }

    // MARK: From the view to the model

    /// The window's first responder changed: a click (or anything else)
    /// put it in a pane of this tab, so focus that pane in the model.
    func firstResponderDidChange(_ responder: NSResponder?) {
        guard let shown, let view = responder as? NSView else { return }
        guard let (paneID, _) = visiblePanes.first(where: { view.isDescendant(of: $0.value) }),
              paneID != shown.focusedPaneID
        else { return }
        model.focus(pane: paneID)
    }

    private func dividersMoved(_ layout: PaneLayout) {
        guard let tabID = shown?.tabID, shown?.layout.hasSameShape(as: layout) == true else { return }
        pendingRatios = (tabID, layout)
        ratioTask?.cancel()
        ratioTask = Task { [weak self] in
            try? await Task.sleep(for: Self.ratioDebounce)
            guard !Task.isCancelled else { return }
            self?.commitRatios()
        }
    }

    /// Writes pending divider positions to the model now.
    func commitRatios() {
        ratioTask?.cancel()
        ratioTask = nil
        guard let pending = pendingRatios else { return }
        pendingRatios = nil
        // Ignored by the model if the tab's shape changed meanwhile, or if
        // it is zoomed (the shown layout then is not the tab's).
        guard model.tab(pending.tab)?.zoomedPaneID == nil else { return }
        model.setSplitRatios(pending.layout, for: pending.tab)
    }
}

/// The pane area: the split tree, or a note with a New Tab button when the
/// selected tab group has no tabs.
@MainActor
final class PaneContainerView: NSView {
    let splitTree = SplitTreeView()
    var onNewTab: (() -> Void)?
    private var emptyState: NSHostingView<EmptyGroupView>?
    private var blankViews: [PaneID: NSView] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        splitTree.frame = bounds
        splitTree.autoresizingMask = [.width, .height]
        addSubview(splitTree)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var showsEmptyState: Bool = false {
        didSet {
            guard showsEmptyState != oldValue else { return }
            if showsEmptyState {
                let hosting = NSHostingView(rootView: EmptyGroupView { [weak self] in self?.onNewTab?() })
                hosting.frame = bounds
                hosting.autoresizingMask = [.width, .height]
                addSubview(hosting)
                emptyState = hosting
            } else {
                emptyState?.removeFromSuperview()
                emptyState = nil
            }
        }
    }

    /// Stands in for a pane whose session is missing (never expected: the
    /// saved state is repaired at launch), or an empty pane (no session
    /// yet): a plain view that never takes keyboard focus. Until step 10c
    /// the New Session dialog is shown over it as a sheet
    /// (``NewSessionPresenter``); 10c shows the chooser here instead.
    func blankView(for paneID: PaneID) -> NSView {
        if let view = blankViews[paneID] { return view }
        let view = NSView()
        blankViews[paneID] = view
        return view
    }
}

private struct EmptyGroupView: View {
    let newTab: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("This tab group has no tabs")
                .font(.title3.weight(.semibold))
            Button("New Tab", action: newTab)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
