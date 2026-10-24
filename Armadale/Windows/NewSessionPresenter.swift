import AppKit
import ArmadaleCore
import Observation

// Step 10b interim: the chooser replaces this in 10c.
/// Until the New Session chooser exists (step 10c), every empty pane of a
/// workspace gets the New Session dialog as soon as its window can show
/// it: new tabs, tab groups and splits, a new workspace (⌘N), the fresh
/// workspace at launch, a reopened workspace's fresh group, and an empty
/// pane restored from the state file. One sheet at a time per window; the
/// next empty pane is asked about once the sheet before has gone. The
/// pane is revealed first (its tab selected, focused, unzoomed) when it is
/// not on screen, and the sheet comes after the window is on screen and the
/// pane laid out. Cancel closes the pane (``WorkspaceActions/cancelNewSession(in:)``).
///
/// It looks again whenever the workspace's empty panes change, the content
/// has shown a new layout, the window became key, a sheet of the window
/// ended, or a full-screen transition ended. A sheet whose pane was closed
/// or started elsewhere is taken down.
@MainActor
final class NewSessionPresenter {
    private let model: AppModel
    private let workspaceID: WorkspaceID
    private unowned let actions: WorkspaceActions
    /// Whether the content shows `pane`, laid out, in the window.
    var isShowing: (PaneID) -> Bool = { _ in false }
    /// Whether a sheet may be presented now: the window is on screen and
    /// key-able, has no sheet, is not closing and is not in a full-screen
    /// transition.
    var canPresent: () -> Bool = { false }
    /// Set while a quit is under way: nothing is presented.
    var isSuspended = false
    private var task: Task<Void, Never>?
    /// A look is scheduled for the next turn of the main actor.
    private var isCheckScheduled = false

    init(model: AppModel, workspaceID: WorkspaceID, actions: WorkspaceActions) {
        self.model = model
        self.workspaceID = workspaceID
        self.actions = actions
    }

    isolated deinit {
        task?.cancel()
    }

    /// Follows the workspace's empty panes.
    func start() {
        guard task == nil else { return }
        let model = model
        let workspaceID = workspaceID
        task = Task { [weak self] in
            for await _ in Observations({ model.emptyPaneIDs(in: workspaceID) }) {
                guard let self else { return }
                self.check()
            }
        }
    }

    /// The window is closing: nothing more is asked, and a sheet up is
    /// taken down.
    func stop() {
        task?.cancel()
        task = nil
        actions.endNewSessionSheet()
    }

    /// Looks on the next turn of the main actor, after the event at hand
    /// (a layout, a sheet ending) has finished.
    func check() {
        guard task != nil, !isCheckScheduled else { return }
        isCheckScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isCheckScheduled = false
            self.checkNow()
        }
    }

    private func checkNow() {
        guard task != nil else { return }
        if let pane = actions.newSessionPane {
            if Self.sheetIsStale(for: pane, in: model, workspace: workspaceID) { actions.endNewSessionSheet() }
            return
        }
        guard !isSuspended, canPresent(), let pane = Self.nextPane(in: model, workspace: workspaceID) else { return }
        guard isShowing(pane) else {
            // Shown after the content lays it out, which looks again.
            Self.reveal(pane, in: model, workspace: workspaceID)
            return
        }
        actions.newSession(in: pane)
    }

    /// Whether the sheet up for `pane` must go: the pane was closed, given
    /// a session, or moved to another workspace (its tab dragged away),
    /// whose window asks about it instead.
    static func sheetIsStale(for pane: PaneID, in model: AppModel, workspace: WorkspaceID) -> Bool {
        !model.emptyPaneIDs(in: workspace).contains(pane)
    }

    /// Which empty pane of `workspace` is asked about next: the focused
    /// pane of the selected tab if it is empty, else an empty pane of that
    /// tab (in layout order), else the first empty pane of the workspace
    /// (tab and layout order); `nil` when it has none.
    static func nextPane(in model: AppModel, workspace: WorkspaceID) -> PaneID? {
        let empty = model.emptyPaneIDs(in: workspace)
        guard let first = empty.first else { return nil }
        if let tab = model.selectedTab(in: workspace) {
            let visible = tab.zoomedPaneID.map { [$0] } ?? tab.layout.leaves()
            if visible.contains(tab.focusedPaneID), empty.contains(tab.focusedPaneID) { return tab.focusedPaneID }
            if let pane = visible.first(where: empty.contains) { return pane }
        }
        return first
    }

    /// Brings `pane` on screen: selects its tab group and tab, focuses it,
    /// and unzooms its tab if another pane is zoomed.
    static func reveal(_ pane: PaneID, in model: AppModel, workspace: WorkspaceID) {
        model.focus(pane: pane)
        if let tab = model.selectedTab(in: workspace), let zoomed = tab.zoomedPaneID, zoomed != pane {
            model.toggleZoom(in: workspace)
        }
    }
}
