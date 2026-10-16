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
        throw BackendError.notPersistent
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

    /// The process is the session, so its exit always ends it.
    public func resolveExit(of session: Session) async -> ExitResolution {
        .ended
    }

    private func pruneExited() {
        processes = processes.filter { $0.value.isRunning }
    }
}
