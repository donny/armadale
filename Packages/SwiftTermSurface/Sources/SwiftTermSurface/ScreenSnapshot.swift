import AppKit
@preconcurrency internal import SwiftTerm
import Synchronization

/// SwiftTerm's `TerminalView` with one addition: for the length of one
/// call (``answers(to:inspecting:)``) the terminal's answers to queries are
/// kept here instead of reaching the program, and the terminal itself can
/// be read while it answers.
///
/// Why this way (DESIGN §5, `TerminalSurface.screenSnapshot()`): SwiftTerm
/// 1.99.0's view keeps its `Terminal` internal, and the terminal keeps the
/// cursor's visibility, origin mode, wraparound and its pen's colours
/// behind internal properties. Through public API only, the terminal is
/// handed to the view's `open` `send(source:data:)` whenever it answers a
/// query (DECRQM, `CSI ? n $ p`), and its public reading API (`getLine`,
/// `CharData`, `buffer`, `currentAttribute`, `isCurrentBufferAlternate`)
/// gives the screen; the modes it keeps internal are read from its DECRQM
/// answers. Output is parsed synchronously on the thread that feeds it
/// (the main thread), so the answers arrive inside ``answers(to:inspecting:)``.
@MainActor
final class SnapshotTerminalView: TerminalView {
    private struct Capture {
        var isActive = false
        var replies: [UInt8] = []
        var inspect: (@Sendable (Terminal) -> Void)?
    }

    private let capture = Mutex(Capture())

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        let taken = capture.withLock { capture -> (captured: Bool, inspect: (@Sendable (Terminal) -> Void)?) in
            guard capture.isActive else { return (false, nil) }
            capture.replies += data
            defer { capture.inspect = nil }
            return (true, capture.inspect)
        }
        guard taken.captured else {
            super.send(source: source, data: data)
            return
        }
        taken.inspect?(source)
    }

    /// Feeds `queries` and returns what the terminal answered, none of it
    /// passed on to the program. `inspect` runs once, with the terminal,
    /// at the first answer.
    func answers(to queries: [UInt8], inspecting inspect: (@Sendable (Terminal) -> Void)? = nil) -> [UInt8] {
        capture.withLock { $0 = Capture(isActive: true, replies: [], inspect: inspect) }
        feed(byteArray: queries[...])
        return capture.withLock { capture in
            defer { capture = Capture() }
            return capture.replies
        }
    }
}

/// What ``SwiftTermSurface/screenSnapshot()`` reads from the terminal.
struct ScreenReading: Sendable {
    /// The live screen drawn row by row (cursor positioning, SGR and text),
    /// wraparound off while drawing.
    var drawing: [UInt8]
    var columns: Int
    var rows: Int
    var cursorColumn: Int
    var cursorRow: Int
    var isAlternate: Bool
    /// The scroll region, zero-based and inclusive.
    var scrollTop: Int
    var scrollBottom: Int
    /// SGR for the pen (`Terminal.currentAttribute`).
    var pen: String
    /// The cursor waits to wrap (it stands past the last column after a
    /// character written there): that character, its column and its SGR,
    /// to be written again last.
    var lastCell: (column: Int, text: String, sgr: String)?
    /// The saved cursor (DECSC): position and pen.
    var savedColumn: Int
    var savedRow: Int
    var savedPen: String

    /// Reads `terminal`'s live screen (rows `0..<rows` from the top of
    /// what is on screen: the caller scrolls to the bottom first).
    nonisolated static func read(_ terminal: Terminal) -> ScreenReading {
        let columns = terminal.cols, rows = terminal.rows
        var out = ""
        var current: Attribute?
        for row in 0..<rows {
            guard let line = terminal.getLine(row: row) else { continue }
            var cursor = -1  // nothing written on this row yet
            for column in 0..<min(columns, line.count) {
                let cell = line[column]
                let width = Int(cell.width)
                guard width > 0 else { continue }  // the second half of a wide character
                let text = Self.text(of: cell)
                if text == " ", Self.isPlain(cell.attribute) { continue }  // blank: left as it is
                if cursor < 0 {
                    out += "\u{1b}[\(row + 1);\(column + 1)H"
                } else if column > cursor {
                    // A run of blank cells: one cursor move, or plain spaces
                    // when that is shorter and the pen is the default one.
                    let gap = column - cursor
                    if gap <= 3, current.map(Self.isPlain) ?? true {
                        out += String(repeating: " ", count: gap)
                    } else {
                        out += "\u{1b}[\(gap)C"
                    }
                }
                if current != cell.attribute {
                    out += sgr(cell.attribute)
                    current = cell.attribute
                }
                out += text
                cursor = column + width
            }
        }
        out += "\u{1b}[0m"
        let buffer = terminal.buffer
        let position = terminal.getCursorLocation()
        var lastCell: (Int, String, String)?
        if position.x >= columns, let line = terminal.getLine(row: position.y) {
            // The character written in the last column, a wide one's first cell.
            var column = min(columns, line.count) - 1
            while column > 0, line[column].width == 0 { column -= 1 }
            if column >= 0 {
                let cell = line[column]
                lastCell = (column, text(of: cell), sgr(cell.attribute))
            }
        }
        return ScreenReading(
            drawing: Array(out.utf8), columns: columns, rows: rows,
            cursorColumn: position.x, cursorRow: position.y, isAlternate: terminal.isCurrentBufferAlternate,
            scrollTop: buffer.scrollTop, scrollBottom: buffer.scrollBottom,
            pen: sgr(terminal.currentAttribute), lastCell: lastCell,
            savedColumn: buffer.savedX, savedRow: buffer.savedY, savedPen: sgr(buffer.savedAttr))
    }

    /// A cell's text; a cell nothing was written to reads as a space.
    nonisolated static func text(of cell: CharData) -> String {
        let text = cell.getText()
        return text.isEmpty || text == "\u{0}" ? " " : text
    }

    /// The default pen: default colours, no style.
    nonisolated static func isPlain(_ attribute: Attribute) -> Bool {
        attribute.fg == .defaultColor && attribute.bg == .defaultColor && attribute.style.isEmpty
            && attribute.underlineStyle == .none && attribute.underlineColor == nil
    }

    /// SGR that sets exactly `attribute`, starting from a reset.
    nonisolated static func sgr(_ attribute: Attribute) -> String {
        var parameters = ["0"]
        let style = attribute.style
        if style.contains(.bold) { parameters.append("1") }
        if style.contains(.dim) { parameters.append("2") }
        if style.contains(.italic) { parameters.append("3") }
        switch attribute.underlineStyle {
        case .none: if style.contains(.underline) { parameters.append("4") }
        case .single: parameters.append("4")
        default: parameters.append("4:\(attribute.underlineStyle.rawValue)")
        }
        if style.contains(.blink) { parameters.append("5") }
        if style.contains(.inverse) { parameters.append("7") }
        if style.contains(.invisible) { parameters.append("8") }
        if style.contains(.crossedOut) { parameters.append("9") }
        if let fg = color(attribute.fg, base: 38) { parameters.append(fg) }
        if let bg = color(attribute.bg, base: 48) { parameters.append(bg) }
        if let underline = attribute.underlineColor, let color = color(underline, base: 58) { parameters.append(color) }
        return "\u{1b}[" + parameters.joined(separator: ";") + "m"
    }

    private nonisolated static func color(_ color: Attribute.Color, base: Int) -> String? {
        switch color {
        case .ansi256(let code): "\(base);5;\(code)"
        case .trueColor(let red, let green, let blue): "\(base);2;\(red);\(green);\(blue)"
        case .defaultColor, .defaultInvertedColor: nil
        }
    }
}

/// The DEC private modes a snapshot asks the terminal for (DECRQM), which
/// SwiftTerm keeps internal.
struct SnapshotModes: Equatable, Sendable {
    var cursorVisible = true
    var originMode = false
    var wraparound = true
    var reverseVideo = false

    /// DECRQM for DECTCEM (25), DECOM (6), DECAWM (7) and DECSCNM (5).
    static let queries: [UInt8] = Array("\u{1b}[?25$p\u{1b}[?6$p\u{1b}[?7$p\u{1b}[?5$p".utf8)

    /// The modes from the terminal's answers (`CSI ? n ; v $ y`, `v` 1 or
    /// 3 set, 2 or 4 reset); a mode not answered keeps its default.
    init(answers: [UInt8]) {
        let text = String(decoding: answers, as: UTF8.self)
        for answer in text.split(separator: "\u{1b}") {
            guard answer.hasPrefix("[?"), answer.hasSuffix("$y") else { continue }
            let fields = answer.dropFirst(2).dropLast(2).split(separator: ";")
            guard fields.count == 2, let mode = Int(fields[0]), let value = Int(fields[1]) else { continue }
            let isSet: Bool
            switch value {
            case 1, 3: isSet = true
            case 2, 4: isSet = false
            default: continue
            }
            switch mode {
            case 25: cursorVisible = isSet
            case 6: originMode = isSet
            case 7: wraparound = isSet
            case 5: reverseVideo = isSet
            default: break
            }
        }
    }

    init() {}
}

extension ScreenReading {
    /// The bytes that reproduce this screen on a fresh terminal of the
    /// same size: the alternate screen if it is active, reverse video, the
    /// drawing, wraparound, the saved cursor, then the scroll region,
    /// origin mode, the cursor (a cursor waiting to wrap by writing the last
    /// column's character again), the pen and the cursor's visibility.
    func bytes(modes: SnapshotModes) -> [UInt8] {
        var out = "\u{1b}[0m"
        if isAlternate { out += "\u{1b}[?1049h" }
        if modes.reverseVideo { out += "\u{1b}[?5h" }
        out += "\u{1b}[?7l"
        var bytes = Array(out.utf8) + drawing
        var tail = ""
        if modes.wraparound { tail += "\u{1b}[?7h" }
        if savedColumn != 0 || savedRow != 0 || savedPen != "\u{1b}[0m" {
            // DECSC with the pen saved, origin mode off and wraparound as
            // it is now (what DECSC saved of those two is internal).
            tail += "\u{1b}[\(max(savedRow, 0) + 1);\(max(0, min(savedColumn, columns - 1)) + 1)H" + savedPen + "\u{1b}7"
        }
        let top = max(0, min(scrollTop, rows - 1)), bottom = max(top, min(scrollBottom, rows - 1))
        if top != 0 || bottom != rows - 1 { tail += "\u{1b}[\(top + 1);\(bottom + 1)r" }
        if modes.originMode { tail += "\u{1b}[?6h" }
        let row = max(modes.originMode ? cursorRow - top : cursorRow, 0) + 1
        if let lastCell, modes.wraparound, cursorColumn >= columns {
            // Written again with wraparound on, it leaves the cursor
            // waiting to wrap, as the program left it.
            tail += "\u{1b}[\(row);\(lastCell.column + 1)H" + lastCell.sgr + lastCell.text
        } else {
            tail += "\u{1b}[\(row);\(max(0, min(cursorColumn, columns - 1)) + 1)H"
        }
        tail += pen
        if !modes.cursorVisible { tail += "\u{1b}[?25l" }
        bytes += Array(tail.utf8)
        return bytes
    }
}

/// A box the terminal's reading lands in, from the view's `send` override.
final class ReadingBox<Value: Sendable>: Sendable {
    let value = Mutex<Value?>(nil)
}

// MARK: For tests

/// One cell, as the snapshot tests compare them.
struct CellState: Equatable, Sendable, CustomStringConvertible {
    var text: String
    var width: Int
    var attribute: Attribute

    var description: String { "\(text.debugDescription)/\(width)/\(ScreenReading.sgr(attribute).debugDescription)" }
}

/// The live screen as the snapshot tests compare it: every cell, the
/// cursor, the alternate screen, the scroll region, the pen and the modes.
struct ScreenState: Equatable, Sendable {
    var cells: [[CellState]]
    var cursorColumn: Int
    var cursorRow: Int
    var isAlternate: Bool
    var scrollTop: Int
    var scrollBottom: Int
    var pen: String
    var modes: SnapshotModes
    var savedColumn: Int
    var savedRow: Int
    var savedPen: String

    /// What differs from `other`, for a failing test.
    func differences(from other: ScreenState) -> [String] {
        var found: [String] = []
        for row in 0..<max(cells.count, other.cells.count) {
            let mine = row < cells.count ? cells[row] : [], theirs = row < other.cells.count ? other.cells[row] : []
            for column in 0..<max(mine.count, theirs.count) {
                let a = column < mine.count ? mine[column].description : "-"
                let b = column < theirs.count ? theirs[column].description : "-"
                if a != b { found.append("(\(column),\(row)): \(a) vs \(b)") }
            }
        }
        if cursorColumn != other.cursorColumn || cursorRow != other.cursorRow {
            found.append("cursor (\(cursorColumn),\(cursorRow)) vs (\(other.cursorColumn),\(other.cursorRow))")
        }
        if isAlternate != other.isAlternate { found.append("alternate \(isAlternate) vs \(other.isAlternate)") }
        if scrollTop != other.scrollTop || scrollBottom != other.scrollBottom {
            found.append("region \(scrollTop)-\(scrollBottom) vs \(other.scrollTop)-\(other.scrollBottom)")
        }
        if pen != other.pen { found.append("pen \(pen.debugDescription) vs \(other.pen.debugDescription)") }
        if modes != other.modes { found.append("modes \(modes) vs \(other.modes)") }
        if savedColumn != other.savedColumn || savedRow != other.savedRow || savedPen != other.savedPen {
            found.append("saved (\(savedColumn),\(savedRow)) \(savedPen.debugDescription) vs "
                + "(\(other.savedColumn),\(other.savedRow)) \(other.savedPen.debugDescription)")
        }
        return found
    }
}

extension SwiftTermSurface {
    /// The screen on view (rows from the top of what is shown), for tests.
    func screenState() -> ScreenState? {
        let modes = currentModes()
        return withTerminal { terminal in
            var cells: [[CellState]] = []
            for row in 0..<terminal.rows {
                guard let line = terminal.getLine(row: row) else { continue }
                cells.append((0..<min(terminal.cols, line.count)).map { column in
                    let cell = line[column]
                    return CellState(text: ScreenReading.text(of: cell), width: Int(cell.width), attribute: cell.attribute)
                })
            }
            let cursor = terminal.getCursorLocation()
            return ScreenState(
                cells: cells, cursorColumn: cursor.x, cursorRow: cursor.y,
                isAlternate: terminal.isCurrentBufferAlternate, scrollTop: terminal.buffer.scrollTop,
                scrollBottom: terminal.buffer.scrollBottom, pen: ScreenReading.sgr(terminal.currentAttribute), modes: modes,
                savedColumn: terminal.buffer.savedX, savedRow: terminal.buffer.savedY,
                savedPen: ScreenReading.sgr(terminal.buffer.savedAttr))
        }
    }
}
