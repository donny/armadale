import AppKit
import ArmadaleSessions
import SwiftUI
import TerminalSurface

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
    /// Where the terminal's appearance comes from.
    let settings: AppSettings
    /// The renderer of the surface shown (``SurfaceFactory/id``).
    private(set) var rendererID: String
    /// The renderer the surface is replaced by at the next attach, if any.
    private(set) var pendingRendererID: String?
    /// Asked to close this pane (the placeholder's Close Pane button).
    var onClosePane: (() -> Void)?
    /// The placeholder's Retry button on an unavailable session.
    var onRetryPersistence: (() -> Void)?
    /// The name shown in the placeholder.
    var titleProvider: () -> String = { "Shell" }

    /// How the pane shows focus: nothing while it is the only pane on
    /// screen; with several, the focused one gets a subtle accent border.
    /// The others are left alone: their terminal keeps its own background
    /// (an earlier dimming overlay was dropped on October 23, 2026).
    enum FocusStyle: Equatable {
        case alone, focused, unfocused
    }

    var focusStyle: FocusStyle = .alone {
        didSet { if focusStyle != oldValue { updateFocusOverlay() } }
    }

    private var placeholder: NSHostingView<SessionPlaceholderView>?
    private let focusOverlay = PassThroughView()
    private var stateObservation: Task<Void, Never>?
    private var appearanceObservation: Task<Void, Never>?

    /// Space between the pane's edge and the text, filled with the theme's
    /// background. The bottom and sides are deep enough that the first glyph
    /// of the last row clears the window's rounded corner when the sidebar
    /// is collapsed.
    private static let padding = NSEdgeInsets(top: 4, left: 10, bottom: 10, right: 10)

    init(controller: SessionController, settings: AppSettings, rendererID: String) {
        self.controller = controller
        self.settings = settings
        self.rendererID = rendererID
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        addTerminalView(controller.surface.view)
        focusOverlay.frame = bounds
        focusOverlay.autoresizingMask = [.width, .height]
        focusOverlay.wantsLayer = true
        addSubview(focusOverlay)
        observeState()
        observeAppearance()
    }

    private var terminalFrame: NSRect {
        let padding = Self.padding
        return NSRect(
            x: padding.left, y: padding.bottom,
            width: max(bounds.width - padding.left - padding.right, 0),
            height: max(bounds.height - padding.top - padding.bottom, 0))
    }

    /// Puts a terminal view at the bottom of the pane, inside the padding.
    private func addTerminalView(_ terminal: NSView) {
        terminal.frame = terminalFrame
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal, positioned: .below, relativeTo: subviews.first)
    }

    /// The renderer changed: the surface is replaced by one from `rendererID`
    /// the next time the session attaches (``SessionController/replaceSurfaceOnNextAttach(_:)``),
    /// never under a live terminal. Choosing the current renderer again
    /// cancels a pending replacement.
    func useRenderer(_ factory: SurfaceFactory) {
        guard factory.id != rendererID else {
            pendingRendererID = nil
            controller.replaceSurfaceOnNextAttach(nil)
            return
        }
        pendingRendererID = factory.id
        let settings = settings
        controller.replaceSurfaceOnNextAttach {
            // The pane applies its own appearance once the surface is in.
            factory.makeSurface(appearance: settings.terminalAppearance(for: NSApp.effectiveAppearance))
        }
    }

    /// The controller replaced its surface: show the new one where the old
    /// one was, keeping keyboard focus.
    func surfaceWasReplaced(_ old: any TerminalSurface) {
        let hadFocus = window.map { $0.firstResponder === old.view } ?? false
        old.view.removeFromSuperview()
        addTerminalView(controller.surface.view)
        if let pendingRendererID {
            rendererID = pendingRendererID
            self.pendingRendererID = nil
        }
        applyAppearance()
        if hadFocus { focusTerminal() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        stateObservation?.cancel()
        appearanceObservation?.cancel()
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
            layer.backgroundColor = nil
            switch focusStyle {
            case .alone, .unfocused:
                layer.borderWidth = 0
            case .focused:
                layer.borderWidth = 1.5
                layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
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
        let appearance = settings.terminalAppearance(for: effectiveAppearance)
        controller.surface.apply(appearance)
        let background = appearance.theme.background
        layer?.backgroundColor = CGColor(
            srgbRed: CGFloat(background.red) / 255, green: CGFloat(background.green) / 255,
            blue: CGFloat(background.blue) / 255, alpha: 1)
    }

    private func observeState() {
        let controller = controller
        stateObservation = Task { [weak self] in
            let changes = Observations {
                PlaceholderState(state: controller.state, failure: controller.failure, isReconnecting: controller.isReconnecting)
            }
            for await change in changes {
                self?.update(change)
            }
        }
    }

    /// Every appearance setting (font, size from ⌘= / ⌘- / ⌘0, theme,
    /// cursor) applies at once to every pane, shown or not.
    private func observeAppearance() {
        let settings = settings
        appearanceObservation = Task { [weak self] in
            var last: AppSettings.AppearanceChange?
            for await change in Observations({ settings.appearanceChange }) {
                guard let self else { return }
                if last != nil, last != change { self.applyAppearance() }
                last = change
            }
        }
    }

    private struct PlaceholderState: Equatable, Sendable {
        var state: SessionState
        var failure: String?
        var isReconnecting: Bool
    }

    private func update(_ change: PlaceholderState) {
        let failure = change.failure
        let kind: SessionPlaceholderView.Kind
        switch change.state {
        case .ended: kind = .ended
        case .disconnected: kind = change.isReconnecting ? .reconnecting : .disconnected
        case .unavailable(let reason): kind = reason == SessionRegistry.hostRemovedReason ? .hostRemoved : .unavailable
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
                case .disconnected, .reconnecting: Task { await self.controller.reconnect() }
                case .unavailable, .hostRemoved: self.onRetryPersistence?()
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
