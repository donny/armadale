import ArmadaleCore

/// Ends sessions in Armadale's private runtime that no saved session refers
/// to any more: for example one whose pane was closed while the runtime was
/// unavailable (it could not be killed then). Every session in that runtime
/// was created by Armadale (its directory is private to the app, and only
/// `a-<id>` names are listed), so this never touches anything else.
public enum OrphanReclaimer {
    /// The live sessions no saved session refers to.
    public static func orphans(live: Set<SessionID>, referenced: Set<SessionID>) -> Set<SessionID> {
        live.subtracting(referenced)
    }

    /// Kills the orphans and returns their IDs. Does nothing unless the
    /// state loaded cleanly: after a damaged or newer state file the
    /// references are unknown, and a session that only looks orphaned must
    /// not be killed.
    @discardableResult
    public static func reclaim(
        live: Set<SessionID>,
        referenced: Set<SessionID>,
        stateLoadedCleanly: Bool,
        backend: any PersistenceBackend
    ) async -> [SessionID] {
        guard stateLoadedCleanly else { return [] }
        var killed: [SessionID] = []
        for id in orphans(live: live, referenced: referenced).sorted() {
            do {
                try await backend.kill(id)
                killed.append(id)
            } catch {
                continue
            }
        }
        return killed
    }
}
