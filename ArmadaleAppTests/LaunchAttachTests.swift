import AppKit
import ArmadaleCore
import ArmadaleSessions
import Foundation
import Synchronization
import SwiftTermSurface
import TerminalSurface
import Testing

/// A client that never starts a process: output is fed by the test, and it
/// runs until the test ends it, it is hung up or the session is killed.
final class TestHandle: ProcessHandle {
    private struct State {
        var resizes: [PTYSize] = []
        var writes: [[UInt8]] = []
        var exited = false
    }

    let output: AsyncStream<[UInt8]>
    let runtimeVersion: String? = ZmxVersion.current
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let state = Mutex(State())
    private let exitStream: AsyncStream<Int32?>
    private let exitContinuation: AsyncStream<Int32?>.Continuation

    init() {
        (output, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        (exitStream, exitContinuation) = AsyncStream.makeStream(of: Int32?.self)
    }

    var resizes: [PTYSize] { state.withLock { $0.resizes } }
    func emit(_ bytes: [UInt8]) { continuation.yield(bytes) }
    func write(_ bytes: [UInt8]) { state.withLock { $0.writes.append(bytes) } }
    func resize(_ size: PTYSize) { state.withLock { $0.resizes.append(size) } }
    /// The client exits: its output ends.
    func end() {
        let first = state.withLock { state -> Bool in
            defer { state.exited = true }
            return !state.exited
        }
        guard first else { return }
        continuation.finish()
        exitContinuation.yield(nil)
        exitContinuation.finish()
    }
    func terminate() async { end() }
    func hangUp() { end() }
    var exitStatus: Int32? {
        get async {
            for await code in exitStream { return code }
            return nil
        }
    }
    var isRunning: Bool { !state.withLock { $0.exited } }
}

/// A local persistence backend for the launch tests: `alive` is what it
/// lists and what exists; attaches to an alive session return a
/// ``TestHandle`` (after `attachDelay`), others throw `noSuchSession`;
/// sessions in `failOnce` fail their first attach with a runtime failure,
/// which leaves them disconnected (they exist). Records attach sizes, how
/// many attaches overlapped, and kills.
actor LaunchTestBackend: PersistenceBackend {
    var alive: Set<SessionID>
    var recorded: [SessionID: ProgramExit] = [:]
    var attachDelay: Duration = .zero
    var failOnce: Set<SessionID> = []
    var listingDelay: Duration = .zero
    func setListingDelay(_ delay: Duration) { listingDelay = delay }
    /// Alive, but left out of the listing (a stopped daemon does not
    /// answer it; its socket is there).
    var unlisted: Set<SessionID> = []
    private(set) var attachSizes: [SessionID: [PTYSize]] = [:]
    private(set) var handles: [SessionID: TestHandle] = [:]
    private(set) var killed: [SessionID] = []
    private(set) var listings = 0
    private var concurrent = 0
    private(set) var maxConcurrent = 0

    init(alive: Set<SessionID>, recorded: [SessionID: ProgramExit] = [:]) {
        self.alive = alive
        self.recorded = recorded
    }

    func setAttachDelay(_ delay: Duration) { attachDelay = delay }
    func setFailOnce(_ ids: Set<SessionID>) { failOnce = ids }
    func setAlive(_ ids: Set<SessionID>) { alive = ids }
    func setUnlisted(_ ids: Set<SessionID>) { unlisted = ids }
    func handle(_ id: SessionID) -> TestHandle? { handles[id] }

    func create(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        let handle = TestHandle()
        handles[session.id] = handle
        alive.insert(session.id)
        attachSizes[session.id, default: []].append(size)
        return handle
    }

    func attach(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        concurrent += 1
        maxConcurrent = max(maxConcurrent, concurrent)
        defer { concurrent -= 1 }
        attachSizes[session.id, default: []].append(size)
        if attachDelay > .zero { try await Task.sleep(for: attachDelay) }
        guard alive.contains(session.id) else { throw BackendError.noSuchSession(session.id) }
        if failOnce.remove(session.id) != nil {
            throw BackendError.runtimeFailure("Could not establish the session.")
        }
        let handle = TestHandle()
        handles[session.id] = handle
        return handle
    }

    func exists(_ id: SessionID) async throws -> Bool { alive.contains(id) }
    func liveSessions() async throws -> Set<SessionID> {
        listings += 1
        if listingDelay > .zero { try await Task.sleep(for: listingDelay) }
        return alive.subtracting(unlisted)
    }
    func kill(_ id: SessionID) async throws {
        killed.append(id)
        alive.remove(id)
        handles[id]?.end()
    }
    func history(_ id: SessionID) async throws -> Data { throw BackendError.historyUnavailable(id) }
    func resolveExit(of session: Session) async -> ExitResolution {
        alive.contains(session.id) ? .detached : .ended(exitStatus: recorded[session.id])
    }
    func recordedExitStatuses(of ids: Set<SessionID>) async -> [SessionID: ProgramExit] {
        recorded.filter { ids.contains($0.key) }
    }
}

/// Restore at launch through the registry (docs/DESIGN.md section 4,
/// "Restore at launch"): restored local sessions whose panes are never
/// shown are attached at their saved size once the listing has answered,
/// left alone without one, ended when gone; paced; and the safety rules of
/// closing and ending them. No process is started and no window is shown.
@Suite("Launch attach of restored sessions")
@MainActor
struct LaunchAttachTests {
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    struct Fixture {
        let model: AppModel
        let registry: SessionRegistry
        let backend: LaunchTestBackend
        let settings: AppSettings
        /// The sessions, in sidebar order: the first is the selected tab's.
        let sessions: [SessionID]
        @MainActor func cleanUp() { settings.removeTestDefaults() }
    }

    /// `count` tabs of one workspace, each a restored persistent shell,
    /// `sized` of them (from the first) with a saved grid of 101×33, `alive`
    /// in the backend (by default all). `unlisted` are alive but left out
    /// of the listing, with a socket in the runtime directory (a stopped
    /// daemon).
    private func makeFixture(
        count: Int, sized: Int? = nil, alive: ((Int) -> Bool)? = nil, unlisted: Set<Int> = [],
        persistent: Bool = true, recorded: [Int: ProgramExit] = [:], attention: Bool = false,
        attachDelay: Duration = .zero, failOnce: Set<Int> = [], listingDelay: Duration = .zero, startPass: Bool = true,
        surfaces: SurfaceRegistry = .standard
    ) async -> Fixture {
        _ = NSApplication.shared
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let group = model.workspace(workspace)!.tabGroups[0].id
        for _ in 1..<count { _ = model.newTab(in: group) }
        model.fillEmptyPanes()
        let sessions = model.sessionOrder
        for id in sessions { model.setRuntimeVersion(ZmxVersion.current, for: id) }
        var sizes: [SessionID: SessionGridSize] = [:]
        for id in sessions.prefix(sized ?? count) { sizes[id] = SessionGridSize(columns: 101, rows: 33) }
        model.setGridSizes(sizes)
        let isAlive = alive ?? { _ in true }
        let live = Set(sessions.enumerated().filter { isAlive($0.offset) }.map(\.element))
        let backend = LaunchTestBackend(
            alive: live, recorded: Dictionary(uniqueKeysWithValues: recorded.map { (sessions[$0.key], $0.value) }))
        let socketIDs = Set(unlisted.map { sessions[$0] })
        await backend.setUnlisted(socketIDs)
        await backend.setAttachDelay(attachDelay)
        await backend.setListingDelay(listingDelay)
        await backend.setFailOnce(Set(failOnce.map { sessions[$0] }))
        let settings = AppSettings.forTesting(surfaces: surfaces)
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: backend, makeOutputFilter: { IdentityOutputFilter() },
                isPersistent: persistent, socketSessions: { socketIDs }),
            restoredSessionIDs: Set(sessions), settings: settings)
        if startPass { registry.startLaunchPass() }
        if attention {
            registry.attention = AttentionCenter(
                model: model, preferences: settings.preferences, notifications: FakeNotificationService())
        }
        return Fixture(model: model, registry: registry, backend: backend, settings: settings, sessions: sessions)
    }

    // MARK: Attached at the saved size

    @Test func aRestoredAliveSessionNeverShownIsAttachedAtItsSavedSize() async throws {
        let f = await makeFixture(count: 2)
        defer { f.cleanUp() }
        let hidden = f.sessions[1]
        let controller = try #require(f.registry.controller(for: hidden))
        #expect(f.registry.status(of: hidden) == .pending, "before the listing answers")
        #expect(await eventually { controller.state == .attached })
        let sizes = await f.backend.attachSizes[hidden] ?? []
        #expect(sizes.map { "\($0.columns)x\($0.rows)" } == ["101x33"], "attached once, at the saved size")
        #expect(controller.surface.gridSize.columns == 101 && controller.surface.gridSize.rows == 33)
        let handle = try #require(await f.backend.handle(hidden))
        #expect(handle.resizes.isEmpty, "no resize at the attach")
        #expect(f.registry.status(of: hidden) == .running)
        #expect(f.registry.paneViews.view(for: hidden) == nil, "no pane view: never shown")
    }

    /// Its bell and its OSC 777 reach the attention center although its
    /// pane was never shown, and its status follows its end, with the
    /// running count.
    @Test func aHiddenAttachedSessionRaisesAttentionAndItsStatusFollowsItsEnd() async throws {
        let f = await makeFixture(count: 2, attention: true)
        defer { f.cleanUp() }
        let hidden = f.sessions[1]
        let attention = try #require(f.registry.attention)
        let controller = try #require(f.registry.controller(for: hidden))
        #expect(await eventually { controller.state == .attached })
        #expect(f.registry.runningSessionCount() == 2)
        let handle = try #require(await f.backend.handle(hidden))
        handle.emit([0x07])
        #expect(await eventually { attention.needsAttention(hidden) }, "the bell")
        #expect(f.registry.glyphStatus(of: hidden) == .attention)
        attention.clearAll()
        handle.emit(Array("\u{1b}]777;notify;Claude Code;Finished\u{07}".utf8))
        #expect(await eventually { attention.needsAttention(hidden) }, "OSC 777")

        // The program ends while nobody looks: the status follows.
        await f.backend.setAlive([f.sessions[0]])
        handle.end()
        #expect(await eventually { f.registry.status(of: hidden) == .ended })
        #expect(f.registry.runningSessionCount() == 1)
    }

    // MARK: Left, ended, socket-only, unavailable

    /// No saved size (an older build's file): left unattached until shown,
    /// running by the listing; shown, it attaches at its laid-out size.
    @Test func withoutASavedSizeItWaitsUntilShown() async throws {
        let f = await makeFixture(count: 2, sized: 0)
        defer { f.cleanUp() }
        let hidden = f.sessions[1]
        #expect(await eventually { f.registry.status(of: hidden) == .running })
        try await Task.sleep(for: .milliseconds(150))
        #expect(await f.backend.attachSizes[hidden] == nil, "no program is resized on a guess")
        #expect(f.registry.controller(for: hidden)?.state == .detached)
        #expect(f.registry.runningSessionCount() == 2)

        let pane = try #require(f.registry.paneView(for: hidden))
        f.registry.startIfNeeded(hidden)
        #expect(await eventually { pane.controller.state == .attached })
        let sizes = await f.backend.attachSizes[hidden] ?? []
        #expect(sizes.count == 1)
        #expect(Int(sizes[0].columns) == pane.controller.surface.gridSize.columns)
    }

    /// Gone: ended through its controller with its recorded status; a clean
    /// exit closes its pane, any other end keeps the placeholder.
    @Test func goneSessionsAreEndedWithTheirRecordedStatus() async throws {
        let f = await makeFixture(count: 3, alive: { $0 == 0 }, recorded: [1: .exited(0), 2: .signaled(9)])
        defer { f.cleanUp() }
        let (clean, killed) = (f.sessions[1], f.sessions[2])
        #expect(await eventually { f.model.session(clean) == nil }, "a clean exit closes its pane")
        #expect(await eventually { f.registry.status(of: killed) == .ended })
        #expect(f.registry.controller(for: killed)?.state == .ended(exitCode: .signaled(9)))
        #expect(await f.backend.attachSizes[killed] == nil, "nothing was attached")
        #expect(f.registry.controller(for: killed)?.hasSurface == false, "an ended session costs no terminal")
    }

    /// A daemon the listing left out (stopped: it does not answer) but whose
    /// socket exists is alive: attached, never Session Ended.
    @Test func aSessionWithOnlyASocketIsAliveNotEnded() async throws {
        let f = await makeFixture(count: 3, sized: 2, unlisted: [1, 2])
        defer { f.cleanUp() }
        let (sized, unsized) = (f.sessions[1], f.sessions[2])
        let controller = try #require(f.registry.controller(for: sized))
        #expect(await eventually { controller.state == .attached }, "attached at its saved size, not ended")
        #expect(await f.backend.attachSizes[sized]?.map { "\($0.columns)x\($0.rows)" } == ["101x33"])
        #expect(f.registry.status(of: unsized) == .running, "left, alive by its socket")
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.registry.controller(for: unsized)?.state == .detached)
        #expect(!f.registry.hasEndedSessions(in: try #require(f.model.workspaces.first?.id)))
    }

    /// The persistent runtime could not be set up: restored persistent
    /// sessions are unavailable from the start, never attached or killed;
    /// Retry brings them up as at launch.
    @Test func unavailableFromTheStartAndRetried() async throws {
        let f = await makeFixture(count: 3, sized: 2, persistent: false)
        defer { f.cleanUp() }
        for id in f.sessions {
            #expect(f.registry.controller(for: id)?.state == .unavailable(reason: SessionRegistry.unavailableReason))
            #expect(f.registry.status(of: id) == .unavailable)
        }
        #expect(f.registry.closeRisk(of: [f.sessions[2]]).unreachable)
        // Shown: the first; the second is sized and hidden; the third has no size.
        let shown = try #require(f.registry.paneView(for: f.sessions[0]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(shown)
        let backend = f.backend
        f.registry.setUpPersistentRuntime = {
            SessionRuntimeSetup(backend: backend, makeOutputFilter: { IdentityOutputFilter() }, isPersistent: true)
        }
        f.registry.retryPersistence()
        #expect(f.registry.sessionsSurviveQuit)
        #expect(await eventually { shown.controller.state == .attached }, "the shown pane at once")
        let hidden = try #require(f.registry.controller(for: f.sessions[1]))
        #expect(await eventually { hidden.state == .attached }, "the hidden one through the launch pass")
        #expect(await f.backend.attachSizes[f.sessions[1]]?.map { "\($0.columns)x\($0.rows)" } == ["101x33"])
        #expect(f.registry.controller(for: f.sessions[2])?.state == .detached, "no size: left until shown")
        #expect(f.registry.status(of: f.sessions[2]) == .running)
    }

    @Test func anUnavailableSessionIsNeverKilled() async throws {
        let f = await makeFixture(count: 2, persistent: false)
        defer { f.cleanUp() }
        var retired: [SessionID] = []
        f.registry.onSessionRetired = { retired.append($0) }
        f.registry.close(f.sessions[1])
        _ = await f.registry.endAllSessions()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await f.backend.killed.isEmpty)
        #expect(retired.isEmpty)
    }

    // MARK: Pacing

    @Test func atMostFourLocalAttachesAreInFlight() async throws {
        let f = await makeFixture(count: 12, sized: 12, attachDelay: .milliseconds(60))
        defer { f.cleanUp() }
        #expect(await eventually {
            f.sessions.allSatisfy { f.registry.controller(for: $0)?.state == .attached }
        })
        #expect(await f.backend.maxConcurrent <= 4)
        #expect(await f.backend.maxConcurrent >= 2, "they do overlap")
        // In sidebar order.
        #expect(f.registry.launchQueue.isIdle)
    }

    /// A pane shown while its session waits in the queue jumps it, at its
    /// laid-out size.
    @Test func aShownPaneJumpsTheQueue() async throws {
        let f = await makeFixture(count: 10, sized: 10, attachDelay: .milliseconds(300))
        defer { f.cleanUp() }
        let last = try #require(f.sessions.last)
        #expect(await eventually { f.registry.launchQueue.isQueued(last) })
        let pane = try #require(f.registry.paneView(for: last))
        pane.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        f.registry.startIfNeeded(last)
        #expect(!f.registry.launchQueue.isQueued(last))
        #expect(await eventually { pane.controller.state == .attached })
        let size = try #require(await f.backend.attachSizes[last]?.first)
        #expect(Int(size.columns) == pane.controller.surface.gridSize.columns)
        #expect(size.columns != 101, "its laid-out size, not the saved one")
    }

    /// A local launch attach that ends Disconnected although its session
    /// exists is tried once more after the queue has drained.
    @Test func aMissedAttachIsRetriedOnceAfterTheQueueDrains() async throws {
        let f = await makeFixture(count: 6, sized: 6, failOnce: [2])
        defer { f.cleanUp() }
        let controller = try #require(f.registry.controller(for: f.sessions[2]))
        #expect(await eventually { controller.state == .attached })
        #expect(await f.backend.attachSizes[f.sessions[2]]?.count == 2, "one failure, one retry")
        #expect(f.registry.launchQueue.isIdle)
    }

    // MARK: Closing and ending

    /// A restored session that may be alive is killed when its pane is
    /// closed, attached or not.
    @Test func closingAnUnattachedRestoredSessionKillsIt() async throws {
        let f = await makeFixture(count: 2, sized: 0)
        defer { f.cleanUp() }
        let hidden = f.sessions[1]
        #expect(await eventually { f.registry.status(of: hidden) == .running })
        #expect(f.registry.closeRisk(of: [hidden]).mayBeRunning, "asks")
        var retired: [SessionID] = []
        f.registry.onSessionRetired = { retired.append($0) }
        f.registry.close(hidden)
        #expect(await eventually { await f.backend.killed == [hidden] })
        #expect(await eventually { retired == [hidden] })
        #expect(f.registry.controller(for: hidden) == nil)
    }

    /// End Sessions and Quit ends every session that may be alive, attached
    /// or left, and then counts none running.
    @Test func endSessionsEndsAttachedAndLeftSessions() async throws {
        let f = await makeFixture(count: 4, sized: 2)
        defer { f.cleanUp() }
        #expect(await eventually {
            f.registry.controller(for: f.sessions[0])?.state == .attached
                && f.registry.controller(for: f.sessions[1])?.state == .attached
                && f.registry.status(of: f.sessions[3]) == .running
        })
        #expect(f.registry.runningSessionCount() == 4)
        let ended = await f.registry.endAllSessions()
        #expect(Set(f.sessions).isSubset(of: ended))
        #expect(Set(await f.backend.killed) == Set(f.sessions))
        #expect(f.registry.sessionsStillRunning().isEmpty)
        #expect(f.registry.runningSessionCount() == 0)
    }

    /// Respawn All Ended respawns sessions ended at launch whose panes were
    /// never shown.
    @Test func respawnAllEndedCoversSessionsNeverShown() async throws {
        let f = await makeFixture(count: 3, alive: { $0 == 0 })
        defer { f.cleanUp() }
        let workspace = try #require(f.model.workspaces.first?.id)
        #expect(await eventually { f.registry.hasEndedSessions(in: workspace) })
        f.registry.respawnAllEnded(in: workspace)
        #expect(await eventually { !f.registry.hasEndedSessions(in: workspace) })
        #expect(await eventually { f.model.sessions.count == 3 && Set(f.model.sessionOrder).intersection(f.sessions) == [f.sessions[0]] })
        // The fresh sessions take over the panes' sizes, and are created at
        // them: their panes were never shown.
        for id in f.model.sessionOrder.dropFirst() {
            #expect(f.model.session(id)?.gridSize == SessionGridSize(columns: 101, rows: 33))
            #expect(await f.backend.attachSizes[id]?.map { "\($0.columns)x\($0.rows)" } == ["101x33"])
        }
    }

    // MARK: Grid sizes

    /// A size is recorded once it has settled, all together in one model
    /// change, and written at once at quit.
    @Test func sizesAreRecordedWhenSettledAndFlushedAtQuit() async throws {
        let f = await makeFixture(count: 2, sized: 2)
        defer { f.cleanUp() }
        f.registry.gridSizes.settleInterval = .milliseconds(150)
        let controllers = try f.sessions.map { try #require(f.registry.controller(for: $0)) }
        #expect(await eventually { controllers.allSatisfy { $0.state == .attached } })
        let before = f.model.changeCount
        // A live resize: several steps on both panes.
        for columns in [90, 91, 92, 93] {
            for controller in controllers { controller.surface.setGridSize(columns: columns, rows: 30) }
        }
        #expect(f.model.session(f.sessions[0])?.gridSize == SessionGridSize(columns: 101, rows: 33), "not yet")
        #expect(f.model.changeCount == before, "no model change per step")
        #expect(await eventually { f.model.session(f.sessions[0])?.gridSize == SessionGridSize(columns: 93, rows: 30) })
        #expect(f.model.session(f.sessions[1])?.gridSize == SessionGridSize(columns: 93, rows: 30))
        #expect(f.model.changeCount == before + 1, "one change for both")

        // At quit the pending size is written before the clients go.
        f.registry.gridSizes.settleInterval = .seconds(60)
        controllers[0].surface.setGridSize(columns: 80, rows: 24)
        f.registry.detachAllNow()
        #expect(f.model.session(f.sessions[0])?.gridSize == SessionGridSize(columns: 80, rows: 24))
        #expect(controllers[0].state == .detached)
    }

    /// An attach at the saved size records nothing new.
    @Test func anAttachAtTheSavedSizeChangesNothing() async throws {
        let f = await makeFixture(count: 2, sized: 2)
        defer { f.cleanUp() }
        let before = f.model.changeCount
        #expect(await eventually { f.registry.controller(for: f.sessions[1])?.state == .attached })
        try await Task.sleep(for: .milliseconds(700))
        #expect(f.model.changeCount == before)
        #expect(f.registry.gridSizes.pendingSizes.isEmpty)
    }
    // MARK: Review fixes

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// The terminal's frame a pane view must have.
    private func expectTerminalPlaced(_ pane: PaneView, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(pane.controller.surface.view.frame == PaneCardStyle.terminalFrame(in: pane.bounds), sourceLocation: sourceLocation)
    }

    /// Respawn All Ended after the tab was visited: the pane view exists
    /// (not on screen); the fresh session is created at that pane's grid,
    /// which the saved size never overrides.
    @Test func aRespawnOfAVisitedTabUsesItsPanesGrid() async throws {
        let f = await makeFixture(count: 2, alive: { $0 == 0 })
        defer { f.cleanUp() }
        let gone = f.sessions[1]
        let window = window()
        defer { window.close() }
        let pane = try #require(f.registry.paneView(for: gone))
        pane.frame = NSRect(x: 0, y: 0, width: 700, height: 420)
        window.contentView?.addSubview(pane)
        pane.removeFromSuperview() // its tab is switched away
        let grid = pane.controller.surface.gridSize
        #expect(grid.columns != 101)
        let workspace = try #require(f.model.workspaces.first?.id)
        #expect(await eventually { f.registry.hasEndedSessions(in: workspace) })
        f.registry.respawnAllEnded(in: workspace)
        #expect(await eventually { pane.controller.state == .attached })
        let fresh = pane.controller.session.id
        #expect(await f.backend.attachSizes[fresh]?.map { "\($0.columns)x\($0.rows)" } == ["\(grid.columns)x\(grid.rows)"])
        expectTerminalPlaced(pane)
    }

    /// Retry on an unavailable pane shown earlier (its tab not on screen
    /// now): the launch pass attaches it at its pane's grid.
    @Test func aRetryAttachesAPaneShownEarlierAtItsPanesGrid() async throws {
        let f = await makeFixture(count: 2, sized: 2, persistent: false)
        defer { f.cleanUp() }
        let earlier = f.sessions[1]
        let pane = try #require(f.registry.paneView(for: earlier))
        pane.frame = NSRect(x: 0, y: 0, width: 700, height: 420)
        let grid = pane.controller.surface.gridSize
        let backend = f.backend
        f.registry.setUpPersistentRuntime = {
            SessionRuntimeSetup(backend: backend, makeOutputFilter: { IdentityOutputFilter() }, isPersistent: true)
        }
        f.registry.retryPersistence()
        #expect(await eventually { pane.controller.state == .attached })
        #expect(await f.backend.attachSizes[earlier]?.map { "\($0.columns)x\($0.rows)" } == ["\(grid.columns)x\(grid.rows)"])
        expectTerminalPlaced(pane)
    }

    /// The guard: a terminal resized from outside inside an unchanged card
    /// is put back when the pane is laid out or enters a window.
    @Test func aPanePutsItsTerminalBack() async throws {
        let f = await makeFixture(count: 1, sized: 0)
        defer { f.cleanUp() }
        let window = window()
        defer { window.close() }
        let pane = try #require(f.registry.paneView(for: f.sessions[0]))
        pane.frame = NSRect(x: 0, y: 0, width: 700, height: 420)
        window.contentView?.addSubview(pane)
        pane.controller.surface.setGridSize(columns: 40, rows: 10)
        pane.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        expectTerminalPlaced(pane)
        pane.removeFromSuperview()
        pane.controller.surface.setGridSize(columns: 40, rows: 10)
        window.contentView?.addSubview(pane)
        expectTerminalPlaced(pane)
    }

    /// A pane shown several times while its start waits for the listing
    /// starts once, counts once, and still gets its retry.
    @Test func repeatedShowsStartOnce() async throws {
        let f = await makeFixture(count: 2, sized: 0, failOnce: [0], listingDelay: .milliseconds(200))
        defer { f.cleanUp() }
        let id = f.sessions[0]
        _ = f.registry.paneView(for: id)
        for _ in 0..<3 { f.registry.startIfNeeded(id) }
        #expect(f.registry.launchQueue.inFlight[id] == .local)
        #expect(f.registry.startsInProgress == [id])
        let controller = try #require(f.registry.controller(for: id))
        #expect(await eventually { controller.state == .attached }, "missed once, retried once")
        #expect(await f.backend.attachSizes[id]?.count == 2)
        #expect(f.registry.launchQueue.retried == [id])
    }

    /// The pass waits for the app: a listing that answers first starts
    /// nothing until ``SessionRegistry/startLaunchPass()``.
    @Test func thePassWaitsForTheApp() async throws {
        let f = await makeFixture(count: 2, sized: 2, startPass: false)
        defer { f.cleanUp() }
        _ = await f.registry.liveProbe.value
        try await Task.sleep(for: .milliseconds(150))
        #expect(await f.backend.attachSizes.isEmpty)
        f.registry.startLaunchPass()
        #expect(await eventually { f.sessions.allSatisfy { f.registry.controller(for: $0)?.state == .attached } })
    }

    /// The launch pass's own socket liveness: a session the listing leaves
    /// out but whose socket remains (a stopped daemon) is attached at launch,
    /// not marked ended, and when its client goes away the registry's
    /// controller reattaches it rather than ending it. (The backend's own
    /// rule, `LocalZmxBackend.exists`, is the scripted fake's here; it is
    /// tested against the real helper in `LocalZmxBackendTests`.)
    @Test func aSessionTheListingLeavesOutIsAttachedByItsSocket() async throws {
        let f = await makeFixture(count: 2, sized: 2, unlisted: [1])
        defer { f.cleanUp() }
        let id = f.sessions[1]
        let controller = try #require(f.registry.controller(for: id))
        #expect(await eventually { controller.state == .attached })
        let first = try #require(await f.backend.handle(id))
        first.end()
        #expect(await eventually { await f.backend.handle(id) !== first }, "reattached once")
        #expect(!controller.state.isEnded)
        #expect(f.model.session(id) != nil)
    }

    /// The clean-exit rule on an end with no recorded status (what a helper
    /// client gives): the placeholder stays.
    @Test func anEndWithNoRecordKeepsThePane() async throws {
        let f = await makeFixture(count: 2, sized: 2)
        defer { f.cleanUp() }
        let id = f.sessions[1]
        let controller = try #require(f.registry.controller(for: id))
        #expect(await eventually { controller.state == .attached })
        await f.backend.setAlive([f.sessions[0]])
        await f.backend.handle(id)?.end()
        #expect(await eventually { controller.state == .ended(exitCode: nil) })
        #expect(f.model.session(id) != nil, "no longer running: not closed")
    }

    /// A renderer change reaches a hidden attached session (its surface is
    /// replaced at its next connect, at its old grid); a pane view made
    /// meanwhile knows both renderers, and choosing the old one again
    /// cancels the replacement.
    @Test func aRendererChangeReachesAHiddenSurface() async throws {
        let surfaces = SurfaceRegistry(
            default: SwiftTermSurface.factory,
            others: [SurfaceFactory(id: "stub", displayName: "Stub") { StubRendererSurface(appearance: $0) }])
        let f = await makeFixture(count: 2, sized: 2, surfaces: surfaces)
        defer { f.cleanUp() }
        let id = f.sessions[1]
        let controller = try #require(f.registry.controller(for: id))
        #expect(await eventually { controller.state == .attached })
        f.settings.preferences.rendererID = "stub"
        #expect(await eventually { controller.hasPendingSurfaceReplacement })
        let pane = try #require(f.registry.paneView(for: id))
        #expect(pane.rendererID == "swiftterm" && pane.pendingRendererID == "stub")
        f.settings.preferences.rendererID = "swiftterm"
        #expect(await eventually { !controller.hasPendingSurfaceReplacement }, "cancelled")
        #expect(pane.pendingRendererID == nil)
    }

    /// Without a pane view, the replacement takes the old surface's grid.
    @Test func aHiddenReplacementKeepsTheGrid() async throws {
        let surfaces = SurfaceRegistry(
            default: SwiftTermSurface.factory,
            others: [SurfaceFactory(id: "stub", displayName: "Stub") { StubRendererSurface(appearance: $0) }])
        let f = await makeFixture(count: 2, sized: 2, surfaces: surfaces)
        defer { f.cleanUp() }
        let id = f.sessions[1]
        let controller = try #require(f.registry.controller(for: id))
        #expect(await eventually { controller.state == .attached })
        f.settings.preferences.rendererID = "stub"
        #expect(await eventually { controller.hasPendingSurfaceReplacement })
        // The connection drops; the reattach installs the new surface.
        await f.backend.handle(id)?.end()
        #expect(await eventually { controller.surface is StubRendererSurface && controller.state == .attached })
        let sizes = await f.backend.attachSizes[id] ?? []
        #expect(sizes.map { "\($0.columns)x\($0.rows)" } == ["101x33", "101x33"])
        #expect(f.registry.surfaceRenderers[id]?.current == "stub")
    }
}
