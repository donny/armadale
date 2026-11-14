import AppKit
import ArmadaleCore
import ArmadaleSessions

/// The pane views of the sessions shown so far, by session (docs/DESIGN.md
/// section 8). A pane view is made the first time its pane is shown, around
/// the controller the registry already holds, and kept until the session
/// leaves the model, so a tab switch or a closed window never destroys it.
@MainActor
final class PaneViewStore {
    private var views: [SessionID: PaneView] = [:]

    func view(for id: SessionID) -> PaneView? {
        views[id]
    }

    func insert(_ view: PaneView, for id: SessionID) {
        views[id] = view
    }

    @discardableResult
    func remove(_ id: SessionID) -> PaneView? {
        views.removeValue(forKey: id)
    }

    /// A respawn gave the pane's session a new ID.
    func rekey(_ old: SessionID, to new: SessionID) {
        if let view = views.removeValue(forKey: old) { views[new] = view }
    }

    /// Whether `id`'s pane is on screen: its view is in a window (a pane of
    /// a tab not shown, or of a closed window, is taken out of it).
    func isShown(_ id: SessionID) -> Bool {
        views[id]?.window != nil
    }
}

extension SessionRegistry {
    /// The pane view for `sessionID`, made around its controller the first
    /// time it is asked for (the pane is being shown).
    func paneView(for sessionID: SessionID) -> PaneView? {
        if let pane = paneViews.view(for: sessionID) { return pane }
        guard let controller = ensureController(for: sessionID) else { return nil }
        makeUnavailableIfHostRemoved(controller)
        // The renderer of the surface the pane will show, and of a
        // replacement pending since a renderer change.
        _ = controller.surface
        let record = surfaceRenderers[sessionID]
        let pane = PaneView(
            controller: controller, settings: settings, rendererID: record?.current ?? settings.surfaceFactory.id,
            pendingRendererID: record?.pending,
            theme: .session(of: controller, in: model) { [weak self] in self?.split(pane: $0, axis: $1) })
        pane.titleProvider = { [weak self, weak controller] in
            guard let self, let controller else { return "Shell" }
            return self.displayName(of: controller.session)
        }
        pane.onRetryPersistence = { [weak self] in self?.retryPersistence() }
        pane.headerSource = { [weak self, weak controller] in
            guard let self, let controller else { return PaneHeaderModel(status: .ended, title: "Shell", directory: nil) }
            return self.headerModel(for: controller.session.id)
        }
        paneViews.insert(pane, for: sessionID)
        return pane
    }
}
