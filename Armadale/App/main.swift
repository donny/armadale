import AppKit

// AppKit lifecycle without a nib. Top-level code in main.swift runs on the
// main actor; `delegate` is a global, so it outlives the weak
// `NSApplication.delegate` reference.
// The updater is Sparkle's (App/SparkleUpdater.swift); it starts at the end
// of launching when the run allows it (UpdaterPolicy).
let delegate = AppDelegate(makeUpdater: { SparkleUpdater(coordinator: $0) })
// The subclass ends sheets before a quit (ArmadaleApplication).
let application = ArmadaleApplication.shared
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
