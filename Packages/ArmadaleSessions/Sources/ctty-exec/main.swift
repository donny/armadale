// ctty-exec: the trampoline `PTYProcess` spawns children through.
//
// The parent has already made this process a session leader
// (POSIX_SPAWN_SETSID) with the PTY slave on fds 0, 1 and 2. On macOS 27 that
// alone does not make the slave the controlling terminal, so the child would
// get neither SIGINT from ^C nor SIGWINCH on resize (docs/DESIGN.md section 7).
// This makes fd 0 the controlling terminal, then execs the real program.
//
// usage: ctty-exec <absolute-path> <argv0> [args...]
import Darwin

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    fputs("usage: ctty-exec /path/to/program argv0 [args...]\n", stderr)
    exit(127)
}
if ioctl(0, TIOCSCTTY, 0) != 0 {
    perror("ctty-exec: TIOCSCTTY") // Not fatal: still run the program.
}
let argv = arguments.dropFirst(2).map { strdup($0) } + [nil]
execv(arguments[1], argv)
perror("ctty-exec: execv \(arguments[1])")
exit(127)
