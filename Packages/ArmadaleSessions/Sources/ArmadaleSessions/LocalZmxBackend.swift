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
    private let driver: ZmxSessionDriver<LocalZmxEndpoint>
    /// Versions of sessions this backend knows about, for control commands
    /// that only get an ID.
    private var versions: [SessionID: String] = [:]

    public init(configuration: Configuration) {
        self.configuration = configuration
        var driver = ZmxSessionDriver(endpoint: LocalZmxEndpoint(configuration: configuration, runner: CommandRunner()))
        driver.createTimeout = configuration.createTimeout
        driver.attachTimeout = configuration.attachTimeout
        driver.firstClientGrace = configuration.firstClientGrace
        self.driver = driver
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
        let version = configuration.executables.executable(forVersion: nil).version
        versions[session.id] = version
        let client = try await driver.create(session, version: version, size: size)
        return ZmxClient(process: client, runtimeVersion: version)
    }

    public func attach(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        let version = configuration.executables.executable(forVersion: session.runtimeVersion).version
        if let recorded = session.runtimeVersion { versions[session.id] = recorded }
        let client = try await driver.attach(session, version: version, size: size)
        return ZmxClient(process: client, runtimeVersion: version)
    }

    public func exists(_ id: SessionID) async throws -> Bool {
        try await driver.exists(id)
    }

    public func liveSessions() async throws -> Set<SessionID> {
        try await driver.liveSessions()
    }

    /// Kills the session. A session that no longer exists is not an error.
    public func kill(_ id: SessionID) async throws {
        try await driver.kill(id, version: versions[id])
    }

    public func history(_ id: SessionID) async throws -> Data {
        try await driver.history(id, version: versions[id])
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
}

/// zmx on this Mac: clients run the installed copy on a PTY through
/// `ctty-exec`, control commands go through a ``CommandRunner``, both with
/// the private runtime directory as `ZMX_DIR`.
struct LocalZmxEndpoint: ZmxEndpoint {
    let configuration: LocalZmxBackend.Configuration
    let runner: CommandRunner

    var attachOnlySentinel: [String] { [LocalZmxBackend.attachOnlySentinel] }
    var clientOutputMayHaveNoise: Bool { false }

    /// ctty-exec sets argv[0] (`-zsh` for a login shell), which zmx's argv
    /// cannot express, and removes zmx's variables from the program's
    /// environment; it is harmless in the daemon's child, which already has
    /// the PTY as its controlling terminal.
    func sessionProgram(for session: Session) throws -> [String] {
        let launch = configuration.resolver.resolve(session)
        let unset = LocalZmxBackend.variablesHiddenFromSessions.flatMap { ["--unset", $0] }
        return [try cttyExecPath()] + unset + [launch.program, launch.argv0] + launch.arguments
    }

    func spawnClient(_ arguments: [String], for session: Session, version: String?, size: PTYSize) throws -> PTYProcess {
        let zmx = configuration.executables.executable(forVersion: version).path
        let launch = configuration.resolver.resolve(session)
        // argv[0] is the full path of the installed copy, which the daemon
        // (a fork of this client) keeps: `pgrep -f` finds Armadale's daemons.
        do {
            return try PTYProcess.spawn(
                program: zmx,
                arguments: arguments,
                environment: configuration.runtime.environment(base: launch.environment),
                workingDirectory: launch.workingDirectory,
                size: size,
                options: PTYProcess.Options(argv0: zmx, helperPath: try cttyExecPath()))
        } catch let error as SpawnError {
            // Shown in the pane: describe it without the runtime's internals.
            throw BackendError.runtimeFailure(
                "The session service could not be started: \(String(cString: strerror(error.code))).")
        }
    }

    func control(_ arguments: [String], version: String?) async throws -> CommandResult {
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

    private func cttyExecPath() throws -> String {
        if let path = configuration.cttyExec { return path }
        return try HelperLocator.cttyExec().path
    }
}
