import AppKit
import ArmadaleCore
import ArmadaleSessions
import Foundation
import Testing

/// Records what would have been posted.
@MainActor
final class FakeNotificationService: NotificationService {
    private(set) var posted: [AttentionNotification] = []
    private(set) var authorizationRequests = 0
    private(set) var withdrawn: [Set<SessionID>] = []
    func post(_ notification: AttentionNotification) { posted.append(notification) }
    func requestAuthorization() { authorizationRequests += 1 }
    func withdraw(_ sessions: Set<SessionID>) { withdrawn.append(sessions) }
}

@Suite("Status precedence with attention")
struct AttentionStatusTests {
    @Test func attentionSitsBelowProblemsAndAboveRunning() {
        #expect(SessionStatus.summary(of: [.running, .attention]) == .attention)
        #expect(SessionStatus.summary(of: [.pending, .attention, .ended]) == .attention)
        #expect(SessionStatus.summary(of: [.attention, .disconnected]) == .disconnected)
        #expect(SessionStatus.summary(of: [.unavailable, .attention]) == .unavailable)
        #expect(SessionStatus.summary(of: [.ended, .ended]) == .ended)
        #expect(SessionStatus.summary(of: [.running, .pending]) == .running)
    }

    @Test func aSessionNeedingAttentionShowsItUnlessItMayBeGone() {
        #expect(SessionStatus.running.withAttention(true) == .attention)
        #expect(SessionStatus.pending.withAttention(true) == .attention)
        #expect(SessionStatus.ended.withAttention(true) == .attention, "it rang before it exited: look at it")
        #expect(SessionStatus.disconnected.withAttention(true) == .disconnected)
        #expect(SessionStatus.unavailable.withAttention(true) == .unavailable)
        #expect(SessionStatus.running.withAttention(false) == .running)
    }

    @Test func attentionCountsAsPossiblyRunningWhenClosing() {
        #expect(CloseRisk.assess([.init(status: .attention, mayExist: true)]).mayBeRunning)
    }
}

@Suite("Notification policy")
struct NotificationPolicyTests {
    let a = SessionID(raw: "aaaaaaaaaaaaaaaa")
    let b = SessionID(raw: "bbbbbbbbbbbbbbbb")

    @Test func coalescesPerSessionWithinTwoSeconds() {
        var policy = NotificationPolicy()
        let start = ContinuousClock.now
        var results: [Bool] = []
        for (id, offset) in [
            (a, Duration.zero), (a, .milliseconds(500)), (b, .milliseconds(600)), (a, .milliseconds(1999)),
            (a, .milliseconds(2000)),
        ] {
            results.append(policy.shouldPost(for: id, isAgent: true, enabled: true, agentsOnly: true, now: start + offset))
        }
        // Another session is not held back; the first is again after 2 s.
        #expect(results == [true, false, true, false, true])
    }

    @Test func honoursThePreferences() {
        var policy = NotificationPolicy()
        let now = ContinuousClock.now
        let disabled = policy.shouldPost(for: a, isAgent: true, enabled: false, agentsOnly: false, now: now)
        let shellWhenAgentsOnly = policy.shouldPost(for: a, isAgent: false, enabled: true, agentsOnly: true, now: now)
        let shellWhenAll = policy.shouldPost(for: a, isAgent: false, enabled: true, agentsOnly: false, now: now)
        #expect(!disabled)
        #expect(!shellWhenAgentsOnly)
        #expect(shellWhenAll)
    }
}

/// The app's attention state: signals from the registry's sessions, focus,
/// notifications through a fake service, the Dock badge, and bringing a
/// session forward.
@Suite("Attention center")
@MainActor
struct AttentionCenterTests {
    private struct Fixture {
        let model: AppModel
        let workspace: WorkspaceID
        /// Tab 1 (a shell) and tab 2 (Claude Code), tab 2 selected.
        let shell: SessionID
        let agent: SessionID
        let center: AttentionCenter
        let service: FakeNotificationService
        let settings: AppSettings
        var badges: () -> [String?]
    }

    private func makeFixture() throws -> Fixture {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "Work")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        model.renameTabGroup(group, to: "Agents")
        let shell = try #require(model.sessionIDs(in: workspace).first)
        let tab = try #require(model.newTab(in: group, profile: Profile.claudeCode.id))
        let agent = try #require(model.sessionIDs(ofTab: tab).first)
        model.select(tab: tab)
        let settings = AppSettings.forTesting()
        let service = FakeNotificationService()
        let center = AttentionCenter(model: model, preferences: settings.preferences, notifications: service)
        var badges: [String?] = []
        center.onBadgeChange = { badges.append($0) }
        center.isAppActive = true
        center.keyWorkspaceID = workspace
        return Fixture(
            model: model, workspace: workspace, shell: shell, agent: agent, center: center, service: service,
            settings: settings, badges: { badges })
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func onlyAgentsNotifyByDefaultAndContentNamesTheSession() throws {
        let f = try makeFixture()
        defer { f.settings.removeTestDefaults() }
        f.model.focus(pane: try #require(f.model.place(of: f.shell)).pane) // look at the shell
        f.center.signal(.bell, from: f.agent)
        f.center.signal(.bell, from: f.shell) // looked at: nothing
        #expect(f.center.needsAttention(f.agent))
        #expect(!f.center.needsAttention(f.shell))
        #expect(f.service.posted.count == 1)
        let posted = try #require(f.service.posted.first)
        #expect(posted.sessionID == f.agent)
        #expect(posted.title == "Claude Code", "no program title yet: the profile's name")
        #expect(posted.subtitle == "Work / Agents")
        #expect(posted.body == "Finished")
        #expect(!posted.playsSound)
        #expect(AttentionNotification.sessionID(fromUserInfo: posted.userInfo) == f.agent)

        // A shell elsewhere sets attention but, agents only, posts nothing.
        f.model.select(tab: try #require(f.model.place(of: f.agent)).tab)
        f.center.signal(.bell, from: f.shell)
        #expect(f.center.needsAttention(f.shell))
        #expect(f.service.posted.count == 1)
        f.settings.preferences.notifyOnlyForAgents = false
        f.center.signal(.notification(title: "", body: "build done"), from: f.shell)
        #expect(f.service.posted.count == 2)
        #expect(f.service.posted.last?.body == "build done")
        #expect(f.service.posted.last?.title == "Shell")
    }

    @Test func notificationsCoalesceAndFollowThePreferences() throws {
        let f = try makeFixture()
        defer { f.settings.removeTestDefaults() }
        f.model.focus(pane: try #require(f.model.place(of: f.shell)).pane)
        var clock = ContinuousClock.now
        f.center.now = { clock }
        f.center.signal(.notification(title: "Claude Code", body: "Claude is waiting for your input"), from: f.agent)
        clock += .milliseconds(800)
        f.center.signal(.bell, from: f.agent)
        #expect(f.service.posted.count == 1, "one per session per 2 s")
        #expect(f.service.posted.first?.body == "Claude is waiting for your input")
        #expect(f.service.posted.first?.title == "Claude Code", "the OSC 777 title")
        clock += .seconds(2)
        f.settings.preferences.notificationPlaysSound = true
        f.center.signal(.notification(title: "MyTitle", body: ""), from: f.agent)
        #expect(f.service.posted.count == 2)
        #expect(f.service.posted.last?.title == "MyTitle")
        #expect(f.service.posted.last?.body == "Finished")
        #expect(f.service.posted.last?.playsSound == true)
        clock += .seconds(3)
        f.settings.preferences.notifyOnAttention = false
        f.center.signal(.bell, from: f.agent)
        #expect(f.service.posted.count == 2)
        #expect(f.center.needsAttention(f.agent), "attention is set whatever the notification preferences")
    }

    @Test func theDockBadgeCountsSessions() throws {
        let f = try makeFixture()
        defer { f.settings.removeTestDefaults() }
        f.center.isAppActive = false
        f.center.signal(.bell, from: f.agent)
        f.center.signal(.bell, from: f.agent)
        f.center.signal(.bell, from: f.shell)
        #expect(f.center.total == 2)
        #expect(f.badges() == ["1", "2"])
        f.center.clearAll()
        #expect(f.badges().last == .some(nil), "empty when zero")
        #expect(f.center.total == 0)
    }

    @Test func revealSelectsTheTabFocusesThePaneAndClears() throws {
        let f = try makeFixture()
        defer { f.settings.removeTestDefaults() }
        var shown: [WorkspaceID] = []
        f.center.showWorkspace = { shown.append($0) }
        f.center.signal(.bell, from: f.shell) // tab 2 is selected: tab 1 is not looked at
        #expect(f.center.needsAttention(f.shell))
        #expect(f.center.reveal(f.shell))
        #expect(shown == [f.workspace])
        #expect(f.model.focusedSessionID(in: f.workspace) == f.shell)
        #expect(!f.center.needsAttention(f.shell), "looked at now")
        #expect(!f.center.reveal(SessionID(raw: "gonegonegonegone")), "a session that no longer exists")
        #expect(shown == [f.workspace])
    }

    @Test func nextCyclesAcrossWorkspaces() throws {
        let f = try makeFixture()
        defer { f.settings.removeTestDefaults() }
        let other = f.model.newWorkspace(name: "Other")
        let remote = try #require(f.model.sessionIDs(in: other).first)
        var shown: [WorkspaceID] = []
        f.center.showWorkspace = { id in
            shown.append(id)
            f.center.keyWorkspaceID = id // its window becomes key
        }
        f.center.isAppActive = false
        f.center.signal(.bell, from: remote)
        f.center.signal(.bell, from: f.shell)
        f.center.isAppActive = true
        #expect(f.center.nextSession == remote, "after the agent (focused here): the other workspace")
        #expect(f.center.revealNext())
        #expect(shown == [other])
        #expect(!f.center.needsAttention(remote))
        #expect(f.center.nextSession == f.shell, "wraps around to the first workspace")
        #expect(f.center.revealNext())
        #expect(shown == [other, f.workspace])
        #expect(f.center.nextSession == nil)
        #expect(!f.center.revealNext())
    }

    @Test func closedSessionsAreForgottenAtOnceAndLaterSignalsIgnored() throws {
        let f = try makeFixture()
        defer { f.settings.removeTestDefaults() }
        f.center.signal(.bell, from: f.shell)
        #expect(f.center.total == 1)
        let tab = try #require(f.model.place(of: f.shell)).tab
        f.model.closeTab(tab)
        #expect(f.center.total == 0, "synchronously, inside the intent")
        #expect(f.badges().last == .some(nil))
        #expect(f.service.withdrawn.last == [f.shell])
        // A bell still in flight from the closed session's surface.
        f.center.signal(.bell, from: f.shell)
        #expect(f.center.total == 0)
        #expect(f.center.count(in: [f.shell]) == 0)
        f.center.signal(.bell, from: SessionID(raw: "nevernevernevern"))
        #expect(f.center.total == 0, "never in the model")
    }

    @Test func permissionIsAskedOnceWhenAttentionIsFirstSet() throws {
        let f = try makeFixture()
        defer { f.settings.removeTestDefaults() }
        f.settings.preferences.notifyOnAttention = false // the badge needs it anyway
        #expect(f.service.authorizationRequests == 0, "never before anything needs attention")
        f.center.signal(.bell, from: f.agent) // looked at: nothing
        #expect(f.service.authorizationRequests == 0)
        f.center.signal(.bell, from: f.shell)
        #expect(f.service.authorizationRequests == 1)
        f.center.clearAll()
        f.center.signal(.bell, from: f.shell)
        #expect(f.service.authorizationRequests == 1, "once per run")
        #expect(f.service.posted.isEmpty)
    }

    @Test func clearedSessionsAreWithdrawnAndLookedAtOnesNotPresented() throws {
        let f = try makeFixture()
        defer { f.settings.removeTestDefaults() }
        f.center.signal(.bell, from: f.shell)
        #expect(f.center.shouldPresent(f.shell))
        #expect(!f.center.shouldPresent(f.agent), "the agent is looked at")
        #expect(f.center.shouldPresent(nil))
        f.model.focus(pane: try #require(f.model.place(of: f.shell)).pane)
        f.center.refreshFocus()
        #expect(f.service.withdrawn.last == [f.shell], "looking at it removes its notification")
        #expect(!f.center.shouldPresent(f.shell))
        f.center.isAppActive = false
        #expect(f.center.shouldPresent(f.shell), "in the background nothing is looked at")
        f.center.signal(.bell, from: f.agent)
        f.center.clearAll()
        #expect(f.service.withdrawn.last == [f.agent])
    }
}

/// The whole path in the app's own code: bytes fed to a real SwiftTerm
/// surface reach the session controller, the registry and the attention
/// center. Nothing is started (inert backend), no window is shown.
@Suite("Attention from terminal output")
@MainActor
struct AttentionFromSurfaceTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aBellInAnUnfocusedPaneSetsAttentionAndFocusingClearsIt() async throws {
        _ = NSApplication.shared
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let first = try #require(model.sessionIDs(in: workspace).first)
        let firstTab = try #require(model.place(of: first)).tab
        let secondTab = try #require(model.newTab(in: group))
        let second = try #require(model.sessionIDs(ofTab: secondTab).first)
        model.select(tab: secondTab)

        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: [], settings: settings)
        let service = FakeNotificationService()
        let center = AttentionCenter(model: model, preferences: settings.preferences, notifications: service)
        registry.attention = center
        center.isAppActive = true
        center.keyWorkspaceID = workspace

        let firstSurface = try #require(registry.paneView(for: first)).controller.surface
        let secondSurface = try #require(registry.paneView(for: second)).controller.surface
        // SwiftTerm hands bells and titles to the main thread through its
        // event queue (and lets one bell through per 100 ms per view), so
        // every check waits; a check that nothing happened waits a while.
        let settle: Duration = .milliseconds(250)

        // A title change is not a signal.
        firstSurface.feed(ArraySlice(Array("\u{1b}]2;busy agent\u{07}".utf8)))
        #expect(await eventually { model.session(first)?.title == "busy agent" })
        try await Task.sleep(for: settle)
        #expect(!center.needsAttention(first))

        // The focused pane of the selected tab rings: nothing.
        secondSurface.feed([0x07])
        try await Task.sleep(for: settle)
        #expect(!center.needsAttention(second))

        // Tab 1 (not selected) rings: attention, shown by its glyph.
        firstSurface.feed([0x07])
        #expect(await eventually { center.needsAttention(first) })
        #expect(registry.glyphStatus(of: [first]) == .attention)
        #expect(center.count(in: model.sessionIDs(in: workspace)) == 1)

        // Switching to another tab keeps it; focusing its pane clears it.
        let thirdTab = try #require(model.newTab(in: group))
        model.select(tab: thirdTab)
        try await Task.sleep(for: .milliseconds(50))
        #expect(center.needsAttention(first))
        model.select(tab: secondTab)
        model.select(tab: firstTab)
        #expect(await eventually { !center.needsAttention(first) }, "looked at now")
        #expect(registry.glyphStatus(of: [first]) != .attention)

        // OSC 777 and OSC 9 from the unfocused tab 2.
        secondSurface.feed(ArraySlice(Array("\u{1b}]777;notify;Title;Body\u{07}".utf8)))
        #expect(await eventually { center.needsAttention(second) })
        center.clearAll()
        secondSurface.feed(ArraySlice(Array("\u{1b}]9;Done\u{07}".utf8)))
        #expect(await eventually { center.needsAttention(second) })

        // The app in the background: even the focused pane gets attention.
        // Its view's last bell must be over 100 ms ago, or SwiftTerm drops
        // this one (the checks since then can take less than that).
        center.clearAll()
        center.isAppActive = false
        try await Task.sleep(for: settle)
        firstSurface.feed([0x07])
        #expect(await eventually { center.needsAttention(first) })
        center.isAppActive = true
        #expect(!center.needsAttention(first), "coming back to the app looks at it")
        #expect(service.posted.isEmpty, "shells do not notify by default")
    }
}

/// `Contents/Resources/armadale-notify`, the helper agents' hooks can run.
/// It is run on a real pseudo-terminal (`script`), whose output is what it
/// wrote to `/dev/tty`.
@Suite("Notify helper")
struct NotifyHelperTests {
    private var helper: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Armadale/Resources/armadale-notify")
    }

    /// Runs the helper under `script` (a fresh pty as its controlling
    /// terminal) and returns everything written to that terminal.
    private func run(_ arguments: [String], environment: [String: String]) throws -> [UInt8] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", helper.path] + arguments
        process.environment = ["PATH": "/usr/bin:/bin"].merging(environment) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Array(data)
    }

    private func contains(_ haystack: [UInt8], _ needle: String) -> Bool {
        let bytes = Array(needle.utf8)
        guard bytes.count <= haystack.count else { return false }
        return (0...(haystack.count - bytes.count)).contains { Array(haystack[$0..<($0 + bytes.count)]) == bytes }
    }

    @Test func isExecutable() {
        #expect(FileManager.default.isExecutableFile(atPath: helper.path))
    }

    @Test func writesOSC777ToTheTerminal() throws {
        let bytes = try run(["Claude Code", "Finished"], environment: ["TERM_PROGRAM": "Armadale"])
        #expect(contains(bytes, "\u{1b}]777;notify;Claude Code;Finished\u{07}"))
    }

    @Test func ignoresCodexPayloadAndSanitizes() throws {
        let bytes = try run(
            ["Co;dex", "Turn\u{1b} complete", #"{"type":"agent-turn-complete"}"#],
            environment: ["ARMADALE_SESSION_ID": "aaaaaaaaaaaaaaaa"])
        #expect(contains(bytes, "\u{1b}]777;notify;Co,dex;Turn complete\u{07}"))
        #expect(!contains(bytes, "agent-turn-complete"))
    }

    @Test func bellAndDefaults() throws {
        let bell = try run(["--bell"], environment: ["TERM_PROGRAM": "Armadale"])
        #expect(bell.contains(0x07))
        #expect(!contains(bell, "]777"))
        let bare = try run([], environment: ["TERM_PROGRAM": "Armadale"])
        #expect(contains(bare, "\u{1b}]777;notify;;Finished\u{07}"))
    }

    /// Claude Code runs hooks in a session of their own, without a
    /// controlling terminal: the helper then writes to its nearest
    /// ancestor's terminal (here the `sh` that `script` runs on the pty).
    @Test func findsTheTerminalOfAnAncestorWithoutAControllingTerminal() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        let detached = "perl -MPOSIX -e 'POSIX::setsid() or die; exec @ARGV' /bin/sh \"$0\" 'Claude Code' 'Finished'; :"
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", detached, helper.path]
        process.environment = ["PATH": "/usr/bin:/bin", "TERM_PROGRAM": "Armadale"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let bytes = Array(output.fileHandleForReading.readDataToEndOfFile())
        process.waitUntilExit()
        #expect(contains(bytes, "\u{1b}]777;notify;Claude Code;Finished\u{07}"))
    }

    @Test func doesNothingOutsideArmadale() throws {
        let bytes = try run(["Claude Code", "Finished"], environment: ["TERM_PROGRAM": "ghostty"])
        #expect(!contains(bytes, "]777"))
        #expect(!bytes.contains(0x07))
    }
}

/// A sheet (a close confirmation) takes key status from its window; that
/// window's focused pane is still the one being looked at (the app delegate
/// resolves the sheet to its window).
@Suite("Sheets and the key window")
@MainActor
struct SheetOwnerTests {
    @Test func aSheetResolvesToTheWindowItIsAttachedTo() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50), styleMask: [.titled], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        #expect(AppDelegate.sheetOwner(of: window) === window)
        window.beginSheet(sheet) { _ in }
        defer { window.endSheet(sheet) }
        for _ in 0..<50 where sheet.sheetParent == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(sheet.sheetParent != nil, "AppKit attached the sheet")
        #expect(AppDelegate.sheetOwner(of: sheet) === window)
    }
}

@Suite("Notification preferences")
@MainActor
struct NotificationPreferencesTests {
    @Test func defaultsAndPersistence() {
        let suite = TestDefaults()
        defer { suite.remove() }
        let preferences = Preferences(defaults: suite.defaults, suiteName: suite.name)
        #expect(preferences.notifyOnAttention)
        #expect(preferences.notifyOnlyForAgents)
        #expect(!preferences.notificationPlaysSound)
        preferences.notifyOnAttention = false
        preferences.notifyOnlyForAgents = false
        preferences.notificationPlaysSound = true
        let reloaded = Preferences(defaults: suite.defaults, suiteName: suite.name)
        #expect(!reloaded.notifyOnAttention)
        #expect(!reloaded.notifyOnlyForAgents)
        #expect(reloaded.notificationPlaysSound)
    }
}
