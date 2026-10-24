import AppKit
import ArmadaleCore
import SwiftUI

/// An empty pane (no session yet): the New Session chooser
/// (``NewSessionPaneView``) over the terminal theme's background, with the
/// same focus border as a ``PaneView``. Owned by the content controller,
/// one per empty pane on screen, and dropped once the pane has a session or
/// is no longer shown.
///
/// Like a pane showing a placeholder, the pane itself holds keyboard focus
/// while it is the focused pane (DESIGN §8, "New sessions"): ↓ and ↑ move
/// the chooser's selection, Return (or keypad Enter) starts the selected
/// favorite or opens the New Session dialog, and Escape closes the pane;
/// Return and Escape only when this is the focused pane of a split, or the
/// only pane on screen. Every other key is ignored. Key equivalents (menu
/// shortcuts) never get here.
@MainActor
final class EmptyPaneView: NSView {
    let chooser: NewSessionChooser
    private let settings: AppSettings
    private let hosting: NSHostingView<NewSessionPaneView>
    private let focusOverlay = PassThroughView()
    private var appearanceObservation: Task<Void, Never>?

    /// How the pane shows focus, as ``PaneView/focusStyle``.
    var focusStyle: PaneView.FocusStyle = .alone {
        didSet {
            guard focusStyle != oldValue else { return }
            chooser.isKeyTarget = focusStyle != .unfocused
            updateFocusOverlay()
        }
    }

    init(chooser: NewSessionChooser, settings: AppSettings) {
        self.chooser = chooser
        self.settings = settings
        hosting = NSHostingView(rootView: NewSessionPaneView(chooser: chooser))
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.sizingOptions = []
        addSubview(hosting)
        hosting.rootView = NewSessionPaneView(chooser: chooser) { [weak self] in self?.focusPane() }
        focusOverlay.frame = bounds
        focusOverlay.autoresizingMask = [.width, .height]
        focusOverlay.wantsLayer = true
        addSubview(focusOverlay)
        observeAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        appearanceObservation?.cancel()
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }

    /// Gives the pane keyboard focus. A click on the pane outside the card
    /// lands here through the chooser's clear background (its tap gesture);
    /// the hosting view covers the whole pane, so the pane itself never
    /// sees a mouse down.
    func focusPane() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard modifiers.isEmpty, let key = Self.key(for: event.keyCode) else { return }
        // Return and Escape do one thing per press; arrows may repeat.
        if event.isARepeat, key == .confirm || key == .cancel { return }
        chooser.handle(key)
    }

    /// The chooser's key for a key code: ↑ (126), ↓ (125), Return (36) or
    /// keypad Enter (76), Escape (53).
    static func key(for keyCode: UInt16) -> NewSessionChooser.Key? {
        switch keyCode {
        case 126: .up
        case 125: .down
        case 36, 76: .confirm
        case 53: .cancel
        default: nil
        }
    }

    // MARK: Appearance

    private func updateFocusOverlay() {
        guard let layer = focusOverlay.layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
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

    /// The terminal theme's background, so an empty pane sits among
    /// terminals like one of them.
    private func applyAppearance() {
        updateFocusOverlay()
        let background = settings.terminalAppearance(for: effectiveAppearance).theme.background
        layer?.backgroundColor = CGColor(
            srgbRed: CGFloat(background.red) / 255, green: CGFloat(background.green) / 255,
            blue: CGFloat(background.blue) / 255, alpha: 1)
    }

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
}
