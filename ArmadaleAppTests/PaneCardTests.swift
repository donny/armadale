import AppKit
import ArmadaleCore
import ArmadaleSessions
import TerminalSurface
import Testing

/// Pane cards (DESIGN §8, "Pane cards"): the card geometry and borders
/// (``PaneCardStyle``), the gutter and gaps, and the header of a pane with a
/// session and of an empty pane, with the views in a window: its title, its
/// directory, its attention, and the "…" button and right-click reaching
/// the pane menu.
@Suite("Pane cards")
@MainActor
struct PaneCardTests {
    // MARK: Style

    @Test func theNumbersAgreedWithTheOwner() {
        #expect(PaneCardStyle.gutter == 8)
        #expect(PaneCardStyle.gutter == TabBarStyle.margin, "the tab bar's margin")
        #expect(PaneCardStyle.gap == 8)
        #expect(PaneCardStyle.cornerRadius == 10)
        #expect(PaneCardStyle.headerHeight == 28)
        #expect(PaneCardStyle.headerHeight == TabBarStyle.trackHeight, "the tab bar's track height")
        #expect(PaneCardStyle.headerSpacing == 4)
        #expect(PaneCardStyle.padding >= PaneCardStyle.cornerRadius, "no corner cell is clipped")
    }

    @Test func theTerminalSitsBelowTheHeaderInsideThePadding() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        #expect(PaneCardStyle.terminalFrame(in: bounds) == NSRect(x: 10, y: 10, width: 380, height: 258))
        #expect(PaneCardStyle.headerFrame(in: bounds) == NSRect(x: 0, y: 272, width: 400, height: 28))
        #expect(PaneCardStyle.contentFrame(in: bounds) == NSRect(x: 0, y: 0, width: 400, height: 272))
        // The header and the terminal never overlap: header clicks never reach the program.
        #expect(PaneCardStyle.terminalFrame(in: bounds).maxY + PaneCardStyle.headerSpacing
            == PaneCardStyle.headerFrame(in: bounds).minY)

        let tiny = NSRect(x: 0, y: 0, width: 12, height: 20)
        let terminal = PaneCardStyle.terminalFrame(in: tiny)
        #expect(terminal.width == 0 && terminal.height == 0, "never negative")
        #expect(PaneCardStyle.headerFrame(in: tiny) == NSRect(x: 0, y: 0, width: 12, height: 20))
        #expect(PaneCardStyle.contentFrame(in: tiny).height == 0)
    }

    @Test func theMenuOpensUnderTheEllipsisButton() {
        let size = NSSize(width: 300, height: PaneCardStyle.headerHeight)
        let origin = PaneCardStyle.menuOrigin(inHeaderOf: size)
        #expect(origin.x == 300 - PaneCardStyle.headerTrailing - PaneCardStyle.headerButtonSize.width)
        #expect(origin.y > (PaneCardStyle.headerHeight + PaneCardStyle.headerButtonSize.height) / 2,
                "below the button (flipped coordinates)")
        #expect(origin.y <= PaneCardStyle.headerHeight)

        // A 105 pt menu with room in the window opens at the button's leading edge…
        let buttonLeading = 300 - PaneCardStyle.headerTrailing - PaneCardStyle.headerButtonSize.width
        let roomy = PaneCardStyle.menuOrigin(inHeaderOf: size, menuWidth: 105, roomRightOfHeader: 300)
        #expect(roomy.x == buttonLeading)
        #expect(PaneCardStyle.menuOrigin(inHeaderOf: size, menuWidth: 105).x == buttonLeading, "no window: as now")
        // …and, on the rightmost pane (only the 8 pt gutter to its right),
        // ends at the button's trailing edge instead of running past the window.
        let rightmost = PaneCardStyle.menuOrigin(inHeaderOf: size, menuWidth: 105, roomRightOfHeader: 8)
        #expect(rightmost.x == 300 - PaneCardStyle.headerTrailing - 105)
        #expect(rightmost.y == origin.y)
        // Exactly fitting still opens at the leading edge.
        let room = PaneCardStyle.headerTrailing + PaneCardStyle.headerButtonSize.width
        #expect(PaneCardStyle.menuOrigin(inHeaderOf: size, menuWidth: room + 8, roomRightOfHeader: 8).x == buttonLeading)
        #expect(PaneCardStyle.menuOrigin(inHeaderOf: size, menuWidth: room + 9, roomRightOfHeader: 8).x < buttonLeading)
    }

    @Test func theSplitButtonsSitLeftOfTheEllipsisButton() {
        let size = NSSize(width: 300, height: PaneCardStyle.headerHeight)
        #expect(PaneCardStyle.headerButtonSize == NSSize(width: 24, height: 20))
        let menu = PaneCardStyle.headerButtonFrame(.menu, inHeaderOf: size)
        let down = PaneCardStyle.headerButtonFrame(.splitDown, inHeaderOf: size)
        let right = PaneCardStyle.headerButtonFrame(.splitRight, inHeaderOf: size)
        #expect(menu == NSRect(x: 272, y: 4, width: 24, height: 20), "4 pt from the trailing edge, centred")
        #expect(down == NSRect(x: 248, y: 4, width: 24, height: 20), "immediately left of …")
        #expect(right == NSRect(x: 224, y: 4, width: 24, height: 20), "Split Right first")
        #expect(PaneCardStyle.headerButtonsWidth(showsSplitButtons: true) == 72)
        #expect(PaneCardStyle.headerButtonsWidth(showsSplitButtons: false) == 24)
        #expect(PaneCardStyle.headerButtonsWidth(showsSplitButtons: true) == menu.maxX - right.minX)
        // The menu still opens under "…".
        #expect(PaneCardStyle.menuOrigin(inHeaderOf: size).x == menu.minX)
        #expect(PaneCardStyle.menuOrigin(inHeaderOf: size).y == menu.maxY + 2)
    }

    @Test func theTextGetsWhatTheButtonsLeaveAndANarrowHeaderShowsEllipsisAlone() {
        // 10 leading, a 12 pt glyph and 6, 6 + 6 around the flexible space, the buttons, 4 trailing.
        #expect(PaneCardStyle.headerTextSpace(headerWidth: 400, hasGlyph: true, showsSplitButtons: true) == 284)
        #expect(PaneCardStyle.headerTextSpace(headerWidth: 400, hasGlyph: false, showsSplitButtons: true) == 302)
        #expect(PaneCardStyle.headerTextSpace(headerWidth: 400, hasGlyph: true, showsSplitButtons: false) == 332)
        #expect(PaneCardStyle.headerTextSpace(headerWidth: 20, hasGlyph: true, showsSplitButtons: true) == 0)
        // The split buttons show while the title keeps 40 pt beside them.
        #expect(PaneCardStyle.showsSplitButtons(headerWidth: 400))
        #expect(PaneCardStyle.showsSplitButtons(headerWidth: 156))
        #expect(!PaneCardStyle.showsSplitButtons(headerWidth: 155.5))
        #expect(!PaneCardStyle.showsSplitButtons(headerWidth: 90), "a 90 pt pane: the title and … only")
        #expect(PaneCardStyle.showsSplitButtons(headerWidth: 165))
    }

    @Test func theTitleAndTheDirectoryShareTheHeader() {
        typealias W = (title: CGFloat, directory: CGFloat?)
        func widths(_ available: CGFloat, _ title: CGFloat, _ directory: CGFloat?) -> W {
            PaneCardStyle.headerTextWidths(available: available, title: title, directory: directory)
        }
        func same(_ a: W, _ b: W) -> Bool { a.title == b.title && a.directory == b.directory }
        // Both whole when they fit (6 pt apart).
        #expect(same(widths(300, 100, 80), (100, 80)))
        #expect(same(widths(186, 100, 80), (100, 80)))
        // A short title stays whole; the directory is truncated to what is left.
        #expect(same(widths(300, 60, 400), (60, 234)))
        // A long title is truncated in the middle so the directory keeps 40 % (a 400 pt
        // header: 160 pt), or what it needs when that is less.
        #expect(same(widths(400, 640, 300), (234, 160)))
        #expect(same(widths(400, 640, 50), (344, 50)))
        // Below 100 pt the directory still keeps 40 pt…
        #expect(same(widths(90, 300, 200), (44, 40)))
        // …until the title would go under 40 pt: then the title alone.
        #expect(same(widths(85, 300, 200), (85, nil)))
        #expect(same(widths(85, 30, 200), (30, 49)), "a short title leaves the directory the rest")
        // No directory: the title alone, truncated to the width.
        #expect(same(widths(200, 300, nil), (200, nil)))
        #expect(same(widths(200, 120, nil), (120, nil)))
        #expect(same(widths(-5, 120, 40), (0, nil)), "never negative")
    }

    private func components(_ color: NSColor, in appearance: NSAppearance.Name) -> [CGFloat] {
        var result: [CGFloat] = []
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let rgb = color.usingColorSpace(.sRGB)!
            result = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
        }
        return result
    }

    @Test func everyCardHasAHairlineAndTheFocusedOneOfSeveralTheAccentBorder() {
        let darkForeground = TerminalColor(hex: 0x101010) // a light theme's text
        let lightForeground = TerminalColor(hex: 0xf0f0f0) // a dark theme's text
        for style in [PaneView.FocusStyle.alone, .unfocused] {
            let border = PaneCardStyle.border(for: style, foreground: darkForeground)
            #expect(border.kind == .hairline)
            #expect(border.width == 0.5)
            let c = components(border.color, in: .aqua)
            #expect(abs(c[0] - 0x10 / 255) < 0.01 && abs(c[3] - 0.12) < 0.001, "the theme's foreground at 12 %")
        }
        let onDark = components(PaneCardStyle.border(for: .alone, foreground: lightForeground).color, in: .darkAqua)
        #expect(abs(onDark[0] - 0xf0 / 255) < 0.01 && abs(onDark[3] - 0.12) < 0.001, "a light edge on a dark card")

        let focused = PaneCardStyle.border(for: .focused, foreground: darkForeground)
        #expect(focused.kind == .focus)
        #expect(focused.width == 1.5)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            #expect(abs(components(focused.color, in: appearance)[3] - 0.55) < 0.001, "the accent at 55 % in \(appearance)")
        }
    }

    // MARK: Header model

    @Test func theTitleIsTheSessionsElseTheProfilesAndTheDirectoryIsShownOnce() {
        #expect(PaneHeaderModel.title(sessionTitle: "vim notes.md", profileName: "Shell") == "vim notes.md")
        #expect(PaneHeaderModel.title(sessionTitle: "", profileName: "Claude Code") == "Claude Code")
        #expect(PaneHeaderModel.title(sessionTitle: "", profileName: nil) == "Shell")

        var model = PaneHeaderModel(status: .running, title: "build", directory: "~/src")
        #expect(model.shownDirectory == "~/src")
        model.directory = ""
        #expect(model.shownDirectory == nil, "blank: nothing")
        model.directory = nil
        #expect(model.shownDirectory == nil, "unknown: nothing")
        model = PaneHeaderModel(status: .running, title: "~/src", directory: "~/src")
        #expect(model.shownDirectory == nil, "a shell titled with its directory reads once, not \"~/src ~/src\"")

        #expect(PaneHeaderModel.newSession.status == nil, "an empty pane has no glyph")
        #expect(PaneHeaderModel.newSession.title == "New Session")
    }

    // MARK: Gutter and gaps

    @Test func thePaneAreaKeepsTheGutterAndSplitsAreAGapApart() {
        let container = PaneContainerView(frame: .zero)
        #expect(container.splitTree.frame.width >= 0, "a zero-sized pane area gives no negative frame")
        container.setFrameSize(NSSize(width: 800, height: 500))
        #expect(container.splitTree.frame == NSRect(x: 8, y: 8, width: 784, height: 484))
        container.setFrameSize(NSSize(width: 600, height: 300))
        #expect(container.splitTree.frame == NSRect(x: 8, y: 8, width: 584, height: 284))

        let split = PaneSplitView(nodeID: SplitNodeID(raw: 1), axis: .horizontal)
        split.frame = NSRect(x: 0, y: 0, width: 808, height: 400)
        #expect(split.dividerThickness == 8)
        let (first, second) = split.childFrames(ratio: 0.5)
        #expect(first == NSRect(x: 0, y: 0, width: 400, height: 400))
        #expect(second == NSRect(x: 408, y: 0, width: 400, height: 400), "8 pt apart")
    }

    // MARK: Views in a window

    private func makeRegistry(settings: AppSettings, home: String = "/") -> (AppModel, SessionRegistry, WorkspaceID) {
        _ = NSApplication.shared
        let model = AppModel(defaultWorkingDirectory: home)
        let workspace = model.newWorkspace(name: "W")
        model.fillEmptyPanes()
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: [],
            settings: settings)
        return (model, registry, workspace)
    }

    private func window(showing view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test func aPanesHeaderFollowsTheSessionsTitleDirectoryAndAttention() async throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        settings.preferences.followsSystemAppearance = false
        settings.preferences.themeID = "builtin.nord"
        let (model, registry, workspace) = makeRegistry(settings: settings, home: "/Users/someone")
        let attention = AttentionCenter(model: model, preferences: settings.preferences, notifications: nil)
        attention.isAppActive = true
        attention.keyWorkspaceID = workspace
        registry.attention = attention
        let paneID = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let sessionID = try #require(model.pane(paneID)?.sessionID)
        let session = try #require(model.session(sessionID))
        let profileName = try #require(model.profile(session.profileID)?.name)
        let pane = try #require(registry.paneView(for: sessionID))
        let window = window(showing: pane)
        defer { window.close() }

        #expect(pane.header.model.title == profileName, "no program title yet: the profile's name")
        #expect(pane.header.model.status != nil, "a session's pane has a glyph")
        #expect(pane.header.model.foreground == ThemeCatalog.nord.foreground, "drawn in the theme's foreground")
        #expect(pane.header.frame == PaneCardStyle.headerFrame(in: pane.bounds), "at the top of the card")

        model.setTitle("make test", for: sessionID)
        #expect(await eventually { pane.header.model.title == "make test" }, "the program's title wins")
        // The start directory is not shown: a shell without OSC 7 may have
        // left it long ago; only a reported directory is.
        #expect(pane.header.model.directory == nil, "unknown until reported")
        model.setWorkingDirectory("/Users/someone/elsewhere", for: sessionID)
        try await Task.sleep(for: .milliseconds(100))
        #expect(pane.header.model.directory == nil, "a directory the program never reported stays unknown")
        registry.sessionController(pane.controller, didChangeDirectory: "/Users/someone/src/armadale")
        #expect(await eventually { pane.header.model.directory == "~/src/armadale" }, "reported (OSC 7): ~-abbreviated")
        #expect(pane.header.model.needsAttention == false)

        // Not looked at (another workspace's window is key): a bell is attention.
        attention.keyWorkspaceID = nil
        attention.signal(.bell, from: sessionID)
        #expect(await eventually { pane.header.model.needsAttention && pane.header.model.status == .attention })
        // Looked at again: cleared, as in the tab bar.
        attention.keyWorkspaceID = workspace
        #expect(await eventually { !pane.header.model.needsAttention && pane.header.model.status != .attention })

        // The card: rounded, clipped, hairline alone, accent focused.
        #expect(pane.layer?.cornerRadius == PaneCardStyle.cornerRadius)
        #expect(pane.layer?.masksToBounds == true)
        #expect(pane.focusOverlay.layer?.borderWidth == PaneCardStyle.hairlineWidth)
        pane.focusStyle = .focused
        #expect(pane.focusOverlay.layer?.borderWidth == PaneCardStyle.focusWidth)
        pane.focusStyle = .unfocused
        #expect(pane.focusOverlay.layer?.borderWidth == PaneCardStyle.hairlineWidth)
    }

    @Test func theEllipsisButtonAndARightClickOpenThePaneMenuAndFocusThePane() throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let (model, registry, workspace) = makeRegistry(settings: settings)
        let paneID = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let pane = try #require(model.pane(paneID)?.sessionID.flatMap { registry.paneView(for: $0) })
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let other = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        holder.addSubview(other)
        pane.frame = NSRect(x: 20, y: 0, width: 600, height: 400)
        holder.addSubview(pane)
        let window = window(showing: holder)
        defer { window.close() }

        var presented: [(NSMenu, NSPoint)] = []
        pane.header.presentMenu = { menu, point, _ in presented.append((menu, point)) }
        window.makeFirstResponder(other)
        pane.header.openMenuFromButton()
        let (menu, point) = try #require(presented.first)
        #expect(menu.items.contains { $0.identifier == PaneMenu.themeItemIdentifier }, "the pane menu")
        // The pane ends 20 pt from the window's right edge: too little for
        // the menu, which is right-aligned to the button.
        let expected = PaneCardStyle.menuOrigin(
            inHeaderOf: pane.header.bounds.size, menuWidth: menu.size.width, roomRightOfHeader: 20)
        #expect(point.x == expected.x)
        #expect(point.x == pane.header.bounds.width - PaneCardStyle.headerTrailing - menu.size.width)
        #expect(window.firstResponder === pane.controller.surface.view, "the pane is focused first")

        // The menu acts on this pane.
        let theme = try #require(menu.items.first { $0.identifier == PaneMenu.themeItemIdentifier }?.submenu)
        try #require(theme.items.first { $0.title == "Dracula" } as? ActionMenuItem).handler()
        #expect(model.pane(paneID)?.themeID == "builtin.dracula")

        var contextMenus: [NSMenu] = []
        pane.header.presentContextMenu = { menu, _, _ in contextMenus.append(menu) }
        window.makeFirstResponder(other)
        let location = pane.header.convert(NSPoint(x: 40, y: 10), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        pane.header.rightMouseDown(with: event)
        #expect(contextMenus.count == 1)
        #expect(contextMenus.first?.items.contains { $0.identifier == PaneMenu.themeItemIdentifier } == true)
        #expect(window.firstResponder === pane.controller.surface.view)

        // A click on the header lands on the header, never on the terminal below it.
        let headerPoint = holder.convert(NSPoint(x: 100, y: pane.header.bounds.midY), from: pane.header)
        let hit = try #require(holder.hitTest(headerPoint))
        #expect(hit.isDescendant(of: pane.header))
        let gridPoint = holder.convert(NSPoint(x: 100, y: 100), from: pane)
        #expect(holder.hitTest(gridPoint)?.isDescendant(of: pane.controller.surface.view) == true)
    }

    /// A split button focuses its pane first, then splits that pane, not
    /// the one focused before; through the window's actions, as ⌘D.
    @Test func theSplitButtonsSplitTheirOwnPane() throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let (model, registry, workspace) = makeRegistry(settings: settings)
        let actions = WorkspaceActions(model: model, registry: registry, workspaceID: workspace)
        registry.actionsOfWorkspace = { $0 == workspace ? actions : nil }
        let first = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let second = try #require(model.splitPane(first, axis: .vertical))
        model.fillEmptyPanes()
        let firstSession = try #require(model.pane(first)?.sessionID)
        let pane = try #require(registry.paneView(for: firstSession))
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let other = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        holder.addSubview(other)
        pane.frame = NSRect(x: 20, y: 0, width: 600, height: 400)
        holder.addSubview(pane)
        let window = window(showing: holder)
        defer { window.close() }
        #expect(pane.header.showsSplitButtons)
        #expect(model.selectedTab(in: workspace)?.focusedPaneID == second)

        var focusedFirst = false
        let focus = pane.header.focusPane
        pane.header.focusPane = {
            focus()
            focusedFirst = model.selectedTab(in: workspace)?.layout.leaves().count == 2
        }
        window.makeFirstResponder(other)
        pane.header.splitFromButton(.horizontal)
        #expect(focusedFirst, "the pane is focused before it is split")
        #expect(window.firstResponder === pane.controller.surface.view)
        let tab = try #require(model.selectedTab(in: workspace))
        let right = try #require(tab.layout.neighbor(of: first, direction: .right), "Split Right: right of this pane")
        #expect(right != second)
        #expect(tab.focusedPaneID == right, "the new pane is focused")
        #expect(model.pane(right)?.isEmpty == true, "and empty: it shows the chooser")
        #expect(actions.lastFocusedSessionID == firstSession, "the dialog's directory comes from the split pane")

        pane.header.splitFromButton(.vertical)
        let below = try #require(model.selectedTab(in: workspace)?.layout.neighbor(of: first, direction: .down))
        #expect(below != second && below != right, "Split Down: below this pane")
    }

    @Test func aNarrowHeaderShowsTheEllipsisButtonAlone() throws {
        let header = PaneHeaderHostingView.make(model: .newSession)
        header.frame = NSRect(x: 0, y: 0, width: 400, height: PaneCardStyle.headerHeight)
        #expect(header.showsSplitButtons)
        header.setFrameSize(NSSize(width: 120, height: PaneCardStyle.headerHeight))
        #expect(!header.showsSplitButtons)
        header.setFrameSize(NSSize(width: 200, height: PaneCardStyle.headerHeight))
        #expect(header.showsSplitButtons)
        // A new model keeps the buttons' state and closures.
        var split: [ArmadaleCore.Axis] = []
        header.splitPane = { split.append($0) }
        header.model = PaneHeaderModel(status: .running, title: "build", directory: nil)
        header.setFrameSize(NSSize(width: 100, height: PaneCardStyle.headerHeight))
        header.model = .newSession
        #expect(!header.showsSplitButtons)
        header.rootView.split(.vertical)
        #expect(split == [.vertical], "the view's split button reaches the pane's split")
    }

    @Test func anEmptyPanesHeaderSaysNewSessionAndOpensItsMenu() throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        settings.preferences.followsSystemAppearance = false
        settings.preferences.themeID = "builtin.nord"
        let (model, registry, workspace) = makeRegistry(settings: settings)
        let actions = WorkspaceActions(model: model, registry: registry, workspaceID: workspace)
        actions.newTab()
        let paneID = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        #expect(model.pane(paneID)?.isEmpty == true)
        let view = EmptyPaneView(
            chooser: NewSessionChooser(model: model, paneID: paneID, actions: actions), settings: settings,
            theme: .pane(paneID, in: model))
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let other = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        holder.addSubview(other)
        view.frame = NSRect(x: 20, y: 0, width: 600, height: 400)
        holder.addSubview(view)
        let window = window(showing: holder)
        defer { window.close() }

        #expect(view.header.model.title == "New Session")
        #expect(view.header.model.status == nil, "no glyph")
        #expect(view.header.model.foreground == ThemeCatalog.nord.foreground)

        var presented: [NSMenu] = []
        view.header.presentMenu = { menu, _, _ in presented.append(menu) }
        window.makeFirstResponder(other)
        view.header.openMenuFromButton()
        #expect(presented.first?.items.contains { $0.identifier == PaneMenu.themeItemIdentifier } == true)
        #expect(window.firstResponder === view, "the empty pane is focused first")

        // Its split buttons split it.
        window.makeFirstResponder(other)
        view.header.splitFromButton(.vertical)
        #expect(window.firstResponder === view, "the empty pane is focused first")
        let below = try #require(model.selectedTab(in: workspace)?.layout.neighbor(of: paneID, direction: .down))
        #expect(model.selectedTab(in: workspace)?.focusedPaneID == below)
    }
}

extension PaneCardTests {
    /// The pane views own their header, its closures and an observation
    /// loop for it: none of them may keep the view alive.
    @Test func paneViewsAreReleasedWithTheirHeaders() async throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let (model, registry, workspace) = makeRegistry(settings: settings)
        let paneID = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let sessionID = try #require(model.pane(paneID)?.sessionID)
        let actions = WorkspaceActions(model: model, registry: registry, workspaceID: workspace)
        actions.newTab()
        let emptyID = try #require(model.selectedTab(in: workspace)?.focusedPaneID)

        weak var weakPane: PaneView?
        weak var weakHeader: PaneHeaderHostingView?
        weak var weakEmpty: EmptyPaneView?
        weak var weakEmptyHeader: PaneHeaderHostingView?
        do {
            let pane = try #require(registry.paneView(for: sessionID))
            let empty = EmptyPaneView(
                chooser: NewSessionChooser(model: model, paneID: emptyID, actions: actions), settings: settings,
                theme: .pane(emptyID, in: model))
            let holder = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
            holder.addSubview(pane)
            holder.addSubview(empty)
            let window = window(showing: holder)
            weakPane = pane
            weakHeader = pane.header
            weakEmpty = empty
            weakEmptyHeader = empty.header
            // Exercise the closures and the observation loop once.
            pane.header.presentMenu = { _, _, _ in }
            pane.header.openMenuFromButton()
            empty.header.presentMenu = { _, _, _ in }
            empty.header.openMenuFromButton()
            pane.header.splitFromButton(.horizontal)
            empty.header.splitFromButton(.vertical)
            model.setTitle("busy", for: sessionID)
            #expect(await eventually { pane.header.model.title == "busy" })
            empty.removeFromSuperview()
            window.contentView = nil
            window.close()
        }
        // The session leaves the model: the registry drops its pane view.
        registry.close(sessionID)
        #expect(await eventually { weakEmpty == nil && weakEmptyHeader == nil }, "EmptyPaneView released")
        #expect(await eventually { weakPane == nil && weakHeader == nil }, "PaneView released")
    }
}

/// A view that can hold keyboard focus, to move it away from a pane.
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
