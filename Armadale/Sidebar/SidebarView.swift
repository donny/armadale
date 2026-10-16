import ArmadaleCore
import SwiftUI

/// The app-global sidebar: every workspace, its tab groups, and their tabs.
/// The current window's workspace starts expanded. Read-only in step 1.
struct SidebarView: View {
    let model: AppModel
    let currentWorkspaceID: WorkspaceID
    @State private var expanded: Set<WorkspaceID>

    init(model: AppModel, currentWorkspaceID: WorkspaceID) {
        self.model = model
        self.currentWorkspaceID = currentWorkspaceID
        _expanded = State(initialValue: [currentWorkspaceID])
    }

    var body: some View {
        List {
            ForEach(model.workspaces) { workspace in
                DisclosureGroup(isExpanded: expansion(for: workspace.id)) {
                    ForEach(workspace.tabGroups) { group in
                        TabGroupSection(
                            model: model,
                            group: group,
                            isSelected: group.id == workspace.selectedTabGroupID)
                    }
                } label: {
                    Label(workspace.name, systemImage: "macwindow")
                        .fontWeight(workspace.id == currentWorkspaceID ? .semibold : .regular)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func expansion(for id: WorkspaceID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isExpanded in
                if isExpanded { expanded.insert(id) } else { expanded.remove(id) }
            })
    }
}

/// A tab group and its tabs.
private struct TabGroupSection: View {
    let model: AppModel
    let group: TabGroup
    let isSelected: Bool
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(group.tabs) { tab in
                Label(model.displayTitle(for: tab), systemImage: icon(for: tab))
                    .foregroundStyle(tab.id == group.selectedTabID ? .primary : .secondary)
            }
        } label: {
            Label(group.name, systemImage: isSelected ? "folder.fill" : "folder")
        }
    }

    private func icon(for tab: ArmadaleCore.Tab) -> String {
        guard let pane = tab.pane(tab.focusedPaneID),
              let session = model.session(pane.sessionID),
              let profile = model.profile(session.profileID)
        else { return "terminal" }
        return profile.icon
    }
}
