import Foundation

/// Runs full-screen work one step at a time, app-wide (DESIGN §8, "Full
/// screen" and "Closing in full screen"): launch entries, entries after
/// menu bar mode, exits for menu bar mode and exits before a close. AppKit
/// handles two overlapping transitions badly: a second toggle while one
/// animates can be refused, and a window closed in full screen while
/// another window's transition runs comes back on screen, empty.
///
/// A step starts only when the previous one has called its `done` and no
/// window is in a transition (``transitionBegan(_:)`` /
/// ``transitionEnded(_:)``, reported by every window, a toggle by hand
/// included), and always from the default run-loop mode on a later turn:
/// never from inside a transition's own callback (where AppKit refuses a
/// toggle), and not under a launch alert's modal session but once it is
/// closed. Every step must call `done` exactly once on every path (a
/// refused toggle included; a second call is ignored); a transition that
/// never ends would hold the queue, and no timeout exists.
@MainActor
final class FullScreenSerializer {
    typealias Step = @MainActor (_ done: @escaping @MainActor () -> Void) -> Void

    /// Queued steps; `ahead` ones (closes) go before the others.
    private var steps: [(ahead: Bool, step: Step)] = []
    private var isRunning = false
    private var isScheduled = false
    /// Windows in a transition, by their controller.
    private var transitioning: Set<ObjectIdentifier> = []
    /// When the last transition ended: a step starts no sooner than
    /// ``settle`` after it.
    private var lastTransitionEnd: ContinuousClock.Instant?
    /// Measured on macOS 27: an exit toggled 9 ms after another window's
    /// entry ended failed (`windowDidFailToExitFullScreen`, and AppKit put
    /// the window back into full screen); entries 7 ms apart worked.
    private let settle: Duration

    init(settle: Duration = .milliseconds(300)) {
        self.settle = settle
    }

    /// Nothing queued, running or in a transition.
    var isIdle: Bool { steps.isEmpty && !isRunning && transitioning.isEmpty }

    /// Queues `step`. One `ahead` (a window closing) goes before the
    /// steps queued without it, after the earlier `ahead` ones, so an
    /// emptied window does not wait for the other windows' entries.
    func enqueue(ahead: Bool = false, _ step: @escaping Step) {
        let index = ahead ? (steps.firstIndex { !$0.ahead } ?? steps.endIndex) : steps.endIndex
        steps.insert((ahead, step), at: index)
        schedule()
    }

    func transitionBegan(_ owner: AnyObject) {
        transitioning.insert(ObjectIdentifier(owner))
    }

    func transitionEnded(_ owner: AnyObject) {
        guard transitioning.remove(ObjectIdentifier(owner)) != nil else { return }
        lastTransitionEnd = .now
        schedule()
    }

    /// A transition the serializer did not count has just ended (the exit
    /// AppKit runs after a full-screen window closes, which comes after
    /// `windowWillClose`): the next step still waits ``settle`` after it.
    func noteTransitionEnded() {
        lastTransitionEnd = .now
    }

    private func schedule() {
        guard !isScheduled, !isRunning, !steps.isEmpty, transitioning.isEmpty else { return }
        isScheduled = true
        let wait = lastTransitionEnd.map { settle - (ContinuousClock.now - $0) } ?? .zero
        guard wait > .zero else {
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                MainActor.assumeIsolated { self?.runNext() }
            }
            return
        }
        let seconds = Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runNext() }
        }
        RunLoop.main.add(timer, forMode: .default)
    }

    private func runNext() {
        isScheduled = false
        guard !isRunning, transitioning.isEmpty, !steps.isEmpty else { return }
        if let lastTransitionEnd, ContinuousClock.now - lastTransitionEnd < settle {
            return schedule() // a transition ended meanwhile: wait again
        }
        isRunning = true
        let step = steps.removeFirst().step
        var isDone = false
        step { [weak self] in
            guard !isDone else { return }
            isDone = true
            self?.isRunning = false
            self?.schedule()
        }
    }
}
