import Foundation
import Testing

/// The app-wide full-screen serializer (DESIGN §8): one step at a time,
/// never while a window is in a transition, closes ahead of entries, and a
/// step's second `done` is ignored. No window is involved.
@Suite("Full-screen serializer")
@MainActor
struct FullScreenSerializerTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private final class Owner {}

    @Test func stepsRunOneAtATimeAndWaitForTransitions() async throws {
        let serializer = FullScreenSerializer(settle: .milliseconds(50))
        var log: [String] = []
        var pending: [@MainActor () -> Void] = []
        let window = Owner()

        serializer.transitionBegan(window) // a toggle by hand, say
        serializer.enqueue { done in log.append("entry A"); pending.append(done) }
        serializer.enqueue { done in log.append("entry B"); pending.append(done) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(log.isEmpty, "nothing starts during a transition")

        serializer.transitionEnded(window)
        #expect(await eventually { log == ["entry A"] })
        // A close queued now goes ahead of the entry still waiting.
        serializer.enqueue(ahead: true) { done in log.append("close C"); done(); done() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(log == ["entry A"], "the running step holds the queue")

        let finishA = pending.removeFirst()
        finishA()
        finishA() // a second call is ignored
        #expect(await eventually { log == ["entry A", "close C", "entry B"] })
        #expect(!serializer.isIdle, "entry B has not called done")
        pending.removeFirst()()
        #expect(await eventually { serializer.isIdle })
    }

    /// A transition noted but not counted (AppKit's exit after a
    /// full-screen window closes) still delays the next step by the settle
    /// time.
    @Test func aNotedTransitionEndDelaysTheNextStep() async throws {
        let serializer = FullScreenSerializer(settle: .milliseconds(400))
        var started: ContinuousClock.Instant?
        serializer.noteTransitionEnded()
        let noted = ContinuousClock.now
        serializer.enqueue { done in started = .now; done() }
        #expect(await eventually { started != nil })
        let waited = try #require(started) - noted
        #expect(waited >= .milliseconds(350), "waited \(waited)")
        #expect(await eventually { serializer.isIdle })
    }
}
