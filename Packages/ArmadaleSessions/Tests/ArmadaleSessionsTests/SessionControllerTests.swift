import AppKit
import ArmadaleCore
import Foundation
import Synchronization
import TerminalSurface
import Testing
@testable import ArmadaleSessions

// MARK: Fakes

@MainActor
private final class FakeSurface: TerminalSurface {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    weak var delegate: (any TerminalSurfaceDelegate)?
    var gridSize = GridSize(columns: 100, rows: 30, cellWidth: 7, cellHeight: 14)
    var fed: [UInt8] = []
    var scrollbackClears = 0
    var text: String { String(decoding: fed, as: UTF8.self) }

    func feed(_ bytes: ArraySlice<UInt8>) { fed += bytes }
    func apply(_ appearance: TerminalAppearance) {}
    func clearScrollback() { scrollbackClears += 1 }
    func scrollToBottom() {}
    func find(_ query: String, direction: FindDirection) {}
    var selectedText: String? { nil }
}

private final class FakeHandle: ProcessHandle {
    struct Record {
        var writes: [[UInt8]] = []
        var resizes: [PTYSize] = []
        var terminated = false
    }

    let output: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let exitLatch = Latch<Int32?>()
    private let record = Mutex(Record())

    init() {
        (output, continuation) = AsyncStream.makeStream(of: [UInt8].self)
    }

    var writes: [[UInt8]] { record.withLock { $0.writes } }
    var resizes: [PTYSize] { record.withLock { $0.resizes } }
    var terminated: Bool { record.withLock { $0.terminated } }

    func emit(_ text: String) { continuation.yield(Array(text.utf8)) }
    func finishOutput() { continuation.finish() }
    func exit(_ code: Int32?) { exitLatch.set(code) }

    func write(_ bytes: [UInt8]) { record.withLock { $0.writes.append(bytes) } }
    func resize(_ size: PTYSize) { record.withLock { $0.resizes.append(size) } }
    func terminate() async {
        record.withLock { $0.terminated = true }
        exitLatch.set(nil)
        continuation.finish()
    }
    var exitStatus: Int32? { get async { await exitLatch.wait() ?? nil } }
    var isRunning: Bool { exitLatch.value == nil }
}

private actor FakeBackend: PersistenceBackend {
    private(set) var handles: [FakeHandle] = []
    private(set) var created: [(session: Session, size: PTYSize)] = []
    private(set) var killed: [SessionID] = []
    var createError: (any Error)?
    var createDelay: Duration?
    var killDelay: Duration?

    func setCreateError(_ error: (any Error)?) { createError = error }
    func setCreateDelay(_ delay: Duration?) { createDelay = delay }
    func setKillDelay(_ delay: Duration?) { killDelay = delay }

    func create(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        if let createDelay { try await Task.sleep(for: createDelay) }
        if let createError { throw createError }
        let handle = FakeHandle()
        handles.append(handle)
        created.append((session, size))
        return handle
    }

    func attach(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        throw BackendError.notPersistent
    }

    func exists(_ id: SessionID) async throws -> Bool { false }
    func liveSessions() async throws -> Set<SessionID> { [] }
    func kill(_ id: SessionID) async throws {
        if let killDelay { try await Task.sleep(for: killDelay) }
        killed.append(id)
        // Like a real backend: killing a session ends its process.
        for (index, entry) in created.enumerated() where entry.session.id == id {
            await handles[index].terminate()
        }
    }
    func history(_ id: SessionID) async throws -> Data { throw BackendError.historyUnavailable(id) }
}

@MainActor
private final class RecordingDelegate: SessionControllerDelegate {
    var states: [SessionState] = []
    var titles: [String] = []
    var directories: [String] = []
    var replacements: [(SessionID, Session)] = []

    func sessionController(_ controller: SessionController, didChangeState state: SessionState) { states.append(state) }
    func sessionController(_ controller: SessionController, didSetTitle title: String) { titles.append(title) }
    func sessionController(_ controller: SessionController, didChangeDirectory path: String) { directories.append(path) }
    func sessionController(_ controller: SessionController, didReplace old: SessionID, with new: Session) {
        replacements.append((old, new))
    }
}

/// Holds back everything until the end of the stream.
private struct HoldingFilter: OutputFilter {
    var held: [UInt8] = []
    mutating func filter(_ bytes: [UInt8]) -> [UInt8] {
        held += bytes
        return []
    }
    mutating func finish() -> [UInt8] {
        defer { held = [] }
        return held
    }
}

/// Drops `X` and appends `!` at end of stream.
private struct DroppingFilter: OutputFilter {
    func filter(_ bytes: [UInt8]) -> [UInt8] { bytes.filter { $0 != UInt8(ascii: "X") } }
    func finish() -> [UInt8] { Array("!".utf8) }
}

// MARK: Tests

@Suite("SessionController")
@MainActor
struct SessionControllerTests {
    private let backend = FakeBackend()
    private let surface = FakeSurface()
    private let delegate = RecordingDelegate()
    private let session = Session(
        profileID: Profile.shell.id, launch: LaunchSpec(program: "claude", arguments: ["-c"]), workingDirectory: "/work")

    private func makeController(filter: (@MainActor () -> any OutputFilter)? = nil) -> SessionController {
        let surface = surface
        let controller = SessionController(
            session: session, backend: backend, makeSurface: { surface },
            makeOutputFilter: filter ?? { IdentityOutputFilter() })
        controller.delegate = delegate
        return controller
    }

    private func eventually(
        _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    private func handle(_ index: Int = 0) async throws -> FakeHandle {
        let handles = await backend.handles
        return try #require(handles.count > index ? handles[index] : nil)
    }

    @Test func startCreatesWithSurfaceSizeAndPumpsOutput() async throws {
        let controller = makeController()
        #expect(surface.delegate === controller)
        await controller.start(.create)
        #expect(controller.state == .attached)
        #expect(controller.isRunning)
        let created = try #require(await backend.created.first)
        #expect(created.session.id == session.id)
        #expect(created.size.columns == 100 && created.size.rows == 30)
        #expect(created.size.pixelWidth > 0 && created.size.pixelHeight > 0)

        let handle = try await handle()
        handle.emit("hello ")
        handle.emit("world")
        await eventually { surface.text == "hello world" }
    }

    @Test func inputAndResizeReachTheProcess() async throws {
        let controller = makeController()
        await controller.start(.create)
        let handle = try await handle()
        surface.delegate?.surface(surface, didInput: [0x61, 0x03])
        #expect(handle.writes == [[0x61, 0x03]])
        surface.gridSize = GridSize(columns: 120, rows: 40, cellWidth: 7, cellHeight: 14)
        surface.delegate?.surface(surface, didResize: surface.gridSize)
        #expect(handle.resizes.last?.columns == 120)
        #expect(handle.resizes.last?.rows == 40)
        _ = controller
    }

    @Test func titleAndDirectoryAreRecordedAndReported() async throws {
        let controller = makeController()
        await controller.start(.create)
        surface.delegate?.surface(surface, didSetTitle: "vim notes.md")
        surface.delegate?.surface(surface, didChangeDirectory: URL(fileURLWithPath: "/tmp/some dir", isDirectory: true))
        #expect(controller.session.title == "vim notes.md")
        #expect(controller.session.workingDirectory == "/tmp/some dir/")
        #expect(delegate.titles == ["vim notes.md"])
        #expect(delegate.directories == ["/tmp/some dir/"])
    }

    @Test func exitEndsTheSessionAfterOutputDrains() async throws {
        let controller = makeController()
        await controller.start(.create)
        let handle = try await handle()
        handle.emit("bye\r\n")
        handle.finishOutput()
        handle.exit(3)
        await eventually { controller.state == .ended(exitCode: 3) }
        #expect(surface.text == "bye\r\n")
        #expect(delegate.states == [.attaching, .attached, .ended(exitCode: 3)])
        #expect(!controller.isRunning)
        // Input after the end goes nowhere.
        surface.delegate?.surface(surface, didInput: [0x61])
        #expect(handle.writes.isEmpty)
    }

    @Test func exitEndsTheSessionEvenIfOutputStaysOpen() async throws {
        let controller = makeController()
        controller.drainTimeout = .milliseconds(20)
        await controller.start(.create)
        try await handle().exit(0)
        await eventually { controller.state == .ended(exitCode: 0) }
    }

    @Test func attachToAGoneSessionEnds() async {
        let controller = makeController()
        await controller.start(.attach)
        #expect(controller.state == .ended(exitCode: nil))
        #expect(controller.failure == nil)
        #expect(delegate.states == [.attaching, .ended(exitCode: nil)])
    }

    @Test func createFailureIsReported() async {
        await backend.setCreateError(SpawnError(call: "posix_spawn", code: ENOENT))
        let controller = makeController()
        await controller.start(.create)
        #expect(controller.state == .ended(exitCode: nil))
        #expect(controller.failure?.contains("posix_spawn") == true)
    }

    @Test func respawnCreatesAFreshSessionAndRebinds() async throws {
        let controller = makeController()
        await controller.start(.create)
        let first = try await handle(0)
        first.finishOutput()
        first.exit(1)
        await eventually { controller.state.isEnded }

        await controller.respawn()
        let fresh = controller.session
        #expect(fresh.id != session.id)
        #expect(fresh.launch == session.launch)
        #expect(fresh.workingDirectory == session.workingDirectory)
        #expect(fresh.profileID == session.profileID)
        #expect(delegate.replacements.map(\.0) == [session.id])
        #expect(delegate.replacements.map(\.1.id) == [fresh.id])
        #expect(await backend.created.map(\.session.id) == [session.id, fresh.id])
        #expect(controller.state == .attached)
        #expect(surface.text.contains("\u{1b}c"), "the surface is reset")
        #expect(surface.scrollbackClears == 1)
        // An ended session is not killed again.
        #expect(await backend.killed.isEmpty)

        let second = try await handle(1)
        second.emit("fresh")
        await eventually { surface.text.hasSuffix("fresh") }
    }

    @Test func respawnOfARunningSessionKillsItAndIgnoresItsOutput() async throws {
        let controller = makeController()
        await controller.start(.create)
        let first = try await handle(0)
        await controller.respawn()
        #expect(await backend.killed == [session.id])
        #expect(first.terminated)
        first.emit("stale")
        let second = try await handle(1)
        second.emit("fresh")
        await eventually { surface.text.hasSuffix("fresh") }
        #expect(!surface.text.contains("stale"))
    }

    @Test func outputFilterIsApplied() async throws {
        let controller = makeController(filter: { DroppingFilter() })
        await controller.start(.create)
        let handle = try await handle()
        handle.emit("aXbX")
        handle.finishOutput()
        handle.exit(0)
        await eventually { controller.state.isEnded }
        #expect(surface.text == "ab!")
    }

    @Test func closeKillsTheSession() async throws {
        let controller = makeController()
        await controller.start(.create)
        let handle = try await handle()
        await controller.close()
        #expect(await backend.killed == [session.id])
        #expect(handle.terminated)
        #expect(controller.state.isEnded)
    }

    @Test func clearScreenSendsFormFeedToALiveProgram() async throws {
        let controller = makeController()
        await controller.start(.create)
        controller.clearScreen()
        #expect(try await handle().writes == [[0x0C]])
        #expect(surface.scrollbackClears == 1)
        #expect(surface.fed.isEmpty, "the program redraws; nothing is cleared locally")
    }

    @Test func clearScreenOfAnEndedSessionClearsLocally() async {
        let controller = makeController()
        await controller.start(.attach) // → ended
        controller.clearScreen()
        #expect(surface.text == "\u{1b}[H\u{1b}[2J")
        #expect(surface.scrollbackClears == 1)
    }

    /// Polls an async condition.
    private func eventuallyAsync(
        _ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), sourceLocation: sourceLocation)
    }

    /// Two respawns racing (a double click) replace the session once and
    /// leave exactly one process running.
    @Test func concurrentRespawnsReplaceOnceAndOrphanNothing() async throws {
        await backend.setKillDelay(.milliseconds(200))
        let controller = makeController()
        await controller.start(.create)
        let first = try await handle(0)
        async let a: Void = controller.respawn()
        async let b: Void = controller.respawn()
        _ = await (a, b)
        #expect(delegate.replacements.count == 1)
        let created = await backend.created
        #expect(created.count == 2)
        #expect(controller.session.id == created.last?.session.id)
        #expect(first.terminated)
        #expect(await backend.handles.filter(\.isRunning).count == 1)
        // A later respawn works again.
        await controller.respawn()
        #expect(delegate.replacements.count == 2)
        #expect(await backend.handles.filter(\.isRunning).count == 1)
    }

    /// close() overtaking an in-flight create: the late session is killed in
    /// the backend, not just its client process.
    @Test func closeDuringCreateKillsTheLateSession() async throws {
        await backend.setCreateDelay(.milliseconds(150))
        let controller = makeController()
        let starting = Task { await controller.start(.create) }
        try await Task.sleep(for: .milliseconds(30))
        await controller.close()
        await starting.value
        let id = session.id
        await eventuallyAsync { await backend.killed == [id] }
        #expect(try await handle().terminated)
        #expect(controller.state == .ended(exitCode: nil))
        // A closed controller never connects again.
        await controller.respawn()
        #expect(await backend.created.count == 1)
    }

    /// respawn() overtaking an in-flight create: the superseded session is killed.
    @Test func respawnDuringCreateKillsTheSupersededSession() async throws {
        await backend.setCreateDelay(.milliseconds(100))
        let controller = makeController()
        let starting = Task { await controller.start(.create) }
        try await Task.sleep(for: .milliseconds(20))
        await controller.respawn()
        await starting.value
        let old = session.id
        await eventuallyAsync { await backend.killed.contains(old) }
        #expect(controller.state == .attached)
        #expect(controller.session.id != old)
        await eventuallyAsync { await backend.handles.filter(\.isRunning).count == 1 }
    }

    /// Bytes a filter held back are flushed even when the session ends by
    /// the drain timeout rather than end of stream.
    @Test func filterIsFinishedWhenTheDrainTimesOut() async throws {
        let controller = makeController(filter: { HoldingFilter() })
        controller.drainTimeout = .milliseconds(20)
        await controller.start(.create)
        let handle = try await handle()
        handle.emit("held")
        try await Task.sleep(for: .milliseconds(30))
        #expect(surface.fed.isEmpty)
        handle.exit(0) // output never finishes
        await eventually { controller.state == .ended(exitCode: 0) }
        #expect(surface.text == "held")
    }
}

/// End to end through a real login zsh on a real PTY.
@Suite("SessionController with a real PTY")
@MainActor
struct SessionControllerPTYTests {
    @Test func shellOutputReachesTheSurfaceAndTheSessionEnds() async throws {
        let surface = FakeSurface()
        let delegate = RecordingDelegate()
        let session = Session(
            profileID: Profile.shell.id,
            launch: LaunchSpec(program: "echo", arguments: ["hi from zsh"]),
            workingDirectory: "/usr/share")
        let controller = SessionController(session: session, backend: try cleanEphemeralBackend(), makeSurface: { surface })
        controller.delegate = delegate
        await controller.start(.create)
        for _ in 0..<500 where !controller.state.isEnded {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(delegate.states == [.attaching, .attached, .ended(exitCode: 0)])
        #expect(surface.text.contains("hi from zsh\r\n"), "\(surface.text.debugDescription)")
    }
}
