import Foundation
import Synchronization
import Testing
@testable import ArmadaleSessions

/// Drains a process's output on a background task and lets tests wait for it.
final class OutputCollector: Sendable {
    private struct State {
        var bytes: [UInt8] = []
        var batchSizes: [Int] = []
        var isFinished = false
    }

    private final class Box: Sendable {
        let state = Mutex(State())
    }

    private let box = Box()
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<[UInt8]>) {
        let box = box
        task = Task.detached {
            for await batch in stream {
                box.state.withLock {
                    $0.bytes += batch
                    $0.batchSizes.append(batch.count)
                }
            }
            box.state.withLock { $0.isFinished = true }
        }
    }

    var bytes: [UInt8] { box.state.withLock { $0.bytes } }
    var batchSizes: [Int] { box.state.withLock { $0.batchSizes } }
    var isFinished: Bool { box.state.withLock { $0.isFinished } }
    /// Output as text with carriage returns removed.
    var text: String { String(decoding: bytes.filter { $0 != 13 }, as: UTF8.self) }

    /// Waits until `predicate` holds for the text so far.
    @discardableResult
    func wait(
        timeout: Duration = .seconds(10),
        sourceLocation: SourceLocation = #_sourceLocation,
        until predicate: (String) -> Bool
    ) async -> String {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            let text = text
            if predicate(text) { return text }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out; output so far: \(text.debugDescription)", sourceLocation: sourceLocation)
        return text
    }

    /// Waits until the stream finishes.
    @discardableResult
    func waitForEnd(timeout: Duration = .seconds(20), sourceLocation: SourceLocation = #_sourceLocation) async -> String {
        await task.value
        return text
    }
}

/// A clean environment for spawned test programs, independent of the
/// developer's shell configuration.
func testEnvironment(_ extra: [String: String] = [:]) -> [String: String] {
    var environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": NSHomeDirectory(),
        "TERM": "xterm-256color",
        "LANG": "en_US.UTF-8",
    ]
    environment.merge(extra) { _, new in new }
    return environment
}

/// Number of open file descriptors in this process.
func openFileDescriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
}

/// An `EphemeralBackend` whose login zsh reads an empty `ZDOTDIR`, so the
/// developer's dotfiles stay out of tests.
func cleanEphemeralBackend() throws -> EphemeralBackend {
    let dotDirectory = FileManager.default.temporaryDirectory.appending(path: "armadale-zdotdir-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dotDirectory, withIntermediateDirectories: true)
    return EphemeralBackend(resolver: LaunchResolver(context: LaunchResolver.Context(
        environment: testEnvironment(["ZDOTDIR": dotDirectory.path]),
        loginShell: "/bin/zsh",
        appVersion: "test",
        locale: Locale(identifier: "en_US"),
        homeDirectory: NSHomeDirectory(),
        directoryExists: { FileManager.default.fileExists(atPath: $0) })))
}
