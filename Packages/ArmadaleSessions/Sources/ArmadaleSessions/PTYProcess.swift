import Darwin
import Dispatch
import Synchronization

/// How a process ended.
public enum Termination: Sendable, Hashable, CustomStringConvertible {
    /// It called `exit` with this code.
    case exited(Int32)
    /// It was killed by this signal.
    case signaled(Int32)
    /// Its status could not be collected (it was reaped elsewhere).
    case unknown

    /// Decodes a `waitpid` status.
    public init(waitStatus status: Int32) {
        let signal = status & 0x7F
        self = signal == 0 ? .exited((status >> 8) & 0xFF) : .signaled(signal)
    }

    /// The exit code, or `nil` if the process did not exit normally.
    public var exitCode: Int32? {
        if case .exited(let code) = self { return code }
        return nil
    }

    public var description: String {
        switch self {
        case .exited(let code): "exited with code \(code)"
        case .signaled(let signal): "killed by signal \(signal)"
        case .unknown: "ended (status unknown)"
        }
    }
}

/// A child process running on a pseudo-terminal that Armadale owns.
///
/// - Output is read with a `DispatchSource` on the non-blocking master into
///   a 64 KB buffer and delivered through ``output`` in coalesced batches
///   (see `OutputBuffer`). The stream finishes when the PTY reaches EOF/EIO,
///   or shortly after the process exits if a leftover background job still
///   holds the terminal open (the master is then closed).
/// - Input and resizes are applied in call order on a serial queue; writes
///   handle partial writes and `EAGAIN`.
/// - Exit is observed with a process `DispatchSource` and `waitpid`.
/// - Dropping the last reference closes the master; the kernel then hangs up
///   the terminal. The child is still reaped when it exits, so neither fds
///   nor zombies leak.
///
/// Sendable without `@unchecked`: all mutable state lives in a `Mutex`, and
/// file-descriptor work happens on one serial queue so the fd is never
/// closed while another operation is using it.
public final class PTYProcess: ProcessHandle {
    /// How to start the child.
    public struct Options: Sendable, Hashable {
        public enum Method: Sendable, Hashable {
            /// `posix_spawn` through the `ctty-exec` trampoline (default).
            case posixSpawn
            /// `forkpty()`; needs no helper. Fallback only.
            case forkpty
        }

        public var method: Method
        /// argv[0]; defaults to `program`. A leading `-` makes a shell a login shell.
        public var argv0: String?
        /// Path of `ctty-exec`; `nil` asks ``HelperLocator``.
        public var helperPath: String?

        public init(method: Method = .posixSpawn, argv0: String? = nil, helperPath: String? = nil) {
            self.method = method
            self.argv0 = argv0
            self.helperPath = helperPath
        }
    }

    /// The child's process ID.
    public let pid: pid_t
    /// The slave device, e.g. `/dev/ttys004`.
    public let ttyPath: String
    public let output: AsyncStream<[UInt8]>

    private struct IOState {
        /// The master, or -1 once shutdown has begun.
        var fd: Int32
        var readSource: (any DispatchSourceRead)?
        var isReadPaused = false
        /// Input not yet written; bytes before `writeOffset` are done.
        var writeBuffer: [UInt8] = []
        var writeOffset = 0
        var isWriteRetryArmed = false
    }

    private let queue: DispatchQueue
    private let io: Mutex<IOState>
    private let buffer: OutputBuffer
    private let exit = Latch<Termination>()
    private let closed = Latch<Void>()

    /// Starts `program` on a new PTY of `size`.
    ///
    /// - Parameters:
    ///   - program: Absolute path, or a name looked up in `environment`'s `PATH`.
    ///   - arguments: Arguments after argv[0].
    ///   - environment: The child's complete environment.
    ///   - workingDirectory: Directory to start in; `nil` keeps the app's.
    public static func spawn(
        program: String,
        arguments: [String] = [],
        environment: [String: String],
        workingDirectory: String? = nil,
        size: PTYSize,
        options: Options = Options()
    ) throws -> PTYProcess {
        let executable = try resolveExecutable(program, path: environment["PATH"])
        let request = SpawnRequest(
            executable: executable,
            argv: [options.argv0 ?? program] + arguments,
            environment: environment.map { "\($0.key)=\($0.value)" }.sorted(),
            workingDirectory: workingDirectory,
            size: size)
        let child: PTYChild
        switch options.method {
        case .posixSpawn:
            let helper = try options.helperPath ?? HelperLocator.cttyExec().path
            child = try spawnOnPTY(request, helper: helper)
        case .forkpty:
            child = try spawnWithForkpty(request)
        }
        return PTYProcess(child)
    }

    private init(_ child: PTYChild) {
        pid = child.pid
        ttyPath = child.slavePath
        let queue = DispatchQueue(label: "armadale.pty.\(child.pid)")
        self.queue = queue
        let flags = fcntl(child.masterFD, F_GETFL)
        _ = fcntl(child.masterFD, F_SETFL, flags | O_NONBLOCK)
        io = Mutex(IOState(fd: child.masterFD))

        // The buffer's resume hook must not retain `self` (a cycle would keep
        // a dropped process alive); a box filled in below breaks it.
        let resumeHook = WeakResume()
        buffer = OutputBuffer(queue: queue) { resumeHook.fire() }
        output = buffer.makeStream()
        resumeHook.target.withLock { $0 = WeakRef(self) }

        startReading(fd: child.masterFD)
        watchExit()
    }

    deinit {
        // Hang up: close the master, and send SIGHUP explicitly too, because
        // the kernel's hangup only reaches a child that has already acquired
        // the terminal (one dropped right after spawn may not have yet). The
        // signal is sent on the I/O queue, where reaping happens, so it can
        // never hit a reused pid. The exit source stays alive on its own and
        // reaps the child when it goes.
        let pid = pid
        let exit = exit
        queue.async {
            guard exit.value == nil else { return }
            kill(pid, SIGHUP)
            killpg(pid, SIGHUP)
        }
        beginShutdown()
    }

    // MARK: ProcessHandle

    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async { self.flushWrites(appending: bytes) }
    }

    public func resize(_ size: PTYSize) {
        queue.async {
            let fd = self.io.withLock { $0.fd }
            guard fd >= 0 else { return }
            var window = winsize(size)
            _ = ioctl(fd, TIOCSWINSZ, &window)
        }
    }

    /// SIGHUP, then SIGKILL if the process is still running 2 s later; then
    /// closes the master. Returns once the process is gone and the master is
    /// closed.
    public func terminate() async {
        await terminate(gracePeriod: .seconds(2))
    }

    /// Hangs up at once and returns without waiting: SIGHUP to the child,
    /// its group and the terminal's foreground job, then the master is
    /// closed. SIGKILL follows 2 s later if the child is still there (unless
    /// the app has exited by then, in which case the closed terminal has
    /// hung it up anyway). Used when quitting and to drop a flooded client.
    public func hangUp() {
        let pid = pid
        let exit = exit
        queue.sync {
            guard exit.value == nil else { return }
            let fd = io.withLock { $0.fd }
            let foreground = fd >= 0 ? tcgetpgrp(fd) : -1
            kill(pid, SIGHUP)
            killpg(pid, SIGHUP)
            if foreground > 0, foreground != pid { killpg(foreground, SIGHUP) }
            queue.asyncAfter(deadline: .now() + .seconds(2)) {
                if exit.value == nil {
                    kill(pid, SIGKILL)
                    killpg(pid, SIGKILL)
                }
            }
        }
        beginShutdown()
    }

    func terminate(gracePeriod: Duration) async {
        if exit.value == nil {
            await signal(SIGHUP)
            if await exit.wait(timeout: gracePeriod) == nil {
                await signal(SIGKILL)
                _ = await exit.wait()
            }
        }
        queue.async { self.drainAndShutdown() }
        _ = await closed.wait()
    }

    public var exitStatus: Int32? {
        get async { await exit.wait()?.exitCode }
    }

    public var isRunning: Bool { exit.value == nil }

    /// Suspends until the process exits; `nil` if the waiting task is cancelled.
    public var termination: Termination? {
        get async { await exit.wait() }
    }

    /// How the process ended, or `nil` if it is still running.
    public var terminationIfExited: Termination? { exit.value }

    /// Waits until the process exits or `timeout` passes; `nil` if it is
    /// still running then.
    public func waitForExit(timeout: Duration) async -> Termination? {
        await exit.wait(timeout: timeout)
    }

    /// Looks at the output not yet consumed from ``output`` without
    /// consuming it: waits until `predicate` holds for it, the output ends,
    /// or `timeout` passes. See `OutputBuffer.peek`.
    func peekOutput(timeout: Duration, until predicate: ([UInt8]) -> Bool) async -> (bytes: [UInt8], isFinished: Bool) {
        await buffer.peek(timeout: timeout, until: predicate)
    }

    // MARK: Reading

    private func startReading(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        // Runs once the source is cancelled: the only place the master is
        // closed. Captures no `self`, so it also runs after deinit.
        let buffer = buffer
        let closed = closed
        source.setCancelHandler {
            close(fd)
            buffer.finish()
            closed.set(())
        }
        io.withLock { $0.readSource = source }
        source.resume()
    }

    /// Reads what is available, up to a few 64 KB chunks per wakeup so writes
    /// and timers on the same queue are not starved by a flood.
    private func readAvailable() {
        let fd = io.withLock { $0.fd }
        guard fd >= 0 else { return }
        withUnsafeTemporaryAllocation(byteCount: OutputBuffer.maxBatch, alignment: 1) { chunk in
            for _ in 0..<4 {
                let count = read(fd, chunk.baseAddress, chunk.count)
                if count > 0 {
                    if buffer.append(UnsafeRawBufferPointer(rebasing: chunk[..<count])) {
                        pauseReading()
                        return
                    }
                    if count < chunk.count { return }
                } else if count == 0 {
                    beginShutdown()
                    return
                } else {
                    switch errno {
                    case EINTR: continue
                    case EAGAIN: return
                    default: // EIO: every slave fd is closed.
                        beginShutdown()
                        return
                    }
                }
            }
        }
    }

    private func pauseReading() {
        io.withLock { state in
            guard !state.isReadPaused, let source = state.readSource else { return }
            state.isReadPaused = true
            source.suspend()
        }
    }

    fileprivate func resumeReading() {
        io.withLock { state in
            guard state.isReadPaused, let source = state.readSource else { return }
            state.isReadPaused = false
            source.resume()
        }
    }

    /// Reads whatever is still buffered in the PTY, then shuts down. Bounded
    /// (16 MB) only against a background job that keeps writing after the
    /// process exited; what an exited process wrote is all read, even when
    /// backpressure had paused reading.
    private func drainAndShutdown() {
        let fd = io.withLock { $0.fd }
        if fd >= 0 {
            withUnsafeTemporaryAllocation(byteCount: OutputBuffer.maxBatch, alignment: 1) { chunk in
                for _ in 0..<256 {
                    let count = read(fd, chunk.baseAddress, chunk.count)
                    if count > 0 {
                        _ = buffer.append(UnsafeRawBufferPointer(rebasing: chunk[..<count]))
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
        beginShutdown()
    }

    /// Stops all I/O and cancels the read source, whose cancel handler closes
    /// the master and finishes ``output``. Idempotent; safe from any thread.
    private func beginShutdown() {
        let taken: (source: any DispatchSourceRead, wasPaused: Bool)? = io.withLock { state in
            guard let source = state.readSource else { return nil }
            defer {
                state.readSource = nil
                state.isReadPaused = false
                state.fd = -1
                state.writeBuffer = []
                state.writeOffset = 0
            }
            return (source, state.isReadPaused)
        }
        guard let taken else { return }
        taken.source.cancel()
        // A suspended source never runs its cancel handler.
        if taken.wasPaused { taken.source.resume() }
    }

    // MARK: Writing

    /// Writes as much pending input as the PTY takes. An offset into the
    /// buffer (compacted only once more than half of it is done) keeps a
    /// large paste linear rather than quadratic in its size.
    private func flushWrites(appending bytes: [UInt8] = []) {
        io.withLock { state in
            guard state.fd >= 0 else { return }
            state.writeBuffer.append(contentsOf: bytes)
            while state.writeOffset < state.writeBuffer.count {
                let offset = state.writeOffset
                let written = state.writeBuffer.withUnsafeBytes { buffer in
                    Darwin.write(state.fd, buffer.baseAddress! + offset, buffer.count - offset)
                }
                if written > 0 {
                    state.writeOffset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno == EAGAIN {
                    if state.writeOffset > state.writeBuffer.count / 2 {
                        state.writeBuffer.removeFirst(state.writeOffset)
                        state.writeOffset = 0
                    }
                    // The child is not reading; retry shortly (reads go on
                    // meanwhile, so this cannot deadlock against our output).
                    guard !state.isWriteRetryArmed else { return }
                    state.isWriteRetryArmed = true
                    queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
                        guard let self else { return }
                        self.io.withLock { $0.isWriteRetryArmed = false }
                        self.flushWrites()
                    }
                    return
                } else {
                    break // EIO: the terminal is gone.
                }
            }
            state.writeBuffer.removeAll(keepingCapacity: state.writeBuffer.count <= 64 * 1024)
            state.writeOffset = 0
        }
    }

    // MARK: Exit

    private func watchExit() {
        let pid = pid
        let exit = exit
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        // The handler retains the source until it fires, so the child is
        // reaped even if this object is gone by then.
        source.setEventHandler { [weak self] in
            guard Self.reap(pid, into: exit) else { return }
            source.cancel()
            self?.processDidExit()
        }
        source.resume()
        // `resume()` registers the kevent asynchronously: a child that exits
        // before the registration lands (it then targets a zombie) never
        // produces the event. So also poll with `waitpid` on the same queue,
        // backing off from 50 ms to 1 s, until the child is reaped: cheap,
        // and a missed exit can never leave a zombie and a waiter forever.
        Self.pollExit(queue: queue, after: .milliseconds(0), pid: pid, exit: exit, source: source, owner: WeakRef(self))
    }

    /// One poll, then the next one, on the process's own serial queue (the
    /// same queue as the event handler, so the two never race); the closure
    /// keeps the queue alive after the process object is gone, and polling
    /// goes on until the child is reaped.
    private static func pollExit(
        queue: DispatchQueue, after delay: DispatchTimeInterval, pid: pid_t,
        exit: Latch<Termination>, source: any DispatchSourceProcess, owner: WeakRef
    ) {
        queue.asyncAfter(deadline: .now() + delay) {
            if exit.value != nil { return } // reaped by the event handler
            if reap(pid, into: exit) {
                source.cancel()
                owner.process?.processDidExit()
                return
            }
            let next: DispatchTimeInterval
            switch delay {
            case .milliseconds(let ms) where ms < 1000: next = .milliseconds(min(max(ms * 2, 50), 1000))
            default: next = .milliseconds(1000)
            }
            pollExit(queue: queue, after: next, pid: pid, exit: exit, source: source, owner: owner)
        }
    }

    /// Collects the child's status if it has exited. Returns `true` once it
    /// has been reaped (by this or an earlier call).
    private static func reap(_ pid: pid_t, into exit: Latch<Termination>) -> Bool {
        if exit.value != nil { return true }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, WNOHANG)
        } while result == -1 && errno == EINTR
        if result == pid {
            exit.set(Termination(waitStatus: status))
            return true
        }
        if result == -1 { // ECHILD: reaped by someone else.
            exit.set(.unknown)
            return true
        }
        return false
    }

    /// EOF normally follows exit at once. If a background job still holds the
    /// terminal, stop waiting for it after a moment so the session can end.
    private func processDidExit() {
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.drainAndShutdown()
        }
    }

    /// Sends `signal` to the child, its process group and the terminal's
    /// foreground job, unless it has already been reaped (its pid could have
    /// been reused). Runs on the I/O queue, which is also where reaping and
    /// closing happen, so neither can interleave.
    private func signal(_ signal: Int32) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.exit.value == nil {
                    let fd = self.io.withLock { $0.fd }
                    let foreground = fd >= 0 ? tcgetpgrp(fd) : -1
                    kill(self.pid, signal)
                    killpg(self.pid, signal)
                    if foreground > 0, foreground != self.pid { killpg(foreground, signal) }
                }
                continuation.resume()
            }
        }
    }

    // MARK: Helpers

    private static func resolveExecutable(_ program: String, path: String?) throws(SpawnError) -> String {
        if program.contains("/") {
            guard access(program, X_OK) == 0 else { throw SpawnError(call: "access \(program)", code: errno) }
            return program
        }
        let directories = (path ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":")
        for directory in directories where !directory.isEmpty {
            let candidate = "\(directory)/\(program)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        throw SpawnError(call: "PATH lookup of \(program)", code: ENOENT)
    }
}

/// A weak reference that can cross isolation domains.
private struct WeakRef: Sendable {
    weak var process: PTYProcess?
    init(_ process: PTYProcess) { self.process = process }
}

/// Lets the output buffer resume a paused reader without retaining it.
private final class WeakResume: Sendable {
    let target = Mutex<WeakRef?>(nil)
    func fire() { target.withLock { $0 }?.process?.resumeReading() }
}
