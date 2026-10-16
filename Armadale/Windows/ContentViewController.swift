import AppKit
import ArmadaleCore
import ArmadaleSessions

/// The content side of a workspace window: the focused pane of the selected
/// tab. (The tab bar and the split tree arrive in step 4; `paneContainer`
/// is where `SplitTreeView` will go.)
@MainActor
final class ContentViewController: NSViewController, NSMenuItemValidation {
    /// UserDefaults key: ask before closing a pane whose process is running.
    static let confirmClosingRunningSessionKey = "confirmClosingRunningSession"

    private let model: AppModel
    private let workspaceID: WorkspaceID
    private let registry: SessionRegistry
    private let paneContainer = NSView()
    private var shown: Focus?
    private var paneView: PaneView?
    private var focusTask: Task<Void, Never>?

    /// The pane on screen and the session it shows.
    private struct Focus: Equatable, Sendable {
        var paneID: PaneID
        var sessionID: SessionID
    }

    init(model: AppModel, workspaceID: WorkspaceID, registry: SessionRegistry) {
        self.model = model
        self.workspaceID = workspaceID
        self.registry = registry
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        focusTask?.cancel()
    }

    override func loadView() {
        let container = NSView()
        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(paneContainer)
        // The content view extends under the transparent title bar and the
        // floating sidebar; keep the terminal inside the safe area.
        let safeArea = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            paneContainer.topAnchor.constraint(equalTo: safeArea.topAnchor),
            paneContainer.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            paneContainer.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            paneContainer.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = model
        let workspaceID = workspaceID
        focusTask = Task { [weak self] in
            let focuses = Observations { () -> Focus? in
                guard let tab = model.workspace(workspaceID)?.selectedTabGroup?.selectedTab,
                      let pane = tab.pane(tab.focusedPaneID)
                else { return nil }
                return Focus(paneID: pane.id, sessionID: pane.sessionID)
            }
            for await focus in focuses {
                self?.show(focus)
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        paneView?.focusTerminal()
    }

    private func show(_ focus: Focus?) {
        guard focus != shown else { return }
        shown = focus
        guard let focus, let pane = registry.paneView(for: focus.sessionID) else {
            paneView?.removeFromSuperview()
            paneView = nil
            return
        }
        if pane !== paneView {
            // Detach, never destroy: the registry keeps the old pane alive.
            paneView?.removeFromSuperview()
            pane.frame = paneContainer.bounds
            pane.autoresizingMask = [.width, .height]
            paneContainer.addSubview(pane)
            paneView = pane
        }
        let paneID = focus.paneID
        pane.onClosePane = { [weak self] in self?.closePane(paneID, confirm: false) }
        // Lay out first so the session starts at the pane's real size.
        view.layoutSubtreeIfNeeded()
        registry.startIfNeeded(focus.sessionID)
        pane.focusTerminal()
    }

    // MARK: Actions

    /// File › Close Pane (⌘W).
    @objc func closePane(_ sender: Any?) {
        guard let shown else { return }
        closePane(shown.paneID, confirm: true)
    }

    /// Edit › Clear Screen (⌘K).
    @objc func clearScreen(_ sender: Any?) {
        paneView?.controller.clearScreen()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(closePane(_:)), #selector(clearScreen(_:)): paneView != nil
        default: true
        }
    }

    /// Closes a pane, killing its session. Asks first if the process is
    /// still running and the user has not turned confirmation off.
    private func closePane(_ paneID: PaneID, confirm: Bool) {
        guard let tab = model.tab(containing: paneID), let sessionID = tab.pane(paneID)?.sessionID else { return }
        let isRunning = registry.controller(for: sessionID)?.isRunning ?? false
        let wantsConfirmation = UserDefaults.standard.bool(forKey: Self.confirmClosingRunningSessionKey)
        guard confirm, isRunning, wantsConfirmation, let window = view.window else {
            performClose(paneID, sessionID: sessionID)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close this pane?"
        alert.informativeText = "A process is still running in this pane. Closing it will end the session."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if alert.suppressionButton?.state == .on {
                    UserDefaults.standard.set(false, forKey: Self.confirmClosingRunningSessionKey)
                }
                guard response == .alertFirstButtonReturn else { return }
                self?.performClose(paneID, sessionID: sessionID)
            }
        }
    }

    private func performClose(_ paneID: PaneID, sessionID: SessionID) {
        // The model cascades (pane → tab → tab group → window); this view and
        // the window controller follow the model. The registry ends the
        // session's process.
        let result = model.closePane(paneID)
        registry.close(sessionID)
        if case .notFound = result {
            NSLog("Armadale: pane %@ was already gone", paneID.raw)
        }
    }
}
