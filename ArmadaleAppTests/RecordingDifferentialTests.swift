import AppKit
import ArmadaleSessions
import Foundation
@testable import SwiftTermSurface
import TerminalSurface
import Testing

/// Collects the titles a surface reports.
@MainActor
private final class TitleLog: TerminalSurfaceDelegate {
    var titles: [String] = []
    func surface(_ surface: any TerminalSurface, didInput bytes: [UInt8]) {}
    func surface(_ surface: any TerminalSurface, didResize size: GridSize) {}
    func surface(_ surface: any TerminalSurface, didSetTitle title: String) { titles.append(title) }
    func surface(_ surface: any TerminalSurface, didChangeDirectory url: URL) {}
    func surfaceDidRingBell(_ surface: any TerminalSurface) {}
    func surface(_ surface: any TerminalSurface, didRequestClipboard op: ClipboardOp) {}
    func surface(_ surface: any TerminalSurface, didReceiveNotification title: String, body: String) {}
    func surface(_ surface: any TerminalSurface, didActivateLink link: String) {}
}

/// A small deterministic generator (SplitMix64).
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The guard for the tracker against SwiftTerm (docs/DESIGN.md section 7,
/// "Recording a pane"; re-run it at every SwiftTerm bump): for streams of
/// every kind of sequence, fed in random batches, a recording is asked for
/// at every byte offset and handled as the controller handles it (between
/// sequences: the snapshot at once; else pending, cut at the first point
/// between sequences, the snapshot there, then the rest). The screen and
/// the titles must equal those of a control fed the same batches with no
/// snapshot. The one known difference is SwiftTerm's own (DESIGN section
/// 13): a sequence left open at the end of a batch that held a RIS is
/// dropped by SwiftTerm, and the cut that feeds the RIS alone keeps it.
@Suite("Recording: the tracker against SwiftTerm", .serialized)
@MainActor
struct RecordingDifferentialTests {
    private static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// Every kind of token, each fed alone between text.
    static let tokens: [[UInt8]] = [
        // CSI and SGR
        bytes("\u{1b}[31m"), bytes("\u{1b}[38;5;196m"), bytes("\u{1b}[38:2::10:20:30m"), bytes("\u{1b}[4:3m"),
        bytes("\u{1b}[2;3H"), bytes("\u{1b}[?25l"), bytes("\u{1b}[2 q"), bytes("\u{1b}[K"), bytes("\u{1b}[1J"),
        bytes("\u{1b}[1<2m"), bytes("\u{1b}[3\u{7f}1m"), bytes("\u{1b}[3\n1m"), bytes("\u{1b}[3\u{18}1m"),
        bytes("\u{1b}[3\u{1a}1m"), bytes("\u{1b}[?1049h\u{1b}[?1049l"), bytes("\u{1b}[2;5r\u{1b}[r"),
        // OSC
        bytes("\u{1b}]0;title\u{07}"), bytes("\u{1b}]2;by st\u{1b}\\"), bytes("\u{1b}]0;c1 st") + [0x9C],
        bytes("\u{1b}]0;é 漢\u{07}"), bytes("\u{1b}]0;") + [0xE2, 0x9C, 0x94] + bytes("\u{07}"),
        bytes("\u{1b}]0;a\u{18}b"), bytes("\u{1b}]0;a\u{1b}b"), bytes("\u{1b}]0;a\u{01}b\u{07}"),
        bytes("\u{1b}]7;file:///tmp\u{07}"), bytes("\u{1b}]7501;status\u{1b}\\"), bytes("\u{1b}]7501;x\u{1b}z"),
        // DCS, APC, SOS, PM
        bytes("\u{1b}P$qm\u{1b}\\"), bytes("\u{1b}P1;2|abc\u{1b}\\"), bytes("\u{1b}Pab\u{18}c"),
        bytes("\u{1b}_Gpayload\u{1b}\\"), bytes("\u{1b}Xsos\u{1b}\\"), bytes("\u{1b}^pm\u{1b}\\"),
        // Character sets
        bytes("\u{1b}(0lqk\u{1b}(B"), bytes("\u{1b})0\u{0e}lqk\u{0f}"), bytes("\u{1b}(B"),
        // Raw C1 introducers, odd bytes
        [0x9B, 0x33, 0x31, 0x6D], [0x9D] + bytes("0;raw osc") + [0x07], [0x90] + bytes("$qm") + [0x9C],
        [0xFF], [0x80], [0xC3, 0x41],
        // Escapes
        bytes("\u{1b}c"), bytes("\u{1b}7"), bytes("\u{1b}8"), bytes("\u{1b}#8"), bytes("\u{1b}D"), bytes("\u{1b}M"),
        // Characters
        bytes("é"), bytes("€"), bytes("👍"), bytes("e\u{301}"), bytes("🇯🇵"), bytes("❤️"),
    ]

    /// Splits `stream` into batches of 1 to 17 bytes.
    private static func batches(_ stream: [UInt8], seed: UInt64) -> [[UInt8]] {
        var generator = SeededGenerator(state: seed)
        var result: [[UInt8]] = []
        var index = 0
        while index < stream.count {
            let size = Int.random(in: 1...17, using: &generator)
            result.append(Array(stream[index..<min(index + size, stream.count)]))
            index += size
        }
        return result
    }

    /// `batches` with a boundary at `offset` too.
    private static func splitting(_ batches: [[UInt8]], at offset: Int) -> (batches: [[UInt8]], index: Int) {
        var result: [[UInt8]] = []
        var position = 0
        for batch in batches {
            if offset > position && offset < position + batch.count {
                result.append(Array(batch[..<(offset - position)]))
                result.append(Array(batch[(offset - position)...]))
            } else {
                result.append(batch)
            }
            position += batch.count
        }
        var running = 0
        var index = result.count
        for (number, batch) in result.enumerated() {
            if running == offset { index = number; break }
            running += batch.count
        }
        return (result, index)
    }

    private func surface() -> SwiftTermSurface {
        let surface = SwiftTermSurface(appearance: TerminalAppearance(fontName: "Menlo", fontSize: 12))
        surface.setGridSize(columns: 24, rows: 6)
        return surface
    }

    /// One run: the recording asked for before batch `requestAt`.
    private struct Run {
        let pane: SwiftTermSurface
        let paneTitles: TitleLog
        let control: SwiftTermSurface
        let controlTitles: TitleLog
        /// The cut fed a batch's RIS apart from a sequence left open at the
        /// end of that batch (SwiftTerm's quirk applies to the control).
        let risQuirk: Bool
    }

    private func run(_ batches: [[UInt8]], requestAt: Int) -> Run {
        let pane = surface(), control = surface()
        let paneTitles = TitleLog(), controlTitles = TitleLog()
        pane.delegate = paneTitles
        control.delegate = controlTitles
        var tracker = TerminalStreamTracker()
        var pending = false
        var risQuirk = false
        for (number, batch) in batches.enumerated() {
            if number == requestAt {
                if tracker.isBetweenSequences { _ = pane.screenSnapshot() } else { pending = true }
            }
            control.feed(batch[...])
            if pending {
                let before = tracker
                if let cut = tracker.feedToFirstGround(batch) {
                    pending = false
                    pane.feed(batch[..<cut])
                    _ = pane.screenSnapshot()
                    let rest = batch[cut...]
                    if !rest.isEmpty {
                        tracker.feed(rest)
                        pane.feed(rest)
                    }
                    risQuirk = risQuirk || (Self.completesRIS(batch[..<cut], from: before) && !tracker.isBetweenSequences)
                } else {
                    pane.feed(batch[...])
                }
            } else {
                tracker.feed(batch)
                pane.feed(batch[...])
            }
        }
        if requestAt >= batches.count, tracker.isBetweenSequences { _ = pane.screenSnapshot() }
        return Run(pane: pane, paneTitles: paneTitles, control: control, controlTitles: controlTitles, risQuirk: risQuirk)
    }

    /// Whether `bytes` complete a RIS (`ESC c`), starting from `tracker`.
    private static func completesRIS(_ bytes: ArraySlice<UInt8>, from tracker: TerminalStreamTracker) -> Bool {
        var tracker = tracker
        for byte in bytes {
            if tracker.state == .escape, byte == 0x63 { return true }
            tracker.feed([byte])
        }
        return false
    }

    /// Runs every offset of `stream` and checks each against its control.
    private func check(_ stream: [UInt8], seed: UInt64, sourceLocation: SourceLocation = #_sourceLocation) async
        -> (offsets: Int, quirks: Int) {
        let base = Self.batches(stream, seed: seed)
        var runs: [(offset: Int, run: Run)] = []
        for offset in 0...stream.count {
            let (batches, index) = Self.splitting(base, at: offset)
            runs.append((offset, run(batches, requestAt: index)))
        }
        // Titles arrive on a later turn of the main queue.
        try? await Task.sleep(for: .milliseconds(30))
        var quirks = 0
        for (offset, run) in runs {
            let pane = run.pane.screenState(), control = run.control.screenState()
            let equal = pane == control && run.paneTitles.titles == run.controlTitles.titles
            if equal { continue }
            if run.risQuirk {
                quirks += 1
                continue
            }
            let differences = pane.flatMap { p in control.map { p.differences(from: $0) } } ?? ["no state"]
            let streamText = String(decoding: stream, as: UTF8.self).debugDescription
            let titles = "\(run.paneTitles.titles) vs \(run.controlTitles.titles)"
            let message: Comment = "offset \(offset) of \(streamText): \(differences.prefix(4)) titles \(titles)"
            Issue.record(message, sourceLocation: sourceLocation)
        }
        return (runs.count, quirks)
    }

    @Test func everyTokenAloneAtEveryOffset() async {
        var offsets = 0, quirks = 0
        for (index, token) in Self.tokens.enumerated() {
            let result = await check(Self.bytes("ab ") + token + Self.bytes(" cd\r\n"), seed: UInt64(index + 1))
            offsets += result.offsets
            quirks += result.quirks
        }
        print("DIFFERENTIAL: \(Self.tokens.count) tokens, \(offsets) offsets, \(quirks) with SwiftTerm's RIS quirk")
    }

    @Test(arguments: Array(1...10) as [UInt64])
    func seededMixesAtEveryOffset(seed: UInt64) async {
        var generator = SeededGenerator(state: seed &* 7919)
        var stream: [UInt8] = []
        for _ in 0..<14 {
            stream += Self.tokens[Int.random(in: 0..<Self.tokens.count, using: &generator)]
            let fillers = ["x", " ", "yz", "漢", "\r\n"]
            stream += Self.bytes(fillers[Int.random(in: 0..<fillers.count, using: &generator)])
        }
        let result = await check(stream, seed: seed)
        print("DIFFERENTIAL mix \(seed): \(result.offsets) offsets, \(result.quirks) with SwiftTerm's RIS quirk")
    }

    /// SwiftTerm's quirk, named: after a RIS in one parse call, a sequence
    /// left open at the end of that call is dropped
    /// (`EscapeSequenceParser.swift`, about lines 824–830 and 1434–1439).
    /// `"ok\ec\e"` then `"[31mC"` prints `[31mC` in the control; the pending
    /// recording's cut feeds `c` alone and the pane shows a red C, the right
    /// thing. When SwiftTerm fixes it, this fails: then remove the case here
    /// and in DESIGN section 13.
    @Test func swiftTermDropsASequenceOpenAfterARISInTheSameBatch() async throws {
        let batches = [Self.bytes("ok\u{1b}"), Self.bytes("c\u{1b}"), Self.bytes("[31mC")]
        let run = run(batches, requestAt: 1)
        #expect(run.risQuirk)
        let pane = try #require(run.pane.screenState()), control = try #require(run.control.screenState())
        #expect(pane.cells[0].prefix(1).map(\.text) == ["C"], "the pane: a red C")
        #expect(control.cells[0].prefix(5).map(\.text).joined() == "[31mC", "the control: the sequence dropped")
        #expect(pane != control)
    }
}
