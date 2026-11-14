import Foundation

/// Debounces state saves on the main actor.
///
/// Each ``schedule(_:)`` replaces the pending snapshot and restarts the
/// timer; the snapshot is written once the model has been quiet for
/// `interval`, but never later than `maximumDelay` after the first change
/// not yet written: a steady stream of changes (programs setting their
/// titles) cannot put a save off. ``flush()`` writes any pending snapshot immediately, which is
/// what the app calls on quit. Saves run on the main actor so a flush can
/// never race a debounced write; the document is small.
///
/// A failed write keeps the snapshot pending (unless a newer one has been
/// scheduled since) and retries after a backoff of 1 s, 2 s, 4 s … capped at
/// 30 s. The backoff resets after a successful write. While a retry is
/// pending, ``schedule(_:)`` replaces the snapshot but leaves the retry's
/// timer alone, so the next attempt comes at the backoff's time, neither
/// earlier nor later, however many changes arrive; ``flush()`` still writes
/// at once. Every write attempt restarts the longest wait.
@MainActor
public final class StateSaver {
    /// Writes a snapshot. Defaults to ``StateStore/save(_:to:fileManager:)``.
    public typealias Writer = @MainActor (PersistedState) throws -> Void

    /// Delay before retry number `attempt` (1-based) after consecutive failures.
    public typealias RetryDelay = @Sendable (_ attempt: Int) -> Duration

    /// 1 s, 2 s, 4 s, … capped at 30 s.
    public static let exponentialBackoff: RetryDelay = { attempt in
        let exponent = min(max(attempt - 1, 0), 5) // 2^5 = 32 > 30
        return .seconds(min(1 << exponent, 30))
    }

    /// The current time; injectable so tests need not depend on timing.
    public typealias Now = @Sendable () -> ContinuousClock.Instant

    public let interval: Duration
    /// The longest a change waits to be written while more keep coming.
    public let maximumDelay: Duration
    private let retryDelay: RetryDelay
    private let now: Now
    private let writer: Writer
    private var pending: PersistedState?
    private var timer: Task<Void, Never>?
    /// When the first change not yet written was scheduled; `nil` after a
    /// write attempt, a flush with nothing pending, or a cancel.
    private var firstPendingAt: ContinuousClock.Instant?
    /// The delay the latest ``schedule(_:)`` set its timer to (for tests).
    private(set) var lastScheduledDelay: Duration?
    /// A failed write's retry timer is running; schedules leave it alone.
    private(set) var isRetryPending = false

    /// Number of snapshots written so far.
    public private(set) var saveCount = 0
    /// Consecutive failed writes since the last success.
    public private(set) var consecutiveFailures = 0
    /// The most recent write error, cleared by the next successful write.
    public private(set) var lastError: (any Error)?
    /// Called on the main actor after every failed write, with the error and
    /// the number of consecutive failures. The app uses it to tell the user
    /// once.
    public var onWriteFailure: (@MainActor (any Error, Int) -> Void)?

    /// Saves to `url` with ``StateStore``.
    public convenience init(
        url: URL,
        interval: Duration = .milliseconds(500),
        maximumDelay: Duration = .seconds(2),
        retryDelay: @escaping RetryDelay = StateSaver.exponentialBackoff
    ) {
        self.init(interval: interval, maximumDelay: maximumDelay, retryDelay: retryDelay) { state in
            try StateStore.save(state, to: url)
        }
    }

    /// Saves with a custom writer (used by tests).
    public init(
        interval: Duration = .milliseconds(500),
        maximumDelay: Duration = .seconds(2),
        retryDelay: @escaping RetryDelay = StateSaver.exponentialBackoff,
        now: @escaping Now = { ContinuousClock.now },
        writer: @escaping Writer
    ) {
        self.interval = interval
        self.maximumDelay = max(maximumDelay, interval)
        self.retryDelay = retryDelay
        self.now = now
        self.writer = writer
    }

    /// How long a ``schedule(_:)`` waits: the debounce `interval`, cut short
    /// so the write is due no later than `maximumDelay` after the first
    /// change not yet written (`elapsed` ago); never negative.
    public static func delay(elapsed: Duration, interval: Duration, maximumDelay: Duration) -> Duration {
        let remaining = maximumDelay - elapsed
        return max(.zero, min(interval, remaining))
    }

    /// Whether a snapshot is waiting to be written.
    public var hasPending: Bool { pending != nil }

    /// Replaces the pending snapshot and restarts the debounce timer, which
    /// is never set past the longest wait.
    public func schedule(_ state: PersistedState) {
        pending = state
        // The failure backoff decides when the next attempt is.
        guard !isRetryPending else { return }
        let current = now()
        let first = firstPendingAt ?? current
        firstPendingAt = first
        let delay = Self.delay(elapsed: current - first, interval: interval, maximumDelay: maximumDelay)
        lastScheduledDelay = delay
        startTimer(after: delay)
    }

    /// Writes the pending snapshot now, if any. On failure the snapshot
    /// stays pending and a retry is scheduled.
    public func flush() {
        timer?.cancel()
        timer = nil
        firstPendingAt = nil
        isRetryPending = false
        guard let state = pending else { return }
        pending = nil
        do {
            try writer(state)
            saveCount += 1
            consecutiveFailures = 0
            lastError = nil
        } catch {
            consecutiveFailures += 1
            lastError = error
            // Nothing newer can have been scheduled during the synchronous
            // write, but keep the rule explicit: never replace a newer snapshot.
            if pending == nil { pending = state }
            startTimer(after: retryDelay(consecutiveFailures))
            isRetryPending = true
            onWriteFailure?(error, consecutiveFailures)
        }
    }

    /// Drops the pending snapshot without writing it.
    public func cancel() {
        timer?.cancel()
        timer = nil
        pending = nil
        firstPendingAt = nil
        isRetryPending = false
    }

    private func startTimer(after delay: Duration) {
        timer?.cancel()
        timer = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return // cancelled by a newer schedule, a flush, or cancel()
            }
            self?.flush()
        }
    }
}
