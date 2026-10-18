import Foundation

/// Where the user's attention is, as far as attention is concerned: whether
/// Armadale is the active app, and which session is in the focused pane of
/// the selected tab of the key window's workspace (`nil` when no workspace
/// window is key, e.g. Settings is, or no window is open).
///
/// A session is *looked at* exactly when the app is active **and** it is
/// ``focusedSessionID``. Everything else (another pane of the same tab,
/// another tab, another window, a window that is not key, the app in the
/// background) is not looked at.
public struct AttentionFocus: Sendable, Hashable {
    public var isAppActive: Bool
    public var focusedSessionID: SessionID?

    public init(isAppActive: Bool, focusedSessionID: SessionID?) {
        self.isAppActive = isAppActive
        self.focusedSessionID = focusedSessionID
    }

    /// Nothing is looked at.
    public static let nobody = AttentionFocus(isAppActive: false, focusedSessionID: nil)

    /// The session the user is looking at right now, if any.
    public var lookedAtSessionID: SessionID? {
        isAppActive ? focusedSessionID : nil
    }

    /// Whether `session` is being looked at.
    public func isLookingAt(_ session: SessionID) -> Bool {
        lookedAtSessionID == session
    }
}

/// What a program did to ask for attention. Title changes (OSC 0/2) are not
/// signals: agents retitle their terminal constantly.
public enum AttentionSignal: Sendable, Hashable {
    /// BEL.
    case bell
    /// OSC 9 (`title` empty) or OSC 777 `notify` (title and body).
    case notification(title: String, body: String)
}

/// Which sessions need attention (DESIGN §10): a bell or a desktop
/// notification sequence from a session nobody is looking at sets it; the
/// session being looked at clears it. Pure and in memory: attention is not
/// persisted, but it survives tab switches and closing and reopening a
/// window, because it lives with the app, not with a view.
public struct AttentionTracker: Sendable, Hashable {
    /// Sessions needing attention, with the order in which they first asked.
    private var raised: [SessionID: Int] = [:]
    private var sequence = 0

    public init() {}

    /// Records `signal` from `session`. Returns whether the session now
    /// needs attention because of it: false when the session is being
    /// looked at (nothing happens then), true otherwise (also when it
    /// already needed attention; it keeps its place in the order).
    @discardableResult
    public mutating func record(_ signal: AttentionSignal, from session: SessionID, focus: AttentionFocus) -> Bool {
        guard !focus.isLookingAt(session) else { return false }
        if raised[session] == nil {
            sequence += 1
            raised[session] = sequence
        }
        return true
    }

    /// The focus changed (or may have): the session now looked at, if any,
    /// no longer needs attention. Returns the session cleared, if one was.
    @discardableResult
    public mutating func focusChanged(to focus: AttentionFocus) -> SessionID? {
        guard let session = focus.lookedAtSessionID, raised.removeValue(forKey: session) != nil else { return nil }
        return session
    }

    /// Clears one session.
    public mutating func clear(_ session: SessionID) {
        raised[session] = nil
    }

    /// Window › Clear All Attention.
    public mutating func clearAll() {
        raised.removeAll()
    }

    /// Forgets sessions that no longer exist (closed, retired by a respawn).
    public mutating func retain(only sessions: Set<SessionID>) {
        raised = raised.filter { sessions.contains($0.key) }
    }

    public func needsAttention(_ session: SessionID) -> Bool {
        raised[session] != nil
    }

    /// Sessions needing attention, in the order they first asked.
    public var sessions: [SessionID] {
        raised.sorted { $0.value < $1.value }.map(\.key)
    }

    /// How many sessions need attention in all (the Dock badge).
    public var total: Int { raised.count }

    /// How many of `sessions` need attention (a tab, a tab group, a workspace).
    public func count(in sessions: some Sequence<SessionID>) -> Int {
        Set(sessions).reduce(0) { $0 + (raised[$1] == nil ? 0 : 1) }
    }

    /// Window › Next Pane Needing Attention: the first session needing
    /// attention after `current` in `order` (every pane's session, in
    /// sidebar order: workspaces, tab groups, tabs, panes), wrapping
    /// around; `current` itself only if it is the only one. `nil` when none
    /// does. Sessions not in `order` are skipped.
    public func next(after current: SessionID?, in order: [SessionID]) -> SessionID? {
        guard !raised.isEmpty else { return nil }
        let start = current.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        for offset in 0..<order.count {
            let candidate = order[(start + offset) % order.count]
            if raised[candidate] != nil { return candidate }
        }
        return nil
    }
}

/// The Dock icon's badge: the number of sessions needing attention, or none.
public enum AttentionBadge {
    public static func label(total: Int) -> String? {
        total > 0 ? String(total) : nil
    }
}

/// Where a session is shown: what clicking its notification, or Next Pane
/// Needing Attention, brings forward and focuses.
public struct SessionPlace: Sendable, Hashable {
    public var workspace: WorkspaceID
    public var tabGroup: TabGroupID
    public var tab: TabID
    public var pane: PaneID

    public init(workspace: WorkspaceID, tabGroup: TabGroupID, tab: TabID, pane: PaneID) {
        self.workspace = workspace
        self.tabGroup = tabGroup
        self.tab = tab
        self.pane = pane
    }
}
