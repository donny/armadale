import ArmadaleCore
import CoreGraphics

/// The pure rules behind a workspace window's saved geometry (DESIGN §8,
/// "App lifecycle"): which frame is recorded, and where a saved frame
/// opens. AppKit is applied by ``WorkspaceWindowController``.
enum WindowGeometry {
    /// The frame to record for a window. In full screen (or on the way in
    /// or out of it) the window's frame is the screen's, so the last normal
    /// frame is kept instead; `nil` when there is none yet, which opens the
    /// default size next time.
    static func recordedFrame(isFullScreen: Bool, current: WindowFrame?, lastNormal: WindowFrame?) -> WindowFrame? {
        isFullScreen ? lastNormal : current
    }

    /// Where a saved frame opens.
    enum Placement: Equatable {
        /// Its title bar is on a screen: as saved, even spanning two
        /// displays or reaching past an edge (deliberate placements).
        case asSaved
        /// Its title bar is on no screen but the frame overlaps one: AppKit
        /// constrains it to the screen at this index (of the visible frames
        /// given), the one it overlaps most.
        case constrained(toScreen: Int)
        /// On no screen that still exists (a disconnected display): the
        /// default size, centred, as a window without a saved frame.
        case centredDefault
    }

    /// The height of the strip at the top of a frame that stands for its
    /// title bar (the toolbar's unified title bar is about 52 pt).
    static let titleBarStrip: CGFloat = 40

    /// Decides the placement of `saved` (AppKit coordinates, y up) among
    /// the screens' visible frames.
    static func placement(of saved: CGRect, visibleFrames: [CGRect]) -> Placement {
        guard !saved.isEmpty else { return .centredDefault }
        let stripHeight = min(titleBarStrip, saved.height)
        let titleBar = CGRect(x: saved.minX, y: saved.maxY - stripHeight, width: saved.width, height: stripHeight)
        if visibleFrames.contains(where: { overlapArea($0, titleBar) > 0 }) { return .asSaved }
        var best: (index: Int, area: CGFloat)?
        for (index, visible) in visibleFrames.enumerated() {
            let area = overlapArea(visible, saved)
            if area > (best?.area ?? 0) { best = (index, area) }
        }
        return best.map { .constrained(toScreen: $0.index) } ?? .centredDefault
    }

    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }
}

extension WindowFrame {
    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
