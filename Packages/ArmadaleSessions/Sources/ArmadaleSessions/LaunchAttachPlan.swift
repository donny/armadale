import ArmadaleCore

/// What the launch does with a restored session whose pane is not on
/// screen, once its location's first listing has answered (docs/DESIGN.md
/// section 4, "Restore at launch"). Pure, so it is testable without the app.
public enum LaunchDisposition: Sendable, Hashable {
    /// Attach at the session's own last size, which its program already has.
    case attach(SessionGridSize)
    /// The session is gone: show it as ended (its recorded exit status
    /// decides whether its pane closes).
    case markEnded
    /// Leave it unattached until its pane is first shown: no size is known
    /// (saved by an older build), so attaching now would resize its program
    /// on a guess (owner's decision, November 14, 2026).
    case leave
}

/// Whether a restored session is alive, as its location's first listing
/// says.
public enum LaunchLiveness: Sendable, Hashable {
    /// Listed, or (locally) with a socket in the runtime directory: the
    /// helper's listing leaves out a daemon that does not answer within
    /// about a second and still succeeds.
    case alive
    /// The listing answered without it.
    case gone
    /// The listing failed (a host that cannot be reached, a local listing
    /// that failed): nothing is known, so it is never ended.
    case unknown
}

public enum LaunchAttachPlan {
    /// The most of one host's sessions the launch keeps attached (or
    /// attaching, or retrying) for panes nobody has shown. Every client of
    /// a host shares one ssh connection, each attached session holds one of
    /// its sessions, and sshd allows 10 per connection by default
    /// (`MaxSessions`); past it, by reading, control commands on that
    /// connection are refused too (a close's kill, listings, the user's own
    /// new panes). Six leaves room for those. Unverified on a host
    /// (coordinator's decision of November 14, 2026; the owner may change
    /// it once checked). Panes the user shows always start.
    public static let maximumHiddenAttachedPerHost = 6

    /// - `alive` and a saved size: attach at that size.
    /// - `alive` without one: leave it until shown.
    /// - `gone`: show it as ended.
    /// - `unknown` (an unreachable host, a failed local listing): attach
    ///   with a saved size, which an unreachable host turns into
    ///   Disconnected on the usual retry schedule, never Session Ended;
    ///   without one, leave it.
    public static func disposition(_ liveness: LaunchLiveness, savedSize: SessionGridSize?) -> LaunchDisposition {
        switch liveness {
        case .gone: return .markEnded
        case .alive, .unknown:
            guard let savedSize, savedSize.isPlausible else { return .leave }
            return .attach(savedSize)
        }
    }

    /// The local liveness of a restored session: `listed` is the helper's
    /// listing (`nil` if it failed), `sockets` the sessions whose socket
    /// exists in the runtime directory (read after the listing, which
    /// removes the stale socket of a killed daemon).
    public static func localLiveness(of id: SessionID, listed: Set<SessionID>?, sockets: Set<SessionID>) -> LaunchLiveness {
        if sockets.contains(id) { return .alive }
        guard let listed else { return .unknown }
        return listed.contains(id) ? .alive : .gone
    }
}

/// The launch attaches still to make, a few at a time per location
/// (docs/DESIGN.md section 4, "Restore at launch"). Pure bookkeeping: the
/// app asks ``take()`` what to start, reports each start's end with
/// ``finished(_:outcome:)``, and ``started(_:in:)`` for attaches it made
/// itself (a pane shown at launch, or one that jumped the queue), which
/// count against the same limit.
///
/// Why pacing: a local attach waits about 2 s for its client's first
/// bytes and a miss ends Disconnected, and local sessions have no retry
/// schedule, so thirty at once on a busy Mac could leave tabs nobody is
/// looking at disconnected until clicked. A local launch attach that ends
/// Disconnected although its session exists gets one more try once the
/// local queue has drained (``Outcome/disconnected``).
public struct LaunchAttachQueue: Sendable, Equatable {
    /// Where an attach goes: this Mac or one host. Each has its own limit.
    public enum Lane: Sendable, Hashable {
        case local
        case host(HostID)
    }

    /// What to start: a first attach, or the one retry of a local attach
    /// that ended Disconnected.
    public enum Kind: Sendable, Hashable {
        case attach
        case retry
    }

    public struct Item: Sendable, Hashable {
        public var id: SessionID
        public var lane: Lane
        public var kind: Kind

        public init(id: SessionID, lane: Lane, kind: Kind = .attach) {
            self.id = id
            self.lane = lane
            self.kind = kind
        }
    }

    /// How a start ended.
    public enum Outcome: Sendable, Hashable {
        /// Attached, ended, unavailable, or anything that needs no retry.
        case done
        /// Disconnected although the session exists (a missed first-bytes
        /// window): retried once after the queue has drained, locally.
        case disconnected
    }

    /// At most this many local attaches in flight (starting points,
    /// measured: docs/HISTORY.md, section 4).
    public var localLimit: Int
    /// At most this many attaches in flight per host.
    public var hostLimit: Int

    public private(set) var queued: [Item] = []
    public private(set) var inFlight: [SessionID: Lane] = [:]
    /// Local sessions owed their one retry, in the order they missed.
    public private(set) var retries: [SessionID] = []
    /// Sessions that have had their retry (never a second one).
    public private(set) var retried: Set<SessionID> = []

    public static let defaultLocalLimit = 4
    public static let defaultHostLimit = 2

    public init(localLimit: Int = Self.defaultLocalLimit, hostLimit: Int = Self.defaultHostLimit) {
        self.localLimit = max(1, localLimit)
        self.hostLimit = max(1, hostLimit)
    }

    public func limit(of lane: Lane) -> Int {
        switch lane {
        case .local: localLimit
        case .host: hostLimit
        }
    }

    public func inFlightCount(in lane: Lane) -> Int {
        inFlight.values.count { $0 == lane }
    }

    public func isQueued(_ id: SessionID) -> Bool {
        queued.contains { $0.id == id }
    }

    /// Adds `items` in their order (the sidebar's), skipping any already
    /// queued or in flight.
    public mutating func enqueue(_ items: [Item]) {
        for item in items where !isQueued(item.id) && inFlight[item.id] == nil {
            queued.append(item)
        }
    }

    /// Removes a queued session (its pane was shown and it jumped the
    /// queue, or it was closed) and any retry it is owed. Returns whether
    /// it was queued.
    @discardableResult
    public mutating func remove(_ id: SessionID) -> Bool {
        let before = queued.count
        queued.removeAll { $0.id == id }
        retries.removeAll { $0 == id }
        return queued.count != before
    }

    /// An attach the app started itself, outside the queue: it counts
    /// against its lane's limit until ``finished(_:outcome:)``.
    public mutating func started(_ id: SessionID, in lane: Lane) {
        remove(id)
        inFlight[id] = lane
    }

    /// The items to start now, in queue order, as far as each lane's limit
    /// allows; they count as in flight until ``finished(_:outcome:)``. A
    /// lane whose queue and flights are empty gets its owed retries queued
    /// first.
    public mutating func take() -> [Item] {
        promoteRetries()
        var taken: [Item] = []
        var remaining: [Item] = []
        var counts: [Lane: Int] = [:]
        for lane in Set(inFlight.values) { counts[lane] = inFlightCount(in: lane) }
        for item in queued {
            if counts[item.lane, default: 0] < limit(of: item.lane) {
                counts[item.lane, default: 0] += 1
                inFlight[item.id] = item.lane
                taken.append(item)
            } else {
                remaining.append(item)
            }
        }
        queued = remaining
        return taken
    }

    /// A start has ended. A local first attach that ended Disconnected is
    /// owed one retry, made once nothing else of the local lane is queued
    /// or in flight.
    public mutating func finished(_ id: SessionID, outcome: Outcome) {
        guard let lane = inFlight.removeValue(forKey: id) else { return }
        if outcome == .disconnected, lane == .local, !retried.contains(id), !retries.contains(id) {
            retries.append(id)
        }
    }

    /// Whether nothing is queued, in flight or owed.
    public var isIdle: Bool {
        queued.isEmpty && inFlight.isEmpty && retries.isEmpty
    }

    private mutating func promoteRetries() {
        guard !retries.isEmpty, !queued.contains(where: { $0.lane == .local }), inFlightCount(in: .local) == 0 else {
            return
        }
        for id in retries {
            retried.insert(id)
            queued.append(Item(id: id, lane: .local, kind: .retry))
        }
        retries = []
    }
}
