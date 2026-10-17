import Testing

@Suite("CloseRisk")
struct CloseRiskTests {
    private func item(_ status: SessionStatus, mayExist: Bool = true, running: Bool = false) -> CloseRisk.Item {
        CloseRisk.Item(status: status, mayExist: mayExist, isRunning: running)
    }

    @Test func runningAndDisconnectedMayBeRunning() {
        #expect(CloseRisk.assess([item(.running)]).mayBeRunning)
        #expect(CloseRisk.assess([item(.disconnected)]).mayBeRunning)
        #expect(CloseRisk.assess([item(.ended), item(.running)]).mayBeRunning)
    }

    @Test func pendingRestoredSessionBeforeTheProbeAsks() {
        // Restored, never shown, probe not answered yet: may well be alive.
        let risk = CloseRisk.assess([item(.pending, mayExist: true)])
        #expect(risk == CloseRisk(mayBeRunning: true, unreachable: false))
    }

    @Test func pendingSessionThatNeverStartedDoesNotAsk() {
        // Created this run, pane never shown: there is no process.
        #expect(!CloseRisk.assess([item(.pending, mayExist: false)]).mayBeRunning)
    }

    @Test func endedDoesNotAsk() {
        #expect(CloseRisk.assess([item(.ended), item(.ended)]) == CloseRisk(mayBeRunning: false, unreachable: false))
        #expect(CloseRisk.assess([]) == CloseRisk(mayBeRunning: false, unreachable: false))
    }

    @Test func unavailableIsUnreachable() {
        let risk = CloseRisk.assess([item(.unavailable), item(.ended)])
        #expect(risk.unreachable)
        #expect(!risk.mayBeRunning)
    }

    @Test func summaryPrefersProblemsThenRunning() {
        #expect(SessionStatus.summary(of: [.ended, .running, .pending]) == .running)
        #expect(SessionStatus.summary(of: [.running, .disconnected]) == .disconnected)
        #expect(SessionStatus.summary(of: [.unavailable, .running]) == .unavailable)
        #expect(SessionStatus.summary(of: [.ended, .pending]) == .pending)
        #expect(SessionStatus.summary(of: [.ended, .ended]) == .ended)
        #expect(SessionStatus.summary(of: []) == .ended)
    }
}
