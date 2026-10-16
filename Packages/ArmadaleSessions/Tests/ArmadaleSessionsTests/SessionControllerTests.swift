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
        var hungUp = false
        var footprint: UInt64?
    }

    let output: AsyncStream<[UInt8]>
    let runtimeVersion: String?
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let exitLatch = Latch<Int32?>()
    private let record = Mutex(Record())

    init(runtimeVersion: String? = nil) {
        self.runtimeVersion = runtimeVersion
        (output, continuation) = AsyncStream.makeStream(of: [UInt8].self)
    }

    var writes: [[UInt8]] { record.withLock { $0.writes } }
    var resizes: [PTYSize] { record.withLock { $0.resizes } }
    var terminated: Bool { record.withLock { $0.terminated } }
    var hungUp: Bool { record.withLock { $0.hungUp } }
    func setFootprint(_ value: UInt64?) { record.withLock { $0.footprint = value } }
    var clientFootprint: UInt64? { record.withLock { $0.footprint } }
    func hangUp() {
        record.withLock { $0.hungUp = true }
        exitLatch.set(nil)
        continuation.finish()
    }

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
    private(set) var attached: [Session] = []
    private(set) var resolved: [SessionID] = []
    var createError: (any Error)?
    /// Thrown by attach (when attaching is possible at all).
    var attachError: (any Error)?
    /// Answers to resolveExit, in order; `.ended` once used up.
    var resolutions: [ExitResolution] = []
    /// Whether attach succeeds (a persistent backend) or throws noSuchSession.
    var canAttach = false
    /// The runtime version handles report.
    var runtimeVersion: String?
    /// Sessions `exists` reports as alive.
    var alive: Set<SessionID> = []
    var createDelay: Duration?
    var killDelay: Duration?

    func setCreateError(_ error: (any Error)?) { createError = error }
    func setCreateDelay(_ delay: Duration?) { createDelay = delay }
    func setKillDelay(_ delay: Duration?) { killDelay = delay }
    func setResolutions(_ list: [ExitResolution]) { resolutions = list }
    func setCanAttach(_ value: Bool) { canAttach = value }
    func setAttachError(_ error: (any Error)?) { attachError = error }
    func setRuntimeVersion(_ value: String?) { runtimeVersion = value }
    func setAlive(_ ids: Set<SessionID>) { alive = ids }

    func create(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        if let createDelay { try await Task.sleep(for: createDelay) }
        if let createError { throw createError }
        let handle = FakeHandle(runtimeVersion: runtimeVersion)
        handles.append(handle)
        created.append((session, size))
        return handle
    }

    func attach(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        guard canAttach else { throw BackendError.notPersistent }
        if let attachError { throw attachError }
        attached.append(session)
        let handle = FakeHandle(runtimeVersion: runtimeVersion)
        handles.append(handle)
        created.append((session, size))
        return handle
    }

    func resolveExit(of session: Session) async -> ExitResolution {
        resolved.append(session.id)
        return resolutions.isEmpty ? .ended : resolutions.removeFirst()
    }

    func exists(_ id: SessionID) async throws -> Bool { alive.contains(id) }
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
    var versions: [String] = []
    var directories: [String] = []
    var replacements: [(SessionID, Session)] = []

    func sessionController(_ controller: SessionController, didChangeState state: SessionState) { states.append(state) }
    func sessionController(_ controller: SessionController, didSetTitle title: String) { titles.append(title) }
    func sessionController(_ controller: SessionController, didChangeDirectory path: String) { directories.append(path) }
    func sessionController(_ controller: SessionController, didReplace old: SessionID, with new: Session) {
        replacements.append((old, new))
    }
    func sessionController(_ controller: SessionController, didRecordRuntimeVersion version: String) {
        versions.append(version)
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
        // The old session is killed even though it looked ended: a session
        // shown as ended or disconnected may still be alive, and killing a
        // gone one is harmless.
        #expect(await backend.killed == [session.id])

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
        // Once by close() (not found yet: the create is still running) and
        // once more when the late create completes.
        await eventuallyAsync { await backend.killed == [id, id] }
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

    // MARK: Exit resolution

    /// Ends the current (index) handle's process with its output.
    private func endClient(_ index: Int) async throws {
        let handle = try await handle(index)
        handle.finishOutput()
        handle.exit(0)
    }

    @Test func endedResolutionEndsWithoutReattaching() async throws {
        await backend.setCanAttach(true)
        let controller = makeController()
        await controller.start(.create)
        try await endClient(0)
        await eventually { controller.state.isEnded }
        #expect(await backend.resolved == [session.id])
        #expect(await backend.attached.isEmpty)
    }

    @Test func detachedResolutionReattachesOnceThenDisconnects() async throws {
        await backend.setCanAttach(true)
        await backend.setResolutions([.detached, .detached])
        let controller = makeController()
        await controller.start(.create)
        surface.fed = Array("old screen".utf8)

        // The client dies but the session lives: one automatic reattach,
        // starting from a reset surface.
        try await endClient(0)
        await eventuallyAsync { await backend.attached.count == 1 }
        await eventually { controller.state == .attached }
        #expect(await backend.attached.first?.id == session.id)
        #expect(surface.text.hasSuffix("\u{1b}c"), "the surface is reset before the replay")
        #expect(surface.scrollbackClears == 1)
        let reattached = try await handle(1)
        reattached.emit("replayed")
        await eventually { surface.text.hasSuffix("replayed") }
        // Input goes to the new client.
        surface.delegate?.surface(surface, didInput: [0x61])
        #expect(reattached.writes == [[0x61]])

        // It dies again at once (two hangups within the allowance): no
        // second automatic reattach, and since the backend says the session
        // is still alive it is disconnected, never ended.
        try await endClient(1)
        await eventually { controller.state.isDisconnected }
        #expect(await backend.attached.count == 1)
        #expect(await backend.resolved == [session.id, session.id])
        #expect(delegate.states == [
            .attaching, .attached, .attaching, .attached,
            .disconnected(reason: "The connection to the session was lost."),
        ])
        #expect(await backend.killed.isEmpty, "a disconnected session is left running")

        // Reconnect attaches again.
        await controller.reconnect()
        #expect(controller.state == .attached)
        #expect(await backend.attached.count == 2)

        // Respawn from a disconnected session kills the live daemon first.
        await controller.respawn()
        #expect(await backend.killed == [session.id])
        #expect(controller.session.id != session.id)
    }

    @Test func aFailedReattachEnds() async throws {
        await backend.setResolutions([.detached])
        let controller = makeController() // canAttach false: attach throws
        await controller.start(.create)
        try await endClient(0)
        await eventually { controller.state.isEnded }
        #expect(controller.state == .ended(exitCode: nil))
        #expect(controller.failure == nil)
    }

    @Test func noSuchSessionIsNotAFailure() async {
        await backend.setCreateError(BackendError.noSuchSession(session.id))
        let controller = makeController()
        await controller.start(.create)
        #expect(controller.state == .ended(exitCode: nil))
        #expect(controller.failure == nil)
    }

    @Test func createRecordsTheRuntimeVersion() async throws {
        await backend.setRuntimeVersion("9.9.9")
        let controller = makeController()
        await controller.start(.create)
        #expect(controller.session.runtimeVersion == "9.9.9")
        #expect(delegate.versions == ["9.9.9"])
    }

    @Test func attachDoesNotRecordAVersionAndResetsTheSurface() async throws {
        await backend.setCanAttach(true)
        await backend.setRuntimeVersion("9.9.9")
        let controller = makeController()
        await controller.start(.attach)
        #expect(controller.state == .attached)
        #expect(delegate.versions.isEmpty)
        #expect(surface.text == "\u{1b}c")
        #expect(surface.scrollbackClears == 1)
    }

    @Test func markEndedAndDetach() async throws {
        let ended = makeController()
        ended.markEnded()
        #expect(ended.state == .ended(exitCode: nil))
        #expect(await backend.created.isEmpty)

        let controller = makeController()
        await controller.start(.create)
        let handle = try await handle()
        await controller.detach()
        #expect(controller.state == .detached)
        #expect(handle.terminated)
        #expect(await backend.killed.isEmpty, "detaching never ends the session")
        #expect(await backend.resolved.isEmpty)
    }

    @Test func closingAnUnattachedSessionKillsItInTheBackend() async {
        let controller = makeController()
        await controller.close()
        #expect(await backend.killed == [session.id])
    }

    /// Orphan guard: a session that looks ended is still killed on close
    /// and on respawn (it may only look ended).
    @Test func closeAndRespawnAfterEndedStillKill() async throws {
        let closing = makeController()
        await closing.start(.create)
        try await endClient(0)
        await eventually { closing.state.isEnded }
        await closing.close()
        #expect(await backend.killed == [session.id])

        let respawning = makeController()
        respawning.markEnded()
        await respawning.respawn()
        #expect(await backend.killed == [session.id, session.id])
    }

    @Test func aReattachThatCannotAttachDisconnects() async throws {
        await backend.setCanAttach(true)
        await backend.setResolutions([.detached])
        await backend.setAttachError(BackendError.runtimeFailure("Could not establish the session."))
        await backend.setAlive([session.id])
        let controller = makeController()
        await controller.start(.create)
        try await endClient(0)
        await eventually { controller.state.isDisconnected }
        #expect(controller.state == .disconnected(reason: "Could not establish the session."))
        #expect(await backend.killed.isEmpty)
        // Attaching at launch fails the same way.
        let restored = makeController()
        await restored.start(.attach)
        #expect(restored.state.isDisconnected)
    }

    /// A create that fails while the session is (or may be) running is
    /// disconnected, not ended; only a confirmed-gone one is ended.
    @Test func aFailedCreateOfALiveSessionDisconnects() async {
        await backend.setCreateError(BackendError.runtimeFailure("The session did not start within 5 seconds."))
        await backend.setAlive([session.id])
        let alive = makeController()
        await alive.start(.create)
        #expect(alive.state == .disconnected(reason: "The session did not start within 5 seconds."))
        #expect(await backend.killed.isEmpty)

        await backend.setAlive([])
        let gone = makeController()
        await gone.start(.create)
        #expect(gone.state == .ended(exitCode: nil))
        #expect(gone.failure == "The session did not start within 5 seconds.")
    }

    @Test func unavailableSessionsAreNeverStartedRespawnedOrKilled() async throws {
        let controller = makeController()
        controller.markUnavailable(reason: "no runtime")
        #expect(controller.state == .unavailable(reason: "no runtime"))
        await controller.start(.attach)
        await controller.respawn()
        #expect(controller.state.isUnavailable)
        #expect(await backend.created.isEmpty)
        #expect(delegate.replacements.isEmpty)
        // Once a working backend is there, it can be attached.
        let working = FakeBackend()
        await working.setCanAttach(true)
        controller.useBackend(working, makeOutputFilter: { IdentityOutputFilter() })
        #expect(controller.state == .detached)
        await controller.start(.attach)
        #expect(controller.state == .attached)
        #expect(await working.attached.map(\.id) == [session.id])

        // Closing an unavailable one does not kill it.
        let other = makeController()
        other.markUnavailable(reason: "no runtime")
        await other.close()
        #expect(await backend.killed.isEmpty)
    }

    @Test func detachNowHangsUpWithoutEndingTheSession() async throws {
        let controller = makeController()
        await controller.start(.create)
        let handle = try await handle()
        controller.detachNow()
        #expect(handle.hungUp, "synchronously")
        #expect(controller.state == .detached)
        #expect(await backend.killed.isEmpty)
        #expect(await backend.resolved.isEmpty)
    }

    /// A client whose footprint stays above the limit (two samples in a
    /// row) is dropped and reattached; a small one is left alone, and
    /// nothing is sampled during the grace period after an attach.
    @Test func aClientWithALargeBacklogIsReattached() async throws {
        await backend.setCanAttach(true)
        let controller = makeController()
        controller.attachGracePeriod = .milliseconds(150)
        controller.footprintSampleInterval = .milliseconds(20)
        await controller.start(.create)
        let first = try await handle(0)
        // A fresh client: about 2.4 MB in practice.
        first.setFootprint(3 * 1024 * 1024)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await backend.attached.isEmpty)
        // A large backlog: reattached from a reset surface.
        first.setFootprint(48 * 1024 * 1024)
        await eventuallyAsync { await backend.attached.count == 1 }
        await eventually { controller.state == .attached }
        #expect(first.hungUp)
        #expect(controller.floodReattaches == 1)
        #expect(await backend.killed.isEmpty)
        // The new client is not sampled during its grace period.
        let second = try await handle(1)
        second.setFootprint(48 * 1024 * 1024)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await backend.attached.count == 1)
        await eventuallyAsync { await backend.attached.count == 2 }
    }

    /// One sample over the limit is not enough: it takes two in a row.
    @Test func aSingleLargeSampleIsIgnored() async throws {
        await backend.setCanAttach(true)
        let controller = makeController()
        controller.attachGracePeriod = .zero
        controller.footprintSampleInterval = .milliseconds(100)
        await controller.start(.create)
        let first = try await handle(0)
        first.setFootprint(48 * 1024 * 1024)
        try await Task.sleep(for: .milliseconds(30)) // one sample taken at ~0 ms
        first.setFootprint(3 * 1024 * 1024)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await backend.attached.isEmpty)
        #expect(controller.floodReattaches == 0)
    }

    /// Ephemeral sessions keep real backpressure (the child blocks), so their
    /// plain PTY handles report no footprint and are never reattached,
    /// however far behind the consumer is.
    @Test func plainPTYHandlesReportNoFootprint() async throws {
        let process = try PTYProcess.spawn(
            program: "/usr/bin/yes", environment: testEnvironment(), size: PTYSize(columns: 80, rows: 24))
        try await Task.sleep(for: .milliseconds(300)) // nobody reads: far behind
        #expect((process as any ProcessHandle).clientFootprint == nil)
        await process.terminate()
    }

}

/// Launch housekeeping: live sessions that no saved session refers to.
@Suite("OrphanReclaimer")
struct OrphanReclaimerTests {
    let referenced = SessionID.generate()
    let orphan = SessionID.generate()

    @Test func killsUnreferencedLiveSessionsWhenStateLoadedCleanly() async {
        let backend = FakeBackend()
        let killed = await OrphanReclaimer.reclaim(
            live: [referenced, orphan], referenced: [referenced, SessionID.generate()],
            stateLoadedCleanly: true, backend: backend)
        #expect(killed == [orphan])
        #expect(await backend.killed == [orphan])
    }

    @Test func killsNothingWhenTheStateDidNotLoadCleanly() async {
        let backend = FakeBackend()
        let killed = await OrphanReclaimer.reclaim(
            live: [referenced, orphan], referenced: [referenced], stateLoadedCleanly: false, backend: backend)
        #expect(killed.isEmpty)
        #expect(await backend.killed.isEmpty)
    }

    @Test func nothingToDo() async {
        let backend = FakeBackend()
        #expect(await OrphanReclaimer.reclaim(
            live: [referenced], referenced: [referenced], stateLoadedCleanly: true, backend: backend).isEmpty)
        #expect(OrphanReclaimer.orphans(live: [], referenced: [referenced]).isEmpty)
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
