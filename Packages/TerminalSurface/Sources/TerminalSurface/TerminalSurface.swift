import AppKit

/// A terminal renderer. Armadale owns the process and PTY; a surface only
/// turns bytes into pixels and user input into bytes, so renderers can be
/// swapped without touching sessions or layout.
///
/// Surfaces are main-actor confined. Their `view` is reparented (never
/// recreated) when tabs switch or panes move.
@MainActor
public protocol TerminalSurface: AnyObject {
    /// The view to embed in a pane.
    var view: NSView { get }
    /// Receives input, size, title and notification events. Held weakly.
    var delegate: (any TerminalSurfaceDelegate)? { get set }
    /// Current grid size in cells and cell size in points.
    var gridSize: GridSize { get }
    /// Feeds process output to the screen.
    func feed(_ bytes: ArraySlice<UInt8>)
    /// Applies font, colours and cursor.
    func apply(_ appearance: TerminalAppearance)
    /// Discards scrollback, keeping the visible screen.
    func clearScrollback()
    /// Scrolls the viewport to the live bottom.
    func scrollToBottom()
    /// Finds and selects the next or previous match of `query`.
    func find(_ query: String, direction: FindDirection)
    /// The selected text, if any.
    var selectedText: String? { get }
}

/// Events emitted by a ``TerminalSurface``. All calls arrive on the main actor.
@MainActor
public protocol TerminalSurfaceDelegate: AnyObject {
    /// The user typed or pasted; write `bytes` to the process.
    func surface(_ surface: any TerminalSurface, didInput bytes: [UInt8])
    /// The grid changed size; resize the PTY.
    func surface(_ surface: any TerminalSurface, didResize size: GridSize)
    /// The program set the window title (OSC 0/2).
    func surface(_ surface: any TerminalSurface, didSetTitle title: String)
    /// The program reported its working directory (OSC 7).
    func surface(_ surface: any TerminalSurface, didChangeDirectory url: URL)
    /// The program rang the bell (BEL).
    func surfaceDidRingBell(_ surface: any TerminalSurface)
    /// The program asked to use the clipboard (OSC 52).
    func surface(_ surface: any TerminalSurface, didRequestClipboard op: ClipboardOp)
    /// The program posted a desktop notification (OSC 9 / OSC 777).
    func surface(_ surface: any TerminalSurface, didReceiveNotification title: String, body: String)
    /// The user activated a link (an OSC 8 hyperlink or a detected URL).
    /// `link` is untrusted text from the program, usually but not always a
    /// URL; the host decides whether and how to open it. Surfaces never open
    /// links themselves.
    func surface(_ surface: any TerminalSurface, didActivateLink link: String)
}

/// A terminal's size in cells, plus the size of one cell in points.
public struct GridSize: Sendable, Hashable, Codable, CustomStringConvertible {
    public var columns: Int
    public var rows: Int
    /// Width of one cell in points, exactly as the renderer lays it out
    /// (not rounded), so `columns * cellWidth` never exceeds the text area.
    public var cellWidth: Double
    /// Height of one cell in points, including line spacing.
    public var cellHeight: Double

    public init(columns: Int, rows: Int, cellWidth: Double = 0, cellHeight: Double = 0) {
        self.columns = columns
        self.rows = rows
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
    }

    public var description: String { "\(columns)x\(rows)" }
}

/// Search direction for ``TerminalSurface/find(_:direction:)``.
public enum FindDirection: Sendable, Hashable {
    case next
    case previous
}

/// A clipboard request from the program (OSC 52).
public enum ClipboardOp: Sendable, Hashable {
    /// Put `text` on the clipboard. The host decides whether to allow it.
    case write(String)
    /// The program asked to read the clipboard. Surfaces currently deny the
    /// read and report it so the host can surface the request to the user.
    case readRequested
}
