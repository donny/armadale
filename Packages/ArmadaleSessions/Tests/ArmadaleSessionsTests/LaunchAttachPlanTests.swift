import ArmadaleCore
import Testing
@testable import ArmadaleSessions

/// The launch attach of restored sessions whose panes are not on screen
/// (docs/DESIGN.md section 4, "Restore at launch"): what each gets, and
/// the queue that paces them.
@Suite("Launch attach plan")
struct LaunchAttachPlanTests {
    let size = SessionGridSize(columns: 120, rows: 40)

    @Test func dispositions() {
        #expect(LaunchAttachPlan.disposition(.alive, savedSize: size) == .attach(size))
        #expect(LaunchAttachPlan.disposition(.alive, savedSize: nil) == .leave, "no program is resized on a guess")
        #expect(LaunchAttachPlan.disposition(.gone, savedSize: size) == .markEnded)
        #expect(LaunchAttachPlan.disposition(.gone, savedSize: nil) == .markEnded)
        #expect(LaunchAttachPlan.disposition(.unknown, savedSize: size) == .attach(size), "unreachable: tried, never ended")
        #expect(LaunchAttachPlan.disposition(.unknown, savedSize: nil) == .leave)
        #expect(LaunchAttachPlan.disposition(.alive, savedSize: SessionGridSize(columns: 0, rows: 3)) == .leave)
    }

    /// A socket counts as alive: the helper's listing leaves out a daemon
    /// that does not answer and still succeeds.
    @Test func localLiveness() {
        let listed = SessionID.generate(), socketOnly = SessionID.generate(), gone = SessionID.generate()
        #expect(LaunchAttachPlan.localLiveness(of: listed, listed: [listed], sockets: []) == .alive)
        #expect(LaunchAttachPlan.localLiveness(of: socketOnly, listed: [listed], sockets: [socketOnly]) == .alive)
        #expect(LaunchAttachPlan.localLiveness(of: gone, listed: [listed], sockets: [socketOnly]) == .gone)
        #expect(LaunchAttachPlan.localLiveness(of: gone, listed: nil, sockets: []) == .unknown)
        #expect(LaunchAttachPlan.localLiveness(of: socketOnly, listed: nil, sockets: [socketOnly]) == .alive)
    }

    private func ids(_ count: Int) -> [SessionID] { (0..<count).map { _ in .generate() } }

    @Test func keepsOrderAndTheLocalLimit() {
        var queue = LaunchAttachQueue()
        let sessions = ids(10)
        queue.enqueue(sessions.map { .init(id: $0, lane: .local) })
        let first = queue.take()
        #expect(first.map(\.id) == Array(sessions.prefix(4)), "sidebar order, four at a time")
        #expect(queue.take().isEmpty, "nothing more until one finishes")
        queue.finished(sessions[1], outcome: .done)
        #expect(queue.take().map(\.id) == [sessions[4]])
        for id in sessions[0...4] where id != sessions[1] { queue.finished(id, outcome: .done) }
        #expect(queue.take().map(\.id) == Array(sessions[5...8]))
        #expect(queue.inFlightCount(in: .local) == 4)
    }

    @Test func hostsHaveTheirOwnLimitOfTwo() {
        var queue = LaunchAttachQueue()
        let a = HostID(raw: "aaaaaaaaaaaaaaaa"), b = HostID(raw: "bbbbbbbbbbbbbbbb")
        let onA = ids(3), onB = ids(3), local = ids(5)
        queue.enqueue(onA.map { .init(id: $0, lane: .host(a)) } + local.map { .init(id: $0, lane: .local) }
            + onB.map { .init(id: $0, lane: .host(b)) })
        let taken = queue.take()
        #expect(taken.filter { $0.lane == .host(a) }.map(\.id) == Array(onA.prefix(2)))
        #expect(taken.filter { $0.lane == .host(b) }.map(\.id) == Array(onB.prefix(2)))
        #expect(taken.filter { $0.lane == .local }.map(\.id) == Array(local.prefix(4)))
        queue.finished(onA[0], outcome: .done)
        #expect(queue.take().map(\.id) == [onA[2]])
    }

    /// Attaches the app makes itself (panes shown at launch, a pane that
    /// jumps the queue) count against the limit, so visible panes go first.
    @Test func startsOutsideTheQueueCountAgainstTheLimit() {
        var queue = LaunchAttachQueue()
        let visible = ids(3), hidden = ids(3)
        for id in visible { queue.started(id, in: .local) }
        queue.enqueue(hidden.map { .init(id: $0, lane: .local) })
        #expect(queue.take().map(\.id) == [hidden[0]])
        // A pane shown while its session waits: it jumps the queue.
        queue.started(hidden[2], in: .local)
        #expect(!queue.isQueued(hidden[2]))
        #expect(queue.take().isEmpty)
        for id in visible { queue.finished(id, outcome: .done) }
        #expect(queue.take().map(\.id) == [hidden[1]])
    }

    @Test func aRemovedSessionIsNotStarted() {
        var queue = LaunchAttachQueue(localLimit: 1)
        let sessions = ids(3)
        queue.enqueue(sessions.map { .init(id: $0, lane: .local) })
        let removed = queue.remove(sessions[0])
        let again = queue.remove(sessions[0])
        #expect(removed && !again)
        #expect(queue.take().map(\.id) == [sessions[1]])
    }

    @Test func enqueueingTwiceAddsOnce() {
        var queue = LaunchAttachQueue()
        let id = SessionID.generate()
        queue.enqueue([.init(id: id, lane: .local), .init(id: id, lane: .local)])
        _ = queue.take()
        queue.enqueue([.init(id: id, lane: .local)])
        #expect(queue.queued.isEmpty, "in flight already")
    }

    /// A local attach that missed its window is tried once more after the
    /// local queue has drained; never twice, and never for a host.
    @Test func aDisconnectedLocalAttachIsRetriedOnceAfterTheQueueDrains() {
        var queue = LaunchAttachQueue(localLimit: 2)
        let host = HostID(raw: "aaaaaaaaaaaaaaaa")
        let local = ids(3), remote = ids(1)
        queue.enqueue(local.map { .init(id: $0, lane: .local) } + remote.map { .init(id: $0, lane: .host(host)) })
        _ = queue.take()
        queue.finished(local[0], outcome: .disconnected)
        queue.finished(remote[0], outcome: .disconnected)
        // The queue still holds local[2]: no retry yet.
        let next = queue.take()
        #expect(next.map(\.id) == [local[2]])
        #expect(next.allSatisfy { $0.kind == .attach })
        queue.finished(local[1], outcome: .done)
        #expect(queue.take().isEmpty, "local[2] is still in flight")
        queue.finished(local[2], outcome: .done)
        let retry = queue.take()
        #expect(retry == [.init(id: local[0], lane: .local, kind: .retry)])
        queue.finished(local[0], outcome: .disconnected)
        #expect(queue.take().isEmpty, "one retry only")
        #expect(queue.isIdle)
    }
}
