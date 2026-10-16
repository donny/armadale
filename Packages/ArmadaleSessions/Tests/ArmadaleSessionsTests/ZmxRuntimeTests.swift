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
        #expect(LocalZmxBackend.parseSessionList("a-abcdefghijklmnop\nwork\n\na-qrstuvwxyz234567\n  a-bogus\n")
            == [SessionID(raw: "abcdefghijklmnop"), SessionID(raw: "qrstuvwxyz234567")])
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

    private func permissions(_ path: String) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }
}
