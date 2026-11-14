import AppKit
import ArmadaleCore
import Foundation
import Testing

/// One process per state directory (docs/DESIGN.md section 8, "App
/// lifecycle"): which lock outcomes stop a launch, the alert's wording, and
/// when the other copy is brought forward. The alert itself, the quit and
/// the activation are AppKit and checked live.
@Suite("Instance lock")
struct InstanceLockTests {
    private let directory = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Armadale", isDirectory: true)

    @Test func onlyALockHeldElsewhereStopsTheLaunch() throws {
        let temp = URL(fileURLWithPath: "/tmp/armadale-locktest-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let outcome = StateLock.acquire(directory: temp)
        guard case .acquired = outcome else {
            Issue.record("expected the lock in a fresh directory, got \(outcome)")
            return
        }
        #expect(InstanceLock.refusal(for: outcome, stateDirectory: temp) == nil)
        #expect(InstanceLock.unavailableLogLine(for: outcome) == nil)

        let unavailable = StateLock.Outcome.unavailable(reason: "flock: Operation not supported (errno 45)")
        #expect(InstanceLock.refusal(for: unavailable, stateDirectory: directory) == nil, "runs as before the lock")
        let line = try #require(InstanceLock.unavailableLogLine(for: unavailable))
        #expect(line.contains("Operation not supported"))

        let held = try #require(InstanceLock.refusal(for: .heldByAnotherProcess(pid: 4242), stateDirectory: directory))
        #expect(held.otherPID == 4242)
        #expect(InstanceLock.unavailableLogLine(for: .heldByAnotherProcess(pid: 4242)) == nil)
        let noPID = try #require(InstanceLock.refusal(for: .heldByAnotherProcess(pid: nil), stateDirectory: directory))
        #expect(noPID.otherPID == nil)
        #expect(!noPID.logLine.contains("pid"))
    }

    @Test func theAlertExplainsAndNamesTheDirectory() throws {
        let refusal = try #require(InstanceLock.refusal(for: .heldByAnotherProcess(pid: 4242), stateDirectory: directory))
        #expect(refusal.message == "Armadale is already running")
        #expect(refusal.details.contains(directory.path))
        #expect(refusal.details.contains("menu bar"))
        #expect(refusal.details.contains("quit"))
        // The log line is for whoever launched a build by hand: the holder,
        // the lock file and how to run a separate copy.
        #expect(refusal.logLine.contains("pid 4242"))
        #expect(refusal.logLine.contains(directory.appendingPathComponent("armadale.lock").path))
        #expect(refusal.logLine.contains("ARMADALE_STATE_DIR"))
        // Not in the alert: the variable is for developers.
        #expect(!refusal.details.contains("ARMADALE_STATE_DIR"))
        for text in [refusal.message, refusal.details, refusal.logLine] {
            #expect(!text.lowercased().contains("zmx"), "the persistence runtime is never named: \(text)")
        }
    }

    /// Every fatal launch (locked out, a newer state file, an unreadable
    /// one) quits under its alert; a reopen meanwhile opens no window.
    @MainActor
    @Test func aPendingFatalReportIgnoresReopen() {
        typealias Report = AppDelegate.LoadReport
        #expect(AppDelegate.ignoresReopen(pendingReport: Report(message: "m", details: "d", isFatal: true, bringForward: 42)))
        #expect(AppDelegate.ignoresReopen(pendingReport: Report(message: "m", details: "d", isFatal: true)))
        #expect(!AppDelegate.ignoresReopen(pendingReport: Report(message: "m", details: "d", isFatal: false)))
        #expect(!AppDelegate.ignoresReopen(pendingReport: nil))
    }

    @Test func onlyARegularArmadaleThatIsNotThisProcessIsBroughtForward() {
        let me: pid_t = 100
        let bundle = "com.tinylittleapps.armadale"
        func check(_ pid: pid_t?, _ id: String?, _ policy: NSApplication.ActivationPolicy?) -> Bool {
            InstanceLock.shouldBringForward(
                pid: pid, ownPID: me, bundleIdentifier: id, ownBundleIdentifier: bundle, activationPolicy: policy)
        }
        #expect(check(200, bundle, .regular))
        #expect(!check(nil, bundle, .regular), "no pid recorded")
        #expect(!check(me, bundle, .regular), "never this process")
        #expect(!check(200, "com.apple.Terminal", .regular), "a recycled pid")
        #expect(!check(200, nil, .regular))
        #expect(!check(200, bundle, .accessory), "in menu bar mode: left alone")
        #expect(!check(200, bundle, nil))
    }
}
