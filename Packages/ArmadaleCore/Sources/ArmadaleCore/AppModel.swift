import Foundation
import Observation

/// What closing a pane or tab ended up closing. Closing cascades upward:
/// the last pane closes its tab, the last tab removes its tab group, and the
/// last tab group closes the workspace's window (the workspace itself stays).
public enum CloseResult: Equatable, Sendable {
    /// Nothing matched the ID.
    case notFound
    /// A pane was removed; its tab remains.
    case closedPane(PaneID, in: TabID)
    /// A tab was removed; its tab group remains.
    case closedTab(TabID, in: TabGroupID)
    /// The tab group's last tab was closed, so the group was removed too.
    case closedTabGroup(TabGroupID, in: WorkspaceID)
    /// The workspace's last tab group was removed. The workspace stays in
    /// the model with `window.isOpen == false`; its window should close.
    case closedWindow(WorkspaceID)
}

/// The single owner of Armadale's state. Every mutation goes through an
/// intent method here, which keeps all windows consistent and increments
/// ``changeCount``; the app observes `changeCount` to schedule persistence.
@MainActor
@Observable
public final class AppModel {
    public private(set) var workspaces: [Workspace]
    public private(set) var sessions: [Session]
    public private(set) var hosts: [Host]
    public private(set) var profiles: [Profile]

    /// Incremented by every intent that changes persisted state.
    public private(set) var changeCount = 0

    /// Working directory for sessions created without an explicit one.
    @ObservationIgnored public var defaultWorkingDirectory: String
    /// Profile used when an intent does not name one.
    @ObservationIgnored public var defaultProfileID: ProfileID = Profile.shell.id

    /// Creates a model from persisted state. Built-in profiles missing from
    /// `state` are added back so they can always be resolved.
    public init(state: PersistedState = .empty, defaultWorkingDirectory: String = NSHomeDirectory()) {
        self.workspaces = state.workspaces
        self.sessions = state.sessions
        self.hosts = state.hosts
        var profiles = state.profiles
        for builtIn in Profile.builtIns where !profiles.contains(where: { $0.id == builtIn.id }) {
            profiles.append(builtIn)
        }
        self.profiles = profiles
        self.defaultWorkingDirectory = defaultWorkingDirectory
    }

    /// A snapshot suitable for ``StateStore``.
    public var persistedState: PersistedState {
        PersistedState(workspaces: workspaces, sessions: sessions, hosts: hosts, profiles: profiles)
    }

    // MARK: Lookup

    public func workspace(_ id: WorkspaceID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    public func session(_ id: SessionID) -> Session? {
        sessions.first { $0.id == id }
    }

    public func profile(_ id: ProfileID) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// The workspace and tab group containing `tab`.
    public func location(of tab: TabID) -> (workspace: WorkspaceID, tabGroup: TabGroupID)? {
        for workspace in workspaces {
            for group in workspace.tabGroups where group.tabs.contains(where: { $0.id == tab }) {
                return (workspace.id, group.id)
            }
        }
        return nil
    }

    /// The tab containing `pane`.
    public func tab(containing pane: PaneID) -> Tab? {
        for workspace in workspaces {
            for group in workspace.tabGroups {
                if let tab = group.tabs.first(where: { $0.layout.contains(pane) }) { return tab }
            }
        }
        return nil
    }

    /// The selected tab of the workspace's selected tab group.
    public func selectedTab(in workspace: WorkspaceID) -> Tab? {
        self.workspace(workspace)?.selectedTabGroup?.selectedTab
    }

    /// The workspace containing `tabGroup`.
    public func workspaceID(containing tabGroup: TabGroupID) -> WorkspaceID? {
        workspaces.first { $0.tabGroups.contains { $0.id == tabGroup } }?.id
    }

    /// The tab group with `id`, in any workspace.
    public func tabGroup(_ id: TabGroupID) -> TabGroup? {
        for workspace in workspaces {
            if let group = workspace.tabGroups.first(where: { $0.id == id }) { return group }
        }
        return nil
    }

    /// The tab with `id`, in any workspace.
    public func tab(_ id: TabID) -> Tab? {
        guard let path = path(ofTab: id) else { return nil }
        return workspaces[path.workspace].tabGroups[path.tabGroup].tabs[path.tab]
    }

    /// The sessions of every pane of `tab`, in layout order.
    public func sessionIDs(ofTab id: TabID) -> [SessionID] {
        guard let path = path(ofTab: id) else { return [] }
        let tab = workspaces[path.workspace].tabGroups[path.tabGroup].tabs[path.tab]
        return tab.layout.leaves().compactMap { tab.pane($0)?.sessionID }
    }

    /// The title shown for `tab`: its custom title, else the focused
    /// session's title, else the focused session's profile name.
    public func displayTitle(for tab: Tab) -> String {
        if let custom = tab.customTitle, !custom.isEmpty { return custom }
        guard let pane = tab.pane(tab.focusedPaneID), let session = session(pane.sessionID) else {
            return "Tab"
        }
        if !session.title.isEmpty { return session.title }
        return profile(session.profileID)?.name ?? "Shell"
    }

    // MARK: Workspaces

    /// Creates a workspace with one tab group holding one tab, open in a window.
    @discardableResult
    public func newWorkspace(name: String? = nil, profile: ProfileID? = nil) -> WorkspaceID {
        let tab = makeTab(profile: profile ?? defaultProfileID, location: .local, workingDirectory: nil)
        let group = TabGroup(name: "Main", tabs: [tab])
        let workspace = Workspace(
            name: name ?? nextWorkspaceName(),
            tabGroups: [group],
            window: WindowState(isOpen: true))
        workspaces.append(workspace)
        didChange()
        return workspace.id
    }

    /// Renames a workspace.
    public func renameWorkspace(_ id: WorkspaceID, to name: String) {
        mutateWorkspace(id) { $0.name = name }
    }

    /// Deletes a workspace and all its sessions.
    public func deleteWorkspace(_ id: WorkspaceID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let sessionIDs = workspaces[index].tabGroups.flatMap(\.tabs).flatMap(\.panes).map(\.sessionID)
        workspaces.remove(at: index)
        removeSessions(Set(sessionIDs))
        didChange()
    }

    /// Records window geometry and visibility for a workspace.
    public func updateWindowState(_ state: WindowState, for id: WorkspaceID) {
        mutateWorkspace(id) { $0.window = state }
    }

    /// Marks a workspace's window open. A workspace whose tab groups were all
    /// closed gets a fresh "Main" group with one tab of the default profile.
    public func reopenWorkspace(_ id: WorkspaceID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        if workspaces[index].tabGroups.isEmpty {
            let tab = makeTab(profile: defaultProfileID, location: .local, workingDirectory: nil)
            let group = TabGroup(name: "Main", tabs: [tab])
            workspaces[index].tabGroups = [group]
            workspaces[index].selectedTabGroupID = group.id
        }
        var window = workspaces[index].window ?? WindowState()
        window.isOpen = true
        workspaces[index].window = window
        didChange()
    }

    // MARK: Tab groups

    /// Adds a tab group with one tab to a workspace and selects it.
    @discardableResult
    public func newTabGroup(in workspaceID: WorkspaceID, name: String? = nil) -> TabGroupID? {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        let tab = makeTab(profile: defaultProfileID, location: .local, workingDirectory: nil)
        let group = TabGroup(name: name ?? "Group \(workspaces[index].tabGroups.count + 1)", tabs: [tab])
        workspaces[index].tabGroups.append(group)
        workspaces[index].selectedTabGroupID = group.id
        didChange()
        return group.id
    }

    /// Renames a tab group.
    public func renameTabGroup(_ id: TabGroupID, to name: String) {
        mutateTabGroup(id) { $0.name = name }
    }

    /// Selects a tab group in its workspace.
    public func select(tabGroup id: TabGroupID) {
        guard let path = path(ofTabGroup: id) else { return }
        workspaces[path.workspace].selectedTabGroupID = id
        didChange()
    }

    /// Selects the workspace's tab group number `number` (1-based, ⇧⌘1…9).
    /// Returns false (and changes nothing) if there is no such group.
    @discardableResult
    public func selectTabGroup(number: Int, in workspaceID: WorkspaceID) -> Bool {
        guard let groups = workspace(workspaceID)?.tabGroups, number >= 1, number <= groups.count else { return false }
        select(tabGroup: groups[number - 1].id)
        return true
    }

    /// Moves a tab group to position `index` among its workspace's groups.
    /// `index` counts positions *after* the group has been removed, and is
    /// clamped. Selection is unchanged.
    public func moveTabGroup(_ id: TabGroupID, to index: Int) {
        guard let path = path(ofTabGroup: id) else { return }
        let group = workspaces[path.workspace].tabGroups.remove(at: path.tabGroup)
        let clamped = min(max(index, 0), workspaces[path.workspace].tabGroups.count)
        workspaces[path.workspace].tabGroups.insert(group, at: clamped)
        didChange()
    }

    /// Closes a tab group with all its tabs and sessions. Closing the
    /// workspace's last group marks its window closed (the workspace stays);
    /// otherwise a neighbouring group is selected if this one was.
    @discardableResult
    public func closeTabGroup(_ id: TabGroupID) -> CloseResult {
        guard let path = path(ofTabGroup: id) else { return .notFound }
        let workspaceID = workspaces[path.workspace].id
        let group = workspaces[path.workspace].tabGroups.remove(at: path.tabGroup)
        removeSessions(Set(group.tabs.flatMap(\.panes).map(\.sessionID)))
        defer { didChange() }
        return groupRemoved(id, at: path)
            ?? .closedTabGroup(id, in: workspaceID)
    }

    // MARK: Tabs

    /// Adds a tab to a tab group and selects it. `profile` defaults to
    /// ``defaultProfileID``; `workingDirectory` to ``defaultWorkingDirectory``.
    @discardableResult
    public func newTab(
        in tabGroupID: TabGroupID,
        profile: ProfileID? = nil,
        location: Location = .local,
        workingDirectory: String? = nil
    ) -> TabID? {
        guard path(ofTabGroup: tabGroupID) != nil else { return nil }
        let tab = makeTab(profile: profile ?? defaultProfileID, location: location, workingDirectory: workingDirectory)
        mutateTabGroup(tabGroupID) { group in
            group.tabs.append(tab)
            group.selectedTabID = tab.id
        }
        return tab.id
    }

    /// Renames a tab; `nil` or empty restores the derived title.
    public func renameTab(_ id: TabID, to title: String?) {
        mutateTab(id) { $0.customTitle = (title?.isEmpty ?? true) ? nil : title }
    }

    /// Closes a tab and removes its sessions. If it was the group's last
    /// tab the group is removed; if that was the workspace's last group the
    /// workspace's window is marked closed. See ``CloseResult``.
    @discardableResult
    public func closeTab(_ id: TabID) -> CloseResult {
        guard let path = path(ofTab: id) else { return .notFound }
        let workspaceID = workspaces[path.workspace].id
        let groupID = workspaces[path.workspace].tabGroups[path.tabGroup].id
        let tab = workspaces[path.workspace].tabGroups[path.tabGroup].tabs.remove(at: path.tab)
        removeSessions(Set(tab.panes.map(\.sessionID)))
        defer { didChange() }

        guard workspaces[path.workspace].tabGroups[path.tabGroup].tabs.isEmpty else {
            fixTabSelection(workspace: path.workspace, tabGroup: path.tabGroup, removedIndex: path.tab, removedID: id)
            return .closedTab(id, in: groupID)
        }

        workspaces[path.workspace].tabGroups.remove(at: path.tabGroup)
        return groupRemoved(groupID, at: TabGroupPath(workspace: path.workspace, tabGroup: path.tabGroup))
            ?? .closedTabGroup(groupID, in: workspaceID)
    }

    /// Closes every other tab of `id`'s tab group (and their sessions), and
    /// selects `id`. Returns the tabs closed.
    @discardableResult
    public func closeOtherTabs(than id: TabID) -> [TabID] {
        guard let path = path(ofTab: id) else { return [] }
        let group = workspaces[path.workspace].tabGroups[path.tabGroup]
        let others = group.tabs.filter { $0.id != id }
        guard !others.isEmpty else { return [] }
        removeSessions(Set(others.flatMap(\.panes).map(\.sessionID)))
        workspaces[path.workspace].tabGroups[path.tabGroup].tabs.removeAll { $0.id != id }
        workspaces[path.workspace].tabGroups[path.tabGroup].selectedTabID = id
        didChange()
        return others.map(\.id)
    }

    /// Selects tab number `number` (⌘1…⌘8) of the workspace's selected tab
    /// group; 9 (⌘9) always means the last tab. Returns false if there is no
    /// such tab.
    @discardableResult
    public func selectTab(number: Int, in workspaceID: WorkspaceID) -> Bool {
        guard let tabs = workspace(workspaceID)?.selectedTabGroup?.tabs, !tabs.isEmpty, number >= 1 else { return false }
        let index = number >= 9 ? tabs.count - 1 : number - 1
        guard index < tabs.count else { return false }
        select(tab: tabs[index].id)
        return true
    }

    /// Selects the tab `offset` places after the selected one in the
    /// workspace's selected group (negative: before), wrapping around.
    @discardableResult
    public func selectAdjacentTab(offset: Int, in workspaceID: WorkspaceID) -> Bool {
        guard let group = workspace(workspaceID)?.selectedTabGroup, !group.tabs.isEmpty else { return false }
        let count = group.tabs.count
        let current = group.tabs.firstIndex { $0.id == group.selectedTabID } ?? 0
        let next = ((current + offset) % count + count) % count
        select(tab: group.tabs[next].id)
        return true
    }

    /// Moves a tab to position `index` of `tabGroup`, possibly across groups
    /// and workspaces. `index` counts positions in the destination *after*
    /// the tab has been removed from its source, and is clamped to the valid
    /// range. The moved tab becomes selected in its new group. A source group
    /// left empty by a move is kept (only closing removes groups).
    public func moveTab(_ id: TabID, to tabGroupID: TabGroupID, index: Int) {
        guard let source = path(ofTab: id), path(ofTabGroup: tabGroupID) != nil else { return }
        let tab = workspaces[source.workspace].tabGroups[source.tabGroup].tabs.remove(at: source.tab)
        if workspaces[source.workspace].tabGroups[source.tabGroup].id != tabGroupID {
            fixTabSelection(workspace: source.workspace, tabGroup: source.tabGroup, removedIndex: source.tab, removedID: id)
        }
        // Re-resolve: indices are unchanged by a tab removal, but be explicit.
        guard let target = path(ofTabGroup: tabGroupID) else { return }
        var group = workspaces[target.workspace].tabGroups[target.tabGroup]
        let clamped = min(max(index, 0), group.tabs.count)
        group.tabs.insert(tab, at: clamped)
        group.selectedTabID = id
        workspaces[target.workspace].tabGroups[target.tabGroup] = group
        didChange()
    }

    /// Selects a tab and its tab group.
    public func select(tab id: TabID) {
        guard let path = path(ofTab: id) else { return }
        let groupID = workspaces[path.workspace].tabGroups[path.tabGroup].id
        workspaces[path.workspace].tabGroups[path.tabGroup].selectedTabID = id
        workspaces[path.workspace].selectedTabGroupID = groupID
        didChange()
    }

    // MARK: Panes

    /// Splits `pane`, creating a new pane and session that inherit the
    /// original session's profile, location and working directory. The new
    /// pane is placed after the original and focused. Returns its ID.
    @discardableResult
    public func splitPane(_ paneID: PaneID, axis: Axis) -> PaneID? {
        guard let path = path(ofPane: paneID) else { return nil }
        let tab = workspaces[path.workspace].tabGroups[path.tabGroup].tabs[path.tab]
        guard let original = tab.pane(paneID), let session = session(original.sessionID) else { return nil }

        let newSession = makeSession(
            profile: session.profileID, location: session.location, workingDirectory: session.workingDirectory)
        let newPane = Pane(sessionID: newSession.id)
        sessions.append(newSession)
        mutateTab(tab.id) { tab in
            tab.layout = tab.layout.split(paneID, axis: axis, newPane: newPane.id)
            tab.panes.append(newPane)
            tab.focusedPaneID = newPane.id
            tab.zoomedPaneID = nil
        }
        return newPane.id
    }

    /// Closes a pane and removes its session. Closing the last pane closes
    /// the tab, which may cascade further; see ``CloseResult``. If the pane
    /// was focused, focus moves to the nearest pane of its sibling branch.
    @discardableResult
    public func closePane(_ paneID: PaneID) -> CloseResult {
        guard let path = path(ofPane: paneID) else { return .notFound }
        let tab = workspaces[path.workspace].tabGroups[path.tabGroup].tabs[path.tab]
        guard let remaining = tab.layout.remove(paneID) else {
            return closeTab(tab.id)
        }
        let sessionID = tab.pane(paneID)?.sessionID
        mutateTab(tab.id) { tab in
            if tab.focusedPaneID == paneID {
                tab.focusedPaneID = tab.layout.focusSuccessor(afterRemoving: paneID) ?? remaining.leaves()[0]
            }
            if tab.zoomedPaneID == paneID { tab.zoomedPaneID = nil }
            tab.layout = remaining
            tab.panes.removeAll { $0.id == paneID }
        }
        if let sessionID { removeSessions([sessionID]) }
        return .closedPane(paneID, in: tab.id)
    }

    /// Splits the focused pane of the workspace's selected tab.
    @discardableResult
    public func splitFocusedPane(axis: Axis, in workspaceID: WorkspaceID) -> PaneID? {
        guard let tab = selectedTab(in: workspaceID) else { return nil }
        return splitPane(tab.focusedPaneID, axis: axis)
    }

    /// Moves focus in the workspace's selected tab to the nearest pane in
    /// `direction` (``PaneLayout/neighbor(of:direction:)``). A zoomed tab
    /// is unzoomed first. Returns the newly focused pane, or `nil` if there
    /// is none that way (nothing changes then).
    @discardableResult
    public func moveFocus(_ direction: Direction, in workspaceID: WorkspaceID) -> PaneID? {
        guard let tab = selectedTab(in: workspaceID),
              let target = tab.layout.neighbor(of: tab.focusedPaneID, direction: direction)
        else { return nil }
        mutateTab(tab.id) { tab in
            tab.focusedPaneID = target
            tab.zoomedPaneID = nil
        }
        return target
    }

    /// Moves the divider next to the focused pane of the workspace's
    /// selected tab toward `direction` by `amount` (a fraction of that
    /// split; ``PaneLayout/moveDivider(of:toward:by:)``). Ignored while the
    /// tab is zoomed.
    public func resizeFocusedPane(toward direction: Direction, by amount: Double = 0.05, in workspaceID: WorkspaceID) {
        guard let tab = selectedTab(in: workspaceID), tab.zoomedPaneID == nil else { return }
        let layout = tab.layout.moveDivider(of: tab.focusedPaneID, toward: direction, by: amount)
        guard layout != tab.layout else { return }
        mutateTab(tab.id) { $0.layout = layout }
    }

    /// Resets every split ratio of the workspace's selected tab to 0.5.
    public func equalizePanes(in workspaceID: WorkspaceID) {
        guard let tab = selectedTab(in: workspaceID) else { return }
        let layout = tab.layout.equalized()
        guard layout != tab.layout else { return }
        mutateTab(tab.id) { $0.layout = layout }
    }

    /// Zooms the focused pane of the workspace's selected tab, or unzooms.
    /// A tab with one pane is never zoomed.
    public func toggleZoom(in workspaceID: WorkspaceID) {
        guard let tab = selectedTab(in: workspaceID) else { return }
        guard tab.zoomedPaneID != nil || tab.layout.isSplit else { return }
        mutateTab(tab.id) { tab in
            tab.zoomedPaneID = tab.zoomedPaneID == nil ? tab.focusedPaneID : nil
        }
    }

    /// Records split ratios the user set by dragging dividers. `layout`
    /// must have the tab's current shape (``PaneLayout/hasSameShape(as:)``);
    /// anything else is stale and ignored. Ratios are clamped.
    public func setSplitRatios(_ layout: PaneLayout, for tabID: TabID) {
        guard let path = path(ofTab: tabID) else { return }
        let current = workspaces[path.workspace].tabGroups[path.tabGroup].tabs[path.tab].layout
        guard current.hasSameShape(as: layout) else { return }
        let clamped = layout.clampingRatios()
        guard clamped != current else { return }
        mutateTab(tabID) { $0.layout = clamped }
    }

    /// Focuses a pane and selects its tab and tab group.
    public func focus(pane paneID: PaneID) {
        guard let path = path(ofPane: paneID) else { return }
        let groupID = workspaces[path.workspace].tabGroups[path.tabGroup].id
        let tabID = workspaces[path.workspace].tabGroups[path.tabGroup].tabs[path.tab].id
        workspaces[path.workspace].tabGroups[path.tabGroup].tabs[path.tab].focusedPaneID = paneID
        workspaces[path.workspace].tabGroups[path.tabGroup].selectedTabID = tabID
        workspaces[path.workspace].selectedTabGroupID = groupID
        didChange()
    }

    // MARK: Sessions

    /// Records the program-set title of a session (OSC 0/2).
    public func setTitle(_ title: String, for id: SessionID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].title != title else { return }
        sessions[index].title = title
        didChange()
    }

    /// Records a session's working directory as reported by its program
    /// (OSC 7), so a respawn or split starts there.
    public func setWorkingDirectory(_ path: String, for id: SessionID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].workingDirectory != path
        else { return }
        sessions[index].workingDirectory = path
        didChange()
    }

    /// Records the session runtime version that created a session's daemon
    /// (`Session.runtimeVersion`).
    public func setRuntimeVersion(_ version: String?, for id: SessionID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].runtimeVersion != version
        else { return }
        sessions[index].runtimeVersion = version
        didChange()
    }

    /// Every session shown in `workspace`'s panes, in tab order.
    public func sessionIDs(in workspace: WorkspaceID) -> [SessionID] {
        guard let workspace = self.workspace(workspace) else { return [] }
        return workspace.tabGroups.flatMap { $0.tabs.flatMap { $0.panes.map(\.sessionID) } }
    }

    /// Replaces session `old` with `new` (a respawn): every pane bound to
    /// `old` is rebound to `new`, and `old` is retired. Does nothing if `old`
    /// is unknown or `new`'s ID is already in use.
    public func replaceSession(_ old: SessionID, with new: Session) {
        guard let index = sessions.firstIndex(where: { $0.id == old }),
              !sessions.contains(where: { $0.id == new.id })
        else { return }
        sessions[index] = new
        for w in workspaces.indices {
            for g in workspaces[w].tabGroups.indices {
                for t in workspaces[w].tabGroups[g].tabs.indices {
                    for p in workspaces[w].tabGroups[g].tabs[t].panes.indices
                    where workspaces[w].tabGroups[g].tabs[t].panes[p].sessionID == old {
                        workspaces[w].tabGroups[g].tabs[t].panes[p].sessionID = new.id
                    }
                }
            }
        }
        didChange()
    }

    // MARK: Profiles

    /// Adds a new profile (a login shell named "New Profile", made unique)
    /// at the end of the list and returns its ID.
    @discardableResult
    public func newProfile() -> ProfileID {
        let profile = Profile(name: uniqueProfileName("New Profile"), kind: .shell, icon: "terminal")
        profiles.append(profile)
        didChange()
        return profile.id
    }

    /// Adds a copy of a profile (built-in or not) right after it, named
    /// "<name> Copy", with a new ID. The copy is never built-in, so all of
    /// it can be edited. Returns `nil` if `id` is unknown.
    @discardableResult
    public func duplicateProfile(_ id: ProfileID) -> ProfileID? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        let source = profiles[index]
        let copy = Profile(
            name: uniqueProfileName("\(source.name) Copy"), kind: source.kind, program: source.program,
            arguments: source.arguments, environment: source.environment, icon: source.icon)
        profiles.insert(copy, at: index + 1)
        didChange()
        return copy.id
    }

    /// Replaces the stored profile with the same ID by `profile`, cleaned up:
    /// a blank name becomes "Untitled", a blank icon "terminal", a blank
    /// program `nil` (the login shell), and environment entries whose names
    /// are not allowed (``Profile/environmentNameProblem(_:)``: empty,
    /// containing `=`, reserved) are dropped. For a built-in profile only the name and icon are
    /// taken; its kind, program, arguments and environment stay as shipped.
    /// Sessions already created keep their launch until they are respawned.
    public func updateProfile(_ profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profiles[index]
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let icon = profile.icon.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.name = name.isEmpty ? "Untitled" : name
        updated.icon = icon.isEmpty ? "terminal" : icon
        if !updated.isBuiltIn {
            updated.kind = profile.kind
            let program = profile.program?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            updated.program = program.isEmpty ? nil : program
            updated.arguments = profile.arguments
            var environment: [String: String] = [:]
            for (key, value) in profile.environment {
                let name = key.trimmingCharacters(in: .whitespaces)
                if Profile.environmentNameProblem(name) == nil { environment[name] = value }
            }
            updated.environment = environment
        }
        guard updated != profiles[index] else { return }
        profiles[index] = updated
        didChange()
    }

    /// Deletes a profile. Built-in profiles cannot be deleted (returns
    /// false). Sessions created from it keep running and keep their launch;
    /// a respawn then reuses that launch. If it was ``defaultProfileID``,
    /// the default goes back to the shell.
    @discardableResult
    public func deleteProfile(_ id: ProfileID) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }), !profiles[index].isBuiltIn else { return false }
        profiles.remove(at: index)
        if defaultProfileID == id { defaultProfileID = Profile.shell.id }
        didChange()
        return true
    }

    /// The launch a respawn of `session` uses: its profile as it is now,
    /// or, if the profile was deleted, the launch the session was created
    /// with.
    public func launchForRespawn(of session: Session) -> LaunchSpec {
        profile(session.profileID)?.launchSpec ?? session.launch
    }

    // MARK: Hosts

    public func host(_ id: HostID) -> Host? {
        hosts.first { $0.id == id }
    }

    /// Adds a host at the end of the list and returns its ID. A blank name
    /// becomes "New Host" (made unique); the rest is cleaned up as
    /// ``updateHost(_:)`` does.
    @discardableResult
    public func addHost(
        name: String = "",
        sshDestination: String = "",
        port: Int? = nil,
        identityFile: String? = nil,
        sshConfigFile: String? = nil,
        remoteDirectory: String = Host.defaultRemoteDirectory
    ) -> HostID {
        var host = Self.cleaned(Host(
            name: name, sshDestination: sshDestination, port: port, identityFile: identityFile,
            sshConfigFile: sshConfigFile, remoteDirectory: remoteDirectory))
        if host.name.isEmpty { host.name = uniqueHostName("New Host") }
        hosts.append(host)
        didChange()
        return host.id
    }

    /// Replaces the stored host with the same ID by `host`, cleaned up:
    /// surrounding whitespace is trimmed everywhere; a port outside
    /// 1…65535 becomes `nil` (ssh's default); a blank identity or config
    /// file `nil`; a blank or unusable remote directory
    /// (``Host/remoteDirectoryProblem(_:)``) the default, and trailing
    /// slashes are dropped. Sessions on the host keep running; they use the
    /// new settings from their next connection.
    public func updateHost(_ host: Host) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        let updated = Self.cleaned(host)
        guard updated != hosts[index] else { return }
        hosts[index] = updated
        didChange()
    }

    /// Removes a host. Sessions on it stay in their panes and are left
    /// running there: they become unreachable (the app shows them as
    /// unavailable), never killed. Returns those sessions.
    @discardableResult
    public func removeHost(_ id: HostID) -> [SessionID] {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return [] }
        let left = sessionIDs(onHost: id)
        hosts.remove(at: index)
        didChange()
        return left
    }

    /// Sessions whose location is `host`, whether the host still exists or not.
    public func sessionIDs(onHost host: HostID) -> [SessionID] {
        sessions.filter { $0.location == .remote(host: host) }.map(\.id)
    }

    /// File › New Tab on Host: a tab in `tabGroupID` whose session runs on
    /// `host`, in the home directory there, with `profile` (else the
    /// default profile). `nil` if the group or host is unknown.
    @discardableResult
    public func newTab(in tabGroupID: TabGroupID, onHost host: HostID, profile: ProfileID? = nil) -> TabID? {
        guard self.host(host) != nil else { return nil }
        return newTab(in: tabGroupID, profile: profile, location: .remote(host: host), workingDirectory: "~")
    }

    private static func cleaned(_ host: Host) -> Host {
        var host = host
        host.name = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        host.sshDestination = host.sshDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        if let port = host.port, !(1...65535).contains(port) { host.port = nil }
        func optionalPath(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        host.identityFile = optionalPath(host.identityFile)
        host.sshConfigFile = optionalPath(host.sshConfigFile)
        var directory = host.remoteDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        while directory.count > 1, directory.hasSuffix("/") { directory.removeLast() }
        if directory.isEmpty || Host.remoteDirectoryProblem(directory) != nil {
            directory = Host.defaultRemoteDirectory
        }
        host.remoteDirectory = directory
        return host
    }

    private func uniqueHostName(_ base: String) -> String {
        let names = Set(hosts.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func uniqueProfileName(_ base: String) -> String {
        let names = Set(profiles.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Internals

    private struct TabGroupPath { var workspace: Int; var tabGroup: Int }
    private struct TabPath { var workspace: Int; var tabGroup: Int; var tab: Int }

    private func didChange() {
        changeCount &+= 1
    }

    private func path(ofTabGroup id: TabGroupID) -> TabGroupPath? {
        for (w, workspace) in workspaces.enumerated() {
            if let g = workspace.tabGroups.firstIndex(where: { $0.id == id }) {
                return TabGroupPath(workspace: w, tabGroup: g)
            }
        }
        return nil
    }

    private func path(ofTab id: TabID) -> TabPath? {
        for (w, workspace) in workspaces.enumerated() {
            for (g, group) in workspace.tabGroups.enumerated() {
                if let t = group.tabs.firstIndex(where: { $0.id == id }) {
                    return TabPath(workspace: w, tabGroup: g, tab: t)
                }
            }
        }
        return nil
    }

    private func path(ofPane id: PaneID) -> TabPath? {
        for (w, workspace) in workspaces.enumerated() {
            for (g, group) in workspace.tabGroups.enumerated() {
                if let t = group.tabs.firstIndex(where: { $0.layout.contains(id) }) {
                    return TabPath(workspace: w, tabGroup: g, tab: t)
                }
            }
        }
        return nil
    }

    private func mutateWorkspace(_ id: WorkspaceID, _ body: (inout Workspace) -> Void) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        body(&workspaces[index])
        didChange()
    }

    private func mutateTabGroup(_ id: TabGroupID, _ body: (inout TabGroup) -> Void) {
        guard let path = path(ofTabGroup: id) else { return }
        body(&workspaces[path.workspace].tabGroups[path.tabGroup])
        didChange()
    }

    private func mutateTab(_ id: TabID, _ body: (inout Tab) -> Void) {
        guard let path = path(ofTab: id) else { return }
        body(&workspaces[path.workspace].tabGroups[path.tabGroup].tabs[path.tab])
        didChange()
    }

    /// Bookkeeping after the group `id` at `path` has been removed from its
    /// workspace: marks the window closed if no group is left (and returns
    /// `.closedWindow`), else moves the selection off the removed group and
    /// returns `nil`.
    private func groupRemoved(_ id: TabGroupID, at path: TabGroupPath) -> CloseResult? {
        let groups = workspaces[path.workspace].tabGroups
        guard !groups.isEmpty else {
            workspaces[path.workspace].selectedTabGroupID = nil
            var window = workspaces[path.workspace].window ?? WindowState()
            window.isOpen = false
            workspaces[path.workspace].window = window
            return .closedWindow(workspaces[path.workspace].id)
        }
        if workspaces[path.workspace].selectedTabGroupID == id {
            workspaces[path.workspace].selectedTabGroupID = groups[min(path.tabGroup, groups.count - 1)].id
        }
        return nil
    }

    private func fixTabSelection(workspace w: Int, tabGroup g: Int, removedIndex: Int, removedID: TabID) {
        let group = workspaces[w].tabGroups[g]
        guard group.selectedTabID == removedID || group.selectedTabID == nil else { return }
        if group.tabs.isEmpty {
            workspaces[w].tabGroups[g].selectedTabID = nil
        } else {
            workspaces[w].tabGroups[g].selectedTabID = group.tabs[min(removedIndex, group.tabs.count - 1)].id
        }
    }

    private func removeSessions(_ ids: Set<SessionID>) {
        sessions.removeAll { ids.contains($0.id) }
    }

    private func makeSession(profile profileID: ProfileID, location: Location, workingDirectory: String?) -> Session {
        let resolved = self.profile(profileID) ?? Profile.shell
        return Session(
            location: location,
            profileID: resolved.id,
            launch: resolved.launchSpec,
            workingDirectory: workingDirectory ?? defaultWorkingDirectory)
    }

    /// Creates a one-pane tab and registers its session.
    private func makeTab(profile: ProfileID, location: Location, workingDirectory: String?) -> Tab {
        let session = makeSession(profile: profile, location: location, workingDirectory: workingDirectory)
        sessions.append(session)
        return Tab(pane: Pane(sessionID: session.id))
    }

    private func nextWorkspaceName() -> String {
        let names = Set(workspaces.map(\.name))
        if !names.contains("Workspace") { return "Workspace" }
        var n = 2
        while names.contains("Workspace \(n)") { n += 1 }
        return "Workspace \(n)"
    }
}
