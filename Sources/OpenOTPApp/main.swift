import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let delegate = AppDelegate()
    app.delegate = delegate
    // NSApplication.delegate is weak, and nothing else retains the delegate.
    // Release-mode ARC is free to deallocate it right after this assignment,
    // which tears down the status item controller (menu bar icon vanishes)
    // and every other subsystem it owns. Pin it for the app's lifetime.
    withExtendedLifetime(delegate) { app.run() }
}
