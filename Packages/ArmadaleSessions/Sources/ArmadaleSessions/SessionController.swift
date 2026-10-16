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
}

/// The per-session glue between a backend's ``ProcessHandle`` and a
/// ``TerminalSurface``: pumps output into the surface, sends input and
/// resizes to the process, runs the state machine
/// (detached → attaching → attached → ended), and reports title, directory,
/// bell and notifications to its delegate.
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

    @ObservationIgnored private let backend: any PersistenceBackend
    @ObservationIgnored private let makeOutputFilter: @MainActor () -> any OutputFilter
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

    /// One attach of one process.
    private struct Binding {
        let generation: Int
        let handle: any ProcessHandle
        var outputTask: Task<Void, Never>?
        var exitTask: Task<Void, Never>?
        var isOutputFinished = false
        /// Set once the process has exited: its exit code, if it had one.
        var exit: Int32??
    }

    /// How long to wait for the output stream to finish after the process
    /// exited before declaring the session ended anyway.
    @ObservationIgnored var drainTimeout: Duration = .milliseconds(500)

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
        await bind(mode)
    }

    /// Replaces an ended (or running) session with a fresh one: same launch,
    /// directory, profile and location, new ID. The surface is reset, the
    /// delegate told to rebind the pane, and the new session created.
    ///
    /// Not re-entrant: a call made while a respawn is in progress does
    /// nothing, so a double click can never retire one session twice or
    /// leave an orphaned process behind.
    public func respawn() async {
        guard !isRespawning, !isClosed else { return }
        isRespawning = true
        defer { isRespawning = false }
        let old = session
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
        surface.feed(Array("\u{1b}c".utf8)[...])
        surface.clearScrollback()
        delegate?.sessionController(self, didReplace: old.id, with: fresh)
        await bind(.create)
    }

    /// Ends the session for good (closing its pane): kills it in the backend
    /// and drops the process. The controller should be discarded afterwards.
    public func close() async {
        isClosed = true
        await stopBinding(killing: true)
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
            if let backendError = error as? BackendError, backendError == .notPersistent {
                failure = nil
            } else {
                failure = String(describing: error)
            }
            setState(.ended(exitCode: nil))
            return
        }
        guard generation == self.generation, !isClosed else {
            // Superseded while connecting (closed or respawned meanwhile):
            // nobody will ever use this session, so end it in the backend
            // too (for zmx, a daemon nobody references).
            let backend = backend
            Task {
                try? await backend.kill(target.id)
                await handle.terminate()
            }
            return
        }
        var binding = Binding(generation: generation, handle: handle)
        filter = makeOutputFilter()
        // The surface may have been resized while connecting.
        handle.resize(currentPTYSize())
        binding.outputTask = Task { [weak self] in
            for await batch in handle.output {
                guard let self, self.generation == generation else { return }
                if let bytes = self.filter?.filter(batch), !bytes.isEmpty {
                    self.surface.feed(bytes[...])
                }
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
            self.end(exitCode: code)
        }
        self.binding = binding
        setState(.attached)
    }

    private func endIfFinished(_ generation: Int) {
        guard let binding, binding.generation == generation, binding.isOutputFinished,
              let exit = binding.exit else { return }
        end(exitCode: exit)
    }

    private func end(exitCode: Int32?) {
        binding?.outputTask?.cancel()
        binding = nil
        finishFilter()
        setState(.ended(exitCode: exitCode))
    }

    /// Flushes what the current filter held back. Runs once per binding,
    /// whichever way the session ended.
    private func finishFilter() {
        guard var current = filter else { return }
        filter = nil
        let tail = current.finish()
        if !tail.isEmpty { surface.feed(tail[...]) }
    }

    /// Detaches from the current process, optionally killing the session.
    private func stopBinding(killing: Bool) async {
        generation += 1
        let old = binding
        binding = nil
        filter = nil
        old?.outputTask?.cancel()
        old?.exitTask?.cancel()
        guard killing else { return }
        if let handle = old?.handle, handle.isRunning {
            try? await backend.kill(session.id)
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
