import AppKit
import QuartzCore
import SwiftUI

/// The pulse of a recording's dots (DESIGN §8, "Recording a pane"): the
/// opacity swings from full down to ``minimum`` and back every ``period``
/// seconds, on one clock for every dot, so any two dots on screen (a
/// header's and its tab's sidebar row's, two recordings' rows) rise and
/// fall together, however and whenever each was started.
enum RecordingPulse {
    static let period: Double = 1.6
    static let minimum: Float = 0.25

    /// When a pulse started at `now` (media time, `CACurrentMediaTime()`)
    /// is said to have begun: the last multiple of ``period``. Every pulse has
    /// begun at a multiple of the period, so all are in phase.
    static func alignedBeginTime(now: CFTimeInterval) -> CFTimeInterval {
        now - phase(at: now)
    }

    /// How far into its cycle, in seconds, every pulse is at `time`.
    static func phase(at time: CFTimeInterval) -> CFTimeInterval {
        let phase = time.truncatingRemainder(dividingBy: period)
        return phase < 0 ? phase + period : phase
    }
}

/// A recording dot in SwiftUI: the header's (8 pt) and a sidebar tab row's
/// (6 pt). Each update makes sure it pulses, so a row the List reuses
/// pulses too.
struct PulsingDot: NSViewRepresentable {
    var diameter: CGFloat

    func makeNSView(context: Context) -> PulsingDotView { PulsingDotView(diameter: diameter) }

    func updateNSView(_ view: PulsingDotView, context: Context) {
        view.diameter = diameter
        view.ensurePulse()
    }
}

/// A red circle whose opacity pulses as a Core Animation animation on its
/// layer, which the render server runs with no SwiftUI update per frame.
/// The layer's own opacity is full, so a dot whose animation is not
/// running is a steady full red, never the dim end. The pulse is added
/// afresh whenever the dot can be seen again (back in a window, its
/// window's occlusion changing, the app unhidden), always on the common
/// clock (``RecordingPulse``), so a restart never shows; with Reduce
/// Motion the dot is steady, following a change of that setting.
final class PulsingDotView: NSView {
    static let animationKey = "armadale.recording-pulse"
    /// Whether Reduce Motion is on; replaced in tests.
    static var reducesMotion: @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var diameter: CGFloat {
        didSet { if diameter != oldValue { needsDisplay = true } }
    }
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    /// The window whose occlusion is followed.
    private var observedWindow: NSWindow?
    private var occlusionObserver: (any NSObjectProtocol)?
    /// How many times the pulse was (re)started (for tests).
    private(set) var pulseStarts = 0

    init(diameter: CGFloat = PaneCardStyle.recordingDotSize) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter + 2, height: diameter + 2))
        wantsLayer = true
        // Reduce Motion switched; the app unhidden (its windows' animations
        // may be gone until something adds them again).
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        observe(NotificationCenter.default, NSApplication.didUnhideNotification)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartPulse() }
        }
        observers.append((center, token))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        for (center, token) in observers { center.removeObserver(token) }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        followOcclusion(of: window)
        restartPulse()
    }

    /// The window's occlusion changing (shown again after being covered,
    /// minimized, on another Space) restarts the pulse.
    private func followOcclusion(of window: NSWindow?) {
        guard window !== observedWindow else { return }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        observedWindow = window
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartPulse() }
        }
    }

    /// Whether the dot pulses now.
    var isPulsing: Bool { layer?.animation(forKey: Self.animationKey) != nil }

    /// The layer's own opacity: full.
    var restingOpacity: Float { layer?.opacity ?? 0 }

    /// The pulse's begin time, in the layer's time (for tests).
    var pulseBeginTime: CFTimeInterval? { layer?.animation(forKey: Self.animationKey)?.beginTime }

    /// Adds the pulse if it is missing (a SwiftUI update, a reused row).
    func ensurePulse() {
        if !isPulsing { restartPulse() }
    }

    /// Adds the pulse afresh on the common clock, or takes it away (out of
    /// a window, Reduce Motion).
    func restartPulse() {
        guard let layer else { return }
        layer.opacity = 1
        layer.removeAnimation(forKey: Self.animationKey)
        guard window != nil, !Self.reducesMotion() else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = RecordingPulse.minimum
        pulse.duration = RecordingPulse.period / 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        // On the common clock: begun at the last multiple of the period of
        // the media time, in this layer's time.
        pulse.beginTime = layer.convertTime(RecordingPulse.alignedBeginTime(now: CACurrentMediaTime()), from: nil)
        layer.add(pulse, forKey: Self.animationKey)
        pulseStarts += 1
    }
}
