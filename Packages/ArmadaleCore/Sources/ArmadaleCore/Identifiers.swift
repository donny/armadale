/// Shared behaviour of Armadale's short random identifiers.
///
/// Generated identifiers are 16 lowercase RFC 4648 base32 characters
/// (`a`–`z`, `2`–`7`) encoding 80 random bits. They are short enough to embed
/// in session names (`a-<SessionID>`) and Unix socket paths, and are encoded
/// in JSON as a plain string.
///
/// Decoding is strict: anything but the exact generated form is rejected,
/// because these identifiers end up in file and socket names. Types that
/// need reserved, readable values (``ProfileID``, for the built-in
/// profiles) opt out with ``allowsArbitraryRawValues``.
public protocol ShortIdentifier: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    /// The identifier's string form.
    var raw: String { get }
    /// Wraps an existing string. No validation is performed; use
    /// ``generate()`` for new identifiers.
    init(raw: String)
    /// Whether decoding accepts any non-empty string rather than only the
    /// generated 16-character form. Defaults to `false`.
    static var allowsArbitraryRawValues: Bool { get }
}

/// Generation and validation of the string used by every ``ShortIdentifier``.
public enum ShortIDGenerator {
    /// RFC 4648 base32 alphabet, lowercased.
    public static let alphabet: [Character] = Array("abcdefghijklmnopqrstuvwxyz234567")
    /// Number of characters in a generated identifier.
    public static let length = 16
    /// Number of random bytes encoded in an identifier (80 bits).
    public static let byteCount = 10

    /// Encodes exactly ``byteCount`` bytes as unpadded lowercase base32
    /// (RFC 4648 §6). Returns `nil` for any other count.
    public static func encode(_ bytes: [UInt8]) -> String? {
        guard bytes.count == byteCount else { return nil }
        var chars: [Character] = []
        chars.reserveCapacity(length)
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                chars.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
            }
        }
        // 80 bits is a multiple of 5, so nothing is left over.
        return String(chars)
    }

    /// Returns a new identifier string using `generator` for randomness.
    public static func make<G: RandomNumberGenerator>(using generator: inout G) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(byteCount)
        while bytes.count < byteCount {
            var word = generator.next() as UInt64
            for _ in 0..<min(8, byteCount - bytes.count) {
                bytes.append(UInt8(truncatingIfNeeded: word >> 56))
                word <<= 8
            }
        }
        return encode(bytes) ?? ""
    }

    /// Returns a new identifier string from the system's secure random source.
    public static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return make(using: &generator)
    }

    /// Whether `string` has the shape of a generated identifier.
    public static func isWellFormed(_ string: String) -> Bool {
        string.count == length && string.allSatisfy { alphabet.contains($0) }
    }
}

extension ShortIdentifier {
    public static var allowsArbitraryRawValues: Bool { false }

    /// Creates a new random identifier.
    public static func generate() -> Self { Self(raw: ShortIDGenerator.make()) }

    public var description: String { raw }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw < rhs.raw }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if Self.allowsArbitraryRawValues {
            guard !string.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "\(Self.self) must not be empty")
            }
        } else {
            guard ShortIDGenerator.isWellFormed(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "\(Self.self) \"\(string)\" is not 16 lowercase base32 characters")
            }
        }
        self.init(raw: string)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// Identifies a ``Workspace``.
public struct WorkspaceID: ShortIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

/// Identifies a ``TabGroup``.
public struct TabGroupID: ShortIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

/// Identifies a ``Tab``.
public struct TabID: ShortIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

/// Identifies a ``Pane``.
public struct PaneID: ShortIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

/// Identifies a ``Session``. Also used to derive the daemon session name.
public struct SessionID: ShortIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

/// Identifies a ``Host``.
public struct HostID: ShortIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

/// Identifies a ``Favorite``.
public struct FavoriteID: ShortIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

/// Identifies a ``Profile``. Unlike the other identifiers it accepts any
/// non-empty string, so the built-in profiles can use readable reserved IDs
/// (`builtin.*`) that can never collide with generated ones.
public struct ProfileID: ShortIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
    public static var allowsArbitraryRawValues: Bool { true }
}
