import AppKit

// AppKit lifecycle without a nib. Top-level code in main.swift runs on the
// main actor; `delegate` is a global, so it outlives the weak
// `NSApplication.delegate` reference.
let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
