import Foundation
@testable import ArmadaleCore

extension AppModel {
    /// What the app's step 10a interim does with a new pane: starts a
    /// session (by default the shell, locally, in the home directory) in
    /// every empty pane of every workspace. Returns the sessions started.
    @discardableResult
    func fillEmptyPanes(
        profile: ProfileID = Profile.shell.id, location: Location = .local, workingDirectory: String = ""
    ) -> [SessionID] {
        let request = SessionRequest(location: location, profileID: profile, workingDirectory: workingDirectory)
        return workspaces.flatMap { emptyPaneIDs(in: $0.id) }.compactMap { startSession(in: $0, request: request) }
    }
}
