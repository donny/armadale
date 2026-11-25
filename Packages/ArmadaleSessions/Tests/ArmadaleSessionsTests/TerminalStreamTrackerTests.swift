import Foundation
import Testing
@testable import ArmadaleSessions

/// ``TerminalStreamTracker`` (docs/DESIGN.md section 7, "Recording a
/// pane"): between sequences or inside one, as SwiftTerm 1.99.0's parser
/// sees the stream.
@Suite("Terminal stream tracker")
struct TerminalStreamTrackerTests {
    private static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// Whole sequences and characters: inside each, never between
    /// sequences; after each, between.
    static let tokens: [(name: String, bytes: [UInt8])] = [
        ("SGR", bytes("\u{1b}[38;5;196m")),
        ("SGR with colons", bytes("\u{1b}[4:3;58:2::1:2:3m")),
        ("CUP", bytes("\u{1b}[10;5H")),
        ("private mode", bytes("\u{1b}[?1049h")),
        ("CSI intermediate", bytes("\u{1b}[2 q")),
        ("CSI ignored", bytes("\u{1b}[1<2m")),
        ("ESC intermediate", bytes("\u{1b}(B")),
        ("DECSC", bytes("\u{1b}7")),
        ("OSC with BEL", bytes("\u{1b}]0;my title\u{07}")),
        ("OSC with ST", bytes("\u{1b}]2;t\u{1b}\\")),
        ("OSC with UTF-8", bytes("\u{1b}]0;é ü ñ\u{07}")),
        ("OSC 7501", bytes("\u{1b}]7501;status\u{1b}\\")),
        ("OSC with C1 ST", bytes("\u{1b}]0;x") + [0x9C]),
        ("DCS", bytes("\u{1b}P$qm\u{1b}\\")),
        ("DCS with parameters", bytes("\u{1b}P1;2|abc\u{1b}\\")),
        ("APC", bytes("\u{1b}_Gpayload\u{1b}\\")),
        ("PM", bytes("\u{1b}^private\u{1b}\\")),
        ("SOS", bytes("\u{1b}Xstring\u{1b}\\")),
        ("2-byte character", bytes("é")),
        ("3-byte character", bytes("€")),
        ("4-byte character", bytes("👍")),
    ]

    @Test func insideASequenceAndBetweenSequences() {
        for token in Self.tokens {
            var whole = TerminalStreamTracker()
            whole.feed(Self.bytes("text "))
            #expect(whole.isBetweenSequences)
            whole.feed(token.bytes)
            #expect(whole.isBetweenSequences, "after \(token.name)")
            // Byte by byte: inside until the last byte.
            var single = TerminalStreamTracker()
            for (index, byte) in token.bytes.enumerated() {
                single.feed([byte])
                #expect(single.isBetweenSequences == (index == token.bytes.count - 1), "\(token.name) at byte \(index)")
            }
        }
    }

    /// Every token split in two batches at every byte: inside after the
    /// first part, between after the second; ``feedToFirstGround(_:)``
    /// finds the end of the token.
    @Test func sequencesSplitAtEveryByte() {
        for token in Self.tokens {
            for cut in 1..<token.bytes.count {
                var tracker = TerminalStreamTracker()
                tracker.feed(Self.bytes("a"))
                tracker.feed(token.bytes[..<cut])
                #expect(!tracker.isBetweenSequences, "\(token.name) cut at \(cut)")
                let rest = token.bytes[cut...] + Self.bytes("RED")
                #expect(tracker.feedToFirstGround(rest) == token.bytes.count - cut, "\(token.name) cut at \(cut)")
                #expect(tracker.isBetweenSequences)
                tracker.feed(rest.dropFirst(token.bytes.count - cut))
                #expect(tracker.isBetweenSequences)
            }
        }
    }

    @Test func everyStateIsReached() {
        var seen: Set<TerminalStreamTracker.State> = []
        let inputs = Self.tokens.map(\.bytes) + [Self.bytes("\u{1b}P:x\u{1b}\\"), Self.bytes("\u{1b}P$1\u{1b}\\")]
        for input in inputs {
            var tracker = TerminalStreamTracker()
            for byte in input {
                tracker.feed([byte])
                seen.insert(tracker.state)
            }
        }
        #expect(seen == Set(TerminalStreamTracker.State.allCases), "missing \(Set(TerminalStreamTracker.State.allCases).subtracting(seen))")
    }

    /// What SwiftTerm's table makes of CAN, SUB, ESC and C1 bytes.
    @Test func cancellingAndC1BytesFollowSwiftTerm() {
        func state(after text: [UInt8]) -> TerminalStreamTracker.State {
            var tracker = TerminalStreamTracker()
            tracker.feed(text)
            return tracker.state
        }
        // CAN and SUB do not end a CSI in SwiftTerm (its C0 executables
        // were added to the CSI states after the "anywhere" rules)...
        #expect(state(after: Self.bytes("\u{1b}[3\u{18}")) == .csiParam)
        #expect(state(after: Self.bytes("\u{1b}[\u{1a}")) == .ground, "SUB is not a C0 executable there")
        // ...but they end a string and an escape.
        #expect(state(after: Self.bytes("\u{1b}]0;t\u{18}")) == .ground)
        #expect(state(after: Self.bytes("\u{1b}\u{1a}")) == .ground)
        // In an escape, CAN is executed and the escape goes on.
        #expect(state(after: Self.bytes("\u{1b}\u{18}")) == .escape)
        // ESC starts over anywhere.
        #expect(state(after: Self.bytes("\u{1b}[12\u{1b}")) == .escape)
        // A C1 ST continuing a UTF-8 character of an OSC payload does not
        // end it (✔ is E2 9C 94); a lone one does.
        #expect(state(after: Self.bytes("\u{1b}]0;") + [0xE2, 0x9C]) == .oscString)
        #expect(state(after: Self.bytes("\u{1b}]0;ab") + [0x9C]) == .ground)
        // A C1 byte opening a batch inside an OSC goes through the table
        // and ends it (so an OSC payload with a UTF-8 continuation byte
        // below 0xA0 at the start of a batch ends there, in SwiftTerm as
        // here); inside a run it is payload.
        var tracker = TerminalStreamTracker()
        tracker.feed(Self.bytes("\u{1b}]0;") + [0xE2])
        tracker.feed([0x82, 0xAC])
        #expect(tracker.state == .ground)
        // In the ground state C1 bytes are printed.
        #expect(state(after: [0x9B, 0x41]) == .ground)
        // OSC 7501 ended by ESC and something other than `\`: an escape
        // sequence starts with that byte.
        #expect(state(after: Self.bytes("\u{1b}]7501;x\u{1b}[")) == .csiEntry)
        // A UTF-8 character interrupted by a control is no longer open.
        #expect(TerminalStreamTracker.expectsUTF8Continuation([0xE2]))
        var cut = TerminalStreamTracker()
        cut.feed([0xE2, 0x0A])
        #expect(cut.isBetweenSequences)
    }

    /// The same answers whether a batch is followed byte by byte or as a
    /// whole (the fast path skips runs of text and string payload).
    @Test func wholeBatchesAndSingleBytesAgree() {
        var all: [UInt8] = []
        for (index, token) in Self.tokens.enumerated() {
            all += token.bytes + Self.bytes("plain \(index) é漢👍 ")
        }
        for chunk in [1, 2, 3, 5, 7, 64, all.count] {
            var whole = TerminalStreamTracker(), slow = TerminalStreamTracker()
            var index = 0
            while index < all.count {
                let piece = all[index..<min(index + chunk, all.count)]
                whole.feed(piece)
                // The byte-by-byte path, stopping at every point between
                // sequences and going on with the rest of the batch.
                var rest = piece
                while let used = slow.feedToFirstGround(rest) { rest = rest.dropFirst(used) }
                #expect(whole.state == slow.state && whole.pendingContinuations == slow.pendingContinuations,
                        "chunks of \(chunk) at \(index)")
                index += chunk
            }
            #expect(whole.isBetweenSequences, "chunks of \(chunk)")
        }
    }

    /// The cost on every byte the surface is fed: printed in the test log.
    @Test func trackingIsCheap() {
        var output: [UInt8] = []
        var line = 0
        while output.count < 1 << 20 {
            output += Self.bytes("\u{1b}[3\(line % 8);1m\(line)\u{1b}[0m step \u{1b}[38;2;10;20;30mdone ✔ 漢字\u{1b}[K\r\n")
            line += 1
        }
        var tracker = TerminalStreamTracker()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for start in stride(from: 0, to: output.count, by: 1024) {
                tracker.feed(output[start..<min(start + 1024, output.count)])
            }
        }
        let microsecondsPerKB = Double(elapsed.components.attoseconds) / 1e12 / Double(output.count / 1024)
            + Double(elapsed.components.seconds) * 1e6 / Double(output.count / 1024)
        print("TRACKER: \(output.count) bytes of colourful output in \(elapsed); \(microsecondsPerKB) µs per KB")
        #expect(tracker.isBetweenSequences)
        #expect(microsecondsPerKB < 500, "far too slow: \(microsecondsPerKB) µs per KB")
    }
}
