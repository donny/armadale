import ArmadaleCore
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import ArmadaleSessions

@Suite("RemoteDeployer")
struct RemoteDeployerTests {
    private let host = ArmadaleCore.Host(name: "VM", sshDestination: "vm")
    private static let payload = Data("pretend this is zmx for linux".utf8)

    /// A scripted Linux host. `installedSize` is the helper's size on the
    /// host (`nil`: absent); a successful upload installs the payload.
    private final class LinuxHost: Sendable {
        let uname: String
        let home: String
        let uploadResult: CommandResult
        let verifyResult: CommandResult
        private let installed: Mutex<Int?>

        init(
            uname: String = "Linux aarch64", home: String = "/home/me", installedSize: Int? = nil,
            upload: CommandResult = .ok(), verify: CommandResult = .ok("zmx\t\t0.8.1\nghostty_vt\tx\n")
        ) {
            self.uname = uname
            self.home = home
            self.uploadResult = upload
            self.verifyResult = verify
            installed = Mutex(installedSize)
        }

        var installedSize: Int? { installed.withLock { $0 } }

        func respond(_ command: String) -> CommandResult {
            if command.contains("cat >") {
                if uploadResult.status == 0 { installed.withLock { $0 = RemoteDeployerTests.payload.count } }
                return uploadResult
            }
            if command.contains("uname -sm; printf") { return .ok("\(uname)\n\(home)\n") }
            if command.contains("echo absent") {
                return .ok("\(uname)\n" + (installedSize.map { "   \($0)\n" } ?? "absent\n"))
            }
            if command.contains(" version || exit 4") { return verifyResult }
            if command.contains("rm -f") {
                installed.withLock { $0 = nil }
                return .ok()
            }
            return .failed(1, "unexpected command: \(command)")
        }
    }

    private func transport(_ host: LinuxHost) -> FakeTransport {
        FakeTransport { host.respond($0) }
    }

    private func deployer(_ transport: FakeTransport, host: ArmadaleCore.Host? = nil) -> RemoteDeployer {
        let url = FileManager.default.temporaryDirectory.appending(path: "armadale-payload-\(UUID().uuidString)")
        try? Self.payload.write(to: url)
        return RemoteDeployer(host: host ?? self.host, transport: transport, version: "0.8.1") { _ in url }
    }

    @Test func platformMapping() {
        #expect(RemotePlatform(uname: "Linux aarch64") == .linuxAarch64)
        #expect(RemotePlatform(uname: "Linux arm64") == .linuxAarch64)
        #expect(RemotePlatform(uname: "Linux x86_64") == .linuxX86_64)
        #expect(RemotePlatform(uname: "Darwin arm64") == .macosAarch64)
        #expect(RemotePlatform(uname: "Darwin x86_64") == .macosX86_64)
        #expect(RemotePlatform(uname: "Linux armv7l") == nil)
        #expect(RemotePlatform(uname: "FreeBSD amd64") == nil)
        #expect(RemotePlatform(uname: "MINGW64_NT-10.0 x86_64") == nil)
        #expect(RemotePlatform(uname: "") == nil)
    }

    @Test func anInstalledHelperOfTheRightSizeIsOnlyChecked() async throws {
        let linux = LinuxHost(installedSize: Self.payload.count)
        let fake = transport(linux)
        let deployment = try await deployer(fake).ensureDeployed()
        #expect(!deployment.uploaded)
        #expect(deployment.platform == .linuxAarch64)
        #expect(fake.commands == [RemoteShell.sh(RemoteDeployer.presenceCheck("~/.armadale/bin/zmx-0.8.1"))])
        #expect(fake.commands[0].contains("wc -c <"))
    }

    /// A truncated or otherwise different copy on the host is replaced on
    /// the next connection, not used.
    @Test func anInstalledHelperOfTheWrongSizeIsRedeployed() async throws {
        let linux = LinuxHost(installedSize: 3_000_000)
        let fake = transport(linux)
        #expect(try await deployer(fake).ensureDeployed().uploaded)
        #expect(linux.installedSize == Self.payload.count)
    }

    @Test func aMissingHelperIsUploadedCheckedAndVerified() async throws {
        let linux = LinuxHost()
        let fake = transport(linux)
        let deployer = deployer(fake)
        let deployment = try await deployer.ensureDeployed()
        #expect(deployment.uploaded)
        #expect(deployment.hashVerified)
        #expect(deployment.platform == .linuxAarch64)

        let calls = fake.recorded
        #expect(calls.count == 4, "check, uname, upload, verify: \(calls.map(\.command))")
        // The upload carries the bundled binary and checks size and hash of
        // the temporary file before renaming it into place.
        let expected = RemoteShell.uploadScript(
            to: "~/.armadale/bin/zmx-0.8.1", mode: 0o755, size: Self.payload.count, sha256: RemoteShell.sha256Hex(Self.payload))
        #expect(calls[2].command == RemoteShell.sh(expected))
        #expect(calls[2].input == Self.payload)
        #expect(expected.contains("-eq \(Self.payload.count) ]"))
        #expect(expected.contains(RemoteShell.sha256Hex(Self.payload)))
        // The verification runs it, and never changes an existing folder's
        // permissions.
        #expect(calls[3].command.contains("\"$HOME\"/.armadale/bin/zmx-0.8.1 version"))
        #expect(calls[3].command.contains("umask 077; mkdir -p \"$HOME\"/.armadale/run"))
        #expect(!calls.contains { $0.command.contains("chmod 700") })

        #expect(try await deployer.ensureDeployed().uploaded == false)
    }

    @Test func aShortUploadInstallsNothing() async throws {
        for status in [RemoteShell.uploadSizeMismatchStatus, RemoteShell.uploadHashMismatchStatus] {
            let linux = LinuxHost(upload: .failed(status, ""))
            let fake = transport(linux)
            await #expect(throws: BackendError.runtimeFailure(
                "Armadale’s persistence helper was damaged on its way to VM, so it was not installed. Try again.")) {
                _ = try await deployer(fake).ensureDeployed()
            }
            #expect(linux.installedSize == nil)
            #expect(!fake.commands.contains { $0.contains(" version || exit 4") }, "not run")
        }
    }

    @Test func aHostWithoutAHashToolIsCheckedBySizeOnly() async throws {
        let linux = LinuxHost(upload: .ok(RemoteShell.noHashToolMarker + "\n"))
        let deployment = try await deployer(transport(linux)).ensureDeployed()
        #expect(deployment.uploaded)
        #expect(!deployment.hashVerified)
    }

    @Test func aHelperThatDoesNotRunIsRemovedAndNotPersistent() async throws {
        let linux = LinuxHost(verify: .failed(4, "/home/me/.armadale/bin/zmx-0.8.1: cannot execute binary file"))
        let fake = transport(linux)
        do {
            _ = try await deployer(fake).ensureDeployed()
            Issue.record("expected notPersistent")
        } catch BackendError.notPersistent(let reason?) {
            #expect(!reason.contains(".armadale/bin"), "the helper's path stays out of the message")
        }
        #expect(linux.installedSize == nil)
    }

    @Test func anUnsupportedPlatformIsNotPersistent() async throws {
        let fake = transport(LinuxHost(uname: "FreeBSD amd64"))
        do {
            _ = try await deployer(fake).ensureDeployed()
            Issue.record("expected notPersistent")
        } catch BackendError.notPersistent(let reason?) {
            #expect(reason.contains("FreeBSD amd64"))
            #expect(!reason.lowercased().contains("zmx"), "the runtime is never named")
        }
        #expect(!fake.recorded.contains { $0.input != nil }, "nothing uploaded")
    }

    @Test func aHostWithoutAPOSIXShellIsNotPersistent() async throws {
        // Windows' OpenSSH runs commands with cmd.exe.
        let fake = FakeTransport { _ in .failed(1, "'exec' is not recognized as an internal or external command") }
        await #expect(throws: BackendError.self) { _ = try await deployer(fake).ensureDeployed() }
    }

    @Test func aHomeThatCannotBeWrittenIsNotPersistent() async throws {
        let fake = transport(LinuxHost(upload: .failed(1, "mkdir: cannot create directory: Read-only file system")))
        do {
            _ = try await deployer(fake).ensureDeployed()
            Issue.record("expected notPersistent")
        } catch BackendError.notPersistent(let reason?) {
            #expect(reason.contains("Read-only file system"))
        }
    }

    @Test func aHomeTooLongForSocketsIsNotPersistent() async throws {
        let fake = transport(LinuxHost(home: "/home/" + String(repeating: "x", count: 80)))
        await #expect(throws: BackendError.self) { _ = try await deployer(fake).ensureDeployed() }
        #expect(!fake.recorded.contains { $0.input != nil })
    }

    /// Defence in depth: a remote folder that is not Armadale's own (from a
    /// hand-edited state file) is never written to.
    @Test func anUnconfinedRemoteFolderIsRefused() async throws {
        for directory in ["~", "/", "/opt"] {
            let fake = transport(LinuxHost())
            var unconfined = host
            unconfined.remoteDirectory = directory
            await #expect(throws: BackendError.self) { _ = try await deployer(fake, host: unconfined).ensureDeployed() }
            #expect(!fake.recorded.contains { $0.input != nil }, "\(directory)")
        }
    }

    @Test func sshFailuresAreThrownAsSuch() async throws {
        let down = FakeTransport { _ in .refused }
        await #expect(throws: SSHFailure.unreachable("ssh: connect to host test.invalid port 22: Connection refused")) {
            _ = try await deployer(down).ensureDeployed()
        }
        let locked = FakeTransport { _ in .failed(255, "vm: Permission denied (publickey).") }
        await #expect(throws: SSHFailure.needsInteraction("vm: Permission denied (publickey).")) {
            _ = try await deployer(locked).ensureDeployed()
        }
        let changed = FakeTransport { _ in
            .failed(255, "@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n@@@@\nHost key verification failed.\n")
        }
        await #expect(throws: SSHFailure.refused("Host key verification failed.")) {
            _ = try await deployer(changed).ensureDeployed()
        }
    }

    @Test func concurrentChecksShareOneDeploy() async throws {
        let fake = transport(LinuxHost())
        let deployer = deployer(fake)
        async let first = deployer.ensureDeployed()
        async let second = deployer.ensureDeployed()
        _ = try await (first, second)
        #expect(fake.recorded.filter { $0.input != nil }.count == 1, "uploaded once")
    }

    @Test func probeReportsThePlatformAndWhetherTheRightHelperIsThere() async throws {
        let absent = try await deployer(FakeTransport { _ in .ok("Linux x86_64\nabsent\n") }).probe()
        #expect(absent.uname == "Linux x86_64")
        #expect(absent.platform == .linuxX86_64)
        #expect(!absent.isDeployed)
        let present = try await deployer(FakeTransport { _ in .ok("Linux x86_64\n\(Self.payload.count)\n") }).probe()
        #expect(present.isDeployed)
        let truncated = try await deployer(FakeTransport { _ in .ok("Linux x86_64\n12\n") }).probe()
        #expect(!truncated.isDeployed)
    }
}
