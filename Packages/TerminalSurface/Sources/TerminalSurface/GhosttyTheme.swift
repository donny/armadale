import Foundation

/// Reads Ghostty theme files: lines of `key = value`, `#` comments, and
/// the colour keys `palette = N=#rrggbb` (N 0–255; Armadale uses 0–15),
/// `background`, `foreground`, `cursor-color`, `selection-background` and
/// `selection-foreground`. Values may be quoted, colours may omit the `#`,
/// and the basic X11 names Ghostty accepts (`black` … `white`, their
/// `bright`/`light` variants, `grey`) mean the default palette's entries. Other Ghostty keys (`cursor-text`, `split-divider-color`, …) are
/// valid but unused, and are listed in ``Result/ignoredKeys``.
///
/// Pure: no file access, no AppKit.
public enum GhosttyTheme {
    /// A parsed theme and what could not be used.
    public struct Result: Sendable, Hashable {
        public var theme: TerminalTheme
        /// Lines that could not be understood, as "line N: problem".
        public var warnings: [String]
        /// Well-formed keys Armadale does not use, in file order.
        public var ignoredKeys: [String]
    }

    public enum ParseError: Error, Sendable, Hashable, CustomStringConvertible {
        /// No background, foreground or palette colour was found. `warnings`
        /// are the lines that could not be understood (often the reason).
        case noColors(warnings: [String])

        public var description: String {
            switch self {
            case .noColors(let warnings):
                guard !warnings.isEmpty else { return "The file does not contain any theme colours." }
                let shown = warnings.prefix(5).joined(separator: "\n")
                let more = warnings.count > 5 ? "\n…and \(warnings.count - 5) more" : ""
                return "The file does not contain any theme colours it can use:\n\(shown)\(more)"
            }
        }
    }

    /// A colour as written: hex, or one of the basic names, which mean the
    /// default palette's entry (resolved once the palette is known).
    private enum Value {
        case color(TerminalColor)
        case paletteEntry(Int)

        func resolved(in palette: [TerminalColor]) -> TerminalColor {
            switch self {
            case .color(let color): color
            case .paletteEntry(let index): palette[index]
            }
        }
    }

    /// The default palette entry a basic colour name stands for: `black` …
    /// `white` (0–7), `bright`/`light` variants (8–15), `grey`/`gray` (8),
    /// `light grey`/`light gray` (7). Case, spaces, `-` and `_` are ignored.
    public static func paletteIndex(forColorName name: String) -> Int? {
        let basic = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        var key = name.lowercased().filter { !" -_".contains($0) }
        if key == "grey" || key == "gray" { return 8 }
        if key == "lightgrey" || key == "lightgray" { return 7 }
        var offset = 0
        for prefix in ["bright", "light"] where key.hasPrefix(prefix) {
            key.removeFirst(prefix.count)
            offset = 8
            break
        }
        return basic.firstIndex(of: key).map { $0 + offset }
    }

    /// Parses `text` into a theme named `name`. Missing palette entries
    /// come from the default palette for the theme's background
    /// (``TerminalTheme/defaultLightANSI`` for a light one, luminance above
    /// 0.5, else ``TerminalTheme/defaultANSI``), which basic colour names
    /// also refer to. A missing background or foreground comes from
    /// ``TerminalTheme/default``; a missing cursor colour is the
    /// foreground, a missing selection colour a mix of background and
    /// foreground.
    public static func parse(_ text: String, name: String) throws(ParseError) -> Result {
        var palette: [Int: Value] = [:]
        var background: Value?
        var foreground: Value?
        var cursor: Value?
        var selection: Value?
        var selectionForeground: Value?
        var warnings: [String] = []
        var ignored: [String] = []

        for (offset, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let number = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "=") else {
                warnings.append("line \(number): expected “key = value”")
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = unquote(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            guard !key.isEmpty else {
                warnings.append("line \(number): missing key")
                continue
            }

            func color(_ string: String) -> Value? {
                if let parsed = TerminalColor(hexString: string) { return .color(parsed) }
                if let index = paletteIndex(forColorName: string) { return .paletteEntry(index) }
                warnings.append("line \(number): “\(string)” is not a colour (#rrggbb or a basic colour name)")
                return nil
            }

            switch key {
            case "palette":
                guard let separator = value.firstIndex(of: "="),
                      let index = Int(value[..<separator].trimmingCharacters(in: .whitespaces)),
                      (0...255).contains(index)
                else {
                    warnings.append("line \(number): expected “palette = N=#rrggbb” with N from 0 to 255")
                    continue
                }
                guard let parsed = color(value[value.index(after: separator)...].trimmingCharacters(in: .whitespaces))
                else { continue }
                if index < 16 { palette[index] = parsed }
            case "background":
                background = color(value) ?? background
            case "foreground":
                foreground = color(value) ?? foreground
            case "cursor-color":
                cursor = color(value) ?? cursor
            case "selection-background":
                selection = color(value) ?? selection
            case "selection-foreground":
                selectionForeground = color(value) ?? selectionForeground
            default:
                ignored.append(key)
            }
        }

        guard background != nil || foreground != nil || !palette.isEmpty else { throw .noColors(warnings: warnings) }
        // The background decides which default palette fills the gaps (a
        // named background is looked up in the dark one first).
        let dark = TerminalTheme.defaultANSI
        let provisional = background?.resolved(in: dark) ?? TerminalTheme.default.background
        let defaults = provisional.luminance > 0.5 ? TerminalTheme.defaultLightANSI : dark
        let ansi = (0..<16).map { palette[$0]?.resolved(in: defaults) ?? defaults[$0] }
        let bg = background?.resolved(in: defaults) ?? TerminalTheme.default.background
        let fg = foreground?.resolved(in: defaults) ?? TerminalTheme.default.foreground
        let theme = TerminalTheme(
            name: name,
            ansi: ansi,
            foreground: fg,
            background: bg,
            cursor: cursor?.resolved(in: defaults) ?? fg,
            selection: selection?.resolved(in: defaults) ?? bg.mixed(with: fg, fraction: 0.3),
            selectionForeground: selectionForeground?.resolved(in: defaults))
        return Result(theme: theme, warnings: warnings, ignoredKeys: ignored)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast())
    }
}
