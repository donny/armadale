import Foundation

/// The asciicast v2 format (asciinema's `.cast`, which `asciinema play`
/// and SwiftTerm's `termcast playback` read): a header line, a JSON object,
/// then one event per line, a JSON array `[seconds, code, data]`
/// (docs/DESIGN.md section 7, "Recording a pane"). Armadale writes output
/// events (`"o"`) and resizes (`"r"`, `"<COLS>x<ROWS>"`), never input
/// (`"i"`): what was typed, a password that does not echo included, never
/// reaches a recording. Every line ends in a newline and holds no other,
/// so a file is complete after every line written.
public enum Asciicast {
    /// The environment the header names: what Armadale's sessions get.
    public static let term = "xterm-256color"

    /// The header line: `{"version":2,"width":…,"height":…,"timestamp":…,
    /// "title":…,"env":{"TERM":"xterm-256color"}}`, keys in that order.
    /// `timestamp` is Unix seconds (whole).
    public static func headerLine(columns: Int, rows: Int, timestamp: Int, title: String) -> [UInt8] {
        let line = "{\"version\":2,\"width\":\(columns),\"height\":\(rows),\"timestamp\":\(timestamp),"
            + "\"title\":\(jsonString(title)),\"env\":{\"TERM\":\(jsonString(term))}}\n"
        return Array(line.utf8)
    }

    /// An output event: `[time, "o", text]`.
    public static func outputLine(time: Double, text: String) -> [UInt8] {
        Array("[\(formatTime(time)),\"o\",\(jsonString(text))]\n".utf8)
    }

    /// A resize event: `[time, "r", "COLSxROWS"]`.
    public static func resizeLine(time: Double, columns: Int, rows: Int) -> [UInt8] {
        Array("[\(formatTime(time)),\"r\",\"\(columns)x\(rows)\"]\n".utf8)
    }

    /// Seconds with six decimals, never negative, never exponent notation.
    public static func formatTime(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(seconds, 0) : 0
        return String(format: "%.6f", value)
    }

    /// `text` as a JSON string, quotes included. Every control character
    /// (C0, DEL and C1) and U+2028 and U+2029 are escaped, so no line ever
    /// holds a raw newline of any kind or an escape byte; `"` and `\` are
    /// escaped; everything else is written as UTF-8.
    public static func jsonString(_ text: String) -> String {
        var out = "\""
        out.unicodeScalars.reserveCapacity(text.unicodeScalars.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                let value = scalar.value
                // Line and paragraph separators too: termcast's player
                // splits lines on every newline character (`CharacterSet.newlines`).
                if value < 0x20 || (0x7F...0x9F).contains(value) || value == 0x2028 || value == 0x2029 {
                    out += "\\u" + String(format: "%04x", value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

/// Decodes a byte stream as UTF-8 one batch at a time, the way decoding the
/// whole stream at once would: an incomplete sequence at the end of a batch
/// (at most three bytes) is held back and decoded with the next batch;
/// bytes that are not UTF-8 become U+FFFD; ``finish()`` decodes what is
/// held (an unfinished sequence there becomes U+FFFD too).
public struct UTF8StreamDecoder: Sendable {
    private var held: [UInt8] = []

    public init() {}

    /// The bytes held back for the next batch (for tests).
    public var heldCount: Int { held.count }

    /// The text of `bytes` and what was held before them, up to the start
    /// of an incomplete sequence at their end.
    public mutating func decode<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> String {
        var input = held
        input.append(contentsOf: bytes)
        let cut = Self.completeLength(of: input)
        held = Array(input[cut...])
        return String(decoding: input[..<cut], as: UTF8.self)
    }

    /// Whatever is held, decoded (U+FFFD for an unfinished sequence).
    public mutating func finish() -> String {
        defer { held = [] }
        return String(decoding: held, as: UTF8.self)
    }

    /// How much of `bytes` can be decoded now: all of it, unless it ends in
    /// the first one to three bytes of a sequence that may still be
    /// completed (a lead byte followed by fewer continuation bytes than it
    /// announces). Holding back bytes that turn out invalid changes
    /// nothing: they are decoded with what follows, as in the whole stream.
    static func completeLength(of bytes: [UInt8]) -> Int {
        let end = bytes.count
        var index = end - 1
        // Back over at most three continuation bytes to a lead byte.
        while index >= 0, end - index <= 3, bytes[index] & 0xC0 == 0x80 {
            index -= 1
        }
        guard index >= 0 else { return end }
        let lead = bytes[index]
        let length: Int
        switch lead {
        case 0xC2...0xDF: length = 2
        case 0xE0...0xEF: length = 3
        case 0xF0...0xF4: length = 4
        default: return end  // ASCII, a stray continuation, or never a lead byte
        }
        return end - index < length ? index : end
    }
}
