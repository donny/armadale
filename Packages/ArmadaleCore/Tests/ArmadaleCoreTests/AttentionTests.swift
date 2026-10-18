import Foundation
import Testing
@testable import ArmadaleCore

/// The attention rule (DESIGN §10): only the focused pane of the key
/// window's selected tab, while the app is active, is looked at; a signal
/// anywhere else sets attention, and being looked at clears it.
@Suite("Attention tracker")
struct AttentionTrackerTests {
    let a = SessionID(raw: "aaaaaaaaaaaaaaaa")
    let b = SessionID(raw: "bbbbbbbbbbbbbbbb")
    let c = SessionID(raw: "cccccccccccccccc")

    @Test func theLookedAtSessionNeverGetsAttention() {
        var tracker = AttentionTracker()
        let focus = AttentionFocus(isAppActive: true, focusedSessionID: a)
        let r1 = tracker.record(.bell, from: a, focus: focus)
        #expect(!r1)
        let r2 = tracker.record(.notification(title: "T", body: "B"), from: a, focus: focus)
        #expect(!r2)
        #expect(!tracker.needsAttention(a))
        #expect(tracker.total == 0)
    }

    @Test func anUnfocusedSessionGetsAttention() {
        var tracker = AttentionTracker()
        let focus = AttentionFocus(isAppActive: true, focusedSessionID: a)
        let r3 = tracker.record(.bell, from: b, focus: focus)
        #expect(r3)
        #expect(tracker.needsAttention(b))
        #expect(!tracker.needsAttention(a))
        let r4 = tracker.record(.notification(title: "", body: "Done"), from: c, focus: focus)
        #expect(r4)
        #expect(tracker.total == 2)
    }

    @Test func theFocusedSessionGetsAttentionWhileTheAppIsInactive() {
        var tracker = AttentionTracker()
        let focus = AttentionFocus(isAppActive: false, focusedSessionID: a)
        let r5 = tracker.record(.bell, from: a, focus: focus)
        #expect(r5)
        #expect(tracker.needsAttention(a))
        // Coming back to the app with that pane focused clears it.
        let r6 = tracker.focusChanged(to: AttentionFocus(isAppActive: true, focusedSessionID: a))
        #expect(r6 == a)
        #expect(!tracker.needsAttention(a))
    }

    @Test func noKeyWorkspaceWindowMeansEverythingGetsAttention() {
        var tracker = AttentionTracker()
        let settingsKey = AttentionFocus(isAppActive: true, focusedSessionID: nil)
        let r7 = tracker.record(.bell, from: a, focus: settingsKey)
        #expect(r7)
        let r8 = tracker.record(.bell, from: b, focus: .nobody)
        #expect(r8)
        #expect(tracker.total == 2)
        let r9 = tracker.focusChanged(to: settingsKey)
        #expect(r9 == nil, "nothing is looked at: nothing clears")
        #expect(tracker.total == 2)
    }

    @Test func focusClearsOnlyTheLookedAtSession() {
        var tracker = AttentionTracker()
        tracker.record(.bell, from: a, focus: .nobody)
        tracker.record(.bell, from: b, focus: .nobody)
        // Focused but the app inactive: not looked at yet.
        let r10 = tracker.focusChanged(to: AttentionFocus(isAppActive: false, focusedSessionID: b))
        #expect(r10 == nil)
        #expect(tracker.needsAttention(b))
        let r11 = tracker.focusChanged(to: AttentionFocus(isAppActive: true, focusedSessionID: b))
        #expect(r11 == b)
        #expect(!tracker.needsAttention(b))
        #expect(tracker.needsAttention(a), "a tab switch elsewhere does not clear other sessions")
    }

    @Test func countsPerSubsetAndTotal() {
        var tracker = AttentionTracker()
        tracker.record(.bell, from: a, focus: .nobody)
        tracker.record(.bell, from: b, focus: .nobody)
        tracker.record(.bell, from: b, focus: .nobody) // again: still one session
        #expect(tracker.total == 2)
        #expect(tracker.count(in: [a]) == 1)
        #expect(tracker.count(in: [a, b, c]) == 2)
        #expect(tracker.count(in: [a, a]) == 1, "a session shown twice counts once")
        #expect(tracker.count(in: [c]) == 0)
        #expect(tracker.sessions == [a, b], "in the order they first asked")
    }

    @Test func clearRetainAndClearAll() {
        var tracker = AttentionTracker()
        for id in [a, b, c] { tracker.record(.bell, from: id, focus: .nobody) }
        tracker.clear(a)
        #expect(tracker.sessions == [b, c])
        tracker.retain(only: [c])
        #expect(tracker.sessions == [c])
        tracker.clearAll()
        #expect(tracker.total == 0)
    }

    @Test func nextCyclesInSidebarOrderAndWraps() {
        var tracker = AttentionTracker()
        let order = [a, b, c]
        #expect(tracker.next(after: nil, in: order) == nil)
        tracker.record(.bell, from: c, focus: .nobody)
        tracker.record(.bell, from: a, focus: .nobody)
        #expect(tracker.next(after: nil, in: order) == a)
        #expect(tracker.next(after: a, in: order) == c)
        #expect(tracker.next(after: b, in: order) == c)
        #expect(tracker.next(after: c, in: order) == a, "wraps around")
        tracker.clear(a)
        #expect(tracker.next(after: c, in: order) == c, "the only one, even if current")
        #expect(tracker.next(after: SessionID(raw: "zzzzzzzzzzzzzzzz"), in: order) == c, "unknown current starts at the top")
        #expect(tracker.next(after: nil, in: [a, b]) == nil, "sessions not in the order are skipped")
    }

    @Test func dockBadgeLabel() {
        #expect(AttentionBadge.label(total: 0) == nil)
        #expect(AttentionBadge.label(total: 1) == "1")
        #expect(AttentionBadge.label(total: 12) == "12")
    }
}

@Suite("Attention lookups in the model")
@MainActor
struct AttentionModelTests {
    @Test func placeFindsWorkspaceGroupTabAndPane() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let first = model.newWorkspace(name: "One")
        let second = model.newWorkspace(name: "Two")
        let group = try #require(model.workspace(second)?.selectedTabGroupID)
        let tab = try #require(model.newTab(in: group))
        let pane = try #require(model.tab(tab)?.focusedPaneID)
        let split = try #require(model.splitPane(pane, axis: .horizontal))
        let session = try #require(model.tab(tab)?.pane(split)?.sessionID)

        let place = try #require(model.place(of: session))
        #expect(place == SessionPlace(workspace: second, tabGroup: group, tab: tab, pane: split))
        #expect(model.place(of: SessionID(raw: "missingmissingmi")) == nil)
        #expect(model.focusedSessionID(in: second) == session, "the split took focus")
        #expect(model.focusedSessionID(in: first) == model.sessionIDs(in: first).first)
        #expect(model.focusedSessionID(in: WorkspaceID(raw: "nope")) == nil)
    }

    @Test func sessionOrderFollowsTheSidebar() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let first = model.newWorkspace(name: "One")
        let second = model.newWorkspace(name: "Two")
        let group = try #require(model.workspace(first)?.selectedTabGroupID)
        model.newTab(in: group)
        let expected = model.sessionIDs(in: first) + model.sessionIDs(in: second)
        #expect(model.sessionOrder == expected)
        #expect(model.sessionIDs(ofTabGroup: group) == model.sessionIDs(in: first))
    }
}

@Suite("Agent integrations")
@MainActor
struct AgentIntegrationTests {
    let claudeArguments = ["--settings", #"{"preferredNotifChannel":"ghostty"}"#]

    @Test func builtInsHaveNoArgumentsAndClaudeGetsItsSettingWhileTheToggleIsOn() {
        #expect(Profile.claudeCode.arguments.isEmpty)
        #expect(Profile.codex.arguments.isEmpty)
        #expect(Profile.claudeCode.attentionIntegration)
        #expect(Profile.claudeCode.launchSpec.arguments == claudeArguments)
        #expect(Profile.codex.launchSpec.arguments.isEmpty, "Codex needs no arguments")
        #expect(AgentIntegration.codex.launchArguments.isEmpty)
        #expect(AgentIntegration.codex.toggleTitle == nil)
        #expect(AgentIntegration.for(.other("aider")) == nil)
        #expect(Profile.claudeCode.isAgent && Profile.codex.isAgent && !Profile.shell.isAgent)
    }

    @Test func theToggleAddsOrDropsTheArgumentInFrontOfTheProfilesOwn() {
        var profile = Profile(name: "Mine", kind: .agent(.claudeCode), program: "claude", arguments: ["--verbose"], icon: "star")
        #expect(profile.launchSpec.arguments == claudeArguments + ["--verbose"], "on: present")
        profile.attentionIntegration = false
        #expect(profile.launchSpec.arguments == ["--verbose"], "off: absent")
        let shell = Profile(name: "S", kind: .shell, arguments: ["-x"], icon: "terminal")
        #expect(shell.launchSpec.arguments == ["-x"], "only agents Armadale knows")
    }

    @Test func theBuiltInsToggleIsTheUsersAndReachesNewSessions() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        var edited = Profile.claudeCode
        edited.attentionIntegration = false
        edited.arguments = ["--ignored"] // built-in: only name, icon and the toggle are taken
        model.updateProfile(edited)
        let stored = try #require(model.profile(Profile.claudeCode.id))
        #expect(!stored.attentionIntegration)
        #expect(stored.arguments.isEmpty)
        let workspace = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let tab = try #require(model.newTab(in: group, profile: Profile.claudeCode.id))
        let session = try #require(model.sessionIDs(ofTab: tab).first.flatMap { model.session($0) })
        #expect(session.launch.arguments.isEmpty, "toggle off: no --settings")
        #expect(model.duplicateProfile(Profile.claudeCode.id).flatMap { model.profile($0) }?.attentionIntegration == false)
    }

    @Test func profilesSavedWithoutTheFieldDecodeWithItOn() throws {
        let json = #"{"id":"p1","name":"Old","kind":{"type":"agent","flavor":"claude-code"},"program":"claude","arguments":[],"environment":{},"icon":"sparkle"}"#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        #expect(profile.attentionIntegration)
        var off = profile
        off.attentionIntegration = false
        let round = try JSONDecoder().decode(Profile.self, from: try JSONEncoder().encode(off))
        #expect(!round.attentionIntegration)
        #expect(round == off)
    }

    @Test func savedBuiltInsTakeTheShippedLaunchButKeepNameIconAndToggle() throws {
        var stale = Profile.codex
        stale.arguments = ["-c", "tui.notification_method=\"osc9\""] // as an earlier build shipped it
        stale.name = "OpenAI Codex"
        stale.icon = "brain"
        var claude = Profile.claudeCode
        claude.attentionIntegration = false
        let custom = Profile(name: "Mine", kind: .agent(.codex), program: "codex", arguments: ["-x"], icon: "star")
        let state = PersistedState(workspaces: [], sessions: [], hosts: [], profiles: [stale, claude, custom])
        let model = AppModel(state: state, defaultWorkingDirectory: "/")
        let refreshed = try #require(model.profile(Profile.codex.id))
        #expect(refreshed.arguments.isEmpty)
        #expect(refreshed.name == "OpenAI Codex")
        #expect(refreshed.icon == "brain")
        #expect(model.profile(Profile.claudeCode.id)?.attentionIntegration == false)
        #expect(model.profile(custom.id)?.arguments == ["-x"], "user profiles are never changed")
        #expect(model.profiles.contains { $0.id == Profile.shell.id }, "missing built-ins are added")
    }

    @Test func hookSnippetsQuoteTheHelperPath() {
        let path = "/Applications/My Apps/Armadale.app/Contents/Resources/armadale-notify"
        let claude = AgentIntegration.claudeCode.hookSnippet(helperPath: path)
        #expect(claude.contains(#""command": "'/Applications/My Apps/Armadale.app/Contents/Resources/armadale-notify' 'Claude Code' 'Finished'""#))
        #expect(claude.contains(#""Stop""#))
        #expect((try? JSONSerialization.jsonObject(with: Data(claude.utf8))) != nil, "valid JSON")
        let codex = AgentIntegration.codex.hookSnippet(helperPath: #"/tmp/a "b"/armadale-notify"#)
        #expect(codex.hasPrefix(#"notify = ["/tmp/a \"b\"/armadale-notify", "Codex", "Turn complete"]"#), "top level first")
        #expect(codex.contains("[tui]\nnotification_method = \"osc9\""))
        #expect(AgentIntegration.posixQuoted("it's") == #"'it'\''s'"#)
    }
}

@Suite("Sessions leaving the model")
@MainActor
struct SessionRemovalHookTests {
    @Test func everyRemovalIsReportedSynchronously() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        var removed: [Set<SessionID>] = []
        model.onSessionsRemoved = { removed.append($0) }
        let workspace = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let tab = try #require(model.newTab(in: group))
        let session = try #require(model.sessionIDs(ofTab: tab).first)
        model.closeTab(tab)
        #expect(removed == [[session]])
        let other = try #require(model.sessionIDs(in: workspace).first)
        let replacement = Session(profileID: Profile.shell.id, launch: LaunchSpec(), workingDirectory: "/")
        model.replaceSession(other, with: replacement)
        #expect(removed.last == [other], "a respawn retires the old session")
    }
}
