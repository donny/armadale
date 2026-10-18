/// When a session controller retries a lost connection by itself
/// (docs/DESIGN.md section 6): after 1 s, 2 s, 4 s … doubling up to 30 s
/// between attempts, and no new attempt once 5 minutes have passed since
/// the connection was lost. Pure, so the schedule is testable on its own.
public struct ReconnectSchedule: Sendable, Hashable {
    public var initialDelay: Duration
    public var maximumDelay: Duration
    /// No attempt starts later than this after the first failure.
    public var budget: Duration

    public init(initialDelay: Duration = .seconds(1), maximumDelay: Duration = .seconds(30), budget: Duration = .seconds(300)) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.budget = budget
    }

    /// How long to wait before attempt `attempt` (0 is the first retry),
    /// given that `elapsed` has passed since the connection was lost; `nil`
    /// when that attempt would start after the budget: stop retrying.
    public func delay(beforeAttempt attempt: Int, elapsed: Duration) -> Duration? {
        let delay = delay(beforeAttempt: attempt)
        return elapsed + delay <= budget ? delay : nil
    }

    /// The pause before attempt `attempt`, ignoring the budget.
    public func delay(beforeAttempt attempt: Int) -> Duration {
        guard attempt > 0 else { return min(initialDelay, maximumDelay) }
        // Doubling saturates long before Int would overflow.
        let factor = 1 << min(attempt, 30)
        let delay = initialDelay * factor
        return delay < maximumDelay ? delay : maximumDelay
    }

    /// Every pause of the schedule, assuming attempts take no time.
    public var delays: [Duration] {
        var delays: [Duration] = []
        var elapsed: Duration = .zero
        while delays.count < 1000, let delay = delay(beforeAttempt: delays.count, elapsed: elapsed) {
            delays.append(delay)
            elapsed += delay
        }
        return delays
    }
}
