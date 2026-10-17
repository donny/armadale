/// Identity of one split container in a rendered split tree. The app keeps
/// one `NSSplitView` per ID, so a container that keeps its ID keeps its
/// view, and the panes inside it are not reparented.
public struct SplitNodeID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let raw: Int

    public init(raw: Int) {
        self.raw = raw
    }

    public static func < (lhs: SplitNodeID, rhs: SplitNodeID) -> Bool { lhs.raw < rhs.raw }
    public var description: String { "#\(raw)" }
}

/// A ``PaneLayout`` as rendered: the same tree, with an identity on every
/// split container. ``SplitTreeReconciler`` assigns the identities so that
/// a layout change keeps as many containers (and therefore views) as it can.
public indirect enum SplitTree: Hashable, Sendable {
    case pane(PaneID)
    case split(id: SplitNodeID, axis: Axis, ratio: Double, first: SplitTree, second: SplitTree)

    /// The layout this tree renders.
    public var layout: PaneLayout {
        switch self {
        case .pane(let id): .pane(id)
        case .split(_, let axis, let ratio, let first, let second):
            .split(axis: axis, ratio: ratio, first: first.layout, second: second.layout)
        }
    }

    /// Leaves in reading order.
    public func leaves() -> [PaneID] {
        layout.leaves()
    }

    /// Every container ID, top-down, `first` before `second`.
    public var splitIDs: [SplitNodeID] {
        switch self {
        case .pane: []
        case .split(let id, _, _, let first, let second): [id] + first.splitIDs + second.splitIDs
        }
    }

    /// The tree with container `id`'s ratio replaced (clamped to
    /// ``PaneLayout/ratioRange``). Unchanged if `id` is not in the tree.
    public func settingRatio(_ ratio: Double, of id: SplitNodeID) -> SplitTree {
        guard case .split(let nodeID, let axis, let current, let first, let second) = self else { return self }
        let newRatio = nodeID == id && ratio.isFinite ? PaneLayout.clampedRatio(ratio) : current
        return .split(
            id: nodeID, axis: axis, ratio: newRatio,
            first: first.settingRatio(ratio, of: id), second: second.settingRatio(ratio, of: id))
    }
}

/// Turns successive ``PaneLayout``s of one view into ``SplitTree``s, keeping
/// container identities stable across changes. Pure; the app's
/// `SplitTreeView` mirrors the result with nested `NSSplitView`s.
///
/// A split of the new layout keeps the ID of an old container when
/// 1. the old container held exactly the same panes along the same axis
///    (a subtree that moved, for example when closing a pane collapses its
///    parent and the sibling subtree moves up), or else
/// 2. the old tree had a container with the same axis at the same position
///    and rule 1 did not claim it (a container that gained or lost panes
///    below it, for example the parent of a pane that was split).
///
/// Every other split gets a new ID. No ID is used twice in one tree, and
/// IDs are never reused once dropped.
public struct SplitTreeReconciler: Sendable {
    private var nextID: Int

    public init(firstID: Int = 1) {
        nextID = firstID
    }

    private struct Key: Hashable {
        var axis: Axis
        var panes: Set<PaneID>
    }

    /// The tree for `layout`, reusing what it can from `old`.
    public mutating func reconcile(_ old: SplitTree?, with layout: PaneLayout) -> SplitTree {
        var oldByKey: [Key: SplitNodeID] = [:]
        if let old { Self.collect(old, into: &oldByKey) }

        // Rule 1 first, for the whole tree, so a position match can never
        // take a container that an exact match elsewhere should keep.
        var newKeys = Set<Key>()
        Self.collectKeys(layout, into: &newKeys)
        var claimed = Set<SplitNodeID>()
        var exact: [Key: SplitNodeID] = [:]
        for key in newKeys {
            if let id = oldByKey[key] {
                exact[key] = id
                claimed.insert(id)
            }
        }
        return build(layout, old: old, exact: exact, claimed: &claimed)
    }

    private mutating func build(
        _ layout: PaneLayout, old: SplitTree?, exact: [Key: SplitNodeID], claimed: inout Set<SplitNodeID>
    ) -> SplitTree {
        switch layout {
        case .pane(let id):
            return .pane(id)
        case .split(let axis, let ratio, let first, let second):
            let key = Key(axis: axis, panes: Set(layout.leaves()))
            var oldFirst: SplitTree?
            var oldSecond: SplitTree?
            let id: SplitNodeID
            if let match = exact[key] {
                id = match
                if let old, let node = Self.find(match, in: old), case .split(_, _, _, let f, let s) = node {
                    oldFirst = f
                    oldSecond = s
                }
            } else if case .split(let oldID, let oldAxis, _, let f, let s)? = old,
                      oldAxis == axis, !claimed.contains(oldID) {
                id = oldID
                claimed.insert(oldID)
                oldFirst = f
                oldSecond = s
            } else {
                id = SplitNodeID(raw: nextID)
                nextID += 1
            }
            return .split(
                id: id, axis: axis, ratio: ratio,
                first: build(first, old: oldFirst, exact: exact, claimed: &claimed),
                second: build(second, old: oldSecond, exact: exact, claimed: &claimed))
        }
    }

    private static func collect(_ tree: SplitTree, into map: inout [Key: SplitNodeID]) {
        guard case .split(let id, let axis, _, let first, let second) = tree else { return }
        map[Key(axis: axis, panes: Set(tree.leaves()))] = id
        collect(first, into: &map)
        collect(second, into: &map)
    }

    private static func collectKeys(_ layout: PaneLayout, into keys: inout Set<Key>) {
        guard case .split(let axis, _, let first, let second) = layout else { return }
        keys.insert(Key(axis: axis, panes: Set(layout.leaves())))
        collectKeys(first, into: &keys)
        collectKeys(second, into: &keys)
    }

    private static func find(_ id: SplitNodeID, in tree: SplitTree) -> SplitTree? {
        guard case .split(let nodeID, _, _, let first, let second) = tree else { return nil }
        if nodeID == id { return tree }
        return find(id, in: first) ?? find(id, in: second)
    }
}
