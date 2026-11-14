import Darwin
import Foundation
import Testing
@testable import ArmadaleCore

/// The lock from an outcome expected to be `.acquired`; records an issue
/// and returns `nil` otherwise.
private func acquired(_ outcome: StateLock.Outcome, sourceLocation: SourceLocation = #_sourceLocation) -> StateLock? {
    if case .acquired(let lock) = outcome { return lock }
    Issue.record("expected the lock to be acquired, got \(outcome)", sourceLocation: sourceLocation)
    return nil
}

/// One process per state directory (docs/DESIGN.md section 3). A second
/// descriptor in the same process conflicts with the first (`flock` locks
/// belong to the open file description), so contention is tested here
/// without a second process.
@Suite("State directory lock")
struct StateLockTests {
    @Test func acquiresInAFreshDirectoryAndRecordsThePID() throws {
        let dir = try TempDirectory()
        let lock = try #require(acquired(StateLock.acquire(directory: dir.url)))
        #expect(lock.isHeld)
        #expect(lock.url == dir.url.appendingPathComponent("armadale.lock"))
        #expect(StateLock.recordedPID(in: dir.url) == getpid())
    }

    @Test func aSecondAcquireReportsTheHolder() throws {
        let dir = try TempDirectory()
        let lock = try #require(acquired(StateLock.acquire(directory: dir.url)))
        guard case .heldByAnotherProcess(let pid) = StateLock.acquire(directory: dir.url) else {
            Issue.record("a second acquire must report the lock as held")
            return
        }
        #expect(pid == getpid())
        // The failed attempt leaves the holder's pid in place.
        #expect(StateLock.recordedPID(in: dir.url) == getpid())
        withExtendedLifetime(lock) {}
    }

    @Test func releaseThenAcquireAgain() throws {
        let dir = try TempDirectory()
        let first = try #require(acquired(StateLock.acquire(directory: dir.url)))
        first.release()
        #expect(!first.isHeld)
        first.release() // twice is harmless
        let second = try #require(acquired(StateLock.acquire(directory: dir.url)))
        #expect(second.isHeld)
    }

    @Test func droppingTheValueReleasesTheLock() throws {
        let dir = try TempDirectory()
        do {
            _ = try #require(acquired(StateLock.acquire(directory: dir.url)))
        }
        #expect(acquired(StateLock.acquire(directory: dir.url)) != nil)
    }

    @Test func aLeftoverLockFileDoesNotBlock() throws {
        let dir = try TempDirectory()
        // As a dead process leaves it: a file with some other pid in it.
        try "99999\n".write(to: StateLock.lockFile(in: dir.url), atomically: true, encoding: .utf8)
        let lock = try #require(acquired(StateLock.acquire(directory: dir.url)))
        #expect(StateLock.recordedPID(in: dir.url) == getpid(), "the stale pid is replaced, not appended to")
        #expect(try String(contentsOf: lock.url, encoding: .utf8) == "\(getpid())\n")
    }

    @Test func createsTheDirectoryWhenMissing() throws {
        let dir = try TempDirectory()
        let nested = dir.url.appendingPathComponent("a/b", isDirectory: true)
        let lock = try #require(acquired(StateLock.acquire(directory: nested)))
        #expect(FileManager.default.fileExists(atPath: lock.url.path))
    }

    @Test func anUnusableDirectoryIsUnavailableNotHeld() throws {
        let dir = try TempDirectory()
        // A regular file where the directory should be.
        let file = dir.url.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        guard case .unavailable(let reason) = StateLock.acquire(directory: file) else {
            Issue.record("a file in place of the directory must be reported as unavailable")
            return
        }
        #expect(reason.contains(file.path))
        // And below it: the directory cannot be created.
        guard case .unavailable = StateLock.acquire(directory: file.appendingPathComponent("sub")) else {
            Issue.record("a directory that cannot be created must be reported as unavailable")
            return
        }
    }

    @Test func aLockFileThatCannotBeOpenedIsUnavailable() throws {
        let dir = try TempDirectory()
        // A directory where the lock file should be: open(O_RDWR) fails.
        try FileManager.default.createDirectory(at: StateLock.lockFile(in: dir.url), withIntermediateDirectories: false)
        guard case .unavailable(let reason) = StateLock.acquire(directory: dir.url) else {
            Issue.record("an unopenable lock file must be reported as unavailable")
            return
        }
        #expect(reason.contains("armadale.lock"))
    }

    @Test func pidParsing() {
        #expect(StateLock.parsePID("123\n") == 123)
        #expect(StateLock.parsePID(" 42 ") == 42)
        #expect(StateLock.parsePID("") == nil)
        #expect(StateLock.parsePID("0") == nil)
        #expect(StateLock.parsePID("-5") == nil)
        #expect(StateLock.parsePID("abc") == nil)
    }
}

/// The two tests that start child processes, serialized so they never
/// overlap: the control holds a descriptor without `O_CLOEXEC` across a
/// spawn, and a child the other test started at that moment (raw
/// `posix_spawn` passes every such descriptor) would inherit it and keep
/// the control's lock. No other test in this bundle starts a process.
@Suite("State directory lock and child processes", .serialized)
struct StateLockChildTests {
    private struct SpawnFailure: Error { var code: Int32 }

    /// `/bin/sleep 60` started with plain `posix_spawn`, which (unlike
    /// Foundation's `Process`) passes every descriptor not marked
    /// close-on-exec to the child, as a fork and exec would. Ended (and
    /// reaped) once, so a recycled pid is never signalled.
    private final class Sleeper {
        let pid: pid_t
        private var ended = false

        init() throws {
            var pid: pid_t = 0
            let args: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("60"), nil]
            defer { args.forEach { free($0) } }
            var environment: [UnsafeMutablePointer<CChar>?] = [nil]
            let result = posix_spawn(&pid, "/bin/sleep", nil, nil, args, &environment)
            guard result == 0 else { throw SpawnFailure(code: result) }
            self.pid = pid
        }

        var isRunning: Bool { !ended && kill(pid, 0) == 0 }

        func end() {
            guard !ended else { return }
            ended = true
            kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }

        deinit { end() }
    }

    @Test func aChildProcessDoesNotInheritTheLock() throws {
        let dir = try TempDirectory()
        let lock = try #require(acquired(StateLock.acquire(directory: dir.url)))
        let child = try Sleeper()
        defer { child.end() }
        lock.release()
        #expect(child.isRunning, "the child is still running")
        let again = acquired(StateLock.acquire(directory: dir.url))
        #expect(again != nil, "a child started while the lock was held must not keep it")
    }

    /// The control for the test above: a descriptor opened *without*
    /// `O_CLOEXEC` is inherited, and the child keeps the lock after the
    /// parent closes its copy. Without this, the test above could pass
    /// because the spawn closed descriptors on its own.
    @Test func anInheritedDescriptorWouldKeepTheLock() throws {
        let dir = try TempDirectory()
        let path = StateLock.lockFile(in: dir.url).path
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let child = try Sleeper()
        defer { child.end() }
        close(fd)
        guard case .heldByAnotherProcess = StateLock.acquire(directory: dir.url) else {
            Issue.record("the child should hold the inherited lock")
            return
        }
        child.end()
        #expect(acquired(StateLock.acquire(directory: dir.url)) != nil, "the lock is free once the child has exited")
    }
}
