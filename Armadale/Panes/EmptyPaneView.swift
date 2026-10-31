import AppKit
import ArmadaleCore
import SwiftUI
import TerminalSurface

/// An empty pane (no session yet), drawn as a card like a ``PaneView``
/// (DESIGN §8, "Pane cards"): a header with no glyph and the title "New
/// Session", and below it the New Session chooser (``NewSessionPaneView``)
/// over the terminal theme's background, with the same borders. Owned by the content controller,
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
    /// The pane's own theme (DESIGN §8, "Pane context menu"): its
    /// background, and ``paneMenu()``'s check mark.
    private let theme: PaneThemeBinding
    private let hosting: NSHostingView<NewSessionPaneView>
    /// Draws the card's border (``PaneCardStyle/border(for:foreground:)``); never takes the mouse.
    let focusOverlay = PassThroughView()
    /// The card's header row.
    let header = PaneHeaderHostingView.make(model: .newSession)
    private var appearanceObservation: Task<Void, Never>?

    /// How the pane shows focus, as ``PaneView/focusStyle``.
    var focusStyle: PaneView.FocusStyle = .alone {
        didSet {
            guard focusStyle != oldValue else { return }
            chooser.isKeyTarget = focusStyle != .unfocused
            updateFocusOverlay()
        }
    }

    init(chooser: NewSessionChooser, settings: AppSettings, theme: PaneThemeBinding = .detached) {
        self.chooser = chooser
        self.settings = settings
        self.theme = theme
        hosting = NSHostingView(rootView: NewSessionPaneView(chooser: chooser))
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        hosting.frame = PaneCardStyle.contentFrame(in: bounds)
        hosting.autoresizingMask = [.width, .height]
        hosting.sizingOptions = []
        addSubview(hosting)
        hosting.rootView = NewSessionPaneView(chooser: chooser) { [weak self] in self?.focusPane() }
        header.frame = PaneCardStyle.headerFrame(in: bounds)
        header.autoresizingMask = [.width, .minYMargin]
        header.focusPane = { [weak self] in self?.focusPane() }
        header.makeMenu = { [weak self] in self?.paneMenu() }
        addSubview(header)
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
    /// lands here through the chooser's clear background (its tap gesture),
    /// and a click on the header through the header; the two cover the
    /// whole pane, so the pane itself never sees a mouse down.
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

    // MARK: Context menu

    /// The pane's context menu, as ``PaneView/paneMenu()``: built fresh
    /// each time, opened from the header (DESIGN §8, "Pane cards").
    func paneMenu() -> NSMenu {
        let theme = theme
        return PaneMenu.make(
            PaneMenu.Inputs(themeID: theme.current(), catalog: settings.themes),
            actions: PaneMenu.Actions(
                splitRight: { theme.split(.horizontal) },
                splitDown: { theme.split(.vertical) },
                chooseTheme: { theme.choose($0) }))
    }

    // MARK: Appearance

    /// The card's corners, background and border for the current theme
    /// and focus style.
    private func updateFocusOverlay() {
        let cardTheme = settings.terminalAppearance(for: effectiveAppearance, paneThemeID: theme.current()).theme
        PaneCardStyle.apply(to: self, overlay: focusOverlay, style: focusStyle, theme: cardTheme)
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
    /// terminals like one of them, and its foreground in the header.
    private func applyAppearance() {
        let paneThemeID = theme.current()
        matchAppearance(toPaneTheme: settings.paneTheme(paneThemeID))
        let cardTheme = settings.terminalAppearance(for: effectiveAppearance, paneThemeID: paneThemeID).theme
        PaneCardStyle.apply(to: self, overlay: focusOverlay, style: focusStyle, theme: cardTheme)
        var model = PaneHeaderModel.newSession
        model.foreground = cardTheme.foreground
        header.model = model
    }

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
}
