import AppKit
import ArmadaleCore
import Observation

/// What a quit does about running sessions (docs/DESIGN.md section 8,
/// "Quitting with running sessions"). Pure, so the rule is testable apart
/// from AppKit; ``AppDelegate/applicationShouldTerminate(_:)`` acts on it.
enum QuitDecision: Equatable, Sendable {
    /// Quit as before: hang up every client, sessions keep running.
    case quitNow
    /// Ask with the alert: keep running in the menu bar, end the sessions
    /// and quit, or cancel. Carries the number of running sessions.
    case ask(running: Int)
    /// Hide the windows and stay in the menu bar; the quit is cancelled.
    case keepInMenuBar
    /// End every session, then quit; this quit is cancelled meanwhile.
    case endSessions
    /// An End Sessions and Quit is already under way and will quit when it
    /// is done; this quit is cancelled.
    case cancel

    /// Where the app is when the quit arrives.
    struct Context: Equatable, Sendable {
        /// SIGTERM (logout, `kill`), or a launch that cannot go on: never
        /// ask, never stay.
        var isForced = false
        /// In menu bar mode: a quit from there (the status menu's Quit,
        /// Keep Sessions Running, or ⌘Q in the Settings window) is a plain
        /// quit that keeps the sessions, from accessory mode.
        var isInMenuBar = false
        /// End Sessions and Quit is running.
        var isEndingSessions = false
        /// End Sessions and Quit has finished; this is its own quit.
        var sessionsEnded = false
    }

    static func decide(
        running: Int, preference: Preferences.QuitWithRunningSessions, context: Context
    ) -> QuitDecision {
        if context.isForced || context.sessionsEnded { return .quitNow }
        if context.isEndingSessions { return .cancel }
        if context.isInMenuBar || running == 0 { return .quitNow }
        switch preference {
        case .ask: return .ask(running: running)
        case .keepInMenuBar: return .keepInMenuBar
        case .endSessions: return .endSessions
        }
    }

    /// How many sessions may still have a live process: the
    /// close-confirmation rule (``CloseRisk/mayBeRunning(_:)``). A session
    /// created in this run and never shown has no process and does not
    /// count; ended and unavailable ones do not either.
    static func runningCount(_ items: [CloseRisk.Item]) -> Int {
        items.count(where: CloseRisk.mayBeRunning)
    }
}

/// Bringing Armadale forward for a window the user just asked for from
/// the status menu or the main menu (docs/DESIGN.md section 8,
/// "Activation"). `NSApp.activate()` is cooperative since macOS 14, and
/// on macOS 27 the system refuses it after a real click on the status
/// item: the active app keeps the focus and the window opens behind it.
/// Activating *from* the frontmost app, as if it had yielded, is let
/// through (measured November 9, 2026).
enum AppActivation {
    /// The app to take activation from: the frontmost app when it is
    /// another one; `nil` (a plain `NSApp.activate()`) when Armadale is
    /// already frontmost or nothing is.
    static func source(frontmost: NSRunningApplication?, current: NSRunningApplication) -> NSRunningApplication? {
        guard let frontmost, frontmost.processIdentifier != current.processIdentifier else { return nil }
        return frontmost
    }

    /// Activates the app for a window it has just put on screen.
    /// `allWindows` brings every window forward (Open Armadale), not only
    /// the key and main ones.
    ///
    /// `activate(from:options:)` is documented for an app the other one has
    /// yielded to (`yieldActivation(to:)`); the frontmost app here never
    /// yields. macOS 27 lets the request through anyway (checked live with
    /// a real status-item click), where the cooperative `NSApp.activate()`
    /// and a switch to the regular policy were refused. AppKit promises no
    /// activation at all, so a refusal falls back to the plain request.
    @MainActor
    static func bringForward(allWindows: Bool = false) {
        let current = NSRunningApplication.current
        if let source = source(frontmost: NSWorkspace.shared.frontmostApplication, current: current),
           current.activate(from: source, options: allWindows ? [.activateAllWindows] : []) {
            return
        }
        NSApp.activate()
    }
}

/// The user-visible wording of the quit question and the status item.
enum MenuBarText {
    static func alertMessage(running: Int) -> String {
        running == 1 ? "1 session is still running" : "\(running) sessions are still running"
    }

    static func alertInformative(running: Int) -> String {
        if running == 1 {
            return "Armadale can keep the session running and stay in the menu bar, where you can "
                + "reopen it or end the session later. Ending the session stops every program running in it."
        }
        return "Armadale can keep them running and stay in the menu bar, where you can "
            + "reopen it or end the sessions later. Ending the sessions stops every program running in them."
    }
    static let keepButton = "Keep Running in Menu Bar"
    static let endButton = "End Sessions and Quit"
    static let cancelButton = "Cancel"

    /// The status menu's first, disabled line.
    static func runningLine(_ running: Int) -> String {
        running == 1 ? "1 session running" : "\(running) sessions running"
    }

    /// The count line while End Sessions and Quit runs.
    static let ending = "Ending sessions…"
    static let open = "Open Armadale"
    static let settings = "Settings…"
    static let quitKeepingSessions = "Quit, Keep Sessions Running"
    static let endSessionsAndQuit = "End Sessions and Quit"

    /// The status item's text next to the glyph: the attention count, or
    /// nothing.
    static func buttonTitle(attentionTotal: Int) -> String {
        AttentionBadge.label(total: attentionTotal) ?? ""
    }

    /// What the status item says on hover: attention first, else whether
    /// sessions are running (none once the last one ended or closed).
    static func toolTip(attentionTotal: Int, isRunning: Bool) -> String {
        switch attentionTotal {
        case 0: isRunning ? "Armadale: sessions running" : "Armadale"
        case 1: "Armadale: 1 session needs attention"
        default: "Armadale: \(attentionTotal) sessions need attention"
        }
    }
}

/// Menu bar mode's status item: the three-pane glyph (a template image from
/// the asset catalog, generated by `scripts/render-app-icon.swift`), the
/// attention count next to it, and a menu to come back or quit. Exists only
/// while the app is in menu bar mode; ``remove()`` takes it away.
@MainActor
final class MenuBarStatusItem: NSObject, NSMenuDelegate {
    /// The actions behind the menu's items (the app delegate's).
    struct Actions {
        var open: Selector
        var settings: Selector
        var quitKeepingSessions: Selector
        var endSessionsAndQuit: Selector
    }

    private let item: NSStatusItem
    private let runningCount: () -> Int
    private let sessionsSurviveQuit: () -> Bool
    private var attentionTask: Task<Void, Never>?
    private let menu: NSMenu
    /// End Sessions and Quit is running (``showEnding()``).
    private(set) var isEnding = false

    /// `sessionsSurviveQuit` false (the persistence fallback) hides Quit,
    /// Keep Sessions Running: every local session would end with it.
    init(
        target: AnyObject, actions: Actions, attention: AttentionCenter,
        runningCount: @escaping () -> Int, sessionsSurviveQuit: @escaping () -> Bool
    ) {
        self.runningCount = runningCount
        self.sessionsSurviveQuit = sessionsSurviveQuit
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = Self.makeMenu(
            target: target, actions: actions, running: runningCount(), sessionsSurviveQuit: sessionsSurviveQuit())
        super.init()
        menu.delegate = self
        item.menu = menu
        if let button = item.button {
            let image = NSImage(named: "StatusItem")
                ?? NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
            image?.isTemplate = true
            image?.accessibilityDescription = "Armadale"
            button.image = image
            button.imagePosition = .imageLeading
        }
        show(attentionTotal: attention.total, isRunning: runningCount() > 0)
        attentionTask = Task { [weak self] in
            for await (total, isRunning) in Observations({ (attention.total, runningCount() > 0) }) {
                self?.show(attentionTotal: total, isRunning: isRunning)
            }
        }
    }

    /// Takes the status item out of the menu bar.
    func remove() {
        attentionTask?.cancel()
        attentionTask = nil
        NSStatusBar.system.removeStatusItem(item)
    }

    private func show(attentionTotal: Int, isRunning: Bool) {
        item.button?.title = MenuBarText.buttonTitle(attentionTotal: attentionTotal)
        item.button?.toolTip = MenuBarText.toolTip(attentionTotal: attentionTotal, isRunning: isRunning)
    }

    /// End Sessions and Quit is running: the count line says so and every
    /// item is disabled until the app quits.
    func showEnding() {
        isEnding = true
        Self.showEnding(in: menu)
    }

    static func showEnding(in menu: NSMenu) {
        menu.items.first?.title = MenuBarText.ending
        for entry in menu.items.dropFirst() { entry.isEnabled = false }
    }

    /// The count is taken each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !isEnding else { return }
        menu.items.first?.title = MenuBarText.runningLine(runningCount())
        menu.item(withTitle: MenuBarText.quitKeepingSessions)?.isHidden = !sessionsSurviveQuit()
    }

    /// "N sessions running" (disabled), Open Armadale, Settings…, a
    /// separator, Quit, Keep Sessions Running (hidden unless sessions
    /// survive a quit), End Sessions and Quit.
    static func makeMenu(target: AnyObject, actions: Actions, running: Int, sessionsSurviveQuit: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let count = NSMenuItem(title: MenuBarText.runningLine(running), action: nil, keyEquivalent: "")
        count.isEnabled = false
        menu.addItem(count)
        func add(_ title: String, _ action: Selector) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = target
            menu.addItem(entry)
        }
        add(MenuBarText.open, actions.open)
        add(MenuBarText.settings, actions.settings)
        menu.addItem(.separator())
        add(MenuBarText.quitKeepingSessions, actions.quitKeepingSessions)
        menu.items.last?.isHidden = !sessionsSurviveQuit
        add(MenuBarText.endSessionsAndQuit, actions.endSessionsAndQuit)
        return menu
    }
}
