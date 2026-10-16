import ArmadaleCore
import Darwin
import Foundation

/// Persistent local sessions: one zmx daemon per session, in Armadale's
/// private runtime directory (docs/DESIGN.md section 4).
///
/// - Interactive clients (`zmx attach`) run on a PTY through `ctty-exec`,
///   so they have a controlling terminal and receive SIGWINCH on resize.
/// - Control commands (`ls`, `kill`, `history`) run through a
///   ``CommandRunner`` with a timeout.
/// - Every invocation uses the installed zmx copy of the version that
///   created the session (`Session.runtimeVersion`), or the current one.
public actor LocalZmxBackend: PersistenceBackend {
    public struct Configuration: Sendable {
        public var runtime: ZmxRuntime
        public var executables: ZmxExecutables
        /// `ctty-exec` for clients and as the program's argv[0] trampoline;
        /// `nil` asks ``HelperLocator``.
        public var cttyExec: String?
        /// Resolves a session's program, arguments, environment and
        /// directory; its context's environment is also the base for
        /// control commands.
        public var resolver: LaunchResolver
        /// Limit for `ls`, `kill` and `history`. Calls from a newer zmx to
        /// an older daemon time out rather than fail.
        public var commandTimeout: Duration = .seconds(10)
        /// How long a creating client may take to report the new session.
        public var createTimeout: Duration = .seconds(5)
        /// How long an attaching client may take to show whether it attached.
        public var attachTimeout: Duration = .seconds(2)
        /// How long the creating client stays connected after it attached,
        /// so the daemon has processed its first message (which is what
        /// makes it replay the screen to the next client).
        public var firstClientGrace: Duration = .milliseconds(150)

        public init(runtime: ZmxRuntime, executables: ZmxExecutables, cttyExec: String?, resolver: LaunchResolver) {
            self.runtime = runtime
            self.executables = executables
            self.cttyExec = cttyExec
            self.resolver = resolver
        }
    }

    public nonisolated let configuration: Configuration
    private let runner = CommandRunner()
    /// Versions of sessions this backend knows about, for control commands
    /// that only get an ID.
    private var versions: [SessionID: String] = [:]

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// The sentinel program for attach-only: an existing session ignores the
    /// command; a missing one is created, runs it, and dies at once.
    static let attachOnlySentinel = "/usr/bin/true"

    /// zmx's variables, which the daemon passes on to the program (it inherits
    /// the creating client's environment and adds `ZMX_SESSION`). Inside a
    /// pane they would make a user's own `zmx` use Armadale's private
    /// directory, or turn its `attach` into a switch away from this session.
    static let variablesHiddenFromSessions = ["ZMX_DIR", "ZMX_NO_DETACH_KEY", "ZMX_SESSION", "ZMX_SESSION_PREFIX"]

    /// Records which zmx version created each session (from the model at
    /// launch), so `kill` and `history` use the matching binary.
    public func noteRuntimeVersions(_ versions: [SessionID: String]) {
        self.versions.merge(versions) { _, new in new }
    }

    // MARK: PersistenceBackend

    public func create(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        let (zmx, version) = configuration.executables.executable(forVersion: nil)
        versions[session.id] = version
        let name = ZmxRuntime.sessionName(for: session.id)
        let launch = configuration.resolver.resolve(session)
        let ctty = try cttyExecPath()
        // zmx execs everything after the name verbatim (there is no `--`).
        // ctty-exec sets argv[0] (`-zsh` for a login shell), which zmx's
        // argv cannot express, and removes zmx's variables from the
        // program's environment; it is harmless in the daemon's child, which
        // already has the PTY as its controlling terminal.
        let unset = Self.variablesHiddenFromSessions.flatMap { ["--unset", $0] }
        let arguments = ["attach", name, ctty] + unset + [launch.program, launch.argv0] + launch.arguments
        let client = try spawnClient(
            zmx: zmx, arguments: arguments,
            environment: configuration.runtime.environment(base: launch.environment),
            workingDirectory: launch.workingDirectory, size: size)

        let first = await client.peekOutput(timeout: configuration.createTimeout) { bytes in
            Self.classify(bytes, sessionName: name, wantsAttach: true).isDecided
        }
        switch Self.classify(first.bytes, sessionName: name, wantsAttach: true) {
        case .attached:
            // The session already existed (an earlier create got this far):
            // this client is attached normally and got the replay.
            return ZmxClient(process: client, runtimeVersion: version)
        case .createdAndAttached:
            // Drop the first client (it gets no replay, so the program's
            // first output may be missing from it) once the daemon has
            // registered it, then attach for real.
            try? await Task.sleep(for: configuration.firstClientGrace)
            await client.terminate()
            var created = session
            created.runtimeVersion = version
            do {
                return try await attach(created, size: size)
            } catch {
                // The program exited at once (a typo in a command, say): the
                // session is gone, or about to be.
                guard await isGone(session.id) else { throw error }
                let output = await Self.text(of: client)
                throw BackendError.runtimeFailure(
                    "The session ended as soon as it started." + (output.isEmpty ? "" : "\n" + output))
            }
        case let outcome:
            // `.other`: the client gave up with the runtime's own error
            // (typically the program exited before the client could
            // connect); it may still be on its way out. Otherwise the
            // client never reported anything in time. Its output is the
            // runtime's wording, not the program's, so it is never shown.
            let gaveUp = outcome == .other || first.isFinished || !client.isRunning
            await client.terminate()
            try? await kill(session.id)
            throw BackendError.runtimeFailure(
                gaveUp
                    ? "The session ended as soon as it started."
                    : "The session did not start within \(configuration.createTimeout).")
        }
    }

    public func attach(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        let (zmx, version) = configuration.executables.executable(forVersion: session.runtimeVersion)
        if let recorded = session.runtimeVersion { versions[session.id] = recorded }
        let name = ZmxRuntime.sessionName(for: session.id)
        let launch = configuration.resolver.resolve(session)
        let client = try spawnClient(
            zmx: zmx, arguments: ["attach", name, Self.attachOnlySentinel],
            environment: configuration.runtime.environment(base: launch.environment),
            workingDirectory: launch.workingDirectory, size: size)

        let first = await client.peekOutput(timeout: configuration.attachTimeout) { bytes in
            Self.classify(bytes, sessionName: name, wantsAttach: false).isDecided
        }
        switch Self.classify(first.bytes, sessionName: name, wantsAttach: false) {
        case .attached:
            return ZmxClient(process: client, runtimeVersion: version)
        case .created, .createdAndAttached:
            // The session did not exist; the sentinel made one that is
            // already dying. Make sure nothing is left behind.
            try await failAttach(client, id: session.id)
        case .other, .undecided:
            if first.isFinished || !client.isRunning || client.terminationIfExited != nil {
                // The client gave up without attaching.
                _ = await client.waitForExit(timeout: .seconds(1))
                if await isGone(session.id) {
                    try await failAttach(client, id: session.id)
                }
                await client.terminate()
                throw BackendError.runtimeFailure("The session is running but could not be reattached.")
            }
            // Still running but not attached after the timeout (a client and
            // daemon that do not understand each other, say): give up rather
            // than leave a pane that never shows anything.
            await client.terminate()
            throw BackendError.runtimeFailure("Could not establish the session.")
        }
    }

    public func exists(_ id: SessionID) async throws -> Bool {
        try await liveSessions().contains(id)
    }

    public func liveSessions() async throws -> Set<SessionID> {
        let result = try await zmx(["ls", "--short"], version: nil)
        guard result.status == 0 else {
            throw BackendError.runtimeFailure("Listing sessions failed: \(Self.message(result))")
        }
        return Self.parseSessionList(result.stdoutText)
    }

    /// Kills the session. A session that no longer exists is not an error.
    public func kill(_ id: SessionID) async throws {
        let result = try await zmx(["kill", ZmxRuntime.sessionName(for: id)], version: versions[id])
        if result.status == 0 || Self.isSessionNotFound(result) { return }
        throw BackendError.runtimeFailure("Ending the session failed: \(Self.message(result))")
    }

    public func history(_ id: SessionID) async throws -> Data {
        guard try await exists(id) else { throw BackendError.historyUnavailable(id) }
        let result = try await zmx(["history", ZmxRuntime.sessionName(for: id), "--vt"], version: versions[id])
        guard result.status == 0 else { throw BackendError.historyUnavailable(id) }
        return result.stdout
    }

    /// Ended if the session is no longer listed; detached if it is (only
    /// the client went away) or if listing fails.
    public func resolveExit(of session: Session) async -> ExitResolution {
        do {
            return try await exists(session.id) ? .detached : .ended
        } catch {
            return .detached
        }
    }

    // MARK: Helpers

    private func cttyExecPath() throws -> String {
        if let path = configuration.cttyExec { return path }
        return try HelperLocator.cttyExec().path
    }

    private func spawnClient(
        zmx: String, arguments: [String], environment: [String: String], workingDirectory: String, size: PTYSize
    ) throws -> PTYProcess {
        // argv[0] is the full path of the installed copy, which the daemon
        // (a fork of this client) keeps: `pgrep -f` finds Armadale's daemons.
        do {
            return try PTYProcess.spawn(
                program: zmx,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                size: size,
                options: PTYProcess.Options(argv0: zmx, helperPath: try cttyExecPath()))
        } catch let error as SpawnError {
            // Shown in the pane: describe it without the runtime's internals.
            throw BackendError.runtimeFailure(
                "The session service could not be started: \(String(cString: strerror(error.code))).")
        }
    }

    private func zmx(_ arguments: [String], version: String?) async throws -> CommandResult {
        let executable = configuration.executables.executable(forVersion: version).path
        let environment = configuration.runtime.environment(
            base: LaunchResolver.scrubbed(configuration.resolver.context.environment))
        do {
            return try await runner.run(
                executable: executable, arguments: arguments, environment: environment,
                timeout: configuration.commandTimeout)
        } catch {
            throw BackendError.runtimeFailure(String(describing: error))
        }
    }

    /// Whether the session is gone. A daemon whose program just exited
    /// takes a moment to unlink its socket, so a session still listed is
    /// checked again a few times over about 300 ms.
    private func isGone(_ id: SessionID) async -> Bool {
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            if (try? await exists(id)) == false { return true }
        }
        return false
    }

    /// Ends an attach whose session turned out not to exist.
    private func failAttach(_ client: PTYProcess, id: SessionID) async throws -> Never {
        if await client.waitForExit(timeout: configuration.attachTimeout) == nil {
            await client.terminate()
        }
        try? await kill(id)
        throw BackendError.noSuchSession(id)
    }

    /// What a client's first output says.
    enum FirstOutput: Equatable {
        /// `ESC[2J`: attached to an existing session.
        case attached
        /// `session "<name>" created`, not yet followed by anything.
        case created
        /// `session "<name>" created` and then `ESC[2J`: created and attached.
        case createdAndAttached
        /// Something else (an error message).
        case other
        /// Too little output to tell.
        case undecided

        var isDecided: Bool { self != .undecided && self != .created }
    }

    static let clearSequence = Array("\u{1b}[2J".utf8)

    /// Classifies the start of a client's output. With `wantsAttach`
    /// false, `created` alone is decisive (the session did not exist).
    static func classify(_ bytes: [UInt8], sessionName: String, wantsAttach: Bool) -> FirstOutput {
        let created = Array("session \"\(sessionName)\" created".utf8)
        if bytes.starts(with: clearSequence) { return .attached }
        if bytes.starts(with: created) {
            var rest = bytes.dropFirst(created.count)
            while let first = rest.first, first == 0x0D || first == 0x0A { rest = rest.dropFirst() }
            if rest.starts(with: clearSequence) { return .createdAndAttached }
            if rest.isEmpty || clearSequence.starts(with: rest) {
                return wantsAttach ? .created : .createdAndAttached
            }
            return wantsAttach ? .other : .createdAndAttached
        }
        if clearSequence.starts(with: bytes) || created.starts(with: bytes) { return .undecided }
        return .other
    }

    /// Session IDs in `zmx ls --short` output; foreign names are ignored.
    static func parseSessionList(_ text: String) -> Set<SessionID> {
        Set(text.split(whereSeparator: \.isNewline).compactMap {
            ZmxRuntime.sessionID(fromName: $0.trimmingCharacters(in: .whitespaces))
        })
    }

    static func isSessionNotFound(_ result: CommandResult) -> Bool {
        let text = result.stderrText + result.stdoutText
        return text.contains("SessionNotFound") || text.contains("not found") || text.contains("does not exist")
    }

    static func message(_ result: CommandResult) -> String {
        let text = (result.stderrText + result.stdoutText).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "exit status \(result.status)" : text
    }

    /// Output as text without escape sequences or carriage returns, for
    /// error messages; at most the last 600 characters.
    static func printable(_ bytes: [UInt8]) -> String {
        var kept: [UInt8] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            index += 1
            if byte == 0x1B, index < bytes.endIndex {
                let kind = bytes[index]
                index += 1
                if kind == UInt8(ascii: "[") {
                    // CSI: parameters up to a final byte in 0x40...0x7E.
                    while index < bytes.endIndex {
                        let b = bytes[index]
                        index += 1
                        if (0x40...0x7E).contains(b) { break }
                    }
                } else if kind == UInt8(ascii: "]") {
                    // OSC: up to BEL or ST (ESC \).
                    while index < bytes.endIndex {
                        let b = bytes[index]
                        index += 1
                        if b == 0x07 { break }
                        if b == 0x1B, index < bytes.endIndex, bytes[index] == 0x5C {
                            index += 1
                            break
                        }
                    }
                }
                continue
            }
            if byte != 0x0D, byte != 0x1B { kept.append(byte) }
        }
        let text = String(decoding: kept, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.suffix(600))
    }

    /// Whatever is left of a dropped client's output, as printable text,
    /// without the `created` line.
    static func text(of client: PTYProcess) async -> String {
        var bytes: [UInt8] = []
        for await batch in client.output { bytes += batch }
        let lines = printable(bytes).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !($0.hasPrefix("session \"") && $0.hasSuffix("\" created")) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A zmx client attached to a session. Its exit status means nothing (it is
/// always 0, whether the session ended or the client was detached), so
/// ``exitStatus`` is `nil`; the backend's ``LocalZmxBackend/resolveExit(of:)``
/// decides what the exit meant.
final class ZmxClient: ProcessHandle {
    let process: PTYProcess
    let runtimeVersion: String?

    init(process: PTYProcess, runtimeVersion: String?) {
        self.process = process
        self.runtimeVersion = runtimeVersion
    }

    var output: AsyncStream<[UInt8]> { process.output }
    func write(_ bytes: [UInt8]) { process.write(bytes) }
    func resize(_ size: PTYSize) { process.resize(size) }
    func terminate() async { await process.terminate() }
    var exitStatus: Int32? {
        get async {
            _ = await process.termination
            return nil
        }
    }
    var isRunning: Bool { process.isRunning }
    var pid: pid_t { process.pid }
    func hangUp() { process.hangUp() }
    /// zmx 0.8.1's client buffers whatever the daemon sends without limit,
    /// so the PTY's backpressure never reaches the program; the backlog
    /// shows up as the client's memory. Only read while the client is
    /// running, so an exited client's (possibly reused) pid is never read.
    var clientFootprint: UInt64? {
        guard process.isRunning else { return nil }
        return ProcessFootprint.bytes(of: process.pid)
    }
}
