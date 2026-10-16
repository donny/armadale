import ArmadaleCore
import Foundation
import Testing
@testable import ArmadaleSessions

/// A trivial in-memory handle proving the protocol is implementable under strict concurrency.
private final class EchoHandle: ProcessHandle {
    let output: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation

    init() {
        (output, continuation) = AsyncStream.makeStream(of: [UInt8].self)
    }

    func write(_ bytes: [UInt8]) async { continuation.yield(bytes) }
    func resize(_ size: PTYSize) async {}
    func terminate() async { continuation.finish() }
    var exitStatus: Int32? { get async { 0 } }
}

@Suite("ArmadaleSessions")
struct SessionStateTests {
    @Test func stateQueries() {
        #expect(SessionState.attached.isAttached)
        #expect(!SessionState.detached.isAttached)
        #expect(SessionState.ended(exitCode: 1).isEnded)
        #expect(!SessionState.disconnected(reason: "timeout").isEnded)
        #expect(SessionState.ended(exitCode: nil) != .ended(exitCode: 0))
    }

    @Test func handleEchoesAndFinishes() async {
        let handle = EchoHandle()
        await handle.write(Array("hi".utf8))
        await handle.terminate()
        var received: [UInt8] = []
        for await chunk in handle.output { received += chunk }
        #expect(received == Array("hi".utf8))
        #expect(await handle.exitStatus == 0)
    }
}
