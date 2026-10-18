import Foundation


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

    /// Parses `#rrggbb`, `rrggbb` or `#rgb` (case-insensitive).
    public init?(hexString: String) {
        var digits = Substring(hexString.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        switch digits.count {
        case 6:
            guard let value = UInt32(digits, radix: 16) else { return nil }
            self.init(hex: value)
        case 3:
            let expanded = digits.map { "\($0)\($0)" }.joined()
            guard let value = UInt32(expanded, radix: 16) else { return nil }
            self.init(hex: value)
        default:
            return nil
        }
    }

    /// Relative luminance (0 black … 1 white), from sRGB.
    public var luminance: Double {
        func linear(_ component: UInt8) -> Double {
            let c = Double(component) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// This colour moved `fraction` (0…1) of the way towards `other`.
    public func mixed(with other: TerminalColor, fraction: Double) -> TerminalColor {
        let t = min(max(fraction, 0), 1)
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded())
        }
        return TerminalColor(red: mix(red, other.red), green: mix(green, other.green), blue: mix(blue, other.blue))
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
    /// Background of selected text.
    public var selection: TerminalColor
    /// Text colour of selected text; `nil` keeps each cell's own colour.
    /// Renderers that cannot recolour selected text ignore it.
    public var selectionForeground: TerminalColor?

    /// Creates a theme. `ansi` must contain exactly 16 colours; shorter
    /// arrays are padded from ``default`` and longer ones truncated.
    public init(
        name: String,
        ansi: [TerminalColor],
        foreground: TerminalColor,
        background: TerminalColor,
        cursor: TerminalColor,
        selection: TerminalColor,
        selectionForeground: TerminalColor? = nil
    ) {
        self.name = name
        self.ansi = Self.normalize(ansi)
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.selectionForeground = selectionForeground
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            ansi: try container.decode([TerminalColor].self, forKey: .ansi),
            foreground: try container.decode(TerminalColor.self, forKey: .foreground),
            background: try container.decode(TerminalColor.self, forKey: .background),
            cursor: try container.decode(TerminalColor.self, forKey: .cursor),
            selection: try container.decode(TerminalColor.self, forKey: .selection),
            selectionForeground: try container.decodeIfPresent(TerminalColor.self, forKey: .selectionForeground))
    }

    private static func normalize(_ colors: [TerminalColor]) -> [TerminalColor] {
        if colors.count >= 16 { return Array(colors.prefix(16)) }
        return colors + defaultANSI.dropFirst(colors.count)
    }

    /// Default colours for a dark background; they also fill in missing
    /// ANSI entries.
    public static let defaultANSI: [TerminalColor] = [
        0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
        0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA,
    ].map(TerminalColor.init(hex:))

    /// Default colours for a light background (Armadale Light's palette).
    public static let defaultLightANSI: [TerminalColor] = [
        0x1D1F21, 0xC82829, 0x718C00, 0xB07D00, 0x4271AE, 0x8959A8, 0x3E999F, 0xA6A6A6,
        0x5C5F66, 0xE0464A, 0x82A000, 0xD69E00, 0x5B8BD0, 0xA270C4, 0x47B0B7, 0xD9D9D9,
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
