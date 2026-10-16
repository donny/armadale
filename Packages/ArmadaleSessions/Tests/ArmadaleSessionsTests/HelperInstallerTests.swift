import ArmadaleCore
import Darwin
import Foundation
import Testing
@testable import ArmadaleSessions

@Suite("HelperInstaller")
struct HelperInstallerTests {
    /// A scratch directory with fake helper binaries.
    private final class Scratch {
        let root: String
        let bin: URL
        let zmx: URL
        let ctty: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "armadale-install-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: root + "/bundle", withIntermediateDirectories: true)
            bin = URL(fileURLWithPath: root + "/state/bin", isDirectory: true)
            zmx = URL(fileURLWithPath: root + "/bundle/zmx")
            ctty = URL(fileURLWithPath: root + "/bundle/ctty-exec")
            try write("#!/bin/sh\necho zmx v1\n", to: zmx)
            try write("#!/bin/sh\necho ctty v1\n", to: ctty)
        }

        deinit {
            if root.contains("/armadale-install-") { try? FileManager.default.removeItem(atPath: root) }
        }

        func write(_ text: String, to url: URL) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o755)
        }

        func installer(zmxVersion: String = "0.8.1", appVersion: String = "1.0") -> HelperInstaller {
            HelperInstaller(binDirectory: bin, zmxSource: zmx, zmxVersion: zmxVersion, cttyExecSource: ctty, cttyExecVersion: appVersion)
        }

        func names() throws -> Set<String> {
            try Set(FileManager.default.contentsOfDirectory(atPath: bin.path))
        }
    }

    private func inode(_ url: URL) throws -> UInt64 {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return info.st_ino
    }

    @Test func copiesBothHelpersExecutable() throws {
        let scratch = try Scratch()
        let installed = try scratch.installer().install(referencedZmxVersions: [])
        #expect(installed.zmx.path == scratch.bin.path + "/zmx-0.8.1")
        #expect(installed.cttyExec.path == scratch.bin.path + "/ctty-exec-1.0")
        #expect(try Data(contentsOf: installed.zmx) == Data(contentsOf: scratch.zmx))
        #expect(try Data(contentsOf: installed.cttyExec) == Data(contentsOf: scratch.ctty))
        #expect(FileManager.default.isExecutableFile(atPath: installed.zmx.path))
        #expect(FileManager.default.isExecutableFile(atPath: installed.cttyExec.path))
        let mode = try FileManager.default.attributesOfItem(atPath: installed.zmx.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(installed.zmxCopies == ["0.8.1": installed.zmx])
        #expect(installed.zmxExecutables.current == installed.zmx.path)
        #expect(try scratch.names() == ["zmx-0.8.1", "ctty-exec-1.0"])
    }

    @Test func identicalCopiesAreLeftAloneAndDifferentOnesReplaced() throws {
        let scratch = try Scratch()
        let installer = scratch.installer()
        let first = try installer.install(referencedZmxVersions: [])
        let inodeBefore = try inode(first.zmx)
        _ = try installer.install(referencedZmxVersions: [])
        #expect(try inode(first.zmx) == inodeBefore, "an identical copy is not rewritten")

        // A different build of the same version (re-signed, say) replaces
        // the copy atomically: a new file, not a rewrite in place.
        try scratch.write("#!/bin/sh\necho zmx v1 resigned\n", to: scratch.zmx)
        _ = try installer.install(referencedZmxVersions: [])
        #expect(try String(contentsOf: first.zmx, encoding: .utf8) == "#!/bin/sh\necho zmx v1 resigned\n")
        #expect(try inode(first.zmx) != inodeBefore)

        // A tampered or truncated copy is repaired; so is a lost x bit.
        try "garbage".write(to: first.cttyExec, atomically: false, encoding: .utf8)
        chmod(first.zmx.path, 0o644)
        _ = try installer.install(referencedZmxVersions: [])
        #expect(try Data(contentsOf: first.cttyExec) == Data(contentsOf: scratch.ctty))
        #expect(FileManager.default.isExecutableFile(atPath: first.zmx.path))
        #expect(try !scratch.names().contains { $0.contains("partial") })
    }

    @Test func referencedOldVersionsAreKeptAndOthersRemoved() throws {
        let scratch = try Scratch()
        try FileManager.default.createDirectory(at: scratch.bin, withIntermediateDirectories: true)
        for name in ["zmx-0.7.0", "zmx-0.6.0", "ctty-exec-0.9", ".zmx-0.8.1.partial-ABC"] {
            try scratch.write("old", to: scratch.bin.appending(path: name))
        }
        let installed = try scratch.installer().install(referencedZmxVersions: ["0.7.0", "0.5.0"])
        #expect(try scratch.names() == ["zmx-0.8.1", "zmx-0.7.0", "ctty-exec-1.0"])
        #expect(Set(installed.zmxCopies.keys) == ["0.8.1", "0.7.0"])
        #expect(installed.zmx(forVersion: "0.7.0").lastPathComponent == "zmx-0.7.0")
        #expect(installed.zmx(forVersion: "0.5.0") == installed.zmx, "a missing copy falls back to the current one")
        #expect(installed.zmx(forVersion: nil) == installed.zmx)
        let executables = installed.zmxExecutables
        #expect(executables.executable(forVersion: "0.7.0").version == "0.7.0")
        #expect(executables.executable(forVersion: "0.5.0") == (installed.zmx.path, "0.8.1"))

        // Once nothing references 0.7.0 it goes too.
        _ = try scratch.installer().install(referencedZmxVersions: [])
        #expect(try scratch.names() == ["zmx-0.8.1", "ctty-exec-1.0"])
    }

    @Test func forAppHonoursStateDirectoryAndOverrides() throws {
        let scratch = try Scratch()
        let environment = [
            "ARMADALE_STATE_DIR": scratch.root + "/custom-state",
            "ARMADALE_ZMX": scratch.zmx.path,
            "ARMADALE_CTTY_EXEC": scratch.ctty.path,
        ]
        let installer = try HelperInstaller.forApp(environment: environment)
        #expect(installer.binDirectory.standardizedFileURL.path == scratch.root + "/custom-state/bin")
        #expect(installer.zmxSource.path == scratch.zmx.path)
        #expect(installer.cttyExecSource.path == scratch.ctty.path)
        #expect(installer.zmxVersion == ZmxVersion.current)
        let installed = try installer.install(referencedZmxVersions: [])
        #expect(FileManager.default.fileExists(atPath: scratch.root + "/custom-state/bin/zmx-\(ZmxVersion.current)"))
        #expect(installed.cttyExec.lastPathComponent.hasPrefix("ctty-exec-"))
    }

    @Test func missingSourceFails() throws {
        let scratch = try Scratch()
        let installer = HelperInstaller(
            binDirectory: scratch.bin, zmxSource: URL(fileURLWithPath: scratch.root + "/nope"), zmxVersion: "1",
            cttyExecSource: scratch.ctty, cttyExecVersion: "1")
        #expect(throws: HelperInstaller.InstallError.self) { try installer.install(referencedZmxVersions: []) }
    }
}

@Suite("Bundled zmx")
struct BundledZmxTests {
    /// ZmxVersion.current must name the release scripts/zmx.lock pins.
    @Test func versionMatchesTheLockFile() throws {
        let lock = try String(contentsOf: repositoryRoot.appending(path: "scripts/zmx.lock"), encoding: .utf8)
        let versionLine = lock.split(separator: "\n").first { $0.hasPrefix("version ") }
        let version = try #require(versionLine).split(separator: " ").last.map(String.init)
        #expect(version == ZmxVersion.current)
        // Every pinned tarball is for that version.
        let tarballs = lock.split(separator: "\n").filter { $0.contains(".tar.gz") }
        #expect(tarballs.count == 4)
        for line in tarballs {
            #expect(line.contains("zmx-\(ZmxVersion.current)-"), "\(line)")
        }
    }

    @Test func locatorFindsTheVendoredBinaryAndHonoursTheOverride() throws {
        let zmx = try testZmx()
        #expect(FileManager.default.isExecutableFile(atPath: zmx))
        #expect(try HelperLocator.zmx(environment: [HelperLocator.zmxOverride: "/usr/bin/true"]).path == "/usr/bin/true")
        #expect(HelperLocator.vendoredZmx.path.hasSuffix("Vendor/zmx/macos-aarch64/zmx")
            || HelperLocator.vendoredZmx.path.hasSuffix("Vendor/zmx/macos-x86_64/zmx"))
        let missing = HelperLocator.NotFound(name: "zmx", searched: ["/x"])
        #expect(missing.description.contains("scripts/fetch-zmx.sh"))
    }

    /// An override that names a missing file is an error, not a reason to
    /// fall back to the bundled or vendored copy.
    @Test func aBadOverrideIsAnErrorNotAFallback() throws {
        do {
            _ = try HelperLocator.zmx(environment: [HelperLocator.zmxOverride: "/nonexistent/zmx"])
            Issue.record("a missing ARMADALE_ZMX fell back to another zmx")
        } catch {
            #expect(error.badOverride?.variable == "ARMADALE_ZMX")
            #expect(error.description.contains("/nonexistent/zmx"))
        }
        do {
            _ = try HelperLocator.cttyExec(environment: [HelperLocator.cttyExecOverride: "/nonexistent/ctty-exec"])
            Issue.record("a missing ARMADALE_CTTY_EXEC fell back to another ctty-exec")
        } catch {
            #expect(error.badOverride?.variable == "ARMADALE_CTTY_EXEC")
        }
        // A directory is not an executable either.
        #expect(throws: HelperLocator.NotFound.self) {
            try HelperLocator.zmx(environment: [HelperLocator.zmxOverride: "/tmp"])
        }
        // An empty value means unset.
        #expect(try HelperLocator.zmx(environment: [HelperLocator.zmxOverride: ""]).path.hasSuffix("zmx"))
    }

    @Test func theVendoredBinaryIsThePinnedVersion() async throws {
        let result = try await CommandRunner().run(executable: try testZmx(), arguments: ["version"], environment: testEnvironment())
        #expect(result.status == 0)
        let firstLine = result.stdoutText.split(separator: "\n").first.map(String.init) ?? ""
        #expect(firstLine.hasPrefix("zmx") && firstLine.hasSuffix(ZmxVersion.current), "\(result.stdoutText)")
    }
}
