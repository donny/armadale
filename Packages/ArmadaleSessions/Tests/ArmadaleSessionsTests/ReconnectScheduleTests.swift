import Testing
@testable import ArmadaleSessions

@Suite("ReconnectSchedule")
struct ReconnectScheduleTests {
    @Test func doublesFromOneSecondUpToThirtyForFiveMinutes() {
        let schedule = ReconnectSchedule()
        let seconds = schedule.delays.map { Int($0.components.seconds) }
        #expect(seconds == [1, 2, 4, 8, 16, 30, 30, 30, 30, 30, 30, 30, 30])
        #expect(seconds.reduce(0, +) <= 300)
    }

    @Test func noAttemptStartsAfterTheBudget() {
        let schedule = ReconnectSchedule()
        #expect(schedule.delay(beforeAttempt: 0, elapsed: .zero) == .seconds(1))
        #expect(schedule.delay(beforeAttempt: 3, elapsed: .seconds(10)) == .seconds(8))
        #expect(schedule.delay(beforeAttempt: 10, elapsed: .seconds(270)) == .seconds(30))
        #expect(schedule.delay(beforeAttempt: 10, elapsed: .seconds(271)) == nil)
        #expect(schedule.delay(beforeAttempt: 0, elapsed: .seconds(300)) == nil)
        // Doubling saturates instead of overflowing.
        #expect(schedule.delay(beforeAttempt: 500) == .seconds(30))
    }

    @Test func customSchedules() {
        let fast = ReconnectSchedule(initialDelay: .milliseconds(100), maximumDelay: .milliseconds(250), budget: .seconds(1))
        #expect(fast.delays == [.milliseconds(100), .milliseconds(200), .milliseconds(250), .milliseconds(250)])
    }
}
