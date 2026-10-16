import Synchronization

/// A value that is set once and can be awaited by any number of tasks.
/// Waiting is cancellable: a cancelled waiter returns `nil` immediately.
final class Latch<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiters: [Int: CheckedContinuation<Value?, Never>] = [:]
        var nextWaiterID = 0
    }

    private let state = Mutex(State())

    init() {}

    /// The value, if it has been set.
    var value: Value? { state.withLock { $0.value } }

    /// Sets the value and wakes every waiter. Later calls are ignored and
    /// return `false`.
    @discardableResult
    func set(_ value: Value) -> Bool {
        let waiters: [CheckedContinuation<Value?, Never>]? = state.withLock { state in
            guard state.value == nil else { return nil }
            state.value = value
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        guard let waiters else { return false }
        for waiter in waiters { waiter.resume(returning: value) }
        return true
    }

    /// Suspends until the value is set. Returns `nil` only if the calling
    /// task is cancelled first.
    func wait() async -> Value? {
        let id = state.withLock { state in
            defer { state.nextWaiterID += 1 }
            return state.nextWaiterID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                let immediate: Value?? = state.withLock { state in
                    if let value = state.value { return .some(value) }
                    if Task.isCancelled { return .some(nil) }
                    state.waiters[id] = continuation
                    return .none
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(returning: nil)
        }
    }

    /// Waits at most `timeout`; `nil` if the value was not set in time.
    func wait(timeout: Duration) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await self.wait() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? self.value
        }
    }
}
