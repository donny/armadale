/// An sRGB colour with 8-bit components, used by ``TerminalTheme``.
public struct TerminalColor: Sendable, Hashable, Codable, CustomStringConvertible {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Creates a colour from `0xRRGGBB`.
    public init(hex: UInt32) {
        self.init(red: UInt8((hex >> 16) & 0xFF), green: UInt8((hex >> 8) & 0xFF), blue: UInt8(hex & 0xFF))
    }

    /// `#rrggbb`.
    public var description: String {
        "#" + [red, green, blue].map { byte in
            let s = String(byte, radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined()
    }
}

/// Terminal colours: the 16 ANSI colours plus default foreground,
/// background, cursor and selection.
public struct TerminalTheme: Sendable, Hashable, Codable {
    public var name: String
    /// ANSI colours 0–15 (normal 0–7, bright 8–15). Always 16 entries.
    public private(set) var ansi: [TerminalColor]
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var cursor: TerminalColor
    public var selection: TerminalColor

    /// Creates a theme. `ansi` must contain exactly 16 colours; shorter
    /// arrays are padded from ``default`` and longer ones truncated.
    public init(
        name: String,
        ansi: [TerminalColor],
        foreground: TerminalColor,
        background: TerminalColor,
        cursor: TerminalColor,
        selection: TerminalColor
    ) {
        self.name = name
        self.ansi = Self.normalize(ansi)
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            ansi: try container.decode([TerminalColor].self, forKey: .ansi),
            foreground: try container.decode(TerminalColor.self, forKey: .foreground),
            background: try container.decode(TerminalColor.self, forKey: .background),
            cursor: try container.decode(TerminalColor.self, forKey: .cursor),
            selection: try container.decode(TerminalColor.self, forKey: .selection))
    }

    private static func normalize(_ colors: [TerminalColor]) -> [TerminalColor] {
        if colors.count >= 16 { return Array(colors.prefix(16)) }
        return colors + defaultANSI.dropFirst(colors.count)
    }

    private static let defaultANSI: [TerminalColor] = [
        0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
        0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA,
    ].map(TerminalColor.init(hex:))

    /// A neutral dark theme used until Settings provides one.
    public static let `default` = TerminalTheme(
        name: "Default Dark",
        ansi: defaultANSI,
        foreground: TerminalColor(hex: 0xC5C8C6),
        background: TerminalColor(hex: 0x1D1F21),
        cursor: TerminalColor(hex: 0xC5C8C6),
        selection: TerminalColor(hex: 0x373B41))
}

/// Cursor shape and blink.
public struct TerminalCursorStyle: Sendable, Hashable, Codable {
    public enum Shape: String, Sendable, Hashable, Codable, CaseIterable {
        case block, underline, bar
    }

    public var shape: Shape
    public var blinks: Bool

    public init(shape: Shape = .block, blinks: Bool = true) {
        self.shape = shape
        self.blinks = blinks
    }
}

/// Everything a surface needs to look right.
public struct TerminalAppearance: Sendable, Hashable, Codable {
    /// PostScript or family name of a monospaced font; an unknown name falls
    /// back to the system monospaced font.
    public var fontName: String
    /// Font size in points.
    public var fontSize: Double
    public var theme: TerminalTheme
    public var cursor: TerminalCursorStyle

    public init(
        fontName: String = "SF Mono",
        fontSize: Double = 13,
        theme: TerminalTheme = .default,
        cursor: TerminalCursorStyle = TerminalCursorStyle()
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.theme = theme
        self.cursor = cursor
    }

    /// The default appearance.
    public static let `default` = TerminalAppearance()
}
