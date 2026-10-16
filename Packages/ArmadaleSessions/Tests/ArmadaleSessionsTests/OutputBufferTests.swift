import Dispatch
import Foundation
import Synchronization
import Testing
@testable import ArmadaleSessions

@Suite("OutputBuffer")
struct OutputBufferTests {
    /// Counts `resumeProducer` calls.
    private final class ResumeCounter: Sendable {
        let count = Mutex(0)
        func fire() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    private func makeBuffer() -> (OutputBuffer, ResumeCounter) {
        let counter = ResumeCounter()
        let buffer = OutputBuffer(queue: DispatchQueue(label: "test.output")) { counter.fire() }
        return (buffer, counter)
    }

    private func append(_ buffer: OutputBuffer, _ count: Int, byte: UInt8 = 0x61) -> Bool {
        [UInt8](repeating: byte, count: count).withUnsafeBytes { buffer.append($0) }
    }

    @Test func firstOutputIsImmediateThenThrottledUnlessAFullBatchIsReady() async throws {
        let (buffer, _) = makeBuffer()
        var iterator = buffer.makeStream().makeAsyncIterator()
        let clock = ContinuousClock()

        // Leading edge: nothing delivered recently, so no delay.
        _ = append(buffer, 10)
        var start = clock.now
        #expect(await iterator.next()?.count == 10)
        #expect(clock.now - start < .milliseconds(10))

        // Within 16 ms of that delivery, a small batch waits for the interval.
        _ = append(buffer, 10)
        start = clock.now
        #expect(await iterator.next()?.count == 10)
        #expect(clock.now - start >= .milliseconds(12))

        // A full 64 KB batch is handed over at once, interval or not; the
        // rest follows after the interval.
        _ = append(buffer, OutputBuffer.maxBatch + 100)
        start = clock.now
        #expect(await iterator.next()?.count == OutputBuffer.maxBatch)
        #expect(clock.now - start < .milliseconds(10))
        #expect(await iterator.next()?.count == 100)

        // Small writes arriving while the consumer waits are coalesced.
        let waiter = Task { await iterator.next()?.count }
        try await Task.sleep(for: .milliseconds(2))
        for _ in 0..<5 { _ = append(buffer, 3) }
        #expect(await waiter.value == 15)
    }

    @Test func finishDeliversPendingBytesAtOnceThenEnds() async {
        let (buffer, _) = makeBuffer()
        var iterator = buffer.makeStream().makeAsyncIterator()
        _ = append(buffer, 1)
        _ = await iterator.next()
        _ = append(buffer, 7) // would be throttled…
        buffer.finish()       // …but the end flushes it.
        let start = ContinuousClock.now
        #expect(await iterator.next()?.count == 7)
        #expect(await iterator.next() == nil)
        #expect(ContinuousClock.now - start < .milliseconds(10))
    }

    @Test func pauseAndResumeAreBalanced() async {
        let (buffer, counter) = makeBuffer()
        var iterator = buffer.makeStream().makeAsyncIterator()
        // Below the high-water mark: keep reading.
        #expect(!append(buffer, OutputBuffer.highWater - 1))
        // At it: pause.
        #expect(append(buffer, 1))
        #expect(counter.value == 0)
        // Draining to below half the mark resumes exactly once.
        var received = 0
        while received < OutputBuffer.highWater {
            received += await iterator.next()?.count ?? 0
        }
        #expect(counter.value == 1)
        // A new pause needs the mark to be reached again, and resumes once more.
        #expect(!append(buffer, OutputBuffer.highWater / 2))
        #expect(append(buffer, OutputBuffer.highWater / 2))
        received = 0
        while received < OutputBuffer.highWater {
            received += await iterator.next()?.count ?? 0
        }
        #expect(counter.value == 2)
    }

    @Test func cancelledConsumerResumesAPausedProducer() async {
        let (buffer, counter) = makeBuffer()
        #expect(append(buffer, OutputBuffer.highWater))
        let stream = buffer.makeStream()
        let consumer = Task {
            var count = 0
            for await batch in stream { count += batch.count }
            return count
        }
        consumer.cancel()
        _ = await consumer.value
        #expect(counter.value == 1, "a paused producer must not stay paused once nobody reads")
        // Output after cancellation is dropped and never pauses again.
        #expect(!append(buffer, OutputBuffer.highWater))
        #expect(counter.value == 1)
    }

    @Test func cancellingAWaitingConsumerEndsTheStream() async throws {
        let (buffer, _) = makeBuffer()
        let stream = buffer.makeStream()
        let consumer = Task {
            var batches = 0
            for await _ in stream { batches += 1 }
            return batches
        }
        try await Task.sleep(for: .milliseconds(20))
        consumer.cancel()
        #expect(await consumer.value == 0)
    }
}
