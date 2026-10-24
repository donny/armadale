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
    /// Saved session recipes, in the order the user keeps them. Added on
    /// October 24, 2026 without a schema bump: absent decodes as none.
    public var favorites: [Favorite]

    public init(
        schemaVersion: Int = PersistedState.currentSchemaVersion,
        workspaces: [Workspace] = [],
        sessions: [Session] = [],
        hosts: [Host] = [],
        profiles: [Profile] = Profile.builtIns,
        favorites: [Favorite] = []
    ) {
        self.schemaVersion = schemaVersion
        self.workspaces = workspaces
        self.sessions = sessions
        self.hosts = hosts
        self.profiles = profiles
        self.favorites = favorites
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, workspaces, sessions, hosts, profiles, favorites
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        sessions = try container.decode([Session].self, forKey: .sessions)
        hosts = try container.decode([Host].self, forKey: .hosts)
        profiles = try container.decode([Profile].self, forKey: .profiles)
        favorites = try container.decodeIfPresent([Favorite].self, forKey: .favorites) ?? []
    }

    /// A first-launch state: no workspaces, the built-in profiles.
    public static let empty = PersistedState()
}

// MARK: - Housekeeping

extension PersistedState {
    /// Whether `workspace` is a closed window with no tab groups: what
    /// closing a workspace's last group left behind before October 23,
    /// 2026, when it started deleting the workspace instead (DESIGN §3, §8).
    public static func isEmptyClosedWorkspace(_ workspace: Workspace) -> Bool {
        workspace.tabGroups.isEmpty && workspace.window?.isOpen == false
    }

    /// A copy without empty closed workspaces (``isEmptyClosedWorkspace(_:)``),
    /// even if none is left: the app makes a fresh workspace when it has
    /// none. A workspace with no window state yet counts as open, as at
    /// launch, and is kept (reopening it makes a fresh "Main" group).
    /// ``StateStore`` applies this on every load, without a schema bump:
    /// such a workspace holds nothing (no tab groups, so no sessions).
    public func droppingEmptyClosedWorkspaces() -> PersistedState {
        var state = self
        state.workspaces.removeAll(where: Self.isEmptyClosedWorkspace)
        return state
    }
}

// MARK: - Validation

extension PersistedState {
    /// Returns a copy that satisfies the model's structural invariants,
    /// plus a description of every repair made (empty if none). Applied
    /// after loading, so a hand-edited or partially written file cannot
    /// leave the UI with dangling references.
    ///
    /// - Workspace, tab group, tab, pane, session and favorite IDs are
    ///   unique; later duplicates are dropped.
    /// - A pane without a session (an empty pane, DESIGN §8 "New sessions")
    ///   is kept as it is. Favorites naming a missing host or profile are
    ///   kept too (they are shown as broken).
    /// - A tab's layout has no repeated leaves; every leaf has a pane
    ///   record and every pane record is a leaf (orphans are dropped). A tab
    ///   left with no panes is dropped.
    /// - `focusedPaneID` is a leaf (else the first leaf); `zoomedPaneID` is
    ///   a leaf or `nil`.
    /// - Selections point at existing children (else the first one, or `nil`).
    /// - A tab group left with no tabs is dropped, and then a closed
    ///   workspace left with no tab groups
    ///   (``droppingEmptyClosedWorkspaces()``, which loading has applied
    ///   already, but a repair can empty one more): a tab group is never
    ///   kept without tabs, nor a workspace without tab groups (DESIGN §1).
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

        var seenFavorites = Set<FavoriteID>()
        state.favorites = favorites.filter { favorite in
            guard seenFavorites.insert(favorite.id).inserted else {
                issues.append("Dropped duplicate favorite \(favorite.id)")
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
                guard !tabs.isEmpty else {
                    issues.append("Dropped tab group \(group.id) with no tabs")
                    continue
                }
                if let selected = group.selectedTabID, !tabs.contains(where: { $0.id == selected }) {
                    issues.append("Reset selected tab of tab group \(group.id)")
                    group.selectedTabID = tabs.first?.id
                } else if group.selectedTabID == nil, let first = tabs.first {
                    group.selectedTabID = first.id
                }
                groups.append(group)
            }
            workspace.tabGroups = groups
            if Self.isEmptyClosedWorkspace(workspace) {
                issues.append("Dropped closed workspace \(workspace.id) with no tab groups")
                continue
            }
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
        // Leaves without a record are removed. (A record without a session
        // is an empty pane, and is kept.)
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
