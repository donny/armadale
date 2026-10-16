/// The orientation of a split.
public enum Axis: String, Codable, Sendable, Hashable, CaseIterable {
    /// Children side by side: `first` on the left, `second` on the right.
    case horizontal
    /// Children stacked: `first` on top, `second` below.
    case vertical
}

/// A direction for geometric pane navigation.
public enum Direction: String, Codable, Sendable, Hashable, CaseIterable {
    case left, right, up, down
}

/// A rectangle in the unit square, with the origin at the top-left and `y`
/// growing downward. Used for geometric queries over a ``PaneLayout``.
public struct UnitRect: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The whole unit square.
    public static let unit = UnitRect(x: 0, y: 0, width: 1, height: 1)

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
}

/// A tab's binary split tree. Leaves are panes; internal nodes split their
/// space between `first` and `second` along an ``Axis`` with `ratio` being the
/// fraction given to `first`.
///
/// All operations are pure and return a new value. Operations addressed at a
/// pane that is not in the tree return the tree unchanged.
public indirect enum PaneLayout: Sendable, Hashable {
    case pane(PaneID)
    case split(axis: Axis, ratio: Double, first: PaneLayout, second: PaneLayout)

    /// The range every split ratio is kept in, by ``resize(_:axis:delta:)``
    /// and when decoding.
    public static let ratioRange: ClosedRange<Double> = 0.1...0.9

    /// `ratio` clamped to ``ratioRange``.
    public static func clampedRatio(_ ratio: Double) -> Double {
        min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
    }

    // MARK: Queries

    /// Whether `pane` is a leaf of this tree.
    public func contains(_ pane: PaneID) -> Bool {
        switch self {
        case .pane(let id): id == pane
        case .split(_, _, let first, let second): first.contains(pane) || second.contains(pane)
        }
    }

    /// Leaves in reading order (depth first, `first` before `second`).
    public func leaves() -> [PaneID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let first, let second): first.leaves() + second.leaves()
        }
    }

    /// The normalized rectangle of every leaf when this tree fills `bounds`.
    public func rects(in bounds: UnitRect = .unit) -> [PaneID: UnitRect] {
        switch self {
        case .pane(let id):
            return [id: bounds]
        case .split(let axis, let ratio, let first, let second):
            let (a, b) = Self.divide(bounds, axis: axis, ratio: ratio)
            return first.rects(in: a).merging(second.rects(in: b)) { lhs, _ in lhs }
        }
    }

    private static func divide(_ rect: UnitRect, axis: Axis, ratio: Double) -> (UnitRect, UnitRect) {
        switch axis {
        case .horizontal:
            let w = rect.width * ratio
            return (UnitRect(x: rect.x, y: rect.y, width: w, height: rect.height),
                    UnitRect(x: rect.x + w, y: rect.y, width: rect.width - w, height: rect.height))
        case .vertical:
            let h = rect.height * ratio
            return (UnitRect(x: rect.x, y: rect.y, width: rect.width, height: h),
                    UnitRect(x: rect.x, y: rect.y + h, width: rect.width, height: rect.height - h))
        }
    }

    /// The nearest pane in `direction` from `pane`, judged geometrically.
    ///
    /// Candidates are leaves lying entirely on the requested side of `pane`
    /// whose extent overlaps it on the perpendicular axis. The closest edge
    /// wins; ties go to the larger overlap, then to the candidate nearest the
    /// top-left.
    public func neighbor(of pane: PaneID, direction: Direction) -> PaneID? {
        let rects = rects()
        guard let current = rects[pane] else { return nil }
        let epsilon = 1e-9

        struct Candidate {
            let id: PaneID
            let distance: Double
            let overlap: Double
            let rect: UnitRect
        }

        func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
            min(a1, b1) - max(a0, b0)
        }

        var candidates: [Candidate] = []
        for (id, rect) in rects where id != pane {
            let distance: Double
            let shared: Double
            switch direction {
            case .left:
                guard rect.maxX <= current.minX + epsilon else { continue }
                distance = current.minX - rect.maxX
                shared = overlap(rect.minY, rect.maxY, current.minY, current.maxY)
            case .right:
                guard rect.minX >= current.maxX - epsilon else { continue }
                distance = rect.minX - current.maxX
                shared = overlap(rect.minY, rect.maxY, current.minY, current.maxY)
            case .up:
                guard rect.maxY <= current.minY + epsilon else { continue }
                distance = current.minY - rect.maxY
                shared = overlap(rect.minX, rect.maxX, current.minX, current.maxX)
            case .down:
                guard rect.minY >= current.maxY - epsilon else { continue }
                distance = rect.minY - current.maxY
                shared = overlap(rect.minX, rect.maxX, current.minX, current.maxX)
            }
            guard shared > epsilon else { continue }
            candidates.append(Candidate(id: id, distance: distance, overlap: shared, rect: rect))
        }

        return candidates.min { a, b in
            if abs(a.distance - b.distance) > epsilon { return a.distance < b.distance }
            if abs(a.overlap - b.overlap) > epsilon { return a.overlap > b.overlap }
            if abs(a.rect.minY - b.rect.minY) > epsilon { return a.rect.minY < b.rect.minY }
            if abs(a.rect.minX - b.rect.minX) > epsilon { return a.rect.minX < b.rect.minX }
            return a.id < b.id
        }?.id
    }

    // MARK: Transformations

    /// Splits `pane` along `axis`, inserting `newPane` beside it with an even
    /// ratio. `placeNewSecond` puts the new pane right of / below the original.
    /// Unchanged if `pane` is missing or `newPane` is already in the tree.
    public func split(_ pane: PaneID, axis: Axis, newPane: PaneID, placeNewSecond: Bool = true) -> PaneLayout {
        guard contains(pane), !contains(newPane) else { return self }
        return replace(pane) { leaf in
            let new = PaneLayout.pane(newPane)
            return placeNewSecond
                ? .split(axis: axis, ratio: 0.5, first: leaf, second: new)
                : .split(axis: axis, ratio: 0.5, first: new, second: leaf)
        }
    }

    /// Removes `pane`, collapsing its parent split into the sibling.
    /// Returns `nil` when `pane` was the only leaf.
    public func remove(_ pane: PaneID) -> PaneLayout? {
        switch self {
        case .pane(let id):
            return id == pane ? nil : self
        case .split(let axis, let ratio, let first, let second):
            guard contains(pane) else { return self }
            guard let newFirst = first.remove(pane) else { return second }
            guard let newSecond = second.remove(pane) else { return first }
            return .split(axis: axis, ratio: ratio, first: newFirst, second: newSecond)
        }
    }

    /// Grows `pane` by `delta` (a fraction of the enclosing split; negative
    /// shrinks) by adjusting its nearest ancestor split along `axis`. The
    /// resulting ratio is clamped to ``ratioRange``. Unchanged if no such
    /// ancestor exists or `delta` is not finite.
    public func resize(_ pane: PaneID, axis: Axis, delta: Double) -> PaneLayout {
        guard delta.isFinite else { return self }
        return resized(pane, axis: axis, delta: delta).layout
    }

    /// Returns the new layout and whether an ancestor split was found below this node.
    private func resized(_ pane: PaneID, axis: Axis, delta: Double) -> (layout: PaneLayout, handled: Bool) {
        guard case .split(let splitAxis, let ratio, let first, let second) = self else {
            return (self, false)
        }
        let inFirst = first.contains(pane)
        guard inFirst || second.contains(pane) else { return (self, false) }

        // Prefer the deepest matching split, which is the nearest ancestor.
        let child = inFirst ? first : second
        let result = child.resized(pane, axis: axis, delta: delta)
        if result.handled {
            let rebuilt: PaneLayout = inFirst
                ? .split(axis: splitAxis, ratio: ratio, first: result.layout, second: second)
                : .split(axis: splitAxis, ratio: ratio, first: first, second: result.layout)
            return (rebuilt, true)
        }
        guard splitAxis == axis else { return (self, false) }
        let proposed = inFirst ? ratio + delta : ratio - delta
        return (.split(axis: splitAxis, ratio: Self.clampedRatio(proposed), first: first, second: second), true)
    }

    /// Exchanges the positions of panes `a` and `b`. Unchanged unless both are present.
    public func swap(_ a: PaneID, _ b: PaneID) -> PaneLayout {
        guard a != b, contains(a), contains(b) else { return self }
        return mapLeaves { id in
            if id == a { return b }
            if id == b { return a }
            return id
        }
    }

    /// The pane that should take focus when `pane` is removed: the nearest
    /// leaf of its sibling branch, i.e. the sibling leaf adjacent to `pane`
    /// across their parent split. Returns `nil` if `pane` is missing or is
    /// the only leaf.
    public func focusSuccessor(afterRemoving pane: PaneID) -> PaneID? {
        guard let (axis, paneIsFirst, sibling) = parentSplit(of: pane) else { return nil }
        let towardSibling: Direction = switch (axis, paneIsFirst) {
        case (.horizontal, true): .right
        case (.horizontal, false): .left
        case (.vertical, true): .down
        case (.vertical, false): .up
        }
        // The sibling fills the parent's other side, so the nearest leaf in
        // that direction lies in the sibling branch.
        if let neighbor = neighbor(of: pane, direction: towardSibling), sibling.contains(neighbor) {
            return neighbor
        }
        return sibling.leaves().first
    }

    /// The axis of `pane`'s parent split, whether `pane` is its first child,
    /// and the sibling subtree.
    private func parentSplit(of pane: PaneID) -> (Axis, Bool, PaneLayout)? {
        guard case .split(let axis, _, let first, let second) = self else { return nil }
        if case .pane(pane) = first { return (axis, true, second) }
        if case .pane(pane) = second { return (axis, false, first) }
        return first.parentSplit(of: pane) ?? second.parentSplit(of: pane)
    }

    /// The tree with any repeated leaf removed (the first occurrence is
    /// kept). Returns `nil` only if nothing would remain, which cannot happen
    /// for a non-empty tree.
    public func removingDuplicateLeaves() -> PaneLayout? {
        var seen = Set<PaneID>()
        return removingDuplicateLeaves(seen: &seen)
    }

    private func removingDuplicateLeaves(seen: inout Set<PaneID>) -> PaneLayout? {
        switch self {
        case .pane(let id):
            return seen.insert(id).inserted ? self : nil
        case .split(let axis, let ratio, let first, let second):
            let newFirst = first.removingDuplicateLeaves(seen: &seen)
            let newSecond = second.removingDuplicateLeaves(seen: &seen)
            switch (newFirst, newSecond) {
            case let (a?, b?): return .split(axis: axis, ratio: ratio, first: a, second: b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            case (nil, nil): return nil
            }
        }
    }

    /// The same tree with every split ratio reset to 0.5.
    public func equalized() -> PaneLayout {
        switch self {
        case .pane: self
        case .split(let axis, _, let first, let second):
            .split(axis: axis, ratio: 0.5, first: first.equalized(), second: second.equalized())
        }
    }

    /// Replaces the leaf `pane` with `replacement` (a single pane or a subtree).
    public func replace(_ pane: PaneID, with replacement: PaneLayout) -> PaneLayout {
        replace(pane) { _ in replacement }
    }

    private func replace(_ pane: PaneID, transform: (PaneLayout) -> PaneLayout) -> PaneLayout {
        switch self {
        case .pane(let id):
            return id == pane ? transform(self) : self
        case .split(let axis, let ratio, let first, let second):
            return .split(
                axis: axis, ratio: ratio,
                first: first.replace(pane, transform: transform),
                second: second.replace(pane, transform: transform))
        }
    }

    private func mapLeaves(_ transform: (PaneID) -> PaneID) -> PaneLayout {
        switch self {
        case .pane(let id): .pane(transform(id))
        case .split(let axis, let ratio, let first, let second):
            .split(axis: axis, ratio: ratio, first: first.mapLeaves(transform), second: second.mapLeaves(transform))
        }
    }
}

// MARK: - Codable

/// JSON shape: `{"pane": "<id>"}` or
/// `{"split": {"axis": "horizontal", "ratio": 0.5, "first": …, "second": …}}`.
extension PaneLayout: Codable {
    private enum CodingKeys: String, CodingKey { case pane, split }
    private enum SplitKeys: String, CodingKey { case axis, ratio, first, second }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(PaneID.self, forKey: .pane) {
            self = .pane(id)
            return
        }
        guard container.contains(.split) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "PaneLayout needs a \"pane\" or \"split\" key"))
        }
        let split = try container.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
        let ratio = try split.decode(Double.self, forKey: .ratio)
        guard ratio.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .ratio, in: split, debugDescription: "Split ratio is not a finite number")
        }
        self = .split(
            axis: try split.decode(Axis.self, forKey: .axis),
            ratio: Self.clampedRatio(ratio), // hand-edited files may exceed the range
            first: try split.decode(PaneLayout.self, forKey: .first),
            second: try split.decode(PaneLayout.self, forKey: .second))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let id):
            try container.encode(id, forKey: .pane)
        case .split(let axis, let ratio, let first, let second):
            var split = container.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            try split.encode(axis, forKey: .axis)
            try split.encode(ratio, forKey: .ratio)
            try split.encode(first, forKey: .first)
            try split.encode(second, forKey: .second)
        }
    }
}
