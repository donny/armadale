import AppKit
import ArmadaleCore
import SwiftUI

/// Where each tab of a tab bar is, in the bar's own coordinates (origin
/// top left), so the hosting view can map a middle click to a tab, and
/// where the track is scrolled to. A plain class: writing to it never
/// redraws the bar (the scroll offset changes on every frame of a scroll).
@MainActor
final class TabFrameStore {
    var frames: [TabID: CGRect] = [:]
    /// The part of the track that shows tabs (the scroll view's frame).
    /// A tab scrolled out of it keeps a frame beside the track, under the
    /// "+" or the bar's ends, so only points inside it can hit a tab.
    var visibleTrack: CGRect = .null
    /// The bar's width, which the tab width and the track's metrics
    /// follow (``TrackScroll``).
    var barWidth: CGFloat = 0
    /// The track's reported offset and the scroll the bar is waiting for.
    var scroll = PendingScroll()
    /// The bar's width and tab count the last scroll decision was made
    /// for (`nil` before the first).
    var decidedBarWidth: CGFloat?
    var decidedCount: Int?

    /// The offset scroll decisions start from.
    var effectiveOffset: CGFloat { scroll.effectiveOffset }

    func tab(at point: CGPoint) -> TabID? {
        guard visibleTrack.contains(point) else { return nil }
        return frames.first { $0.value.contains(point) }?.key
    }
}

/// The bookkeeping of the track's scrolling (DESIGN §8, "Scrolling the
/// track"), pure so that it can be tested event by event: the offset the
/// scroll view last reported, and the target the bar last asked for until
/// the track comes to rest there.
///
/// While an animated scroll is under way the reported offset is out of
/// date, so decisions start from the pending target (``effectiveOffset``).
/// The target counts as reached only when the track comes to rest at it,
/// or is reported at it while no animation runs (a scroll without
/// animation); an offset reported at it while an animation runs is only
/// passing through (⌘9 then ⌘1: the animation towards the end starts at
/// the start). The scroll view can drop a scroll asked for just after an
/// animated one began and come to rest at the earlier target; an
/// animation coming to rest away from the pending target therefore asks
/// for it once more, at most once per requested scroll. The user's own
/// scrolling (any phase but idle and animating) drops the target, so a
/// retry never follows it.
struct PendingScroll: Equatable {
    /// The scroll view's phases as far as this bookkeeping is concerned.
    enum Phase: Equatable {
        case idle
        /// A programmatic scroll is moving the track.
        case animating
        /// The user is scrolling (tracking, interacting, decelerating).
        case user
    }

    /// The offset the scroll view last reported.
    private(set) var offset: CGFloat = 0
    /// The target the bar last asked for, until the track rests there.
    private(set) var target: CGFloat?
    private(set) var phase: Phase = .idle
    /// Whether ``target`` was already asked for a second time.
    private(set) var retried = false

    /// The offset scroll decisions start from.
    var effectiveOffset: CGFloat { target ?? offset }

    /// The bar asks the track to scroll to `x`.
    mutating func requested(_ x: CGFloat) {
        target = x
        retried = false
    }

    /// The scroll view reports the offset `x`.
    mutating func reported(_ x: CGFloat) {
        offset = x
        if phase == .idle, let target, abs(target - x) < 0.5 { done() }
    }

    /// The scroll phase changed to `new`. Returns the target to ask for
    /// once more, if any.
    mutating func phaseChanged(to new: Phase) -> CGFloat? {
        let old = phase
        phase = new
        switch new {
        case .animating:
            return nil
        case .user:
            done()
            return nil
        case .idle:
            guard let target else { return nil }
            if abs(target - offset) < 0.5 { done(); return nil }
            if old == .animating, !retried {
                retried = true
                return target
            }
            done()
            return nil
        }
    }

    private mutating func done() {
        target = nil
        retried = false
    }
}

/// Hosts the tab bar and closes the tab under a middle click, which SwiftUI
/// has no gesture for. A click anywhere in it outside a rename field ends
/// the window's inline rename (the bar never takes keyboard focus, so the
/// field would not notice the click).
@MainActor
final class TabBarHostingView: NSHostingView<TabBarView> {
    var frames = TabFrameStore()
    var onMiddleClick: ((TabID) -> Void)?
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        let local = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        if let tab = frames.tab(at: point) {
            onMiddleClick?(tab)
        }
    }
}

/// The tab bar's coordinate space, which ``TabFrameStore`` frames are in.
private let tabBarCoordinateSpace = "TabBar"

/// The tabs of the window's selected tab group (DESIGN §8): status glyph
/// (◐ and a tinted pill when a pane needs attention), title, ⌘N
/// badge, close button on hover, and "+" for a new tab. Click
/// selects, drag reorders (or drops the tab on a sidebar tab group),
/// double-click (or the context menu's Rename Tab) edits the title in place
/// (``InlineRenameField``), the context menu also closes. Drawn like the
/// native macOS 27 window tab bar (``TabBarStyle``).
struct TabBarView: View {
    let model: AppModel
    let registry: SessionRegistry
    let workspaceID: WorkspaceID
    let actions: WorkspaceActions
    let frames: TabFrameStore

    static let height = TabBarStyle.height

    /// The tab under the pointer, which is drawn as a pill and so hides the
    /// dividers next to it.
    @State private var hoveredTabID: TabID?
    /// Drives the track's scroll offset; read back through
    /// `onScrollGeometryChange` into ``TabFrameStore/scroll``.
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let group = model.workspace(workspaceID)?.selectedTabGroup
        let tabs = group?.tabs ?? []
        let pills = Set(tabs.indices.filter { index in
            let tab = tabs[index]
            return tab.id == group?.selectedTabID || tab.id == hoveredTabID
                || TabItemView.needsAttention(tab, registry: registry)
        })
        GeometryReader { geometry in
            let width = TabBarStyle.tabWidth(barWidth: geometry.size.width, count: tabs.count)
            HStack(spacing: TabBarStyle.plusGap) {
                if tabs.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: TabBarStyle.tabSpacing) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                TabItemView(
                                    model: model,
                                    registry: registry,
                                    actions: actions,
                                    tab: tab,
                                    groupID: group?.id,
                                    index: index,
                                    badge: Self.badge(index: index, count: tabs.count),
                                    isSelected: tab.id == group?.selectedTabID,
                                    isOnly: tabs.count == 1,
                                    isHovering: tab.id == hoveredTabID,
                                    edit: actions.rename.edit(of: .tab(tab.id), on: .tabBar),
                                    onHover: { hovering in
                                        if hovering {
                                            hoveredTabID = tab.id
                                        } else if hoveredTabID == tab.id {
                                            hoveredTabID = nil
                                        }
                                    })
                                .frame(width: width)
                                .overlay(alignment: .trailing) {
                                    if TabBarStyle.showsDivider(after: index, count: tabs.count, pills: pills) {
                                        TabBarDivider()
                                    }
                                }
                                .onGeometryChange(for: CGRect.self) { tabGeometry in
                                    tabGeometry.frame(in: .named(tabBarCoordinateSpace))
                                } action: { frame in
                                    frames.frames[tab.id] = frame
                                }
                            }
                        }
                        .padding(TabBarStyle.pillInset)
                    }
                    .scrollIndicators(.never)
                    .scrollPosition($scrollPosition)
                    .clipShape(Capsule())
                    .onGeometryChange(for: CGRect.self) { track in
                        track.frame(in: .named(tabBarCoordinateSpace))
                    } action: { frame in
                        frames.visibleTrack = frame
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { scroll in
                        scroll.contentOffset.x
                    } action: { _, offset in
                        frames.scroll.reported(offset)
                    }
                    .onScrollPhaseChange { _, phase in
                        scrollPhaseChanged(to: phase)
                    }
                    .onAppear { adjustScroll(revealingSelection: true, animated: false) }
                    // The selection changed (a new tab, ⌘1…⌘9, the sidebar,
                    // the attention reveal, a close that selects a
                    // neighbour): show the selected tab.
                    .onChange(of: group?.selectedTabID) {
                        adjustScroll(revealingSelection: true, animated: true)
                    }
                    // Tabs added or closed, or a resize, with the same
                    // selection: leave the user's scroll alone, only clamp
                    // it (the start when every tab fits; the new end when
                    // the content shrank under the offset, which the scroll
                    // view itself does not always do); a resize also keeps
                    // a selected tab that was wholly in view in view.
                    .onChange(of: TrackLayout(barWidth: geometry.size.width, count: tabs.count)) {
                        adjustScroll(revealingSelection: false, animated: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: TabBarStyle.trackHeight)
                    .background {
                        Capsule().fill(TabBarStyle.trackFill)
                        Capsule().strokeBorder(
                            TabBarStyle.color(.trackBorder, contrast: contrast), lineWidth: TabBarStyle.hairline)
                    }
                }

                Button {
                    actions.newTab(in: group?.id)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: TabBarStyle.plusDiameter, height: TabBarStyle.plusDiameter)
                        .contentShape(Circle())
                }
                .buttonStyle(NewTabButtonStyle())
                .help("New Tab")
                .accessibilityLabel("New Tab")
            }
            .padding(.horizontal, TabBarStyle.margin)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onGeometryChange(for: CGFloat.self) { bar in
                bar.size.width
            } action: { width in
                frames.barWidth = width
            }
            .contentShape(Rectangle())
            .dropDestination(for: HierarchyDragItem.self) { items, _ in
                guard let group else { return false }
                return actions.drop(items, onTabAt: nil, in: group.id)
            }
        }
        .coordinateSpace(.named(tabBarCoordinateSpace))
        .frame(height: Self.height)
        .onChange(of: tabs.map(\.id)) { _, ids in
            let live = Set(ids)
            frames.frames = frames.frames.filter { live.contains($0.key) }
            if let hoveredTabID, !live.contains(hoveredTabID) { self.hoveredTabID = nil }
        }
    }

    /// What the track's scroll position depends on besides the selection.
    private struct TrackLayout: Equatable {
        var barWidth: CGFloat
        var count: Int
    }

    /// Asks for a scroll on the main actor's next turn (by then a tab
    /// added with the selection is normally part of the scroll view's
    /// content). The tabs, the selection, the bar's width and the offset
    /// are read when it runs, not when it was asked for, so of several
    /// quick changes the last state wins whatever order the turns run in;
    /// the offset is ``TabFrameStore/effectiveOffset``, so a decision made
    /// while an animated scroll is under way starts from where that scroll
    /// is going, and the target is computed from the tab's index and the
    /// uniform tab width (``TrackScroll``), never from measured frames.
    private func adjustScroll(revealingSelection: Bool, animated: Bool) {
        Task { @MainActor in
            guard let group = model.workspace(workspaceID)?.selectedTabGroup else { return }
            let tabs = group.tabs
            let barWidth = frames.barWidth
            guard barWidth > 0 else { return }
            let offset = frames.effectiveOffset
            let index = group.selectedTabID.flatMap { id in tabs.firstIndex { $0.id == id } }
            // The layout the previous decision was made for, so a resize
            // is told apart from tabs added or closed.
            let previousWidth = frames.decidedBarWidth ?? barWidth
            let previousCount = frames.decidedCount ?? tabs.count
            frames.decidedBarWidth = barWidth
            frames.decidedCount = tabs.count
            let target: CGFloat? = if revealingSelection {
                TrackScroll.revealOffset(index: index, count: tabs.count, barWidth: barWidth, offset: offset)
            } else if tabs.count != previousCount {
                TrackScroll.clampedOffset(count: tabs.count, barWidth: barWidth, offset: offset)
            } else {
                TrackScroll.resizedOffset(
                    index: index, count: tabs.count, from: previousWidth, to: barWidth, offset: offset)
            }
            scroll(to: target, animated: animated)
        }
    }

    /// The track's scroll phase changed: tell ``PendingScroll``, and ask
    /// once more for a target it says was dropped.
    private func scrollPhaseChanged(to phase: ScrollPhase) {
        let mapped: PendingScroll.Phase = switch phase {
        case .idle: .idle
        case .animating: .animating
        default: .user
        }
        if let retry = frames.scroll.phaseChanged(to: mapped) {
            withAnimation(.easeInOut(duration: 0.2)) { scrollPosition.scrollTo(x: retry) }
        }
    }

    /// Scrolls the track to `offset` (nothing when `nil`), remembering it
    /// as pending until the scroll view reports it.
    private func scroll(to offset: CGFloat?, animated: Bool) {
        guard let offset else { return }
        frames.scroll.requested(offset)
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) { scrollPosition.scrollTo(x: offset) }
        } else {
            scrollPosition.scrollTo(x: offset)
        }
    }

    /// ⌘1…⌘8 for the first eight tabs; ⌘9 always goes to the last one.
    static func badge(index: Int, count: Int) -> String? {
        if index < 8 { return "⌘\(index + 1)" }
        return index == count - 1 ? "⌘9" : nil
    }
}

/// The look of the tab bar: the native macOS 27 window tab bar (Terminal's
/// Window › Show Tab Bar), measured on October 30, 2026 (DESIGN §8). A
/// capsule track holds every tab; the selected tab is a raised pill inset
/// in it; plain tabs are separated by hairline dividers; "+" is a circle
/// outside the track. Each colour is a black or white tint picked by the
/// view's appearance (light or dark), its strength chosen so that the
/// pixels on screen match screenshots of the native bar in both
/// appearances; the native bar's own tints are not exposed as named
/// system colours.
enum TabBarStyle {
    /// The native tab bar's height (a window grows by 36 pt when it shows one).
    static let height: CGFloat = 36
    static let trackHeight: CGFloat = 28
    /// The gap between the track's edge and a pill.
    static let pillInset: CGFloat = 2
    static let tabHeight: CGFloat = trackHeight - 2 * pillInset
    static let tabSpacing: CGFloat = 2
    /// Space at both ends of the bar.
    static let margin: CGFloat = 8
    static let plusGap: CGFloat = 4
    static let plusDiameter: CGFloat = 28
    static let dividerHeight: CGFloat = 16
    static let hairline: CGFloat = 0.5
    static let minTabWidth: CGFloat = 110

    /// The width every tab gets: the track's whole inside shared out
    /// equally, as native (one tab fills the track), but never less than
    /// ``minTabWidth``; below that the track scrolls.
    static func tabWidth(barWidth: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return max(share(barWidth: barWidth, count: count), minTabWidth)
    }

    /// The track's inside (less the insets and the gaps between tabs) over
    /// `count` tabs.
    private static func share(barWidth: CGFloat, count: Int) -> CGFloat {
        let inside = barWidth - 2 * margin - plusGap - plusDiameter - 2 * pillInset
        return (inside - tabSpacing * CGFloat(count - 1)) / CGFloat(count)
    }

    /// Whether a divider follows the tab at `index`: only between two plain
    /// tabs, never next to one drawn as a pill (selected, hovered or needing
    /// attention, the indices in `pills`), and never after the last tab.
    static func showsDivider(after index: Int, count: Int, pills: Set<Int>) -> Bool {
        index >= 0 && index + 1 < count && !pills.contains(index) && !pills.contains(index + 1)
    }

    static let trackFill = color(light: .black.withAlphaComponent(0.088), dark: .white.withAlphaComponent(0.11))
    static let pillFill = color(light: .white, dark: .white.withAlphaComponent(0.035))
    static let pillShadow = color(light: .black.withAlphaComponent(0.05), dark: .black.withAlphaComponent(0.45))
    /// The selected pill in a window that is not key: flatter, no shadow.
    static let inactivePillFill = color(light: .white.withAlphaComponent(0.4), dark: .black.withAlphaComponent(0.08))
    /// A hovered plain tab: a faint darkening of the track in both
    /// appearances, so in dark it stays clearly below the (lighter) pill.
    static let hoverFill = color(light: .black.withAlphaComponent(0.05), dark: .black.withAlphaComponent(0.1))
    /// The strength of an unselected title: black in light, white in dark.
    static let unselectedTitleAlpha: (light: CGFloat, dark: CGFloat) = (0.5, 0.22)
    /// The ⌘N badge and the split/zoom hint: never brighter than the
    /// dimmest title beside them (the unselected one).
    static let detailAlpha: (light: CGFloat, dark: CGFloat) = (0.26, 0.18)
    static let unselectedTitle = color(
        light: .black.withAlphaComponent(unselectedTitleAlpha.light),
        dark: .white.withAlphaComponent(unselectedTitleAlpha.dark))
    static let detail = color(
        light: .black.withAlphaComponent(detailAlpha.light), dark: .white.withAlphaComponent(detailAlpha.dark))
    static let plusFill = color(light: .black.withAlphaComponent(0.04), dark: .white.withAlphaComponent(0.16))
    static let plusPressed = Color.primary.opacity(0.08)

    /// The hairlines, which Increase Contrast makes clearly stronger.
    enum Hairline: CaseIterable {
        case trackBorder, pillBorder, divider, plusRing
    }

    /// A hairline's tint in each appearance: black in light, white in dark
    /// (the "+" ring is a dark ring in dark at standard contrast, as
    /// native, and a white one with Increase Contrast).
    static func tint(_ line: Hairline, increasedContrast: Bool) -> (light: NSColor, dark: NSColor) {
        let (light, dark): (CGFloat, CGFloat)
        switch (line, increasedContrast) {
        case (.trackBorder, false): (light, dark) = (0.06, 0.09)
        case (.trackBorder, true): (light, dark) = (0.3, 0.35)
        case (.pillBorder, false): (light, dark) = (0.04, 0.22)
        case (.pillBorder, true): (light, dark) = (0.35, 0.5)
        case (.divider, false): (light, dark) = (0.12, 0.12)
        case (.divider, true): (light, dark) = (0.35, 0.4)
        case (.plusRing, false): return (.black.withAlphaComponent(0.26), .black.withAlphaComponent(0.75))
        case (.plusRing, true): (light, dark) = (0.5, 0.5)
        }
        return (.black.withAlphaComponent(light), .white.withAlphaComponent(dark))
    }

    static func color(_ line: Hairline, contrast: ColorSchemeContrast) -> Color {
        let tint = tint(line, increasedContrast: contrast == .increased)
        return color(light: tint.light, dark: tint.dark)
    }

    /// A colour that is `light` in a light appearance and `dark` in a dark one.
    static func color(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// Where the tab track scrolls (DESIGN §8, "Scrolling the track"): pure
/// offsets computed from the tab count, the tab's index and the bar's
/// width (every tab has the same width), so a decision never depends on
/// frames measured before an earlier scroll landed.
enum TrackScroll {
    /// The visible width of the track.
    static func viewportWidth(barWidth: CGFloat) -> CGFloat {
        barWidth - 2 * TabBarStyle.margin - TabBarStyle.plusGap - TabBarStyle.plusDiameter
    }

    /// The width of the track's content: the tabs, the gaps between them
    /// and the inset at either end.
    static func contentWidth(count: Int, barWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let width = TabBarStyle.tabWidth(barWidth: barWidth, count: count)
        return 2 * TabBarStyle.pillInset + CGFloat(count) * width + CGFloat(count - 1) * TabBarStyle.tabSpacing
    }

    /// The largest offset: the track scrolled to its end.
    static func maxOffset(count: Int, barWidth: CGFloat) -> CGFloat {
        max(0, contentWidth(count: count, barWidth: barWidth) - viewportWidth(barWidth: barWidth))
    }

    /// After the selection changed to the tab at `index`: the least scroll
    /// from `offset` that shows it wholly with the inset beside it (the
    /// start for the first tab, the end for the last), or `nil` when it
    /// already shows that way and the offset is in range. With every tab
    /// fitting, the start.
    static func revealOffset(index: Int?, count: Int, barWidth: CGFloat, offset: CGFloat) -> CGFloat? {
        guard count > 0 else { return nil }
        let maximum = maxOffset(count: count, barWidth: barWidth)
        var target = min(max(offset, 0), maximum)
        if let index, index >= 0, index < count {
            let width = TabBarStyle.tabWidth(barWidth: barWidth, count: count)
            let start = CGFloat(index) * (width + TabBarStyle.tabSpacing)
            let end = start + width + 2 * TabBarStyle.pillInset
            let viewport = viewportWidth(barWidth: barWidth)
            if start < target {
                target = start
            } else if end > target + viewport {
                target = end - viewport
            }
            target = min(max(target, 0), maximum)
        }
        return abs(target - offset) < 0.5 ? nil : target
    }

    /// After a resize (the bar's width changed from `oldWidth` to
    /// `newWidth`, the tabs and the selection did not): the offset clamped
    /// as ``clampedOffset(count:barWidth:offset:)`` does, and then, if the
    /// selected tab at `index` showed wholly before the resize and no longer
    /// does, the least scroll that shows it again; a selected tab that was
    /// already out of view stays out of view. `nil` when nothing moves.
    static func resizedOffset(
        index: Int?, count: Int, from oldWidth: CGFloat, to newWidth: CGFloat, offset: CGFloat
    ) -> CGFloat? {
        let clamped = clampedOffset(count: count, barWidth: newWidth, offset: offset) ?? offset
        if let index, isWhollyVisible(index: index, count: count, barWidth: oldWidth, offset: offset),
           !isWhollyVisible(index: index, count: count, barWidth: newWidth, offset: clamped),
           let revealed = revealOffset(index: index, count: count, barWidth: newWidth, offset: clamped) {
            return abs(revealed - offset) < 0.5 ? nil : revealed
        }
        return abs(clamped - offset) < 0.5 ? nil : clamped
    }

    /// Whether the pill of the tab at `index` lies wholly inside the track
    /// scrolled to `offset`.
    static func isWhollyVisible(index: Int, count: Int, barWidth: CGFloat, offset: CGFloat) -> Bool {
        guard index >= 0, index < count else { return false }
        let width = TabBarStyle.tabWidth(barWidth: barWidth, count: count)
        let minX = TabBarStyle.pillInset + CGFloat(index) * (width + TabBarStyle.tabSpacing)
        return minX >= offset - 0.5 && minX + width <= offset + viewportWidth(barWidth: barWidth) + 0.5
    }

    /// After tabs were added or closed without a selection change:
    /// the user's offset clamped to the content (the start when every tab
    /// fits, the new end when the content shrank under it), or `nil` to
    /// leave it where it is.
    static func clampedOffset(count: Int, barWidth: CGFloat, offset: CGFloat) -> CGFloat? {
        let target = min(max(offset, 0), maxOffset(count: count, barWidth: barWidth))
        return abs(target - offset) < 0.5 ? nil : target
    }
}

/// The hairline between two plain tabs, centred in the gap after a tab.
private struct TabBarDivider: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle()
            .fill(TabBarStyle.color(.divider, contrast: contrast))
            .frame(width: 1, height: TabBarStyle.dividerHeight)
            .offset(x: (TabBarStyle.tabSpacing + 1) / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The "+" button: a circle with a hairline border beside the track; its
/// glyph dims with the tab titles in a window that is not key.
private struct NewTabButtonStyle: ButtonStyle {
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(appearsActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .background {
                Circle().fill(TabBarStyle.plusFill)
                if configuration.isPressed {
                    Circle().fill(TabBarStyle.plusPressed)
                }
                Circle().strokeBorder(TabBarStyle.color(.plusRing, contrast: contrast), lineWidth: TabBarStyle.hairline)
            }
    }
}

private struct TabItemView: View {
    let model: AppModel
    let registry: SessionRegistry
    let actions: WorkspaceActions
    let tab: ArmadaleCore.Tab
    let groupID: TabGroupID?
    let index: Int
    let badge: String?
    let isSelected: Bool
    let isOnly: Bool
    /// The pointer is over this tab (kept by the bar, whose dividers
    /// depend on it).
    let isHovering: Bool
    /// The rename under way of this tab, if any.
    let edit: InlineRename.Edit?
    let onHover: (Bool) -> Void

    @State private var isTargeted = false
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorSchemeContrast) private var contrast

    private static let font = Font.system(size: 12)

    /// Whether a pane of `tab` needs attention (DESIGN §8: a tinted pill).
    static func needsAttention(_ tab: ArmadaleCore.Tab, registry: SessionRegistry) -> Bool {
        tab.layout.leaves().contains { leaf in
            guard let session = tab.pane(leaf)?.sessionID else { return false }
            return registry.attention?.needsAttention(session) ?? false
        }
    }

    var body: some View {
        let title = model.displayTitle(for: tab)
        let sessions = tab.layout.leaves().compactMap { tab.pane($0)?.sessionID }
        let status = registry.glyphStatus(of: sessions)
        let needsAttention = Self.needsAttention(tab, registry: registry)
        HStack(spacing: 6) {
            StatusGlyph(status: sessions.isEmpty ? nil : status)
            HostBadge(hosts: registry.hosts(of: sessions), persistenceNote: registry.persistenceNote(of: sessions))
            if let edit {
                InlineRenameField(rename: actions.rename, edit: edit, font: Self.font)
                    .id(edit.id)
                    .frame(maxWidth: .infinity)
            } else {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(titleStyle)
            }
            if tab.layout.isSplit {
                Image(systemName: tab.zoomedPaneID == nil ? "rectangle.split.2x1" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9))
                    .foregroundStyle(detailStyle)
                    .help(tab.zoomedPaneID == nil ? "\(tab.panes.count) panes" : "Zoomed")
            }
            if edit == nil { Spacer(minLength: 0) }
            ZStack {
                if let badge {
                    Text(badge)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(detailStyle)
                        .opacity(isHovering ? 0 : 1)
                }
                Button {
                    actions.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Close Tab")
                .accessibilityLabel("Close Tab")
                .opacity(isHovering ? 1 : 0)
            }
            .frame(minWidth: 22)
        }
        .font(Self.font)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: TabBarStyle.tabHeight)
        .background {
            if isSelected {
                if appearsActive {
                    Capsule()
                        .fill(TabBarStyle.pillFill)
                        .shadow(color: TabBarStyle.pillShadow, radius: 1, y: 0.5)
                    Capsule()
                        .strokeBorder(TabBarStyle.color(.pillBorder, contrast: contrast), lineWidth: TabBarStyle.hairline)
                } else {
                    Capsule().fill(TabBarStyle.inactivePillFill)
                }
            } else if isHovering {
                Capsule().fill(TabBarStyle.hoverFill)
            }
            if needsAttention {
                // A subtle highlight for a tab needing attention (DESIGN §8).
                Capsule().fill(StatusGlyph.attentionColor.opacity(0.13))
                Capsule().strokeBorder(StatusGlyph.attentionColor.opacity(0.35), lineWidth: 1)
            }
        }
        .overlay(alignment: .leading) {
            if isTargeted {
                // Short and just inside the leading edge, so the track's
                // rounded end does not clip it on the first tab.
                Capsule().fill(Color.accentColor)
                    .frame(width: 2, height: TabBarStyle.dividerHeight)
                    .padding(.leading, 1)
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture { actions.select(tab: tab.id) }
        // Simultaneous, so a single click still selects at once instead of
        // waiting to see whether a second click follows.
        .simultaneousGesture(TapGesture(count: 2).onEnded { actions.beginRename(.tab(tab.id), on: .tabBar) })
        .draggable(HierarchyDragItem.tab(tab.id), unlessEditing: edit != nil) {
            Label(title, systemImage: "terminal")
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: HierarchyDragItem.self) { items, _ in
            guard let groupID else { return false }
            return actions.drop(items, onTabAt: index, in: groupID)
        } isTargeted: { isTargeted = $0 }
        .contextMenu {
            Button("Rename Tab") { actions.beginRename(.tab(tab.id), on: .tabBar) }
            Divider()
            Button("Close Tab") { actions.closeTab(tab.id) }
            Button("Close Other Tabs") { actions.closeOtherTabs(than: tab.id) }
                .disabled(isOnly)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Primary on the selected tab, dimmer on the others, and tertiary on
    /// every tab of a window that is not key, as the native bar draws them.
    /// The badge and split/zoom hint: ``TabBarStyle/detail``, or tertiary
    /// like the titles in a window that is not key.
    private var detailStyle: AnyShapeStyle {
        appearsActive ? AnyShapeStyle(TabBarStyle.detail) : AnyShapeStyle(.tertiary)
    }

    private var titleStyle: AnyShapeStyle {
        if !appearsActive { return AnyShapeStyle(.tertiary) }
        return isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(TabBarStyle.unselectedTitle)
    }
}
