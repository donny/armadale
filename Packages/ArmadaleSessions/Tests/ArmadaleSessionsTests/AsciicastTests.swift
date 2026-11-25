import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import ArmadaleSessions

/// The asciicast v2 writing a pane recording uses (docs/DESIGN.md section
/// 7, "Recording a pane"): the header, escaping, UTF-8 across batches, the
/// file writer.
@Suite("Asciicast")
struct AsciicastTests {
    private func object(_ line: [UInt8]) throws -> Any {
        #expect(line.last == 0x0A, "a line ends in a newline")
        #expect(line.dropLast().contains(0x0A) == false, "and holds no other")
        return try JSONSerialization.jsonObject(with: Data(line.dropLast()))
    }

    @Test func theHeaderHasTheFieldsInOrder() throws {
        let line = Asciicast.headerLine(columns: 120, rows: 40, timestamp: 1_795_000_000, title: "Claude \"Code\"")
        #expect(String(decoding: line, as: UTF8.self)
            == "{\"version\":2,\"width\":120,\"height\":40,\"timestamp\":1795000000,\"title\":\"Claude \\\"Code\\\"\",\"env\":{\"TERM\":\"xterm-256color\"}}\n")
        let header = try #require(try object(line) as? [String: Any])
        #expect(header["version"] as? Int == 2)
        #expect(header["width"] as? Int == 120)
        #expect(header["height"] as? Int == 40)
        #expect(header["timestamp"] as? Int == 1_795_000_000)
        #expect(header["title"] as? String == "Claude \"Code\"")
        #expect((header["env"] as? [String: String]) == ["TERM": "xterm-256color"])
    }

    @Test func eventsAreArraysOfTimeCodeAndData() throws {
        let output = try #require(try object(Asciicast.outputLine(time: 1.25, text: "hi\r\n")) as? [Any])
        #expect(output.count == 3)
        #expect(output[0] as? Double == 1.25)
        #expect(output[1] as? String == "o")
        #expect(output[2] as? String == "hi\r\n")
        let resize = try #require(try object(Asciicast.resizeLine(time: 2, columns: 80, rows: 24)) as? [Any])
        #expect(resize[1] as? String == "r")
        #expect(resize[2] as? String == "80x24")
        #expect(Asciicast.formatTime(0) == "0.000000")
        #expect(Asciicast.formatTime(-1) == "0.000000")
        #expect(Asciicast.formatTime(12345.6789) == "12345.678900")
        #expect(Asciicast.formatTime(1e-9) == "0.000000", "never exponent notation")
    }

    /// Every control character is escaped (C0, DEL, C1), quotes and
    /// backslashes too; the rest is UTF-8 as it is, and parses back.
    @Test func everyControlCharacterIsEscaped() throws {
        var text = ""
        for value in 0..<0x20 { text.unicodeScalars.append(Unicode.Scalar(UInt8(value))) }
        text += "\u{7F}\u{80}\u{9F}\"\\/é漢👍"
        let json = Asciicast.jsonString(text)
        for scalar in json.unicodeScalars {
            #expect(scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value), "raw \(scalar.value) in \(json)")
        }
        #expect(json.contains("\\u001b") && json.contains("\\n") && json.contains("\\u007f") && json.contains("\\u0080"))
        let parsed = try JSONSerialization.jsonObject(with: Data(("[" + json + "]").utf8)) as? [String]
        #expect(parsed == [text])
    }

    // MARK: UTF-8 across batches

    /// A 2-, 3- and 4-byte character split at every boundary decodes as the
    /// whole stream does.
    @Test(arguments: ["\u{E9}", "\u{20AC}", "\u{6F22}", "\u{1F44D}", "e\u{301}"])
    func aCharacterSplitAnywhereSurvives(character: String) {
        let stream = Array("a\(character)b\(character)".utf8)
        for first in 0...stream.count {
            for second in first...stream.count {
                var decoder = UTF8StreamDecoder()
                var text = decoder.decode(stream[..<first])
                text += decoder.decode(stream[first..<second])
                text += decoder.decode(stream[second...])
                text += decoder.finish()
                #expect(text == "a\(character)b\(character)", "split at \(first), \(second)")
            }
        }
    }

    @Test func atMostThreeBytesAreHeld() {
        var decoder = UTF8StreamDecoder()
        #expect(decoder.decode([0x61, 0xF0, 0x9F, 0x91]) == "a")
        #expect(decoder.heldCount == 3)
        #expect(decoder.decode([0x8D]) == "👍")
        #expect(decoder.heldCount == 0)
        #expect(decoder.decode([0xE6]) == "")
        #expect(decoder.heldCount == 1)
    }

    @Test func invalidBytesBecomeReplacementCharacters() {
        var decoder = UTF8StreamDecoder()
        #expect(decoder.decode([0x61, 0xFF, 0x62]) == "a\u{FFFD}b")
        #expect(decoder.decode([0x80, 0x63]) == "\u{FFFD}c", "a stray continuation byte")
        // A lead byte followed by something that does not continue it.
        #expect(decoder.decode([0xE6, 0x41]) == "\u{FFFD}A")
        #expect(decoder.decode([0xC0, 0xAF]) == "\u{FFFD}\u{FFFD}", "overlong")
        let whole = [UInt8]([0xE0, 0x80, 0x80, 0x41, 0xED, 0xA0, 0x80])
        for cut in 0...whole.count {
            var split = UTF8StreamDecoder()
            let text = split.decode(whole[..<cut]) + split.decode(whole[cut...]) + split.finish()
            #expect(text == String(decoding: whole, as: UTF8.self), "cut at \(cut)")
        }
    }

    @Test func finishingFlushesWhatIsHeld() {
        var decoder = UTF8StreamDecoder()
        #expect(decoder.decode([0x78, 0xE6, 0xBC]) == "x")
        #expect(decoder.finish() == "\u{FFFD}")
        #expect(decoder.finish() == "")
    }

    /// U+2028 and U+2029 are escaped: termcast's player splits lines on
    /// every newline character (`TermcastPlayer.swift`, `CharacterSet.newlines`).
    @Test func lineAndParagraphSeparatorsAreEscaped() throws {
        let line = Asciicast.outputLine(time: 0, text: "a\u{2028}b\u{2029}c\u{85}d")
        let text = String(decoding: line, as: UTF8.self)
        #expect(text == "[0.000000,\"o\",\"a\\u2028b\\u2029c\\u0085d\"]\n")
        #expect(text.dropLast().rangeOfCharacter(from: .newlines) == nil, "one line by Foundation's reckoning too")
        let event = try #require(try JSONSerialization.jsonObject(with: Data(line.dropLast())) as? [Any])
        #expect(event[2] as? String == "a\u{2028}b\u{2029}c\u{85}d")
    }

    // MARK: The writer

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "armadale-cast-\(UUID().uuidString).cast")
    }

    /// Raw bytes in, asciicast lines out, in order, decoded across batches;
    /// nothing is taken after the end.
    @Test func theWriterTurnsBytesIntoLinesInOrder() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingFileWriter(url: url)
        writer.header(columns: 80, rows: 24, timestamp: 7, title: "t")
        var expected = Asciicast.headerLine(columns: 80, rows: 24, timestamp: 7, title: "t")
        for index in 0..<2000 {
            writer.output(Array("line \(index)\r\n".utf8), time: Double(index))
            expected += Asciicast.outputLine(time: Double(index), text: "line \(index)\r\n")
        }
        writer.output([0xE6], time: 2000)
        writer.output([0xBC, 0xA2], time: 2001)
        expected += Asciicast.outputLine(time: 2001, text: "\u{6F22}")
        writer.resize(columns: 100, rows: 30, time: 2002)
        expected += Asciicast.resizeLine(time: 2002, columns: 100, rows: 30)
        writer.output([0x41, 0xE6], time: 2003)
        expected += Asciicast.outputLine(time: 2003, text: "A")
        writer.finish(time: 2004)
        expected += Asciicast.outputLine(time: 2004, text: "\u{FFFD}")
        writer.output(Array("late".utf8), time: 2005)
        await writer.drained()
        #expect(writer.isClosed)
        #expect(try Data(contentsOf: url) == Data(expected), "in order, held bytes flushed at the end, nothing after")
    }

    /// The file is playable at every moment: after each event written, the
    /// whole file parses line by line.
    @Test func theFileParsesAfterEveryEvent() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingFileWriter(url: url)
        writer.header(columns: 80, rows: 24, timestamp: 0, title: "t")
        let steps: [@Sendable () -> Void] = [
            { writer.output(Array("\u{1b}[2J\u{1b}[H".utf8), time: 0) },
            { writer.output(Array("漢字\r\n".utf8), time: 0.5) },
            { writer.resize(columns: 100, rows: 30, time: 1) },
            { writer.output(Array("\u{1b}]0;title\u{07}\"quoted\" \\ \u{2028}".utf8) + [0xC2, 0x9B], time: 1.5) },
        ]
        for (index, step) in steps.enumerated() {
            step()
            await writer.drained()
            #expect(try CastFile(url).events.count == index + 1)
        }
        writer.finish()
        await writer.drained()
        #expect(try CastFile(url).events.map(\.code) == ["o", "o", "r", "o"])
    }

    @Test func aFileThatCannotBeCreatedThrows() {
        let url = URL(fileURLWithPath: "/nonexistent-armadale-folder/x.cast")
        #expect(throws: RecordingError.self) { _ = try RecordingFileWriter(url: url) }
        do {
            _ = try RecordingFileWriter(url: url)
        } catch {
            #expect(error == .cannotCreateFile(name: "x.cast", reason: "No such file or directory"))
            #expect(error.description == "The file “x.cast” could not be created. No such file or directory.")
        }
    }

    /// A write that fails (here a pipe nobody reads) is reported once,
    /// closes the file and drops what follows; no SIGPIPE.
    @Test func aFailedWriteIsReportedOnce() async throws {
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        close(ends[0])
        let writer = RecordingFileWriter(descriptor: ends[1])
        writer.output(Array("first".utf8), time: 0)
        writer.output(Array("second".utf8), time: 1)
        var reasons: [String] = []
        for await reason in writer.failures { reasons.append(reason) }
        #expect(reasons == ["Broken pipe"])
        await writer.drained()
        #expect(writer.isClosed)
    }

    /// A write cut short, then failing, leaves the file at the end of the
    /// last whole line: never half a line.
    @Test func aWriteCutShortIsTruncatedToTheLastWholeLine() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        #expect(descriptor >= 0)
        /// Lets 300 bytes through in all, then fails with "No space left on device".
        final class Budget: Sendable {
            let left = Mutex(300)
        }
        let budget = Budget()
        let writer = RecordingFileWriter(descriptor: descriptor) { descriptor, bytes, count in
            let allowed = budget.left.withLock { left -> Int in
                let allowed = min(left, count)
                left -= allowed
                return allowed
            }
            guard allowed > 0 else {
                errno = ENOSPC
                return -1
            }
            return Darwin.write(descriptor, bytes, allowed)
        }
        writer.header(columns: 80, rows: 24, timestamp: 0, title: "t")
        for index in 0..<20 { writer.output(Array("output line \(index)\r\n".utf8), time: Double(index)) }
        var reasons: [String] = []
        for await reason in writer.failures { reasons.append(reason) }
        await writer.drained()
        #expect(reasons == ["No space left on device"])
        let data = try Data(contentsOf: url)
        #expect(data.count < 300 && data.last == 0x0A, "ends on a whole line: \(data.count) bytes")
        let file = try CastFile(url)
        #expect(file.events.count >= 1)
    }

    /// Output the disk does not take: past 32 MB behind, the recording
    /// ends as a failure, at once, without waiting for the disk.
    @Test func aBacklogPastTheCapEndsTheRecording() async throws {
        let gate = DispatchSemaphore(value: 0)
        let descriptor = open("/dev/null", O_WRONLY)
        let writer = RecordingFileWriter(descriptor: descriptor) { descriptor, bytes, count in
            gate.wait()
            gate.signal()
            return Darwin.write(descriptor, bytes, count)
        }
        let chunk = [UInt8](repeating: 0x41, count: 1024 * 1024)
        for index in 0..<40 { writer.output(chunk, time: Double(index)) }
        var reasons: [String] = []
        for await reason in writer.failures {
            reasons.append(reason)
            break
        }
        #expect(reasons == ["Writing it fell more than 32 MB behind the pane’s output"])
        gate.signal()
        await writer.drained()
        await writer.drained()
        #expect(writer.isClosed)
    }

    /// A quit waits for every open file at most until its deadline, also
    /// when a write never returns.
    @Test func waitingForOpenWritersIsBounded() async throws {
        let gate = DispatchSemaphore(value: 0)
        let descriptor = open("/dev/null", O_WRONLY)
        let stuck = RecordingFileWriter(descriptor: descriptor) { descriptor, bytes, count in
            gate.wait()
            return Darwin.write(descriptor, bytes, count)
        }
        stuck.output(Array("blocked".utf8), time: 0)
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let fine = try RecordingFileWriter(url: url)
        fine.header(columns: 80, rows: 24, timestamp: 0, title: "t")
        let started = ContinuousClock.now
        RecordingFileWriter.waitForWriters([stuck, fine], until: started + .milliseconds(300))
        let waited = ContinuousClock.now - started
        #expect(waited < .milliseconds(900), "bounded: \(waited)")
        #expect(!stuck.isClosed)
        gate.signal()
        await stuck.drained()
        await stuck.drained()
        #expect(stuck.isClosed)
        await fine.drained()
        #expect(fine.isClosed, "finished by the wait")
    }
}
