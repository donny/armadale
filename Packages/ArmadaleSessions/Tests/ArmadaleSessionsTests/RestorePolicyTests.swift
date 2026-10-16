import ArmadaleCore
import Testing
@testable import ArmadaleSessions

@Suite("RestorePolicy")
struct RestorePolicyTests {
    let persistentSession = Session(profileID: Profile.shell.id, launch: LaunchSpec(), workingDirectory: "/", runtimeVersion: "0.8.1")
    let plainSession = Session(profileID: Profile.shell.id, launch: LaunchSpec(), workingDirectory: "/")

    @Test func persistentBackend() {
        let policy = RestorePolicy(backendIsPersistent: true)
        #expect(policy.action(for: persistentSession, restored: false, live: []) == .create)
        #expect(policy.action(for: persistentSession, restored: true, live: [persistentSession.id]) == .attach)
        #expect(policy.action(for: persistentSession, restored: true, live: []) == .markEnded)
        // Unknown (the probe failed): attach, which never creates.
        #expect(policy.action(for: persistentSession, restored: true, live: nil) == .attach)
        #expect(policy.mayRespawnUnshown(persistentSession, restored: true, live: []))
        #expect(!policy.mayRespawnUnshown(persistentSession, restored: true, live: [persistentSession.id]))
        #expect(!policy.mayRespawnUnshown(persistentSession, restored: true, live: nil))
        #expect(!policy.mayRespawnUnshown(persistentSession, restored: false, live: []))
    }

    /// Fallback mode (the persistent runtime could not be set up): the
    /// plain backend knows nothing of earlier daemons, so persistent
    /// sessions must not look ended, or Respawn All would retire them.
    @Test func fallbackNeverRetiresPersistentSessions() {
        let policy = RestorePolicy(backendIsPersistent: false)
        for live: Set<SessionID>? in [[], nil] {
            #expect(policy.action(for: persistentSession, restored: true, live: live) == .markUnavailable)
            #expect(!policy.mayRespawnUnshown(persistentSession, restored: true, live: live))
        }
        // Sessions that were plain all along are simply gone.
        #expect(policy.action(for: plainSession, restored: true, live: []) == .markEnded)
        #expect(policy.mayRespawnUnshown(plainSession, restored: true, live: []))
        // New sessions still work, as plain ones.
        #expect(policy.action(for: persistentSession, restored: false, live: []) == .create)
    }
}
