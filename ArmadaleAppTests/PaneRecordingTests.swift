import AppKit
import ArmadaleCore
import ArmadaleSessions
import Foundation
@testable import SwiftTermSurface
import TerminalSurface
import Testing

/// Recording a pane, the app's part (DESIGN §8, "Recording a pane"): the
/// pane menu's item, the save sheet and its end at a quit, the header's
/// controls, the tab's dot, the suggested file name, and playback of a
/// recording against the pane it was made of.
@Suite("Recording a pane in the app")
@MainActor
struct PaneRecordingTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<120 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func outline(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.isEnabled ? "" : " (off)") }
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "armadale-app-recording-\(UUID().uuidString).cast")
    }

    /// A model with one workspace whose pane has a session, and a registry
    /// over a backend whose clients the test feeds.
    private func makeRegistry(settings: AppSettings) -> (AppModel, SessionRegistry, WorkspaceID, LaunchTestBackend) {
        _ = NSApplication.shared
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        model.fillEmptyPanes()
        let backend = LaunchTestBackend(alive: [])
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(backend: backend, makeOutputFilter: { IdentityOutputFilter() }, isPersistent: true),
            restoredSessionIDs: [],
            settings: settings)
        return (model, registry, workspace, backend)
    }

    // MARK: The menu

    @Test func theMenuItemReadsRecordPaneOrStopRecording() throws {
        func make(
            _ recording: PaneMenu.RecordingItem?, record: @escaping @MainActor () -> Void = {},
            stop: @escaping @MainActor () -> Void = {}
        )
            -> NSMenu {
            PaneMenu.make(
                PaneMenu.Inputs(
                    themeID: nil, builtInThemes: ThemeCatalog.builtIns, userThemes: [], showsSaveAsFavorite: true,
                    recording: recording),
                actions: PaneMenu.Actions(
                    splitRight: {}, splitDown: {}, chooseTheme: { _ in }, record: record, stopRecording: stop))
        }
        var recorded = 0, stopped = 0
        let live = make(.record(isEnabled: true), record: { recorded += 1 })
        #expect(outline(live) == ["Split Right", "Split Down", "—", "Save as Favorite…", "Record Pane…", "—", "Theme"])
        let item = try #require(live.items.first { $0.identifier == PaneMenu.recordItemIdentifier } as? ActionMenuItem)
        #expect(item.keyEquivalent.isEmpty, "no shortcut")
        item.handler()
        #expect(recorded == 1)
        #expect(outline(make(.record(isEnabled: false))).contains("Record Pane… (off)"))
        let recording = make(.stop, stop: { stopped += 1 })
        #expect(outline(recording) == ["Split Right", "Split Down", "—", "Save as Favorite…", "Stop Recording", "—", "Theme"])
        try #require(recording.items.first { $0.identifier == PaneMenu.recordItemIdentifier } as? ActionMenuItem).handler()
        #expect(stopped == 1)
        #expect(!outline(make(nil)).contains { $0.hasPrefix("Record") || $0.hasPrefix("Stop") })
    }

    /// The application's Pane menu has no such item: the shortcut table is
    /// unchanged.
    @Test func theApplicationsMenusHaveNoRecordingItem() {
        let menu = MainMenu.make(installsSpecialMenus: false)
        func titles(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) }
        }
        #expect(!titles(menu).contains { $0.contains("Record") })
    }

    /// A terminal pane's menu: Record Pane… is off until the session is
    /// attached, opens the window's save sheet, which a quit takes down;
    /// a recording pane's menu reads Stop Recording; an empty pane's menu
    /// has neither.
    @Test func aTerminalPanesMenuRecordsAndAQuitEndsTheSaveSheet() async throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let (model, registry, workspace, _) = makeRegistry(settings: settings)
        let window = WorkspaceWindowController(model: model, workspaceID: workspace, registry: registry)
        defer { window.close() }
        registry.actionsOfWorkspace = { [weak window] id in id == workspace ? window?.actions : nil }
        let paneID = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let session = try #require(model.pane(paneID)?.sessionID)
        let view = try #require(registry.paneView(for: session))
        func recordItem() -> NSMenuItem? { view.paneMenu().items.first { $0.identifier == PaneMenu.recordItemIdentifier } }

        #expect(recordItem()?.title == "Record Pane…")
        #expect(recordItem()?.isEnabled == false, "not attached: nothing to record")
        await view.controller.start(.create)
        #expect(view.controller.state == .attached)
        #expect(recordItem()?.isEnabled == true)

        let log = PanelLog()
        window.actions.recordPanelPresenter = log.presenter
        try #require(recordItem() as? ActionMenuItem).handler()
        let sheet = try #require(window.actions.recordSheet)
        #expect(log.panels.count == 1 && log.panels.first?.panel === sheet.panel, "put up on the window")
        #expect(sheet.panel.nameFieldStringValue.hasSuffix(".cast"))
        #expect(sheet.panel.nameFieldStringValue.hasPrefix(registry.displayName(of: view.controller.session) + " "))
        #expect(sheet.panel.allowedContentTypes == [RecordingFileName.contentType])
        AppDelegate.endSheetsForQuit(workspaceWindows: [window], settingsWindow: nil)
        #expect(log.dismissedPanels == 1, "taken down before terminate")
        #expect(window.actions.recordSheet == nil)
        log.panels.first?.completion(.cancel)
        #expect(!view.controller.isRecording, "nothing is recorded")

        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try registry.startRecording(session: session, to: url)
        #expect(recordItem()?.title == "Stop Recording")
        #expect(recordItem()?.isEnabled == true)
        try #require(recordItem() as? ActionMenuItem).handler()
        #expect(!view.controller.isRecording)

        let empty = try #require(model.splitPane(paneID, axis: .horizontal))
        let emptyView = EmptyPaneView(
            chooser: NewSessionChooser(model: model, paneID: empty, actions: window.actions),
            settings: settings, theme: .pane(empty, in: model))
        #expect(!emptyView.paneMenu().items.contains { $0.identifier == PaneMenu.recordItemIdentifier })
        await view.controller.close()
    }

    /// The save sheet goes when its pane leaves the window (closed here).
    @Test func theSaveSheetEndsWhenItsPaneCloses() async throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let (model, registry, workspace, _) = makeRegistry(settings: settings)
        let window = WorkspaceWindowController(model: model, workspaceID: workspace, registry: registry)
        defer { window.close() }
        let paneID = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let session = try #require(model.pane(paneID)?.sessionID)
        let controller = try #require(registry.paneView(for: session)?.controller)
        await controller.start(.create)
        _ = model.splitPane(paneID, axis: .vertical)
        let log = PanelLog()
        window.actions.recordPanelPresenter = log.presenter
        window.actions.recordPane(session: session)
        #expect(window.actions.recordSheet != nil)
        #expect(WorkspaceActions.recordSheetIsWanted(for: session, in: model, workspace: workspace))
        model.closePane(paneID)
        #expect(!WorkspaceActions.recordSheetIsWanted(for: session, in: model, workspace: workspace))
        #expect(await eventually { window.actions.recordSheet == nil })
        #expect(log.dismissedPanels == 1)
    }

    // MARK: Header and tabs

    @Test func theHeaderShowsTheRecordingAndItsStopButtonStopsIt() async throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let (model, registry, workspace, _) = makeRegistry(settings: settings)
        let paneID = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let session = try #require(model.pane(paneID)?.sessionID)
        let pane = try #require(registry.paneView(for: session))
        await pane.controller.start(.create)
        #expect(!registry.headerModel(for: session).isRecording)
        #expect(!pane.header.model.isRecording)

        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try registry.startRecording(session: session, to: url)
        #expect(registry.headerModel(for: session).isRecording)
        #expect(await eventually { pane.header.model.isRecording }, "the header follows the controller")
        // The title changes (the header's root view is replaced): still recording.
        model.setTitle("vim notes.txt", for: session)
        #expect(await eventually { pane.header.model.title == "vim notes.txt" && pane.header.model.isRecording })
        pane.header.stopRecording()
        #expect(!pane.controller.isRecording)
        #expect(await eventually { !pane.header.model.isRecording })
        await pane.controller.close()
    }

    /// The text gives way to the recording controls, which sit left of "…".
    @Test func theRecordingControlsTakeTheirPlaceFromTheText() {
        #expect(PaneCardStyle.recordingControlsWidth == 34)
        #expect(PaneCardStyle.headerTextSpace(headerWidth: 400, hasGlyph: true, isRecording: true) == 292)
        #expect(PaneCardStyle.headerTextSpace(headerWidth: 400, hasGlyph: true) == 332)
        #expect(PaneCardStyle.headerTextSpace(headerWidth: 100, hasGlyph: true, isRecording: true) == 0, "never negative")
        let size = NSSize(width: 300, height: PaneCardStyle.headerHeight)
        let stop = PaneCardStyle.stopButtonFrame(inHeaderOf: size)
        let menu = PaneCardStyle.menuButtonFrame(inHeaderOf: size)
        #expect(stop.maxX + PaneCardStyle.textSpacing == menu.minX)
        #expect(stop.midY == menu.midY)
        // The dot, the stop button and "…" all fit right of the text space.
        let fixedRight = size.width - PaneCardStyle.headerTrailing - menu.width - PaneCardStyle.textSpacing
            - PaneCardStyle.recordingControlsWidth
        #expect(fixedRight >= PaneCardStyle.headerLeading + PaneCardStyle.glyphWidth + PaneCardStyle.textSpacing
            + PaneCardStyle.headerTextSpace(headerWidth: size.width, hasGlyph: true, isRecording: true))
    }

    /// The give-way rule (``PaneCardStyle/headerParts(width:hasGlyph:isRecording:)``).
    @Test func thingsGiveWayInOrder() {
        func parts(_ width: CGFloat) -> PaneCardStyle.HeaderParts {
            PaneCardStyle.headerParts(width: width, hasGlyph: true, isRecording: true)
        }
        typealias Parts = PaneCardStyle.HeaderParts
        #expect(parts(400) == Parts(glyph: true, title: true, dot: true, stop: true))
        #expect(parts(140) == Parts(glyph: true, title: true, dot: true, stop: true))
        #expect(parts(100) == Parts(glyph: true, title: false, dot: false, stop: true), "the title, then the dot")
        #expect(parts(80) == Parts(glyph: false, title: false, dot: false, stop: true), "then the glyph")
        #expect(parts(60) == Parts(), "\u{2026} alone")
        #expect(parts(40) == Parts())
        // Never more than fits.
        for width in stride(from: CGFloat(38), through: 400, by: 1) {
            #expect(PaneCardStyle.headerWidth(parts(width)) <= width)
        }
        #expect(PaneCardStyle.headerWidth(parts(400), textWidth: 400 - 108) == 400, "the text gets what the rule says")
    }

    /// Drawn at 140, 100, 80, 60 and 40 pt: red only where the dot and the
    /// stop button belong, nothing else drawn there, "…" always drawn, and
    /// no red at all when only "…" fits.
    @Test(arguments: [140, 100, 80, 60, 40] as [CGFloat])
    func aNarrowRecordingHeaderNeverOverlaps(width: CGFloat) throws {
        _ = NSApplication.shared
        var model = PaneHeaderModel(
            status: .running, title: String(repeating: "a very long title ", count: 8),
            directory: "~/" + String(repeating: "deep/", count: 20))
        model.isRecording = true
        let header = PaneHeaderHostingView.make(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: PaneCardStyle.headerHeight), styleMask: [.borderless],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = header
        header.frame = NSRect(x: 0, y: 0, width: width, height: PaneCardStyle.headerHeight)
        header.layoutSubtreeIfNeeded()
        let size = header.bounds.size
        let parts = PaneCardStyle.headerParts(width: width, hasGlyph: true, isRecording: true)
        let stop = PaneCardStyle.stopButtonFrame(inHeaderOf: size)
        let menu = PaneCardStyle.menuButtonFrame(inHeaderOf: size)
        let dotStart = stop.minX - PaneCardStyle.recordingControlsSpacing - PaneCardStyle.recordingDotFrameWidth
        let controls = (parts.dot ? dotStart : stop.minX)...stop.maxX
        let rep = try #require(header.bitmapImageRepForCachingDisplay(in: header.bounds))
        header.cacheDisplay(in: header.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / size.width
        var red: [CGFloat] = [], other: [CGFloat] = []
        for px in 0..<rep.pixelsWide {
            for py in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB), color.alphaComponent > 0.15 else { continue }
                let x = (CGFloat(px) + 0.5) / scale
                if color.redComponent > 0.6 && color.greenComponent < 0.45 && color.blueComponent < 0.45 {
                    red.append(x)
                } else {
                    other.append(x)
                }
            }
        }
        #expect(other.contains { $0 > menu.minX && $0 < menu.maxX }, "\u{2026} is drawn at \(width) pt")
        #expect(!other.contains { $0 > menu.maxX + 0.5 }, "nothing past \u{2026}")
        if parts.stop {
            #expect(red.allSatisfy { controls.contains($0) }, "red only at the controls: \(red.min() ?? 0)–\(red.max() ?? 0) in \(controls)")
            #expect(red.contains { $0 > stop.minX }, "the stop button")
            #expect(red.contains { $0 < stop.minX } == parts.dot, "the dot only when it fits")
            #expect(!other.contains { controls.contains($0) }, "nothing else over the controls at \(width) pt")
        } else {
            #expect(red.isEmpty, "\u{2026} alone at \(width) pt")
        }
        if parts.title {
            let textStart = PaneCardStyle.headerLeading + PaneCardStyle.glyphWidth + PaneCardStyle.textSpacing
            #expect(other.contains { $0 > textStart && $0 < controls.lowerBound }, "the title, truncated")
        }
    }

    /// The dot pulses as a Core Animation animation; the same view keeps
    /// pulsing when the header's root view is replaced (a title change),
    /// and with Reduce Motion it is steady.
    @Test func theDotPulsesAndKeepsPulsingThroughATitleChange() throws {
        _ = NSApplication.shared
        var model = PaneHeaderModel(status: .running, title: "zsh", directory: nil)
        model.isRecording = true
        let header = PaneHeaderHostingView.make(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: PaneCardStyle.headerHeight), styleMask: [.borderless],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = header
        header.frame = NSRect(x: 0, y: 0, width: 400, height: PaneCardStyle.headerHeight)
        header.layoutSubtreeIfNeeded()
        func dots(_ view: NSView) -> [PulsingDotView] {
            (view as? PulsingDotView).map { [$0] } ?? view.subviews.flatMap(dots)
        }
        let dot = try #require(dots(header).first)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #expect(dot.isPulsing == !reduceMotion)
        model.title = "vim notes.txt"
        header.model = model
        header.layoutSubtreeIfNeeded()
        #expect(dots(header).first === dot, "the same view")
        #expect(dot.isPulsing == !reduceMotion)
        dot.removeFromSuperview()
        #expect(!dot.isPulsing, "out of a window: no animation")
    }

    /// The tab's dot: shown while any of the tab's panes records.
    @Test func aTabShowsTheDotWhileAnyOfItsPanesRecords() async throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let (model, registry, workspace, _) = makeRegistry(settings: settings)
        let first = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let second = try #require(model.splitPane(first, axis: .horizontal))
        model.startSession(in: second, request: SessionRequest())
        let tab = try #require(model.selectedTab(in: workspace))
        let sessions = tab.layout.leaves().compactMap { tab.pane($0)?.sessionID }
        #expect(sessions.count == 2)
        let controller = try #require(registry.paneView(for: sessions[1])?.controller)
        await controller.start(.create)
        #expect(!registry.isRecording(tab))
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try registry.startRecording(session: sessions[1], to: url)
        #expect(registry.isRecording(tab))
        #expect(registry.isRecording(anyOf: sessions))
        #expect(!registry.isRecording(anyOf: [sessions[0]]))
        #expect(registry.glyphStatus(of: sessions) == .running, "not a status")
        // A quit ends it with the file written.
        registry.detachAllNow()
        #expect(!registry.isRecording(tab))
        #expect(try #require(controller.recordingWriter).isClosed, "closed before detachAllNow returned")
    }

    // MARK: Problems and refusals

    /// Problems are told one at a time, in order: on the pane's window, and
    /// when it has none, on the next window that opens or becomes key.
    @Test func problemsAreToldOneAtATime() throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let (model, registry, workspace, _) = makeRegistry(settings: settings)
        let window = WorkspaceWindowController(model: model, workspaceID: workspace, registry: registry)
        defer { window.close() }
        let log = PanelLog()
        window.actions.recordPanelPresenter = log.presenter
        let other = model.newWorkspace(name: "Closed")
        registry.actionsOfWorkspace = { [weak window] id in id == workspace ? window?.actions : nil }
        let url = URL(fileURLWithPath: "/tmp/x.cast")
        registry.queueRecordingProblem(.writeFailed(RecordingFailure(url: url, reason: "No space left on device")),
                                       workspace: workspace)
        registry.queueRecordingProblem(.couldNotStart(.fileInUse(name: "y.cast")), workspace: workspace)
        registry.queueRecordingProblem(.writeFailed(RecordingFailure(url: url, reason: "Input/output error")),
                                       workspace: other)
        #expect(log.alerts.count == 1, "one at a time")
        #expect(log.alerts[0].alert.informativeText
            == "“x.cast” could not be written. No space left on device. What was recorded until then is in the file.")
        log.alerts[0].completion()
        #expect(log.alerts.count == 2)
        #expect(log.alerts[1].alert.informativeText == "Another pane is being recorded into “y.cast”. Choose another file.")
        log.alerts[1].completion()
        #expect(log.alerts.count == 2, "the third waits: its window is closed")
        registry.showNextRecordingProblem(preferring: window.actions)
        #expect(log.alerts.count == 3, "shown on the window that became key")
        #expect(log.alerts[2].alert.informativeText.contains("Input/output error"))
        // Taken down unanswered (its window closing, a quit): told again first.
        AppDelegate.endSheetsForQuit(workspaceWindows: [window], settingsWindow: nil)
        #expect(log.dismissedAlerts == 1, "an alert goes before a quit")
        #expect(registry.recordingProblems.count == 1 && !registry.isShowingRecordingProblem)
        registry.showNextRecordingProblem(preferring: window.actions)
        #expect(log.alerts.count == 4, "the same problem, on the next window")
        #expect(log.alerts[3].alert.informativeText == log.alerts[2].alert.informativeText)
        log.alerts[3].completion()
        #expect(registry.recordingProblems.isEmpty)
    }

    /// Two panes into one file: the second is refused.
    @Test func aFileBeingRecordedIsRefused() async throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let (model, registry, workspace, _) = makeRegistry(settings: settings)
        let first = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let second = try #require(model.splitPane(first, axis: .horizontal))
        model.startSession(in: second, request: SessionRequest())
        let sessions = try [first, second].map { try #require(model.pane($0)?.sessionID) }
        for session in sessions { await registry.paneView(for: session)?.controller.start(.create) }
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try registry.startRecording(session: sessions[0], to: url)
        #expect(throws: RecordingError.fileInUse(name: url.lastPathComponent)) {
            try registry.startRecording(session: sessions[1], to: URL(fileURLWithPath: url.path + "/../" + url.lastPathComponent))
        }
        #expect(!(registry.controllers[sessions[1]]?.isRecording ?? true))
        registry.detachAllNow()

        // Stopped, but its file still being written: refused too, until
        // the writer has closed it.
        let other = temporaryFile()
        defer { try? FileManager.default.removeItem(at: other) }
        let finishing = try RecordingFileWriter(url: other)
        registry.recordingWriters.append(finishing)
        #expect(throws: RecordingError.fileInUse(name: other.lastPathComponent)) {
            try registry.startRecording(session: sessions[1], to: other)
        }
        finishing.finish()
        await finishing.drained()
        #expect(finishing.isClosed)
        await registry.controllers[sessions[1]]?.start(.create)
        try registry.startRecording(session: sessions[1], to: other)
        #expect(registry.controllers[sessions[1]]?.isRecording == true)
        registry.detachAllNow()
    }

    // MARK: File name

    @Test func theSuggestedNameIsTheTitleDateAndTime() {
        let date = Date(timeIntervalSince1970: 1_795_000_000)  // 2026-11-18 11:06:40 UTC
        let utc = TimeZone(identifier: "UTC")!
        #expect(RecordingFileName.suggested(title: "zsh", date: date, timeZone: utc) == "zsh 2026-11-18 at 11.06.40.cast")
        #expect(RecordingFileName.suggested(title: "~/src: make", date: date, timeZone: utc)
            == "src- make 2026-11-18 at 11.06.40.cast")
        // A title that is a path, as a shell's often is (seen live: zsh in
        // /tmp/armrec/w gave "-tmp-armrec-w …"): no leading dash or tilde.
        #expect(RecordingFileName.cleaned("/tmp/armrec/w") == "tmp-armrec-w")
        #expect(RecordingFileName.cleaned("~/Developer/armadale/") == "Developer-armadale")
        #expect(RecordingFileName.cleaned("-- ~.profile") == "profile")
        #expect(RecordingFileName.suggested(title: "~", date: date, timeZone: utc) == "Pane 2026-11-18 at 11.06.40.cast")
        #expect(RecordingFileName.suggested(title: "  .hidden\ttab\n", date: date, timeZone: utc)
            == "hidden tab 2026-11-18 at 11.06.40.cast")
        #expect(RecordingFileName.suggested(title: "", date: date, timeZone: utc) == "Pane 2026-11-18 at 11.06.40.cast")
        #expect(RecordingFileName.cleaned(String(repeating: "x", count: 300)).utf8.count == RecordingFileName.maximumTitleBytes)
        // An emoji title: cut by bytes, on a character boundary, the name within 255 bytes.
        let emoji = String(repeating: "👩‍👩‍👧‍👦🇯🇵", count: 30)
        let long = RecordingFileName.suggested(title: emoji, date: date, timeZone: utc)
        #expect(long.utf8.count <= 255, "\(long.utf8.count) bytes")
        #expect(long.hasSuffix(" 2026-11-18 at 11.06.40.cast"))
        let kept = RecordingFileName.cleaned(emoji)
        #expect(!kept.isEmpty && emoji.hasPrefix(kept), "whole characters only")
        #expect(kept.utf8.count <= RecordingFileName.maximumTitleBytes)
        #expect(RecordingFileName.cleaned("✳ Claude Code") == "✳ Claude Code")
        #expect(RecordingFileName.contentType.preferredFilenameExtension == "cast")
    }

    // MARK: Playback equals the pane

    /// Feeds a recording's file to a fresh surface the way a player would:
    /// its size from the header, then every output event, and every resize.
    private func play(_ url: URL) throws -> SwiftTermSurface {
        let file = try CastFile(url)
        let columns = try #require(file.header["width"] as? Int), rows = try #require(file.header["height"] as? Int)
        let player = SwiftTermSurface(appearance: TerminalAppearance(fontName: "Menlo", fontSize: 12))
        player.setGridSize(columns: columns, rows: rows)
        for event in file.events {
            switch event.code {
            case "o": player.feed(Array(event.data.utf8)[...])
            case "r":
                let size = event.data.split(separator: "x").compactMap { Int($0) }
                try #require(size.count == 2)
                player.setGridSize(columns: size[0], rows: size[1])
            default: Issue.record("an event that is neither output nor a resize: \(event.code)")
            }
        }
        #expect(!file.events.contains { $0.code == "i" })
        return player
    }

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// A scripted session through a real controller and a real SwiftTerm
    /// surface; the recording starts in the middle (inside a full-screen
    /// program that redraws by moving the cursor), the program goes on,
    /// the pane is resized, a character is split across two reads. The
    /// file's events, played on a fresh surface, give the pane's screen.
    @Test func playbackOfARecordingStartedInAFullScreenProgramEqualsThePane() async throws {
        let backend = LaunchTestBackend(alive: [])
        let surface = SwiftTermSurface(appearance: TerminalAppearance(fontName: "Menlo", fontSize: 12))
        surface.setGridSize(columns: 60, rows: 16)
        let session = Session(profileID: Profile.shell.id, launch: LaunchSpec(program: "agent", arguments: []), workingDirectory: "/")
        let controller = SessionController(session: session, backend: backend, makeSurface: { surface })
        await controller.start(.create)
        let client = try #require(await backend.handle(session.id))
        func settle(_ marker: String) async throws {
            let shown = await eventually {
                surface.visibleText().contains { $0.contains(marker) }
            }
            try #require(shown, "\(marker) on screen")
        }

        // Before the recording: a shell, then a full-screen program.
        client.emit(bytes("user@mac ~ % ls\r\n\u{1b}[34mDocuments\u{1b}[0m  \u{1b}[1;32mrun.sh\u{1b}[0m\r\nuser@mac ~ % agent\r\n"))
        client.emit(bytes("\u{1b}[?1049h\u{1b}[H\u{1b}[2J\u{1b}[44;97m Agent \u{1b}[0m\u{1b}[K\r\n"))
        for line in 1...10 { client.emit(bytes("\u{1b}[\(line + 1);1H\u{1b}[2m\(line).\u{1b}[0m step \(line) \u{1b}[32m✔\u{1b}[0m 漢字")) }
        client.emit(bytes("\u{1b}[16;1H\u{1b}[7m > type here \u{1b}[0m\u{1b}[16;14H\u{1b}[?25l\u{1b}[3;14r\u{1b}[16;14H"))
        try await settle("type here")

        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try controller.startRecording(to: url, title: "agent")

        // After: relative movement only, a scroll inside the region, an
        // insertion, a split character, a resize and a redraw at the new size.
        client.emit(bytes("\u{1b}[8A\u{1b}[3D\u{1b}[1;33m★\u{1b}[0m\u{1b}[2B\r\u{1b}[K changed line"))
        client.emit(bytes("\u{1b}[14;1H\r\n\u{1b}[35mscrolled in\u{1b}[0m\u{1b}[5;1H\u{1b}[L\u{1b}[4minserted\u{1b}[0m"))
        client.emit([0x20, 0xE2, 0x9C])
        client.emit([0x94, 0x20] + bytes("e\u{301} 👍 done"))
        try await settle("done")
        surface.setGridSize(columns: 72, rows: 18)
        client.emit(bytes("\u{1b}[r\u{1b}[H\u{1b}[2J\u{1b}[44;97m Agent (72x18) \u{1b}[0m\u{1b}[K\r\n"))
        client.emit(bytes("\u{1b}[18;1H\u{1b}[7m > typing\u{1b}[0m\u{1b}[?25h\u{1b}[18;10H\u{1b}[31m"))
        try await settle("typing")
        controller.stopRecordingNow()

        let player = try play(url)
        let pane = try #require(surface.screenState()), played = try #require(player.screenState())
        #expect(pane.isAlternate)
        #expect(pane.cells.count == 18 && pane.cells[0].count == 72)
        let differences = pane.differences(from: played)
        #expect(differences.isEmpty, "\(differences.prefix(12))")
        #expect(pane == played, "playback equals the pane")
        await controller.close()
    }

    /// The output stopped in the middle of a sequence or a character when
    /// Record is confirmed (the reviewer's five splits). The pane is not
    /// disturbed (it equals a terminal fed the same bytes with no
    /// recording), the recording waits for the sequence to end, and the
    /// file played back equals the pane.
    nonisolated static let splits: [(String, [UInt8], [UInt8])] = {
        let sgr: (String, [UInt8], [UInt8]) = ("SGR", Array("\u{1b}[38;5;19".utf8), Array("6mRED".utf8))
        let osc: (String, [UInt8], [UInt8]) = ("OSC title", Array("\u{1b}]0;my ti".utf8), Array("tle\u{07}after".utf8))
        let cup: (String, [UInt8], [UInt8]) = ("CUP", Array("\u{1b}[1".utf8), Array("0;5Hx".utf8))
        let four: (String, [UInt8], [UInt8]) = ("4-byte character", [0xF0, 0x9F], [0x91, 0x8D, 0x6F, 0x6B])
        let three: (String, [UInt8], [UInt8]) = ("3-byte character", [0xE2, 0x82], [0xAC, 0x20, 0x65, 0x75])
        return [sgr, osc, cup, four, three]
    }()

    @Test(arguments: PaneRecordingTests.splits)
    func aRecordingStartedInsideASequence(name: String, first: [UInt8], second: [UInt8]) async throws {
        let backend = LaunchTestBackend(alive: [])
        let surface = SwiftTermSurface(appearance: TerminalAppearance(fontName: "Menlo", fontSize: 12))
        surface.setGridSize(columns: 40, rows: 10)
        let reference = SwiftTermSurface(appearance: TerminalAppearance(fontName: "Menlo", fontSize: 12))
        reference.setGridSize(columns: 40, rows: 10)
        let session = Session(profileID: Profile.shell.id, launch: LaunchSpec(program: nil, arguments: []), workingDirectory: "/")
        let controller = SessionController(session: session, backend: backend, makeSurface: { surface })
        await controller.start(.create)
        let client = try #require(await backend.handle(session.id))
        func send(_ bytes: [UInt8]) {
            client.emit(bytes)
            reference.feed(bytes[...])
        }
        func settle(_ marker: String) async throws {
            let shown = await eventually {
                surface.visibleText().contains { $0.contains(marker) }
            }
            try #require(shown, "\(marker) on screen (\(name))")
        }
        send(bytes("\u{1b}[1mmarker\u{1b}[0m\r\n") + first)
        try await settle("marker")
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try controller.startRecording(to: url, title: name)
        #expect(controller.isRecordingPending, "\(name): inside a sequence")
        send(second)
        send(bytes(" more \u{1b}[1mbold\u{1b}[0m\r\n"))
        try await settle("bold")
        #expect(!controller.isRecordingPending)
        controller.stopRecordingNow()

        let pane = try #require(surface.screenState()), undisturbed = try #require(reference.screenState())
        #expect(pane.differences(from: undisturbed).isEmpty, "\(name): \(pane.differences(from: undisturbed).prefix(8))")
        let played = try #require(try play(url).screenState())
        #expect(pane.differences(from: played).isEmpty, "\(name): \(pane.differences(from: played).prefix(8))")
        if name == "OSC title" { #expect(controller.session.title == "my title") }
        let output = try CastFile(url).events.filter { $0.code == "o" }.map(\.data).joined()
        #expect(!output.contains("\u{FFFD}"), "no broken character in the file")
        await controller.close()
    }

    /// Started at a shell prompt: colours, a full-screen program entered
    /// and left after the start, and a reset; playback equals the pane.
    @Test func playbackOfARecordingStartedAtAPromptEqualsThePane() async throws {
        let backend = LaunchTestBackend(alive: [])
        let surface = SwiftTermSurface(appearance: TerminalAppearance(fontName: "Menlo", fontSize: 12))
        surface.setGridSize(columns: 50, rows: 12)
        let session = Session(profileID: Profile.shell.id, launch: LaunchSpec(program: nil, arguments: []), workingDirectory: "/")
        let controller = SessionController(session: session, backend: backend, makeSurface: { surface })
        await controller.start(.create)
        let client = try #require(await backend.handle(session.id))
        func settle(_ marker: String) async throws {
            let shown = await eventually {
                surface.visibleText().contains { $0.contains(marker) }
            }
            try #require(shown, "\(marker) on screen")
        }
        for index in 0..<30 { client.emit(bytes("old \(index) \u{1b}[3\(index % 8)mcolour\u{1b}[0m\r\n")) }
        client.emit(bytes("\u{1b}[1muser\u{1b}[0m ~ % "))
        try await settle("user")

        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try controller.startRecording(to: url, title: "zsh")
        client.emit(bytes("vim\r\n\u{1b}[?1049h\u{1b}[H\u{1b}[2J~\r\n~\r\n\u{1b}[12;1H\"notes\" 2L"))
        try await settle("notes")
        client.emit(bytes("\u{1b}[?1049l\u{1b}[1muser\u{1b}[0m ~ % printf done\r\ndone\r\n\u{1b}[1muser\u{1b}[0m ~ % "))
        try await settle("printf done")
        controller.stopRecordingNow()

        let player = try play(url)
        let pane = try #require(surface.screenState()), played = try #require(player.screenState())
        #expect(!pane.isAlternate)
        let differences = pane.differences(from: played)
        #expect(differences.isEmpty, "\(differences.prefix(12))")
        #expect(pane == played)
        await controller.close()
    }
}

/// A recording's file, parsed line by line (every line must be JSON).
struct CastFile {
    var header: [String: Any]
    var events: [(time: Double, code: String, data: String)]

    init(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let data = try Data(contentsOf: url)
        #expect(data.last == 0x0A, "the file ends with a whole line", sourceLocation: sourceLocation)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()
        let first = try #require(lines.first, sourceLocation: sourceLocation)
        header = try #require(try JSONSerialization.jsonObject(with: Data(first)) as? [String: Any], sourceLocation: sourceLocation)
        events = []
        for line in lines.dropFirst() {
            let event = try #require(try JSONSerialization.jsonObject(with: Data(line)) as? [Any], sourceLocation: sourceLocation)
            let time = try #require(event.first as? Double, sourceLocation: sourceLocation)
            let code = try #require(event.count == 3 ? event[1] as? String : nil, sourceLocation: sourceLocation)
            let value = try #require(event[2] as? String, sourceLocation: sourceLocation)
            events.append((time, code, value))
        }
    }
}

/// Stands in for the save panel's and the alert's sheets, so the tests
/// put nothing on screen (``WorkspaceActions/recordPanelPresenter``).
@MainActor
final class PanelLog {
    var panels: [(panel: NSSavePanel, completion: @MainActor (NSApplication.ModalResponse) -> Void)] = []
    var dismissedPanels = 0
    var alerts: [(alert: NSAlert, completion: @MainActor () -> Void)] = []
    var dismissedAlerts = 0

    var presenter: RecordPanelPresenter {
        RecordPanelPresenter(
            present: { panel, _, completion in self.panels.append((panel, completion)) },
            dismiss: { _ in self.dismissedPanels += 1 },
            presentAlert: { alert, _, completion in self.alerts.append((alert, completion)) },
            dismissAlert: { _ in self.dismissedAlerts += 1 })
    }
}
