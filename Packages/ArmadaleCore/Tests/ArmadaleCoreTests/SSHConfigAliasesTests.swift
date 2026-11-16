import Foundation
import Testing
@testable import ArmadaleCore

/// The aliases of an ssh configuration (``SSHConfigAliases``), from strings
/// and from temporary folders standing in for a home folder. Nothing here
/// reads the real `~/.ssh/config`.
@Suite("SSH config aliases")
struct SSHConfigAliasesTests {
    // MARK: Lines

    @Test func hostLinesInEveryAllowedSpelling() {
        let text = """
            # a comment
            Host alpha
              HostName alpha.example.com
            host Beta gamma
            HOST=delta
            Host = epsilon
            Host\t"zeta eta" 'theta'
            \tHost iota # a trailing comment
            Hostname not-a-host
            HostKeyAlias not-a-host-either

            """
        #expect(SSHConfigAliases.lines(of: text) == [
            .host(["alpha"]), .host(["Beta", "gamma"]), .host(["delta"]), .host(["epsilon"]),
            .host(["zeta eta", "theta"]), .host(["iota"]),
        ])
    }

    @Test func wildcardsAndNegationsAreNotAliases() {
        let text = """
            Host *
            Host *.example.com web?? !bastion box
            Host github.com
            """
        #expect(SSHConfigAliases.aliases(inText: text) == ["box", "github.com"])
        #expect(!SSHConfigAliases.isAlias(""))
        #expect(!SSHConfigAliases.isAlias("!x"))
        #expect(SSHConfigAliases.isAlias("user-box.local"))
    }

    @Test func everythingElseIsIgnoredMatchBlocksIncluded() {
        let text = """
            Match host foo exec "true"
              User me
            Host after-match
            IdentityFile ~/.ssh/id
            ProxyJump jump
            """
        #expect(SSHConfigAliases.lines(of: text) == [.host(["after-match"])])
    }

    @Test func aliasesAreDeduplicatedInFirstSeenOrder() {
        let text = """
            Host b a
            Host c b
            Host a d
            """
        #expect(SSHConfigAliases.aliases(inText: text) == ["b", "a", "c", "d"])
    }

    @Test func includeLinesKeepTheirPaths() {
        #expect(SSHConfigAliases.lines(of: "Include a.conf ~/b \"/c d\"\ninclude=e") == [
            .include(["a.conf", "~/b", "/c d"]), .include(["e"]),
        ])
    }

    @Test func blankCommentAndOddLinesGiveNothing() {
        #expect(SSHConfigAliases.lines(of: "").isEmpty)
        #expect(SSHConfigAliases.lines(of: "   \n\t\n# Host x\n=\nHost").count == 1)
        #expect(SSHConfigAliases.aliases(inText: "Host").isEmpty, "a Host line with no pattern")
        #expect(SSHConfigAliases.aliases(inText: "Host a\r\nHost b\r\n") == ["a", "b"], "CRLF lines")
    }

    // MARK: Matching

    @Test func suggestionsStartWithPrefixesThenContainingIgnoringCase() {
        let aliases = ["lima-default", "build", "Limbo", "my-lima", "lima"]
        #expect(SSHConfigAliases.suggestions(for: "", in: aliases) == aliases, "nothing typed: all")
        #expect(SSHConfigAliases.suggestions(for: "lim", in: aliases) == ["lima-default", "Limbo", "lima", "my-lima"])
        #expect(SSHConfigAliases.suggestions(for: " LIMA ", in: aliases) == ["lima-default", "lima", "my-lima"])
        #expect(SSHConfigAliases.suggestions(for: "lima", in: aliases) == ["lima-default", "my-lima"],
                "an exact match has nothing to complete")
        #expect(SSHConfigAliases.suggestions(for: "zzz", in: aliases).isEmpty)
        #expect(SSHConfigAliases.suggestions(for: "", in: (1...30).map { "h\($0)" }, limit: 5).count == 5)
    }

    // MARK: Files

    /// A temporary folder standing in for a home folder, with `.ssh` in it.
    private final class Home {
        let path: String
        var ssh: String { path + "/.ssh" }

        init() throws {
            path = FileManager.default.temporaryDirectory
                .appendingPathComponent("armadale-sshconfig-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: path + "/.ssh", withIntermediateDirectories: true)
        }

        func write(_ text: String, to relative: String) throws {
            let url = URL(fileURLWithPath: path + "/" + relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        deinit {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    @Test func aMissingConfigOrHomeGivesNothing() throws {
        let home = try Home()
        #expect(SSHConfigAliases.aliases(home: home.path).isEmpty)
        #expect(SSHConfigAliases.aliases(home: home.path + "/nowhere").isEmpty)
    }

    @Test func theUserConfigIsReadFromTheHomeFolderGiven() throws {
        let home = try Home()
        try home.write("Host one two\nHost *\n", to: ".ssh/config")
        #expect(SSHConfigAliases.aliases(home: home.path) == ["one", "two"])
        #expect(SSHConfigAliases.aliases(home: home.path + "/") == ["one", "two"], "a trailing slash")
    }

    @Test func includesAreFollowedInPlaceRelativeTildeAndAbsolute() throws {
        let home = try Home()
        try home.write("Host relative\n", to: ".ssh/relative.conf")
        try home.write("Host tilde\n", to: "elsewhere/tilde.conf")
        try home.write("Host absolute\n", to: "abs/absolute.conf")
        try home.write("""
            Host first
            Include relative.conf ~/elsewhere/tilde.conf
            Host middle
            Include \(home.path)/abs/absolute.conf missing.conf
            Host last
            """, to: ".ssh/config")
        #expect(SSHConfigAliases.aliases(home: home.path) == ["first", "relative", "tilde", "middle", "absolute", "last"])
    }

    @Test func includeGlobsAreSorted() throws {
        let home = try Home()
        try home.write("Host b-host\n", to: ".ssh/config.d/b.conf")
        try home.write("Host a-host\n", to: ".ssh/config.d/a.conf")
        try home.write("Host not-matched\n", to: ".ssh/config.d/c.txt")
        try home.write("Include config.d/*.conf\nHost main\n", to: ".ssh/config")
        #expect(SSHConfigAliases.aliases(home: home.path) == ["a-host", "b-host", "main"])
    }

    @Test func anIncludeCycleEnds() throws {
        let home = try Home()
        try home.write("Host one\nInclude two.conf\n", to: ".ssh/config")
        try home.write("Host two\nInclude config ~/.ssh/two.conf\n", to: ".ssh/two.conf")
        #expect(SSHConfigAliases.aliases(home: home.path) == ["one", "two"])
    }

    @Test func includesStopAtSshsDepthLimit() throws {
        let home = try Home()
        // config → n1 → n2 → … each adding its own alias.
        try home.write("Host n0\nInclude n1.conf\n", to: ".ssh/config")
        for depth in 1...20 {
            try home.write("Host n\(depth)\nInclude n\(depth + 1).conf\n", to: ".ssh/n\(depth).conf")
        }
        let aliases = SSHConfigAliases.aliases(home: home.path)
        #expect(aliases == (0...SSHConfigAliases.maximumIncludeDepth).map { "n\($0)" })
    }

    @Test func anUnreadableFileGivesNothingAndTheRestStill() throws {
        let home = try Home()
        try home.write("Host secret\n", to: ".ssh/secret.conf")
        try home.write("Include secret.conf\nHost open\n", to: ".ssh/config")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home.ssh + "/secret.conf")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.ssh + "/secret.conf")
        }
        #expect(SSHConfigAliases.aliases(home: home.path) == ["open"])

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home.ssh + "/config")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.ssh + "/config") }
        #expect(SSHConfigAliases.aliases(home: home.path).isEmpty)
    }

    @Test func anUnreadableSshFolderGivesNothing() throws {
        let home = try Home()
        try home.write("Host x\n", to: ".ssh/config")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home.ssh)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.ssh) }
        #expect(SSHConfigAliases.aliases(home: home.path).isEmpty)
    }

    @Test func readingNeverWrites() throws {
        let home = try Home()
        let text = "Host keep\nInclude nothing-here/*\n"
        try home.write(text, to: ".ssh/config")
        let before = try FileManager.default.contentsOfDirectory(atPath: home.ssh)
        _ = SSHConfigAliases.aliases(home: home.path)
        #expect(try String(contentsOfFile: home.ssh + "/config", encoding: .utf8) == text)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.ssh) == before)
    }

    // MARK: After the review

    /// Only aliases ``Host/destinationProblem(_:)`` accepts are offered.
    @Test func aliasesADestinationCannotUseAreLeftOut() {
        #expect(SSHConfigAliases.aliases(inText: "Host \"a b\" -x ok\nHost=-oProxyCommand=y") == ["ok"])
        #expect(!SSHConfigAliases.isAlias("a b"))
        #expect(!SSHConfigAliases.isAlias("-x"))
    }

    /// A line with an unterminated quote is dropped, as ssh rejects it.
    @Test func anUnterminatedQuoteDropsTheLine() {
        #expect(SSHConfigAliases.lines(of: "Host \"open\nHost 'also\nHost fine") == [.host(["fine"])])
        #expect(SSHConfigAliases.aliases(inText: "Host a \"b") .isEmpty)
    }

    /// Backslashes as OpenSSH's `argv_split` reads them: `'`, `"` and `\`
    /// are escaped in every quote state, a space only outside quotes, and
    /// before anything else the backslash stays.
    @Test func backslashesEscapeAsArgvSplitDoes() {
        func words(_ text: String) -> [String]? { SSHConfigAliases.words(Substring(text)) }
        #expect(words(#"a\ b"#) == ["a b"], "a space outside quotes")
        #expect(words(#"a\\b \"q\" \'s\'"#) == [#"a\b"#, "\"q\"", "'s'"])
        #expect(words(#"a\nb"#) == [#"a\nb"#], "before anything else it stays")
        #expect(words(#""x\'y""#) == ["x'y"], "\\' inside double quotes")
        #expect(words(#"'x\"y'"#) == ["x\"y"], "\\\" inside single quotes")
        #expect(words(#""x\\y\"z""#) == [#"x\y"z"#])
        #expect(words(#"'x\'y\\z'"#) == [#"x'y\z"#])
        #expect(words(#""a\ b""#) == [#"a\ b"#], "a space inside double quotes keeps the backslash")
        #expect(words(#"'a\ b'"#) == [#"a\ b"#], "and inside single quotes")
        #expect(words("\"unclosed") == nil)
    }

    /// An `Include` path starting with `~` but not `~/` names nothing.
    @Test func anIncludeOfAnotherUsersHomeNamesNothing() throws {
        let home = try Home()
        try home.write("Host trap\n", to: ".ssh/~user/x")
        try home.write("Host trap2\n", to: ".ssh/~")
        try home.write("Include ~user/x ~\nHost main\n", to: ".ssh/config")
        #expect(SSHConfigAliases.aliases(home: home.path) == ["main"])
        #expect(SSHConfigAliases.expand("~user/x", home: home.path).isEmpty)
    }

    /// A FIFO is never opened: as the config file or as an include, the
    /// read returns at once with nothing from it.
    @Test func aFIFOIsNotRead() throws {
        let home = try Home()
        #expect(mkfifo(home.ssh + "/config", 0o600) == 0)
        #expect(SSHConfigAliases.aliases(home: home.path).isEmpty)

        let other = try Home()
        #expect(mkfifo(other.ssh + "/pipe", 0o600) == 0)
        try other.write("Include pipe\nHost after\n", to: ".ssh/config")
        #expect(SSHConfigAliases.aliases(home: other.path) == ["after"])
    }

    /// A file larger than the limit is skipped; one at the limit is read.
    @Test func aFileOverTheSizeLimitIsSkipped() throws {
        let home = try Home()
        let limit = SSHConfigAliases.maximumFileSize
        func padded(_ host: String, to size: Int) -> String {
            let line = "Host \(host)\n"
            return line + String(repeating: "#", count: size - line.utf8.count)
        }
        try home.write(padded("at-limit", to: limit), to: ".ssh/at.conf")
        try home.write(padded("over-limit", to: limit + 1), to: ".ssh/over.conf")
        try home.write("Include at.conf over.conf\n", to: ".ssh/config")
        #expect(SSHConfigAliases.aliases(home: home.path) == ["at-limit"])
    }

    /// At most ``SSHConfigAliases/maximumFiles`` files are read in one read,
    /// the top file included: the 257th is not.
    @Test func atMostTheFileLimitIsRead() throws {
        let home = try Home()
        let count = SSHConfigAliases.maximumFiles + 10
        for n in 1...count {
            try home.write("Host h\(String(format: "%03d", n))\n", to: ".ssh/d/\(String(format: "%03d", n)).conf")
        }
        try home.write("Host top\nInclude d/*.conf\n", to: ".ssh/config")
        let aliases = SSHConfigAliases.aliases(home: home.path)
        #expect(aliases.count == SSHConfigAliases.maximumFiles)
        #expect(aliases.first == "top")
        #expect(aliases.last == String(format: "h%03d", SSHConfigAliases.maximumFiles - 1))
        #expect(!aliases.contains(String(format: "h%03d", SSHConfigAliases.maximumFiles)), "the 257th file")
    }
}
