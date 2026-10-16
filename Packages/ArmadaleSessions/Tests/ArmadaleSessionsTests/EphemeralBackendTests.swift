import ArmadaleCore
import Foundation
import Testing
@testable import ArmadaleSessions

@Suite("EphemeralBackend", .serialized)
struct EphemeralBackendTests {
    private func backend() throws -> EphemeralBackend { try cleanEphemeralBackend() }

    @Test func createRunsTheLaunchSpecThroughALoginShell() async throws {
        let backend = try backend()
        let session = Session(
            profileID: Profile.shell.id,
            launch: LaunchSpec(program: "printenv", arguments: ["ARMADALE_SESSION_ID"]),
            workingDirectory: "/usr/share")
        let handle = try await backend.create(session, size: PTYSize(columns: 80, rows: 24))
        let text = await OutputCollector(handle.output).waitForEnd()
        #expect(text.hasSuffix(session.id.raw + "\n"), "\(text)")
        #expect(await handle.exitStatus == 0)
        #expect(try await backend.exists(session.id) == false)
    }

    @Test func liveSessionsExistsAndKill() async throws {
        let backend = try backend()
        let session = Session(profileID: Profile.shell.id, launch: LaunchSpec(), workingDirectory: "/")
        let handle = try await backend.create(session, size: PTYSize(columns: 80, rows: 24))
        let output = OutputCollector(handle.output)
        #expect(try await backend.exists(session.id))
        #expect(try await backend.liveSessions() == [session.id])
        // A second create of a running session returns the same process.
        #expect(try await backend.create(session, size: PTYSize(columns: 80, rows: 24)) === handle)

        // The interactive login shell runs with a controlling terminal: ^C
        // reaches a foreground job.
        handle.write(Array("echo started; /bin/sleep 30; echo slept\r".utf8))
        // "started" followed by a newline only appears once the command runs
        // (the echoed command line has "started;").
        await output.wait { $0.contains("started\n") }
        try await Task.sleep(for: .milliseconds(100))
        handle.write([0x03])
        handle.write(Array("echo after-interrupt\r".utf8))
        await output.wait { $0.contains("after-interrupt\n") }
        // The command line is echoed; the sleep's own "slept" line must not appear.
        #expect(!output.text.split(separator: "\n").contains("slept"))

        try await backend.kill(session.id)
        #expect(!handle.isRunning)
        #expect(try await backend.exists(session.id) == false)
        #expect(try await backend.liveSessions().isEmpty)
        await output.waitForEnd()
    }

    @Test func attachIsNeverPossible() async throws {
        let backend = try backend()
        let session = Session(profileID: Profile.shell.id, launch: LaunchSpec(), workingDirectory: "/")
        await #expect(throws: BackendError.notPersistent) {
            _ = try await backend.attach(session, size: PTYSize(columns: 80, rows: 24))
        }
        await #expect(throws: BackendError.historyUnavailable(session.id)) {
            _ = try await backend.history(session.id)
        }
    }
}
