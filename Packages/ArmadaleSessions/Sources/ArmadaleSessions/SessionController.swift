import AppKit
import ArmadaleCore
import Foundation
import Observation
import TerminalSurface

/// Rewrites a session's output before it reaches the surface. One instance
/// is made per attach, so it may keep state across batches (e.g. hold back a
/// possible prefix of a sequence to strip at end of stream).
@MainActor
public protocol OutputFilter {
    /// Returns what to show of `bytes`.
    mutating func filter(_ bytes: [UInt8]) -> [UInt8]
    /// The stream ended; returns anything still held back.
    mutating func finish() -> [UInt8]
}

/// Passes output through unchanged.
public struct IdentityOutputFilter: OutputFilter {
    public init() {}
    public func filter(_ bytes: [UInt8]) -> [UInt8] { bytes }
    public func finish() -> [UInt8] { [] }
}

/// What a ``SessionController`` reports to the app, which records it in the
/// model. Every method has a default no-op implementation.
@MainActor
public protocol SessionControllerDelegate: AnyObject {
    func sessionController(_ controller: SessionController, didChangeState state: SessionState)
    /// The program set its title (OSC 0/2).
    func sessionController(_ controller: SessionController, didSetTitle title: String)
    /// The program reported its working directory (OSC 7).
    func sessionController(_ controller: SessionController, didChangeDirectory path: String)
    func sessionControllerDidRingBell(_ controller: SessionController)
    func sessionController(_ controller: SessionController, didReceiveNotification title: String, body: String)
    /// The user activated a link; `link` is untrusted program output.
    func sessionController(_ controller: SessionController, didActivateLink link: String)
    func sessionController(_ controller: SessionController, didRequestClipboard op: ClipboardOp)
    /// A respawn replaced session `old` with `new`; rebind the pane.
    func sessionController(_ controller: SessionController, didReplace old: SessionID, with new: Session)
    /// A create recorded the runtime version that made the session
    /// (`Session.runtimeVersion`); store it.
    func sessionController(_ controller: SessionController, didRecordRuntimeVersion version: String)
}

extension SessionControllerDelegate {
    public func sessionController(_ controller: SessionController, didChangeState state: SessionState) {}
    public func sessionController(_ controller: SessionController, didSetTitle title: String) {}
    public func sessionController(_ controller: SessionController, didChangeDirectory path: String) {}
    public func sessionControllerDidRingBell(_ controller: SessionController) {}
    public func sessionController(_ controller: SessionController, didReceiveNotification title: String, body: String) {}
    public func sessionController(_ controller: SessionController, didActivateLink link: String) {}
    public func sessionController(_ controller: SessionController, didRequestClipboard op: ClipboardOp) {}
    public func sessionController(_ controller: SessionController, didReplace old: SessionID, with new: Session) {}
    public func sessionController(_ controller: SessionController, didRecordRuntimeVersion version: String) {}
}

/// The per-session glue between a backend's ``ProcessHandle`` and a
/// ``TerminalSurface``: pumps output into the surface, sends input and
/// resizes to the process, runs the state machine
/// (detached → attaching → attached → ended), and reports title, directory,
/// bell and notifications to its delegate.
///
/// When the client process exits, the backend decides what that meant
/// (``PersistenceBackend/resolveExit(of:)``): the session ended, or only
/// the client went away. In the second case the controller reattaches once
/// by itself; if that fails, or the new client goes away again at once, the
/// session is shown as disconnected (it may still be running), with
/// ``reconnect()`` to try again.
///
/// The controller owns the surface for the session's whole life; views that
/// show it reparent `surface.view` and never recreate it.
@MainActor
@Observable
public final class SessionController {
    /// How ``start(_:)`` connects.
    public enum StartMode: Sendable {
        /// Create the session (attaching if it already exists).
        case create
        /// Attach only; a missing session ends up `.ended`.
        case attach
    }

    public private(set) var session: Session
    public private(set) var state: SessionState = .detached
    /// Why the last start failed, if it did (spawn errors and the like).
    public private(set) var failure: String?

    @ObservationIgnored public let surface: any TerminalSurface
    @ObservationIgnored public weak var delegate: (any SessionControllerDelegate)?

    @ObservationIgnored private var backend: any PersistenceBackend
    @ObservationIgnored private var makeOutputFilter: @MainActor () -> any OutputFilter
    @ObservationIgnored private var binding: Binding?
    /// Incremented on every (re)bind; events from older bindings are ignored.
    @ObservationIgnored private var generation = 0
    /// The output filter of the current binding; `nil` once it has been
    /// finished (each binding's filter is finished exactly once).
    @ObservationIgnored private var filter: (any OutputFilter)?
    /// A respawn is in progress; further calls are ignored until it is done.
    @ObservationIgnored private var isRespawning = false
    /// ``close()`` was called: never connect again.
    @ObservationIgnored private var isClosed = false
    /// Automatic reattaches since the last attach that lasted.
    @ObservationIgnored private var automaticReattaches = 0
    /// Reattaches made because the client's backlog grew too large.
    @ObservationIgnored public private(set) var floodReattaches = 0

    /// One attach of one process.
    private struct Binding {
        let generation: Int
        let handle: any ProcessHandle
        let attachedAt: ContinuousClock.Instant
        var outputTask: Task<Void, Never>?
        var exitTask: Task<Void, Never>?
        var floodWatchTask: Task<Void, Never>?
        var isOutputFinished = false
        /// Set once the process has exited: its exit code, if it had one.
        var exit: Int32??
        /// The backend is deciding what the client's exit meant.
        var isResolvingExit = false

        func cancelTasks() {
            outputTask?.cancel()
            exitTask?.cancel()
            floodWatchTask?.cancel()
        }
    }

    /// An attach that lasted at least this long restores the allowance of
    /// one automatic reattach.
    @ObservationIgnored var reattachAllowanceInterval: Duration = .seconds(5)

    /// How long to wait for the output stream to finish after the process
    /// exited before declaring the session ended anyway.
    @ObservationIgnored var drainTimeout: Duration = .milliseconds(500)

    /// A client whose memory footprint (``ProcessHandle/clientFootprint``)
    /// is above this on two consecutive samples (every 500 ms) is dropped and reattached:
    /// zmx's client buffers output without limit, so a footprint this large
    /// means the pane is far behind the session, and the replay, a bounded
    /// snapshot, brings it to the current state (docs/DESIGN.md section 7).
    /// Fast output that is being rendered never grows the client. Only
    /// handles that report a footprint are affected; `nil` turns it off.
    @ObservationIgnored public var clientFootprintLimit: UInt64? = SessionController.defaultClientFootprintLimit
    /// 16 MB. Measured with zmx 0.8.1: an idle client, and one carrying
    /// ~400 KB/s that the pane keeps up with, stays at about 1.4 MB; one
    /// second of `yes` against a slow pane takes it to about 35 MB.
    public nonisolated static let defaultClientFootprintLimit: UInt64 = 16 * 1024 * 1024
    /// No sampling right after an attach, while the replay is shown.
    @ObservationIgnored public var attachGracePeriod: Duration = .seconds(1)
    @ObservationIgnored var footprintSampleInterval: Duration = .milliseconds(500)

    public init(
        session: Session,
        backend: any PersistenceBackend,
        makeSurface: @MainActor () -> any TerminalSurface,
        makeOutputFilter: @escaping @MainActor () -> any OutputFilter = { IdentityOutputFilter() }
    ) {
        self.session = session
        self.backend = backend
        self.makeOutputFilter = makeOutputFilter
        self.surface = makeSurface()
        surface.delegate = self
    }

    /// Whether a live process is attached.
    public var isRunning: Bool {
        state.isAttached && (binding?.handle.isRunning ?? false)
    }

    // MARK: Lifecycle

    /// Connects to the session. Does nothing unless detached.
    public func start(_ mode: StartMode) async {
        guard state == .detached, !isClosed else { return }
        automaticReattaches = 0
        await bind(mode)
    }

    /// Shows a session that is known to be gone (at launch, a restored
    /// session that is no longer live) as ended, without starting anything.
    /// Does nothing unless detached.
    public func markEnded() {
        guard state == .detached, !isClosed else { return }
        setState(.ended(exitCode: nil))
    }

    /// Shows a session whose runtime is not available in this run. It is
    /// never started, respawned or killed until ``useBackend(_:makeOutputFilter:)``
    /// provides a working one. Does nothing unless detached or unavailable.
    public func markUnavailable(reason: String) {
        guard state == .detached || state.isUnavailable, !isClosed else { return }
        setState(.unavailable(reason: reason))
    }

    /// Switches to another backend while not connected (after the session
    /// runtime became available). An unavailable session becomes detached,
    /// ready to be started.
    public func useBackend(_ backend: any PersistenceBackend, makeOutputFilter: @escaping @MainActor () -> any OutputFilter) {
        guard binding == nil, !isClosed, state != .attaching else { return }
        self.backend = backend
        self.makeOutputFilter = makeOutputFilter
        if state.isUnavailable { setState(.detached) }
    }

    /// Tries again to attach to a disconnected session.
    public func reconnect() async {
        guard state.isDisconnected, !isClosed else { return }
        automaticReattaches = 0
        await bind(.attach)
    }

    /// Disconnects from the session without ending it: the client process
    /// is terminated, the session (for a persistent backend) keeps running.
    public func detach() async {
        guard let handle = binding?.handle else { return }
        await stopBinding(killing: false)
        await handle.terminate()
        setState(.detached)
    }

    /// ``detach()`` without waiting, for quitting: the client is hung up and
    /// its terminal closed before this returns; the session keeps running.
    public func detachNow() {
        guard let handle = binding?.handle else { return }
        abandonBinding()
        handle.hangUp()
        setState(.detached)
    }

    /// Replaces an ended (or running) session with a fresh one: same launch,
    /// directory, profile and location, new ID. The old session is killed in
    /// the backend first, whatever its state (a session shown as ended or
    /// disconnected may still be alive; killing a gone one is harmless).
    /// The surface is reset, the delegate told to rebind the pane, and the
    /// new session created. An unavailable session is never respawned.
    ///
    /// Not re-entrant: a call made while a respawn is in progress does
    /// nothing, so a double click can never retire one session twice or
    /// leave an orphaned process behind.
    public func respawn() async {
        guard !isRespawning, !isClosed, !state.isUnavailable else { return }
        isRespawning = true
        defer { isRespawning = false }
        let old = session
        automaticReattaches = 0
        await stopBinding(killing: true)
        // Closed while the old session was being killed: nothing to replace.
        guard !isClosed, session.id == old.id else { return }
        let fresh = Session(
            location: old.location,
            profileID: old.profileID,
            launch: old.launch,
            workingDirectory: old.workingDirectory)
        session = fresh
        // Full reset: a program that died in the alternate screen or with
        // mouse reporting on must not leave those modes behind.
        resetSurface()
        delegate?.sessionController(self, didReplace: old.id, with: fresh)
        await bind(.create)
    }

    /// Ends the session for good (closing its pane): kills it in the backend,
    /// whatever its state, and drops the process. An unavailable session is
    /// left alone (its runtime cannot be reached). The controller should be
    /// discarded afterwards.
    public func close() async {
        isClosed = true
        await stopBinding(killing: !state.isUnavailable)
        setState(.ended(exitCode: nil))
    }

    /// Clears the screen and scrollback (⌘K). A live program is sent ^L, the
    /// conventional redraw key: a shell clears the screen and redraws its
    /// prompt itself, so its idea of the cursor stays right. An ended
    /// session's screen is cleared locally.
    public func clearScreen() {
        surface.clearScrollback()
        if state.isAttached, let handle = binding?.handle {
            handle.write([0x0C])
        } else {
            surface.feed(Array("\u{1b}[H\u{1b}[2J".utf8)[...])
        }
    }

    // MARK: Binding

    private func bind(_ mode: StartMode) async {
        generation += 1
        let generation = generation
        let target = session
        failure = nil
        setState(.attaching)
        let size = currentPTYSize()
        let handle: any ProcessHandle
        do {
            switch mode {
            case .create: handle = try await backend.create(target, size: size)
            case .attach: handle = try await backend.attach(target, size: size)
            }
        } catch {
            guard generation == self.generation, !isClosed else { return }
            switch error as? BackendError {
            case .notPersistent?, .noSuchSession?:
                // Simply gone; nothing went wrong.
                failure = nil
                setState(.ended(exitCode: nil))
            default:
                let reason = String(describing: error)
                // Only a session confirmed gone is ended. One that may still
                // be running (alive, or the backend cannot tell) is
                // disconnected, with Reconnect: a create whose second attach
                // timed out on a loaded machine, say.
                let alive = (try? await backend.exists(target.id)) ?? true
                guard generation == self.generation, !isClosed else { return }
                failure = reason
                setState(alive ? .disconnected(reason: reason) : .ended(exitCode: nil))
            }
            return
        }
        guard generation == self.generation, !isClosed else {
            // Superseded while connecting (closed or respawned meanwhile):
            // nobody will ever use this session, so end it in the backend
            // too (for zmx, a daemon nobody references). If a newer connect
            // is for the same session, only this client goes.
            let backend = backend
            let isRetired = isClosed || target.id != session.id
            Task {
                if isRetired { try? await backend.kill(target.id) }
                await handle.terminate()
            }
            return
        }
        if mode == .create, let version = handle.runtimeVersion, session.runtimeVersion != version {
            session.runtimeVersion = version
            delegate?.sessionController(self, didRecordRuntimeVersion: version)
        }
        if mode == .attach {
            // The replay starts from a clean slate: no modes, screen or
            // scrollback left from an earlier attach.
            resetSurface()
        }
        let attachedAt = ContinuousClock.now
        var binding = Binding(generation: generation, handle: handle, attachedAt: attachedAt)
        filter = makeOutputFilter()
        // The surface may have been resized while connecting.
        handle.resize(currentPTYSize())
        binding.outputTask = Task { [weak self] in
            for await batch in handle.output {
                guard let self, self.generation == generation else { return }
                if let bytes = self.filter?.filter(batch), !bytes.isEmpty {
                    self.surface.feed(bytes[...])
                }
                // While output keeps coming, `next()` resumes without ever
                // suspending, so without this the loop would hold the main
                // actor for the whole flood: no events, no flood check.
                await Task.yield()
            }
            guard let self, self.generation == generation else { return }
            self.finishFilter()
            self.binding?.isOutputFinished = true
            self.endIfFinished(generation)
        }
        binding.exitTask = Task { [weak self] in
            let code = await handle.exitStatus
            guard let self, self.generation == generation else { return }
            self.binding?.exit = .some(code)
            self.endIfFinished(generation)
            guard self.state.isAttached else { return }
            // Output normally ends with the process; don't wait forever for a
            // stream something else keeps open.
            try? await Task.sleep(for: self.drainTimeout)
            guard self.generation == generation, self.state.isAttached else { return }
            self.clientDidEnd(generation, exitCode: code)
        }
        if let limit = clientFootprintLimit {
            let grace = attachGracePeriod
            let interval = footprintSampleInterval
            binding.floodWatchTask = Task { [weak self] in
                try? await Task.sleep(for: grace)
                var samplesOverLimit = 0
                while !Task.isCancelled {
                    // Read off the main actor (one system call per sample).
                    let footprint = await Self.footprint(of: handle)
                    guard let self, self.generation == generation, self.state.isAttached else { return }
                    guard footprint != nil else { return } // not reported: nothing to watch
                    samplesOverLimit = (footprint ?? 0) > limit ? samplesOverLimit + 1 : 0
                    if samplesOverLimit >= 2 {
                        // Not from this task: reattaching cancels it, and
                        // the cancellation must not reach the new attach.
                        Task { await self.reattachAfterFlood(generation) }
                        return
                    }
                    try? await Task.sleep(for: interval)
                }
            }
        }
        self.binding = binding
        setState(.attached)
    }

    private func endIfFinished(_ generation: Int) {
        guard let binding, binding.generation == generation, binding.isOutputFinished,
              let exit = binding.exit else { return }
        clientDidEnd(generation, exitCode: exit)
    }

    /// The client of binding `generation` exited (and its output drained,
    /// or the drain timed out). Asks the backend what that means. Ended:
    /// the session is over. Detached: the session is alive, so the
    /// controller reattaches once; if the allowance is used up it shows the
    /// session as disconnected (never as ended: it is still running).
    private func clientDidEnd(_ generation: Int, exitCode: Int32?) {
        guard var current = binding, current.generation == generation, !current.isResolvingExit else { return }
        current.isResolvingExit = true
        current.outputTask?.cancel()
        current.floodWatchTask?.cancel()
        binding = current
        finishFilter()
        let lasted = ContinuousClock.now - current.attachedAt >= reattachAllowanceInterval
        let target = session
        let backend = backend
        Task { [weak self] in
            let resolution = await backend.resolveExit(of: target)
            guard let self, self.generation == generation, !self.isClosed else { return }
            if lasted { self.automaticReattaches = 0 }
            switch resolution {
            case .ended:
                self.end(exitCode: exitCode)
            case .detached:
                guard self.automaticReattaches < 1 else {
                    self.disconnect(reason: "The connection to the session was lost.")
                    return
                }
                self.automaticReattaches += 1
                self.binding = nil
                await self.bind(.attach)
            }
        }
    }

    @concurrent
    private nonisolated static func footprint(of handle: any ProcessHandle) async -> UInt64? {
        handle.clientFootprint
    }

    /// Drops a client whose backlog has grown too large and attaches again:
    /// the new client starts from a bounded snapshot of the session.
    private func reattachAfterFlood(_ generation: Int) async {
        guard generation == self.generation, let old = binding, !isClosed else { return }
        floodReattaches += 1
        abandonBinding()
        old.handle.hangUp()
        await bind(.attach)
    }

    /// Full terminal reset plus cleared scrollback.
    private func resetSurface() {
        surface.feed(Array("\u{1b}c".utf8)[...])
        surface.clearScrollback()
    }

    private func end(exitCode: Int32?) {
        binding?.cancelTasks()
        binding = nil
        finishFilter()
        setState(.ended(exitCode: exitCode))
    }

    private func disconnect(reason: String) {
        binding?.cancelTasks()
        binding = nil
        finishFilter()
        setState(.disconnected(reason: reason))
    }

    /// Flushes what the current filter held back. Runs once per binding,
    /// whichever way the session ended.
    private func finishFilter() {
        guard var current = filter else { return }
        filter = nil
        let tail = current.finish()
        if !tail.isEmpty { surface.feed(tail[...]) }
    }

    /// Forgets the current binding: events from it are ignored from now on.
    private func abandonBinding() {
        generation += 1
        binding?.cancelTasks()
        binding = nil
        filter = nil
    }

    /// Detaches from the current process. With `killing`, the session is
    /// also killed in the backend, whatever state it seemed to be in (a
    /// not-found session is not an error), so nothing is left running.
    private func stopBinding(killing: Bool) async {
        let old = binding
        abandonBinding()
        guard killing else { return }
        try? await backend.kill(session.id)
        if let handle = old?.handle, handle.isRunning {
            await handle.terminate()
        }
    }

    private func setState(_ newState: SessionState) {
        guard state != newState else { return }
        state = newState
        delegate?.sessionController(self, didChangeState: newState)
    }

    /// The surface's grid as a PTY window size, with the text area in pixels.
    func currentPTYSize() -> PTYSize {
        let grid = surface.gridSize
        let scale = Double(surface.view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        func clamp(_ value: Double) -> UInt16 { UInt16(clamping: Int(value.rounded())) }
        return PTYSize(
            columns: UInt16(clamping: max(grid.columns, 1)),
            rows: UInt16(clamping: max(grid.rows, 1)),
            pixelWidth: clamp(Double(grid.columns) * grid.cellWidth * scale),
            pixelHeight: clamp(Double(grid.rows) * grid.cellHeight * scale))
    }
}

// MARK: - TerminalSurfaceDelegate

extension SessionController: TerminalSurfaceDelegate {
    public func surface(_ surface: any TerminalSurface, didInput bytes: [UInt8]) {
        guard state.isAttached else { return }
        binding?.handle.write(bytes)
    }

    public func surface(_ surface: any TerminalSurface, didResize size: GridSize) {
        binding?.handle.resize(currentPTYSize())
    }

    public func surface(_ surface: any TerminalSurface, didSetTitle title: String) {
        session.title = title
        delegate?.sessionController(self, didSetTitle: title)
    }

    public func surface(_ surface: any TerminalSurface, didChangeDirectory url: URL) {
        guard url.isFileURL else { return }
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty, path != session.workingDirectory else { return }
        session.workingDirectory = path
        delegate?.sessionController(self, didChangeDirectory: path)
    }

    public func surfaceDidRingBell(_ surface: any TerminalSurface) {
        delegate?.sessionControllerDidRingBell(self)
    }

    public func surface(_ surface: any TerminalSurface, didRequestClipboard op: ClipboardOp) {
        delegate?.sessionController(self, didRequestClipboard: op)
    }

    public func surface(_ surface: any TerminalSurface, didReceiveNotification title: String, body: String) {
        delegate?.sessionController(self, didReceiveNotification: title, body: body)
    }

    public func surface(_ surface: any TerminalSurface, didActivateLink link: String) {
        delegate?.sessionController(self, didActivateLink: link)
    }
}
