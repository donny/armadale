import AppKit
import ArmadaleCore
import ArmadaleSessions

/// Where a pane's own theme (``Pane/themeID``) is read from and written to:
/// the model's pane record, reached from a ``PaneView`` through its session
/// and from an ``EmptyPaneView`` through its pane ID (DESIGN §8, "Pane
/// context menu").
///
/// `current` is called inside observation tracking, so the model reads it
/// makes are observed and the pane re-applies its appearance when they
/// change.
struct PaneThemeBinding: Sendable {
    /// The pane's own theme ID, or `nil` when it follows Settings.
    let current: @MainActor @Sendable () -> String?
    /// Gives the pane its own theme, or `nil` for the Settings choice.
    let choose: @MainActor @Sendable (String?) -> Void

    /// A pane outside any model (tests): always the Settings choice.
    static let detached = PaneThemeBinding(current: { nil }, choose: { _ in })

    /// The pane `paneID` of `model`.
    @MainActor
    static func pane(_ paneID: PaneID, in model: AppModel) -> PaneThemeBinding {
        PaneThemeBinding(
            current: { model.pane(paneID)?.themeID },
            choose: { model.setTheme($0, forPane: paneID) })
    }

    /// The pane showing `controller`'s session, whichever session that is
    /// now (a respawn replaces it; the pane stays).
    @MainActor
    static func session(of controller: SessionController, in model: AppModel) -> PaneThemeBinding {
        PaneThemeBinding(
            current: { [weak controller] in
                controller.flatMap { model.pane(showing: $0.session.id)?.themeID }
            },
            choose: { [weak controller] themeID in
                guard let controller, let place = model.place(of: controller.session.id) else { return }
                model.setTheme(themeID, forPane: place.pane)
            })
    }
}

/// The context menu of a pane (``PaneView/paneMenu()``,
/// ``EmptyPaneView/paneMenu()``). No mouse event opens it yet: right-click
/// and Control-click stay the program's, and the owner is choosing an
/// entry point (DESIGN §8, "Pane context menu").
///
/// ``make(_:actions:)`` is a pure function of its inputs, so the menu can be
/// tested without a window. Items added later take their state from new
/// fields of ``Inputs`` and act through new fields of ``Actions``.
@MainActor
enum PaneMenu {
    /// What the menu shows.
    struct Inputs {
        /// The pane's own theme, `nil` when it follows Settings.
        var themeID: String?
        /// The built-in themes, in catalog order.
        var builtInThemes: [ThemeEntry]
        /// The imported themes, in catalog order.
        var userThemes: [ThemeEntry]

        /// The inputs for a pane whose theme is `themeID`, with `catalog`'s themes.
        @MainActor
        init(themeID: String?, catalog: ThemeCatalog) {
            self.init(themeID: themeID, builtInThemes: ThemeCatalog.builtIns, userThemes: catalog.userThemes)
        }

        init(themeID: String?, builtInThemes: [ThemeEntry], userThemes: [ThemeEntry]) {
            self.themeID = themeID
            self.builtInThemes = builtInThemes
            self.userThemes = userThemes
        }
    }

    /// What the items do.
    struct Actions {
        /// A theme was chosen: its ID, or `nil` for Default.
        var chooseTheme: @MainActor (String?) -> Void
    }

    static let themeTitle = "Theme"
    static let defaultThemeTitle = "Default"
    static let themeItemIdentifier = NSUserInterfaceItemIdentifier("armadale.pane.theme")

    /// The pane's menu.
    static func make(_ inputs: Inputs, actions: Actions) -> NSMenu {
        let menu = NSMenu(title: "Pane")
        menu.autoenablesItems = false
        menu.addItem(themeItem(inputs, actions: actions))
        return menu
    }

    /// Theme ▸ Default, the built-in themes, then the imported ones; the
    /// pane's current choice is checked (Default when it has none, or one
    /// the catalog does not know).
    private static func themeItem(_ inputs: Inputs, actions: Actions) -> NSMenuItem {
        let item = NSMenuItem(title: themeTitle, action: nil, keyEquivalent: "")
        item.identifier = themeItemIdentifier
        let submenu = NSMenu(title: themeTitle)
        submenu.autoenablesItems = false
        let known = (inputs.builtInThemes + inputs.userThemes).map(\.id)
        let current = inputs.themeID.map { $0.lowercased() }.flatMap { known.contains($0) ? $0 : nil }
        let choose = actions.chooseTheme

        let defaultItem = ActionMenuItem(title: defaultThemeTitle) { choose(nil) }
        defaultItem.state = current == nil ? .on : .off
        submenu.addItem(defaultItem)
        submenu.addItem(.separator())
        for entry in inputs.builtInThemes {
            submenu.addItem(themeEntryItem(entry, current: current, choose: choose))
        }
        if !inputs.userThemes.isEmpty {
            submenu.addItem(.separator())
            for entry in inputs.userThemes {
                submenu.addItem(themeEntryItem(entry, current: current, choose: choose))
            }
        }
        item.submenu = submenu
        return item
    }

    private static func themeEntryItem(
        _ entry: ThemeEntry, current: String?, choose: @escaping @MainActor (String?) -> Void
    ) -> NSMenuItem {
        let id = entry.id
        let item = ActionMenuItem(title: entry.name) { choose(id) }
        item.representedObject = id
        item.state = current == id ? .on : .off
        return item
    }
}

/// A menu item that runs a closure; it is its own target.
@MainActor
final class ActionMenuItem: NSMenuItem {
    let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}
