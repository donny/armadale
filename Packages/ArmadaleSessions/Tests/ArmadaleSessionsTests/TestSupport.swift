import AppKit
import ArmadaleCore
import Foundation
import Synchronization
import TerminalSurface
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

    /// Waits until the stream finishes, at most `timeout` (then records an
    /// issue and returns what arrived so far).
    @discardableResult
    func waitForEnd(timeout: Duration = .seconds(20), sourceLocation: SourceLocation = #_sourceLocation) async -> String {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !isFinished, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !isFinished {
            Issue.record("Output did not end within \(timeout); so far: \(text.suffix(300).debugDescription)",
                         sourceLocation: sourceLocation)
        }
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

// MARK: zmx

/// zmx is not available to the tests.
struct ZmxUnavailable: Error, CustomStringConvertible {
    let reason: String
    var description: String {
        "The zmx binary for tests is missing (\(reason)). Run scripts/fetch-zmx.sh from the repository root "
            + "to download the pinned release into Vendor/zmx, or set ARMADALE_ZMX to a zmx binary."
    }
}

/// The repository root (this file is Packages/ArmadaleSessions/Tests/ArmadaleSessionsTests/TestSupport.swift).
let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// The zmx binary the tests run: `$ARMADALE_ZMX`, or the vendored one,
/// fetched with scripts/fetch-zmx.sh first if it is missing. Fails (rather
/// than skipping) with instructions when neither works.
func testZmx() throws -> String {
    if let url = try? HelperLocator.zmx() { return url.path }
    let fetch = Process()
    fetch.executableURL = URL(fileURLWithPath: "/bin/bash")
    fetch.arguments = [repositoryRoot.appending(path: "scripts/fetch-zmx.sh").path]
    fetch.standardOutput = FileHandle.nullDevice
    fetch.standardError = FileHandle.nullDevice
    do {
        try fetch.run()
        fetch.waitUntilExit()
    } catch {
        throw ZmxUnavailable(reason: "scripts/fetch-zmx.sh could not run: \(error)")
    }
    do {
        return try HelperLocator.zmx().path
    } catch {
        throw ZmxUnavailable(reason: "scripts/fetch-zmx.sh exited with \(fetch.terminationStatus); \(error)")
    }
}

/// A private zmx runtime for one test: its own short runtime directory
/// (`/tmp/armadale-test-<pid>-<random>`, short enough for socket paths),
/// a login zsh with test dotfiles, and a ``LocalZmxBackend`` over them.
///
/// Tests kill what they create; ``tearDown()`` (run from the owning suite's
/// `deinit`) is the safety net: it kills every session left in the
/// directory with the real zmx and removes the directory.
final class ZmxSandbox: Sendable {
    let directory: String
    let runtime: ZmxRuntime
    let zmx: String
    let backend: LocalZmxBackend
    let environment: [String: String]

    /// The prompt the test shell prints.
    static let prompt = "armadale-test% "

    init(extraEnvironment: [String: String] = [:]) throws {
        zmx = try testZmx()
        let random = String(UInt32.random(in: 0...UInt32.max), radix: 36)
        directory = "/tmp/armadale-test-\(getpid())-\(random)"
        let zdotdir = directory + "-zdot"
        try FileManager.default.createDirectory(atPath: zdotdir, withIntermediateDirectories: true)
        // A fixed prompt, after macOS's /etc/zshrc set its own.
        try "PS1='armadale-test%# '\nunsetopt PROMPT_SP\n".write(
            toFile: zdotdir + "/.zshrc", atomically: true, encoding: .utf8)
        runtime = ZmxRuntime(directory: directory)
        try runtime.prepare()
        environment = testEnvironment(["ZDOTDIR": zdotdir, "SHELL": "/bin/zsh"].merging(extraEnvironment) { $1 })
        let resolver = LaunchResolver(context: LaunchResolver.Context(
            environment: environment,
            loginShell: "/bin/zsh",
            appVersion: "test",
            locale: Locale(identifier: "en_US"),
            homeDirectory: NSHomeDirectory(),
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }))
        backend = LocalZmxBackend(configuration: LocalZmxBackend.Configuration(
            runtime: runtime,
            executables: ZmxExecutables(path: zmx),
            cttyExec: try HelperLocator.cttyExec(environment: [:]).path,
            resolver: resolver))
    }

    func session(_ launch: LaunchSpec = LaunchSpec(), directory: String = "/usr/share") -> Session {
        Session(profileID: Profile.shell.id, launch: launch, workingDirectory: directory)
    }

    /// Runs this sandbox's zmx synchronously (for teardown and assertions).
    @discardableResult
    func zmxSync(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmx)
        process.arguments = arguments
        process.environment = runtime.environment(base: testEnvironment())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Names `zmx ls --short` lists in this sandbox.
    var listedNames: [String] {
        zmxSync(["ls", "--short"]).output.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Kills every session in the sandbox and removes its directories.
    func tearDown() {
        for name in listedNames {
            zmxSync(["kill", name])
        }
        for path in [directory, directory + "-zdot"] where path.hasPrefix("/tmp/armadale-test-") {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(
    timeout: Duration = .seconds(10),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async throws -> Bool
) async rethrows -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return try await condition()
}

/// A surface that records what it is fed.
@MainActor
final class RecordingSurface: TerminalSurface {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    weak var delegate: (any TerminalSurfaceDelegate)?
    var gridSize = GridSize(columns: 100, rows: 30, cellWidth: 7, cellHeight: 14)
    var fed: [UInt8] = []
    var scrollbackClears = 0
    /// Makes every feed this slow, like a renderer that cannot keep up.
    var feedDelay: TimeInterval = 0
    var text: String { String(decoding: fed, as: UTF8.self) }
    /// What was fed since the last full reset (RIS).
    var textSinceReset: String {
        let ris = Array("\u{1b}c".utf8)
        var start = 0
        if fed.count >= 2 {
            for index in stride(from: fed.count - 2, through: 0, by: -1) where fed[index] == ris[0] && fed[index + 1] == ris[1] {
                start = index + 2
                break
            }
        }
        return String(decoding: fed[start...], as: UTF8.self)
    }

    func feed(_ bytes: ArraySlice<UInt8>) {
        fed += bytes
        if feedDelay > 0 { Thread.sleep(forTimeInterval: feedDelay) }
    }
    func apply(_ appearance: TerminalAppearance) {}
    func clearScrollback() { scrollbackClears += 1 }
    func scrollToBottom() {}
    func find(_ query: String, direction: FindDirection) {}
    var selectedText: String? { nil }
}
