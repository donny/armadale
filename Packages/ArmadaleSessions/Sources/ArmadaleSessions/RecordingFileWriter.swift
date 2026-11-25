import Darwin
import Dispatch
import Foundation
import Synchronization

/// Writes a recording's file (docs/DESIGN.md section 7, "Recording a
/// pane"). The main actor hands it raw bytes and their times; turning them
/// into asciicast lines (decoding UTF-8 across batches, escaping) and
/// writing them happen on one serial queue of its own, in the order they
/// were handed over.
///
/// - **Backlog cap.** More than ``backlogLimit`` bytes handed over and not
///   yet written (a disk or a network volume that does not keep up) end
///   the recording as a failure.
/// - **Whole lines only.** Every line is written whole or not at all: a
///   write that fails or is cut short is truncated back to the end of the
///   last whole line, then the file is closed and the failure reported
///   once on ``failures``.
/// - **Closing.** ``finish(time:)`` writes what the decoder holds and
///   closes the file after everything handed over before it. A quit waits
///   for the writers it knows, within a bound
///   (``waitForWriters(_:until:)``).
public final class RecordingFileWriter: Sendable {
    /// Bytes handed over and not yet written past which the recording ends.
    public static let backlogLimit = 32 * 1024 * 1024

    /// `write(2)`, or a stand-in in tests.
    typealias WriteFunction = @Sendable (Int32, UnsafeRawPointer, Int) -> Int

    private struct State {
        var descriptor: Int32
        var isClosed = false
        /// ``finish(time:)`` was asked for, or the recording failed: nothing
        /// more is taken.
        var isEnding = false
        var hasFailed = false
        /// Bytes handed over, not yet written.
        var backlog = 0
        /// The file's length up to the end of the last whole line.
        var committed: off_t = 0
        var decoder = UTF8StreamDecoder()
        /// The time of the last event handed over.
        var lastTime: Double = 0
    }

    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "com.tinylittleapps.armadale.recording-writer")
    private let writeFunction: WriteFunction
    private let failureContinuation: AsyncStream<String>.Continuation
    /// One reason when the recording fails, then the end; just the end when
    /// the file is closed without a failure.
    public let failures: AsyncStream<String>
    /// The file it writes, when it was made with one.
    public let url: URL?

    /// Creates (or empties) the file at `url`. Throws, with the system's
    /// reason, when it cannot be created; nothing is left open then.
    public convenience init(url: URL) throws(RecordingError) {
        let descriptor = Darwin.open(url.path(percentEncoded: false), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw RecordingError.cannotCreateFile(name: url.lastPathComponent, reason: Self.reason(errno))
        }
        self.init(descriptor: descriptor, url: url)
    }

    /// Writes to an open descriptor, which it owns from now on, through
    /// `write` (tests stand in for it to make writes fail or fall short).
    init(descriptor: Int32, url: URL? = nil, write: @escaping WriteFunction = { Darwin.write($0, $1, $2) }) {
        self.url = url
        // A pipe or socket whose reader went away must fail the write, not
        // end the app.
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        state = Mutex(State(descriptor: descriptor))
        writeFunction = write
        (failures, failureContinuation) = AsyncStream.makeStream(of: String.self)
    }

    // MARK: Handing over

    /// The header line.
    public func header(columns: Int, rows: Int, timestamp: Int, title: String) {
        enqueue(byteCount: 0) { writer in
            writer.writeLine(Asciicast.headerLine(columns: columns, rows: rows, timestamp: timestamp, title: title))
        }
    }

    /// Output: `bytes` as fed to the surface, at `time` seconds.
    public func output(_ bytes: [UInt8], time: Double) {
        enqueue(byteCount: bytes.count, time: time) { writer in
            let text = writer.state.withLock { $0.decoder.decode(bytes) }
            if !text.isEmpty { writer.writeLine(Asciicast.outputLine(time: time, text: text)) }
        }
    }

    /// A resize to `columns` × `rows` at `time` seconds.
    public func resize(columns: Int, rows: Int, time: Double) {
        enqueue(byteCount: 0, time: time) { writer in
            writer.writeLine(Asciicast.resizeLine(time: time, columns: columns, rows: rows))
        }
    }

    /// Writes what the decoder holds (at `time`, or the last event's time)
    /// and closes the file once everything handed over before is written.
    public func finish(time: Double? = nil) {
        let accepted = state.withLock { state -> Bool in
            guard !state.isEnding else { return false }
            state.isEnding = true
            return true
        }
        guard accepted else { return }
        queue.async { [self] in
            let (tail, last) = state.withLock { ($0.decoder.finish(), $0.lastTime) }
            if !tail.isEmpty { writeLine(Asciicast.outputLine(time: max(time ?? last, last), text: tail)) }
            close()
        }
    }

    private func enqueue(byteCount: Int, time: Double? = nil, _ work: @escaping @Sendable (RecordingFileWriter) -> Void) {
        let verdict = state.withLock { state -> Bool? in
            guard !state.isEnding else { return nil }
            if let time { state.lastTime = max(state.lastTime, time) }
            state.backlog += byteCount
            if state.backlog > Self.backlogLimit {
                state.isEnding = true
                return false
            }
            return true
        }
        switch verdict {
        case true?:
            queue.async { [self] in
                work(self)
                state.withLock { $0.backlog -= byteCount }
            }
        case false?:
            fail("Writing it fell more than 32 MB behind the pane’s output")
        case nil:
            break
        }
    }

    // MARK: Waiting

    /// Returns once everything handed over so far has been written (or
    /// dropped after a failure), the closing too if it was asked for.
    public func drained() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    /// Waits until the work handed over so far is done, at most until
    /// `deadline`; returns whether it was.
    @discardableResult
    public func waitUntilDrained(until deadline: ContinuousClock.Instant) -> Bool {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { semaphore.signal() }
        let (seconds, attoseconds) = remaining.components
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        return semaphore.wait(timeout: .now() + .nanoseconds(nanoseconds)) == .success
    }

    /// Finishes each of `writers` whose file is still open and waits for
    /// them to close, all together at most until `deadline`: the quit.
    /// What has not been written by then is lost; what is on disk is whole
    /// lines, unless the app exits in the middle of a write.
    public static func waitForWriters(_ writers: [RecordingFileWriter], until deadline: ContinuousClock.Instant) {
        let open = writers.filter { !$0.isClosed }
        for writer in open { writer.finish() }
        for writer in open where !writer.waitUntilDrained(until: deadline) { break }
    }

    /// Whether the file has been closed (finished or failed).
    public var isClosed: Bool { state.withLock { $0.isClosed } }

    // MARK: On the queue

    private func writeLine(_ line: [UInt8]) {
        let (descriptor, committed) = state.withLock { state -> (Int32, off_t) in
            state.isClosed || state.hasFailed ? (-1, 0) : (state.descriptor, state.committed)
        }
        guard descriptor >= 0 else { return }
        var offset = 0
        while offset < line.count {
            let written = line.withUnsafeBytes { buffer in
                writeFunction(descriptor, buffer.baseAddress! + offset, line.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                let reason = written < 0 ? Self.reason(errno) : "The disk took no more"
                // Whole lines only: back to the end of the last one.
                _ = ftruncate(descriptor, committed)
                fail(reason)
                return
            }
        }
        state.withLock { $0.committed += off_t(line.count) }
    }

    /// Reports `reason` once and closes the file (on the queue, after what
    /// is under way).
    private func fail(_ reason: String) {
        let first = state.withLock { state -> Bool in
            state.isEnding = true
            guard !state.hasFailed else { return false }
            state.hasFailed = true
            return true
        }
        guard first else { return }
        failureContinuation.yield(reason)
        queue.async { [self] in close() }
    }

    private func close() {
        let descriptor = state.withLock { state -> Int32 in
            guard !state.isClosed else { return -1 }
            state.isClosed = true
            state.isEnding = true
            return state.descriptor
        }
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        failureContinuation.finish()
    }

    deinit {
        let descriptor = state.withLock { $0.isClosed ? -1 : $0.descriptor }
        if descriptor >= 0 { Darwin.close(descriptor) }
        failureContinuation.finish()
    }

    /// The system's reason for `code`, as a sentence without its period.
    static func reason(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

/// Why a recording could not start, or stopped.
public enum RecordingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The pane is recorded already.
    case alreadyRecording
    /// The session has ended (or its pane was closed).
    case sessionEnded
    /// The session is disconnected or unavailable, with no attach under way.
    case notConnected
    /// The session's first attach has not finished.
    case stillStarting
    /// The file could not be created.
    case cannotCreateFile(name: String, reason: String)
    /// Another pane is being recorded into that file.
    case fileInUse(name: String)

    public var description: String {
        switch self {
        case .alreadyRecording: "This pane is being recorded already."
        case .sessionEnded: "There is nothing to record: the session has ended."
        case .notConnected: "There is nothing to record: the session is not connected right now."
        case .stillStarting: "There is nothing to record yet: the session is still starting."
        case .cannotCreateFile(let name, let reason): "The file “\(name)” could not be created. \(reason)."
        case .fileInUse(let name): "Another pane is being recorded into “\(name)”. Choose another file."
        }
    }
}
