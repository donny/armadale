import ArmadaleCore
import Darwin
import Foundation

/// How a zmx backend reaches its zmx: on this Mac (``LocalZmxBackend``) or
/// on an SSH host (``RemoteZmxBackend``). The session protocol on top of it
/// (create, attach-only, listing, killing) is the same for both and lives
/// in ``ZmxSessionDriver``.
protocol ZmxEndpoint: Sendable {
    /// Starts an interactive zmx client, `zmx <arguments>`, on a new PTY of
    /// `size`, using the binary of `version` (`nil`: the current one).
    func spawnClient(_ arguments: [String], for session: Session, version: String?, size: PTYSize) async throws -> PTYProcess
    /// Runs `zmx <arguments>` as a one-shot control command.
    func control(_ arguments: [String], version: String?) async throws -> CommandResult
    /// What a create starts in the new session: everything after the
    /// session name in `zmx attach <name> …` (zmx execs it verbatim; there
    /// is no `--`).
    func sessionProgram(for session: Session) async throws -> [String]
    /// The attach-only sentinel: a program that exits at once. An existing
    /// session ignores it; a missing one is created, runs it and dies.
    var attachOnlySentinel: [String] { get }
    /// Whether text that is not the client's may come before its first
    /// output (over ssh: a warning, a remote shell's start-up output).
    var clientOutputMayHaveNoise: Bool { get }
    /// What a client that exited before showing anything recognisable
    /// means, if the endpoint can tell (ssh's exit status 255: the host
    /// could not be reached); `nil` leaves it to the protocol.
    func failure(ofExitedClient status: Int32?, output: [UInt8]) -> BackendError?
}

extension ZmxEndpoint {
    func failure(ofExitedClient status: Int32?, output: [UInt8]) -> BackendError? { nil }
}

/// The zmx session protocol of docs/DESIGN.md section 4, over an endpoint:
///
/// - **create**: `zmx attach a-<id> <program>`, wait for
///   `session "a-<id>" created` and `ESC[2J` (plus a grace period, so the
///   daemon has registered the client), drop that client and attach again,
///   because only the second and later clients get a replay.
/// - **attach**: `zmx attach a-<id> <sentinel>`. `ESC[2J` first means an
///   existing session; `created` first means the sentinel made one, i.e.
///   the session did not exist (``BackendError/noSuchSession(_:)``).
/// - listing (`ls --short`), killing and history.
struct ZmxSessionDriver<Endpoint: ZmxEndpoint>: Sendable {
    let endpoint: Endpoint
    /// How long a creating client may take to report the new session.
    var createTimeout: Duration = .seconds(5)
    /// How long an attaching client may take to show whether it attached.
    var attachTimeout: Duration = .seconds(2)
    /// How long the creating client stays connected after it attached.
    var firstClientGrace: Duration = .milliseconds(150)

    /// Creates the session (attaching if it already exists) with the zmx
    /// of `version`; returns the client attached to it.
    func create(_ session: Session, version: String, size: PTYSize) async throws -> PTYProcess {
        let name = ZmxRuntime.sessionName(for: session.id)
        let program = try await endpoint.sessionProgram(for: session)
        let client = try await endpoint.spawnClient(["attach", name] + program, for: session, version: version, size: size)
        let noise = endpoint.clientOutputMayHaveNoise
        let first = await client.peekOutput(timeout: createTimeout) { bytes in
            ZmxProtocol.classify(bytes, sessionName: name, wantsAttach: true, allowingNoise: noise).isDecided
        }
        switch ZmxProtocol.classify(first.bytes, sessionName: name, wantsAttach: true, allowingNoise: noise) {
        case .attached:
            // The session already existed (an earlier create got this far):
            // this client is attached normally and got the replay.
            return client
        case .createdAndAttached:
            // Drop the first client (it gets no replay, so the program's
            // first output may be missing from it) once the daemon has
            // registered it, then attach for real.
            try? await Task.sleep(for: firstClientGrace)
            await client.terminate()
            var created = session
            created.runtimeVersion = version
            do {
                return try await attach(created, version: version, size: size)
            } catch {
                // The program exited at once (a typo in a command, say): the
                // session is gone, or about to be.
                guard await isGone(session.id) else { throw error }
                let output = await ZmxProtocol.text(of: client)
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
            if gaveUp, let exit = await client.waitForExit(timeout: .seconds(1)),
               let error = endpoint.failure(ofExitedClient: exit.exitCode, output: first.bytes) {
                throw error
            }
            await client.terminate()
            try? await kill(session.id, version: version)
            throw BackendError.runtimeFailure(
                gaveUp
                    ? "The session ended as soon as it started."
                    : "The session did not start within \(createTimeout).")
        }
    }

    /// Attaches to the session only if it exists, with the zmx of
    /// `version`; returns the attached client.
    func attach(_ session: Session, version: String?, size: PTYSize) async throws -> PTYProcess {
        let name = ZmxRuntime.sessionName(for: session.id)
        let client = try await endpoint.spawnClient(
            ["attach", name] + endpoint.attachOnlySentinel, for: session, version: version, size: size)
        let noise = endpoint.clientOutputMayHaveNoise
        let first = await client.peekOutput(timeout: attachTimeout) { bytes in
            ZmxProtocol.classify(bytes, sessionName: name, wantsAttach: false, allowingNoise: noise).isDecided
        }
        switch ZmxProtocol.classify(first.bytes, sessionName: name, wantsAttach: false, allowingNoise: noise) {
        case .attached:
            return client
        case .created, .createdAndAttached:
            // The session did not exist; the sentinel made one that is
            // already dying. Make sure nothing is left behind.
            try await failAttach(client, id: session.id, version: version)
        case .other, .undecided:
            if first.isFinished || !client.isRunning || client.terminationIfExited != nil {
                // The client gave up without attaching.
                let exit = await client.waitForExit(timeout: .seconds(1))
                if let exit, let error = endpoint.failure(ofExitedClient: exit.exitCode, output: first.bytes) {
                    throw error
                }
                if await isGone(session.id) {
                    try await failAttach(client, id: session.id, version: version)
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

    func exists(_ id: SessionID) async throws -> Bool {
        try await liveSessions().contains(id)
    }

    func liveSessions() async throws -> Set<SessionID> {
        let result = try await endpoint.control(["ls", "--short"], version: nil)
        guard result.status == 0 else {
            // The helper's own wording (with its paths) goes to the log only.
            NSLog("Armadale: listing sessions failed: %@", ZmxProtocol.message(result))
            throw BackendError.runtimeFailure("The persistence helper could not list sessions.")
        }
        return ZmxProtocol.parseSessionList(result.stdoutText)
    }

    /// Kills the session. A session that no longer exists is not an error.
    func kill(_ id: SessionID, version: String?) async throws {
        let result = try await endpoint.control(["kill", ZmxRuntime.sessionName(for: id)], version: version)
        if result.status == 0 || ZmxProtocol.isSessionNotFound(result) { return }
        NSLog("Armadale: ending session %@ failed: %@", id.raw, ZmxProtocol.message(result))
        throw BackendError.runtimeFailure("The persistence helper could not end the session.")
    }

    func history(_ id: SessionID, version: String?) async throws -> Data {
        guard try await exists(id) else { throw BackendError.historyUnavailable(id) }
        let result = try await endpoint.control(["history", ZmxRuntime.sessionName(for: id), "--vt"], version: version)
        guard result.status == 0 else { throw BackendError.historyUnavailable(id) }
        return result.stdout
    }

    /// Whether the session is gone. A daemon whose program just exited
    /// takes a moment to unlink its socket, so a session still listed is
    /// checked again a few times over about 300 ms.
    func isGone(_ id: SessionID) async -> Bool {
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            if (try? await exists(id)) == false { return true }
        }
        return false
    }

    /// Ends an attach whose session turned out not to exist.
    private func failAttach(_ client: PTYProcess, id: SessionID, version: String?) async throws -> Never {
        if await client.waitForExit(timeout: attachTimeout) == nil {
            await client.terminate()
        }
        try? await kill(id, version: version)
        throw BackendError.noSuchSession(id)
    }
}

/// zmx's wire-level conventions, as Armadale reads them (pure functions).
enum ZmxProtocol {
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
    /// What a zmx client writes first when it attaches: clear, then home.
    static let attachSequence = Array("\u{1b}[2J\u{1b}[H".utf8)

    /// Classifies the start of a client's output. With `wantsAttach`
    /// false, `created` alone is decisive (the session did not exist).
    ///
    /// With `allowingNoise` (clients over ssh), whole lines of text before
    /// zmx's own output are skipped (an ssh warning, a remote rc file's
    /// output): zmx's output is only looked for at the start of the stream
    /// or of a line, and an attach is only its full clear-plus-home
    /// sequence there, never an `ESC[2J` in the middle of other text.
    /// Output that never shows it is undecided rather than ``other`` (the
    /// caller's timeout, or the client's exit, settles it).
    static func classify(_ bytes: [UInt8], sessionName: String, wantsAttach: Bool, allowingNoise: Bool = false) -> FirstOutput {
        guard allowingNoise else { return classifyFromStart(bytes[...], sessionName: sessionName, wantsAttach: wantsAttach) }
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if index == bytes.startIndex || bytes[index - 1] == 0x0A {
                let outcome = classifyFromStart(
                    bytes[index...], sessionName: sessionName, wantsAttach: wantsAttach, attach: attachSequence)
                if outcome != .other { return outcome }
            }
            index += 1
        }
        return .undecided
    }

    private static func classifyFromStart(
        _ bytes: ArraySlice<UInt8>, sessionName: String, wantsAttach: Bool, attach: [UInt8] = clearSequence
    ) -> FirstOutput {
        let created = Array("session \"\(sessionName)\" created".utf8)
        if bytes.starts(with: attach) { return .attached }
        if bytes.starts(with: created) {
            var rest = bytes.dropFirst(created.count)
            while let first = rest.first, first == 0x0D || first == 0x0A { rest = rest.dropFirst() }
            if rest.starts(with: clearSequence) { return .createdAndAttached }
            if rest.isEmpty || clearSequence.starts(with: rest) {
                return wantsAttach ? .created : .createdAndAttached
            }
            return wantsAttach ? .other : .createdAndAttached
        }
        if attach.starts(with: bytes) || created.starts(with: bytes) { return .undecided }
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
/// ``exitStatus`` is `nil`; the backend's `resolveExit(of:)` decides what
/// the exit meant.
final class ZmxClient: ProcessHandle {
    let process: PTYProcess
    let runtimeVersion: String?
    /// Whether ``clientFootprint`` is the zmx client's own memory (a local
    /// client). Over ssh the local process is ssh, which does not grow; the
    /// backlog builds up in the client on the host, out of reach.
    let reportsFootprint: Bool

    init(process: PTYProcess, runtimeVersion: String?, reportsFootprint: Bool = true) {
        self.process = process
        self.runtimeVersion = runtimeVersion
        self.reportsFootprint = reportsFootprint
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
        guard reportsFootprint, process.isRunning else { return nil }
        return ProcessFootprint.bytes(of: process.pid)
    }
}
