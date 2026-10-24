import AppKit
import ArmadaleCore
import ArmadaleSessions
import Testing

/// The New Session chooser every empty pane shows (DESIGN §8, "New
/// sessions"): its decisions (``NewSessionChooser``), the actions behind
/// them (``WorkspaceActions/startFavorite(_:in:)``, ``WorkspaceActions/newSession(in:)``,
/// ``WorkspaceActions/cancelNewSession(in:)``, ``WorkspaceActions/editFavorite(_:)``),
/// and the empty pane's keyboard focus (``EmptyPaneView``). Windows are
/// never ordered on screen and no process is started.
@Suite("New Session chooser")
@MainActor
struct NewSessionChooserTests {
    private func fixture() -> (AppModel, WorkspaceActions, AppSettings, WorkspaceID) {
        _ = NSApplication.shared
        let model = AppModel(defaultWorkingDirectory: "/Users/me")
        let workspace = model.newWorkspace(name: "W")
        model.fillEmptyPanes(workingDirectory: "/repo")
        let settings = AppSettings.forTesting()
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: [],
            settings: settings)
        return (model, WorkspaceActions(model: model, registry: registry, workspaceID: workspace), settings, workspace)
    }

    /// A window for the real sheet and content (never ordered on screen).
    private func windowFixture() -> (AppModel, WorkspaceWindowController, AppSettings, WorkspaceID) {
        let (model, actions, settings, workspace) = fixture()
        let controller = WorkspaceWindowController(model: model, workspaceID: workspace, registry: actions.registry)
        return (model, controller, settings, workspace)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func focusedSession(_ model: AppModel, _ workspace: WorkspaceID) throws -> Session {
        try #require(model.focusedSessionID(in: workspace).flatMap { model.session($0) })
    }

    /// Three favorites: a local Claude Code one, a broken one (its host is
    /// gone) and a local shell in a directory.
    private func addFavorites(to model: AppModel) -> (claude: FavoriteID, broken: FavoriteID, shell: FavoriteID) {
        let claude = model.addFavorite(Favorite(
            name: "Claude", request: SessionRequest(
                profileID: Profile.claudeCode.id, workingDirectory: "~/work",
                options: SessionOptions(continueConversation: true))))
        let broken = model.addFavorite(Favorite(
            name: "Gone", request: SessionRequest(location: .remote(host: HostID.generate()))))
        let shell = model.addFavorite(Favorite(
            name: "Shell", request: SessionRequest(workingDirectory: "/tmp")))
        return (claude, broken, shell)
    }

    // MARK: Selection

    /// ↓ and ↑ move through the favorites that can start, skipping broken
    /// ones, and clamp: above the first is no selection, and the last stays.
    @Test func arrowsMoveThroughStartableFavoritesAndClamp() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let (claude, _, shell) = addFavorites(to: model)
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let chooser = NewSessionChooser(model: model, paneID: pane, actions: actions)

        #expect(chooser.favorites.count == 3, "broken ones are listed")
        #expect(chooser.selectedFavoriteID == nil, "nothing is selected at first")
        #expect(chooser.returnOpensDialog)
        #expect(chooser.handle(.up) == false, "nothing above no selection")
        #expect(chooser.handle(.down))
        #expect(chooser.selectedFavoriteID == claude)
        #expect(chooser.handle(.down))
        #expect(chooser.selectedFavoriteID == shell, "the broken one is skipped")
        #expect(chooser.handle(.down) == false, "clamped at the last")
        #expect(chooser.selectedFavoriteID == shell)
        chooser.handle(.up)
        #expect(chooser.selectedFavoriteID == claude)
        chooser.handle(.up)
        #expect(chooser.selectedFavoriteID == nil, "back to no selection")
        #expect(chooser.returnOpensDialog)
    }

    /// A selection whose favorite is removed or breaks no longer counts.
    @Test func aSelectionThatBreaksOrGoesIsDropped() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let host = model.addHost(name: "box", sshDestination: "me@box")
        let remote = model.addFavorite(Favorite(name: "Box", request: SessionRequest(location: .remote(host: host))))
        let (claude, _, _) = addFavorites(to: model)
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let chooser = NewSessionChooser(model: model, paneID: pane, actions: actions)
        chooser.handle(.down)
        #expect(chooser.selectedFavoriteID == remote)
        model.removeHost(host)
        #expect(chooser.selectedFavoriteID == nil, "broken now")
        #expect(chooser.problem(of: try #require(model.favorite(remote))) == "Host removed")
        chooser.handle(.down)
        #expect(chooser.selectedFavoriteID == claude)
        chooser.remove(claude)
        #expect(model.favorite(claude) == nil, "removed without a question")
        #expect(chooser.selection == nil)
    }

    // MARK: Return, Escape, clicks

    /// Return with a favorite selected starts it in the pane, with the
    /// favorite's request resolved (profile, options, directory).
    @Test func returnStartsTheSelectedFavorite() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let (claude, _, _) = addFavorites(to: model)
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        var focused: PaneID?
        actions.focusPaneWhenShown = { focused = $0 }
        let chooser = NewSessionChooser(model: model, paneID: pane, actions: actions)
        chooser.handle(.down)
        #expect(chooser.selectedFavoriteID == claude)
        #expect(chooser.handle(.confirm))

        let session = try #require(model.pane(pane)?.sessionID.flatMap { model.session($0) })
        #expect(session.profileID == Profile.claudeCode.id)
        #expect(session.options == SessionOptions(continueConversation: true))
        #expect(session.workingDirectory == "/Users/me/work", "~ resolved against home")
        #expect(model.selectedTab(in: workspace)?.focusedPaneID == pane)
        #expect(focused == pane, "the terminal takes keyboard focus once shown")
    }

    /// A click on a favorite starts it; a broken one is refused and
    /// changes nothing.
    @Test func aClickStartsAFavoriteAndABrokenOneIsRefused() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let (_, broken, shell) = addFavorites(to: model)
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let chooser = NewSessionChooser(model: model, paneID: pane, actions: actions)
        let sessionsBefore = model.sessions.count

        #expect(chooser.start(broken) == false)
        #expect(actions.startFavorite(broken, in: pane) == nil)
        #expect(actions.startFavorite(FavoriteID.generate(), in: pane) == nil, "a removed favorite")
        #expect(model.pane(pane)?.isEmpty == true)
        #expect(model.sessions.count == sessionsBefore)

        #expect(chooser.start(shell))
        let session = try #require(model.pane(pane)?.sessionID.flatMap { model.session($0) })
        #expect(session.profileID == Profile.shell.id)
        #expect(session.workingDirectory == "/tmp")
        #expect(chooser.start(shell) == false, "the pane has its session now")
        #expect(model.sessions.count == sessionsBefore + 1)
    }

    /// Return with nothing selected opens the New Session dialog for the
    /// pane; its Cancel closes only the sheet, and the pane keeps its
    /// chooser.
    @Test func returnWithoutSelectionOpensTheDialog() throws {
        let (model, controller, settings, workspace) = windowFixture()
        defer {
            controller.close()
            settings.removeTestDefaults()
        }
        let actions = controller.actions
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let chooser = NewSessionChooser(model: model, paneID: pane, actions: actions)
        #expect(chooser.handle(.confirm))
        #expect(actions.newSessionPane == pane)
        #expect(controller.window?.attachedSheet != nil)
        actions.endNewSessionSheet() // the dialog's Cancel
        #expect(actions.newSessionPane == nil)
        #expect(model.pane(pane)?.isEmpty == true, "the pane stays, with its chooser")
    }

    /// Return and Escape do nothing in a pane that is not the focused one
    /// of a split.
    @Test func onlyTheKeyTargetTakesReturnAndEscape() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let (claude, _, _) = addFavorites(to: model)
        actions.splitFocusedPane(axis: .horizontal)
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let chooser = NewSessionChooser(model: model, paneID: pane, actions: actions)
        chooser.isKeyTarget = false
        chooser.select(claude)
        #expect(chooser.handle(.confirm) == false)
        #expect(chooser.handle(.cancel) == false)
        #expect(model.pane(pane)?.isEmpty == true)
    }

    /// Escape (Cancel) closes the empty pane at once, with no question and
    /// nothing to end; a split's pane leaves the tab as it was.
    @Test func escapeClosesTheEmptyPane() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let tab = try #require(model.selectedTab(in: workspace))
        actions.splitFocusedPane(axis: .horizontal)
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        var removed: Set<SessionID> = []
        model.onSessionsRemoved = { removed.formUnion($0) }
        let chooser = NewSessionChooser(model: model, paneID: pane, actions: actions)
        #expect(chooser.handle(.cancel))
        #expect(model.pane(pane) == nil)
        #expect(model.tab(tab.id)?.layout == tab.layout)
        #expect(removed.isEmpty)
        #expect(model.emptyPaneIDs(in: workspace).isEmpty)
    }

    /// ⌘N then Cancel: the cascade removes the tab, the group and the new
    /// workspace (its window then closes itself), as a clean exit does.
    @Test func cancellingANewWorkspaceRemovesIt() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let fresh = model.newWorkspace()
        let pane = try #require(model.emptyPaneIDs(in: fresh).first)
        let freshActions = WorkspaceActions(model: model, registry: actions.registry, workspaceID: fresh)
        NewSessionChooser(model: model, paneID: pane, actions: freshActions).cancel()
        #expect(model.workspace(fresh) == nil)
        #expect(model.workspace(workspace) != nil)
    }

    /// Cancel for a pane that was meanwhile given a session (or is gone)
    /// closes nothing.
    @Test func cancelLeavesAStartedPaneAlone() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        actions.cancelNewSession(in: pane)
        #expect(model.pane(pane)?.isEmpty == false)
    }

    /// An empty pane closes without a question and ends nothing.
    @Test func closingAnEmptyPaneDoesNotAsk() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let tab = try #require(model.newTab(in: group))
        let pane = try #require(model.tab(tab)?.focusedPaneID)
        var removed: Set<SessionID> = []
        model.onSessionsRemoved = { removed.formUnion($0) }
        actions.closePane(pane, confirm: true)
        #expect(model.tab(tab) == nil, "closed at once, no alert")
        #expect(removed.isEmpty)
        #expect(model.sessionIDs(in: workspace).count == 1)
    }

    // MARK: The dialog and Edit…

    /// The dialog's directory: the focused session's before the pane was
    /// made (noted by every intent that makes one), else home.
    @Test func theDirectoryComesFromThePaneFocusedBefore() throws {
        let (model, controller, settings, workspace) = windowFixture()
        defer {
            controller.close()
            settings.removeTestDefaults()
        }
        let actions = controller.actions
        let first = try focusedSession(model, workspace)
        model.setWorkingDirectory("/Users/me/src/app", for: first.id) // as OSC 7 reports it
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        #expect(model.focusedSessionID(in: workspace) == nil)
        actions.newSession(in: pane)
        #expect(actions.newSessionForm?.workingDirectory == "~/src/app")
        actions.endNewSessionSheet()
        #expect(NewSessionForm.prefilledDirectory(in: model, from: nil) == "~")
    }

    /// Start in the dialog: the session runs in the pane, which is focused,
    /// and the sheet goes.
    @Test func startInTheDialogStartsInThePane() throws {
        let (model, controller, settings, workspace) = windowFixture()
        defer {
            controller.close()
            settings.removeTestDefaults()
        }
        let actions = controller.actions
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        actions.newSession(in: pane)
        let form = try #require(actions.newSessionForm)
        var focused: PaneID?
        actions.focusPaneWhenShown = { focused = $0 }
        actions.startNewSession(form)
        #expect(model.pane(pane)?.isEmpty == false)
        #expect(focused == pane)
        #expect(actions.newSessionForm == nil)
        #expect(controller.window?.attachedSheet == nil)
    }

    /// Edit… opens the dialog in edit mode; Save updates the favorite and
    /// starts nothing. One sheet at a time.
    @Test func editOpensTheFormInEditModeAndSaveUpdates() throws {
        let (model, controller, settings, workspace) = windowFixture()
        defer {
            controller.close()
            settings.removeTestDefaults()
        }
        let actions = controller.actions
        let (claude, _, shell) = addFavorites(to: model)
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let chooser = NewSessionChooser(model: model, paneID: pane, actions: actions)
        chooser.edit(claude)
        let form = try #require(actions.newSessionForm)
        #expect(form.mode == .editFavorite(claude))
        #expect(form.title == "Edit Favorite")
        #expect(actions.newSessionPane == nil, "not a New Session sheet")
        chooser.edit(shell)
        #expect(actions.newSessionForm === form, "one sheet at a time")
        chooser.newSession()
        #expect(actions.newSessionForm === form)

        form.name = "Claude at work"
        #expect(form.save() == claude)
        actions.endNewSessionSheet()
        #expect(model.favorite(claude)?.name == "Claude at work")
        #expect(model.pane(pane)?.isEmpty == true, "nothing started")
        #expect(controller.window?.attachedSheet == nil)
    }

    /// Before a quit (``AppDelegate/prepareForQuit()``) the sheet goes, so
    /// AppKit's terminate is not refused; the pane stays empty, saved so,
    /// and shows its chooser again.
    @Test func aQuitEndsTheSheetAndKeepsThePane() throws {
        let (model, controller, settings, workspace) = windowFixture()
        defer {
            controller.close()
            settings.removeTestDefaults()
        }
        let actions = controller.actions
        actions.splitFocusedPane(axis: .horizontal)
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        actions.newSession(in: pane)
        #expect(controller.window?.attachedSheet != nil)
        actions.endNewSessionSheet() // what prepareForQuit does for every window
        #expect(controller.window?.attachedSheet == nil, "terminate is no longer refused")
        #expect(actions.newSessionPane == nil)
        #expect(model.pane(pane)?.isEmpty == true, "kept, and saved empty")
        #expect(model.persistedState.workspaces.first?.tabGroups.first?.tabs.first?.pane(pane)?.isEmpty == true)
    }

    /// A sheet whose pane was closed elsewhere (or whose favorite was
    /// removed in Settings) goes by itself.
    @Test func aSheetWhosePaneOrFavoriteGoesIsTakenDown() async throws {
        let (model, controller, settings, workspace) = windowFixture()
        defer {
            controller.close()
            settings.removeTestDefaults()
        }
        let actions = controller.actions
        actions.splitFocusedPane(axis: .horizontal)
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        actions.newSession(in: pane)
        #expect(actions.newSessionPane == pane)
        model.closePane(pane)
        #expect(await eventually { actions.newSessionForm == nil })
        #expect(controller.window?.attachedSheet == nil)

        let (claude, _, _) = addFavorites(to: model)
        actions.editFavorite(claude)
        #expect(actions.newSessionForm?.mode == .editFavorite(claude))
        model.removeFavorite(claude)
        #expect(await eventually { actions.newSessionForm == nil })
    }

    /// A New Session sheet whose pane's tab was dragged into another
    /// workspace (from another window's sidebar) goes; that workspace's
    /// window shows the pane's chooser. Started or closed panes go too.
    @Test func aSheetForAPaneThatLeftTheWorkspaceIsTakenDown() async throws {
        let (model, controller, settings, workspace) = windowFixture()
        defer {
            controller.close()
            settings.removeTestDefaults()
        }
        let actions = controller.actions
        actions.newTab()
        let tab = try #require(model.selectedTab(in: workspace)?.id)
        let pane = try #require(model.tab(tab)?.focusedPaneID)
        #expect(WorkspaceActions.sheetIsWanted(for: pane, in: model, workspace: workspace))
        actions.newSession(in: pane)
        #expect(actions.newSessionPane == pane)

        let other = model.newWorkspace(name: "Other")
        let otherGroup = try #require(model.workspace(other)?.selectedTabGroupID)
        model.moveTab(tab, to: otherGroup, index: 0)
        #expect(!WorkspaceActions.sheetIsWanted(for: pane, in: model, workspace: workspace))
        #expect(WorkspaceActions.sheetIsWanted(for: pane, in: model, workspace: other))
        #expect(await eventually { actions.newSessionForm == nil })
        #expect(controller.window?.attachedSheet == nil)
        #expect(model.pane(pane)?.isEmpty == true, "still empty, in the other workspace")

        model.startSession(in: pane, request: SessionRequest())
        #expect(!WorkspaceActions.sheetIsWanted(for: pane, in: model, workspace: other))
    }

    /// What a quit runs before AppKit's terminate
    /// (``AppDelegate/endSheetsForQuit(workspaceWindows:settingsWindow:)``):
    /// a New Session sheet in one window and an Edit Favorite sheet in
    /// another both end, and the panes stay empty (saved so).
    @Test func aQuitEndsEveryWindowsSheet() throws {
        let (model, first, settings, workspace) = windowFixture()
        let other = model.newWorkspace(name: "Other")
        let second = WorkspaceWindowController(model: model, workspaceID: other, registry: first.actions.registry)
        defer {
            first.close()
            second.close()
            settings.removeTestDefaults()
        }
        let (claude, _, _) = addFavorites(to: model)
        first.actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        first.actions.newSession(in: pane)
        second.actions.editFavorite(claude)
        #expect(first.window?.attachedSheet != nil)
        #expect(second.window?.attachedSheet != nil)
        #expect(second.actions.newSessionForm?.mode == .editFavorite(claude))

        AppDelegate.endSheetsForQuit(workspaceWindows: [first, second], settingsWindow: nil)
        #expect(first.window?.attachedSheet == nil, "terminate is no longer refused")
        #expect(second.window?.attachedSheet == nil)
        #expect(first.actions.newSessionForm == nil)
        #expect(second.actions.newSessionForm == nil)
        #expect(model.pane(pane)?.isEmpty == true)
        #expect(model.emptyPaneIDs(in: other).count == 1)
        #expect(model.favorite(claude)?.name == "Claude", "nothing saved")
    }

    /// No sheet while the window is closing or in a full-screen transition:
    /// New Session… and Return do nothing then.
    @Test func noSheetDuringAFullScreenTransition() throws {
        #expect(WorkspaceWindowController.canPresentSheet(isClosed: false, isClosePending: false, fullScreenTarget: nil))
        #expect(!WorkspaceWindowController.canPresentSheet(isClosed: false, isClosePending: false, fullScreenTarget: true))
        #expect(!WorkspaceWindowController.canPresentSheet(isClosed: false, isClosePending: false, fullScreenTarget: false))
        #expect(!WorkspaceWindowController.canPresentSheet(isClosed: true, isClosePending: false, fullScreenTarget: nil))
        #expect(!WorkspaceWindowController.canPresentSheet(isClosed: false, isClosePending: true, fullScreenTarget: nil))

        let (model, controller, settings, workspace) = windowFixture()
        defer {
            controller.close()
            settings.removeTestDefaults()
        }
        let actions = controller.actions
        #expect(actions.canPresentSheet(), "the window controller's check, at rest")
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        actions.canPresentSheet = { false } // as during a transition
        #expect(NewSessionChooser(model: model, paneID: pane, actions: actions).handle(.confirm))
        #expect(actions.newSessionForm == nil)
        #expect(controller.window?.attachedSheet == nil)
        actions.canPresentSheet = { true }
        actions.newSession(in: pane)
        #expect(actions.newSessionPane == pane)
        actions.endNewSessionSheet()
    }

    /// Edit… on a broken favorite from the chooser: Save is allowed (the
    /// looser ``NewSessionForm/canSave``, as in Settings), so it can be
    /// renamed while it stays broken; Start in a new session's form still
    /// needs a valid form.
    @Test func aBrokenFavoriteCanBeSavedFromTheChoosersEdit() throws {
        let (model, controller, settings, workspace) = windowFixture()
        defer {
            controller.close()
            settings.removeTestDefaults()
        }
        let actions = controller.actions
        let (_, broken, _) = addFavorites(to: model)
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        NewSessionChooser(model: model, paneID: pane, actions: actions).edit(broken)
        let form = try #require(actions.newSessionForm)
        #expect(!form.isValid, "Host removed")
        #expect(form.canConfirm)
        form.name = "Renamed"
        #expect(form.save() == broken)
        #expect(model.favorite(broken)?.name == "Renamed")
        #expect(model.favoriteProblem(try #require(model.favorite(broken))) == "Host removed", "still broken")
        actions.endNewSessionSheet()

        let newSession = NewSessionForm(model: model, mode: .newSession(pane))
        newSession.isRemote = true
        #expect(!newSession.isValid)
        #expect(!newSession.canConfirm)
        newSession.isRemote = false
        #expect(newSession.canConfirm)
    }

    /// A favorite on a host with no usable destination shows as broken
    /// in the chooser and is refused.
    @Test func aFavoriteOnAHostWithoutADestinationIsRefused() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let host = model.addHost(name: "Fresh")
        let id = model.addFavorite(Favorite(name: "Fresh", request: SessionRequest(location: .remote(host: host))))
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let chooser = NewSessionChooser(model: model, paneID: pane, actions: actions)
        #expect(chooser.problem(of: try #require(model.favorite(id))) == AppModel.unusableHostDestination)
        #expect(chooser.handle(.down) == false, "not selectable")
        #expect(chooser.start(id) == false)
        #expect(model.pane(pane)?.isEmpty == true)
    }

    // MARK: Keyboard focus

    private func key(_ keyCode: UInt16, _ characters: String, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: keyCode))
    }

    /// The empty pane itself takes keyboard focus, so the arrows, Return
    /// and Escape reach it (the Return bug of October 23, 2026 came from a
    /// pane without a terminal that did not); Return and Escape only while
    /// it is not an unfocused pane of a split; other keys do nothing.
    @Test func theEmptyPaneIsFirstResponderAndTakesTheKeys() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let (_, _, shell) = addFavorites(to: model)
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let view = EmptyPaneView(
            chooser: NewSessionChooser(model: model, paneID: pane, actions: actions), settings: settings)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window.contentView = content
        content.addSubview(view)

        #expect(view.acceptsFirstResponder)
        view.focusPane()
        #expect(window.firstResponder === view)

        view.keyDown(with: try key(125, "\u{F701}", in: window)) // ↓
        view.keyDown(with: try key(125, "\u{F701}", in: window))
        #expect(view.chooser.selectedFavoriteID == shell)
        view.keyDown(with: try key(0, "a", in: window))
        view.keyDown(with: try key(48, "\t", in: window))

        view.focusStyle = .unfocused
        #expect(!view.chooser.isKeyTarget)
        view.keyDown(with: try key(36, "\r", in: window))
        view.keyDown(with: try key(53, "\u{1b}", in: window))
        #expect(model.pane(pane)?.isEmpty == true, "an unfocused pane ignores Return and Escape")

        view.focusStyle = .focused
        view.keyDown(with: try key(76, "\u{3}", in: window)) // keypad Enter
        #expect(model.pane(pane)?.sessionID.flatMap { model.session($0) }?.workingDirectory == "/tmp")
    }

    /// In a real window, a new tab's empty pane shows the chooser and holds
    /// keyboard focus; once a favorite starts, the terminal replaces it and
    /// takes focus; nothing opens a sheet by itself.
    @Test func aNewTabShowsTheChooserWithFocusAndNoSheet() async throws {
        let (model, controller, settings, workspace) = windowFixture()
        defer {
            controller.close()
            settings.removeTestDefaults()
        }
        let (claude, _, _) = addFavorites(to: model)
        let window = try #require(controller.window)
        window.contentViewController?.view.layoutSubtreeIfNeeded()
        controller.actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        #expect(await eventually { (window.firstResponder as? EmptyPaneView)?.chooser.paneID == pane })
        #expect(window.attachedSheet == nil, "the dialog opens only on request")

        let chooser = try #require((window.firstResponder as? EmptyPaneView)?.chooser)
        chooser.start(claude)
        #expect(await eventually {
            guard let responder = window.firstResponder as? NSView else { return false }
            return !(responder is EmptyPaneView) && responder.enclosingPaneView != nil
        })
    }

    /// Return and Escape held down do nothing (one action per press); the
    /// arrows may repeat.
    @Test func returnAndEscapeRepeatsAreIgnored() throws {
        let (model, actions, settings, workspace) = fixture()
        defer { settings.removeTestDefaults() }
        let (claude, _, shell) = addFavorites(to: model)
        actions.newTab()
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let view = EmptyPaneView(
            chooser: NewSessionChooser(model: model, paneID: pane, actions: actions), settings: settings)
        func repeated(_ keyCode: UInt16, _ characters: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: true,
                keyCode: keyCode))
        }
        view.keyDown(with: try repeated(125, "\u{F701}"))
        #expect(view.chooser.selectedFavoriteID == claude, "an arrow repeat moves")
        view.keyDown(with: try repeated(125, "\u{F701}"))
        #expect(view.chooser.selectedFavoriteID == shell)
        view.keyDown(with: try repeated(36, "\r"))
        view.keyDown(with: try repeated(76, "\u{3}"))
        view.keyDown(with: try repeated(53, "\u{1b}"))
        #expect(model.pane(pane)?.isEmpty == true, "neither started nor closed")
    }

    /// The empty pane in a real window (never ordered on screen).
    private func emptyPaneView(for pane: PaneID, in window: NSWindow) -> EmptyPaneView? {
        func find(_ view: NSView) -> EmptyPaneView? {
            if let empty = view as? EmptyPaneView, empty.chooser.paneID == pane { return empty }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    /// A split of a terminal and an empty pane: the focus styles count both
    /// leaves (an ended pane beside a focused empty pane is unfocused, so
    /// its Respawn does not take Return), and the empty pane taking
    /// keyboard focus (a click on it) focuses it in the model.
    @Test func anEmptyPaneInASplitTakesFocusAndStyles() async throws {
        let (model, controller, settings, workspace) = windowFixture()
        defer {
            controller.close()
            settings.removeTestDefaults()
        }
        let window = try #require(controller.window)
        window.contentViewController?.view.layoutSubtreeIfNeeded()
        let first = try focusedSession(model, workspace)
        let firstPane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        controller.actions.splitFocusedPane(axis: .horizontal)
        let empty = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        #expect(await eventually { emptyPaneView(for: empty, in: window) != nil })
        let emptyView = try #require(emptyPaneView(for: empty, in: window))
        let terminal = try #require(controller.actions.registry.paneView(for: first.id))
        #expect(await eventually { window.firstResponder === emptyView })
        #expect(emptyView.focusStyle == .focused)
        #expect(terminal.focusStyle == .unfocused, "a split of two, though only one has a session")

        // The terminal's session ends: its Respawn must not take Return
        // while the empty pane is the focused one.
        terminal.controller.markEnded(exitCode: .signaled(9))
        terminal.keyDown(with: try key(36, "\r", in: window))
        try await Task.sleep(for: .milliseconds(150))
        #expect(terminal.controller.session.id == first.id, "not respawned")

        // Focus the terminal pane, then click (make first responder) the
        // empty one: the model follows.
        model.focus(pane: firstPane)
        #expect(await eventually { emptyView.focusStyle == .unfocused && terminal.focusStyle == .focused })
        #expect(!emptyView.chooser.isKeyTarget)
        window.makeFirstResponder(emptyView)
        #expect(model.selectedTab(in: workspace)?.focusedPaneID == empty)
        #expect(await eventually { emptyView.focusStyle == .focused })
        #expect(emptyView.chooser.isKeyTarget)
    }

    /// A display change that does not move the model's focus (a divider
    /// moved) leaves keyboard focus where it is, in the sidebar say: the
    /// empty focused pane does not take it.
    @Test func theChooserDoesNotStealFocusFromTheSidebar() async throws {
        let (model, controller, settings, workspace) = windowFixture()
        defer {
            controller.close()
            settings.removeTestDefaults()
        }
        let window = try #require(controller.window)
        window.contentViewController?.view.layoutSubtreeIfNeeded()
        controller.actions.splitFocusedPane(axis: .horizontal)
        let empty = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        #expect(await eventually { window.firstResponder === emptyPaneView(for: empty, in: window) })

        // A text field in the sidebar takes keyboard focus.
        let split = try #require(window.contentViewController as? NSSplitViewController)
        let sidebar = try #require(split.splitViewItems.first?.viewController.view)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        sidebar.addSubview(field)
        #expect(window.makeFirstResponder(field))
        #expect(field.currentEditor() != nil)

        let before = try #require(model.selectedTab(in: workspace)?.layout)
        model.resizeFocusedPane(toward: .left, by: 0.1, in: workspace)
        #expect(model.selectedTab(in: workspace)?.layout != before, "the display changed")
        try await Task.sleep(for: .milliseconds(200))
        #expect(field.currentEditor() != nil, "focus stayed in the sidebar")
        #expect(!(window.firstResponder is EmptyPaneView))
        #expect(model.selectedTab(in: workspace)?.focusedPaneID == empty)
    }

    /// The host removal question counts the favorites it breaks.
    @Test func hostRemovalMentionsBrokenFavorites() {
        #expect(!HostsSettingsView.removalMessage(sessions: 1, favorites: 0).contains("favorite"))
        #expect(HostsSettingsView.removalMessage(sessions: 2, favorites: 1).hasSuffix(
            "A favorite uses this host and won’t start until you edit it."))
        #expect(HostsSettingsView.removalMessage(sessions: 1, favorites: 3).hasSuffix(
            "3 favorites use this host and won’t start until you edit them."))
    }
}

private extension NSView {
    /// The ``PaneView`` this view is in, if any.
    var enclosingPaneView: PaneView? {
        var view: NSView? = self
        while let current = view {
            if let pane = current as? PaneView { return pane }
            view = current.superview
        }
        return nil
    }
}
