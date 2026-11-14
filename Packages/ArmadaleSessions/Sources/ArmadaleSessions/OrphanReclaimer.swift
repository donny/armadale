import ArmadaleCore

/// Ends sessions in Armadale's private runtime that no saved session refers
/// to any more: for example one whose pane was closed while the runtime was
/// unavailable (it could not be killed then). Every session in that runtime
/// was created by Armadale (its directory is private to the app, and only
/// `a-<id>` names are listed), so this never touches anything else.
///
/// It never ends a session it cannot account for (DESIGN §4,
/// "Housekeeping"): after a launch whose saved sessions were not known to
/// be complete, the unreferenced sessions are recorded as spared
/// (``PersistedState/sparedSessionIDs``) instead. The list means "sessions
/// the reclaim must never end, running or not": it never shrinks by itself,
/// so a spared session one listing missed is not ended when a later
/// listing shows it again.
public enum OrphanReclaimer {
    /// The live sessions no saved session refers to.
    public static func orphans(live: Set<SessionID>, referenced: Set<SessionID>) -> Set<SessionID> {
        live.subtracting(referenced)
    }

    /// What the launch housekeeping does with the live sessions: a pure
    /// decision from the probe's answer and the model.
    public struct Plan: Equatable, Sendable {
        /// Sessions to end.
        public var toEnd: Set<SessionID>
        /// The spared list to record afterwards.
        public var spared: Set<SessionID>

        /// - Parameters:
        ///   - live: the sessions the runtime lists.
        ///   - referenced: the sessions in the model.
        ///   - spared: the spared list loaded with the state.
        ///   - present: sessions whose socket exists in the runtime
        ///     directory, listed or not (a stopped daemon is left out of a
        ///     listing that still succeeds); the plan uses it only when held
        ///     back (``reclaim(live:present:model:mayReclaim:backend:)`` also
        ///     counts them as running).
        ///   - mayReclaim: the saved sessions are known to be complete (the
        ///     state file was read and does not carry
        ///     ``PersistedState/sessionListIncomplete``).
        ///
        /// Held back: ends nothing; spared = old spared ∪ ((live ∪ present)
        /// − referenced). Allowed: spared is unchanged; ends live −
        /// referenced − spared. A referenced session is never spared.
        public init(
            live: Set<SessionID>, referenced: Set<SessionID>, spared: Set<SessionID>,
            present: Set<SessionID> = [], mayReclaim: Bool
        ) {
            if mayReclaim {
                toEnd = OrphanReclaimer.orphans(live: live, referenced: referenced).subtracting(spared)
                self.spared = spared.subtracting(referenced)
            } else {
                toEnd = []
                self.spared = spared.union(live).union(present).subtracting(referenced)
            }
        }
    }

    /// What ``reclaim(live:present:model:mayReclaim:backend:)`` did.
    public struct Outcome: Equatable, Sendable {
        /// Sessions ended (a failed kill is left out, and tried again at
        /// the next launch that may reclaim).
        public var ended: [SessionID]
        /// The spared list now in the model.
        public var spared: [SessionID]
        /// How many of `spared` are running: listed, or with a socket
        /// (`present`).
        public var sparedRunning: Int
        /// Whether recording the outcome changed the model (only then does
        /// the app save at once).
        public var changedModel: Bool
    }

    /// Plans from `live` and the model, ends what the plan says, and
    /// records the spared list in the model, clearing
    /// ``AppModel/sessionListIncomplete``. Called only when the live probe
    /// answered and the persistent runtime is available; otherwise nothing
    /// is recorded and the flag stays.
    @MainActor
    public static func reclaim(
        live: Set<SessionID>, present: Set<SessionID> = [], model: AppModel, mayReclaim: Bool,
        backend: any PersistenceBackend
    ) async -> Outcome {
        let plan = Plan(
            live: live, referenced: Set(model.sessions.map(\.id)), spared: Set(model.sparedSessionIDs),
            present: present, mayReclaim: mayReclaim)
        var ended: [SessionID] = []
        for id in plan.toEnd.sorted() {
            do {
                try await backend.kill(id)
                ended.append(id)
            } catch {
                continue
            }
        }
        let changed = model.recordOrphanReclaim(spared: plan.spared)
        return Outcome(
            ended: ended, spared: model.sparedSessionIDs,
            sparedRunning: model.sparedSessionIDs.filter { live.contains($0) || present.contains($0) }.count,
            changedModel: changed)
    }
}
