import ArmadaleCore
import Darwin
import Foundation
import Testing
@testable import ArmadaleSessions

@Suite("ZmxRuntime")
struct ZmxRuntimeTests {
    @Test func runtimeDirectoryIsRunUnlessTooLongForASocket() {
        let normal = URL(fileURLWithPath: "/Users/donny/Library/Application Support/Armadale", isDirectory: true)
        #expect(ZmxRuntime.directory(forStateDirectory: normal, uid: 501) == "/Users/donny/Library/Application Support/Armadale/run")
        // 72 bytes for this socket: the design's figure.
        #expect(("/Users/donny/Library/Application Support/Armadale/run/a-" + String(repeating: "a", count: 16)).utf8.count == 72)

        // A home directory longer than 64 bytes no longer fits.
        let longHome = "/Users/" + String(repeating: "x", count: 58)
        #expect(longHome.utf8.count == 65)
        let long = URL(fileURLWithPath: longHome + "/Library/Application Support/Armadale", isDirectory: true)
        #expect(ZmxRuntime.directory(forStateDirectory: long, uid: 501) == "/tmp/armadale-501")
        #expect(ZmxRuntime(stateDirectory: long, uid: 77).directory == "/tmp/armadale-77")

        // Exactly at the limit: dir + "/" + 18 == 103.
        let exact = "/" + String(repeating: "d", count: 83)
        #expect(ZmxRuntime.fits(exact))
        #expect(!ZmxRuntime.fits(exact + "d"))
        // Multi-byte characters count in bytes.
        #expect(!ZmxRuntime.fits("/" + String(repeating: "é", count: 42)))
    }

    @Test func environmentScrubsSessionVariablesAndSetsTheRuntime() {
        let runtime = ZmxRuntime(directory: "/tmp/armadale-test-env")
        let environment = runtime.environment(base: [
            "ZMX_SESSION": "other", "ZMX_SESSION_PREFIX": "p-", "ZMX_DIR": "/elsewhere", "PATH": "/usr/bin", "HOME": "/h",
        ])
        #expect(environment["ZMX_SESSION"] == nil)
        #expect(environment["ZMX_SESSION_PREFIX"] == nil)
        #expect(environment["ZMX_DIR"] == "/tmp/armadale-test-env")
        #expect(environment["ZMX_NO_DETACH_KEY"] == "1")
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["HOME"] == "/h")
    }

    @Test func sessionNamesRoundTripAndForeignNamesAreRejected() {
        for _ in 0..<50 {
            let id = SessionID.generate()
            let name = ZmxRuntime.sessionName(for: id)
            #expect(name == "a-" + id.raw)
            #expect(name.utf8.count == ZmxRuntime.sessionNameLength)
            #expect(ZmxRuntime.sessionID(fromName: name) == id)
        }
        let foreign = [
            "", "a-", "work", "a-abcdefghijklmno", "a-abcdefghijklmnopq", "b-abcdefghijklmnop", "xa-abcdefghijklmnop",
            "a-ABCDEFGHIJKLMNOP", "a-abcdefghijklmn0p", "a-abcdefghijklmn1p", "a-abcdefghijklmn8p", "a_abcdefghijklmnop",
            "a-abcdefghijklmno ", "a-abcdefghijklmnop.log", "bogus-a-abcdefghijklmnop",
        ]
        for name in foreign {
            #expect(ZmxRuntime.sessionID(fromName: name) == nil, "\(name)")
        }
        #expect(ZmxRuntime.sessionID(fromName: "a-abcdefghijklm234") == SessionID(raw: "abcdefghijklm234"))
        #expect(ZmxProtocol.parseSessionList("a-abcdefghijklmnop\nwork\n\na-qrstuvwxyz234567\n  a-bogus\n")
            == [SessionID(raw: "abcdefghijklmnop"), SessionID(raw: "qrstuvwxyz234567")])
    }

    /// Sockets named like Armadale sessions count; plain files, foreign
    /// names and directories do not.
    @Test func sessionsWithSocketsListsArmadaleSockets() throws {
        let directory = "/tmp/arm-sock-\(getpid())-\(Int.random(in: 0..<100_000))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let runtime = ZmxRuntime(directory: directory)
        let sock = SessionID.generate(), file = SessionID.generate()
        var descriptors: [Int32] = []
        defer { descriptors.forEach { close($0) } }
        for name in ["a-\(sock.raw)", "work"] {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            #expect(fd >= 0)
            descriptors.append(fd)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = directory + "/" + name
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            #expect(bound == 0)
        }
        FileManager.default.createFile(atPath: directory + "/a-\(file.raw)", contents: Data())
        try FileManager.default.createDirectory(atPath: directory + "/logs", withIntermediateDirectories: true)
        #expect(runtime.sessionsWithSockets() == [sock])
        #expect(ZmxRuntime(directory: directory + "/missing").sessionsWithSockets().isEmpty)
    }

    /// Binds a Unix socket at `path`; returns its descriptor (close it).
    private func bindSocket(at path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(fd >= 0 && bound == 0)
        return fd
    }

    /// The launch housekeeping keeps the log and exit file of a session the
    /// listing left out whose socket exists (a stopped daemon), and of one
    /// listed and not ended; a session with neither, or one just ended
    /// without a socket, loses both.
    @Test func housekeepingKeepsFilesOfSessionsWithASocket() throws {
        let directory = "/tmp/arm-hk-\(getpid())-\(Int.random(in: 0..<100_000))"
        let runtime = ZmxRuntime(directory: directory)
        try FileManager.default.createDirectory(atPath: runtime.logDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let stopped = SessionID.generate(), listed = SessionID.generate()
        let gone = SessionID.generate(), ended = SessionID.generate()
        let fd = bindSocket(at: runtime.socketPath(for: stopped))
        defer { close(fd) }
        for id in [stopped, listed, gone, ended] {
            FileManager.default.createFile(atPath: runtime.logDirectory + "/a-\(id.raw).log", contents: Data("x".utf8))
            FileManager.default.createFile(atPath: runtime.exitFilePath(for: id), contents: Data("0".utf8))
        }
        let sockets = runtime.sessionsWithSockets()
        #expect(sockets == [stopped])
        let alive = ZmxRuntime.aliveForHousekeeping(listed: [listed, ended], ended: [ended], sockets: sockets)
        #expect(alive == [stopped, listed])
        let logs = Set(runtime.collectGarbageLogs(live: alive, referenced: []).map { ($0 as NSString).lastPathComponent })
        let exits = Set(runtime.collectGarbageExitStatuses(live: alive, referenced: []).map { ($0 as NSString).lastPathComponent })
        #expect(logs == ["a-\(gone.raw).log", "a-\(ended.raw).log"])
        #expect(exits == [gone, ended].map { (runtime.exitFilePath(for: $0) as NSString).lastPathComponent }.reduce(into: Set()) { $0.insert($1) })
        for id in [stopped, listed] {
            #expect(FileManager.default.fileExists(atPath: runtime.logDirectory + "/a-\(id.raw).log"))
            #expect(FileManager.default.fileExists(atPath: runtime.exitFilePath(for: id)))
        }
    }

    @Test func logGarbageCollectionKeepsLiveReferencedAndForeignFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "armadale-logs-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let runtime = ZmxRuntime(directory: directory)
        try FileManager.default.createDirectory(atPath: runtime.logDirectory, withIntermediateDirectories: true)
        let live = SessionID.generate(), referenced = SessionID.generate()
        let dead = SessionID.generate(), dead2 = SessionID.generate()
        let files = [
            "a-\(live.raw).log", "a-\(referenced.raw).log", "a-\(dead.raw).log", "a-\(dead2.raw).log",
            "zmx.log", "work.log", "a-short.log", "a-\(dead.raw).txt",
        ]
        for file in files {
            FileManager.default.createFile(atPath: runtime.logDirectory + "/" + file, contents: Data("x".utf8))
        }
        let removed = runtime.collectGarbageLogs(live: [live], referenced: [referenced])
        #expect(Set(removed.map { ($0 as NSString).lastPathComponent }) == ["a-\(dead.raw).log", "a-\(dead2.raw).log"])
        let left = try Set(FileManager.default.contentsOfDirectory(atPath: runtime.logDirectory))
        #expect(left == Set(files).subtracting(["a-\(dead.raw).log", "a-\(dead2.raw).log"]))
        // One retired session's log can be removed at once.
        runtime.removeLog(for: live)
        #expect(!FileManager.default.fileExists(atPath: runtime.logDirectory + "/a-\(live.raw).log"))
        #expect(FileManager.default.fileExists(atPath: runtime.logDirectory + "/a-\(referenced.raw).log"))
        runtime.removeLog(for: SessionID.generate()) // missing: harmless
        try FileManager.default.createDirectory(atPath: runtime.logDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: runtime.logDirectory + "/a-\(live.raw).log", contents: Data("x".utf8))
        // Nothing to do, and no directory at all, are both fine.
        #expect(runtime.collectGarbageLogs(live: [live], referenced: [referenced]).isEmpty)
        #expect(ZmxRuntime(directory: directory + "/missing").collectGarbageLogs(live: [], referenced: []).isEmpty)
    }

    /// Exit files (`<runtime>/a-<id>.exit`, docs/DESIGN.md section 4): read,
    /// removed with their session, and collected at launch when their
    /// session is neither live nor referenced; sockets, logs and foreign
    /// files are left alone.
    @Test func exitFilesAreReadRemovedAndCollected() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "armadale-exits-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let runtime = ZmxRuntime(directory: directory)
        try FileManager.default.createDirectory(atPath: runtime.logDirectory, withIntermediateDirectories: true)
        let live = SessionID.generate(), referenced = SessionID.generate()
        let dead = SessionID.generate(), dead2 = SessionID.generate()
        #expect(runtime.exitFilePath(for: live) == directory + "/a-\(live.raw).exit")
        let files = [
            "a-\(live.raw).exit", "a-\(referenced.raw).exit", "a-\(dead.raw).exit", "a-\(dead2.raw).exit.tmp",
            "a-\(dead.raw)", "work.exit", "a-short.exit", "a-\(dead2.raw).log",
        ]
        for file in files {
            FileManager.default.createFile(atPath: directory + "/" + file, contents: Data("3\n".utf8))
        }
        #expect(runtime.recordedExitStatus(for: referenced) == 3)
        #expect(runtime.recordedExitStatus(for: dead2) == nil, "a temporary file is not a record")
        let removed = runtime.collectGarbageExitStatuses(live: [live], referenced: [referenced])
        #expect(Set(removed.map { ($0 as NSString).lastPathComponent }) == ["a-\(dead.raw).exit", "a-\(dead2.raw).exit.tmp"])
        let left = try Set(FileManager.default.contentsOfDirectory(atPath: directory))
        #expect(left == Set(files + ["logs"]).subtracting(["a-\(dead.raw).exit", "a-\(dead2.raw).exit.tmp"]))
        runtime.removeExitStatus(for: referenced)
        #expect(runtime.recordedExitStatus(for: referenced) == nil)
        #expect(runtime.recordedExitStatus(for: live) == 3)
        // Contents: a decimal status and a newline; anything else is no record.
        // Local records: `N` is a normal exit, `signal N` a death by signal.
        #expect(ZmxRuntime.parseExitRecord("0\n") == .exited(0))
        #expect(ZmxRuntime.parseExitRecord("130\n") == .exited(130))
        #expect(ZmxRuntime.parseExitRecord("signal 9\n") == .signaled(9))
        #expect(ZmxRuntime.parseExitRecord("") == nil)
        #expect(ZmxRuntime.parseExitRecord("x\n") == nil)
        #expect(ZmxRuntime.parseExitRecord("signal x\n") == nil)
        // Remote records are `$?`: 128 and above is taken as a signal.
        #expect(ZmxRuntime.parseShellExitStatus("1\n") == .exited(1))
        #expect(ZmxRuntime.parseShellExitStatus("127\n") == .exited(127))
        #expect(ZmxRuntime.parseShellExitStatus("130\n") == .signaled(2))
        #expect(ZmxRuntime.parseShellExitStatus("x") == nil)
        #expect(ProgramExit.signaled(2).status == 130 && ProgramExit.exited(3).status == 3)
        #expect(ZmxRuntime(directory: directory + "/missing").collectGarbageExitStatuses(live: [], referenced: []).isEmpty)
    }

    @Test func prepareCreatesAPrivateDirectoryAndRefusesASymlink() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "armadale-prep-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let runtime = ZmxRuntime(directory: base + "/state/run")
        try runtime.prepare()
        #expect(try permissions(runtime.directory) == 0o700)
        // An existing directory with looser permissions is tightened.
        chmod(runtime.directory, 0o755)
        try runtime.prepare()
        #expect(try permissions(runtime.directory) == 0o700)
        // A symlink in its place is refused.
        try FileManager.default.createSymbolicLink(atPath: base + "/link", withDestinationPath: runtime.directory)
        #expect(throws: ZmxRuntime.SetupError.self) { try ZmxRuntime(directory: base + "/link").prepare() }
        // So is a file.
        FileManager.default.createFile(atPath: base + "/file", contents: nil)
        #expect(throws: ZmxRuntime.SetupError.self) { try ZmxRuntime(directory: base + "/file").prepare() }
    }

    /// The helper's log line after SIGTERM to the daemon (helper 0.8.1;
    /// `LocalZmxBackendTests` pins it against the real helper), as the
    /// launch check after a quit reads it (docs/DESIGN.md section 8,
    /// "Background App Activity").
    @Test func theLastTerminationSignalIsReadFromTheLog() {
        let name = "a-aaaaaaaaaaaaaaaa"
        let log = """
            [1794717100] [info] (default): daemon started session=\(name)
            [1794717105] [debug] (default): client connected session=\(name)
            [1794717111] [info] (default): SIGTERM received, shutting down gracefully session=\(name)
            [1794717111] [info] (default): shutting down daemon session=\(name)

            """
        #expect(ZmxRuntime.lastTerminationSignal(inLog: log, sessionName: name) == Date(timeIntervalSince1970: 1_794_717_111))
        // The last one counts; another session's line, a cut first line and
        // the helper's own kill do not.
        let mixed = """
            4717000] [info] (default): SIGTERM received, shutting down gracefully session=\(name)
            [1794717050] [info] (default): SIGTERM received, shutting down gracefully session=\(name)
            [1794717060] [info] (default): SIGTERM received, shutting down gracefully session=a-bbbbbbbbbbbbbbbb
            [1794717070] [info] (default): kill received session=\(name)
            [1794717071] [info] (default): shutting down daemon session=\(name)
            """
        #expect(ZmxRuntime.lastTerminationSignal(inLog: mixed, sessionName: name) == Date(timeIntervalSince1970: 1_794_717_050))
        let none = """
            [1794717070] [info] (default): kill received session=\(name)
            [1794717071] [info] (default): shutting down daemon session=\(name)
            """
        #expect(ZmxRuntime.lastTerminationSignal(inLog: none, sessionName: name) == nil)
        #expect(ZmxRuntime.lastTerminationSignal(inLog: "", sessionName: name) == nil)
        // A tail that starts mid-line: its only SIGTERM line is the cut one,
        // whose time is gone, so nothing is found.
        let cut = """
            94717111] [info] (default): SIGTERM received, shutting down gracefully session=\(name)
            [1794717111] [info] (default): shutting down daemon session=\(name)
            """
        #expect(ZmxRuntime.lastTerminationSignal(inLog: cut, sessionName: name) == nil)
        let cutToDigits = "1794717111] [info] (default): SIGTERM received, shutting down gracefully session=\(name)"
        #expect(ZmxRuntime.lastTerminationSignal(inLog: cutToDigits, sessionName: name) == nil)
        // The last line without a trailing newline still counts.
        let unterminated = "[1794717100] [info] (default): daemon started session=\(name)\n"
            + "[1794717111] [info] (default): SIGTERM received, shutting down gracefully session=\(name)"
        #expect(ZmxRuntime.lastTerminationSignal(inLog: unterminated, sessionName: name) == Date(timeIntervalSince1970: 1_794_717_111))
        #expect(ZmxRuntime.lastTerminationSignal(
            inLog: "[x] [info] (default): SIGTERM received, shutting down gracefully session=\(name)", sessionName: name) == nil)
    }

    @Test func onlyTheLogsTailIsRead() throws {
        let directory = "/tmp/armadale-test-\(getpid())-\(String(UInt32.random(in: 0...UInt32.max), radix: 36))"
        defer { if directory.hasPrefix("/tmp/armadale-test-") { try? FileManager.default.removeItem(atPath: directory) } }
        let runtime = ZmxRuntime(directory: directory)
        try FileManager.default.createDirectory(atPath: runtime.logDirectory, withIntermediateDirectories: true)
        let id = SessionID.generate()
        let name = ZmxRuntime.sessionName(for: id)
        #expect(runtime.lastTerminationSignal(for: id) == nil, "no log")
        let line = "[1794717111] [info] (default): SIGTERM received, shutting down gracefully session=\(name)\n"
        let filler = String(repeating: "[1794717000] [debug] (default): client connected session=\(name)\n", count: 3000)
        let path = runtime.logDirectory + "/\(name).log"
        // At the end of a log larger than the tail: found.
        try (filler + line).write(toFile: path, atomically: true, encoding: .utf8)
        #expect((filler + line).utf8.count > ZmxRuntime.terminationLogTail)
        #expect(runtime.lastTerminationSignal(for: id) == Date(timeIntervalSince1970: 1_794_717_111))
        // Further back than the tail: not read.
        try (line + filler).write(toFile: path, atomically: true, encoding: .utf8)
        #expect(runtime.lastTerminationSignal(for: id) == nil)
    }

    private func permissions(_ path: String) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }
}
