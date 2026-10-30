import AppKit
import Testing
@testable import Armadale

/// The tab bar's native look (DESIGN §8, October 30, 2026): its height,
/// the shared tab widths inside the track, and where dividers are drawn.
@Suite("Tab bar style")
@MainActor
struct TabBarStyleTests {
    @Test func takesTheNativeHeight() {
        #expect(TabBarView.height == 36)
        #expect(TabBarStyle.trackHeight + 2 * 4 == TabBarView.height, "the track sits centred with 4 pt above and below")
        #expect(TabBarStyle.tabHeight == 24, "a pill is inset 2 pt inside the 28 pt track")
    }

    @Test func tabsShareTheTrackBetweenTheLimits() {
        // 800 pt bar: 800 - 16 margins - 4 gap - 28 "+" - 4 insets = 748 inside.
        #expect(TabBarStyle.tabWidth(barWidth: 800, count: 0) == 0)
        #expect(TabBarStyle.tabWidth(barWidth: 800, count: 1) == 220, "never wider than 220")
        #expect(TabBarStyle.tabWidth(barWidth: 800, count: 4) == 185.5, "(748 - 3 gaps of 2) / 4")
        #expect(TabBarStyle.tabWidth(barWidth: 800, count: 10) == 110, "never narrower than 110; the track scrolls")
        // The tabs and the gaps between them fill the inside exactly.
        let count = 5
        let width = TabBarStyle.tabWidth(barWidth: 800, count: count)
        #expect(abs(CGFloat(count) * width + CGFloat(count - 1) * TabBarStyle.tabSpacing - 748) < 0.001)
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
