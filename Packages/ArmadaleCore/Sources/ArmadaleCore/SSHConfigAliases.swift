import Darwin
import Foundation

/// The host aliases of a user's ssh configuration, offered while a
/// destination is typed in the New Session dialog (DESIGN §8, "New
/// sessions"). It only reads: it never writes a file, runs `ssh -G` or
/// connects anywhere.
///
/// What counts: the patterns of `Host` lines (the keyword in any case;
/// several patterns on one line; `Host=name` and quoted patterns as
/// ssh_config(5) allows them) that name one host and that
/// ``Host/destinationProblem(_:)`` accepts: not patterns with `*` or `?`,
/// negated ones (`!name`), ones with spaces or starting with `-`. `Include`
/// lines are followed (several paths on one line; a relative path is
/// relative to `~/.ssh`; `~/` is the home folder, and any other path
/// starting with `~`, such as `~user/x`, names nothing; globs), at most
/// ``maximumIncludeDepth`` deep, and a file already read is not read again,
/// so a cycle ends. Only regular files are read (checked with `stat`
/// before opening, so a FIFO or a device is never opened), none larger
/// than ``maximumFileSize``, and at most ``maximumFiles`` in one read.
/// Words are split as OpenSSH's `argv_split` does (``words(_:)``); a line
/// with an unterminated quote is dropped. Everything else is ignored, `Match`
/// blocks included, as are comments and blank lines. A missing or
/// unreadable file or folder gives nothing, never an error. The aliases
/// come deduplicated, in the order they were first seen, an included
/// file's in its place.
public enum SSHConfigAliases {
    /// ssh's own limit on nested `Include`s (`READCONF_MAX_DEPTH`).
    public static let maximumIncludeDepth = 16
    /// A file larger than this (bytes) is skipped whole.
    public static let maximumFileSize = 1 << 20
    /// At most this many files are read in one read, the top file and
    /// everything it includes.
    public static let maximumFiles = 256

    /// One line of a configuration file that matters here.
    public enum Line: Equatable, Sendable {
        /// A `Host` line's patterns, as written.
        case host([String])
        /// An `Include` line's paths, as written.
        case include([String])
    }

    /// The `Host` and `Include` lines of a configuration file's text, in
    /// order; every other line is left out.
    public static func lines(of text: String) -> [Line] {
        var result: [Line] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let (keyword, arguments) = keywordAndArguments(String(rawLine)) else { continue }
            switch keyword.lowercased() {
            case "host": result.append(.host(arguments))
            case "include": result.append(.include(arguments))
            default: continue
            }
        }
        return result
    }

    /// Whether a `Host` pattern is an alias worth offering: it names one
    /// host (no `*` or `?`, not negated) and ``Host/destinationProblem(_:)``
    /// accepts it as a destination (not empty, no spaces, not starting with
    /// `-`).
    public static func isAlias(_ pattern: String) -> Bool {
        !pattern.hasPrefix("!") && !pattern.contains("*") && !pattern.contains("?")
            && Host.destinationProblem(pattern) == nil
    }

    /// The aliases of one file's text, ignoring its `Include` lines.
    public static func aliases(inText text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for case .host(let patterns) in lines(of: text) {
            for pattern in patterns where isAlias(pattern) && seen.insert(pattern).inserted {
                result.append(pattern)
            }
        }
        return result
    }

    /// The aliases of the user configuration under `home`
    /// (`<home>/.ssh/config`), its includes followed. Empty when there is
    /// none or it cannot be read.
    public static func aliases(home: String) -> [String] {
        aliases(configFile: sshDirectory(home: home) + "/config", home: home)
    }

    /// The aliases of the configuration file at `path`, its includes
    /// followed; `home` gives `~` and the `.ssh` folder relative includes
    /// are read from.
    public static func aliases(configFile path: String, home: String) -> [String] {
        var reader = Reader(home: home)
        reader.read(path, depth: 0)
        return reader.aliases
    }

    /// The aliases worth offering for `typed` (whitespace around it is
    /// ignored), at most `limit`: with nothing typed, all of them; else
    /// those that start with it, then those that contain it elsewhere,
    /// ignoring case, each group in the configuration's order. An alias
    /// that is exactly what was typed is left out (nothing to complete).
    public static func suggestions(for typed: String, in aliases: [String], limit: Int = 20) -> [String] {
        let query = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(aliases.prefix(limit)) }
        let candidates = aliases.filter { $0 != query }
        let prefixed = candidates.filter { $0.range(of: query, options: [.caseInsensitive, .anchored]) != nil }
        let containing = candidates.filter {
            !prefixed.contains($0) && $0.range(of: query, options: .caseInsensitive) != nil
        }
        return Array((prefixed + containing).prefix(limit))
    }

    // MARK: Reading

    private static func sshDirectory(home: String) -> String {
        (home.hasSuffix("/") ? String(home.dropLast()) : home) + "/.ssh"
    }

    /// Follows a configuration and its includes, collecting aliases.
    private struct Reader {
        let home: String
        var aliases: [String] = []
        private var seenAliases = Set<String>()
        private var readFiles = Set<String>()
        /// Files opened so far, against ``SSHConfigAliases/maximumFiles``.
        private var filesRead = 0

        init(home: String) {
            self.home = home
        }

        mutating func read(_ path: String, depth: Int) {
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard filesRead < SSHConfigAliases.maximumFiles, readFiles.insert(canonical).inserted,
                  SSHConfigAliases.isSmallRegularFile(path)
            else { return }
            filesRead += 1
            guard let data = SSHConfigAliases.contents(ofFile: path),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else { return }
            for line in SSHConfigAliases.lines(of: text) {
                switch line {
                case .host(let patterns):
                    for pattern in patterns where SSHConfigAliases.isAlias(pattern)
                        && seenAliases.insert(pattern).inserted {
                        aliases.append(pattern)
                    }
                case .include(let paths):
                    guard depth < SSHConfigAliases.maximumIncludeDepth else { continue }
                    for pattern in paths {
                        for file in SSHConfigAliases.expand(pattern, home: home) {
                            read(file, depth: depth + 1)
                        }
                    }
                }
            }
        }
    }

    /// Whether `path` is a regular file no larger than ``maximumFileSize``,
    /// by `stat` (following a symbolic link), without opening it.
    static func isSmallRegularFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_size <= off_t(maximumFileSize)
    }

    /// A regular file's contents, at most ``maximumFileSize`` bytes; `nil`
    /// when it cannot be read or has grown past the limit since its `stat`.
    private static func contents(ofFile path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumFileSize + 1) else { return nil }
        return data.count <= maximumFileSize ? data : nil
    }

    /// The files an `Include` path names: `~/` against `home`, a relative
    /// path against `~/.ssh`, then globbed (sorted, as ssh does). Nothing
    /// when nothing matches, and for any other path starting with `~`
    /// (`~`, `~user/x`).
    static func expand(_ pattern: String, home: String) -> [String] {
        var path = pattern
        if path.hasPrefix("~"), !path.hasPrefix("~/") {
            return []
        } else if path.hasPrefix("~/") {
            path = (home.hasSuffix("/") ? String(home.dropLast()) : home) + path.dropFirst()
        } else if !path.hasPrefix("/") {
            path = sshDirectory(home: home) + "/" + path
        }
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(path, 0, nil, &matches) == 0 else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { index in
            matches.gl_pathv[index].map { String(cString: $0) }
        }
    }

    // MARK: Words

    /// A line's keyword and arguments as ssh_config(5) reads them: the
    /// keyword ends at whitespace or `=`; one `=` (with whitespace around
    /// it) may separate it from the arguments; arguments are split as
    /// ``words(_:)`` says. `nil` for a blank or comment line, and for a
    /// line with an unterminated quote, which ssh rejects.
    static func keywordAndArguments(_ line: String) -> (String, [String])? {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first, first != "#", !first.isNewline else { return nil }
        let keyword = rest.prefix { !($0 == " " || $0 == "\t" || $0 == "=") }
        guard !keyword.isEmpty else { return nil }
        rest = rest.dropFirst(keyword.count).drop { $0 == " " || $0 == "\t" }
        if rest.first == "=" { rest = rest.dropFirst() }
        guard let arguments = words(rest) else { return nil }
        return (String(keyword), arguments)
    }

    /// Arguments as OpenSSH's `argv_split` (misc.c) splits them: separated
    /// by whitespace, grouped by `"` or `'`. A backslash escapes a following
    /// `'`, `"` or `\` in every quote state, and a following space only
    /// outside quotes; before anything else it stays a backslash. An
    /// unquoted word starting with `#` ends the line. `nil` when a quote is
    /// not closed.
    static func words(_ text: Substring) -> [String]? {
        var result: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\\", next < text.endIndex {
                let following = text[next]
                if following == "'" || following == "\"" || following == "\\" || (quote == nil && following == " ") {
                    current.append(text[next])
                    inWord = true
                    index = text.index(after: next)
                    continue
                }
            }
            index = next
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            switch character {
            case " ", "\t", "\r":
                if inWord { result.append(current) }
                current = ""
                inWord = false
            case "\"", "'":
                quote = character
                inWord = true
            case "#" where !inWord:
                return result
            default:
                current.append(character)
                inWord = true
            }
        }
        guard quote == nil else { return nil }
        if inWord { result.append(current) }
        return result
    }
}
