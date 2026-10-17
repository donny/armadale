import ArmadaleCore
import SwiftUI

/// A row of the sidebar.
enum SidebarItem: Hashable {
    case workspace(WorkspaceID)
    case tabGroup(TabGroupID)
    case tab(TabID)
}

/// The app-global sidebar (DESIGN §1): every workspace, its tab groups, and
/// their tabs, the same in every window. The current window's workspace
/// starts expanded and is shown in bold; its selected tab group is the
/// highlighted row. Clicking another workspace brings its window to front
/// (or opens it); clicking a tab group or tab selects it. Double-click
/// renames; the context menu creates, renames and closes. Tab groups can be
/// dragged to reorder them, and a tab (from here or the tab bar) dropped on
/// a tab group moves it there.
struct SidebarView: View {
    let model: AppModel
    let registry: SessionRegistry
    let currentWorkspaceID: WorkspaceID
    let actions: WorkspaceActions
    @State private var expandedWorkspaces: Set<WorkspaceID>
    @State private var collapsedGroups: Set<TabGroupID> = []

    init(model: AppModel, registry: SessionRegistry, currentWorkspaceID: WorkspaceID, actions: WorkspaceActions) {
        self.model = model
        self.registry = registry
        self.currentWorkspaceID = currentWorkspaceID
        self.actions = actions
        _expandedWorkspaces = State(initialValue: [currentWorkspaceID])
    }

    var body: some View {
        List(selection: selection) {
            ForEach(model.workspaces) { workspace in
                DisclosureGroup(isExpanded: workspaceExpansion(workspace.id)) {
                    ForEach(workspace.tabGroups) { group in
                        DisclosureGroup(isExpanded: groupExpansion(group.id)) {
                            ForEach(group.tabs) { tab in
                                TabRow(model: model, registry: registry, tab: tab,
                                       isSelected: tab.id == group.selectedTabID)
                                    .tag(SidebarItem.tab(tab.id))
                                    .draggable(HierarchyDragItem.tab(tab.id))
                            }
                        } label: {
                            TabGroupRow(
                                group: group,
                                isSelected: group.id == workspace.selectedTabGroupID,
                                actions: actions)
                                .tag(SidebarItem.tabGroup(group.id))
                        }
                    }
                } label: {
                    WorkspaceRow(
                        workspace: workspace,
                        isCurrent: workspace.id == currentWorkspaceID)
                        .tag(SidebarItem.workspace(workspace.id))
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if let item = items.first { menu(for: item) }
        } primaryAction: { items in
            if let item = items.first { rename(item) }
        }
    }

    // MARK: Selection

    /// The highlighted row is this window's selected tab group; choosing a
    /// row acts on it.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { model.workspace(currentWorkspaceID)?.selectedTabGroupID.map(SidebarItem.tabGroup) },
            set: { item in
                guard let item else { return }
                activate(item)
            })
    }

    private func activate(_ item: SidebarItem) {
        switch item {
        case .workspace(let id):
            if id != currentWorkspaceID { actions.showWorkspace(id) }
        case .tabGroup(let id):
            actions.select(tabGroup: id)
        case .tab(let id):
            actions.select(tab: id)
        }
    }

    private func rename(_ item: SidebarItem) {
        switch item {
        case .workspace(let id): actions.renameWorkspace(id)
        case .tabGroup(let id): actions.renameTabGroup(id)
        case .tab(let id): actions.renameTab(id)
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func menu(for item: SidebarItem) -> some View {
        switch item {
        case .workspace(let id):
            Button("New Tab Group") { actions.newTabGroup(in: id) }
            Button("Rename Workspace…") { actions.renameWorkspace(id) }
            if id != currentWorkspaceID {
                Divider()
                Button(model.workspace(id)?.window?.isOpen == true ? "Show Window" : "Open Window") {
                    actions.showWorkspace(id)
                }
            }
            Divider()
            Button("Delete Workspace…") { actions.deleteWorkspace(id) }
        case .tabGroup(let id):
            Button("New Tab") { actions.newTab(in: id) }
            Button("New Tab Group") { actions.newTabGroup(in: model.workspaceID(containing: id)) }
            Button("Rename Tab Group…") { actions.renameTabGroup(id) }
            Divider()
            Button("Close Tab Group") { actions.closeTabGroup(id) }
        case .tab(let id):
            Button("Rename Tab…") { actions.renameTab(id) }
            Divider()
            Button("Close Tab") { actions.closeTab(id) }
            Button("Close Other Tabs") { actions.closeOtherTabs(than: id) }
                .disabled((model.location(of: id).flatMap { model.tabGroup($0.tabGroup) }?.tabs.count ?? 0) < 2)
        }
    }

    // MARK: Expansion

    private func workspaceExpansion(_ id: WorkspaceID) -> Binding<Bool> {
        Binding(
            get: { expandedWorkspaces.contains(id) },
            set: { isExpanded in
                if isExpanded { expandedWorkspaces.insert(id) } else { expandedWorkspaces.remove(id) }
            })
    }

    private func groupExpansion(_ id: TabGroupID) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(id) },
            set: { isExpanded in
                if isExpanded { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
            })
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    let isCurrent: Bool

    var body: some View {
        let isOpen = workspace.window?.isOpen ?? false
        Label {
            Text(workspace.name)
                .font(.body.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isOpen || isCurrent ? .primary : .secondary)
        } icon: {
            Image(systemName: isOpen ? "macwindow" : "macwindow.badge.plus")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
        }
            .help(isCurrent ? "This window" : (isOpen ? "Show this workspace’s window" : "Open this workspace"))
    }
}

private struct TabGroupRow: View {
    let group: TabGroup
    let isSelected: Bool
    let actions: WorkspaceActions
    @State private var isTargeted = false

    var body: some View {
        HStack {
            Label(group.name, systemImage: isSelected ? "folder.fill" : "folder")
            Spacer(minLength: 4)
            Text("\(group.tabs.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .background {
            if isTargeted {
                RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: 2).padding(-3)
            }
        }
        .draggable(HierarchyDragItem.tabGroup(group.id))
        .dropDestination(for: HierarchyDragItem.self) { items, _ in
            actions.drop(items, onTabGroup: group.id)
        } isTargeted: { isTargeted = $0 }
    }
}

private struct TabRow: View {
    let model: AppModel
    let registry: SessionRegistry
    let tab: ArmadaleCore.Tab
    let isSelected: Bool

    var body: some View {
        let sessions = tab.layout.leaves().compactMap { tab.pane($0)?.sessionID }
        HStack(spacing: 6) {
            StatusGlyph(status: registry.status(of: sessions))
            Label(model.displayTitle(for: tab), systemImage: icon)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
    }

    private var icon: String {
        guard let pane = tab.pane(tab.focusedPaneID),
              let session = model.session(pane.sessionID),
              let profile = model.profile(session.profileID)
        else { return "terminal" }
        return profile.icon
    }
}
