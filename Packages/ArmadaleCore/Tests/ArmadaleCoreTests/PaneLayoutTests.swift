import Foundation
import Testing
@testable import ArmadaleCore

/// Readable fixed pane IDs for tests.
private let a = PaneID(raw: "a")
private let b = PaneID(raw: "b")
private let c = PaneID(raw: "c")
private let d = PaneID(raw: "d")
private let missing = PaneID(raw: "missing")

/// `a | b` side by side.
private let ab = PaneLayout.split(axis: .horizontal, ratio: 0.5, first: .pane(a), second: .pane(b))

/// ```
/// +---+---+
/// |   | b |
/// | a +---+
/// |   | c |
/// +---+---+
/// ```
private let aBC = PaneLayout.split(
    axis: .horizontal, ratio: 0.5,
    first: .pane(a),
    second: .split(axis: .vertical, ratio: 0.5, first: .pane(b), second: .pane(c)))

/// 2x2 grid: (a b / c d), built as two rows.
private let grid = PaneLayout.split(
    axis: .vertical, ratio: 0.5,
    first: .split(axis: .horizontal, ratio: 0.5, first: .pane(a), second: .pane(b)),
    second: .split(axis: .horizontal, ratio: 0.5, first: .pane(c), second: .pane(d)))

@Suite("PaneLayout")
struct PaneLayoutTests {
    @Test func containsAndLeaves() {
        #expect(aBC.contains(a))
        #expect(aBC.contains(c))
        #expect(!aBC.contains(missing))
        #expect(aBC.leaves() == [a, b, c])
        #expect(PaneLayout.pane(a).leaves() == [a])
    }

    @Test func splitSingleLeafPlacesNewPaneSecond() {
        let result = PaneLayout.pane(a).split(a, axis: .horizontal, newPane: b)
        #expect(result == ab)
    }

    @Test func splitCanPlaceNewPaneFirst() {
        let result = PaneLayout.pane(a).split(a, axis: .vertical, newPane: b, placeNewSecond: false)
        #expect(result == .split(axis: .vertical, ratio: 0.5, first: .pane(b), second: .pane(a)))
    }

    @Test func splitNestedLeafOnlyTouchesThatLeaf() {
        let result = ab.split(b, axis: .vertical, newPane: c)
        #expect(result == aBC)
    }

    @Test func splitMissingPaneIsNoOp() {
        #expect(aBC.split(missing, axis: .horizontal, newPane: d) == aBC)
    }

    @Test func removeOnlyLeafReturnsNil() {
        #expect(PaneLayout.pane(a).remove(a) == nil)
    }

    @Test func removeCollapsesParentIntoSibling() {
        #expect(ab.remove(a) == .pane(b))
        #expect(ab.remove(b) == .pane(a))
    }

    @Test func removeNestedCollapsesOnlyInnerSplit() {
        let result = aBC.remove(b)
        #expect(result == .split(axis: .horizontal, ratio: 0.5, first: .pane(a), second: .pane(c)))
    }

    @Test func removeKeepsRatiosOfUntouchedSplits() {
        let skewed = PaneLayout.split(
            axis: .horizontal, ratio: 0.3,
            first: .pane(a),
            second: .split(axis: .vertical, ratio: 0.7, first: .pane(b), second: .pane(c)))
        #expect(skewed.remove(c) == .split(axis: .horizontal, ratio: 0.3, first: .pane(a), second: .pane(b)))
    }

    @Test func removeMissingIsNoOp() {
        #expect(aBC.remove(missing) == aBC)
    }

    @Test func rectsFollowRatios() {
        let layout = PaneLayout.split(axis: .horizontal, ratio: 0.25, first: .pane(a), second: .pane(b))
        let rects = layout.rects()
        #expect(rects[a] == UnitRect(x: 0, y: 0, width: 0.25, height: 1))
        #expect(rects[b] == UnitRect(x: 0.25, y: 0, width: 0.75, height: 1))
    }

    @Test func neighborSimpleHorizontal() {
        #expect(ab.neighbor(of: a, direction: .right) == b)
        #expect(ab.neighbor(of: b, direction: .left) == a)
        #expect(ab.neighbor(of: a, direction: .left) == nil)
        #expect(ab.neighbor(of: a, direction: .up) == nil)
        #expect(ab.neighbor(of: a, direction: .down) == nil)
    }

    @Test func neighborAcrossNestedSplits() {
        #expect(aBC.neighbor(of: b, direction: .down) == c)
        #expect(aBC.neighbor(of: c, direction: .up) == b)
        #expect(aBC.neighbor(of: b, direction: .left) == a)
        #expect(aBC.neighbor(of: c, direction: .left) == a)
        // a overlaps both b and c equally: tie goes to the topmost.
        #expect(aBC.neighbor(of: a, direction: .right) == b)
    }

    @Test func neighborInGridIsGeometricNotStructural() {
        #expect(grid.neighbor(of: a, direction: .down) == c)
        #expect(grid.neighbor(of: b, direction: .down) == d)
        #expect(grid.neighbor(of: d, direction: .up) == b)
        #expect(grid.neighbor(of: c, direction: .right) == d)
        #expect(grid.neighbor(of: d, direction: .left) == c)
    }

    @Test func neighborPrefersLargerOverlap() {
        // Right column split 0.2/0.8: b is the short top pane, so from a the
        // larger overlap is c.
        let layout = PaneLayout.split(
            axis: .horizontal, ratio: 0.5,
            first: .pane(a),
            second: .split(axis: .vertical, ratio: 0.2, first: .pane(b), second: .pane(c)))
        #expect(layout.neighbor(of: a, direction: .right) == c)
    }

    @Test func neighborOfMissingPaneIsNil() {
        #expect(grid.neighbor(of: missing, direction: .left) == nil)
    }

    @Test func resizeGrowsFirstChild() {
        let result = ab.resize(a, axis: .horizontal, delta: 0.1)
        guard case .split(_, let ratio, _, _) = result else { Issue.record("not a split"); return }
        #expect(abs(ratio - 0.6) < 1e-9)
    }

    @Test func resizeGrowsSecondChildByShrinkingRatio() {
        let result = ab.resize(b, axis: .horizontal, delta: 0.1)
        guard case .split(_, let ratio, _, _) = result else { Issue.record("not a split"); return }
        #expect(abs(ratio - 0.4) < 1e-9)
    }

    @Test func resizeClampsToRange() {
        guard case .split(_, let high, _, _) = ab.resize(a, axis: .horizontal, delta: 5) else {
            Issue.record("not a split"); return
        }
        #expect(high == 0.9)
        guard case .split(_, let low, _, _) = ab.resize(a, axis: .horizontal, delta: -5) else {
            Issue.record("not a split"); return
        }
        #expect(low == 0.1)
    }

    @Test func resizeUsesNearestAncestorOnAxis() {
        // b's nearest vertical ancestor is the inner split; its horizontal one is the root.
        let vertical = aBC.resize(b, axis: .vertical, delta: 0.2)
        #expect(vertical == .split(
            axis: .horizontal, ratio: 0.5,
            first: .pane(a),
            second: .split(axis: .vertical, ratio: 0.7, first: .pane(b), second: .pane(c))))

        let horizontal = aBC.resize(b, axis: .horizontal, delta: 0.2)
        guard case .split(.horizontal, let ratio, _, let second) = horizontal else {
            Issue.record("unexpected shape"); return
        }
        #expect(abs(ratio - 0.3) < 1e-9)
        #expect(second == .split(axis: .vertical, ratio: 0.5, first: .pane(b), second: .pane(c)))
    }

    @Test func resizeWithoutMatchingAncestorIsNoOp() {
        #expect(ab.resize(a, axis: .vertical, delta: 0.2) == ab)
        #expect(PaneLayout.pane(a).resize(a, axis: .horizontal, delta: 0.2) == .pane(a))
    }

    @Test func swapExchangesLeaves() {
        let result = aBC.swap(a, c)
        #expect(result.leaves() == [c, b, a])
        #expect(aBC.swap(a, missing) == aBC)
        #expect(aBC.swap(a, a) == aBC)
    }

    @Test func equalizedResetsEveryRatio() {
        let skewed = PaneLayout.split(
            axis: .horizontal, ratio: 0.2,
            first: .pane(a),
            second: .split(axis: .vertical, ratio: 0.85, first: .pane(b), second: .pane(c)))
        #expect(skewed.equalized() == aBC)
    }

    @Test func equalizedWeightsNestedColumnsByPaneCount() {
        // ((a | b) | c): three columns built from two nested horizontal splits.
        let columns = PaneLayout.split(
            axis: .horizontal, ratio: 0.5,
            first: .split(axis: .horizontal, ratio: 0.3, first: .pane(a), second: .pane(b)),
            second: .pane(c))
        let expected = PaneLayout.split(
            axis: .horizontal, ratio: 2.0 / 3.0,
            first: .split(axis: .horizontal, ratio: 0.5, first: .pane(a), second: .pane(b)),
            second: .pane(c))
        #expect(columns.equalized() == expected)
        // A split across the axis does not add columns: (a | (b / c)) stays 50/50.
        let mixed = PaneLayout.split(
            axis: .horizontal, ratio: 0.2,
            first: .pane(a),
            second: .split(axis: .vertical, ratio: 0.85, first: .pane(b), second: .pane(c)))
        #expect(mixed.equalized() == aBC)
    }

    @Test func replaceSwapsLeafForSubtree() {
        let result = ab.replace(b, with: .split(axis: .vertical, ratio: 0.5, first: .pane(b), second: .pane(c)))
        #expect(result == aBC)
        #expect(ab.replace(missing, with: .pane(d)) == ab)
    }

    @Test func codableRoundTripAndShape() throws {
        let (p, q, r) = (PaneID.generate(), PaneID.generate(), PaneID.generate())
        let layout = PaneLayout.split(
            axis: .horizontal, ratio: 0.3,
            first: .pane(p),
            second: .split(axis: .vertical, ratio: 0.6, first: .pane(q), second: .pane(r)))
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(PaneLayout.self, from: data) == layout)
        let json = String(decoding: try JSONEncoder().encode(PaneLayout.pane(p)), as: UTF8.self)
        #expect(json == "{\"pane\":\"\(p.raw)\"}")
    }

    @Test func decodingClampsRatioToResizeRange() throws {
        let (p, q) = ("aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb")
        for (written, expected) in [(1.5, 0.9), (0.0, 0.1), (-3.0, 0.1), (0.95, 0.9), (0.42, 0.42)] {
            let json = Data(#"{"split":{"axis":"horizontal","ratio":\#(written),"first":{"pane":"\#(p)"},"second":{"pane":"\#(q)"}}}"#.utf8)
            let layout = try JSONDecoder().decode(PaneLayout.self, from: json)
            guard case .split(_, let ratio, _, _) = layout else { Issue.record("not a split"); continue }
            #expect(ratio == expected, "ratio \(written)")
        }
    }

    @Test func decodingRejectsMalformedPaneID() {
        let json = Data(#"{"pane":"not-an-id"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PaneLayout.self, from: json) }
    }

    @Test func splitWithExistingNewPaneIsNoOp() {
        #expect(ab.split(a, axis: .vertical, newPane: b) == ab)
        #expect(ab.split(a, axis: .vertical, newPane: a) == ab)
    }

    @Test func resizeWithNonFiniteDeltaIsNoOp() throws {
        for delta in [Double.nan, .infinity, -.infinity] {
            #expect(ab.resize(a, axis: .horizontal, delta: delta) == ab)
        }
        // A resized tree must always stay encodable.
        _ = try JSONEncoder().encode(ab.resize(a, axis: .horizontal, delta: .nan))
    }

    @Test func focusSuccessorPrefersSiblingBranch() {
        // a | (b / c): closing c focuses b (its sibling), not a (geometrically left).
        #expect(aBC.focusSuccessor(afterRemoving: c) == b)
        #expect(aBC.focusSuccessor(afterRemoving: b) == c)
        // Closing a: the sibling branch is (b / c); the adjacent leaf nearest
        // the top wins the tie.
        #expect(aBC.focusSuccessor(afterRemoving: a) == b)
        #expect(ab.focusSuccessor(afterRemoving: b) == a)
        #expect(PaneLayout.pane(a).focusSuccessor(afterRemoving: a) == nil)
        #expect(aBC.focusSuccessor(afterRemoving: missing) == nil)
    }

    @Test func focusSuccessorPicksAdjacentLeafInsideSiblingSubtree() {
        // x | ((a | b) / c): closing x focuses a, the leaf of the sibling
        // branch that touches x (b does not), topmost on ties with c.
        // In the 2x2 grid, closing c focuses d, its sibling in the bottom row.
        let x = PaneID(raw: "x")
        let layout = PaneLayout.split(
            axis: .horizontal, ratio: 0.5,
            first: .pane(x),
            second: .split(
                axis: .vertical, ratio: 0.5,
                first: .split(axis: .horizontal, ratio: 0.5, first: .pane(a), second: .pane(b)),
                second: .pane(c)))
        #expect(layout.focusSuccessor(afterRemoving: x) == a)
        #expect(grid.focusSuccessor(afterRemoving: c) == d)
    }

    @Test func removingDuplicateLeavesKeepsFirstOccurrence() {
        let duplicated = PaneLayout.split(axis: .horizontal, ratio: 0.5, first: .pane(a), second: ab)
        #expect(duplicated.removingDuplicateLeaves() == ab)
        #expect(aBC.removingDuplicateLeaves() == aBC)
    }
}
