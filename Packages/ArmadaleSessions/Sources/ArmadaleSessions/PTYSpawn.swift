import Darwin

/// A system call failed while starting a process on a PTY.
public struct SpawnError: Error, CustomStringConvertible, Sendable, Equatable {
    /// The failing call, e.g. `posix_spawn`.
    public let call: String
    /// The `errno` (or returned error code) of the failure.
    public let code: Int32

    public init(call: String, code: Int32) {
        self.call = call
        self.code = code
    }

    public var description: String { "\(call) failed: \(String(cString: strerror(code))) (\(code))" }
}

/// A child process freshly started on a PTY.
struct PTYChild: Sendable {
    let pid: pid_t
    /// The master side. Close-on-exec; the caller owns it.
    let masterFD: Int32
    /// Path of the slave device, e.g. `/dev/ttys004`.
    let slavePath: String
}

/// What a spawn needs, already flattened to C-friendly strings.
struct SpawnRequest: Sendable {
    /// Absolute path of the program to execute.
    var executable: String
    /// Full argv, including argv[0].
    var argv: [String]
    /// `KEY=VALUE` entries.
    var environment: [String]
    var workingDirectory: String?
    var size: PTYSize
}

/// Starts `request` on a new PTY with `posix_spawn`, through the `ctty-exec`
/// trampoline at `helper`.
///
/// `openpty()`, then `posix_spawn` with `SETSID | CLOEXEC_DEFAULT |
/// SETSIGMASK | SETSIGDEF`: only fds 0–2 (the slave) reach the child, and it
/// inherits neither the app's blocked nor its ignored signals. On macOS 27
/// `SETSID` plus an open of the slave does not acquire a controlling
/// terminal, so the trampoline does `ioctl(TIOCSCTTY)` and then `execv`s the
/// real program (docs/DESIGN.md section 7). Ported from the verified spike.
func spawnOnPTY(_ request: SpawnRequest, helper: String) throws(SpawnError) -> PTYChild {
    let (master, slave, slavePath) = try openPTY(size: request.size)
    // Keep `slave` open until posix_spawn returns: if the last slave fd closes
    // before the child opens it, the tty is reset and the window size reads
    // back as 0x0.
    defer { close(slave) }

    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
    }

    posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
    posix_spawn_file_actions_adddup2(&actions, 0, 1)
    posix_spawn_file_actions_adddup2(&actions, 0, 2)
    if let directory = request.workingDirectory {
        // addchdir_np is deprecated since macOS 26.
        posix_spawn_file_actions_addchdir(&actions, directory)
    }

    var noSignals = sigset_t()
    sigemptyset(&noSignals)
    var allSignals = sigset_t()
    sigfillset(&allSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    posix_spawnattr_setsigdefault(&attributes, &allSignals)
    let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
    posix_spawnattr_setflags(&attributes, Int16(flags))

    // ctty-exec <path> <argv0> <args...>
    let argv = (["ctty-exec", request.executable] + request.argv).map { strdup($0) } + [nil]
    let envp = request.environment.map { strdup($0) } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }

    var pid: pid_t = 0
    let result = posix_spawn(&pid, helper, &actions, &attributes, argv, envp)
    guard result == 0 else {
        close(master)
        throw SpawnError(call: "posix_spawn", code: result)
    }
    return PTYChild(pid: pid, masterFD: master, slavePath: slavePath)
}

/// Opens a PTY pair with both ends close-on-exec from the moment they exist
/// (`O_CLOEXEC` on the open itself), so a process launched concurrently by
/// other code in the app (Foundation's `Process`, say) can never inherit the
/// master. `openpty()` followed by `fcntl(FD_CLOEXEC)` leaves a window where
/// it could. Both ends are opened `O_NOCTTY` so the app never acquires the
/// terminal itself.
func openPTY(size: PTYSize) throws(SpawnError) -> (master: Int32, slave: Int32, slavePath: String) {
    let master = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC)
    guard master >= 0 else { throw SpawnError(call: "open /dev/ptmx", code: errno) }
    guard grantpt(master) == 0, unlockpt(master) == 0 else {
        let code = errno
        close(master)
        throw SpawnError(call: "grantpt/unlockpt", code: code)
    }
    var nameBuffer = [CChar](repeating: 0, count: 128)
    guard ptsname_r(master, &nameBuffer, nameBuffer.count) == 0 else {
        let code = errno
        close(master)
        throw SpawnError(call: "ptsname_r", code: code)
    }
    let slavePath = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let slave = open(slavePath, O_RDWR | O_NOCTTY | O_CLOEXEC)
    guard slave >= 0 else {
        let code = errno
        close(master)
        throw SpawnError(call: "open \(slavePath)", code: code)
    }
    var window = winsize(size)
    guard ioctl(slave, TIOCSWINSZ, &window) == 0 else {
        let code = errno
        close(slave)
        close(master)
        throw SpawnError(call: "TIOCSWINSZ", code: code)
    }
    return (master, slave, slavePath)
}

/// Starts `request` on a new PTY with `forkpty()`, which makes the slave the
/// controlling terminal itself, so no helper is needed. Everything is
/// prepared before the fork; the child only makes async-signal-safe calls.
/// The fallback for when the trampoline is unavailable.
func spawnWithForkpty(_ request: SpawnRequest) throws(SpawnError) -> PTYChild {
    let argv = request.argv.map { strdup($0) } + [nil]
    let envp = request.environment.map { strdup($0) } + [nil]
    let executable = strdup(request.executable)
    let directory: UnsafeMutablePointer<CChar>? = request.workingDirectory.flatMap { strdup($0) }
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
        free(executable)
        free(directory)
    }
    let resetSignals: [Int32] = [
        SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD, SIGTSTP, SIGTTIN, SIGTTOU, SIGWINCH, SIGUSR1, SIGUSR2,
    ]
    let maxFD = min(Int32(getdtablesize()), 4096)
    var none = sigset_t()
    sigemptyset(&none)
    var size = winsize(request.size)
    var nameBuffer = [CChar](repeating: 0, count: 128)
    var master: Int32 = -1
    let pid = resetSignals.withUnsafeBufferPointer { signals in
        nameBuffer.withUnsafeMutableBufferPointer { name in
            let pid = forkpty(&master, name.baseAddress, nil, &size)
            if pid == 0 {
                // Child: plain C calls only.
                if let directory, chdir(directory) != 0 { _exit(126) }
                sigprocmask(SIG_SETMASK, &none, nil)
                for signal in signals { _ = Darwin.signal(signal, SIG_DFL) }
                var fd: Int32 = 3
                while fd < maxFD {
                    close(fd)
                    fd += 1
                }
                execve(executable, argv, envp)
                _exit(127)
            }
            return pid
        }
    }
    if pid < 0 { throw SpawnError(call: "forkpty", code: errno) }
    // forkpty() cannot open the master close-on-exec, so this fallback keeps
    // a short window in which a concurrent launch elsewhere could inherit it.
    _ = fcntl(master, F_SETFD, FD_CLOEXEC)
    let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return PTYChild(pid: pid, masterFD: master, slavePath: name)
}

extension winsize {
    init(_ size: PTYSize) {
        self.init(ws_row: size.rows, ws_col: size.columns, ws_xpixel: size.pixelWidth, ws_ypixel: size.pixelHeight)
    }
}
