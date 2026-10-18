import ArmadaleCore
import Darwin
import Foundation
import Synchronization

/// Persistent sessions on one SSH host (docs/DESIGN.md section 6): the same
/// zmx session protocol as ``LocalZmxBackend`` (``ZmxSessionDriver``), with
/// Armadale's own copy of zmx deployed to the host (``RemoteDeployer``).
///
/// - Interactive clients are `ssh -tt <host> -- <zmx attach …>`, spawned on
///   the pane's PTY through `ctty-exec` like local clients, so resizes
///   reach them and ssh's prompts appear in the pane.
/// - Control commands (`ls`, `kill`, the deployment check before every
///   connection) run non-interactively over the host's shared connection.
/// - ssh failing to connect throws ``BackendError/unreachable(_:)``: the
///   session may be alive, and the controller shows it as disconnected and
///   keeps retrying. Only the host saying a session is gone ends it.
/// - When ssh needs the user (an unknown host key, a passphrase), the
///   client first runs an interactive sign-in in the pane, which leaves the
///   shared connection up, and then attaches (``SignInClient``).
/// - A host that cannot take the helper (``BackendError/notPersistent(reason:)``
///   from the deployer) gets plain `ssh -tt` sessions instead, which end
///   when Armadale quits; their handles carry a ``ProcessHandle/persistenceNote``.
public actor RemoteZmxBackend: PersistenceBackend {
    public struct Configuration: Sendable {
        public var host: ArmadaleCore.Host
        public var transport: any SSHTransport
        /// The zmx version to deploy and create sessions with.
        public var version: String = ZmxVersion.current
        /// The bundled zmx for a platform.
        public var binary: @Sendable (RemotePlatform) throws -> URL = { try HelperLocator.remoteZmx(for: $0) }
        /// `ctty-exec` for the ssh clients; `nil` asks ``HelperLocator``.
        public var cttyExec: String?
        /// Where ssh clients start on this Mac.
        public var localDirectory: String = NSHomeDirectory()
        /// `TERM_PROGRAM_VERSION` in sessions.
        public var appVersion: String = "dev"
        /// Over ssh everything takes longer than locally.
        public var createTimeout: Duration = .seconds(15)
        public var attachTimeout: Duration = .seconds(10)
        public var firstClientGrace: Duration = .milliseconds(250)
        /// How long an interactive sign-in may take to show a prompt; one
        /// that shows none fails (there is nothing to answer).
        public var signInPromptTimeout: Duration = .seconds(10)
        /// How long the user has to answer a sign-in's prompts.
        public var signInTimeout: Duration = .seconds(120)

        public init(host: ArmadaleCore.Host, transport: any SSHTransport) {
            self.host = host
            self.transport = transport
        }
    }

    public nonisolated let configuration: Configuration
    public nonisolated var host: ArmadaleCore.Host { configuration.host }
    /// Deploys and checks the helper on the host (also used by Settings › Hosts).
    public nonisolated let deployer: RemoteDeployer
    private let driver: ZmxSessionDriver<RemoteZmxEndpoint>
    /// Versions of sessions this backend knows about, for control commands
    /// that only get an ID.
    private var versions: [SessionID: String] = [:]
    /// Sessions running as plain ssh shells (the host could not take the
    /// helper); they end with their client.
    private var plainSessions: [SessionID: PTYProcess] = [:]

    public init(configuration: Configuration) {
        self.configuration = configuration
        deployer = RemoteDeployer(
            host: configuration.host, transport: configuration.transport,
            version: configuration.version, binary: configuration.binary)
        var driver = ZmxSessionDriver(endpoint: RemoteZmxEndpoint(configuration: configuration))
        driver.createTimeout = configuration.createTimeout
        driver.attachTimeout = configuration.attachTimeout
        driver.firstClientGrace = configuration.firstClientGrace
        self.driver = driver
    }

    /// Records which zmx version created each session (from the model at
    /// launch), so `kill` and `history` use the matching binary.
    public func noteRuntimeVersions(_ versions: [SessionID: String]) {
        self.versions.merge(versions) { _, new in new }
    }

    // MARK: PersistenceBackend

    public func create(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        do {
            try await prepare()
        } catch let failure as SSHFailure {
            guard case .needsInteraction(let message) = failure else { throw failure.backendError }
            return try await signIn(for: session, mode: .create, size: size, batchMessage: message)
        } catch BackendError.notPersistent(let reason) {
            return try startPlainSession(session, size: size, reason: reason)
        }
        return try await createAfterPreparing(session, size: size)
    }

    public func attach(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        // A plain ssh session that is not running here is gone for good.
        if session.runtimeVersion == nil, plainSessions[session.id] != nil { throw BackendError.notPersistent(reason: nil) }
        do {
            try await prepare()
        } catch let failure as SSHFailure {
            guard case .needsInteraction(let message) = failure else { throw failure.backendError }
            return try await signIn(for: session, mode: .attach, size: size, batchMessage: message)
        }
        return try await attachAfterPreparing(session, size: size)
    }

    public func exists(_ id: SessionID) async throws -> Bool {
        if let plain = plainSessions[id] { return plain.isRunning }
        return try await driver.exists(id)
    }

    public func liveSessions() async throws -> Set<SessionID> {
        let plain = Set(plainSessions.filter { $0.value.isRunning }.keys)
        return try await driver.liveSessions().union(plain)
    }

    /// Kills the session and removes its log on the host. A session that
    /// no longer exists is not an error.
    public func kill(_ id: SessionID) async throws {
        if let plain = plainSessions.removeValue(forKey: id) {
            await plain.terminate()
            return
        }
        try await driver.kill(id, version: versions[id])
        let log = configuration.transport
        let layout = RemoteLayout(directory: host.remoteDirectory)
        _ = try? await log.run(host, RemoteShell.sh(
            "rm -f " + RemoteShell.path(layout.logDirectory + "/" + ZmxRuntime.sessionName(for: id) + ".log")))
    }

    public func history(_ id: SessionID) async throws -> Data {
        guard plainSessions[id] == nil else { throw BackendError.historyUnavailable(id) }
        return try await driver.history(id, version: versions[id])
    }

    /// Ended only when the host says the session is gone; detached when it
    /// is alive or the host cannot be asked (the connection may simply be
    /// down). A plain ssh session ends with its client.
    public func resolveExit(of session: Session) async -> ExitResolution {
        if plainSessions[session.id] != nil {
            plainSessions[session.id] = nil
            return .ended
        }
        do {
            return try await driver.exists(session.id) ? .detached : .ended
        } catch {
            return .detached
        }
    }

    // MARK: Connecting

    /// Makes sure the helper is on the host (a cheap check over the shared
    /// connection, a deploy when it is missing or outdated).
    private func prepare() async throws {
        _ = try await deployer.ensureDeployed()
    }

    private func createAfterPreparing(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        var session = session
        if !(try await directoryExists(session.workingDirectory)) { session.workingDirectory = "~" }
        let version = configuration.version
        versions[session.id] = version
        let client = try await driver.create(session, version: version, size: size)
        return ZmxClient(process: client, runtimeVersion: version, reportsFootprint: false)
    }

    private func attachAfterPreparing(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        let version = session.runtimeVersion ?? configuration.version
        if let recorded = session.runtimeVersion { versions[session.id] = recorded }
        let client = try await driver.attach(session, version: version, size: size)
        return ZmxClient(process: client, runtimeVersion: version, reportsFootprint: false)
    }

    /// `test -d` on the host. `~` always exists.
    private func directoryExists(_ path: String) async throws -> Bool {
        guard path != "~", !path.isEmpty else { return true }
        let result = try await configuration.transport.run(
            host, RemoteShell.sh("if test -d \(RemoteShell.path(path)); then echo yes; fi"))
        if let failure = SSHFailure.classify(result) { throw failure.backendError }
        return result.stdoutText.contains("yes")
    }

    /// ssh could not connect without prompts. An interactive ssh runs in
    /// the pane; if it asks something (a password, a passphrase, a new host
    /// key) the user answers there, which leaves the host's shared
    /// connection up, and then the session is attached (or created) through
    /// it (``SignInClient``). If it asks nothing within
    /// ``Configuration/signInPromptTimeout`` (a rejected key, say) the
    /// attempt fails for good with ssh's message: retrying cannot help.
    private func signIn(
        for session: Session, mode: SignInClient.Mode, size: PTYSize, batchMessage: String
    ) async throws -> any ProcessHandle {
        let invocation = try configuration.transport.interactive(host, remoteCommand: RemoteShell.sh("exit 0"))
        let login = try RemoteZmxEndpoint.spawn(invocation, configuration: configuration, size: size)
        let first = await login.peekOutput(timeout: configuration.signInPromptTimeout) { bytes in
            SSHFailure.isPrompt(String(decoding: bytes, as: UTF8.self))
        }
        guard SSHFailure.isPrompt(String(decoding: first.bytes, as: UTF8.self)) else {
            if first.isFinished, await login.waitForExit(timeout: .seconds(2))?.exitCode == 0 {
                // It connected without asking anything after all.
                return try await connectAfterSignIn(session, mode: mode, size: size)
            }
            await login.terminate()
            let said = ZmxProtocol.printable(first.bytes).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw BackendError.authenticationFailed(said.isEmpty ? batchMessage : said)
        }
        return SignInClient(
            login: login, hostName: host.displayName, timeout: configuration.signInTimeout,
            runtimeVersion: mode == .create ? configuration.version : session.runtimeVersion ?? configuration.version
        ) { [self] size in
            try await self.connectAfterSignIn(session, mode: mode, size: size)
        }
    }

    private func connectAfterSignIn(_ session: Session, mode: SignInClient.Mode, size: PTYSize) async throws -> any ProcessHandle {
        do {
            try await prepare()
        } catch let failure as SSHFailure {
            throw failure.backendError
        } catch BackendError.notPersistent(let reason) where mode == .create {
            return try startPlainSession(session, size: size, reason: reason)
        }
        switch mode {
        case .create: return try await createAfterPreparing(session, size: size)
        case .attach: return try await attachAfterPreparing(session, size: size)
        }
    }

    /// The fallback for a host that cannot keep sessions: a plain
    /// `ssh -tt` running the session's program, which ends with its client.
    private func startPlainSession(_ session: Session, size: PTYSize, reason: String?) throws -> any ProcessHandle {
        let script = RemoteZmxEndpoint.sessionScript(for: session, appVersion: configuration.appVersion, unsetRuntimeVariables: false)
        let invocation = try configuration.transport.interactive(host, remoteCommand: RemoteShell.sh(script))
        let process = try RemoteZmxEndpoint.spawn(invocation, configuration: configuration, size: size)
        plainSessions[session.id] = process
        return PlainRemoteClient(
            process: process,
            persistenceNote: reason ?? "\(host.displayName) can’t keep sessions running, so this one ends when Armadale quits.")
    }
}

/// zmx on an SSH host, as ``ZmxSessionDriver`` uses it.
struct RemoteZmxEndpoint: ZmxEndpoint {
    let configuration: RemoteZmxBackend.Configuration
    var host: ArmadaleCore.Host { configuration.host }
    var layout: RemoteLayout { RemoteLayout(directory: configuration.host.remoteDirectory) }

    /// Control commands exit with this when the helper is not installed:
    /// then there are no sessions to list or kill either.
    static let noRuntimeStatus: Int32 = 97

    /// Found on the host's `PATH` (`/bin/true` or `/usr/bin/true`).
    var attachOnlySentinel: [String] { ["true"] }
    var clientOutputMayHaveNoise: Bool { true }

    /// ssh exits 255 when it could not connect (or lost the connection).
    func failure(ofExitedClient status: Int32?, output: [UInt8]) -> BackendError? {
        guard status == SSHFailure.exitStatus else { return nil }
        let text = ZmxProtocol.printable(output).split(whereSeparator: \.isNewline).last.map(String.init)
        return .unreachable(text?.isEmpty == false ? text ?? "" : "The connection to \(host.displayName) was lost.")
    }

    func sessionProgram(for session: Session) -> [String] {
        ["/bin/sh", "-c", Self.sessionScript(for: session, appVersion: configuration.appVersion, unsetRuntimeVariables: true)]
    }

    func spawnClient(_ arguments: [String], for session: Session, version: String?, size: PTYSize) throws -> PTYProcess {
        let command = Self.clientCommand(arguments, layout: layout, version: version ?? configuration.version)
        let invocation = try configuration.transport.interactive(host, remoteCommand: command)
        return try Self.spawn(invocation, configuration: configuration, size: size)
    }

    func control(_ arguments: [String], version: String?) async throws -> CommandResult {
        let command = Self.controlCommand(arguments, layout: layout, version: version ?? configuration.version)
        let result = try await configuration.transport.run(host, command)
        if let failure = SSHFailure.classify(result) { throw failure.backendError }
        if result.status == Self.noRuntimeStatus { return CommandResult(status: 0, stdout: Data(), stderr: Data()) }
        return result
    }

    // MARK: Command lines (pure)

    /// `env ZMX_DIR=<dir>/run ZMX_NO_DETACH_KEY=1 <dir>/bin/zmx-<version> <arguments…>`
    /// for an interactive client, as a remote command line. `ZMX_SESSION`
    /// and `ZMX_SESSION_PREFIX` are unset first, as locally: an inherited
    /// `ZMX_SESSION` would turn the attach into a switch.
    static func clientCommand(_ arguments: [String], layout: RemoteLayout, version: String) -> String {
        RemoteShell.sh(unsetInherited + "exec "
            + zmxInvocation(layout: layout, binary: RemoteShell.path(layout.binary(version: version)))
            + " " + arguments.map(RemoteShell.quote).joined(separator: " "))
    }

    /// The same for a control command, which exits with
    /// ``noRuntimeStatus`` when the helper is not installed.
    static func controlCommand(_ arguments: [String], layout: RemoteLayout, version: String) -> String {
        RemoteShell.sh(unsetInherited + "z=\(RemoteShell.path(layout.binary(version: version))); if test -x \"$z\"; then exec "
            + zmxInvocation(layout: layout, binary: "\"$z\"") + " "
            + arguments.map(RemoteShell.quote).joined(separator: " ") + "; else exit \(noRuntimeStatus); fi")
    }

    private static let unsetInherited = "unset ZMX_SESSION ZMX_SESSION_PREFIX; "

    private static func zmxInvocation(layout: RemoteLayout, binary: String) -> String {
        "env ZMX_DIR=\(RemoteShell.path(layout.runDirectory)) ZMX_NO_DETACH_KEY=1 \(binary)"
    }

    /// What a session runs on the host, as a `/bin/sh` script: zmx's
    /// variables removed (with `unsetRuntimeVariables`, inside a session),
    /// the working directory (else home), the terminal variables, the
    /// profile's environment, and then the user's login shell, or the
    /// profile's program through it (`$SHELL -l -c 'exec <program> …'`),
    /// like a local session. A single line, like every remote command.
    static func sessionScript(for session: Session, appVersion: String, unsetRuntimeVariables: Bool) -> String {
        var lines: [String] = []
        if unsetRuntimeVariables {
            lines.append("unset " + LocalZmxBackend.variablesHiddenFromSessions.joined(separator: " "))
        }
        let directory = session.workingDirectory.isEmpty ? "~" : session.workingDirectory
        lines.append("cd \(RemoteShell.path(directory)) 2>/dev/null || cd \"$HOME\"")
        let terminal = [
            ("TERM", "xterm-256color"), ("COLORTERM", "truecolor"), ("TERM_PROGRAM", "Armadale"),
            ("TERM_PROGRAM_VERSION", appVersion), ("ARMADALE_SESSION_ID", session.id.raw),
        ]
        lines.append("export " + terminal.map { "\($0.0)=\(RemoteShell.quote($0.1))" }.joined(separator: " "))
        lines.append("[ -n \"${LANG-}\" ] || export LANG=C.UTF-8")
        let profile = session.launch.environment
            .filter { Profile.environmentNameProblem($0.key) == nil && isShellName($0.key) }
            .sorted { $0.key < $1.key }
        if !profile.isEmpty {
            lines.append("export " + profile.map { "\($0.key)=\(RemoteShell.quote($0.value))" }.joined(separator: " "))
        }
        if let program = session.launch.program, !program.isEmpty {
            let command = ([program] + session.launch.arguments).map(RemoteShell.quote).joined(separator: " ")
            // csh and tcsh refuse `-l` with other flags; they read their rc
            // file for `-c` anyway.
            let run = RemoteShell.quote("exec " + command)
            lines.append("case \"${SHELL##*/}\" in csh|tcsh) exec \"$SHELL\" -c \(run);; "
                + "*) exec \"${SHELL:-/bin/sh}\" -l -c \(run);; esac")
        } else {
            lines.append("exec \"${SHELL:-/bin/sh}\" -l" + session.launch.arguments.map { " " + RemoteShell.quote($0) }.joined())
        }
        // One line: sshd hands remote commands to the user's login shell,
        // and csh-family shells reject a newline inside quotes.
        return lines.joined(separator: "; ")
    }

    /// Whether `name` can be exported by a POSIX shell.
    static func isShellName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && first.properties.isAlphabetic) else {
            return false
        }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) }
    }

    /// Spawns an ssh invocation on a new PTY through `ctty-exec`, so ssh
    /// gets SIGWINCH and forwards resizes. argv[0] is `ssh`, so the client
    /// shows (and can be found) as `ssh -tt …`.
    static func spawn(_ invocation: SSHInvocation, configuration: RemoteZmxBackend.Configuration, size: PTYSize) throws -> PTYProcess {
        do {
            let helper = try configuration.cttyExec ?? HelperLocator.cttyExec().path
            return try PTYProcess.spawn(
                program: invocation.executable,
                arguments: invocation.arguments,
                environment: invocation.environment,
                workingDirectory: configuration.localDirectory,
                size: size,
                options: PTYProcess.Options(argv0: (invocation.executable as NSString).lastPathComponent, helperPath: helper))
        } catch let error as SpawnError {
            throw BackendError.runtimeFailure("ssh could not be started: \(String(cString: strerror(error.code))).")
        } catch {
            throw BackendError.runtimeFailure("ssh could not be started: \(error)")
        }
    }
}

/// A plain ssh session on a host that cannot keep sessions: the process is
/// the session.
final class PlainRemoteClient: ProcessHandle {
    let process: PTYProcess
    let persistenceNote: String?

    init(process: PTYProcess, persistenceNote: String) {
        self.process = process
        self.persistenceNote = persistenceNote
    }

    var output: AsyncStream<[UInt8]> { process.output }
    func write(_ bytes: [UInt8]) { process.write(bytes) }
    func resize(_ size: PTYSize) { process.resize(size) }
    func terminate() async { await process.terminate() }
    var exitStatus: Int32? { get async { await process.exitStatus } }
    var isRunning: Bool { process.isRunning }
    func hangUp() { process.hangUp() }
}

/// A client that first runs ssh's interactive sign-in in the pane (host key
/// confirmation, passphrase or password prompts), then, if that worked,
/// connects to the session over the connection it left up and carries on
/// as that client. Output is relayed on demand from whichever process is
/// current, so the PTY's backpressure still applies. Its exit status means
/// nothing, like a zmx client's; the backend's `resolveExit` decides once
/// it was connected. A sign-in that fails, is abandoned or takes longer
/// than its timeout ends the client with a ``connectionFailure``.
final class SignInClient: ProcessHandle {
    enum Mode: Sendable { case create, attach }

    let output: AsyncStream<[UInt8]>
    let runtimeVersion: String?
    private let pump: Pump
    private let box: StateBox
    private let finished = Latch<Void>()

    private struct State {
        var current: (any ProcessHandle)?
        var size: PTYSize
        var isCancelled = false
        var failure: String?
    }

    /// Shared with the pump's closures (a `Mutex` cannot be captured).
    private final class StateBox: Sendable {
        let state: Mutex<State>
        init(_ state: State) { self.state = Mutex(state) }
    }

    init(
        login: PTYProcess, hostName: String, timeout: Duration, runtimeVersion: String?,
        connect: @escaping @Sendable (PTYSize) async throws -> any ProcessHandle
    ) {
        self.runtimeVersion = runtimeVersion
        let box = StateBox(State(current: login, size: PTYSize(columns: 80, rows: 24)))
        self.box = box
        let finished = finished
        let pump = Pump(
            login: login,
            hostName: hostName,
            connect: {
                let size = box.state.withLock { $0.size }
                let client = try await connect(size)
                let cancelled = box.state.withLock { current -> Bool in
                    if current.isCancelled { return true }
                    current.current = client
                    return false
                }
                if cancelled {
                    await client.terminate()
                    return nil
                }
                client.resize(size)
                return client
            },
            isCancelled: { box.state.withLock { $0.isCancelled } },
            onFinish: { failure in
                // Recorded before the client counts as exited.
                box.state.withLock { if $0.failure == nil { $0.failure = failure } }
                finished.set(())
            })
        self.pump = pump
        output = AsyncStream(unfolding: { await pump.next() })
        Task {
            try? await Task.sleep(for: timeout)
            await pump.expireSignIn(after: timeout)
        }
    }

    var connectionFailure: String? { box.state.withLock { $0.failure } }

    func write(_ bytes: [UInt8]) { box.state.withLock { $0.current }?.write(bytes) }

    func resize(_ size: PTYSize) {
        let current = box.state.withLock { state -> (any ProcessHandle)? in
            state.size = size
            return state.current
        }
        current?.resize(size)
    }

    func terminate() async {
        let current = box.state.withLock { state -> (any ProcessHandle)? in
            state.isCancelled = true
            return state.current
        }
        await current?.terminate()
    }

    func hangUp() {
        let current = box.state.withLock { state -> (any ProcessHandle)? in
            state.isCancelled = true
            return state.current
        }
        current?.hangUp()
    }

    var exitStatus: Int32? {
        get async {
            _ = await finished.wait()
            return nil
        }
    }

    var isRunning: Bool { finished.value == nil }

    /// Pulls output from the sign-in, then from the session's client.
    private actor Pump {
        private enum Stage {
            case login(PTYProcess)
            case connecting
            case client(any ProcessHandle)
            case done
        }

        private var stage: Stage
        private var iterator: AsyncStream<[UInt8]>.Iterator?
        private var tail: [UInt8] = []
        private var expiredAfter: Duration?
        private let hostName: String
        private let connect: @Sendable () async throws -> (any ProcessHandle)?
        private let isCancelled: @Sendable () -> Bool
        private let onFinish: @Sendable (String?) -> Void

        init(
            login: PTYProcess, hostName: String, connect: @escaping @Sendable () async throws -> (any ProcessHandle)?,
            isCancelled: @escaping @Sendable () -> Bool, onFinish: @escaping @Sendable (String?) -> Void
        ) {
            stage = .login(login)
            self.hostName = hostName
            self.connect = connect
            self.isCancelled = isCancelled
            self.onFinish = onFinish
        }

        /// The user did not finish signing in in time: end the sign-in.
        func expireSignIn(after timeout: Duration) async {
            guard case .login(let login) = stage else { return }
            expiredAfter = timeout
            await login.terminate()
        }

        func next() async -> [UInt8]? {
            while true {
                switch stage {
                case .login(let login):
                    if let bytes = await pull(login.output) {
                        tail = Array((tail + bytes).suffix(2048))
                        return bytes
                    }
                    let status = await login.exitStatus
                    if let expiredAfter {
                        return finish("Signing in to \(hostName) timed out after \(expiredAfter).")
                    }
                    if isCancelled() { return finish("Signing in to \(hostName) was cancelled.") }
                    guard status == 0 else {
                        let said = ZmxProtocol.printable(tail).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                        return finish(said.isEmpty ? "Signing in to \(hostName) did not succeed." : said)
                    }
                    stage = .connecting
                case .connecting:
                    do {
                        guard let client = try await connect() else { return finish("Signing in to \(hostName) was cancelled.") }
                        stage = .client(client)
                    } catch {
                        stage = .done
                        onFinish(String(describing: error))
                        return Array("\r\n\(error)\r\n".utf8)
                    }
                case .client(let client):
                    if let bytes = await pull(client.output) { return bytes }
                    _ = await client.exitStatus
                    return finish(nil)
                case .done:
                    return nil
                }
            }
        }

        /// The next batch of `stream`, or `nil` at its end.
        private func pull(_ stream: AsyncStream<[UInt8]>) async -> [UInt8]? {
            var current = iterator ?? stream.makeAsyncIterator()
            let bytes = await current.next(isolation: self)
            iterator = bytes == nil ? nil : current
            return bytes
        }

        /// Ends the stream; `failure` when the session was never reached.
        private func finish(_ failure: String?) -> [UInt8]? {
            stage = .done
            onFinish(failure)
            return nil
        }
    }
}
