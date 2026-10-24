import AppKit

/// What must happen before AppKit's own `terminate(_:)` runs.
@MainActor
protocol QuitPreparing: AnyObject {
    /// Ends whatever would make AppKit refuse to terminate.
    func prepareForQuit()
}

/// Armadale's application object. AppKit's `terminate(_:)` returns without
/// asking the delegate, and so without quitting, while any window has a
/// sheet attached (measured on macOS 27, for `presentAsSheet` and
/// `beginSheet` alike). Every quit path ends in `terminate(_:)`: the Quit
/// item, the system's quit Apple Event, the SIGTERM handler, the status
/// menu's Quit and End Sessions and Quit. So the delegate gets to end its
/// sheets here first (DESIGN §8, "App lifecycle").
@objc(ArmadaleApplication)
final class ArmadaleApplication: NSApplication {
    override func terminate(_ sender: Any?) {
        (delegate as? QuitPreparing)?.prepareForQuit()
        super.terminate(sender)
    }
}

extension Notification.Name {
    /// Posted by ``AppDelegate/prepareForQuit()`` before it ends a sheet in
    /// Settings, so its SwiftUI state lets go of it too.
    static let armadaleWillQuit = Notification.Name("com.tinylittleapps.armadale.willQuit")
}
