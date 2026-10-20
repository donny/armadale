import AppKit
import ArmadaleCore
import SwiftUI

/// Where each tab of a tab bar is, in the bar's own coordinates (origin
/// top left), so the hosting view can map a middle click to a tab.
@MainActor
final class TabFrameStore {
    var frames: [TabID: CGRect] = [:]

    func tab(at point: CGPoint) -> TabID? {
        frames.first { $0.value.contains(point) }?.key
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
/// (◐ and a tinted background when a pane needs attention), title, ⌘N
/// badge, close button on hover, and "+" for a new tab. Click
/// selects, drag reorders (or drops the tab on a sidebar tab group),
/// double-click (or the context menu's Rename Tab) edits the title in place
/// (``InlineRenameField``), the context menu also closes.
struct TabBarView: View {
    let model: AppModel
    let registry: SessionRegistry
    let workspaceID: WorkspaceID
    let actions: WorkspaceActions
    let frames: TabFrameStore

    static let height: CGFloat = 32

    var body: some View {
        let group = model.workspace(workspaceID)?.selectedTabGroup
        let tabs = group?.tabs ?? []
        GeometryReader { geometry in
            let available = geometry.size.width - 44
            let width = tabs.isEmpty ? 0 : min(max(available / CGFloat(tabs.count), 110), 220)
            HStack(spacing: 4) {
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
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
                                edit: actions.rename.edit(of: .tab(tab.id), on: .tabBar))
                            .frame(width: width)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(tabBarCoordinateSpace))
                            } action: { frame in
                                frames.frames[tab.id] = frame
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                .frame(maxWidth: tabs.isEmpty ? 0 : .infinity, alignment: .leading)
                .fixedSize(horizontal: tabs.isEmpty, vertical: false)

                Button {
                    actions.newTab(in: group?.id)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("New Tab (right-click to choose a profile or a host)")
                .accessibilityLabel("New Tab")
                .contextMenu {
                    ForEach(model.profiles) { profile in
                        Button {
                            actions.newTab(in: group?.id, profile: profile.id)
                        } label: {
                            Label(profile.name, systemImage: profile.icon)
                        }
                    }
                    if !model.hosts.isEmpty {
                        Section("On Host") {
                            ForEach(model.hosts) { host in
                                Button {
                                    actions.newTab(onHost: host.id, in: group?.id)
                                } label: {
                                    Label(host.displayName, systemImage: "network")
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(width: geometry.size.width, height: geometry.size.height)
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
        }
    }

    /// ⌘1…⌘8 for the first eight tabs; ⌘9 always goes to the last one.
    static func badge(index: Int, count: Int) -> String? {
        if index < 8 { return "⌘\(index + 1)" }
        return index == count - 1 ? "⌘9" : nil
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
    /// The rename under way of this tab, if any.
    let edit: InlineRename.Edit?

    @State private var isHovering = false
    @State private var isTargeted = false

    private static let font = Font.system(size: 12)

    var body: some View {
        let title = model.displayTitle(for: tab)
        let sessions = tab.layout.leaves().compactMap { tab.pane($0)?.sessionID }
        let status = registry.glyphStatus(of: sessions)
        let needsAttention = sessions.contains { registry.attention?.needsAttention($0) ?? false }
        HStack(spacing: 6) {
            StatusGlyph(status: status)
            HostBadge(hosts: registry.hosts(of: sessions), persistenceNote: registry.persistenceNote(of: sessions))
            if let edit {
                InlineRenameField(rename: actions.rename, edit: edit, font: Self.font)
                    .id(edit.id)
                    .frame(maxWidth: .infinity)
            } else {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            if tab.layout.isSplit {
                Image(systemName: tab.zoomedPaneID == nil ? "rectangle.split.2x1" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help(tab.zoomedPaneID == nil ? "\(tab.panes.count) panes" : "Zoomed")
            }
            if edit == nil { Spacer(minLength: 0) }
            ZStack {
                if let badge {
                    Text(badge)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
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
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.11 : (isHovering ? 0.05 : 0)))
            if needsAttention {
                // A subtle highlight for a tab needing attention (DESIGN §8).
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(StatusGlyph.attentionColor.opacity(0.13))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(StatusGlyph.attentionColor.opacity(0.35), lineWidth: 1)
            }
        }
        .overlay(alignment: .leading) {
            if isTargeted {
                Capsule().fill(Color.accentColor).frame(width: 2).padding(.vertical, 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
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
}
