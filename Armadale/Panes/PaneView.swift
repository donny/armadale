import AppKit
import ArmadaleSessions
import SwiftUI

/// One pane: the session's terminal view filling it, and the *Session
/// Ended* placeholder over it once the session is over.
///
/// A `PaneView` belongs to its ``SessionController`` for the session's whole
/// life (the registry keeps both) and is only ever reparented, so a
/// container can host any number of them and move them around without
/// losing terminal state.
@MainActor
final class PaneView: NSView {
    let controller: SessionController
    /// Asked to close this pane (the placeholder's Close Pane button).
    var onClosePane: (() -> Void)?
    /// The placeholder's Retry button on an unavailable session.
    var onRetryPersistence: (() -> Void)?
    /// The name shown in the placeholder.
    var titleProvider: () -> String = { "Shell" }

    /// How the pane shows focus: nothing while it is the only pane on
    /// screen; with several, the focused one gets a subtle accent border and
    /// the others dim slightly.
    enum FocusStyle: Equatable {
        case alone, focused, unfocused
    }

    var focusStyle: FocusStyle = .alone {
        didSet { if focusStyle != oldValue { updateFocusOverlay() } }
    }

    private var placeholder: NSHostingView<SessionPlaceholderView>?
    private let focusOverlay = PassThroughView()
    private var stateObservation: Task<Void, Never>?
    private var fontObservation: Task<Void, Never>?

    /// Space between the pane's edge and the text, filled with the theme's
    /// background. The bottom and sides are deep enough that the first glyph
    /// of the last row clears the window's rounded corner when the sidebar
    /// is collapsed.
    private static let padding = NSEdgeInsets(top: 4, left: 10, bottom: 10, right: 10)

    init(controller: SessionController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        let terminal = controller.surface.view
        let padding = Self.padding
        terminal.frame = NSRect(
            x: padding.left, y: padding.bottom,
            width: bounds.width - padding.left - padding.right,
            height: bounds.height - padding.top - padding.bottom)
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        focusOverlay.frame = bounds
        focusOverlay.autoresizingMask = [.width, .height]
        focusOverlay.wantsLayer = true
        addSubview(focusOverlay)
        observeState()
        observeFontSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        stateObservation?.cancel()
        fontObservation?.cancel()
    }

    /// Makes the terminal the window's first responder.
    func focusTerminal() {
        guard let window, window.firstResponder !== controller.surface.view else { return }
        window.makeFirstResponder(controller.surface.view)
    }

    /// Whether the terminal (or anything inside this pane) is first responder.
    var containsFirstResponder: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    /// A click on the padding around the terminal focuses it too.
    override func mouseDown(with event: NSEvent) {
        focusTerminal()
    }

    private func updateFocusOverlay() {
        guard let layer = focusOverlay.layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            switch focusStyle {
            case .alone:
                layer.borderWidth = 0
                layer.backgroundColor = nil
            case .focused:
                layer.borderWidth = 1.5
                layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
                layer.backgroundColor = nil
            case .unfocused:
                layer.borderWidth = 0
                layer.backgroundColor = NSColor.black.withAlphaComponent(isDark ? 0.22 : 0.07).cgColor
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { applyAppearance() }
    }

    private func applyAppearance() {
        updateFocusOverlay()
        let appearance = TerminalPreferences.shared.terminalAppearance(for: effectiveAppearance)
        controller.surface.apply(appearance)
        let background = appearance.theme.background
        layer?.backgroundColor = CGColor(
            srgbRed: CGFloat(background.red) / 255, green: CGFloat(background.green) / 255,
            blue: CGFloat(background.blue) / 255, alpha: 1)
    }

    private func observeState() {
        let controller = controller
        stateObservation = Task { [weak self] in
            let changes = Observations { PlaceholderState(state: controller.state, failure: controller.failure) }
            for await change in changes {
                self?.update(state: change.state, failure: change.failure)
            }
        }
    }

    /// ⌘= / ⌘- / ⌘0 apply to every pane, shown or not.
    private func observeFontSize() {
        let preferences = TerminalPreferences.shared
        fontObservation = Task { [weak self] in
            var last: Double?
            for await size in Observations({ preferences.fontSize }) {
                guard let self else { return }
                if last != nil, last != size { self.applyAppearance() }
                last = size
            }
        }
    }

    private struct PlaceholderState: Equatable, Sendable {
        var state: SessionState
        var failure: String?
    }

    private func update(state: SessionState, failure: String?) {
        let kind: SessionPlaceholderView.Kind
        switch state {
        case .ended: kind = .ended
        case .disconnected: kind = .disconnected
        case .unavailable: kind = .unavailable
        case .detached, .attaching, .attached:
            placeholder?.removeFromSuperview()
            placeholder = nil
            return
        }
        let view = SessionPlaceholderView(
            kind: kind,
            title: titleProvider(),
            failure: failure,
            primary: { [weak self] in
                guard let self else { return }
                switch kind {
                case .ended: Task { await self.controller.respawn() }
                case .disconnected: Task { await self.controller.reconnect() }
                case .unavailable: self.onRetryPersistence?()
                }
                self.focusTerminal()
            },
            closePane: { [weak self] in self?.onClosePane?() })
        if let placeholder {
            placeholder.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = bounds
            hosting.autoresizingMask = [.width, .height]
            addSubview(hosting, positioned: .below, relativeTo: focusOverlay)
            placeholder = hosting
        }
    }
}

/// A view that draws but never takes mouse events, so clicks reach the
/// terminal below it.
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
