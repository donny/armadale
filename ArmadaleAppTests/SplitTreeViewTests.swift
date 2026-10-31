import AppKit
import ArmadaleCore
import TerminalSurface
import Testing

/// The split tree must move panes into their new place at their final size:
/// every intermediate size reaches the pane's program as a PTY resize, and
/// a pass through a tiny grid rewraps (and can truncate) its scrollback.
@Suite("SplitTreeView")
@MainActor
struct SplitTreeViewTests {
    private let a = PaneID(raw: "a")
    private let b = PaneID(raw: "b")
    private let c = PaneID(raw: "c")
    private let frame = NSRect(x: 0, y: 0, width: 1000, height: 600)

    private func h(_ first: PaneLayout, _ second: PaneLayout) -> PaneLayout {
        .split(axis: .horizontal, ratio: 0.5, first: first, second: second)
    }

    private func v(_ first: PaneLayout, _ second: PaneLayout) -> PaneLayout {
        .split(axis: .vertical, ratio: 0.5, first: first, second: second)
    }

    private func log(_ name: String, _ surface: CountingSurface) {
        print("SPLIT RESIZES \(name): \(surface.sizes.map(\.description))")
    }

    @Test func splittingAPaneResizesItsTerminalOnceAndNeverTiny() {
        let tree = SplitTreeView(frame: frame)
        let (paneA, surfaceA) = makeCountingPane()
        let (paneB, surfaceB) = makeCountingPane()
        let panes = [a: paneA, b: paneB]
        tree.update(layout: .pane(a)) { panes[$0] ?? NSView() }
        let full = surfaceA.gridSize
        #expect(full.columns > 80)
        surfaceA.resetLog()
        surfaceB.resetLog()

        tree.update(layout: h(.pane(a), .pane(b))) { panes[$0] ?? NSView() }
        log("a (⌘D on a)", surfaceA)
        log("b (new)", surfaceB)
        #expect(surfaceA.sizes.count == 1, "one resize for the split pane, got \(surfaceA.sizes)")
        #expect(surfaceA.sizes.allSatisfy { $0.columns >= 10 && $0.rows == full.rows })
        #expect(abs(surfaceA.gridSize.columns - full.columns / 2) <= 2)
        #expect(surfaceB.sizes.count <= 1)
        #expect(surfaceB.sizes.allSatisfy { $0.columns >= 10 })
        #expect(paneA.superview === paneB.superview)
        #expect(tree.subviews.count == 1)
    }

    @Test func panesNeverPassThroughATinySizeWhileSplitting() {
        let tree = SplitTreeView(frame: frame)
        let viewA = FrameLoggingView(), viewB = FrameLoggingView(), viewC = FrameLoggingView()
        let panes: [PaneID: NSView] = [a: viewA, b: viewB, c: viewC]
        tree.update(layout: .pane(a)) { panes[$0] ?? NSView() }
        viewA.sizes.removeAll()
        tree.update(layout: h(.pane(a), .pane(b))) { panes[$0] ?? NSView() }
        tree.update(layout: h(.pane(a), v(.pane(b), .pane(c)))) { panes[$0] ?? NSView() }
        print("SPLIT FRAMES a: \(viewA.sizes), b: \(viewB.sizes), c: \(viewC.sizes)")
        for (name, view) in [("a", viewA), ("b", viewB), ("c", viewC)] {
            #expect(view.sizes.allSatisfy { $0.width >= 400 && $0.height >= 250 }, "\(name): \(view.sizes)")
        }
        #expect(viewA.sizes.count == 1, "a: \(viewA.sizes)")
        #expect(viewB.sizes.count == 2, "b: \(viewB.sizes)")
        #expect(viewC.sizes.count == 1, "c: \(viewC.sizes)")
    }

    @Test func splittingANestedPaneLeavesTheOthersAlone() {
        let tree = SplitTreeView(frame: frame)
        let (paneA, surfaceA) = makeCountingPane()
        let (paneB, surfaceB) = makeCountingPane()
        let (paneC, surfaceC) = makeCountingPane()
        let panes = [a: paneA, b: paneB, c: paneC]
        tree.update(layout: h(.pane(a), .pane(b))) { panes[$0] ?? NSView() }
        let rightColumn = paneB.superview
        [surfaceA, surfaceB, surfaceC].forEach { $0.resetLog() }

        tree.update(layout: h(.pane(a), v(.pane(b), .pane(c)))) { panes[$0] ?? NSView() }
        log("a (untouched)", surfaceA)
        log("b (⇧⌘D on b)", surfaceB)
        log("c (new)", surfaceC)
        #expect(surfaceA.sizes.isEmpty)
        #expect(surfaceB.sizes.count == 1, "got \(surfaceB.sizes)")
        #expect(surfaceB.sizes.allSatisfy { $0.rows >= 5 && $0.columns >= 10 })
        #expect(surfaceC.sizes.allSatisfy { $0.rows >= 5 && $0.columns >= 10 })
        #expect(paneA.superview === rightColumn, "the root split kept its view")
    }

    @Test func closingAPaneGrowsItsSiblingsOnce() {
        let tree = SplitTreeView(frame: frame)
        let (paneA, surfaceA) = makeCountingPane()
        let (paneB, surfaceB) = makeCountingPane()
        let (paneC, surfaceC) = makeCountingPane()
        let panes = [a: paneA, b: paneB, c: paneC]
        tree.update(layout: h(.pane(a), v(.pane(b), .pane(c)))) { panes[$0] ?? NSView() }
        let column = paneB.superview
        [surfaceA, surfaceB, surfaceC].forEach { $0.resetLog() }

        tree.update(layout: v(.pane(b), .pane(c))) { panes[$0] ?? NSView() }
        log("b (a closed)", surfaceB)
        log("c (a closed)", surfaceC)
        #expect(surfaceB.sizes.count == 1, "got \(surfaceB.sizes)")
        #expect(surfaceC.sizes.count == 1, "got \(surfaceC.sizes)")
        #expect(paneB.superview === column, "the column moved up whole")
        #expect(paneA.superview == nil)
    }

    @Test func switchingTabsAwayAndBackDoesNotResize() {
        let tree = SplitTreeView(frame: frame)
        let (paneA, surfaceA) = makeCountingPane()
        let (paneB, surfaceB) = makeCountingPane()
        let (paneC, _) = makeCountingPane()
        let panes = [a: paneA, b: paneB, c: paneC]
        let firstTab = h(.pane(a), .pane(b))
        tree.update(layout: firstTab) { panes[$0] ?? NSView() }
        surfaceA.resetLog()
        surfaceB.resetLog()
        tree.update(layout: .pane(c)) { panes[$0] ?? NSView() }
        #expect(paneA.superview == nil && paneB.superview == nil)
        tree.update(layout: firstTab) { panes[$0] ?? NSView() }
        #expect(surfaceA.sizes.isEmpty, "got \(surfaceA.sizes)")
        #expect(surfaceB.sizes.isEmpty, "got \(surfaceB.sizes)")
    }

    @Test func ratioChangesResizeOnlyOnce() {
        let tree = SplitTreeView(frame: frame)
        let (paneA, surfaceA) = makeCountingPane()
        let (paneB, surfaceB) = makeCountingPane()
        let panes = [a: paneA, b: paneB]
        tree.update(layout: h(.pane(a), .pane(b))) { panes[$0] ?? NSView() }
        surfaceA.resetLog()
        surfaceB.resetLog()
        tree.update(layout: .split(axis: .horizontal, ratio: 0.3, first: .pane(a), second: .pane(b))) {
            panes[$0] ?? NSView()
        }
        #expect(surfaceA.sizes.count == 1)
        #expect(surfaceB.sizes.count == 1)
        // The gap between the cards is the divider (DESIGN §8, "Pane cards").
        #expect(abs(paneA.frame.width - (1000 - PaneCardStyle.gap) * 0.3) <= 1)
    }
}

/// Records every size it is given.
@MainActor
final class FrameLoggingView: NSView {
    var sizes: [NSSize] = []

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { sizes.append(newSize) }
        super.setFrameSize(newSize)
    }
}
