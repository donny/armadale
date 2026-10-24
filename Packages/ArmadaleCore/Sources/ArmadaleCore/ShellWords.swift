import Foundation

/// Splits one line of text into arguments like a shell, simplified: no
/// variable expansion, globbing or command substitution; inside double
/// quotes only `\"` and `\\` are escapes. For the New Session dialog's
/// "Additional arguments" field (DESIGN §8 "New sessions"). Pure.
///
/// - Unquoted whitespace (spaces, tabs, newlines) separates words; runs of
///   it count once, and leading or trailing whitespace makes no word.
/// - `'…'` groups its characters literally (a backslash in it is a
///   backslash).
/// - `"…"` groups its characters, with `\"` for a quote and `\\` for a
///   backslash; any other backslash in it is kept as written (`"\$HOME"`
///   is `\$HOME`, where a shell would give `$HOME`, and a backslash-newline
///   is not joined).
/// - Outside quotes a backslash makes the next character literal (`\ ` is a
///   space inside a word); a backslash at the very end is kept.
/// - Quotes join with what touches them (`--name="a b"` is one word) and an
///   empty pair (`''`, `""`) is an empty word.
/// - Nothing is expanded: `$HOME`, `~`, `*` and backticks stay as written.
/// - **An unterminated quote is closed at the end of the text**: its
///   characters so far form (the rest of) the last word, rather than the
///   whole line being refused. The field has no error state, and what the
///   user typed is kept, not dropped.
public enum ShellWords {
    public static func split(_ text: String) -> [String] {
        enum Quote { case none, single, double }
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote = Quote.none
        var characters = text.makeIterator()

        while let character = characters.next() {
            switch quote {
            case .single:
                if character == "'" { quote = .none } else { current.append(character) }
            case .double:
                if character == "\"" {
                    quote = .none
                } else if character == "\\" {
                    guard let next = characters.next() else { current.append("\\"); break }
                    if next != "\"" && next != "\\" { current.append("\\") }
                    current.append(next)
                } else {
                    current.append(character)
                }
            case .none:
                if character.isWhitespace {
                    if inWord {
                        words.append(current)
                        current = ""
                        inWord = false
                    }
                } else if character == "'" {
                    quote = .single
                    inWord = true
                } else if character == "\"" {
                    quote = .double
                    inWord = true
                } else if character == "\\" {
                    inWord = true
                    current.append(characters.next() ?? "\\")
                } else {
                    current.append(character)
                    inWord = true
                }
            }
        }
        if inWord { words.append(current) }
        return words
    }
}
