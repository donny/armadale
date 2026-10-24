import ArmadaleCore
import SwiftUI

/// A row of the sidebar.
enum SidebarItem: Hashable {
    case workspace(WorkspaceID)
    case tabGroup(TabGroupID)
    case tab(TabID)
}

/// The app-global sidebar (DESIGN §1): every workspace, its tab groups, and
/// their tabs, the same in every window. Workspace and tab group rows count
/// their panes needing attention; a tab needing attention shows ◐. The current window's workspace
/// starts expanded and is shown in bold; its selected tab group is the
/// highlighted row. Clicking another workspace brings its window to front
/// (or opens it); clicking a tab group or tab selects it. Double-click (or
/// the context menu's Rename) turns the row's title into a text field
/// (``InlineRenameField``, driven by the window's ``InlineRename``); the
/// context menu also creates and closes. Tab groups can be
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
                                       isSelected: tab.id == group.selectedTabID,
                                       rename: rename, edit: rename.edit(of: .tab(tab.id), on: .sidebar))
                                    .tag(SidebarItem.tab(tab.id))
                                    .draggable(
                                        HierarchyDragItem.tab(tab.id),
                                        unlessEditing: rename.edit(of: .tab(tab.id), on: .sidebar) != nil)
                            }
                        } label: {
                            TabGroupRow(
                                group: group,
                                attentionCount: registry.attention?.count(in: model.sessionIDs(ofTabGroup: group.id)) ?? 0,
                                actions: actions,
                                edit: rename.edit(of: .tabGroup(group.id), on: .sidebar))
                                .tag(SidebarItem.tabGroup(group.id))
                        }
                    }
                } label: {
                    WorkspaceRow(
                        workspace: workspace,
                        isCurrent: workspace.id == currentWorkspaceID,
                        attentionCount: registry.attention?.count(in: model.sessionIDs(in: workspace.id)) ?? 0,
                        rename: rename,
                        edit: rename.edit(of: .workspace(workspace.id), on: .sidebar))
                        .tag(SidebarItem.workspace(workspace.id))
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if let item = items.first { menu(for: item) }
        } primaryAction: { items in
            if let item = items.first { beginRename(item) }
        }
        .onChange(of: rename.edit?.id) {
            if let edit = rename.edit, edit.surface == .sidebar { reveal(edit.item) }
        }
    }

    private var rename: InlineRename { actions.rename }

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

    private func beginRename(_ item: SidebarItem) {
        actions.beginRename(item, on: .sidebar)
    }

    /// Expands what contains `item`, so the row being renamed is shown.
    private func reveal(_ item: SidebarItem) {
        switch item {
        case .workspace:
            break
        case .tabGroup(let id):
            if let workspace = model.workspaceID(containing: id) { expandedWorkspaces.insert(workspace) }
        case .tab(let id):
            guard let location = model.location(of: id) else { return }
            expandedWorkspaces.insert(location.workspace)
            collapsedGroups.remove(location.tabGroup)
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func menu(for item: SidebarItem) -> some View {
        switch item {
        case .workspace(let id):
            Button("New Tab Group") { actions.newTabGroup(in: id) }
            Button("Rename Workspace") { beginRename(item) }
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
            Button("Rename Tab Group") { beginRename(item) }
            Divider()
            Button("Close Tab Group") { actions.closeTabGroup(id) }
        case .tab(let id):
            Button("Rename Tab") { beginRename(item) }
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
    /// Panes of the workspace needing attention.
    let attentionCount: Int
    let rename: InlineRename
    /// The rename under way of this row, if any.
    let edit: InlineRename.Edit?

    var body: some View {
        let isOpen = workspace.window?.isOpen ?? false
        let font = Font.body.weight(isCurrent ? .semibold : .regular)
        HStack {
            Label {
                if let edit {
                    InlineRenameField(rename: rename, edit: edit, font: font)
                        .id(edit.id)
                } else {
                    Text(workspace.name)
                        .font(font)
                        .foregroundStyle(isOpen || isCurrent ? .primary : .secondary)
                }
            } icon: {
                Image(systemName: isOpen ? "macwindow" : "macwindow.badge.plus")
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            }
            .help(isCurrent ? "This window" : (isOpen ? "Show this workspace’s window" : "Open this workspace"))
            Spacer(minLength: 4)
            AttentionCount(count: attentionCount)
        }
    }
}

private struct TabGroupRow: View {
    let group: TabGroup
    /// Panes of the group needing attention.
    let attentionCount: Int
    let actions: WorkspaceActions
    /// The rename under way of this row, if any.
    let edit: InlineRename.Edit?
    @State private var isTargeted = false

    var body: some View {
        HStack {
            Label {
                if let edit {
                    InlineRenameField(rename: actions.rename, edit: edit)
                        .id(edit.id)
                } else {
                    Text(group.name)
                }
            } icon: {
                Image(systemName: "folder")
            }
            Spacer(minLength: 4)
            AttentionCount(count: attentionCount)
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
        .draggable(HierarchyDragItem.tabGroup(group.id), unlessEditing: edit != nil)
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
    let rename: InlineRename
    /// The rename under way of this row, if any.
    let edit: InlineRename.Edit?

    var body: some View {
        let sessions = tab.layout.leaves().compactMap { tab.pane($0)?.sessionID }
        let status = registry.glyphStatus(of: sessions)
        HStack(spacing: 6) {
            StatusGlyph(status: sessions.isEmpty ? nil : status)
            Label {
                if let edit {
                    InlineRenameField(
                        rename: rename, edit: edit, font: .body.weight(status == .attention ? .semibold : .regular))
                        .id(edit.id)
                } else {
                    Text(model.displayTitle(for: tab))
                }
            } icon: {
                Image(systemName: icon)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(isSelected || status == .attention ? .primary : .secondary)
            .fontWeight(status == .attention ? .semibold : nil)
            HostBadge(
                hosts: registry.hosts(of: sessions), persistenceNote: registry.persistenceNote(of: sessions),
                showsName: true)
        }
    }

    private var icon: String {
        guard let sessionID = tab.pane(tab.focusedPaneID)?.sessionID,
              let session = model.session(sessionID),
              let profile = model.profile(session.profileID)
        else { return "terminal" }
        return profile.icon
    }
}
