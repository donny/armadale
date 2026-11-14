import ArmadaleCore
import Foundation

/// Each session's last grid size (``Session/gridSize``, docs/DESIGN.md
/// section 3): the size its controller last gave the program's PTY, written
/// to the model once it has settled (``settleInterval`` after the last
/// change), all sessions together in one model change. A live window
/// resize changes many panes' grids many times a second; recording each
/// step would save and invalidate every view observing the model's
/// sessions each time. ``flush()`` writes what is pending at once (before
/// the save at quit); a crash loses at most the settle interval plus the
/// usual save window.
@MainActor
final class GridSizeRecorder {
    /// How long a size must stay unchanged before it is recorded.
    var settleInterval: Duration = .milliseconds(500)
    private var pending: [SessionID: SessionGridSize] = [:]
    private var task: Task<Void, Never>?
    private let current: (SessionID) -> SessionGridSize?
    private let write: ([SessionID: SessionGridSize]) -> Void

    /// `current` reads a session's recorded size, `write` records sizes.
    init(current: @escaping (SessionID) -> SessionGridSize?, write: @escaping ([SessionID: SessionGridSize]) -> Void) {
        self.current = current
        self.write = write
    }

    /// The sizes waiting to be recorded.
    var pendingSizes: [SessionID: SessionGridSize] { pending }

    /// A size was applied to `id`'s program. Nothing is scheduled when it
    /// is already the recorded one (an attach at the saved size).
    func record(_ size: SessionGridSize, for id: SessionID) {
        guard size.isPlausible else { return }
        if pending[id] == nil, current(id) == size { return }
        pending[id] = size
        task?.cancel()
        let interval = settleInterval
        task = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Records every pending size now.
    func flush() {
        task?.cancel()
        task = nil
        guard !pending.isEmpty else { return }
        let sizes = pending
        pending = [:]
        write(sizes)
    }

    /// The session left the model: nothing to record for it.
    func forget(_ id: SessionID) {
        pending[id] = nil
    }

    /// A respawn replaced `old` with `new` in the same pane.
    func rekey(_ old: SessionID, to new: SessionID) {
        if let size = pending.removeValue(forKey: old) { pending[new] = size }
    }
}
