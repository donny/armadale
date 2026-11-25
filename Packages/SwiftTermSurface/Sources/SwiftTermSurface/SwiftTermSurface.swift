import AppKit
@preconcurrency internal import SwiftTerm
import TerminalSurface

/// A ``TerminalSurface`` backed by SwiftTerm's `TerminalView`.
///
/// Uses the plain `TerminalView`, not `LocalProcessTerminalView`: Armadale
/// owns the PTY, so output arrives through ``feed(_:)`` and keyboard input
/// leaves through the delegate. SwiftTerm is imported `internal` so none of
/// its types leak into this module's API, and it is confined to the main
/// actor by this class.
@MainActor
public final class SwiftTermSurface: TerminalSurface {
    public weak var delegate: (any TerminalSurfaceDelegate)?

    private let terminalView: SnapshotTerminalView
    private let bridge: DelegateBridge
    /// The appearance last applied.
    public private(set) var appearance: TerminalAppearance
    private var oscObservation: TerminalOscObservation?
    /// The cursor style last pushed to the terminal. Re-applying the same
    /// appearance (a tab switch, a theme change) must not override the
    /// style the program chose with DECSCUSR, e.g. vim's insert-mode bar.
    private var appliedCursor: TerminalCursorStyle?
    /// The font name and size last set on the view. SwiftTerm's `font`
    /// setter recomputes the grid and resizes the terminal, and its
    /// `resize(cols:rows:)` ends in `terminal.softReset()` (SwiftTerm 1.99.0,
    /// `AppleTerminalView.resize(cols:rows:)` → `Terminal.cmdSoftReset`):
    /// the program's application cursor keys, keypad mode, hidden cursor,
    /// scroll region, origin mode and attributes are reset. So the font is
    /// set only when it changes, never when the same appearance is applied
    /// again (a tab switch, a split, a zoom) or only the theme changes.
    private var appliedFont: (name: String, size: Double)?

    /// Creates a surface with `appearance` applied.
    public init(appearance: TerminalAppearance = .default) {
        terminalView = SnapshotTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        bridge = DelegateBridge()
        self.appearance = appearance
        bridge.owner = self
        terminalView.terminalDelegate = bridge
        apply(appearance)
        observeNotifications()
    }

    public var view: NSView { terminalView }

    /// Identifier of this renderer in a ``SurfaceRegistry`` (and in
    /// preferences).
    public static let rendererID = "swiftterm"

    /// The factory that registers this renderer.
    public static var factory: SurfaceFactory {
        SurfaceFactory(id: rendererID, displayName: "SwiftTerm") { SwiftTermSurface(appearance: $0) }
    }

    /// Grid size with SwiftTerm's own cell dimensions. SwiftTerm does not
    /// expose its cell size directly, but `getOptimalFrameSize()` is exactly
    /// `cell × cols (+ a legacy scroller's width)` by `cell × rows`, using the
    /// same pixel-snapped, line-spacing-adjusted cell it lays out with.
    public var gridSize: GridSize {
        let dimensions = terminalView.terminalDimensions
        guard dimensions.cols > 0, dimensions.rows > 0 else {
            return GridSize(columns: dimensions.cols, rows: dimensions.rows)
        }
        let optimal = terminalView.getOptimalFrameSize()
        let textWidth = optimal.width - reservedScrollerWidth
        return GridSize(
            columns: dimensions.cols,
            rows: dimensions.rows,
            cellWidth: Double(textWidth) / Double(dimensions.cols),
            cellHeight: Double(optimal.height) / Double(dimensions.rows))
    }

    /// Mirrors SwiftTerm's private `reservedScrollerWidth`: only a visible
    /// legacy-style scroller takes horizontal space.
    private var reservedScrollerWidth: CGFloat {
        guard terminalView.scrollerStyle == .legacy,
              terminalView.subviews.contains(where: { $0 is NSScroller && !$0.isHidden })
        else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    /// Gives the view the size of `columns` × `rows` cells (plus a legacy
    /// scroller's width), which SwiftTerm turns back into that grid
    /// (`processSizeChange` divides the frame by the cell and truncates, so
    /// half a point is added to stay clear of rounding). SwiftTerm's own
    /// `resize(cols:rows:)` is not used: it ends in a soft reset and leaves
    /// the frame alone, so the next layout would size the grid back. The
    /// cell is the one SwiftTerm measured when the font was set (snapped to
    /// the backing scale of the window or, outside one, the main screen) and
    /// does not change when the view enters a window, so the grid stays.
    public func setGridSize(columns: Int, rows: Int) {
        let current = gridSize
        guard columns > 0, rows > 0, current.columns > 0, current.rows > 0,
              current.columns != columns || current.rows != rows
        else { return }
        // The current grid's cell, exactly as SwiftTerm lays it out.
        let cellWidth = CGFloat(current.cellWidth), cellHeight = CGFloat(current.cellHeight)
        guard cellWidth > 0, cellHeight > 0 else { return }
        terminalView.setFrameSize(NSSize(
            width: cellWidth * CGFloat(columns) + reservedScrollerWidth + 0.5,
            height: cellHeight * CGFloat(rows) + 0.5))
    }

    public func feed(_ bytes: ArraySlice<UInt8>) {
        terminalView.feed(byteArray: bytes)
    }

    public func apply(_ appearance: TerminalAppearance) {
        self.appearance = appearance
        if appliedFont?.name != appearance.fontName || appliedFont?.size != appearance.fontSize {
            appliedFont = (appearance.fontName, appearance.fontSize)
            let size = CGFloat(appearance.fontSize)
            terminalView.font = NSFont(name: appearance.fontName, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }

        // The colours and the cursor style soft-reset nothing (SwiftTerm
        // 1.99.0: `installColors` installs the palette, which does replace a
        // palette the program set with OSC 4 (`installPalette` sets
        // `ansiColors = defaultAnsiColors`); the native colours and
        // `caretColor` only redraw; `setCursorStyle` sets the renderer's style).

        let theme = appearance.theme
        terminalView.installColors(theme.ansi.map(Self.swiftTermColor))
        terminalView.nativeForegroundColor = Self.nsColor(theme.foreground)
        terminalView.nativeBackgroundColor = Self.nsColor(theme.background)
        terminalView.caretColor = Self.nsColor(theme.cursor)
        terminalView.selectedTextBackgroundColor = Self.nsColor(theme.selection)
        if appliedCursor != appearance.cursor {
            appliedCursor = appearance.cursor
            terminalView.setCursorStyle(Self.swiftTermCursor(appearance.cursor))
        }
    }

    /// The terminal's current cursor style, as DECSCUSR's parameter
    /// (1/2 block, 3/4 underline, 5/6 bar; odd blinks). Internal, for tests.
    var cursorStyleParameter: Int {
        switch terminalView.terminalStateSnapshot().cursorStyle {
        case .blinkBlock: 1
        case .steadyBlock: 2
        case .blinkUnderline: 3
        case .steadyUnderline: 4
        case .blinkBar: 5
        case .steadyBar: 6
        }
    }

    public func clearScrollback() {
        terminalView.clearScrollback()
    }

    public func scrollToBottom() {
        terminalView.scroll(toPosition: 1)
    }

    public func find(_ query: String, direction: FindDirection) {
        switch direction {
        case .next: _ = terminalView.findNext(query)
        case .previous: _ = terminalView.findPrevious(query)
        }
    }

    public var selectedText: String? {
        terminalView.getSelection()
    }

    /// The live screen as bytes for a fresh terminal (``TerminalSurface/screenSnapshot()``).
    /// The view scrolls to the bottom first, then the terminal is asked for
    /// the modes it keeps internal (DECRQM for 25, 6, 7 and 5; the answers
    /// never reach the program) and read, through SwiftTerm's public API,
    /// while it answers (``SnapshotTerminalView``). SwiftTerm parses and
    /// answers on the feeding thread, so the reading is always there; were
    /// it not, nothing would be given (an empty snapshot).
    public func screenSnapshot() -> [UInt8] {
        scrollToBottom()
        let box = ReadingBox<ScreenReading>()
        let answers = terminalView.answers(to: SnapshotModes.queries) { terminal in
            let reading = ScreenReading.read(terminal)
            box.value.withLock { $0 = reading }
        }
        guard let reading = box.value.withLock({ $0 }) else { return [] }
        return reading.bytes(modes: SnapshotModes(answers: answers))
    }

    /// Runs `body` with the terminal (through a DECRQM answer, as
    /// ``screenSnapshot()`` does). Internal, for tests.
    func withTerminal<Value: Sendable>(_ body: @escaping @Sendable (Terminal) -> Value) -> Value? {
        let box = ReadingBox<Value>()
        _ = terminalView.answers(to: Array("\u{1b}[?25$p".utf8)) { terminal in
            let value = body(terminal)
            box.value.withLock { $0 = value }
        }
        return box.value.withLock { $0 }
    }

    /// The modes ``screenSnapshot()`` asks for, answered now. Internal, for tests.
    func currentModes() -> SnapshotModes {
        SnapshotModes(answers: terminalView.answers(to: SnapshotModes.queries))
    }

    /// The text of the rows on view, from the view's public state, without
    /// feeding the terminal anything (``screenState()`` asks it a query,
    /// which would cut short a sequence the program left unfinished).
    /// Internal, for tests.
    func visibleText() -> [String] {
        terminalView.terminalStateSnapshot().visibleRows.map(\.text)
    }

    /// Scrolls the view to the top of its scrollback. Internal, for tests.
    func scrollToTop() {
        terminalView.scroll(toPosition: 0)
    }

    // MARK: Delegate forwarding

    fileprivate func forwardInput(_ data: ArraySlice<UInt8>) {
        delegate?.surface(self, didInput: Array(data))
    }

    fileprivate func forwardResize() {
        delegate?.surface(self, didResize: gridSize)
    }

    fileprivate func forwardTitle(_ title: String) {
        delegate?.surface(self, didSetTitle: title)
    }

    fileprivate func forwardDirectory(_ directory: String?) {
        guard let directory, let url = Self.directoryURL(directory) else { return }
        delegate?.surface(self, didChangeDirectory: url)
    }

    fileprivate func forwardBell() {
        delegate?.surfaceDidRingBell(self)
    }

    fileprivate func forwardClipboard(_ op: ClipboardOp) {
        delegate?.surface(self, didRequestClipboard: op)
    }

    fileprivate func forwardLink(_ link: String) {
        delegate?.surface(self, didActivateLink: link)
    }

    /// Invokes the SwiftTerm delegate callback for a link click, as
    /// SwiftTerm does. Internal, for tests.
    func simulateLinkActivation(_ link: String) {
        bridge.requestOpenLink(source: terminalView, link: link, params: [:])
    }

    /// OSC 9 and OSC 777 are not surfaced by `TerminalView`; observe them
    /// passively and hop to the main actor.
    private func observeNotifications() {
        oscObservation = terminalView.observeOscEvents { [weak self] event in
            guard let notification = Self.notification(from: event.code, payload: event.payload) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.surface(self, didReceiveNotification: notification.title, body: notification.body)
            }
        }
    }

    // MARK: Conversions

    /// Parses OSC 9 (`9;text`) and OSC 777 (`777;notify;title;body`).
    /// ConEmu's OSC 9 extensions are not notifications: their payload is a
    /// number, alone or before a `;` (`9;4;st;pr` progress, `9;9;path`
    /// working directory, `9;1;ms` sleep, …), so such payloads and empty
    /// ones are ignored; only plain text is a notification.
    nonisolated static func notification(from code: Int, payload: [UInt8]) -> (title: String, body: String)? {
        let text = String(decoding: payload, as: UTF8.self)
        switch code {
        case 9:
            let first = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            if text.isEmpty || (!first.isEmpty && first.allSatisfy({ $0.isASCII && $0.isNumber })) { return nil }
            return ("", text)
        case 777:
            let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, parts[0] == "notify" else { return nil }
            return (String(parts[1]), parts.count > 2 ? String(parts[2]) : "")
        default:
            return nil
        }
    }

    /// OSC 7 reports `file://host/path`; accept a bare path too.
    nonisolated static func directoryURL(_ string: String) -> URL? {
        if let url = URL(string: string), url.isFileURL { return url }
        guard string.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: string, isDirectory: true)
    }

    private static func nsColor(_ color: TerminalColor) -> NSColor {
        NSColor(
            srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255, alpha: 1)
    }

    private static func swiftTermColor(_ color: TerminalColor) -> SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16(color.red), green8: UInt16(color.green), blue8: UInt16(color.blue))
    }

    private static func swiftTermCursor(_ style: TerminalCursorStyle) -> SwiftTerm.CursorStyle {
        switch (style.shape, style.blinks) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        }
    }
}

/// Receives SwiftTerm's delegate calls and forwards them to the surface.
/// Kept separate so `TerminalViewDelegate` is not part of the public API.
@MainActor
private final class DelegateBridge: TerminalViewDelegate {
    weak var owner: SwiftTermSurface?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        owner?.forwardResize()
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        owner?.forwardTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        owner?.forwardDirectory(directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        owner?.forwardInput(data)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func bell(source: TerminalView) {
        owner?.forwardBell()
    }

    /// Overrides SwiftTerm's default, which opens the link with NSWorkspace.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        owner?.forwardLink(link)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        owner?.forwardClipboard(.write(String(decoding: content, as: UTF8.self)))
    }

    func clipboardRead(source: TerminalView) -> Data? {
        owner?.forwardClipboard(.readRequested)
        return nil
    }
}
