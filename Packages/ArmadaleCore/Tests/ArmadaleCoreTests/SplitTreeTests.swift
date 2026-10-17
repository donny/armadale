import Foundation
import Testing
@testable import ArmadaleCore

private let a = PaneID(raw: "a")
private let b = PaneID(raw: "b")
private let c = PaneID(raw: "c")
private let d = PaneID(raw: "d")

private func h(_ first: PaneLayout, _ second: PaneLayout, _ ratio: Double = 0.5) -> PaneLayout {
    .split(axis: .horizontal, ratio: ratio, first: first, second: second)
}

private func v(_ first: PaneLayout, _ second: PaneLayout, _ ratio: Double = 0.5) -> PaneLayout {
    .split(axis: .vertical, ratio: ratio, first: first, second: second)
}

/// The container holding exactly `panes`, if any.
private func container(holding panes: Set<PaneID>, in tree: SplitTree) -> SplitNodeID? {
    guard case .split(let id, _, _, let first, let second) = tree else { return nil }
    if Set(tree.leaves()) == panes { return id }
    return container(holding: panes, in: first) ?? container(holding: panes, in: second)
}

@Suite("SplitTreeReconciler")
struct SplitTreeTests {
    @Test func firstRenderAssignsFreshIDsAndMirrorsLayout() {
        var reconciler = SplitTreeReconciler()
        let layout = h(.pane(a), v(.pane(b), .pane(c)), 0.3)
        let tree = reconciler.reconcile(nil, with: layout)
        #expect(tree.layout == layout)
        #expect(tree.splitIDs == [SplitNodeID(raw: 1), SplitNodeID(raw: 2)])
        #expect(tree.leaves() == [a, b, c])
        #expect(reconciler.reconcile(nil, with: .pane(a)) == .pane(a))
    }

    @Test func unchangedLayoutKeepsEveryID() {
        var reconciler = SplitTreeReconciler()
        let layout = h(.pane(a), v(.pane(b), .pane(c)))
        let first = reconciler.reconcile(nil, with: layout)
        let second = reconciler.reconcile(first, with: layout)
        #expect(first == second)
    }

    @Test func ratioChangeKeepsIDs() {
        var reconciler = SplitTreeReconciler()
        let first = reconciler.reconcile(nil, with: h(.pane(a), v(.pane(b), .pane(c))))
        let second = reconciler.reconcile(first, with: h(.pane(a), v(.pane(b), .pane(c), 0.8), 0.2))
        #expect(second.splitIDs == first.splitIDs)
        #expect(second.layout == h(.pane(a), v(.pane(b), .pane(c), 0.8), 0.2))
    }

    @Test func splittingALeafKeepsItsParentContainer() {
        // a | b  →  a | (b / c): the root keeps its ID (same axis, same
        // place), so `a` stays where it is; only the new inner split is new.
        var reconciler = SplitTreeReconciler()
        let before = reconciler.reconcile(nil, with: h(.pane(a), .pane(b)))
        let after = reconciler.reconcile(before, with: h(.pane(a), v(.pane(b), .pane(c))))
        #expect(after.splitIDs.first == before.splitIDs.first)
        #expect(after.splitIDs.count == 2)
        #expect(!before.splitIDs.contains(after.splitIDs[1]))
    }

    @Test func closingAPaneMovesTheSiblingSubtreeWithItsContainer() {
        // a | (b / c)  →  b / c: the inner container moves up intact.
        var reconciler = SplitTreeReconciler()
        let before = reconciler.reconcile(nil, with: h(.pane(a), v(.pane(b), .pane(c))))
        let inner = container(holding: [b, c], in: before)
        let after = reconciler.reconcile(before, with: v(.pane(b), .pane(c)))
        #expect(after.splitIDs == [inner].compactMap { $0 })
    }

    @Test func exactMatchWinsOverPositionMatch() {
        // (a | b) / (c | d), close c → (a | b) / d. The root keeps its ID by
        // position; (a | b) keeps its own by exact match.
        var reconciler = SplitTreeReconciler()
        let before = reconciler.reconcile(nil, with: v(h(.pane(a), .pane(b)), h(.pane(c), .pane(d))))
        let ab = container(holding: [a, b], in: before)
        let after = reconciler.reconcile(before, with: v(h(.pane(a), .pane(b)), .pane(d)))
        #expect(after.splitIDs == [before.splitIDs[0], ab].compactMap { $0 })
    }

    @Test func positionMatchNeverStealsAClaimedContainer() {
        // a | (b | c), close a → b | c: the root position would offer the old
        // root, but the old inner container holds exactly {b, c} and wins.
        var reconciler = SplitTreeReconciler()
        let before = reconciler.reconcile(nil, with: h(.pane(a), h(.pane(b), .pane(c))))
        let inner = container(holding: [b, c], in: before)
        let after = reconciler.reconcile(before, with: h(.pane(b), .pane(c)))
        #expect(after.splitIDs == [inner].compactMap { $0 })
        #expect(Set(after.splitIDs).count == after.splitIDs.count)
    }

    @Test func axisChangeGetsANewContainer() {
        var reconciler = SplitTreeReconciler()
        let before = reconciler.reconcile(nil, with: h(.pane(a), .pane(b)))
        let after = reconciler.reconcile(before, with: v(.pane(a), .pane(b)))
        #expect(after.splitIDs.count == 1)
        #expect(after.splitIDs[0] != before.splitIDs[0])
    }

    @Test func droppedIDsAreNeverReused() {
        var reconciler = SplitTreeReconciler()
        let one = reconciler.reconcile(nil, with: h(.pane(a), .pane(b)))
        let zoomed = reconciler.reconcile(one, with: .pane(a))
        #expect(zoomed.splitIDs.isEmpty)
        let back = reconciler.reconcile(zoomed, with: h(.pane(a), .pane(b)))
        #expect(back.splitIDs.count == 1)
        #expect(back.splitIDs[0] != one.splitIDs[0])
    }

    @Test func settingRatioUpdatesOnlyThatContainer() {
        var reconciler = SplitTreeReconciler()
        let tree = reconciler.reconcile(nil, with: h(.pane(a), v(.pane(b), .pane(c))))
        let inner = tree.splitIDs[1]
        let changed = tree.settingRatio(0.75, of: inner)
        #expect(changed.layout == h(.pane(a), v(.pane(b), .pane(c), 0.75)))
        #expect(changed.splitIDs == tree.splitIDs)
        #expect(tree.settingRatio(5, of: inner).layout == h(.pane(a), v(.pane(b), .pane(c), 0.9)))
        #expect(tree.settingRatio(.nan, of: inner) == tree)
    }
}

@Suite("PaneLayout step 4")
struct PaneLayoutStep4Tests {
    @Test func moveDividerFollowsTheArrowOnEitherSide() {
        let layout = h(.pane(a), .pane(b))
        #expect(layout.moveDivider(of: a, toward: .right, by: 0.1) == h(.pane(a), .pane(b), 0.6))
        #expect(layout.moveDivider(of: b, toward: .right, by: 0.1) == h(.pane(a), .pane(b), 0.6))
        #expect(layout.moveDivider(of: b, toward: .left, by: 0.1) == h(.pane(a), .pane(b), 0.4))
        #expect(layout.moveDivider(of: a, toward: .up, by: 0.1) == layout)
        #expect(layout.moveDivider(of: a, toward: .right, by: .infinity) == layout)
        #expect(layout.moveDivider(of: a, toward: .right, by: 1) == h(.pane(a), .pane(b), 0.9))
    }

    @Test func moveDividerUsesNearestSplitOnTheAxis() {
        // a | (b / c): from c, up/down move the inner divider, left/right the root.
        let layout = h(.pane(a), v(.pane(b), .pane(c)))
        #expect(layout.moveDivider(of: c, toward: .down, by: 0.2) == h(.pane(a), v(.pane(b), .pane(c), 0.7)))
        #expect(layout.moveDivider(of: c, toward: .left, by: 0.2) == h(.pane(a), v(.pane(b), .pane(c)), 0.3))
    }

    @Test func sameShapeIgnoresRatiosOnly() {
        let layout = h(.pane(a), v(.pane(b), .pane(c)))
        #expect(layout.hasSameShape(as: h(.pane(a), v(.pane(b), .pane(c), 0.2), 0.8)))
        #expect(!layout.hasSameShape(as: h(.pane(a), h(.pane(b), .pane(c)))))
        #expect(!layout.hasSameShape(as: h(.pane(a), v(.pane(c), .pane(b)))))
        #expect(!layout.hasSameShape(as: h(.pane(a), .pane(b))))
        #expect(PaneLayout.pane(a).hasSameShape(as: .pane(a)))
    }

    @Test func clampingRatios() {
        #expect(h(.pane(a), v(.pane(b), .pane(c), 0.01), .nan).clampingRatios() == h(.pane(a), v(.pane(b), .pane(c), 0.1)))
    }

    @Test func clampedRatioMapsNonFiniteToHalf() {
        #expect(PaneLayout.clampedRatio(.nan) == 0.5)
        #expect(PaneLayout.clampedRatio(.infinity) == 0.5)
        #expect(PaneLayout.clampedRatio(-.infinity) == 0.5)
        #expect(PaneLayout.clampedRatio(0.95) == 0.9)
        #expect(PaneLayout.clampedRatio(0.01) == 0.1)
        #expect(PaneLayout.clampedRatio(0.3) == 0.3)
    }

    @Test func directionAxis() {
        #expect(Direction.left.axis == .horizontal)
        #expect(Direction.down.axis == .vertical)
    }
}
