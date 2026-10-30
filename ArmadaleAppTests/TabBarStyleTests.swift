import AppKit
import ArmadaleCore
import Testing
@testable import Armadale

/// The tab bar's native look (DESIGN §8, October 30, 2026): its height,
/// the shared tab widths inside the track, where dividers are drawn, where
/// the track scrolls to (``TrackScroll``), and which tab a middle click hits.
@Suite("Tab bar style")
@MainActor
struct TabBarStyleTests {
    @Test func takesTheNativeHeight() {
        #expect(TabBarView.height == 36)
        #expect(TabBarStyle.trackHeight + 2 * 4 == TabBarView.height, "the track sits centred with 4 pt above and below")
        #expect(TabBarStyle.tabHeight == 24, "a pill is inset 2 pt inside the 28 pt track")
    }

    @Test func tabsFillTheTrackDownToTheMinimum() {
        // 800 pt bar: 800 - 16 margins - 4 gap - 28 "+" - 4 insets = 748 inside.
        #expect(TabBarStyle.tabWidth(barWidth: 800, count: 0) == 0)
        #expect(TabBarStyle.tabWidth(barWidth: 800, count: 1) == 748, "one tab fills the track, as native")
        #expect(TabBarStyle.tabWidth(barWidth: 800, count: 2) == 373, "two halves: (748 - 2) / 2")
        #expect(TabBarStyle.tabWidth(barWidth: 800, count: 4) == 185.5, "(748 - 3 gaps of 2) / 4")
        #expect(TabBarStyle.tabWidth(barWidth: 800, count: 10) == 110, "never narrower than 110; the track scrolls")
        // Whenever they fit, the tabs and the gaps between them fill the inside exactly.
        for count in 1...6 {
            let width = TabBarStyle.tabWidth(barWidth: 800, count: count)
            #expect(abs(CGFloat(count) * width + CGFloat(count - 1) * TabBarStyle.tabSpacing - 748) < 0.001)
        }
    }

    @Test func scrollsOnlyBelowTheMinimumWidth() {
        // Six tabs need 6 × 110 + 5 × 2 = 670 pt inside: a 722 pt bar.
        #expect(TrackScroll.maxOffset(count: 6, barWidth: 722) == 0)
        #expect(TrackScroll.maxOffset(count: 6, barWidth: 721) > 0)
        #expect(TrackScroll.maxOffset(count: 0, barWidth: 100) == 0)
    }

    // An 860 pt bar (an 1100 pt window less the sidebar): an 812 pt
    // viewport; 11 tabs of 110 pt make 1234 pt of content (end at 422),
    // 10 tabs 1122 pt (end at 310).
    @Test func trackMetrics() {
        #expect(TrackScroll.viewportWidth(barWidth: 860) == 812)
        #expect(TrackScroll.contentWidth(count: 11, barWidth: 860) == 1234)
        #expect(TrackScroll.maxOffset(count: 11, barWidth: 860) == 422)
        #expect(TrackScroll.maxOffset(count: 10, barWidth: 860) == 310)
        #expect(TrackScroll.maxOffset(count: 5, barWidth: 860) == 0, "five tabs fit")
        #expect(TrackScroll.contentWidth(count: 5, barWidth: 860) == 812, "and fill the track exactly")
    }

    @Test func closingATabOnlyClampsTheUsersScroll() {
        // Tab 3 selected, scrolled to the end by hand, a visible unselected
        // tab closed: the offset is clamped to the new end, not moved back
        // to tab 3 (224, which moved the track 198 pt).
        #expect(TrackScroll.clampedOffset(count: 10, barWidth: 860, offset: 422) == 310)
        // Scrolled to the middle: the offset stays.
        #expect(TrackScroll.clampedOffset(count: 10, barWidth: 860, offset: 200) == nil)
        // Every tab fits after a widening or a close: back to the start.
        #expect(TrackScroll.clampedOffset(count: 5, barWidth: 860, offset: 30) == 0)
        #expect(TrackScroll.clampedOffset(count: 5, barWidth: 860, offset: 0) == nil)
        // Narrowed: an offset still in range stays.
        #expect(TrackScroll.clampedOffset(count: 5, barWidth: 280, offset: 100) == nil)
    }

    @Test func narrowingKeepsAVisibleSelectedTabInView() {
        // Five tabs fill an 860 pt bar; tab 3 is selected and shows. At a
        // 280 pt bar (a 520 pt window) the viewport is 232 pt and tab 3
        // (2 × 112 = 224 to 338 with its insets) would be out of view at
        // offset 0: it is revealed with the least scroll.
        #expect(TrackScroll.isWhollyVisible(index: 2, count: 5, barWidth: 860, offset: 0))
        #expect(!TrackScroll.isWhollyVisible(index: 2, count: 5, barWidth: 280, offset: 0))
        #expect(TrackScroll.resizedOffset(index: 2, count: 5, from: 860, to: 280, offset: 0) == 106, "338 - 232")
        // Widened again: every tab fits, back to the start.
        #expect(TrackScroll.resizedOffset(index: 2, count: 5, from: 280, to: 860, offset: 106) == 0)
        // A tab that still shows after the resize: no scroll.
        #expect(TrackScroll.resizedOffset(index: 0, count: 5, from: 860, to: 280, offset: 0) == nil)
    }

    @Test func narrowingLeavesAHiddenSelectedTabHidden() {
        // Eleven tabs, tab 1 selected, the track scrolled to the end (422)
        // so tab 1 is out of view; narrowing to a 700 pt bar only clamps
        // (the end is now 1234 - 652 = 582, so 422 stays) and never jumps
        // back to tab 1.
        #expect(!TrackScroll.isWhollyVisible(index: 0, count: 11, barWidth: 860, offset: 422))
        #expect(TrackScroll.resizedOffset(index: 0, count: 11, from: 860, to: 700, offset: 422) == nil)
        // Widened past the content's end instead: clamped to the new end.
        #expect(TrackScroll.resizedOffset(index: 0, count: 11, from: 860, to: 1000, offset: 422) == 282)
    }

    @Test func aSelectionChangeRevealsTheTab() {
        // 10 tabs at the start: the last tab scrolls to the end, the first
        // to the start, a hidden one by the least amount with the inset.
        #expect(TrackScroll.revealOffset(index: 9, count: 10, barWidth: 860, offset: 0) == 310)
        #expect(TrackScroll.revealOffset(index: 0, count: 10, barWidth: 860, offset: 310) == 0)
        #expect(TrackScroll.revealOffset(index: 7, count: 10, barWidth: 860, offset: 0) == 86,
                "tab 8 ends at 7 × 112 + 110 + 4 = 898, 86 past the 812 pt viewport")
        #expect(TrackScroll.revealOffset(index: 2, count: 10, barWidth: 860, offset: 300) == 224,
                "tab 3 starts at 2 × 112 (with the inset before it)")
        // Already wholly in view: no scroll.
        #expect(TrackScroll.revealOffset(index: 5, count: 10, barWidth: 860, offset: 0) == nil)
        #expect(TrackScroll.revealOffset(index: 9, count: 10, barWidth: 860, offset: 310) == nil)
        // No selection: only an out-of-range offset moves.
        #expect(TrackScroll.revealOffset(index: nil, count: 10, barWidth: 860, offset: 100) == nil)
        #expect(TrackScroll.revealOffset(index: nil, count: 10, barWidth: 860, offset: 500) == 310)
        // Every tab fits: the start.
        #expect(TrackScroll.revealOffset(index: 4, count: 5, barWidth: 860, offset: 30) == 0)
    }

    @Test func quickSelectionChangesStartFromThePendingScroll() {
        // ⌘9 then ⌘2 within the 0.2 s animation, 10 tabs at the start.
        var scroll = PendingScroll()
        scroll.reported(0)
        let first = TrackScroll.revealOffset(index: 9, count: 10, barWidth: 860, offset: scroll.effectiveOffset)
        #expect(first == 310)
        scroll.requested(310)
        _ = scroll.phaseChanged(to: .animating)
        scroll.reported(5)
        // The scroll view still reports about 0 (the animation has only
        // begun), which would wrongly say tab 2 shows; the pending target
        // says it does not.
        #expect(TrackScroll.revealOffset(index: 1, count: 10, barWidth: 860, offset: scroll.offset) == nil)
        #expect(scroll.effectiveOffset == 310)
        #expect(TrackScroll.revealOffset(index: 1, count: 10, barWidth: 860, offset: scroll.effectiveOffset) == 112)
        // ⌘2 then ⌘9: tab 2 shows at the start, then the end.
        #expect(TrackScroll.revealOffset(index: 1, count: 10, barWidth: 860, offset: 0) == nil)
        #expect(TrackScroll.revealOffset(index: 9, count: 10, barWidth: 860, offset: 0) == 310)
    }

    @Test func aTargetPassedOnTheWayIsNotReached() {
        // 11 tabs: ⌘9 asks for 422; while that animation runs (0 … 112 …)
        // ⌘2 asks for 112; the scroll view drops it and comes to rest at
        // 422. Passing 112 on the way must not count as reaching it.
        var scroll = PendingScroll()
        scroll.reported(0)
        scroll.requested(422)
        #expect(scroll.phaseChanged(to: .animating) == nil)
        scroll.reported(40)
        scroll.requested(112)
        for x: CGFloat in [80, 112, 200, 300, 422] { scroll.reported(x) }
        #expect(scroll.target == 112, "passing through 112 while animating is not reaching it")
        #expect(scroll.effectiveOffset == 112)
        // At rest at 422: ask for 112 once more.
        #expect(scroll.phaseChanged(to: .idle) == 112)
        #expect(scroll.target == 112)
        // That retry animates and comes to rest at 112: reached.
        #expect(scroll.phaseChanged(to: .animating) == nil)
        for x: CGFloat in [300, 200, 112] { scroll.reported(x) }
        #expect(scroll.phaseChanged(to: .idle) == nil)
        #expect(scroll.target == nil)
        #expect(scroll.effectiveOffset == 112)
    }

    @Test func aRetryHappensAtMostOnce() {
        var scroll = PendingScroll()
        scroll.requested(112)
        _ = scroll.phaseChanged(to: .animating)
        scroll.reported(422)
        #expect(scroll.phaseChanged(to: .idle) == 112)
        // The retry is dropped too: give up rather than loop.
        _ = scroll.phaseChanged(to: .animating)
        scroll.reported(422)
        #expect(scroll.phaseChanged(to: .idle) == nil)
        #expect(scroll.target == nil)
        #expect(scroll.effectiveOffset == 422)
    }

    @Test func theUsersScrollDropsThePendingTarget() {
        // A trackpad scroll during the animation: interacting, then
        // decelerating, then rest; no retry, the user's offset wins.
        var scroll = PendingScroll()
        scroll.requested(422)
        _ = scroll.phaseChanged(to: .animating)
        scroll.reported(100)
        #expect(scroll.phaseChanged(to: .user) == nil)
        #expect(scroll.target == nil)
        scroll.reported(250)
        #expect(scroll.phaseChanged(to: .user) == nil)
        #expect(scroll.phaseChanged(to: .idle) == nil)
        #expect(scroll.effectiveOffset == 250)
    }

    @Test func aScrollWithoutAnimationIsReachedWhenReported() {
        // A clamp or a resize reveal scrolls without animation; the scroll
        // view may report no phase change at all.
        var scroll = PendingScroll()
        scroll.reported(422)
        scroll.requested(310)
        scroll.reported(310)
        #expect(scroll.target == nil)
        #expect(scroll.effectiveOffset == 310)
        // A rest without an animation away from the target: given up, no retry.
        scroll.requested(200)
        #expect(scroll.phaseChanged(to: .idle) == nil)
        #expect(scroll.target == nil)
    }

    @Test func middleClickOnlyHitsVisibleTabs() {
        let store = TabFrameStore()
        let visible = TabID(raw: "visible")
        let hidden = TabID(raw: "hidden")
        // The track shows x 10…500; the hidden tab was scrolled past its end
        // and its stored frame lies under the "+" beside the track.
        store.visibleTrack = CGRect(x: 10, y: 4, width: 490, height: 28)
        store.frames = [
            visible: CGRect(x: 12, y: 6, width: 200, height: 24),
            hidden: CGRect(x: 480, y: 6, width: 200, height: 24),
        ]
        #expect(store.tab(at: CGPoint(x: 100, y: 18)) == visible)
        #expect(store.tab(at: CGPoint(x: 490, y: 18)) == hidden, "its visible part still hits it")
        #expect(store.tab(at: CGPoint(x: 520, y: 18)) == nil, "under the \"+\": outside the track")
        #expect(store.tab(at: CGPoint(x: 5, y: 18)) == nil, "the bar's end, outside the track")
        store.visibleTrack = .null
        #expect(store.tab(at: CGPoint(x: 100, y: 18)) == nil, "no track, no tabs")
    }

    @Test func dividersOnlyBetweenPlainTabs() {
        func shown(_ count: Int, pills: Set<Int>) -> [Int] {
            (0..<count).filter { TabBarStyle.showsDivider(after: $0, count: count, pills: pills) }
        }
        #expect(shown(1, pills: [0]).isEmpty, "a single tab has none")
        #expect(shown(4, pills: []) == [0, 1, 2], "never after the last tab")
        #expect(shown(4, pills: [3]) == [0, 1], "none next to the selected tab")
        #expect(shown(4, pills: [0]) == [1, 2])
        #expect(shown(5, pills: [2]) == [0, 3], "none on either side of a pill")
        #expect(shown(5, pills: [0, 2]) == [3], "a hovered or attention pill hides its dividers too")
        #expect(shown(3, pills: [1]).isEmpty)
        #expect(!TabBarStyle.showsDivider(after: -1, count: 3, pills: []))
    }
}

/// Review fixes (October 30, 2026): badges never outshine their titles, and
/// Increase Contrast strengthens every hairline.
@Suite("Tab bar style: contrast")
@MainActor
struct TabBarContrastTests {
    @Test func badgesAreNoBrighterThanUnselectedTitles() {
        #expect(TabBarStyle.detailAlpha.light <= TabBarStyle.unselectedTitleAlpha.light)
        #expect(TabBarStyle.detailAlpha.dark <= TabBarStyle.unselectedTitleAlpha.dark)
    }

    @Test func increasedContrastStrengthensEveryHairline() {
        for line in TabBarStyle.Hairline.allCases {
            let standard = TabBarStyle.tint(line, increasedContrast: false)
            let increased = TabBarStyle.tint(line, increasedContrast: true)
            #expect(increased.light.alphaComponent >= standard.light.alphaComponent + 0.2, "\(line) in light")
            #expect(increased.light.alphaComponent >= 0.3, "\(line) in light")
            // In dark every increased hairline is a white line of at least 35 %.
            let white = increased.dark.usingColorSpace(.genericGray)
            #expect(white?.whiteComponent == 1, "\(line) in dark is white")
            #expect(increased.dark.alphaComponent >= 0.35, "\(line) in dark")
        }
    }

    @Test func standardContrastKeepsTheMeasuredStrengths() {
        func alphas(_ line: TabBarStyle.Hairline) -> [CGFloat] {
            let tint = TabBarStyle.tint(line, increasedContrast: false)
            return [tint.light.alphaComponent, tint.dark.alphaComponent]
        }
        #expect(alphas(.trackBorder) == [0.06, 0.09])
        #expect(alphas(.pillBorder) == [0.04, 0.22])
        #expect(alphas(.divider) == [0.12, 0.12])
        #expect(alphas(.plusRing) == [0.26, 0.75])
    }
}
