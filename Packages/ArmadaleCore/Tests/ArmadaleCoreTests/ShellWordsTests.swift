import Testing
@testable import ArmadaleCore

@Suite("ShellWords")
struct ShellWordsTests {
    @Test(arguments: [
        ("", []),
        ("   ", []),
        ("a", ["a"]),
        ("  a   b\tc\nd  ", ["a", "b", "c", "d"]),
        ("--model opus", ["--model", "opus"]),
        ("'a b' c", ["a b", "c"]),
        (#""a b" c"#, ["a b", "c"]),
        (#"--name="a b""#, ["--name=a b"]),
        (#"pre'mid'post"#, ["premidpost"]),
        (#"'it''s'"#, ["its"]),
        (#"'a\b'"#, [#"a\b"#]),
        (#"'say "hi"'"#, [#"say "hi""#]),
        (#""it's""#, ["it's"]),
        (#""a \"q\" b""#, [#"a "q" b"#]),
        (#""back\\slash""#, [#"back\slash"#]),
        (#""keep\n""#, [#"keep\n"#]),
        (#""\$HOME""#, [#"\$HOME"#]), // deliberate: only \" and \\ are escapes in double quotes
        (#"a\ b"#, ["a b"]),
        (#"\'x\'"#, ["'x'"]),
        (#"\"x"#, [#""x"#]),
        (#"end\"#, [#"end\"#]),
        ("'' x", ["", "x"]),
        (#""" """#, ["", ""]),
        ("$HOME ~ *", ["$HOME", "~", "*"]),
        ("'unterminated words", ["unterminated words"]),
        (#"a "open quote"#, ["a", "open quote"]),
        (#""open \"#, [#"open \"#]),
        ("'", [""]),
    ] as [(String, [String])])
    func splits(text: String, words: [String]) {
        #expect(ShellWords.split(text) == words)
    }
}
