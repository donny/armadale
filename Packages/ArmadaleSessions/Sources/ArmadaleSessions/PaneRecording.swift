import Foundation

/// A running recording of a pane, as the app sees it: where it goes and
/// when it started (``SessionController/recording``).
public struct RecordingInfo: Sendable, Equatable {
    public let url: URL
    public let startedAt: Date

    public init(url: URL, startedAt: Date) {
        self.url = url
        self.startedAt = startedAt
    }
}

/// A recording that stopped because its file could not be written (a full
/// disk, a volume gone): what was written before stays in the file.
public struct RecordingFailure: Sendable, Equatable {
    public let url: URL
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

/// One recording of a pane (docs/DESIGN.md section 7, "Recording a pane").
/// It hands its ``RecordingFileWriter`` raw bytes and their times; the
/// writer turns them into asciicast v2 lines off the main actor. The first
/// event, at time 0, is the surface's snapshot
/// (``TerminalSurface/screenSnapshot()``), then every batch fed to the
/// surface and every change of the grid size given to the program. Times
/// are seconds since the start on a monotonic clock and never go backwards.
///
/// A recording asked for while the output stream is inside a sequence is
/// *pending* (``isPending``): its file exists, nothing is written yet, and
/// it starts (``begin(columns:rows:snapshot:)``) at the first point
/// between sequences in the output that follows.
@MainActor
final class PaneRecording {
    let url: URL
    let writer: RecordingFileWriter
    let title: String
    let timestamp: Int
    private var start: ContinuousClock.Instant?
    private var lastTime: Double = 0
    private(set) var columns = 0
    private(set) var rows = 0

    init(url: URL, writer: RecordingFileWriter, timestamp: Int, title: String) {
        self.url = url
        self.writer = writer
        self.timestamp = timestamp
        self.title = title
    }

    /// Not started yet: waiting for the output to come between sequences.
    var isPending: Bool { start == nil }

    /// Starts: the header (`columns` × `rows`) and the snapshot at time 0.
    func begin(columns: Int, rows: Int, snapshot: [UInt8]) {
        guard start == nil else { return }
        start = ContinuousClock.now
        self.columns = columns
        self.rows = rows
        writer.header(columns: columns, rows: rows, timestamp: timestamp, title: title)
        if !snapshot.isEmpty { writer.output(snapshot, time: 0) }
    }

    /// What the surface was just fed (nothing while pending).
    func output(_ bytes: ArraySlice<UInt8>) {
        guard !isPending, !bytes.isEmpty else { return }
        writer.output(Array(bytes), time: elapsed())
    }

    /// The grid size given to the program; recorded when it changed.
    func resize(columns: Int, rows: Int) {
        guard !isPending, columns != self.columns || rows != self.rows else { return }
        self.columns = columns
        self.rows = rows
        writer.resize(columns: columns, rows: rows, time: elapsed())
    }

    /// Ends the recording; the writer closes the file once what it was
    /// handed is written. Still pending, it writes the header alone, with
    /// `columns` × `rows`, and no snapshot.
    func finish(columns: Int, rows: Int) {
        if isPending {
            writer.header(columns: columns, rows: rows, timestamp: timestamp, title: title)
            writer.finish(time: 0)
        } else {
            writer.finish(time: elapsed())
        }
    }

    /// Seconds since the start, never less than the last time given.
    private func elapsed() -> Double {
        guard let start else { return 0 }
        let duration = ContinuousClock.now - start
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        lastTime = max(lastTime, seconds)
        return lastTime
    }
}
