import Darwin
import Foundation
import Synchronization

/// What a one-shot command produced.
public struct CommandResult: Sendable, Hashable {
    /// The exit code, or `128 + signal` if the command was killed by a signal.
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs one-shot commands (`zmx ls`, `zmx kill`, ssh control commands)
/// with `Process`, collecting their output, with a timeout
/// (docs/DESIGN.md section 7).
///
/// - stdout and stderr are always pipes, never files: zmx writes
///   positionally at offset 0 and would overwrite a file's start.
/// - stdin is `/dev/null`, or a pipe fed with `input` (an upload over
///   ssh). Writing to it never raises SIGPIPE, even if the command exits
///   without reading everything.
/// - `ZMX_SESSION` and `ZMX_SESSION_PREFIX` are removed from every
///   environment, whatever the caller passes.
/// - On timeout the command gets SIGTERM, then SIGKILL a second later, and
///   ``run(executable:arguments:environment:timeout:)`` throws ``TimedOut``.
public actor CommandRunner {
    /// The command did not finish in time; it has been killed.
    public struct TimedOut: Error, CustomStringConvertible, Sendable {
        public let executable: String
        public let arguments: [String]
        public let timeout: Duration
        public var description: String {
            "\(([executable] + arguments).joined(separator: " ")) did not finish within \(timeout)"
        }
    }

    /// The command could not be started.
    public struct LaunchFailed: Error, CustomStringConvertible, Sendable {
        public let executable: String
        public let reason: String
        public var description: String { "Cannot run \(executable): \(reason)" }
    }

    /// How long to wait for the pipes to reach EOF after the command
    /// exited. Something it left running in the background could hold them
    /// open forever; what arrived by then is returned.
    static let drainTimeout: Duration = .seconds(1)

    public init() {}

    public func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String],
        input: Data? = nil,
        timeout: Duration = .seconds(10)
    ) async throws -> CommandResult {
        var environment = environment
        environment["ZMX_SESSION"] = nil
        environment["ZMX_SESSION_PREFIX"] = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let stdinPipe = input.map { _ in Pipe() }
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exit = Latch<Int32>()
        process.terminationHandler = { process in
            let status = process.terminationStatus
            exit.set(process.terminationReason == .uncaughtSignal ? 128 + status : status)
        }
        let stdout = PipeCollector(stdoutPipe.fileHandleForReading)
        let stderr = PipeCollector(stderrPipe.fileHandleForReading)

        do {
            try process.run()
        } catch {
            stdout.stop()
            stderr.stop()
            throw LaunchFailed(executable: executable, reason: error.localizedDescription)
        }
        // The child has its own copies; without closing ours, EOF never comes.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        if let stdinPipe, let input {
            try? stdinPipe.fileHandleForReading.close()
            Self.feed(input, to: stdinPipe.fileHandleForWriting)
        }

        guard let status = await exit.wait(timeout: timeout) else {
            let pid = process.processIdentifier
            process.terminate()
            if await exit.wait(timeout: .seconds(1)) == nil {
                Darwin.kill(pid, SIGKILL)
                _ = await exit.wait(timeout: .seconds(2))
            }
            stdout.stop()
            stderr.stop()
            throw TimedOut(executable: executable, arguments: arguments, timeout: timeout)
        }
        async let out = stdout.collect(timeout: Self.drainTimeout)
        async let err = stderr.collect(timeout: Self.drainTimeout)
        return CommandResult(status: status, stdout: await out, stderr: await err)
    }
}

extension CommandRunner {
    /// Writes `data` to a pipe off the caller's thread (a blocking write of
    /// megabytes must not hold a cooperative thread), then closes it so the
    /// command sees EOF. SIGPIPE is off for the pipe: a command that exits
    /// early makes the write fail with EPIPE instead of killing the app.
    nonisolated static func feed(_ data: Data, to handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }
}

/// Collects everything written to a pipe, from its readability handler.
private final class PipeCollector: Sendable {
    private let handle: FileHandle
    private let data = Mutex(Data())
    private let eof = Latch<Void>()

    init(_ handle: FileHandle) {
        self.handle = handle
        // The handler retains the collector until EOF or stop() removes it.
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                eof.set(())
            } else {
                data.withLock { $0.append(chunk) }
            }
        }
    }

    /// Waits for EOF (at most `timeout`), stops reading and returns the data.
    func collect(timeout: Duration) async -> Data {
        _ = await eof.wait(timeout: timeout)
        stop()
        return data.withLock { $0 }
    }

    func stop() {
        handle.readabilityHandler = nil
        try? handle.close()
    }
}
