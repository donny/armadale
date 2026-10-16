/// Everything Armadale persists between launches. Scrollback and terminal
/// state are not included; the session daemon owns those.
public struct PersistedState: Codable, Sendable, Hashable {
    /// The schema version this build reads and writes.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var workspaces: [Workspace]
    public var sessions: [Session]
    public var hosts: [Host]
    public var profiles: [Profile]

    public init(
        schemaVersion: Int = PersistedState.currentSchemaVersion,
        workspaces: [Workspace] = [],
        sessions: [Session] = [],
        hosts: [Host] = [],
        profiles: [Profile] = Profile.builtIns
    ) {
        self.schemaVersion = schemaVersion
        self.workspaces = workspaces
        self.sessions = sessions
        self.hosts = hosts
        self.profiles = profiles
    }

    /// A first-launch state: no workspaces, the built-in profiles.
    public static let empty = PersistedState()
}

// MARK: - Validation

extension PersistedState {
    /// Returns a copy that satisfies the model's structural invariants,
    /// plus a description of every repair made (empty if none). Applied
    /// after loading, so a hand-edited or partially written file cannot
    /// leave the UI with dangling references.
    ///
    /// - Workspace, tab group, tab, pane and session IDs are unique; later
    ///   duplicates are dropped.
    /// - A tab's layout has no repeated leaves; every leaf has a pane
    ///   record and every pane record is a leaf (orphans are dropped). A tab
    ///   left with no panes is dropped.
    /// - `focusedPaneID` is a leaf (else the first leaf); `zoomedPaneID` is
    ///   a leaf or `nil`.
    /// - Selections point at existing children (else the first one, or `nil`).
    /// - Built-in profiles and other profile references are left alone.
    public func repaired() -> (state: PersistedState, issues: [String]) {
        var issues: [String] = []
        var state = self

        var seenSessions = Set<SessionID>()
        state.sessions = sessions.filter { session in
            guard seenSessions.insert(session.id).inserted else {
                issues.append("Dropped duplicate session \(session.id)")
                return false
            }
            return true
        }

        var seenWorkspaces = Set<WorkspaceID>()
        var seenGroups = Set<TabGroupID>()
        var seenTabs = Set<TabID>()
        var seenPanes = Set<PaneID>()
        var repairedWorkspaces: [Workspace] = []

        for var workspace in workspaces {
            guard seenWorkspaces.insert(workspace.id).inserted else {
                issues.append("Dropped duplicate workspace \(workspace.id)")
                continue
            }
            var groups: [TabGroup] = []
            for var group in workspace.tabGroups {
                guard seenGroups.insert(group.id).inserted else {
                    issues.append("Dropped duplicate tab group \(group.id)")
                    continue
                }
                var tabs: [Tab] = []
                for tab in group.tabs {
                    guard seenTabs.insert(tab.id).inserted else {
                        issues.append("Dropped duplicate tab \(tab.id)")
                        continue
                    }
                    if let fixed = Self.repair(tab, seenPanes: &seenPanes, issues: &issues) {
                        tabs.append(fixed)
                    } else {
                        issues.append("Dropped tab \(tab.id) with no valid panes")
                    }
                }
                group.tabs = tabs
                if let selected = group.selectedTabID, !tabs.contains(where: { $0.id == selected }) {
                    issues.append("Reset selected tab of tab group \(group.id)")
                    group.selectedTabID = tabs.first?.id
                } else if group.selectedTabID == nil, let first = tabs.first {
                    group.selectedTabID = first.id
                }
                groups.append(group)
            }
            workspace.tabGroups = groups
            if let selected = workspace.selectedTabGroupID, !groups.contains(where: { $0.id == selected }) {
                issues.append("Reset selected tab group of workspace \(workspace.id)")
                workspace.selectedTabGroupID = groups.first?.id
            } else if workspace.selectedTabGroupID == nil, let first = groups.first {
                workspace.selectedTabGroupID = first.id
            }
            repairedWorkspaces.append(workspace)
        }
        state.workspaces = repairedWorkspaces
        return (state, issues)
    }

    private static func repair(_ tab: Tab, seenPanes: inout Set<PaneID>, issues: inout [String]) -> Tab? {
        var tab = tab
        guard var layout = tab.layout.removingDuplicateLeaves() else { return nil }
        if layout != tab.layout { issues.append("Removed repeated panes from the layout of tab \(tab.id)") }

        // Pane records: unique within the app, and only for leaves.
        let leaves = Set(layout.leaves())
        var panes: [Pane] = []
        for pane in tab.panes {
            if !leaves.contains(pane.id) {
                issues.append("Dropped pane \(pane.id) that is not in the layout of tab \(tab.id)")
            } else if !seenPanes.insert(pane.id).inserted {
                issues.append("Dropped duplicate pane \(pane.id)")
            } else {
                panes.append(pane)
            }
        }
        // Leaves without a record have no session; remove them.
        let recorded = Set(panes.map(\.id))
        for leaf in layout.leaves() where !recorded.contains(leaf) {
            issues.append("Removed pane \(leaf) without a record from tab \(tab.id)")
            guard let smaller = layout.remove(leaf) else { return nil }
            layout = smaller
        }
        tab.layout = layout
        tab.panes = panes

        let finalLeaves = layout.leaves()
        if !finalLeaves.contains(tab.focusedPaneID), let first = finalLeaves.first {
            issues.append("Reset focused pane of tab \(tab.id)")
            tab.focusedPaneID = first
        }
        if let zoomed = tab.zoomedPaneID, !finalLeaves.contains(zoomed) {
            issues.append("Cleared zoomed pane of tab \(tab.id)")
            tab.zoomedPaneID = nil
        }
        return tab
    }
}
