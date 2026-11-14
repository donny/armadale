import Dispatch
import Synchronization

/// Accumulates PTY output on the I/O queue and hands it to a single consumer
/// as coalesced batches, with backpressure.
///
/// - A batch is at most ``maxBatch`` bytes.
/// - Delivery is throttled, not debounced: the first bytes after a quiet
///   period go out at once (interactive echo is not delayed), but within
///   ``interval`` of the previous batch further output waits until the
///   interval has passed or a full batch has accumulated. A flood therefore
///   reaches the main actor as full 64 KB batches, as fast as the consumer
///   takes them: the interval only holds back smaller batches, and
///   backpressure (below), not the interval, bounds a flood.
/// - Delivery is pull-based (`AsyncStream(unfolding:)`): when more than
///   ``highWater`` bytes are waiting, the producer is told to stop reading,
///   which lets the kernel's PTY buffer fill and blocks the child, exactly as
///   a slow real terminal would. Memory stays bounded however fast the child
///   writes.
final class OutputBuffer: Sendable {
    static let maxBatch = 64 * 1024
    static let interval: UInt64 = 16_000_000 // ns
    static let highWater = 4 * maxBatch

    private struct State {
        var pending: [UInt8] = []
        /// No more input will arrive (EOF, or the PTY was closed).
        var isFinished = false
        /// The consumer stopped iterating (its task was cancelled).
        var isCancelled = false
        var waiter: CheckedContinuation<[UInt8]?, Never>?
        var lastDelivery: UInt64 = 0
        var isTimerArmed = false
        /// The producer was told to pause because of backpressure.
        var isProducerPaused = false
    }

    private let state = Mutex(State())
    private let queue: DispatchQueue
    /// Called (from the consumer's context) when a paused producer may
    /// resume reading.
    private let resumeProducer: @Sendable () -> Void

    init(queue: DispatchQueue, resumeProducer: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.resumeProducer = resumeProducer
    }

    /// The consumer-facing stream.
    func makeStream() -> AsyncStream<[UInt8]> {
        // `onCancel` covers a consumer cancelled before it ever asks (the
        // stream then never calls the closure); the handler inside `next()`
        // covers one cancelled while waiting.
        AsyncStream(unfolding: { [self] in await self.next() }, onCancel: { [self] in self.consumerCancelled() })
    }

    // MARK: Producer (I/O queue)

    /// Appends output. Returns `true` if the producer must pause reading
    /// until `resumeProducer` is called.
    func append(_ bytes: UnsafeRawBufferPointer) -> Bool {
        let now = Self.now()
        let (delivery, timer, pause): (Delivery?, UInt64?, Bool) = state.withLock { state in
            guard !state.isFinished, !state.isCancelled else { return (nil, nil, false) }
            state.pending.append(contentsOf: bytes)
            let pause = state.pending.count >= Self.highWater
            if pause { state.isProducerPaused = true }
            let (delivery, timer) = Self.serviceWaiter(&state, now: now)
            return (delivery, timer, pause)
        }
        delivery?.run()
        if let timer { armTimer(after: timer) }
        return pause
    }

    /// Marks the end of output; the consumer receives what is pending, then `nil`.
    func finish() {
        let delivery: Delivery? = state.withLock { state in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            return Self.serviceWaiter(&state, now: Self.now()).0
        }
        delivery?.run()
    }

    var isFinished: Bool { state.withLock { $0.isFinished } }

    /// Waits, without consuming anything, until the output not yet delivered
    /// satisfies `predicate`, the output has finished, or `timeout` passes;
    /// returns that output. Used to look at a client's first bytes before
    /// its stream is handed to the consumer. Polls: it is only used for a
    /// moment at attach time.
    func peek(timeout: Duration, until predicate: ([UInt8]) -> Bool) async -> (bytes: [UInt8], isFinished: Bool) {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            let (bytes, finished) = state.withLock { ($0.pending, $0.isFinished) }
            if finished || predicate(bytes) || clock.now >= deadline || Task.isCancelled {
                return (bytes, finished)
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Consumer

    private func next() async -> [UInt8]? {
        let batch: [UInt8]? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[UInt8]?, Never>) in
                let (immediate, timer): ([UInt8]??, UInt64?) = state.withLock { state in
                    if state.isCancelled || Task.isCancelled {
                        state.isCancelled = true
                        return (.some(nil), nil)
                    }
                    if let batch = Self.takeBatchIfReady(&state, now: Self.now()) { return (.some(batch), nil) }
                    // takeBatchIfReady always returns pending bytes once finished.
                    if state.isFinished { return (.some(nil), nil) }
                    state.waiter = continuation
                    return (.none, Self.timerDelay(&state, now: Self.now()))
                }
                if let immediate { continuation.resume(returning: immediate) }
                if let timer { armTimer(after: timer) }
            }
        } onCancel: {
            consumerCancelled()
        }
        if batch != nil, state.withLock({ Self.shouldResumeProducer(&$0) }) { resumeProducer() }
        return batch
    }

    /// The consumer is gone: drop output from now on, and never leave the
    /// producer paused, or the child would block on a full PTY. Idempotent.
    private func consumerCancelled() {
        let (waiter, wasPaused) = state.withLock { state in
            state.isCancelled = true
            state.pending = []
            defer {
                state.waiter = nil
                state.isProducerPaused = false
            }
            return (state.waiter, state.isProducerPaused)
        }
        waiter?.resume(returning: nil)
        if wasPaused { resumeProducer() }
    }

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    private struct Delivery {
        let waiter: CheckedContinuation<[UInt8]?, Never>
        let batch: [UInt8]?
        func run() { waiter.resume(returning: batch) }
    }

    /// If a consumer is waiting and a batch is ready, hands it over.
    /// Otherwise returns the delay after which to look again.
    private static func serviceWaiter(_ state: inout State, now: UInt64) -> (Delivery?, UInt64?) {
        guard let waiter = state.waiter else { return (nil, nil) }
        if let batch = takeBatchIfReady(&state, now: now) {
            state.waiter = nil
            return (Delivery(waiter: waiter, batch: batch), nil)
        }
        if state.isFinished, state.pending.isEmpty {
            state.waiter = nil
            return (Delivery(waiter: waiter, batch: nil), nil)
        }
        return (nil, timerDelay(&state, now: now))
    }

    private static func takeBatchIfReady(_ state: inout State, now: UInt64) -> [UInt8]? {
        guard !state.pending.isEmpty else { return nil }
        let due = now &- state.lastDelivery >= interval
        guard due || state.pending.count >= maxBatch || state.isFinished else { return nil }
        let count = min(state.pending.count, maxBatch)
        let batch: [UInt8]
        if count == state.pending.count {
            batch = state.pending
            state.pending.removeAll(keepingCapacity: true)
        } else {
            batch = Array(state.pending[..<count])
            state.pending.removeFirst(count)
        }
        state.lastDelivery = now
        return batch
    }

    private static func shouldResumeProducer(_ state: inout State) -> Bool {
        guard state.isProducerPaused, state.pending.count < highWater / 2 else { return false }
        state.isProducerPaused = false
        return true
    }

    private static func timerDelay(_ state: inout State, now: UInt64) -> UInt64? {
        guard !state.pending.isEmpty, !state.isTimerArmed else { return nil }
        state.isTimerArmed = true
        let elapsed = now &- state.lastDelivery
        return elapsed >= interval ? 0 : interval - elapsed
    }

    private func armTimer(after nanoseconds: UInt64) {
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) { [weak self] in
            self?.timerFired()
        }
    }

    private func timerFired() {
        let (delivery, timer): (Delivery?, UInt64?) = state.withLock { state in
            state.isTimerArmed = false
            return Self.serviceWaiter(&state, now: Self.now())
        }
        delivery?.run()
        if let timer { armTimer(after: timer) }
    }
}
