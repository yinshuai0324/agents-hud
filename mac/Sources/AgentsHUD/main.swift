import AppKit

// Pure AppKit entry point — no SwiftUI App/Scene, so the app never opens a stray
// window. The menu-bar status item and the SwiftUI popover live in AppDelegate.
//
// main.swift top-level code is nonisolated; we're already on the main thread at
// startup, so assume the main actor to construct the @MainActor delegate and run.
MainActor.assumeIsolated {
    let appDelegate = AppDelegate()
    let application = NSApplication.shared
    application.delegate = appDelegate
    application.run()
}
