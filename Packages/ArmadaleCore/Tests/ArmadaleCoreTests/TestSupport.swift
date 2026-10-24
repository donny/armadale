import Foundation
@testable import ArmadaleCore

extension AppModel {
    /// Starts a session (by default the shell, locally, in the home
    /// directory) in every empty pane of every workspace, as step 10a's
    /// interim did with new panes. Returns the sessions started.
    @discardableResult
    func fillEmptyPanes(
        profile: ProfileID = Profile.shell.id, location: Location = .local, workingDirectory: String = ""
    ) -> [SessionID] {
        let request = SessionRequest(location: location, profileID: profile, workingDirectory: workingDirectory)
        return workspaces.flatMap { emptyPaneIDs(in: $0.id) }.compactMap { startSession(in: $0, request: request) }
    }
}
