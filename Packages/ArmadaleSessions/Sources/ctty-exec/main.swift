// ctty-exec: the trampoline `PTYProcess` spawns children through.
//
// The parent has already made this process a session leader
// (POSIX_SPAWN_SETSID) with the PTY slave on fds 0, 1 and 2. On macOS 27 that
// alone does not make the slave the controlling terminal, so the child would
// get neither SIGINT from ^C nor SIGWINCH on resize (docs/DESIGN.md section 7).
// This makes fd 0 the controlling terminal, then execs the real program.
//
// It is also the program zmx runs inside a session: there it sets argv[0]
// (`-zsh` for a login shell), which zmx's command line cannot express, and
// removes zmx's own variables (`--unset`) from the program's environment.
//
// With `--exit-file <path>` it records how the program ended instead of
// exec'ing it (docs/DESIGN.md section 4, "Ended"): it starts the program as
// its child (argv[0], environment and signal dispositions as an exec would
// pass them), stays out of the way of job control (it ignores the keyboard
// and background-terminal signals, which still reach the program with their
// default actions, and never touches the terminal), passes SIGHUP and
// SIGTERM on to the program, waits for it, writes the record to the file
// atomically (a temporary file and a rename): `N` for a normal exit with
// status N, `signal N` for a death by signal N. It then exits with the
// status (128 + N after a signal, as shells report it). After it has passed
// on SIGHUP or SIGTERM it writes nothing: the session is being ended from
// outside (zmx's kill, a hangup), and the app removes the file of a session
// it ends, which a late write would bring back.
//
// usage: ctty-exec [--unset VAR]... [--exit-file PATH] <absolute-path> <argv0> [args...]
import Darwin

var arguments = Array(CommandLine.arguments.dropFirst())
var exitFile: String?
while arguments.count >= 2 {
    if arguments[0] == "--unset" {
        unsetenv(arguments[1])
    } else if arguments[0] == "--exit-file" {
        exitFile = arguments[1]
    } else {
        break
    }
    arguments.removeFirst(2)
}
guard arguments.count >= 2 else {
    fputs("usage: ctty-exec [--unset VAR]... [--exit-file PATH] /path/to/program argv0 [args...]\n", stderr)
    exit(127)
}
if ioctl(0, TIOCSCTTY, 0) != 0 {
    perror("ctty-exec: TIOCSCTTY") // Not fatal: still run the program.
}
let argv = arguments.dropFirst().map { strdup($0) } + [nil]
guard let exitFile else {
    execv(arguments[0], argv)
    perror("ctty-exec: execv \(arguments[0])")
    exit(127)
}
recordExit(program: arguments[0], argv: argv, to: exitFile)

/// Runs `program` as a child and records how it ended in `path`; never returns.
func recordExit(program: String, argv: [UnsafeMutablePointer<CChar>?], to path: String) -> Never {
    // Signals the program gets and this process does not act on: ^C, ^\ and
    // ^Z go to the terminal's foreground process group, which includes this
    // process while the program has not taken a group of its own (a bare
    // program; an interactive shell moves itself into its own group).
    // Never touching the terminal, it needs no SIGTTIN or SIGTTOU either.
    let ignored = [SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU]
    // Signals it waits for: the program's exit, and the hangup or
    // termination request (zmx ends a session with SIGHUP to its child),
    // which it passes on.
    let forwarded = [SIGHUP, SIGTERM]
    var waited = sigset_t()
    sigemptyset(&waited)
    for signal in forwarded + [SIGCHLD] { sigaddset(&waited, signal) }
    var original = sigset_t()
    sigprocmask(SIG_BLOCK, &waited, &original)
    // The program gets back the default action of each signal this process
    // ignores, unless it was ignored already (an exec would keep it
    // ignored). SIGHUP and SIGTERM keep their dispositions (only blocked
    // here); the SIGCHLD handler below becomes the default in the program,
    // as any caught signal does across an exec.
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for signal in ignored {
        var current = sigaction()
        sigaction(signal, nil, &current)
        if current.__sigaction_u.__sa_handler == nil { sigaddset(&defaults, signal) } // SIG_DFL is 0
        Darwin.signal(signal, SIG_IGN)
    }
    // A caught (not ignored) SIGCHLD, so a blocked one stays pending for
    // sigwait; the handler never runs.
    signal(SIGCHLD) { _ in }

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    posix_spawnattr_setsigmask(&attributes, &original)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
    var child: pid_t = 0
    let spawned = posix_spawn(&child, program, nil, &attributes, argv, environ)
    posix_spawnattr_destroy(&attributes)
    guard spawned == 0 else {
        fputs("ctty-exec: \(program): \(String(cString: strerror(spawned)))\n", stderr)
        finish(status: 127, signal: nil, path: path)
    }

    var endedFromOutside = false
    while true {
        var received: Int32 = 0
        guard sigwait(&waited, &received) == 0 else { continue }
        if received == SIGCHLD {
            var status: Int32 = 0
            let reaped = waitpid(child, &status, WNOHANG)
            if reaped == child {
                let signal = status & 0x7F
                if signal == 0x7F { continue } // stopped: still running
                finish(
                    status: signal == 0 ? (status >> 8) & 0xFF : 128 + signal,
                    signal: signal == 0 ? nil : signal,
                    path: endedFromOutside ? nil : path)
            }
            if reaped < 0, errno == ECHILD { finish(status: 127, signal: nil, path: endedFromOutside ? nil : path) }
        } else {
            // To the program's process group when it has one of its own (a
            // shell leads its own; it passes the signal on to its jobs
            // itself), else to the program alone (it shares this process's
            // group). Once only either way.
            endedFromOutside = true
            let group = getpgid(child)
            if group > 0, group != getpgrp() {
                kill(-group, received)
                if group != child { kill(child, received) }
            } else {
                kill(child, received)
            }
        }
    }
}

/// Writes the record (`N`, or `signal N` after a death by signal N) to
/// `path` through a temporary file and a rename, so a reader never sees a
/// partial file, then exits with `status`. No `path`: nothing is written.
/// Failures are not reported: the terminal belongs to the session, and an
/// unrecorded status only means the app shows the session as ended without
/// one.
func finish(status: Int32, signal: Int32?, path: String?) -> Never {
    guard let path else { exit(status) }
    let temporary = path + ".tmp"
    let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    if fd >= 0 {
        let text = Array((signal.map { "signal \($0)" } ?? "\(status)").utf8) + [0x0A]
        let written = text.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        if written == text.count { rename(temporary, path) } else { unlink(temporary) }
    }
    exit(status)
}
