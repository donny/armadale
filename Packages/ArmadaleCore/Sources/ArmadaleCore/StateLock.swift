import Darwin
import Foundation

/// One Armadale process per state directory (docs/DESIGN.md section 3,
/// "One process per state directory").
///
/// An exclusive, non-blocking `flock` on ``fileName`` inside the state
/// directory, held for the life of the process: the descriptor stays open
/// until ``release()`` or deinit, and the app never releases it. The kernel
/// drops the lock when the process exits however it exits, so a lock file
/// left behind by a dead process blocks nothing, and the file is never
/// deleted.
///
/// The descriptor is opened close-on-exec (`O_CLOEXEC` on the `open`
/// itself, so no fork between `open` and `fcntl` can leak it): session
/// daemons outlive the app, and one that inherited the descriptor would
/// share the open file description and hold the lock for as long as it
/// runs.
public final class StateLock {
    /// The lock file's name inside the state directory.
    public static let fileName = "armadale.lock"

    /// What ``acquire(directory:fileManager:)`` found.
    public enum Outcome {
        /// This process holds the lock; keep the value alive.
        case acquired(StateLock)
        /// Another process (or another descriptor in this one) holds it.
        /// `pid` is what the holder wrote into the file, when readable.
        case heldByAnotherProcess(pid: pid_t?)
        /// No lock could be taken for another reason (the directory cannot
        /// be created, the file cannot be opened, the volume does not
        /// support `flock`, an I/O error). Not a reason to stop a launch.
        case unavailable(reason: String)
    }

    /// The lock file.
    public let url: URL
    private var descriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// Whether this value still holds the lock.
    public var isHeld: Bool { descriptor >= 0 }

    /// Lets go of the lock (tests; the app never calls this).
    public func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    /// The lock file of `directory`.
    public static func lockFile(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Takes the lock on `directory`, creating the directory if needed. On
    /// success this process's pid is written into the file (diagnostics
    /// only; a failed write does not matter).
    public static func acquire(directory: URL, fileManager: FileManager = .default) -> Outcome {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .unavailable(reason: "could not create \(directory.path): \(error.localizedDescription)")
        }
        let url = lockFile(in: directory)
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { errno = EINVAL; return -1 }
            return open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        }
        guard fd >= 0 else {
            return .unavailable(reason: "could not open \(url.path): \(describe(errno))")
        }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            if error == EINTR { continue }
            if error == EWOULDBLOCK {
                let pid = readPID(fd)
                close(fd)
                return .heldByAnotherProcess(pid: pid)
            }
            close(fd)
            return .unavailable(reason: "could not lock \(url.path): \(describe(error))")
        }
        writePID(getpid(), to: fd)
        return .acquired(StateLock(url: url, descriptor: fd))
    }

    /// The pid recorded in the lock file at `directory`, if any (read
    /// without locking).
    public static func recordedPID(in directory: URL) -> pid_t? {
        guard let text = try? String(contentsOf: lockFile(in: directory), encoding: .utf8) else { return nil }
        return parsePID(text)
    }

    static func parsePID(_ text: String) -> pid_t? {
        guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    private static func readPID(_ fd: Int32) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard count > 0 else { return nil }
        return parsePID(String(decoding: buffer[0..<count], as: UTF8.self))
    }

    private static func writePID(_ pid: pid_t, to fd: Int32) {
        let bytes = Array("\(pid)\n".utf8)
        guard ftruncate(fd, 0) == 0 else { return }
        _ = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
    }

    private static func describe(_ error: Int32) -> String {
        "\(String(cString: strerror(error))) (errno \(error))"
    }
}
