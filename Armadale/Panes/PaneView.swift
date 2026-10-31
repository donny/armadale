import AppKit
import ArmadaleCore
import ArmadaleSessions
import SwiftUI
import TerminalSurface

/// One pane: the session's terminal view filling it, and the *Session
/// Ended* placeholder over it once the session is over. A right-click in it
/// opens the pane's context menu (``PaneMenu``).
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
    /// The pane's own theme, which overrides the Settings choice
    /// (DESIGN §8, "Pane context menu").
    let theme: PaneThemeBinding
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
        didSet {
            guard focusStyle != oldValue else { return }
            updateFocusOverlay()
            // Return presses the placeholder's button only in the focused pane.
            if placeholder != nil, let lastPlaceholderState { update(lastPlaceholderState) }
        }
    }
    private var lastPlaceholderState: PlaceholderState?

    private var placeholder: NSHostingView<SessionPlaceholderView>?
    /// The placeholder's primary button (Respawn, Reconnect, Retry), which
    /// Return presses while the pane has keyboard focus; `nil` without a
    /// placeholder or when it has no such button.
    private var primaryAction: (() -> Void)?
    private let focusOverlay = PassThroughView()
    private var stateObservation: Task<Void, Never>?
    private var appearanceObservation: Task<Void, Never>?

    /// Space between the pane's edge and the text, filled with the theme's
    /// background. The bottom and sides are deep enough that the first glyph
    /// of the last row clears the window's rounded corner when the sidebar
    /// is collapsed.
    private static let padding = NSEdgeInsets(top: 4, left: 10, bottom: 10, right: 10)

    init(controller: SessionController, settings: AppSettings, rendererID: String, theme: PaneThemeBinding = .detached) {
        self.controller = controller
        self.settings = settings
        self.theme = theme
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
        let theme = theme
        controller.replaceSurfaceOnNextAttach {
            // The pane applies its own appearance once the surface is in.
            factory.makeSurface(appearance: settings.terminalAppearance(
                for: NSApp.effectiveAppearance, paneThemeID: theme.current()))
        }
    }

    /// The controller replaced its surface: show the new one where the old
    /// one was, keeping keyboard focus.
    func surfaceWasReplaced(_ old: any TerminalSurface) {
        let hadFocus = window.map { $0.firstResponder === old.view || $0.firstResponder === self } ?? false
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

    /// Gives the pane keyboard focus: the terminal, or the pane itself
    /// while a placeholder is shown (the session's terminal is dead then,
    /// and would swallow Return; see ``keyDown(with:)``).
    func focusTerminal() {
        guard let window else { return }
        let target: NSView = placeholder != nil ? self : controller.surface.view
        guard window.firstResponder !== target else { return }
        window.makeFirstResponder(target)
    }

    /// Only while a placeholder is shown: the pane then holds keyboard
    /// focus instead of its terminal.
    override var acceptsFirstResponder: Bool { placeholder != nil }

    /// While a placeholder is shown (the pane is first responder), Return
    /// or keypad Enter presses its primary button, unless another pane of
    /// a split is the focused one (DESIGN §4, "Ended"). Every other key is
    /// ignored: nothing runs in the pane to receive it. Key equivalents
    /// (menu shortcuts) never get here.
    override func keyDown(with event: NSEvent) {
        guard placeholder != nil else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard Self.isReturn(event.keyCode), modifiers.isEmpty, !event.isARepeat,
              focusStyle != .unfocused, let primaryAction
        else { return }
        primaryAction()
    }

    /// Return (36) or keypad Enter (76).
    private static func isReturn(_ keyCode: UInt16) -> Bool {
        keyCode == 36 || keyCode == 76
    }

    /// Whether the terminal (or anything inside this pane) is first responder.
    var containsFirstResponder: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    /// A click on the padding around the terminal focuses it too; a
    /// Control-click there is a right-click.
    override func mouseDown(with event: NSEvent) {
        if ContextClick.isSecondaryClick(event) { return showMenu(for: event) }
        focusTerminal()
    }

    // MARK: Context menu

    /// A right-click on the padding, on the placeholder, or on the terminal
    /// when the program did not take it (the terminal view passes it up the
    /// responder chain, Shift + right-click always; ``TerminalSurface``):
    /// the pane takes keyboard focus, as a click would, and shows its menu.
    override func rightMouseDown(with event: NSEvent) {
        showMenu(for: event)
    }

    private func showMenu(for event: NSEvent) {
        focusTerminal()
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// The pane's context menu, built fresh each time from the pane's
    /// theme and the theme catalog.
    override func menu(for event: NSEvent) -> NSMenu? {
        let theme = theme
        return PaneMenu.make(
            PaneMenu.Inputs(themeID: theme.current(), catalog: settings.themes),
            actions: PaneMenu.Actions(chooseTheme: { theme.choose($0) }))
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
        let paneThemeID = theme.current()
        matchAppearance(toPaneTheme: settings.paneTheme(paneThemeID))
        updateFocusOverlay()
        let appearance = settings.terminalAppearance(for: effectiveAppearance, paneThemeID: paneThemeID)
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
    /// cursor) and the pane's own theme apply at once to every pane, shown
    /// or not.
    private func observeAppearance() {
        let settings = settings
        let theme = theme
        appearanceObservation = Task { [weak self] in
            var last: PaneAppearanceChange?
            for await change in Observations({
                PaneAppearanceChange(settings: settings.appearanceChange, paneThemeID: theme.current())
            }) {
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
        lastPlaceholderState = change
        let failure = change.failure
        let kind: SessionPlaceholderView.Kind
        var exitStatus: ProgramExit?
        switch change.state {
        case .ended(let code):
            kind = .ended
            exitStatus = code
        case .disconnected: kind = change.isReconnecting ? .reconnecting : .disconnected
        case .unavailable(let reason): kind = reason == SessionRegistry.hostRemovedReason ? .hostRemoved : .unavailable
        case .detached, .attaching, .attached:
            guard let shown = placeholder else { return }
            shown.removeFromSuperview()
            placeholder = nil
            primaryAction = nil
            // The terminal is live again: keyboard focus goes back to it.
            if let window, window.firstResponder === self { window.makeFirstResponder(controller.surface.view) }
            return
        }
        let primary: () -> Void = { [weak self] in
            guard let self else { return }
            switch kind {
            case .ended: Task { await self.controller.respawn() }
            case .disconnected, .reconnecting: Task { await self.controller.reconnect() }
            case .unavailable, .hostRemoved: self.onRetryPersistence?()
            }
            self.focusTerminal()
        }
        // Return reaches `keyDown` (the pane holds keyboard focus while the
        // placeholder is shown). The button keeps its default-action
        // shortcut for its look; a key equivalent that is handled never
        // reaches `keyDown`, so the action runs once either way.
        primaryAction = kind == .hostRemoved ? nil : primary
        let view = SessionPlaceholderView(
            kind: kind,
            title: titleProvider(),
            failure: failure,
            exitStatus: exitStatus,
            isDefaultActionEnabled: focusStyle != .unfocused,
            primary: primary,
            closePane: { [weak self] in self?.onClosePane?() },
            focusPane: { [weak self] in self?.focusTerminal() })
        if let placeholder {
            placeholder.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = bounds
            hosting.autoresizingMask = [.width, .height]
            addSubview(hosting, positioned: .below, relativeTo: focusOverlay)
            placeholder = hosting
            // The dead terminal had keyboard focus: the pane takes it, so
            // Return reaches ``keyDown(with:)``.
            if let window, window.firstResponder === controller.surface.view { window.makeFirstResponder(self) }
        }
    }
}

extension NSView {
    /// A pane with its own theme draws its controls (the *Session Ended*
    /// placeholder, the New Session chooser) in the system appearance that
    /// suits the theme's background, dark or light, so a light theme in dark
    /// mode does not get a dark card with faded text; without one the pane
    /// follows the window (DESIGN §8, "Pane context menu"). Only set when it
    /// changes: setting it re-applies the pane's appearance.
    func matchAppearance(toPaneTheme theme: TerminalTheme?) {
        let wanted = theme.flatMap { NSAppearance(named: $0.background.luminance < 0.4 ? .darkAqua : .aqua) }
        if appearance?.name != wanted?.name { appearance = wanted }
    }
}

/// What a pane's appearance is made from: the app's settings and the
/// pane's own theme. Re-applied when it changes.
struct PaneAppearanceChange: Hashable, Sendable {
    var settings: AppSettings.AppearanceChange
    var paneThemeID: String?
}

/// A view that draws but never takes mouse events, so clicks reach the
/// terminal below it.
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
