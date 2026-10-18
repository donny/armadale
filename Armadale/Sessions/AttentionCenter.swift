import AppKit
import ArmadaleCore
import Observation

/// One desktop notification about a session needing attention.
struct AttentionNotification: Sendable, Hashable {
    var sessionID: SessionID
    /// The OSC 777 title if the program gave one, else the session's
    /// title, else its profile's name.
    var title: String
    /// "Workspace / Tab group".
    var subtitle: String
    /// The notification's text, or "Finished" (a bell, or no text).
    var body: String
    var playsSound: Bool

    /// The `userInfo` key that carries the session, so a click can find it.
    static let sessionIDKey = "armadale.sessionID"

    var userInfo: [String: String] { [Self.sessionIDKey: sessionID.raw] }

    /// The session a clicked notification is about, from its `userInfo`.
    static func sessionID(fromUserInfo userInfo: [AnyHashable: Any]) -> SessionID? {
        guard let raw = userInfo[sessionIDKey] as? String, !raw.isEmpty else { return nil }
        return SessionID(raw: raw)
    }

    /// The notification for `signal` from `session`, as it is in `model`.
    @MainActor
    static func make(for signal: AttentionSignal, from session: Session, in model: AppModel, playsSound: Bool) -> AttentionNotification {
        let profileName = model.profile(session.profileID)?.name ?? "Shell"
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var subtitle = ""
        if let place = model.place(of: session.id) {
            let workspace = model.workspace(place.workspace)?.name ?? ""
            let group = model.tabGroup(place.tabGroup)?.name ?? ""
            subtitle = [workspace, group].filter { !$0.isEmpty }.joined(separator: " / ")
        }
        var heading = title.isEmpty ? profileName : title
        var body = "Finished"
        if case .notification(let oscTitle, let oscBody) = signal {
            let givenTitle = oscTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = oscBody.trimmingCharacters(in: .whitespacesAndNewlines)
            if !givenTitle.isEmpty { heading = givenTitle }
            if !text.isEmpty { body = text }
        }
        return AttentionNotification(
            sessionID: session.id, title: heading, subtitle: subtitle, body: body, playsSound: playsSound)
    }
}

/// Posts desktop notifications. The app's is ``UserNotificationService``
/// (UserNotifications, asking for permission the first time it posts);
/// tests use a fake.
@MainActor
protocol NotificationService: AnyObject {
    func post(_ notification: AttentionNotification)
    /// Asks for permission (alerts, sounds, badges) if it has not been
    /// decided yet; called the first time a session needs attention, so
    /// the Dock badge works even when nothing is posted.
    func requestAuthorization()
    /// Removes the delivered notifications of sessions whose attention
    /// cleared.
    func withdraw(_ sessions: Set<SessionID>)
}

/// Which attention signals become desktop notifications: the preferences
/// ("Notify when an unfocused pane needs attention", "Only for agent
/// profiles"), and at most one per session every ``interval``. Pure apart
/// from the clock it is given.
struct NotificationPolicy {
    var interval: Duration = .seconds(2)
    private var lastPosted: [SessionID: ContinuousClock.Instant] = [:]

    init(interval: Duration = .seconds(2)) {
        self.interval = interval
    }

    /// Whether to post for a signal from `session` (which runs an agent
    /// profile if `isAgent`) at `now`; records the post if so.
    mutating func shouldPost(
        for session: SessionID, isAgent: Bool, enabled: Bool, agentsOnly: Bool, now: ContinuousClock.Instant
    ) -> Bool {
        guard enabled, isAgent || !agentsOnly else { return false }
        if let last = lastPosted[session], now - last < interval { return false }
        lastPosted[session] = now
        return true
    }

    mutating func forget(sessionsNotIn sessions: Set<SessionID>) {
        lastPosted = lastPosted.filter { sessions.contains($0.key) }
    }
}

/// The app's attention state (DESIGN §10): which sessions rang the bell or
/// posted a notification while nobody was looking (``AttentionTracker``),
/// what the user is looking at (``focus``), the Dock badge, desktop
/// notifications, and bringing a session forward (a notification click,
/// Window › Next Pane Needing Attention).
///
/// ``isAppActive`` and ``keyWorkspaceID`` are set by the app delegate from
/// AppKit's notifications (tests set them directly). Attention lives here,
/// in memory, for the app's lifetime: it survives tab switches and closing
/// and reopening windows, and is not saved.
@MainActor
@Observable
final class AttentionCenter {
    private(set) var tracker = AttentionTracker()
    /// Armadale is the active app.
    var isAppActive = false {
        didSet { if isAppActive != oldValue { refreshFocus() } }
    }
    /// The workspace whose window is key, if a workspace window is.
    var keyWorkspaceID: WorkspaceID? {
        didSet { if keyWorkspaceID != oldValue { refreshFocus() } }
    }

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let notifications: (any NotificationService)?
    @ObservationIgnored private var policy = NotificationPolicy()
    @ObservationIgnored var now: () -> ContinuousClock.Instant = { .now }
    /// Called with the Dock badge's label whenever the total changes.
    @ObservationIgnored var onBadgeChange: (String?) -> Void = { _ in }
    /// Brings a workspace's window forward (opening it if it is closed).
    @ObservationIgnored var showWorkspace: (WorkspaceID) -> Void = { _ in }
    @ObservationIgnored private var focusTask: Task<Void, Never>?
    /// Permission has been asked for in this run (``signal(_:from:)``).
    @ObservationIgnored private var hasRequestedAuthorization = false

    /// Takes ``AppModel/onSessionsRemoved``: sessions leaving the model are
    /// forgotten inside the intent that removed them, so no count or badge
    /// can outlive its session.
    init(model: AppModel, preferences: Preferences, notifications: (any NotificationService)?) {
        self.model = model
        self.preferences = preferences
        self.notifications = notifications
        model.onSessionsRemoved = { [weak self] ids in self?.forget(ids) }
        observe()
    }

    isolated deinit {
        focusTask?.cancel()
    }

    /// What the user is looking at now.
    var focus: AttentionFocus {
        AttentionFocus(isAppActive: isAppActive, focusedSessionID: keyWorkspaceID.flatMap { model.focusedSessionID(in: $0) })
    }

    // MARK: Signals

    /// A session's program rang the bell or posted a notification.
    /// Signals from sessions the model no longer has are ignored.
    func signal(_ signal: AttentionSignal, from session: SessionID) {
        guard model.session(session) != nil else { return }
        let before = tracker.total
        guard tracker.record(signal, from: session, focus: focus) else { return }
        if tracker.total != before {
            onBadgeChange(AttentionBadge.label(total: tracker.total))
            if !hasRequestedAuthorization {
                hasRequestedAuthorization = true
                notifications?.requestAuthorization()
            }
        }
        notify(signal, from: session)
    }

    private func notify(_ signal: AttentionSignal, from sessionID: SessionID) {
        guard let notifications, let session = model.session(sessionID) else { return }
        let isAgent = model.profile(session.profileID)?.isAgent ?? false
        guard policy.shouldPost(
            for: sessionID, isAgent: isAgent, enabled: preferences.notifyOnAttention,
            agentsOnly: preferences.notifyOnlyForAgents, now: now())
        else { return }
        notifications.post(AttentionNotification.make(
            for: signal, from: session, in: model, playsSound: preferences.notificationPlaysSound))
    }

    // MARK: Reading

    func needsAttention(_ session: SessionID) -> Bool { tracker.needsAttention(session) }
    func count(in sessions: some Sequence<SessionID>) -> Int { tracker.count(in: sessions) }
    var total: Int { tracker.total }

    // MARK: Clearing

    /// The focus may have changed: the session now looked at is cleared.
    func refreshFocus() {
        guard let cleared = tracker.focusChanged(to: focus) else { return }
        onBadgeChange(AttentionBadge.label(total: tracker.total))
        notifications?.withdraw([cleared])
    }

    /// Window › Clear All Attention.
    func clearAll() {
        guard tracker.total > 0 else { return }
        let cleared = Set(tracker.sessions)
        tracker.clearAll()
        onBadgeChange(nil)
        notifications?.withdraw(cleared)
    }

    /// Sessions that left the model (``AppModel/onSessionsRemoved``).
    func forget(_ sessions: Set<SessionID>) {
        policy.forget(sessionsNotIn: Set(model.sessions.map(\.id)))
        let gone = sessions.filter { tracker.needsAttention($0) }
        guard !gone.isEmpty else { return }
        for id in gone { tracker.clear(id) }
        onBadgeChange(AttentionBadge.label(total: tracker.total))
        notifications?.withdraw(gone)
    }

    /// Whether a notification about `session` should still be shown as a
    /// banner: not if the user is looking at the session by now.
    func shouldPresent(_ session: SessionID?) -> Bool {
        guard let session else { return true }
        return !focus.isLookingAt(session)
    }

    // MARK: Bringing a session forward

    /// Selects the session's tab group and tab, focuses its pane, and
    /// brings its window forward; being looked at then clears its
    /// attention. Returns false (and does nothing) if no pane shows it any
    /// more.
    @discardableResult
    func reveal(_ session: SessionID) -> Bool {
        guard let place = model.place(of: session) else { return false }
        model.focus(pane: place.pane)
        showWorkspace(place.workspace)
        refreshFocus()
        return true
    }

    /// The next session needing attention after the one in the key
    /// window's focused pane, in sidebar order, across every window.
    var nextSession: SessionID? {
        tracker.next(after: keyWorkspaceID.flatMap { model.focusedSessionID(in: $0) }, in: model.sessionOrder)
    }

    /// Window › Next Pane Needing Attention. Returns false if none does.
    @discardableResult
    func revealNext() -> Bool {
        guard let next = nextSession else { return false }
        return reveal(next)
    }

    // MARK: Following the model

    private func observe() {
        // Selection and focus changes in the model (a click into a pane, a
        // tab switch) clear the session that is now looked at.
        focusTask = Task { [weak self] in
            for await _ in Observations({ [weak self] in self?.focus }) {
                guard let self else { return }
                self.refreshFocus()
            }
        }
    }
}
