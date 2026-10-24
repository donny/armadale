import ArmadaleCore
import Foundation

/// Sessions as plain PTY processes with no daemon: they end when Armadale
/// quits, and cannot be reattached afterwards. The fallback when the session
/// runtime cannot be installed or a host cannot take a zmx deployment, and
/// selectable with `ARMADALE_BACKEND=ephemeral` for tests and debugging.
public actor EphemeralBackend: PersistenceBackend {
    private let resolver: LaunchResolver
    private let options: PTYProcess.Options
    private var processes: [SessionID: PTYProcess] = [:]

    public init(resolver: LaunchResolver = LaunchResolver(), options: PTYProcess.Options = PTYProcess.Options()) {
        self.resolver = resolver
        self.options = options
    }

    /// Spawns the session's program on a new PTY. If the session is already
    /// running here, returns its existing handle (whose output supports a
    /// single consumer).
    public func create(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        if let existing = processes[session.id], existing.isRunning { return existing }
        let launch = resolver.resolve(session)
        var options = options
        options.argv0 = launch.argv0
        let process = try PTYProcess.spawn(
            program: launch.program,
            arguments: launch.arguments,
            environment: launch.environment,
            workingDirectory: launch.workingDirectory,
            size: size,
            options: options)
        processes[session.id] = process
        return process
    }

    /// Always throws ``BackendError/notPersistent``: an ephemeral session that
    /// is not running in this process is gone for good.
    public func attach(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        throw BackendError.notPersistent(reason: nil)
    }

    public func exists(_ id: SessionID) async throws -> Bool {
        pruneExited()
        return processes[id] != nil
    }

    public func liveSessions() async throws -> Set<SessionID> {
        pruneExited()
        return Set(processes.keys)
    }

    /// Terminates the session's process (SIGHUP, then SIGKILL) and forgets it.
    public func kill(_ id: SessionID) async throws {
        guard let process = processes.removeValue(forKey: id) else { return }
        await process.terminate()
    }

    public func history(_ id: SessionID) async throws -> Data {
        throw BackendError.historyUnavailable(id)
    }

    /// The process is the session, so its exit always ends it. Its status
    /// is the process's own, which the controller already has.
    public func resolveExit(of session: Session) async -> ExitResolution {
        .ended(exitStatus: nil)
    }

    private func pruneExited() {
        processes = processes.filter { $0.value.isRunning }
    }
}

/// The backend of a session that cannot be reached at all any more (its
/// host was removed): it refuses to create or attach and never ends
/// anything, so closing such a pane leaves the session running where it is.
public actor UnavailableBackend: PersistenceBackend {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func create(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        throw BackendError.unreachable(reason)
    }

    public func attach(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        throw BackendError.unreachable(reason)
    }

    public func exists(_ id: SessionID) async throws -> Bool { throw BackendError.unreachable(reason) }
    public func liveSessions() async throws -> Set<SessionID> { throw BackendError.unreachable(reason) }
    /// Does nothing: the session is out of reach and must not be ended.
    public func kill(_ id: SessionID) async throws {}
    public func history(_ id: SessionID) async throws -> Data { throw BackendError.historyUnavailable(id) }
    public func resolveExit(of session: Session) async -> ExitResolution { .detached }
}
