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
// usage: ctty-exec [--unset VAR]... <absolute-path> <argv0> [args...]
import Darwin

var arguments = Array(CommandLine.arguments.dropFirst())
while arguments.count >= 2, arguments[0] == "--unset" {
    unsetenv(arguments[1])
    arguments.removeFirst(2)
}
guard arguments.count >= 2 else {
    fputs("usage: ctty-exec [--unset VAR]... /path/to/program argv0 [args...]\n", stderr)
    exit(127)
}
if ioctl(0, TIOCSCTTY, 0) != 0 {
    perror("ctty-exec: TIOCSCTTY") // Not fatal: still run the program.
}
let argv = arguments.dropFirst().map { strdup($0) } + [nil]
execv(arguments[0], argv)
perror("ctty-exec: execv \(arguments[0])")
exit(127)
