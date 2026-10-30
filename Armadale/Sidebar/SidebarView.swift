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
/// starts expanded. The List has no selection, so no row is ever
/// highlighted and a click never gives the List the keyboard. The window's
/// shown path (``SidebarShownPath``: its workspace, the tab group it shows,
/// that group's selected tab) has semibold titles, and accent-coloured
/// icons while the window looks active; every other row is regular with a
/// gray icon. A click on a row
/// (a tap gesture over the whole row) acts on it: another workspace brings
/// its window to front (or opens it); a tab group or tab is selected.
/// Double-click (a simultaneous double-tap gesture, as in the tab bar, or
/// the row's context menu's Rename) turns the row's title into a text field
/// (``InlineRenameField``, driven by the window's ``InlineRename``); each
/// row's context menu also creates and closes. Tab groups can be
/// dragged to reorder them, and a tab (from here or the tab bar) dropped on
/// a tab group moves it there.
struct SidebarView: View {
    let model: AppModel
    let registry: SessionRegistry
    let currentWorkspaceID: WorkspaceID
    let actions: WorkspaceActions
    @State private var expandedWorkspaces: Set<WorkspaceID>
    @State private var collapsedGroups: Set<TabGroupID> = []
    /// Whether the window looks active (key, or main under a panel); an
    /// inactive window's sidebar shows every icon gray.
    @Environment(\.appearsActive) private var appearsActive

    init(model: AppModel, registry: SessionRegistry, currentWorkspaceID: WorkspaceID, actions: WorkspaceActions) {
        self.model = model
        self.registry = registry
        self.currentWorkspaceID = currentWorkspaceID
        self.actions = actions
        _expandedWorkspaces = State(initialValue: [currentWorkspaceID])
    }

    var body: some View {
        List {
            ForEach(model.workspaces) { workspace in
                DisclosureGroup(isExpanded: workspaceExpansion(workspace.id)) {
                    ForEach(workspace.tabGroups) { group in
                        DisclosureGroup(isExpanded: groupExpansion(group.id)) {
                            ForEach(group.tabs) { tab in
                                let item = SidebarItem.tab(tab.id)
                                let edit = rename.edit(of: item, on: .sidebar)
                                TabRow(model: model, registry: registry, tab: tab,
                                       isSelected: tab.id == group.selectedTabID,
                                       isShown: isShown(item),
                                       isAccented: isAccented(item),
                                       rename: rename, edit: edit)
                                    .modifier(rowActions(for: item, isEditing: edit != nil))
                                    .draggable(HierarchyDragItem.tab(tab.id), unlessEditing: edit != nil)
                            }
                        } label: {
                            let item = SidebarItem.tabGroup(group.id)
                            let edit = rename.edit(of: item, on: .sidebar)
                            TabGroupRow(
                                group: group,
                                attentionCount: registry.attention?.count(in: model.sessionIDs(ofTabGroup: group.id)) ?? 0,
                                isShown: isShown(item),
                                isAccented: isAccented(item),
                                actions: actions,
                                edit: edit,
                                rowActions: rowActions(for: item, isEditing: edit != nil))
                        }
                    }
                } label: {
                    let item = SidebarItem.workspace(workspace.id)
                    let edit = rename.edit(of: item, on: .sidebar)
                    WorkspaceRow(
                        workspace: workspace,
                        isCurrent: workspace.id == currentWorkspaceID,
                        isShown: isShown(item),
                        isAccented: isAccented(item),
                        attentionCount: registry.attention?.count(in: model.sessionIDs(in: workspace.id)) ?? 0,
                        rename: rename,
                        edit: edit)
                        .modifier(rowActions(for: item, isEditing: edit != nil))
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: rename.edit?.id) {
            if let edit = rename.edit, edit.surface == .sidebar { reveal(edit.item) }
        }
    }

    private var rename: InlineRename { actions.rename }

    private func isShown(_ item: SidebarItem) -> Bool {
        SidebarShownPath.contains(item, in: model, currentWorkspaceID: currentWorkspaceID)
    }

    private func isAccented(_ item: SidebarItem) -> Bool {
        SidebarShownPath.isAccented(
            item, in: model, currentWorkspaceID: currentWorkspaceID, isWindowActive: appearsActive)
    }

    // MARK: Row actions

    private func rowActions(for item: SidebarItem, isEditing: Bool) -> SidebarRowActions<some View> {
        SidebarRowActions(
            isEditing: isEditing,
            activate: { activate(item) },
            beginRename: { beginRename(item) },
            menu: menu(for: item))
    }

    /// Acts on a clicked row: another workspace is shown (its window brought
    /// to front, or opened); a tab group or tab is selected. A row on the
    /// window's shown path (its workspace, the tab group it shows, that
    /// group's selected tab) writes nothing to the model: a select there
    /// would change no value but still schedule a save, twice for a double
    /// click.
    private func activate(_ item: SidebarItem) {
        guard !isShown(item) else { return }
        switch item {
        case .workspace(let id):
            actions.showWorkspace(id)
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

/// The window's shown path in the sidebar and what it looks like (owner's
/// rules, October 29 and 30, 2026). The shown path is the window's own
/// workspace, the tab group it shows and that group's selected tab. Its
/// rows' titles are semibold in every window; its icons are
/// accent-coloured only while the window looks active. Every other row,
/// the other workspaces' included, is regular with a gray icon, and in an
/// inactive window every icon is gray.
enum SidebarShownPath {
    /// Whether the row is on the window's shown path: its own workspace,
    /// the tab group it shows, or that group's selected tab. Such rows are
    /// semibold in every window, active or not (owner's rule, October 30,
    /// 2026), and are the ones ``isAccented`` colours.
    @MainActor
    static func contains(_ item: SidebarItem, in model: AppModel, currentWorkspaceID: WorkspaceID) -> Bool {
        guard let workspace = model.workspace(currentWorkspaceID) else { return false }
        switch item {
        case .workspace(let id):
            return id == workspace.id
        case .tabGroup(let id):
            return id == workspace.selectedTabGroupID && workspace.tabGroups.contains { $0.id == id }
        case .tab(let id):
            guard let groupID = workspace.selectedTabGroupID,
                  let group = workspace.tabGroups.first(where: { $0.id == groupID })
            else { return false }
            return id == group.selectedTabID && group.tabs.contains { $0.id == id }
        }
    }

    /// Whether the row's icon is accent-coloured: on the shown path of a
    /// window that looks active.
    @MainActor
    static func isAccented(
        _ item: SidebarItem, in model: AppModel, currentWorkspaceID: WorkspaceID, isWindowActive: Bool
    ) -> Bool {
        isWindowActive && contains(item, in: model, currentWorkspaceID: currentWorkspaceID)
    }

    /// The title font for a row: semibold on the shown path.
    static func font(isShown: Bool) -> Font {
        .body.weight(isShown ? .semibold : .regular)
    }

    /// The icon colour for a row: `Color` values, not the hierarchical
    /// `.secondary`, which inside a sidebar label is a level of the list's
    /// own tint and so still reads blue in an active window.
    static func color(isAccented: Bool) -> Color {
        isAccented ? Color.accentColor : Color.secondary
    }
}

/// A sidebar row's mouse actions (owner's decision, October 29, 2026: the
/// List has no selection): a click anywhere across the row acts on it, a
/// double click renames it, and a right click shows its own context menu.
/// The double click is a `TapGesture(count: 2)` added as a
/// `simultaneousGesture`, as in the tab bar, so the single click acts at
/// once instead of waiting to see whether a second click follows. While
/// the row's rename field is up both taps are off, so a click in the field
/// neither starts another edit nor takes the field's focus away. For
/// accessibility the row is one button (its children combined, except
/// while the rename field is up) whose default action acts on it, with a
/// Rename action, since arrow keys and Full Keyboard Access no longer
/// reach rows of a List without a selection.
struct SidebarRowActions<Menu: View>: ViewModifier {
    let isEditing: Bool
    let activate: () -> Void
    let beginRename: () -> Void
    let menu: Menu

    func body(content: Content) -> some View {
        let mask: GestureMask = isEditing ? .subviews : .all
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded { activate() }, including: mask)
            .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename() }, including: mask)
            .contextMenu { menu }
            .accessibilityElement(children: isEditing ? .contain : .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { activate() }
            .accessibilityAction(named: "Rename") { beginRename() }
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    let isCurrent: Bool
    let isShown: Bool
    let isAccented: Bool
    /// Panes of the workspace needing attention.
    let attentionCount: Int
    let rename: InlineRename
    /// The rename under way of this row, if any.
    let edit: InlineRename.Edit?

    var body: some View {
        let isOpen = workspace.window?.isOpen ?? false
        let font = SidebarShownPath.font(isShown: isShown)
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
                    .foregroundStyle(SidebarShownPath.color(isAccented: isAccented))
            }
            .help(isCurrent ? "This window" : (isOpen ? "Show this workspace’s window" : "Open this workspace"))
            Spacer(minLength: 4)
            AttentionCount(count: attentionCount)
        }
    }
}

private struct TabGroupRow<Menu: View>: View {
    let group: TabGroup
    /// Panes of the group needing attention.
    let attentionCount: Int
    let isShown: Bool
    let isAccented: Bool
    let actions: WorkspaceActions
    /// The rename under way of this row, if any.
    let edit: InlineRename.Edit?
    /// The row's click, double click and context menu.
    let rowActions: SidebarRowActions<Menu>
    @State private var isTargeted = false

    var body: some View {
        let font = SidebarShownPath.font(isShown: isShown)
        HStack {
            Label {
                if let edit {
                    InlineRenameField(rename: actions.rename, edit: edit, font: font)
                        .id(edit.id)
                } else {
                    Text(group.name)
                        .font(font)
                }
            } icon: {
                Image(systemName: "folder")
                    .foregroundStyle(SidebarShownPath.color(isAccented: isAccented))
            }
            Spacer(minLength: 4)
            AttentionCount(count: attentionCount)
            Text("\(group.tabs.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .background {
            if isTargeted {
                RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: 2).padding(-3)
            }
        }
        .modifier(rowActions)
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
    let isShown: Bool
    let isAccented: Bool
    let rename: InlineRename
    /// The rename under way of this row, if any.
    let edit: InlineRename.Edit?

    var body: some View {
        let sessions = tab.layout.leaves().compactMap { tab.pane($0)?.sessionID }
        let status = registry.glyphStatus(of: sessions)
        let font = SidebarShownPath.font(isShown: isShown)
        HStack(spacing: 6) {
            StatusGlyph(status: sessions.isEmpty ? nil : status)
            Label {
                if let edit {
                    InlineRenameField(rename: rename, edit: edit, font: font)
                        .id(edit.id)
                } else {
                    Text(model.displayTitle(for: tab))
                        .font(font)
                }
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(SidebarShownPath.color(isAccented: isAccented))
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(isSelected || status == .attention ? .primary : .secondary)
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
