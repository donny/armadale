import AppKit
import ArmadaleCore

/// Shows a tab's ``PaneLayout`` as nested `NSSplitView`s with one
/// ``PaneView`` per leaf.
///
/// Each update runs the layout through a ``SplitTreeReconciler``, which keeps
/// container identities stable, and then only touches what changed: a
/// container that keeps its identity keeps its `NSSplitView`, and a pane is
/// only reparented when its parent container changed. Pane views are never
/// created here (the ``SessionRegistry`` owns them), so terminals keep their
/// state; the caller restores first responder after an update.
///
/// Divider drags update the ratio locally at once and are reported through
/// ``onRatiosChanged`` with the whole layout; the caller writes them back to
/// the model (debounced). A model update with the same ratios is a no-op.
@MainActor
final class SplitTreeView: NSView {
    /// Called on every divider drag step with the layout as now shown.
    var onRatiosChanged: ((PaneLayout) -> Void)?

    private var tree: SplitTree?
    private var reconciler = SplitTreeReconciler()
    private var containers: [SplitNodeID: PaneSplitView] = [:]

    /// The layout currently shown (with any dragged ratios).
    var layout: PaneLayout? { tree?.layout }

    /// Shows `layout`, taking each leaf's view from `paneView`. `nil` shows
    /// nothing.
    func update(layout: PaneLayout?, paneView: (PaneID) -> NSView) {
        guard let layout else {
            tree = nil
            for container in containers.values { container.subviews = [] }
            containers = [:]
            if !subviews.isEmpty { subviews = [] }
            return
        }
        let newTree = reconciler.reconcile(tree, with: layout)
        var used = Set<SplitNodeID>()
        // Every view gets its final frame before anything is laid out inside
        // it, top-down: a new container that started at zero size would
        // otherwise squeeze the pane moved into it to nothing first, and its
        // terminal would resize (and rewrap) through a 2x1 grid.
        let root = view(for: newTree, frame: bounds, paneView: paneView, used: &used)
        // Containers left out are dropped. Whatever they still hold is not in
        // the new tree (panes of another tab, or closed ones): detach it, so
        // no pane keeps a parent outside the window.
        for (id, container) in containers where !used.contains(id) {
            container.subviews = []
            container.removeFromSuperview()
        }
        containers = containers.filter { used.contains($0.key) }
        root.autoresizingMask = [.width, .height]
        if subviews.count != 1 || subviews.first !== root {
            subviews = [root]
        }
        tree = newTree
    }

    private func view(
        for node: SplitTree, frame: NSRect, paneView: (PaneID) -> NSView, used: inout Set<SplitNodeID>
    ) -> NSView {
        switch node {
        case .pane(let id):
            let pane = paneView(id)
            if pane.frame != frame { pane.frame = frame }
            return pane
        case .split(let id, let axis, let ratio, let first, let second):
            used.insert(id)
            let container = containers[id] ?? makeContainer(id: id, axis: axis)
            if container.frame != frame { container.frame = frame }
            let (firstFrame, secondFrame) = container.childFrames(ratio: PaneLayout.clampedRatio(ratio))
            let firstView = view(for: first, frame: firstFrame, paneView: paneView, used: &used)
            let secondView = view(for: second, frame: secondFrame, paneView: paneView, used: &used)
            let structureChanged = container.setPanes(firstView, secondView)
            container.setRatio(ratio, relayout: structureChanged)
            return container
        }
    }

    private func makeContainer(id: SplitNodeID, axis: Axis) -> PaneSplitView {
        let container = PaneSplitView(nodeID: id, axis: axis)
        container.onUserResize = { [weak self] id, ratio in
            self?.userDidResize(id, ratio: ratio)
        }
        containers[id] = container
        return container
    }

    private func userDidResize(_ id: SplitNodeID, ratio: Double) {
        guard let tree else { return }
        let updated = tree.settingRatio(ratio, of: id)
        guard updated != tree else { return }
        self.tree = updated
        onRatiosChanged?(updated.layout)
    }
}

/// One split of a ``SplitTreeView``: two subviews laid out by `ratio` (the
/// share of the first), with a thin divider the user can drag.
@MainActor
final class PaneSplitView: NSSplitView {
    let nodeID: SplitNodeID
    /// The user dragged the divider; reports the new ratio.
    var onUserResize: ((SplitNodeID, Double) -> Void)?

    private(set) var ratio: Double = 0.5
    /// Set while this view positions its own subviews, so the resulting
    /// resize notifications are not taken for a drag.
    private var isApplyingRatio = false
    /// A separate object: an `NSSplitView` that is its own delegate recurses
    /// forever in `respondsToSelector:` (it forwards to its delegate).
    private let splitDelegate = PaneSplitViewDelegate()

    init(nodeID: SplitNodeID, axis: Axis) {
        self.nodeID = nodeID
        super.init(frame: .zero)
        // NSSplitView's "vertical" means vertical dividers: side by side.
        isVertical = axis == .horizontal
        dividerStyle = .thin
        splitDelegate.owner = self
        delegate = splitDelegate
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var dividerColor: NSColor { .separatorColor }

    /// Sets the ratio from the model; lays out again if it changed (or
    /// `relayout` asks for it).
    func setRatio(_ newRatio: Double, relayout: Bool) {
        let clamped = PaneLayout.clampedRatio(newRatio)
        guard relayout || abs(clamped - ratio) > 1e-6 else { return }
        ratio = clamped
        layoutByRatio()
    }

    /// Makes `first` and `second` the two arranged subviews, moving them
    /// here from wherever they are. Returns whether anything changed.
    func setPanes(_ first: NSView, _ second: NSView) -> Bool {
        let wanted = [first, second]
        let current = arrangedSubviews
        guard current.count != 2 || current[0] !== first || current[1] !== second else { return false }
        for view in current where !wanted.contains(where: { $0 === view }) {
            view.removeFromSuperview()
        }
        for (index, view) in wanted.enumerated() {
            let arranged = arrangedSubviews
            if arranged.count > index, arranged[index] === view { continue }
            if view.superview === self { removeArrangedSubview(view); view.removeFromSuperview() }
            insertArrangedSubview(view, at: min(index, arrangedSubviews.count))
        }
        return true
    }

    /// The window or the parent split resized this view: keep the ratio.
    /// (Not `super`: its proportional pass followed by a correction would
    /// give every nested pane two sizes, and its program two resizes.)
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutByRatio()
    }

    private var length: CGFloat { isVertical ? bounds.width : bounds.height }
    private var available: CGFloat { max(length - dividerThickness, 0) }

    /// The frames of the two subviews for `ratio` in the current bounds.
    func childFrames(ratio: Double) -> (NSRect, NSRect) {
        let firstLength = (available * ratio).rounded()
        let secondLength = available - firstLength
        let secondStart = firstLength + dividerThickness
        if isVertical {
            return (NSRect(x: 0, y: 0, width: firstLength, height: bounds.height),
                    NSRect(x: secondStart, y: 0, width: secondLength, height: bounds.height))
        }
        // NSSplitView is flipped: the first subview is on top at y = 0.
        let firstY = isFlipped ? 0 : bounds.height - firstLength
        let secondY = isFlipped ? secondStart : 0
        return (NSRect(x: 0, y: firstY, width: bounds.width, height: firstLength),
                NSRect(x: 0, y: secondY, width: bounds.width, height: secondLength))
    }

    /// Gives both subviews their final frames in one pass, then lets
    /// NSSplitView sync its divider to them. Nothing happens while the view
    /// has no size yet: laying panes out in an empty view would shrink their
    /// terminals to nothing and back.
    private func layoutByRatio() {
        let panes = arrangedSubviews
        guard panes.count == 2, available > 0, bounds.width > 0, bounds.height > 0 else { return }
        isApplyingRatio = true
        defer { isApplyingRatio = false }
        let (firstFrame, secondFrame) = childFrames(ratio: ratio)
        if panes[0].frame != firstFrame { panes[0].frame = firstFrame }
        if panes[1].frame != secondFrame { panes[1].frame = secondFrame }
        // Same position as the frames above, so nothing resizes again; this
        // only moves NSSplitView's own divider (drawn separately from the
        // subviews, it is left behind by plain frame changes).
        setPosition(isVertical ? firstFrame.width : firstFrame.height, ofDividerAt: 0)
    }

    // MARK: Delegate callbacks

    fileprivate func minimumCoordinate(proposed: CGFloat) -> CGFloat {
        max(proposed, (available * PaneLayout.ratioRange.lowerBound).rounded())
    }

    fileprivate func maximumCoordinate(proposed: CGFloat) -> CGFloat {
        min(proposed, (available * PaneLayout.ratioRange.upperBound).rounded())
    }

    fileprivate func didResizeSubviews(_ notification: Notification) {
        // Only a divider drag carries the divider index.
        guard !isApplyingRatio, notification.userInfo?["NSSplitViewDividerIndex"] != nil,
              arrangedSubviews.count == 2, available > 0
        else { return }
        let first = arrangedSubviews[0]
        let firstLength = isVertical ? first.frame.width : first.frame.height
        let newRatio = PaneLayout.clampedRatio(Double(firstLength / available))
        guard abs(newRatio - ratio) > 1e-6 else { return }
        ratio = newRatio
        onUserResize?(nodeID, newRatio)
    }
}

/// The delegate of a ``PaneSplitView``: keeps ratios in range and reports
/// divider drags.
@MainActor
private final class PaneSplitViewDelegate: NSObject, NSSplitViewDelegate {
    weak var owner: PaneSplitView?

    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        owner?.minimumCoordinate(proposed: proposedMinimumPosition) ?? proposedMinimumPosition
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        owner?.maximumCoordinate(proposed: proposedMaximumPosition) ?? proposedMaximumPosition
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        owner?.didResizeSubviews(notification)
    }
}
