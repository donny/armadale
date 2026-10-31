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

    private let terminalView: HostTerminalView
    private let bridge: DelegateBridge
    /// The appearance last applied.
    public private(set) var appearance: TerminalAppearance
    private var oscObservation: TerminalOscObservation?
    /// The cursor style last pushed to the terminal. Re-applying the same
    /// appearance (a tab switch, a theme change) must not override the
    /// style the program chose with DECSCUSR, e.g. vim's insert-mode bar.
    private var appliedCursor: TerminalCursorStyle?

    /// Creates a surface with `appearance` applied.
    public init(appearance: TerminalAppearance = .default) {
        terminalView = HostTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
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

    public func feed(_ bytes: ArraySlice<UInt8>) {
        terminalView.feed(byteArray: bytes)
    }

    public func apply(_ appearance: TerminalAppearance) {
        self.appearance = appearance
        let size = CGFloat(appearance.fontSize)
        terminalView.font = NSFont(name: appearance.fontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)

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

/// SwiftTerm's view with the host's context-menu rules (DESIGN §8, "Pane
/// context menu"; ``TerminalSurface``'s contract):
///
/// - **Shift + right-click** is never reported to the program, even one that
///   asked to see Shift with the mouse (XTSHIFTESCAPE, which SwiftTerm's own
///   Shift bypass honours): it goes straight to the next responder, the
///   host's pane view, which opens its menu.
/// - **Control-click** (without Command) is a right-click, as everywhere on
///   macOS: the press, drags and release are handed on as right-button
///   events without the Control flag, so a program that asked for the
///   mouse gets a right button, and otherwise the next responder gets the
///   right-click. A click with Command held stays SwiftTerm's (⌘-click
///   opens a link). The rules are ``ContextClick``'s, in `TerminalSurface`.
///
/// Every other event is SwiftTerm's: a right-click goes to a program that
/// asked for the mouse, and otherwise (SwiftTerm calls `super`, and NSView
/// passes a right-click it has no menu for up the responder chain) to the
/// pane.
final class HostTerminalView: TerminalView {
    /// Whether the left-button press under way began as a Control-click,
    /// so its drags and release are right-button events too.
    private var pressIsSecondaryClick = false

    override func rightMouseDown(with event: NSEvent) {
        if ContextClick.bypassesProgram(event.modifierFlags) {
            nextResponder?.rightMouseDown(with: event)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if ContextClick.bypassesProgram(event.modifierFlags) {
            nextResponder?.rightMouseUp(with: event)
        } else {
            super.rightMouseUp(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressIsSecondaryClick = ContextClick.isSecondaryClick(event.modifierFlags)
        guard pressIsSecondaryClick, let right = ContextClick.rightButtonEvent(.rightMouseDown, from: event) else {
            pressIsSecondaryClick = false
            return super.mouseDown(with: event)
        }
        rightMouseDown(with: right)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressIsSecondaryClick, let right = ContextClick.rightButtonEvent(.rightMouseDragged, from: event) else {
            return super.mouseDragged(with: event)
        }
        rightMouseDragged(with: right)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressIsSecondaryClick else { return super.mouseUp(with: event) }
        pressIsSecondaryClick = false
        guard let right = ContextClick.rightButtonEvent(.rightMouseUp, from: event) else { return }
        rightMouseUp(with: right)
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
