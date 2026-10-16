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

    private var placeholder: NSHostingView<SessionPlaceholderView>?
    private var stateObservation: Task<Void, Never>?

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
        observeState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        stateObservation?.cancel()
    }

    /// Makes the terminal the window's first responder.
    func focusTerminal() {
        guard let window else { return }
        window.makeFirstResponder(controller.surface.view)
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
        let appearance = DefaultTheme.appearance(for: effectiveAppearance)
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
            addSubview(hosting, positioned: .above, relativeTo: controller.surface.view)
            placeholder = hosting
        }
    }
}
